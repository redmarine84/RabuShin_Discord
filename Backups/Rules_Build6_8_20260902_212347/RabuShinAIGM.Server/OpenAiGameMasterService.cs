using QuestsOfRabuShinAIGM;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

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

SETTLEMENT / ENCOUNTER MAP AUTHORITY — MANDATORY:
- The Settlement Map always represents the campaign's current settlement and needs no GM state change.
- The Encounter Map is shared campaign state and must stay hidden during ordinary exploration, travel, shopping, or conversation.
- When a tactical encounter or combat begins and the current settlement's encounter map is useful, call set_encounter_map with active=true before or as you establish the tactical scene.
- When that encounter ends, the party leaves the tactical scene, or travel changes settlements, call set_encounter_map with active=false.
- Do not activate the Encounter Map merely because enemies are mentioned or because combat might happen later.

COMBAT / STRICT INITIATIVE — SERVER-AUTHORITATIVE / MANDATORY:
- When actual combat begins, call start_combat exactly once, then add_combat_monster for EVERY enemy participating in the encounter. Keep returned display names stable (for example Wolf 1, Wolf 2).
- BEFORE any combatant acts, call stage_combat_tokens to establish legal initial positions, then call initialize_combat_initiative exactly once. The server includes only player characters who are currently online in this campaign plus active hostile enemies; absent/offline party characters do not receive initiative rolls or tactical participation.
- INTERRUPTED COMBAT SETUP RECOVERY: If COMBAT STATE is ACTIVE, STRICT INITIATIVE is NOT INITIALIZED, and the current turn is NOT SET, setup was interrupted. Do NOT wait for another combatant. Do NOT restart or end the encounter merely because initiative is missing. Add only enemies that are still missing, stage all combat tokens, initialize combat initiative, and then continue normally. If no enemies have been added yet, add the encounter's enemies before staging.
- Never invent a turn, action, target, or tactical position for an offline party character. If a participating player disconnects, the server can skip that character while they are offline; if they reconnect during the same fight and already had an initiative entry, they may resume on a later round.
- Once strict initiative exists, NEVER choose or jump to another combatant manually. The current turn is the server's source of truth.
- If initialize_combat_initiative makes an ENEMY the current combatant, immediately resolve that enemy's complete turn and then call advance_combat_turn. Continue resolving every consecutive enemy in initiative order until a player character's turn is reached or combat ends.
- On a PLAYER CHARACTER turn, resolve only the player's declared actions. NEVER call advance_combat_turn for that player. Their turn ends only when that player presses the End Turn button.
- After a player's End Turn request, the server advances initiative before asking you to continue. If the new current turn is an enemy, resolve it completely, call advance_combat_turn, and continue through any consecutive enemies. STOP when the current turn becomes a character.
- A complete enemy turn means adjudicate legal movement/action/bonus action as appropriate, use server dice for attacks/saves/damage, persist damage to a character with update_character_hp, persist enemy HP/status with update_combat_monster, and then advance.
- Never narrate persistent HP changes without the matching trusted state tool. hpDelta is negative for damage and positive for healing.
- Round number advances automatically when strict initiative wraps. Do not manually change rounds during strict initiative.
- Enemy hostility is authoritative state. When an enemy flees, surrenders, becomes friendly/non-hostile, or otherwise leaves the fight without being killed, call set_enemy_disposition immediately. Do not leave a departed enemy marked hostile.
- update_combat_monster automatically ends combat when that update defeats the final hostile enemy. set_enemy_disposition automatically ends combat when the final hostile enemy flees, surrenders, or becomes non-hostile. If either tool reports combatEnded=true, STOP resolving initiative immediately and do not call advance_combat_turn afterward.
- If the PLAYER PARTY successfully escapes/pursuit ends and no enemy can immediately continue the fight, call end_combat immediately with the escape reason.
- Combat is over when all enemies are defeated, fled, surrendered/non-hostile, or the party successfully escapes. Do not keep initiative running merely because defeated or departed combatants still exist in history.

CHARACTER DEATH / REVIVAL AUTHORITY — MANDATORY:
- Reaching 0 HP is NOT automatically death. A character at 0 HP is unconscious and follows normal D&D death-saving-throw / instant-death rules unless a rule explicitly says otherwise.
- Use roll_dice for death saving throws when they are required. Do not call mark_character_dead merely because HP reached 0.
- Call mark_character_dead exactly once only when the character is truly dead: for example after the normal death-save failure threshold, massive/instant death, or another rule/effect that explicitly kills them. Include the cause.
- Once mark_character_dead succeeds, the server creates the player's Respawn decision state. Do not decide Yes/No for the player and do not deduct Respawn gold yourself.
- Normal D&D revival remains valid. If Revivify, another legal revival spell/effect, or an owned revival item is successfully used on a truly dead character, resolve all normal spell/item requirements first and then call revive_character with the HP the rule grants. The server cancels any open Respawn fund and refunds party donations.
- Ordinary healing via update_character_hp cannot revive a truly dead character. Use revive_character only for a valid rules-based revival effect.

TACTICAL COMBAT MAP / TOKEN AUTHORITY - SERVER-AUTHORITATIVE / MANDATORY:
- The Encounter Map uses a logical 20x20 combat grid. Grid coordinates are zero-based: x=0..19 left-to-right; y=0..19 top-to-bottom. Each square represents 5 feet.
- Initial token placement MUST use stage_combat_tokens, not arbitrary coordinates. The server chooses safe legal squares from the Build 5.1 terrain masks. By default it avoids buildings, walls, cliffs/ledges, closed doors, difficult terrain and partial obstructions. Set the party terrain allowances true only when the scene explicitly says the party begins in that terrain/cover.
- Describe the encounter geometry to stage_combat_tokens: for a melee creature that jumps in front of a character, use about 5–10 ft.; for a ranged attacker, choose a starting distance that is within that attack/weapon's legal range and require line of sight. If the fiction explicitly puts an enemy in difficult terrain or cover, allow it in that engagement.
- A player can move only their own character token and only on their current initiative turn. The server enforces Speed, terrain cost, obstacles, and cumulative movement.
- Do not use position_combat_token for a player's voluntary movement. Player voluntary movement comes from the Tactical Combat Map UI.
- Use position_combat_token for monster movement after combat begins or for GM-authoritative forced movement. Use exact stable monster display names and exact party character names.
- VISUALS BUILD 5.1 - TACTICAL TERRAIN GM
- Monster movement remains GM-authoritative, but normal position_combat_token movement is now validated against the encounter terrain mask and uses terrain-aware path cost.
- Buildings and walls block normal movement and line of sight. Closed doors block both until opened. Open doors and marked bridge/stair passages are passable.
- Water and marked stone/debris are difficult terrain. Marked stalls, stone/debris, tables, and chairs can provide half cover while remaining partially visible.
- Use check_tactical_line_of_sight before a ranged attack, visible-target spell, or visibility-sensitive ruling when cover or obstruction may matter.
- Use set_tactical_door_state when a combatant opens or closes a nearby marked door. The server finds the nearest marked door to that combatant.
- Do not narrate a creature walking through a building, wall, closed door, or cliff. If normal movement is blocked, choose a legal path/destination instead.
- Teleportation is the exception: include the word teleport in the position_combat_token reason when the effect legitimately ignores the path between start and destination. The destination still must be an unoccupied tactical square.

EXPERIENCE / QUEST REWARDS / REST-GATED LEVELING — MANDATORY:
- Character XP is server-authoritative. Never invent, subtract, or manually narrate an XP award that was not returned by a trusted tool.
- When update_combat_monster first marks a monster defeated, RabuShin automatically reads that monster's trusted Challenge Rating / XP value from the Monster Codex and awards the encounter XP to the player characters who received initiative in that fight. Do not call a separate monster-XP tool and do not award the same monster twice.
- Quest XP is separate from monster XP. When a quest is definitively completed, call complete_quest exactly once with the quest's stable name and whether it was a minor, side, or main quest. The server calculates the XP amount from the character's current level and the quest category and prevents duplicate awards for the same quest.
- Earning enough XP does NOT immediately change a character's level. It only makes that character Level Up Ready.
- A character levels only after actually completing an in-game LONG REST. Do not call complete_long_rest merely because the player says they intend to sleep; resolve whether the Long Rest successfully completes first.
- A first-person request such as "I take a Short Rest" or "I take a Long Rest" applies only to the speaking player's character unless the players explicitly establish that the party is resting together. Never silently rest absent or nonparticipating party members.
- When one or more characters actually wake from a completed Long Rest, call complete_long_rest and pass only the characters who completed it. The server restores HP to full, restores all spent Hit Dice, restores tracked spell slots/resources, and, if XP qualifies, advances them to the earned level.
- If complete_long_rest reports a level increase, do not choose the player's subclass, class options, spells, or other level-up choices for them. Tell them they wake stronger and that their Level Up screen is waiting in the Character tab.
- A spellcasting character who completes a Long Rest without leveling can optionally review/change their spells after waking. The client presents that choice; do not choose spells for the player.
- A Short Rest never triggers an XP level increase. A Short Rest must actually complete before you call complete_short_rest. The server then presents each named player with their own Hit Dice screen. Do NOT roll or spend their Hit Dice for them.
- On that Short Rest screen, the player may spend zero or more of their AVAILABLE Hit Dice. Each spent die is rolled by the server and adds the character's Constitution modifier; healing is at least 1 HP per die and cannot exceed max HP. A character cannot spend more Hit Dice in one Short Rest than their total character level, and previously spent Hit Dice stay unavailable until a completed Long Rest restores them.

