using System.Text.Json;

public static class EquipmentLoadoutRulesService
{
    private sealed record SlotDefinition(string Key, string Label, string Icon);

    private static readonly SlotDefinition[] SlotDefinitions =
    {
        new("armor", "Armor", "🛡"),
        new("shield", "Shield", "◈"),
        new("main_hand", "Main Hand", "⚔"),
        new("off_hand", "Off Hand", "†"),
        new("ranged", "Ranged", "➶"),
        new("ammunition", "Ammunition", "⌁"),
        new("head", "Head", "⛨"),
        new("neck", "Neck", "◇"),
        new("hands", "Hands", "✦"),
        new("feet", "Feet", "⌂"),
        new("ring_left", "Left Ring", "○"),
        new("ring_right", "Right Ring", "○"),
        new("accessory_1", "Accessory I", "✧"),
        new("accessory_2", "Accessory II", "✧")
    };

    public static EquipmentLoadoutView Build(DiscordCharacterInfo character, IReadOnlyList<DiscordInventoryInfo> inventory, IReadOnlyList<EquipmentSlotRow> slotRows)
    {
        var standardized = inventory
            .Select(InventoryPresentationService.ToClientItem)
            .ToDictionary(x => x.InventoryItemId, x => x);
        var slotMap = slotRows
            .Where(x => !string.IsNullOrWhiteSpace(x.SlotKey))
            .GroupBy(x => x.SlotKey, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Last(), StringComparer.OrdinalIgnoreCase);

        var slots = new List<EquipmentSlotView>();
        foreach (var definition in SlotDefinitions)
        {
            slotMap.TryGetValue(definition.Key, out var row);
            InventoryClientItem? item = null;
            if (row?.InventoryItemId is Guid id) standardized.TryGetValue(id, out item);
            slots.Add(new EquipmentSlotView
            {
                SlotKey = definition.Key,
                Label = definition.Label,
                Icon = definition.Icon,
                InventoryItemId = row?.InventoryItemId,
                ItemName = item?.ItemName ?? row?.ItemName ?? string.Empty,
                ItemType = item?.ItemType ?? string.Empty,
                RulesSummary = item?.RulesSummary ?? string.Empty
            });
        }

        var armorClass = CalculateArmorClass(character, standardized, slotMap, out var defenseSummary);
        var attacks = BuildAttacks(character, standardized, slotMap);
        return new EquipmentLoadoutView
        {
            CharacterId = character.CharacterId,
            CharacterName = character.CharacterName,
            ArmorClass = armorClass,
            DefenseSummary = defenseSummary,
            Slots = slots,
            Attacks = attacks
        };
    }

    public static bool IsSlotEligible(InventoryClientItem item, string slotKey)
    {
        var slot = NormalizeSlot(slotKey);
        if (slot.Length == 0) return false;
        var type = (item.ItemType ?? string.Empty).Trim().ToLowerInvariant();
        var name = (item.ItemName ?? string.Empty).Trim().ToLowerInvariant();
        var equipmentSlot = (item.EquipmentSlot ?? string.Empty).Trim().ToLowerInvariant();
        var properties = (item.WeaponProperties ?? string.Empty).Trim().ToLowerInvariant();
        var ranged = name.Contains("bow") || name.Contains("crossbow") || name.Contains("sling") || name.Contains("blowgun") || properties.Contains("ammunition") || properties.Contains("ranged");
        var ammo = type == "ammunition" || name.Contains("arrow") || name.Contains("bolt") || name.Contains("bullet") || name.Contains("needle") || name.Contains("ammunition");
        var shield = type == "shield" || name.Contains("shield");
        var ring = name.Contains("ring");
        var neck = name.Contains("necklace") || name.Contains("amulet") || name.Contains("pendant") || name.Contains("brooch");
        var hands = equipmentSlot.Contains("hand") || equipmentSlot.Contains("arm") || name.Contains("glove") || name.Contains("gauntlet") || name.Contains("bracer");
        var feet = equipmentSlot.Contains("feet") || name.Contains("boot") || name.Contains("greave");
        var head = equipmentSlot.Contains("head") || name.Contains("helmet") || name.Contains("helm") || name.Contains("circlet");

        return slot switch
        {
            "armor" => type == "armor" && !shield && !head && !hands && !feet,
            "shield" => shield,
            "main_hand" => type == "weapon" && !ranged,
            "off_hand" => type == "weapon" && !ranged,
            "ranged" => type == "weapon" && ranged,
            "ammunition" => ammo,
            "head" => head,
            "hands" => hands,
            "feet" => feet,
            "neck" => neck || (type == "accessory" && !ring),
            "ring_left" or "ring_right" => ring,
            "accessory_1" or "accessory_2" => type == "accessory" && !ring && !neck,
            _ => false
        };
    }

