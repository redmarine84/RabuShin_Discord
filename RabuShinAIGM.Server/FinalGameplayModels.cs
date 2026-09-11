using System.Text.Json;
using System.Text.Json.Serialization;

public sealed class CraftRecipeRequest
{
    public string RecipeKey { get; set; } = string.Empty;
}

public sealed class EquipmentEquipRequest
{
    public Guid InventoryItemId { get; set; }
    public string SlotKey { get; set; } = string.Empty;
}

public sealed class EquipmentUnequipRequest
{
    public string SlotKey { get; set; } = string.Empty;
}

public sealed class FormationSaveRequest
{
    public string PresetKey { get; set; } = "traveling";
    public List<FormationOffsetRequest> CustomOffsets { get; set; } = new();
}

public sealed class FormationOffsetRequest
{
    public Guid CharacterId { get; set; }
    public int OffsetX { get; set; }
    public int OffsetY { get; set; }
}

public sealed class EquipmentSlotRow
{
    [JsonPropertyName("slot_key")] public string SlotKey { get; set; } = string.Empty;
    [JsonPropertyName("inventory_item_id")] public Guid? InventoryItemId { get; set; }
    [JsonPropertyName("item_name")] public string ItemName { get; set; } = string.Empty;
    [JsonPropertyName("mechanics")] public JsonElement Mechanics { get; set; }
}

public sealed class EquipmentSlotView
{
    public string SlotKey { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public string Icon { get; set; } = string.Empty;
    public Guid? InventoryItemId { get; set; }
    public string ItemName { get; set; } = string.Empty;
    public string ItemType { get; set; } = string.Empty;
    public string RulesSummary { get; set; } = string.Empty;
}

public sealed class EquipmentAttackView
{
    public string SlotKey { get; set; } = string.Empty;
    public string ItemName { get; set; } = string.Empty;
    public int AttackBonus { get; set; }
    public string Damage { get; set; } = string.Empty;
    public string DamageType { get; set; } = string.Empty;
    public string Range { get; set; } = string.Empty;
    public string Properties { get; set; } = string.Empty;
    public bool IsOffHand { get; set; }
    public bool RequiresAmmunition { get; set; }
    public bool AmmunitionReady { get; set; } = true;
    public string AvailabilityNote { get; set; } = string.Empty;
}

public sealed class EquipmentLoadoutView
{
    public Guid CharacterId { get; set; }
    public string CharacterName { get; set; } = string.Empty;
    public int ArmorClass { get; set; }
    public string DefenseSummary { get; set; } = string.Empty;
    public List<EquipmentSlotView> Slots { get; set; } = new();
    public List<EquipmentAttackView> Attacks { get; set; } = new();
}
