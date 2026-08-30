Imports System
Imports System.Collections.Generic
Imports System.IO
Imports System.Linq
Imports System.Text.Json

Public Class DiscordSpellProgression
    Public Property ClassName As String = String.Empty
    Public Property CharacterLevel As Integer
    Public Property CantripsKnown As Integer
    Public Property PreparedSpells As Integer
    Public Property MaxSpellLevel As Integer
    Public Property WizardSpellbookCount As Integer
    Public Property SpellSlots As New Dictionary(Of Integer, Integer)()
    Public Property WarlockArcanumLevels As New List(Of Integer)()
End Class

Public NotInheritable Class DiscordSpellService
    Private Sub New()
    End Sub

    Private Shared ReadOnly FullCasterPrepared As Integer() = {4, 5, 6, 7, 9, 10, 11, 12, 14, 15, 16, 16, 17, 17, 18, 18, 19, 20, 21, 22}
    Private Shared ReadOnly SorcererPrepared As Integer() = {2, 4, 6, 7, 9, 10, 11, 12, 14, 15, 16, 16, 17, 17, 18, 18, 19, 20, 21, 22}
    Private Shared ReadOnly WizardPrepared As Integer() = {4, 5, 6, 7, 9, 10, 11, 12, 14, 15, 16, 16, 17, 18, 19, 21, 22, 23, 24, 25}
    Private Shared ReadOnly HalfCasterPrepared As Integer() = {2, 3, 4, 5, 6, 6, 7, 7, 9, 9, 10, 10, 11, 11, 12, 12, 14, 14, 15, 15}
    Private Shared ReadOnly ArtificerPrepared As Integer() = {2, 3, 4, 5, 6, 6, 7, 7, 9, 9, 10, 10, 11, 11, 12, 12, 14, 14, 15, 15}
    Private Shared ReadOnly WarlockPrepared As Integer() = {2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15}
    Private Shared ReadOnly WarlockSlots As Integer() = {1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4}
    Private Shared ReadOnly WarlockSlotLevels As Integer() = {1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5}

    Private Shared ReadOnly FullCasterSlots As Integer()() = {
        New Integer() {2,0,0,0,0,0,0,0,0},
        New Integer() {3,0,0,0,0,0,0,0,0},
        New Integer() {4,2,0,0,0,0,0,0,0},
        New Integer() {4,3,0,0,0,0,0,0,0},
        New Integer() {4,3,2,0,0,0,0,0,0},
        New Integer() {4,3,3,0,0,0,0,0,0},
        New Integer() {4,3,3,1,0,0,0,0,0},
        New Integer() {4,3,3,2,0,0,0,0,0},
        New Integer() {4,3,3,3,1,0,0,0,0},
        New Integer() {4,3,3,3,2,0,0,0,0},
        New Integer() {4,3,3,3,2,1,0,0,0},
        New Integer() {4,3,3,3,2,1,0,0,0},
        New Integer() {4,3,3,3,2,1,1,0,0},
        New Integer() {4,3,3,3,2,1,1,0,0},
        New Integer() {4,3,3,3,2,1,1,1,0},
        New Integer() {4,3,3,3,2,1,1,1,0},
        New Integer() {4,3,3,3,2,1,1,1,1},
        New Integer() {4,3,3,3,3,1,1,1,1},
        New Integer() {4,3,3,3,3,2,1,1,1},
        New Integer() {4,3,3,3,3,2,2,1,1}
    }

    Private Shared ReadOnly HalfCasterSlots As Integer()() = {
        New Integer() {2,0,0,0,0}, New Integer() {2,0,0,0,0}, New Integer() {3,0,0,0,0}, New Integer() {3,0,0,0,0},
        New Integer() {4,2,0,0,0}, New Integer() {4,2,0,0,0}, New Integer() {4,3,0,0,0}, New Integer() {4,3,0,0,0},
        New Integer() {4,3,2,0,0}, New Integer() {4,3,2,0,0}, New Integer() {4,3,3,0,0}, New Integer() {4,3,3,0,0},
        New Integer() {4,3,3,1,0}, New Integer() {4,3,3,1,0}, New Integer() {4,3,3,2,0}, New Integer() {4,3,3,2,0},
        New Integer() {4,3,3,3,1}, New Integer() {4,3,3,3,1}, New Integer() {4,3,3,3,2}, New Integer() {4,3,3,3,2}
    }

    Public Shared Function IsSupportedCaster(className As String) As Boolean
        Select Case Normalize(className)
            Case "bard", "cleric", "druid", "paladin", "ranger", "sorcerer", "warlock", "wizard", "artificer"
                Return True
            Case Else
                Return False
        End Select
    End Function

    Public Shared Function GetProgression(className As String, characterLevel As Integer) As DiscordSpellProgression
        Dim level = Math.Max(1, Math.Min(20, characterLevel))
        Dim result As New DiscordSpellProgression With {.ClassName = className, .CharacterLevel = level}

        Select Case Normalize(className)
            Case "bard"
                result.CantripsKnown = If(level < 4, 2, If(level < 10, 3, 4))
                result.PreparedSpells = FullCasterPrepared(level - 1)
                AddSlots(result, FullCasterSlots(level - 1))
            Case "cleric"
                result.CantripsKnown = If(level < 4, 3, If(level < 10, 4, 5))
                result.PreparedSpells = FullCasterPrepared(level - 1)
                AddSlots(result, FullCasterSlots(level - 1))
            Case "druid"
                result.CantripsKnown = If(level < 4, 2, If(level < 10, 3, 4))
                result.PreparedSpells = FullCasterPrepared(level - 1)
                AddSlots(result, FullCasterSlots(level - 1))
            Case "sorcerer"
                result.CantripsKnown = If(level < 4, 4, If(level < 10, 5, 6))
                result.PreparedSpells = SorcererPrepared(level - 1)
                AddSlots(result, FullCasterSlots(level - 1))
            Case "wizard"
                result.CantripsKnown = If(level < 4, 3, If(level < 10, 4, 5))
                result.PreparedSpells = WizardPrepared(level - 1)
                result.WizardSpellbookCount = 6 + ((level - 1) * 2)
                AddSlots(result, FullCasterSlots(level - 1))
            Case "paladin", "ranger"
                result.CantripsKnown = 0
                result.PreparedSpells = HalfCasterPrepared(level - 1)
                AddSlots(result, HalfCasterSlots(level - 1))
            Case "artificer"
                result.CantripsKnown = If(level < 10, 2, If(level < 14, 3, 4))
                result.PreparedSpells = ArtificerPrepared(level - 1)
                AddSlots(result, HalfCasterSlots(level - 1))
            Case "warlock"
                result.CantripsKnown = If(level < 4, 2, If(level < 10, 3, 4))
                result.PreparedSpells = WarlockPrepared(level - 1)
                result.SpellSlots(WarlockSlotLevels(level - 1)) = WarlockSlots(level - 1)
                If level >= 11 Then result.WarlockArcanumLevels.Add(6)
                If level >= 13 Then result.WarlockArcanumLevels.Add(7)
                If level >= 15 Then result.WarlockArcanumLevels.Add(8)
                If level >= 17 Then result.WarlockArcanumLevels.Add(9)
        End Select

        result.MaxSpellLevel = If(result.SpellSlots.Count = 0, 0, result.SpellSlots.Keys.Max())
        Return result
    End Function

    Public Shared Function GetAvailableSpells(className As String, characterLevel As Integer) As List(Of SrdSpellReference)
        Dim all = LoadSpells()
        Dim progression = GetProgression(className, characterLevel)
        Dim wanted As IEnumerable(Of SrdSpellReference)

        If Normalize(className) = "artificer" Then
            wanted = GetArtificerSpellReferences(all)
        ElseIf Normalize(className) = "bard" AndAlso characterLevel >= 10 Then
            Dim allowedClasses As New HashSet(Of String)(StringComparer.OrdinalIgnoreCase) From {"Bard", "Cleric", "Druid", "Wizard"}
            wanted = all.Where(Function(s) s.Classes IsNot Nothing AndAlso
                                        ((s.Level = 0 AndAlso s.Classes.Any(Function(c) c.Equals("Bard", StringComparison.OrdinalIgnoreCase))) OrElse
                                         (s.Level > 0 AndAlso s.Classes.Any(Function(c) allowedClasses.Contains(c)))))
        Else
            wanted = all.Where(Function(s) s.Classes IsNot Nothing AndAlso s.Classes.Any(Function(c) c.Equals(className, StringComparison.OrdinalIgnoreCase)))
        End If

        Dim maximumLevel = Math.Max(progression.MaxSpellLevel, If(Normalize(className) = "warlock", 9, 0))
        Return wanted.Where(Function(s) s.Level = 0 OrElse s.Level <= maximumLevel).
            GroupBy(Function(s) s.Name, StringComparer.OrdinalIgnoreCase).
            Select(Function(g) g.First()).
            OrderBy(Function(s) s.Level).
            ThenBy(Function(s) s.Name).
            ToList()
    End Function

    Public Shared Function GetBaseAlwaysPreparedSpellNames(className As String, characterLevel As Integer) As List(Of String)
        Dim level = Math.Max(1, Math.Min(20, characterLevel))
        Dim result As New List(Of String)()
        Select Case Normalize(className)
            Case "artificer"
                result.Add("Mending")
            Case "druid"
                result.Add("Speak with Animals")
            Case "ranger"
                result.Add("Hunter's Mark")
            Case "paladin"
                If level >= 2 Then result.Add("Divine Smite")
                If level >= 5 Then result.Add("Find Steed")
            Case "warlock"
                If level >= 9 Then result.Add("Contact Other Plane")
            Case "bard"
                If level >= 20 Then
                    result.Add("Power Word Heal")
                    result.Add("Power Word Kill")
                End If
        End Select
        Return result
    End Function

    Private Shared Function LoadSpells() As List(Of SrdSpellReference)
        Dim candidates As String() = {
            System.IO.Path.Combine(AppContext.BaseDirectory, "Data", "srd_spells_5_2_1.json"),
            System.IO.Path.Combine(AppContext.BaseDirectory, "srd_spells_5_2_1.json")
        }

        Dim selectedPath As String =
            candidates.FirstOrDefault(
                Function(candidatePath) File.Exists(candidatePath)
            )

        If String.IsNullOrWhiteSpace(selectedPath) Then
            Return New List(Of SrdSpellReference)()
        End If

        Dim options As New JsonSerializerOptions With {
            .PropertyNameCaseInsensitive = True
        }

        Return JsonSerializer.Deserialize(Of List(Of SrdSpellReference))(
            File.ReadAllText(selectedPath),
            options
        )
    End Function

    Private Shared Sub AddSlots(result As DiscordSpellProgression, values As Integer())
        For i = 0 To values.Length - 1
            If values(i) > 0 Then result.SpellSlots(i + 1) = values(i)
        Next
    End Sub

    Private Shared Function Normalize(value As String) As String
        Return If(value, String.Empty).Trim().ToLowerInvariant()
    End Function

    Private Shared Function GetArtificerSpellReferences(all As List(Of SrdSpellReference)) As List(Of SrdSpellReference)
        Dim byName As New Dictionary(Of String, SrdSpellReference)(StringComparer.OrdinalIgnoreCase)
        For Each reference In all
            If reference Is Nothing Then Continue For
            If Not String.IsNullOrWhiteSpace(reference.Name) Then byName(reference.Name.Replace("’"c, "'"c)) = reference
            If Not String.IsNullOrWhiteSpace(reference.PhbTitle) Then byName(reference.PhbTitle.Replace("’"c, "'"c)) = reference
        Next

        Dim result As New List(Of SrdSpellReference)()
        Dim levels As New Dictionary(Of Integer, String()) From {
            {0, New String() {"Acid Splash","Dancing Lights","Elementalism","Fire Bolt","Guidance","Light","Mage Hand","Message","Poison Spray","Prestidigitation","Ray of Frost","Resistance","Shocking Grasp","Spare the Dying","Thorn Whip","Thunderclap","True Strike","Mending"}},
            {1, New String() {"Alarm","Cure Wounds","Detect Magic","Disguise Self","Expeditious Retreat","Faerie Fire","False Life","Feather Fall","Grease","Identify","Jump","Longstrider","Purify Food and Drink","Sanctuary"}},
            {2, New String() {"Aid","Alter Self","Arcane Lock","Arcane Vigor","Blur","Continual Flame","Darkvision","Dragon's Breath","Enhance Ability","Enlarge/Reduce","Heat Metal","Invisibility","Lesser Restoration","Levitate","Magic Mouth","Magic Weapon","Protection from Poison","Rope Trick","See Invisibility","Spider Climb","Web"}},
            {3, New String() {"Blink","Create Food and Water","Dispel Magic","Elemental Weapon","Fly","Glyph of Warding","Haste","Protection from Energy","Revivify","Water Breathing","Water Walk"}},
            {4, New String() {"Arcane Eye","Fabricate","Freedom of Movement","Leomund's Secret Chest","Mordenkainen's Faithful Hound","Mordenkainen's Private Sanctum","Otiluke's Resilient Sphere","Stone Shape","Stoneskin","Summon Construct"}},
            {5, New String() {"Animate Objects","Bigby's Hand","Circle of Power","Creation","Greater Restoration","Wall of Stone"}}
        }

        For Each levelGroup In levels
            For Each name In levelGroup.Value
                Dim reference As SrdSpellReference = Nothing
                Dim lookupName = name.Replace("’"c, "'"c)
                If byName.TryGetValue(lookupName, reference) Then
                    result.Add(CloneReference(reference, "Artificer", levelGroup.Key))
                Else
                    result.Add(New SrdSpellReference With {.Name = name, .Level = levelGroup.Key, .School = "Expanded", .Classes = New List(Of String) From {"Artificer"}})
                End If
            Next
        Next
        Return result
    End Function

    Private Shared Function CloneReference(reference As SrdSpellReference, className As String, level As Integer) As SrdSpellReference
        Return New SrdSpellReference With {
            .Name = reference.Name,
            .PhbTitle = reference.PhbTitle,
            .Level = level,
            .School = reference.School,
            .Classes = New List(Of String) From {className},
            .CastingTime = reference.CastingTime,
            .Range = reference.Range,
            .Components = reference.Components,
            .Duration = reference.Duration,
            .Description = reference.Description,
            .DamageDice = reference.DamageDice,
            .DamageType = reference.DamageType,
            .HealingDice = reference.HealingDice,
            .AreaShape = reference.AreaShape,
            .AreaSizeFeet = reference.AreaSizeFeet,
            .RangeFeet = reference.RangeFeet,
            .Concentration = reference.Concentration
        }
    End Function
End Class
