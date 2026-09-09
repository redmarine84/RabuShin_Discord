using System.Text.Json;
using System.Text.Json.Serialization;
using QuestsOfRabuShinAIGM;

// RULES BUILD 6.13 - 2014 SUBRACES + DRACONIC ANCESTRY
public static class CharacterFeatureRules
{
    public const string RulesVersion = "6.13";

    public static readonly string[] AlignmentLadder =
    {
        "Lawful Good", "Neutral Good", "Chaotic Good",
        "Lawful Neutral", "True Neutral", "Chaotic Neutral",
        "Lawful Evil", "Neutral Evil", "Chaotic Evil"
    };

    public static readonly string[] AbilityNames =
        { "Strength", "Dexterity", "Constitution", "Intelligence", "Wisdom", "Charisma" };

    private static Dictionary<string, int> Bonus(params (string Ability, int Value)[] values)
        => values.ToDictionary(v => v.Ability, v => v.Value, StringComparer.OrdinalIgnoreCase);

    private static readonly Dictionary<string, Dictionary<string, int>> FixedAbilityBonuses = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Dragonborn"] = Bonus(("Strength", 2), ("Charisma", 1)),
        ["Dwarf"] = Bonus(("Constitution", 2)),
        ["Elf"] = Bonus(("Dexterity", 2)),
        ["Gnome"] = Bonus(("Intelligence", 2)),
        ["Halfling"] = Bonus(("Dexterity", 2)),
        ["Half-Orc"] = Bonus(("Strength", 2), ("Constitution", 1)),
        ["Half Orc"] = Bonus(("Strength", 2), ("Constitution", 1)),
        ["Human"] = Bonus(("Strength", 1), ("Dexterity", 1), ("Constitution", 1), ("Intelligence", 1), ("Wisdom", 1), ("Charisma", 1)),
        ["Orc"] = Bonus(("Strength", 2), ("Constitution", 1)),
        ["Tiefling"] = Bonus(("Charisma", 2), ("Intelligence", 1))
    };

    private static readonly Dictionary<string, string[]> TraitSummaries = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Dragonborn"] = new[] { "Draconic Ancestry", "Breath Weapon", "Damage Resistance" },
        ["Dwarf"] = new[]
        {
            "Darkvision (60 ft.)",
            "Dwarven Resilience (advantage on saves against poison and resistance to poison damage)",
            "Dwarven Combat Training (battleaxe, handaxe, light hammer, warhammer)",
            "Stonecunning"
        },
        ["Elf"] = new[] { "Darkvision (60 ft.)", "Keen Senses (Perception proficiency)", "Fey Ancestry", "Trance" },
        ["Gnome"] = new[] { "Darkvision (60 ft.)", "Gnome Cunning" },
        ["Halfling"] = new[] { "Lucky", "Brave", "Halfling Nimbleness" },
        ["Half-Orc"] = new[] { "Darkvision (60 ft.)", "Menacing", "Relentless Endurance", "Savage Attacks" },
        ["Half Orc"] = new[] { "Darkvision (60 ft.)", "Menacing", "Relentless Endurance", "Savage Attacks" },
        ["Human"] = new[] { "Human versatility" },
        ["Orc"] = new[] { "Darkvision", "Adrenaline Rush", "Powerful Build" },
        ["Tiefling"] = new[] { "Darkvision (60 ft.)", "Hellish Resistance", "Infernal Legacy" },
        ["Tortle"] = new[] { "Claws (1d6 + Strength slashing)", "Hold Breath (1 hour)", "Natural Armor (base AC 17)", "Nature's Intuition", "Shell Defense (+4 AC while withdrawn)" }
    };

    private static readonly Dictionary<string, SubraceRule[]> SubraceRules = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Elf"] = new[]
        {
            new SubraceRule(
                "High Elf",
                Bonus(("Intelligence", 1)),
                new[] { "Elf Weapon Training (longsword, shortsword, shortbow, longbow)", "High Elf Cantrip", "High Elf Extra Language" }),
            new SubraceRule(
                "Wood Elf",
                Bonus(("Wisdom", 1)),
                new[] { "Elf Weapon Training (longsword, shortsword, shortbow, longbow)", "Fleet of Foot (walking speed 35 ft.)", "Mask of the Wild" },
                SpeedOverride: 35),
            new SubraceRule(
                "Dark Elf (Drow)",
                Bonus(("Charisma", 1)),
                new[]
                {
                    "Superior Darkvision (120 ft.)",
                    "Sunlight Sensitivity",
                    "Drow Magic (Dancing Lights; Faerie Fire at level 3; Darkness at level 5; Charisma spellcasting)",
                    "Drow Weapon Training (rapier, shortsword, hand crossbow)"
                })
        },
        ["Dwarf"] = new[]
        {
            new SubraceRule(
                "Hill Dwarf",
                Bonus(("Wisdom", 1)),
                new[] { "Dwarven Toughness (+1 maximum HP per character level)" },
                HitPointBonusPerLevel: 1),
            new SubraceRule(
                "Mountain Dwarf",
                Bonus(("Strength", 2)),
                new[] { "Dwarven Armor Training (light and medium armor proficiency)" })
        },
        ["Halfling"] = new[]
        {
            new SubraceRule(
                "Lightfoot Halfling",
                Bonus(("Charisma", 1)),
                new[] { "Naturally Stealthy" }),
            new SubraceRule(
                "Stout Halfling",
                Bonus(("Constitution", 1)),
                new[] { "Stout Resilience (advantage on saves against poison and resistance to poison damage)" })
        },
        ["Gnome"] = new[]
        {
            new SubraceRule(
                "Forest Gnome",
                Bonus(("Dexterity", 1)),
                new[] { "Natural Illusionist (Minor Illusion cantrip; Intelligence spellcasting)", "Speak with Small Beasts" }),
            new SubraceRule(
                "Rock Gnome",
                Bonus(("Constitution", 1)),
                new[] { "Artificer's Lore", "Tinker (tinker's tools proficiency; clockwork devices)" })
        }
    };

    private static readonly DragonbornAncestryRule[] DragonbornAncestries =
    {
        new("Black", "Acid", "5 by 30 ft. line", "Dexterity"),
        new("Blue", "Lightning", "5 by 30 ft. line", "Dexterity"),
        new("Brass", "Fire", "5 by 30 ft. line", "Dexterity"),
        new("Bronze", "Lightning", "5 by 30 ft. line", "Dexterity"),
        new("Copper", "Acid", "5 by 30 ft. line", "Dexterity"),
        new("Gold", "Fire", "15 ft. cone", "Dexterity"),
        new("Green", "Poison", "15 ft. cone", "Constitution"),
        new("Red", "Fire", "15 ft. cone", "Dexterity"),
        new("Silver", "Cold", "15 ft. cone", "Constitution"),
        new("White", "Cold", "15 ft. cone", "Constitution")
    };

    public static readonly string[] HighElfWizardCantrips =
    {
        "Acid Splash", "Blade Ward", "Chill Touch", "Dancing Lights", "Fire Bolt", "Friends", "Light",
        "Mage Hand", "Mending", "Message", "Minor Illusion", "Poison Spray", "Prestidigitation",
        "Ray of Frost", "Shocking Grasp", "True Strike"
    };

    public static readonly string[] DwarfToolChoices = { "Smith's Tools", "Brewer's Supplies", "Mason's Tools" };

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
        var subraces = SubraceRules.ToDictionary(
            pair => pair.Key,
            pair => pair.Value.Select(rule => new
            {
                name = rule.Name,
                abilityBonuses = rule.AbilityBonuses,
                traits = rule.Traits,
                speedOverride = rule.SpeedOverride,
                hitPointBonusPerLevel = rule.HitPointBonusPerLevel
            }).ToArray(),
            StringComparer.OrdinalIgnoreCase);

        return new
        {
            rulesVersion = RulesVersion,
            abilityNames = AbilityNames,
            fixedBonuses = FixedAbilityBonuses,
            subraces,
            dragonbornAncestries = DragonbornAncestries.Select(a => new
            {
                name = a.Name,
                damageType = a.DamageType,
                area = a.Area,
                savingThrow = a.SavingThrow,
                resistance = a.DamageType
            }).ToArray(),
            highElfWizardCantrips = HighElfWizardCantrips,
            dwarfTools = DwarfToolChoices,
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

    public static string PrimaryHeritage(string species)
    {
        var value = (species ?? string.Empty).Trim();
        return value.StartsWith("Half ", StringComparison.OrdinalIgnoreCase) ? value[5..].Trim() : value;
    }

    public static bool IsHalfRace(string species) => (species ?? string.Empty).Trim().StartsWith("Half ", StringComparison.OrdinalIgnoreCase);
    public static bool IsTortleLineage(string species) => PrimaryHeritage(species).Equals("Tortle", StringComparison.OrdinalIgnoreCase);
    public static bool RequiresSubrace(string species) => SubraceRules.ContainsKey(PrimaryHeritage(species));
    public static bool RequiresDragonbornAncestry(string species) => PrimaryHeritage(species).Equals("Dragonborn", StringComparison.OrdinalIgnoreCase);

    public static AppliedRacialScores ApplyAbilityScores(
        string species,
        int strength, int dexterity, int constitution, int intelligence, int wisdom, int charisma,
        Dictionary<string, int>? choices,
        string? subrace)
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

        var selectedSubrace = GetSubraceRule(heritage, subrace, requireWhenSupported: true);
        if (selectedSubrace is not null)
        {
            foreach (var pair in selectedSubrace.AbilityBonuses)
                AddBonus(values, applied, pair.Key, pair.Value);
        }

        return new AppliedRacialScores(
            values["Strength"], values["Dexterity"], values["Constitution"],
            values["Intelligence"], values["Wisdom"], values["Charisma"], applied);
    }

    // The legacy random generator already applied the base race's fixed ability increases.
    // Build 6.13 applies only the selected subrace increase to the generated numeric scores,
    // while returning the complete expected racial bonus map for the character sheet.
    public static AppliedRacialScores ApplyGeneratedSubraceScores(
        string species,
        int strength, int dexterity, int constitution, int intelligence, int wisdom, int charisma,
        string? subrace)
    {
        var values = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
        {
            ["Strength"] = strength, ["Dexterity"] = dexterity, ["Constitution"] = constitution,
            ["Intelligence"] = intelligence, ["Wisdom"] = wisdom, ["Charisma"] = charisma
        };
        var applied = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var heritage = PrimaryHeritage(species);

        if (FixedAbilityBonuses.TryGetValue(heritage, out var baseBonuses))
            foreach (var pair in baseBonuses) applied[pair.Key] = pair.Value;

        var selectedSubrace = GetSubraceRule(heritage, subrace, requireWhenSupported: true);
        if (selectedSubrace is not null)
        {
            foreach (var pair in selectedSubrace.AbilityBonuses)
            {
                var next = values[pair.Key] + pair.Value;
                if (next > 20)
                    throw new InvalidOperationException($"{pair.Key} would exceed 20 after the {selectedSubrace.Name} ability increase.");
                values[pair.Key] = next;
                applied[pair.Key] = applied.TryGetValue(pair.Key, out var prior) ? prior + pair.Value : pair.Value;
            }
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
        applied[ability] = applied.TryGetValue(ability, out var prior) ? prior + bonus : bonus;
    }

    private static SubraceRule? GetSubraceRule(string heritage, string? requested, bool requireWhenSupported)
    {
        if (!SubraceRules.TryGetValue(heritage, out var available)) return null;
        var value = (requested ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(value))
        {
            if (requireWhenSupported) throw new InvalidOperationException($"Choose a {heritage} subrace.");
            return null;
        }

        if (heritage.Equals("Elf", StringComparison.OrdinalIgnoreCase))
        {
            if (value.Equals("Drow", StringComparison.OrdinalIgnoreCase) || value.Equals("Dark Elf", StringComparison.OrdinalIgnoreCase))
                value = "Dark Elf (Drow)";
        }
        else if (heritage.Equals("Halfling", StringComparison.OrdinalIgnoreCase))
        {
            if (value.Equals("Lightfoot", StringComparison.OrdinalIgnoreCase)) value = "Lightfoot Halfling";
            if (value.Equals("Stout", StringComparison.OrdinalIgnoreCase)) value = "Stout Halfling";
        }

        return available.FirstOrDefault(r => r.Name.Equals(value, StringComparison.OrdinalIgnoreCase))
               ?? throw new InvalidOperationException($"'{requested}' is not a valid {heritage} subrace.");
    }

    private static DragonbornAncestryRule GetDragonbornAncestry(string? requested)
    {
        var value = (requested ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(value))
            throw new InvalidOperationException("Choose your Dragonborn Draconic Ancestry.");
        return DragonbornAncestries.FirstOrDefault(a => a.Name.Equals(value, StringComparison.OrdinalIgnoreCase))
               ?? throw new InvalidOperationException($"'{requested}' is not a valid Dragonborn ancestry.");
    }

    public static CharacterFeatureProfile BuildProfile(
        string species,
        string? secondaryHeritage,
        AppliedRacialScores scores,
        string? subrace,
        string? dragonbornAncestry,
        string? highElfCantrip,
        string? highElfLanguage,
        string? dwarfTool,
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

        var selectedSubrace = GetSubraceRule(primary, subrace, requireWhenSupported: true);
        var traits = new List<string>();
        if (TraitSummaries.TryGetValue(primary, out var primaryTraits)) traits.AddRange(primaryTraits);
        if (selectedSubrace is not null) traits.AddRange(selectedSubrace.Traits.Select(t => $"{selectedSubrace.Name}: {t}"));
        if (!string.IsNullOrWhiteSpace(secondary) && TraitSummaries.TryGetValue(secondary, out var secondaryTraits))
            traits.AddRange(secondaryTraits.Select(t => $"{secondary} heritage: {t}"));

        var size = string.Empty;
        var natureSkill = string.Empty;
        var extraLanguage = string.Empty;
        var canonicalCantrip = string.Empty;
        var canonicalDwarfTool = string.Empty;
        DragonbornAncestryRule? ancestry = null;

        if (primary.Equals("Tortle", StringComparison.OrdinalIgnoreCase))
        {
            size = string.Equals(tortleSize, "Small", StringComparison.OrdinalIgnoreCase) ? "Small" : "Medium";
            var validSkill = new[] { "Animal Handling", "Medicine", "Nature", "Perception", "Stealth", "Survival" }
                .FirstOrDefault(v => v.Equals(tortleNatureSkill, StringComparison.OrdinalIgnoreCase));
            natureSkill = validSkill ?? "Survival";
            extraLanguage = string.IsNullOrWhiteSpace(tortleLanguage) ? "Aquan" : tortleLanguage.Trim();
        }

        if (primary.Equals("Dwarf", StringComparison.OrdinalIgnoreCase))
        {
            canonicalDwarfTool = DwarfToolChoices.FirstOrDefault(v => v.Equals(dwarfTool, StringComparison.OrdinalIgnoreCase))
                                 ?? throw new InvalidOperationException("Choose Smith's Tools, Brewer's Supplies, or Mason's Tools for Dwarven Tool Proficiency.");
            traits.Add($"Dwarven Tool Proficiency: {canonicalDwarfTool}");
        }

        if (selectedSubrace?.Name.Equals("High Elf", StringComparison.OrdinalIgnoreCase) == true)
        {
            canonicalCantrip = HighElfWizardCantrips.FirstOrDefault(v => v.Equals(highElfCantrip, StringComparison.OrdinalIgnoreCase))
                               ?? throw new InvalidOperationException("Choose a valid High Elf wizard cantrip.");
            extraLanguage = (highElfLanguage ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(extraLanguage))
                throw new InvalidOperationException("Choose the High Elf extra language.");
            traits.Add($"High Elf Cantrip: {canonicalCantrip} (Intelligence spellcasting)");
            traits.Add($"High Elf Extra Language: {extraLanguage}");
        }

        if (primary.Equals("Dragonborn", StringComparison.OrdinalIgnoreCase))
        {
            ancestry = GetDragonbornAncestry(dragonbornAncestry);
            traits.RemoveAll(t => t.Equals("Draconic Ancestry", StringComparison.OrdinalIgnoreCase)
                                  || t.Equals("Breath Weapon", StringComparison.OrdinalIgnoreCase)
                                  || t.Equals("Damage Resistance", StringComparison.OrdinalIgnoreCase));
            traits.Add($"Draconic Ancestry: {ancestry.Name} Dragon");
            traits.Add($"Breath Weapon ({ancestry.DamageType}): {ancestry.Area}; {ancestry.SavingThrow} save; DC = 8 + Constitution modifier + proficiency bonus; 2d6 at level 1, 3d6 at level 6, 4d6 at level 11, 5d6 at level 16; half damage on a successful save; usable once per short or long rest");
            traits.Add($"Damage Resistance: {ancestry.DamageType}");
        }

        return new CharacterFeatureProfile
        {
            PrimaryHeritage = primary,
            SecondaryHeritage = secondary,
            Subrace = selectedSubrace?.Name ?? string.Empty,
            DragonbornAncestry = ancestry?.Name ?? string.Empty,
            RacialAbilityBonuses = scores.Bonuses,
            RacialTraits = traits.Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
            NaturalArmorBase = primary.Equals("Tortle", StringComparison.OrdinalIgnoreCase) ? 17 : null,
            SpeedOverride = selectedSubrace?.SpeedOverride,
            HitPointBonusPerLevel = selectedSubrace?.HitPointBonusPerLevel ?? 0,
            Size = size,
            NatureIntuitionSkill = natureSkill,
            ExtraLanguage = extraLanguage,
            HighElfCantrip = canonicalCantrip,
            DwarfToolProficiency = canonicalDwarfTool,
            BreathWeaponDamageType = ancestry?.DamageType ?? string.Empty,
            BreathWeaponArea = ancestry?.Area ?? string.Empty,
            BreathWeaponSavingThrow = ancestry?.SavingThrow ?? string.Empty,
            DamageResistance = ancestry?.DamageType ?? string.Empty
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
        if (features.TryGetProperty("subrace", out var subrace) && !string.IsNullOrWhiteSpace(subrace.GetString()))
            lines.Add($"Subrace: {subrace.GetString()}");
        if (features.TryGetProperty("dragonbornAncestry", out var ancestry) && !string.IsNullOrWhiteSpace(ancestry.GetString()))
            lines.Add($"Draconic ancestry: {ancestry.GetString()}");
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
        return string.Join("; ", lines.Distinct(StringComparer.OrdinalIgnoreCase));
    }
}

public sealed record SubraceRule(
    string Name,
    IReadOnlyDictionary<string, int> AbilityBonuses,
    IReadOnlyList<string> Traits,
    int? SpeedOverride = null,
    int HitPointBonusPerLevel = 0);

public sealed record DragonbornAncestryRule(string Name, string DamageType, string Area, string SavingThrow);

public sealed record AppliedRacialScores(
    int Strength, int Dexterity, int Constitution, int Intelligence, int Wisdom, int Charisma,
    IReadOnlyDictionary<string, int> Bonuses);

public sealed class CharacterFeatureProfile
{
    [JsonPropertyName("primaryHeritage")] public string PrimaryHeritage { get; set; } = string.Empty;
    [JsonPropertyName("secondaryHeritage")] public string SecondaryHeritage { get; set; } = string.Empty;
    [JsonPropertyName("subrace")] public string Subrace { get; set; } = string.Empty;
    [JsonPropertyName("dragonbornAncestry")] public string DragonbornAncestry { get; set; } = string.Empty;
    [JsonPropertyName("racialAbilityBonuses")] public IReadOnlyDictionary<string, int> RacialAbilityBonuses { get; set; } = new Dictionary<string, int>();
    [JsonPropertyName("racialTraits")] public IReadOnlyList<string> RacialTraits { get; set; } = Array.Empty<string>();
    [JsonPropertyName("naturalArmorBase")] public int? NaturalArmorBase { get; set; }
    [JsonPropertyName("speedOverride")] public int? SpeedOverride { get; set; }
    [JsonPropertyName("hitPointBonusPerLevel")] public int HitPointBonusPerLevel { get; set; }
    [JsonPropertyName("size")] public string Size { get; set; } = string.Empty;
    [JsonPropertyName("natureIntuitionSkill")] public string NatureIntuitionSkill { get; set; } = string.Empty;
    [JsonPropertyName("extraLanguage")] public string ExtraLanguage { get; set; } = string.Empty;
    [JsonPropertyName("highElfCantrip")] public string HighElfCantrip { get; set; } = string.Empty;
    [JsonPropertyName("dwarfToolProficiency")] public string DwarfToolProficiency { get; set; } = string.Empty;
    [JsonPropertyName("breathWeaponDamageType")] public string BreathWeaponDamageType { get; set; } = string.Empty;
    [JsonPropertyName("breathWeaponArea")] public string BreathWeaponArea { get; set; } = string.Empty;
    [JsonPropertyName("breathWeaponSavingThrow")] public string BreathWeaponSavingThrow { get; set; } = string.Empty;
    [JsonPropertyName("damageResistance")] public string DamageResistance { get; set; } = string.Empty;
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
    public string? Subrace { get; set; }
    public string? DragonbornAncestry { get; set; }
    public string? HighElfCantrip { get; set; }
    public string? HighElfLanguage { get; set; }
    public string? DwarfTool { get; set; }
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
    public string? Subrace { get; set; }
    public string? DragonbornAncestry { get; set; }
    public string? HighElfCantrip { get; set; }
    public string? HighElfLanguage { get; set; }
    public string? DwarfTool { get; set; }
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
