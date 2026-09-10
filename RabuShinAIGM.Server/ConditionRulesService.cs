using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Serialization;

// RULES BUILD 6.19 - COMBAT CONDITIONS + STATUS EFFECTS
// Pure server-side condition mechanics. Supabase owns persistence; this class owns
// deterministic mechanical interpretation for rolls, movement, damage, and UI projection.
public static class ConditionRulesService
{
    public static readonly string[] SupportedConditions =
    {
        "blinded", "charmed", "deafened", "frightened", "grappled",
        "incapacitated", "invisible", "paralyzed", "petrified", "poisoned",
        "prone", "restrained", "stunned", "unconscious"
    };

    private static readonly HashSet<string> Incapacitating = new(StringComparer.OrdinalIgnoreCase)
    {
        "incapacitated", "paralyzed", "petrified", "stunned", "unconscious"
    };

    private static readonly HashSet<string> Immobile = new(StringComparer.OrdinalIgnoreCase)
    {
        "grappled", "paralyzed", "petrified", "restrained", "stunned", "unconscious"
    };

    public static IReadOnlyList<DiscordCombatConditionRow> ForCharacter(
        IEnumerable<DiscordCombatConditionRow>? rows, Guid characterId)
        => (rows ?? Array.Empty<DiscordCombatConditionRow>())
            .Where(r => r.EntityType.Equals("character", StringComparison.OrdinalIgnoreCase)
                     && r.CharacterId == characterId)
            .ToList();

    public static IReadOnlyList<DiscordCombatConditionRow> ForEntity(
        IEnumerable<DiscordCombatConditionRow>? rows, string entityType, string displayName)
        => (rows ?? Array.Empty<DiscordCombatConditionRow>())
            .Where(r => r.EntityType.Equals(entityType ?? string.Empty, StringComparison.OrdinalIgnoreCase)
                     && r.DisplayName.Equals(displayName ?? string.Empty, StringComparison.OrdinalIgnoreCase))
            .ToList();

    public static IReadOnlyList<DiscordCombatConditionRow> ForName(
        IEnumerable<DiscordCombatConditionRow>? rows, string displayName)
        => (rows ?? Array.Empty<DiscordCombatConditionRow>())
            .Where(r => r.DisplayName.Equals(displayName ?? string.Empty, StringComparison.OrdinalIgnoreCase))
            .ToList();

    public static bool Has(IEnumerable<DiscordCombatConditionRow>? rows, string condition)
        => (rows ?? Array.Empty<DiscordCombatConditionRow>())
            .Any(r => r.ConditionName.Equals(condition, StringComparison.OrdinalIgnoreCase));

    public static bool IsIncapacitated(IEnumerable<DiscordCombatConditionRow>? rows)
        => (rows ?? Array.Empty<DiscordCombatConditionRow>())
            .Any(r => Incapacitating.Contains(r.ConditionName));

    public static bool IsImmobile(IEnumerable<DiscordCombatConditionRow>? rows)
    {
        var list = (rows ?? Array.Empty<DiscordCombatConditionRow>()).ToList();
        return list.Any(r => Immobile.Contains(r.ConditionName))
            || list.Any(r => r.ConditionName.Equals("exhaustion", StringComparison.OrdinalIgnoreCase)
                          && r.ExhaustionLevel >= 5);
    }

    public static bool IsProne(IEnumerable<DiscordCombatConditionRow>? rows)
        => Has(rows, "prone") || Has(rows, "unconscious");

    public static string MovementBlockReason(IEnumerable<DiscordCombatConditionRow>? rows)
    {
        var list = (rows ?? Array.Empty<DiscordCombatConditionRow>()).ToList();
        var exhaustion = list.FirstOrDefault(r =>
            r.ConditionName.Equals("exhaustion", StringComparison.OrdinalIgnoreCase)
            && r.ExhaustionLevel >= 5);
        if (exhaustion is not null) return "Exhaustion Level 5 sets Speed to 0.";

        var condition = list.FirstOrDefault(r => Immobile.Contains(r.ConditionName));
        return condition is null
            ? string.Empty
            : $"{Title(condition.ConditionName)} sets Speed to 0.";
    }

