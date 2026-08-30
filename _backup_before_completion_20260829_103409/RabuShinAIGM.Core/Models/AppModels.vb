Imports System
Imports System.Collections.Generic

Public Class CampaignState
    Public Property SessionId As Integer
    Public Property SessionName As String = String.Empty
    Public Property CampaignDay As Integer
    Public Property CurrentChapter As String = String.Empty
    Public Property CurrentSceneKey As String = String.Empty
    Public Property CurrentSceneTitle As String = String.Empty
    Public Property RabuShinAwareness As Integer
    Public Property KrasisAdaptation As Integer
    Public Property GlobalLatticeStrength As Integer
    Public Property SettlementStability As Integer
    Public Property PartyThreatLevel As Integer
End Class

Public Class PlayerCharacter
    Public Property Id As Integer
    Public Property SessionId As Integer
    Public Property CharacterName As String = String.Empty
    Public Property SpeciesName As String = String.Empty
    Public Property ClassName As String = String.Empty
    Public Property BackgroundName As String = String.Empty
    Public Property Alignment As String = String.Empty
    Public Property Level As Integer = 1
    Public Property ExperiencePoints As Integer

    Public Property Strength As Integer = 10
    Public Property Dexterity As Integer = 10
    Public Property Constitution As Integer = 10
    Public Property Intelligence As Integer = 10
    Public Property Wisdom As Integer = 10
    Public Property Charisma As Integer = 10

    Public Property ArmorClass As Integer = 10
    Public Property Initiative As Integer
    Public Property MaxHitPoints As Integer = 1
    Public Property CurrentHitPoints As Integer = 1
    Public Property TempHitPoints As Integer
    Public Property Speed As Integer = 30
    Public Property SizeName As String = "Medium"
    Public Property PassivePerception As Integer = 10
    Public Property ProficiencyBonus As Integer = 2
    Public Property HitDice As String = "1d8"
    Public Property CurrentHitDice As Integer = 1
    Public Property DeathSaveSuccesses As Integer
    Public Property DeathSaveFailures As Integer
    Public Property ExhaustionLevel As Integer
    Public Property HeroicInspiration As Boolean
    Public Property Gold As Decimal
    Public Property Conditions As String = String.Empty

    ' Optional tactical position in feet. New characters begin together at 0,0.
    ' Inventory transfers use these coordinates to enforce the 30-foot party range.
    Public Property PositionXFeet As Integer
    Public Property PositionYFeet As Integer
    ' Multiplayer tactical visibility context. Coordinates are still measured in feet.
    Public Property TacticalArea As String = "Outside"
    Public Property IsIndoors As Boolean
    Public Property LineOfSightBlocked As Boolean

    Public Property SpellcastingAbility As String = String.Empty
    Public Property SpellSaveDC As Integer
    Public Property SpellAttackBonus As Integer
    Public Property MaxSpellPoints As Integer
    Public Property CurrentSpellPoints As Integer
    Public Property ClassResourceName As String = String.Empty
    Public Property MaxClassResource As Integer
    Public Property CurrentClassResource As Integer

    Public Property Appearance As String = String.Empty
    Public Property PortraitImageData As String = String.Empty
    Public Property Personality As String = String.Empty
    Public Property Backstory As String = String.Empty
    Public Property Languages As String = String.Empty
    Public Property Proficiencies As String = String.Empty
    Public Property Features As String = String.Empty
    Public Property Notes As String = String.Empty

    Public Shared Function AbilityModifier(score As Integer) As Integer
        Return CInt(Math.Floor((score - 10) / 2.0R))
    End Function
End Class

