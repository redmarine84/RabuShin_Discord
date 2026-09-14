using System.Text.Json;

public static class MulticlassRules
{
    public static readonly string[] ClassOrder =
    {
        "Artificer", "Barbarian", "Bard", "Cleric", "Druid", "Fighter", "Monk",
        "Paladin", "Ranger", "Rogue", "Sorcerer", "Warlock", "Wizard"
    };

    private static readonly Dictionary<string,string> Requirements = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Artificer"] = "INT 13 (RabuShin extension)",
        ["Barbarian"] = "STR 13",
        ["Bard"] = "CHA 13",
        ["Cleric"] = "WIS 13",
        ["Druid"] = "WIS 13",
        ["Fighter"] = "STR 13 or DEX 13",
        ["Monk"] = "DEX 13 and WIS 13",
        ["Paladin"] = "STR 13 and CHA 13",
        ["Ranger"] = "DEX 13 and WIS 13",
        ["Rogue"] = "DEX 13",
        ["Sorcerer"] = "CHA 13",
        ["Warlock"] = "CHA 13",
        ["Wizard"] = "INT 13"
    };

    public static object GetRulesForClient() => new
    {
        rulesSource = "https://5thsrd.org/rules/multiclassing/",
        totalLevelCap = 20,
        classes = ClassOrder.Select(name => new
        {
            className = name,
            requirement = Requirements[name],
            artificerExtension = name.Equals("Artificer", StringComparison.OrdinalIgnoreCase)
        })
    };

    public static MulticlassPreview Preview(JsonElement state, JsonElement plan)
    {
        if (state.ValueKind != JsonValueKind.Object)
            throw new ArgumentException("Multiclass state is unavailable.");
        if (plan.ValueKind != JsonValueKind.Array)
            throw new ArgumentException("A class level plan is required.");

        var fromLevel = ReadInt(state, "fromLevel", ReadInt(state, "totalLevel", 1));
        var toLevel = ReadInt(state, "toLevel", fromLevel);
        var expected = Math.Max(0, toLevel - fromLevel);
        if (plan.GetArrayLength() != expected)
            throw new ArgumentException($"Choose exactly one class for each gained level ({expected} required).");

        var classLevels = new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
        if (state.TryGetProperty("classes", out var classes) && classes.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in classes.EnumerateArray())
            {
                var name = ReadString(item, "className");
                if (!string.IsNullOrWhiteSpace(name)) classLevels[name] = ReadInt(item, "level", 0);
            }
        }
        var initialClass = ReadString(state, "initialClass");
        if (classLevels.Count == 0 && !string.IsNullOrWhiteSpace(initialClass))
            classLevels[initialClass] = Math.Max(1, fromLevel);

        var optionEligibility = new Dictionary<string,bool>(StringComparer.OrdinalIgnoreCase);
        var optionRequirements = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        if (state.TryGetProperty("options", out var options) && options.ValueKind == JsonValueKind.Array)
        {
            foreach (var option in options.EnumerateArray())
            {
                var name = ReadString(option, "className");
                if (string.IsNullOrWhiteSpace(name)) continue;
                optionEligibility[name] = ReadBool(option, "eligible", false);
                optionRequirements[name] = ReadString(option, "requirement");
            }
        }

        var normalizedPlan = new List<MulticlassPlanItem>();
        var prompts = new List<MulticlassChoicePrompt>();
        var step = 0;
        foreach (var entry in plan.EnumerateArray())
        {
            step++;
            var expectedTotal = fromLevel + step;
            var total = ReadInt(entry, "totalLevel", expectedTotal);
            if (total != expectedTotal)
                throw new ArgumentException($"Level plan is out of order. Expected total level {expectedTotal}.");
            var className = CanonicalClass(ReadString(entry, "className"));
            if (className is null)
                throw new ArgumentException($"Unknown multiclass selection: {ReadString(entry, "className")}.");

            var alreadyClass = classLevels.ContainsKey(className);
            if (!alreadyClass && (!optionEligibility.TryGetValue(className, out var eligible) || !eligible))
            {
                var requirement = optionRequirements.TryGetValue(className, out var req) ? req : Requirements[className];
                throw new ArgumentException($"The character does not qualify for {className} ({requirement}).");
            }

            var proficiencyChoices = entry.TryGetProperty("proficiencyChoices", out var pc) && pc.ValueKind == JsonValueKind.Object
                ? pc.Clone()
                : JsonSerializer.Deserialize<JsonElement>("{}");
            if (!alreadyClass)
                ValidateProficiencyChoices(className, proficiencyChoices);

            var oldClassLevel = classLevels.TryGetValue(className, out var oldLevel) ? oldLevel : 0;
            var newClassLevel = oldClassLevel + 1;
            classLevels[className] = newClassLevel;

            foreach (var prompt in ExperienceProgression.GetAbilityChoicePrompts(
                         className,
                         Math.Max(1, oldClassLevel),
                         Math.Max(1, newClassLevel)))
            {
                // New class level 1 has no level-crossing class choice in the existing
                // progression helper. Its generic optional "other" prompt is harmless,
                // but prefix every key so multiple gained levels can never collide.
                prompts.Add(new MulticlassChoicePrompt(
                    $"mc-{total}-{Slug(className)}-{prompt.Key}",
                    $"{className} {newClassLevel}: {prompt.Label}",
                    prompt.Description,
                    prompt.Optional));
            }

            if (!alreadyClass)
            {
                if (className.Equals("Bard", StringComparison.OrdinalIgnoreCase))
                {
                    prompts.Add(new($"mc-{total}-bard-skill", "Bard multiclass skill proficiency", "Record the one skill proficiency gained from multiclassing into Bard.", false));
                    prompts.Add(new($"mc-{total}-bard-instrument", "Bard multiclass instrument proficiency", "Record the one musical instrument proficiency gained from multiclassing into Bard.", false));
                }
                else if (className.Equals("Ranger", StringComparison.OrdinalIgnoreCase))
                    prompts.Add(new($"mc-{total}-ranger-skill", "Ranger multiclass skill proficiency", "Record the one Ranger class skill proficiency gained from multiclassing.", false));
                else if (className.Equals("Rogue", StringComparison.OrdinalIgnoreCase))
                    prompts.Add(new($"mc-{total}-rogue-skill", "Rogue multiclass skill proficiency", "Record the one Rogue class skill proficiency gained from multiclassing.", false));
            }

            normalizedPlan.Add(new(total, className, newClassLevel, !alreadyClass, proficiencyChoices));
        }

        var summary = string.Join(" / ", classLevels
            .Where(kv => kv.Value > 0)
            .OrderBy(kv => Array.FindIndex(ClassOrder, c => c.Equals(kv.Key, StringComparison.OrdinalIgnoreCase)))
            .Select(kv => $"{kv.Key} {kv.Value}"));

        return new MulticlassPreview(normalizedPlan, prompts, summary);
    }

    private static void ValidateProficiencyChoices(string className, JsonElement choices)
    {
        var skill = choices.ValueKind == JsonValueKind.Object ? ReadString(choices, "skill") : string.Empty;
        var instrument = choices.ValueKind == JsonValueKind.Object ? ReadString(choices, "instrument") : string.Empty;
        if ((className.Equals("Bard", StringComparison.OrdinalIgnoreCase) ||
             className.Equals("Ranger", StringComparison.OrdinalIgnoreCase) ||
             className.Equals("Rogue", StringComparison.OrdinalIgnoreCase)) && string.IsNullOrWhiteSpace(skill))
            throw new ArgumentException($"{className} multiclassing requires the granted skill proficiency to be recorded.");

        var allSkills = new HashSet<string>(new[]
        {
            "Acrobatics","Animal Handling","Arcana","Athletics","Deception","History","Insight","Intimidation",
            "Investigation","Medicine","Nature","Perception","Performance","Persuasion","Religion",
            "Sleight of Hand","Stealth","Survival"
        }, StringComparer.OrdinalIgnoreCase);
        var rangerSkills = new HashSet<string>(new[] { "Animal Handling","Athletics","Insight","Investigation","Nature","Perception","Stealth","Survival" }, StringComparer.OrdinalIgnoreCase);
        var rogueSkills = new HashSet<string>(new[] { "Acrobatics","Athletics","Deception","Insight","Intimidation","Investigation","Perception","Performance","Persuasion","Sleight of Hand","Stealth" }, StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(skill))
        {
            if (className.Equals("Bard", StringComparison.OrdinalIgnoreCase) && !allSkills.Contains(skill))
                throw new ArgumentException("Choose a valid skill proficiency for the Bard multiclass.");
            if (className.Equals("Ranger", StringComparison.OrdinalIgnoreCase) && !rangerSkills.Contains(skill))
                throw new ArgumentException("Choose a skill from the Ranger class skill list.");
            if (className.Equals("Rogue", StringComparison.OrdinalIgnoreCase) && !rogueSkills.Contains(skill))
                throw new ArgumentException("Choose a skill from the Rogue class skill list.");
        }
        if (className.Equals("Bard", StringComparison.OrdinalIgnoreCase) && string.IsNullOrWhiteSpace(instrument))
            throw new ArgumentException("Bard multiclassing requires the granted musical instrument proficiency to be recorded.");
    }

    private static string? CanonicalClass(string value) =>
        ClassOrder.FirstOrDefault(c => c.Equals((value ?? string.Empty).Trim(), StringComparison.OrdinalIgnoreCase));

    private static string Slug(string value) => new(value.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
    private static string ReadString(JsonElement e, string name) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() ?? string.Empty : string.Empty;
    private static int ReadInt(JsonElement e, string name, int fallback) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var p) && p.TryGetInt32(out var n) ? n : fallback;
    private static bool ReadBool(JsonElement e, string name, bool fallback) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var p) && (p.ValueKind == JsonValueKind.True || p.ValueKind == JsonValueKind.False) ? p.GetBoolean() : fallback;
}

public sealed record MulticlassPlanItem(int TotalLevel, string ClassName, int ClassLevelAfter, bool NewClass, JsonElement ProficiencyChoices);
public sealed record MulticlassChoicePrompt(string Key, string Label, string Description, bool Optional = false);
public sealed record MulticlassPreview(IReadOnlyList<MulticlassPlanItem> Plan, IReadOnlyList<MulticlassChoicePrompt> Prompts, string Summary);
