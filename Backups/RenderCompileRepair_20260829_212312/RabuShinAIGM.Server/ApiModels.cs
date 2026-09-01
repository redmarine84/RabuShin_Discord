public sealed record CreateDiscordCampaignRequest(string CampaignName);
public sealed record JoinDiscordCampaignRequest(string JoinCode);
public sealed record RandomCharacterRequest(string? CharacterName, string Species, string ClassName);
public sealed record ManualCharacterRequest(
    string CharacterName, string Species, string? SecondaryHeritage, string ClassName,
    string Background, string Alignment, int Level,
    int Strength, int Dexterity, int Constitution, int Intelligence, int Wisdom, int Charisma,
    string? Appearance, string? Personality, string? Backstory, string? Notes);
public sealed record StartingEquipmentSelectionRequest(
    int ClassPackageIndex, string? ClassChoice,
    int BackgroundPackageIndex, string? BackgroundChoice);
public sealed record SpellSelectionRequest(
    List<string>? Cantrips,
    List<string>? Spells,
    List<string>? PreparedWizardSpells,
    Dictionary<int, string>? MysticArcanum);
public sealed record CampaignMessageRequest(string Message);
public sealed record JournalRequest(string Category, string Title, string EntryText);
public sealed record OpenAiKeyRequest(string ApiKey);
public sealed record GameMasterRequest(string Message);
public sealed record InventoryQuantityRequest(int Quantity);
