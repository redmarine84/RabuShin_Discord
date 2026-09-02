using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using QuestsOfRabuShinAIGM;

public sealed class DiscordSupabaseService
{
    private readonly HttpClient _http;
    private readonly string _supabaseUrl;
    private readonly string _supabaseSecretKey;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public DiscordSupabaseService(HttpClient http, IConfiguration configuration)
    {
        _http = http;
        _supabaseUrl = configuration["Supabase:Url"]
            ?? throw new InvalidOperationException("Supabase:Url is not configured.");
        _supabaseSecretKey = configuration["Supabase:SecretKey"]
            ?? throw new InvalidOperationException("Supabase:SecretKey is not configured.");
    }

    public async Task<DiscordUserInfo> VerifyDiscordUserAsync(string? authorizationHeader)
    {
        if (string.IsNullOrWhiteSpace(authorizationHeader) ||
            !authorizationHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            throw new UnauthorizedAccessException("Discord authorization token is missing.");
        }

        var accessToken = authorizationHeader["Bearer ".Length..].Trim();
        if (accessToken.Length == 0)
            throw new UnauthorizedAccessException("Discord access token is missing.");

        using var request = new HttpRequestMessage(HttpMethod.Get, "https://discord.com/api/v10/users/@me");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        using var response = await _http.SendAsync(request);
        if (!response.IsSuccessStatusCode)
            throw new UnauthorizedAccessException("Discord could not verify this player.");

        var user = await response.Content.ReadFromJsonAsync<DiscordUserInfo>(JsonOptions);
        if (user is null || string.IsNullOrWhiteSpace(user.Id))
            throw new UnauthorizedAccessException("Discord returned an invalid player.");
        return user;
    }

    public async Task<Guid> GetOrCreatePlayerAsync(DiscordUserInfo user)
    {
        using var response = await CallRpcAsync("discord_upsert_player", new
        {
            p_discord_user_id = user.Id,
            p_discord_username = user.Username,
            p_display_name = user.GlobalName ?? user.Username
        });
        return await ReadGuidResultAsync(response, "Unable to register Discord player");
    }

    public async Task<List<DiscordCampaignInfo>> GetCampaignsAsync(Guid playerId)
    {
        using var response = await CallRpcAsync("discord_get_my_campaigns", new { p_player_id = playerId });
        return await ReadListAsync<DiscordCampaignInfo>(response, "Unable to load campaigns");
    }

    public async Task<Guid> CreateCampaignAsync(Guid playerId, string campaignName)
    {
        if (string.IsNullOrWhiteSpace(campaignName)) throw new ArgumentException("Campaign name is required.");
        using var response = await CallRpcAsync("discord_create_campaign", new
        {
            p_player_id = playerId,
            p_campaign_name = campaignName.Trim()
        });
        return await ReadGuidResultAsync(response, "Unable to create campaign");
    }

    public async Task<Guid> JoinCampaignAsync(Guid playerId, string joinCode)
    {
        if (string.IsNullOrWhiteSpace(joinCode)) throw new ArgumentException("Campaign code is required.");
        using var response = await CallRpcAsync("discord_join_campaign", new
        {
            p_player_id = playerId,
            p_join_code = joinCode.Trim()
        });
        return await ReadGuidResultAsync(response, "Unable to join campaign");
    }

    public async Task DeleteCampaignAsync(Guid playerId, Guid campaignId)
    {
        var portraitPaths = new List<string>();
        try
        {
            portraitPaths = (await GetPartyAsync(playerId, campaignId))
                .Select(member => member.PortraitPath)
                .Where(path => !string.IsNullOrWhiteSpace(path))
                .Select(path => path!)
                .Distinct(StringComparer.Ordinal)
                .ToList();
        }
        catch
        {
            // Campaign deletion must not be blocked if portrait cleanup discovery fails.
        }

        using var response = await CallRpcAsync("discord_delete_campaign", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        await EnsureSuccessAsync(response, "Unable to delete campaign");

        foreach (var path in portraitPaths)
            await TryDeletePortraitObjectAsync(path);
    }

    public async Task LeaveCampaignAsync(Guid playerId, Guid campaignId)
    {
        string? portraitPath = null;
        try
        {
            var character = await GetCharacterAsync(playerId, campaignId);
            if (character is not null)
            {
                var party = await GetPartyAsync(playerId, campaignId);
                portraitPath = party.FirstOrDefault(member => member.CharacterId == character.CharacterId)?.PortraitPath;
            }
        }
        catch
        {
            // Leaving the campaign must not be blocked by optional portrait cleanup.
        }

        using var response = await CallRpcAsync("discord_leave_campaign", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        await EnsureSuccessAsync(response, "Unable to leave campaign");

        if (!string.IsNullOrWhiteSpace(portraitPath))
            await TryDeletePortraitObjectAsync(portraitPath);
    }

    public async Task<DiscordCharacterInfo?> GetCharacterAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_character", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        var list = await ReadListAsync<DiscordCharacterInfo>(response, "Unable to load character");
        return list.FirstOrDefault();
    }

    public async Task<Guid> CreateCharacterAsync(Guid playerId, Guid campaignId, PlayerCharacter character)
    {
        var characterData = new
        {
            character_name = character.CharacterName,
            species_name = character.SpeciesName,
            class_name = character.ClassName,
            background_name = character.BackgroundName,
            alignment = character.Alignment,
            level = character.Level,
            experience = character.ExperiencePoints,
            current_hp = character.CurrentHitPoints,
            max_hp = character.MaxHitPoints,
            armor_class = character.ArmorClass,
            strength = character.Strength,
            dexterity = character.Dexterity,
            constitution = character.Constitution,
            intelligence = character.Intelligence,
            wisdom = character.Wisdom,
            charisma = character.Charisma,
            initiative = character.Initiative,
            passive_perception = character.PassivePerception,
            proficiency_bonus = character.ProficiencyBonus,
            speed = character.Speed,
            size_name = character.SizeName,
            gold = character.Gold,
            snapshot = character
        };

        using var response = await CallRpcAsync("discord_create_character", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_character_data = characterData
        });
        return await ReadGuidResultAsync(response, "Unable to create character");
    }

