Imports System
Imports System.Collections.Generic

Public NotInheritable Class InventoryReferenceService
    Private Shared ReadOnly EquippableItems As New HashSet(Of String)(StringComparer.OrdinalIgnoreCase) From {
        "Battleaxe", "Club", "Dagger", "Dart", "Flail", "Glaive", "Greataxe", "Greatclub", "Greatsword",
        "Halberd", "Hand Crossbow", "Handaxe", "Heavy Crossbow", "Javelin", "Lance", "Light Crossbow",
        "Light Hammer", "Longbow", "Longsword", "Mace", "Maul", "Morningstar", "Pike", "Quarterstaff",
        "Rapier", "Scimitar", "Shortbow", "Shortsword", "Sickle", "Sling", "Spear", "Trident", "War Pick",
        "Warhammer", "Whip", "Leather Armor", "Studded Leather Armor", "Chain Shirt", "Chain Mail", "Shield",
        "Robe", "Fine Clothes", "Traveler's Clothes", "Costume", "Arcane Focus (Crystal)", "Arcane Focus (Orb)",
        "Arcane Focus (Quarterstaff)", "Druidic Focus (Quarterstaff)", "Druidic Focus (Sprig of Mistletoe)", "Holy Symbol"
    }

    Private Shared ReadOnly Descriptions As New Dictionary(Of String, String)(StringComparer.OrdinalIgnoreCase) From {
        {"Greataxe", "A heavy, two-handed martial axe built for powerful sweeping blows."},
        {"Handaxe", "A compact one-handed axe that can be used in close combat or thrown."},
        {"Dagger", "A small, light blade suited to close fighting and throwing."},
        {"Mace", "A one-handed bludgeoning weapon with a weighted striking head."},
        {"Sickle", "A light curved blade originally made as a harvesting tool and usable as a weapon."},
        {"Greatsword", "A large two-handed sword designed for forceful melee attacks."},
        {"Flail", "A one-handed martial weapon with a striking head connected to its handle."},
        {"Javelin", "A light spear balanced for either melee use or throwing."},
        {"Scimitar", "A light curved sword well suited to quick one-handed attacks."},
        {"Shortsword", "A compact martial sword designed for fast close-quarters fighting."},
        {"Longsword", "A versatile martial sword that can be wielded with one or two hands."},
        {"Longbow", "A powerful two-handed ranged weapon that fires arrows over long distances."},
        {"Shortbow", "A compact two-handed bow useful for mobile ranged combat."},
        {"Light Crossbow", "A two-handed ranged weapon that fires crossbow bolts."},
        {"Spear", "A versatile pole weapon that can be used one-handed, two-handed, or thrown."},
        {"Quarterstaff", "A sturdy staff usable as both a walking aid and a versatile melee weapon."},
        {"Leather Armor", "Light armor made from hardened leather that protects without greatly restricting movement."},
        {"Studded Leather Armor", "Light leather armor reinforced with protective metal fittings."},
        {"Chain Shirt", "Medium armor made from interlocking metal rings worn beneath outer clothing or gear."},
        {"Chain Mail", "Heavy interlocking metal armor that provides strong protection at the cost of weight and mobility."},
        {"Shield", "A handheld defensive item used to improve protection against incoming attacks."},
        {"Arrow", "Ammunition used with bows."},
        {"Bolt", "Ammunition used with crossbows."},
        {"Quiver", "A container designed to carry arrows or similar ammunition where they can be reached quickly."},
        {"Explorer's Pack", "A bundled set of common adventuring and wilderness supplies for travel and exploration."},
        {"Entertainer's Pack", "A collection of travel and performance supplies useful to a professional entertainer."},
        {"Priest's Pack", "A bundle of travel, devotional, and adventuring supplies suited to religious service."},
        {"Dungeoneer's Pack", "A set of practical supplies for exploring ruins, caves, and underground environments."},
        {"Burglar's Pack", "A collection of tools and supplies useful for infiltration, climbing, and covert work."},
        {"Scholar's Pack", "A collection of writing, study, and travel supplies for research-focused adventurers."},
        {"Thieves' Tools", "A specialized tool set used for locks, traps, and other delicate mechanical work."},
        {"Herbalism Kit", "A collection of tools used to identify, gather, and prepare herbs and similar natural materials."},
        {"Healer's Kit", "A compact collection of medical supplies used to provide immediate mundane aid."},
        {"Forgery Kit", "Tools and materials used to imitate documents, handwriting, seals, and similar marks."},
        {"Navigator's Tools", "Specialized instruments used to determine direction, position, and travel course."},
        {"Cartographer's Tools", "Tools used to measure, draw, copy, and maintain maps."},
        {"Calligrapher's Supplies", "Writing tools and materials used for careful lettering, documents, and decorative script."},
        {"Arcane Focus (Crystal)", "A crystal used by an arcane spellcaster to channel spellcasting energy."},
        {"Arcane Focus (Orb)", "An orb used by an arcane spellcaster to channel spellcasting energy."},
        {"Arcane Focus (Quarterstaff)", "A quarterstaff prepared to serve as an arcane spellcasting focus as well as a staff."},
        {"Druidic Focus (Quarterstaff)", "A quarterstaff prepared as a druidic focus for channeling nature magic."},
        {"Druidic Focus (Sprig of Mistletoe)", "A natural druidic focus used to channel nature-based spellcasting."},
        {"Holy Symbol", "A sacred emblem used by a devotee to represent a faith and, when appropriate, channel divine magic."},
        {"Spellbook", "A personal book used by a wizard to record, organize, and study spells."},
        {"Book (Occult Lore)", "A book containing notes, traditions, or writings concerning occult subjects."},
        {"Book (Prayers)", "A devotional book containing prayers and religious writings."},
        {"Book (Philosophy)", "A book containing philosophical arguments, observations, or teachings."},
        {"Book (History)", "A written historical reference or chronicle."},
        {"Parchment", "A sheet of writing material suitable for notes, maps, correspondence, or records."},
        {"Robe", "A loose full-length garment suitable for ordinary wear, ceremonial use, or spellcaster attire."},
        {"Fine Clothes", "Well-made formal clothing intended for respectable or high-status appearances."},
        {"Traveler's Clothes", "Durable everyday clothing made for long journeys and changing weather."},
        {"Costume", "Clothing and accessories intended to create a particular appearance or performance persona."},
        {"Crowbar", "A rigid metal lever used for prying, forcing, and moving stubborn objects."},
        {"Mirror", "A small reflective object useful for grooming, signaling, or looking around difficult angles."},
        {"Perfume", "A small container of scented liquid used to add a deliberate fragrance."},
        {"Iron Pot", "A durable cooking vessel suitable for campfires and travel."},
        {"Shovel", "A sturdy digging tool for moving soil, sand, ash, or loose material."},
        {"Hooded Lantern", "A portable lantern whose hood can control or conceal the amount of visible light."},
        {"Manacles", "Metal restraints designed to secure a creature's wrists."},
        {"Bedroll", "Portable bedding that can be rolled for travel and laid out for rest."},
        {"Tent", "Portable shelter that can be erected at a campsite."},
        {"Lamp", "A small portable light source that burns lamp oil."},
        {"Oil Flask", "A container of lamp oil useful as fuel and for other practical adventuring purposes."},
        {"Rope", "A length of strong cordage useful for climbing, tying, hauling, and countless field tasks."},
        {"Pouch", "A small container worn or carried for coins and other compact items."}
    }

    Private Shared ReadOnly MusicalInstruments As New HashSet(Of String)(StartingEquipmentService.MusicalInstruments, StringComparer.OrdinalIgnoreCase)
    Private Shared ReadOnly ArtisanTools As New HashSet(Of String)(StartingEquipmentService.ArtisanTools, StringComparer.OrdinalIgnoreCase)
    Private Shared ReadOnly GamingSets As New HashSet(Of String)(StartingEquipmentService.GamingSets, StringComparer.OrdinalIgnoreCase)

    Private Sub New()
    End Sub

    Public Shared Function CanEquip(itemName As String) As Boolean
        If String.IsNullOrWhiteSpace(itemName) Then Return False
        Dim name = itemName.Trim()
        If EquippableItems.Contains(name) Then Return True
        Dim lower = name.ToLowerInvariant()
        If lower.Contains("armor") OrElse lower.Contains("shield") Then Return True
        If lower.Contains("focus") OrElse lower.Contains("symbol") Then Return True

        ' Homebrew items do not have a separate item-type field yet, so recognize
        ' common wearable/wieldable words in their names as a safe fallback.
        Dim equipWords As String() = {
            "sword", "blade", "axe", "bow", "crossbow", "dagger", "mace", "spear", "staff", "wand",
            "hammer", "flail", "sickle", "lance", "pike", "whip", "club", "trident", "robe", "clothes",
            "costume", "cloak", "helm", "helmet", "boots", "gauntlet", "bracer", "ring", "amulet"
        }
        Return Array.Exists(equipWords, Function(word) lower.Contains(word))
    End Function

    Public Shared Function GetDescription(item As InventoryItem) As String
        If item Is Nothing Then Return String.Empty
        Dim name = If(item.ItemName, String.Empty).Trim()
        Dim description As String = String.Empty

        If Not String.IsNullOrWhiteSpace(item.ItemDescription) Then
            description = item.ItemDescription.Trim()
        ElseIf Descriptions.TryGetValue(name, description) Then
            ' Found a concise built-in description.
        ElseIf MusicalInstruments.Contains(name) Then
            description = $"A musical instrument ({name}) used for performance, practice, and other situations where music matters."
        ElseIf ArtisanTools.Contains(name) Then
            description = $"A professional artisan tool set ({name}) used for the craft associated with that trade."
        ElseIf GamingSets.Contains(name) Then
            description = $"A portable gaming set ({name}) used for recreation, contests, gambling, or social play."
        Else
            Dim lower = name.ToLowerInvariant()
            If lower.Contains("armor") Then
                description = "Protective armor worn to reduce a character's vulnerability in combat."
            ElseIf lower.Contains("pack") Then
                description = "A bundled collection of adventuring supplies associated with the named pack."
            ElseIf lower.Contains("tool") OrElse lower.Contains("supplies") OrElse lower.Contains("kit") Then
                description = "A specialized collection of tools or supplies used for the activity named by the item."
            ElseIf lower.Contains("clothes") OrElse lower.Contains("robe") OrElse lower.Contains("costume") Then
                description = "Wearable clothing carried as part of the character's equipment."
            Else
                description = "No built-in rules description is stored for this item. Use Edit Item to add your own notes or description."
            End If
        End If

        If Not String.IsNullOrWhiteSpace(item.Notes) Then
            description &= Environment.NewLine & Environment.NewLine & "Notes: " & item.Notes.Trim()
        End If
        Return description
    End Function
End Class