Public Class InventoryItem
    Public Property Id As Integer
    Public Property SessionId As Integer
    Public Property CharacterId As Integer
    Public Property ItemName As String = String.Empty
    Public Property Quantity As Integer = 1
    Public Property Weight As Decimal
    Public Property Equipped As Boolean
    Public Property Attuned As Boolean
    Public Property Notes As String = String.Empty

    ' Equipment rules data. These fields allow weapons, armor, shields, helmets,
    ' clothing, and other wearable/wieldable items to carry their actual combat
    ' statistics instead of relying on the item name alone.
    Public Property ItemType As String = String.Empty
    Public Property EquipmentSlot As String = String.Empty
    Public Property Rarity As String = "Common"
    Public Property IsMagical As Boolean
    Public Property RequiresAttunement As Boolean
    Public Property ItemDescription As String = String.Empty

    ' Weapon fields. DamageDice is the normal/one-handed damage.
    ' VersatileDamageDice is used when a versatile weapon is wielded two-handed.
    Public Property DamageDice As String = String.Empty
    Public Property VersatileDamageDice As String = String.Empty
    Public Property DamageType As String = String.Empty
    Public Property WeaponProperties As String = String.Empty
    Public Property NormalRangeFeet As Integer
    Public Property LongRangeFeet As Integer
    Public Property AttackBonus As Integer
    Public Property DamageBonus As Integer

    ' Armor / defensive equipment fields. ArmorClassBase is used by armor;
    ' ArmorClassBonus is used by shields and magical wearable bonuses.
    ' MaxDexBonus = -1 means there is no Dexterity cap.
    Public Property ArmorClassBase As Integer
    Public Property ArmorClassBonus As Integer
    Public Property MaxDexBonus As Integer = -1
    Public Property StrengthRequirement As Integer
    Public Property StealthDisadvantage As Boolean
    Public Property DamageResistances As String = String.Empty
    Public Property DamageImmunities As String = String.Empty

    ' Magical equipment fields. Free-form lists are intentionally used so homebrew
    ' equipment can grant custom effects without requiring another schema change.
    Public Property MagicEffects As String = String.Empty
    Public Property GrantedSpells As String = String.Empty
    Public Property Buffs As String = String.Empty
    Public Property CurrentCharges As Integer
    Public Property MaxCharges As Integer
End Class

Public Class CharacterCoins
    Public Property SessionId As Integer
    Public Property CharacterId As Integer
    Public Property Platinum As Integer
    Public Property Gold As Integer
    Public Property Silver As Integer
    Public Property Copper As Integer
End Class

Public Class CharacterSpell
    Public Property Id As Integer
    Public Property SessionId As Integer
    Public Property CharacterId As Integer
    Public Property SpellName As String = String.Empty
    Public Property SpellLevel As Integer
    Public Property Prepared As Boolean
    Public Property Notes As String = String.Empty

    ' Phase 1.2 homebrew-spell balancing fields.
    Public Property SpellDescription As String = String.Empty
    Public Property DamageDice As String = String.Empty
    Public Property DamageType As String = String.Empty
    Public Property HealingDice As String = String.Empty
    Public Property AreaShape As String = "Single Target"
    Public Property AreaSizeFeet As Integer
    Public Property RangeFeet As Integer
    Public Property DurationText As String = "Instantaneous"
    Public Property Concentration As Boolean
    Public Property TreatAsHomebrew As Boolean = False
    Public Property OfficialRuleMatch As Boolean
    Public Property MinimumCharacterLevel As Integer = 1
    Public Property TenRollAverage As Double
    Public Property EvaluationSummary As String = String.Empty
End Class

Public Class SrdSpellReference
    Public Property Name As String = String.Empty
    Public Property PhbTitle As String = String.Empty
    Public Property Level As Integer
    Public Property School As String = String.Empty
    Public Property Classes As New List(Of String)()
    Public Property CastingTime As String = String.Empty
    Public Property Range As String = String.Empty
    Public Property Components As String = String.Empty
    Public Property Duration As String = String.Empty
    Public Property Description As String = String.Empty
    Public Property DamageDice As String = String.Empty
    Public Property DamageType As String = String.Empty
    Public Property HealingDice As String = String.Empty
    Public Property AreaShape As String = "Single Target"
    Public Property AreaSizeFeet As Integer
    Public Property RangeFeet As Integer
    Public Property Concentration As Boolean

    Public Overrides Function ToString() As String
        Return If(Level = 0, Name & " (Cantrip)", Name & " (Level " & Level.ToString() & ")")
    End Function