    public static IReadOnlyList<string> FrighteningSources(IEnumerable<DiscordCombatConditionRow>? rows)
        => (rows ?? Array.Empty<DiscordCombatConditionRow>())
            .Where(r => r.ConditionName.Equals("frightened", StringComparison.OrdinalIgnoreCase))
            .Select(r => (r.SourceName ?? string.Empty).Trim())
            .Where(v => v.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

    public static int ApplyPetrifiedDamageResistance(
        IEnumerable<DiscordCombatConditionRow>? allRows,
        string entityType,
        string displayName,
        int hpDelta)
    {
        if (hpDelta >= 0) return hpDelta;
        var target = ForEntity(allRows, entityType, displayName);
        if (!Has(target, "petrified")) return hpDelta;

        var damage = Math.Abs(hpDelta);
        return -(damage / 2); // D&D resistance halves damage and rounds down.
    }

    public static ConditionRollResolution ResolveRoll(
        IEnumerable<DiscordCombatConditionRow>? allRows,
        string actorName,
        string targetName,
        string rollType,
        string ability,
        int distanceFeet,
        string sensoryBasis,
        bool sourceVisible,
        bool requiresAction,
        bool requestedAdvantage,
        bool requestedDisadvantage)
    {
        var actor = ForName(allRows, actorName);
        var target = ForName(allRows, targetName);
        var type = (rollType ?? string.Empty).Trim().ToLowerInvariant();
        var stat = (ability ?? string.Empty).Trim().ToLowerInvariant();
        var sense = (sensoryBasis ?? string.Empty).Trim().ToLowerInvariant();

        var reasons = new List<string>();
        var forceAdvantage = false;
        var forceDisadvantage = false;
        var automaticFailure = false;
        var illegalAction = false;
        var criticalOnHit = false;

        var actorPetrified = Has(actor, "petrified");
        var actorIncapacitated = IsIncapacitated(actor);

        if (requiresAction && actorIncapacitated)
        {
            illegalAction = true;
            reasons.Add("Incapacitated creatures cannot take actions or reactions.");
        }

        if (type == "attack")
        {
            if (actorIncapacitated)
            {
                illegalAction = true;
                reasons.Add("The attacker is incapacitated and cannot attack.");
            }

            if (Has(actor, "blinded"))
            {
                forceDisadvantage = true;
                reasons.Add("Blinded attacker.");
            }
            if (Has(actor, "poisoned") && !actorPetrified)
            {
                forceDisadvantage = true;
                reasons.Add("Poisoned attacker.");
            }
            if (Has(actor, "prone") || Has(actor, "unconscious"))
            {
                forceDisadvantage = true;
                reasons.Add("Prone attacker.");
            }
            if (Has(actor, "restrained"))
            {
                forceDisadvantage = true;
                reasons.Add("Restrained attacker.");
            }
            if (Has(actor, "invisible"))
            {
                forceAdvantage = true;
                reasons.Add("Invisible attacker.");
            }
            if (Has(actor, "frightened") && sourceVisible)
            {
                forceDisadvantage = true;
                reasons.Add("Frightened while the source of fear is visible.");
            }

            foreach (var charmed in actor.Where(r =>
                         r.ConditionName.Equals("charmed", StringComparison.OrdinalIgnoreCase)))
            {
                if (!string.IsNullOrWhiteSpace(targetName)
                    && !string.IsNullOrWhiteSpace(charmed.SourceName)
                    && targetName.Equals(charmed.SourceName, StringComparison.OrdinalIgnoreCase))
                {
                    illegalAction = true;
                    reasons.Add("A Charmed creature cannot attack its charmer.");
                }
            }

            if (Has(target, "blinded"))
            {
                forceAdvantage = true;
                reasons.Add("Target is Blinded.");
            }
            if (Has(target, "invisible"))
            {
                forceDisadvantage = true;
                reasons.Add("Target is Invisible.");
            }
            if (Has(target, "paralyzed") || Has(target, "petrified")
                || Has(target, "restrained") || Has(target, "stunned")
                || Has(target, "unconscious"))
            {
                forceAdvantage = true;
                reasons.Add("Target condition grants advantage to attackers.");
            }

            if (IsProne(target))
            {
                if (distanceFeet > 0 && distanceFeet <= 5)
                {
                    forceAdvantage = true;
                    reasons.Add("Attack is within 5 ft. of a Prone target.");
                }
                else
                {
                    forceDisadvantage = true;
                    reasons.Add("Attack is farther than 5 ft. from a Prone target.");
                }
            }

            if ((Has(target, "paralyzed") || Has(target, "unconscious"))
                && distanceFeet > 0 && distanceFeet <= 5)
            {
                criticalOnHit = true;
                reasons.Add("A hit within 5 ft. against a Paralyzed/Unconscious target is a critical hit.");
            }
        }
        else if (type is "ability_check" or "initiative")
        {
            if (Has(actor, "poisoned") && !actorPetrified)
            {
                forceDisadvantage = true;
                reasons.Add("Poisoned creature has disadvantage on ability checks.");
            }
            if (Has(actor, "frightened") && sourceVisible)
            {
                forceDisadvantage = true;
                reasons.Add("Frightened creature has disadvantage on ability checks while the source is visible.");
            }

            if (type == "ability_check" && sense == "sight" && Has(actor, "blinded"))
            {
                automaticFailure = true;
                reasons.Add("Blinded creature automatically fails checks that require sight.");
            }
            if (type == "ability_check" && sense == "hearing" && Has(actor, "deafened"))
            {
                automaticFailure = true;
                reasons.Add("Deafened creature automatically fails checks that require hearing.");
            }

            // Charmed: the charmer has advantage on social interaction checks with the charmed target.
            if (type == "ability_check" && stat == "charisma" && !string.IsNullOrWhiteSpace(actorName))
            {
                if (target.Any(r => r.ConditionName.Equals("charmed", StringComparison.OrdinalIgnoreCase)
                                 && r.SourceName.Equals(actorName, StringComparison.OrdinalIgnoreCase)))
                {
                    forceAdvantage = true;
                    reasons.Add("Charmer has advantage on social interaction with the Charmed target.");
                }
            }
        }
        else if (type == "saving_throw")
        {
            if ((stat == "strength" || stat == "dexterity")
                && (Has(actor, "paralyzed") || Has(actor, "petrified")
                    || Has(actor, "stunned") || Has(actor, "unconscious")))
            {
                automaticFailure = true;
                reasons.Add($"{Title(stat)} saving throw automatically fails because of the active condition.");
            }

            if (stat == "dexterity" && Has(actor, "restrained"))
            {
                forceDisadvantage = true;
                reasons.Add("Restrained creature has disadvantage on Dexterity saving throws.");
            }
        }

        var advantage = requestedAdvantage || forceAdvantage;
        var disadvantage = requestedDisadvantage || forceDisadvantage;
        if (advantage && disadvantage)
        {
            advantage = false;
            disadvantage = false;
            reasons.Add("Advantage and disadvantage cancel.");
        }

        return new ConditionRollResolution(
            illegalAction,
            automaticFailure,
            advantage,
            disadvantage,
            criticalOnHit,
            reasons.Count == 0 ? "No condition modifier." : string.Join(" ", reasons.Distinct()));
    }

    public static string FormatForEntity(
        IEnumerable<DiscordCombatConditionRow>? rows, string entityType, string displayName)
    {
        var list = ForEntity(rows, entityType, displayName);
        if (list.Count == 0) return string.Empty;

        var names = new List<string>();
        var exhaustion = list
            .Where(r => r.ConditionName.Equals("exhaustion", StringComparison.OrdinalIgnoreCase))
            .Select(r => r.ExhaustionLevel)
            .DefaultIfEmpty(0)
            .Max();

        if (exhaustion > 0) names.Add($"Exhaustion {exhaustion}");
        names.AddRange(list
            .Where(r => !r.ConditionName.Equals("exhaustion", StringComparison.OrdinalIgnoreCase))
            .Select(r => Title(r.ConditionName))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(v => v));

        return string.Join(", ", names);
    }

    public static object ToClientCondition(DiscordCombatConditionRow row) => new
    {
        conditionId = row.ConditionId,
        entityType = row.EntityType,
        characterId = row.CharacterId,
        combatMonsterId = row.CombatMonsterId,
        displayName = row.DisplayName,
        conditionName = row.ConditionName,
        sourceName = row.SourceName,
        notes = row.Notes,
        durationType = row.DurationType,
        roundsRemaining = row.RoundsRemaining,
        saveAbility = row.SaveAbility,
        saveDc = row.SaveDc,
        appliedRound = row.AppliedRound,
        exhaustionLevel = row.ExhaustionLevel
    };

    public static string Title(string? value)
    {
        var s = (value ?? string.Empty).Trim().ToLowerInvariant();
        return s switch
        {
            "blinded" => "Blinded",
            "charmed" => "Charmed",
            "deafened" => "Deafened",
            "frightened" => "Frightened",
            "grappled" => "Grappled",
            "incapacitated" => "Incapacitated",
            "invisible" => "Invisible",
            "paralyzed" => "Paralyzed",
            "petrified" => "Petrified",
            "poisoned" => "Poisoned",
            "prone" => "Prone",
            "restrained" => "Restrained",
            "stunned" => "Stunned",
            "unconscious" => "Unconscious",
            "exhaustion" => "Exhaustion",
            "strength" => "Strength",
            "dexterity" => "Dexterity",
            "constitution" => "Constitution",
            "intelligence" => "Intelligence",
            "wisdom" => "Wisdom",
            "charisma" => "Charisma",
            _ => string.IsNullOrWhiteSpace(value) ? string.Empty : value.Trim()
        };
    }
}

public sealed record ConditionRollResolution(
    bool IllegalAction,
    bool AutomaticFailure,
    bool Advantage,
    bool Disadvantage,
    bool CriticalOnHit,
    string Summary);

public sealed class DiscordCombatConditionRow
{
    [JsonPropertyName("condition_id")] public Guid? ConditionId { get; set; }
    [JsonPropertyName("entity_type")] public string EntityType { get; set; } = string.Empty;
    [JsonPropertyName("character_id")] public Guid? CharacterId { get; set; }
    [JsonPropertyName("combat_monster_id")] public Guid? CombatMonsterId { get; set; }
    [JsonPropertyName("display_name")] public string DisplayName { get; set; } = string.Empty;
    [JsonPropertyName("condition_name")] public string ConditionName { get; set; } = string.Empty;
    [JsonPropertyName("source_name")] public string SourceName { get; set; } = string.Empty;
    [JsonPropertyName("notes")] public string Notes { get; set; } = string.Empty;
    [JsonPropertyName("duration_type")] public string DurationType { get; set; } = string.Empty;
    [JsonPropertyName("rounds_remaining")] public int? RoundsRemaining { get; set; }
    [JsonPropertyName("save_ability")] public string SaveAbility { get; set; } = string.Empty;
    [JsonPropertyName("save_dc")] public int? SaveDc { get; set; }
    [JsonPropertyName("applied_round")] public int? AppliedRound { get; set; }
    [JsonPropertyName("exhaustion_level")] public int ExhaustionLevel { get; set; }
}
