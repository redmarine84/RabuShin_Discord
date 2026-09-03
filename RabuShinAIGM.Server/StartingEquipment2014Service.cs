using System.Text.Json;

public sealed record StartingEquipment2014Grant(string ItemName, int Quantity = 1, string BundleKey = "", string Origin = "");
public sealed record StartingEquipment2014Slot(string Key, string Label, IReadOnlyList<StartingEquipment2014Option> Options);
public sealed record StartingEquipment2014Option(string Key, string Label, IReadOnlyList<StartingEquipment2014Grant> Grants, IReadOnlyList<StartingEquipment2014Slot> Slots);
public sealed record StartingEquipment2014ChoiceGroup(string Key, string Label, IReadOnlyList<StartingEquipment2014Option> Options);
public sealed record StartingEquipment2014Plan(string SourceName, string RulesName, decimal Gold, IReadOnlyList<StartingEquipment2014Grant> FixedGrants, IReadOnlyList<StartingEquipment2014ChoiceGroup> ChoiceGroups);
public sealed record StartingEquipment2014ResolvedItem(string ItemName, int Quantity, string Origin);

public static class StartingEquipment2014Service
{
    public const string RulesetVersion = "2014";
    public const string BuildVersion = "6.11";

    public static readonly string[] LegacyBackgroundNames =
    {
        "Acolyte", "Charlatan", "Criminal", "Entertainer", "Folk Hero", "Guild Artisan", "Hermit",
        "Noble", "Outlander", "Sage", "Sailor", "Soldier", "Urchin"
    };

    private static readonly string[] SimpleMeleeWeapons =
    {
        "Club", "Dagger", "Greatclub", "Handaxe", "Javelin", "Light Hammer", "Mace", "Quarterstaff", "Sickle", "Spear"
    };

    private static readonly string[] SimpleRangedWeapons = { "Light Crossbow", "Dart", "Shortbow", "Sling" };

    private static readonly string[] MartialMeleeWeapons =
    {
        "Battleaxe", "Flail", "Glaive", "Greataxe", "Greatsword", "Halberd", "Lance", "Longsword", "Maul",
        "Morningstar", "Pike", "Rapier", "Scimitar", "Shortsword", "Trident", "War Pick", "Warhammer", "Whip"
    };

    private static readonly string[] MartialRangedWeapons = { "Blowgun", "Hand Crossbow", "Heavy Crossbow", "Longbow", "Net" };

    private static readonly string[] MusicalInstruments =
    {
        "Bagpipes", "Drum", "Dulcimer", "Flute", "Horn", "Lute", "Lyre", "Pan Flute", "Shawm", "Viol"
    };

    private static readonly string[] ArtisanTools =
    {
        "Alchemist's Supplies", "Brewer's Supplies", "Calligrapher's Supplies", "Carpenter's Tools",
        "Cartographer's Tools", "Cobbler's Tools", "Cook's Utensils", "Glassblower's Tools", "Jeweler's Tools",
        "Leatherworker's Tools", "Mason's Tools", "Painter's Supplies", "Potter's Tools", "Smith's Tools",
        "Tinker's Tools", "Weaver's Tools", "Woodcarver's Tools"
    };

