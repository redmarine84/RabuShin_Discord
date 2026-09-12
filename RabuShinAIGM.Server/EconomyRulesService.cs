using System.Text.Json;

public static class EconomyRulesService
{
    public static IReadOnlyList<EconomyCatalogSeedItem> BuildCatalog(
        IReadOnlyList<SettlementShopItemDefinition> catalog)
        => catalog.Select(item => new EconomyCatalogSeedItem
        {
            ItemKey = item.ItemKey,
            ItemName = item.ItemName,
            Category = item.Category,
            BasePriceGp = Math.Round(item.PriceGp, 2),
            Description = item.Description,
            Rarity = item.Rarity,
            ValueClass = item.ValueClass
        }).ToArray();

    public static IReadOnlyList<EconomySellSeedItem> BuildSellCatalog(
        SettlementPoiDefinition poi,
        IReadOnlyList<DiscordInventoryInfo> inventory)
        => inventory.Select(item => BuildSellItem(poi, item)).ToArray();

    public static IReadOnlyList<EconomyServiceSeedItem> BuildServiceCatalog(
        IReadOnlyList<DiscordInventoryInfo> inventory)
    {
        return inventory.Select(item =>
        {
            var presentation = InventoryPresentationService.ToClientItem(item);
            var valuation = item.Valuation ?? ItemValuationService.Classify(item);
            return new EconomyServiceSeedItem
            {
                InventoryItemId = item.InventoryItemId,
                ItemName = item.ItemName,
                ItemType = presentation.ItemType ?? string.Empty,
                BaseValueGp = Math.Round(Math.Max(0m, valuation.BaseValueGp), 2),
                Equipped = item.Equipped,
                ImprovementLevel = ReadInt(item.ItemData, "economy_improvement_level")
            };
        })
        .Where(x => IsBlacksmithEquipment(x.ItemType))
        .ToArray();
    }

    public static EconomySellSeedItem BuildSellItem(
        SettlementPoiDefinition poi,
        DiscordInventoryInfo item)
    {
        var valuation = item.Valuation ?? ItemValuationService.Classify(item);
        var family = ReadString(item.ItemData, "crafting_family");
        var accepted = SettlementInteractionCatalog.MerchantAccepts(poi, item, valuation)
                       || MerchantAcceptsCraftingFamily(poi.ShopKind, family);
        var baseValue = Math.Max(0m, valuation.BaseValueGp);

        if (baseValue <= 0m && !string.IsNullOrWhiteSpace(family))
            baseValue = FallbackCraftingMaterialValue(item.ItemData, valuation.Rarity);

        if (ReadInt(item.ItemData, "economy_improvement_level") > 0)
            baseValue = Math.Round(baseValue * 1.50m, 2);

        var reason = string.Empty;
        var canSell = valuation.Sellable && !valuation.Priceless && baseValue > 0m && accepted
                      && !item.Equipped && !item.Attuned && item.Quantity > 0;

        if (item.Equipped) reason = "Unequip this item before selling it.";
        else if (item.Attuned) reason = "End attunement before selling this item.";
        else if (valuation.Priceless) reason = "This item is protected as priceless.";
        else if (!valuation.Sellable) reason = "This item is not normally accepted for resale.";
        else if (!accepted) reason = "This merchant does not trade in this kind of item.";
        else if (baseValue <= 0m) reason = "This item has no established merchant value.";

        return new EconomySellSeedItem
        {
            InventoryItemId = item.InventoryItemId,
            ItemName = item.ItemName,
            Quantity = Math.Max(0, item.Quantity),
            Equipped = item.Equipped,
            Attuned = item.Attuned,
            CanSell = canSell,
            Reason = reason,
            Category = valuation.Category ?? "Inventory Item",
            Rarity = valuation.Rarity ?? "Common",
            BaseValueGp = Math.Round(baseValue, 2),
            PriceBand = valuation.PriceBand ?? string.Empty,
            CraftingFamily = family,
            ItemData = item.ItemData
        };
    }

    private static bool MerchantAcceptsCraftingFamily(string? shopKind, string family)
    {
        if (string.IsNullOrWhiteSpace(family)) return false;
        var kind = (shopKind ?? string.Empty).Trim().ToLowerInvariant();
        var f = family.Trim().ToLowerInvariant();

        if (kind is "market" or "general") return true;

        if (kind is "smithy" or "arms" or "fletcher")
            return f is "leather" or "pelt_hide" or "bone_horn" or "chitin_shell"
                or "dragon_scale" or "dragon_scale_component" or "bone_reinforcement"
                or "cordage" or "construct_salvage" or "alchemical_adhesive";

        if (kind is "alchemy" or "apothecary" or "enchanter")
            return f is "healing_herb" or "venom" or "dragon_blood" or "draconic_reagent"
                or "ooze_residue" or "alchemical_adhesive" or "elemental_essence"
                or "elemental_infusion" or "ectoplasm" or "vial";

        if (kind is "fishmarket")
            return f is "monster_meat" or "pelt_hide" or "bone_horn";

        return false;
    }

    private static bool IsBlacksmithEquipment(string? itemType)
    {
        var type = (itemType ?? string.Empty).Trim().ToLowerInvariant();
        return type.Contains("weapon") || type.Contains("armor") || type.Contains("armour")
               || type.Contains("shield") || type.Contains("helmet");
    }

    private static decimal FallbackCraftingMaterialValue(JsonElement data, string? rarity)
    {
        var harvestRarity = ReadString(data, "harvest_rarity");
        var valueRarity = string.IsNullOrWhiteSpace(harvestRarity) ? rarity ?? "Common" : harvestRarity;
        return valueRarity.Trim().ToLowerInvariant().Replace("_", " ") switch
        {
            "legendary" => 250m,
            "very rare" => 50m,
            "rare" => 10m,
            "uncommon" => 2m,
            _ => 0.5m
        };
    }

    private static string ReadString(JsonElement data, string name)
    {
        if (data.ValueKind == JsonValueKind.Object
            && data.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.String)
            return value.GetString()?.Trim() ?? string.Empty;
        return string.Empty;
    }

    private static int ReadInt(JsonElement data, string name)
    {
        if (data.ValueKind != JsonValueKind.Object || !data.TryGetProperty(name, out var value)) return 0;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)) return number;
        if (value.ValueKind == JsonValueKind.String && int.TryParse(value.GetString(), out number)) return number;
        return 0;
    }
}
