using System.Text.Json;

public sealed class EconomyBuyRequest
{
    public Guid StockId { get; set; }
    public int Quantity { get; set; } = 1;
}

public sealed class EconomySellRequest
{
    public Guid InventoryItemId { get; set; }
    public int Quantity { get; set; } = 1;
}

public sealed class EconomyBlacksmithServiceRequest
{
    public string ServiceType { get; set; } = string.Empty;
    public Guid? InventoryItemId { get; set; }
    public Guid? StockId { get; set; }
}

public sealed class EconomyClaimOrderRequest
{
    public Guid OrderId { get; set; }
}

public sealed class EconomyCatalogSeedItem
{
    public string ItemKey { get; set; } = string.Empty;
    public string ItemName { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public decimal BasePriceGp { get; set; }
    public string Description { get; set; } = string.Empty;
    public string Rarity { get; set; } = "Common";
    public string ValueClass { get; set; } = string.Empty;
}

public sealed class EconomySellSeedItem
{
    public Guid InventoryItemId { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public int Quantity { get; set; }
    public bool Equipped { get; set; }
    public bool Attuned { get; set; }
    public bool CanSell { get; set; }
    public string Reason { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public string Rarity { get; set; } = "Common";
    public decimal BaseValueGp { get; set; }
    public string PriceBand { get; set; } = string.Empty;
    public string CraftingFamily { get; set; } = string.Empty;
    public JsonElement ItemData { get; set; }
}

public sealed class EconomyServiceSeedItem
{
    public Guid InventoryItemId { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public string ItemType { get; set; } = string.Empty;
    public decimal BaseValueGp { get; set; }
    public bool Equipped { get; set; }
    public int ImprovementLevel { get; set; }
}
