Imports System
Imports System.Collections.Generic
Imports System.Linq

Public Class DiceRollResult
    Public Property Expression As String = String.Empty
    Public Property Rolls As New List(Of Integer)()
    Public Property Modifier As Integer
    Public Property Total As Integer
    Public Property Mode As String = "Normal"
    Public Property KeptRoll As Integer?

    Public Overrides Function ToString() As String
        Dim rollText = String.Join(", ", Rolls)
        If KeptRoll.HasValue Then
            Return $"{Mode}: [{rollText}] -> kept {KeptRoll.Value}; modifier {Modifier:+#;-#;0}; total {Total}"
        End If
        Return $"{Expression}: [{rollText}] {Modifier:+#;-#;0} = {Total}"
    End Function
End Class

Public Class DiceService
    Public Function Roll(count As Integer, sides As Integer, modifier As Integer) As DiceRollResult
        If count < 1 OrElse count > 100 Then Throw New ArgumentOutOfRangeException(NameOf(count))
        If sides < 2 OrElse sides > 1000 Then Throw New ArgumentOutOfRangeException(NameOf(sides))
        Dim result As New DiceRollResult With {.Expression = $"{count}d{sides}{FormatModifier(modifier)}", .Modifier = modifier}
        For index = 1 To count
            result.Rolls.Add(Random.Shared.Next(1, sides + 1))
        Next
        result.Total = result.Rolls.Sum() + modifier
        Return result
    End Function

    Public Function RollD20(modifier As Integer, advantage As Boolean, disadvantage As Boolean) As DiceRollResult
        If advantage AndAlso disadvantage Then
            advantage = False
            disadvantage = False
        End If
        If Not advantage AndAlso Not disadvantage Then Return Roll(1, 20, modifier)

        Dim first = Random.Shared.Next(1, 21)
        Dim second = Random.Shared.Next(1, 21)
        Dim keep = If(advantage, Math.Max(first, second), Math.Min(first, second))
        Return New DiceRollResult With {
            .Expression = "1d20" & FormatModifier(modifier),
            .Rolls = New List(Of Integer) From {first, second},
            .Modifier = modifier,
            .Total = keep + modifier,
            .Mode = If(advantage, "Advantage", "Disadvantage"),
            .KeptRoll = keep
        }
    End Function

    Private Shared Function FormatModifier(modifier As Integer) As String
        If modifier > 0 Then Return "+" & modifier.ToString()
        If modifier < 0 Then Return modifier.ToString()
        Return String.Empty
    End Function
End Class