    private static readonly Dictionary<string, IReadOnlyList<StartingEquipment2014Grant>> Packs =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["burglar"] = new[]
            {
                G("Backpack"), G("Ball Bearings (bag of 1,000)"), G("String (10 feet)"), G("Bell"), G("Candle", 5),
                G("Crowbar"), G("Hammer"), G("Piton", 10), G("Hooded Lantern"), G("Oil Flask", 2),
                G("Rations (5 days)"), G("Tinderbox"), G("Waterskin"), G("Hempen Rope (50 feet)")
            },
            ["diplomat"] = new[]
            {
                G("Chest"), G("Map or Scroll Case", 2), G("Fine Clothes"), G("Bottle of Ink"), G("Ink Pen"),
                G("Lamp"), G("Oil Flask", 2), G("Paper", 5), G("Perfume Vial"), G("Sealing Wax"), G("Soap")
            },
            ["dungeoneer"] = new[]
            {
                G("Backpack"), G("Crowbar"), G("Hammer"), G("Piton", 10), G("Torch", 10), G("Tinderbox"),
                G("Rations (5 days)", 2), G("Waterskin"), G("Hempen Rope (50 feet)")
            },
            ["entertainer"] = new[]
            {
                G("Backpack"), G("Bedroll"), G("Costume", 2), G("Candle", 5), G("Rations (5 days)"),
                G("Waterskin"), G("Disguise Kit")
            },
            ["explorer"] = new[]
            {
                G("Backpack"), G("Bedroll"), G("Mess Kit"), G("Tinderbox"), G("Torch", 10),
                G("Rations (5 days)", 2), G("Waterskin"), G("Hempen Rope (50 feet)")
            },
            ["priest"] = new[]
            {
                G("Backpack"), G("Blanket"), G("Candle", 10), G("Tinderbox"), G("Alms Box"),
                G("Incense Block", 2), G("Censer"), G("Vestments"), G("Rations (1 day)", 2), G("Waterskin")
            },
            ["scholar"] = new[]
            {
                G("Backpack"), G("Book of Lore"), G("Bottle of Ink"), G("Ink Pen"), G("Parchment", 10),
                G("Bag of Sand"), G("Small Knife")
            }
        };

    private static readonly Dictionary<string, string> BackgroundAliases = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Artisan"] = "Guild Artisan",
        ["Farmer"] = "Folk Hero",
        ["Guard"] = "Soldier",
        ["Guide"] = "Outlander",
        ["Merchant"] = "Guild Artisan",
        ["Scribe"] = "Sage",
        ["Wayfarer"] = "Urchin"
    };

    public static StartingEquipment2014Plan? GetClassPlan(string? className)
    {
        return Normalize(className) switch
        {
            "barbarian" => Plan("Class", "Barbarian", 0,
                fixedGrants: new[] { Pack("explorer", "Explorer's Pack"), G("Javelin", 4) },
                groups: new[]
                {
                    Group("primary_weapon", "Primary weapon",
                        FixedOption("a", "Greataxe", G("Greataxe")),
                        SlotOption("b", "Any martial melee weapon", Slot("weapon", "Choose martial melee weapon", MartialMeleeWeapons))),
                    Group("secondary_weapon", "Secondary weapon",
                        FixedOption("a", "Two handaxes", G("Handaxe", 2)),
                        SlotOption("b", "Any simple weapon", Slot("weapon", "Choose simple weapon", SimpleWeapons())))
                }),

            "bard" => Plan("Class", "Bard", 0,
                fixedGrants: new[] { G("Leather Armor"), G("Dagger") },
                groups: new[]
                {
                    Group("weapon", "Weapon",
                        FixedOption("a", "Rapier", G("Rapier")),
                        FixedOption("b", "Longsword", G("Longsword")),
                        SlotOption("c", "Any simple weapon", Slot("weapon", "Choose simple weapon", SimpleWeapons()))),
                    Group("pack", "Equipment pack",
                        FixedOption("a", "Diplomat's Pack", Pack("diplomat", "Diplomat's Pack")),
                        FixedOption("b", "Entertainer's Pack", Pack("entertainer", "Entertainer's Pack"))),
                    Group("instrument", "Musical instrument",
                        FixedOption("a", "Lute", G("Lute")),
                        SlotOption("b", "Any other musical instrument", Slot("instrument", "Choose musical instrument", MusicalInstruments.Where(x => !x.Equals("Lute", StringComparison.OrdinalIgnoreCase)).ToArray())))
                }),

            "cleric" => Plan("Class", "Cleric", 0,
                fixedGrants: new[] { G("Shield"), G("Holy Symbol") },
                groups: new[]
                {
                    Group("weapon", "Melee weapon",
                        FixedOption("a", "Mace", G("Mace")),
                        FixedOption("b", "Warhammer (if proficient)", G("Warhammer"))),
                    Group("armor", "Armor",
                        FixedOption("a", "Scale Mail", G("Scale Mail")),
                        FixedOption("b", "Leather Armor", G("Leather Armor")),
                        FixedOption("c", "Chain Mail (if proficient)", G("Chain Mail"))),
                    Group("ranged_or_simple", "Additional weapon",
                        FixedOption("a", "Light Crossbow + 20 bolts", G("Light Crossbow"), G("Crossbow Bolt", 20)),
                        SlotOption("b", "Any simple weapon", Slot("weapon", "Choose simple weapon", SimpleWeapons()))),
                    Group("pack", "Equipment pack",
                        FixedOption("a", "Priest's Pack", Pack("priest", "Priest's Pack")),
                        FixedOption("b", "Explorer's Pack", Pack("explorer", "Explorer's Pack")))
                }),

            "druid" => Plan("Class", "Druid", 0,
                fixedGrants: new[] { G("Leather Armor"), Pack("explorer", "Explorer's Pack"), G("Druidic Focus") },
                groups: new[]
                {
                    Group("shield_or_simple", "Shield or simple weapon",
                        FixedOption("a", "Wooden Shield", G("Wooden Shield")),
                        SlotOption("b", "Any simple weapon", Slot("weapon", "Choose simple weapon", SimpleWeapons()))),
                    Group("melee_weapon", "Melee weapon",
                        FixedOption("a", "Scimitar", G("Scimitar")),
                        SlotOption("b", "Any simple melee weapon", Slot("weapon", "Choose simple melee weapon", SimpleMeleeWeapons)))
                }),

            "fighter" => Plan("Class", "Fighter", 0,
                fixedGrants: Array.Empty<StartingEquipment2014Grant>(),
                groups: new[]
                {
                    Group("armor", "Armor and ranged equipment",
                        FixedOption("a", "Chain Mail", G("Chain Mail")),
                        FixedOption("b", "Leather Armor + Longbow + 20 arrows", G("Leather Armor"), G("Longbow"), G("Arrow", 20))),
                    Group("martial_weapons", "Martial weapon loadout",
                        SlotOptionWithGrants("a", "Martial weapon + Shield", new[] { G("Shield") }, Slot("weapon", "Choose martial weapon", MartialWeapons())),
                        SlotOption("b", "Two martial weapons",
                            Slot("weapon1", "Choose first martial weapon", MartialWeapons()),
                            Slot("weapon2", "Choose second martial weapon", MartialWeapons()))),
                    Group("extra_weapon", "Additional weapon",
                        FixedOption("a", "Light Crossbow + 20 bolts", G("Light Crossbow"), G("Crossbow Bolt", 20)),
                        FixedOption("b", "Two Handaxes", G("Handaxe", 2))),
                    Group("pack", "Equipment pack",
                        FixedOption("a", "Dungeoneer's Pack", Pack("dungeoneer", "Dungeoneer's Pack")),
                        FixedOption("b", "Explorer's Pack", Pack("explorer", "Explorer's Pack")))
                }),

            "monk" => Plan("Class", "Monk", 0,
                fixedGrants: new[] { G("Dart", 10) },
                groups: new[]
                {
                    Group("weapon", "Weapon",
                        FixedOption("a", "Shortsword", G("Shortsword")),
                        SlotOption("b", "Any simple weapon", Slot("weapon", "Choose simple weapon", SimpleWeapons()))),
                    Group("pack", "Equipment pack",
                        FixedOption("a", "Dungeoneer's Pack", Pack("dungeoneer", "Dungeoneer's Pack")),
                        FixedOption("b", "Explorer's Pack", Pack("explorer", "Explorer's Pack")))
                }),

            "paladin" => Plan("Class", "Paladin", 0,
                fixedGrants: new[] { G("Chain Mail"), G("Holy Symbol") },
                groups: new[]
                {
                    Group("martial_weapons", "Martial weapon loadout",
                        SlotOptionWithGrants("a", "Martial weapon + Shield", new[] { G("Shield") }, Slot("weapon", "Choose martial weapon", MartialWeapons())),
                        SlotOption("b", "Two martial weapons",
                            Slot("weapon1", "Choose first martial weapon", MartialWeapons()),
                            Slot("weapon2", "Choose second martial weapon", MartialWeapons()))),
                    Group("extra_weapon", "Additional weapon",
                        FixedOption("a", "Five Javelins", G("Javelin", 5)),
                        SlotOption("b", "Any simple melee weapon", Slot("weapon", "Choose simple melee weapon", SimpleMeleeWeapons))),
                    Group("pack", "Equipment pack",
                        FixedOption("a", "Priest's Pack", Pack("priest", "Priest's Pack")),
                        FixedOption("b", "Explorer's Pack", Pack("explorer", "Explorer's Pack")))
                }),

            "ranger" => Plan("Class", "Ranger", 0,
                fixedGrants: new[] { G("Longbow"), G("Quiver"), G("Arrow", 20) },
                groups: new[]
                {
                    Group("armor", "Armor",
                        FixedOption("a", "Scale Mail", G("Scale Mail")),
                        FixedOption("b", "Leather Armor", G("Leather Armor"))),
                    Group("melee_weapons", "Melee weapons",
                        FixedOption("a", "Two Shortswords", G("Shortsword", 2)),
                        SlotOption("b", "Two simple melee weapons",
                            Slot("weapon1", "Choose first simple melee weapon", SimpleMeleeWeapons),
                            Slot("weapon2", "Choose second simple melee weapon", SimpleMeleeWeapons))),
                    Group("pack", "Equipment pack",
                        FixedOption("a", "Dungeoneer's Pack", Pack("dungeoneer", "Dungeoneer's Pack")),
                        FixedOption("b", "Explorer's Pack", Pack("explorer", "Explorer's Pack")))
                }),

            "rogue" => Plan("Class", "Rogue", 0,
                fixedGrants: new[] { G("Leather Armor"), G("Dagger", 2), G("Thieves' Tools") },
                groups: new[]
                {
                    Group("primary_weapon", "Primary weapon",
                        FixedOption("a", "Rapier", G("Rapier")),
                        FixedOption("b", "Shortsword", G("Shortsword"))),
                    Group("secondary_weapon", "Secondary weapon",
                        FixedOption("a", "Shortbow + Quiver + 20 arrows", G("Shortbow"), G("Quiver"), G("Arrow", 20)),
                        FixedOption("b", "Shortsword", G("Shortsword"))),
                    Group("pack", "Equipment pack",
                        FixedOption("a", "Burglar's Pack", Pack("burglar", "Burglar's Pack")),
                        FixedOption("b", "Dungeoneer's Pack", Pack("dungeoneer", "Dungeoneer's Pack")),
                        FixedOption("c", "Explorer's Pack", Pack("explorer", "Explorer's Pack")))
                }),

            "sorcerer" => Plan("Class", "Sorcerer", 0,
                fixedGrants: new[] { G("Dagger", 2) },
                groups: new[]
                {
                    Group("weapon", "Weapon",
                        FixedOption("a", "Light Crossbow + 20 bolts", G("Light Crossbow"), G("Crossbow Bolt", 20)),
                        SlotOption("b", "Any simple weapon", Slot("weapon", "Choose simple weapon", SimpleWeapons()))),
                    Group("focus", "Spellcasting focus",
                        FixedOption("a", "Component Pouch", G("Component Pouch")),
                        FixedOption("b", "Arcane Focus", G("Arcane Focus"))),
                    Group("pack", "Equipment pack",
                        FixedOption("a", "Dungeoneer's Pack", Pack("dungeoneer", "Dungeoneer's Pack")),
                        FixedOption("b", "Explorer's Pack", Pack("explorer", "Explorer's Pack")))
                }),

            "warlock" => Plan("Class", "Warlock", 0,
                fixedGrants: new[] { G("Leather Armor"), G("Dagger", 2) },
                groups: new[]
                {
                    Group("weapon", "Weapon",
                        FixedOption("a", "Light Crossbow + 20 bolts", G("Light Crossbow"), G("Crossbow Bolt", 20)),
                        SlotOption("b", "Any simple weapon", Slot("weapon", "Choose simple weapon", SimpleWeapons()))),
                    Group("focus", "Spellcasting focus",
                        FixedOption("a", "Component Pouch", G("Component Pouch")),
                        FixedOption("b", "Arcane Focus", G("Arcane Focus"))),
                    Group("pack", "Equipment pack",
                        FixedOption("a", "Scholar's Pack", Pack("scholar", "Scholar's Pack")),
                        FixedOption("b", "Dungeoneer's Pack", Pack("dungeoneer", "Dungeoneer's Pack"))),
                    Group("additional_simple_weapon", "Additional simple weapon",
                        SlotOption("choose", "Choose any simple weapon", Slot("weapon", "Choose simple weapon", SimpleWeapons())))
                }),

            "wizard" => Plan("Class", "Wizard", 0,
                fixedGrants: new[] { G("Spellbook") },
                groups: new[]
                {
                    Group("weapon", "Weapon",
                        FixedOption("a", "Quarterstaff", G("Quarterstaff")),
                        FixedOption("b", "Dagger", G("Dagger"))),
                    Group("focus", "Spellcasting focus",
                        FixedOption("a", "Component Pouch", G("Component Pouch")),
                        FixedOption("b", "Arcane Focus", G("Arcane Focus"))),
                    Group("pack", "Equipment pack",
                        FixedOption("a", "Scholar's Pack", Pack("scholar", "Scholar's Pack")),
                        FixedOption("b", "Explorer's Pack", Pack("explorer", "Explorer's Pack")))
                }),

            _ => null
        };
    }

    public static StartingEquipment2014Plan? GetBackgroundPlan(string? backgroundName)
    {
        var rulesName = ResolveBackgroundRulesName(backgroundName);
        return Normalize(rulesName) switch
        {
            "acolyte" => Plan("Background", "Acolyte", 15,
                fixedGrants: new[] { G("Holy Symbol"), G("Incense Stick", 5), G("Vestments"), G("Common Clothes"), G("Pouch") },
                groups: new[] { Group("devotional_text", "Devotional text", FixedOption("a", "Prayer Book", G("Prayer Book")), FixedOption("b", "Prayer Wheel", G("Prayer Wheel"))) }),

            "charlatan" => Plan("Background", "Charlatan", 15,
                fixedGrants: new[] { G("Fine Clothes"), G("Disguise Kit"), G("Pouch") },
                groups: new[]
                {
                    Group("con_tool", "Tools of the con",
                        FixedOption("bottles", "10 stoppered bottles of colored liquid", G("Stoppered Bottle of Colored Liquid", 10)),
                        FixedOption("weighted_dice", "Weighted Dice", G("Weighted Dice")),
                        FixedOption("marked_cards", "Marked Playing Cards", G("Marked Playing Cards")),
                        FixedOption("imaginary_signet", "Signet Ring of an Imaginary Duke", G("Signet Ring of an Imaginary Duke")))
                }),

            "criminal" => Plan("Background", "Criminal", 15,
                fixedGrants: new[] { G("Crowbar"), G("Dark Common Clothes with Hood"), G("Pouch") },
                groups: Array.Empty<StartingEquipment2014ChoiceGroup>()),

            "entertainer" => Plan("Background", "Entertainer", 15,
                fixedGrants: new[] { G("Costume"), G("Pouch") },
                groups: new[]
                {
                    DirectGroup("instrument", "Musical instrument", MusicalInstruments),
                    Group("admirer_favor", "Favor of an admirer",
                        FixedOption("letter", "Love Letter", G("Love Letter")),
                        FixedOption("hair", "Lock of Hair", G("Lock of Hair")),
                        FixedOption("trinket", "Trinket", G("Admirer's Trinket")))
                }),

            "folk hero" => Plan("Background", "Folk Hero", 10,
                fixedGrants: new[] { G("Shovel"), G("Iron Pot"), G("Common Clothes"), G("Pouch") },
                groups: new[] { DirectGroup("artisan_tools", "Artisan's tools", ArtisanTools) }),

            "guild artisan" => Plan("Background", "Guild Artisan", 15,
                fixedGrants: new[] { G("Letter of Introduction"), G("Traveler's Clothes"), G("Pouch") },
                groups: new[] { DirectGroup("artisan_tools", "Artisan's tools", ArtisanTools) }),

            "hermit" => Plan("Background", "Hermit", 5,
                fixedGrants: new[] { G("Scroll Case with Notes and Prayers"), G("Winter Blanket"), G("Common Clothes"), G("Herbalism Kit"), G("Pouch") },
                groups: Array.Empty<StartingEquipment2014ChoiceGroup>()),

            "noble" => Plan("Background", "Noble", 25,
                fixedGrants: new[] { G("Fine Clothes"), G("Signet Ring"), G("Scroll of Pedigree"), G("Purse") },
                groups: Array.Empty<StartingEquipment2014ChoiceGroup>()),

            "outlander" => Plan("Background", "Outlander", 10,
                fixedGrants: new[] { G("Staff"), G("Hunting Trap"), G("Trophy from an Animal"), G("Traveler's Clothes"), G("Pouch") },
                groups: Array.Empty<StartingEquipment2014ChoiceGroup>()),

            "sage" => Plan("Background", "Sage", 10,
                fixedGrants: new[] { G("Bottle of Black Ink"), G("Quill"), G("Small Knife"), G("Letter from a Dead Colleague"), G("Common Clothes"), G("Pouch") },
                groups: Array.Empty<StartingEquipment2014ChoiceGroup>()),

            "sailor" => Plan("Background", "Sailor", 10,
                fixedGrants: new[] { G("Belaying Pin (Club)"), G("Silk Rope (50 feet)"), G("Lucky Charm"), G("Common Clothes"), G("Pouch") },
                groups: Array.Empty<StartingEquipment2014ChoiceGroup>()),

            "soldier" => Plan("Background", "Soldier", 10,
                fixedGrants: new[] { G("Insignia of Rank"), G("Trophy from a Fallen Enemy"), G("Common Clothes"), G("Pouch") },
                groups: new[]
                {
                    Group("gaming_set", "Gaming set",
                        FixedOption("bone_dice", "Bone Dice", G("Bone Dice")),
                        FixedOption("playing_cards", "Deck of Playing Cards", G("Playing Cards")))
                }),

            "urchin" => Plan("Background", "Urchin", 10,
                fixedGrants: new[] { G("Small Knife"), G("Map of Home City"), G("Pet Mouse"), G("Token from Parents"), G("Common Clothes"), G("Pouch") },
                groups: Array.Empty<StartingEquipment2014ChoiceGroup>()),

            _ => null
        };
    }

    public static string ResolveBackgroundRulesName(string? backgroundName)
    {
        var raw = (backgroundName ?? string.Empty).Trim();
        if (BackgroundAliases.TryGetValue(raw, out var mapped)) return mapped;
        return LegacyBackgroundNames.FirstOrDefault(x => x.Equals(raw, StringComparison.OrdinalIgnoreCase)) ?? raw;
    }

    public static object ToClientPlan(StartingEquipment2014Plan plan)
    {
        return new
        {
            sourceName = plan.SourceName,
            rulesName = plan.RulesName,
            gold = plan.Gold,
            fixedItems = Expand(plan.FixedGrants).Select(ToClientItem),
            choiceGroups = plan.ChoiceGroups.Select(group => new
            {
                key = group.Key,
                label = group.Label,
                options = group.Options.Select(option => new
                {
                    key = option.Key,
                    label = option.Label,
                    items = Expand(option.Grants).Select(ToClientItem),
                    slots = option.Slots.Select(slot => new
                    {
                        key = slot.Key,
                        label = slot.Label,
                        options = slot.Options.Select(slotOption => new
                        {
                            key = slotOption.Key,
                            label = slotOption.Label,
                            items = Expand(slotOption.Grants).Select(ToClientItem)
                        })
                    })
                })
            })
        };
    }

    public static List<StartingEquipment2014ResolvedItem> ResolveSelections(
        StartingEquipment2014Plan plan, JsonElement body, string propertyName)
    {
        var grants = new List<StartingEquipment2014Grant>();
        grants.AddRange(plan.FixedGrants);

        JsonElement selectionRoot = default;
        if (body.ValueKind == JsonValueKind.Object && body.TryGetProperty(propertyName, out var candidate) && candidate.ValueKind == JsonValueKind.Object)
            selectionRoot = candidate;

        foreach (var group in plan.ChoiceGroups)
        {
            if (selectionRoot.ValueKind != JsonValueKind.Object || !selectionRoot.TryGetProperty(group.Key, out var selection) || selection.ValueKind != JsonValueKind.Object)
                throw new InvalidOperationException($"Choose an option for {plan.RulesName}: {group.Label}.");

            var optionKey = ReadString(selection, "optionKey");
            var option = group.Options.FirstOrDefault(x => x.Key.Equals(optionKey, StringComparison.OrdinalIgnoreCase));
            if (option is null)
                throw new InvalidOperationException($"The selected option for {group.Label} is not valid.");

            grants.AddRange(option.Grants);

            JsonElement slotsRoot = default;
            if (selection.TryGetProperty("slots", out var slots) && slots.ValueKind == JsonValueKind.Object) slotsRoot = slots;
            foreach (var slot in option.Slots)
            {
                if (slotsRoot.ValueKind != JsonValueKind.Object || !slotsRoot.TryGetProperty(slot.Key, out var selectedSlot))
                    throw new InvalidOperationException($"Choose {slot.Label}.");
                var selectedKey = selectedSlot.ValueKind == JsonValueKind.String ? selectedSlot.GetString() ?? string.Empty : string.Empty;
                var selectedOption = slot.Options.FirstOrDefault(x => x.Key.Equals(selectedKey, StringComparison.OrdinalIgnoreCase));
                if (selectedOption is null) throw new InvalidOperationException($"The selection for {slot.Label} is not valid.");
                grants.AddRange(selectedOption.Grants);
            }
        }

        return Expand(grants)
            .GroupBy(x => $"{x.ItemName}\u001F{x.Origin}", StringComparer.OrdinalIgnoreCase)
            .Select(g => new StartingEquipment2014ResolvedItem(g.First().ItemName, g.Sum(x => x.Quantity), g.First().Origin))
            .OrderBy(x => x.Origin)
            .ThenBy(x => x.ItemName)
            .ToList();
    }

    public static bool ShouldStartEquipped(string? itemName)
    {
        var normalized = Normalize(itemName);
        return normalized.Contains("armor") || normalized is "chain mail" or "chain shirt" or "scale mail" or "shield" or "wooden shield";
    }

    private static object ToClientItem(StartingEquipment2014ResolvedItem item) => new { itemName = item.ItemName, quantity = item.Quantity, origin = item.Origin };

    private static List<StartingEquipment2014ResolvedItem> Expand(IEnumerable<StartingEquipment2014Grant> grants)
    {
        var result = new List<StartingEquipment2014ResolvedItem>();
        foreach (var grant in grants) ExpandGrant(grant, result, grant.Origin);
        return result;
    }

    private static void ExpandGrant(StartingEquipment2014Grant grant, List<StartingEquipment2014ResolvedItem> result, string inheritedOrigin)
    {
        var origin = string.IsNullOrWhiteSpace(grant.Origin) ? inheritedOrigin : grant.Origin;
        var quantity = Math.Max(1, grant.Quantity);
        if (!string.IsNullOrWhiteSpace(grant.BundleKey))
        {
            if (!Packs.TryGetValue(grant.BundleKey, out var pack)) throw new InvalidOperationException($"Unknown equipment pack: {grant.BundleKey}");
            var packOrigin = string.IsNullOrWhiteSpace(origin) ? grant.ItemName : origin;
            for (var i = 0; i < quantity; i++)
                foreach (var nested in pack) ExpandGrant(nested with { Origin = packOrigin }, result, packOrigin);
            return;
        }
        if (!string.IsNullOrWhiteSpace(grant.ItemName)) result.Add(new StartingEquipment2014ResolvedItem(grant.ItemName, quantity, origin));
    }

    private static StartingEquipment2014Plan Plan(string source, string rulesName, decimal gold,
        IReadOnlyList<StartingEquipment2014Grant> fixedGrants, IReadOnlyList<StartingEquipment2014ChoiceGroup> groups) =>
        new(source, rulesName, gold, fixedGrants, groups);

    private static StartingEquipment2014ChoiceGroup Group(string key, string label, params StartingEquipment2014Option[] options) => new(key, label, options);

    private static StartingEquipment2014ChoiceGroup DirectGroup(string key, string label, IEnumerable<string> itemNames) =>
        Group(key, label, itemNames.Select(name => FixedOption(Key(name), name, G(name))).ToArray());

    private static StartingEquipment2014Option FixedOption(string key, string label, params StartingEquipment2014Grant[] grants) =>
        new(key, label, grants, Array.Empty<StartingEquipment2014Slot>());

    private static StartingEquipment2014Option SlotOption(string key, string label, params StartingEquipment2014Slot[] slots) =>
        new(key, label, Array.Empty<StartingEquipment2014Grant>(), slots);

    private static StartingEquipment2014Option SlotOptionWithGrants(string key, string label, IReadOnlyList<StartingEquipment2014Grant> grants, params StartingEquipment2014Slot[] slots) =>
        new(key, label, grants, slots);

    private static StartingEquipment2014Slot Slot(string key, string label, IEnumerable<string> choices) =>
        new(key, label, choices.Select(name => FixedOption(Key(name), name, G(name))).ToArray());

    private static StartingEquipment2014Grant G(string itemName, int quantity = 1) => new(itemName, quantity);
    private static StartingEquipment2014Grant Pack(string key, string displayName) => new(displayName, 1, key, displayName);

    private static string[] SimpleWeapons() => SimpleMeleeWeapons.Concat(SimpleRangedWeapons).ToArray();
    private static string[] MartialWeapons() => MartialMeleeWeapons.Concat(MartialRangedWeapons).ToArray();

    private static string ReadString(JsonElement obj, string propertyName)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(propertyName, out var value) && value.ValueKind == JsonValueKind.String)
            return value.GetString()?.Trim() ?? string.Empty;
        return string.Empty;
    }

    private static string Key(string value)
    {
        var chars = (value ?? string.Empty).Trim().ToLowerInvariant().Select(ch => char.IsLetterOrDigit(ch) ? ch : '_').ToArray();
        var key = string.Join('_', new string(chars).Split('_', StringSplitOptions.RemoveEmptyEntries));
        return key.Length == 0 ? "choice" : key;
    }

    private static string Normalize(string? value) => (value ?? string.Empty).Trim().ToLowerInvariant();
}
