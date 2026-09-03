using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

public static class RationMechanicsService
{
    public const string MechanicsVersion = "6.10";
    public const int PortionsPerDay = 3;
    public const decimal HungerPercentPerPortion = 33m;

    private static readonly JsonSerializerOptions WebJson = new(JsonSerializerDefaults.Web);
    private static readonly Regex RationNamePattern = new(
        @"\bRations?\s*\(\s*(?<days>1|3|5|7)\s+days?\s*\)\s*$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static bool TryGetDayCount(string? itemName, out int dayCount)
    {
        dayCount = 0;
        var match = RationNamePattern.Match((itemName ?? string.Empty).Trim());
        return match.Success && int.TryParse(match.Groups["days"].Value, out dayCount)
            && dayCount is 1 or 3 or 5 or 7;
    }

    public static int MaximumPortions(int dayCount) => Math.Max(0, dayCount) * PortionsPerDay;

    public static JsonObject ToClientItem(DiscordInventoryInfo item)
    {
        var baseline = InventoryPresentationService.ToClientItem(item);
        var result = JsonSerializer.SerializeToNode(baseline, WebJson) as JsonObject ?? new JsonObject();
        var state = item.RationState;
        if (state is null) return result;

        var maximum = state.MaximumPortions > 0 ? state.MaximumPortions : MaximumPortions(state.DayCount);
        var remaining = Math.Clamp(state.PortionsRemaining, 0, maximum);
        result["canUse"] = false;
        result["ration"] = new JsonObject
        {
            ["dayCount"] = state.DayCount,
            ["portionsRemaining"] = remaining,
            ["maximumPortions"] = maximum,
            ["portionsPerDay"] = PortionsPerDay,
            ["hungerPercentPerPortion"] = HungerPercentPerPortion,
            ["canEat"] = remaining > 0
        };
        return result;
    }

    public static string BuildGameplaySummary(DiscordInventoryInfo item)
    {
        var baseline = InventoryPresentationService.BuildGameplaySummary(item);
        var state = item.RationState;
        if (state is null) return baseline;
        var maximum = state.MaximumPortions > 0 ? state.MaximumPortions : MaximumPortions(state.DayCount);
        return $"{baseline}; inventoryItemId {item.InventoryItemId}; ration pack {state.DayCount} day(s); " +
               $"{Math.Clamp(state.PortionsRemaining, 0, maximum)}/{maximum} unnamed portions remain; " +
               $"each portion restores exactly {HungerPercentPerPortion:0} Hunger percentage points";
    }

    public static decimal WeightLb(DiscordRationState state)
    {
        // One day of rations is one pound of food and is divided into three equal portions.
        var maximum = state.MaximumPortions > 0 ? state.MaximumPortions : MaximumPortions(state.DayCount);
        var portions = Math.Clamp(state.PortionsRemaining, 0, maximum);
        return Math.Round(portions / (decimal)PortionsPerDay, 2, MidpointRounding.AwayFromZero);
    }
}
