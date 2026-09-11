using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

public sealed record WeatherGameplayProfile(
    string WeatherKey,
    string WeatherLabel,
    decimal TravelMultiplier,
    int VisibilityFeet,
    int RangedDisadvantageBeyondFeet,
    bool DifficultTravel,
    bool ExposedOrdinaryFireSuppressed,
    bool FlyingControlChecksDisadvantage,
    bool ShipHandlingChecksDisadvantage,
    int WaterRequirementMultiplier,
    string Summary);

public sealed record WeatherRollAdjustment(
    bool Advantage,
    bool Disadvantage,
    string Summary);

public static class WeatherGameplayRulesService
{
    public static WeatherGameplayProfile Build(string? weatherKey, string? weatherLabel, bool hotWeather)
    {
        var key = (weatherKey ?? "clear").Trim().ToLowerInvariant();
        var label = string.IsNullOrWhiteSpace(weatherLabel) ? Title(key) : weatherLabel.Trim();
        decimal travel = 1.00m;
        var visibility = 0;
        var rangedDisadvantage = 0;
        var difficultTravel = false;
        var fireSuppressed = false;
        var flyingDisadvantage = false;
        var shipDisadvantage = false;
        var summary = "No significant mechanical weather penalties.";

        switch (key)
        {
            case "rain":
                travel = 1.10m; visibility = 180; rangedDisadvantage = 90; fireSuppressed = true;
                summary = "Rain reduces long-range visibility, hampers exposed ordinary flames, and slows overland travel.";
                break;
            case "fog":
                travel = 1.15m; visibility = 60; rangedDisadvantage = 30;
                summary = "Fog sharply limits sight and long-range attacks while slowing navigation.";
                break;
            case "storm":
                travel = 1.40m; visibility = 90; rangedDisadvantage = 60; difficultTravel = true;
                fireSuppressed = true; flyingDisadvantage = true; shipDisadvantage = true;
                summary = "Storm conditions reduce visibility, suppress exposed flames, slow travel, and hinder flying or ship handling.";
                break;
            case "snow":
                travel = 1.25m; visibility = 150; rangedDisadvantage = 90; difficultTravel = true;
                summary = "Snow slows travel and makes exposed ground harder to cross while reducing long-range visibility.";
                break;
            case "snowstorm":
                travel = 1.60m; visibility = 60; rangedDisadvantage = 30; difficultTravel = true;
                fireSuppressed = true; flyingDisadvantage = true; shipDisadvantage = true;
                summary = "Snowstorm conditions severely restrict visibility, slow travel, suppress exposed flames, and hinder flight or ships.";
                break;
            case "sandstorm":
                travel = 1.70m; visibility = 30; rangedDisadvantage = 20; difficultTravel = true;
                fireSuppressed = true; flyingDisadvantage = true; shipDisadvantage = true;
                summary = "Sandstorm conditions make navigation extremely slow, visibility very short, and airborne or ship control hazardous.";
                break;
            case "dry-wind":
                travel = 1.08m; visibility = 180; rangedDisadvantage = 120;
                flyingDisadvantage = true; shipDisadvantage = true;
                summary = "Strong dry wind modestly slows travel and can hinder flight, sails, and very long ranged attacks.";
                break;
            case "ash-haze":
                travel = 1.15m; visibility = 90; rangedDisadvantage = 60;
                summary = "Ash haze limits sight and long-range attacks and slows careful travel.";
                break;
            case "haze":
                travel = 1.15m; visibility = 120; rangedDisadvantage = 90;
                summary = "Heat haze reduces distant visibility and makes navigation slightly slower.";
                break;
            case "hot-clear":
                summary = "Extreme heat doubles the daily water requirement while otherwise leaving visibility clear.";
                break;
        }

        if (hotWeather && !summary.Contains("water requirement", StringComparison.OrdinalIgnoreCase))
            summary += " Hot-weather survival doubles the daily water requirement.";

        return new WeatherGameplayProfile(
            key, label, travel, visibility, rangedDisadvantage, difficultTravel,
            fireSuppressed, flyingDisadvantage, shipDisadvantage,
            hotWeather ? 2 : 1, summary);
    }

    public static WeatherRollAdjustment ApplyToRoll(
        WeatherGameplayProfile profile,
        int sides,
        string? rollType,
        int distanceFeet,
        string? sensoryBasis,
        string? reason,
        bool advantage,
        bool disadvantage)
    {
        if (sides != 20)
            return new WeatherRollAdjustment(advantage, disadvantage, string.Empty);

        var type = (rollType ?? string.Empty).Trim().ToLowerInvariant();
        var sense = (sensoryBasis ?? string.Empty).Trim().ToLowerInvariant();
        var text = (reason ?? string.Empty).Trim();
        var forcesDisadvantage = false;
        var reasons = new List<string>();

        if (type == "attack" && profile.RangedDisadvantageBeyondFeet > 0 && distanceFeet > profile.RangedDisadvantageBeyondFeet)
        {
            forcesDisadvantage = true;
            reasons.Add($"{profile.WeatherLabel} hampers ranged attacks beyond {profile.RangedDisadvantageBeyondFeet} ft.");
        }

        if (type == "ability_check" && sense == "sight" && profile.VisibilityFeet > 0)
        {
            forcesDisadvantage = true;
            reasons.Add($"{profile.WeatherLabel} obscures sight.");
        }

        if (type == "ability_check" && profile.FlyingControlChecksDisadvantage &&
            Regex.IsMatch(text, @"\b(fly|flying|flight|airborne|wing|hover|aerial)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
        {
            forcesDisadvantage = true;
            reasons.Add($"{profile.WeatherLabel} makes flight control hazardous.");
        }

        if (type == "ability_check" && profile.ShipHandlingChecksDisadvantage &&
            Regex.IsMatch(text, @"\b(ship|boat|sail|sailing|helm|rudder|rigging|vessel|seamanship)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
        {
            forcesDisadvantage = true;
            reasons.Add($"{profile.WeatherLabel} makes ship handling hazardous.");
        }

        if (forcesDisadvantage)
        {
            if (advantage)
            {
                advantage = false;
                disadvantage = false;
            }
            else
            {
                disadvantage = true;
            }
        }

        return new WeatherRollAdjustment(advantage, disadvantage, string.Join(" ", reasons));
    }

    private static string Title(string key)
        => string.Join(' ', (key ?? string.Empty)
            .Split('-', StringSplitOptions.RemoveEmptyEntries)
            .Select(x => x.Length == 0 ? x : char.ToUpperInvariant(x[0]) + x[1..]));
}
