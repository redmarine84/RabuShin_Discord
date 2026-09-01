using System.Text.Json;
using System.Text.Json.Serialization;

public sealed class DiscordCombatStateRow
{
    [JsonPropertyName("active")] public bool Active { get; set; }
    [JsonPropertyName("title")] public string Title { get; set; } = string.Empty;
    [JsonPropertyName("round_number")] public int RoundNumber { get; set; }
    [JsonPropertyName("started_at")] public DateTimeOffset? StartedAt { get; set; }
    [JsonPropertyName("monsters")] public JsonElement Monsters { get; set; }
}

public sealed class DiscordCombatMonsterInfo
{
    [JsonPropertyName("combat_monster_id")] public Guid CombatMonsterId { get; set; }
    [JsonPropertyName("monster_name")] public string MonsterName { get; set; } = string.Empty;
    [JsonPropertyName("display_name")] public string DisplayName { get; set; } = string.Empty;
    [JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
    [JsonPropertyName("max_hp")] public int MaxHp { get; set; }
    [JsonPropertyName("armor_class")] public int ArmorClass { get; set; }
    [JsonPropertyName("conditions")] public string Conditions { get; set; } = string.Empty;
    [JsonPropertyName("defeated")] public bool Defeated { get; set; }
    [JsonPropertyName("sort_order")] public int SortOrder { get; set; }
}
