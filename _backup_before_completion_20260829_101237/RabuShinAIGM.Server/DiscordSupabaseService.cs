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


    private static readonly JsonSerializerOptions JsonOptions =
        new()
        {
            PropertyNameCaseInsensitive = true
        };


    public DiscordSupabaseService(
        HttpClient http,
        IConfiguration configuration
    )
    {
        _http = http;


        _supabaseUrl =
            configuration["Supabase:Url"]
            ??
            throw new InvalidOperationException(
                "Supabase:Url is not configured."
            );


        _supabaseSecretKey =
            configuration["Supabase:SecretKey"]
            ??
            throw new InvalidOperationException(
                "Supabase:SecretKey is not configured."
            );
    }


    // ============================================================
    // VERIFY DISCORD USER
    // ============================================================

    public async Task<DiscordUserInfo>
        VerifyDiscordUserAsync(
            string? authorizationHeader
        )
    {
        if (
            string.IsNullOrWhiteSpace(
                authorizationHeader
            )
        )
        {
            throw new UnauthorizedAccessException(
                "Discord authorization token is missing."
            );
        }


        const string prefix =
            "Bearer ";


        if (
            !authorizationHeader.StartsWith(
                prefix,
                StringComparison.OrdinalIgnoreCase
            )
        )
        {
            throw new UnauthorizedAccessException(
                "Invalid Discord authorization header."
            );
        }


        var accessToken =
            authorizationHeader
                .Substring(prefix.Length)
                .Trim();


        if (
            string.IsNullOrWhiteSpace(
                accessToken
            )
        )
        {
            throw new UnauthorizedAccessException(
                "Discord access token is missing."
            );
        }


        using var request =
            new HttpRequestMessage(
                HttpMethod.Get,
                "https://discord.com/api/v10/users/@me"
            );


        request.Headers.Authorization =
            new AuthenticationHeaderValue(
                "Bearer",
                accessToken
            );


        using var response =
            await _http.SendAsync(
                request
            );


        if (!response.IsSuccessStatusCode)
        {
            throw new UnauthorizedAccessException(
                "Discord could not verify this player."
            );
        }


        var user =
            await response.Content
                .ReadFromJsonAsync<DiscordUserInfo>(
                    JsonOptions
                );


        if (
            user is null ||
            string.IsNullOrWhiteSpace(
                user.Id
            )
        )
        {
            throw new UnauthorizedAccessException(
                "Discord returned an invalid player."
            );
        }


        return user;
    }


    // ============================================================
    // GET / CREATE PLAYER
    // ============================================================

    public async Task<Guid>
        GetOrCreatePlayerAsync(
            DiscordUserInfo user
        )
    {
        var body =
            new
            {
                p_discord_user_id =
                    user.Id,

                p_discord_username =
                    user.Username,

                p_display_name =
                    user.GlobalName
                    ??
                    user.Username
            };


        using var response =
            await CallRpcAsync(
                "discord_upsert_player",
                body
            );


        var json =
            await response.Content
                .ReadAsStringAsync();


        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                "Unable to register Discord player: "
                + json
            );
        }


        var idText =
            JsonSerializer.Deserialize<string>(
                json,
                JsonOptions
            );


        if (
            !Guid.TryParse(
                idText,
                out var playerId
            )
        )
        {
            throw new InvalidOperationException(
                "Supabase returned an invalid player ID."
            );
        }


        return playerId;
    }


    // ============================================================
    // GET CAMPAIGNS
    // ============================================================

    public async Task<List<DiscordCampaignInfo>>
        GetCampaignsAsync(
            Guid playerId
        )
    {
        var body =
            new
            {
                p_player_id =
                    playerId
            };


        using var response =
            await CallRpcAsync(
                "discord_get_my_campaigns",
                body
            );


        var json =
            await response.Content
                .ReadAsStringAsync();


        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                "Unable to load campaigns: "
                + json
            );
        }


        return
            JsonSerializer.Deserialize<
                List<DiscordCampaignInfo>
            >(
                json,
                JsonOptions
            )
            ??
            new List<DiscordCampaignInfo>();
    }


    // ============================================================
    // CREATE CAMPAIGN
    // ============================================================

    public async Task<Guid>
        CreateCampaignAsync(
            Guid playerId,
            string campaignName
        )
    {
        if (
            string.IsNullOrWhiteSpace(
                campaignName
            )
        )
        {
            throw new ArgumentException(
                "Campaign name is required."
            );
        }


        var body =
            new
            {
                p_player_id =
                    playerId,

                p_campaign_name =
                    campaignName.Trim()
            };


        using var response =
            await CallRpcAsync(
                "discord_create_campaign",
                body
            );


        var json =
            await response.Content
                .ReadAsStringAsync();


        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                "Unable to create campaign: "
                + json
            );
        }


        var idText =
            JsonSerializer.Deserialize<string>(
                json,
                JsonOptions
            );


        if (
            !Guid.TryParse(
                idText,
                out var campaignId
            )
        )
        {
            throw new InvalidOperationException(
                "Supabase returned an invalid campaign ID."
            );
        }


        return campaignId;
    }


    // ============================================================
    // JOIN CAMPAIGN
    // ============================================================

    public async Task<Guid>
        JoinCampaignAsync(
            Guid playerId,
            string joinCode
        )
    {
        if (
            string.IsNullOrWhiteSpace(
                joinCode
            )
        )
        {
            throw new ArgumentException(
                "Campaign code is required."
            );
        }


        var body =
            new
            {
                p_player_id =
                    playerId,

                p_join_code =
                    joinCode.Trim()
            };


        using var response =
            await CallRpcAsync(
                "discord_join_campaign",
                body
            );


        var json =
            await response.Content
                .ReadAsStringAsync();


        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                "Unable to join campaign: "
                + json
            );
        }


        var idText =
            JsonSerializer.Deserialize<string>(
                json,
                JsonOptions
            );


        if (
            !Guid.TryParse(
                idText,
                out var campaignId
            )
        )
        {
            throw new InvalidOperationException(
                "Supabase returned an invalid campaign ID."
            );
        }


        return campaignId;
    }

    public async Task<DiscordCharacterInfo?>
    GetCharacterAsync(
        Guid playerId,
        Guid campaignId
    )
    {
        var body =
            new
            {
                p_player_id =
                    playerId,

                p_campaign_id =
                    campaignId
            };


        using var response =
            await CallRpcAsync(
                "discord_get_character",
                body
            );


        var json =
            await response.Content
                .ReadAsStringAsync();


        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                "Unable to load character: "
                + json
            );
        }


        var characters =
            JsonSerializer.Deserialize<
                List<DiscordCharacterInfo>
            >(
                json,
                JsonOptions
            );


        return characters?
            .FirstOrDefault();
    }

    public async Task<Guid>
    CreateCharacterAsync(
        Guid playerId,
        Guid campaignId,
        PlayerCharacter character
    )
    {
        var characterData =
            new
            {
                character_name =
                    character.CharacterName,

                species_name =
                    character.SpeciesName,

                class_name =
                    character.ClassName,

                background_name =
                    character.BackgroundName,

                level =
                    character.Level,

                experience =
                    character.ExperiencePoints,

                current_hp =
                    character.CurrentHitPoints,

                max_hp =
                    character.MaxHitPoints,

                armor_class =
                    character.ArmorClass,

                strength =
                    character.Strength,

                dexterity =
                    character.Dexterity,

                constitution =
                    character.Constitution,

                intelligence =
                    character.Intelligence,

                wisdom =
                    character.Wisdom,

                charisma =
                    character.Charisma,

                initiative =
                    character.Initiative,

                passive_perception =
                    character.PassivePerception,

                proficiency_bonus =
                    character.ProficiencyBonus,

                speed =
                    character.Speed,

                size_name =
                    character.SizeName,

                gold =
                    character.Gold,


                // Preserve everything generated by
                // your existing VB.NET PlayerCharacter.

                snapshot =
                    character
            };


        var body =
            new
            {
                p_player_id =
                    playerId,

                p_campaign_id =
                    campaignId,

                p_character_data =
                    characterData
            };


        using var response =
            await CallRpcAsync(
                "discord_create_character",
                body
            );


        var json =
            await response.Content
                .ReadAsStringAsync();


        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                "Unable to create character: "
                + json
            );
        }


        var idText =
            JsonSerializer.Deserialize<string>(
                json,
                JsonOptions
            );


        if (
            !Guid.TryParse(
                idText,
                out var characterId
            )
        )
        {
            throw new InvalidOperationException(
                "Supabase returned an invalid character ID."
            );
        }


        return characterId;
    }

    public async Task<DiscordCharacterSetupState?>
    GetCharacterSetupStateAsync(
        Guid playerId,
        Guid campaignId
    )
    {
        var body =
            new
            {
                p_player_id =
                    playerId,

                p_campaign_id =
                    campaignId
            };


        using var response =
            await CallRpcAsync(
                "discord_get_character_setup_state",
                body
            );


        var json =
            await response.Content
                .ReadAsStringAsync();


        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                "Unable to load character setup state: "
                + json
            );
        }


        var states =
            JsonSerializer.Deserialize<
                List<DiscordCharacterSetupState>
            >(
                json,
                JsonOptions
            );


        return states?
            .FirstOrDefault();
    }

    public async Task
    SaveStartingEquipmentAsync(
        Guid playerId,
        Guid campaignId,
        decimal gold,
        List<DiscordStartingInventoryItem> items
    )
    {
        var body =
            new
            {
                p_player_id =
                    playerId,

                p_campaign_id =
                    campaignId,

                p_gold =
                    gold,

                p_items =
                    items
            };


        using var response =
            await CallRpcAsync(
                "discord_set_starting_equipment",
                body
            );


        var json =
            await response.Content
                .ReadAsStringAsync();


        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                "Unable to save starting equipment: "
                + json
            );
        }
    }

    // ============================================================
    // SUPABASE RPC
    // ============================================================

    private async Task<HttpResponseMessage>
        CallRpcAsync(
            string functionName,
            object body
        )
    {
        var json =
            JsonSerializer.Serialize(
                body
            );


        var url =
            $"{_supabaseUrl.TrimEnd('/')}/rest/v1/rpc/{functionName}";


        var request =
            new HttpRequestMessage(
                HttpMethod.Post,
                url
            );


        // New Supabase sb_secret keys belong in the
        // apikey header, not in browser code.

        request.Headers.TryAddWithoutValidation(
            "apikey",
            _supabaseSecretKey
        );


        request.Content =
            new StringContent(
                json,
                Encoding.UTF8,
                "application/json"
            );


        return await _http.SendAsync(
            request
        );
    }  

}





