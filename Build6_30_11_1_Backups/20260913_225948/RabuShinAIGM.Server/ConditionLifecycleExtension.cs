using System;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

// BUILD 6.30.11 - Condition saving throws, lifecycle, suppression, immunity and cures.
// This partial extension intentionally keeps the existing Build 6.19 condition engine intact.
public sealed partial class OpenAiGameMasterService
{
    private async Task<JsonElement> ApplyConditionWithImmunityAsync(Guid campaignId, ApplyConditionToolArguments args)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_apply_condition_extended",
            new
            {
                p_campaign_id = campaignId,
                p_target_type = (args.TargetType ?? string.Empty).Trim(),
                p_target_name = (args.TargetName ?? string.Empty).Trim(),
                p_condition_name = (args.ConditionName ?? string.Empty).Trim(),
                p_source_name = (args.SourceName ?? string.Empty).Trim(),
                p_duration_type = (args.DurationType ?? string.Empty).Trim(),
                p_rounds_remaining = args.RoundsRemaining,
                p_save_ability = (args.SaveAbility ?? string.Empty).Trim(),
                p_save_dc = args.SaveDc,
                p_notes = CleanReason(args.Notes, string.Empty)
            },
            "Unable to apply condition");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> SetConditionLifecycleAsync(Guid campaignId, ConditionLifecycleToolArguments args)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_set_condition_lifecycle",
            new
            {
                p_campaign_id = campaignId,
                p_target_type = args.TargetType.Trim(),
                p_target_name = args.TargetName.Trim(),
                p_condition_name = args.ConditionName.Trim(),
                p_source_name = args.SourceName.Trim(),
                p_repeat_save_timing = args.RepeatSaveTiming.Trim(),
                p_magic_effect = args.MagicEffect,
                p_spell_name = args.SpellName.Trim(),
                p_duration_minutes = Math.Max(0, args.DurationMinutes),
                p_ends_on_combat_end = args.EndsOnCombatEnd,
                p_ends_on_source_death = args.EndsOnSourceDeath,
                p_ends_on_source_lost_los = args.EndsOnSourceLostLos
            },
            "Unable to set condition lifecycle");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> ResolveConditionSaveAsync(Guid campaignId, ResolveConditionSaveToolArguments args)
    {
        var targetType = (args.TargetType ?? string.Empty).Trim();
        var targetName = (args.TargetName ?? string.Empty).Trim();
        var ability = (args.Ability ?? string.Empty).Trim();
        var sourceName = (args.SourceName ?? string.Empty).Trim();

        var conditionState = await GetCombatConditionsForGmAsync(campaignId);
        var matching = conditionState.FirstOrDefault(row =>
            row.EntityType.Equals(targetType, StringComparison.OrdinalIgnoreCase) &&
            row.DisplayName.Equals(targetName, StringComparison.OrdinalIgnoreCase) &&
            row.ConditionName.Equals(args.ConditionName ?? string.Empty, StringComparison.OrdinalIgnoreCase) &&
            row.DurationType.Equals("save_ends", StringComparison.OrdinalIgnoreCase) &&
            (sourceName.Length == 0 || row.SourceName.Equals(sourceName, StringComparison.OrdinalIgnoreCase)))
            ?? throw new InvalidOperationException($"No active save-ending {args.ConditionName} condition was found on {targetName}.");

        if (!string.IsNullOrWhiteSpace(matching.SaveAbility))
            ability = matching.SaveAbility;

        var rollArgs = new DiceToolArguments
        {
            Count = 1,
            Sides = 20,
            Modifier = 0,
            Advantage = false,
            Disadvantage = false,
            ActorName = targetName,
            TargetName = string.Empty,
            RollType = "saving_throw",
            Ability = ability,
            DistanceFeet = 0,
            SensoryBasis = "none",
            SourceVisible = true,
            RequiresAction = false,
            Reason = $"{targetName} repeated {ConditionRulesService.Title(args.ConditionName)} saving throw",
            Dc = matching.SaveDc ?? 0
        };

        if (targetType.Equals("character", StringComparison.OrdinalIgnoreCase))
        {
            var exhaustion = await GetCharacterExhaustionAsync(campaignId, targetName);
            rollArgs = ApplyExhaustionToRoll(rollArgs, exhaustion);
        }

        var conditionRoll = ConditionRulesService.ResolveRoll(
            conditionState,
            targetName,
            string.Empty,
            "saving_throw",
            ability,
            0,
            "none",
            true,
            false,
            rollArgs.Advantage,
            rollArgs.Disadvantage);

        if (conditionRoll.AutomaticFailure)
        {
            using var automaticFailure = JsonDocument.Parse(JsonSerializer.Serialize(new
            {
                success = true,
                condition = args.ConditionName,
                source = matching.SourceName,
                ability,
                dc = matching.SaveDc,
                automaticFailure = true,
                saveSucceeded = false,
                conditionRemoved = false,
                conditionSummary = conditionRoll.Summary
            }));
            return automaticFailure.RootElement.Clone();
        }

        rollArgs.Advantage = conditionRoll.Advantage;
        rollArgs.Disadvantage = conditionRoll.Disadvantage;
        var audit = ExecuteAuthoritativeRoll(rollArgs);
        var trustedD20 = audit.KeptRoll ?? audit.Rolls.FirstOrDefault();
        if (trustedD20 < 1 || trustedD20 > 20)
            throw new InvalidOperationException("Condition saving throw did not produce a valid d20 result.");

        var modifier = 0;
        if (targetType.Equals("monster", StringComparison.OrdinalIgnoreCase))
        {
            var combat = await GetCombatStateForGmAsync(campaignId);
            var monster = combat?.Monsters.FirstOrDefault(m =>
                m.DisplayName.Equals(targetName, StringComparison.OrdinalIgnoreCase));
            modifier = GetMonsterConditionSaveModifier(monster?.MonsterName ?? targetName, ability);
        }

        var raw = await CallSupabaseRpcAsync(
            "discord_gm_resolve_condition_save",
            new
            {
                p_campaign_id = campaignId,
                p_target_type = targetType,
                p_target_name = targetName,
                p_condition_name = (args.ConditionName ?? string.Empty).Trim(),
                p_source_name = sourceName,
                p_d20_roll = trustedD20,
                p_ability_modifier = modifier,
                p_timing = (args.Timing ?? string.Empty).Trim()
            },
            "Unable to resolve condition saving throw");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private static int GetMonsterConditionSaveModifier(string monsterName, string ability)
    {
        var codex = MonsterCodexService.Shared.Find((monsterName ?? string.Empty).Trim());
        var details = codex?.Details ?? string.Empty;
        var key = (ability ?? string.Empty).Trim().ToUpperInvariant() switch
        {
            "STRENGTH" => "STR",
            "DEXTERITY" => "DEX",
            "CONSTITUTION" => "CON",
            "INTELLIGENCE" => "INT",
            "WISDOM" => "WIS",
            "CHARISMA" => "CHA",
            _ => string.Empty
        };
        if (key.Length == 0) return 0;

        // Prefer an explicit Saving Throws entry from the stat block.
        var saveLine = Regex.Match(
            details,
            @"(?im)^\s*Saving Throws\s+([^\r\n]+)");
        if (saveLine.Success)
        {
            var saveMatch = Regex.Match(
                saveLine.Groups[1].Value,
                $@"\b{Regex.Escape(key)}\s*([+-]\d+)\b",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (saveMatch.Success &&
                int.TryParse(saveMatch.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var saveModifier))
                return saveModifier;
        }

        // Fall back to the normal ability modifier.
        var abilityMatch = Regex.Match(
            details,
            $@"\b{Regex.Escape(key)}\s+\d+\s*\(\s*([+-]?\d+)\s*\)",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        return abilityMatch.Success &&
               int.TryParse(abilityMatch.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var modifier)
            ? modifier
            : 0;
    }

    private async Task<JsonElement> SuppressConditionAsync(Guid campaignId, SuppressConditionToolArguments args)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_suppress_condition",
            new
            {
                p_campaign_id = campaignId,
                p_target_type = args.TargetType.Trim(),
                p_target_name = args.TargetName.Trim(),
                p_condition_name = args.ConditionName.Trim(),
                p_suppressing_effect = args.SuppressingEffect.Trim(),
                p_duration_minutes = Math.Max(0, args.DurationMinutes)
            },
            "Unable to suppress condition");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> RestoreSuppressedConditionAsync(Guid campaignId, RestoreSuppressedConditionToolArguments args)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_restore_suppressed_condition",
            new
            {
                p_campaign_id = campaignId,
                p_target_type = args.TargetType.Trim(),
                p_target_name = args.TargetName.Trim(),
                p_condition_name = args.ConditionName.Trim()
            },
            "Unable to restore suppressed condition");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> SetConditionImmunityAsync(Guid campaignId, ConditionImmunityToolArguments args)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_set_condition_immunity",
            new
            {
                p_campaign_id = campaignId,
                p_target_type = args.TargetType.Trim(),
                p_target_name = args.TargetName.Trim(),
                p_condition_name = args.ConditionName.Trim(),
                p_source_name = args.SourceName.Trim(),
                p_duration_minutes = Math.Max(0, args.DurationMinutes)
            },
            "Unable to set condition immunity");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> RemoveConditionImmunityAsync(Guid campaignId, ConditionImmunityToolArguments args)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_remove_condition_immunity",
            new
            {
                p_campaign_id = campaignId,
                p_target_type = args.TargetType.Trim(),
                p_target_name = args.TargetName.Trim(),
                p_condition_name = args.ConditionName.Trim(),
                p_source_name = args.SourceName.Trim()
            },
            "Unable to remove condition immunity");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> ConsumeConditionCureItemAsync(Guid campaignId, ConsumeConditionCureItemToolArguments args)
    {
        if (!Guid.TryParse(args.InventoryItemId, out var inventoryItemId))
            throw new InvalidOperationException("A valid curative inventoryItemId is required.");

        var raw = await CallSupabaseRpcAsync(
            "discord_gm_consume_condition_cure_item",
            new
            {
                p_campaign_id = campaignId,
                p_character_name = args.CharacterName.Trim(),
                p_inventory_item_id = inventoryItemId,
                p_reason = CleanReason(args.Reason, "Condition cured by inventory item")
            },
            "Unable to consume condition cure item");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> DispelConditionEffectAsync(Guid campaignId, DispelConditionEffectToolArguments args)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_dispel_condition_effect",
            new
            {
                p_campaign_id = campaignId,
                p_target_type = args.TargetType.Trim(),
                p_target_name = args.TargetName.Trim(),
                p_condition_name = args.ConditionName.Trim(),
                p_source_name = args.SourceName.Trim(),
                p_reason = CleanReason(args.Reason, "Magical condition effect dispelled")
            },
            "Unable to dispel condition effect");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> ResolveConditionSourceLosAsync(Guid campaignId, ResolveConditionSourceLosToolArguments args)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_resolve_condition_source_los",
            new
            {
                p_campaign_id = campaignId,
                p_target_type = args.TargetType.Trim(),
                p_target_name = args.TargetName.Trim(),
                p_source_name = args.SourceName.Trim(),
                p_has_line_of_sight = args.HasLineOfSight
            },
            "Unable to resolve condition source line of sight");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private static string[] LifecycleConditionNames => new[]
    {
        "blinded","charmed","deafened","frightened","grappled","incapacitated",
        "invisible","paralyzed","petrified","poisoned","prone","restrained","stunned","unconscious"
    };

    private static object BuildSetConditionLifecycleTool() => new
    {
        type = "function",
        name = "set_condition_lifecycle",
        description = "Attach authoritative ending rules to an already-applied condition: repeated start/end saves, magic/spell identity, world-time duration, combat-end removal, source-death removal, or source-line-of-sight removal. Call immediately after apply_condition when any of these rules apply.",
        strict = true,
        parameters = new
        {
            type = "object",
            properties = new
            {
                targetType = new { type = "string", @enum = new[] { "character", "monster" } },
                targetName = new { type = "string" },
                conditionName = new { type = "string", @enum = LifecycleConditionNames },
                sourceName = new { type = "string", description = "Exact sourceName used by apply_condition; empty only if apply_condition used an empty source." },
                repeatSaveTiming = new { type = "string", @enum = new[] { "none", "start", "end" } },
                magicEffect = new { type = "boolean" },
                spellName = new { type = "string", description = "Exact spell/effect name for a magical condition; empty for nonmagical effects." },
                durationMinutes = new { type = "integer", minimum = 0, maximum = 10080, description = "In-game minutes until automatic expiration; 0 means no world-time expiration." },
                endsOnCombatEnd = new { type = "boolean" },
                endsOnSourceDeath = new { type = "boolean" },
                endsOnSourceLostLos = new { type = "boolean" }
            },
            required = new[] { "targetType","targetName","conditionName","sourceName","repeatSaveTiming","magicEffect","spellName","durationMinutes","endsOnCombatEnd","endsOnSourceDeath","endsOnSourceLostLos" },
            additionalProperties = false
        }
    };

    private static object BuildResolveConditionSaveTool() => new
    {
        type = "function",
        name = "resolve_condition_save",
        description = "Roll one trusted repeated saving throw for an active save-ending condition. This works during combat and after combat. The server reads the stored DC/ability and automatically removes the condition on success.",
        strict = true,
        parameters = new
        {
            type = "object",
            properties = new
            {
                targetType = new { type = "string", @enum = new[] { "character", "monster" } },
                targetName = new { type = "string" },
                conditionName = new { type = "string", @enum = LifecycleConditionNames },
                sourceName = new { type = "string" },
                ability = new { type = "string", @enum = new[] { "strength","dexterity","constitution","intelligence","wisdom","charisma" }, description = "Stored save ability. Character modifier is read from the DB; monster modifier is read from the Monster Codex." },
                timing = new { type = "string", @enum = new[] { "start", "end" } }
            },
            required = new[] { "targetType","targetName","conditionName","sourceName","ability","timing" },
            additionalProperties = false
        }
    };

    private static object BuildSuppressConditionTool() => new
    {
        type = "function",
        name = "suppress_condition",
        description = "Temporarily suppress an underlying condition without curing/removing its cause. Use for effects such as Calm Emotions suppressing Charmed or Frightened. The underlying condition is preserved and automatically returns when the suppression duration expires unless it was cured meanwhile.",
        strict = true,
        parameters = new
        {
            type = "object",
            properties = new
            {
                targetType = new { type = "string", @enum = new[] { "character", "monster" } },
                targetName = new { type = "string" },
                conditionName = new { type = "string", @enum = LifecycleConditionNames },
                suppressingEffect = new { type = "string" },
                durationMinutes = new { type = "integer", minimum = 0, maximum = 10080 }
            },
            required = new[] { "targetType","targetName","conditionName","suppressingEffect","durationMinutes" },
            additionalProperties = false
        }
    };

    private static object BuildRestoreSuppressedConditionTool() => new
    {
        type = "function",
        name = "restore_suppressed_condition",
        description = "Restore a temporarily suppressed underlying condition early when the suppressing effect ends before its scheduled duration.",
        strict = true,
        parameters = new
        {
            type = "object",
            properties = new
            {
                targetType = new { type = "string", @enum = new[] { "character", "monster" } },
                targetName = new { type = "string" },
                conditionName = new { type = "string", @enum = LifecycleConditionNames }
            },
            required = new[] { "targetType","targetName","conditionName" },
            additionalProperties = false
        }
    };

    private static object BuildSetConditionImmunityTool() => new
    {
        type = "function",
        name = "set_condition_immunity",
        description = "Apply a temporary immunity to one condition, such as Heroism granting immunity to Frightened. Existing matching condition is cleared and new applications are rejected while immunity is active.",
        strict = true,
        parameters = new
        {
            type = "object",
            properties = new
            {
                targetType = new { type = "string", @enum = new[] { "character", "monster" } },
                targetName = new { type = "string" },
                conditionName = new { type = "string", @enum = LifecycleConditionNames },
                sourceName = new { type = "string" },
                durationMinutes = new { type = "integer", minimum = 0, maximum = 10080 }
            },
            required = new[] { "targetType","targetName","conditionName","sourceName","durationMinutes" },
            additionalProperties = false
        }
    };

    private static object BuildRemoveConditionImmunityTool() => new
    {
        type = "function",
        name = "remove_condition_immunity",
        description = "End a tracked temporary condition immunity early when its source spell/effect ends.",
        strict = true,
        parameters = new
        {
            type = "object",
            properties = new
            {
                targetType = new { type = "string", @enum = new[] { "character", "monster" } },
                targetName = new { type = "string" },
                conditionName = new { type = "string", @enum = LifecycleConditionNames },
                sourceName = new { type = "string" },
                durationMinutes = new { type = "integer", minimum = 0, maximum = 10080, description = "Compatibility field. Use 0." }
            },
            required = new[] { "targetType","targetName","conditionName","sourceName","durationMinutes" },
            additionalProperties = false
        }
    };

    private static object BuildConsumeConditionCureItemTool() => new
    {
        type = "function",
        name = "consume_condition_cure_item",
        description = "Atomically use a carried potion/item whose rules explicitly cure conditions. The server verifies the exact inventory item, removes only conditions listed by that item's cure rule, and consumes one item only if at least one condition was actually cured. Custom items may define item_data.cures_conditions. Built-ins include Lesser Restoration potions, Greater Restoration potions, poison antidote potions, sight-restoration potions, and paralysis-removal potions.",
        strict = true,
        parameters = new
        {
            type = "object",
            properties = new
            {
                characterName = new { type = "string" },
                inventoryItemId = new { type = "string", description = "Exact inventoryItemId from CURRENT INVENTORY." },
                reason = new { type = "string" }
            },
            required = new[] { "characterName","inventoryItemId","reason" },
            additionalProperties = false
        }
    };

    private static object BuildDispelConditionEffectTool() => new
    {
        type = "function",
        name = "dispel_condition_effect",
        description = "Remove a tracked condition only after Dispel Magic or another valid dispelling effect has successfully resolved. The server refuses to dispel a condition unless its lifecycle is marked as a magical effect.",
        strict = true,
        parameters = new
        {
            type = "object",
            properties = new
            {
                targetType = new { type = "string", @enum = new[] { "character", "monster" } },
                targetName = new { type = "string" },
                conditionName = new { type = "string", @enum = LifecycleConditionNames },
                sourceName = new { type = "string" },
                reason = new { type = "string" }
            },
            required = new[] { "targetType","targetName","conditionName","sourceName","reason" },
            additionalProperties = false
        }
    };

    private static object BuildResolveConditionSourceLosTool() => new
    {
        type = "function",
        name = "resolve_condition_source_los",
        description = "Resolve a condition that explicitly ends when its target loses line of sight to the source. Call after the tactical LOS check or when the fiction definitively establishes LOS was lost.",
        strict = true,
        parameters = new
        {
            type = "object",
            properties = new
            {
                targetType = new { type = "string", @enum = new[] { "character", "monster" } },
                targetName = new { type = "string" },
                sourceName = new { type = "string" },
                hasLineOfSight = new { type = "boolean" }
            },
            required = new[] { "targetType","targetName","sourceName","hasLineOfSight" },
            additionalProperties = false
        }
    };

    private sealed class ConditionLifecycleToolArguments
    {
        public string TargetType { get; set; } = string.Empty;
        public string TargetName { get; set; } = string.Empty;
        public string ConditionName { get; set; } = string.Empty;
        public string SourceName { get; set; } = string.Empty;
        public string RepeatSaveTiming { get; set; } = "none";
        public bool MagicEffect { get; set; }
        public string SpellName { get; set; } = string.Empty;
        public int DurationMinutes { get; set; }
        public bool EndsOnCombatEnd { get; set; }
        public bool EndsOnSourceDeath { get; set; }
        public bool EndsOnSourceLostLos { get; set; }
    }

    private sealed class ResolveConditionSaveToolArguments
    {
        public string TargetType { get; set; } = string.Empty;
        public string TargetName { get; set; } = string.Empty;
        public string ConditionName { get; set; } = string.Empty;
        public string SourceName { get; set; } = string.Empty;
        public string Ability { get; set; } = string.Empty;
        public string Timing { get; set; } = "end";
    }

    private sealed class SuppressConditionToolArguments
    {
        public string TargetType { get; set; } = string.Empty;
        public string TargetName { get; set; } = string.Empty;
        public string ConditionName { get; set; } = string.Empty;
        public string SuppressingEffect { get; set; } = string.Empty;
        public int DurationMinutes { get; set; }
    }

    private sealed class RestoreSuppressedConditionToolArguments
    {
        public string TargetType { get; set; } = string.Empty;
        public string TargetName { get; set; } = string.Empty;
        public string ConditionName { get; set; } = string.Empty;
    }

    private sealed class ConditionImmunityToolArguments
    {
        public string TargetType { get; set; } = string.Empty;
        public string TargetName { get; set; } = string.Empty;
        public string ConditionName { get; set; } = string.Empty;
        public string SourceName { get; set; } = string.Empty;
        public int DurationMinutes { get; set; }
    }

    private sealed class ConsumeConditionCureItemToolArguments
    {
        public string CharacterName { get; set; } = string.Empty;
        public string InventoryItemId { get; set; } = string.Empty;
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class DispelConditionEffectToolArguments
    {
        public string TargetType { get; set; } = string.Empty;
        public string TargetName { get; set; } = string.Empty;
        public string ConditionName { get; set; } = string.Empty;
        public string SourceName { get; set; } = string.Empty;
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class ResolveConditionSourceLosToolArguments
    {
        public string TargetType { get; set; } = string.Empty;
        public string TargetName { get; set; } = string.Empty;
        public string SourceName { get; set; } = string.Empty;
        public bool HasLineOfSight { get; set; }
    }
}