End Class

Public Class SpellEvaluation
    Public Property RecommendedSpellLevel As Integer
    Public Property MinimumCharacterLevel As Integer
    Public Property TenRollAverage As Double
    Public Property ExpectedAverage As Double
    Public Property EffectivePower As Double
    Public Property IsAccessible As Boolean
    Public Property IsOfficialRuleMatch As Boolean
    Public Property RuleSet As String = String.Empty
    Public Property Summary As String = String.Empty
End Class

Public Class CharacterSpellSlot
    Public Property Id As Integer
    Public Property SessionId As Integer
    Public Property CharacterId As Integer
    Public Property SpellLevel As Integer
    Public Property MaxSlots As Integer
    Public Property UsedSlots As Integer

    Public ReadOnly Property RemainingSlots As Integer
        Get
            Return Math.Max(0, MaxSlots - UsedSlots)
        End Get
    End Property
End Class

Public Class JournalEntry
    Public Property Id As Integer
    Public Property CreatedAt As DateTime
    Public Property EntryType As String = String.Empty
    Public Property Title As String = String.Empty
    Public Property Body As String = String.Empty
End Class

Public Class ChatMessage
    Public Property Id As Integer
    Public Property Role As String = String.Empty
    Public Property Content As String = String.Empty
    Public Property CreatedAt As DateTime
End Class


Public Class DiceAuditRecord
    Public Property Id As Integer
    Public Property SessionId As Integer
    Public Property Purpose As String = String.Empty
    Public Property Expression As String = String.Empty
    Public Property RollsText As String = String.Empty
    Public Property Modifier As Integer
    Public Property Total As Integer
    Public Property Mode As String = "Normal"
    Public Property IsMulligan As Boolean
    Public Property ReplacesRollId As Integer?
    Public Property CreatedAt As DateTime
End Class

Public Class AppSettings
    Public Property AiEndpoint As String = "https://api.openai.com/v1/responses"
    Public Property AiModel As String = "gpt-5.6"
    Public Property NarrationDetail As String = "Moderate"
    Public Property HorrorLevel As String = "Strange"
    Public Property RulesMode As String = "D&D 5e 2024"
    Public Property AutoSecretRolls As Boolean = True
    Public Property AllowImprovisation As Boolean = True
    Public Property PreserveCanon As Boolean = True
End Class

Public Class CodexEntry
    Public Property Category As String = String.Empty
    Public Property Name As String = String.Empty
    Public Property Subtitle As String = String.Empty
    Public Property Image As String = String.Empty
    Public Property Details As String = String.Empty

    ' v4.2.0+: structured Codex metadata. Existing campaign JSON does not need these fields.
    Public Property Source As String = String.Empty
    Public Property CreatureType As String = String.Empty
    Public Property ChallengeRating As String = String.Empty
    Public Property ArmorClass As Integer?
    Public Property HitPoints As Integer?
    Public Property Dexterity As Integer?
    Public Property ExperiencePoints As Integer?
    Public Property InitiativeModifier As Integer?
    Public Property IsSrd As Boolean

    Public Overrides Function ToString() As String
        Return Name
    End Function
End Class

Public Class MapEntry
    Public Property Title As String = String.Empty
    Public Property RelativePath As String = String.Empty
    Public Property Description As String = String.Empty

    Public Overrides Function ToString() As String
        Return Title
    End Function
End Class

Public Class GameMasterReply
    Public Property DisplayText As String = String.Empty
    Public Property RawText As String = String.Empty
    Public Property Directives As New List(Of String)()
End Class

Public Class GreymoorScene
    Public Property Key As String = String.Empty
    Public Property Title As String = String.Empty
    Public Property PlayerFacing As String = String.Empty
    Public Property Dm As String = String.Empty
    Public Property Discoveries As New List(Of String)()
