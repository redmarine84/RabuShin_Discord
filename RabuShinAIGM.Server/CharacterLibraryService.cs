using System.Text.Json.Serialization;
using QuestsOfRabuShinAIGM;

public sealed partial class DiscordSupabaseService
{
    // BUILD 6.30.9 - CHARACTER LIBRARY / CAMPAIGN MEMBERSHIP

    public async Task<List<CharacterLibraryInfo>> GetCharacterLibraryAsync(Guid playerId)
    {
        using var response = await CallRpcAsync("discord_get_character_library", new
        {
            p_player_id = playerId
        });
        return await ReadListAsync<CharacterLibraryInfo>(response, "Unable to load Character Library");
    }

    public async Task<Guid> CreateLibraryCharacterWithFeaturesAsync(
        Guid playerId,
        PlayerCharacter character,
        string requestedSpecies,
        AppliedRacialScores scores,
        CharacterFeatureProfile features,
        string appearance,
        string personality,
        string backstory,
        string notes,
        string gender)
    {
        static int Mod(int score) => (int)Math.Floor((score - 10) / 2.0);

        var constitutionDelta = Mod(scores.Constitution) - Mod(character.Constitution);
        var dexterityDelta = Mod(scores.Dexterity) - Mod(character.Dexterity);
        var wisdomDelta = Mod(scores.Wisdom) - Mod(character.Wisdom);
        var subraceHpBonus = Math.Max(0, features.HitPointBonusPerLevel) * Math.Max(1, character.Level);
        var maxHp = Math.Max(1, character.MaxHitPoints + constitutionDelta * Math.Max(1, character.Level) + subraceHpBonus);
        var currentHp = Math.Max(1, character.CurrentHitPoints + constitutionDelta * Math.Max(1, character.Level) + subraceHpBonus);
        var armorClass = features.NaturalArmorBase.HasValue
            ? Math.Max(features.NaturalArmorBase.Value, character.ArmorClass + dexterityDelta)
            : character.ArmorClass + dexterityDelta;

        var characterData = new
        {
            character_name = character.CharacterName,
            species_name = requestedSpecies,
            class_name = character.ClassName,
            background_name = character.BackgroundName,
            alignment = character.Alignment,
            gender,
            level = character.Level,
            experience = character.ExperiencePoints,
            current_hp = currentHp,
            max_hp = maxHp,
            armor_class = armorClass,
            strength = scores.Strength,
            dexterity = scores.Dexterity,
            constitution = scores.Constitution,
            intelligence = scores.Intelligence,
            wisdom = scores.Wisdom,
            charisma = scores.Charisma,
            initiative = character.Initiative + dexterityDelta,
            passive_perception = character.PassivePerception + wisdomDelta,
            proficiency_bonus = character.ProficiencyBonus,
            speed = features.SpeedOverride.HasValue ? features.SpeedOverride.Value : character.Speed,
            size_name = string.IsNullOrWhiteSpace(features.Size) ? character.SizeName : features.Size,
            gold = character.Gold,
            appearance = appearance ?? string.Empty,
            personality = personality ?? string.Empty,
            backstory = backstory ?? string.Empty,
            notes = notes ?? string.Empty,
            features,
            snapshot = character
        };

        using var response = await CallRpcAsync("discord_create_library_character", new
        {
            p_player_id = playerId,
            p_character_data = characterData,
            p_secondary_heritage = features.SecondaryHeritage,
            p_appearance = appearance ?? string.Empty,
            p_personality = personality ?? string.Empty,
            p_backstory = backstory ?? string.Empty,
            p_notes = notes ?? string.Empty,
            p_racial_traits = features,
            p_gender = gender
        });

        return await ReadGuidResultAsync(response, "Unable to create Character Library character");
    }

