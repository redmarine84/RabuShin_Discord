public static class LocalMapCatalog
{
    public static IReadOnlyList<LocalMapDefinition> Locations { get; } = new[]
    {
        new LocalMapDefinition("greymoor", "Greymoor Hollow", "/maps/settlements/Settlement_Greymoor_Hollow.jpg", 2048, 1365, "/maps/encounters/Encounter_Greymoor_Hollow.jpeg", 1432, 955),
        new LocalMapDefinition("stonewake", "Stonewake Port", "/maps/settlements/Settlement_Stonewake_Port.jpg", 1536, 1024, "/maps/encounters/Encounter_Stonewake_Port.jpeg", 1432, 955),
        new LocalMapDefinition("emberfall", "Emberfall", "/maps/settlements/Settlement_Emberfall.jpg", 1536, 1024, "/maps/encounters/Encounter_Emberfall.jpeg", 1432, 955),
        new LocalMapDefinition("lunareth", "Lunareth", "/maps/settlements/Settlement_Lunareth.jpg", 1536, 1024, "/maps/encounters/Encounter_Lunareth.jpeg", 1432, 955),
        new LocalMapDefinition("high_bastion", "High Bastion", "/maps/settlements/Settlement_High_Bastion.jpg", 1536, 1024, "/maps/encounters/Encounter_High_Bastion.jpeg", 1432, 955),
        new LocalMapDefinition("marrowfen", "Marrowfen", "/maps/settlements/Settlement_Marrowfen.jpg", 1536, 1024, "/maps/encounters/Encounter_Marrowfen.jpeg", 1502, 1001),
        new LocalMapDefinition("silverreach", "Silverreach", "/maps/settlements/Settlement_Silverreach.jpg", 1536, 1024, "/maps/encounters/Encounter_Silverreach.jpeg", 1432, 955),
        new LocalMapDefinition("duskmire", "Duskmire Crossing", "/maps/settlements/Settlement_Duskmire_Crossing.jpg", 1536, 1024, "/maps/encounters/Encounter_Duskmire_Crossing.jpeg", 1432, 955),
        new LocalMapDefinition("frostharbor", "Frostharbor", "/maps/settlements/Settlement_Frostharbor.jpg", 1536, 1024, "/maps/encounters/Encounter_Frostharbor.jpeg", 1432, 955),
        new LocalMapDefinition("sunspire", "Sunspire", "/maps/settlements/Settlement_Sunspire.jpg", 1536, 1024, "/maps/encounters/Encounter_Sunspire.jpeg", 1432, 955),
        new LocalMapDefinition("blackroot", "Blackroot Enclave", "/maps/settlements/Settlement_Blackroot_Enclave.jpg", 1536, 1024, "/maps/encounters/Encounter_Blackroot_Enclave.png", 1448, 1086),
        new LocalMapDefinition("aetherfall", "Aetherfall", "/maps/settlements/Settlement_Aetherfall.jpg", 1536, 1024, "/maps/encounters/Encounter_Aetherfall.jpeg", 1432, 955)
    };

    public static LocalMapDefinition? FindByLocation(string? location)
    {
        if (string.IsNullOrWhiteSpace(location)) return null;
        var value = location.Trim();
        return Locations.FirstOrDefault(x =>
            x.LocationName.Equals(value, StringComparison.OrdinalIgnoreCase) ||
            x.LocationKey.Equals(value, StringComparison.OrdinalIgnoreCase));
    }
}

public sealed record LocalMapDefinition(
    string LocationKey,
    string LocationName,
    string SettlementImageUrl,
    int SettlementImageWidth,
    int SettlementImageHeight,
    string EncounterImageUrl,
    int EncounterImageWidth,
    int EncounterImageHeight);