    public async Task<Guid> CreateCharacterWithFeaturesAsync(
        Guid playerId,
        Guid campaignId,
        PlayerCharacter character,
        string requestedSpecies,
        AppliedRacialScores scores,
        CharacterFeatureProfile features,
        string appearance,
        string personality,
        string backstory,
        string notes)
    {
        static int Mod(int score) => (int)Math.Floor((score - 10) / 2.0);

        var constitutionDelta = Mod(scores.Constitution) - Mod(character.Constitution);
        var dexterityDelta = Mod(scores.Dexterity) - Mod(character.Dexterity);
        var wisdomDelta = Mod(scores.Wisdom) - Mod(character.Wisdom);
        var maxHp = Math.Max(1, character.MaxHitPoints + constitutionDelta * Math.Max(1, character.Level));
        var currentHp = Math.Max(1, character.CurrentHitPoints + constitutionDelta * Math.Max(1, character.Level));
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
            speed = character.Speed,
            size_name = string.IsNullOrWhiteSpace(features.Size) ? character.SizeName : features.Size,
            gold = character.Gold,
            appearance = appearance ?? string.Empty,
            personality = personality ?? string.Empty,
            backstory = backstory ?? string.Empty,
            notes = notes ?? string.Empty,
            features,
            snapshot = character
        };

