Imports System
Imports System.Linq

Public NotInheritable Class ManualCharacterCreationService

    Private Sub New()
    End Sub


    Public Shared Function Create(
        characterName As String,
        speciesSelection As String,
        secondaryHeritage As String,
        className As String,
        backgroundName As String,
        alignment As String,
        level As Integer,
        strength As Integer,
        dexterity As Integer,
        constitution As Integer,
        intelligence As Integer,
        wisdom As Integer,
        charisma As Integer,
        appearance As String,
        personality As String,
        backstory As String,
        notes As String
    ) As PlayerCharacter

        ' =====================================================
        ' BASIC VALIDATION
        ' =====================================================

        If String.IsNullOrWhiteSpace(characterName) Then
            Throw New ArgumentException(
                "Character name is required."
            )
        End If


        If level < 1 OrElse level > 20 Then
            Throw New ArgumentOutOfRangeException(
                NameOf(level),
                "Character level must be between 1 and 20."
            )
        End If


        ValidateAbility(
            "Strength",
            strength
        )

        ValidateAbility(
            "Dexterity",
            dexterity
        )

        ValidateAbility(
            "Constitution",
            constitution
        )

        ValidateAbility(
            "Intelligence",
            intelligence
        )

        ValidateAbility(
            "Wisdom",
            wisdom
        )

        ValidateAbility(
            "Charisma",
            charisma
        )


        ' =====================================================
        ' VALIDATE SPECIES
        ' =====================================================

        Dim validSpecies =
            CharacterGenerationService.Species.FirstOrDefault(
                Function(value)
                    Return value.Equals(
                        speciesSelection,
                        StringComparison.OrdinalIgnoreCase
                    )
                End Function
            )


        If String.IsNullOrWhiteSpace(validSpecies) Then
            Throw New ArgumentException(
                "Invalid species."
            )
        End If


        ' =====================================================
        ' VALIDATE CLASS
        ' =====================================================

        Dim validClass =
            CharacterGenerationService.Classes.FirstOrDefault(
                Function(value)
                    Return value.Equals(
                        className,
                        StringComparison.OrdinalIgnoreCase
                    )
                End Function
            )


        If String.IsNullOrWhiteSpace(validClass) Then
            Throw New ArgumentException(
                "Invalid class."
            )
        End If


        ' =====================================================
        ' VALIDATE BACKGROUND
        ' =====================================================

        Dim validBackground =
            CharacterGenerationService.Backgrounds.FirstOrDefault(
                Function(value)
                    Return value.Equals(
                        backgroundName,
                        StringComparison.OrdinalIgnoreCase
                    )
                End Function
            )


        If String.IsNullOrWhiteSpace(validBackground) Then
            Throw New ArgumentException(
                "Invalid background."
            )
        End If


        ' =====================================================
        ' VALIDATE ALIGNMENT
        ' =====================================================

        Dim validAlignment =
            CharacterGenerationService.Alignments.FirstOrDefault(
                Function(value)
                    Return value.Equals(
                        alignment,
                        StringComparison.OrdinalIgnoreCase
                    )
                End Function
            )


        If String.IsNullOrWhiteSpace(validAlignment) Then
            Throw New ArgumentException(
                "Invalid alignment."
            )
        End If


        ' =====================================================
        ' HERITAGE
        ' =====================================================

        Dim primaryHeritage =
            CharacterGenerationService.GetPrimaryHeritage(
                validSpecies
            )


        Dim actualSecondaryHeritage As String =
            String.Empty


        If CharacterGenerationService.IsHalfSpeciesSelection(
            validSpecies
        ) Then

            If String.IsNullOrWhiteSpace(
                secondaryHeritage
            ) Then

                Throw New ArgumentException(
                    "Choose the Other Half for this character."
                )

            End If


            actualSecondaryHeritage =
                CharacterGenerationService.BaseSpecies.FirstOrDefault(
                    Function(value)
                        Return value.Equals(
                            secondaryHeritage,
                            StringComparison.OrdinalIgnoreCase
                        )
                    End Function
                )


            If String.IsNullOrWhiteSpace(
                actualSecondaryHeritage
            ) Then

                Throw New ArgumentException(
                    "Invalid secondary heritage."
                )

            End If


            If actualSecondaryHeritage.Equals(
                primaryHeritage,
                StringComparison.OrdinalIgnoreCase
            ) Then

                Throw New ArgumentException(
                    "The Other Half must be a different species."
                )

            End If

        End If


        ' =====================================================
        ' BUILD DISPLAY SPECIES
        ' =====================================================

        Dim displaySpecies =
            validSpecies


        If Not String.IsNullOrWhiteSpace(
            actualSecondaryHeritage
        ) Then

            displaySpecies =
                CharacterGenerationService.BuildHybridSpeciesName(
                    primaryHeritage,
                    actualSecondaryHeritage
                )

        End If


        ' =====================================================
        ' CREATE CHARACTER
        ' =====================================================

        Dim character As New PlayerCharacter With {
            .characterName = characterName.Trim(),
            .SpeciesName = displaySpecies,
            .className = validClass,
            .backgroundName = validBackground,
            .alignment = validAlignment,
            .level = level,
            .ExperiencePoints = 0,
            .strength = strength,
            .dexterity = dexterity,
            .constitution = constitution,
            .intelligence = intelligence,
            .wisdom = wisdom,
            .charisma = charisma,
            .TacticalArea = "Outside",
            .appearance = If(
                appearance,
                String.Empty
            ).Trim(),
            .personality = If(
                personality,
                String.Empty
            ).Trim(),
            .backstory = If(
                backstory,
                String.Empty
            ).Trim(),
            .notes = If(
                notes,
                String.Empty
            ).Trim()
        }


        ' =====================================================
        ' APPLY SPECIES / HYBRID TRAITS
        ' =====================================================

        CharacterGenerationService.ApplyHeritageTraits(
            character,
            primaryHeritage,
            actualSecondaryHeritage,
            True
        )


        ' =====================================================
        ' PROFICIENCY BONUS
        ' =====================================================

        character.ProficiencyBonus =
            ProficiencyForLevel(
                character.Level
            )


        ' =====================================================
        ' INITIATIVE
        ' =====================================================

        character.Initiative =
            PlayerCharacter.AbilityModifier(
                character.Dexterity
            )


        ' =====================================================
        ' PASSIVE PERCEPTION
        ' =====================================================

        character.PassivePerception =
            10 +
            PlayerCharacter.AbilityModifier(
                character.Wisdom
            )


        If CharacterGenerationService.HasHeritage(
            character.SpeciesName,
            "Elf"
        ) Then

            character.PassivePerception +=
                character.ProficiencyBonus

        End If


        ' =====================================================
        ' HIT DICE
        ' =====================================================

        Dim hitDie =
            GetHitDie(
                character.ClassName
            )


        character.HitDice =
            $"{character.Level}d{hitDie}"


        character.CurrentHitDice =
            character.Level


        ' =====================================================
        ' HIT POINTS
        ' =====================================================

        character.MaxHitPoints =
            CalculateHitPoints(
                character.ClassName,
                character.Level,
                character.Constitution
            )


        character.CurrentHitPoints =
            character.MaxHitPoints


        character.TempHitPoints =
            0


        ' =====================================================
        ' ARMOR CLASS
        ' =====================================================

        character.ArmorClass =
            EstimateArmorClass(
                character.ClassName,
                character
            )


        character.Gold =
            0D


        ' =====================================================
        ' PROFICIENCIES
        ' =====================================================

        character.Proficiencies =
            $"Class proficiencies: {character.ClassName}. " &
            $"Background proficiencies: {character.BackgroundName}."


        If CharacterGenerationService.HasHeritage(
            character.SpeciesName,
            "Elf"
        ) Then

            character.Proficiencies &=
                " Species proficiency: Perception (Keen Senses)."

        End If


        ' =====================================================
        ' SPELLCASTING
        ' =====================================================

        ConfigureSpellcasting(
            character
        )


        Return character

    End Function


    ' =========================================================
    ' ABILITY VALIDATION
    ' =========================================================

    Private Shared Sub ValidateAbility(
        abilityName As String,
        score As Integer
    )

        If score < 1 OrElse score > 20 Then

            Throw New ArgumentOutOfRangeException(
                abilityName,
                $"{abilityName} must be between 1 and 20 during character creation."
            )

        End If

    End Sub


    ' =========================================================
    ' PROFICIENCY BONUS
    ' =========================================================

    Private Shared Function ProficiencyForLevel(
        level As Integer
    ) As Integer

        Return 2 +
            (
                (
                    Math.Max(
                        1,
                        level
                    ) - 1
                ) \ 4
            )

    End Function


    ' =========================================================
    ' HIT DIE
    ' =========================================================

    Private Shared Function GetHitDie(
        className As String
    ) As Integer

        Select Case className.Trim().ToLowerInvariant()

            Case "barbarian"

                Return 12


            Case "fighter", "paladin", "ranger"

                Return 10


            Case "sorcerer", "wizard"

                Return 6


            Case Else

                Return 8

        End Select

    End Function


    ' =========================================================
    ' HIT POINTS
    ' =========================================================

    Private Shared Function CalculateHitPoints(
        className As String,
        level As Integer,
        constitution As Integer
    ) As Integer

        Dim die =
            GetHitDie(
                className
            )


        Dim constitutionModifier =
            PlayerCharacter.AbilityModifier(
                constitution
            )


        Dim total =
            die +
            constitutionModifier


        Dim average =
            (die \ 2) + 1


        For currentLevel =
            2 To level

            total +=
                Math.Max(
                    1,
                    average +
                    constitutionModifier
                )

        Next


        Return Math.Max(
            level,
            total
        )

    End Function


    ' =========================================================
    ' ARMOR CLASS
    ' =========================================================

    Private Shared Function EstimateArmorClass(
        className As String,
        character As PlayerCharacter
    ) As Integer

        Dim dexModifier =
            PlayerCharacter.AbilityModifier(
                character.Dexterity
            )


        Dim wisdomModifier =
            PlayerCharacter.AbilityModifier(
                character.Wisdom
            )


        Dim constitutionModifier =
            PlayerCharacter.AbilityModifier(
                character.Constitution
            )


        Select Case className.Trim().ToLowerInvariant()

            Case "barbarian"

                Return 10 +
                    dexModifier +
                    constitutionModifier


            Case "monk"

                Return 10 +
                    dexModifier +
                    wisdomModifier


            Case "fighter", "paladin", "cleric"

                Return 16


            Case "ranger", "artificer"

                Return 14 +
                    Math.Min(
                        2,
                        dexModifier
                    )


            Case "bard", "rogue", "warlock"

                Return 11 +
                    dexModifier


            Case "druid"

                Return 12 +
                    Math.Min(
                        2,
                        dexModifier
                    )


            Case Else

                Return 10 +
                    dexModifier

        End Select

    End Function


    ' =========================================================
    ' SPELLCASTING
    ' =========================================================

    Private Shared Sub ConfigureSpellcasting(
        character As PlayerCharacter
    )

        Select Case character.ClassName.Trim().ToLowerInvariant()

            Case "bard", "sorcerer", "warlock", "paladin"

                character.SpellcastingAbility =
                    "Charisma"


            Case "cleric", "druid", "ranger"

                character.SpellcastingAbility =
                    "Wisdom"


            Case "wizard", "artificer"

                character.SpellcastingAbility =
                    "Intelligence"


            Case Else

                character.SpellcastingAbility =
                    String.Empty

        End Select


        If String.IsNullOrWhiteSpace(
            character.SpellcastingAbility
        ) Then

            Return

        End If


        Dim abilityScore As Integer


        Select Case character.SpellcastingAbility

            Case "Charisma"

                abilityScore =
                    character.Charisma


            Case "Wisdom"

                abilityScore =
                    character.Wisdom


            Case Else

                abilityScore =
                    character.Intelligence

        End Select


        Dim modifier =
            PlayerCharacter.AbilityModifier(
                abilityScore
            )


        character.SpellSaveDC =
            8 +
            character.ProficiencyBonus +
            modifier


        character.SpellAttackBonus =
            character.ProficiencyBonus +
            modifier

    End Sub

End Class