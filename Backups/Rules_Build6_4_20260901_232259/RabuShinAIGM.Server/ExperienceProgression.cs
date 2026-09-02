using System.Text.Json;
using System.Text.RegularExpressions;
using QuestsOfRabuShinAIGM;

public static class ExperienceProgression
{
    private static readonly int[] Thresholds =
    {
        0, 0, 300, 900, 2700, 6500, 14000, 23000, 34000, 48000, 64000,
        85000, 100000, 120000, 140000, 165000, 195000, 225000, 265000, 305000, 355000
    };

    private static readonly Dictionary<string,int> ChallengeXp = new(StringComparer.OrdinalIgnoreCase)
    {
        ["0"] = 10, ["1/8"] = 25, ["1/4"] = 50, ["1/2"] = 100,
        ["1"] = 200, ["2"] = 450, ["3"] = 700, ["4"] = 1100, ["5"] = 1800,
        ["6"] = 2300, ["7"] = 2900, ["8"] = 3900, ["9"] = 5000, ["10"] = 5900,
        ["11"] = 7200, ["12"] = 8400, ["13"] = 10000, ["14"] = 11500, ["15"] = 13000,
        ["16"] = 15000, ["17"] = 18000, ["18"] = 20000, ["19"] = 22000, ["20"] = 25000,
        ["21"] = 33000, ["22"] = 41000, ["23"] = 50000, ["24"] = 62000, ["25"] = 75000,
        ["26"] = 90000, ["27"] = 105000, ["28"] = 120000, ["29"] = 135000, ["30"] = 155000
    };

    public static int ThresholdForLevel(int level)
    {
        level = Math.Clamp(level, 1, 20);
        return Thresholds[level];
    }

    public static int LevelForXp(int xp)
    {
        xp = Math.Max(0, xp);
        var level = 1;
        for (var candidate = 2; candidate <= 20; candidate++)
        {
            if (xp < Thresholds[candidate]) break;
            level = candidate;
        }
        return level;
    }

    public static int ProficiencyBonusForLevel(int level) => Math.Clamp(level, 1, 20) switch
    {
        <= 4 => 2,
        <= 8 => 3,
        <= 12 => 4,
        <= 16 => 5,
        _ => 6
    };

    public static int QuestXpPerCharacter(int recommendedLevel, string difficulty)
    {
        recommendedLevel = Math.Clamp(recommendedLevel, 1, 20);
        if (recommendedLevel >= 20) return 5000;
        var gap = ThresholdForLevel(recommendedLevel + 1) - ThresholdForLevel(recommendedLevel);
        var factor = (difficulty ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "minor" => 0.10m,
            "side" => 0.20m,
            "major" => 0.30m,
            "main" => 0.40m,
            _ => 0.20m
        };
        var raw = Math.Max(25m, gap * factor);
        return Math.Max(25, (int)(Math.Round(raw / 25m, MidpointRounding.AwayFromZero) * 25m));
    }

