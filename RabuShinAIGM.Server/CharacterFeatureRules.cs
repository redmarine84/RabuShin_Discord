using System.Text.Json;
using System.Text.Json.Serialization;
using QuestsOfRabuShinAIGM;

public static class CharacterFeatureRules
{
    public static readonly string[] AlignmentLadder =
    {
        "Lawful Good", "Neutral Good", "Chaotic Good",
        "Lawful Neutral", "True Neutral", "Chaotic Neutral",
        "Lawful Evil", "Neutral Evil", "Chaotic Evil"
    };

    private static readonly Dictionary<string, Dictionary<string, int>> FixedAbilityBonuses = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Dragonborn"] = new() { ["Strength"] = 2, ["Charisma"] = 1 },
        ["Dwarf"] = new() { ["Constitution"] = 2 },
        ["Elf"] = new() { ["Dexterity"] = 2 },
        ["Gnome"] = new() { ["Intelligence"] = 2 },
        ["Halfling"] = new() { ["Dexterity"] = 2 },
        ["Half-Orc"] = new() { ["Strength"] = 2, ["Constitution"] = 1 },
        ["Half Orc"] = new() { ["Strength"] = 2, ["Constitution"] = 1 },
        ["Human"] = new() { ["Strength"] = 1, ["Dexterity"] = 1, ["Constitution"] = 1, ["Intelligence"] = 1, ["Wisdom"] = 1, ["Charisma"] = 1 },
        ["Orc"] = new() { ["Strength"] = 2, ["Constitution"] = 1 },
        ["Tiefling"] = new() { ["Charisma"] = 2, ["Intelligence"] = 1 }
    };

    private static readonly Dictionary<string, string[]> TraitSummaries = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Dragonborn"] = new[] { "Draconic ancestry", "Breath weapon", "Damage resistance" },
        ["Dwarf"] = new[] { "Darkvision", "Dwarven resilience", "Stonecunning" },
        ["Elf"] = new[] { "Darkvision", "Keen Senses", "Fey Ancestry", "Trance" },
        ["Gnome"] = new[] { "Darkvision", "Gnome Cunning" },
        ["Halfling"] = new[] { "Lucky", "Brave", "Halfling Nimbleness" },
        ["Half-Orc"] = new[] { "Darkvision", "Relentless Endurance", "Savage Attacks" },
        ["Half Orc"] = new[] { "Darkvision", "Relentless Endurance", "Savage Attacks" },
        ["Human"] = new[] { "Human versatility" },
        ["Orc"] = new[] { "Darkvision", "Adrenaline Rush", "Powerful Build" },
        ["Tiefling"] = new[] { "Darkvision", "Hellish Resistance", "Infernal Legacy" },
        ["Tortle"] = new[] { "Claws (1d6 + Strength slashing)", "Hold Breath (1 hour)", "Natural Armor (base AC 17)", "Nature's Intuition", "Shell Defense (+4 AC while withdrawn)" }
    };

    public static IReadOnlyList<string> WithTortleSpecies(IEnumerable<string> existing)
    {
        var result = existing.Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (!result.Contains("Tortle", StringComparer.OrdinalIgnoreCase)) result.Add("Tortle");
        if (!result.Contains("Half Tortle", StringComparer.OrdinalIgnoreCase)) result.Add("Half Tortle");
        return result.OrderBy(v => v, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public static IReadOnlyList<string> WithTortleBaseSpecies(IEnumerable<string> existing)
    {
        var result = existing.Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (!result.Contains("Tortle", StringComparer.OrdinalIgnoreCase)) result.Add("Tortle");
        return result.OrderBy(v => v, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public static object GetClientRules()
    {
        return new
        {
            abilityNames = AbilityNames,
            fixedBonuses = FixedAbilityBonuses,
            tortle = new
            {
                flexibleAbilityIncrease = true,
                patterns = new[] { "+2 / +1", "+1 / +1 / +1" },
                sizes = new[] { "Medium", "Small" },
                natureSkills = new[] { "Animal Handling", "Medicine", "Nature", "Perception", "Stealth", "Survival" },
                defaultLanguage = "Aquan",
                traits = TraitSummaries["Tortle"]
            },
            traitSummaries = TraitSummaries
        };
    }

    public static readonly string[] AbilityNames = { "Strength", "Dexterity", "Constitution", "Intelligence", "Wisdom", "Charisma" };

    public static string PrimaryHeritage(string species)
    {
        var value = (species ?? string.Empty).Trim();
        return value.StartsWith("Half ", StringComparison.OrdinalIgnoreCase) ? value[5..].Trim() : value;
    }

    public static bool IsHalfRace(string species) => (species ?? string.Empty).Trim().StartsWith("Half ", StringComparison.OrdinalIgnoreCase);
    public static bool IsTortleLineage(string species) => PrimaryHeritage(species).Equals("Tortle", StringComparison.OrdinalIgnoreCase);

    public static AppliedRacialScores ApplyAbilityScores(
        string species,
        int strength, int dexterity, int constitution, int intelligence, int wisdom, int charisma,
        Dictionary<string, int>? choices)
    {
        var values = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
        {
            ["Strength"] = ClampBase(strength), ["Dexterity"] = ClampBase(dexterity), ["Constitution"] = ClampBase(constitution),
            ["Intelligence"] = ClampBase(intelligence), ["Wisdom"] = ClampBase(wisdom), ["Charisma"] = ClampBase(charisma)
        };

        var applied = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var heritage = PrimaryHeritage(species);

        if (heritage.Equals("Tortle", StringComparison.OrdinalIgnoreCase))
        {
            var normalized = NormalizeFlexibleChoices(choices);
            foreach (var pair in normalized) AddBonus(values, applied, pair.Key, pair.Value);
        }
        else if (FixedAbilityBonuses.TryGetValue(heritage, out var fixedBonuses))
        {
            foreach (var pair in fixedBonuses) AddBonus(values, applied, pair.Key, pair.Value);
        }

        return new AppliedRacialScores(
            values["Strength"], values["Dexterity"], values["Constitution"],
            values["Intelligence"], values["Wisdom"], values["Charisma"], applied);
    }

    private static Dictionary<string, int> NormalizeFlexibleChoices(Dictionary<string, int>? choices)
    {
        if (choices is null || choices.Count == 0)
            throw new InvalidOperationException("Choose your Tortle racial ability score increases.");

        var normalized = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in choices)
        {
            var ability = AbilityNames.FirstOrDefault(a => a.Equals(pair.Key, StringComparison.OrdinalIgnoreCase));
            if (ability is null || pair.Value <= 0) continue;
            if (normalized.ContainsKey(ability)) throw new InvalidOperationException("Each Tortle ability score choice must use a different ability.");
            normalized[ability] = pair.Value;
        }

        var bonuses = normalized.Values.OrderByDescending(v => v).ToArray();
        var valid = bonuses.SequenceEqual(new[] { 2, 1 }) || bonuses.SequenceEqual(new[] { 1, 1, 1 });
        if (!valid)
            throw new InvalidOperationException("Tortle ability increases must be +2 to one score and +1 to a different score, or +1 to three different scores.");
        return normalized;
    }

    private static int ClampBase(int value) => Math.Clamp(value <= 0 ? 10 : value, 1, 20);

    private static void AddBonus(Dictionary<string, int> values, Dictionary<string, int> applied, string ability, int bonus)
    {
        var next = values[ability] + bonus;
        if (next > 20) throw new InvalidOperationException($"{ability} would exceed 20 after its racial increase. Lower the base score before creating the character.");
        values[ability] = next;
        applied[ability] = bonus;
    }

    public static CharacterFeatureProfile BuildProfile(
        string species,
        string? secondaryHeritage,
        AppliedRacialScores scores,
        string? tortleSize,
        string? tortleNatureSkill,
        string? tortleLanguage)
    {
        var primary = PrimaryHeritage(species);
        var secondary = IsHalfRace(species) ? (secondaryHeritage ?? string.Empty).Trim() : string.Empty;
        if (IsHalfRace(species) && string.IsNullOrWhiteSpace(secondary))
            throw new InvalidOperationException("Choose the other half of your character's race.");
        if (!string.IsNullOrWhiteSpace(secondary) && secondary.Equals(primary, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The other half must be a different race.");

        var traits = new List<string>();
        if (TraitSummaries.TryGetValue(primary, out var primaryTraits)) traits.AddRange(primaryTraits);
        if (!string.IsNullOrWhiteSpace(secondary) && TraitSummaries.TryGetValue(secondary, out var secondaryTraits))
            traits.AddRange(secondaryTraits.Select(t => $"{secondary} heritage: {t}"));

        var size = string.Empty;
        var natureSkill = string.Empty;
        var language = string.Empty;
        if (primary.Equals("Tortle", StringComparison.OrdinalIgnoreCase))
        {
            size = string.Equals(tortleSize, "Small", StringComparison.OrdinalIgnoreCase) ? "Small" : "Medium";
            var validSkill = new[] { "Animal Handling", "Medicine", "Nature", "Perception", "Stealth", "Survival" }
                .FirstOrDefault(v => v.Equals(tortleNatureSkill, StringComparison.OrdinalIgnoreCase));
            natureSkill = validSkill ?? "Survival";
            language = string.IsNullOrWhiteSpace(tortleLanguage) ? "Aquan" : tortleLanguage.Trim();
        }

        return new CharacterFeatureProfile
        {
            PrimaryHeritage = primary,
            SecondaryHeritage = secondary,
            RacialAbilityBonuses = scores.Bonuses,
            RacialTraits = traits.Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
            NaturalArmorBase = primary.Equals("Tortle", StringComparison.OrdinalIgnoreCase) ? 17 : null,
            Size = size,
            NatureIntuitionSkill = natureSkill,
            ExtraLanguage = language
        };
    }

    public static string EngineSpecies(string requestedSpecies, IEnumerable<string> supportedSpecies)
    {
        if (supportedSpecies.Any(v => v.Equals(requestedSpecies, StringComparison.OrdinalIgnoreCase))) return requestedSpecies;
        return supportedSpecies.FirstOrDefault(v => v.Equals("Human", StringComparison.OrdinalIgnoreCase))
               ?? supportedSpecies.FirstOrDefault()
               ?? "Human";
    }

    public static string BuildGmTraitSummary(JsonElement characterData)
    {
        if (characterData.ValueKind != JsonValueKind.Object || !characterData.TryGetProperty("features", out var features)) return string.Empty;
        var lines = new List<string>();
        if (features.TryGetProperty("secondaryHeritage", out var secondary) && !string.IsNullOrWhiteSpace(secondary.GetString()))
            lines.Add($"Secondary heritage: {secondary.GetString()}");
        if (features.TryGetProperty("racialTraits", out var traits) && traits.ValueKind == JsonValueKind.Array)
        {
            foreach (var trait in traits.EnumerateArray())
            {
                var text = trait.GetString();
                if (!string.IsNullOrWhiteSpace(text)) lines.Add(text);
            }
        }
        if (features.TryGetProperty("natureIntuitionSkill", out var skill) && !string.IsNullOrWhiteSpace(skill.GetString()))
            lines.Add($"Nature's Intuition proficiency: {skill.GetString()}");
        if (features.TryGetProperty("extraLanguage", out var language) && !string.IsNullOrWhiteSpace(language.GetString()))
            lines.Add($"Additional language: {language.GetString()}");
        return string.Join("; ", lines);
    }
}

public sealed record AppliedRacialScores(
    int Strength, int Dexterity, int Constitution, int Intelligence, int Wisdom, int Charisma,
    IReadOnlyDictionary<string, int> Bonuses);

public sealed class CharacterFeatureProfile
{
    [JsonPropertyName("primaryHeritage")] public string PrimaryHeritage { get; set; } = string.Empty;
    [JsonPropertyName("secondaryHeritage")] public string SecondaryHeritage { get; set; } = string.Empty;
    [JsonPropertyName("racialAbilityBonuses")] public IReadOnlyDictionary<string, int> RacialAbilityBonuses { get; set; } = new Dictionary<string, int>();
    [JsonPropertyName("racialTraits")] public IReadOnlyList<string> RacialTraits { get; set; } = Array.Empty<string>();
    [JsonPropertyName("naturalArmorBase")] public int? NaturalArmorBase { get; set; }
    [JsonPropertyName("size")] public string Size { get; set; } = string.Empty;
    [JsonPropertyName("natureIntuitionSkill")] public string NatureIntuitionSkill { get; set; } = string.Empty;
    [JsonPropertyName("extraLanguage")] public string ExtraLanguage { get; set; } = string.Empty;
}

public sealed class EnhancedManualCharacterRequest
{
    public string CharacterName { get; set; } = string.Empty;
    public string Species { get; set; } = string.Empty;
    public string? SecondaryHeritage { get; set; }
    public string ClassName { get; set; } = string.Empty;
    public string Background { get; set; } = string.Empty;
    public string Alignment { get; set; } = string.Empty;
    public int Level { get; set; } = 1;
    public int Strength { get; set; } = 10;
    public int Dexterity { get; set; } = 10;
    public int Constitution { get; set; } = 10;
    public int Intelligence { get; set; } = 10;
    public int Wisdom { get; set; } = 10;
    public int Charisma { get; set; } = 10;
    public string? Appearance { get; set; }
    public string? Personality { get; set; }
    public string? Backstory { get; set; }
    public string? Notes { get; set; }
    public Dictionary<string, int>? RacialAbilityChoices { get; set; }
    public string? TortleSize { get; set; }
    public string? TortleNatureSkill { get; set; }
    public string? TortleLanguage { get; set; }
}

public sealed class EnhancedRandomCharacterRequest
{
    public string? CharacterName { get; set; }
    public string Species { get; set; } = string.Empty;
    public string? SecondaryHeritage { get; set; }
    public string ClassName { get; set; } = string.Empty;
    public Dictionary<string, int>? RacialAbilityChoices { get; set; }
    public string? TortleSize { get; set; }
    public string? TortleNatureSkill { get; set; }
    public string? TortleLanguage { get; set; }
}

public sealed class CharacterDetailsUpdateRequest
{
    public string Background { get; set; } = string.Empty;
    public string Appearance { get; set; } = string.Empty;
    public string Personality { get; set; } = string.Empty;
    public string Backstory { get; set; } = string.Empty;
    public string Notes { get; set; } = string.Empty;
}