End Class

Public Class CharacterGridRow
    Public Property Name As String = String.Empty
    Public Property Species As String = String.Empty
    Public Property [Class] As String = String.Empty
    Public Property Level As Integer
    Public Property AC As Integer
    Public Property HP As String = String.Empty
    Public Property Conditions As String = String.Empty
End Class

Public Class JournalGridRow
    Public Property [When] As String = String.Empty
    Public Property Type As String = String.Empty
    Public Property Title As String = String.Empty
End Class

Public Class QuestRecord
    Public Property Id As Integer
    Public Property QuestKey As String = String.Empty
    Public Property Title As String = String.Empty
    Public Property Status As String = String.Empty
    Public Property Objectives As String = String.Empty
    Public Property Notes As String = String.Empty
End Class

Public Class QuestRewardResult
    Public Property Granted As Boolean
    Public Property QuestKey As String = String.Empty
    Public Property Summary As String = String.Empty
End Class

' =========================
' Phase 2 campaign runtime
' =========================
Public Class CampaignDefinition
    Public Property CampaignTitle As String = String.Empty
    Public Property Rules As String = String.Empty
    Public Property Source As String = String.Empty
    Public Property HybridAdvancement As HybridAdvancementDefinition
    Public Property Chapters As New List(Of CampaignChapterDefinition)()
End Class

Public Class HybridAdvancementDefinition
    Public Property Description As String = String.Empty
    Public Property ChapterTargets As New List(Of ChapterLevelTarget)()
End Class

Public Class ChapterLevelTarget
    Public Property Key As String = String.Empty
    Public Property TargetLevel As Integer
End Class

Public Class CampaignChapterDefinition
    Public Property Order As Integer
    Public Property Key As String = String.Empty
    Public Property Part As String = String.Empty
    Public Property Title As String = String.Empty
    Public Property Location As String = String.Empty
    Public Property StartLevel As Integer
    Public Property TargetLevel As Integer
    Public Property MainQuest As CampaignQuestDefinition
    Public Property RegionIntro As String = String.Empty
    Public Property SideQuests As New List(Of CampaignQuestDefinition)()
    Public Property RandomEncounters As New List(Of String)()
    Public Property Escalation As String = String.Empty
    Public Property SettlementMapTitle As String = String.Empty
    Public Property EncounterMapTitle As String = String.Empty
    Public Property CanonFile As String = String.Empty
    Public Property CanonicalPurpose As String = String.Empty
    Public Property AdvancementNote As String = String.Empty
End Class

Public Class CampaignQuestDefinition
    Public Property Key As String = String.Empty
    Public Property Number As Integer
    Public Property Title As String = String.Empty
    Public Property Location As String = String.Empty
    Public Property RecommendedLevels As String = String.Empty
    Public Property Hook As String = String.Empty
    Public Property ReadAloud As String = String.Empty
    Public Property Npcs As String = String.Empty
    Public Property Investigation As String = String.Empty
    Public Property Encounter As String = String.Empty
    Public Property Hazards As String = String.Empty
    Public Property Twist As String = String.Empty
    Public Property Reward As String = String.Empty
    Public Property Consequences As String = String.Empty
    Public Property Revelation As String = String.Empty
    Public Property Encounters As String = String.Empty
    Public Property SourceText As String = String.Empty
End Class

Public Class CharacterSkillRecord
    Public Property Id As Integer
    Public Property SessionId As Integer
    Public Property CharacterId As Integer
    Public Property SkillName As String = String.Empty
    Public Property AbilityName As String = String.Empty
    Public Property ProficiencyLevel As Integer
    Public Property MiscBonus As Integer
    Public Property Modifier As Integer
    Public ReadOnly Property ProficiencyText As String
        Get
            Select Case ProficiencyLevel
                Case 2 : Return "Expertise"
                Case 1 : Return "Proficient"
                Case Else : Return "None"
            End Select
        End Get
    End Property
End Class