        using var response = await CallRpcAsync("discord_create_character", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_character_data = characterData
        });
        var id = await ReadGuidResultAsync(response, "Unable to create character");

        using var featureResponse = await CallRpcAsync("discord_set_character_features", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_character_id = id,
            p_secondary_heritage = features.SecondaryHeritage,
            p_appearance = appearance ?? string.Empty,
            p_personality = personality ?? string.Empty,
            p_backstory = backstory ?? string.Empty,
            p_notes = notes ?? string.Empty,
            p_racial_traits = features
        });
        await EnsureSuccessAsync(featureResponse, "Unable to save racial traits and character details");
        return id;
    }

    public async Task<DiscordCharacterFeatureState?> GetCharacterFeatureStateAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_character_features", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        var list = await ReadListAsync<DiscordCharacterFeatureState>(response, "Unable to load character details");
        return list.FirstOrDefault();
    }

    public async Task UpdateCharacterDetailsAsync(
        Guid playerId, Guid campaignId, string background, string appearance,
        string personality, string backstory, string notes)
    {
        using var response = await CallRpcAsync("discord_update_character_details", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_background = background ?? string.Empty,
            p_appearance = appearance ?? string.Empty,
            p_personality = personality ?? string.Empty,
            p_backstory = backstory ?? string.Empty,
            p_notes = notes ?? string.Empty
        });
        await EnsureSuccessAsync(response, "Unable to update character details");
    }

    public async Task<DiscordCharacterSetupState?> GetCharacterSetupStateAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_character_setup_state", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        var list = await ReadListAsync<DiscordCharacterSetupState>(response, "Unable to load character setup state");
        return list.FirstOrDefault();
    }

    public async Task<List<DiscordPartyMember>> GetPartyAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_party", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        return await ReadListAsync<DiscordPartyMember>(response, "Unable to load party");
    }

    public async Task UploadCharacterPortraitAsync(
        Guid playerId, Guid campaignId, Stream portraitStream, string contentType)
    {
        var character = await GetCharacterAsync(playerId, campaignId)
            ?? throw new InvalidOperationException("Character could not be found.");

        var portraitPath = $"{campaignId:D}/{character.CharacterId:D}";
        await UploadPortraitObjectAsync(portraitPath, portraitStream, contentType);

        using var response = await CallRpcAsync("discord_set_character_portrait", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_portrait_path = portraitPath
        });
        await EnsureSuccessAsync(response, "Unable to save character portrait");
    }

    public async Task ClearCharacterPortraitAsync(Guid playerId, Guid campaignId)
    {
        var character = await GetCharacterAsync(playerId, campaignId)
            ?? throw new InvalidOperationException("Character could not be found.");
        var party = await GetPartyAsync(playerId, campaignId);
        var portraitPath = party.FirstOrDefault(member => member.CharacterId == character.CharacterId)?.PortraitPath;

        using var response = await CallRpcAsync("discord_set_character_portrait", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_portrait_path = (string?)null
        });
        await EnsureSuccessAsync(response, "Unable to remove character portrait");

        if (!string.IsNullOrWhiteSpace(portraitPath))
            await TryDeletePortraitObjectAsync(portraitPath);
    }

    public async Task<DiscordPortraitObject?> GetPartyPortraitAsync(
        Guid viewerPlayerId, Guid campaignId, Guid characterId)
    {
        var party = await GetPartyAsync(viewerPlayerId, campaignId);
        var member = party.FirstOrDefault(item => item.CharacterId == characterId);
        if (member is null)
            throw new UnauthorizedAccessException("That character is not part of this campaign.");
        if (string.IsNullOrWhiteSpace(member.PortraitPath))
            return null;
        return await DownloadPortraitObjectAsync(member.PortraitPath);
    }

    public async Task SaveStartingEquipmentAsync(
        Guid playerId, Guid campaignId, decimal gold, List<DiscordStartingInventoryItem> items)
    {
        using var response = await CallRpcAsync("discord_set_starting_equipment", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_gold = gold,
            p_items = items
        });
        await EnsureSuccessAsync(response, "Unable to save starting equipment");
    }

    public async Task<List<DiscordInventoryInfo>> GetInventoryAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_inventory", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        return await ReadListAsync<DiscordInventoryInfo>(response, "Unable to load inventory");
    }

    public async Task SetInventoryEquippedAsync(
        Guid playerId, Guid campaignId, Guid inventoryItemId, bool equipped)
    {
        using var response = await CallRpcAsync("discord_set_inventory_equipped", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_inventory_item_id = inventoryItemId,
            p_equipped = equipped
        });
        await EnsureSuccessAsync(response, "Unable to update equipped item");
    }

    public async Task<int> RemoveInventoryQuantityAsync(
        Guid playerId, Guid campaignId, Guid inventoryItemId, int quantity)
    {
        using var response = await CallRpcAsync("discord_remove_inventory_quantity", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_inventory_item_id = inventoryItemId,
            p_quantity = quantity
        });

        var text = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException("Unable to remove inventory item: " + text);

        if (int.TryParse(text.Trim().Trim('"'), out var remaining)) return remaining;
        throw new InvalidOperationException("Supabase returned an invalid remaining inventory quantity.");
    }

    public async Task SaveSpellsAsync(
        Guid playerId, Guid campaignId,
        List<DiscordSpellSaveItem> spells,
        List<DiscordSpellSlotSaveItem> slots)
    {
        using var response = await CallRpcAsync("discord_set_spells", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_spells = spells,
            p_slots = slots
        });
        await EnsureSuccessAsync(response, "Unable to save spells");
    }

    public async Task<List<DiscordSpellInfo>> GetSpellsAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_spells", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        return await ReadListAsync<DiscordSpellInfo>(response, "Unable to load spells");
    }

    public async Task<List<DiscordSpellSlotInfo>> GetSpellSlotsAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_spell_slots", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        return await ReadListAsync<DiscordSpellSlotInfo>(response, "Unable to load spell slots");
    }

    public async Task<long> AddMessageAsync(
        Guid playerId, Guid campaignId, string channel, string role, string senderName, string message)
    {
        using var response = await CallRpcAsync("discord_add_message", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_channel_name = channel,
            p_role_name = role,
            p_sender_name = senderName,
            p_message_text = message
        });
        return await ReadLongResultAsync(response, "Unable to save message");
    }

    public async Task<List<DiscordTimelineMessage>> GetMessagesAsync(
        Guid playerId, Guid campaignId, string channel, int limit = 100)
    {
        using var response = await CallRpcAsync("discord_get_messages", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_channel_name = channel,
            p_limit = limit
        });
        return await ReadListAsync<DiscordTimelineMessage>(response, "Unable to load messages");
    }

    public async Task<long> AddJournalAsync(
        Guid playerId, Guid campaignId, string category, string title, string entryText)
    {
        using var response = await CallRpcAsync("discord_add_journal", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_category = category,
            p_title = title,
            p_entry_text = entryText
        });
        return await ReadLongResultAsync(response, "Unable to save journal entry");
    }

    public async Task<List<DiscordJournalEntry>> GetJournalAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_journal", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        return await ReadListAsync<DiscordJournalEntry>(response, "Unable to load journal");
    }


    public async Task<DiscordStoredOpenAiKey?> GetStoredOpenAiKeyAsync(Guid playerId)
    {
        using var response = await CallRpcAsync("discord_get_openai_key", new { p_player_id = playerId });
        var list = await ReadListAsync<DiscordStoredOpenAiKey>(response, "Unable to load OpenAI key status");
        return list.FirstOrDefault();
    }

    public async Task<bool> HasStoredOpenAiKeyAsync(Guid playerId)
    {
        var stored = await GetStoredOpenAiKeyAsync(playerId);
        return stored is not null && !string.IsNullOrWhiteSpace(stored.EncryptedValue);
    }

    public async Task SaveStoredOpenAiKeyAsync(Guid playerId, string encryptedValue)
    {
        if (string.IsNullOrWhiteSpace(encryptedValue))
            throw new ArgumentException("Encrypted OpenAI API key is required.", nameof(encryptedValue));

        using var response = await CallRpcAsync("discord_set_openai_key", new
        {
            p_player_id = playerId,
            p_encrypted_value = encryptedValue
        });
        await EnsureSuccessAsync(response, "Unable to save OpenAI API key");
    }

    public async Task ClearStoredOpenAiKeyAsync(Guid playerId)
    {
        using var response = await CallRpcAsync("discord_clear_openai_key", new { p_player_id = playerId });
        await EnsureSuccessAsync(response, "Unable to remove OpenAI API key");
    }

    private async Task UploadPortraitObjectAsync(string portraitPath, Stream portraitStream, string contentType)
    {
        var url = $"{_supabaseUrl.TrimEnd('/')}/storage/v1/object/character-portraits/{EscapeStoragePath(portraitPath)}";
        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        AddSupabaseServiceHeaders(request);
        request.Headers.TryAddWithoutValidation("x-upsert", "true");
        request.Content = new StreamContent(portraitStream);
        request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
        using var response = await _http.SendAsync(request);
        await EnsureSuccessAsync(response, "Unable to upload character portrait");
    }

    private async Task<DiscordPortraitObject> DownloadPortraitObjectAsync(string portraitPath)
    {
        var url = $"{_supabaseUrl.TrimEnd('/')}/storage/v1/object/character-portraits/{EscapeStoragePath(portraitPath)}";
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        AddSupabaseServiceHeaders(request);
        using var response = await _http.SendAsync(request);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync();
            throw new InvalidOperationException($"Unable to load character portrait: {body}");
        }

        var bytes = await response.Content.ReadAsByteArrayAsync();
        var contentType = response.Content.Headers.ContentType?.MediaType ?? "application/octet-stream";
        return new DiscordPortraitObject(bytes, contentType);
    }

    private async Task TryDeletePortraitObjectAsync(string portraitPath)
    {
        try
        {
            var url = $"{_supabaseUrl.TrimEnd('/')}/storage/v1/object/character-portraits";
            using var request = new HttpRequestMessage(HttpMethod.Delete, url);
            AddSupabaseServiceHeaders(request);
            request.Content = JsonContent.Create(new { prefixes = new[] { portraitPath } });
            using var response = await _http.SendAsync(request);
        }
        catch
        {
            // Portrait storage cleanup is best-effort.
        }
    }

    private void AddSupabaseServiceHeaders(HttpRequestMessage request)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _supabaseSecretKey);
        request.Headers.TryAddWithoutValidation("apikey", _supabaseSecretKey);
    }

    private static string EscapeStoragePath(string path) =>
        string.Join("/", path.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.EscapeDataString));

    // VISUALS BUILD 2 - WORLD MAP STATE
    public async Task<List<DiscordWorldMapState>> GetWorldMapStateAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_world_map_state", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        return await ReadListAsync<DiscordWorldMapState>(response, "Unable to load World Map");
    }
    // VISUALS BUILD 3 - LOCAL MAP STATE
    public async Task<DiscordLocalMapState?> GetLocalMapStateAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_local_map_state", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        var list = await ReadListAsync<DiscordLocalMapState>(response, "Unable to load Settlement/Encounter Map state");
        return list.FirstOrDefault();
    }
    // VISUALS BUILD 4 - MONSTER COMBAT STATE
    public async Task<DiscordCombatStateRow?> GetCombatStateAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_combat_state", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        var rows = await ReadListAsync<DiscordCombatStateRow>(response, "Unable to load Combat state");
        return rows.FirstOrDefault();
    }
    // VISUALS BUILD 5 - TACTICAL COMBAT STATE
    public async Task<DiscordTacticalCombatStateRow?> GetTacticalCombatStateAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_tactical_combat_state", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        var rows = await ReadListAsync<DiscordTacticalCombatStateRow>(response, "Unable to load Tactical Combat state");
        return rows.FirstOrDefault();
    }

    public async Task<TacticalMoveResult> MoveOwnCombatTokenAsync(
        Guid playerId,
        Guid campaignId,
        int gridX,
        int gridY)
    {
        using var response = await CallRpcAsync("discord_move_own_combat_token", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_grid_x = gridX,
            p_grid_y = gridY
        });

        var json = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Unable to move tactical token: {json}");

        return JsonSerializer.Deserialize<TacticalMoveResult>(json, JsonOptions)
            ?? throw new InvalidOperationException("Supabase returned an invalid tactical movement result.");
    }
    // VISUALS BUILD 5.1 - TACTICAL TERRAIN RPC
    public async Task<List<TacticalDoorStateRow>> GetTacticalDoorStatesAsync(
        Guid playerId,
        Guid campaignId,
        string locationKey)
    {
        using var response = await CallRpcAsync("discord_get_tactical_door_states", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_location_key = locationKey
        });
        return await ReadListAsync<TacticalDoorStateRow>(response, "Unable to load tactical door state");
    }

    public async Task<TacticalMoveResult> MoveOwnCombatTokenCostedAsync(
        Guid playerId,
        Guid campaignId,
        int gridX,
        int gridY,
        int moveCostFt)
    {
        using var response = await CallRpcAsync("discord_move_own_combat_token_costed", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_grid_x = gridX,
            p_grid_y = gridY,
            p_move_cost_ft = Math.Max(0, moveCostFt)
        });

        var json = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Unable to move tactical token: {json}");

        return JsonSerializer.Deserialize<TacticalMoveResult>(json, JsonOptions)
            ?? throw new InvalidOperationException("Supabase returned an invalid terrain-aware movement result.");
    }
    // RULES BUILD 6.2.2 - CAMPAIGN PRESENCE / ONLINE INITIATIVE
    public async Task TouchCampaignPresenceAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_touch_campaign_presence", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        await EnsureSuccessAsync(response, "Unable to update campaign presence");
    }

    public async Task SkipOfflineCurrentCombatTurnAsync(Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_gm_skip_offline_current_turn", new
        {
            p_campaign_id = campaignId
        });
        await EnsureSuccessAsync(response, "Unable to skip an offline combat turn");
    }

    // COMBAT BUILD 6.1 - STRICT INITIATIVE / PLAYER END TURN
    public async Task<List<CombatInitiativeRow>> GetCombatInitiativeAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_combat_initiative", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        return await ReadListAsync<CombatInitiativeRow>(response, "Unable to load combat initiative");
    }

    public async Task<CombatTurnAdvanceResult> EndPlayerCombatTurnAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_end_player_combat_turn", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        var json = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Unable to end combat turn: {json}");
        return JsonSerializer.Deserialize<CombatTurnAdvanceResult>(json, JsonOptions)
            ?? throw new InvalidOperationException("Supabase returned an invalid combat turn result.");
    }

    // RULES BUILD 6.2 - DEATH / RESPAWN STATE
    public async Task<DeathStateRow?> GetDeathStateAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_death_state", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        var rows = await ReadListAsync<DeathStateRow>(response, "Unable to load death / respawn state");
        return rows.FirstOrDefault();
    }

    public async Task<DeathActionResult> ChooseRespawnAsync(Guid playerId, Guid campaignId, bool respawn)
        => await ReadDeathActionAsync(await CallRpcAsync("discord_choose_respawn", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_respawn = respawn
        }), "Unable to resolve respawn choice");

    public async Task<DeathActionResult> DonateToRespawnAsync(Guid playerId, Guid campaignId, Guid deathId, int amountGp)
        => await ReadDeathActionAsync(await CallRpcAsync("discord_donate_to_respawn", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_death_id = deathId,
            p_amount_gp = Math.Max(0, amountGp)
        }), "Unable to donate to revival");

    public async Task<DeathActionResult> DeclineRespawnDonationAsync(Guid playerId, Guid campaignId, Guid deathId)
        => await ReadDeathActionAsync(await CallRpcAsync("discord_decline_respawn_donation", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_death_id = deathId
        }), "Unable to decline revival donation");

    public async Task<DeathActionResult> FinalizePartyRespawnAsync(Guid playerId, Guid campaignId, Guid deathId)
        => await ReadDeathActionAsync(await CallRpcAsync("discord_finalize_party_respawn", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_death_id = deathId
        }), "Unable to finalize party revival");

    private static async Task<DeathActionResult> ReadDeathActionAsync(HttpResponseMessage response, string prefix)
    {
        using (response)
        {
            var json = await response.Content.ReadAsStringAsync();
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException($"{prefix}: {json}");
            return JsonSerializer.Deserialize<DeathActionResult>(json, JsonOptions)
                ?? throw new InvalidOperationException($"{prefix}: Supabase returned an invalid result.");
        }
    }

    // MULTIPLAYER LIVE CHAT - AI GAME MASTER TURN LEASE
    public async Task<GmTurnStateResult> GetGmTurnStateAsync(Guid playerId, Guid campaignId)
    {
        using var response = await CallRpcAsync("discord_get_gm_turn_state", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId
        });
        return await ReadGmTurnStateAsync(response, "Unable to load AI Game Master turn state");
    }

    public async Task<GmTurnStateResult> AcquireGmTurnAsync(
        Guid playerId,
        Guid campaignId,
        string playerName)
    {
        using var response = await CallRpcAsync("discord_acquire_gm_turn", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_player_name = playerName
        });
        return await ReadGmTurnStateAsync(response, "Unable to acquire AI Game Master turn");
    }

    public async Task<GmTurnStateResult> BeginGmProcessingAsync(
        Guid playerId,
        Guid campaignId,
        Guid lockToken)
    {
        using var response = await CallRpcAsync("discord_begin_gm_processing", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_lock_token = lockToken
        });
        return await ReadGmTurnStateAsync(response, "Unable to begin AI Game Master turn");
    }

    public async Task ReleaseGmTurnAsync(Guid playerId, Guid campaignId, Guid lockToken)
    {
        using var response = await CallRpcAsync("discord_release_gm_turn", new
        {
            p_player_id = playerId,
            p_campaign_id = campaignId,
            p_lock_token = lockToken
        });
        await EnsureSuccessAsync(response, "Unable to release AI Game Master turn");
    }

    private static async Task<GmTurnStateResult> ReadGmTurnStateAsync(
        HttpResponseMessage response,
        string prefix)
    {
        var json = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"{prefix}: {json}");

        return JsonSerializer.Deserialize<GmTurnStateResult>(json, JsonOptions)
            ?? throw new InvalidOperationException($"{prefix}: Supabase returned an invalid turn state.");
    }

    private async Task<HttpResponseMessage> CallRpcAsync(string functionName, object body)
    {
        var json = JsonSerializer.Serialize(body);
        var url = $"{_supabaseUrl.TrimEnd('/')}/rest/v1/rpc/{functionName}";
        var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.TryAddWithoutValidation("apikey", _supabaseSecretKey);
        request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        return await _http.SendAsync(request);
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage response, string prefix)
    {
        if (response.IsSuccessStatusCode) return;
        var json = await response.Content.ReadAsStringAsync();
        throw new InvalidOperationException($"{prefix}: {json}");
    }

    private static async Task<List<T>> ReadListAsync<T>(HttpResponseMessage response, string prefix)
    {
        var json = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"{prefix}: {json}");
        return JsonSerializer.Deserialize<List<T>>(json, JsonOptions) ?? new List<T>();
    }

    private static async Task<Guid> ReadGuidResultAsync(HttpResponseMessage response, string prefix)
    {
        var json = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"{prefix}: {json}");
        var value = JsonSerializer.Deserialize<string>(json, JsonOptions);
        if (!Guid.TryParse(value, out var id)) throw new InvalidOperationException($"{prefix}: Supabase returned an invalid UUID.");
        return id;
    }

    private static async Task<long> ReadLongResultAsync(HttpResponseMessage response, string prefix)
    {
        var json = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"{prefix}: {json}");
        if (long.TryParse(json, out var direct)) return direct;
        try
        {
            var value = JsonSerializer.Deserialize<long>(json, JsonOptions);
            return value;
        }
        catch
        {
            throw new InvalidOperationException($"{prefix}: Supabase returned an invalid numeric ID.");
        }
    }
}

