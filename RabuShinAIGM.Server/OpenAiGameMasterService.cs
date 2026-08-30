using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

public sealed class OpenAiKeyStore
{
    private readonly ConcurrentDictionary<string, string> _keys = new(StringComparer.Ordinal);

    public void Set(string discordUserId, string apiKey)
    {
        if (string.IsNullOrWhiteSpace(discordUserId)) throw new ArgumentException("Discord user ID is required.");
        if (string.IsNullOrWhiteSpace(apiKey)) throw new ArgumentException("OpenAI API key is required.");
        _keys[discordUserId] = apiKey.Trim();
    }

    public bool TryGet(string discordUserId, out string apiKey)
    {
        if (_keys.TryGetValue(discordUserId, out var value))
        {
            apiKey = value;
            return true;
        }

        apiKey = string.Empty;
        return false;
    }

    public bool Remove(string discordUserId)
        => _keys.TryRemove(discordUserId, out _);
}

public sealed class OpenAiGameMasterService
{
    private readonly HttpClient _http;
    private readonly IConfiguration _configuration;
    private readonly OpenAiKeyStore _keyStore;
    private readonly CampaignCanonService _canon;

    public OpenAiGameMasterService(HttpClient http, IConfiguration configuration, OpenAiKeyStore keyStore, CampaignCanonService canon)
    {
        _http = http;
        _configuration = configuration;
        _keyStore = keyStore;
        _canon = canon;
    }

    public bool HasApiKey(string discordUserId)
    {
        if (!string.IsNullOrWhiteSpace(_configuration["OpenAI:ApiKey"])) return true;
        return _keyStore.TryGet(discordUserId, out _);
    }

    public void SetSessionApiKey(string discordUserId, string apiKey) => _keyStore.Set(discordUserId, apiKey);
    public void ClearSessionApiKey(string discordUserId) => _keyStore.Remove(discordUserId);

