using System.Security.Cryptography;
using System.Text;

public sealed record SettlementHotspot(double X, double Y, double Width, double Height);

public sealed record SettlementPoiDefinition(
    string PoiKey,
    string Name,
    string Kind,
    string? ShopKind,
    IReadOnlyList<SettlementHotspot> Hotspots)
{
    public bool IsShop => !string.IsNullOrWhiteSpace(ShopKind);
}

public sealed record SettlementDefinition(
    string SettlementKey,
    string SettlementName,
    IReadOnlyList<SettlementPoiDefinition> Pois);

public sealed record SettlementShopItemDefinition(
    string ItemKey,
    string ItemName,
    string Category,
    int PriceGp,
    string Description);

public sealed record SettlementSellOffer(
    string ItemName,
    string Category,
    decimal UnitPriceGp);

public static class SettlementInteractionCatalog
{
    private static SettlementHotspot H(double x,double y,double width,double height) => new(x,y,width,height);
    private static SettlementPoiDefinition P(string key,string name,string kind,string? shopKind,params SettlementHotspot[] hotspots)
        => new(key,name,kind,shopKind,hotspots);

    private static readonly IReadOnlyList<SettlementDefinition> Settlements = new List<SettlementDefinition>
    {
        new("greymoor-hollow","Greymoor Hollow",new List<SettlementPoiDefinition>
        {
            P("mudhaven-inn","Mudhaven Inn","Inn",null,H(7,27,20,5)),
            P("shepherds-croft","Shepherd's Croft","Residence",null,H(22,47,19,5)),
            P("raffs-smithy","Raff's Smithy","Smithy","smithy",H(77,43,18,5)),
            P("farmers-market","Farmer's Market","Market","market",H(34,60,19,5)),
            P("brimblecups-sundries","Brimblecup's Sundries","Shop","general",H(67,61,21,5)),
            P("old-horn-apothecary","The Old Horn Apothecary","Apothecary","apothecary",H(52,75,24,5)),
            P("fletchers-cottage","Fletcher's Cottage","Fletcher","fletcher",H(70,87,21,5))
        }),
        new("stonewake-port","Stonewake Port",new List<SettlementPoiDefinition>
        {
            P("octopus-tankard","The Octopus' Tankard","Tavern",null,H(2,52,23,5)),
            P("starboard-pier","Starboard Pier","Pier",null,H(36,54,18,6)),
            P("seafront-fish-market","Seafront Fish Market","Fish Market","fishmarket",H(10,71,20,5)),
            P("hillwatch-temple","Hillwatch Temple","Temple",null,H(70,30,20,5)),
            P("hiltsrick-smithy","The Hiltsrick Smithy","Smithy","smithy",H(80,64,18,5)),
            P("rigid-brick-smithy","Rigid Brick Smithy","Smithy","smithy",H(70,73,17,5)),
            P("foomcloak-apothecary","Foomcloak Apothecary","Apothecary","apothecary",H(25,92,23,5)),
            P("seaworthy-inn","Seaworthy Inn","Inn",null,H(46,74,18,5)),
            P("port-bazaar","Port Bazaar","Bazaar","market",H(69,84,18,6))
        }),
        new("emberfall","Emberfall",new List<SettlementPoiDefinition>
        {
            P("ember-tavern","Ember Tavern","Tavern",null,H(59,25,17,5)),
            P("mine-entrance","Mine Entrance","Mine",null,H(80,43,16,5)),
            P("brass-anvil","The Brass Anvil","Smithy","smithy",H(65,57,16,5)),
            P("ashgrip-inn","Ashgrip Inn","Inn",null,H(5,67,14,5)),
            P("steel-forge","The Steel Forge","Forge","smithy",H(17,81,19,5)),
            P("moltenvein-mercantile","Moltenvein Mercantile","Mercantile","general",H(80,71,17,5)),
            P("grimroots-apothecary","Grimroot's Apothecary","Apothecary","apothecary",H(41,86,20,5)),
            P("wicks-wonders","Wick's Wonders","Curio Shop","enchanter",H(70,93,17,5))
        }),
        new("lunareth","Lunareth",new List<SettlementPoiDefinition>
        {
            P("creeping-rose-tavern","Creeping Rose Tavern","Tavern",null,H(5,27,21,5)),
            P("greenwood-hearth-inn","Greenwood Hearth Inn","Inn",null,H(46,38,23,5)),
            P("rosethorn-smithy","Rosethorn Smithy","Smithy","smithy",H(10,58,19,5)),
            P("evergreen-apothecary","Evergreen Apothecary","Apothecary","apothecary",H(55,64,21,5)),
            P("evergreen-shrine","Evergreen Shrine","Shrine",null,H(76,69,19,5)),
            P("elms-general-goods","Elm's General Goods","General Store","general",H(20,83,25,6)),
            P("starleaf-elixirs","Starleaf Elixirs","Alchemy Shop","alchemy",H(77,87,18,5))
        }),
        new("high-bastion","High Bastion",new List<SettlementPoiDefinition>
        {
            P("stoneborn-smithy","Stoneborn Smithy","Smithy","smithy",H(6,67,19,5)),
            P("stoutheart-arms","Stoutheart Arms","Armorer","arms",H(25,78,18,5)),
            P("ironmaul-inn","Ironmaul Inn","Inn",null,H(44,74,16,5)),
            P("bastion-bazaar","Bastion Bazaar","Bazaar","market",H(62,63,28,7)),
            P("citadel-of-dawn","Citadel of the Dawn","Citadel",null,H(80,74,18,5)),
            P("wyvernguard-tavern","Wyvernguard Tavern","Tavern",null,H(63,90,20,5))
        }),
        new("marrowfen","Marrowfen",new List<SettlementPoiDefinition>
        {
            P("imalers-hut","Imalers' Hut","Residence",null,H(10,37,18,5)),
            P("neighbors-folly","Neighbor's Folly","Landmark",null,H(48,36,18,5)),
            P("hags-hive-apothecary","The Hag's Hive Apothecary","Apothecary","apothecary",H(72,37,23,5)),
            P("broken-barrel-tavern","The Broken Barrel Tavern","Tavern",null,H(11,62,26,5)),
            P("swampgourd-blends","Swampgourd Blends","Alchemy Shop","alchemy",H(62,80,30,7))
        }),
        new("silverreach","Silverreach",new List<SettlementPoiDefinition>
        {
            P("brightwater-smithy","Brightwater Smithy","Smithy","smithy",H(16,35,20,5)),
            P("celestial-temple","Celestial Temple","Temple",null,H(74,30,18,5)),
            P("golden-cup-tavern","Golden Cup Tavern","Tavern",null,H(5,53,20,5)),
            P("kings-hall","The King's Hall","Civic",null,H(42,47,18,5)),
            P("lavinas-ceramics","Lavina's Ceramics","Artisan Shop","ceramics",H(66,52,22,5)),
            P("alchemists-emporium","Alchemist's Emporium","Alchemy Shop","alchemy",H(10,72,22,5)),
            P("goldenroot-alchemy","Goldenroot Alchemy","Alchemy Shop","alchemy",H(68,86,23,6))
        }),
        new("duskmire-crossing","Duskmire Crossing",new List<SettlementPoiDefinition>
        {
            P("drovers-rest-inn","Drover's Rest Inn","Inn",null,H(11,27,20,5)),
            P("cloven-helm-tavern","The Cloven Helm Tavern","Tavern",null,H(6,52,22,5)),
            P("willowbell-remedies","Willowbell Remedies","Apothecary","apothecary",H(72,40,20,5)),
            P("hedgwick-bazaar","Hedgwick Bazaar","Bazaar","market",H(49,64,20,5)),
            P("willowell-alchemy","Willowell Alchemy Shop","Alchemy Shop","alchemy",H(74,70,22,7))
        }),
        new("frostharbor","Frostharbor",new List<SettlementPoiDefinition>
        {
            P("frigid-winds-inn","Frigid Winds Inn","Inn",null,H(11,37,20,5)),
            P("winteis-bounty","Winteis Bounty","Outfitter","general",H(70,21,18,5)),
            P("deepwater-tavern","Deepwater Tavern","Tavern",null,H(81,50,17,5)),
            P("icevein-smithy","Icevein Smithy","Smithy","smithy",H(7,64,18,5)),
            P("coldwater-fish-market","Coldwater Fish Market","Fish Market","fishmarket",H(59,67,22,5)),
            P("bitterbalm-apothecary","Bitterbalm Apothecary","Apothecary","apothecary",H(71,87,22,7))
        }),
        new("sunspire","Sunspire",new List<SettlementPoiDefinition>
        {
            P("shimmering-sands-inn","Shimmering Sands Inn","Inn",null,H(10,22,21,5)),
            P("bardic-university","Bardic University","University",null,H(76,42,18,5)),
            P("kazuds-well","Kazud's Well","Landmark",null,H(40,57,17,5)),
            P("brifegin-quail-tavern","Brifegin & Quail Tavern","Tavern",null,H(7,66,25,5)),
            P("finehilt-forge","Finehilt Forge","Forge","smithy",H(79,65,17,5),H(72,88,20,5)),
            P("coldswa-fish-market","Coldswa Fish Market","Fish Market","fishmarket",H(55,73,22,5))
        }),
        new("blackroot-enclave","Blackroot Enclave",new List<SettlementPoiDefinition>
        {
            P("smolderstone-inn","Smolderstone Inn","Inn",null,H(11,25,22,5)),
            P("deepdelve-temple","Deepdelve Temple","Temple",null,H(71,27,19,5)),
            P("gemhold-bazaar","Gemhold Bazaar","Bazaar","market",H(7,50,21,5),H(20,74,20,5)),
            P("obsidian-vault","Obsidian Vault","Vault",null,H(74,63,19,5)),
            P("grim-glory-tavern","Grim Glory Tavern","Tavern",null,H(68,84,20,5))
        }),
        new("aetherfall","Aetherfall",new List<SettlementPoiDefinition>
        {
            P("starseekers-inn","Starseekers Inn","Inn",null,H(11,34,20,5)),
            P("mystic-spiral","Mystic Spiral","Landmark",null,H(69,32,20,5)),
            P("gateway-realities","Gateway of Realities","Gateway",null,H(40,50,23,5)),
            P("skylight-enchanters","Skylight Enchanters","Enchanter","enchanter",H(11,70,21,5)),
            P("wild-hex-tavern","The Wild Hex Tavern","Tavern",null,H(70,72,22,5))
        })
    };

