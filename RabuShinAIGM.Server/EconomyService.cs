using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

public sealed class EconomyService
{
    private readonly HttpClient _http;
    private readonly string _supabaseUrl;
    private readonly string _supabaseSecretKey;

    public EconomyService(HttpClient http, IConfiguration configuration)
    {
        _http = http;
        _supabaseUrl = (configuration["Supabase:Url"] ?? string.Empty).TrimEnd('/');
        _supabaseSecretKey = configuration["Supabase:SecretKey"]
                             ?? configuration["Supabase:ServiceRoleKey"]
                             ?? string.Empty;

        if (string.IsNullOrWhiteSpace(_supabaseUrl) || string.IsNullOrWhiteSpace(_supabaseSecretKey))
            throw new InvalidOperationException("Supabase configuration is missing for Build 6.29 economy.");
    }

    public async Task<JsonElement> GetShopAsync(
        Guid playerId,
        Guid campaignId,
        SettlementDefinition settlement,
        SettlementPoiDefinition poi,
        IReadOnlyList<SettlementShopItemDefinition> catalog,
        IReadOnlyList<DiscordInventoryInfo> inventory)
    {
        var catalogSeed = EconomyRulesService.BuildCatalog(catalog);
        var sellSeed = EconomyRulesService.BuildSellCatalog(poi, inventory);
        var serviceSeed = EconomyRulesService.BuildServiceCatalog(inventory);

        var seed = await RpcAsync("discord_economy_seed_shop", new
        {
            p_campaign_id = campaignId,
            p_settlement_key = settlement.SettlementKey,
            p_settlement_name = settlement.SettlementName,
            p_poi_key = poi.PoiKey,
            p_shop_name = poi.Name,
            p_shop_kind = poi.ShopKind ?? "general",
            p_catalog = catalogSeed.Select(x => new
            {
                itemKey = x.ItemKey,
                itemName = x.ItemName,
                category = x.Category,
                basePriceGp = x.BasePriceGp,
                description = x.Description,
                rarity = x.Rarity,
                valueClass = x.ValueClass
            }).ToArray()
        }, "Unable to initialize dynamic shop");

        if (!seed.TryGetProperty("shopId", out var idElement)
            || idElement.ValueKind != JsonValueKind.String
            || !Guid.TryParse(idElement.GetString(), out var shopId))
            throw new InvalidOperationException("Dynamic shop initialization did not return a shop ID.");

        return await RpcAsync("discord_economy_get_shop", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_shop_id = shopId,
            p_sell_items = sellSeed.Select(x => new
            {
                inventoryItemId = x.InventoryItemId,
                itemName = x.ItemName,
                quantity = x.Quantity,
                equipped = x.Equipped,
                attuned = x.Attuned,
                canSell = x.CanSell,
                reason = x.Reason,
                category = x.Category,
                rarity = x.Rarity,
                baseValueGp = x.BaseValueGp,
                priceBand = x.PriceBand,
                craftingFamily = x.CraftingFamily,
                itemData = x.ItemData
            }).ToArray(),
            p_service_items = serviceSeed.Select(x => new
            {
                inventoryItemId = x.InventoryItemId,
                itemName = x.ItemName,
                itemType = x.ItemType,
                baseValueGp = x.BaseValueGp,
                equipped = x.Equipped,
                improvementLevel = x.ImprovementLevel
            }).ToArray()
        }, "Unable to load dynamic economy shop");
    }

    public Task<JsonElement> BuyAsync(Guid playerId, Guid campaignId, Guid stockId, int quantity)
        => RpcAsync("discord_economy_buy", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_stock_id = stockId,
            p_quantity = quantity
        }, "Unable to complete dynamic shop purchase");

    public Task<JsonElement> SellAsync(Guid playerId, Guid campaignId, EconomySellSeedItem item, int quantity)
        => RpcAsync("discord_economy_sell", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_inventory_item_id = item.InventoryItemId,
            p_quantity = quantity,
            p_can_sell = item.CanSell,
            p_item_name = item.ItemName,
            p_category = item.Category,
            p_rarity = item.Rarity,
            p_base_value_gp = item.BaseValueGp,
            p_crafting_family = item.CraftingFamily,
            p_item_data = item.ItemData
        }, "Unable to complete dynamic shop sale");

    public Task<JsonElement> BlacksmithServiceAsync(
        Guid playerId,
        Guid campaignId,
        string serviceType,
        EconomyServiceSeedItem? inventoryItem,
        Guid? commissionStockId)
        => RpcAsync("discord_economy_blacksmith_service", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_service_type = serviceType,
            p_inventory_item_id = inventoryItem?.InventoryItemId,
            p_item_name = inventoryItem?.ItemName ?? string.Empty,
            p_item_type = inventoryItem?.ItemType ?? string.Empty,
            p_base_value_gp = inventoryItem?.BaseValueGp ?? 0m,
            p_commission_stock_id = commissionStockId
        }, "Unable to complete blacksmith service");

    public Task<JsonElement> ClaimOrderAsync(Guid playerId, Guid campaignId, Guid orderId)
        => RpcAsync("discord_economy_claim_order", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_order_id = orderId
        }, "Unable to claim commissioned item");

    private async Task<JsonElement> RpcAsync(string functionName, object body, string errorPrefix)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{_supabaseUrl}/rest/v1/rpc/{functionName}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _supabaseSecretKey);
        request.Headers.TryAddWithoutValidation("apikey", _supabaseSecretKey);
        request.Content = JsonContent.Create(body);

        using var response = await _http.SendAsync(request);
        var raw = await response.Content.ReadAsStringAsync();

        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"{errorPrefix}: {ExtractMessage(raw, response.StatusCode)}");

        using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(raw) ? "{}" : raw);
        return document.RootElement.Clone();
    }

    private static string ExtractMessage(string raw, System.Net.HttpStatusCode statusCode)
    {
        if (!string.IsNullOrWhiteSpace(raw))
        {
            try
            {
                using var document = JsonDocument.Parse(raw);
                if (document.RootElement.TryGetProperty("message", out var message)
                    && message.ValueKind == JsonValueKind.String)
                    return message.GetString() ?? raw;
            }
            catch { }

            return raw.Length <= 700 ? raw : raw[..700];
        }

        return $"Supabase returned HTTP {(int)statusCode}.";
    }
}