Public Class CharacterSavingThrowRecord
    Public Property Id As Integer
    Public Property SessionId As Integer
    Public Property CharacterId As Integer
    Public Property AbilityName As String = String.Empty
    Public Property Proficient As Boolean
    Public Property MiscBonus As Integer
    Public Property Modifier As Integer
End Class

Public Class RulesAwareRollResolution
    Public Property CharacterId As Integer
    Public Property CharacterName As String = String.Empty
    Public Property Purpose As String = String.Empty
    Public Property Modifier As Integer
    Public Property Explanation As String = String.Empty
End Class

Public Class CombatEncounter
    Public Property Id As Integer
    Public Property SessionId As Integer
    Public Property EncounterKey As String = String.Empty
    Public Property Title As String = String.Empty
    Public Property LocationKey As String = String.Empty
    Public Property LocationName As String = String.Empty
    Public Property Status As String = "Active"
    Public Property RoundNumber As Integer = 1
    Public Property CurrentTurnIndex As Integer = 0
    Public Property AwardedXp As Integer = 0
    Public Property CreatedAt As DateTime
    Public Property CompletedAt As DateTime?
End Class

Public Class CombatantRecord
    Public Property Id As Integer
    Public Property EncounterId As Integer
    Public Property SessionId As Integer
    Public Property CharacterId As Integer?
    Public Property IsPlayer As Boolean
    Public Property Name As String = String.Empty
    Public Property CreatureName As String = String.Empty
    Public Property ArmorClass As Integer
    Public Property MaxHitPoints As Integer
    Public Property CurrentHitPoints As Integer
    Public Property TempHitPoints As Integer
    Public Property InitiativeModifier As Integer
    Public Property InitiativeRoll As Integer
    Public Property InitiativeTotal As Integer
    Public Property Conditions As String = String.Empty
    Public Property Defeated As Boolean
    Public Property XpValue As Integer
    Public Property TurnOrder As Integer
    Public Property Notes As String = String.Empty

    Public ReadOnly Property HpDisplay As String
        Get
            Return $"{CurrentHitPoints}/{MaxHitPoints}"
        End Get
    End Property
End Class

Public Class CreatureCombatProfile
    Public Property Name As String = String.Empty
    Public Property ArmorClass As Integer = 10
    Public Property MaxHitPoints As Integer = 1
    Public Property Dexterity As Integer = 10
    Public Property ChallengeRating As String = String.Empty
    Public Property XpValue As Integer
    Public Property Details As String = String.Empty
    Public Property InitiativeModifierOverride As Integer?
    Public ReadOnly Property InitiativeModifier As Integer
        Get
            If InitiativeModifierOverride.HasValue Then Return InitiativeModifierOverride.Value
            Return PlayerCharacter.AbilityModifier(Dexterity)
        End Get
    End Property
End Class

Public Class QuestRuntimeRecord
    Public Property Id As Integer
    Public Property QuestKey As String = String.Empty
    Public Property RegionKey As String = String.Empty
    Public Property QuestType As String = String.Empty
    Public Property Title As String = String.Empty
    Public Property Status As String = String.Empty
    Public Property Objectives As String = String.Empty
    Public Property Notes As String = String.Empty
    Public Property RecommendedLevels As String = String.Empty
    Public Property IsDiscovered As Boolean
    Public Property SortOrder As Integer
End Class

Public Class MerchantStockItem
    Public Property ItemName As String = String.Empty
    Public Property PriceText As String = String.Empty
    Public Property PriceInCopper As Integer
    Public Property QuantityAvailable As Integer = 1
    Public Property Notes As String = String.Empty
End Class

Public Class MerchantDefinition
    Public Property MerchantName As String = String.Empty
    Public Property Stock As New List(Of MerchantStockItem)()
    Public Property SellRatePercent As Integer = 50
End Class

Public Class WorldMapLocationDefinition
    Public Property Name As String = String.Empty
    Public Property X As Integer
    Public Property Y As Integer
    Public Property Width As Integer
    Public Property Height As Integer
    Public Property ChapterKey As String = String.Empty