    private static readonly IReadOnlyList<SettlementShopItemDefinition> SmithyItems = new List<SettlementShopItemDefinition>
    {
        I("dagger","Dagger","Weapon",2,"A light finesse blade suitable for close combat or throwing."),
        I("handaxe","Handaxe","Weapon",5,"A compact chopping weapon balanced well enough to throw."),
        I("javelin","Javelin","Weapon",1,"A light spear designed for throwing or close fighting."),
        I("mace","Mace","Weapon",5,"A sturdy one-handed bludgeoning weapon."),
        I("spear","Spear","Weapon",1,"A versatile thrusting weapon that can also be thrown."),
        I("battleaxe","Battleaxe","Weapon",10,"A martial axe built for powerful one- or two-handed strikes."),
        I("longsword","Longsword","Weapon",15,"A versatile martial sword with a strong straight blade."),
        I("rapier","Rapier","Weapon",25,"A finely balanced finesse sword."),
        I("warhammer","Warhammer","Weapon",15,"A versatile martial hammer for crushing armor."),
        I("greatsword","Greatsword","Weapon",50,"A heavy two-handed martial sword."),
        I("shortbow","Shortbow","Weapon",25,"A compact ranged weapon used with arrows."),
        I("longbow","Longbow","Weapon",50,"A powerful two-handed ranged weapon."),
        I("light-crossbow","Light Crossbow","Weapon",25,"A reliable crossbow for bolts."),
        I("shield","Shield","Armor",10,"A hand-held shield that improves protection when equipped."),
        I("leather-armor","Leather Armor","Armor",10,"Light armor made from toughened leather."),
        I("studded-leather","Studded Leather Armor","Armor",45,"Flexible light armor reinforced with metal studs."),
        I("hide-armor","Hide Armor","Armor",10,"Rugged medium armor of thick hides and furs."),
        I("chain-shirt","Chain Shirt","Armor",50,"A flexible shirt of interlocking metal rings."),
        I("scale-mail","Scale Mail","Armor",50,"Medium armor made from overlapping metal scales."),
        I("breastplate","Breastplate","Armor",400,"A fitted metal breastplate offering strong protection with mobility."),
        I("half-plate","Half Plate Armor","Armor",750,"Heavy medium armor with shaped metal plates."),
        I("ring-mail","Ring Mail","Armor",30,"Heavy leather reinforced with metal rings."),
        I("chain-mail","Chain Mail","Armor",75,"Heavy interlocking metal armor."),
        I("splint-armor","Splint Armor","Armor",200,"Heavy armor made from vertical metal strips."),
        I("plate-armor","Plate Armor","Armor",1500,"A complete suit of fitted metal plate armor."),
        I("smiths-tools","Smith's Tools","Tool",20,"Tools for metalworking, repair, and smithing tasks."),
        I("blacksmithing-kit","Blacksmithing Kit","Tool",25,"A portable hammer, tongs, files, whetstone, and compact repair supplies.")
    };

