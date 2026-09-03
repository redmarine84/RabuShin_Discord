using System.Globalization;
using System.Text.Json;

public sealed record InventoryItemValuation(
    string Rarity,
    string Category,
    string ValueClass,
    decimal BaseValueGp,
    bool Sellable,
    bool Priceless,
    string ValuationSource,
    string PriceBand)
{
    public decimal StandardMerchantOfferGp => !Sellable || Priceless
        ? 0m
        : Math.Max(0.01m, Math.Round(BaseValueGp * 0.50m, 2, MidpointRounding.AwayFromZero));
}

public sealed record InventoryItemValuationPatch(
    Guid InventoryItemId,
    string Rarity,
    string Category,
    string ValueClass,
    decimal BaseValueGp,
    bool Sellable,
    bool Priceless,
    string ValuationSource,
    string PriceBand,
    decimal WeightLb,
    decimal FoodLb,
    decimal WaterGallons,
    string PhysicalProfileVersion);

public static class ItemValuationService
{
    public const string ValuationVersion = "6.8";

    private static readonly string[] Rarities = new[]
    {
        "Common", "Uncommon", "Rare", "Very Rare", "Legendary", "Artifact"
    };

    public static InventoryItemValuation Classify(DiscordInventoryInfo item)
    {
        var persisted = TryReadPersisted(item.ItemData);
        if (persisted is not null)
            return persisted;

        var name = (item.ItemName ?? string.Empty).Trim();
        var source = (item.SourceName ?? string.Empty).Trim();
        var notes = (item.Notes ?? string.Empty).Trim();
        var dataText = item.ItemData.ValueKind == JsonValueKind.Object ? item.ItemData.ToString() : string.Empty;
        var text = $"{name} {source} {notes} {dataText}".ToLowerInvariant();

        // Narrative keys, campaign artifacts, and one-off plot components are deliberately protected.
        if (ContainsAny(text,
            "quest item", "campaign item", "artifact", "containment seal", "signet key",
            "engine fragment", "core crystal fragment", "wish fragment", "runestone fragment",
            "gateway key", "plot item", "story item"))
        {
            return Make("Artifact", "Quest Item", "Artifact", 0m, false, true,
                "Protected narrative item", "Priceless / Cannot be bought or sold");
        }

        var known = SettlementInteractionCatalog.FindKnownItem(name);
        if (known is not null)
        {
            return Make(
                known.Rarity,
                known.Category,
                known.ValueClass,
                known.PriceGp,
                true,
                false,
                "Settlement catalog",
                CatalogBand(known.Rarity, known.ValueClass, known.PriceGp));
        }

        var explicitRarity = DetectExplicitRarity(item.ItemData, text);

        if (LooksLikePotion(text))
        {
            var rarity = explicitRarity ?? DetectPotionRarity(text);
            var value = PotionValue(name, text, rarity);
            return Make(rarity, PotionCategory(text), "Potion / Consumable", value, true, false,
                "Potion power and rarity", MagicBand(rarity));
        }

        if (LooksLikeMagicItem(text))
        {
            var rarity = explicitRarity ?? DetectMagicRarity(text);
            if (rarity == "Artifact")
                return Make(rarity, "Magic Item", "Artifact", 0m, false, true,
                    "Artifact rarity", "Priceless / Cannot be bought or sold");
            var value = MagicDefaultValue(rarity);
            return Make(rarity, "Magic Item", "Magic Item", value, true, false,
                "Magic-item rarity", MagicBand(rarity));
        }

        if (LooksLikeWeapon(text))
        {
            var rarity = explicitRarity ?? DetectMagicRarity(text);
            var magical = rarity != "Common" || LooksLikeMagicItem(text);
            var value = magical ? MagicDefaultValue(rarity) : 10m;
            return Make(rarity, "Weapon", magical ? "Magic Equipment" : "Mundane Equipment", value, true, false,
                magical ? "Weapon rarity" : "Fallback mundane weapon value",
                magical ? MagicBand(rarity) : "Mundane equipment; catalog value preferred when known");
        }

        if (LooksLikeArmor(text))
        {
            var rarity = explicitRarity ?? DetectMagicRarity(text);
            var magical = rarity != "Common" || LooksLikeMagicItem(text);
            var value = magical ? MagicDefaultValue(rarity) : 50m;
            return Make(rarity, "Armor", magical ? "Magic Equipment" : "Mundane Equipment", value, true, false,
                magical ? "Armor rarity" : "Fallback mundane armor value",
                magical ? MagicBand(rarity) : "Mundane equipment; catalog value preferred when known");
        }

        var partTier = DetectHarvestTier(text);
        var isBoss = LooksLikeBossSource(text);
        var isMonster = isBoss || LooksLikeMonsterSource(text);
        var isAnimal = LooksLikeAnimalSource(text) || partTier is not null;

        if (isBoss && partTier is not null)
        {
            var rarity = explicitRarity ?? BossRarityFromPartTier(partTier.Value);
            var value = MagicDefaultValue(rarity);
            return Make(rarity, "Boss Loot", "Boss Loot", value, true, false,
                "Boss-monster harvested component", MagicBand(rarity));
        }

        if (isMonster && partTier is not null)
        {
            var rarity = explicitRarity ?? LootRarity(partTier.Value);
            var value = MonsterLootValue(partTier.Value, rarity);
            return Make(rarity, "Monster Loot", "Monster Loot", value, true, false,
                "Monster harvested component", MonsterLootBand(rarity));
        }

        if (isAnimal && partTier is not null)
        {
            var rarity = explicitRarity ?? LootRarity(partTier.Value);
            var value = AnimalLootBaseValue(text, partTier.Value);
            return Make(rarity, "Animal Loot", "Animal Loot", value, true, false,
                "Animal harvested component", AnimalLootBand(partTier.Value));
        }

        if (ContainsAny(text, "gem", "jewel", "pearl", "ruby", "sapphire", "emerald", "diamond"))
        {
            var rarity = explicitRarity ?? "Uncommon";
            return Make(rarity, "Trade Good", "Valuable Trade Good", 50m, true, false,
                "Valuable trade-good fallback", "Valuable trade good; exact gem values may override this fallback");
        }

        // Absolute fallback: every non-artifact inventory entry has a deterministic coin value.
        return Make(explicitRarity ?? "Common", "Miscellaneous", "General Goods", 1m, true, false,
            "General inventory fallback", "Common miscellaneous item: 1 GP base market value");
    }

