using QuestsOfRabuShinAIGM;
using System.Text.Json;

public static class InventoryPresentationService
{
    private static readonly string[] ArmorWords =
    {
        "armor", "armour", "shield", "helm", "helmet", "gauntlet", "glove", "bracer",
        "boot", "greave", "pauldron", "cuirass", "breastplate", "chest piece", "chestpiece",
        "chain mail", "chain shirt", "scale mail", "half plate", "plate", "splint", "ring mail",
        "leather armor", "studded leather", "hide armor"
    };

    private static readonly string[] ClothingWords =
    {
        "robe", "clothes", "clothing", "costume", "cloak", "coat", "jacket", "shirt", "tunic",
        "pants", "trousers", "dress", "skirt", "vest", "hood", "hat", "scarf"
    };

    private static readonly string[] ConsumableWords =
    {
        "potion", "elixir", "tonic", "antitoxin", "antidote", "scroll", "ration", "food",
        "bread", "meat", "fruit", "berry", "berries", "cheese", "meal", "stew", "drink",
        "ale", "wine", "water", "juice", "tea", "coffee", "poison", "acid", "holy water",
        "alchemist's fire", "alchemists fire", "oil flask", "torch"
    };

    public static InventoryClientItem ToClientItem(DiscordInventoryInfo info)
    {
        var item = BuildInventoryItem(info);

        // Let the existing Windows rules service seed standard weapon/armor values
        // while the item is still unclassified, then apply the stricter Discord
        // equipability rules requested for this interface.
        EquipmentReferenceService.ApplyStandardDefaults(item, false);

        var itemType = InferDiscordItemType(item);
        item.ItemType = itemType;

        if (string.IsNullOrWhiteSpace(item.EquipmentSlot))
            item.EquipmentSlot = InferDiscordSlot(itemType, item.ItemName);

        // ApplyStandardDefaults can infer the Windows-app item type. Re-apply the
        // stricter Discord type so rings/foci/etc. do not accidentally become equipable.
        item.ItemType = InferDiscordItemType(item);
        if (string.IsNullOrWhiteSpace(item.EquipmentSlot))
            item.EquipmentSlot = InferDiscordSlot(item.ItemType, item.ItemName);

        var description = GetExplicitDescription(info.ItemData);
        if (string.IsNullOrWhiteSpace(description))
            description = InventoryReferenceService.GetDescription(item);

        if (string.IsNullOrWhiteSpace(description) ||
            description.Contains("No built-in rules description", StringComparison.OrdinalIgnoreCase))
        {
            description = BuildFallbackDescription(item.ItemName, item.ItemType);
        }

        var rulesSummary = EquipmentReferenceService.BuildRulesSummary(item);

        return new InventoryClientItem
        {
            InventoryItemId = info.InventoryItemId,
            ItemName = info.ItemName,
            Quantity = info.Quantity,
            Equipped = info.Equipped,
            Attuned = info.Attuned,
            SourceName = info.SourceName,
            Notes = info.Notes,
            ItemType = item.ItemType,
            EquipmentSlot = item.EquipmentSlot,
            Description = description.Trim(),
            RulesSummary = rulesSummary.Trim(),
            CanEquip = CanEquip(item),
            CanUse = CanUse(item),
            ItemData = info.ItemData
        };
    }

    public static string BuildGameplaySummary(DiscordInventoryInfo info)
    {
        var item = BuildInventoryItem(info);
        EquipmentReferenceService.ApplyStandardDefaults(item, false);
        item.ItemType = InferDiscordItemType(item);
        return EquipmentReferenceService.BuildGameplaySummary(item);
    }

    public static bool CanEquip(DiscordInventoryInfo info)
        => CanEquip(BuildInventoryItem(info));

    public static bool CanUse(DiscordInventoryInfo info)
        => CanUse(BuildInventoryItem(info));

    public static string GetItemType(DiscordInventoryInfo info)
        => InferDiscordItemType(BuildInventoryItem(info));

    private static bool CanEquip(InventoryItem item)
    {
        var type = InferDiscordItemType(item);
        return type.Equals("Weapon", StringComparison.OrdinalIgnoreCase) ||
               type.Equals("Armor", StringComparison.OrdinalIgnoreCase) ||
               type.Equals("Shield", StringComparison.OrdinalIgnoreCase) ||
               type.Equals("Helmet", StringComparison.OrdinalIgnoreCase) ||
               type.Equals("Clothing", StringComparison.OrdinalIgnoreCase);
    }