ALIGNMENT GAUGE — SERVER-AUTHORITATIVE / MANDATORY:
- The character's current alignment is server supplied. Alignment follows this ordered nine-stage ladder from most good to most evil: Lawful Good → Neutral Good → Chaotic Good → Lawful Neutral → True Neutral → Chaotic Neutral → Lawful Evil → Neutral Evil → Chaotic Evil.
- A morally significant GOOD deed moves the hidden alignment gauge one point toward the good side. A morally significant EVIL deed moves it one point toward the evil side.
- Exactly 9 net points in one direction changes alignment by one stage and resets the stage progress. Example: True Neutral + 9 good points becomes Lawful Neutral; True Neutral + 9 evil points becomes Chaotic Neutral.
- Call record_alignment_deed only after a player character definitively performs a morally significant deed. Do not score ordinary politeness, combat against legitimate hostile enemies, routine bargaining, or merely stated intentions.
- Killing or deliberately harming innocents, cruelty, betrayal for selfish harm, and similarly serious acts normally qualify as evil. Meaningful mercy, self-sacrifice, protection of innocents, and similarly serious altruistic acts normally qualify as good. Judge context fairly.
- If an action is morally mixed or neutral, do not call the tool. If one resolved player action contains multiple clearly separate significant deeds, you may call it once for each distinct deed.
- The server, not narration, changes the stored alignment. Never claim the alignment changed unless the tool result says it changed.

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
        var earnedXpLevel = ExperienceProgression.LevelForXp(character.Experience);
        inputBuilder.AppendLine($"XP {character.Experience:N0}; stored Level {character.Level}; XP-earned Level {earnedXpLevel}{(earnedXpLevel > character.Level ? " — LEVEL UP READY; LONG REST REQUIRED" : string.Empty)}");
        if (character.CharacterData.ValueKind == JsonValueKind.Object && character.CharacterData.TryGetProperty("lastLevelUp", out var lastLevelUp))
            inputBuilder.AppendLine($"LAST PLAYER-CHOSEN LEVEL-UP OPTIONS: {lastLevelUp.GetRawText()}");
        inputBuilder.AppendLine(
            $"STR {character.Strength} ({FormatModifier(AbilityModifier(character.Strength))}), " +
            $"DEX {character.Dexterity} ({FormatModifier(AbilityModifier(character.Dexterity))}), " +
            $"CON {character.Constitution} ({FormatModifier(AbilityModifier(character.Constitution))}), " +
            $"INT {character.Intelligence} ({FormatModifier(AbilityModifier(character.Intelligence))}), " +
            $"WIS {character.Wisdom} ({FormatModifier(AbilityModifier(character.Wisdom))}), " +
            $"CHA {character.Charisma} ({FormatModifier(AbilityModifier(character.Charisma))})");
        inputBuilder.AppendLine($"ALIGNMENT: {character.Alignment}");
        var racialTraitSummary = CharacterFeatureRules.BuildGmTraitSummary(character.CharacterData);
        if (!string.IsNullOrWhiteSpace(racialTraitSummary)) inputBuilder.AppendLine($"RACIAL TRAITS: {racialTraitSummary}");
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

        // VISUALS BUILD 3 - LOCAL MAP GM TOOL
        var localMapState = await GetLocalMapStateAsync(campaign.CampaignId);
        inputBuilder.AppendLine();
        inputBuilder.AppendLine("LOCAL MAP STATE (SERVER-AUTHORITATIVE / CAMPAIGN-WIDE):");
        if (localMapState is null)
        {
            inputBuilder.AppendLine("(Local map state unavailable. Do not attempt to change encounter-map state.)");
        }
        else
        {
            inputBuilder.AppendLine($"- Settlement Map: {localMapState.CurrentLocation}");
            inputBuilder.AppendLine(localMapState.EncounterActive
                ? $"- Encounter Map: ACTIVE for {localMapState.CurrentLocation} ({localMapState.EncounterReason})"
                : "- Encounter Map: INACTIVE");
        }
        var partyCombatants = await GetPartyCombatantsForGmAsync(campaign.CampaignId);
        inputBuilder.AppendLine();
        inputBuilder.AppendLine("PARTY COMBAT STATS (SERVER-AUTHORITATIVE):");
        foreach (var member in partyCombatants)
        {
            inputBuilder.AppendLine($"- {member.CharacterName}: Level {member.Level} {member.ClassName}; HP {member.CurrentHp}/{member.MaxHp}; AC {member.ArmorClass}; Speed {member.Speed} ft.; PB +{member.ProficiencyBonus}; STR {member.Strength} ({FormatModifier(AbilityModifier(member.Strength))}), DEX {member.Dexterity} ({FormatModifier(AbilityModifier(member.Dexterity))}), CON {member.Constitution} ({FormatModifier(AbilityModifier(member.Constitution))}), INT {member.Intelligence} ({FormatModifier(AbilityModifier(member.Intelligence))}), WIS {member.Wisdom} ({FormatModifier(AbilityModifier(member.Wisdom))}), CHA {member.Charisma} ({FormatModifier(AbilityModifier(member.Charisma))})");
        }

        // VISUALS BUILD 4 - MONSTER COMBAT GM
        var combatState = await GetCombatStateForGmAsync(campaign.CampaignId);
        inputBuilder.AppendLine();
        inputBuilder.AppendLine("COMBAT STATE (SERVER-AUTHORITATIVE / CAMPAIGN-WIDE):");
        if (combatState is null || !combatState.Active)
        {
            inputBuilder.AppendLine("- Combat: INACTIVE");
        }
        else
        {
            inputBuilder.AppendLine($"- Combat: ACTIVE â€” {combatState.Title}; Round {combatState.RoundNumber}");
            foreach (var enemy in combatState.Monsters)
            {
                inputBuilder.AppendLine($"- {enemy.DisplayName} [{enemy.MonsterName}] HP {enemy.CurrentHp}/{enemy.MaxHp}; AC {enemy.ArmorClass}; Conditions: {(string.IsNullOrWhiteSpace(enemy.Conditions) ? "None" : enemy.Conditions)}; Disposition: {enemy.Disposition}; Defeated: {enemy.Defeated}");
                var codexEnemy = MonsterCodexService.Shared.Find(enemy.MonsterName);
                if (codexEnemy is not null && !string.IsNullOrWhiteSpace(codexEnemy.Details))
                {
                    var details = codexEnemy.Details.Length > 6000 ? codexEnemy.Details[..6000] : codexEnemy.Details;
                    inputBuilder.AppendLine($"  Trusted codex stat block for {enemy.DisplayName}:");
                    inputBuilder.AppendLine(details);
                }
            }
        }
        // VISUALS BUILD 5 - TACTICAL COMBAT GM
        var tacticalState = await GetTacticalCombatStateForGmAsync(campaign.CampaignId);
        inputBuilder.AppendLine();
        inputBuilder.AppendLine("TACTICAL COMBAT GRID (SERVER-AUTHORITATIVE / CAMPAIGN-WIDE):");
        if (tacticalState is null || !tacticalState.Active)
        {
            inputBuilder.AppendLine("- Tactical grid: INACTIVE");
        }
        else
        {
            inputBuilder.AppendLine($"- Grid: 20x20; 5 ft. per square; Round {tacticalState.RoundNumber}");
            inputBuilder.AppendLine(string.IsNullOrWhiteSpace(tacticalState.CurrentTurnName)
                ? "- Current turn: NOT SET"
                : $"- Current turn: {tacticalState.CurrentTurnName} ({tacticalState.CurrentTurnType})");
            foreach (var token in tacticalState.Tokens)
            {
                inputBuilder.AppendLine($"- {token.DisplayName} [{token.EntityType}] square ({token.GridX},{token.GridY}); HP {token.CurrentHp}/{token.MaxHp}; AC {token.ArmorClass}; movement spent {token.MovementSpentFt} ft.{(token.Defeated ? "; DEFEATED/DOWN" : string.Empty)}");
            }
        }
        var initiativeState = await GetCombatInitiativeForGmAsync(campaign.CampaignId);
        inputBuilder.AppendLine();
        inputBuilder.AppendLine("STRICT INITIATIVE ORDER (SERVER-AUTHORITATIVE):");
        if (initiativeState.Count == 0)
        {
            inputBuilder.AppendLine("- Initiative: NOT INITIALIZED");
        }
        else
        {
            foreach (var entry in initiativeState)
            {
                inputBuilder.AppendLine($"- #{entry.OrderPosition}: {entry.DisplayName} ({entry.EntityType}) = {entry.InitiativeRoll}{FormatModifier(entry.InitiativeModifier)} = {entry.InitiativeTotal}{(entry.IsCurrent ? " — CURRENT TURN" : string.Empty)}{(entry.Defeated ? " — DEFEATED" : string.Empty)}");
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
            BuildAlignmentDeedTool(),
            BuildAddInventoryItemTool(),
            BuildRemoveInventoryItemTool(),
            BuildDiscoverWorldLocationTool(),
            BuildTravelToWorldLocationTool(),
            BuildCompleteQuestTool(),
            BuildCompleteShortRestTool(),
            BuildCompleteLongRestTool(),
            BuildSetEncounterMapTool(),
            BuildStartCombatTool(),
            BuildAddCombatMonsterTool(),
            BuildStageCombatTokensTool(),
            BuildInitializeCombatInitiativeTool(),
            BuildUpdateCombatMonsterTool(),
            BuildSetEnemyDispositionTool(),
            BuildUpdateCharacterHpTool(),
            BuildMarkCharacterDeadTool(),
            BuildReviveCharacterTool(),
            BuildAdvanceCombatTurnTool(),
            BuildEndCombatTool(),
            BuildPositionCombatTokenTool(),
            BuildCheckTacticalLineOfSightTool(),
            BuildSetTacticalDoorStateTool()
        };
        var rollAudits = new List<GameMasterDiceAudit>();
        var stateAudits = new List<GameMasterStateAudit>();
        var combatEndedDuringTurn = false;

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
        for (var step = 0; step < 32; step++)
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
                    case "record_alignment_deed":
                    {
                        var args = DeserializeArguments<AlignmentDeedToolArguments>(call.ArgumentsJson, "alignment deed");
                        var direction = (args.Direction ?? string.Empty).Trim().ToLowerInvariant();
                        if (direction is not ("good" or "evil"))
                            throw new InvalidOperationException("Alignment deed direction must be good or evil.");
                        var reason = CleanReason(args.Reason, direction == "good" ? "Significant good deed" : "Significant evil deed");
                        var result = await RecordAlignmentDeedAsync(character.CharacterId, campaign.CampaignId, direction, reason);
                        if (result.Changed)
                            stateAudits.Add(new GameMasterStateAudit("Alignment", $"Alignment changed: {result.PreviousAlignment} → {result.Alignment} ({reason})"));
                        toolResult = new
                        {
                            authoritative = true,
                            action = "record_alignment_deed",
                            direction,
                            reason,
                            alignment = result.Alignment,
                            deedBalance = result.AlignmentDeedBalance,
                            goodDeeds = result.GoodDeeds,
                            evilDeeds = result.EvilDeeds,
                            changed = result.Changed,
                            previousAlignment = result.PreviousAlignment
                        };
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
                    case "complete_quest":
                    {
                        var args = DeserializeArguments<CompleteQuestToolArguments>(call.ArgumentsJson, "quest completion");
                        var result = await CompleteQuestAsync(campaign.CampaignId, character.Level, args);
                        stateAudits.Add(new GameMasterStateAudit("Experience", $"Quest completed: {args.QuestName}; XP reward processed as {args.Difficulty}."));
                        toolResult = result;
                        break;
                    }
                    case "complete_short_rest":
                    {
                        var args = DeserializeArguments<CompleteShortRestToolArguments>(call.ArgumentsJson, "short rest completion");
                        var result = await CompleteShortRestAsync(campaign.CampaignId, args);
                        var waiting = result.Where(r => r.Status.Equals("awaiting_hit_dice", StringComparison.OrdinalIgnoreCase))
                            .Select(r => r.CharacterName).ToArray();
                        stateAudits.Add(new GameMasterStateAudit("Rest", waiting.Length > 0
                            ? $"Short Rest completed; Hit Dice choices waiting for: {string.Join(", ", waiting)}"
                            : "Short Rest completed."));
                        toolResult = new { authoritative = true, action = "complete_short_rest", characters = result };
                        break;
                    }
                    case "complete_long_rest":
                    {
                        var args = DeserializeArguments<CompleteLongRestToolArguments>(call.ArgumentsJson, "long rest completion");
                        var result = await CompleteLongRestAsync(campaign.CampaignId, args);
                        var leveled = result.Where(r => r.LeveledUp).Select(r => $"{r.CharacterName} {r.FromLevel}→{r.ToLevel}").ToArray();
                        stateAudits.Add(new GameMasterStateAudit("Rest", leveled.Length > 0
                            ? $"Long Rest completed; level up: {string.Join(", ", leveled)}"
                            : "Long Rest completed; no XP level increase."));
                        toolResult = new { authoritative = true, action = "complete_long_rest", characters = result };
                        break;
                    }
                    case "set_encounter_map":
                    {
                        var args = DeserializeArguments<SetEncounterMapToolArguments>(call.ArgumentsJson, "encounter map state");
                        var reason = CleanReason(args.Reason, args.Active ? "Tactical encounter" : "Encounter ended");
                        var location = await SetEncounterMapAsync(campaign.CampaignId, args.Active, reason);
                        var summary = args.Active
                            ? $"Encounter Map activated for {location} ({reason})"
                            : $"Encounter Map closed ({reason})";
                        stateAudits.Add(new GameMasterStateAudit("Map", summary));
                        toolResult = new { authoritative = true, action = "set_encounter_map", active = args.Active, currentLocation = location, reason };
                        break;
                    }                    case "start_combat":
                    {
                        var args = DeserializeArguments<StartCombatToolArguments>(call.ArgumentsJson, "combat start");
                        var title = await StartCombatAsync(campaign.CampaignId, args.Title);
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"Combat started: {title}"));
                        toolResult = new { authoritative=true, action="start_combat", title };
                        break;
                    }
                    case "add_combat_monster":
                    {
                        var args = DeserializeArguments<AddCombatMonsterToolArguments>(call.ArgumentsJson, "combat monster");
                        var added = await AddCombatMonsterAsync(campaign.CampaignId, args);
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"Added to combat: {string.Join(", ", added)}"));
                        toolResult = new { authoritative=true, action="add_combat_monster", monsterName=args.MonsterName, displayNames=added };
                        break;
                    }
                    case "stage_combat_tokens":
                    {
                        var args = DeserializeArguments<StageCombatTokensToolArguments>(call.ArgumentsJson, "initial combat staging");
                        var result = await StageCombatTokensAsync(campaign.CampaignId, args);
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"Initial tactical staging completed for {result.Positioned} combatants ({result.Reason})"));
                        toolResult = new { authoritative=true, action="stage_combat_tokens", result.Positioned, result.Reason, positions=result.Positions };
                        break;
                    }
                    case "initialize_combat_initiative":
                    {
                        var candidates = await GetInitiativeCandidatesAsync(campaign.CampaignId);
                        if (candidates.Count == 0) throw new InvalidOperationException("No combatants are available for initiative.");
                        var entries = new List<InitiativePersistEntry>();
                        foreach (var candidate in candidates)
                        {
                            var modifier = candidate.EntityType.Equals("monster", StringComparison.OrdinalIgnoreCase)
                                ? GetMonsterInitiativeModifier(candidate.MonsterName)
                                : candidate.InitiativeModifier;
                            var audit = ExecuteAuthoritativeRoll(new DiceToolArguments
                            {
                                Count=1,Sides=20,Modifier=modifier,Advantage=false,Disadvantage=false,
                                Reason=$"{candidate.DisplayName} initiative",Dc=0
                            });
                            rollAudits.Add(audit);
                            entries.Add(new InitiativePersistEntry(candidate.EntityType,candidate.CharacterId,candidate.CombatMonsterId,audit.Rolls[0],modifier,audit.Total));
                        }
                        var result = await SetCombatInitiativeAsync(campaign.CampaignId, entries);
                        stateAudits.Add(new GameMasterStateAudit("Combat", "Strict initiative rolled and locked by the server."));
                        toolResult = result;
                        break;
                    }
                    case "update_combat_monster":
                    {
                        var args = DeserializeArguments<UpdateCombatMonsterToolArguments>(call.ArgumentsJson, "combat monster update");
                        var updated = await UpdateCombatMonsterAsync(campaign.CampaignId, args);
                        combatEndedDuringTurn |= updated.CombatEnded;
                        JsonElement? xpAward = null;
                        if (updated.Defeated)
                        {
                            xpAward = await AwardMonsterExperienceAsync(campaign.CampaignId, updated);
                            if (xpAward.Value.TryGetProperty("awarded", out var awarded) && awarded.ValueKind == JsonValueKind.True)
                                stateAudits.Add(new GameMasterStateAudit("Experience", $"{updated.DisplayName} XP awarded from trusted Challenge Rating."));
                        }
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"{updated.DisplayName}: HP {updated.CurrentHp}/{updated.MaxHp}; {updated.Disposition}; {(updated.Defeated ? "Defeated" : string.IsNullOrWhiteSpace(updated.Conditions) ? "No conditions" : updated.Conditions)}"));
                        toolResult = new { authoritative=true, action="update_combat_monster", updated.DisplayName, updated.CurrentHp, updated.MaxHp, updated.ArmorClass, updated.Conditions, updated.Defeated, updated.Disposition, combatEnded=updated.CombatEnded, endReason=updated.EndReason, experienceAward=xpAward };
                        break;
                    }
                    case "set_enemy_disposition":
                    {
                        var args = DeserializeArguments<SetEnemyDispositionToolArguments>(call.ArgumentsJson, "enemy disposition");
                        var result = await SetEnemyDispositionAsync(campaign.CampaignId, args);
                        if (result.TryGetProperty("combat_ended", out var ended) && ended.ValueKind == JsonValueKind.True) combatEndedDuringTurn = true;
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"{args.DisplayName}: disposition set to {args.Disposition} ({CleanReason(args.Reason, "combat state change")})"));
                        toolResult = result;
                        break;
                    }
                    case "update_character_hp":
                    {
                        var args = DeserializeArguments<UpdateCharacterHpToolArguments>(call.ArgumentsJson, "character HP update");
                        var result = await UpdateCharacterHpAsync(campaign.CampaignId,args);
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"{result.CharacterName}: HP {result.CurrentHp}/{result.MaxHp} ({(args.HpDelta >= 0 ? "+" : string.Empty)}{args.HpDelta})"));
                        toolResult = new { authoritative=true, action="update_character_hp", result.CharacterName, result.CurrentHp, result.MaxHp, hpDelta=args.HpDelta, result.Reason };
                        break;
                    }
                    case "mark_character_dead":
                    {
                        var args = DeserializeArguments<MarkCharacterDeadToolArguments>(call.ArgumentsJson, "character death");
                        var result = await MarkCharacterDeadAsync(campaign.CampaignId, args);
                        if (result.TryGetProperty("combat_advanced", out var advancedState) && advancedState.ValueKind == JsonValueKind.Object &&
                            advancedState.TryGetProperty("combat_ended", out var deathEnded) && deathEnded.ValueKind == JsonValueKind.True)
                            combatEndedDuringTurn = true;
                        stateAudits.Add(new GameMasterStateAudit("Death", $"{args.CharacterName} died ({CleanReason(args.Cause, "death")})"));
                        toolResult = result;
                        break;
                    }
                    case "revive_character":
                    {
                        var args = DeserializeArguments<ReviveCharacterToolArguments>(call.ArgumentsJson, "character revival");
                        var result = await ReviveCharacterAsync(campaign.CampaignId, args);
                        stateAudits.Add(new GameMasterStateAudit("Revival", $"{args.CharacterName} revived by normal D&D rules ({CleanReason(args.Reason, "revival")})"));
                        toolResult = result;
                        break;
                    }
                    case "advance_combat_turn":
                    {
                        var args = DeserializeArguments<AdvanceCombatTurnToolArguments>(call.ArgumentsJson, "combat turn advance");
                        if (combatEndedDuringTurn)
                        {
                            toolResult = new { authoritative=true, action="advance_combat_turn", skipped=true, combatEnded=true, reason="Combat already ended during this GM resolution." };
                            break;
                        }
                        var result = await AdvanceCombatTurnAsync(campaign.CampaignId,args.Reason);
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"Initiative advanced ({CleanReason(args.Reason,"turn complete")})"));
                        toolResult = result;
                        break;
                    }
                    case "set_combat_round":
                    {
                        var args = DeserializeArguments<SetCombatRoundToolArguments>(call.ArgumentsJson, "combat round");
                        var round = await SetCombatRoundAsync(campaign.CampaignId, args.RoundNumber);
                        toolResult = new { authoritative=true, action="set_combat_round", roundNumber=round };
                        break;
                    }
                    case "end_combat":
                    {
                        var args = DeserializeArguments<EndCombatToolArguments>(call.ArgumentsJson, "combat end");
                        var reason = CleanReason(args.Reason, "Encounter resolved");
                        await EndCombatAsync(campaign.CampaignId, reason);
                        combatEndedDuringTurn = true;
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"Combat ended ({reason})"));
                        toolResult = new { authoritative=true, action="end_combat", reason, combatEnded=true };
                        break;
                    }                    case "set_combat_turn":
                    {
                        var args = DeserializeArguments<SetCombatTurnToolArguments>(call.ArgumentsJson, "combat turn");
                        var result = await SetCombatTurnAsync(campaign.CampaignId, args);
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"Current turn: {args.CombatantName}"));
                        toolResult = result;
                        break;
                    }
                    case "position_combat_token":
                    {
                        var args = DeserializeArguments<PositionCombatTokenToolArguments>(call.ArgumentsJson, "combat token position");
                        var result = await PositionCombatTokenAsync(campaign.CampaignId, args);
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"{args.CombatantName} moved to tactical square ({args.GridX},{args.GridY})"));
                        toolResult = result;
                        break;
                    }                    case "check_tactical_line_of_sight":
                    {
                        var args = DeserializeArguments<CheckTacticalLineOfSightArguments>(call.ArgumentsJson, "tactical line of sight");
                        var result = await CheckTacticalLineOfSightAsync(campaign.CampaignId, args);
                        toolResult = result;
                        break;
                    }
                    case "set_tactical_door_state":
                    {
                        var args = DeserializeArguments<SetTacticalDoorStateArguments>(call.ArgumentsJson, "tactical door state");
                        var result = await SetTacticalDoorStateAsync(campaign.CampaignId, args);
                        stateAudits.Add(new GameMasterStateAudit("Combat", $"Nearby tactical door {(args.Open ? "opened" : "closed")} by {args.CombatantName}"));
                        toolResult = result;
                        break;
                    }                    default:
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

    private static object BuildAlignmentDeedTool()
    {
        return new
        {
            type = "function",
            name = "record_alignment_deed",
            description = "Record one definitively completed, morally significant good or evil deed on the current character's alignment gauge. Do not use for neutral, trivial, merely intended, or ambiguous actions. The server changes alignment automatically after 9 net deed points toward one side.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    direction = new { type = "string", @enum = new[] { "good", "evil" }, description = "Moral direction of this significant deed." },
                    reason = new { type = "string", description = "Short factual reason describing the completed deed." }
                },
                required = new[] { "direction", "reason" },
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

    private static object BuildCompleteQuestTool()
    {
        return new
        {
            type = "function",
            name = "complete_quest",
            description = "Award the shared campaign quest XP after a quest has been definitively completed. Call exactly once per completed quest. The trusted server calculates the per-character XP from the quest category and current progression; never invent or pass a raw XP amount.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    questName = new { type = "string", description = "Stable canonical quest name, e.g. The Sheep That Howled." },
                    difficulty = new { type = "string", @enum = new[] { "minor", "side", "main" }, description = "minor for a small optional objective, side for a substantial side quest, main for a main-story quest." }
                },
                required = new[] { "questName", "difficulty" },
                additionalProperties = false
            }
        };
    }

    private static object BuildCompleteShortRestTool()
    {
        return new
        {
            type = "function",
            name = "complete_short_rest",
            description = "Commit a successfully completed in-game Short Rest for the named player characters. Use only after the full Short Rest actually finishes without interruption. The trusted server opens each player's Hit Dice recovery screen; never choose, roll, or spend Hit Dice for a player.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    characterNames = new
                    {
                        type = "array",
                        minItems = 1,
                        maxItems = 20,
                        items = new { type = "string" },
                        description = "Exact character names that successfully completed this Short Rest."
                    },
                    reason = new { type = "string", description = "Short story reason/location for the completed rest." }
                },
                required = new[] { "characterNames", "reason" },
                additionalProperties = false
            }
        };
    }

    private static object BuildCompleteLongRestTool()
    {
        return new
        {
            type = "function",
            name = "complete_long_rest",
            description = "Commit a successfully completed in-game Long Rest for the named player characters. Use only after the rest actually finishes and the characters wake. This restores Long Rest resources and is the ONLY operation that converts enough accumulated XP into a higher character level. Never use for a Short Rest or merely intending to sleep.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    characterNames = new
                    {
                        type = "array",
                        minItems = 1,
                        maxItems = 20,
                        items = new { type = "string" },
                        description = "Exact character names that successfully completed this Long Rest."
                    },
                    reason = new { type = "string", description = "Short story reason/location for the completed rest, e.g. Slept safely at the Greymoor inn." }
                },
                required = new[] { "characterNames", "reason" },
                additionalProperties = false
            }
        };
    }

    private static object BuildSetEncounterMapTool()
    {
        return new
        {
            type = "function",
            name = "set_encounter_map",
            description = "Activate or close the shared Encounter Map for the campaign's current settlement. Activate only for an actual tactical encounter/combat; close it when that scene ends.",
            strict = true,
            parameters = new
            {
                type = "object",
                properties = new
                {
                    active = new { type = "boolean", description = "True when a tactical encounter begins; false when it ends." },
                    reason = new { type = "string", description = "Short reason such as Combat with wolf pack or Encounter resolved." }
                },
                required = new[] { "active", "reason" },
                additionalProperties = false
            }
        };
    }
    private static object BuildStartCombatTool() => new
    {
        type="function", name="start_combat", description="Start authoritative campaign combat and clear stale enemy state. Also activates the current Encounter Map.", strict=true,
        parameters=new { type="object", properties=new { title=new { type="string", description="Short encounter title." } }, required=new[]{"title"}, additionalProperties=false }
    };

    private static object BuildAddCombatMonsterTool() => new
    {
        type="function", name="add_combat_monster", description="Add one or more enemy monsters to active combat. RabuShin uses its Codex values for HP/AC when available.", strict=true,
        parameters=new { type="object", properties=new {
            monsterName=new { type="string", description="Canonical Codex creature name." },
            displayName=new { type="string", description="Short combat label. Empty string uses monsterName." },
            count=new { type="integer", minimum=1, maximum=20 },
            maxHp=new { type="integer", minimum=0, maximum=100000, description="Fallback max HP if the server Codex has no value; use 0 when unknown." },
            armorClass=new { type="integer", minimum=0, maximum=1000, description="Fallback AC if the server Codex has no value; use 0 when unknown." }
        }, required=new[]{"monsterName","displayName","count","maxHp","armorClass"}, additionalProperties=false }
    };

    private static object BuildStageCombatTokensTool() => new
    {
        type="function", name="stage_combat_tokens",
        description="Atomically place all combat tokens on safe Build 5.1 terrain before initiative. The server chooses actual squares; specify each enemy's intended engagement distance/range and target.",
        strict=true,
        parameters=new
        {
            type="object",
            properties=new
            {
                reason=new { type="string", description="Short scene reason, e.g. Wolf leaps onto the Greymoor path or Goblin ambush from bow range." },
                partyAllowDifficultTerrain=new { type="boolean", description="True only when the fiction explicitly starts the party in water, debris, rough stone, or other difficult terrain." },
                partyAllowHalfCover=new { type="boolean", description="True only when the fiction explicitly starts the party behind/in a partial obstruction that grants half cover." },
                engagements=new
                {
                    type="array",
                    items=new
                    {
                        type="object",
                        properties=new
                        {
                            combatantName=new { type="string", description="Exact stable enemy display name." },
                            targetCharacterName=new { type="string", description="Exact party character name this enemy initially engages; empty string uses the first party character." },
                            distanceFeet=new { type="integer", minimum=5, maximum=95, description="Preferred initial distance. Use 5-10 for adjacent/melee encounters; for ranged attackers choose a sensible distance within weapon/spell range." },
                            maximumRangeFeet=new { type="integer", minimum=5, maximum=1000, description="Maximum legal attack/weapon/spell range for this opening position. Must be at least distanceFeet." },
                            requireLineOfSight=new { type="boolean", description="Usually true, especially for a ranged attacker that already attacked or can see the target." },
                            allowDifficultTerrain=new { type="boolean", description="True only when the fiction explicitly places this enemy in water, debris, rough stone, or other difficult terrain." },
                            allowHalfCover=new { type="boolean", description="True only when the fiction explicitly places this enemy behind partial cover/obstruction." },
                            reason=new { type="string", description="Why this starting range/terrain is appropriate." }
                        },
                        required=new[]{"combatantName","targetCharacterName","distanceFeet","maximumRangeFeet","requireLineOfSight","allowDifficultTerrain","allowHalfCover","reason"},
                        additionalProperties=false
                    }
                }
            },
            required=new[]{"reason","partyAllowDifficultTerrain","partyAllowHalfCover","engagements"},additionalProperties=false
        }
    };

    private static object BuildInitializeCombatInitiativeTool() => new
    {
        type="function", name="initialize_combat_initiative",
        description="Roll and persist initiative for every active party character and enemy on the trusted server. Call exactly once after monsters are added and initial tokens are staged.",
        strict=true,
        parameters=new { type="object", properties=new { reason=new { type="string" } }, required=new[]{"reason"}, additionalProperties=false }
    };

    private static object BuildUpdateCharacterHpTool() => new
    {
        type="function", name="update_character_hp",
        description="Persist damage or healing to a party character, especially when resolving an enemy turn. hpDelta is negative damage or positive healing.",
        strict=true,
        parameters=new { type="object", properties=new {
            characterName=new { type="string", description="Exact party character name." },
            hpDelta=new { type="integer", minimum=-100000, maximum=100000 },
            reason=new { type="string", description="Short cause such as Wolf bite damage or healing." }
        }, required=new[]{"characterName","hpDelta","reason"}, additionalProperties=false }
    };

    private static object BuildAdvanceCombatTurnTool() => new
    {
        type="function", name="advance_combat_turn",
        description="Advance strictly to the next persisted initiative entry after the CURRENT ENEMY has fully completed its turn. Never use this to end a player character turn; players use the End Turn button.",
        strict=true,
        parameters=new { type="object", properties=new { reason=new { type="string", description="Short summary of why the current enemy turn is complete." } }, required=new[]{"reason"}, additionalProperties=false }
    };

    private static object BuildUpdateCombatMonsterTool() => new
    {
        type="function", name="update_combat_monster", description="Persist HP, conditions, and defeated state for one active enemy. hpDelta is negative damage or positive healing.", strict=true,
        parameters=new { type="object", properties=new {
            displayName=new { type="string", description="Exact stable display name from COMBAT STATE." },
            hpDelta=new { type="integer", minimum=-100000, maximum=100000 },
            conditions=new { type="string", description="Full current condition list after this update; empty string means none." },
            defeated=new { type="boolean" }
        }, required=new[]{"displayName","hpDelta","conditions","defeated"}, additionalProperties=false }
    };

    private static object BuildSetEnemyDispositionTool() => new
    {
        type="function", name="set_enemy_disposition",
        description="Persist that an active enemy fled, surrendered, became non-hostile, or returned to hostile status. This automatically ends combat when no hostile enemies remain.",
        strict=true,
        parameters=new { type="object", properties=new {
            displayName=new { type="string", description="Exact stable enemy display name from COMBAT STATE." },
            disposition=new { type="string", @enum=new[]{"fled","surrendered","nonhostile","hostile"} },
            reason=new { type="string", description="Why the enemy changed participation/hostility." }
        }, required=new[]{"displayName","disposition","reason"}, additionalProperties=false }
    };

    private static object BuildMarkCharacterDeadTool() => new
    {
        type="function", name="mark_character_dead",
        description="Mark a party character truly dead only after normal D&D death rules have actually killed them. Never use merely for reaching 0 HP.",
        strict=true,
        parameters=new { type="object", properties=new {
            characterName=new { type="string", description="Exact party character name." },
            cause=new { type="string", description="Concise mechanical/narrative cause of actual death." }
        }, required=new[]{"characterName","cause"}, additionalProperties=false }
    };

    private static object BuildReviveCharacterTool() => new
    {
        type="function", name="revive_character",
        description="Revive a truly dead character only after a valid D&D revival spell, item, or effect has been successfully resolved. Cancels/refunds any Respawn fund.",
        strict=true,
        parameters=new { type="object", properties=new {
            characterName=new { type="string", description="Exact dead party character name." },
            hitPoints=new { type="integer", minimum=1, maximum=100000, description="HP granted by the revival rule/effect." },
            reason=new { type="string", description="Spell/item/effect that performed the revival." }
        }, required=new[]{"characterName","hitPoints","reason"}, additionalProperties=false }
    };

    private static object BuildSetCombatRoundTool() => new
    {
        type="function", name="set_combat_round", description="Set the current combat round when a new round begins.", strict=true,
        parameters=new { type="object", properties=new { roundNumber=new { type="integer", minimum=1, maximum=10000 } }, required=new[]{"roundNumber"}, additionalProperties=false }
    };

    private static object BuildEndCombatTool() => new
    {
        type="function", name="end_combat", description="End authoritative combat, clear enemy combat state, and close the Encounter Map.", strict=true,
        parameters=new { type="object", properties=new { reason=new { type="string" } }, required=new[]{"reason"}, additionalProperties=false }
    };
    private static object BuildSetCombatTurnTool() => new
    {
        type="function",
        name="set_combat_turn",
        description="Set the authoritative current combat turn. This resets that combatant token's movement spent for the new turn and enables a player to move their own token when it is their character's turn.",
        strict=true,
        parameters=new
        {
            type="object",
            properties=new
            {
                entityType=new { type="string", @enum=new[]{"character","monster"}, description="character for a party member or monster for an enemy." },
                combatantName=new { type="string", description="Exact party character name or exact stable monster display name from combat state." }
            },
            required=new[]{"entityType","combatantName"},
            additionalProperties=false
        }
    };

    private static object BuildPositionCombatTokenTool() => new
    {
        type="function",
        name="position_combat_token",
        description="GM-authoritative tactical token positioning on the 20x20 encounter grid. Use for monster movement, initial staging, or forced movement; do not use for voluntary player movement.",
        strict=true,
        parameters=new
        {
            type="object",
            properties=new
            {
                entityType=new { type="string", @enum=new[]{"character","monster"} },
                combatantName=new { type="string", description="Exact party character name or exact stable monster display name." },
                gridX=new { type="integer", minimum=0, maximum=19, description="Zero-based column from left to right." },
                gridY=new { type="integer", minimum=0, maximum=19, description="Zero-based row from top to bottom." },
                reason=new { type="string", description="Short reason such as monster movement, initial staging, knockback, or teleport." }
            },
            required=new[]{"entityType","combatantName","gridX","gridY","reason"},
            additionalProperties=false
        }
    };
    private static object BuildCheckTacticalLineOfSightTool() => new
    {
        type="function",
        name="check_tactical_line_of_sight",
        description="Check server-authoritative line of sight and cover between two combatants on the active tactical encounter map.",
        strict=true,
        parameters=new
        {
            type="object",
            properties=new
            {
                fromCombatantName=new { type="string", description="Exact party character name or exact monster display name." },
                toCombatantName=new { type="string", description="Exact party character name or exact monster display name." }
            },
            required=new[]{"fromCombatantName","toCombatantName"},
            additionalProperties=false
        }
    };

    private static object BuildSetTacticalDoorStateTool() => new
    {
        type="function",
        name="set_tactical_door_state",
        description="Open or close the nearest marked tactical door to a combatant. Use only when the narrative action actually opens or closes a door.",
        strict=true,
        parameters=new
        {
            type="object",
            properties=new
            {
                combatantName=new { type="string", description="Exact party character name or exact monster display name standing near the door." },
                open=new { type="boolean", description="true to open the nearest door; false to close it." },
                reason=new { type="string", description="Short narrative reason for the door state change." }
            },
            required=new[]{"combatantName","open","reason"},
            additionalProperties=false
        }
    };
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

    private async Task<AlignmentDeedToolResult> RecordAlignmentDeedAsync(Guid characterId, Guid campaignId, string direction, string reason)
    {
        var raw = await CallSupabaseRpcAsync("discord_gm_record_alignment_deed", new
        {
            p_character_id = characterId,
            p_campaign_id = campaignId,
            p_direction = direction,
            p_reason = reason
        }, "Unable to update alignment gauge");

        return JsonSerializer.Deserialize<AlignmentDeedToolResult>(raw, JsonOptions)
               ?? throw new InvalidOperationException("Supabase returned an invalid alignment result.");
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

    private async Task<JsonElement> CompleteQuestAsync(Guid campaignId, int currentLevel, CompleteQuestToolArguments args)
    {
        var questName = (args.QuestName ?? string.Empty).Trim();
        if (questName.Length == 0) throw new InvalidOperationException("Quest completion requires a quest name.");
        if (questName.Length > 160) questName = questName[..160];

        var difficulty = (args.Difficulty ?? string.Empty).Trim().ToLowerInvariant();
        if (difficulty is not ("minor" or "side" or "main"))
            throw new InvalidOperationException("Quest difficulty must be minor, side, or main.");

        var key = Regex.Replace(questName.ToLowerInvariant(), @"[^a-z0-9]+", "-").Trim('-');
        if (key.Length == 0) key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(questName))).ToLowerInvariant()[..16];
        if (key.Length > 120) key = key[..120];
        var xp = ExperienceProgression.QuestXpPerCharacter(currentLevel, difficulty);

        var raw = await CallSupabaseRpcAsync(
            "discord_gm_award_quest_xp",
            new
            {
                p_campaign_id = campaignId,
                p_quest_key = key,
                p_quest_name = questName,
                p_xp_per_character = xp,
                p_difficulty = difficulty
            },
            "Unable to award quest experience");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<List<ShortRestResult>> CompleteShortRestAsync(Guid campaignId, CompleteShortRestToolArguments args)
    {
        var names = (args.CharacterNames ?? Array.Empty<string>())
            .Select(name => (name ?? string.Empty).Trim())
            .Where(name => name.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(20)
            .ToArray();
        if (names.Length == 0) throw new InvalidOperationException("A completed Short Rest requires at least one character name.");
        var reason = CleanReason(args.Reason, "Completed Short Rest");
        var results = new List<ShortRestResult>();

        foreach (var name in names)
        {
            var raw = await CallSupabaseRpcAsync(
                "discord_gm_complete_short_rest",
                new { p_campaign_id = campaignId, p_character_name = name, p_reason = reason },
                $"Unable to complete Short Rest for {name}");
            var result = JsonSerializer.Deserialize<ShortRestResult>(raw, JsonOptions)
                ?? throw new InvalidOperationException($"Short Rest returned no result for {name}.");
            results.Add(result);
        }
        return results;
    }

    private async Task<List<LongRestResult>> CompleteLongRestAsync(Guid campaignId, CompleteLongRestToolArguments args)
    {
        var names = (args.CharacterNames ?? Array.Empty<string>())
            .Select(name => (name ?? string.Empty).Trim())
            .Where(name => name.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(20)
            .ToArray();
        if (names.Length == 0) throw new InvalidOperationException("A completed Long Rest requires at least one character name.");
        var reason = CleanReason(args.Reason, "Completed Long Rest");
        var results = new List<LongRestResult>();

        foreach (var name in names)
        {
            var raw = await CallSupabaseRpcAsync(
                "discord_gm_complete_long_rest",
                new { p_campaign_id = campaignId, p_character_name = name, p_reason = reason },
                $"Unable to complete Long Rest for {name}");
            var result = JsonSerializer.Deserialize<LongRestResult>(raw, JsonOptions)
                ?? throw new InvalidOperationException($"Long Rest returned no result for {name}.");
            results.Add(result);
        }
        return results;
    }

    private async Task<JsonElement> AwardMonsterExperienceAsync(Guid campaignId, CombatMonsterForGm monster)
    {
        var xp = ExperienceProgression.GetMonsterExperience(monster.MonsterName);
        if (!xp.Found || xp.Xp <= 0)
        {
            using var missing = JsonDocument.Parse(JsonSerializer.Serialize(new
            {
                awarded = false,
                monsterName = monster.MonsterName,
                displayName = monster.DisplayName,
                reason = "No trusted Challenge Rating / XP value was found in the Monster Codex stat block."
            }));
            return missing.RootElement.Clone();
        }

        var raw = await CallSupabaseRpcAsync(
            "discord_gm_award_monster_xp",
            new
            {
                p_campaign_id = campaignId,
                p_display_name = monster.DisplayName,
                p_challenge_rating = xp.ChallengeRating,
                p_total_xp = xp.Xp
            },
            $"Unable to award experience for {monster.DisplayName}");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<LocalMapStateRow?> GetLocalMapStateAsync(Guid campaignId)
    {
        try
        {
            var raw = await CallSupabaseRpcAsync(
                "discord_gm_get_local_map_state",
                new { p_campaign_id = campaignId },
                "Unable to load local map state");
            var rows = JsonSerializer.Deserialize<List<LocalMapStateRow>>(raw, JsonOptions);
            return rows?.FirstOrDefault();
        }
        catch
        {
            return null;
        }
    }

    private async Task<string> SetEncounterMapAsync(Guid campaignId, bool active, string reason)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_set_encounter_map",
            new
            {
                p_campaign_id = campaignId,
                p_active = active,
                p_reason = reason
            },
            "Unable to update Encounter Map state");

        return JsonSerializer.Deserialize<string>(raw, JsonOptions) ?? string.Empty;
    }
    private async Task<CombatStateForGm?> GetCombatStateForGmAsync(Guid campaignId)
    {
        try
        {
            var raw=await CallSupabaseRpcAsync("discord_gm_get_combat_state",new { p_campaign_id=campaignId },"Unable to load combat state");
            var rows=JsonSerializer.Deserialize<List<CombatStateRowRaw>>(raw,JsonOptions);
            var row=rows?.FirstOrDefault();
            if(row is null)return null;
            var monsters=row.Monsters.ValueKind==JsonValueKind.Array ? JsonSerializer.Deserialize<List<CombatMonsterForGm>>(row.Monsters.GetRawText(),JsonOptions)??new() : new();
            return new CombatStateForGm(row.Active,row.Title,row.RoundNumber,monsters);
        }
        catch{return null;}
    }

    private async Task<string> StartCombatAsync(Guid campaignId,string title)
    {
        var raw=await CallSupabaseRpcAsync("discord_gm_start_combat",new { p_campaign_id=campaignId,p_title=CleanReason(title,"Combat Encounter") },"Unable to start combat");
        return JsonSerializer.Deserialize<string>(raw,JsonOptions)??"Combat Encounter";
    }

    private async Task<List<string>> AddCombatMonsterAsync(Guid campaignId,AddCombatMonsterToolArguments args)
    {
        var name=(args.MonsterName??string.Empty).Trim(); if(name.Length==0)throw new InvalidOperationException("Monster name is required.");
        var codex=MonsterCodexService.Shared.Find(name);
        var hp=Math.Max(1,codex?.HitPoints??(args.MaxHp>0?args.MaxHp:1));
        var ac=Math.Max(0,codex?.ArmorClass??(args.ArmorClass>0?args.ArmorClass:10));
        var raw=await CallSupabaseRpcAsync("discord_gm_add_combat_monster",new { p_campaign_id=campaignId,p_monster_name=name,p_display_name=(args.DisplayName??string.Empty).Trim(),p_max_hp=hp,p_armor_class=ac,p_count=Math.Clamp(args.Count,1,20) },"Unable to add combat monster");
        return JsonSerializer.Deserialize<List<string>>(raw,JsonOptions)??new();
    }

    private async Task<CombatMonsterForGm> UpdateCombatMonsterAsync(Guid campaignId,UpdateCombatMonsterToolArguments args)
    {
        var raw=await CallSupabaseRpcAsync("discord_gm_update_combat_monster",new { p_campaign_id=campaignId,p_display_name=(args.DisplayName??string.Empty).Trim(),p_hp_delta=args.HpDelta,p_conditions=args.Conditions??string.Empty,p_defeated=args.Defeated },"Unable to update combat monster");
        return JsonSerializer.Deserialize<CombatMonsterForGm>(raw,JsonOptions)??throw new InvalidOperationException("Supabase returned invalid combat monster state.");
    }

    private async Task<JsonElement> SetEnemyDispositionAsync(Guid campaignId, SetEnemyDispositionToolArguments args)
    {
        var disposition=(args.Disposition??string.Empty).Trim().ToLowerInvariant();
        if (disposition is not ("fled" or "surrendered" or "nonhostile" or "hostile"))
            throw new InvalidOperationException("Enemy disposition must be fled, surrendered, nonhostile, or hostile.");
        var raw=await CallSupabaseRpcAsync("discord_gm_set_enemy_disposition",new {
            p_campaign_id=campaignId,p_display_name=(args.DisplayName??string.Empty).Trim(),p_disposition=disposition,
            p_reason=CleanReason(args.Reason,"Enemy disposition changed")
        },"Unable to update enemy disposition");
        using var document=JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> MarkCharacterDeadAsync(Guid campaignId, MarkCharacterDeadToolArguments args)
    {
        var raw=await CallSupabaseRpcAsync("discord_gm_mark_character_dead",new {
            p_campaign_id=campaignId,p_character_name=(args.CharacterName??string.Empty).Trim(),p_cause=CleanReason(args.Cause,"Death")
        },"Unable to mark character dead");
        using var document=JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> ReviveCharacterAsync(Guid campaignId, ReviveCharacterToolArguments args)
    {
        var raw=await CallSupabaseRpcAsync("discord_gm_revive_character",new {
            p_campaign_id=campaignId,p_character_name=(args.CharacterName??string.Empty).Trim(),
            p_hit_points=Math.Max(1,args.HitPoints),p_reason=CleanReason(args.Reason,"Rules-based revival")
        },"Unable to revive character");
        using var document=JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<int> SetCombatRoundAsync(Guid campaignId,int roundNumber)
    {
        var raw=await CallSupabaseRpcAsync("discord_gm_set_combat_round",new { p_campaign_id=campaignId,p_round=Math.Clamp(roundNumber,1,10000) },"Unable to update combat round");
        return int.TryParse(raw.Trim().Trim('"'),out var value)?value:Math.Max(1,roundNumber);
    }

    private async Task EndCombatAsync(Guid campaignId,string reason)
        => _=await CallSupabaseRpcAsync("discord_gm_end_combat",new { p_campaign_id=campaignId,p_reason=reason },"Unable to end combat");
    private async Task<List<PartyCombatantForGm>> GetPartyCombatantsForGmAsync(Guid campaignId)
    {
        var raw=await CallSupabaseRpcAsync("discord_gm_get_party_combatants",new { p_campaign_id=campaignId },"Unable to load party combat stats");
        return JsonSerializer.Deserialize<List<PartyCombatantForGm>>(raw,JsonOptions) ?? new();
    }

    private async Task<List<InitiativeCandidateForGm>> GetInitiativeCandidatesAsync(Guid campaignId)
    {
        var raw=await CallSupabaseRpcAsync("discord_gm_get_initiative_candidates",new { p_campaign_id=campaignId },"Unable to load initiative candidates");
        return JsonSerializer.Deserialize<List<InitiativeCandidateForGm>>(raw,JsonOptions) ?? new();
    }

    private async Task<List<CombatInitiativeForGm>> GetCombatInitiativeForGmAsync(Guid campaignId)
    {
        try
        {
            var raw=await CallSupabaseRpcAsync("discord_gm_get_combat_initiative",new { p_campaign_id=campaignId },"Unable to load strict initiative");
            return JsonSerializer.Deserialize<List<CombatInitiativeForGm>>(raw,JsonOptions) ?? new();
        }
        catch { return new(); }
    }

    private async Task<JsonElement> SetCombatInitiativeAsync(Guid campaignId,IReadOnlyList<InitiativePersistEntry> entries)
    {
        var payload=entries.Select(e=>new
        {
            entity_type=e.EntityType,
            character_id=e.CharacterId,
            combat_monster_id=e.CombatMonsterId,
            initiative_roll=e.InitiativeRoll,
            initiative_modifier=e.InitiativeModifier,
            initiative_total=e.InitiativeTotal
        }).ToArray();
        var raw=await CallSupabaseRpcAsync("discord_gm_set_combat_initiative",new { p_campaign_id=campaignId,p_entries=payload },"Unable to initialize strict initiative");
        using var document=JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> AdvanceCombatTurnAsync(Guid campaignId,string? reason)
    {
        var raw=await CallSupabaseRpcAsync("discord_gm_advance_combat_turn",new { p_campaign_id=campaignId,p_reason=CleanReason(reason,"Enemy turn complete") },"Unable to advance strict initiative");
        using var document=JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<CharacterHpResult> UpdateCharacterHpAsync(Guid campaignId,UpdateCharacterHpToolArguments args)
    {
        var raw=await CallSupabaseRpcAsync("discord_gm_adjust_character_hp",new
        {
            p_campaign_id=campaignId,
            p_character_name=(args.CharacterName??string.Empty).Trim(),
            p_hp_delta=args.HpDelta,
            p_reason=CleanReason(args.Reason,"Combat HP change")
        },"Unable to update character HP");
        return JsonSerializer.Deserialize<CharacterHpResult>(raw,JsonOptions) ?? throw new InvalidOperationException("Supabase returned invalid character HP state.");
    }

    private static int GetMonsterInitiativeModifier(string? monsterName)
    {
        var name=(monsterName??string.Empty).Trim();
        if(name.Length==0)return 0;
        var codex=MonsterCodexService.Shared.Find(name);
        var details=codex?.Details??string.Empty;
        var match=Regex.Match(details,@"\bDEX\s+\d+\s*\(\s*([+-]?\d+)\s*\)",RegexOptions.IgnoreCase|RegexOptions.CultureInvariant);
        return match.Success&&int.TryParse(match.Groups[1].Value,NumberStyles.Integer,CultureInfo.InvariantCulture,out var modifier)?modifier:0;
    }

    private async Task<CombatStagingResult> StageCombatTokensAsync(Guid campaignId,StageCombatTokensToolArguments args)
    {
        var localMap=await GetLocalMapStateAsync(campaignId);
        var tactical=await GetTacticalCombatStateForGmAsync(campaignId);
        if(localMap is null || tactical is null || !tactical.Active)
            throw new InvalidOperationException("Tactical map state is not active for initial combat staging.");
        if(TacticalTerrainCatalog.Find(localMap.LocationKey) is null)
            throw new InvalidOperationException($"No Build 5.1 terrain definition exists for {localMap.CurrentLocation}.");

        var doors=await GetTacticalDoorStatesForGmAsync(campaignId,localMap.LocationKey);
        var occupied=new HashSet<(int X,int Y)>();
        var positions=new List<CombatStagingPosition>();
        var characterPositions=new Dictionary<string,TacticalSpawnPoint>(StringComparer.OrdinalIgnoreCase);
        var characters=tactical.Tokens.Where(t=>t.EntityType.Equals("character",StringComparison.OrdinalIgnoreCase)).OrderBy(t=>t.DisplayName).ToList();
        var monsters=tactical.Tokens.Where(t=>t.EntityType.Equals("monster",StringComparison.OrdinalIgnoreCase)&&!t.Defeated).OrderBy(t=>t.DisplayName).ToList();
        if(characters.Count==0)throw new InvalidOperationException("No party character tokens are available for initial staging.");

        var anchor=TacticalTerrainCatalog.FindInitialPartyAnchor(localMap.LocationKey,doors,occupied,args.PartyAllowDifficultTerrain,args.PartyAllowHalfCover);
        for(var i=0;i<characters.Count;i++)
        {
            var token=characters[i];
            TacticalSpawnPoint point;
            if(i==0) point=anchor;
            else point=TacticalTerrainCatalog.FindInitialSpawnNear(localMap.LocationKey,anchor.GridX,anchor.GridY,5,Math.Min(15,5+i*5),doors,occupied,true,args.PartyAllowDifficultTerrain,args.PartyAllowHalfCover);
            occupied.Add((point.GridX,point.GridY));
            characterPositions[token.DisplayName]=point;
            positions.Add(new CombatStagingPosition(token.TokenId,token.DisplayName,token.EntityType,point.GridX,point.GridY,point.DistanceFeet,point.Note));
        }

        var engagements=(args.Engagements??new List<StageEngagementToolArguments>())
            .Where(e=>!string.IsNullOrWhiteSpace(e.CombatantName))
            .GroupBy(e=>e.CombatantName.Trim(),StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g=>g.Key,g=>g.Last(),StringComparer.OrdinalIgnoreCase);
        var fallbackTarget=characters[0].DisplayName;

        foreach(var token in monsters)
        {
            engagements.TryGetValue(token.DisplayName,out var engagement);
            engagement??=new StageEngagementToolArguments
            {
                CombatantName=token.DisplayName,TargetCharacterName=fallbackTarget,DistanceFeet=10,MaximumRangeFeet=10,
                RequireLineOfSight=true,AllowDifficultTerrain=false,AllowHalfCover=false,Reason="Default close engagement"
            };
            var targetName=string.IsNullOrWhiteSpace(engagement.TargetCharacterName)?fallbackTarget:engagement.TargetCharacterName.Trim();
            if(!characterPositions.TryGetValue(targetName,out var target))
                target=characterPositions[fallbackTarget];
            var desired=Math.Clamp(engagement.DistanceFeet<=0?10:engagement.DistanceFeet,5,95);
            var maxRange=Math.Max(desired,engagement.MaximumRangeFeet<=0?desired:engagement.MaximumRangeFeet);
            var point=TacticalTerrainCatalog.FindInitialSpawnNear(localMap.LocationKey,target.GridX,target.GridY,desired,maxRange,doors,occupied,
                engagement.RequireLineOfSight,engagement.AllowDifficultTerrain,engagement.AllowHalfCover);
            occupied.Add((point.GridX,point.GridY));
            positions.Add(new CombatStagingPosition(token.TokenId,token.DisplayName,token.EntityType,point.GridX,point.GridY,point.DistanceFeet,
                $"{point.Note}; {CleanReason(engagement.Reason,"initial engagement")}"));
        }

        // Include defeated monster tokens if any somehow exist during setup; place them safely after active tokens.
        foreach(var token in tactical.Tokens.Where(t=>t.EntityType.Equals("monster",StringComparison.OrdinalIgnoreCase)&&t.Defeated))
        {
            var point=TacticalTerrainCatalog.FindInitialSpawnNear(localMap.LocationKey,anchor.GridX,anchor.GridY,15,40,doors,occupied,false,true,true);
            occupied.Add((point.GridX,point.GridY));
            positions.Add(new CombatStagingPosition(token.TokenId,token.DisplayName,token.EntityType,point.GridX,point.GridY,point.DistanceFeet,"defeated token staging"));
        }

        var rpcPositions=positions.Select(x=>new { token_id=x.TokenId,grid_x=x.GridX,grid_y=x.GridY }).ToArray();
        var reason=CleanReason(args.Reason,"Terrain-aware initial combat staging");
        var raw=await CallSupabaseRpcAsync("discord_gm_stage_combat_tokens",new { p_campaign_id=campaignId,p_positions=rpcPositions,p_reason=reason },"Unable to stage combat tokens");
        using var doc=JsonDocument.Parse(raw);
        var positioned=doc.RootElement.TryGetProperty("positioned",out var count)&&count.TryGetInt32(out var n)?n:positions.Count;
        return new CombatStagingResult(positioned,reason,positions);
    }

    private async Task<TacticalCombatForGm?> GetTacticalCombatStateForGmAsync(Guid campaignId)
    {
        try
        {
            var raw = await CallSupabaseRpcAsync(
                "discord_gm_get_tactical_combat_state",
                new { p_campaign_id = campaignId },
                "Unable to load tactical combat state");
            var rows = JsonSerializer.Deserialize<List<TacticalCombatStateRowForGm>>(raw, JsonOptions);
            var row = rows?.FirstOrDefault();
            if (row is null) return null;
            var tokens = row.Tokens.ValueKind == JsonValueKind.Array
                ? JsonSerializer.Deserialize<List<TacticalTokenForGm>>(row.Tokens.GetRawText(), JsonOptions) ?? new()
                : new List<TacticalTokenForGm>();
            return new TacticalCombatForGm(row.Active,row.RoundNumber,row.CurrentTurnType,row.CurrentTurnName,tokens);
        }
        catch
        {
            return null;
        }
    }

    private async Task<JsonElement> SetCombatTurnAsync(Guid campaignId, SetCombatTurnToolArguments args)
    {
        var raw = await CallSupabaseRpcAsync(
            "discord_gm_set_combat_turn",
            new
            {
                p_campaign_id = campaignId,
                p_entity_type = (args.EntityType ?? string.Empty).Trim(),
                p_combatant_name = (args.CombatantName ?? string.Empty).Trim()
            },
            "Unable to set combat turn");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }

    private async Task<JsonElement> PositionCombatTokenAsync(Guid campaignId, PositionCombatTokenToolArguments args)
    {
        var entityType=(args.EntityType ?? string.Empty).Trim();
        var combatantName=(args.CombatantName ?? string.Empty).Trim();
        var destinationX=Math.Clamp(args.GridX,0,19);
        var destinationY=Math.Clamp(args.GridY,0,19);
        var reason=CleanReason(args.Reason,"Tactical positioning");
        var localMap=await GetLocalMapStateAsync(campaignId);
        var tactical=await GetTacticalCombatStateForGmAsync(campaignId);
        if(localMap is null || tactical is null || !tactical.Active)
            throw new InvalidOperationException("Tactical map state is not active.");

        var token=tactical.Tokens.FirstOrDefault(t =>
            t.EntityType.Equals(entityType,StringComparison.OrdinalIgnoreCase) &&
            t.DisplayName.Equals(combatantName,StringComparison.OrdinalIgnoreCase));
        if(token is null)
            throw new InvalidOperationException($"Tactical combatant was not found: {combatantName}");

        var cost=0;
        var teleport=reason.Contains("teleport",StringComparison.OrdinalIgnoreCase) ||
                     reason.Contains("dimension door",StringComparison.OrdinalIgnoreCase) ||
                     reason.Contains("misty step",StringComparison.OrdinalIgnoreCase);
        if(!teleport)
        {
            var doorStates=await GetTacticalDoorStatesForGmAsync(campaignId,localMap.LocationKey);
            var occupied=tactical.Tokens
                .Where(t => !t.Defeated && !ReferenceEquals(t,token))
                .Select(t => (t.GridX,t.GridY))
                .ToHashSet();
            var path=TacticalTerrainCatalog.FindPath(
                localMap.LocationKey,
                token.GridX,token.GridY,
                destinationX,destinationY,
                doorStates,occupied);
            if(!path.Success) throw new InvalidOperationException(path.Error);
            cost=path.CostFt;
        }

        var raw = await CallSupabaseRpcAsync(
            "discord_gm_position_combat_token_costed",
            new
            {
                p_campaign_id = campaignId,
                p_entity_type = entityType,
                p_combatant_name = combatantName,
                p_grid_x = destinationX,
                p_grid_y = destinationY,
                p_distance_ft = cost,
                p_reason = reason
            },
            "Unable to position combat token");
        using var document = JsonDocument.Parse(raw);
        return document.RootElement.Clone();
    }
    private async Task<Dictionary<int,bool>> GetTacticalDoorStatesForGmAsync(Guid campaignId,string locationKey)
    {
        var raw=await CallSupabaseRpcAsync(
            "discord_gm_get_tactical_door_states",
            new { p_campaign_id=campaignId,p_location_key=locationKey },
            "Unable to load tactical door state");
        var rows=JsonSerializer.Deserialize<List<TacticalDoorStateForGm>>(raw,JsonOptions) ?? new();
        return rows.ToDictionary(r=>r.DoorId,r=>r.IsOpen);
    }

    private async Task<object> CheckTacticalLineOfSightAsync(Guid campaignId,CheckTacticalLineOfSightArguments args)
    {
        var localMap=await GetLocalMapStateAsync(campaignId);
        var tactical=await GetTacticalCombatStateForGmAsync(campaignId);
        if(localMap is null || tactical is null || !tactical.Active)
            throw new InvalidOperationException("Tactical map state is not active.");
        var from=tactical.Tokens.FirstOrDefault(t=>t.DisplayName.Equals((args.FromCombatantName??string.Empty).Trim(),StringComparison.OrdinalIgnoreCase));
        var target=tactical.Tokens.FirstOrDefault(t=>t.DisplayName.Equals((args.ToCombatantName??string.Empty).Trim(),StringComparison.OrdinalIgnoreCase));
        if(from is null || target is null)
            throw new InvalidOperationException("Both tactical combatants must exist on the active map.");
        var doors=await GetTacticalDoorStatesForGmAsync(campaignId,localMap.LocationKey);
        var los=TacticalTerrainCatalog.CheckLineOfSight(localMap.LocationKey,from.GridX,from.GridY,target.GridX,target.GridY,doors);
        return new { authoritative=true,from=from.DisplayName,target=target.DisplayName,visible=los.Visible,cover=los.Cover,reason=los.Reason };
    }

    private async Task<JsonElement> SetTacticalDoorStateAsync(Guid campaignId,SetTacticalDoorStateArguments args)
    {
        var localMap=await GetLocalMapStateAsync(campaignId);
        var tactical=await GetTacticalCombatStateForGmAsync(campaignId);
        if(localMap is null || tactical is null || !tactical.Active)
            throw new InvalidOperationException("Tactical map state is not active.");
        var name=(args.CombatantName??string.Empty).Trim();
        var token=tactical.Tokens.FirstOrDefault(t=>t.DisplayName.Equals(name,StringComparison.OrdinalIgnoreCase));
        if(token is null) throw new InvalidOperationException($"Tactical combatant was not found: {name}");
        var door=TacticalTerrainCatalog.FindNearestDoor(localMap.LocationKey,token.GridX,token.GridY,2.75);
        if(door is null) throw new InvalidOperationException($"No marked tactical door is close enough to {name} to interact with.");
        var raw=await CallSupabaseRpcAsync(
            "discord_gm_set_tactical_door_state",
            new
            {
                p_campaign_id=campaignId,
                p_location_key=localMap.LocationKey,
                p_door_id=door.DoorId,
                p_is_open=args.Open,
                p_reason=CleanReason(args.Reason,args.Open?"Door opened":"Door closed")
            },
            "Unable to update tactical door state");
        using var document=JsonDocument.Parse(raw);
        return document.RootElement.Clone();
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

    private sealed class AlignmentDeedToolArguments
    {
        public string Direction { get; set; } = string.Empty;
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class AlignmentDeedToolResult
    {
        public string Alignment { get; set; } = string.Empty;
        public int AlignmentDeedBalance { get; set; }
        public int GoodDeeds { get; set; }
        public int EvilDeeds { get; set; }
        public bool Changed { get; set; }
        public string PreviousAlignment { get; set; } = string.Empty;
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

    private sealed class StartCombatToolArguments { public string Title { get; set; } = string.Empty; }
    private sealed class AddCombatMonsterToolArguments { public string MonsterName { get; set; } = string.Empty; public string DisplayName { get; set; } = string.Empty; public int Count { get; set; } public int MaxHp { get; set; } public int ArmorClass { get; set; } }
    private sealed class UpdateCombatMonsterToolArguments { public string DisplayName { get; set; } = string.Empty; public int HpDelta { get; set; } public string Conditions { get; set; } = string.Empty; public bool Defeated { get; set; } }
    private sealed class SetEnemyDispositionToolArguments { public string DisplayName { get; set; } = string.Empty; public string Disposition { get; set; } = string.Empty; public string Reason { get; set; } = string.Empty; }
    private sealed class MarkCharacterDeadToolArguments { public string CharacterName { get; set; } = string.Empty; public string Cause { get; set; } = string.Empty; }
    private sealed class ReviveCharacterToolArguments { public string CharacterName { get; set; } = string.Empty; public int HitPoints { get; set; } public string Reason { get; set; } = string.Empty; }
    private sealed class SetCombatRoundToolArguments { public int RoundNumber { get; set; } }
    private sealed class EndCombatToolArguments { public string Reason { get; set; } = string.Empty; }
    private sealed class CombatStateRowRaw { [System.Text.Json.Serialization.JsonPropertyName("active")] public bool Active { get; set; } [System.Text.Json.Serialization.JsonPropertyName("title")] public string Title { get; set; } = string.Empty; [System.Text.Json.Serialization.JsonPropertyName("round_number")] public int RoundNumber { get; set; } [System.Text.Json.Serialization.JsonPropertyName("monsters")] public JsonElement Monsters { get; set; } }
    private sealed class CombatMonsterForGm { [System.Text.Json.Serialization.JsonPropertyName("monster_name")] public string MonsterName { get; set; } = string.Empty; [System.Text.Json.Serialization.JsonPropertyName("display_name")] public string DisplayName { get; set; } = string.Empty; [System.Text.Json.Serialization.JsonPropertyName("current_hp")] public int CurrentHp { get; set; } [System.Text.Json.Serialization.JsonPropertyName("max_hp")] public int MaxHp { get; set; } [System.Text.Json.Serialization.JsonPropertyName("armor_class")] public int ArmorClass { get; set; } [System.Text.Json.Serialization.JsonPropertyName("conditions")] public string Conditions { get; set; } = string.Empty; [System.Text.Json.Serialization.JsonPropertyName("defeated")] public bool Defeated { get; set; } [System.Text.Json.Serialization.JsonPropertyName("disposition")] public string Disposition { get; set; } = "hostile"; [System.Text.Json.Serialization.JsonPropertyName("combat_ended")] public bool CombatEnded { get; set; } [System.Text.Json.Serialization.JsonPropertyName("end_reason")] public string EndReason { get; set; } = string.Empty; }
    private sealed record CombatStateForGm(bool Active,string Title,int RoundNumber,List<CombatMonsterForGm> Monsters);
    private sealed class CheckTacticalLineOfSightArguments
    {
        public string FromCombatantName { get; set; } = string.Empty;
        public string ToCombatantName { get; set; } = string.Empty;
    }

    private sealed class SetTacticalDoorStateArguments
    {
        public string CombatantName { get; set; } = string.Empty;
        public bool Open { get; set; }
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class TacticalDoorStateForGm
    {
        [System.Text.Json.Serialization.JsonPropertyName("door_id")] public int DoorId { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("is_open")] public bool IsOpen { get; set; }
    }
    private sealed class StageCombatTokensToolArguments
    {
        public string Reason { get; set; } = string.Empty;
        public bool PartyAllowDifficultTerrain { get; set; }
        public bool PartyAllowHalfCover { get; set; }
        public List<StageEngagementToolArguments> Engagements { get; set; } = new();
    }
    private sealed class StageEngagementToolArguments
    {
        public string CombatantName { get; set; } = string.Empty;
        public string TargetCharacterName { get; set; } = string.Empty;
        public int DistanceFeet { get; set; }
        public int MaximumRangeFeet { get; set; }
        public bool RequireLineOfSight { get; set; }
        public bool AllowDifficultTerrain { get; set; }
        public bool AllowHalfCover { get; set; }
        public string Reason { get; set; } = string.Empty;
    }
    private sealed class UpdateCharacterHpToolArguments
    {
        public string CharacterName { get; set; } = string.Empty;
        public int HpDelta { get; set; }
        public string Reason { get; set; } = string.Empty;
    }
    private sealed class AdvanceCombatTurnToolArguments { public string Reason { get; set; } = string.Empty; }
    private sealed class PartyCombatantForGm
    {
        [System.Text.Json.Serialization.JsonPropertyName("character_id")] public Guid CharacterId { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("character_name")] public string CharacterName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("class_name")] public string ClassName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("level")] public int Level { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("max_hp")] public int MaxHp { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("armor_class")] public int ArmorClass { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("strength")] public int Strength { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("dexterity")] public int Dexterity { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("constitution")] public int Constitution { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("intelligence")] public int Intelligence { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("wisdom")] public int Wisdom { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("charisma")] public int Charisma { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("proficiency_bonus")] public int ProficiencyBonus { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("speed")] public int Speed { get; set; }
    }
    private sealed class InitiativeCandidateForGm
    {
        [System.Text.Json.Serialization.JsonPropertyName("entity_type")] public string EntityType { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("character_id")] public Guid? CharacterId { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("combat_monster_id")] public Guid? CombatMonsterId { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("display_name")] public string DisplayName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("monster_name")] public string MonsterName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("initiative_modifier")] public int InitiativeModifier { get; set; }
    }
    private sealed class CombatInitiativeForGm
    {
        [System.Text.Json.Serialization.JsonPropertyName("order_position")] public int OrderPosition { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("entity_type")] public string EntityType { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("display_name")] public string DisplayName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("initiative_roll")] public int InitiativeRoll { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("initiative_modifier")] public int InitiativeModifier { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("initiative_total")] public int InitiativeTotal { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("is_current")] public bool IsCurrent { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("defeated")] public bool Defeated { get; set; }
    }
    private sealed record InitiativePersistEntry(string EntityType,Guid? CharacterId,Guid? CombatMonsterId,int InitiativeRoll,int InitiativeModifier,int InitiativeTotal);
    private sealed class CharacterHpResult
    {
        [System.Text.Json.Serialization.JsonPropertyName("character_name")] public string CharacterName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("max_hp")] public int MaxHp { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("reason")] public string Reason { get; set; } = string.Empty;
    }
    private sealed record CombatStagingPosition(Guid TokenId,string DisplayName,string EntityType,int GridX,int GridY,int DistanceFeet,string Note);
    private sealed record CombatStagingResult(int Positioned,string Reason,List<CombatStagingPosition> Positions);

    private sealed class SetCombatTurnToolArguments
    {
        public string EntityType { get; set; } = string.Empty;
        public string CombatantName { get; set; } = string.Empty;
    }

    private sealed class PositionCombatTokenToolArguments
    {
        public string EntityType { get; set; } = string.Empty;
        public string CombatantName { get; set; } = string.Empty;
        public int GridX { get; set; }
        public int GridY { get; set; }
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class TacticalCombatStateRowForGm
    {
        [System.Text.Json.Serialization.JsonPropertyName("active")] public bool Active { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("round_number")] public int RoundNumber { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("current_turn_type")] public string CurrentTurnType { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("current_turn_name")] public string CurrentTurnName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("tokens")] public JsonElement Tokens { get; set; }
    }

    private sealed class TacticalTokenForGm
    {
        [System.Text.Json.Serialization.JsonPropertyName("token_id")] public Guid TokenId { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("entity_type")] public string EntityType { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("character_id")] public Guid? CharacterId { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("combat_monster_id")] public Guid? CombatMonsterId { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("monster_name")] public string MonsterName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("display_name")] public string DisplayName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("grid_x")] public int GridX { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("grid_y")] public int GridY { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("movement_spent_ft")] public int MovementSpentFt { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("current_hp")] public int CurrentHp { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("max_hp")] public int MaxHp { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("armor_class")] public int ArmorClass { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("defeated")] public bool Defeated { get; set; }
    }

    private sealed record TacticalCombatForGm(
        bool Active,
        int RoundNumber,
        string CurrentTurnType,
        string CurrentTurnName,
        List<TacticalTokenForGm> Tokens);
    private sealed class CompleteQuestToolArguments
    {
        public string QuestName { get; set; } = string.Empty;
        public string Difficulty { get; set; } = "side";
    }

    private sealed class CompleteShortRestToolArguments
    {
        public string[] CharacterNames { get; set; } = Array.Empty<string>();
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class ShortRestResult
    {
        [System.Text.Json.Serialization.JsonPropertyName("characterName")] public string CharacterName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("status")] public string Status { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("currentHp")] public int CurrentHp { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("maxHp")] public int MaxHp { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("hitDieSides")] public int HitDieSides { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("hitDiceTotal")] public int HitDiceTotal { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("hitDiceAvailable")] public int HitDiceAvailable { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("reason")] public string Reason { get; set; } = string.Empty;
    }

    private sealed class CompleteLongRestToolArguments
    {
        public string[] CharacterNames { get; set; } = Array.Empty<string>();
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class LongRestResult
    {
        [System.Text.Json.Serialization.JsonPropertyName("characterId")] public Guid CharacterId { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("characterName")] public string CharacterName { get; set; } = string.Empty;
        [System.Text.Json.Serialization.JsonPropertyName("leveledUp")] public bool LeveledUp { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("fromLevel")] public int FromLevel { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("toLevel")] public int ToLevel { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("experience")] public int Experience { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("hpGain")] public int HpGain { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("maxHp")] public int MaxHp { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("proficiencyBonus")] public int ProficiencyBonus { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("spellSelectionRequired")] public bool SpellSelectionRequired { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("spellReviewAvailable")] public bool SpellReviewAvailable { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("hitDiceRestored")] public int HitDiceRestored { get; set; }
        [System.Text.Json.Serialization.JsonPropertyName("reason")] public string Reason { get; set; } = string.Empty;
    }

    private sealed class SetEncounterMapToolArguments
    {
        public bool Active { get; set; }
        public string Reason { get; set; } = string.Empty;
    }

    private sealed class LocalMapStateRow
    {
        [System.Text.Json.Serialization.JsonPropertyName("current_location")]
        public string CurrentLocation { get; set; } = string.Empty;

        [System.Text.Json.Serialization.JsonPropertyName("location_key")]
        public string LocationKey { get; set; } = string.Empty;

        [System.Text.Json.Serialization.JsonPropertyName("encounter_active")]
        public bool EncounterActive { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("encounter_location_key")]
        public string? EncounterLocationKey { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("encounter_reason")]
        public string EncounterReason { get; set; } = string.Empty;
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