    public async Task<string> AskGameMasterAsync(
        string discordUserId,
        DiscordCampaignInfo campaign,
        DiscordCharacterInfo character,
        IReadOnlyList<DiscordTimelineMessage> history,
        string playerMessage)
    {
        string apiKey;
        var configuredKey = _configuration["OpenAI:ApiKey"];

        if (!string.IsNullOrWhiteSpace(configuredKey))
        {
            apiKey = configuredKey;
        }
        else if (_keyStore.TryGet(discordUserId, out var sessionKey))
        {
            apiKey = sessionKey;
        }
        else
        {
            throw new OpenAiConfigurationException("No OpenAI API key is configured. Open Settings in RabuShin and enter an API key, or configure OpenAI:ApiKey on the server.");
        }

        var model = _configuration["OpenAI:Model"];
        if (string.IsNullOrWhiteSpace(model)) model = "gpt-5.4-mini";

        var recentHistory = history.TakeLast(20)
            .Select(m => $"{(m.RoleName.Equals("assistant", StringComparison.OrdinalIgnoreCase) ? "GAME MASTER" : m.SenderName)}: {m.MessageText}")
            .ToList();

        var instructions = """
You are the AI Game Master for The Quests of Rabu Shin: Tales of the Krasis, a D&D 5e 2024 fantasy campaign.
Run the world as a fair, descriptive Game Master. Never decide a player character's choices for them. Ask for ability checks, saving throws, attack rolls, or damage rolls when appropriate and state the exact die/modifier or DC when useful. Keep continuity with the supplied campaign history. Track consequences narratively. Do not invent that a roll succeeded before the player supplies the roll when a roll is required. Keep responses focused enough for a live multiplayer game.
""";

        var inputBuilder = new StringBuilder();
        inputBuilder.AppendLine($"CAMPAIGN: {campaign.CampaignName}");
        inputBuilder.AppendLine($"CHAPTER: {campaign.CurrentChapter}; CURRENT LOCATION: {campaign.CurrentLocation}");
        var canon = _canon.GetCanon(campaign.CurrentChapter, campaign.CurrentLocation);
        if (!string.IsNullOrWhiteSpace(canon))
        {
            inputBuilder.AppendLine();
            inputBuilder.AppendLine("AUTHORITATIVE RABUSHIN CAMPAIGN CANON:");
            inputBuilder.AppendLine(canon);
        }
        inputBuilder.AppendLine($"PLAYER CHARACTER: {character.CharacterName}, Level {character.Level} {character.SpeciesName} {character.ClassName}");
        inputBuilder.AppendLine($"HP {character.CurrentHp}/{character.MaxHp}; AC {character.ArmorClass}; Location/campaign state is managed by RabuShin.");
        if (recentHistory.Count > 0)
        {
            inputBuilder.AppendLine();
            inputBuilder.AppendLine("RECENT GAME HISTORY:");
            foreach (var line in recentHistory) inputBuilder.AppendLine(line);
        }
        inputBuilder.AppendLine();
        inputBuilder.AppendLine("PLAYER ACTION:");
        inputBuilder.AppendLine(playerMessage.Trim());

        var body = new
        {
            model,
            instructions,
            input = inputBuilder.ToString(),
            max_output_tokens = 1200,
            safety_identifier = BuildSafetyIdentifier(discordUserId)
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/responses");
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", apiKey);
        request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

        using var response = await _http.SendAsync(request);
        var raw = await response.Content.ReadAsStringAsync();

        if (!response.IsSuccessStatusCode)
        {
            var status = (int)response.StatusCode;
            if (status == 401)
                throw new OpenAiConfigurationException("OpenAI rejected the API key. Check the key in RabuShin Settings.");
            if (status == 429)
                throw new OpenAiUsageException("OpenAI usage is unavailable right now (quota, credits, or rate limit). The campaign is still open; add credits/change the key and try again.");

            var lower = raw.ToLowerInvariant();
            if (lower.Contains("insufficient_quota") || lower.Contains("billing") || lower.Contains("credit"))
                throw new OpenAiUsageException("OpenAI credits/quota are unavailable. RabuShin will remain open instead of crashing. Update billing or use another API key and try again.");

            throw new InvalidOperationException($"OpenAI request failed (HTTP {status}). {ExtractApiError(raw)}");
        }

        var text = ExtractOutputText(raw);
        if (string.IsNullOrWhiteSpace(text))
            throw new InvalidOperationException("OpenAI returned no Game Master text.");
        return text.Trim();
    }

    private static string BuildSafetyIdentifier(string discordUserId)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes("rabushin:" + discordUserId));
        return "rabu_" + Convert.ToHexString(bytes).ToLowerInvariant()[..24];
    }

    private static string ExtractOutputText(string json)
    {
        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("output", out var output) || output.ValueKind != JsonValueKind.Array)
            return string.Empty;

        var sb = new StringBuilder();
        foreach (var item in output.EnumerateArray())
        {
            if (!item.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) continue;
            foreach (var part in content.EnumerateArray())
            {
                if (part.TryGetProperty("type", out var type) && type.GetString() == "output_text" &&
                    part.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String)
                {
                    if (sb.Length > 0) sb.AppendLine();
                    sb.Append(text.GetString());
                }
            }
        }
        return sb.ToString();
    }

    private static string ExtractApiError(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("error", out var error))
            {
                if (error.ValueKind == JsonValueKind.Object && error.TryGetProperty("message", out var msg))
                    return msg.GetString() ?? "Unknown OpenAI error.";
                return error.ToString();
            }
        }
        catch { }
        return json.Length > 500 ? json[..500] : json;
    }
}

public sealed class OpenAiUsageException : Exception
{
    public OpenAiUsageException(string message) : base(message) { }
}

public sealed class OpenAiConfigurationException : Exception
{
    public OpenAiConfigurationException(string message) : base(message) { }
}
