using System.Text.Json;
using System.Text.Json.Serialization;

public sealed class DiscordTacticalCombatStateRow
{
    [JsonPropertyName("active")] public bool Active { get; set; }
    [JsonPropertyName("round_number")] public int RoundNumber { get; set; }
    [JsonPropertyName("current_turn_type")] public string CurrentTurnType { get; set; } = string.Empty;
    [JsonPropertyName("current_turn_character_id")] public Guid? CurrentTurnCharacterId { get; set; }
    [JsonPropertyName("current_turn_monster_id")] public Guid? CurrentTurnMonsterId { get; set; }
    [JsonPropertyName("current_turn_name")] public string CurrentTurnName { get; set; } = string.Empty;
    [JsonPropertyName("viewer_character_id")] public Guid? ViewerCharacterId { get; set; }
    [JsonPropertyName("viewer_speed")] public int ViewerSpeed { get; set; }
    [JsonPropertyName("viewer_movement_remaining")] public int ViewerMovementRemaining { get; set; }
    [JsonPropertyName("tokens")] public JsonElement Tokens { get; set; }
}

public sealed class DiscordTacticalTokenInfo
{
    [JsonPropertyName("token_id")] public Guid TokenId { get; set; }
    [JsonPropertyName("entity_type")] public string EntityType { get; set; } = string.Empty;
    [JsonPropertyName("character_id")] public Guid? CharacterId { get; set; }
    [JsonPropertyName("combat_monster_id")] public Guid? CombatMonsterId { get; set; }
    [JsonPropertyName("display_name")] public string DisplayName { get; set; } = string.Empty;
    [JsonPropertyName("monster_name")] public string MonsterName { get; set; } = string.Empty;
    [JsonPropertyName("grid_x")] public int GridX { get; set; }
    [JsonPropertyName("grid_y")] public int GridY { get; set; }
    [JsonPropertyName("movement_spent_ft")] public int MovementSpentFt { get; set; }
    [JsonPropertyName("speed_ft")] public int SpeedFt { get; set; }
    [JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
    [JsonPropertyName("max_hp")] public int MaxHp { get; set; }
    [JsonPropertyName("armor_class")] public int ArmorClass { get; set; }
    [JsonPropertyName("defeated")] public bool Defeated { get; set; }
    [JsonPropertyName("has_portrait")] public bool HasPortrait { get; set; }
}

public sealed class TacticalMoveRequest
{
    public int GridX { get; set; }
    public int GridY { get; set; }
}

public sealed class TacticalMoveResult
{
    [JsonPropertyName("token_id")] public Guid TokenId { get; set; }
    [JsonPropertyName("grid_x")] public int GridX { get; set; }
    [JsonPropertyName("grid_y")] public int GridY { get; set; }
    [JsonPropertyName("move_cost_ft")] public int MoveCostFt { get; set; }
    [JsonPropertyName("movement_spent_ft")] public int MovementSpentFt { get; set; }
    [JsonPropertyName("movement_remaining_ft")] public int MovementRemainingFt { get; set; }
}
