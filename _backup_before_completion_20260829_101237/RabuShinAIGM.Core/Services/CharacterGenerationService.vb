Imports System
Imports System.Collections.Generic
Imports System.Linq

Public Class CharacterGenerationService
    Private ReadOnly _random As Random = Random.Shared

    Public Shared ReadOnly BaseSpecies As String() = {
        "Aasimar", "Dragonborn", "Dwarf", "Elf", "Gnome", "Goliath", "Halfling", "Human", "Orc", "Tiefling"
    }

    ' Every base species remains available, and every base species also receives a
    ' Half version. Example: Dragonborn + Half Dragonborn, Dwarf + Half Dwarf.
    Public Shared ReadOnly Species As String() = BuildSpeciesOptions()

    Public Shared ReadOnly Classes As String() = {
        "Artificer", "Barbarian", "Bard", "Cleric", "Druid", "Fighter", "Monk", "Paladin", "Ranger", "Rogue", "Sorcerer", "Warlock", "Wizard"
    }

    Public Shared ReadOnly Backgrounds As String() = {
        "Acolyte", "Artisan", "Charlatan", "Criminal", "Entertainer", "Farmer", "Guard", "Guide",
        "Hermit", "Merchant", "Noble", "Sage", "Sailor", "Scribe", "Soldier", "Wayfarer"
    }

    Public Shared ReadOnly Alignments As String() = {
        "Lawful Good", "Neutral Good", "Chaotic Good", "Lawful Neutral", "Neutral", "Chaotic Neutral",
        "Lawful Evil", "Neutral Evil", "Chaotic Evil"
    }

    Private Class SpeciesTraitProfile
        Public Property Name As String = String.Empty
        Public Property Speed As Integer = 30
        Public Property SizeName As String = "Medium"
        Public Property Languages As New List(Of String)()
        Public Property AbilityBonuses As New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase)
        Public Property TraitText As String = String.Empty
        Public Property GrantsPerceptionProficiency As Boolean
    End Class

    Private Shared ReadOnly SpeciesProfiles As Dictionary(Of String, SpeciesTraitProfile) = BuildSpeciesProfiles()

    Private Shared ReadOnly BackgroundAbilities As New Dictionary(Of String, String())(StringComparer.OrdinalIgnoreCase) From {
        {"Acolyte", New String() {"INT", "WIS", "CHA"}},
        {"Artisan", New String() {"STR", "DEX", "INT"}},
        {"Charlatan", New String() {"DEX", "CON", "CHA"}},
        {"Criminal", New String() {"DEX", "CON", "INT"}},
        {"Entertainer", New String() {"STR", "DEX", "CHA"}},
        {"Farmer", New String() {"STR", "CON", "WIS"}},
        {"Guard", New String() {"STR", "INT", "WIS"}},
        {"Guide", New String() {"DEX", "CON", "WIS"}},
        {"Hermit", New String() {"CON", "WIS", "CHA"}},
        {"Merchant", New String() {"CON", "INT", "CHA"}},
        {"Noble", New String() {"STR", "INT", "CHA"}},
        {"Sage", New String() {"CON", "INT", "WIS"}},
        {"Sailor", New String() {"STR", "DEX", "WIS"}},
        {"Scribe", New String() {"DEX", "INT", "WIS"}},
        {"Soldier", New String() {"STR", "DEX", "CON"}},
        {"Wayfarer", New String() {"DEX", "WIS", "CHA"}}
    }

    Private Shared ReadOnly ClassArray As New Dictionary(Of String, Integer())(StringComparer.OrdinalIgnoreCase) From {
        {"Artificer", New Integer() {8, 14, 14, 15, 12, 10}},
        {"Barbarian", New Integer() {15, 13, 14, 10, 12, 8}},
        {"Bard", New Integer() {8, 14, 12, 13, 10, 15}},
        {"Cleric", New Integer() {14, 8, 13, 10, 15, 12}},
        {"Druid", New Integer() {8, 12, 14, 13, 15, 10}},
        {"Fighter", New Integer() {15, 14, 13, 8, 10, 12}},
        {"Monk", New Integer() {12, 15, 13, 10, 14, 8}},
        {"Paladin", New Integer() {15, 10, 13, 8, 12, 14}},
        {"Ranger", New Integer() {12, 15, 13, 8, 14, 10}},
        {"Rogue", New Integer() {12, 15, 13, 14, 10, 8}},
        {"Sorcerer", New Integer() {10, 13, 14, 8, 12, 15}},
        {"Warlock", New Integer() {8, 14, 13, 12, 10, 15}},
        {"Wizard", New Integer() {8, 12, 13, 15, 14, 10}}
    }

    Private Shared Function BuildSpeciesOptions() As String()
        Dim result As New List(Of String)()
        For Each speciesName In BaseSpecies
            result.Add(speciesName)
            result.Add("Half " & speciesName)
        Next
        Return result.ToArray()
    End Function

    Private Shared Function BuildSpeciesProfiles() As Dictionary(Of String, SpeciesTraitProfile)
        Dim result As New Dictionary(Of String, SpeciesTraitProfile)(StringComparer.OrdinalIgnoreCase)

        result("Aasimar") = New SpeciesTraitProfile With {
            .Name = "Aasimar", .Speed = 30, .SizeName = "Medium",
            .Languages = New List(Of String) From {"Common", "Celestial"},
            .AbilityBonuses = New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {{"CHA", 2}},
            .TraitText = "Aasimar Traits: Darkvision; Celestial Resistance (resistance to necrotic and radiant damage); Healing Hands; Light Bearer; Celestial Revelation.",
            .GrantsPerceptionProficiency = False
        }
        result("Dragonborn") = New SpeciesTraitProfile With {
            .Name = "Dragonborn", .Speed = 30, .SizeName = "Medium",
            .Languages = New List(Of String) From {"Common", "Draconic"},
            .AbilityBonuses = New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {{"STR", 2}, {"CHA", 1}},
            .TraitText = "Dragonborn Traits: Draconic Ancestry; Breath Weapon; Damage Resistance matching draconic ancestry; Darkvision; Draconic Flight when the campaign/rules grant it.",
            .GrantsPerceptionProficiency = False
        }
        result("Dwarf") = New SpeciesTraitProfile With {
            .Name = "Dwarf", .Speed = 30, .SizeName = "Medium",
            .Languages = New List(Of String) From {"Common", "Dwarvish"},
            .AbilityBonuses = New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {{"CON", 2}},
            .TraitText = "Dwarf Traits: Darkvision; Dwarven Resilience against poison; Dwarven Toughness; Stonecunning; sturdy dwarven physiology.",
            .GrantsPerceptionProficiency = False
        }
        result("Elf") = New SpeciesTraitProfile With {
            .Name = "Elf", .Speed = 30, .SizeName = "Medium",
            .Languages = New List(Of String) From {"Common", "Elvish"},
            .AbilityBonuses = New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {{"DEX", 2}},
            .TraitText = "Elf Traits: Dexterity +2; adult around 100 years and can live over 700 years; Darkvision 60 ft.; Keen Senses (Perception proficiency); Fey Ancestry (advantage against being charmed and immunity to magical sleep); Trance (4-hour meditation instead of normal sleep).",
            .GrantsPerceptionProficiency = True
        }
        result("Gnome") = New SpeciesTraitProfile With {
            .Name = "Gnome", .Speed = 30, .SizeName = "Small",
            .Languages = New List(Of String) From {"Common", "Gnomish"},
            .AbilityBonuses = New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {{"INT", 2}},
            .TraitText = "Gnome Traits: Intelligence +2; Darkvision; Gnomish Cunning (advantage on Intelligence, Wisdom, and Charisma saving throws against magic); Small stature.",
            .GrantsPerceptionProficiency = False
        }
        result("Goliath") = New SpeciesTraitProfile With {
            .Name = "Goliath", .Speed = 35, .SizeName = "Medium",
            .Languages = New List(Of String) From {"Common", "Giant"},
            .AbilityBonuses = New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {{"STR", 2}, {"CON", 1}},
            .TraitText = "Goliath Traits: Strength +2, Constitution +1; Little Giant/Powerful Build; Stone's Endurance; Mountain Born and resistance to cold; 35-foot speed.",
            .GrantsPerceptionProficiency = False
        }
        result("Halfling") = New SpeciesTraitProfile With {
            .Name = "Halfling", .Speed = 30, .SizeName = "Small",
            .Languages = New List(Of String) From {"Common", "Halfling"},
            .AbilityBonuses = New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {{"DEX", 2}},
            .TraitText = "Halfling Traits: Dexterity +2; Lucky; Brave; Halfling Nimbleness; Small stature.",
            .GrantsPerceptionProficiency = False
        }
        result("Human") = New SpeciesTraitProfile With {
            .Name = "Human", .Speed = 30, .SizeName = "Medium",
            .Languages = New List(Of String) From {"Common"},
            .AbilityBonuses = New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {{"STR", 1}, {"DEX", 1}, {"CON", 1}, {"INT", 1}, {"WIS", 1}, {"CHA", 1}},
            .TraitText = "Human Traits: +1 to each ability score for this campaign's hybrid-species rule; versatile heritage; one additional skill/Origin feat choice where appropriate.",
            .GrantsPerceptionProficiency = False
        }
        result("Orc") = New SpeciesTraitProfile With {
            .Name = "Orc", .Speed = 30, .SizeName = "Medium",
            .Languages = New List(Of String) From {"Common", "Orc"},
            .AbilityBonuses = New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {{"STR", 2}, {"CON", 1}},
            .TraitText = "Orc Traits: Strength +2, Constitution +1; Darkvision; Adrenaline Rush; Relentless Endurance; powerful orcish build.",
            .GrantsPerceptionProficiency = False
        }
        result("Tiefling") = New SpeciesTraitProfile With {
            .Name = "Tiefling", .Speed = 30, .SizeName = "Medium",
            .Languages = New List(Of String) From {"Common", "Infernal"},
            .AbilityBonuses = New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {{"CHA", 2}, {"INT", 1}},
            .TraitText = "Tiefling Traits: Charisma +2, Intelligence +1; Darkvision; resistance to fire damage; Infernal Legacy magic such as Thaumaturgy, Hellish Rebuke, and Darkness as level progression permits.",
            .GrantsPerceptionProficiency = False
        }

        Return result
    End Function

    Public Shared Function IsHalfSpeciesSelection(speciesName As String) As Boolean
        Dim value = If(speciesName, String.Empty).Trim()
        Return value.StartsWith("Half ", StringComparison.OrdinalIgnoreCase)
    End Function

    Public Shared Function GetPrimaryHeritage(speciesName As String) As String
        Dim value = If(speciesName, String.Empty).Trim()
        If value.Length = 0 Then Return String.Empty
        If value.Contains("/") Then value = value.Split("/"c)(0).Trim()
        If value.StartsWith("Half ", StringComparison.OrdinalIgnoreCase) Then value = value.Substring(5).Trim()
        Return BaseSpecies.FirstOrDefault(Function(s) s.Equals(value, StringComparison.OrdinalIgnoreCase))
    End Function

    Public Shared Function GetSecondaryHeritage(speciesDisplay As String) As String
        Dim value = If(speciesDisplay, String.Empty).Trim()
        If Not value.Contains("/") Then Return String.Empty
        Dim parts = value.Split("/"c)
        If parts.Length < 2 Then Return String.Empty
        Dim second = parts(1).Trim()
        If second.StartsWith("Half ", StringComparison.OrdinalIgnoreCase) Then second = second.Substring(5).Trim()
        Return BaseSpecies.FirstOrDefault(Function(s) s.Equals(second, StringComparison.OrdinalIgnoreCase))
    End Function

    Public Shared Function GetSpeciesSelectionForDisplay(speciesDisplay As String) As String
        Dim primary = GetPrimaryHeritage(speciesDisplay)
        If String.IsNullOrWhiteSpace(primary) Then Return speciesDisplay
        If IsHalfSpeciesSelection(speciesDisplay) Then Return "Half " & primary
        Return primary
    End Function

    Public Shared Function GetAvailableSecondaryHeritages(primaryHeritage As String) As String()
        Dim primary = If(primaryHeritage, String.Empty).Trim()
        Return BaseSpecies.Where(Function(s) Not s.Equals(primary, StringComparison.OrdinalIgnoreCase)).ToArray()
    End Function

    Public Shared Function BuildHybridSpeciesName(primaryHeritage As String, secondaryHeritage As String) As String
        Dim primary = If(primaryHeritage, String.Empty).Trim()
        Dim secondary = If(secondaryHeritage, String.Empty).Trim()
        If primary.Length = 0 Then Return secondary
        If secondary.Length = 0 Then Return "Half " & primary
        Return "Half " & primary & " / Half " & secondary
    End Function

    Public Shared Function HasHeritage(speciesDisplay As String, heritageName As String) As Boolean
        Dim wanted = If(heritageName, String.Empty).Trim()
        If wanted.Length = 0 Then Return False
        Return String.Equals(GetPrimaryHeritage(speciesDisplay), wanted, StringComparison.OrdinalIgnoreCase) OrElse
               String.Equals(GetSecondaryHeritage(speciesDisplay), wanted, StringComparison.OrdinalIgnoreCase)
    End Function

    Public Function Generate(speciesName As String, className As String, level As Integer, requestedName As String) As PlayerCharacter
        Dim selectedSpecies = If(speciesName, String.Empty).Trim()
        Dim primaryHeritage = GetPrimaryHeritage(selectedSpecies)
        If String.IsNullOrWhiteSpace(primaryHeritage) Then primaryHeritage = selectedSpecies

        Dim secondaryHeritage As String = String.Empty
        If IsHalfSpeciesSelection(selectedSpecies) Then
            Dim choices = GetAvailableSecondaryHeritages(primaryHeritage)
            If choices.Length > 0 Then secondaryHeritage = choices(_random.Next(choices.Length))
        End If

        Dim displaySpecies = If(String.IsNullOrWhiteSpace(secondaryHeritage), primaryHeritage, BuildHybridSpeciesName(primaryHeritage, secondaryHeritage))
        Dim c As New PlayerCharacter With {
            .SpeciesName = displaySpecies,
            .ClassName = className,
            .Level = Math.Max(1, Math.Min(20, level)),
            .CharacterName = If(String.IsNullOrWhiteSpace(requestedName), GenerateName(displaySpecies), requestedName.Trim()),
            .Alignment = Alignments(_random.Next(0, 6)),
            .ExperiencePoints = 0
        }

        Dim rolled = Enumerable.Range(1, 6).Select(Function(i) RollAbility()).OrderByDescending(Function(v) v).ToList()
        AssignByClassPriority(c, className, rolled)

        c.BackgroundName = ChooseBackground(className)
        ApplyBackgroundBoost(c, c.BackgroundName, className)
        c.ProficiencyBonus = ProficiencyForLevel(c.Level)
        ApplyHeritageTraits(c, primaryHeritage, secondaryHeritage, True)
        If HasHeritage(c.SpeciesName, "Dragonborn") Then ApplyRandomDraconicAncestry(c)
        c.Initiative = PlayerCharacter.AbilityModifier(c.Dexterity)
        c.PassivePerception = 10 + PlayerCharacter.AbilityModifier(c.Wisdom) + If(HasHeritage(c.SpeciesName, "Elf"), c.ProficiencyBonus, 0)
        c.HitDice = $"{c.Level}d{GetHitDie(className)}"
        c.CurrentHitDice = c.Level
        c.MaxHitPoints = CalculateHitPoints(className, c.Level, c.Constitution)
        c.CurrentHitPoints = c.MaxHitPoints
        c.ArmorClass = EstimateArmorClass(className, c)
        c.Gold = 15D + _random.Next(0, 36)
        c.Appearance = GenerateAppearance(c.SpeciesName, className)
        c.Personality = GeneratePersonality(c)
        c.Backstory = GenerateBackstory(c)
        c.Proficiencies = GenerateProficiencies(className, c.BackgroundName, c.SpeciesName)
        ConfigureSpellcasting(c)
        Return c
    End Function

    Public Shared Sub ApplyHeritageTraits(character As PlayerCharacter, primaryHeritage As String, secondaryHeritage As String, applyAbilityBonuses As Boolean)
        If character Is Nothing Then Return
        Dim primary As SpeciesTraitProfile = Nothing
        If Not SpeciesProfiles.TryGetValue(If(primaryHeritage, String.Empty).Trim(), primary) Then Return

        Dim secondary As SpeciesTraitProfile = Nothing
        If Not String.IsNullOrWhiteSpace(secondaryHeritage) Then SpeciesProfiles.TryGetValue(secondaryHeritage.Trim(), secondary)

        If applyAbilityBonuses Then
            ApplyAbilityBonus(character, primary)
            If secondary IsNot Nothing Then ApplyAbilityBonus(character, secondary)
        End If

        character.Speed = primary.Speed
        character.SizeName = primary.SizeName
        If secondary IsNot Nothing Then character.Speed = Math.Max(character.Speed, secondary.Speed)

        Dim languages As New List(Of String)()
        AddDistinct(languages, primary.Languages)
        If secondary IsNot Nothing Then AddDistinct(languages, secondary.Languages)
        If HasProfile(primary, "Human") OrElse HasProfile(secondary, "Human") Then
            If languages.Count < 3 Then languages.Add("One additional language of your choice")
        End If
        character.Languages = String.Join(", ", languages)

        Dim features As New List(Of String)()
        If secondary IsNot Nothing Then
            features.Add($"Hybrid Heritage (campaign rule): {character.SpeciesName} inherits racial traits from both {primary.Name} and {secondary.Name}. Racial ability bonuses from both heritages are applied during character creation, with no score exceeding 20.")
        Else
            features.Add($"{primary.Name} Heritage (campaign rule).")
        End If
        features.Add(primary.TraitText)
        If secondary IsNot Nothing Then features.Add(secondary.TraitText)
        If Not String.IsNullOrWhiteSpace(character.ClassName) Then features.Add($"Review the {character.ClassName} level {character.Level} class features for this character.")
        character.Features = String.Join(Environment.NewLine & Environment.NewLine, features)
    End Sub

    Private Shared Function HasProfile(profile As SpeciesTraitProfile, name As String) As Boolean
        Return profile IsNot Nothing AndAlso profile.Name.Equals(name, StringComparison.OrdinalIgnoreCase)
    End Function

    Private Shared Sub AddDistinct(target As List(Of String), values As IEnumerable(Of String))
        If values Is Nothing Then Return
        For Each value In values
            If String.IsNullOrWhiteSpace(value) Then Continue For
            If Not target.Contains(value, StringComparer.OrdinalIgnoreCase) Then target.Add(value)
        Next
    End Sub

    Private Shared Sub ApplyAbilityBonus(character As PlayerCharacter, profile As SpeciesTraitProfile)
        If character Is Nothing OrElse profile Is Nothing Then Return
        For Each pair In profile.AbilityBonuses
            SetAbility(character, pair.Key, Math.Min(20, GetAbility(character, pair.Key) + pair.Value))
        Next
    End Sub

    Private Sub ApplyRandomDraconicAncestry(character As PlayerCharacter)
        Dim ancestries = New String() {
            "Black — Acid", "Blue — Lightning", "Brass — Fire", "Bronze — Lightning", "Copper — Acid",
            "Gold — Fire", "Green — Poison", "Red — Fire", "Silver — Cold", "White — Cold"
        }
        Dim chosen = ancestries(_random.Next(ancestries.Length))
        character.Features &= Environment.NewLine & Environment.NewLine &
                              "Generated Draconic Ancestry: " & chosen & ". The Dragonborn Breath Weapon and Damage Resistance use this ancestry's damage type."
    End Sub

    Public Shared Function IsSpellcastingClass(className As String) As Boolean
        Select Case className.Trim().ToLowerInvariant()
            Case "artificer", "bard", "cleric", "druid", "paladin", "ranger", "sorcerer", "warlock", "wizard"
                Return True
            Case Else
                Return False
        End Select
    End Function

    Private Function RollAbility() As Integer
        Dim dice As New List(Of Integer)()
        For i = 1 To 4
            dice.Add(_random.Next(1, 7))
        Next
        dice.Sort()
        Return dice(1) + dice(2) + dice(3)
    End Function

    Private Shared Sub AssignByClassPriority(c As PlayerCharacter, className As String, rolls As List(Of Integer))
        Dim template As Integer() = Nothing
        If Not ClassArray.TryGetValue(className, template) Then template = New Integer() {15, 14, 13, 12, 10, 8}

        Dim rankedAbilities = Enumerable.Range(0, 6).OrderByDescending(Function(i) template(i)).ToList()
        Dim values(5) As Integer
        For i = 0 To 5
            values(rankedAbilities(i)) = rolls(i)
        Next
        c.Strength = values(0)
        c.Dexterity = values(1)
        c.Constitution = values(2)
        c.Intelligence = values(3)
        c.Wisdom = values(4)
        c.Charisma = values(5)
    End Sub

    Private Function ChooseBackground(className As String) As String
        Dim primary = GetPrimaryAbility(className)
        Dim matching = Backgrounds.Where(Function(bg) BackgroundAbilities(bg).Contains(primary, StringComparer.OrdinalIgnoreCase)).ToList()
        If matching.Count = 0 Then Return Backgrounds(_random.Next(Backgrounds.Length))
        Return matching(_random.Next(matching.Count))
    End Function

    Private Shared Sub ApplyBackgroundBoost(c As PlayerCharacter, background As String, className As String)
        Dim allowed = BackgroundAbilities(background)
        Dim primary = GetPrimaryAbility(className)
        Dim first = If(allowed.Contains(primary, StringComparer.OrdinalIgnoreCase), primary, allowed(0))
        Dim second = allowed.First(Function(a) Not a.Equals(first, StringComparison.OrdinalIgnoreCase))
        SetAbility(c, first, Math.Min(20, GetAbility(c, first) + 2))
        SetAbility(c, second, Math.Min(20, GetAbility(c, second) + 1))
    End Sub

    Private Shared Function GetPrimaryAbility(className As String) As String
        Select Case className.Trim().ToLowerInvariant()
            Case "barbarian", "paladin" : Return "STR"
            Case "bard", "sorcerer", "warlock" : Return "CHA"
            Case "cleric", "druid" : Return "WIS"
            Case "fighter" : Return "STR"
            Case "monk", "ranger", "rogue" : Return "DEX"
            Case "wizard", "artificer" : Return "INT"
            Case Else : Return "STR"
        End Select
    End Function

    Private Shared Function GetAbility(c As PlayerCharacter, key As String) As Integer
        Select Case key.ToUpperInvariant()
            Case "STR" : Return c.Strength
            Case "DEX" : Return c.Dexterity
            Case "CON" : Return c.Constitution
            Case "INT" : Return c.Intelligence
            Case "WIS" : Return c.Wisdom
            Case "CHA" : Return c.Charisma
            Case Else : Return 10
        End Select
    End Function

    Private Shared Sub SetAbility(c As PlayerCharacter, key As String, value As Integer)
        Select Case key.ToUpperInvariant()
            Case "STR" : c.Strength = value
            Case "DEX" : c.Dexterity = value
            Case "CON" : c.Constitution = value
            Case "INT" : c.Intelligence = value
            Case "WIS" : c.Wisdom = value
            Case "CHA" : c.Charisma = value
        End Select
    End Sub

    Private Shared Function ProficiencyForLevel(level As Integer) As Integer
        Return 2 + ((Math.Max(1, level) - 1) \ 4)
    End Function

    Private Shared Function GetHitDie(className As String) As Integer
        Select Case className.Trim().ToLowerInvariant()
            Case "barbarian" : Return 12
            Case "fighter", "paladin", "ranger" : Return 10
            Case "sorcerer", "wizard" : Return 6
            Case Else : Return 8
        End Select
    End Function

    Private Shared Function CalculateHitPoints(className As String, level As Integer, constitution As Integer) As Integer
        Dim die = GetHitDie(className)
        Dim conMod = PlayerCharacter.AbilityModifier(constitution)
        Dim total = die + conMod
        Dim average = (die \ 2) + 1
        For i = 2 To level
            total += Math.Max(1, average + conMod)
        Next
        Return Math.Max(level, total)
    End Function

    Private Shared Function EstimateArmorClass(className As String, c As PlayerCharacter) As Integer
        Dim dexMod = PlayerCharacter.AbilityModifier(c.Dexterity)
        Dim wisMod = PlayerCharacter.AbilityModifier(c.Wisdom)
        Dim conMod = PlayerCharacter.AbilityModifier(c.Constitution)
        Select Case className.Trim().ToLowerInvariant()
            Case "barbarian" : Return 10 + dexMod + conMod
            Case "monk" : Return 10 + dexMod + wisMod
            Case "fighter", "paladin" : Return 16
            Case "cleric" : Return 16
            Case "ranger", "artificer" : Return 14 + Math.Min(2, dexMod)
            Case "bard", "rogue", "warlock" : Return 11 + dexMod
            Case "druid" : Return 12 + Math.Min(2, dexMod)
            Case Else : Return 10 + dexMod
        End Select
    End Function

    Private Shared Sub ConfigureSpellcasting(c As PlayerCharacter)
        Select Case c.ClassName.Trim().ToLowerInvariant()
            Case "bard", "sorcerer", "warlock", "paladin"
                c.SpellcastingAbility = "Charisma"
            Case "cleric", "druid", "ranger"
                c.SpellcastingAbility = "Wisdom"
            Case "wizard", "artificer"
                c.SpellcastingAbility = "Intelligence"
            Case Else
                c.SpellcastingAbility = String.Empty
        End Select
        If String.IsNullOrWhiteSpace(c.SpellcastingAbility) Then Return
        Dim abilityScore As Integer
        Select Case c.SpellcastingAbility
            Case "Charisma" : abilityScore = c.Charisma
            Case "Wisdom" : abilityScore = c.Wisdom
            Case Else : abilityScore = c.Intelligence
        End Select
        Dim modifier = PlayerCharacter.AbilityModifier(abilityScore)
        c.SpellSaveDC = 8 + c.ProficiencyBonus + modifier
        c.SpellAttackBonus = c.ProficiencyBonus + modifier
    End Sub

    Private Function GenerateName(speciesName As String) As String
        Dim firstNames = New String() {"Aren", "Bryn", "Cael", "Dara", "Edrin", "Fara", "Galen", "Ilyra", "Kael", "Liora", "Marek", "Neris", "Orin", "Rhea", "Tavian", "Vara"}
        Dim lastNames = New String() {"Ashfall", "Brightwater", "Dawnmere", "Emberward", "Greybrook", "Ironwood", "Mooncrest", "Ravenmark", "Stonepath", "Thornvale", "Windmere"}
        Return firstNames(_random.Next(firstNames.Length)) & " " & lastNames(_random.Next(lastNames.Length))
    End Function

    Private Function GenerateAppearance(speciesName As String, className As String) As String
        Dim builds = New String() {"lean", "athletic", "broad-shouldered", "compact", "rangy", "powerfully built"}
        Dim eyes = New String() {"gray", "green", "amber", "blue", "violet", "dark brown", "silver-flecked"}
        Dim details = New String() {"a weathered travel cloak", "a braided leather wrist cord", "a small collection of old scars", "carefully maintained adventuring gear", "a distinctive silver clasp", "a practical belt of pouches"}
        Return $"A {builds(_random.Next(builds.Length))} {speciesName} with {eyes(_random.Next(eyes.Length))} eyes. Their {className.ToLowerInvariant()} training shows in their posture and equipment, and they are usually recognized by {details(_random.Next(details.Length))}."
    End Function

    Private Function GeneratePersonality(c As PlayerCharacter) As String
        Dim traits = New String() {"calm under pressure", "curious and observant", "protective of companions", "dryly humorous", "methodical and patient", "bold when others hesitate", "quiet but fiercely loyal"}
        Return $"{traits(_random.Next(traits.Length))}; approaches danger with the instincts of a {c.ClassName.ToLowerInvariant()} but still carries habits from a {c.BackgroundName.ToLowerInvariant()} life."
    End Function

    Private Function GenerateBackstory(c As PlayerCharacter) As String
        Dim reasons = New String() {"a missing friend", "an unanswered mystery", "a debt that cannot be paid with coin", "a promise made to family", "a desire to prove their worth", "rumors of unnatural changes spreading between settlements"}
        Return $"Before becoming an adventurer, {c.CharacterName} lived as a {c.BackgroundName.ToLowerInvariant()}. They took up the path of the {c.ClassName.ToLowerInvariant()} after {reasons(_random.Next(reasons.Length))} pushed them away from ordinary life."
    End Function

    Private Shared Function GenerateProficiencies(className As String, background As String, speciesDisplay As String) As String
        Dim extra = If(HasHeritage(speciesDisplay, "Elf"), " Species proficiency: Perception (Keen Senses).", String.Empty)
        Return $"Class proficiencies: {className}. Background proficiencies: {background}.{extra} Use the Manual Sheet to record any additional exact skills, tools, weapons, armor, and saving throws chosen for this character."
    End Function
End Class
