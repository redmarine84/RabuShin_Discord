using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

public sealed class MonsterCodexService
{
    private readonly Dictionary<string, MonsterCodexRecord> _entries = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _images = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _sync = new();
    private bool _loaded;

    public static MonsterCodexService Shared { get; } = new();

    public MonsterCodexRecord? Find(string? name)
    {
        EnsureLoaded();
        if (string.IsNullOrWhiteSpace(name)) return null;
        var key = Normalize(name);
        if (_entries.TryGetValue(key, out var exact)) return WithImage(exact, key);

        var stripped = StripKrasis(key);
        var candidate = _entries
            .Select(pair => new { pair.Key, pair.Value, Stripped = StripKrasis(pair.Key) })
            .Where(x => x.Key.EndsWith(key, StringComparison.OrdinalIgnoreCase) ||
                        key.EndsWith(x.Key, StringComparison.OrdinalIgnoreCase) ||
                        x.Stripped.Equals(stripped, StringComparison.OrdinalIgnoreCase))
            .OrderBy(x => Math.Abs(x.Key.Length - key.Length))
            .FirstOrDefault();

        return candidate is null ? null : WithImage(candidate.Value, candidate.Key);
    }

    public string? FindImageUrl(string? name)
    {
        EnsureLoaded();
        if (string.IsNullOrWhiteSpace(name)) return null;
        var key = Normalize(name);
        if (_images.TryGetValue(key, out var exact)) return exact;
        var stripped = StripKrasis(key);
        var candidate = _images
            .Select(pair => new { pair.Key, pair.Value, Stripped = StripKrasis(pair.Key) })
            .Where(x => x.Key.EndsWith(key, StringComparison.OrdinalIgnoreCase) ||
                        key.EndsWith(x.Key, StringComparison.OrdinalIgnoreCase) ||
                        x.Stripped.Equals(stripped, StringComparison.OrdinalIgnoreCase))
            .OrderBy(x => Math.Abs(x.Key.Length - key.Length))
            .FirstOrDefault();
        return candidate?.Value;
    }

    private MonsterCodexRecord WithImage(MonsterCodexRecord record, string key)
        => record with { ImageUrl = FindImageByKey(key) ?? record.ImageUrl };

    private string? FindImageByKey(string key)
    {
        if (_images.TryGetValue(key, out var image)) return image;
        var stripped = StripKrasis(key);
        return _images.FirstOrDefault(pair => StripKrasis(pair.Key).Equals(stripped, StringComparison.OrdinalIgnoreCase)).Value;
    }

    private void EnsureLoaded()
    {
        if (_loaded) return;
        lock (_sync)
        {
            if (_loaded) return;
            LoadCampaignCodex();
            LoadSrdCodex();
            LoadImageIndex();
            _loaded = true;
        }
    }

    private static string DataPath(string fileName) => Path.Combine(AppContext.BaseDirectory, "Data", fileName);

    private void LoadCampaignCodex()
    {
        var path = DataPath("monster_codex_campaign.json");
        if (!File.Exists(path)) return;
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        if (document.RootElement.ValueKind != JsonValueKind.Array) return;

        foreach (var item in document.RootElement.EnumerateArray())
        {
            var category = ReadString(item, "category");
            if (!category.Equals("Creature", StringComparison.OrdinalIgnoreCase)) continue;
            var name = ReadString(item, "name").Trim();
            if (name.Length == 0) continue;
            var subtitle = ReadString(item, "subtitle").Trim();
            var details = ReadString(item, "details").Trim();
            var ac = RegexInteger(details, @"(?im)^Armor Class\s+(\d+)");
            var hp = RegexInteger(details, @"(?im)^Hit Points\s+(\d+)");
            var crMatch = Regex.Match(subtitle, @"(?i)\bCR\s+([^|]+)$");
            var cr = crMatch.Success ? crMatch.Groups[1].Value.Trim() : string.Empty;
            _entries[Normalize(name)] = new MonsterCodexRecord(name, subtitle, details, "RabuShin Campaign Codex", cr, ac, hp, null);
        }
    }