End Class

' =========================
' Phase 4 local account / shared-campaign runtime
' =========================
Public Class LocalUserAccount
    Public Property Id As Integer
    Public Property Username As String = String.Empty
    Public Property DisplayName As String = String.Empty
    Public Property Email As String = String.Empty
    Public Property CreatedAt As DateTime
    Public Property LastLoginAt As DateTime?

    Public Overrides Function ToString() As String
        Return If(String.IsNullOrWhiteSpace(DisplayName), Username, DisplayName)
    End Function
End Class

Public Class CampaignAccessRecord
    Public Property CampaignSessionId As Integer
    Public Property SessionName As String = String.Empty
    Public Property OwnerUserId As Integer
    Public Property OwnerUsername As String = String.Empty
    Public Property IsOwner As Boolean
    Public Property ControlledCharacterId As Integer?
    Public Property ControlledCharacterName As String = String.Empty
    Public Property MainCharacterId As Integer?
    Public Property MainCharacterName As String = String.Empty
    Public Property CurrentLocation As String = String.Empty
    Public Property CurrentChapter As String = String.Empty
    Public Property IsStarted As Boolean
    Public Property UpdatedAt As DateTime

    Public Overrides Function ToString() As String
        Dim mainText = If(String.IsNullOrWhiteSpace(MainCharacterName), "No main character", MainCharacterName)
        Dim roleText = If(IsOwner, "Owner", "Playing " & If(String.IsNullOrWhiteSpace(ControlledCharacterName), "assigned character", ControlledCharacterName))
        Return $"{SessionName} — {mainText} — {roleText}"
    End Function
End Class

Public Class JoinableCharacterRecord
    Public Property CharacterId As Integer
    Public Property CharacterName As String = String.Empty
    Public Property ClassName As String = String.Empty
    Public Property Level As Integer
    Public Property CampaignSessionId As Integer
    Public Property CampaignName As String = String.Empty
    Public Property OwnerUserId As Integer
    Public Property OwnerUsername As String = String.Empty
    Public Property RequestStatus As String = String.Empty

    Public Overrides Function ToString() As String
        Dim suffix = If(String.IsNullOrWhiteSpace(RequestStatus), String.Empty, " — " & RequestStatus)
        Return $"{CharacterName} — Level {Level} {ClassName} — {CampaignName} — Owner: {OwnerUsername}{suffix}"
    End Function
End Class

Public Class CampaignJoinRequestRecord
    Public Property Id As Integer
    Public Property CampaignSessionId As Integer
    Public Property CampaignName As String = String.Empty
    Public Property RequestedCharacterId As Integer
    Public Property CharacterName As String = String.Empty
    Public Property CharacterOwnerUserId As Integer
    Public Property RequesterUserId As Integer
    Public Property RequesterUsername As String = String.Empty
    Public Property Status As String = "Pending"
    Public Property RequestedAt As DateTime
    Public Property RespondedAt As DateTime?

    Public Overrides Function ToString() As String
        Return $"{RequesterUsername} wants to play {CharacterName} in {CampaignName}"
    End Function
End Class

Public Class CampaignPlayContext
    Public Property UserId As Integer
    Public Property Username As String = String.Empty
    Public Property SessionId As Integer
    Public Property IsOwner As Boolean
    Public Property ControlledCharacterId As Integer?
    Public Property ControlledCharacterName As String = String.Empty
    Public Property LockToken As String = String.Empty
End Class

Public Class CharacterAccessGrantRecord
    Public Property CampaignSessionId As Integer
    Public Property CampaignName As String = String.Empty
    Public Property CharacterId As Integer
    Public Property CharacterName As String = String.Empty
    Public Property GuestUserId As Integer
    Public Property GuestUsername As String = String.Empty
    Public Property GrantedAt As DateTime

    Public Overrides Function ToString() As String
        Return $"{GuestUsername} → {CharacterName} — {CampaignName}"
    End Function
End Class
