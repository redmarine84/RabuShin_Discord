using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Threading;

// RULES BUILD 6.17.1 - DISCORD OAUTH RATE LIMIT / DUPLICATE EXCHANGE GUARD
public sealed class DiscordOAuthService
{
    private const int MaxTokenAttempts = 3;
    private static readonly TimeSpan RetrySafetyBuffer = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan MaxInlineRetryDelay = TimeSpan.FromSeconds(45);
    private static readonly TimeSpan SuccessfulExchangeCacheTime = TimeSpan.FromSeconds(30);

    // AddHttpClient<T>() creates typed-client service instances as needed. These
    // guards are static so separate /api/token requests still coordinate with
    // one another across DiscordOAuthService instances.
    private static readonly ConcurrentDictionary<string, Lazy<Task<string>>> ExchangeTasks =
        new(StringComparer.Ordinal);
    private static readonly SemaphoreSlim TokenEndpointGate = new(1, 1);

    private readonly HttpClient _http;
    private readonly ILogger<DiscordOAuthService> _logger;
    private readonly string _clientId;
    private readonly string _clientSecret;

    public DiscordOAuthService(
        HttpClient http,
        IConfiguration configuration,
        ILogger<DiscordOAuthService> logger)
    {
        _http = http;
        _logger = logger;
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

        var normalizedCode = code.Trim();

        // Discord authorization codes are one-use values. If the Activity startup
        // path fires twice, both callers share one exchange instead of POSTing the
        // same authorization code to Discord twice.
        var pending = ExchangeTasks.GetOrAdd(
            normalizedCode,
            value => new Lazy<Task<string>>(
                () => ExchangeCodeCoreAsync(value),
                LazyThreadSafetyMode.ExecutionAndPublication));

        try
        {
            var token = await pending.Value.ConfigureAwait(false);

            // Keep a successful result briefly so a nearly simultaneous duplicate
            // /api/token request receives the already-issued token rather than
            // attempting to consume the same one-use code again.
            _ = RemoveSuccessfulExchangeLaterAsync(normalizedCode, pending);
            return token;
        }
        catch
        {
            RemoveExchangeIfSame(normalizedCode, pending);
            throw;
        }
    }

    private async Task<string> ExchangeCodeCoreAsync(string code)
    {
        // Discord rate limits the token endpoint itself, not just individual auth
        // codes. Serialize token POSTs so another player/client cannot immediately
        // hit the endpoint while a prior 429 is still cooling down.
        await TokenEndpointGate.WaitAsync().ConfigureAwait(false);

        try
        {
            for (var attempt = 1; attempt <= MaxTokenAttempts; attempt++)
            {
                using var content = CreateTokenRequestContent(code);
                using var response = await _http.PostAsync(
                    "https://discord.com/api/oauth2/token",
                    content).ConfigureAwait(false);

                var responseText = await response.Content.ReadAsStringAsync().ConfigureAwait(false);

                // IMPORTANT: Handle 429 before treating the body as a normal OAuth
                // response. Discord can return a rate-limit payload that does not
                // contain OAuth error fields and may not always be parseable JSON.
                if (response.StatusCode == HttpStatusCode.TooManyRequests)
                {
                    var retryAfterSeconds = ResolveRetryAfterSeconds(response, responseText, attempt);

                    _logger.LogWarning(
                        "Discord OAuth token exchange was rate limited (HTTP 429). Attempt {Attempt}/{MaxAttempts}; RetryAfter={RetryAfterSeconds:0.###}s.",
                        attempt,
                        MaxTokenAttempts,
                        retryAfterSeconds);

                    // Very long waits are returned to the Activity instead of keeping
                    // a Render request open indefinitely. The client will show the
                    // exact reason instead of the old invalid-response message.
                    if (attempt >= MaxTokenAttempts || retryAfterSeconds > MaxInlineRetryDelay.TotalSeconds)
                    {
                        throw new DiscordOAuthException(
                            429,
                            "discord_rate_limited",
                            $"Discord is temporarily rate limiting login requests. Try again in about {Math.Max(1, Math.Ceiling(retryAfterSeconds))} seconds.",
                            retryAfterSeconds);
                    }

                    // Never retry before Discord's requested delay has elapsed. The
                    // small buffer keeps the retry off the exact reset boundary.
                    await Task.Delay(
                        TimeSpan.FromSeconds(retryAfterSeconds) + RetrySafetyBuffer).ConfigureAwait(false);
                    continue;
                }

                if (!response.IsSuccessStatusCode)
                {
                    var error = TryGetJsonString(responseText, "error") ?? "discord_oauth_error";
                    var description = TryGetJsonString(responseText, "error_description")
                        ?? $"Discord rejected the OAuth token exchange (HTTP {(int)response.StatusCode}).";
                    throw new DiscordOAuthException((int)response.StatusCode, error, description);
                }

                var accessToken = TryGetJsonString(responseText, "access_token");
                if (string.IsNullOrWhiteSpace(accessToken))
                {
                    // Only a successful 2xx response with malformed JSON is an
                    // "invalid OAuth response". A 429 was already handled above.
                    if (!IsValidJson(responseText))
                    {
                        throw new DiscordOAuthException(
                            502,
                            "invalid_discord_response",
                            "Discord returned an invalid OAuth response.");
                    }

                    throw new DiscordOAuthException(
                        502,
                        "missing_access_token",
                        "Discord returned no access token.");
                }

                return accessToken;
            }

            throw new DiscordOAuthException(
                429,
                "discord_rate_limited",
                "Discord is temporarily rate limiting login requests. Try again shortly.");
        }
        finally
        {
            TokenEndpointGate.Release();
        }
    }