    public async Task<Guid> AssignLibraryCharacterAsync(Guid playerId, Guid campaignId, Guid characterId)
    {
        using var response = await CallRpcAsync("discord_assign_library_character", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_character_id = characterId
        });
        return await ReadGuidResultAsync(response, "Unable to assign Character Library character");
    }

    public async Task DeleteLibraryCharacterAsync(Guid playerId, Guid characterId)
    {
        string? portraitPath = null;
        try
        {
            portraitPath = (await GetCharacterLibraryAsync(playerId))
                .FirstOrDefault(c => c.CharacterId == characterId)?.PortraitPath;
        }
        catch
        {
            // A storage cleanup lookup must never block a database deletion.
        }

        using var response = await CallRpcAsync("discord_delete_library_character", new
        {
            p_player_id = playerId,
            p_character_id = characterId
        });
        await EnsureSuccessAsync(response, "Unable to delete Character Library character");

        if (!string.IsNullOrWhiteSpace(portraitPath))
            await TryDeletePortraitObjectAsync(portraitPath);
    }

    public async Task<CharacterLibraryMutationInfo> ResolvePendingCharacterAsync(
        Guid playerId,
        Guid characterId,
        string action,
        Guid? replaceCharacterId)
    {
        string? portraitToDelete = null;
        if (string.Equals(action, "delete", StringComparison.OrdinalIgnoreCase) ||
            replaceCharacterId.HasValue)
        {
            try
            {
                var library = await GetCharacterLibraryAsync(playerId);
                var doomedId = string.Equals(action, "delete", StringComparison.OrdinalIgnoreCase)
                    ? characterId
                    : replaceCharacterId!.Value;
                portraitToDelete = library.FirstOrDefault(c => c.CharacterId == doomedId)?.PortraitPath;
            }
            catch
            {
                // Optional object cleanup only.
            }
        }

        using var response = await CallRpcAsync("discord_resolve_pending_character", new
        {
            p_player_id = playerId,
            p_character_id = characterId,
            p_action = action,
            p_replace_character_id = replaceCharacterId
        });

        var rows = await ReadListAsync<CharacterLibraryMutationInfo>(
            response, "Unable to resolve Character Library decision");
        var result = rows.FirstOrDefault()
            ?? throw new InvalidOperationException("Character Library decision returned no result.");

        if (result.WasDeleted && !string.IsNullOrWhiteSpace(portraitToDelete))
            await TryDeletePortraitObjectAsync(portraitToDelete);
        else if (replaceCharacterId.HasValue && !string.IsNullOrWhiteSpace(portraitToDelete))
            await TryDeletePortraitObjectAsync(portraitToDelete);

        return result;
    }

    public async Task<CharacterDeparturePreviewInfo?> GetCharacterDeparturePreviewAsync(
        Guid playerId,
        Guid campaignId,
        Guid? characterId = null)
    {
        using var response = await CallRpcAsync("discord_get_character_departure_preview", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_character_id = characterId
        });
        var rows = await ReadListAsync<CharacterDeparturePreviewInfo>(
            response, "Unable to inspect character departure");
        return rows.FirstOrDefault();
    }

    public async Task<List<CampaignMemberManagementInfo>> GetCampaignMembersForManagementAsync(
        Guid ownerPlayerId,
        Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_campaign_members", new
        {
            p_requester_player_id = ownerPlayerId,
            p_campaign_id = campaignId
        });
        return await ReadListAsync<CampaignMemberManagementInfo>(
            response, "Unable to load campaign players");
    }

    public async Task KickCampaignPlayerAsync(Guid ownerPlayerId, Guid campaignId, Guid targetPlayerId)
    {
        using var response = await CallRpcAsync("discord_kick_campaign_player", new
        {
            p_owner_player_id = ownerPlayerId,
            p_campaign_id = campaignId,
            p_target_player_id = targetPlayerId
        });
        await EnsureSuccessAsync(response, "Unable to kick player");
    }

    public async Task<SoloCharacterRemovalInfo> RemoveSoloCharacterAsync(
        Guid ownerPlayerId,
        Guid campaignId,
        Guid characterId)
    {
        using var response = await CallRpcAsync("discord_remove_solo_character", new
        {
            p_owner_player_id = ownerPlayerId,
            p_campaign_id = campaignId,
            p_character_id = characterId
        });
        var rows = await ReadListAsync<SoloCharacterRemovalInfo>(
            response, "Unable to remove Solo character");
        return rows.FirstOrDefault()
            ?? throw new InvalidOperationException("Solo character removal returned no result.");
    }
}

