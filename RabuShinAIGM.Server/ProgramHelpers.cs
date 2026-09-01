using QuestsOfRabuShinAIGM;

public static class ProgramHelpers
{
    public static object ToClientCharacter(DiscordCharacterInfo c, bool hasPortrait = false) => new
    {
        characterId = c.CharacterId,
        campaignId = c.CampaignId,
        characterName = c.CharacterName,
        speciesName = c.SpeciesName,
        className = c.ClassName,
        backgroundName = c.BackgroundName,
        alignment = c.Alignment,
        level = c.Level,
        experience = c.Experience,
        currentHp = c.CurrentHp,
        maxHp = c.MaxHp,
        armorClass = c.ArmorClass,
        strength = c.Strength,
        dexterity = c.Dexterity,
        constitution = c.Constitution,
        intelligence = c.Intelligence,
        wisdom = c.Wisdom,
        charisma = c.Charisma,
        initiative = c.Initiative,
        passivePerception = c.PassivePerception,
        proficiencyBonus = c.ProficiencyBonus,
        speed = c.Speed,
        sizeName = c.SizeName,
        gold = c.Gold,
        equipmentComplete = c.EquipmentComplete,
        spellsComplete = c.SpellsComplete,
        hasPortrait,
        characterData = c.CharacterData
    };

    public static object ToClientGeneratedCharacter(Guid id, PlayerCharacter c) => new
    {
        characterId = id,
        characterName = c.CharacterName,
        speciesName = c.SpeciesName,
        className = c.ClassName,
        backgroundName = c.BackgroundName,
        alignment = c.Alignment,
        level = c.Level,
        experience = c.ExperiencePoints,
        currentHp = c.CurrentHitPoints,
        maxHp = c.MaxHitPoints,
        armorClass = c.ArmorClass,
        strength = c.Strength,
        dexterity = c.Dexterity,
        constitution = c.Constitution,
        intelligence = c.Intelligence,
        wisdom = c.Wisdom,
        charisma = c.Charisma,
        initiative = c.Initiative,
        passivePerception = c.PassivePerception,
        proficiencyBonus = c.ProficiencyBonus,
        speed = c.Speed,
        sizeName = c.SizeName,
        gold = c.Gold,
        appearance = c.Appearance,
        personality = c.Personality,
        backstory = c.Backstory,
        languages = c.Languages,
        proficiencies = c.Proficiencies,
        features = c.Features,
        hasPortrait = false
    };


    public static object ToClientPartyMember(DiscordPartyMember p) => new
    {
        characterId = p.CharacterId,
        playerId = p.PlayerId,
        displayName = p.DisplayName,
        discordUsername = p.DiscordUsername,
        characterName = p.CharacterName,
        speciesName = p.SpeciesName,
        className = p.ClassName,
        backgroundName = p.BackgroundName,
        alignment = p.Alignment,
        level = p.Level,
        currentHp = p.CurrentHp,
        maxHp = p.MaxHp,
        armorClass = p.ArmorClass,
        strength = p.Strength,
        dexterity = p.Dexterity,
        constitution = p.Constitution,
        intelligence = p.Intelligence,
        wisdom = p.Wisdom,
        charisma = p.Charisma,
        initiative = p.Initiative,
        passivePerception = p.PassivePerception,
        proficiencyBonus = p.ProficiencyBonus,
        speed = p.Speed,
        hasPortrait = !string.IsNullOrWhiteSpace(p.PortraitPath)
    };

    public static object MapEquipmentPackage(StartingEquipmentPackage package, int index)
    {
        var choiceKind = StartingEquipmentService.GetChoiceKind(package);
        return new
        {
            index,
            label = package.Label,
            gold = package.Gold,
            choiceKind,
            choiceOptions = StartingEquipmentService.GetChoiceOptions(choiceKind),
            items = package.Items.Select(item => new
            {
                itemName = item.ItemName,
                quantity = item.Quantity,
                choiceKind = item.ChoiceKind
            })
        };
    }

    public static string ResolveEquipmentChoice(StartingEquipmentPackage package, string? requestedChoice)
    {
        var choiceKind = StartingEquipmentService.GetChoiceKind(package);
        if (string.IsNullOrWhiteSpace(choiceKind)) return string.Empty;
        var choices = StartingEquipmentService.GetChoiceOptions(choiceKind);
        var match = choices.FirstOrDefault(choice => choice.Equals(requestedChoice ?? "", StringComparison.OrdinalIgnoreCase));
        if (match is null) throw new ArgumentException("Choose a valid starting equipment option.");
        return match;
    }

    public static DiscordSpellSaveItem SpellSaveItem(SrdSpellReference reference, bool prepared, string sourceTag) => new()
    {
        SpellName = reference.Name,
        SpellLevel = reference.Level,
        Prepared = prepared,
        SourceTag = sourceTag,
        CastingTime = reference.CastingTime,
        Range = reference.Range,
        Components = reference.Components,
        Duration = reference.Duration,
        Description = reference.Description
    };

    public static SrdSpellReference FindSpell(IEnumerable<SrdSpellReference> available, string name)
    {
        var spell = available.FirstOrDefault(s => s.Name.Equals(name, StringComparison.OrdinalIgnoreCase) ||
            (!string.IsNullOrWhiteSpace(s.PhbTitle) && s.PhbTitle.Equals(name, StringComparison.OrdinalIgnoreCase)));
        if (spell is null) throw new ArgumentException($"Invalid spell selection: {name}");
        return spell;
    }

    public static List<string> CleanDistinct(IEnumerable<string>? values) =>
        (values ?? Array.Empty<string>())
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Select(v => v.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
}