// ============================================================
// DISCORD USER
// ============================================================

public sealed class DiscordUserInfo
{
    [JsonPropertyName("id")]
    public string Id { get; set; }
        = string.Empty;


    [JsonPropertyName("username")]
    public string Username { get; set; }
        = string.Empty;


    [JsonPropertyName("global_name")]
    public string? GlobalName { get; set; }
}



// ============================================================
// CAMPAIGN
// ============================================================

public sealed class DiscordCampaignInfo
{
    [JsonPropertyName("campaign_id")]
    public Guid CampaignId { get; set; }


    [JsonPropertyName("campaign_name")]
    public string CampaignName { get; set; }
        = string.Empty;


    [JsonPropertyName("join_code")]
    public string JoinCode { get; set; }
        = string.Empty;


    [JsonPropertyName("current_chapter")]
    public int CurrentChapter { get; set; }


    [JsonPropertyName("current_location")]
    public string CurrentLocation { get; set; }
        = string.Empty;


    [JsonPropertyName("is_owner")]
    public bool IsOwner { get; set; }


    [JsonPropertyName("member_count")]
    public long MemberCount { get; set; }
}

public sealed class DiscordCharacterInfo
{
    [JsonPropertyName("character_id")]
    public Guid CharacterId { get; set; }


    [JsonPropertyName("campaign_id")]
    public Guid CampaignId { get; set; }