    public static InventoryItemValuationPatch ToPatch(DiscordInventoryInfo item)
    {
        var value = item.Valuation ?? Classify(item);
        var physical = item.PhysicalProfile ?? ItemPhysicalProfileService.Classify(item);
        return new InventoryItemValuationPatch(
            item.InventoryItemId,
            value.Rarity,
            value.Category,
            value.ValueClass,
            value.BaseValueGp,
            value.Sellable,
            value.Priceless,
            value.ValuationSource,
            value.PriceBand,
            physical.WeightLb,
            physical.FoodLb,
            physical.WaterGallons,
            ItemPhysicalProfileService.PhysicalProfileVersion);
    }

    public static object ToClientValuation(DiscordInventoryInfo item)
    {
        var value = item.Valuation ?? Classify(item);
        var physical = item.PhysicalProfile ?? ItemPhysicalProfileService.Classify(item);
        return new
        {
            inventoryItemId = item.InventoryItemId,
            rarity = value.Rarity,
            valuationCategory = value.Category,
            valueClass = value.ValueClass,
            baseValueGp = value.BaseValueGp,
            standardSellValueGp = value.StandardMerchantOfferGp,
            sellable = value.Sellable,
            priceless = value.Priceless,
            valuationSource = value.ValuationSource,
            priceBand = value.PriceBand,
            weightLb = physical.WeightLb,
            foodLb = physical.FoodLb,
            waterGallons = physical.WaterGallons,
            physicalProfileSource = physical.Source
        };
    }

    public static bool HasCurrentPersistedValuation(JsonElement itemData)
    {
        if (itemData.ValueKind != JsonValueKind.Object) return false;
        return TryString(itemData, "valuation_version", out var version)
            && version.Equals(ValuationVersion, StringComparison.OrdinalIgnoreCase)
            && TryDecimal(itemData, "base_value_gp", out _)
            && TryString(itemData, "rarity", out _)
            && TryString(itemData, "valuation_category", out _);
    }