    public static object MechanicsFor(InventoryClientItem item) => new
    {
        itemType = item.ItemType,
        equipmentSlot = item.EquipmentSlot,
        damageDice = item.DamageDice,
        versatileDamageDice = item.VersatileDamageDice,
        damageType = item.DamageType,
        weaponProperties = item.WeaponProperties,
        normalRangeFeet = item.NormalRangeFeet,
        longRangeFeet = item.LongRangeFeet,
        attackBonus = item.AttackBonus,
        damageBonus = item.DamageBonus,
        armorClassBase = item.ArmorClassBase,
        armorClassBonus = item.ArmorClassBonus,
        maxDexBonus = item.MaxDexBonus,
        strengthRequirement = item.StrengthRequirement,
        stealthDisadvantage = item.StealthDisadvantage
    };

    private static int CalculateArmorClass(
        DiscordCharacterInfo character,
        IReadOnlyDictionary<Guid, InventoryClientItem> items,
        IReadOnlyDictionary<string, EquipmentSlotRow> slots,
        out string summary)
    {
        var dexterityModifier = AbilityModifier(character.Dexterity);
        var unarmored = 10 + dexterityModifier;
        var shieldEquipped = ItemForSlot("shield", slots, items) is not null;
        if (character.ClassName.Equals("Barbarian", StringComparison.OrdinalIgnoreCase))
            unarmored = Math.Max(unarmored, 10 + dexterityModifier + AbilityModifier(character.Constitution));
        if (character.ClassName.Equals("Monk", StringComparison.OrdinalIgnoreCase) && !shieldEquipped)
            unarmored = Math.Max(unarmored, 10 + dexterityModifier + AbilityModifier(character.Wisdom));

        var naturalArmor = FindNaturalArmorBase(character.CharacterData);
        if ((character.SpeciesName ?? string.Empty).Contains("Tortle", StringComparison.OrdinalIgnoreCase))
            naturalArmor = Math.Max(naturalArmor, 17);
        if (naturalArmor > 0) unarmored = Math.Max(unarmored, naturalArmor);

        var armorClass = unarmored;
        var source = naturalArmor > 0 && naturalArmor >= unarmored ? $"natural armor {naturalArmor}" : $"unarmored {unarmored}";
        var armor = ItemForSlot("armor", slots, items);
        if (armor is not null && armor.ArmorClassBase > 0)
        {
            var dexContribution = armor.MaxDexBonus switch
            {
                0 => 0,
                > 0 => Math.Min(dexterityModifier, armor.MaxDexBonus),
                _ => dexterityModifier
            };
            armorClass = armor.ArmorClassBase + dexContribution + Math.Max(0, armor.ArmorClassBonus);
            source = $"{armor.ItemName} {armor.ArmorClassBase}" + (dexContribution == 0 ? string.Empty : $" + DEX {dexContribution:+#;-#;0}");
        }

        var bonusParts = new List<string>();
        foreach (var slot in new[] { "shield", "head", "neck", "hands", "feet", "ring_left", "ring_right", "accessory_1", "accessory_2" })
        {
            var item = ItemForSlot(slot, slots, items);
            if (item is null) continue;
            var bonus = item.ArmorClassBonus;
            if (slot == "shield" && bonus <= 0) bonus = 2;
            if (bonus <= 0) continue;
            armorClass += bonus;
            bonusParts.Add($"{item.ItemName} +{bonus}");
        }

        armorClass = Math.Clamp(armorClass, 1, 40);
        summary = bonusParts.Count == 0 ? source : $"{source}; {string.Join(", ", bonusParts)}";
        return armorClass;
    }

