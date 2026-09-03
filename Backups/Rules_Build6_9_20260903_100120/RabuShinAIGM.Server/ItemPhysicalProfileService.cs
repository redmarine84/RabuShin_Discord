using System.Globalization;
using System.Text.Json;

public sealed record InventoryItemPhysicalProfile(
    decimal WeightLb,
    decimal FoodLb,
    decimal WaterGallons,
    string Source)
{
    public bool IsFood => FoodLb > 0m;
    public bool IsWater => WaterGallons > 0m;
}

public sealed record InventoryEncumbrance(
    decimal CarriedWeightLb,
    decimal CapacityLb,
    decimal RemainingCapacityLb,
    decimal Percent,
    bool OverCapacity);

public static class ItemPhysicalProfileService
{
    public const string PhysicalProfileVersion = "6.8";

    private static readonly Dictionary<string, decimal> KnownWeights = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Club"] = 2m, ["Dagger"] = 1m, ["Greatclub"] = 10m, ["Handaxe"] = 2m,
        ["Javelin"] = 2m, ["Light Hammer"] = 2m, ["Mace"] = 4m, ["Quarterstaff"] = 4m,
        ["Sickle"] = 2m, ["Spear"] = 3m, ["Light Crossbow"] = 5m, ["Dart"] = 0.25m,
        ["Shortbow"] = 2m, ["Sling"] = 0m, ["Battleaxe"] = 4m, ["Flail"] = 2m,
        ["Glaive"] = 6m, ["Greataxe"] = 7m, ["Greatsword"] = 6m, ["Halberd"] = 6m,
        ["Lance"] = 6m, ["Longsword"] = 3m, ["Maul"] = 10m, ["Morningstar"] = 4m,
        ["Pike"] = 18m, ["Rapier"] = 2m, ["Scimitar"] = 3m, ["Shortsword"] = 2m,
        ["Trident"] = 4m, ["War Pick"] = 2m, ["Warhammer"] = 2m, ["Whip"] = 3m,
        ["Blowgun"] = 1m, ["Hand Crossbow"] = 3m, ["Heavy Crossbow"] = 18m, ["Longbow"] = 2m,
        ["Shield"] = 6m, ["Padded Armor"] = 8m, ["Leather Armor"] = 10m,
        ["Studded Leather Armor"] = 13m, ["Hide Armor"] = 12m, ["Chain Shirt"] = 20m,
        ["Scale Mail"] = 45m, ["Breastplate"] = 20m, ["Half Plate"] = 40m,
        ["Ring Mail"] = 40m, ["Chain Mail"] = 55m, ["Splint Armor"] = 60m, ["Plate Armor"] = 65m,
        ["Backpack"] = 5m, ["Bedroll"] = 7m, ["Blanket"] = 3m, ["Crowbar"] = 5m,
        ["Grappling Hook"] = 4m, ["Hammer"] = 3m, ["Sledgehammer"] = 10m,
        ["Lantern"] = 2m, ["Bullseye Lantern"] = 2m, ["Hooded Lantern"] = 2m,
        ["Mess Kit"] = 1m, ["Piton"] = 0.25m, ["Pole"] = 7m, ["Rope"] = 10m,
        ["Silk Rope"] = 5m, ["Shovel"] = 5m, ["Tent"] = 20m, ["Tinderbox"] = 1m,
        ["Torch"] = 1m, ["Waterskin"] = 1m, ["Thieves' Tools"] = 1m,
        ["Smith's Tools"] = 8m, ["Blacksmithing Kit"] = 8m, ["Alchemist's Supplies"] = 8m,
        ["Herbalism Kit"] = 3m, ["Healer's Kit"] = 3m, ["Fishing Tackle"] = 4m,
        ["Potion of Healing"] = 0.5m, ["Greater Potion of Healing"] = 0.5m,
        ["Superior Potion of Healing"] = 0.5m, ["Supreme Potion of Healing"] = 0.5m,
        ["Antitoxin"] = 0.5m, ["Basic Poison"] = 0.5m, ["Alchemist's Fire"] = 1m, ["Acid"] = 1m,
        ["Fresh Fish"] = 1m, ["Rations"] = 2m, ["Rations (1 Day)"] = 2m,
        ["Water (1 Gallon)"] = 8.34m, ["Water (1/2 Gallon)"] = 4.17m,
        ["Full Waterskin"] = 5m, ["Waterskin (Full)"] = 5m
    };

    public static InventoryItemPhysicalProfile Classify(DiscordInventoryInfo item)
    {
        if (TryReadPersisted(item.ItemData) is { } persisted) return persisted;

        var name = (item.ItemName ?? string.Empty).Trim();
        var source = (item.SourceName ?? string.Empty).Trim();
        var notes = (item.Notes ?? string.Empty).Trim();
        var dataText = item.ItemData.ValueKind == JsonValueKind.Object ? item.ItemData.ToString() : string.Empty;
        var text = $"{name} {source} {notes} {dataText}".ToLowerInvariant();

        var explicitWeight = ReadNonNegative(item.ItemData, "weight_lb");
        var explicitFood = ReadNonNegative(item.ItemData, "food_lb");
        var explicitWater = ReadNonNegative(item.ItemData, "water_gallons");
        if (explicitWeight.HasValue || explicitFood.HasValue || explicitWater.HasValue)
            return Make(explicitWeight ?? EstimateWeight(name, text, item), explicitFood ?? 0m, explicitWater ?? 0m, "Explicit item metadata");

        var food = EstimateFoodLb(name, text);
        var water = EstimateWaterGallons(name, text);
        var weight = EstimateWeight(name, text, item);
        if (food > 0m || water > 0m) return Make(weight, food, water, "Food / water item classification");
        return Make(weight, 0m, 0m, "Server item-weight classification");
    }

    public static bool HasCurrentPersistedProfile(JsonElement data)
    {
        if (data.ValueKind != JsonValueKind.Object) return false;
        return TryString(data, "physical_profile_version", out var version)
            && version.Equals(PhysicalProfileVersion, StringComparison.OrdinalIgnoreCase)
            && TryDecimal(data, "weight_lb", out _)
            && TryDecimal(data, "food_lb", out _)
            && TryDecimal(data, "water_gallons", out _);
    }

    public static InventoryEncumbrance CalculateEncumbrance(int strength, IEnumerable<DiscordInventoryInfo> items)
    {
        var capacity = Math.Max(0m, strength * 15m);
        var carried = items.Sum(i => Math.Max(0, i.Quantity) * (i.PhysicalProfile ?? Classify(i)).WeightLb);
        carried = Math.Round(carried, 2, MidpointRounding.AwayFromZero);
        var remaining = Math.Max(0m, capacity - carried);
        var percent = capacity <= 0m ? (carried > 0m ? 100m : 0m) : Math.Min(100m, Math.Round(carried / capacity * 100m, 1));
        return new InventoryEncumbrance(carried, capacity, remaining, percent, carried > capacity);
    }

    private static InventoryItemPhysicalProfile? TryReadPersisted(JsonElement data)
    {
        if (data.ValueKind != JsonValueKind.Object) return null;
        if (!TryDecimal(data, "weight_lb", out var weight)) return null;
        TryDecimal(data, "food_lb", out var food);
        TryDecimal(data, "water_gallons", out var water);
        return Make(weight, food, water, "Persisted item metadata");
    }

    private static decimal EstimateWeight(string name, string text, DiscordInventoryInfo item)
    {
        if (KnownWeights.TryGetValue(name, out var exact)) return exact;
        var simple = name.Replace("+1", "", StringComparison.OrdinalIgnoreCase)
            .Replace("+2", "", StringComparison.OrdinalIgnoreCase)
            .Replace("+3", "", StringComparison.OrdinalIgnoreCase).Trim();
        if (KnownWeights.TryGetValue(simple, out exact)) return exact;

        if (text.Contains("plate armor")) return 65m;
        if (text.Contains("splint")) return 60m;
        if (text.Contains("chain mail")) return 55m;
        if (text.Contains("scale mail")) return 45m;
        if (text.Contains("half plate")) return 40m;
        if (text.Contains("breastplate")) return 20m;
        if (text.Contains("chain shirt")) return 20m;
        if (text.Contains("studded leather")) return 13m;
        if (text.Contains("leather armor")) return 10m;
        if (text.Contains("shield")) return 6m;

        if (ContainsAny(text, "greatsword", "glaive", "halberd")) return 6m;
        if (text.Contains("greataxe")) return 7m;
        if (text.Contains("maul")) return 10m;
        if (ContainsAny(text, "longsword", "scimitar")) return 3m;
        if (ContainsAny(text, "rapier", "shortsword", "warhammer", "handaxe")) return 2m;
        if (ContainsAny(text, "dagger", "dart")) return 1m;
        if (text.Contains("bow")) return 2m;
        if (text.Contains("crossbow")) return 5m;

        if (ContainsAny(text, "potion", "salve", "poison", "elixir", "tonic")) return 0.5m;
        if (ContainsAny(text, "pelt", "hide", "fur")) return 2m;
        if (text.Contains("ration") && text.Contains("5 day")) return 5m;
        if (ContainsAny(text, "meat", "fish", "ration", "bread", "provisions")) return 1m;
        if (ContainsAny(text, "blood", "organ", "heart", "liver", "kidney")) return 0.5m;
        if (ContainsAny(text, "bone", "fang", "tooth", "claw", "scale", "stinger")) return 0.25m;
        if (ContainsAny(text, "horn", "antler", "tusk")) return 1m;
        if (ContainsAny(text, "gem", "jewel", "ring", "amulet", "necklace")) return 0.1m;
        if (ContainsAny(text, "scroll", "letter", "map", "note")) return 0.1m;
        if (item.Valuation?.Category == "Boss Loot") return 2m;
        if (item.Valuation?.Category == "Monster Loot") return 1m;
        return 1m; // Unknown carried items are never silently weightless.
    }

    private static decimal EstimateFoodLb(string name, string text)
    {
        if (text.Contains("ration") && text.Contains("5 day")) return 5m;
        if (text.Contains("ration")) return 1m;
        if (ContainsAny(text, "fresh fish", "fish fillet", "meat", "steak", "jerky", "dried meat", "bread", "provisions", "meal")) return 1m;
        if (ContainsAny(text, "berries", "fruit", "vegetables", "vegetable")) return 0.5m;
        return 0m;
    }

    private static decimal EstimateWaterGallons(string name, string text)
    {
        if (ContainsAny(text, "water (1 gallon)", "one gallon water", "1 gallon of water")) return 1m;
        if (ContainsAny(text, "water (1/2 gallon)", "half gallon water", "0.5 gallon water")) return 0.5m;
        if (ContainsAny(text, "full waterskin", "waterskin (full)", "filled waterskin")) return 0.5m;
        // A plain waterskin is treated as an empty container.
        return 0m;
    }

    private static InventoryItemPhysicalProfile Make(decimal weight, decimal food, decimal water, string source) =>
        new(Math.Round(Math.Max(0m, weight), 2), Math.Round(Math.Max(0m, food), 2), Math.Round(Math.Max(0m, water), 3), source);

    private static bool ContainsAny(string text, params string[] values) => values.Any(v => text.Contains(v, StringComparison.OrdinalIgnoreCase));

    private static decimal? ReadNonNegative(JsonElement data, string name)
    {
        return TryDecimal(data, name, out var value) ? Math.Max(0m, value) : null;
    }

    private static bool TryString(JsonElement data, string name, out string value)
    {
        value = string.Empty;
        if (!data.TryGetProperty(name, out var element) || element.ValueKind != JsonValueKind.String) return false;
        value = element.GetString()?.Trim() ?? string.Empty;
        return value.Length > 0;
    }

    private static bool TryDecimal(JsonElement data, string name, out decimal value)
    {
        value = 0m;
        if (!data.TryGetProperty(name, out var element)) return false;
        if (element.ValueKind == JsonValueKind.Number && element.TryGetDecimal(out value)) return true;
        return element.ValueKind == JsonValueKind.String && decimal.TryParse(element.GetString(), NumberStyles.Number, CultureInfo.InvariantCulture, out value);
    }
}