    private static InventoryItemValuation? TryReadPersisted(JsonElement data)
    {
        if (data.ValueKind != JsonValueKind.Object) return null;

        // A manually-authored value is authoritative even if it predates Build 6.7.
        var hasBase = TryDecimal(data, "base_value_gp", out var baseValue);
        var hasRarity = TryString(data, "rarity", out var rarity);
        if (!hasBase || !hasRarity || !NormalizeRarity(rarity, out var normalizedRarity)) return null;
        rarity = normalizedRarity;

        TryString(data, "valuation_category", out var category);
        if (string.IsNullOrWhiteSpace(category)) TryString(data, "item_category", out category);
        if (string.IsNullOrWhiteSpace(category)) category = "Miscellaneous";
        TryString(data, "value_class", out var valueClass);
        if (string.IsNullOrWhiteSpace(valueClass)) valueClass = category;
        TryString(data, "valuation_source", out var source);
        if (string.IsNullOrWhiteSpace(source)) source = "Stored item metadata";
        TryString(data, "price_band", out var band);
        if (string.IsNullOrWhiteSpace(band)) band = rarity == "Artifact" ? "Priceless" : MagicBand(rarity);
        var sellable = !TryBool(data, "sellable", out var storedSellable) || storedSellable;
        var priceless = TryBool(data, "priceless", out var storedPriceless) && storedPriceless;
        if (rarity == "Artifact") { priceless = true; sellable = false; baseValue = 0m; }
        return Make(rarity, category, valueClass, Math.Max(0m, Math.Round(baseValue, 2)), sellable, priceless, source, band);
    }

    private static string? DetectExplicitRarity(JsonElement data, string text)
    {
        if (data.ValueKind == JsonValueKind.Object && TryString(data, "rarity", out var fromData) && NormalizeRarity(fromData, out var normalized))
            return normalized;

        if (text.Contains("very rare", StringComparison.OrdinalIgnoreCase)) return "Very Rare";
        if (text.Contains("legendary", StringComparison.OrdinalIgnoreCase)) return "Legendary";
        if (text.Contains("artifact", StringComparison.OrdinalIgnoreCase)) return "Artifact";
        if (text.Contains("uncommon", StringComparison.OrdinalIgnoreCase)) return "Uncommon";
        if (text.Contains("rare", StringComparison.OrdinalIgnoreCase)) return "Rare";
        return null;
    }

    private static string DetectPotionRarity(string text)
    {
        if (ContainsAny(text, "supreme healing", "supreme potion", "very rare")) return "Very Rare";
        if (ContainsAny(text, "superior healing", "rare potion")) return "Rare";
        if (ContainsAny(text, "greater healing", "uncommon potion")) return "Uncommon";
        if (ContainsAny(text, "legendary potion", "elixir of immortality")) return "Legendary";
        return "Common";
    }

    private static string DetectMagicRarity(string text)
    {
        if (text.Contains("+3", StringComparison.OrdinalIgnoreCase)) return "Very Rare";
        if (text.Contains("+2", StringComparison.OrdinalIgnoreCase)) return "Rare";
        if (text.Contains("+1", StringComparison.OrdinalIgnoreCase)) return "Uncommon";
        if (text.Contains("legendary", StringComparison.OrdinalIgnoreCase)) return "Legendary";
        if (text.Contains("very rare", StringComparison.OrdinalIgnoreCase)) return "Very Rare";
        if (text.Contains("uncommon", StringComparison.OrdinalIgnoreCase)) return "Uncommon";
        if (text.Contains("rare", StringComparison.OrdinalIgnoreCase)) return "Rare";
        return "Common";
    }

    private static decimal PotionValue(string name, string text, string rarity)
    {
        if (text.Contains("potion of healing") && !text.Contains("greater") && !text.Contains("superior") && !text.Contains("supreme")) return 50m;
        if (text.Contains("greater healing")) return 150m;
        if (text.Contains("superior healing")) return 1000m;
        if (text.Contains("supreme healing")) return 5000m;
        return MagicDefaultValue(rarity);
    }

