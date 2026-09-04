using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

public static class MonsterLootCatalogService
{
    public sealed record LootEntry(string ItemName, int Quantity, string Description);

    public static IReadOnlyList<LootEntry> Build(string monsterName, string? codexDetails, int maxHp)
    {
        var name = (monsterName ?? string.Empty).Trim();
        var lowerName = name.ToLowerInvariant();
        var details = (codexDetails ?? string.Empty).ToLowerInvariant();
        var text = lowerName + "\n" + details;
        var size = DetectSize(details);
        var meat = MeatQuantity(size, maxHp);
        var list = new List<LootEntry>();

        void Add(string item, int qty, string description)
        {
            if (qty <= 0 || string.IsNullOrWhiteSpace(item)) return;
            var existing = list.FindIndex(x => x.ItemName.Equals(item, StringComparison.OrdinalIgnoreCase));
            if (existing >= 0)
            {
                var old = list[existing];
                list[existing] = old with { Quantity = old.Quantity + qty };
            }
            else list.Add(new LootEntry(item, qty, description));
        }

        bool Has(params string[] terms) => terms.Any(t => text.Contains(t, StringComparison.OrdinalIgnoreCase));
        bool Type(string term) => Regex.IsMatch(details, $@"\b{Regex.Escape(term)}\b", RegexOptions.IgnoreCase);

        // Mundane gear explicitly named in the trusted Codex/stat block is also expected loot.
        // This is source-derived evidence, never a player claim. Natural attacks (claw/bite/etc.)
        // are intentionally excluded because anatomy is handled by the creature-family tables below.
        var expectedGear = new (string Pattern, string Item)[]
        {
            (@"\blongsword\b", "Longsword"), (@"\bshortsword\b", "Shortsword"),
            (@"\bgreatsword\b", "Greatsword"), (@"\bscimitar\b", "Scimitar"),
            (@"\brapier\b", "Rapier"), (@"\bdagger\b", "Dagger"),
            (@"\bspear\b", "Spear"), (@"\bjavelin\b", "Javelin"),
            (@"\bhandaxe\b", "Handaxe"), (@"\bgreataxe\b", "Greataxe"),
            (@"\bbattleaxe\b", "Battleaxe"), (@"\bwarhammer\b", "Warhammer"),
            (@"\bmace\b", "Mace"), (@"\bgreatclub\b", "Greatclub"),
            (@"\bclub\b", "Club"), (@"\bquarterstaff\b", "Quarterstaff"),
            (@"\btrident\b", "Trident"), (@"\bwhip\b", "Whip"),
            (@"\bglaive\b", "Glaive"), (@"\bhalberd\b", "Halberd"),
            (@"\bshortbow\b", "Shortbow"), (@"\blongbow\b", "Longbow"),
            (@"\bhand crossbow\b", "Hand Crossbow"), (@"\blight crossbow\b", "Light Crossbow"),
            (@"\bheavy crossbow\b", "Heavy Crossbow"), (@"\bshield\b", "Shield"),
            (@"\bchain mail\b", "Chain Mail"), (@"\bchain shirt\b", "Chain Shirt"),
            (@"\bstudded leather\b", "Studded Leather Armor"), (@"\bleather armor\b", "Leather Armor"),
            (@"\bplate armor\b", "Plate Armor"), (@"\bhalf plate\b", "Half Plate Armor"),
            (@"\bscale mail\b", "Scale Mail")
        };
        foreach (var (pattern, item) in expectedGear)
            if (Regex.IsMatch(details, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                Add(item, 1, "Mundane carried/equipped gear explicitly supported by the trusted monster Codex/stat block.");
        if (Regex.IsMatch(details, @"\b(shortbow|longbow)\b", RegexOptions.IgnoreCase))
            Add("Arrow", 10, "A conservative expected amount of ammunition carried with the stat-block bow.");
        if (Regex.IsMatch(details, @"\b(hand crossbow|light crossbow|heavy crossbow)\b", RegexOptions.IgnoreCase))
            Add("Crossbow Bolt", 10, "A conservative expected amount of ammunition carried with the stat-block crossbow.");

        // Non-biological creature families get material remains instead of generic meat.
        if (Type("construct") || Has("animated armor", "flying sword", "shield guardian", "golem", "homunculus"))
        {
            Add($"{name} Construct Components", Math.Max(1, SizeUnits(size)), "Salvageable magical/mechanical components from the defeated construct.");
            Add("Arcane Scrap", Math.Max(1, SizeUnits(size) / 2), "Metal, stone, wood, cloth, crystal, or other animated construction material.");
            return list;
        }

        if (Type("elemental") || Has("elemental", "mephit", "magmin"))
        {
            Add($"{name} Elemental Essence", Math.Max(1, SizeUnits(size)), "Residual elemental material or condensed essence.");
            if (Has("fire", "magma", "lava")) Add("Cinder Core", 1, "Heat-scarred elemental core material.");
            else if (Has("ice", "frost", "cold")) Add("Frost Crystal", Math.Max(1, SizeUnits(size) / 2), "Cold elemental crystal residue.");
            else if (Has("earth", "stone", "rock")) Add("Elemental Stone", Math.Max(1, SizeUnits(size)), "Dense stone charged with elemental energy.");
            else if (Has("air", "dust")) Add("Elemental Dust", Math.Max(1, SizeUnits(size)), "Fine residue carrying faint elemental energy.");
            else if (Has("water")) Add("Elemental Water Essence", Math.Max(1, SizeUnits(size)), "Stable water-elemental residue.");
            return list;
        }

        if (Type("ooze") || Has("gelatinous cube", "ochre jelly", "slime", "ooze"))
        {
            Add($"{name} Ooze Residue", Math.Max(1, SizeUnits(size) * 2), "Recoverable alchemical slime or gelatin left by the creature.");
            Add("Ooze Membrane", Math.Max(1, SizeUnits(size) / 2), "Tough translucent membrane suitable for alchemical use.");
            return list;
        }

        if (Type("undead") || Has("skeleton", "zombie", "mummy", "specter", "ghost", "wraith", "flameskull"))
        {
            if (Has("specter", "ghost", "wraith", "phantom", "incorporeal"))
                Add("Ectoplasmic Residue", Math.Max(1, SizeUnits(size)), "Faint spiritual residue left after the undead is destroyed.");
            else
            {
                Add($"{name} Bones", Math.Max(1, SizeUnits(size) * 2), "Recoverable bones from the defeated undead.");
                Add("Grave Dust", Math.Max(1, SizeUnits(size)), "Dust and funerary residue clinging to the remains.");
            }
            return list;
        }

        if (Type("plant") || Has("treant", "blight", "shambling mound", "plant"))
        {
            Add($"{name} Plant Fiber", Math.Max(1, SizeUnits(size) * 2), "Usable fibers, vines, bark, or woody tissue.");
            Add($"{name} Sap", Math.Max(1, SizeUnits(size)), "Recoverable sap or resin.");
            Add($"{name} Seeds/Spores", Math.Max(1, SizeUnits(size) / 2), "Seeds, spores, or reproductive material where present.");
            return list;
        }

        // Dragons and draconic reptiles always have the classic harvestable anatomy.
        if (Type("dragon") || Has("dragon", "wyvern", "drake"))
        {
            Add($"Raw {name} Meat (1 lb)", meat, "Fresh monster meat; requires preparation before eating.");
            Add($"{name} Scales", Math.Max(4, SizeUnits(size) * 8), "Usable scales harvested from the hide.");
            Add($"{name} Claw", Math.Max(2, SizeUnits(size) * 2), "Hard claw or talon.");
            Add($"{name} Fang", Math.Max(2, SizeUnits(size) * 2), "Large tooth or fang.");
            Add($"{name} Bone", Math.Max(2, SizeUnits(size) * 3), "Dense draconic bone.");
            return list;
        }

        // Arthropods and similar chitinous creatures.
        if (Has("spider", "scorpion", "centipede", "beetle", "insect", "crab", "lobster", "crawling claw"))
        {
            Add($"{name} Chitin", Math.Max(2, SizeUnits(size) * 3), "Hard plates of chitin from the creature's shell/exoskeleton.");
            Add($"{name} Meat (1 lb)", Math.Max(1, meat / 2), "Edible tissue if properly prepared.");
            if (Has("spider", "scorpion", "venom", "poison")) Add($"{name} Venom Sac", 1, "Intact venom-producing organ; hazardous if mishandled.");
            if (Has("scorpion")) Add($"{name} Stinger", 1, "Harvested stinger.");
            else Add($"{name} Mandible", 2, "Hard biting mouthpart.");
            return list;
        }

        // Aquatic creatures.
        if (Has("shark", "fish", "piranha", "seahorse", "eel"))
        {
            Add($"Raw {name} Meat (1 lb)", meat, "Fresh fish/monster meat.");
            Add($"{name} Scales/Skin", Math.Max(1, SizeUnits(size) * 2), "Skin or scales from the creature.");
            if (Has("shark", "piranha")) Add($"{name} Tooth", Math.Max(4, SizeUnits(size) * 4), "Sharp tooth.");
            Add($"{name} Bone", Math.Max(1, SizeUnits(size)), "Recoverable bone or cartilage.");
            return list;
        }
        if (Has("octopus", "squid", "kraken"))
        {
            Add($"Raw {name} Meat (1 lb)", meat, "Fresh cephalopod/monster meat.");
            Add($"{name} Tentacle", Math.Max(2, SizeUnits(size) * 2), "Harvested tentacle section.");
            Add($"{name} Ink Sac", 1, "Intact ink-producing organ where present.");
            return list;
        }
        if (Has("turtle", "archelon", "snail"))
        {
            Add($"Raw {name} Meat (1 lb)", meat, "Fresh monster meat.");
            Add($"{name} Shell", Math.Max(1, SizeUnits(size)), "Shell plates or usable shell material.");
            return list;
        }

        // Birds and feathered creatures.
        if (Has("eagle", "owl", "hawk", "raven", "crow", "vulture", "bird", "roc", "stirge", "hippogriff"))
        {
            Add($"Raw {name} Meat (1 lb)", Math.Max(1, meat / 2), "Fresh monster meat.");
            Add($"{name} Feather", Math.Max(4, SizeUnits(size) * 6), "Usable feathers.");
            Add($"{name} Talon", Math.Max(2, SizeUnits(size) * 2), "Sharp talon.");
            Add($"{name} Beak", 1, "Harvested beak.");
            return list;
        }

        // Amphibians.
        if (Has("frog", "toad", "amphibian"))
        {
            Add($"Raw {name} Meat (1 lb)", Math.Max(1, meat / 2), "Fresh amphibian/monster meat; requires safe preparation.");
            Add($"{name} Skin", Math.Max(1, SizeUnits(size)), "Harvested amphibian skin.");
            if (Has("poison", "venom")) Add($"{name} Poison Gland", 1, "Toxic gland; hazardous if mishandled.");
            return list;
        }

        // Reptiles and scaled terrestrial creatures.
        if (Has("snake", "lizard", "crocodile", "alligator", "dinosaur", "allosaurus", "ankylosaurus", "pteranodon", "salamander", "naga", "hydra"))
        {
            Add($"Raw {name} Meat (1 lb)", meat, "Fresh monster meat; requires preparation before eating.");
            Add($"{name} Scales/Skin", Math.Max(2, SizeUnits(size) * 3), "Usable scaled hide or skin.");
            Add($"{name} Fang/Tooth", Math.Max(2, SizeUnits(size) * 2), "Sharp fang or tooth.");
            if (Has("venom", "poison", "snake", "naga")) Add($"{name} Venom Gland", 1, "Venom-producing organ; hazardous if mishandled.");
            if (!Has("snake")) Add($"{name} Claw", Math.Max(2, SizeUnits(size) * 2), "Harvested claw.");
            return list;
        }

        // Mammalian beasts/monstrosities with expected hide/pelt.
        if (Type("beast") || Has("wolf", "bear", "lion", "tiger", "panther", "mastiff", "dog", "cat", "boar", "horse", "elk", "deer", "mammoth", "ape", "rat", "weasel", "hyena", "owlbear", "manticore", "hippopotamus"))
        {
            Add($"Raw {name} Meat (1 lb)", meat, "Fresh monster meat; requires preparation before eating.");
            Add($"{name} Pelt/Hide", 1, "Usable pelt, skin, or hide from this individual creature.");
            Add($"{name} Bone", Math.Max(2, SizeUnits(size) * 2), "Recoverable bone.");
            if (Has("wolf", "bear", "lion", "tiger", "panther", "mastiff", "dog", "cat", "hyena", "owlbear", "manticore"))
            {
                Add($"{name} Claw", Math.Max(2, SizeUnits(size) * 2), "Harvested claw.");
                Add($"{name} Fang", Math.Max(2, SizeUnits(size) * 2), "Harvested fang.");
            }
            if (Has("mammoth", "elephant")) Add($"{name} Tusk", 2, "Harvested tusk.");
            if (Has("elk", "deer")) Add($"{name} Antler", 2, "Harvested antler.");
            return list;
        }

        // Unusual corporeal monstrosities still have a conservative biological harvest.
        if (Type("monstrosity"))
        {
            Add($"Raw {name} Meat (1 lb)", meat, "Fresh monster tissue; edibility depends on creature and preparation.");
            Add($"{name} Hide/Skin", Math.Max(1, SizeUnits(size)), "Harvestable outer hide or skin.");
            Add($"{name} Bone/Hard Tissue", Math.Max(2, SizeUnits(size) * 2), "Recoverable bone or hard anatomical material.");
            Add($"{name} Claw/Tooth", Math.Max(2, SizeUnits(size)), "Harvestable claw, tooth, spine, or similar hard natural weapon where present.");
            return list;
        }

        // Fiends, celestials, fey and aberrations are often corporeal but may not be ordinary food.
        if (Type("fiend") || Type("celestial") || Type("fey") || Type("aberration"))
        {
            Add($"{name} Hide/Skin", Math.Max(1, SizeUnits(size)), "Recoverable outer tissue from the defeated creature.");
            Add($"{name} Bone", Math.Max(1, SizeUnits(size) * 2), "Recoverable bone or hard internal structure.");
            if (Has("horn", "devil", "demon", "minotaur")) Add($"{name} Horn", Math.Max(1, SizeUnits(size)), "Harvested horn.");
            if (Has("fang", "bite", "devil", "demon", "hag")) Add($"{name} Fang/Tooth", Math.Max(2, SizeUnits(size)), "Harvested tooth or fang.");
            if (Has("claw", "talon", "devil", "demon", "hag")) Add($"{name} Claw/Talon", Math.Max(2, SizeUnits(size)), "Harvested claw or talon.");
            if (Type("aberration") || Has("beholder", "otyugh", "grick")) Add($"{name} Aberrant Organ", Math.Max(1, SizeUnits(size)), "Unusual organ or tissue of possible alchemical interest.");
            return list;
        }

        // Humanoids and giants get plausible physical remains/personal effects. Mundane gear
        // explicitly supported by the trusted Codex was already added above. Coins and any
        // unlisted valuables are never invented.
        if (Type("humanoid") || Type("giant") || Has("goblin", "hobgoblin", "bugbear", "orc", "ogre", "giant", "pirate", "guard", "warrior", "mage", "druid", "noble"))
        {
            Add($"{name} Personal Effects", 1, "Non-valuable ordinary personal effects. Specific weapons, armor, valuables, or coins are not assumed by this biological loot table.");
            Add($"{name} Bone", Math.Max(1, SizeUnits(size) * 2), "Physical remains if harvesting is attempted and the campaign context permits it.");
            return list;
        }

        // Universal fallback: every defeated monster still has an expected, non-invented remains profile.
        Add($"{name} Remains", Math.Max(1, SizeUnits(size)), "Recognizable remains from the defeated creature. The GM must not invent valuables that are not in an authoritative loot source.");
        if (!Has("incorporeal")) Add($"{name} Bone/Hard Tissue", Math.Max(1, SizeUnits(size)), "Recoverable hard tissue, bone, shell, or similar material where anatomically present.");
        return list;
    }

    private static string DetectSize(string details)
    {
        foreach (var size in new[] { "Gargantuan", "Huge", "Large", "Medium", "Small", "Tiny" })
            if (Regex.IsMatch(details ?? string.Empty, $@"\b{size}\b", RegexOptions.IgnoreCase)) return size;
        return "Medium";
    }

    private static int SizeUnits(string size) => size switch
    {
        "Tiny" => 1,
        "Small" => 1,
        "Medium" => 2,
        "Large" => 4,
        "Huge" => 8,
        "Gargantuan" => 16,
        _ => 2
    };

    private static int MeatQuantity(string size, int maxHp)
    {
        var bySize = size switch
        {
            "Tiny" => 1,
            "Small" => 4,
            "Medium" => 12,
            "Large" => 35,
            "Huge" => 90,
            "Gargantuan" => 220,
            _ => 12
        };
        if (maxHp <= 0) return bySize;
        var byHp = Math.Clamp(maxHp / 3, 1, 300);
        return Math.Max(bySize, byHp);
    }
}
