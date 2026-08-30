using System.Text;

public sealed class CampaignCanonService
{
    private readonly IWebHostEnvironment _environment;

    public CampaignCanonService(IWebHostEnvironment environment)
    {
        _environment = environment;
    }

    public string GetCanon(int chapter, string currentLocation)
    {
        var dataRoot = Path.Combine(_environment.ContentRootPath, "Data", "Canon");
        var parts = new List<string>();
        AddFile(parts, Path.Combine(dataRoot, "campaign_overview.txt"), 18000);

        var slug = LocationSlug(currentLocation);
        if (!string.IsNullOrWhiteSpace(slug))
            AddFile(parts, Path.Combine(dataRoot, slug + ".txt"), 30000);

        return string.Join("\n\n--- CURRENT CAMPAIGN CANON ---\n\n", parts);
    }

    private static void AddFile(List<string> parts, string path, int maxChars)
    {
        if (!File.Exists(path)) return;
        var text = File.ReadAllText(path);
        if (text.Length > maxChars) text = text[..maxChars];
        if (!string.IsNullOrWhiteSpace(text)) parts.Add(text);
    }

    private static string LocationSlug(string value)
    {
        var location = (value ?? string.Empty).Trim().ToLowerInvariant();
        if (location.Contains("greymoor")) return "greymoor";
        if (location.Contains("stonewake")) return "stonewake";
        if (location.Contains("emberfall")) return "emberfall";
        if (location.Contains("lunareth")) return "lunareth";
        if (location.Contains("high bastion")) return "high_bastion";
        if (location.Contains("marrowfen")) return "marrowfen";
        if (location.Contains("silverreach")) return "silverreach";
        if (location.Contains("duskmire")) return "duskmire";
        if (location.Contains("frostharbor")) return "frostharbor";
        if (location.Contains("sunspire")) return "sunspire";
        if (location.Contains("blackroot")) return "blackroot";
        if (location.Contains("aetherfall")) return "aetherfall";
        return string.Empty;
    }
}