    private static bool CanUse(InventoryItem item)
    {
        var type = InferDiscordItemType(item);
        if (type.Equals("Consumable", StringComparison.OrdinalIgnoreCase)) return true;

        var lower = (item.ItemName ?? string.Empty).Trim().ToLowerInvariant();
        return ConsumableWords.Any(lower.Contains);
    }

    private static string InferDiscordItemType(InventoryItem item)
    {
        var name = (item.ItemName ?? string.Empty).Trim();
        var lower = name.ToLowerInvariant();
        var explicitType = (item.ItemType ?? string.Empty).Trim();

        if (explicitType.Equals("Consumable", StringComparison.OrdinalIgnoreCase)) return "Consumable";
        if (ConsumableWords.Any(lower.Contains)) return "Consumable";

        var inferred = string.IsNullOrWhiteSpace(explicitType)
            ? EquipmentReferenceService.InferItemType(name)
            : explicitType;

        if (inferred.Equals("Weapon", StringComparison.OrdinalIgnoreCase)) return "Weapon";
        if (inferred.Equals("Armor", StringComparison.OrdinalIgnoreCase)) return "Armor";
        if (inferred.Equals("Shield", StringComparison.OrdinalIgnoreCase)) return "Shield";
        if (inferred.Equals("Helmet", StringComparison.OrdinalIgnoreCase)) return "Helmet";
        if (inferred.Equals("Clothing", StringComparison.OrdinalIgnoreCase)) return "Clothing";

        // The Windows model classifies gloves, boots and bracers as accessories.
        // The Discord rule requested by the user treats protective armor pieces as armor.
        if (ArmorWords.Any(lower.Contains)) return "Armor";
        if (ClothingWords.Any(lower.Contains)) return "Clothing";

        return inferred;
    }

    private static string InferDiscordSlot(string itemType, string itemName)
    {
        var lower = (itemName ?? string.Empty).ToLowerInvariant();
        if (itemType.Equals("Weapon", StringComparison.OrdinalIgnoreCase)) return "Hand";
        if (itemType.Equals("Shield", StringComparison.OrdinalIgnoreCase)) return "Off Hand";
        if (itemType.Equals("Helmet", StringComparison.OrdinalIgnoreCase)) return "Head";
        if (itemType.Equals("Clothing", StringComparison.OrdinalIgnoreCase)) return "Body";
        if (!itemType.Equals("Armor", StringComparison.OrdinalIgnoreCase)) return string.Empty;

        if (lower.Contains("helm") || lower.Contains("helmet")) return "Head";
        if (lower.Contains("gauntlet") || lower.Contains("glove") || lower.Contains("bracer")) return "Hands / Arms";
        if (lower.Contains("boot") || lower.Contains("greave")) return "Feet";
        if (lower.Contains("shield")) return "Off Hand";
        return "Body";
    }

    private static string BuildFallbackDescription(string itemName, string itemType)
    {
        var name = string.IsNullOrWhiteSpace(itemName) ? "This item" : itemName.Trim();
        return itemType.ToLowerInvariant() switch
        {
            "weapon" => $"{name} is a weapon that can be equipped and used in combat.",
            "armor" or "shield" or "helmet" => $"{name} is protective equipment that can be equipped while adventuring or fighting.",
            "clothing" => $"{name} is wearable clothing that can be equipped by the character.",
            "consumable" => $"{name} is a consumable item. Using it consumes one from the stack; the Game Master determines its in-game effect.",
            _ => $"{name} is an item carried in the character's inventory."
        };
    }

