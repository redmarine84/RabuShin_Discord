using System.Text.Json;

public sealed partial class DiscordSupabaseService
{
    // BUILD 6.30.12 - MULTICLASSING
    public async Task<JsonElement> GetMulticlassStateAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_multiclass_state", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        return await ReadMulticlassJsonAsync(response, "Unable to load multiclass state");
    }

    public async Task<JsonElement> ApplyMulticlassLevelPlanAsync(
        Guid playerId,
        Guid campaignId,
        JsonElement plan)
    {
        var safePlan = plan.ValueKind == JsonValueKind.Array
            ? plan
            : JsonSerializer.Deserialize<JsonElement>("[]");
        using var response = await CallRpcAsync("discord_apply_multiclass_level_plan", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_plan = safePlan
        });
        return await ReadMulticlassJsonAsync(response, "Unable to apply multiclass level plan");
    }

    public async Task<JsonElement> SpendMulticlassHitDieAsync(
        Guid playerId,
        Guid campaignId,
        int? dieSides)
    {
        using var response = await CallRpcAsync("discord_spend_multiclass_hit_die", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_die_sides = dieSides
        });
        return await ReadMulticlassJsonAsync(response, "Unable to spend multiclass Hit Die");
    }

    private static async Task<JsonElement> ReadMulticlassJsonAsync(HttpResponseMessage response, string prefix)
    {
        var raw = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"{prefix}: {raw}");
        if (string.IsNullOrWhiteSpace(raw))
            return JsonSerializer.Deserialize<JsonElement>("{}");

        using var document = JsonDocument.Parse(raw);
        var root = document.RootElement;
        // PostgREST normally returns a scalar JSONB RPC directly, but tolerate a
        // one-row/one-value wrapper so the client remains resilient to config changes.
        if (root.ValueKind == JsonValueKind.Array && root.GetArrayLength() == 1)
        {
            var first = root[0];
            if (first.ValueKind == JsonValueKind.Object)
            {
                if (first.TryGetProperty("discord_get_multiclass_state", out var state)) return state.Clone();
                if (first.TryGetProperty("discord_apply_multiclass_level_plan", out var applied)) return applied.Clone();
                if (first.TryGetProperty("discord_spend_multiclass_hit_die", out var hitDie)) return hitDie.Clone();
            }
            return first.Clone();
        }
        return root.Clone();
    }
}
