using System.Net;
using System.Text.Json;

public sealed class DiscordOAuthService
{
    private readonly HttpClient _http;
    private readonly string _clientId;
    private readonly string _clientSecret;

    public DiscordOAuthService(HttpClient http, IConfiguration configuration)
    {
        _http = http;
        _clientId = FirstNonBlank(
            configuration["Discord:ClientId"],
            configuration["VITE_DISCORD_CLIENT_ID"])
            ?? throw new InvalidOperationException(
                "Discord Client ID is not configured. Set Discord__ClientId or VITE_DISCORD_CLIENT_ID.");

        _clientSecret = FirstNonBlank(
            configuration["Discord:ClientSecret"],
            configuration["DISCORD_CLIENT_SECRET"])
            ?? throw new InvalidOperationException(
                "Discord Client Secret is not configured. Set Discord__ClientSecret or DISCORD_CLIENT_SECRET.");
    }

    public async Task<string> ExchangeCodeAsync(string code)
    {
        if (string.IsNullOrWhiteSpace(code))
            throw new DiscordOAuthException(400, "invalid_request", "Discord authorization code is required.");

        using var content = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["client_id"] = _clientId,
            ["client_secret"] = _clientSecret,
            ["grant_type"] = "authorization_code",
            ["code"] = code.Trim()
        });

        using var response = await _http.PostAsync("https://discord.com/api/oauth2/token", content);
        var responseText = await response.Content.ReadAsStringAsync();

        JsonDocument? document = null;
        try
        {
            document = JsonDocument.Parse(responseText);
            var root = document.RootElement;

            if (!response.IsSuccessStatusCode)
            {
                var error = TryGetString(root, "error") ?? "discord_oauth_error";
                var description = TryGetString(root, "error_description")
                    ?? $"Discord rejected the OAuth token exchange (HTTP {(int)response.StatusCode}).";
                throw new DiscordOAuthException((int)response.StatusCode, error, description);
            }

            var accessToken = TryGetString(root, "access_token");
            if (string.IsNullOrWhiteSpace(accessToken))
                throw new DiscordOAuthException(502, "missing_access_token", "Discord returned no access token.");

            return accessToken;
        }
        catch (JsonException)
        {
            throw new DiscordOAuthException(
                response.IsSuccessStatusCode ? 502 : (int)response.StatusCode,
                "invalid_discord_response",
                "Discord returned an invalid OAuth response.");
        }
        finally
        {
            document?.Dispose();
        }
    }

    private static string? TryGetString(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
    }

    private static string? FirstNonBlank(params string?[] values)
        => values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
}

public sealed class DiscordOAuthException : Exception
{
    public int StatusCode { get; }
    public string ErrorCode { get; }

    public DiscordOAuthException(int statusCode, string errorCode, string message)
        : base(message)
    {
        StatusCode = statusCode;
        ErrorCode = errorCode;
    }
}