    private FormUrlEncodedContent CreateTokenRequestContent(string code)
        => new(new Dictionary<string, string>
        {
            ["client_id"] = _clientId,
            ["client_secret"] = _clientSecret,
            ["grant_type"] = "authorization_code",
            ["code"] = code
        });

    private static double ResolveRetryAfterSeconds(
        HttpResponseMessage response,
        string responseText,
        int attempt)
    {
        if (response.Headers.RetryAfter?.Delta is TimeSpan delta && delta.TotalSeconds > 0)
            return delta.TotalSeconds;

        if (response.Headers.RetryAfter?.Date is DateTimeOffset retryDate)
        {
            var remaining = retryDate - DateTimeOffset.UtcNow;
            if (remaining.TotalSeconds > 0)
                return remaining.TotalSeconds;
        }

        var bodyValue = TryGetJsonNumber(responseText, "retry_after");
        if (bodyValue is > 0)
            return bodyValue.Value;

        if (TryGetPositiveSecondsHeader(response, "Retry-After", out var retryAfter))
            return retryAfter;

        if (TryGetPositiveSecondsHeader(response, "X-RateLimit-Reset-After", out var resetAfter))
            return resetAfter;

        // Fallback only when Discord supplied no usable retry delay.
        return Math.Min(8, Math.Pow(2, Math.Max(0, attempt - 1)));
    }

    private static bool TryGetPositiveSecondsHeader(
        HttpResponseMessage response,
        string headerName,
        out double seconds)
    {
        seconds = 0;
        if (!response.Headers.TryGetValues(headerName, out var values))
            return false;

        var raw = values.FirstOrDefault();
        return double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out seconds)
               && seconds > 0;
    }

    private static string? TryGetJsonString(string json, string propertyName)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            return root.TryGetProperty(propertyName, out var value) && value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static double? TryGetJsonNumber(string json, string propertyName)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (!root.TryGetProperty(propertyName, out var value))
                return null;

            if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var numeric))
                return numeric;

            if (value.ValueKind == JsonValueKind.String &&
                double.TryParse(value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out numeric))
                return numeric;

            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool IsValidJson(string json)
    {
        try
        {
            using var _ = JsonDocument.Parse(json);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static async Task RemoveSuccessfulExchangeLaterAsync(
        string code,
        Lazy<Task<string>> pending)
    {
        await Task.Delay(SuccessfulExchangeCacheTime).ConfigureAwait(false);
        RemoveExchangeIfSame(code, pending);
    }

    private static void RemoveExchangeIfSame(string code, Lazy<Task<string>> pending)
    {
        if (ExchangeTasks.TryGetValue(code, out var current) && ReferenceEquals(current, pending))
            ExchangeTasks.TryRemove(code, out _);
    }

    private static string? FirstNonBlank(params string?[] values)
        => values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
}

public sealed class DiscordOAuthException : Exception
{
    public int StatusCode { get; }
    public string ErrorCode { get; }
    public double? RetryAfterSeconds { get; }

    public DiscordOAuthException(
        int statusCode,
        string errorCode,
        string message,
        double? retryAfterSeconds = null)
        : base(message)
    {
        StatusCode = statusCode;
        ErrorCode = errorCode;
        RetryAfterSeconds = retryAfterSeconds;
    }
}