public sealed class DeathStateRow
{
    [JsonPropertyName("death_id")] public Guid DeathId { get; set; }
    [JsonPropertyName("dead_player_id")] public Guid DeadPlayerId { get; set; }
    [JsonPropertyName("dead_character_name")] public string DeadCharacterName { get; set; } = string.Empty;
    [JsonPropertyName("status")] public string Status { get; set; } = string.Empty;
    [JsonPropertyName("required_gp")] public int RequiredGp { get; set; }
    [JsonPropertyName("donated_gp")] public int DonatedGp { get; set; }
    [JsonPropertyName("remaining_gp")] public int RemainingGp { get; set; }
    [JsonPropertyName("viewer_is_dead_player")] public bool ViewerIsDeadPlayer { get; set; }
    [JsonPropertyName("viewer_is_eligible_donor")] public bool ViewerIsEligibleDonor { get; set; }
    [JsonPropertyName("viewer_decision")] public string ViewerDecision { get; set; } = string.Empty;
    [JsonPropertyName("viewer_donated_gp")] public int ViewerDonatedGp { get; set; }
    [JsonPropertyName("viewer_gold")] public decimal ViewerGold { get; set; }
    [JsonPropertyName("dead_character_gold")] public decimal DeadCharacterGold { get; set; }
    [JsonPropertyName("eligible_donor_count")] public int EligibleDonorCount { get; set; }
    [JsonPropertyName("answered_donor_count")] public int AnsweredDonorCount { get; set; }
    [JsonPropertyName("can_finalize")] public bool CanFinalize { get; set; }
    [JsonPropertyName("cause")] public string Cause { get; set; } = string.Empty;
    [JsonPropertyName("created_at")] public DateTimeOffset CreatedAt { get; set; }
}