    private static readonly IReadOnlyList<SettlementShopItemDefinition> ApothecaryItems = new List<SettlementShopItemDefinition>
    {
        I("potion-healing","Potion of Healing","Potion",50,"A red healing draught that restores hit points when consumed."),
        I("antitoxin","Antitoxin","Remedy",50,"A medicinal dose used to resist or counter common poisons."),
        I("healers-kit","Healer's Kit","Tool",5,"Bandages, salves, and splints for emergency treatment."),
        I("herbal-poultice","Herbal Poultice","Salve",5,"A soothing herbal dressing for cuts, swelling, and minor burns."),
        I("burn-salve","Burn Salve","Salve",10,"A cooling medicinal salve prepared for burns and heat injuries."),
        I("antivenom-salve","Antivenom Salve","Salve",15,"A pungent topical treatment commonly carried by hunters and sailors."),
        I("restorative-tonic","Restorative Tonic","Potion",25,"A bitter tonic sold for fatigue, nausea, and recovery after exertion."),
        I("basic-poison","Basic Poison","Poison",100,"A vial of weapon poison sold where local law permits."),
        I("potion-climbing","Potion of Climbing","Potion",75,"A potion sold to climbers, miners, and adventurers for difficult ascents."),
        I("potion-water-breathing","Potion of Water Breathing","Potion",100,"A specialized draught for extended activity beneath the water.")
    };