    [JsonPropertyName("character_name")]
    public string CharacterName { get; set; }
        = string.Empty;


    [JsonPropertyName("species_name")]
    public string SpeciesName { get; set; }
        = string.Empty;


    [JsonPropertyName("class_name")]
    public string ClassName { get; set; }
        = string.Empty;


    [JsonPropertyName("background_name")]
    public string BackgroundName { get; set; }
        = string.Empty;


    [JsonPropertyName("level")]
    public int Level { get; set; }


    [JsonPropertyName("experience")]
    public int Experience { get; set; }


    [JsonPropertyName("current_hp")]
    public int CurrentHp { get; set; }


    [JsonPropertyName("max_hp")]
    public int MaxHp { get; set; }


    [JsonPropertyName("armor_class")]
    public int ArmorClass { get; set; }


    [JsonPropertyName("strength")]
    public int Strength { get; set; }


    [JsonPropertyName("dexterity")]
    public int Dexterity { get; set; }


    [JsonPropertyName("constitution")]
    public int Constitution { get; set; }


    [JsonPropertyName("intelligence")]
    public int Intelligence { get; set; }


    [JsonPropertyName("wisdom")]
    public int Wisdom { get; set; }


    [JsonPropertyName("charisma")]
    public int Charisma { get; set; }


    [JsonPropertyName("initiative")]
    public int Initiative { get; set; }


    [JsonPropertyName("passive_perception")]
    public int PassivePerception { get; set; }


    [JsonPropertyName("proficiency_bonus")]
    public int ProficiencyBonus { get; set; }


    [JsonPropertyName("speed")]
    public int Speed { get; set; }


    [JsonPropertyName("size_name")]
    public string SizeName { get; set; }
        = string.Empty;


    [JsonPropertyName("gold")]
    public decimal Gold { get; set; }


    [JsonPropertyName("character_data")]
    public JsonElement CharacterData { get; set; }
}

public sealed class DiscordCharacterSetupState
{
    [JsonPropertyName("character_id")]
    public Guid CharacterId { get; set; }


    [JsonPropertyName("equipment_complete")]
    public bool EquipmentComplete { get; set; }
}

public sealed class DiscordStartingInventoryItem
{
    [JsonPropertyName("item_name")]
    public string ItemName { get; set; }
        = string.Empty;


    [JsonPropertyName("quantity")]
    public int Quantity { get; set; }
        = 1;


    [JsonPropertyName("equipped")]
    public bool Equipped { get; set; }


    [JsonPropertyName("source_name")]
    public string SourceName { get; set; }
        = string.Empty;


    [JsonPropertyName("notes")]
    public string Notes { get; set; }
        = string.Empty;
}