    public static MonsterExperience GetMonsterExperience(string monsterName)
    {
        var codex = MonsterCodexService.Shared.Find((monsterName ?? string.Empty).Trim());
        var details = codex?.Details ?? string.Empty;
        var match = Regex.Match(details,
            @"Challenge(?:\s+Rating)?[^0-9\r\n]{0,16}(?<cr>\d+(?:/\d+)?)\s*(?:\((?<xp>[\d,]+)\s*XP\))?",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        if (!match.Success)
            return new MonsterExperience(string.Empty, 0, false);

        var cr = match.Groups["cr"].Value.Trim();
        if (match.Groups["xp"].Success &&
            int.TryParse(match.Groups["xp"].Value.Replace(",", string.Empty), out var explicitXp) && explicitXp > 0)
            return new MonsterExperience(cr, explicitXp, true);

        return ChallengeXp.TryGetValue(cr, out var xp)
            ? new MonsterExperience(cr, xp, true)
            : new MonsterExperience(cr, 0, false);
    }

    public static IReadOnlyList<LevelUpChoicePrompt> GetAbilityChoicePrompts(string className, int fromLevel, int toLevel)
    {
        className = (className ?? string.Empty).Trim();
        fromLevel = Math.Clamp(fromLevel, 1, 20);
        toLevel = Math.Clamp(toLevel, fromLevel, 20);
        var prompts = new List<LevelUpChoicePrompt>();

        bool Crosses(int level) => fromLevel < level && toLevel >= level;

        if (Crosses(3))
            prompts.Add(new("subclass", "Subclass", $"Choose the {className} subclass your character follows."));

        var featLevels = className.Equals("Fighter", StringComparison.OrdinalIgnoreCase)
            ? new[] { 4, 6, 8, 12, 14, 16 }
            : className.Equals("Rogue", StringComparison.OrdinalIgnoreCase)
                ? new[] { 4, 8, 10, 12, 16 }
                : new[] { 4, 8, 12, 16 };
        foreach (var level in featLevels.Where(Crosses))
            prompts.Add(new($"featOrAsi-{level}", "Feat / Ability Score Improvement", $"At level {level}, choose the feat gained by your class, or record the ability-score increases if you use an Ability Score Improvement option."));
        if (Crosses(19))
            prompts.Add(new("epicBoon-19", "Epic Boon", "Choose the Epic Boon or other level-19 feat granted by your class progression."));

        if (className.Equals("Paladin", StringComparison.OrdinalIgnoreCase) && Crosses(2) ||
            className.Equals("Ranger", StringComparison.OrdinalIgnoreCase) && Crosses(2))
            prompts.Add(new("fightingStyle", "Fighting Style", "Choose the Fighting Style gained by your class at this level."));

        if (className.Equals("Sorcerer", StringComparison.OrdinalIgnoreCase) && Crosses(2))
            prompts.Add(new("metamagic-2", "Metamagic", "Record the Metamagic options chosen for your Sorcerer."));
        if (className.Equals("Sorcerer", StringComparison.OrdinalIgnoreCase) && Crosses(10))
            prompts.Add(new("metamagic-10", "Metamagic", "Record the additional or replaced Metamagic option chosen at this level."));
        if (className.Equals("Sorcerer", StringComparison.OrdinalIgnoreCase) && Crosses(17))
            prompts.Add(new("metamagic-17", "Metamagic", "Record the additional or replaced Metamagic option chosen at this level."));

        if (className.Equals("Cleric", StringComparison.OrdinalIgnoreCase) && Crosses(7))
            prompts.Add(new("blessedStrikes-7", "Blessed Strikes", "Record the Blessed Strikes option chosen for your Cleric at this level."));
        if (className.Equals("Druid", StringComparison.OrdinalIgnoreCase) && Crosses(7))
            prompts.Add(new("elementalFury-7", "Elemental Fury", "Record the Elemental Fury option chosen for your Druid at this level."));

        if (className.Equals("Bard", StringComparison.OrdinalIgnoreCase) && (Crosses(2) || Crosses(9)))
            prompts.Add(new($"expertise-{toLevel}", "Expertise", "Record the skill proficiencies chosen for Expertise."));

        if (className.Equals("Rogue", StringComparison.OrdinalIgnoreCase) && Crosses(6))
            prompts.Add(new("expertise-6", "Expertise", "Record the skill proficiencies chosen for your additional Expertise."));

        if (className.Equals("Warlock", StringComparison.OrdinalIgnoreCase) &&
            new[] { 2, 5, 7, 9, 12, 15, 18 }.Any(Crosses))
            prompts.Add(new($"invocations-{toLevel}", "Eldritch Invocation", "Record any new or replaced Eldritch Invocation choices granted by the new level."));

        prompts.Add(new("other", "Other class choice", "If this level grants another class feature choice not listed above, record it here. Leave blank when none is required.", true));
        return prompts;
    }

    public static object BuildClientProgression(DiscordCharacterInfo character, DiscordLevelUpState? state)
    {
        var currentLevel = Math.Clamp(character.Level, 1, 20);
        var xp = Math.Max(0, character.Experience);
        var currentThreshold = ThresholdForLevel(currentLevel);
        var nextThreshold = currentLevel >= 20 ? currentThreshold : ThresholdForLevel(currentLevel + 1);
        var earnedLevel = LevelForXp(xp);
        return new
        {
            experience = xp,
            currentLevel,
            earnedLevel,
            currentLevelXp = currentThreshold,
            nextLevelXp = nextThreshold,
            xpIntoLevel = currentLevel >= 20 ? 0 : Math.Max(0, xp - currentThreshold),
            xpNeededThisLevel = currentLevel >= 20 ? 0 : Math.Max(1, nextThreshold - currentThreshold),
            readyForLevelUp = currentLevel < 20 && earnedLevel > currentLevel,
            pendingLevelUp = state?.Pending ?? false,
            spellSelectionPending = state is not null && !state.Pending && !character.SpellsComplete && DiscordSpellService.IsSupportedCaster(character.ClassName),
            fromLevel = state?.FromLevel ?? currentLevel,
            toLevel = state?.ToLevel ?? currentLevel,
            abilityChoices = state is not null && state.AbilityChoices.ValueKind == JsonValueKind.Object
                ? state.AbilityChoices
                : JsonSerializer.Deserialize<JsonElement>("{}"),
            restReason = state?.RestReason ?? string.Empty,
            prompts = state?.Pending == true
                ? GetAbilityChoicePrompts(character.ClassName, state.FromLevel, state.ToLevel)
                : (IReadOnlyList<LevelUpChoicePrompt>)Array.Empty<LevelUpChoicePrompt>()
        };
    }
}

public sealed record MonsterExperience(string ChallengeRating, int Xp, bool Found);
public sealed record LevelUpChoicePrompt(string Key, string Label, string Description, bool Optional = false);