public sealed class CharacterLibraryInfo
{
    [JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
    [JsonPropertyName("character_name")] public string CharacterName { get; set; } = string.Empty;
    [JsonPropertyName("species_name")] public string SpeciesName { get; set; } = string.Empty;
    [JsonPropertyName("class_name")] public string ClassName { get; set; } = string.Empty;
    [JsonPropertyName("background_name")] public string BackgroundName { get; set; } = string.Empty;
    [JsonPropertyName("alignment")] public string Alignment { get; set; } = string.Empty;
    [JsonPropertyName("gender")] public string? Gender { get; set; }
    [JsonPropertyName("level")] public int Level { get; set; }
    [JsonPropertyName("experience")] public int Experience { get; set; }
    [JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
    [JsonPropertyName("max_hp")] public int MaxHp { get; set; }
    [JsonPropertyName("armor_class")] public int ArmorClass { get; set; }
    [JsonPropertyName("library_slot")] public int? LibrarySlot { get; set; }
    [JsonPropertyName("character_origin")] public string CharacterOrigin { get; set; } = "campaign";
    [JsonPropertyName("character_status")] public string CharacterStatus { get; set; } = "available";
    [JsonPropertyName("pending_reason")] public string PendingReason { get; set; } = string.Empty;
    [JsonPropertyName("campaign_id")] public Guid? CampaignId { get; set; }
    [JsonPropertyName("campaign_name")] public string? CampaignName { get; set; }
    [JsonPropertyName("equipment_complete")] public bool EquipmentComplete { get; set; }
    [JsonPropertyName("spells_complete")] public bool SpellsComplete { get; set; }
    [JsonPropertyName("portrait_path")] public string? PortraitPath { get; set; }
}

public sealed class CharacterLibraryMutationInfo
{
    [JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
    [JsonPropertyName("character_status")] public string CharacterStatus { get; set; } = string.Empty;
    [JsonPropertyName("library_slot")] public int? LibrarySlot { get; set; }
    [JsonPropertyName("was_deleted")] public bool WasDeleted { get; set; }
}

public sealed class CharacterDeparturePreviewInfo
{
    [JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
    [JsonPropertyName("character_name")] public string CharacterName { get; set; } = string.Empty;
    [JsonPropertyName("is_library_character")] public bool IsLibraryCharacter { get; set; }
    [JsonPropertyName("requires_store_delete_choice")] public bool RequiresStoreDeleteChoice { get; set; }
    [JsonPropertyName("library_slot")] public int? LibrarySlot { get; set; }
}

public sealed class CampaignMemberManagementInfo
{
    [JsonPropertyName("player_id")] public Guid PlayerId { get; set; }
    [JsonPropertyName("display_name")] public string DisplayName { get; set; } = string.Empty;
    [JsonPropertyName("discord_username")] public string DiscordUsername { get; set; } = string.Empty;
    [JsonPropertyName("role")] public string Role { get; set; } = string.Empty;
    [JsonPropertyName("is_owner")] public bool IsOwner { get; set; }
    [JsonPropertyName("character_name")] public string? CharacterName { get; set; }
}

public sealed class SoloCharacterRemovalInfo
{
    [JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
    [JsonPropertyName("character_status")] public string CharacterStatus { get; set; } = string.Empty;
    [JsonPropertyName("library_slot")] public int? LibrarySlot { get; set; }
}