    private void LoadSrdCodex()
    {
        var path = DataPath("srd_monsters_5_2_1.json");
        if (!File.Exists(path)) return;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            if (document.RootElement.ValueKind != JsonValueKind.Array) return;
            foreach (var monster in document.RootElement.EnumerateArray())
            {
                var name = ReadString(monster, "name").Trim();
                if (name.Length == 0) continue;
                var key = Normalize(name);
                if (_entries.ContainsKey(key)) continue; // Campaign version wins.
                var size = ReadString(monster, "size");
                var type = ReadString(monster, "type");
                var subtype = ReadString(monster, "subtype");
                var alignment = ReadString(monster, "alignment");
                var cr = ReadString(monster, "cr_string");
                if (cr.Length == 0 && monster.TryGetProperty("cr", out var crValue)) cr = ValueAsString(crValue);
                var typeLabel = type;
                if (subtype.Length > 0) typeLabel += $" ({subtype})";
                var subtitleCore = string.Join(" ", new[] { size, typeLabel }.Where(v => !string.IsNullOrWhiteSpace(v)));
                if (alignment.Length > 0) subtitleCore += $", {alignment}";
                var subtitle = subtitleCore + (cr.Length > 0 ? $" | CR {cr}" : string.Empty);
                var ac = ReadNullableInt(monster, "ac");
                var hp = ReadHpAverage(monster);
                var details = BuildSrdDetails(monster, subtitleCore, ac, hp, cr);
                _entries[key] = new MonsterCodexRecord(name, subtitle, details, "SRD 5.2.1", cr, ac, hp, null);
            }
        }
        catch { }
    }

    private void LoadImageIndex()
    {
        var path = DataPath("monster_image_index.json");
        if (!File.Exists(path)) return;
        try
        {
            var index = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path));
            if (index is null) return;
            foreach (var pair in index)
            {
                var key = Normalize(pair.Key);
                if (key.Length > 0 && !string.IsNullOrWhiteSpace(pair.Value)) _images[key] = pair.Value;
            }
        }
        catch { }
    }

    private static string BuildSrdDetails(JsonElement monster, string subtitleCore, int? ac, int? hp, string cr)
    {
        var sb = new StringBuilder();
        if (subtitleCore.Length > 0) sb.AppendLine(subtitleCore);
        if (ac.HasValue) sb.AppendLine($"Armor Class {ac.Value}");
        if (hp.HasValue)
        {
            var dice = string.Empty;
            if (monster.TryGetProperty("hp", out var hpElement) && hpElement.ValueKind == JsonValueKind.Object)
                dice = ReadString(hpElement, "dice");
            sb.AppendLine($"Hit Points {hp.Value}{(dice.Length > 0 ? $" ({CleanInline(dice)})" : string.Empty)}");
        }
        if (monster.TryGetProperty("speed", out var speed) && speed.ValueKind == JsonValueKind.Object)
        {
            var parts = new List<string>();
            foreach (var key in new[] { "walk", "burrow", "climb", "fly", "swim" })
            {
                var value = ReadNullableInt(speed, key);
                if (!value.HasValue) continue;
                var label = key == "walk" ? "" : char.ToUpperInvariant(key[0]) + key[1..] + " ";
                var text = $"{label}{value.Value} ft.";
                if (key == "fly" && speed.TryGetProperty("hover", out var hover) && hover.ValueKind == JsonValueKind.True) text += " (hover)";
                parts.Add(text);
            }
            if (parts.Count > 0) sb.AppendLine("Speed " + string.Join(", ", parts));
        }

        AppendAbilities(sb, monster);
        AppendObjectBonuses(sb, monster, "skills", "Skills");
        AppendArray(sb, monster, "vulnerabilities", "Damage Vulnerabilities");
        AppendArray(sb, monster, "resistances", "Damage Resistances");
        if (monster.TryGetProperty("immunities", out var immunities) && immunities.ValueKind == JsonValueKind.Object)
        {
            AppendArray(sb, immunities, "damage", "Damage Immunities");
            AppendArray(sb, immunities, "condition", "Condition Immunities");
        }
        var senses = ReadString(monster, "senses"); if (senses.Length > 0) sb.AppendLine("Senses " + CleanInline(senses));
        var languages = ReadString(monster, "languages"); if (languages.Length > 0) sb.AppendLine("Languages " + CleanInline(languages));
        if (cr.Length > 0) sb.AppendLine("Challenge " + cr);
        var pb = ReadNullableInt(monster, "proficiency_bonus"); if (pb.HasValue) sb.AppendLine("Proficiency Bonus " + Signed(pb.Value));
        AppendNamedSection(sb, monster, "traits", "Traits");
        AppendNamedSection(sb, monster, "actions", "Actions");
        AppendNamedSection(sb, monster, "bonus_actions", "Bonus Actions");
        AppendNamedSection(sb, monster, "reactions", "Reactions");
        if (monster.TryGetProperty("legendary_actions", out var legendary) && legendary.ValueKind == JsonValueKind.Object && legendary.TryGetProperty("actions", out var la))
        {
            sb.AppendLine(); sb.AppendLine("Legendary Actions"); AppendNamedArray(sb, la);
        }
        sb.AppendLine(); sb.AppendLine("Source: System Reference Document 5.2.1");
        return sb.ToString().TrimEnd();
    }

    private static void AppendAbilities(StringBuilder sb, JsonElement monster)
    {
        if (!monster.TryGetProperty("abilities", out var abilities) || abilities.ValueKind != JsonValueKind.Object) return;
        var parts = new List<string>();
        foreach (var key in new[] { "str", "dex", "con", "int", "wis", "cha" })
        {
            if (!abilities.TryGetProperty(key, out var a) || a.ValueKind != JsonValueKind.Object) continue;
            var score = ReadNullableInt(a, "score"); if (!score.HasValue) continue;
            var mod = ReadNullableInt(a, "modifier") ?? (int)Math.Floor((score.Value - 10) / 2.0);
            parts.Add($"{key.ToUpperInvariant()} {score.Value} ({Signed(mod)})");
        }
        if (parts.Count > 0) { sb.AppendLine(); sb.AppendLine(string.Join("   ", parts)); }
    }

    private static void AppendObjectBonuses(StringBuilder sb, JsonElement monster, string property, string label)
    {
        if (!monster.TryGetProperty(property, out var obj) || obj.ValueKind != JsonValueKind.Object) return;
        var parts = new List<string>();
        foreach (var p in obj.EnumerateObject()) if (p.Value.TryGetInt32(out var v)) parts.Add($"{p.Name} {Signed(v)}");
        if (parts.Count > 0) sb.AppendLine(label + " " + string.Join(", ", parts));
    }

    private static void AppendArray(StringBuilder sb, JsonElement element, string property, string label)
    {
        if (!element.TryGetProperty(property, out var arr) || arr.ValueKind != JsonValueKind.Array) return;
        var values = arr.EnumerateArray().Where(v => v.ValueKind == JsonValueKind.String).Select(v => CleanInline(v.GetString() ?? "")).Where(v => v.Length > 0).ToList();
        if (values.Count > 0) sb.AppendLine(label + " " + string.Join(", ", values));
    }

    private static void AppendNamedSection(StringBuilder sb, JsonElement monster, string property, string heading)
    {
        if (!monster.TryGetProperty(property, out var arr) || arr.ValueKind != JsonValueKind.Array || arr.GetArrayLength() == 0) return;
        sb.AppendLine(); sb.AppendLine(heading); AppendNamedArray(sb, arr);
    }

    private static void AppendNamedArray(StringBuilder sb, JsonElement arr)
    {
        if (arr.ValueKind != JsonValueKind.Array) return;
        foreach (var item in arr.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object) continue;
            var name = CleanInline(ReadString(item, "name"));
            var description = CleanInline(ReadString(item, "description"));
            if (name.Length == 0 && description.Length == 0) continue;
            sb.AppendLine(name.Length == 0 ? description : description.Length == 0 ? name : $"{name}. {description}");
        }
    }

    private static int? ReadHpAverage(JsonElement monster)
    {
        if (!monster.TryGetProperty("hp", out var hp) || hp.ValueKind != JsonValueKind.Object) return null;
        return ReadNullableInt(hp, "average");
    }
    private static int? ReadNullableInt(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value)) return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var i)) return i;
        if (value.ValueKind == JsonValueKind.String && int.TryParse(value.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out i)) return i;
        return null;
    }
    private static string ReadString(JsonElement element, string property)
        => element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? string.Empty : string.Empty;
    private static string ValueAsString(JsonElement value) => value.ValueKind switch { JsonValueKind.String => value.GetString() ?? "", JsonValueKind.Number => value.GetRawText(), _ => "" };
    private static int? RegexInteger(string value, string pattern) { var m = Regex.Match(value ?? "", pattern); return m.Success && int.TryParse(m.Groups[1].Value, out var i) ? i : null; }
    private static string CleanInline(string value) => Regex.Replace((value ?? "").Replace("\r", " ").Replace("\n", " "), @"\s{2,}", " ").Trim();
    private static string Signed(int value) => value >= 0 ? $"+{value}" : value.ToString(CultureInfo.InvariantCulture);
    public static string Normalize(string? value) => new string((value ?? "").Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
    private static string StripKrasis(string value) => value.Replace("krasis", "", StringComparison.OrdinalIgnoreCase);
}

public sealed record MonsterCodexRecord(
    string Name,
    string Subtitle,
    string Details,
    string Source,
    string ChallengeRating,
    int? ArmorClass,
    int? HitPoints,
    string? ImageUrl);