    private static readonly IReadOnlyList<SettlementShopItemDefinition> AlchemyItems = ApothecaryItems.Concat(new[]
    {
        I("acid-vial","Acid Vial","Alchemical",25,"A stoppered vial of corrosive alchemical acid."),
        I("alchemists-fire","Alchemist's Fire","Alchemical",50,"A sticky volatile mixture that ignites when its container breaks."),
        I("oil-flask","Flask of Oil","Alchemical",1,"A flask of lamp oil useful for light, machinery, or improvised plans."),
        I("alchemists-supplies","Alchemist's Supplies","Tool",50,"Glassware, reagents, burners, and tools for alchemical work."),
        I("empty-vials","Empty Glass Vials (5)","Container",2,"Five clean stoppered vials for potions, samples, or reagents.")
    }).ToList();

    private static readonly IReadOnlyList<SettlementShopItemDefinition> GeneralItems = new List<SettlementShopItemDefinition>
    {
        I("bedroll","Bedroll","Adventuring Gear",1,"A compact roll of bedding for travel."),
        I("crowbar","Crowbar","Adventuring Gear",2,"A stout metal bar for leverage."),
        I("hammer","Hammer","Adventuring Gear",1,"A general-purpose hand hammer."),
        I("hemp-rope","Hempen Rope (50 ft.)","Adventuring Gear",1,"Fifty feet of sturdy hemp rope."),
        I("silk-rope","Silk Rope (50 ft.)","Adventuring Gear",10,"Fifty feet of light, strong silk rope."),
        I("lantern","Hooded Lantern","Adventuring Gear",5,"A shuttered lantern for controlled light."),
        I("oil-flask","Flask of Oil","Adventuring Gear",1,"Lamp oil in a stoppered flask."),
        I("pitons","Pitons (10)","Adventuring Gear",1,"Ten iron spikes for climbing and securing lines."),
        I("rations","Rations (5 days)","Food",3,"Five days of preserved travel food."),
        I("torch-bundle","Torches (10)","Adventuring Gear",1,"Ten simple wooden torches."),
        I("waterskin","Waterskin","Adventuring Gear",1,"A leather water container."),
        I("backpack","Backpack","Adventuring Gear",2,"A durable travel pack."),
        I("blanket","Blanket","Adventuring Gear",1,"A warm wool blanket."),
        I("grappling-hook","Grappling Hook","Adventuring Gear",2,"A metal climbing hook for use with rope."),
        I("thieves-tools","Thieves' Tools","Tool",25,"Picks and fine tools for locks and traps."),
        I("healers-kit","Healer's Kit","Tool",5,"Bandages, salves, and splints for emergency treatment.")
    };

