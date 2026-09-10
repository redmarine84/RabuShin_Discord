using System.Security.Cryptography;
using System.Text.Json.Serialization;

// RULES BUILD 6.19.1 - DEATH SAVING THROWS
// The browser never supplies a death-save roll. The trusted RabuShin server rolls it.
public static class DeathSaveRulesService
{
    public static int RollD20() => RandomNumberGenerator.GetInt32(1, 21);

    public static string Summary(DeathSaveResolutionRow result)
    {
        var name = string.IsNullOrWhiteSpace(result.CharacterName)
            ? "Character"
            : result.CharacterName.Trim();

        return result.Outcome switch
        {
            "natural_20" =>
                $"Death Save — {name} rolled a natural 20, regains 1 HP, and may act on this turn.",
            "stabilized" =>
                $"Death Save — {name} rolled {result.Roll}: SUCCESS. Three successes reached; {name} is stable.",
            "dead" =>
                $"Death Save — {name} rolled {result.Roll}: FAILURE. Three failures reached; {name} has died.",
            "natural_1_failure" =>
                $"Death Save — {name} rolled a natural 1: TWO FAILURES. " +
                $"Successes {result.Successes}/3 • Failures {result.Failures}/3.",
            "success" =>
                $"Death Save — {name} rolled {result.Roll}: SUCCESS. " +
                $"Successes {result.Successes}/3 • Failures {result.Failures}/3.",
            "failure" =>
                $"Death Save — {name} rolled {result.Roll}: FAILURE. " +
                $"Successes {result.Successes}/3 • Failures {result.Failures}/3.",
            "already_resolved" =>
                $"Death Save — {name}'s death save for this round was already resolved.",
            _ => string.IsNullOrWhiteSpace(result.Message)
                ? $"Death Save — {name}: {result.Outcome}."
                : result.Message
        };
    }
}

public sealed class DeathSaveStateRow
{
    [JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
    [JsonPropertyName("character_name")] public string CharacterName { get; set; } = string.Empty;
    [JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
    [JsonPropertyName("max_hp")] public int MaxHp { get; set; }
    [JsonPropertyName("life_state")] public string LifeState { get; set; } = string.Empty;
    [JsonPropertyName("successes")] public int Successes { get; set; }
    [JsonPropertyName("failures")] public int Failures { get; set; }
    [JsonPropertyName("stable")] public bool Stable { get; set; }
    [JsonPropertyName("last_roll")] public int? LastRoll { get; set; }
    [JsonPropertyName("last_result")] public string LastResult { get; set; } = string.Empty;
    [JsonPropertyName("last_resolved_round")] public int? LastResolvedRound { get; set; }
    [JsonPropertyName("current_round")] public int? CurrentRound { get; set; }
    [JsonPropertyName("combat_active")] public bool CombatActive { get; set; }
    [JsonPropertyName("is_current_turn")] public bool IsCurrentTurn { get; set; }
    [JsonPropertyName("active")] public bool Active { get; set; }
    [JsonPropertyName("requires_save")] public bool RequiresSave { get; set; }
    [JsonPropertyName("resolved_this_round")] public bool ResolvedThisRound { get; set; }
}

public sealed class DeathSaveResolutionRow
{
    [JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
    [JsonPropertyName("character_name")] public string CharacterName { get; set; } = string.Empty;
    [JsonPropertyName("roll")] public int Roll { get; set; }
    [JsonPropertyName("outcome")] public string Outcome { get; set; } = string.Empty;
    [JsonPropertyName("successes")] public int Successes { get; set; }
    [JsonPropertyName("failures")] public int Failures { get; set; }
    [JsonPropertyName("stable")] public bool Stable { get; set; }
    [JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
    [JsonPropertyName("max_hp")] public int MaxHp { get; set; }
    [JsonPropertyName("dead")] public bool Dead { get; set; }
    [JsonPropertyName("combat_active")] public bool CombatActive { get; set; }
    [JsonPropertyName("is_current_turn")] public bool IsCurrentTurn { get; set; }
    [JsonPropertyName("message")] public string Message { get; set; } = string.Empty;
}