    private static string PotionCategory(string text)
    {
        if (text.Contains("poison")) return "Poison";
        if (text.Contains("salve")) return "Salve";
        if (text.Contains("antitoxin") || text.Contains("antivenom") || text.Contains("remedy")) return "Remedy";
        return "Potion";
    }

    private static decimal MagicDefaultValue(string rarity) => rarity switch
    {
        "Common" => 75m,
        "Uncommon" => 300m,
        "Rare" => 2750m,
        "Very Rare" => 27500m,
        "Legendary" => 100000m,
        _ => 0m
    };

    private static string MagicBand(string rarity) => rarity switch
    {
        "Common" => "Common magic item: 50–100 GP",
        "Uncommon" => "Uncommon magic item: 101–500 GP",
        "Rare" => "Rare magic item: 501–5,000 GP",
        "Very Rare" => "Very Rare magic item: 5,001–50,000 GP",
        "Legendary" => "Legendary magic item: 50,001–500,000+ GP",
        "Artifact" => "Priceless / Cannot be bought or sold",
        _ => "Value determined by item category"
    };

    private static string CatalogBand(string rarity, string valueClass, decimal price) =>
        valueClass.Contains("Magic", StringComparison.OrdinalIgnoreCase) || valueClass.Contains("Potion", StringComparison.OrdinalIgnoreCase)
            ? MagicBand(rarity)
            : $"Known catalog item: {price.ToString("0.##", CultureInfo.InvariantCulture)} GP base value";

    private static decimal AnimalLootBaseValue(string text, int tier)
    {
        return tier switch
        {
            1 when ContainsAny(text, "meat", "feather", "egg") => 0.20m, // sells for 1 SP
            1 => 0.40m,                                                    // sells for 2 SP
            2 when ContainsAny(text, "blood", "bone", "bones") => 1.00m, // sells for 5 SP
            2 => 2.00m,                                                    // sells for 1 GP
            3 when ContainsAny(text, "scale", "scales") => 2.00m,         // sells for 1 GP
            3 => 4.00m,                                                    // sells for 2 GP
            _ => 1.00m
        };
    }

    private static decimal MonsterLootValue(int tier, string rarity) => tier switch
    {
        1 => 1.00m,
        2 => 4.00m,
        3 => 10.00m,
        _ => rarity switch
        {
            "Very Rare" => 25m,
            "Legendary" => 100m,
            _ => 5m
        }
    };

    private static string AnimalLootBand(int tier) => tier switch
    {
        1 => "Common animal loot: typically sells for 1–2 SP each",
        2 => "Uncommon animal loot: typically sells for 5–10 SP each",
        3 => "Scarce animal loot: typically sells for 1–2 GP each",
        _ => "Harvested animal loot"
    };

    private static string MonsterLootBand(string rarity) => rarity switch
    {
        "Common" => "Common monster component: above ordinary animal loot",
        "Uncommon" => "Uncommon monster component: useful reagent or trophy",
        "Rare" => "Scarce monster component: valuable reagent or trophy",
        "Very Rare" => "Exceptional monster component",
        "Legendary" => "Legendary monster component",
        _ => "Monster component"
    };

    private static int? DetectHarvestTier(string text)
    {
        if (ContainsAny(text, "scale", "scales", "stinger", "stingers", "horn", "horns", "antler", "antlers", "tusk", "tusks", "shell", "carapace", "chitin", "venom sac", "venom gland", "poison gland")) return 3;
        if (ContainsAny(text, "blood", "organ", "organs", "heart", "liver", "kidney", "kidneys", "lung", "lungs", "bone", "bones", "skull", "fang", "fangs", "tooth", "teeth", "claw", "claws", "talon", "talons")) return 2;
        if (ContainsAny(text, "pelt", "pelts", "hide", "hides", "skin", "fur", "meat", "flesh", "feather", "feathers", "tail", "tails", "beak", "egg", "eggs", "fat", "tallow")) return 1;
        return null;
    }

    private static string LootRarity(int tier) => tier switch { 1 => "Common", 2 => "Uncommon", _ => "Rare" };
    private static string BossRarityFromPartTier(int tier) => tier switch { 1 => "Uncommon", 2 => "Rare", _ => "Very Rare" };