    private static readonly IReadOnlyList<SettlementShopItemDefinition> FletcherItems = new List<SettlementShopItemDefinition>
    {
        I("arrows","Arrows (20)","Ammunition",1,"Twenty arrows for bows."),
        I("bolts","Crossbow Bolts (20)","Ammunition",1,"Twenty bolts for crossbows."),
        I("shortbow","Shortbow","Weapon",25,"A compact bow favored by scouts and hunters."),
        I("longbow","Longbow","Weapon",50,"A powerful long-ranged bow."),
        I("light-crossbow","Light Crossbow","Weapon",25,"A reliable crossbow for adventuring."),
        I("quiver","Quiver","Adventuring Gear",1,"A rigid carrier for arrows or bolts."),
        I("fletchers-tools","Fletcher's Tools","Tool",10,"Knives, jigs, glue, feathers, and gauges for making ammunition.")
    };

    private static readonly IReadOnlyList<SettlementShopItemDefinition> FishMarketItems = new List<SettlementShopItemDefinition>
    {
        I("fresh-fish","Fresh Fish","Food",1,"A fresh local catch suitable for a meal."),
        I("dried-fish-rations","Dried Fish Rations (5 days)","Food",3,"Five days of salted or smoked fish rations."),
        I("salted-eel","Salted Eel","Food",1,"Preserved eel wrapped for travel."),
        I("fish-oil","Fish Oil Flask","Trade Good",2,"Rendered fish oil used for lamps, leatherwork, or alchemical mixtures."),
        I("fishing-tackle","Fishing Tackle","Tool",1,"Hooks, line, sinkers, and simple fishing gear."),
        I("net","Net","Adventuring Gear",1,"A weighted net useful for fishing or restraint."),
        I("salt-pouch","Salt Pouch","Trade Good",1,"A pouch of coarse preserving salt.")
    };

