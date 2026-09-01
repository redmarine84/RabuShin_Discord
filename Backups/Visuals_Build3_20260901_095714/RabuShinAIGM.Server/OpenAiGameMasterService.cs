using QuestsOfRabuShinAIGM;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Globalization;
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

AUTHORITATIVE INVENTORY / CURRENCY STATE — MANDATORY:
- The server-supplied CURRENT GOLD and CURRENT INVENTORY are authoritative. Never merely narrate a permanent currency or inventory change.
- Whenever the character definitively receives or loses GP, call adjust_gold before narrating the completed transaction or reward. Use a positive delta for gained GP and a negative delta for spent/lost GP.
- Whenever the character definitively gains an item, trophy, quest reward, purchased item, or loot, call add_inventory_item before narrating that it is now carried.
- Whenever the character definitively sells, gives away, surrenders, or consumes a carried item through GM resolution, call remove_inventory_item before narrating that it is gone.
- Do NOT call add_inventory_item merely because an item is visible, offered, found but not taken, or mentioned. Only mutate state after acquisition is actually resolved.
- Do NOT call adjust_gold merely because a reward is promised. Only mutate state when payment is actually received or spent.
- The inventory Use button prepares an action but does not pre-consume the item; if the use is successfully resolved and should consume the item, call remove_inventory_item exactly once.
- Never invent successful state changes. Use the tool result as the source of truth and narrate only after a successful tool response.

