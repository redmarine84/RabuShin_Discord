using System.Text.Json;
using System.Text.Json.Nodes;

public static class WaterskinMechanicsService
{
    public const string MechanicsVersion = "6.9";
    public const int MaximumDrinks = 30;
    public const string BasicDescription = "A durable leather water container. It holds 30 drinks, equal to 3 days of water.";
    public const string TaintedWarning = "Foul or Tainted water. Drinking will cause nausea and reduce Hunger 30% and Thirst to Increase by 1%. Boil before consuming";
    public const string MagicNote = "Magically purifies water. Any water that is used to fill the Magic Waterskin is purified water and safe to drink.";

    private static readonly JsonSerializerOptions WebJson = new(JsonSerializerDefaults.Web);

    public static bool IsWaterskinName(string? itemName)
    {
        var name = Normalize(itemName);
        return name is "waterskin" or "waterskin full" or "full waterskin" or "waterskin tainted"
            or "magic waterskin" or "magic waterskin full" or "full magic waterskin";
    }

    public static string DisplayName(DiscordInventoryInfo item)
    {
        var state = item.WaterskinState;
        if (state is null) return item.ItemName;
        if (state.Kind.Equals("magic", StringComparison.OrdinalIgnoreCase)) return "Magic Waterskin";
        return state.WaterQuality.Equals("tainted", StringComparison.OrdinalIgnoreCase)
            ? "Waterskin(Tainted)"
            : "Waterskin";
    }

    public static string Description(DiscordInventoryInfo item)
    {
        var state = item.WaterskinState;
        if (state is null) return ReadDescription(item.ItemData);

        var baseDescription = state.Kind.Equals("magic", StringComparison.OrdinalIgnoreCase)
            ? $"{BasicDescription} {MagicNote}"
            : BasicDescription;
        var status = state.DrinksRemaining <= 0
            ? "Current contents: Empty."
            : $"Current contents: {state.DrinksRemaining}/{MaximumDrinks} drinks of {state.WaterQuality.ToLowerInvariant()} water.";
        return state.WaterQuality.Equals("tainted", StringComparison.OrdinalIgnoreCase)
            ? $"{baseDescription}\n\n{status}\n\n{TaintedWarning}"
            : $"{baseDescription}\n\n{status}";
    }

    public static JsonObject ToClientItem(DiscordInventoryInfo item)
    {
        var baseline = InventoryPresentationService.ToClientItem(item);
        var result = JsonSerializer.SerializeToNode(baseline, WebJson) as JsonObject ?? new JsonObject();
        var state = item.WaterskinState;
        if (state is null) return result;

        result["itemName"] = DisplayName(item);
        result["description"] = Description(item);
        result["canUse"] = false;
        result["waterskin"] = new JsonObject
        {
            ["kind"] = state.Kind,
            ["drinksRemaining"] = state.DrinksRemaining,
            ["maximumDrinks"] = MaximumDrinks,
            ["waterQuality"] = state.WaterQuality,
            ["sourceName"] = state.SourceName,
            ["canDrink"] = state.DrinksRemaining > 0,
            ["canFill"] = state.DrinksRemaining <= 0,
            ["canBoil"] = state.Kind.Equals("basic", StringComparison.OrdinalIgnoreCase)
                && state.WaterQuality.Equals("tainted", StringComparison.OrdinalIgnoreCase)
                && state.DrinksRemaining > 0,
            ["taintedWarning"] = state.WaterQuality.Equals("tainted", StringComparison.OrdinalIgnoreCase)
                ? TaintedWarning
                : string.Empty,
            ["magicNote"] = state.Kind.Equals("magic", StringComparison.OrdinalIgnoreCase)
                ? MagicNote
                : string.Empty
        };
        return result;
    }

    public static string BuildGameplaySummary(DiscordInventoryInfo item)
    {
        var baseline = InventoryPresentationService.BuildGameplaySummary(item);
        var state = item.WaterskinState;
        if (state is null) return baseline;
        return $"{baseline}; inventoryItemId {item.InventoryItemId}; waterskin {state.Kind}; " +
               $"{state.DrinksRemaining}/{MaximumDrinks} drinks; water quality {state.WaterQuality}; " +
               $"source {state.SourceName}";
    }

    public static decimal WeightLb(DiscordWaterskinState state)
    {
        // One drink is one tenth of a normal one-gallon daily water requirement.
        // Water weighs about 8.34 lb/gallon; the empty leather container weighs 1 lb.
        return Math.Round(1m + Math.Clamp(state.DrinksRemaining, 0, MaximumDrinks) * 0.834m, 2);
    }

    private static string ReadDescription(JsonElement data)
    {
        if (data.ValueKind == JsonValueKind.Object && data.TryGetProperty("description", out var value)
            && value.ValueKind == JsonValueKind.String)
            return value.GetString()?.Trim() ?? string.Empty;
        return string.Empty;
    }

    private static string Normalize(string? value)
    {
        var source = (value ?? string.Empty).Trim().ToLowerInvariant();
        var chars = source.Select(ch => char.IsLetterOrDigit(ch) ? ch : ' ').ToArray();
        return string.Join(' ', new string(chars).Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }
}
