using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

public static class WorldLootCatalogService
{
    public sealed record LootEntry(string ItemName, int Quantity, string Description);
    public sealed record LootProfile(decimal GoldGp, IReadOnlyList<LootEntry> Items, string ProfileName);

    // Used only when the current player turn is itself a source-sensitive claim/action
    // (pickpocket, loot, search corpse/chest, "X has Y", etc.). In that situation the
    // player's words are never allowed to seed the source. The server creates a stable,
    // conservative expected profile from the source identity instead.
    public static LootProfile BuildConservative(string sourceKind, string sourceName, string currentLocation)
    {
        var kind = (sourceKind ?? string.Empty).Trim().ToLowerInvariant();
        var name = (sourceName ?? string.Empty).Trim();
        var lower = name.ToLowerInvariant();
        var seed = StableSeed($"{kind}|{currentLocation}|{name}");
        var items = new List<LootEntry>();

        void Add(string item, int qty, string description)
        {
            if (qty > 0 && !string.IsNullOrWhiteSpace(item)) items.Add(new LootEntry(item, qty, description));
        }

        decimal gold;
        string profile;

        if (kind == "npc" || kind == "corpse")
        {
            if (HasAny(lower, "merchant", "shopkeeper", "trader", "vendor"))
            {
                profile = "merchant expected holdings";
                gold = 3m + (seed % 1300) / 100m; // 3.00-15.99 GP
                Add("Coin Purse", 1, "An ordinary purse used to carry the NPC's server-generated expected currency.");
                Add("Trade Ledger", 1, "A mundane ledger or set of trade notes.");
                Add("Common Clothes", 1, "Ordinary worn clothing.");
            }
            else if (HasAny(lower, "noble", "lord", "lady", "baron", "duke", "count", "prince", "princess"))
            {
                profile = "noble expected holdings";
                gold = 2m + (seed % 800) / 100m; // 2.00-9.99 GP carried personally
                Add("Fine Clothes", 1, "Fine clothing worn by the NPC.");
                Add("Signet or Personal Seal", 1, "A personal identifying seal; exact significance is determined by campaign canon.");
                Add("Personal Effects", 1, "Ordinary personal possessions; no unestablished treasure is implied.");
            }
            else if (HasAny(lower, "guard", "soldier", "warrior", "veteran", "infantry", "captain"))
            {
                profile = "soldier expected holdings";
                gold = (seed % 301) / 100m; // 0-3.00 GP
                Add("Belt Pouch", 1, "An ordinary belt pouch.");
                Add("Common Clothes", 1, "Ordinary worn clothing beneath or with combat gear.");
                Add("Personal Effects", 1, "Small mundane personal belongings.");
            }
            else if (HasAny(lower, "bandit", "pirate", "thief", "rogue", "cutpurse", "brigand"))
            {
                profile = "criminal expected holdings";
                gold = (seed % 601) / 100m; // 0-6.00 GP
                Add("Belt Pouch", 1, "An ordinary belt pouch.");
                Add("Dagger", 1, "A mundane dagger expected for this role.");
                Add("Personal Effects", 1, "Small mundane personal belongings.");
            }
            else if (HasAny(lower, "mage", "wizard", "sorcerer", "warlock", "druid", "priest", "acolyte"))
            {
                profile = "spellcaster expected holdings";
                gold = (seed % 401) / 100m; // 0-4.00 GP
                Add("Spellcasting Components or Focus", 1, "Mundane spellcasting materials/focus appropriate to the NPC; no magical item is implied.");
                Add("Personal Effects", 1, "Small mundane personal belongings.");
            }
            else
            {
                profile = kind == "corpse" ? "generic corpse expected holdings" : "generic NPC expected holdings";
                gold = (seed % 201) / 100m; // 0-2.00 GP
                Add("Personal Effects", 1, "Ordinary personal belongings; no player-claimed valuables are assumed.");
            }
        }
        else if (kind == "container")
        {
            profile = "unestablished container expected contents";
            gold = (seed % 501) / 100m; // 0-5.00 GP
            var pick = seed % 6;
            if (pick == 0) Add("Torch", 2, "Ordinary stored supplies.");
            else if (pick == 1) Add("Hempen Rope (50 ft)", 1, "Ordinary stored supplies.");
            else if (pick == 2) Add("Rations (1 day)", 1, "Ordinary stored provisions.");
            else if (pick == 3) Add("Waterskin", 1, "An ordinary empty waterskin.");
            else if (pick == 4) Add("Common Cloth", 2, "Ordinary stored material.");
            else Add("Mundane Supplies", 1, "Unremarkable supplies appropriate to the scene.");
        }
        else if (kind == "object")
        {
            profile = "object material profile";
            gold = 0m;
            Add("Salvageable Material", 1, "Ordinary material that can reasonably be removed from the object; no valuables are implied.");
        }
        else
        {
            profile = "world source conservative profile";
            gold = 0m;
            Add("Ordinary Material", 1, "Conservative world material established independently of the player's claim.");
        }

        gold = Math.Round(Math.Max(0m, gold), 2);
        return new LootProfile(gold, items, profile);
    }

    private static int StableSeed(string value)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(value ?? string.Empty));
        return (int)(BitConverter.ToUInt32(bytes, 0) & 0x7FFFFFFF);
    }

    private static bool HasAny(string text, params string[] terms) => terms.Any(text.Contains);
}
