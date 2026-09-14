using System.Text.Json;
using QuestsOfRabuShinAIGM;

public static class MulticlassSpellService
{
    private static readonly HashSet<string> FullCasters = new(StringComparer.OrdinalIgnoreCase)
    { "Bard", "Cleric", "Druid", "Sorcerer", "Wizard" };
    private static readonly HashSet<string> HalfCasters = new(StringComparer.OrdinalIgnoreCase)
    { "Paladin", "Ranger" };

    public static bool IsSupportedCaster(DiscordCharacterInfo character) =>
        ReadClassLevels(character).Any(c => DiscordSpellService.IsSupportedCaster(c.ClassName));

    public static DiscordSpellProgression GetProgression(DiscordCharacterInfo character)
    {
        var classes = ReadClassLevels(character);
        var result = new DiscordSpellProgression
        {
            ClassName = string.Join(" / ", classes.Select(c => $"{c.ClassName} {c.Level}")),
            CharacterLevel = character.Level
        };

        var effectiveCasterLevel = 0;
        foreach (var entry in classes)
        {
            if (!DiscordSpellService.IsSupportedCaster(entry.ClassName)) continue;
            var individual = DiscordSpellService.GetProgression(entry.ClassName, entry.Level);
            result.CantripsKnown += individual.CantripsKnown;
            result.PreparedSpells += individual.PreparedSpells;
            result.WizardSpellbookCount += individual.WizardSpellbookCount;
            foreach (var arcanum in individual.WarlockArcanumLevels)
                if (!result.WarlockArcanumLevels.Contains(arcanum)) result.WarlockArcanumLevels.Add(arcanum);

            if (FullCasters.Contains(entry.ClassName)) effectiveCasterLevel += entry.Level;
            else if (HalfCasters.Contains(entry.ClassName)) effectiveCasterLevel += entry.Level / 2;
            else if (entry.ClassName.Equals("Artificer", StringComparison.OrdinalIgnoreCase))
                effectiveCasterLevel += (entry.Level + 1) / 2; // Artificer extension: round up.
        }

        if (effectiveCasterLevel > 0)
        {
            var shared = DiscordSpellService.GetProgression("Wizard", Math.Clamp(effectiveCasterLevel, 1, 20));
            foreach (var slot in shared.SpellSlots) result.SpellSlots[slot.Key] = slot.Value;
        }

        var warlock = classes.FirstOrDefault(c => c.ClassName.Equals("Warlock", StringComparison.OrdinalIgnoreCase));
        if (warlock is not null)
        {
            var pact = DiscordSpellService.GetProgression("Warlock", warlock.Level);
            foreach (var slot in pact.SpellSlots)
                result.SpellSlots[slot.Key] = result.SpellSlots.TryGetValue(slot.Key, out var existing)
                    ? existing + slot.Value
                    : slot.Value;
        }

        result.MaxSpellLevel = result.SpellSlots.Count == 0 ? 0 : result.SpellSlots.Keys.Max();
        result.WarlockArcanumLevels.Sort();
        return result;
    }

    public static List<SrdSpellReference> GetAvailableSpells(DiscordCharacterInfo character)
    {
        var byName = new Dictionary<string,SrdSpellReference>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in ReadClassLevels(character))
        {
            if (!DiscordSpellService.IsSupportedCaster(entry.ClassName)) continue;
            foreach (var spell in DiscordSpellService.GetAvailableSpells(entry.ClassName, entry.Level))
                if (!byName.ContainsKey(spell.Name)) byName[spell.Name] = spell;
        }
        return byName.Values.OrderBy(s => s.Level).ThenBy(s => s.Name).ToList();
    }

    public static List<string> GetBaseAlwaysPreparedSpellNames(DiscordCharacterInfo character)
    {
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in ReadClassLevels(character))
        {
            if (!DiscordSpellService.IsSupportedCaster(entry.ClassName)) continue;
            foreach (var spell in DiscordSpellService.GetBaseAlwaysPreparedSpellNames(entry.ClassName, entry.Level))
                result.Add(spell);
        }
        return result.OrderBy(s => s).ToList();
    }

    public static IReadOnlyList<MulticlassClassLevel> ReadClassLevels(DiscordCharacterInfo character)
    {
        var result = new List<MulticlassClassLevel>();
        var data = character.CharacterData;
        if (data.ValueKind == JsonValueKind.Object &&
            data.TryGetProperty("multiclassClasses", out var classes) &&
            classes.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in classes.EnumerateArray())
            {
                if (!item.TryGetProperty("className", out var nameElement) || nameElement.ValueKind != JsonValueKind.String) continue;
                var name = nameElement.GetString() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(name)) continue;
                var level = item.TryGetProperty("level", out var levelElement) && levelElement.TryGetInt32(out var parsed) ? parsed : 0;
                if (level > 0) result.Add(new(name, Math.Clamp(level, 1, 20)));
            }
        }
        if (result.Count == 0)
            result.Add(new(character.ClassName, Math.Clamp(character.Level, 1, 20)));
        return result;
    }
}

public sealed record MulticlassClassLevel(string ClassName, int Level);