    private static InventoryItem BuildInventoryItem(DiscordInventoryInfo info)
    {
        var item = new InventoryItem
        {
            ItemName = info.ItemName,
            Quantity = Math.Max(1, info.Quantity),
            Equipped = info.Equipped,
            Attuned = info.Attuned,
            Notes = info.Notes ?? string.Empty
        };

        var data = info.ItemData;
        if (data.ValueKind != JsonValueKind.Object) return item;

        item.Weight = ReadDecimal(data, "weight");
        item.ItemType = ReadString(data, "item_type", "itemType");
        item.EquipmentSlot = ReadString(data, "equipment_slot", "equipmentSlot");
        item.Rarity = ReadString(data, "rarity");
        if (string.IsNullOrWhiteSpace(item.Rarity)) item.Rarity = "Common";
        item.IsMagical = ReadBool(data, "is_magical", "isMagical");
        item.RequiresAttunement = ReadBool(data, "requires_attunement", "requiresAttunement");
        item.ItemDescription = ReadString(data, "item_description", "itemDescription", "description");
        item.DamageDice = ReadString(data, "damage_dice", "damageDice");
        item.VersatileDamageDice = ReadString(data, "versatile_damage_dice", "versatileDamageDice");
        item.DamageType = ReadString(data, "damage_type", "damageType");
        item.WeaponProperties = ReadString(data, "weapon_properties", "weaponProperties");
        item.NormalRangeFeet = ReadInt(data, "normal_range_feet", "normalRangeFeet");
        item.LongRangeFeet = ReadInt(data, "long_range_feet", "longRangeFeet");
        item.AttackBonus = ReadInt(data, "attack_bonus", "attackBonus");
        item.DamageBonus = ReadInt(data, "damage_bonus", "damageBonus");
        item.ArmorClassBase = ReadInt(data, "armor_class_base", "armorClassBase");
        item.ArmorClassBonus = ReadInt(data, "armor_class_bonus", "armorClassBonus");
        var maxDex = ReadNullableInt(data, "max_dex_bonus", "maxDexBonus");
        item.MaxDexBonus = maxDex ?? -1;
        item.StrengthRequirement = ReadInt(data, "strength_requirement", "strengthRequirement");
        item.StealthDisadvantage = ReadBool(data, "stealth_disadvantage", "stealthDisadvantage");
        item.DamageResistances = ReadString(data, "damage_resistances", "damageResistances");
        item.DamageImmunities = ReadString(data, "damage_immunities", "damageImmunities");
        item.MagicEffects = ReadString(data, "magic_effects", "magicEffects");
        item.GrantedSpells = ReadString(data, "granted_spells", "grantedSpells");
        item.Buffs = ReadString(data, "buffs");
        item.CurrentCharges = ReadInt(data, "current_charges", "currentCharges");
        item.MaxCharges = ReadInt(data, "max_charges", "maxCharges");
        return item;
    }

    private static string GetExplicitDescription(JsonElement data)
        => data.ValueKind == JsonValueKind.Object
            ? ReadString(data, "item_description", "itemDescription", "description")
            : string.Empty;

    private static string ReadString(JsonElement data, params string[] names)
    {
        foreach (var name in names)
        {
            if (!data.TryGetProperty(name, out var value)) continue;
            if (value.ValueKind == JsonValueKind.String) return value.GetString() ?? string.Empty;
            if (value.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined)) return value.ToString();
        }
        return string.Empty;
    }

    private static int ReadInt(JsonElement data, params string[] names)
        => ReadNullableInt(data, names) ?? 0;

    private static int? ReadNullableInt(JsonElement data, params string[] names)
    {
        foreach (var name in names)
        {
            if (!data.TryGetProperty(name, out var value)) continue;
            if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)) return number;
            if (value.ValueKind == JsonValueKind.String && int.TryParse(value.GetString(), out number)) return number;
        }
        return null;
    }

    private static decimal ReadDecimal(JsonElement data, params string[] names)
    {
        foreach (var name in names)
        {
            if (!data.TryGetProperty(name, out var value)) continue;
            if (value.ValueKind == JsonValueKind.Number && value.TryGetDecimal(out var number)) return number;
            if (value.ValueKind == JsonValueKind.String && decimal.TryParse(value.GetString(), out number)) return number;
        }
        return 0m;
    }

    private static bool ReadBool(JsonElement data, params string[] names)
    {
        foreach (var name in names)
        {
            if (!data.TryGetProperty(name, out var value)) continue;
            if (value.ValueKind == JsonValueKind.True) return true;
            if (value.ValueKind == JsonValueKind.False) return false;
            if (value.ValueKind == JsonValueKind.String && bool.TryParse(value.GetString(), out var boolean)) return boolean;
        }
        return false;
    }
}

public sealed class InventoryClientItem
{
    public Guid InventoryItemId { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public int Quantity { get; set; }
    public bool Equipped { get; set; }
    public bool Attuned { get; set; }
    public string SourceName { get; set; } = string.Empty;
    public string Notes { get; set; } = string.Empty;
    public string ItemType { get; set; } = string.Empty;
    public string EquipmentSlot { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string RulesSummary { get; set; } = string.Empty;
    public bool CanEquip { get; set; }
    public bool CanUse { get; set; }
    public JsonElement ItemData { get; set; }
}