WORLD MAP / TRAVEL AUTHORITY — MANDATORY:
- The server-supplied WORLD MAP STATE below is authoritative and shared by the entire campaign.
- Locations marked HIDDEN are not known well enough for fast travel. Do not reveal their names, positions, routes, or existence merely because they appear in campaign canon or in your private world knowledge.
- When the party definitively learns the name and usable directions/location of a settlement through a quest, NPC, discovered clue, or direct visit, call discover_world_location exactly once for that settlement before treating it as available on the World Map.
- Do not call discover_world_location for a vague rumor that does not provide enough information to locate the settlement.
- A [WORLD MAP TRAVEL REQUEST] always comes from a destination already revealed by the server. Resolve the journey normally, including travel complications, random encounters, weather, or interruptions when appropriate.
- If the party actually arrives at the selected destination, call travel_to_world_location before narrating arrival. If the journey is interrupted, do not call travel_to_world_location until arrival actually occurs.
- Never update the campaign's location by narration alone. The travel_to_world_location tool is the authoritative location change.
- The current settlement is always considered discovered.

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
        inputBuilder.AppendLine($"HP {character.CurrentHp}/{character.MaxHp}; AC {character.ArmorClass}; Proficiency Bonus +{character.ProficiencyBonus}; GP {character.Gold:0.##}");
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

        var worldMapState = await GetWorldMapStateAsync(campaign.CampaignId);
        inputBuilder.AppendLine();
        inputBuilder.AppendLine("WORLD MAP STATE (SERVER-AUTHORITATIVE / CAMPAIGN-WIDE):");
        if (worldMapState.Count == 0)
        {
            inputBuilder.AppendLine("(World Map state is unavailable.)");
        }
        else
        {
            foreach (var location in worldMapState)
            {
                if (location.Discovered)
                    inputBuilder.AppendLine($"- DISCOVERED: {location.LocationName}{(location.IsCurrent ? " — CURRENT LOCATION" : string.Empty)}");
                else
                    inputBuilder.AppendLine($"- HIDDEN: {location.LocationKey}");
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

        var tools = new[]
        {
            BuildDiceTool(),
            BuildAdjustGoldTool(),
            BuildAddInventoryItemTool(),
            BuildRemoveInventoryItemTool(),
            BuildDiscoverWorldLocationTool(),
            BuildTravelToWorldLocationTool()
        };
        var rollAudits = new List<GameMasterDiceAudit>();
        var stateAudits = new List<GameMasterStateAudit>();

        object initialBody = new
        {
            model,
            instructions,
            input = inputBuilder.ToString(),
            tools,
            tool_choice = "auto",
            parallel_tool_calls = false,
            max_output_tokens = 1200,
            safety_identifier = BuildSafetyIdentifier(discordUserId)
        };

        var raw = await SendOpenAiAsync(apiKey, initialBody);

        // Allow sequential trusted operations in one GM turn: dice, rewards, loot,
        // purchases, and item removal. Every state mutation is committed to Supabase
        // before the GM receives the tool result and narrates the outcome.
        for (var step = 0; step < 12; step++)
        {
            var calls = ExtractToolCalls(raw);
            if (calls.Count == 0)
            {
                var finalText = ExtractOutputText(raw);
                if (string.IsNullOrWhiteSpace(finalText))
                    throw new InvalidOperationException("OpenAI returned no Game Master text.");

                return new GameMasterTurnResult(
                    BuildVisibleGmMessage(finalText.Trim(), rollAudits, stateAudits),
                    rollAudits,
                    stateAudits);
            }

            var responseId = ExtractResponseId(raw);
            if (string.IsNullOrWhiteSpace(responseId))
                throw new InvalidOperationException("OpenAI requested a trusted GM operation but returned no response ID.");

            var toolOutputs = new List<object>();

            foreach (var call in calls)
            {
                object toolResult;

                switch (call.Name)
                {
                    case "roll_dice":
                    {
                        var args = DeserializeArguments<DiceToolArguments>(call.ArgumentsJson, "dice");
                        var audit = ExecuteAuthoritativeRoll(args);
                        rollAudits.Add(audit);
                        toolResult = new
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
                        break;
                    }
                    case "adjust_gold":
                    {
                        var args = DeserializeArguments<AdjustGoldToolArguments>(call.ArgumentsJson, "gold adjustment");
                        var newGold = await AdjustGoldAsync(character.CharacterId, campaign.CampaignId, args.Delta);
                        var reason = CleanReason(args.Reason, "GM currency change");
                        var summary = $"{(args.Delta >= 0 ? "+" : string.Empty)}{args.Delta} GP ({reason}); balance {newGold:0.##} GP";
                        stateAudits.Add(new GameMasterStateAudit("Gold", summary));
                        toolResult = new { authoritative = true, action = "adjust_gold", delta = args.Delta, newGold, reason };
                        break;
                    }
                    case "add_inventory_item":
                    {
                        var args = DeserializeArguments<AddInventoryItemToolArguments>(call.ArgumentsJson, "inventory addition");
                        var quantity = Math.Clamp(args.Quantity, 1, 1000);
                        var itemName = CleanItemName(args.ItemName);
                        var carried = await AddInventoryItemAsync(
                            character.CharacterId, campaign.CampaignId, itemName, quantity,
                            args.Description, args.Source, args.Notes);
                        var summary = $"Added {quantity} × {itemName}; now carrying {carried}";
                        stateAudits.Add(new GameMasterStateAudit("Inventory", summary));
                        toolResult = new { authoritative = true, action = "add_inventory_item", itemName, quantityAdded = quantity, quantityCarried = carried };
                        break;
                    }
                    case "remove_inventory_item":
                    {
                        var args = DeserializeArguments<RemoveInventoryItemToolArguments>(call.ArgumentsJson, "inventory removal");
                        var quantity = Math.Clamp(args.Quantity, 1, 1000);
                        var itemName = CleanItemName(args.ItemName);
                        var remaining = await RemoveInventoryItemAsync(character.CharacterId, campaign.CampaignId, itemName, quantity);
                        var reason = CleanReason(args.Reason, "GM inventory change");
                        var summary = $"Removed {quantity} × {itemName} ({reason}); {remaining} remaining";
                        stateAudits.Add(new GameMasterStateAudit("Inventory", summary));
                        toolResult = new { authoritative = true, action = "remove_inventory_item", itemName, quantityRemoved = quantity, quantityRemaining = remaining, reason };
                        break;
                    }
                    case "discover_world_location":
                    {
                        var args = DeserializeArguments<DiscoverWorldLocationToolArguments>(call.ArgumentsJson, "world map discovery");
                        var locationName = CleanWorldLocationName(args.LocationName);
                        var reason = CleanReason(args.Reason, "Discovered through play");
                        var discovered = await DiscoverWorldLocationAsync(campaign.CampaignId, locationName, reason);
                        var summary = $"World Map discovered: {discovered} ({reason})";
                        stateAudits.Add(new GameMasterStateAudit("WorldMap", summary));
                        toolResult = new { authoritative = true, action = "discover_world_location", locationName = discovered, reason };
                        break;
                    }
                    case "travel_to_world_location":
                    {
                        var args = DeserializeArguments<TravelWorldLocationToolArguments>(call.ArgumentsJson, "world map travel");
                        var locationName = CleanWorldLocationName(args.LocationName);
                        var arrived = await TravelToWorldLocationAsync(campaign.CampaignId, locationName);
                        var summary = $"Campaign location changed to {arrived}";
                        stateAudits.Add(new GameMasterStateAudit("WorldMap", summary));
                        toolResult = new { authoritative = true, action = "travel_to_world_location", currentLocation = arrived };
                        break;
                    }
                    default:
                        throw new InvalidOperationException($"The Game Master requested unsupported tool '{call.Name}'.");
                }

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
                tools,
                tool_choice = "auto",
                parallel_tool_calls = false,
                max_output_tokens = 1200,
                safety_identifier = BuildSafetyIdentifier(discordUserId)
            };

            raw = await SendOpenAiAsync(apiKey, continuationBody);
        }

        throw new InvalidOperationException("The Game Master requested too many trusted operations in one turn.");
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

    private static object BuildAdjustGoldTool()
    {
        return new
        {
            type = "function",
            name = "adjust_gold",
            description = "Atomically change the current player character's GP balance after a reward, purchase, payment, theft, loss, or other definitively resolved currency event. Use a positive delta to add GP and a negative delta to spend/remove GP. Never use this for merely promised money.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    delta = new { type = "integer", minimum = -1000000, maximum = 1000000, description = "GP change. Example: 25 awards 25 GP; -5 spends 5 GP." },
                    reason = new { type = "string", description = "Short reason such as Quest reward, bought rations, paid innkeeper." }
                },
                required = new[] { "delta", "reason" },
                additionalProperties = false
            }
        };
    }

    private static object BuildAddInventoryItemTool()
    {
        return new
        {
            type = "function",
            name = "add_inventory_item",
            description = "Add a definitively acquired item or loot to the current player character's authoritative inventory. Call this when an item is actually taken, awarded, purchased, harvested, or otherwise obtained. Do not call for merely visible or offered items.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    itemName = new { type = "string", description = "Canonical concise item name, e.g. Wolf Pelt, Potion of Healing, Longsword." },
                    quantity = new { type = "integer", minimum = 1, maximum = 1000 },
                    description = new { type = "string", description = "Brief useful description for the inventory detail panel. Use an empty string if no additional description is known." },
                    source = new { type = "string", description = "Where the item came from, e.g. Wolf, Quest Reward, Merchant, Chest. Empty string is allowed." },
                    notes = new { type = "string", description = "Short special notes. Empty string is allowed." }
                },
                required = new[] { "itemName", "quantity", "description", "source", "notes" },
                additionalProperties = false
            }
        };
    }

    private static object BuildRemoveInventoryItemTool()
    {
        return new
        {
            type = "function",
            name = "remove_inventory_item",
            description = "Remove an item from the current player character's authoritative inventory when it is definitively sold, given away, surrendered, destroyed, or consumed through GM resolution. The server rejects removal if the character does not carry enough.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    itemName = new { type = "string", description = "Exact carried item name from CURRENT INVENTORY." },
                    quantity = new { type = "integer", minimum = 1, maximum = 1000 },
                    reason = new { type = "string", description = "Short reason such as Sold to merchant, given to NPC, consumed." }
                },
                required = new[] { "itemName", "quantity", "reason" },
                additionalProperties = false
            }
        };
    }

    private static object BuildDiscoverWorldLocationTool()
    {
        return new
        {
            type = "function",
            name = "discover_world_location",
            description = "Reveal a Vael Turog settlement on the shared campaign World Map after the party definitively learns its name and usable location/directions through play. Do not use for vague rumors or hidden campaign knowledge.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    locationName = new { type = "string", description = "Canonical settlement name learned by the party." },
                    reason = new { type = "string", description = "Short player-visible reason such as Directions from Mayor Harlowe or quest clue." }
                },
                required = new[] { "locationName", "reason" },
                additionalProperties = false
            }
        };
    }

    private static object BuildTravelToWorldLocationTool()
    {
        return new
        {
            type = "function",
            name = "travel_to_world_location",
            description = "Commit the campaign's current location after the party actually arrives at a discovered World Map destination. Never call merely when travel begins or while a journey is interrupted.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    locationName = new { type = "string", description = "Canonical discovered settlement that the party has actually reached." }
                },
                required = new[] { "locationName" },
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

    private async Task<decimal> AdjustGoldAsync(Guid characterId, Guid campaignId, int delta)
    {
        var raw = await CallSupabaseRpcAsync("discord_gm_adjust_gold", new
        {
            p_character_id = characterId,
            p_campaign_id = campaignId,
            p_delta = delta
        }, "Unable to update GP");

        if (decimal.TryParse(raw.Trim().Trim('"'), NumberStyles.Number, CultureInfo.InvariantCulture, out var value))
            return value;

        throw new InvalidOperationException("Supabase returned an invalid GP balance.");
    }

    private async Task<int> AddInventoryItemAsync(
        Guid characterId, Guid campaignId, string itemName, int quantity,
        string? description, string? source, string? notes)
    {
        var raw = await CallSupabaseRpcAsync("discord_gm_add_inventory_item", new
        {
            p_character_id = characterId,
            p_campaign_id = campaignId,
            p_item_name = itemName,
            p_quantity = quantity,
            p_description = (description ?? string.Empty).Trim(),
            p_source_name = (source ?? string.Empty).Trim(),
            p_notes = (notes ?? string.Empty).Trim()
        }, "Unable to add inventory item");

        if (int.TryParse(raw.Trim().Trim('"'), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value))
            return value;

        throw new InvalidOperationException("Supabase returned an invalid inventory quantity.");
    }

    private async Task<int> RemoveInventoryItemAsync(
        Guid characterId, Guid campaignId, string itemName, int quantity)
    {
        var raw = await CallSupabaseRpcAsync("discord_gm_remove_inventory_item", new
        {
            p_character_id = characterId,
            p_campaign_id = campaignId,
            p_item_name = itemName,
            p_quantity = quantity
        }, "Unable to remove inventory item");

        if (int.TryParse(raw.Trim().Trim('"'), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value))
            return value;

        throw new InvalidOperationException("Supabase returned an invalid remaining inventory quantity.");
    }

    private async Task<List<WorldMapStateRow>> GetWorldMapStateAsync(Guid campaignId)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_get_world_map_state",
            new { p_campaign_id = campaignId },
            "Unable to load World Map state");

        return JsonSerializer.Deserialize<List<WorldMapStateRow>>(raw, JsonOptions)
               ?? new List<WorldMapStateRow>();
    }

    private async Task<string> DiscoverWorldLocationAsync(Guid campaignId, string locationName, string reason)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_discover_world_location",
            new
            {
                p_campaign_id = campaignId,
                p_location_name = locationName,
                p_reason = reason
            },
            "Unable to reveal World Map location");

        var value = JsonSerializer.Deserialize<string>(raw, JsonOptions);
        if (string.IsNullOrWhiteSpace(value))
            throw new InvalidOperationException("Supabase returned an invalid World Map discovery result.");
        return value;
    }

    private async Task<string> TravelToWorldLocationAsync(Guid campaignId, string locationName)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_travel_to_world_location",
            new
            {
                p_campaign_id = campaignId,
                p_location_name = locationName
            },
            "Unable to update World Map travel location");

        var value = JsonSerializer.Deserialize<string>(raw, JsonOptions);
        if (string.IsNullOrWhiteSpace(value))
            throw new InvalidOperationException("Supabase returned an invalid World Map travel result.");
        return value;
    }

    private async Task<string> CallSupabaseRpcAsync(string functionName, object body, string errorPrefix)
    {
        var supabaseUrl = _configuration["Supabase:Url"];
        var secretKey = _configuration["Supabase:SecretKey"];

        if (string.IsNullOrWhiteSpace(supabaseUrl) || string.IsNullOrWhiteSpace(secretKey))
            throw new InvalidOperationException("Supabase server configuration is missing; the Game Master cannot persist inventory or currency changes.");

        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            $"{supabaseUrl.TrimEnd('/')}/rest/v1/rpc/{functionName}");
        request.Headers.TryAddWithoutValidation("apikey", secretKey);
        request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

        using var response = await _http.SendAsync(request);
        var raw = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"{errorPrefix}: {raw}");

        return raw;
    }

    private static T DeserializeArguments<T>(string json, string label)
    {
        var value = JsonSerializer.Deserialize<T>(json, JsonOptions);
        if (value is null)
            throw new InvalidOperationException($"The Game Master returned invalid {label} arguments.");
        return value;
    }

    private static string CleanItemName(string? itemName)
    {
        var value = (itemName ?? string.Empty).Trim();
        if (value.Length == 0) throw new InvalidOperationException("The Game Master tried to mutate an inventory item without a name.");
        if (value.Length > 120) value = value[..120];
        return value;
    }

    private static string CleanWorldLocationName(string? locationName)
    {
        var value = (locationName ?? string.Empty).Trim();
        if (value.Length == 0)
            throw new InvalidOperationException("The Game Master tried to change World Map state without a location name.");
        if (value.Length > 80) value = value[..80];
        return value;
    }

    private static string CleanReason(string? reason, string fallback)
    {
        var value = (reason ?? string.Empty).Trim();
        if (value.Length == 0) return fallback;
        return value.Length <= 160 ? value : value[..160];
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

    private static List<GmToolCall> ExtractToolCalls(string json)
    {
        var result = new List<GmToolCall>();

        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("output", out var output) || output.ValueKind != JsonValueKind.Array)
            return result;

        foreach (var item in output.EnumerateArray())
        {
            if (!item.TryGetProperty("type", out var type) || type.GetString() != "function_call")
                continue;

            if (!item.TryGetProperty("name", out var nameElement) || nameElement.ValueKind != JsonValueKind.String)
                continue;

            if (!item.TryGetProperty("call_id", out var callIdElement) || callIdElement.ValueKind != JsonValueKind.String)
                continue;

            if (!item.TryGetProperty("arguments", out var argsElement) || argsElement.ValueKind != JsonValueKind.String)
                continue;

            var name = nameElement.GetString();
            var callId = callIdElement.GetString();
            var argsJson = argsElement.GetString();

            if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(callId) || string.IsNullOrWhiteSpace(argsJson))
                continue;

            result.Add(new GmToolCall(callId, name, argsJson));
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

    private static string BuildVisibleGmMessage(
        string finalText,
        IReadOnlyList<GameMasterDiceAudit> rolls,
        IReadOnlyList<GameMasterStateAudit> stateChanges)
    {
        if (rolls.Count == 0 && stateChanges.Count == 0)
            return finalText;

        var sb = new StringBuilder();

        if (rolls.Count > 0)
        {
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
        }

        if (stateChanges.Count > 0)
        {
            sb.AppendLine("SERVER-AUTHORITATIVE STATE UPDATES");
            foreach (var change in stateChanges)
                sb.Append("• ").Append(change.Summary).AppendLine();
            sb.AppendLine();
        }

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

    private sealed record GmToolCall(string CallId, string Name, string ArgumentsJson);

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

    private sealed class AdjustGoldToolArguments
    {
        public int Delta { get; set; }
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class AddInventoryItemToolArguments
    {
        public string ItemName { get; set; } = string.Empty;
        public int Quantity { get; set; }
        public string Description { get; set; } = string.Empty;
        public string Source { get; set; } = string.Empty;
        public string Notes { get; set; } = string.Empty;
    }

    private sealed class RemoveInventoryItemToolArguments
    {
        public string ItemName { get; set; } = string.Empty;
        public int Quantity { get; set; }
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class DiscoverWorldLocationToolArguments
    {
        public string LocationName { get; set; } = string.Empty;
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class TravelWorldLocationToolArguments
    {
        public string LocationName { get; set; } = string.Empty;
    }

    private sealed class WorldMapStateRow
    {
        [System.Text.Json.Serialization.JsonPropertyName("location_key")]
        public string LocationKey { get; set; } = string.Empty;

        [System.Text.Json.Serialization.JsonPropertyName("location_name")]
        public string LocationName { get; set; } = string.Empty;

        [System.Text.Json.Serialization.JsonPropertyName("discovered")]
        public bool Discovered { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("is_current")]
        public bool IsCurrent { get; set; }
    }
}

public sealed record GameMasterTurnResult(
    string Message,
    IReadOnlyList<GameMasterDiceAudit> Rolls,
    IReadOnlyList<GameMasterStateAudit> StateChanges);

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

public sealed record GameMasterStateAudit(string Kind, string Summary);

public sealed class OpenAiUsageException : Exception
{
    public OpenAiUsageException(string message) : base(message) { }
}

public sealed class OpenAiConfigurationException : Exception
{
    public OpenAiConfigurationException(string message) : base(message) { }
}
