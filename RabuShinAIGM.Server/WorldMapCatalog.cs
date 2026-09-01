public static class WorldMapCatalog
{
    // Actual Vael Turog world-map artwork supplied for the Discord Activity.
    public const int ImageWidth = 1536;
    public const int ImageHeight = 1024;
    public const string ImageUrl = "/maps/Vael_Turog_World_Map.png";

    // Hitboxes are calibrated directly against Vael_Turog_World_Map_Outlined.png.
    // Coordinates use the original 1536 x 1024 image pixel space.
    public static IReadOnlyList<WorldMapLocationDefinition> Locations { get; } = new[]
    {
        new WorldMapLocationDefinition("aetherfall", "Aetherfall", 577, 20, 315, 69),
        new WorldMapLocationDefinition("frostharbor", "Frostharbor", 247, 171, 250, 72),
        new WorldMapLocationDefinition("high_bastion", "High Bastion", 617, 237, 247, 59),
        new WorldMapLocationDefinition("silverreach", "Silverreach", 1144, 262, 239, 54),
        new WorldMapLocationDefinition("marrowfen", "Marrowfen", 899, 338, 247, 65),
        new WorldMapLocationDefinition("stonewake", "Stonewake Port", 254, 382, 282, 69),
        new WorldMapLocationDefinition("greymoor", "Greymoor Hollow", 552, 374, 284, 61),
        new WorldMapLocationDefinition("lunareth", "Lunareth", 892, 434, 258, 69),
        new WorldMapLocationDefinition("emberfall", "Emberfall", 1159, 528, 238, 55),
        new WorldMapLocationDefinition("duskmire", "Duskmire Crossing", 1180, 691, 335, 62),
        new WorldMapLocationDefinition("sunspire", "Sunspire", 249, 694, 250, 71),
        new WorldMapLocationDefinition("blackroot", "Blackroot Enclave", 620, 723, 352, 71)
    };
}

public sealed record WorldMapLocationDefinition(
    string Key,
    string Name,
    int X,
    int Y,
    int Width,
    int Height);
