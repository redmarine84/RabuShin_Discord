Imports System
Imports System.Collections.Generic
Imports System.Linq
Imports System.Text
Imports System.Text.RegularExpressions

Public NotInheritable Class EquipmentReferenceService
    Private Sub New()
    End Sub

    Private NotInheritable Class WeaponDefinition
        Public Property DamageDice As String = String.Empty
        Public Property VersatileDamageDice As String = String.Empty
        Public Property DamageType As String = String.Empty
        Public Property Properties As String = String.Empty
        Public Property NormalRange As Integer
        Public Property LongRange As Integer
    End Class

    Private NotInheritable Class ArmorDefinition
        Public Property BaseArmorClass As Integer
        Public Property MaxDexBonus As Integer = -1
        Public Property StrengthRequirement As Integer
        Public Property StealthDisadvantage As Boolean
    End Class

    Private Shared ReadOnly Weapons As New Dictionary(Of String, WeaponDefinition)(StringComparer.OrdinalIgnoreCase) From {
        {"club", W("1d4", "Bludgeoning", "Light")},
        {"dagger", W("1d4", "Piercing", "Finesse, Light, Thrown", 20, 60)},
        {"greatclub", W("1d8", "Bludgeoning", "Two-Handed")},
        {"handaxe", W("1d6", "Slashing", "Light, Thrown", 20, 60)},
        {"javelin", W("1d6", "Piercing", "Thrown", 30, 120)},
        {"light hammer", W("1d4", "Bludgeoning", "Light, Thrown", 20, 60)},
        {"mace", W("1d6", "Bludgeoning")},
        {"quarterstaff", W("1d6", "Bludgeoning", "Versatile", 0, 0, "1d8")},
        {"sickle", W("1d4", "Slashing", "Light")},
        {"spear", W("1d6", "Piercing", "Thrown, Versatile", 20, 60, "1d8")},
        {"light crossbow", W("1d8", "Piercing", "Ammunition, Loading, Two-Handed", 80, 320)},
        {"dart", W("1d4", "Piercing", "Finesse, Thrown", 20, 60)},
        {"shortbow", W("1d6", "Piercing", "Ammunition, Two-Handed", 80, 320)},
        {"sling", W("1d4", "Bludgeoning", "Ammunition", 30, 120)},
        {"battleaxe", W("1d8", "Slashing", "Versatile", 0, 0, "1d10")},
        {"flail", W("1d8", "Bludgeoning")},
        {"glaive", W("1d10", "Slashing", "Heavy, Reach, Two-Handed")},
        {"greataxe", W("1d12", "Slashing", "Heavy, Two-Handed")},
        {"greatsword", W("2d6", "Slashing", "Heavy, Two-Handed")},
        {"halberd", W("1d10", "Slashing", "Heavy, Reach, Two-Handed")},
        {"lance", W("1d10", "Piercing", "Reach")},
        {"longsword", W("1d8", "Slashing", "Versatile", 0, 0, "1d10")},
        {"maul", W("2d6", "Bludgeoning", "Heavy, Two-Handed")},
        {"morningstar", W("1d8", "Piercing")},
        {"pike", W("1d10", "Piercing", "Heavy, Reach, Two-Handed")},
        {"rapier", W("1d8", "Piercing", "Finesse")},
        {"scimitar", W("1d6", "Slashing", "Finesse, Light")},
        {"shortsword", W("1d6", "Piercing", "Finesse, Light")},
        {"trident", W("1d6", "Piercing", "Thrown, Versatile", 20, 60, "1d8")},
        {"war pick", W("1d8", "Piercing")},
        {"warhammer", W("1d8", "Bludgeoning", "Versatile", 0, 0, "1d10")},
        {"whip", W("1d4", "Slashing", "Finesse, Reach")},
        {"blowgun", W("1", "Piercing", "Ammunition, Loading", 25, 100)},
        {"hand crossbow", W("1d6", "Piercing", "Ammunition, Light, Loading", 30, 120)},
        {"heavy crossbow", W("1d10", "Piercing", "Ammunition, Heavy, Loading, Two-Handed", 100, 400)},
        {"longbow", W("1d8", "Piercing", "Ammunition, Heavy, Two-Handed", 150, 600)}
    }

    Private Shared ReadOnly Armors As New Dictionary(Of String, ArmorDefinition)(StringComparer.OrdinalIgnoreCase) From {
        {"padded", A(11, -1, 0, True)},
        {"leather", A(11, -1)},
        {"studded leather", A(12, -1)},
        {"hide", A(12, 2)},
        {"chain shirt", A(13, 2)},
        {"scale mail", A(14, 2, 0, True)},
        {"breastplate", A(14, 2)},
        {"half plate", A(15, 2, 0, True)},
        {"ring mail", A(14, 0, 0, True)},
        {"chain mail", A(16, 0, 13, True)},
        {"splint", A(17, 0, 15, True)},
        {"plate", A(18, 0, 15, True)}
    }

    Public Shared Function InferItemType(itemName As String) As String
        Dim normalized = Normalize(itemName)
        If normalized.Length = 0 Then Return "General"
        If normalized = "shield" OrElse normalized.EndsWith(" shield", StringComparison.Ordinal) Then Return "Shield"
        If IsArmorName(normalized) Then Return "Armor"
        If normalized.Contains("helmet") OrElse normalized.Contains("helm") Then Return "Helmet"
        If normalized.Contains("robe") OrElse normalized.Contains("clothes") OrElse normalized.Contains("clothing") OrElse normalized.Contains("costume") OrElse normalized.Contains("cloak") Then Return "Clothing"
        If normalized.Contains("focus") OrElse normalized.Contains("holy symbol") OrElse normalized.Contains("druidic symbol") Then Return "Focus"
        If FindWeaponDefinition(normalized) IsNot Nothing Then Return "Weapon"
        If normalized.Contains("sword") OrElse normalized.Contains("blade") OrElse normalized.Contains("axe") OrElse normalized.Contains("bow") OrElse
           normalized.Contains("dagger") OrElse normalized.Contains("mace") OrElse normalized.Contains("spear") OrElse normalized.Contains("staff") OrElse
           normalized.Contains("hammer") OrElse normalized.Contains("flail") OrElse normalized.Contains("sickle") OrElse normalized.Contains("lance") OrElse
           normalized.Contains("pike") OrElse normalized.Contains("whip") OrElse normalized.Contains("club") OrElse normalized.Contains("trident") Then Return "Weapon"
        If normalized.Contains("boots") OrElse normalized.Contains("gauntlet") OrElse normalized.Contains("glove") OrElse normalized.Contains("bracer") OrElse
           normalized.Contains("ring") OrElse normalized.Contains("amulet") OrElse normalized.Contains("necklace") OrElse normalized.Contains("belt") Then Return "Accessory"
        If normalized.Contains("tool") OrElse normalized.Contains("supplies") OrElse normalized.Contains("kit") Then Return "Tool"
        If normalized.Contains("potion") OrElse normalized.Contains("scroll") OrElse normalized.Contains("elixir") Then Return "Consumable"
        Return "General"
    End Function

    Public Shared Function InferEquipmentSlot(itemType As String, itemName As String) As String
        Select Case If(itemType, String.Empty).Trim().ToLowerInvariant()
            Case "weapon" : Return "Hand"
            Case "shield" : Return "Off Hand"
            Case "armor", "clothing" : Return "Body"
            Case "helmet" : Return "Head"
            Case "focus" : Return "Focus / Hand"
            Case "accessory"
                Dim lower = Normalize(itemName)
                If lower.Contains("boot") Then Return "Feet"
                If lower.Contains("gauntlet") OrElse lower.Contains("glove") OrElse lower.Contains("bracer") Then Return "Hands / Arms"
                If lower.Contains("ring") Then Return "Finger"
                If lower.Contains("amulet") OrElse lower.Contains("necklace") Then Return "Neck"
                If lower.Contains("belt") Then Return "Waist"
                Return "Accessory"
            Case Else
                Return String.Empty
        End Select
    End Function

    Public Shared Function CanEquip(item As InventoryItem) As Boolean
        If item Is Nothing Then Return False
        Dim kind = If(String.IsNullOrWhiteSpace(item.ItemType), InferItemType(item.ItemName), item.ItemType).Trim()
        Select Case kind.ToLowerInvariant()
            Case "weapon", "armor", "shield", "helmet", "clothing", "accessory", "focus"
                Return True
            Case Else
                Return InventoryReferenceService.CanEquip(item.ItemName)
        End Select
    End Function

    Public Shared Sub ApplyStandardDefaults(item As InventoryItem, overwriteExisting As Boolean)
        If item Is Nothing Then Return

        Dim hadItemType = Not String.IsNullOrWhiteSpace(item.ItemType)
        Dim inferredType = InferItemType(item.ItemName)
        If overwriteExisting OrElse Not hadItemType Then item.ItemType = inferredType
        If overwriteExisting OrElse String.IsNullOrWhiteSpace(item.EquipmentSlot) Then item.EquipmentSlot = InferEquipmentSlot(item.ItemType, item.ItemName)
        If String.IsNullOrWhiteSpace(item.Rarity) Then item.Rarity = "Common"

        ' Standard combat values are automatically seeded only while an item has no
        ' stored type yet (old saves/new rewards) or when the user explicitly clicks
        ' Load Standard D&D Values. Once an item has been classified, blank/zero fields
        ' are treated as intentional homebrew edits and are not silently restored.
        Dim seedRules = overwriteExisting OrElse Not hadItemType
        If Not seedRules Then Return

        Dim normalized = Normalize(item.ItemName)
        Dim weapon = FindWeaponDefinition(normalized)
        If weapon IsNot Nothing AndAlso item.ItemType.Equals("Weapon", StringComparison.OrdinalIgnoreCase) Then
            item.DamageDice = weapon.DamageDice
            item.VersatileDamageDice = weapon.VersatileDamageDice
            item.DamageType = weapon.DamageType
            item.WeaponProperties = weapon.Properties
            item.NormalRangeFeet = weapon.NormalRange
            item.LongRangeFeet = weapon.LongRange
        End If

        Dim armor = FindArmorDefinition(normalized)
        If armor IsNot Nothing AndAlso item.ItemType.Equals("Armor", StringComparison.OrdinalIgnoreCase) Then
            item.ArmorClassBase = armor.BaseArmorClass
            item.MaxDexBonus = armor.MaxDexBonus
            item.StrengthRequirement = armor.StrengthRequirement
            item.StealthDisadvantage = armor.StealthDisadvantage
        End If

        If item.ItemType.Equals("Shield", StringComparison.OrdinalIgnoreCase) Then
            item.ArmorClassBonus = 2
        End If
    End Sub

    Public Shared Function GetAuthoritativeSpecialAbilities(item As InventoryItem) As String
        If item Is Nothing Then Return String.Empty

        ' MagicEffects is the single source of truth for item abilities going forward.
        ' GrantedSpells and Buffs are retained only for backwards compatibility with
        ' older saves and are merged here so those saves keep working immediately.
        Dim sections As New List(Of String)()
        If Not String.IsNullOrWhiteSpace(item.MagicEffects) Then sections.Add(item.MagicEffects.Trim())

        If Not String.IsNullOrWhiteSpace(item.GrantedSpells) Then
            Dim legacy = "Granted Spells: " & item.GrantedSpells.Trim()
            If Not sections.Any(Function(s) s.IndexOf(legacy, StringComparison.OrdinalIgnoreCase) >= 0) Then sections.Add(legacy)
        End If

        If Not String.IsNullOrWhiteSpace(item.Buffs) Then
            Dim legacy = "Buffs / Bonuses / Conditional Effects: " & item.Buffs.Trim()
            If Not sections.Any(Function(s) s.IndexOf(legacy, StringComparison.OrdinalIgnoreCase) >= 0) Then sections.Add(legacy)
        End If

        Return String.Join(Environment.NewLine, sections)
    End Function

    Public Shared Function IsMechanicallyActive(item As InventoryItem) As Boolean
        If item Is Nothing OrElse Not item.Equipped Then Return False
        If item.RequiresAttunement AndAlso Not item.Attuned Then Return False
        Return True
    End Function

    Public Shared Function BuildGmEquipmentRuleBlock(characterName As String, inventory As IEnumerable(Of InventoryItem)) As String
        If inventory Is Nothing Then Return String.Empty

        Dim items = inventory.Where(Function(i) i IsNot Nothing AndAlso CanEquip(i)).ToList()
        If items.Count = 0 Then Return String.Empty

        Dim builder As New StringBuilder()
        Dim wroteAny As Boolean = False

        For Each item In items
            ApplyStandardDefaults(item, False)

            Dim abilities = GetAuthoritativeSpecialAbilities(item)
            Dim hasMechanicalData =
                Not String.IsNullOrWhiteSpace(item.DamageDice) OrElse
                Not String.IsNullOrWhiteSpace(item.VersatileDamageDice) OrElse
                item.AttackBonus <> 0 OrElse item.DamageBonus <> 0 OrElse
                item.ArmorClassBase > 0 OrElse item.ArmorClassBonus <> 0 OrElse
                Not String.IsNullOrWhiteSpace(item.DamageResistances) OrElse
                Not String.IsNullOrWhiteSpace(item.DamageImmunities) OrElse
                Not String.IsNullOrWhiteSpace(abilities) OrElse item.MaxCharges > 0

            If Not hasMechanicalData Then Continue For

            If item.Equipped AndAlso item.RequiresAttunement AndAlso Not item.Attuned Then
                builder.AppendLine($"INACTIVE ITEM: {item.ItemName} — equipped but NOT attuned; do not apply its attunement-required properties.")
                wroteAny = True
                Continue For
            End If

            If Not IsMechanicallyActive(item) Then Continue For

            wroteAny = True
            Dim status As New List(Of String) From {"equipped"}
            If item.Attuned Then status.Add("attuned")
            If item.IsMagical Then status.Add("magical")
            If Not String.IsNullOrWhiteSpace(item.ItemType) Then status.Add(item.ItemType)
            builder.AppendLine($"ACTIVE ITEM: {item.ItemName} [{String.Join(", ", status)}]")

            Dim core As New List(Of String)()
            If Not String.IsNullOrWhiteSpace(item.DamageDice) Then
                Dim damage = item.DamageDice & If(String.IsNullOrWhiteSpace(item.DamageType), String.Empty, " " & item.DamageType)
                If Not String.IsNullOrWhiteSpace(item.VersatileDamageDice) Then damage &= "; versatile/2H " & item.VersatileDamageDice
                If item.AttackBonus <> 0 Then damage &= "; attack " & Signed(item.AttackBonus)
                If item.DamageBonus <> 0 Then damage &= "; damage " & Signed(item.DamageBonus)
                core.Add("Weapon: " & damage)
            End If
            If Not String.IsNullOrWhiteSpace(item.WeaponProperties) Then core.Add("Weapon properties: " & item.WeaponProperties)
            If item.ArmorClassBase > 0 Then core.Add("Base AC: " & item.ArmorClassBase)
            If item.ArmorClassBonus <> 0 Then core.Add("AC bonus: " & Signed(item.ArmorClassBonus))
            If Not String.IsNullOrWhiteSpace(item.DamageResistances) Then core.Add("Damage resistance: " & item.DamageResistances)
            If Not String.IsNullOrWhiteSpace(item.DamageImmunities) Then core.Add("Damage immunity: " & item.DamageImmunities)
            If item.MaxCharges > 0 Then core.Add($"Charges: {item.CurrentCharges}/{item.MaxCharges}")

            For Each rule In core
                builder.AppendLine("  - " & rule)
            Next

            If Not String.IsNullOrWhiteSpace(abilities) Then
                builder.AppendLine("  - AUTHORITATIVE SPECIAL ABILITIES (Magic Effects / Special Abilities field):")
                For Each line In abilities.Replace(vbCrLf, vbLf).Split(New String() {vbLf}, StringSplitOptions.None)
                    If Not String.IsNullOrWhiteSpace(line) Then builder.AppendLine("      " & line.Trim())
                Next

                Dim normalized = BuildMechanicalInterpretation(abilities)
                If Not String.IsNullOrWhiteSpace(normalized) Then
                    builder.AppendLine("  - NORMALIZED MECHANICAL INTERPRETATION:")
                    For Each line In normalized.Replace(vbCrLf, vbLf).Split(New String() {vbLf}, StringSplitOptions.None)
                        If Not String.IsNullOrWhiteSpace(line) Then builder.AppendLine("      " & line.Trim())
                    Next
                End If
            End If
        Next

        If Not wroteAny Then Return String.Empty
        Return builder.ToString().TrimEnd()
    End Function

    Public Shared Function BuildMechanicalInterpretation(abilities As String) As String
        If String.IsNullOrWhiteSpace(abilities) Then Return String.Empty

        Dim text = abilities.Trim()
        Dim lower = text.ToLowerInvariant()
        Dim lines As New List(Of String)()

        If lower.Contains("spell focus") OrElse lower.Contains("spellcasting focus") OrElse
           lower.Contains("arcane focus") OrElse lower.Contains("used as a focus") OrElse lower.Contains("functions as a focus") Then
            lines.Add("This item functions as a spellcasting focus when its active-state requirements are met.")
        End If

        Dim multiplier = DetectDeclaredMultiplier(lower)
        If multiplier > 1 Then
            Dim hasSpellScope = lower.Contains("spell effect") OrElse lower.Contains("spells effect") OrElse lower.Contains("spell effects") OrElse
                                lower.Contains("all spell") OrElse lower.Contains("spells by") OrElse lower.Contains("spell by")
            Dim hasProjectile = lower.Contains("projectile") OrElse lower.Contains("bolt") OrElse lower.Contains("ray") OrElse lower.Contains("missile")
            Dim hasHealing = lower.Contains("heal") OrElse lower.Contains("healing")
            Dim hasDamage = lower.Contains("damage")

            If hasSpellScope Then lines.Add($"All numeric spell effects explicitly covered by this ability use x{multiplier}; resolve the base spell first, then apply this multiplier.")
            If hasProjectile Then lines.Add($"Spell projectile / bolt / ray / missile count explicitly covered by this ability uses x{multiplier}.")
            If hasHealing Then lines.Add($"Healing amounts explicitly covered by this ability use x{multiplier}.")
            If hasDamage Then lines.Add($"Damage amounts explicitly covered by this ability use x{multiplier}.")
            If hasSpellScope OrElse hasProjectile OrElse hasHealing OrElse hasDamage Then
                lines.Add("Do not stack the same stated multiplier with itself when multiple lines describe the same ability; each affected value is multiplied once unless the item explicitly says otherwise.")
            End If
        End If

        Return String.Join(Environment.NewLine, lines)
    End Function

    Public Shared Function BuildRulesSummary(item As InventoryItem) As String
        If item Is Nothing Then Return String.Empty
        ApplyStandardDefaults(item, False)
        Dim lines As New List(Of String)()
        Dim kind = If(String.IsNullOrWhiteSpace(item.ItemType), "General", item.ItemType)

        If CanEquip(item) Then
            Dim header = kind
            If Not String.IsNullOrWhiteSpace(item.EquipmentSlot) Then header &= " • Slot: " & item.EquipmentSlot
            If item.IsMagical Then header &= " • Magical"
            If Not String.IsNullOrWhiteSpace(item.Rarity) Then header &= " • " & item.Rarity
            lines.Add(header)
        End If

        If kind.Equals("Weapon", StringComparison.OrdinalIgnoreCase) OrElse Not String.IsNullOrWhiteSpace(item.DamageDice) Then
            Dim damage = If(String.IsNullOrWhiteSpace(item.DamageDice), "Damage not set", item.DamageDice & If(String.IsNullOrWhiteSpace(item.DamageType), String.Empty, " " & item.DamageType))
            If Not String.IsNullOrWhiteSpace(item.VersatileDamageDice) Then damage &= " • Versatile/2H " & item.VersatileDamageDice
            If item.AttackBonus <> 0 Then damage &= " • Attack " & Signed(item.AttackBonus)
            If item.DamageBonus <> 0 Then damage &= " • Damage " & Signed(item.DamageBonus)
            lines.Add(damage)
            If item.NormalRangeFeet > 0 Then
                lines.Add("Range: " & item.NormalRangeFeet & If(item.LongRangeFeet > 0, "/" & item.LongRangeFeet, String.Empty) & " ft.")
            End If
            If Not String.IsNullOrWhiteSpace(item.WeaponProperties) Then lines.Add("Properties: " & item.WeaponProperties)
        End If

        If kind.Equals("Armor", StringComparison.OrdinalIgnoreCase) OrElse item.ArmorClassBase > 0 Then
            Dim armorText = If(item.ArmorClassBase > 0, "Base AC " & item.ArmorClassBase.ToString(), "Base AC not set")
            If item.MaxDexBonus >= 0 Then armorText &= " • Max DEX bonus " & item.MaxDexBonus
            If item.StrengthRequirement > 0 Then armorText &= " • STR " & item.StrengthRequirement
            If item.StealthDisadvantage Then armorText &= " • Stealth disadvantage"
            lines.Add(armorText)
        End If
        If item.ArmorClassBonus <> 0 Then lines.Add("AC Bonus: " & Signed(item.ArmorClassBonus))
        If Not String.IsNullOrWhiteSpace(item.DamageResistances) Then lines.Add("Resistance: " & item.DamageResistances)
        If Not String.IsNullOrWhiteSpace(item.DamageImmunities) Then lines.Add("Immunity: " & item.DamageImmunities)
        If item.RequiresAttunement Then lines.Add("Requires Attunement: " & If(item.Attuned, "Attuned", "Not attuned"))
        Dim abilities = GetAuthoritativeSpecialAbilities(item)
        If Not String.IsNullOrWhiteSpace(abilities) Then lines.Add("Magic Effects / Special Abilities (authoritative): " & abilities)
        If item.MaxCharges > 0 Then lines.Add($"Charges: {item.CurrentCharges}/{item.MaxCharges}")

        Return String.Join(Environment.NewLine, lines)
    End Function

    Public Shared Function BuildGameplaySummary(item As InventoryItem) As String
        If item Is Nothing Then Return String.Empty
        ApplyStandardDefaults(item, False)
        Dim parts As New List(Of String) From {item.ItemName & " x" & Math.Max(1, item.Quantity).ToString()}
        If item.Equipped Then parts.Add("equipped")
        If item.Attuned Then parts.Add("attuned")
        If Not String.IsNullOrWhiteSpace(item.ItemType) Then parts.Add(item.ItemType)
        If Not String.IsNullOrWhiteSpace(item.DamageDice) Then
            Dim damage = item.DamageDice
            If Not String.IsNullOrWhiteSpace(item.DamageType) Then damage &= " " & item.DamageType
            If Not String.IsNullOrWhiteSpace(item.VersatileDamageDice) Then damage &= "; versatile/2H " & item.VersatileDamageDice
            If item.AttackBonus <> 0 Then damage &= "; attack " & Signed(item.AttackBonus)
            If item.DamageBonus <> 0 Then damage &= "; damage " & Signed(item.DamageBonus)
            parts.Add(damage)
        End If
        If item.ArmorClassBase > 0 Then parts.Add("base AC " & item.ArmorClassBase)
        If item.ArmorClassBonus <> 0 Then parts.Add("AC " & Signed(item.ArmorClassBonus))
        If Not String.IsNullOrWhiteSpace(item.DamageResistances) Then parts.Add("resists " & item.DamageResistances)
        If Not String.IsNullOrWhiteSpace(item.DamageImmunities) Then parts.Add("immune " & item.DamageImmunities)
        If item.MaxCharges > 0 Then parts.Add($"charges {item.CurrentCharges}/{item.MaxCharges}")
        Return String.Join("; ", parts)
    End Function

    Private Shared Function DetectDeclaredMultiplier(text As String) As Integer
        If String.IsNullOrWhiteSpace(text) Then Return 1

        ' Normalize only when the ability text consistently declares one multiplier.
        ' If an item intentionally uses different multipliers for different effects,
        ' the original Special Abilities text remains authoritative and the AI is left
        ' to follow those exact category-specific rules rather than receiving a bad
        ' simplified interpretation.
        Dim values As New HashSet(Of Integer)()

        For Each match As Match In Regex.Matches(text, "(?i)(?:\bx\s*|\bby\s+|\btimes\s+)(\d{1,3})\b")
            Dim value As Integer
            If Integer.TryParse(match.Groups(1).Value, value) AndAlso value > 1 Then values.Add(value)
        Next

        For Each match As Match In Regex.Matches(text, "(?i)\b(\d{1,3})\s*(?:x|×|times)\b")
            Dim value As Integer
            If Integer.TryParse(match.Groups(1).Value, value) AndAlso value > 1 Then values.Add(value)
        Next

        Dim wordValues As New Dictionary(Of String, Integer)(StringComparer.OrdinalIgnoreCase) From {
            {"two", 2}, {"three", 3}, {"four", 4}, {"five", 5}, {"six", 6}, {"seven", 7}, {"eight", 8}, {"nine", 9},
            {"ten", 10}, {"eleven", 11}, {"twelve", 12}, {"thirteen", 13}, {"fourteen", 14}, {"fifteen", 15},
            {"sixteen", 16}, {"seventeen", 17}, {"eighteen", 18}, {"nineteen", 19}, {"twenty", 20}
        }

        For Each pair In wordValues
            If Regex.IsMatch(text, "(?i)\b(?:by|times)\s+" & Regex.Escape(pair.Key) & "\b") OrElse
               Regex.IsMatch(text, "(?i)\b" & Regex.Escape(pair.Key) & "fold\b") Then
                values.Add(pair.Value)
            End If
        Next

        If values.Count = 1 Then Return values.First()
        Return 1
    End Function

    Private Shared Function W(damageDice As String, damageType As String, Optional properties As String = "", Optional normalRange As Integer = 0, Optional longRange As Integer = 0, Optional versatileDamage As String = "") As WeaponDefinition
        Return New WeaponDefinition With {
            .DamageDice = damageDice,
            .DamageType = damageType,
            .Properties = properties,
            .NormalRange = normalRange,
            .LongRange = longRange,
            .VersatileDamageDice = versatileDamage
        }
    End Function

    Private Shared Function A(baseArmorClass As Integer, maxDexBonus As Integer, Optional strengthRequirement As Integer = 0, Optional stealthDisadvantage As Boolean = False) As ArmorDefinition
        Return New ArmorDefinition With {
            .BaseArmorClass = baseArmorClass,
            .MaxDexBonus = maxDexBonus,
            .StrengthRequirement = strengthRequirement,
            .StealthDisadvantage = stealthDisadvantage
        }
    End Function

    Private Shared Function FindWeaponDefinition(normalizedName As String) As WeaponDefinition
        Dim value As WeaponDefinition = Nothing
        If Weapons.TryGetValue(normalizedName, value) Then Return value
        For Each pair In Weapons.OrderByDescending(Function(p) p.Key.Length)
            If normalizedName.Equals(pair.Key, StringComparison.OrdinalIgnoreCase) OrElse normalizedName.EndsWith(" " & pair.Key, StringComparison.OrdinalIgnoreCase) Then Return pair.Value
        Next
        Return Nothing
    End Function

    Private Shared Function FindArmorDefinition(normalizedName As String) As ArmorDefinition
        Dim key = normalizedName
        If key.EndsWith(" armor", StringComparison.OrdinalIgnoreCase) Then key = key.Substring(0, key.Length - 6).Trim()
        Dim value As ArmorDefinition = Nothing
        If Armors.TryGetValue(key, value) Then Return value
        For Each pair In Armors.OrderByDescending(Function(p) p.Key.Length)
            If key.EndsWith(pair.Key, StringComparison.OrdinalIgnoreCase) Then Return pair.Value
        Next
        Return Nothing
    End Function

    Private Shared Function IsArmorName(normalizedName As String) As Boolean
        Return FindArmorDefinition(normalizedName) IsNot Nothing OrElse normalizedName.Contains(" armor") OrElse normalizedName.EndsWith("mail", StringComparison.Ordinal) OrElse normalizedName.Contains("plate")
    End Function


    Private Shared Function Signed(value As Integer) As String
        If value >= 0 Then Return "+" & value.ToString()
        Return value.ToString()
    End Function

    Private Shared Function OneLine(value As String) As String
        Return If(value, String.Empty).Replace(vbCrLf, " | ").Replace(vbLf, " | ").Trim()
    End Function

    Private Shared Function Normalize(value As String) As String
        Return If(value, String.Empty).Trim().ToLowerInvariant()
    End Function
End Class
