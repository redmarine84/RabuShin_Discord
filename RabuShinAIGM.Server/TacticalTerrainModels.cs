using System.Text.Json.Serialization;

public sealed class TacticalDoorStateRow
{
    [JsonPropertyName("door_id")] public int DoorId { get; set; }
    [JsonPropertyName("is_open")] public bool IsOpen { get; set; }
    [JsonPropertyName("reason")] public string Reason { get; set; } = string.Empty;
}
