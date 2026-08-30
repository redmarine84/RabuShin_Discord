Imports System
Imports System.Collections.Generic
Imports System.Linq

Public Class StartingEquipmentEntry
    Public Property ItemName As String = String.Empty
    Public Property Quantity As Integer = 1
    Public Property ChoiceKind As String = String.Empty

    Public Sub New()
    End Sub

    Public Sub New(itemName As String, Optional quantity As Integer = 1, Optional choiceKind As String = "")
        Me.ItemName = itemName
        Me.Quantity = quantity
        Me.ChoiceKind = choiceKind
    End Sub
End Class

Public Class StartingEquipmentPackage
    Public Property Label As String = String.Empty
    Public Property Gold As Decimal
    Public Property Items As New List(Of StartingEquipmentEntry)()

    Public Overrides Function ToString() As String
        Return Label
    End Function
End Class


Public Class StartingEquipmentPreviewRow
    Public Property Source As String = String.Empty
    Public Property Item As String = String.Empty
    Public Property Qty As Integer
End Class

Public NotInheritable Class StartingEquipmentService
    Private Sub New()
    End Sub

    Public Const MusicalInstrumentChoice As String = "MusicalInstrument"
    Public Const ArtisanToolsChoice As String = "ArtisanTools"
    Public Const GamingSetChoice As String = "GamingSet"
    Public Const ToolOrInstrumentChoice As String = "ToolOrInstrument"

    Public Shared ReadOnly MusicalInstruments As String() = {
        "Bagpipes", "Drum", "Dulcimer", "Flute", "Horn", "Lute", "Lyre", "Pan Flute", "Shawm", "Viol"
    }

    Public Shared ReadOnly ArtisanTools As String() = {
        "Alchemist's Supplies", "Brewer's Supplies", "Calligrapher's Supplies", "Carpenter's Tools",
        "Cartographer's Tools", "Cobbler's Tools", "Cook's Utensils", "Glassblower's Tools",
        "Jeweler's Tools", "Leatherworker's Tools", "Mason's Tools", "Painter's Supplies",
        "Potter's Tools", "Smith's Tools", "Tinker's Tools", "Weaver's Tools", "Woodcarver's Tools"
    }

    Public Shared ReadOnly GamingSets As String() = {
        "Dice Set", "Dragonchess Set", "Playing Card Set", "Three-Dragon Ante Set"
    }

    Public Shared Function GetClassPackages(className As String) As List(Of StartingEquipmentPackage)
        Select Case Normalize(className)
            Case "artificer"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Studded Leather, Dagger, Thieves' Tools, Tinker's Tools, Dungeoneer's Pack + 16 GP", 16D,
                            E("Studded Leather Armor"), E("Dagger"), E("Thieves' Tools"), E("Tinker's Tools"), E("Dungeoneer's Pack")),
                    GoldPackage("Option B — 150 GP (buy your own equipment)", 150D)
                }
            Case "barbarian"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Greataxe, 4 Handaxes, Explorer's Pack + 15 GP", 15D, E("Greataxe"), E("Handaxe", 4), E("Explorer's Pack")),
                    GoldPackage("Option B — 75 GP (buy your own equipment)", 75D)
                }
            Case "bard"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Leather Armor, 2 Daggers, Instrument, Entertainer's Pack + 19 GP", 19D,
                            E("Leather Armor"), E("Dagger", 2), E("Musical Instrument", 1, MusicalInstrumentChoice), E("Entertainer's Pack")),
                    GoldPackage("Option B — 90 GP (buy your own equipment)", 90D)
                }
            Case "cleric"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Chain Shirt, Shield, Mace, Holy Symbol, Priest's Pack + 7 GP", 7D,
                            E("Chain Shirt"), E("Shield"), E("Mace"), E("Holy Symbol"), E("Priest's Pack")),
                    GoldPackage("Option B — 110 GP (buy your own equipment)", 110D)
                }
            Case "druid"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Leather Armor, Shield, Sickle, Druidic Focus, Explorer's Pack, Herbalism Kit + 9 GP", 9D,
                            E("Leather Armor"), E("Shield"), E("Sickle"), E("Druidic Focus (Quarterstaff)"), E("Explorer's Pack"), E("Herbalism Kit")),
                    GoldPackage("Option B — 50 GP (buy your own equipment)", 50D)
                }
            Case "fighter"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Chain Mail, Greatsword, Flail, 8 Javelins, Dungeoneer's Pack + 4 GP", 4D,
                            E("Chain Mail"), E("Greatsword"), E("Flail"), E("Javelin", 8), E("Dungeoneer's Pack")),
                    Package("Package B — Studded Leather, Scimitar, Shortsword, Longbow, 20 Arrows, Quiver, Dungeoneer's Pack + 11 GP", 11D,
                            E("Studded Leather Armor"), E("Scimitar"), E("Shortsword"), E("Longbow"), E("Arrow", 20), E("Quiver"), E("Dungeoneer's Pack")),
                    GoldPackage("Option C — 155 GP (buy your own equipment)", 155D)
                }
            Case "monk"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Spear, 5 Daggers, chosen Tool/Instrument, Explorer's Pack + 11 GP", 11D,
                            E("Spear"), E("Dagger", 5), E("Tool or Musical Instrument", 1, ToolOrInstrumentChoice), E("Explorer's Pack")),
                    GoldPackage("Option B — 50 GP (buy your own equipment)", 50D)
                }
            Case "paladin"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Chain Mail, Shield, Longsword, 6 Javelins, Holy Symbol, Priest's Pack + 9 GP", 9D,
                            E("Chain Mail"), E("Shield"), E("Longsword"), E("Javelin", 6), E("Holy Symbol"), E("Priest's Pack")),
                    GoldPackage("Option B — 150 GP (buy your own equipment)", 150D)
                }
            Case "ranger"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Studded Leather, Scimitar, Shortsword, Longbow, 20 Arrows, Quiver, Druidic Focus, Explorer's Pack + 7 GP", 7D,
                            E("Studded Leather Armor"), E("Scimitar"), E("Shortsword"), E("Longbow"), E("Arrow", 20), E("Quiver"), E("Druidic Focus (Sprig of Mistletoe)"), E("Explorer's Pack")),
                    GoldPackage("Option B — 150 GP (buy your own equipment)", 150D)
                }
            Case "rogue"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Leather Armor, 2 Daggers, Shortsword, Shortbow, 20 Arrows, Quiver, Thieves' Tools, Burglar's Pack + 8 GP", 8D,
                            E("Leather Armor"), E("Dagger", 2), E("Shortsword"), E("Shortbow"), E("Arrow", 20), E("Quiver"), E("Thieves' Tools"), E("Burglar's Pack")),
                    GoldPackage("Option B — 100 GP (buy your own equipment)", 100D)
                }
            Case "sorcerer"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Spear, 2 Daggers, Arcane Focus, Dungeoneer's Pack + 28 GP", 28D,
                            E("Spear"), E("Dagger", 2), E("Arcane Focus (Crystal)"), E("Dungeoneer's Pack")),
                    GoldPackage("Option B — 50 GP (buy your own equipment)", 50D)
                }
            Case "warlock"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — Leather Armor, Sickle, 2 Daggers, Arcane Focus, Occult Book, Scholar's Pack + 15 GP", 15D,
                            E("Leather Armor"), E("Sickle"), E("Dagger", 2), E("Arcane Focus (Orb)"), E("Book (Occult Lore)"), E("Scholar's Pack")),
                    GoldPackage("Option B — 100 GP (buy your own equipment)", 100D)
                }
            Case "wizard"
                Return New List(Of StartingEquipmentPackage) From {
                    Package("Package A — 2 Daggers, Arcane Focus, Robe, Spellbook, Scholar's Pack + 5 GP", 5D,
                            E("Dagger", 2), E("Arcane Focus (Quarterstaff)"), E("Robe"), E("Spellbook"), E("Scholar's Pack")),
                    GoldPackage("Option B — 55 GP (buy your own equipment)", 55D)
                }
            Case Else
                Return New List(Of StartingEquipmentPackage)()
        End Select
    End Function

    Public Shared Function GetBackgroundPackages(backgroundName As String) As List(Of StartingEquipmentPackage)
        Select Case Normalize(backgroundName)
            Case "acolyte"
                Return StandardBackground(8D, E("Calligrapher's Supplies"), E("Book (Prayers)"), E("Holy Symbol"), E("Parchment", 10), E("Robe"))
            Case "artisan"
                Return StandardBackground(32D, E("Artisan's Tools", 1, ArtisanToolsChoice), E("Pouch", 2), E("Traveler's Clothes"))
            Case "charlatan"
                Return StandardBackground(15D, E("Forgery Kit"), E("Costume"), E("Fine Clothes"))
            Case "criminal"
                Return StandardBackground(16D, E("Dagger", 2), E("Thieves' Tools"), E("Crowbar"), E("Pouch", 2), E("Traveler's Clothes"))
            Case "entertainer"
                Return StandardBackground(11D, E("Musical Instrument", 1, MusicalInstrumentChoice), E("Costume", 2), E("Mirror"), E("Perfume"), E("Traveler's Clothes"))
            Case "farmer"
                Return StandardBackground(30D, E("Sickle"), E("Carpenter's Tools"), E("Healer's Kit"), E("Iron Pot"), E("Shovel"), E("Traveler's Clothes"))
            Case "guard"
                Return StandardBackground(12D, E("Spear"), E("Light Crossbow"), E("Bolt", 20), E("Gaming Set", 1, GamingSetChoice), E("Hooded Lantern"), E("Manacles"), E("Quiver"), E("Traveler's Clothes"))
            Case "guide"
                Return StandardBackground(3D, E("Shortbow"), E("Arrow", 20), E("Cartographer's Tools"), E("Bedroll"), E("Quiver"), E("Tent"), E("Traveler's Clothes"))
            Case "hermit"
                Return StandardBackground(16D, E("Quarterstaff"), E("Herbalism Kit"), E("Bedroll"), E("Book (Philosophy)"), E("Lamp"), E("Oil Flask", 3), E("Traveler's Clothes"))
            Case "merchant"
                Return StandardBackground(22D, E("Navigator's Tools"), E("Pouch", 2), E("Traveler's Clothes"))
            Case "noble"
                Return StandardBackground(29D, E("Gaming Set", 1, GamingSetChoice), E("Fine Clothes"), E("Perfume"))
            Case "sage"
                Return StandardBackground(8D, E("Quarterstaff"), E("Calligrapher's Supplies"), E("Book (History)"), E("Parchment", 8), E("Robe"))
            Case "sailor"
                Return StandardBackground(20D, E("Dagger"), E("Navigator's Tools"), E("Rope"), E("Traveler's Clothes"))
            Case "scribe"
                Return StandardBackground(23D, E("Calligrapher's Supplies"), E("Fine Clothes"), E("Lamp"), E("Oil Flask", 3), E("Parchment", 12))
            Case "soldier"
                Return StandardBackground(14D, E("Spear"), E("Shortbow"), E("Arrow", 20), E("Gaming Set", 1, GamingSetChoice), E("Healer's Kit"), E("Quiver"), E("Traveler's Clothes"))
            Case "wayfarer"
                Return StandardBackground(16D, E("Dagger", 2), E("Thieves' Tools"), E("Gaming Set", 1, GamingSetChoice), E("Bedroll"), E("Pouch", 2), E("Traveler's Clothes"))
            Case Else
                Return New List(Of StartingEquipmentPackage)()
        End Select
    End Function

    Public Shared Function GetChoiceOptions(choiceKind As String) As String()
        Select Case choiceKind
            Case MusicalInstrumentChoice
                Return MusicalInstruments
            Case ArtisanToolsChoice
                Return ArtisanTools
            Case GamingSetChoice
                Return GamingSets
            Case ToolOrInstrumentChoice
                Return ArtisanTools.Concat(MusicalInstruments).OrderBy(Function(value) value).ToArray()
            Case Else
                Return Array.Empty(Of String)()
        End Select
    End Function

    Public Shared Function GetChoiceKind(package As StartingEquipmentPackage) As String
        If package Is Nothing Then Return String.Empty
        Dim entry = package.Items.FirstOrDefault(Function(item) Not String.IsNullOrWhiteSpace(item.ChoiceKind))
        Return If(entry Is Nothing, String.Empty, entry.ChoiceKind)
    End Function

    Public Shared Function ResolveItems(package As StartingEquipmentPackage, selectedChoice As String) As List(Of StartingEquipmentEntry)
        Dim result As New List(Of StartingEquipmentEntry)()
        If package Is Nothing Then Return result

        For Each source In package.Items
            Dim name = source.ItemName
            If Not String.IsNullOrWhiteSpace(source.ChoiceKind) AndAlso Not String.IsNullOrWhiteSpace(selectedChoice) Then
                name = selectedChoice.Trim()
            End If
            result.Add(New StartingEquipmentEntry(name, source.Quantity))
        Next
        Return result
    End Function

    Public Shared Function ShouldStartEquipped(itemName As String) As Boolean
        If String.IsNullOrWhiteSpace(itemName) Then Return False
        Dim normalized = itemName.ToLowerInvariant()
        Return normalized.Contains("armor") OrElse normalized = "chain mail" OrElse normalized = "chain shirt" OrElse normalized = "shield"
    End Function

    Private Shared Function StandardBackground(gold As Decimal, ParamArray items As StartingEquipmentEntry()) As List(Of StartingEquipmentPackage)
        Dim description = String.Join(", ", items.Select(Function(item) If(item.Quantity > 1, $"{item.Quantity} {item.ItemName}", item.ItemName)))
        Return New List(Of StartingEquipmentPackage) From {
            Package($"Package A — {description} + {gold:0} GP", gold, items),
            GoldPackage("Option B — 50 GP (buy your own equipment)", 50D)
        }
    End Function

    Private Shared Function Package(label As String, gold As Decimal, ParamArray items As StartingEquipmentEntry()) As StartingEquipmentPackage
        Return New StartingEquipmentPackage With {
            .Label = label,
            .Gold = gold,
            .Items = items.ToList()
        }
    End Function

    Private Shared Function GoldPackage(label As String, gold As Decimal) As StartingEquipmentPackage
        Return New StartingEquipmentPackage With {.Label = label, .Gold = gold}
    End Function

    Private Shared Function E(itemName As String, Optional quantity As Integer = 1, Optional choiceKind As String = "") As StartingEquipmentEntry
        Return New StartingEquipmentEntry(itemName, quantity, choiceKind)
    End Function

    Private Shared Function Normalize(value As String) As String
        Return If(value, String.Empty).Trim().ToLowerInvariant()
    End Function
End Class