    private static List<EquipmentAttackView> BuildAttacks(
        DiscordCharacterInfo character,
        IReadOnlyDictionary<Guid, InventoryClientItem> items,
        IReadOnlyDictionary<string, EquipmentSlotRow> slots)
    {
        var attacks = new List<EquipmentAttackView>();
        var ammunition = ItemForSlot("ammunition", slots, items);
        foreach (var slotKey in new[] { "main_hand", "off_hand", "ranged" })
        {
            var item = ItemForSlot(slotKey, slots, items);
            if (item is null || !item.ItemType.Equals("Weapon", StringComparison.OrdinalIgnoreCase)) continue;
            var properties = item.WeaponProperties ?? string.Empty;
            var name = item.ItemName ?? string.Empty;
            var ranged = slotKey == "ranged" || properties.Contains("Ammunition", StringComparison.OrdinalIgnoreCase) || properties.Contains("Ranged", StringComparison.OrdinalIgnoreCase) ||
                         name.Contains("bow", StringComparison.OrdinalIgnoreCase) || name.Contains("crossbow", StringComparison.OrdinalIgnoreCase) ||
                         name.Contains("sling", StringComparison.OrdinalIgnoreCase) || name.Contains("blowgun", StringComparison.OrdinalIgnoreCase);
            var requiresAmmunition = properties.Contains("Ammunition", StringComparison.OrdinalIgnoreCase);
            var ammunitionReady = !requiresAmmunition || IsCompatibleAmmunition(item, ammunition);
            var finesse = properties.Contains("Finesse", StringComparison.OrdinalIgnoreCase);
            var abilityModifier = ranged ? AbilityModifier(character.Dexterity) : AbilityModifier(character.Strength);
            if (finesse) abilityModifier = Math.Max(AbilityModifier(character.Strength), AbilityModifier(character.Dexterity));
            var attackBonus = abilityModifier + Math.Max(0, character.ProficiencyBonus) + item.AttackBonus;
            var damageBonus = abilityModifier + item.DamageBonus;
            var dice = string.IsNullOrWhiteSpace(item.DamageDice) ? "1d4" : item.DamageDice.Trim();
            var damage = damageBonus == 0 ? dice : $"{dice} {(damageBonus > 0 ? "+" : "-")} {Math.Abs(damageBonus)}";
            var range = item.NormalRangeFeet > 0
                ? (item.LongRangeFeet > item.NormalRangeFeet ? $"{item.NormalRangeFeet}/{item.LongRangeFeet} ft" : $"{item.NormalRangeFeet} ft")
                : "Melee";
            attacks.Add(new EquipmentAttackView
            {
                SlotKey = slotKey,
                ItemName = item.ItemName,
                AttackBonus = attackBonus,
                Damage = damage,
                DamageType = item.DamageType,
                Range = range,
                Properties = properties,
                IsOffHand = slotKey == "off_hand",
                RequiresAmmunition = requiresAmmunition,
                AmmunitionReady = ammunitionReady,
                AvailabilityNote = ammunitionReady ? string.Empty : "Compatible ammunition is not equipped"
            });
        }
        return attacks;
    }


    private static bool IsCompatibleAmmunition(InventoryClientItem weapon, InventoryClientItem? ammunition)
    {
        if (ammunition is null) return false;
        var weaponName = (weapon.ItemName ?? string.Empty).ToLowerInvariant();
        var ammoName = (ammunition.ItemName ?? string.Empty).ToLowerInvariant();
        if (weaponName.Contains("crossbow")) return ammoName.Contains("bolt");
        if (weaponName.Contains("bow") && !weaponName.Contains("crossbow")) return ammoName.Contains("arrow");
        if (weaponName.Contains("sling")) return ammoName.Contains("bullet") || ammoName.Contains("stone");
        if (weaponName.Contains("blowgun")) return ammoName.Contains("needle");
        return true;
    }

    private static InventoryClientItem? ItemForSlot(
        string slotKey,
        IReadOnlyDictionary<string, EquipmentSlotRow> slots,
        IReadOnlyDictionary<Guid, InventoryClientItem> items)
    {
        if (!slots.TryGetValue(slotKey, out var row) || row.InventoryItemId is not Guid id) return null;
        return items.TryGetValue(id, out var item) ? item : null;
    }

    private static int AbilityModifier(int score) => (int)Math.Floor((score - 10) / 2.0);

    private static string NormalizeSlot(string? value) => (value ?? string.Empty).Trim().ToLowerInvariant().Replace('-', '_').Replace(' ', '_');

    private static int FindNaturalArmorBase(JsonElement root)
    {
        if (root.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in root.EnumerateObject())
            {
                if (property.Name.Equals("NaturalArmorBase", StringComparison.OrdinalIgnoreCase) ||
                    property.Name.Equals("natural_armor_base", StringComparison.OrdinalIgnoreCase) ||
                    property.Name.Equals("naturalArmorBase", StringComparison.OrdinalIgnoreCase))
                {
                    if (property.Value.ValueKind == JsonValueKind.Number && property.Value.TryGetInt32(out var number)) return number;
                    if (property.Value.ValueKind == JsonValueKind.String && int.TryParse(property.Value.GetString(), out number)) return number;
                }
                var nested = FindNaturalArmorBase(property.Value);
                if (nested > 0) return nested;
            }
        }
        else if (root.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in root.EnumerateArray())
            {
                var nested = FindNaturalArmorBase(item);
                if (nested > 0) return nested;
            }
        }
        return 0;
    }
}