    private static bool LooksLikeBossSource(string text) => ContainsAny(text,
        "boss", "legendary", "ancient dragon", "dragon lord", "hydra", "beholder", "demon lord",
        "prime krasis", "krasis commander", "commander", "chieftain", "war chief", "queen", "king", "titan");

    private static bool LooksLikeMonsterSource(string text) => ContainsAny(text,
        "monster", "krasis", "aberration", "fiend", "undead", "dragon", "wyvern", "chimera", "troll",
        "ogre", "hill giant", "frost giant", "fire giant", "stone giant", "cloud giant", "storm giant",
        "naga", "sphinx", "elemental", "golem", "manticore", "basilisk");

    private static bool LooksLikeAnimalSource(string text) => ContainsAny(text,
        "wolf", "rat", "bat", "bear", "boar", "deer", "elk", "stag", "goat", "sheep", "cow", "ox", "horse",
        "fish", "eel", "crab", "snake", "vulture", "eagle", "frog", "mastiff", "cat", "dog", "animal", "beast");

    private static bool LooksLikePotion(string text) => ContainsAny(text,
        "potion", "elixir", "tonic", "draught", "salve", "antitoxin", "antivenom", "poison", "venom vial");

    private static bool LooksLikeMagicItem(string text) => ContainsAny(text,
        "magic item", "magical", "enchanted", "wondrous", "arcane", "amulet", "ring of", "cloak of", "boots of",
        "wand", "staff of", "rod of", "horn of", "bag of", "tome", "manual of", "scroll of", "+1", "+2", "+3");

    private static bool LooksLikeWeapon(string text) => ContainsAny(text,
        "sword", "dagger", "axe", "mace", "hammer", "spear", "javelin", "bow", "crossbow", "staff", "club", "flail", "glaive", "halberd", "lance", "weapon");

    private static bool LooksLikeArmor(string text) => ContainsAny(text,
        "armor", "armour", "mail", "plate", "breastplate", "shield", "helmet", "helm", "gauntlet", "bracer");

    private static InventoryItemValuation Make(string rarity, string category, string valueClass, decimal value,
        bool sellable, bool priceless, string source, string band)
    {
        if (!NormalizeRarity(rarity, out rarity)) rarity = "Common";
        if (rarity == "Artifact") { value = 0m; sellable = false; priceless = true; }
        return new InventoryItemValuation(rarity, category, valueClass, Math.Round(Math.Max(0m, value), 2), sellable, priceless, source, band);
    }

    private static bool NormalizeRarity(string? value, out string rarity)
    {
        var source = (value ?? string.Empty).Trim().Replace("_", " ").Replace("-", " ");
        rarity = Rarities.FirstOrDefault(r => r.Equals(source, StringComparison.OrdinalIgnoreCase)) ?? string.Empty;
        return rarity.Length > 0;
    }

    private static bool ContainsAny(string source, params string[] values) =>
        values.Any(value => source.Contains(value, StringComparison.OrdinalIgnoreCase));

    private static bool TryString(JsonElement data, string name, out string value)
    {
        value = string.Empty;
        if (!data.TryGetProperty(name, out var element)) return false;
        if (element.ValueKind != JsonValueKind.String) return false;
        value = element.GetString() ?? string.Empty;
        return value.Length > 0;
    }

    private static bool TryDecimal(JsonElement data, string name, out decimal value)
    {
        value = 0m;
        if (!data.TryGetProperty(name, out var element)) return false;
        if (element.ValueKind == JsonValueKind.Number && element.TryGetDecimal(out value)) return true;
        return element.ValueKind == JsonValueKind.String
            && decimal.TryParse(element.GetString(), NumberStyles.Number, CultureInfo.InvariantCulture, out value);
    }

    private static bool TryBool(JsonElement data, string name, out bool value)
    {
        value = false;
        if (!data.TryGetProperty(name, out var element)) return false;
        if (element.ValueKind == JsonValueKind.True) { value = true; return true; }
        if (element.ValueKind == JsonValueKind.False) { value = false; return true; }
        return false;
    }
}
