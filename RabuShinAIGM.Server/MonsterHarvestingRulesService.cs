using System.Text.Json.Serialization;

public static class MonsterHarvestingRulesService
{
    public sealed class HarvestSeedEntry
    {
        public string ItemName { get; init; } = string.Empty;
        public string Description { get; init; } = string.Empty;
        public int MaximumQuantity { get; init; }
        public int BaseDc { get; init; }
        public string Rarity { get; init; } = "common";
        public string SkillName { get; init; } = "Survival";
        public string AbilityName { get; init; } = "wisdom";
        public string ToolLabel { get; init; } = "Suitable harvesting tool";
        public string[] ToolKeywords { get; init; } = Array.Empty<string>();
        public bool ToolRequired { get; init; }
        public string RequiredContainerFamily { get; init; } = string.Empty;
        public int? SpoilageMinutes { get; init; }
        public Dictionary<string, object?> ItemData { get; init; } = new();
    }

    public static HarvestSeedEntry Describe(
        string monsterName,
        MonsterLootCatalogService.LootEntry entry)
    {
        var item = (entry.ItemName ?? string.Empty).Trim();
        var lower = item.ToLowerInvariant();
        var monster = (monsterName ?? string.Empty).Trim();
        var monsterLower = monster.ToLowerInvariant();

        var family = CraftingFamily(item);
        var skill = "Survival";
        var ability = "wisdom";
        var toolLabel = "Knife, dagger, or other suitable blade";
        var toolKeywords = new[] { "knife", "dagger", "shortsword", "longsword", "handaxe", "battleaxe" };
        var toolRequired = false;
        var rarity = "common";
        var dc = 10;
        int? spoilage = null;
        var requiredContainer = string.Empty;

        if (family == "monster_meat")
        {
            dc = 10;
            spoilage = 60;
        }
        else if (family == "pelt_hide")
        {
            dc = 12;
            rarity = "uncommon";
            spoilage = 240;
        }
        else if (family == "dragon_scale")
        {
            dc = 14;
            rarity = "rare";
            toolLabel = "Strong knife, axe, or leatherworking blade";
            spoilage = null;
        }
        else if (family == "dragon_blood")
        {
            dc = 16;
            rarity = "rare";
            skill = "Medicine";
            toolLabel = "Clean blade plus an Empty Vial";
            requiredContainer = "vial";
            spoilage = 60;
        }
        else if (family == "venom")
        {
            dc = 15;
            rarity = "rare";
            skill = "Medicine";
            toolLabel = "Poisoner's kit, herbalism kit, or fine blade";
            toolKeywords = new[] { "poisoner", "herbalism", "knife", "dagger" };
            spoilage = 120;
        }
        else if (family == "chitin_shell")
        {
            dc = 13;
            rarity = "uncommon";
            toolLabel = "Knife, axe, or sturdy cutting tool";
        }
        else if (family == "bone_horn")
        {
            dc = 11;
            rarity = lower.Contains("fang") || lower.Contains("tooth") || lower.Contains("claw")
                ? "uncommon"
                : "common";
        }
        else if (family == "plant_fiber")
        {
            dc = 10;
            skill = "Nature";
            ability = "intelligence";
            toolLabel = "Herbalism kit or blade";
            toolKeywords = new[] { "herbalism", "knife", "dagger", "sickle" };
            spoilage = lower.Contains("sap") || lower.Contains("spore") ? 180 : null;
        }
        else if (family == "ooze_residue")
        {
            dc = 14;
            rarity = "uncommon";
            skill = "Nature";
            ability = "intelligence";
            toolLabel = "Alchemist's supplies or sealed container";
            toolKeywords = new[] { "alchemist", "vial", "bottle", "jar" };
            spoilage = 120;
        }
        else if (family == "elemental_essence")
        {
            dc = 15;
            rarity = "rare";
            skill = "Arcana";
            ability = "intelligence";
            toolLabel = "Alchemist's supplies or arcane focus";
            toolKeywords = new[] { "alchemist", "arcane focus", "component pouch" };
        }
        else if (family == "ectoplasm")
        {
            dc = 15;
            rarity = "rare";
            skill = "Arcana";
            ability = "intelligence";
            toolLabel = "Arcane focus plus an Empty Vial";
            toolKeywords = new[] { "arcane focus", "component pouch", "vial" };
            requiredContainer = "vial";
            spoilage = 120;
        }
        else if (family == "construct_salvage")
        {
            dc = 13;
            rarity = "uncommon";
            skill = "Investigation";
            ability = "intelligence";
            toolLabel = "Tinker's tools, smith's tools, or suitable hand tools";
            toolKeywords = new[] { "tinker", "smith", "tool", "hammer" };
        }
        else
        {
            dc = 12;
            rarity = "uncommon";
        }

        if (monsterLower.Contains("ancient") || monsterLower.Contains("adult dragon"))
        {
            dc += 2;
            rarity = family is "dragon_scale" or "dragon_blood" ? "very_rare" : rarity;
        }

        var itemData = new Dictionary<string, object?>
        {
            ["item_type"] = "Crafting Material",
            ["crafting_family"] = family,
            ["harvested_from"] = monster,
            ["harvest_rarity"] = rarity,
            ["harvest_skill"] = skill,
            ["description"] = entry.Description
        };

        return new HarvestSeedEntry
        {
            ItemName = item,
            Description = entry.Description,
            MaximumQuantity = Math.Max(1, entry.Quantity),
            BaseDc = Math.Clamp(dc, 5, 25),
            Rarity = rarity,
            SkillName = skill,
            AbilityName = ability,
            ToolLabel = toolLabel,
            ToolKeywords = toolKeywords,
            ToolRequired = toolRequired,
            RequiredContainerFamily = requiredContainer,
            SpoilageMinutes = spoilage,
            ItemData = itemData
        };
    }

    public static string CraftingFamily(string itemName)
    {
        var name = (itemName ?? string.Empty).Trim().ToLowerInvariant();
        if (name.Contains("dragon") && name.Contains("blood")) return "dragon_blood";
        if (name.Contains("dragon") && name.Contains("scale")) return "dragon_scale";
        if (name.Contains("venom") || name.Contains("poison gland") || name.Contains("poison sac")) return "venom";
        if (name.Contains("chitin") || name.Contains("carapace") || name.Contains("shell")) return "chitin_shell";
        if (name.Contains("pelt") || name.Contains("hide") || name.Contains(" skin")) return "pelt_hide";
        if ((name.Contains("meat") || name.Contains("flesh")) && !name.Contains("ration")) return "monster_meat";
        if (name.Contains("bone") || name.Contains("horn") || name.Contains("antler") ||
            name.Contains("claw") || name.Contains("talon") || name.Contains("fang") ||
            name.Contains("tooth") || name.Contains("teeth") || name.Contains("tusk"))
            return "bone_horn";
        if (name.Contains("plant fiber") || name.Contains("sap") || name.Contains("seed") || name.Contains("spore"))
            return "plant_fiber";
        if (name.Contains("ooze") || name.Contains("slime") || name.Contains("membrane"))
            return "ooze_residue";
        if (name.Contains("elemental") || name.Contains("cinder core") || name.Contains("frost crystal"))
            return "elemental_essence";
        if (name.Contains("ectoplasm")) return "ectoplasm";
        if (name.Contains("construct component") || name.Contains("arcane scrap"))
            return "construct_salvage";
        return "monster_material";
    }
}
