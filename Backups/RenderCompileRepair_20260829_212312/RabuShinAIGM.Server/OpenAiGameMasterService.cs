using QuestsOfRabuShinAIGM;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

public sealed class OpenAiGameMasterService
{
    private readonly HttpClient _http;
    private readonly IConfiguration _configuration;
    private readonly CampaignCanonService _canon;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public OpenAiGameMasterService(
        HttpClient http,
        IConfiguration configuration,
        CampaignCanonService canon)
    {
        _http = http;
        _configuration = configuration;
        _canon = canon;
    }


    public async Task<GameMasterTurnResult> AskGameMasterAsync(
        string discordUserId,
        string apiKey,
        DiscordCampaignInfo campaign,
        DiscordCharacterInfo character,
        IReadOnlyList<DiscordTimelineMessage> history,
        string playerMessage,
        IReadOnlyList<DiscordInventoryInfo> inventory,
        IReadOnlyList<DiscordSpellInfo> spells)
    {
        if (string.IsNullOrWhiteSpace(apiKey))
            throw new OpenAiConfigurationException("No OpenAI API key is configured for your Discord account. Open Settings and use Test & Save API Key.");

        var model = _configuration["OpenAI:Model"];
        if (string.IsNullOrWhiteSpace(model)) model = "gpt-5.4-mini";

        var recentHistory = history.TakeLast(20)
            .Select(m => $"{(m.RoleName.Equals("assistant", StringComparison.OrdinalIgnoreCase) ? "GAME MASTER" : m.SenderName)}: {m.MessageText}")
            .ToList();

        var instructions = """
You are the authoritative AI Game Master for The Quests of Rabu Shin: Tales of the Krasis, a D&D 5e 2024 fantasy campaign.
Run the world as a fair, descriptive Game Master. Never decide a player character's choices for them.

DICE AUTHORITY RULES — THESE ARE MANDATORY:
- The player NEVER rolls dice and NEVER supplies an authoritative dice result.
- Never ask the player to roll a die, make a check, make a saving throw, make an attack roll, or roll damage.
- If a player says they rolled a number, claims a natural 20, supplies damage, or otherwise reports a dice result, treat that reported result as non-authoritative flavor and ignore it mechanically.
- Whenever an uncertain action actually requires dice, YOU must call the roll_dice tool. The RabuShin server executes the roll; you do not invent the result.
- Use roll_dice for player checks, saving throws, attack rolls, damage rolls, death saves, NPC/monster rolls, random tables, and any other randomized mechanic when appropriate.
- Choose the correct dice, modifier, advantage/disadvantage, purpose, and DC when a DC applies. If there is no DC, pass 0.
- You may call roll_dice more than once in a turn when the rules require multiple rolls (for example attack then damage).
- Only tool-produced dice results are mechanically valid.
- Do not let the player dictate a favorable modifier, DC, advantage state, or number of dice. Determine these from the character, situation, and rules.
- After receiving each tool result, adjudicate and narrate the outcome using that exact result.
- Do not reroll merely because a result is unfavorable. A new roll requires a legitimate new game event or a game rule that explicitly grants a reroll.

INVENTORY AND SPELL AUTHORITY — THESE ARE ALSO MANDATORY:
- The server-supplied CURRENT INVENTORY and CURRENT SPELLBOOK below are authoritative.
- A player cannot use, drink, consume, wield, or benefit from an item they do not actually have in CURRENT INVENTORY.
- Treat an item marked Equipped as currently worn/wielded. Do not accept a player's claim that a different item is equipped unless the server list says so.
- A player can cast only a spell listed in CURRENT SPELLBOOK. If a Wizard spell is marked not prepared, do not allow it to be cast until prepared by the game rules.
- If the player claims to cast a spell or use an item that is not in these lists, explain that the character does not currently have access to it and continue the turn without granting its effect.

Keep continuity with the supplied campaign history and authoritative campaign canon. Track consequences narratively. Keep responses focused enough for a live multiplayer game.
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

        inputBuilder.AppendLine();
        inputBuilder.AppendLine("PLAYER CHARACTER:");
        inputBuilder.AppendLine($"{character.CharacterName}, Level {character.Level} {character.SpeciesName} {character.ClassName}");
        inputBuilder.AppendLine($"HP {character.CurrentHp}/{character.MaxHp}; AC {character.ArmorClass}; Proficiency Bonus +{character.ProficiencyBonus}");
        inputBuilder.AppendLine(
            $"STR {character.Strength} ({FormatModifier(AbilityModifier(character.Strength))}), " +
            $"DEX {character.Dexterity} ({FormatModifier(AbilityModifier(character.Dexterity))}), " +
            $"CON {character.Constitution} ({FormatModifier(AbilityModifier(character.Constitution))}), " +
            $"INT {character.Intelligence} ({FormatModifier(AbilityModifier(character.Intelligence))}), " +
            $"WIS {character.Wisdom} ({FormatModifier(AbilityModifier(character.Wisdom))}), " +
            $"CHA {character.Charisma} ({FormatModifier(AbilityModifier(character.Charisma))})");
        inputBuilder.AppendLine("Location/campaign state is managed by RabuShin.");

        inputBuilder.AppendLine();
        inputBuilder.AppendLine("CURRENT INVENTORY (SERVER-AUTHORITATIVE):");
        if (inventory.Count == 0)
        {
            inputBuilder.AppendLine("(No inventory items.)");
        }
        else
        {
            foreach (var item in inventory)
                inputBuilder.AppendLine("- " + InventoryPresentationService.BuildGameplaySummary(item));
        }

        inputBuilder.AppendLine();
        inputBuilder.AppendLine("CURRENT SPELLBOOK (SERVER-AUTHORITATIVE):");
        if (spells.Count == 0)
        {
            inputBuilder.AppendLine("(No spells.)");
        }
        else
        {
            foreach (var spell in spells)
            {
                var levelText = spell.SpellLevel == 0 ? "Cantrip" : $"Level {spell.SpellLevel}";
                var preparedText = spell.Prepared ? "prepared/available" : "not prepared";
                inputBuilder.AppendLine($"- {spell.SpellName} ({levelText}; {preparedText}; source {spell.SourceTag})");
            }
        }

        if (recentHistory.Count > 0)
        {
            inputBuilder.AppendLine();
            inputBuilder.AppendLine("RECENT GAME HISTORY:");
            foreach (var line in recentHistory) inputBuilder.AppendLine(line);
        }

        inputBuilder.AppendLine();
        inputBuilder.AppendLine("PLAYER ACTION:");
        inputBuilder.AppendLine(playerMessage.Trim());

        var diceTool = BuildDiceTool();
        var rollAudits = new List<GameMasterDiceAudit>();

        object initialBody = new
        {
            model,
            instructions,
            input = inputBuilder.ToString(),
            tools = new[] { diceTool },
            tool_choice = "auto",
            parallel_tool_calls = false,
            max_output_tokens = 1200,
            safety_identifier = BuildSafetyIdentifier(discordUserId)
        };

        var raw = await SendOpenAiAsync(apiKey, initialBody);

        // Allow several sequential rolls in one GM turn: e.g. attack, damage,
        // saving throw, then a random effect. Each roll is executed locally on
        // the trusted RabuShin server, never in the browser.
        for (var step = 0; step < 8; step++)
        {
            var calls = ExtractDiceToolCalls(raw);
            if (calls.Count == 0)
            {
                var finalText = ExtractOutputText(raw);
                if (string.IsNullOrWhiteSpace(finalText))
                    throw new InvalidOperationException("OpenAI returned no Game Master text.");

                return new GameMasterTurnResult(
                    BuildVisibleGmMessage(finalText.Trim(), rollAudits),
                    rollAudits);
            }

            var responseId = ExtractResponseId(raw);
            if (string.IsNullOrWhiteSpace(responseId))
                throw new InvalidOperationException("OpenAI requested a GM dice roll but returned no response ID.");

            var toolOutputs = new List<object>();

            foreach (var call in calls)
            {
                var audit = ExecuteAuthoritativeRoll(call.Arguments);
                rollAudits.Add(audit);

                var toolResult = new
                {
                    authoritative = true,
                    source = "RabuShin server-side DiceService",
                    reason = audit.Reason,
                    expression = audit.Expression,
                    rolls = audit.Rolls,
                    keptRoll = audit.KeptRoll,
                    modifier = audit.Modifier,
                    total = audit.Total,
                    mode = audit.Mode,
                    dc = audit.Dc,
                    success = audit.Dc > 0 ? (bool?)audit.Success : null
                };

                toolOutputs.Add(new
                {
                    type = "function_call_output",
                    call_id = call.CallId,
                    output = JsonSerializer.Serialize(toolResult)
                });
            }

            object continuationBody = new
            {
                model,
                instructions,
                previous_response_id = responseId,
                input = toolOutputs,
                tools = new[] { diceTool },
                tool_choice = "auto",
                parallel_tool_calls = false,
                max_output_tokens = 1200,
                safety_identifier = BuildSafetyIdentifier(discordUserId)
            };

            raw = await SendOpenAiAsync(apiKey, continuationBody);
        }

        throw new InvalidOperationException("The Game Master requested too many dice operations in one turn.");
    }

    public async Task TestApiKeyAsync(string apiKey)
    {
        if (string.IsNullOrWhiteSpace(apiKey))
            throw new OpenAiConfigurationException("OpenAI API key is required.");

        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.openai.com/v1/models");
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", apiKey.Trim());
        using var response = await _http.SendAsync(request);
        var raw = await response.Content.ReadAsStringAsync();

        if (response.IsSuccessStatusCode) return;

        if ((int)response.StatusCode == 401)
            throw new OpenAiConfigurationException("OpenAI rejected this API key. Check the key and try again.");

        if ((int)response.StatusCode == 429)
            throw new OpenAiUsageException("OpenAI rate-limited the key while testing it. Try again shortly.");

        throw new InvalidOperationException($"OpenAI API key test failed (HTTP {(int)response.StatusCode}). {ExtractApiError(raw)}");
    }

    private static object BuildDiceTool()
    {
        return new
        {
            type = "function",
            name = "roll_dice",
            description = "Roll authoritative game dice on the trusted RabuShin server. Use this whenever any player, NPC, monster, attack, save, check, damage, random table, or other game mechanic requires randomness. Never ask the player to roll instead.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    count = new
                    {
                        type = "integer",
                        minimum = 1,
                        maximum = 100,
                        description = "Number of dice to roll. For advantage/disadvantage use count 1 and sides 20."
                    },
                    sides = new
                    {
                        type = "integer",
                        minimum = 2,
                        maximum = 1000,
                        description = "Number of sides on each die, such as 4, 6, 8, 10, 12, 20, or 100."
                    },
                    modifier = new
                    {
                        type = "integer",
                        minimum = -100,
                        maximum = 100,
                        description = "Total numeric modifier to add after rolling."
                    },
                    advantage = new
                    {
                        type = "boolean",
                        description = "True only for a d20 roll made with advantage."
                    },
                    disadvantage = new
                    {
                        type = "boolean",
                        description = "True only for a d20 roll made with disadvantage."
                    },
                    reason = new
                    {
                        type = "string",
                        description = "Short human-readable reason, e.g. Stealth check, longsword attack, fireball damage, Goblin Dexterity save."
                    },
                    dc = new
                    {
                        type = "integer",
                        minimum = 0,
                        maximum = 1000,
                        description = "Target DC or AC if this roll is checked against one. Use 0 if no DC applies, such as most damage rolls."
                    }
                },
                required = new[]
                {
                    "count", "sides", "modifier", "advantage", "disadvantage", "reason", "dc"
                },
                additionalProperties = false
            }
        };
    }

    private GameMasterDiceAudit ExecuteAuthoritativeRoll(DiceToolArguments args)
    {
        var count = Math.Clamp(args.Count, 1, 100);
        var sides = Math.Clamp(args.Sides, 2, 1000);
        var modifier = Math.Clamp(args.Modifier, -100, 100);
        var dc = Math.Clamp(args.Dc, 0, 1000);
        var advantage = sides == 20 && args.Advantage;
        var disadvantage = sides == 20 && args.Disadvantage;

        var dice = new DiceService();
        var result = sides == 20 && (advantage || disadvantage)
            ? dice.RollD20(modifier, advantage, disadvantage)
            : dice.Roll(count, sides, modifier);

        var reason = string.IsNullOrWhiteSpace(args.Reason)
            ? "GM roll"
            : args.Reason.Trim();

        return new GameMasterDiceAudit(
            reason,
            result.Expression,
            result.Rolls.ToArray(),
            result.KeptRoll,
            result.Modifier,
            result.Total,
            result.Mode,
            dc,
            dc > 0 && result.Total >= dc);
    }

    private async Task<string> SendOpenAiAsync(string apiKey, object body)
    {
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

        return raw;
    }

    private static List<DiceToolCall> ExtractDiceToolCalls(string json)
    {
        var result = new List<DiceToolCall>();

        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("output", out var output) || output.ValueKind != JsonValueKind.Array)
            return result;

        foreach (var item in output.EnumerateArray())
        {
            if (!item.TryGetProperty("type", out var type) || type.GetString() != "function_call")
                continue;

            if (!item.TryGetProperty("name", out var name) || name.GetString() != "roll_dice")
                continue;

            if (!item.TryGetProperty("call_id", out var callIdElement) || callIdElement.ValueKind != JsonValueKind.String)
                continue;

            if (!item.TryGetProperty("arguments", out var argsElement) || argsElement.ValueKind != JsonValueKind.String)
                continue;

            var callId = callIdElement.GetString();
            var argsJson = argsElement.GetString();

            if (string.IsNullOrWhiteSpace(callId) || string.IsNullOrWhiteSpace(argsJson))
                continue;

            var args = JsonSerializer.Deserialize<DiceToolArguments>(argsJson, JsonOptions);
            if (args is null)
                throw new InvalidOperationException("The Game Master returned invalid dice arguments.");

            result.Add(new DiceToolCall(callId, args));
        }

        return result;
    }

    private static string ExtractResponseId(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String
            ? id.GetString() ?? string.Empty
            : string.Empty;
    }

    private static string BuildVisibleGmMessage(string finalText, IReadOnlyList<GameMasterDiceAudit> rolls)
    {
        if (rolls.Count == 0)
            return finalText;

        var sb = new StringBuilder();
        sb.AppendLine("SERVER-AUTHORITATIVE GM ROLLS");

        foreach (var roll in rolls)
        {
            sb.Append("• ").Append(roll.Reason).Append(": ");

            if (roll.KeptRoll.HasValue)
            {
                sb.Append(roll.Mode)
                    .Append(" [")
                    .Append(string.Join(", ", roll.Rolls))
                    .Append("] → kept ")
                    .Append(roll.KeptRoll.Value)
                    .Append(' ')
                    .Append(FormatModifier(roll.Modifier))
                    .Append(" = ")
                    .Append(roll.Total);
            }
            else
            {
                sb.Append(roll.Expression)
                    .Append(" [")
                    .Append(string.Join(", ", roll.Rolls))
                    .Append("] ")
                    .Append(FormatModifier(roll.Modifier))
                    .Append(" = ")
                    .Append(roll.Total);
            }

            if (roll.Dc > 0)
            {
                sb.Append(" vs ")
                    .Append(roll.Dc)
                    .Append(roll.Success ? " — SUCCESS" : " — FAILURE");
            }

            sb.AppendLine();
        }

        sb.AppendLine();
        sb.Append(finalText);
        return sb.ToString();
    }

    private static int AbilityModifier(int score)
        => (int)Math.Floor((score - 10) / 2.0);

    private static string FormatModifier(int modifier)
        => modifier >= 0 ? $"+{modifier}" : modifier.ToString();

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
        catch
        {
            // Fall through to raw response text below.
        }

        return json.Length > 500 ? json[..500] : json;
    }

    private sealed record DiceToolCall(string CallId, DiceToolArguments Arguments);

    private sealed class DiceToolArguments
    {
        public int Count { get; set; }
        public int Sides { get; set; }
        public int Modifier { get; set; }
        public bool Advantage { get; set; }
        public bool Disadvantage { get; set; }
        public string Reason { get; set; } = "GM roll";
        public int Dc { get; set; }
    }
}

public sealed record GameMasterTurnResult(
    string Message,
    IReadOnlyList<GameMasterDiceAudit> Rolls);

public sealed record GameMasterDiceAudit(
    string Reason,
    string Expression,
    int[] Rolls,
    int? KeptRoll,
    int Modifier,
    int Total,
    string Mode,
    int Dc,
    bool Success);

public sealed class OpenAiUsageException : Exception
{
    public OpenAiUsageException(string message) : base(message) { }
}

public sealed class OpenAiConfigurationException : Exception
{
    public OpenAiConfigurationException(string message) : base(message) { }
}