    private static readonly IReadOnlyList<SettlementShopItemDefinition> CeramicsItems = new List<SettlementShopItemDefinition>
    {
        I("ceramic-flasks","Ceramic Flasks (5)","Container",2,"Five sturdy ceramic flasks for liquids or samples."),
        I("sealed-jug","Sealed Ceramic Jug","Container",1,"A glazed jug with a fitted stopper."),
        I("cooking-pot","Cooking Pot","Adventuring Gear",2,"A durable ceramic cooking pot."),
        I("alchemical-crucible","Ceramic Alchemical Crucible","Tool",5,"A heat-resistant crucible for small alchemical preparations."),
        I("inkwell","Decorative Inkwell","Adventuring Gear",2,"A glazed inkwell made for scholars and scribes.")
    };

    private static readonly IReadOnlyList<SettlementShopItemDefinition> EnchanterItems = new List<SettlementShopItemDefinition>
    {
        I("arcane-focus-crystal","Arcane Focus — Crystal","Arcane Gear",10,"A worked crystal suitable for use as an arcane focus."),
        I("arcane-focus-orb","Arcane Focus — Orb","Arcane Gear",20,"A polished orb suitable for use as an arcane focus."),
        I("component-pouch","Component Pouch","Arcane Gear",25,"A belt pouch organized for common spell components."),
        I("spellbook","Blank Spellbook","Arcane Gear",50,"A durable spellbook with pages prepared for magical notation."),
        I("scroll-case","Scroll Case","Arcane Gear",1,"A protective case for maps, parchments, or spell scrolls."),
        I("moon-touched-trinket","Moon-Touched Trinket","Wondrous Curio",75,"A minor enchanted keepsake that sheds a faint glow on command."),
        I("everbright-lantern","Everbright Lantern","Wondrous Curio",100,"A small enchanted lantern sold as a durable magical light source."),
        I("potion-healing","Potion of Healing","Potion",50,"A red healing draught that restores hit points when consumed.")
    };

    private static readonly IReadOnlyList<SettlementShopItemDefinition> ArmsItems = SmithyItems
        .Where(i => i.Category is "Weapon" or "Armor")
        .ToList();

    private static readonly IReadOnlyList<SettlementShopItemDefinition> MarketPool =
        SmithyItems.Where(i => i.PriceGp <= 75)
        .Concat(ApothecaryItems.Where(i => i.PriceGp <= 100))
        .Concat(GeneralItems)
        .Concat(FletcherItems)
        .Concat(FishMarketItems)
        .Concat(CeramicsItems)
        .Concat(EnchanterItems.Where(i => i.PriceGp <= 100))
        .GroupBy(i => i.ItemKey,StringComparer.OrdinalIgnoreCase)
        .Select(g => g.First())
        .ToList();

    private static readonly IReadOnlyList<SettlementShopItemDefinition> AllKnownItems =
        SmithyItems
        .Concat(ApothecaryItems)
        .Concat(AlchemyItems)
        .Concat(GeneralItems)
        .Concat(FletcherItems)
        .Concat(FishMarketItems)
        .Concat(CeramicsItems)
        .Concat(EnchanterItems)
        .GroupBy(i => Normalize(i.ItemName),StringComparer.OrdinalIgnoreCase)
        .Select(g => g.OrderBy(i => i.PriceGp).First())
        .ToList();

    private static SettlementShopItemDefinition I(string key,string name,string category,int price,string description)
        => new(key,name,category,price,description);

    public static SettlementDefinition? FindByLocation(string? location)
    {
        var normalized=Normalize(location);
        return Settlements.FirstOrDefault(s => Normalize(s.SettlementName)==normalized || s.SettlementKey==normalized);
    }

    public static SettlementPoiDefinition? FindPoi(string? settlementKey,string? poiKey)
    {
        var settlement=Settlements.FirstOrDefault(s => s.SettlementKey.Equals(Normalize(settlementKey),StringComparison.OrdinalIgnoreCase));
        return settlement?.Pois.FirstOrDefault(p => p.PoiKey.Equals(Normalize(poiKey),StringComparison.OrdinalIgnoreCase));
    }

