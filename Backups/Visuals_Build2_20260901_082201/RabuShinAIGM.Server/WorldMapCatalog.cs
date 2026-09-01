public static class WorldMapCatalog
{
    public const int ImageWidth = 1439;
    public const int ImageHeight = 959;
    public const string ImageUrl = "/maps/Vael_Turog_World_Map.jpg";

    public static IReadOnlyList<WorldMapLocationDefinition> Locations { get; } = new[]
    {
        new WorldMapLocationDefinition("aetherfall", "Aetherfall", 1170, 145, 190, 55),
        new WorldMapLocationDefinition("frostharbor", "Frostharbor", 390, 245, 205, 50),
        new WorldMapLocationDefinition("high_bastion", "High Bastion", 1010, 245, 210, 47),
        new WorldMapLocationDefinition("silverreach", "Silverreach", 1120, 415, 190, 45),
        new WorldMapLocationDefinition("marrowfen", "Marrowfen", 175, 375, 180, 45),
        new WorldMapLocationDefinition("stonewake", "Stonewake Port", 700, 470, 245, 52),
        new WorldMapLocationDefinition("greymoor", "Greymoor Hollow", 375, 610, 285, 53),
        new WorldMapLocationDefinition("lunareth", "Lunareth", 1075, 670, 225, 55),
        new WorldMapLocationDefinition("emberfall", "Emberfall", 112, 565, 183, 49),
        new WorldMapLocationDefinition("sunspire", "Sunspire", 655, 878, 175, 54),
        new WorldMapLocationDefinition("blackroot", "Blackroot Enclave", 375, 868, 260, 57),
        new WorldMapLocationDefinition("duskmire", "Duskmire Crossing", 935, 800, 185, 50)
    };
}

public sealed record WorldMapLocationDefinition(
    string Key,
    string Name,
    int X,
    int Y,
    int Width,
    int Height);
