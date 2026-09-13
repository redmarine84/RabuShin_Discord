using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

public sealed class FinalGameplaySystemsService
{
    private readonly HttpClient _http;
    private readonly string _supabaseUrl;
    private readonly string _supabaseSecretKey;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };

    public FinalGameplaySystemsService(HttpClient http, IConfiguration configuration)
    {
        _http = http;
        _supabaseUrl = (configuration["Supabase:Url"] ?? string.Empty).TrimEnd('/');
        _supabaseSecretKey = configuration["Supabase:SecretKey"] ?? configuration["Supabase:ServiceRoleKey"] ?? string.Empty;
        if (string.IsNullOrWhiteSpace(_supabaseUrl) || string.IsNullOrWhiteSpace(_supabaseSecretKey))
            throw new InvalidOperationException("Supabase configuration is missing for final gameplay systems.");
    }

    public async Task<JsonElement> GetCraftingStateAsync(Guid playerId, Guid campaignId)
        => await RpcElementAsync("discord_get_crafting_state", new { p_player_id = playerId, p_campaign_id = campaignId }, "Unable to load crafting state");

    public async Task<JsonElement> CraftAsync(Guid playerId, Guid campaignId, string recipeKey)
        => await RpcElementAsync("discord_craft_recipe", new { p_player_id = playerId, p_campaign_id = campaignId, p_recipe_key = recipeKey }, "Unable to craft recipe");

    public async Task<JsonElement> GetHarvestingStateAsync(Guid playerId, Guid campaignId)
    {
        var raw = await RpcRawAsync(
            "discord_get_unseeded_defeated_monsters",
            new { p_campaign_id = campaignId },
            "Unable to discover defeated monsters for harvesting");

        var monsters = JsonSerializer.Deserialize<List<HarvestSeedMonsterRow>>(raw, JsonOptions)
                       ?? new List<HarvestSeedMonsterRow>();

        foreach (var monster in monsters)
        {
            var codex = MonsterCodexService.Shared.Find(monster.MonsterName);
            var entries = MonsterLootCatalogService
                .Build(monster.MonsterName, codex?.Details, monster.MaxHp)
                .Where(x => MonsterLootCatalogService.IsHarvestableMaterial(x.ItemName, x.Description))
                .Select(x => MonsterHarvestingRulesService.Describe(monster.MonsterName, x))
                .ToArray();

            _ = await RpcElementAsync(
                "discord_seed_monster_harvest_source",
                new
                {
                    p_campaign_id = campaignId,
                    p_combat_monster_id = monster.CombatMonsterId,
                    p_entries = entries
                },
                $"Unable to register harvesting for {monster.DisplayName}");
        }

        return await RpcElementAsync(
            "discord_get_monster_harvest_state",
            new { p_player_id = playerId, p_campaign_id = campaignId },
            "Unable to load monster harvesting state");
    }

    public async Task<JsonElement> AttemptHarvestAsync(
        Guid playerId,
        Guid campaignId,
        Guid harvestEntryId,
        int d20Roll)
        => await RpcElementAsync(
            "discord_attempt_monster_harvest",
            new
            {
                p_player_id = playerId,
                p_campaign_id = campaignId,
                p_harvest_entry_id = harvestEntryId,
                p_d20_roll = d20Roll
            },
            "Unable to resolve monster harvesting attempt");

    public async Task<List<EquipmentSlotRow>> GetEquipmentSlotsAsync(Guid playerId, Guid campaignId)
    {
        var raw = await RpcRawAsync("discord_get_equipment_slots", new { p_player_id = playerId, p_campaign_id = campaignId }, "Unable to load equipment slots");
        return JsonSerializer.Deserialize<List<EquipmentSlotRow>>(raw, JsonOptions) ?? new List<EquipmentSlotRow>();
    }

    public async Task<JsonElement> SetEquipmentSlotAsync(Guid playerId, Guid campaignId, Guid inventoryItemId, string slotKey, object mechanics)
        => await RpcElementAsync("discord_set_equipment_slot", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_inventory_item_id = inventoryItemId,
            p_slot_key = slotKey,
            p_mechanics = mechanics
        }, "Unable to equip item");

    public async Task<JsonElement> ClearEquipmentSlotAsync(Guid playerId, Guid campaignId, string slotKey)
        => await RpcElementAsync("discord_clear_equipment_slot", new { p_player_id = playerId, p_campaign_id = campaignId, p_slot_key = slotKey }, "Unable to unequip item");

    public async Task PersistArmorClassAsync(Guid playerId, Guid campaignId, int armorClass)
        => _ = await RpcElementAsync("discord_set_character_derived_ac", new { p_player_id = playerId, p_campaign_id = campaignId, p_armor_class = armorClass }, "Unable to save derived Armor Class");

    public async Task<JsonElement> GetFormationStateAsync(Guid playerId, Guid campaignId)
        => await RpcElementAsync("discord_get_solo_formation", new { p_owner_player_id = playerId, p_campaign_id = campaignId }, "Unable to load Solo formation");

    public async Task<JsonElement> SetFormationAsync(Guid playerId, Guid campaignId, string presetKey, IReadOnlyList<FormationOffsetRequest>? offsets)
        => await RpcElementAsync("discord_set_solo_formation", new
        {
            p_owner_player_id = playerId,
            p_campaign_id = campaignId,
            p_preset_key = presetKey,
            p_custom_offsets = (offsets ?? Array.Empty<FormationOffsetRequest>()).Select(x => new
            {
                characterId = x.CharacterId,
                offsetX = x.OffsetX,
                offsetY = x.OffsetY
            }).ToArray()
        }, "Unable to save Solo formation");

    private async Task<JsonElement> RpcElementAsync(string functionName, object body, string errorPrefix)
    {
        var raw = await RpcRawAsync(functionName, body, errorPrefix);
        using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(raw) ? "{}" : raw);
        return document.RootElement.Clone();
    }

    private async Task<string> RpcRawAsync(string functionName, object body, string errorPrefix)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{_supabaseUrl}/rest/v1/rpc/{functionName}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _supabaseSecretKey);
        request.Headers.TryAddWithoutValidation("apikey", _supabaseSecretKey);
        request.Content = JsonContent.Create(body);
        using var response = await _http.SendAsync(request);
        var raw = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"{errorPrefix}: {ExtractSupabaseMessage(raw, response.StatusCode)}");
        return raw;
    }

    private static string ExtractSupabaseMessage(string raw, System.Net.HttpStatusCode statusCode)
    {
        if (!string.IsNullOrWhiteSpace(raw))
        {
            try
            {
                using var document = JsonDocument.Parse(raw);
                if (document.RootElement.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String)
                    return message.GetString() ?? raw;
            }
            catch { }
            return raw.Length <= 500 ? raw : raw[..500];
        }
        return $"Supabase returned HTTP {(int)statusCode}.";
    }
}