public sealed class DeathActionResult
{
    [JsonPropertyName("outcome")] public string Outcome { get; set; } = string.Empty;
    [JsonPropertyName("character_name")] public string CharacterName { get; set; } = string.Empty;
    [JsonPropertyName("requires_new_character")] public bool RequiresNewCharacter { get; set; }
    [JsonPropertyName("required_gp")] public int RequiredGp { get; set; }
    [JsonPropertyName("dead_character_gold")] public decimal DeadCharacterGold { get; set; }
    [JsonPropertyName("paid_gp")] public int PaidGp { get; set; }
    [JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
    [JsonPropertyName("max_hp")] public int MaxHp { get; set; }
    [JsonPropertyName("remaining_gold")] public decimal RemainingGold { get; set; }
    [JsonPropertyName("donor_character_name")] public string DonorCharacterName { get; set; } = string.Empty;
    [JsonPropertyName("donated_now")] public int DonatedNow { get; set; }
    [JsonPropertyName("donated_gp")] public int DonatedGp { get; set; }
    [JsonPropertyName("remaining_gp")] public int RemainingGp { get; set; }
    [JsonPropertyName("can_finalize")] public bool CanFinalize { get; set; }
    [JsonPropertyName("refunded_gp")] public int RefundedGp { get; set; }
}

public sealed class CombatInitiativeRow
{
    [JsonPropertyName("order_position")] public int OrderPosition { get; set; }
    [JsonPropertyName("entity_type")] public string EntityType { get; set; } = string.Empty;
    [JsonPropertyName("character_id")] public Guid? CharacterId { get; set; }
    [JsonPropertyName("combat_monster_id")] public Guid? CombatMonsterId { get; set; }
    [JsonPropertyName("display_name")] public string DisplayName { get; set; } = string.Empty;
    [JsonPropertyName("initiative_roll")] public int InitiativeRoll { get; set; }
    [JsonPropertyName("initiative_modifier")] public int InitiativeModifier { get; set; }
    [JsonPropertyName("initiative_total")] public int InitiativeTotal { get; set; }
    [JsonPropertyName("is_current")] public bool IsCurrent { get; set; }
    [JsonPropertyName("defeated")] public bool Defeated { get; set; }
}

public sealed class CombatTurnAdvanceResult
{
    [JsonPropertyName("round_number")] public int RoundNumber { get; set; }
    [JsonPropertyName("wrapped_round")] public bool WrappedRound { get; set; }
    [JsonPropertyName("current_turn_type")] public string CurrentTurnType { get; set; } = string.Empty;
    [JsonPropertyName("current_turn_character_id")] public Guid? CurrentTurnCharacterId { get; set; }
    [JsonPropertyName("current_turn_monster_id")] public Guid? CurrentTurnMonsterId { get; set; }
    [JsonPropertyName("current_turn_name")] public string CurrentTurnName { get; set; } = string.Empty;
    [JsonPropertyName("order_position")] public int OrderPosition { get; set; }
    [JsonPropertyName("reason")] public string Reason { get; set; } = string.Empty;
}

public sealed class GmTurnStateResult
{
    [JsonPropertyName("active")] public bool Active { get; set; }
    [JsonPropertyName("processing")] public bool Processing { get; set; }
    [JsonPropertyName("is_owner")] public bool IsOwner { get; set; }
    [JsonPropertyName("owner_player_id")] public Guid? OwnerPlayerId { get; set; }
    [JsonPropertyName("owner_name")] public string OwnerName { get; set; } = string.Empty;
    [JsonPropertyName("lock_token")] public Guid? LockToken { get; set; }
    [JsonPropertyName("remaining_seconds")] public int RemainingSeconds { get; set; }
    [JsonPropertyName("expires_at")] public DateTimeOffset? ExpiresAt { get; set; }
}

public sealed class DiscordLocalMapState
{
    [JsonPropertyName("current_location")] public string CurrentLocation { get; set; } = string.Empty;
    [JsonPropertyName("location_key")] public string LocationKey { get; set; } = string.Empty;
    [JsonPropertyName("encounter_active")] public bool EncounterActive { get; set; }
    [JsonPropertyName("encounter_location_key")] public string? EncounterLocationKey { get; set; }
    [JsonPropertyName("encounter_reason")] public string EncounterReason { get; set; } = string.Empty;
}
public sealed class DiscordWorldMapState
{
    [JsonPropertyName("location_key")] public string LocationKey { get; set; } = string.Empty;
    [JsonPropertyName("location_name")] public string LocationName { get; set; } = string.Empty;
    [JsonPropertyName("discovered")] public bool Discovered { get; set; }
    [JsonPropertyName("is_current")] public bool IsCurrent { get; set; }
    [JsonPropertyName("discovered_at")] public DateTimeOffset? DiscoveredAt { get; set; }
}
public sealed class DiscordUserInfo
{
    [JsonPropertyName("id")] public string Id { get; set; } = string.Empty;
    [JsonPropertyName("username")] public string Username { get; set; } = string.Empty;
    [JsonPropertyName("global_name")] public string? GlobalName { get; set; }
}


public sealed class DiscordStoredOpenAiKey
{
    [JsonPropertyName("encrypted_value")] public string EncryptedValue { get; set; } = string.Empty;
    [JsonPropertyName("updated_at")] public DateTimeOffset? UpdatedAt { get; set; }
}

public sealed class DiscordCampaignInfo
{
    [JsonPropertyName("campaign_id")] public Guid CampaignId { get; set; }
    [JsonPropertyName("campaign_name")] public string CampaignName { get; set; } = string.Empty;
    [JsonPropertyName("join_code")] public string JoinCode { get; set; } = string.Empty;
    [JsonPropertyName("current_chapter")] public int CurrentChapter { get; set; }
    [JsonPropertyName("current_location")] public string CurrentLocation { get; set; } = string.Empty;
    [JsonPropertyName("is_owner")] public bool IsOwner { get; set; }
    [JsonPropertyName("member_count")] public long MemberCount { get; set; }
}

public sealed class DiscordCharacterInfo
{
    [JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
    [JsonPropertyName("campaign_id")] public Guid CampaignId { get; set; }
    [JsonPropertyName("character_name")] public string CharacterName { get; set; } = string.Empty;
    [JsonPropertyName("species_name")] public string SpeciesName { get; set; } = string.Empty;
    [JsonPropertyName("class_name")] public string ClassName { get; set; } = string.Empty;
    [JsonPropertyName("background_name")] public string BackgroundName { get; set; } = string.Empty;
    [JsonPropertyName("alignment")] public string Alignment { get; set; } = string.Empty;
    [JsonPropertyName("level")] public int Level { get; set; }
    [JsonPropertyName("experience")] public int Experience { get; set; }
    [JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
    [JsonPropertyName("max_hp")] public int MaxHp { get; set; }
    [JsonPropertyName("armor_class")] public int ArmorClass { get; set; }
    [JsonPropertyName("strength")] public int Strength { get; set; }
    [JsonPropertyName("dexterity")] public int Dexterity { get; set; }
    [JsonPropertyName("constitution")] public int Constitution { get; set; }
    [JsonPropertyName("intelligence")] public int Intelligence { get; set; }
    [JsonPropertyName("wisdom")] public int Wisdom { get; set; }
    [JsonPropertyName("charisma")] public int Charisma { get; set; }
    [JsonPropertyName("initiative")] public int Initiative { get; set; }
    [JsonPropertyName("passive_perception")] public int PassivePerception { get; set; }
    [JsonPropertyName("proficiency_bonus")] public int ProficiencyBonus { get; set; }
    [JsonPropertyName("speed")] public int Speed { get; set; }
    [JsonPropertyName("size_name")] public string SizeName { get; set; } = string.Empty;
    [JsonPropertyName("gold")] public decimal Gold { get; set; }
    [JsonPropertyName("equipment_complete")] public bool EquipmentComplete { get; set; }
    [JsonPropertyName("spells_complete")] public bool SpellsComplete { get; set; }
    [JsonPropertyName("character_data")] public JsonElement CharacterData { get; set; }
}

public sealed class DiscordCharacterFeatureState
{
    [JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
    [JsonPropertyName("background_name")] public string BackgroundName { get; set; } = string.Empty;
    [JsonPropertyName("alignment")] public string Alignment { get; set; } = string.Empty;
    [JsonPropertyName("alignment_deed_balance")] public int AlignmentDeedBalance { get; set; }
    [JsonPropertyName("alignment_good_deeds")] public int AlignmentGoodDeeds { get; set; }
    [JsonPropertyName("alignment_evil_deeds")] public int AlignmentEvilDeeds { get; set; }
    [JsonPropertyName("secondary_heritage")] public string SecondaryHeritage { get; set; } = string.Empty;
    [JsonPropertyName("appearance")] public string Appearance { get; set; } = string.Empty;
    [JsonPropertyName("personality")] public string Personality { get; set; } = string.Empty;
    [JsonPropertyName("backstory")] public string Backstory { get; set; } = string.Empty;
    [JsonPropertyName("notes")] public string Notes { get; set; } = string.Empty;
    [JsonPropertyName("racial_traits")] public JsonElement RacialTraits { get; set; }
}

public sealed class DiscordCharacterSetupState
{
    [JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
    [JsonPropertyName("equipment_complete")] public bool EquipmentComplete { get; set; }
    [JsonPropertyName("spells_complete")] public bool SpellsComplete { get; set; }
}

public sealed class DiscordStartingInventoryItem
{
    [JsonPropertyName("item_name")] public string ItemName { get; set; } = string.Empty;
    [JsonPropertyName("quantity")] public int Quantity { get; set; } = 1;
    [JsonPropertyName("equipped")] public bool Equipped { get; set; }
    [JsonPropertyName("source_name")] public string SourceName { get; set; } = string.Empty;
    [JsonPropertyName("notes")] public string Notes { get; set; } = string.Empty;
}

public sealed class DiscordInventoryInfo
{
    [JsonPropertyName("inventory_item_id")] public Guid InventoryItemId { get; set; }
    [JsonPropertyName("item_name")] public string ItemName { get; set; } = string.Empty;
    [JsonPropertyName("quantity")] public int Quantity { get; set; }
    [JsonPropertyName("equipped")] public bool Equipped { get; set; }
    [JsonPropertyName("attuned")] public bool Attuned { get; set; }
    [JsonPropertyName("source_name")] public string SourceName { get; set; } = string.Empty;
    [JsonPropertyName("notes")] public string Notes { get; set; } = string.Empty;
    [JsonPropertyName("item_data")] public JsonElement ItemData { get; set; }
}

public sealed class DiscordSpellSaveItem
{
    [JsonPropertyName("spell_name")] public string SpellName { get; set; } = string.Empty;
    [JsonPropertyName("spell_level")] public int SpellLevel { get; set; }
    [JsonPropertyName("prepared")] public bool Prepared { get; set; }
    [JsonPropertyName("source_tag")] public string SourceTag { get; set; } = "Class";
    [JsonPropertyName("casting_time")] public string CastingTime { get; set; } = string.Empty;
    [JsonPropertyName("range")] public string Range { get; set; } = string.Empty;
    [JsonPropertyName("components")] public string Components { get; set; } = string.Empty;
    [JsonPropertyName("duration")] public string Duration { get; set; } = string.Empty;
    [JsonPropertyName("description")] public string Description { get; set; } = string.Empty;
}

public sealed class DiscordSpellSlotSaveItem
{
    [JsonPropertyName("spell_level")] public int SpellLevel { get; set; }
    [JsonPropertyName("max_slots")] public int MaxSlots { get; set; }
}

public sealed class DiscordSpellInfo
{
    [JsonPropertyName("character_spell_id")] public Guid CharacterSpellId { get; set; }
    [JsonPropertyName("spell_name")] public string SpellName { get; set; } = string.Empty;
    [JsonPropertyName("spell_level")] public int SpellLevel { get; set; }
    [JsonPropertyName("prepared")] public bool Prepared { get; set; }
    [JsonPropertyName("source_tag")] public string SourceTag { get; set; } = string.Empty;
    [JsonPropertyName("spell_data")] public JsonElement SpellData { get; set; }
}

public sealed class DiscordSpellSlotInfo
{
    [JsonPropertyName("spell_level")] public int SpellLevel { get; set; }
    [JsonPropertyName("max_slots")] public int MaxSlots { get; set; }
    [JsonPropertyName("used_slots")] public int UsedSlots { get; set; }
}

public sealed class DiscordTimelineMessage
{
    [JsonPropertyName("message_id")] public long MessageId { get; set; }
    [JsonPropertyName("role_name")] public string RoleName { get; set; } = string.Empty;
    [JsonPropertyName("sender_name")] public string SenderName { get; set; } = string.Empty;
    [JsonPropertyName("message_text")] public string MessageText { get; set; } = string.Empty;
    [JsonPropertyName("created_at")] public DateTimeOffset CreatedAt { get; set; }
}

public sealed class DiscordJournalEntry
{
    [JsonPropertyName("journal_id")] public long JournalId { get; set; }
    [JsonPropertyName("category")] public string Category { get; set; } = string.Empty;
    [JsonPropertyName("title")] public string Title { get; set; } = string.Empty;
    [JsonPropertyName("entry_text")] public string EntryText { get; set; } = string.Empty;
    [JsonPropertyName("created_at")] public DateTimeOffset CreatedAt { get; set; }
}

public sealed class DiscordPartyMember
{
    [JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
    [JsonPropertyName("player_id")] public Guid PlayerId { get; set; }
    [JsonPropertyName("display_name")] public string DisplayName { get; set; } = string.Empty;
    [JsonPropertyName("discord_username")] public string DiscordUsername { get; set; } = string.Empty;
    [JsonPropertyName("character_name")] public string CharacterName { get; set; } = string.Empty;
    [JsonPropertyName("species_name")] public string SpeciesName { get; set; } = string.Empty;
    [JsonPropertyName("class_name")] public string ClassName { get; set; } = string.Empty;
    [JsonPropertyName("background_name")] public string BackgroundName { get; set; } = string.Empty;
    [JsonPropertyName("alignment")] public string Alignment { get; set; } = string.Empty;
    [JsonPropertyName("level")] public int Level { get; set; }
    [JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
    [JsonPropertyName("max_hp")] public int MaxHp { get; set; }
    [JsonPropertyName("armor_class")] public int ArmorClass { get; set; }
    [JsonPropertyName("strength")] public int Strength { get; set; }
    [JsonPropertyName("dexterity")] public int Dexterity { get; set; }
    [JsonPropertyName("constitution")] public int Constitution { get; set; }
    [JsonPropertyName("intelligence")] public int Intelligence { get; set; }
    [JsonPropertyName("wisdom")] public int Wisdom { get; set; }
    [JsonPropertyName("charisma")] public int Charisma { get; set; }
    [JsonPropertyName("initiative")] public int Initiative { get; set; }
    [JsonPropertyName("passive_perception")] public int PassivePerception { get; set; }
    [JsonPropertyName("proficiency_bonus")] public int ProficiencyBonus { get; set; }
    [JsonPropertyName("speed")] public int Speed { get; set; }
    [JsonPropertyName("portrait_path")] public string? PortraitPath { get; set; }
}

public sealed record DiscordPortraitObject(byte[] Bytes, string ContentType);