    public static IReadOnlyList<SettlementShopItemDefinition> GetShopItems(Guid campaignId, SettlementDefinition settlement, SettlementPoiDefinition poi)
    {
        var kind=(poi.ShopKind??string.Empty).Trim().ToLowerInvariant();
        return kind switch
        {
            "smithy" => SmithyItems,
            "arms" => ArmsItems,
            "apothecary" => ApothecaryItems,
            "alchemy" => AlchemyItems,
            "general" => GeneralItems,
            "fletcher" => FletcherItems,
            "fishmarket" => FishMarketItems,
            "ceramics" => CeramicsItems,
            "enchanter" => EnchanterItems,
            "market" => DeterministicMarket(campaignId,settlement.SettlementKey,poi.PoiKey),
            _ => Array.Empty<SettlementShopItemDefinition>()
        };
    }

    public static SettlementSellOffer? GetSellOffer(SettlementPoiDefinition poi, string? inventoryItemName)
    {
        var itemName=(inventoryItemName??string.Empty).Trim();
        if(itemName.Length==0)return null;

        var known=AllKnownItems.FirstOrDefault(i => Normalize(i.ItemName)==Normalize(itemName));
        if(known is null)return null;

        var kind=(poi.ShopKind??string.Empty).Trim().ToLowerInvariant();
        var accepted=kind switch
        {
            "smithy" => SmithyItems.Any(i => SameItem(i,known)),
            "arms" => ArmsItems.Any(i => SameItem(i,known)),
            "apothecary" => ApothecaryItems.Any(i => SameItem(i,known)),
            "alchemy" => AlchemyItems.Any(i => SameItem(i,known)),
            "general" => GeneralItems.Any(i => SameItem(i,known)),
            "fletcher" => FletcherItems.Any(i => SameItem(i,known)),
            "fishmarket" => FishMarketItems.Any(i => SameItem(i,known)),
            "ceramics" => CeramicsItems.Any(i => SameItem(i,known)),
            "enchanter" => EnchanterItems.Any(i => SameItem(i,known)),
            "market" => MarketPool.Any(i => SameItem(i,known)),
            _ => false
        };
        if(!accepted)return null;

        // Standard merchant resale: 50% of catalog price. Decimal GP preserves 5 sp values.
        var resale=known.PriceGp/2m;
        if(resale<=0)return null;
        return new SettlementSellOffer(known.ItemName,known.Category,resale);
    }

    private static bool SameItem(SettlementShopItemDefinition left, SettlementShopItemDefinition right)
        => Normalize(left.ItemName)==Normalize(right.ItemName);

    private static IReadOnlyList<SettlementShopItemDefinition> DeterministicMarket(Guid campaignId,string settlementKey,string poiKey)
    {
        var bytes=SHA256.HashData(Encoding.UTF8.GetBytes($"{campaignId:N}|{settlementKey}|{poiKey}|market-v1"));
        var seed=BitConverter.ToInt32(bytes,0) & 0x7fffffff;
        var random=new Random(seed);
        var list=MarketPool.ToList();
        for(var i=list.Count-1;i>0;i--)
        {
            var j=random.Next(i+1);
            (list[i],list[j])=(list[j],list[i]);
        }
        return list.Take(12).OrderBy(i=>i.Category).ThenBy(i=>i.ItemName).ToList();
    }

    private static string Normalize(string? value)
    {
        var source=(value??string.Empty).Trim().ToLowerInvariant();
        if(source.Length==0)return string.Empty;
        var sb=new StringBuilder(source.Length);
        var dash=false;
        foreach(var c in source)
        {
            if(char.IsLetterOrDigit(c))
            {
                sb.Append(c);
                dash=false;
            }
            else if(!dash&&sb.Length>0)
            {
                sb.Append('-');
                dash=true;
            }
        }
        return sb.ToString().Trim('-');
    }
}
