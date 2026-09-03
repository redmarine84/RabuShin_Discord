using System.Text.Json;
using QuestsOfRabuShinAIGM;

// Render containers can share a low Linux inotify-instance allowance. The
// default ASP.NET configuration builder otherwise creates file-system watchers
// before the application reaches builder.Build(), which can terminate startup
// with IOException/status 139. RabuShin reads production configuration from
// environment variables, so live appsettings reload is unnecessary here.
Environment.SetEnvironmentVariable("DOTNET_HOSTBUILDER__RELOADCONFIGONCHANGE", "false");
Environment.SetEnvironmentVariable("DOTNET_USE_POLLING_FILE_WATCHER", "1");

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHttpClient<DiscordSupabaseService>();
builder.Services.AddHttpClient<DiscordOAuthService>();
builder.Services.AddHttpClient<OpenAiGameMasterService>();
builder.Services.AddSingleton<ApiKeyEncryptionService>();
builder.Services.AddSingleton<CampaignCanonService>();
var port = Environment.GetEnvironmentVariable("PORT") ?? "3002";
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");

var app = builder.Build();

// In production, the built Vite Activity is copied into wwwroot by Docker.
// These calls are harmless during local development when wwwroot is absent.
app.UseDefaultFiles();
app.UseStaticFiles();

app.MapGet("/api/health", () => Results.Ok(new
{
    success = true,
    server = "RabuShin Discord OAuth",
    productionHost = true
}));

app.MapPost("/api/token", async (
    DiscordTokenRequest body,
    DiscordOAuthService oauth) =>
{
    try
    {
        if (string.IsNullOrWhiteSpace(body.Code))
            return Results.BadRequest(new { success = false, error = "No Discord authorization code was supplied." });

        var token = await oauth.ExchangeCodeAsync(body.Code);
        return Results.Ok(new { access_token = token });
    }
    catch (DiscordOAuthException ex)
    {
        return Results.Json(new
        {
            success = false,
            error = ex.ErrorCode,
            error_description = ex.Message
        }, statusCode: ex.StatusCode);
    }
    catch (Exception ex)
    {
        return Results.Json(new
        {
            success = false,
            error = "oauth_server_error",
            error_description = ex.Message
        }, statusCode: 500);
    }
});

app.MapGet("/game-api/health", () => Results.Ok(new
{
    success = true,
    game = "RabuShinAIGM",
    version = "Discord Completion Package",
    server = "ASP.NET Core",
    gameEngine = "VB.NET",
    message = "RabuShin Discord server is running."
}));

app.MapGet("/game-api/campaigns", async (HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var campaigns = await service.GetCampaignsAsync(playerId);
        return Results.Ok(new
        {
            success = true,
            campaigns = campaigns.Select(c => new
            {
                campaignId = c.CampaignId, campaignName = c.CampaignName, joinCode = c.JoinCode,
                currentChapter = c.CurrentChapter, currentLocation = c.CurrentLocation,
                isOwner = c.IsOwner, memberCount = c.MemberCount
            })
        });
    }
    catch (UnauthorizedAccessException ex) { return Results.Json(new { success = false, error = ex.Message }, statusCode: 401); }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns", async (HttpRequest request, CreateDiscordCampaignRequest body, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var id = await service.CreateCampaignAsync(playerId, body.CampaignName);
        return Results.Ok(new { success = true, campaignId = id });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/join", async (HttpRequest request, JoinDiscordCampaignRequest body, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var id = await service.JoinCampaignAsync(playerId, body.JoinCode);
        return Results.Ok(new { success = true, campaignId = id });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapDelete("/game-api/campaigns/{campaignId:guid}", async (Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        await service.DeleteCampaignAsync(playerId, campaignId);
        return Results.Ok(new { success = true, message = "Campaign deleted." });
    }
    catch (UnauthorizedAccessException ex)
    {
        return Results.Json(new { success = false, error = ex.Message }, statusCode: 401);
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/leave", async (Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        await service.LeaveCampaignAsync(playerId, campaignId);
        return Results.Ok(new { success = true, message = "You left the campaign." });
    }
    catch (UnauthorizedAccessException ex)
    {
        return Results.Json(new { success = false, error = ex.Message }, statusCode: 401);
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapGet("/game-api/character-options", () => Results.Ok(new
{
    success = true,
    species = CharacterFeatureRules.WithTortleSpecies(CharacterGenerationService.Species),
    baseSpecies = CharacterFeatureRules.WithTortleBaseSpecies(CharacterGenerationService.BaseSpecies),
    classes = CharacterGenerationService.Classes,
    backgrounds = CharacterGenerationService.Backgrounds,
    alignments = CharacterFeatureRules.AlignmentLadder,
    racialRules = CharacterFeatureRules.GetClientRules()
}));

app.MapGet("/game-api/campaigns/{campaignId:guid}/character", async (Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var character = await service.GetCharacterAsync(playerId, campaignId);
        return character is null
            ? Results.Ok(new { success = true, hasCharacter = false })
            : Results.Ok(new { success = true, hasCharacter = true, character = ProgramHelpers.ToClientCharacter(character) });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/character/features", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var state = await service.GetCharacterFeatureStateAsync(playerId, campaignId);
        if (state is null) return Results.NotFound(new { success = false, error = "Character details could not be found." });
        return Results.Ok(new
        {
            success = true,
            characterId = state.CharacterId,
            background = state.BackgroundName,
            alignment = state.Alignment,
            alignmentDeedBalance = state.AlignmentDeedBalance,
            goodDeeds = state.AlignmentGoodDeeds,
            evilDeeds = state.AlignmentEvilDeeds,
            secondaryHeritage = state.SecondaryHeritage,
            appearance = state.Appearance,
            personality = state.Personality,
            backstory = state.Backstory,
            notes = state.Notes,
            racialTraits = state.RacialTraits
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPut("/game-api/campaigns/{campaignId:guid}/character/details", async (
    Guid campaignId, CharacterDetailsUpdateRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        await service.UpdateCharacterDetailsAsync(playerId, campaignId, body.Background, body.Appearance, body.Personality, body.Backstory, body.Notes);
        return Results.Ok(new { success = true });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/progression", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var character = await service.GetCharacterAsync(playerId, campaignId);
        if (character is null) return Results.NotFound(new { success = false, error = "Character could not be found." });
        var levelUp = await service.GetLevelUpStateAsync(playerId, campaignId);
        return Results.Ok(new { success = true, progression = ExperienceProgression.BuildClientProgression(character, levelUp) });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/rest-state", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var rest = await service.GetRestStateAsync(playerId, campaignId);
        return Results.Ok(new { success = true, rest });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/rest/short/hit-die", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var result = await service.SpendShortRestHitDieAsync(playerId, campaignId);
        return Results.Ok(new { success = true, result });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/rest/short/finish", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var result = await service.FinishShortRestAsync(playerId, campaignId);
        return Results.Ok(new { success = true, result });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/rest/long/review", async (
    Guid campaignId, RestSpellReviewRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var result = await service.FinishLongRestSpellReviewAsync(playerId, campaignId, body.ReviewSpells);
        return Results.Ok(new { success = true, result });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/level-up/choices", async (
    Guid campaignId, LevelUpChoicesRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var character = await service.GetCharacterAsync(playerId, campaignId);
        if (character is null) return Results.NotFound(new { success = false, error = "Character could not be found." });
        var levelUp = await service.GetLevelUpStateAsync(playerId, campaignId);
        if (levelUp is null || !levelUp.Pending)
            return Results.Conflict(new { success = false, error = "No post-rest level-up choices are waiting for this character." });

        var choices = body.Choices.ValueKind == JsonValueKind.Object ? body.Choices : JsonSerializer.Deserialize<JsonElement>("{}");
        var prompts = ExperienceProgression.GetAbilityChoicePrompts(character.ClassName, levelUp.FromLevel, levelUp.ToLevel);
        foreach (var prompt in prompts.Where(p => !p.Optional))
        {
            if (!choices.TryGetProperty(prompt.Key, out var value) || string.IsNullOrWhiteSpace(value.GetString()))
                return Results.BadRequest(new { success = false, error = $"Choose or record your {prompt.Label} before finishing the level up." });
        }

        await service.SaveLevelUpChoicesAsync(playerId, campaignId, choices);
        return Results.Ok(new
        {
            success = true,
            fromLevel = levelUp.FromLevel,
            toLevel = levelUp.ToLevel,
            needsSpellSelection = DiscordSpellService.IsSupportedCaster(character.ClassName)
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/characters/random", async (
    Guid campaignId, EnhancedRandomCharacterRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        if (await service.GetCharacterAsync(playerId, campaignId) is not null)
            return Results.BadRequest(new { success = false, error = "You already have a character in this campaign." });

        var validSpecies = CharacterFeatureRules.WithTortleSpecies(CharacterGenerationService.Species);
        var species = validSpecies.FirstOrDefault(v => v.Equals(body.Species, StringComparison.OrdinalIgnoreCase));
        var className = CharacterGenerationService.Classes.FirstOrDefault(v => v.Equals(body.ClassName, StringComparison.OrdinalIgnoreCase));
        if (species is null) return Results.BadRequest(new { success = false, error = "Invalid species." });
        if (className is null) return Results.BadRequest(new { success = false, error = "Invalid class." });

        var engineSpecies = CharacterFeatureRules.EngineSpecies(species, CharacterGenerationService.Species);
        var generated = new CharacterGenerationService().Generate(engineSpecies, className, 1, body.CharacterName ?? "");

        AppliedRacialScores scores;
        if (CharacterFeatureRules.IsTortleLineage(species))
        {
            // Tortle is not part of the older generation engine. Human is used only as a stat-roll shell;
            // the classic Human +1s are removed before applying the player's Tortle choices.
            scores = CharacterFeatureRules.ApplyAbilityScores(
                species,
                Math.Max(1, generated.Strength - 1), Math.Max(1, generated.Dexterity - 1), Math.Max(1, generated.Constitution - 1),
                Math.Max(1, generated.Intelligence - 1), Math.Max(1, generated.Wisdom - 1), Math.Max(1, generated.Charisma - 1),
                body.RacialAbilityChoices);
        }
        else
        {
            scores = new AppliedRacialScores(generated.Strength, generated.Dexterity, generated.Constitution,
                generated.Intelligence, generated.Wisdom, generated.Charisma,
                new Dictionary<string, int>());
        }

        var profile = CharacterFeatureRules.BuildProfile(species, body.SecondaryHeritage, scores,
            body.TortleSize, body.TortleNatureSkill, body.TortleLanguage);
        var id = await service.CreateCharacterWithFeaturesAsync(playerId, campaignId, generated, species, scores, profile,
            string.Empty, string.Empty, string.Empty, string.Empty);
        var saved = await service.GetCharacterAsync(playerId, campaignId);
        return Results.Ok(new { success = true, character = saved is null ? ProgramHelpers.ToClientGeneratedCharacter(id, generated) : ProgramHelpers.ToClientCharacter(saved) });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/characters/manual", async (
    Guid campaignId, EnhancedManualCharacterRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        if (await service.GetCharacterAsync(playerId, campaignId) is not null)
            return Results.BadRequest(new { success = false, error = "You already have a character in this campaign." });

        var validSpecies = CharacterFeatureRules.WithTortleSpecies(CharacterGenerationService.Species);
        var species = validSpecies.FirstOrDefault(v => v.Equals(body.Species, StringComparison.OrdinalIgnoreCase));
        if (species is null) return Results.BadRequest(new { success = false, error = "Invalid species." });

        var scores = CharacterFeatureRules.ApplyAbilityScores(
            species, body.Strength, body.Dexterity, body.Constitution, body.Intelligence, body.Wisdom, body.Charisma,
            body.RacialAbilityChoices);
        var profile = CharacterFeatureRules.BuildProfile(species, body.SecondaryHeritage, scores,
            body.TortleSize, body.TortleNatureSkill, body.TortleLanguage);

        var engineSpecies = CharacterFeatureRules.EngineSpecies(species, CharacterGenerationService.Species);
        var character = ManualCharacterCreationService.Create(
            body.CharacterName, engineSpecies, body.SecondaryHeritage ?? "", body.ClassName,
            body.Background, body.Alignment, body.Level,
            scores.Strength, scores.Dexterity, scores.Constitution, scores.Intelligence, scores.Wisdom, scores.Charisma,
            body.Appearance ?? "", body.Personality ?? "", body.Backstory ?? "", body.Notes ?? "");

        var id = await service.CreateCharacterWithFeaturesAsync(playerId, campaignId, character, species, scores, profile,
            body.Appearance ?? "", body.Personality ?? "", body.Backstory ?? "", body.Notes ?? "");
        var saved = await service.GetCharacterAsync(playerId, campaignId);
        return Results.Ok(new { success = true, character = saved is null ? ProgramHelpers.ToClientGeneratedCharacter(id, character) : ProgramHelpers.ToClientCharacter(saved) });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/character/portrait", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        if (!request.HasFormContentType)
            return Results.BadRequest(new { success = false, error = "Upload the portrait as multipart form data." });

        var form = await request.ReadFormAsync(request.HttpContext.RequestAborted);
        var file = form.Files.GetFile("portrait");
        if (file is null)
            return Results.BadRequest(new { success = false, error = "Choose a portrait image first." });

        await CharacterPortraitFileValidator.ValidateAsync(file, request.HttpContext.RequestAborted);
        await using var stream = file.OpenReadStream();
        await service.UploadCharacterPortraitAsync(playerId, campaignId, stream, file.ContentType);
        return Results.Ok(new { success = true, message = "Character portrait saved." });
    }
    catch (UnauthorizedAccessException ex) { return Results.Json(new { success = false, error = ex.Message }, statusCode: 401); }
    catch (ArgumentException ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapDelete("/game-api/campaigns/{campaignId:guid}/character/portrait", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        await service.ClearCharacterPortraitAsync(playerId, campaignId);
        return Results.Ok(new { success = true, message = "Character portrait removed." });
    }
    catch (UnauthorizedAccessException ex) { return Results.Json(new { success = false, error = ex.Message }, statusCode: 401); }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/characters/{characterId:guid}/portrait", async (
    Guid campaignId, Guid characterId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var portrait = await service.GetPartyPortraitAsync(playerId, campaignId, characterId);
        return portrait is null
            ? Results.NotFound(new { success = false, error = "This character does not have a portrait." })
            : Results.File(portrait.Bytes, portrait.ContentType, enableRangeProcessing: false);
    }
    catch (UnauthorizedAccessException ex) { return Results.Json(new { success = false, error = ex.Message }, statusCode: 403); }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/party", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var party = await service.GetPartyAsync(playerId, campaignId);
        return Results.Ok(new { success = true, party = party.Select(ProgramHelpers.ToClientPartyMember) });
    }
    catch (UnauthorizedAccessException ex) { return Results.Json(new { success = false, error = ex.Message }, statusCode: 401); }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/character/setup", async (Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var state = await service.GetCharacterSetupStateAsync(playerId, campaignId);
        return state is null
            ? Results.NotFound(new { success = false, error = "Character could not be found." })
            : Results.Ok(new { success = true, characterId = state.CharacterId, equipmentComplete = state.EquipmentComplete, spellsComplete = state.SpellsComplete });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/starting-equipment", async (Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var character = await service.GetCharacterAsync(playerId, campaignId);
        if (character is null) return Results.NotFound(new { success = false, error = "Character could not be found." });
        var classPackages = StartingEquipmentService.GetClassPackages(character.ClassName);
        var backgroundPackages = StartingEquipmentService.GetBackgroundPackages(character.BackgroundName);
        return Results.Ok(new
        {
            success = true,
            className = character.ClassName,
            backgroundName = character.BackgroundName,
            classPackages = classPackages.Select((p, i) => ProgramHelpers.MapEquipmentPackage(p, i)),
            backgroundPackages = backgroundPackages.Select((p, i) => ProgramHelpers.MapEquipmentPackage(p, i))
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/starting-equipment", async (
    Guid campaignId, StartingEquipmentSelectionRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var character = await service.GetCharacterAsync(playerId, campaignId);
        if (character is null) return Results.NotFound(new { success = false, error = "Character could not be found." });

        var classPackages = StartingEquipmentService.GetClassPackages(character.ClassName);
        var backgroundPackages = StartingEquipmentService.GetBackgroundPackages(character.BackgroundName);
        if (body.ClassPackageIndex < 0 || body.ClassPackageIndex >= classPackages.Count)
            return Results.BadRequest(new { success = false, error = "Invalid class equipment package." });
        if (body.BackgroundPackageIndex < 0 || body.BackgroundPackageIndex >= backgroundPackages.Count)
            return Results.BadRequest(new { success = false, error = "Invalid background equipment package." });

        var classPackage = classPackages[body.ClassPackageIndex];
        var backgroundPackage = backgroundPackages[body.BackgroundPackageIndex];
        var classChoice = ProgramHelpers.ResolveEquipmentChoice(classPackage, body.ClassChoice);
        var backgroundChoice = ProgramHelpers.ResolveEquipmentChoice(backgroundPackage, body.BackgroundChoice);
        var items = new List<DiscordStartingInventoryItem>();

        foreach (var entry in StartingEquipmentService.ResolveItems(classPackage, classChoice))
            items.Add(new DiscordStartingInventoryItem { ItemName = entry.ItemName, Quantity = entry.Quantity,
                Equipped = StartingEquipmentService.ShouldStartEquipped(entry.ItemName), SourceName = "Class", Notes = "2024 class starting equipment" });
        foreach (var entry in StartingEquipmentService.ResolveItems(backgroundPackage, backgroundChoice))
            items.Add(new DiscordStartingInventoryItem { ItemName = entry.ItemName, Quantity = entry.Quantity,
                Equipped = StartingEquipmentService.ShouldStartEquipped(entry.ItemName), SourceName = "Background", Notes = "2024 background starting equipment" });

        var gold = classPackage.Gold + backgroundPackage.Gold;
        await service.SaveStartingEquipmentAsync(playerId, campaignId, gold, items);
        return Results.Ok(new { success = true, gold, itemCount = items.Sum(i => i.Quantity) });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/spell-options", async (Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var character = await service.GetCharacterAsync(playerId, campaignId);
        if (character is null) return Results.NotFound(new { success = false, error = "Character could not be found." });

        if (!DiscordSpellService.IsSupportedCaster(character.ClassName))
            return Results.Ok(new { success = true, required = false, className = character.ClassName });

        var progression = DiscordSpellService.GetProgression(character.ClassName, character.Level);
        var available = DiscordSpellService.GetAvailableSpells(character.ClassName, character.Level);
        var existingSpells = await service.GetSpellsAsync(playerId, campaignId);
        object MapSpell(SrdSpellReference s) => new
        {
            name = s.Name, level = s.Level, school = s.School, castingTime = s.CastingTime,
            range = s.Range, components = s.Components, duration = s.Duration, description = s.Description
        };
        return Results.Ok(new
        {
            success = true,
            required = true,
            className = character.ClassName,
            level = character.Level,
            progression = new
            {
                cantripsKnown = progression.CantripsKnown,
                preparedSpells = progression.PreparedSpells,
                maxSpellLevel = progression.MaxSpellLevel,
                wizardSpellbookCount = progression.WizardSpellbookCount,
                spellSlots = progression.SpellSlots,
                warlockArcanumLevels = progression.WarlockArcanumLevels
            },
            alwaysPrepared = DiscordSpellService.GetBaseAlwaysPreparedSpellNames(character.ClassName, character.Level),
            existingSpells = existingSpells.Select(s => new
            {
                name = s.SpellName, level = s.SpellLevel, prepared = s.Prepared, sourceTag = s.SourceTag
            }),
            cantrips = available.Where(s => s.Level == 0).Select(MapSpell),
            spells = available.Where(s => s.Level > 0).Select(MapSpell)
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/spell-selection", async (
    Guid campaignId, SpellSelectionRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var character = await service.GetCharacterAsync(playerId, campaignId);
        if (character is null) return Results.NotFound(new { success = false, error = "Character could not be found." });

        if (!DiscordSpellService.IsSupportedCaster(character.ClassName))
        {
            await service.SaveSpellsAsync(playerId, campaignId, new(), new());
            return Results.Ok(new { success = true, spellCount = 0, slotCount = 0 });
        }

        var progression = DiscordSpellService.GetProgression(character.ClassName, character.Level);
        var available = DiscordSpellService.GetAvailableSpells(character.ClassName, character.Level);
        var cantripNames = ProgramHelpers.CleanDistinct(body.Cantrips);
        var spellNames = ProgramHelpers.CleanDistinct(body.Spells);
        var preparedWizard = ProgramHelpers.CleanDistinct(body.PreparedWizardSpells);

        if (cantripNames.Count != progression.CantripsKnown)
            return Results.BadRequest(new { success = false, error = $"Choose exactly {progression.CantripsKnown} cantrip(s)." });

        var saved = new List<DiscordSpellSaveItem>();
        foreach (var name in cantripNames)
        {
            var reference = ProgramHelpers.FindSpell(available.Where(s => s.Level == 0), name);
            saved.Add(ProgramHelpers.SpellSaveItem(reference, true, "Cantrip"));
        }

        if (character.ClassName.Equals("Wizard", StringComparison.OrdinalIgnoreCase))
        {
            if (spellNames.Count != progression.WizardSpellbookCount)
                return Results.BadRequest(new { success = false, error = $"Choose exactly {progression.WizardSpellbookCount} spellbook spell(s)." });
            if (preparedWizard.Count != progression.PreparedSpells)
                return Results.BadRequest(new { success = false, error = $"Prepare exactly {progression.PreparedSpells} spell(s) from the spellbook." });
            if (preparedWizard.Any(p => !spellNames.Contains(p, StringComparer.OrdinalIgnoreCase)))
                return Results.BadRequest(new { success = false, error = "Prepared Wizard spells must also be in your spellbook." });

            foreach (var name in spellNames)
            {
                var reference = ProgramHelpers.FindSpell(available.Where(s => s.Level > 0), name);
                saved.Add(ProgramHelpers.SpellSaveItem(reference, preparedWizard.Contains(name, StringComparer.OrdinalIgnoreCase), "Spellbook"));
            }
        }
        else
        {
            if (spellNames.Count != progression.PreparedSpells)
                return Results.BadRequest(new { success = false, error = $"Choose exactly {progression.PreparedSpells} class spell(s)." });
            foreach (var name in spellNames)
            {
                var reference = ProgramHelpers.FindSpell(available.Where(s => s.Level > 0), name);
                saved.Add(ProgramHelpers.SpellSaveItem(reference, true, "Class"));
            }
        }

        foreach (var name in DiscordSpellService.GetBaseAlwaysPreparedSpellNames(character.ClassName, character.Level))
        {
            if (saved.Any(s => s.SpellName.Equals(name, StringComparison.OrdinalIgnoreCase))) continue;
            var reference = available.FirstOrDefault(s => s.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
            if (reference is not null) saved.Add(ProgramHelpers.SpellSaveItem(reference, true, "ClassGranted"));
        }

        foreach (var requiredLevel in progression.WarlockArcanumLevels)
        {
            if (body.MysticArcanum is null || !body.MysticArcanum.TryGetValue(requiredLevel, out var name) || string.IsNullOrWhiteSpace(name))
                return Results.BadRequest(new { success = false, error = $"Choose one level {requiredLevel} Mystic Arcanum spell." });
            var reference = ProgramHelpers.FindSpell(available.Where(s => s.Level == requiredLevel), name);
            saved.Add(ProgramHelpers.SpellSaveItem(reference, true, "MysticArcanum"));
        }

        var slots = progression.SpellSlots.Select(p => new DiscordSpellSlotSaveItem { SpellLevel = p.Key, MaxSlots = p.Value }).ToList();
        await service.SaveSpellsAsync(playerId, campaignId, saved, slots);
        return Results.Ok(new { success = true, spellCount = saved.Count, slotCount = slots.Count });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/bootstrap", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        await service.TouchCampaignPresenceAsync(playerId, campaignId);
        await service.SkipOfflineCurrentCombatTurnAsync(campaignId);
        var campaigns = await service.GetCampaignsAsync(playerId);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null) return Results.NotFound(new { success = false, error = "Campaign could not be found." });
        var character = await service.GetCharacterAsync(playerId, campaignId);
        if (character is null) return Results.NotFound(new { success = false, error = "Character could not be found." });

        var party = await service.GetPartyAsync(playerId, campaignId);
        var inventory = await service.GetInventoryAsync(playerId, campaignId);
        var spells = await service.GetSpellsAsync(playerId, campaignId);
        var slots = await service.GetSpellSlotsAsync(playerId, campaignId);
        var gm = await service.GetMessagesAsync(playerId, campaignId, "gm", 100);
        var chat = await service.GetMessagesAsync(playerId, campaignId, "chat", 100);
        var journal = await service.GetJournalAsync(playerId, campaignId);
        var survival = await service.GetSurvivalStateAsync(playerId, campaignId);
        var encumbrance = ItemPhysicalProfileService.CalculateEncumbrance(character.Strength, inventory);

        return Results.Ok(new
        {
            success = true,
            campaign = new { campaignId = campaign.CampaignId, campaignName = campaign.CampaignName, joinCode = campaign.JoinCode,
                currentChapter = campaign.CurrentChapter, currentLocation = campaign.CurrentLocation, isOwner = campaign.IsOwner, memberCount = campaign.MemberCount },
            character = ProgramHelpers.ToClientCharacter(character, party.Any(p => p.CharacterId == character.CharacterId && !string.IsNullOrWhiteSpace(p.PortraitPath))),
            party = party.Select(ProgramHelpers.ToClientPartyMember),
            inventory = inventory.Select(InventoryPresentationService.ToClientItem),
            inventoryValuations = inventory.Select(ItemValuationService.ToClientValuation),
            spells = spells.Select(s => new { characterSpellId=s.CharacterSpellId,spellName=s.SpellName,spellLevel=s.SpellLevel,prepared=s.Prepared,sourceTag=s.SourceTag,spellData=s.SpellData }),
            spellSlots = slots.Select(s => new { spellLevel=s.SpellLevel,maxSlots=s.MaxSlots,usedSlots=s.UsedSlots }),
            gmMessages = gm.Select(m => new { messageId=m.MessageId,roleName=m.RoleName,senderName=m.SenderName,messageText=m.MessageText,createdAt=m.CreatedAt }),
            chatMessages = chat.Select(m => new { messageId=m.MessageId,roleName=m.RoleName,senderName=m.SenderName,messageText=m.MessageText,createdAt=m.CreatedAt }),
            journal = journal.Select(j => new { journalId=j.JournalId,category=j.Category,title=j.Title,entryText=j.EntryText,createdAt=j.CreatedAt }),
            survival,
            encumbrance = new
            {
                carriedWeightLb = encumbrance.CarriedWeightLb,
                capacityLb = encumbrance.CapacityLb,
                remainingCapacityLb = encumbrance.RemainingCapacityLb,
                percent = encumbrance.Percent,
                overCapacity = encumbrance.OverCapacity
            },
            openAiConfigured = await service.HasStoredOpenAiKeyAsync(playerId)
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

// RULES BUILD 6.8 - SURVIVAL SETTINGS / STATE
app.MapGet("/game-api/campaigns/{campaignId:guid}/survival", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var state = await service.GetSurvivalStateAsync(playerId, campaignId);
        if (state is null) return Results.NotFound(new { success = false, error = "Survival state could not be found." });

        var character = await service.GetCharacterAsync(playerId, campaignId);
        if (character is null) return Results.NotFound(new { success = false, error = "Character could not be found." });
        var inventory = await service.GetInventoryAsync(playerId, campaignId);
        var encumbrance = ItemPhysicalProfileService.CalculateEncumbrance(character.Strength, inventory);

        return Results.Ok(new
        {
            success = true,
            survival = state,
            encumbrance = new
            {
                carriedWeightLb = encumbrance.CarriedWeightLb,
                capacityLb = encumbrance.CapacityLb,
                remainingCapacityLb = encumbrance.RemainingCapacityLb,
                percent = encumbrance.Percent,
                overCapacity = encumbrance.OverCapacity
            }
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/settings/survival", async (
    Guid campaignId, SurvivalSettingsRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var campaigns = await service.GetCampaignsAsync(playerId);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null) return Results.NotFound(new { success = false, error = "Campaign could not be found." });
        if (!campaign.IsOwner) return Results.Json(new { success = false, error = "Only the campaign owner can change Hunger and Thirst rules." }, statusCode: 403);

        var state = await service.SetSurvivalEnabledAsync(playerId, campaignId, body.Enabled);
        return Results.Ok(new
        {
            success = true,
            survival = state,
            message = body.Enabled
                ? "Hunger and Thirst survival rules are ON."
                : "Hunger and Thirst survival rules are OFF. Survival time is paused."
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

// VISUALS BUILD 2 - WORLD MAP ENDPOINT
app.MapGet("/game-api/campaigns/{campaignId:guid}/world-map", async (
    Guid campaignId,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var campaigns = await service.GetCampaignsAsync(playerId);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null)
            return Results.NotFound(new { success = false, error = "Campaign could not be found." });

        var state = await service.GetWorldMapStateAsync(playerId, campaignId);
        var byKey = state.ToDictionary(s => s.LocationKey, StringComparer.OrdinalIgnoreCase);

        var locations = WorldMapCatalog.Locations.Select((location, index) =>
        {
            byKey.TryGetValue(location.Key, out var mapState);
            var discovered = mapState?.Discovered == true;
            var current = mapState?.IsCurrent == true;

            return new
            {
                id = $"world-{index}",
                name = discovered ? location.Name : null,
                locationKey = discovered ? location.Key : null,
                x = location.X,
                y = location.Y,
                width = location.Width,
                height = location.Height,
                discovered,
                current
            };
        });

        return Results.Ok(new
        {
            success = true,
            imageUrl = WorldMapCatalog.ImageUrl,
            imageWidth = WorldMapCatalog.ImageWidth,
            imageHeight = WorldMapCatalog.ImageHeight,
            currentLocation = campaign.CurrentLocation,
            locations
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});
// VISUALS BUILD 3 - LOCAL MAP ENDPOINT
// VISUALS BUILD 5.1 - TACTICAL TERRAIN ENDPOINTS
app.MapPost("/game-api/campaigns/{campaignId:guid}/combat/tactical/move51", async (
    Guid campaignId,
    TacticalMoveRequest move,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var campaigns = await service.GetCampaignsAsync(playerId);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId)
            ?? throw new InvalidOperationException("Campaign could not be found.");
        var mapDefinition = LocalMapCatalog.FindByLocation(campaign.CurrentLocation)
            ?? throw new InvalidOperationException("The current location does not have a tactical terrain definition.");

        var state = await service.GetTacticalCombatStateAsync(playerId, campaignId)
            ?? throw new InvalidOperationException("Tactical combat state could not be found.");
        if (!state.Active)
            throw new InvalidOperationException("There is no active tactical combat.");

        var tokens = state.Tokens.ValueKind == JsonValueKind.Array
            ? JsonSerializer.Deserialize<List<DiscordTacticalTokenInfo>>(
                state.Tokens.GetRawText(),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new()
            : new List<DiscordTacticalTokenInfo>();

        if (!state.ViewerCharacterId.HasValue)
            throw new InvalidOperationException("Your campaign character could not be found.");

        var ownToken = tokens.FirstOrDefault(t => t.CharacterId == state.ViewerCharacterId)
            ?? throw new InvalidOperationException("Your tactical token could not be found.");

        var doorRows = await service.GetTacticalDoorStatesAsync(playerId, campaignId, mapDefinition.LocationKey);
        var doorStates = doorRows.ToDictionary(d => d.DoorId, d => d.IsOpen);
        var occupied = tokens
            .Where(t => t.TokenId != ownToken.TokenId && !t.Defeated)
            .Select(t => (t.GridX, t.GridY))
            .ToHashSet();

        var path = TacticalTerrainCatalog.FindPath(
            mapDefinition.LocationKey,
            ownToken.GridX,
            ownToken.GridY,
            move.GridX,
            move.GridY,
            doorStates,
            occupied);

        if (!path.Success)
            return Results.BadRequest(new { success = false, error = path.Error });

        var result = await service.MoveOwnCombatTokenCostedAsync(
            playerId,
            campaignId,
            move.GridX,
            move.GridY,
            path.CostFt);

        return Results.Ok(new
        {
            success = true,
            move = new
            {
                tokenId = result.TokenId,
                gridX = result.GridX,
                gridY = result.GridY,
                moveCostFt = result.MoveCostFt,
                movementSpentFt = result.MovementSpentFt,
                movementRemainingFt = result.MovementRemainingFt
            },
            usesDifficultTerrain = path.UsesDifficultTerrain,
            path = path.Path.Select(p => new { gridX = p.X, gridY = p.Y })
        });
    }
    catch (UnauthorizedAccessException)
    {
        return Results.Unauthorized();
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/combat/tactical/los", async (
    Guid campaignId,
    Guid fromTokenId,
    Guid toTokenId,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var campaigns = await service.GetCampaignsAsync(playerId);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId)
            ?? throw new InvalidOperationException("Campaign could not be found.");
        var mapDefinition = LocalMapCatalog.FindByLocation(campaign.CurrentLocation)
            ?? throw new InvalidOperationException("The current location does not have a tactical terrain definition.");
        var state = await service.GetTacticalCombatStateAsync(playerId, campaignId)
            ?? throw new InvalidOperationException("Tactical combat state could not be found.");

        var tokens = state.Tokens.ValueKind == JsonValueKind.Array
            ? JsonSerializer.Deserialize<List<DiscordTacticalTokenInfo>>(
                state.Tokens.GetRawText(),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new()
            : new List<DiscordTacticalTokenInfo>();
        var from = tokens.FirstOrDefault(t => t.TokenId == fromTokenId)
            ?? throw new InvalidOperationException("The source combat token could not be found.");
        var to = tokens.FirstOrDefault(t => t.TokenId == toTokenId)
            ?? throw new InvalidOperationException("The target combat token could not be found.");

        var doorRows = await service.GetTacticalDoorStatesAsync(playerId, campaignId, mapDefinition.LocationKey);
        var doorStates = doorRows.ToDictionary(d => d.DoorId, d => d.IsOpen);
        var los = TacticalTerrainCatalog.CheckLineOfSight(
            mapDefinition.LocationKey,
            from.GridX,
            from.GridY,
            to.GridX,
            to.GridY,
            doorStates);

        return Results.Ok(new
        {
            success = true,
            visible = los.Visible,
            cover = los.Cover,
            reason = los.Reason,
            from = from.DisplayName,
            target = to.DisplayName
        });
    }
    catch (UnauthorizedAccessException)
    {
        return Results.Unauthorized();
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});
// VISUALS BUILD 5 - TACTICAL COMBAT ENDPOINTS
app.MapGet("/game-api/campaigns/{campaignId:guid}/combat/tactical", async (
    Guid campaignId,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var state = await service.GetTacticalCombatStateAsync(playerId, campaignId);
        if (state is null)
            return Results.Ok(new { success = true, active = false, gridColumns = 20, gridRows = 20, feetPerSquare = 5, tokens = Array.Empty<object>() });

        var tokens = state.Tokens.ValueKind == JsonValueKind.Array
            ? JsonSerializer.Deserialize<List<DiscordTacticalTokenInfo>>(
                state.Tokens.GetRawText(),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new()
            : new List<DiscordTacticalTokenInfo>();

        var canMove = state.Active &&
                      state.ViewerCharacterId.HasValue &&
                      state.CurrentTurnType.Equals("character", StringComparison.OrdinalIgnoreCase) &&
                      state.CurrentTurnCharacterId == state.ViewerCharacterId;

        // BUILD 5 FIX - BROWSER TACTICAL TOKEN JSON
        // The model uses snake_case JsonPropertyName attributes for Supabase input.
        // Explicitly project to camelCase for client/main.js.
        var clientTokens = tokens.Select(token => new
        {
            tokenId = token.TokenId,
            entityType = token.EntityType,
            characterId = token.CharacterId,
            combatMonsterId = token.CombatMonsterId,
            displayName = token.DisplayName,
            monsterName = token.MonsterName,
            gridX = token.GridX,
            gridY = token.GridY,
            movementSpentFt = token.MovementSpentFt,
            speedFt = token.SpeedFt,
            currentHp = token.CurrentHp,
            maxHp = token.MaxHp,
            armorClass = token.ArmorClass,
            defeated = token.Defeated,
            hasPortrait = token.HasPortrait
        }).ToList();

        return Results.Ok(new
        {
            success = true,
            active = state.Active,
            roundNumber = Math.Max(1, state.RoundNumber),
            gridColumns = 20,
            gridRows = 20,
            feetPerSquare = 5,
            currentTurnType = state.CurrentTurnType,
            currentTurnCharacterId = state.CurrentTurnCharacterId,
            currentTurnMonsterId = state.CurrentTurnMonsterId,
            currentTurnName = state.CurrentTurnName,
            viewerCharacterId = state.ViewerCharacterId,
            viewerSpeed = Math.Max(0, state.ViewerSpeed),
            viewerMovementRemaining = Math.Max(0, state.ViewerMovementRemaining),
            canMove,
            tokens = clientTokens
        });
    }
    catch (UnauthorizedAccessException ex)
    {
        return Results.Unauthorized();
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/combat/tactical/move", async (
    Guid campaignId,
    TacticalMoveRequest move,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var result = await service.MoveOwnCombatTokenAsync(playerId, campaignId, move.GridX, move.GridY);
        // BUILD 5 FIX - BROWSER TACTICAL MOVE JSON
        return Results.Ok(new
        {
            success = true,
            move = new
            {
                tokenId = result.TokenId,
                gridX = result.GridX,
                gridY = result.GridY,
                moveCostFt = result.MoveCostFt,
                movementSpentFt = result.MovementSpentFt,
                movementRemainingFt = result.MovementRemainingFt
            }
        });
    }
    catch (UnauthorizedAccessException)
    {
        return Results.Unauthorized();
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});
// VISUALS BUILD 4 - COMBAT ENDPOINT
app.MapGet("/game-api/campaigns/{campaignId:guid}/combat", async (
    Guid campaignId,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var state = await service.GetCombatStateAsync(playerId, campaignId);
        var monsters = new List<DiscordCombatMonsterInfo>();
        if (state is not null && state.Monsters.ValueKind == JsonValueKind.Array)
            monsters = JsonSerializer.Deserialize<List<DiscordCombatMonsterInfo>>(state.Monsters.GetRawText(), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new();

        var codex = MonsterCodexService.Shared;
        return Results.Ok(new
        {
            success = true,
            active = state?.Active == true,
            title = state?.Title ?? string.Empty,
            roundNumber = Math.Max(1, state?.RoundNumber ?? 1),
            startedAt = state?.StartedAt,
            monsters = monsters.Select(m =>
            {
                var entry = codex.Find(m.MonsterName);
                var imageUrl = entry?.ImageUrl ?? codex.FindImageUrl(m.MonsterName);
                return new
                {
                    combatMonsterId = m.CombatMonsterId,
                    monsterName = m.MonsterName,
                    displayName = m.DisplayName,
                    currentHp = m.CurrentHp,
                    maxHp = m.MaxHp,
                    armorClass = m.ArmorClass,
                    conditions = m.Conditions,
                    defeated = m.Defeated,
                    imageUrl,
                    subtitle = entry?.Subtitle ?? "Creature",
                    challengeRating = entry?.ChallengeRating ?? string.Empty,
                    statBlock = entry?.Details ?? "No Codex stat block is available for this creature.",
                    source = entry?.Source ?? "Combat state"
                };
            })
        });
    }
    catch(Exception ex){ return Results.BadRequest(new { success=false,error=ex.Message }); }
});
app.MapGet("/game-api/campaigns/{campaignId:guid}/local-maps", async (
    Guid campaignId,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var campaigns = await service.GetCampaignsAsync(playerId);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null)
            return Results.NotFound(new { success = false, error = "Campaign could not be found." });

        var definition = LocalMapCatalog.FindByLocation(campaign.CurrentLocation);
        var settlement = SettlementInteractionCatalog.FindByLocation(campaign.CurrentLocation);
        var state = await service.GetLocalMapStateAsync(playerId, campaignId);
        var viewerLocation = await service.GetPlayerSettlementLocationAsync(playerId, campaignId);
        if (viewerLocation is not null && settlement is not null &&
            !viewerLocation.SettlementKey.Equals(settlement.SettlementKey, StringComparison.OrdinalIgnoreCase))
            viewerLocation = null;

        object? settlementMap = null;
        object? encounterMap = null;

        if (definition is not null)
        {
            settlementMap = new
            {
                available = true,
                interactive = settlement is not null,
                locationKey = definition.LocationKey,
                settlementKey = settlement?.SettlementKey ?? string.Empty,
                name = $"{definition.LocationName} Settlement Map",
                imageUrl = definition.SettlementImageUrl,
                imageWidth = definition.SettlementImageWidth,
                imageHeight = definition.SettlementImageHeight,
                viewerPoiKey = viewerLocation?.PoiKey ?? string.Empty,
                viewerPoiName = viewerLocation?.PoiName ?? string.Empty,
                pois = settlement is null
                    ? Array.Empty<object>()
                    : settlement.Pois.Select(p => (object)new
                    {
                        poiKey = p.PoiKey,
                        name = p.Name,
                        kind = p.Kind,
                        isShop = p.IsShop,
                        shopKind = p.ShopKind ?? string.Empty,
                        hotspots = p.Hotspots.Select(h => new { x = h.X, y = h.Y, width = h.Width, height = h.Height })
                    }).ToArray()
            };

            var encounterActive = state?.EncounterActive == true &&
                string.Equals(state.EncounterLocationKey, definition.LocationKey, StringComparison.OrdinalIgnoreCase);

            encounterMap = new
            {
                available = encounterActive,
                active = encounterActive,
                locationKey = definition.LocationKey,
                name = $"{definition.LocationName} Encounter Map",
                imageUrl = encounterActive ? definition.EncounterImageUrl : null,
                imageWidth = definition.EncounterImageWidth,
                imageHeight = definition.EncounterImageHeight,
                reason = encounterActive ? state?.EncounterReason : null
            };
        }

        return Results.Ok(new
        {
            success = true,
            currentLocation = campaign.CurrentLocation,
            personalLocation = viewerLocation is null ? null : new
            {
                settlementKey = viewerLocation.SettlementKey,
                poiKey = viewerLocation.PoiKey,
                poiName = viewerLocation.PoiName
            },
            settlementMap,
            encounterMap
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/settlement/move", async (
    Guid campaignId, SettlementMoveRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        await service.TouchCampaignPresenceAsync(playerId, campaignId);

        var deathState = await service.GetDeathStateAsync(playerId, campaignId);
        if (deathState?.ViewerIsDeadPlayer == true)
            return Results.Conflict(new { success = false, error = "A dead character cannot travel around the settlement until death is resolved." });

        var combat = await service.GetTacticalCombatStateAsync(playerId, campaignId);
        if (combat?.Active == true)
            return Results.Conflict(new { success = false, error = "Settlement-map movement is unavailable during active combat." });

        var campaigns = await service.GetCampaignsAsync(playerId);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null)
            return Results.NotFound(new { success = false, error = "Campaign could not be found." });

        var settlement = SettlementInteractionCatalog.FindByLocation(campaign.CurrentLocation);
        if (settlement is null)
            return Results.BadRequest(new { success = false, error = "This campaign location does not have an interactive settlement map." });

        var poi = settlement.Pois.FirstOrDefault(p => p.PoiKey.Equals((body.PoiKey ?? string.Empty).Trim(), StringComparison.OrdinalIgnoreCase));
        if (poi is null)
            return Results.BadRequest(new { success = false, error = "That settlement location could not be found." });

        var moved = await service.MovePlayerSettlementLocationAsync(playerId, campaignId, settlement.SettlementKey, poi.PoiKey, poi.Name);
        return Results.Ok(new
        {
            success = true,
            settlementKey = settlement.SettlementKey,
            settlementName = settlement.SettlementName,
            poiKey = moved?.PoiKey ?? poi.PoiKey,
            poiName = moved?.PoiName ?? poi.Name,
            kind = poi.Kind,
            isShop = poi.IsShop,
            shopKind = poi.ShopKind ?? string.Empty
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/settlement/shop", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var campaigns = await service.GetCampaignsAsync(playerId);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null)
            return Results.NotFound(new { success = false, error = "Campaign could not be found." });

        var settlement = SettlementInteractionCatalog.FindByLocation(campaign.CurrentLocation);
        var location = await service.GetPlayerSettlementLocationAsync(playerId, campaignId);
        if (settlement is null || location is null ||
            !location.SettlementKey.Equals(settlement.SettlementKey, StringComparison.OrdinalIgnoreCase))
            return Results.BadRequest(new { success = false, error = "Move to a shop on the Settlement Map first." });

        var poi = settlement.Pois.FirstOrDefault(p => p.PoiKey.Equals(location.PoiKey, StringComparison.OrdinalIgnoreCase));
        if (poi is null || !poi.IsShop)
            return Results.BadRequest(new { success = false, error = "Your character is not currently at a shop." });

        var character = await service.GetCharacterAsync(playerId, campaignId);
        if (character is null)
            return Results.NotFound(new { success = false, error = "Character could not be found." });

        var items = SettlementInteractionCatalog.GetShopItems(campaignId, settlement, poi);
        var inventory = await service.GetInventoryAsync(playerId, campaignId);
        var sellItems = inventory.Select(i =>
        {
            var offer = SettlementInteractionCatalog.GetSellOffer(poi, i);
            var reason = i.Valuation?.Priceless == true
                ? "This is an Artifact or protected campaign item. It is priceless and cannot be sold."
                : offer is null
                    ? "This merchant does not buy this item category."
                    : i.Equipped
                    ? "Unequip this item before selling it."
                    : i.Attuned
                        ? "Unattune this item before selling it."
                        : string.Empty;
            return new
            {
                inventoryItemId = i.InventoryItemId,
                itemName = i.ItemName,
                quantity = i.Quantity,
                equipped = i.Equipped,
                attuned = i.Attuned,
                canSell = offer is not null && !i.Equipped && !i.Attuned && i.Quantity > 0,
                category = offer?.Category ?? (i.Valuation?.Category ?? string.Empty),
                rarity = offer?.Rarity ?? (i.Valuation?.Rarity ?? "Common"),
                baseValueGp = offer?.BaseValueGp ?? (i.Valuation?.BaseValueGp ?? 0m),
                unitPriceGp = offer?.UnitPriceGp ?? 0m,
                priceBand = i.Valuation?.PriceBand ?? string.Empty,
                reason
            };
        }).ToList();

        return Results.Ok(new
        {
            success = true,
            settlementName = settlement.SettlementName,
            poiKey = poi.PoiKey,
            shopName = poi.Name,
            shopKind = poi.ShopKind ?? string.Empty,
            gold = character.Gold,
            items = items.Select(i => new
            {
                itemKey = i.ItemKey,
                itemName = i.ItemName,
                category = i.Category,
                rarity = i.Rarity,
                valueClass = i.ValueClass,
                baseValueGp = i.PriceGp,
                priceGp = i.PriceGp,
                description = i.Description
            }),
            sellItems
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/settlement/shop/buy", async (
    Guid campaignId, SettlementShopPurchaseRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var quantity = Math.Clamp(body.Quantity, 1, 20);
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var campaigns = await service.GetCampaignsAsync(playerId);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null)
            return Results.NotFound(new { success = false, error = "Campaign could not be found." });

        var settlement = SettlementInteractionCatalog.FindByLocation(campaign.CurrentLocation);
        var location = await service.GetPlayerSettlementLocationAsync(playerId, campaignId);
        if (settlement is null || location is null ||
            !location.SettlementKey.Equals(settlement.SettlementKey, StringComparison.OrdinalIgnoreCase))
            return Results.BadRequest(new { success = false, error = "Move to a shop on the Settlement Map first." });

        var poi = settlement.Pois.FirstOrDefault(p => p.PoiKey.Equals(location.PoiKey, StringComparison.OrdinalIgnoreCase));
        if (poi is null || !poi.IsShop)
            return Results.BadRequest(new { success = false, error = "Your character is not currently at a shop." });

        var items = SettlementInteractionCatalog.GetShopItems(campaignId, settlement, poi);
        var item = items.FirstOrDefault(i => i.ItemKey.Equals((body.ItemKey ?? string.Empty).Trim(), StringComparison.OrdinalIgnoreCase));
        if (item is null)
            return Results.BadRequest(new { success = false, error = "That item is not sold by this shop." });

        var result = await service.BuySettlementShopItemAsync(
            playerId, campaignId, settlement.SettlementKey, poi.PoiKey, item, quantity, poi.Name);

        return Results.Ok(new
        {
            success = result.Success,
            shopName = poi.Name,
            itemKey = item.ItemKey,
            itemName = result.ItemName,
            quantityPurchased = result.QuantityPurchased,
            quantityCarried = result.QuantityCarried,
            unitPriceGp = result.UnitPriceGp,
            totalPriceGp = result.TotalPriceGp,
            remainingGold = result.RemainingGold
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/settlement/shop/sell", async (
    Guid campaignId, SettlementShopSaleRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var campaigns = await service.GetCampaignsAsync(playerId);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null)
            return Results.NotFound(new { success = false, error = "Campaign could not be found." });

        var settlement = SettlementInteractionCatalog.FindByLocation(campaign.CurrentLocation);
        var location = await service.GetPlayerSettlementLocationAsync(playerId, campaignId);
        if (settlement is null || location is null ||
            !location.SettlementKey.Equals(settlement.SettlementKey, StringComparison.OrdinalIgnoreCase))
            return Results.BadRequest(new { success = false, error = "Move to a shop on the Settlement Map first." });

        var poi = settlement.Pois.FirstOrDefault(p => p.PoiKey.Equals(location.PoiKey, StringComparison.OrdinalIgnoreCase));
        if (poi is null || !poi.IsShop)
            return Results.BadRequest(new { success = false, error = "Your character is not currently at a shop." });

        var inventory = await service.GetInventoryAsync(playerId, campaignId);
        var item = inventory.FirstOrDefault(i => i.InventoryItemId == body.InventoryItemId);
        if (item is null)
            return Results.NotFound(new { success = false, error = "Inventory item could not be found." });
        if (item.Equipped)
            return Results.BadRequest(new { success = false, error = "Unequip this item before selling it." });
        if (item.Attuned)
            return Results.BadRequest(new { success = false, error = "Unattune this item before selling it." });
        var quantity = body.Quantity;
        if (quantity < 1 || quantity > item.Quantity)
            return Results.BadRequest(new { success = false, error = $"Sell quantity must be between 1 and {item.Quantity}." });

        var offer = SettlementInteractionCatalog.GetSellOffer(poi, item);
        if (offer is null)
            return Results.BadRequest(new { success = false, error = "This merchant does not buy that item or it has no defined shop value." });

        var result = await service.SellSettlementShopItemAsync(
            playerId, campaignId, settlement.SettlementKey, poi.PoiKey,
            item.InventoryItemId, item.ItemName, quantity, offer.UnitPriceGp, poi.Name);

        return Results.Ok(new
        {
            success = result.Success,
            shopName = poi.Name,
            inventoryItemId = item.InventoryItemId,
            itemName = result.ItemName,
            quantitySold = result.QuantitySold,
            quantityRemaining = result.QuantityRemaining,
            rarity = offer.Rarity,
            category = offer.Category,
            baseValueGp = offer.BaseValueGp,
            unitPriceGp = result.UnitPriceGp,
            totalPriceGp = result.TotalPriceGp,
            remainingGold = result.RemainingGold
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/inventory", async (
    Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var character = await service.GetCharacterAsync(playerId, campaignId);
        if (character is null) return Results.NotFound(new { success = false, error = "Character could not be found." });

        var inventory = await service.GetInventoryAsync(playerId, campaignId);
        var encumbrance = ItemPhysicalProfileService.CalculateEncumbrance(character.Strength, inventory);
        return Results.Ok(new
        {
            success = true,
            gold = character.Gold,
            inventory = inventory.Select(InventoryPresentationService.ToClientItem),
            inventoryValuations = inventory.Select(ItemValuationService.ToClientValuation),
            encumbrance = new
            {
                carriedWeightLb = encumbrance.CarriedWeightLb,
                capacityLb = encumbrance.CapacityLb,
                remainingCapacityLb = encumbrance.RemainingCapacityLb,
                percent = encumbrance.Percent,
                overCapacity = encumbrance.OverCapacity
            }
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/inventory/{inventoryItemId:guid}/equip", async (
    Guid campaignId, Guid inventoryItemId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var inventory = await service.GetInventoryAsync(playerId, campaignId);
        var item = inventory.FirstOrDefault(i => i.InventoryItemId == inventoryItemId);
        if (item is null) return Results.NotFound(new { success = false, error = "Inventory item could not be found." });

        var presentation = InventoryPresentationService.ToClientItem(item);
        if (!presentation.CanEquip)
            return Results.BadRequest(new { success = false, error = "Only armor, armor pieces, weapons, shields, and clothing can be equipped." });

        var newState = !item.Equipped;
        await service.SetInventoryEquippedAsync(playerId, campaignId, inventoryItemId, newState);
        return Results.Ok(new
        {
            success = true,
            inventoryItemId,
            itemName = item.ItemName,
            equipped = newState,
            message = newState ? $"Equipped {item.ItemName}." : $"Unequipped {item.ItemName}."
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/inventory/{inventoryItemId:guid}/drop", async (
    Guid campaignId, Guid inventoryItemId, InventoryQuantityRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var inventory = await service.GetInventoryAsync(playerId, campaignId);
        var item = inventory.FirstOrDefault(i => i.InventoryItemId == inventoryItemId);
        if (item is null) return Results.NotFound(new { success = false, error = "Inventory item could not be found." });

        var quantity = body.Quantity;
        if (quantity < 1 || quantity > item.Quantity)
            return Results.BadRequest(new { success = false, error = $"Drop quantity must be between 1 and {item.Quantity}." });

        var remaining = await service.RemoveInventoryQuantityAsync(playerId, campaignId, inventoryItemId, quantity);
        return Results.Ok(new
        {
            success = true,
            inventoryItemId,
            itemName = item.ItemName,
            dropped = quantity,
            remaining,
            message = $"Dropped {quantity} × {item.ItemName}."
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/inventory/{inventoryItemId:guid}/use", async (
    Guid campaignId, Guid inventoryItemId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        var inventory = await service.GetInventoryAsync(playerId, campaignId);
        var item = inventory.FirstOrDefault(i => i.InventoryItemId == inventoryItemId);
        if (item is null) return Results.NotFound(new { success = false, error = "Inventory item could not be found." });

        var presentation = InventoryPresentationService.ToClientItem(item);
        if (!presentation.CanUse)
            return Results.BadRequest(new { success = false, error = "This item is not a consumable item and cannot be used from the inventory." });

        var remaining = await service.RemoveInventoryQuantityAsync(playerId, campaignId, inventoryItemId, 1);
        return Results.Ok(new
        {
            success = true,
            inventoryItemId,
            itemName = item.ItemName,
            used = 1,
            remaining,
            gmPrefill = $"I use {item.ItemName}",
            message = $"Used 1 × {item.ItemName}."
        });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/chat", async (Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user=await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString()); var player=await service.GetOrCreatePlayerAsync(user);
        await service.TouchCampaignPresenceAsync(player,campaignId);
        await service.SkipOfflineCurrentCombatTurnAsync(campaignId);
        var messages=await service.GetMessagesAsync(player,campaignId,"chat",150);
        return Results.Ok(new { success=true, messages=messages.Select(m=>new {messageId=m.MessageId,roleName=m.RoleName,senderName=m.SenderName,messageText=m.MessageText,createdAt=m.CreatedAt})});
    }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/chat", async (Guid campaignId, CampaignMessageRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user=await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString()); var player=await service.GetOrCreatePlayerAsync(user);
        await service.TouchCampaignPresenceAsync(player,campaignId);
        var name=user.GlobalName??user.Username; var id=await service.AddMessageAsync(player,campaignId,"chat","user",name,body.Message);
        return Results.Ok(new {success=true,messageId=id});
    }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/journal", async (Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user=await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString()); var player=await service.GetOrCreatePlayerAsync(user);
        var entries=await service.GetJournalAsync(player,campaignId);
        return Results.Ok(new {success=true,entries=entries.Select(j=>new {journalId=j.JournalId,category=j.Category,title=j.Title,entryText=j.EntryText,createdAt=j.CreatedAt})});
    }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/journal", async (Guid campaignId, JournalRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user=await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString()); var player=await service.GetOrCreatePlayerAsync(user);
        var id=await service.AddJournalAsync(player,campaignId,body.Category,body.Title,body.EntryText);
        return Results.Ok(new {success=true,journalId=id});
    }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.MapGet("/game-api/settings/openai", async (HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player = await service.GetOrCreatePlayerAsync(user);
        var stored = await service.GetStoredOpenAiKeyAsync(player);
        return Results.Ok(new
        {
            success = true,
            configured = stored is not null && !string.IsNullOrWhiteSpace(stored.EncryptedValue),
            persisted = true,
            updatedAt = stored?.UpdatedAt
        });
    }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.MapPost("/game-api/settings/openai", async (
    OpenAiKeyRequest body,
    HttpRequest request,
    DiscordSupabaseService service,
    OpenAiGameMasterService ai,
    ApiKeyEncryptionService encryption) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player = await service.GetOrCreatePlayerAsync(user);
        if (string.IsNullOrWhiteSpace(body.ApiKey))
            return Results.BadRequest(new { success=false, error="OpenAI API key is required." });

        await ai.TestApiKeyAsync(body.ApiKey.Trim());
        var encrypted = encryption.Encrypt(body.ApiKey.Trim());
        await service.SaveStoredOpenAiKeyAsync(player, encrypted);

        return Results.Ok(new
        {
            success = true,
            configured = true,
            persisted = true,
            message = "OpenAI API key tested successfully and saved encrypted for your Discord account."
        });
    }
    catch(OpenAiUsageException ex){ return Results.Json(new {success=false,error=ex.Message,usageIssue=true},statusCode:429); }
    catch(OpenAiConfigurationException ex){ return Results.BadRequest(new {success=false,error=ex.Message,needsApiKey=true}); }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.MapDelete("/game-api/settings/openai", async (HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player = await service.GetOrCreatePlayerAsync(user);
        await service.ClearStoredOpenAiKeyAsync(player);
        return Results.Ok(new {success=true,configured=false});
    }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.MapGet("/game-api/campaigns/{campaignId:guid}/gm", async (Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player = await service.GetOrCreatePlayerAsync(user);
        await service.TouchCampaignPresenceAsync(player, campaignId);
        await service.SkipOfflineCurrentCombatTurnAsync(campaignId);
        var messages = await service.GetMessagesAsync(player, campaignId, "gm", 150);
        var turnState = await service.GetGmTurnStateAsync(player, campaignId);
        var tactical = await service.GetTacticalCombatStateAsync(player, campaignId);
        var initiative = tactical?.Active == true
            ? await service.GetCombatInitiativeAsync(player, campaignId)
            : new List<CombatInitiativeRow>();
        // RULES BUILD 6.7.1 - INTERRUPTED COMBAT SETUP RECOVERY
        var combatSetupPending = tactical?.Active == true &&
            string.IsNullOrWhiteSpace(tactical.CurrentTurnType) &&
            !tactical.CurrentTurnCharacterId.HasValue &&
            !tactical.CurrentTurnMonsterId.HasValue &&
            initiative.Count == 0;
        var combatCanAct = tactical?.Active != true || combatSetupPending ||
            (tactical.ViewerCharacterId.HasValue &&
             tactical.CurrentTurnType.Equals("character", StringComparison.OrdinalIgnoreCase) &&
             tactical.CurrentTurnCharacterId == tactical.ViewerCharacterId);

        return Results.Ok(new
        {
            success = true,
            messages = messages.Select(m => new
            {
                messageId = m.MessageId,
                roleName = m.RoleName,
                senderName = m.SenderName,
                messageText = m.MessageText,
                createdAt = m.CreatedAt
            }),
            turnState = new
            {
                active = turnState.Active,
                processing = turnState.Processing,
                isOwner = turnState.IsOwner,
                ownerPlayerId = turnState.OwnerPlayerId,
                ownerName = turnState.OwnerName,
                lockToken = turnState.IsOwner ? turnState.LockToken : null,
                remainingSeconds = turnState.RemainingSeconds,
                expiresAt = turnState.ExpiresAt
            },
            combatTurn = new
            {
                active = tactical?.Active == true,
                roundNumber = Math.Max(1, tactical?.RoundNumber ?? 1),
                currentTurnType = tactical?.CurrentTurnType ?? string.Empty,
                currentTurnCharacterId = tactical?.CurrentTurnCharacterId,
                currentTurnMonsterId = tactical?.CurrentTurnMonsterId,
                currentTurnName = tactical?.CurrentTurnName ?? string.Empty,
                viewerCharacterId = tactical?.ViewerCharacterId,
                canAct = combatCanAct,
                initiative = initiative.Select(i => new
                {
                    orderPosition = i.OrderPosition,
                    entityType = i.EntityType,
                    characterId = i.CharacterId,
                    combatMonsterId = i.CombatMonsterId,
                    displayName = i.DisplayName,
                    initiativeRoll = i.InitiativeRoll,
                    initiativeModifier = i.InitiativeModifier,
                    initiativeTotal = i.InitiativeTotal,
                    isCurrent = i.IsCurrent,
                    defeated = i.Defeated
                })
            }
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

// RULES BUILD 6.2 - SERVER-AUTHORITATIVE DEATH / RESPAWN WORKFLOW
app.MapGet("/game-api/campaigns/{campaignId:guid}/death-state", async (
    Guid campaignId,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player = await service.GetOrCreatePlayerAsync(user);
        await service.TouchCampaignPresenceAsync(player, campaignId);
        await service.SkipOfflineCurrentCombatTurnAsync(campaignId);
        var death = await service.GetDeathStateAsync(player, campaignId);
        return Results.Ok(new { success = true, death });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/death/choice", async (
    Guid campaignId,
    RespawnChoiceRequest body,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player = await service.GetOrCreatePlayerAsync(user);
        var result = await service.ChooseRespawnAsync(player, campaignId, body.Respawn);

        var characterName = string.IsNullOrWhiteSpace(result.CharacterName) ? "A party member" : result.CharacterName;
        if (result.Outcome.Equals("awaiting_donations", StringComparison.OrdinalIgnoreCase))
        {
            await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM",
                $"{characterName} has died and does not have enough gold to respawn. Do you want to donate GP to revive them? 10 GP needed for revival.");
        }
        else if (result.Outcome.Equals("self_paid_respawn", StringComparison.OrdinalIgnoreCase))
        {
            await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM",
                $"{characterName} paid 10 GP for Respawn and returns at half health.");
        }
        else if (result.Outcome.Equals("rag_respawn", StringComparison.OrdinalIgnoreCase))
        {
            await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM",
                $"The party could not fund {characterName}'s Respawn. {characterName} returns at half health wearing only Cloth Rags; all carried items and GP were lost.");
        }
        else if (result.Outcome.Equals("new_character", StringComparison.OrdinalIgnoreCase))
        {
            await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM",
                $"{characterName} will not Respawn. That character's story has ended, and the player will create a new character to replace them in this campaign.");
        }

        return Results.Ok(new { success = true, result });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/death/{deathId:guid}/donate", async (
    Guid campaignId,
    Guid deathId,
    RespawnDonationRequest body,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player = await service.GetOrCreatePlayerAsync(user);
        var result = await service.DonateToRespawnAsync(player, campaignId, deathId, body.AmountGp);

        if (result.Outcome.Equals("donated", StringComparison.OrdinalIgnoreCase))
        {
            var donor = string.IsNullOrWhiteSpace(result.DonorCharacterName) ? (user.GlobalName ?? user.Username) : result.DonorCharacterName;
            await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM",
                $"{donor} donated {result.DonatedNow} GP to the Respawn fund. {result.RemainingGp} GP still needed.");
        }
        else if (result.Outcome.Equals("rag_respawn", StringComparison.OrdinalIgnoreCase))
        {
            var name = string.IsNullOrWhiteSpace(result.CharacterName) ? "The fallen party member" : result.CharacterName;
            await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM",
                $"The party could not fund {name}'s Respawn. {name} returns at half health wearing only Cloth Rags; all carried items and GP were lost.");
        }

        return Results.Ok(new { success = true, result });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/death/{deathId:guid}/decline", async (
    Guid campaignId,
    Guid deathId,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player = await service.GetOrCreatePlayerAsync(user);
        var result = await service.DeclineRespawnDonationAsync(player, campaignId, deathId);
        if (result.Outcome.Equals("rag_respawn", StringComparison.OrdinalIgnoreCase))
        {
            var name = string.IsNullOrWhiteSpace(result.CharacterName) ? "The fallen party member" : result.CharacterName;
            await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM",
                $"No viable 10 GP party Respawn fund remains for {name}. {name} returns at half health wearing only Cloth Rags; all carried items and GP were lost.");
        }
        return Results.Ok(new { success = true, result });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/death/{deathId:guid}/revive", async (
    Guid campaignId,
    Guid deathId,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player = await service.GetOrCreatePlayerAsync(user);
        var result = await service.FinalizePartyRespawnAsync(player, campaignId, deathId);
        var name = string.IsNullOrWhiteSpace(result.CharacterName) ? "The fallen party member" : result.CharacterName;
        await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM",
            $"The party completed the 10 GP Respawn fund. {name} returns at half health.");
        return Results.Ok(new { success = true, result });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/gm/turn/acquire", async (
    Guid campaignId,
    HttpRequest request,
    DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player = await service.GetOrCreatePlayerAsync(user);
        await service.TouchCampaignPresenceAsync(player, campaignId);
        await service.SkipOfflineCurrentCombatTurnAsync(campaignId);
        var deathState = await service.GetDeathStateAsync(player, campaignId);
        if (deathState?.ViewerIsDeadPlayer == true)
            return Results.Conflict(new { success = false, error = "Your character is dead. Resolve the Respawn screen before taking another Game Master action.", deadCharacter = true });
        var tactical = await service.GetTacticalCombatStateAsync(player, campaignId);
        var setupInitiative = tactical?.Active == true && string.IsNullOrWhiteSpace(tactical.CurrentTurnType)
            ? await service.GetCombatInitiativeAsync(player, campaignId)
            : new List<CombatInitiativeRow>();
        var combatSetupPending = tactical?.Active == true &&
            string.IsNullOrWhiteSpace(tactical.CurrentTurnType) &&
            !tactical.CurrentTurnCharacterId.HasValue &&
            !tactical.CurrentTurnMonsterId.HasValue &&
            setupInitiative.Count == 0;
        if (tactical?.Active == true && !combatSetupPending &&
            !(tactical.ViewerCharacterId.HasValue &&
              tactical.CurrentTurnType.Equals("character", StringComparison.OrdinalIgnoreCase) &&
              tactical.CurrentTurnCharacterId == tactical.ViewerCharacterId))
        {
            return Results.Conflict(new
            {
                success = false,
                error = string.IsNullOrWhiteSpace(tactical.CurrentTurnName)
                    ? "Combat initiative is active. Wait for your character's turn."
                    : $"Combat initiative is active. It is {tactical.CurrentTurnName}'s turn.",
                combatLocked = true,
                currentTurnName = tactical.CurrentTurnName
            });
        }

        var playerName = user.GlobalName ?? user.Username;
        var turnState = await service.AcquireGmTurnAsync(player, campaignId, playerName);
        return Results.Ok(new
        {
            success = true,
            turnState = new
            {
                active = turnState.Active,
                processing = turnState.Processing,
                isOwner = turnState.IsOwner,
                ownerPlayerId = turnState.OwnerPlayerId,
                ownerName = turnState.OwnerName,
                lockToken = turnState.IsOwner ? turnState.LockToken : null,
                remainingSeconds = turnState.RemainingSeconds,
                expiresAt = turnState.ExpiresAt
            }
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
});

// COMBAT BUILD 6.1 - PLAYER END TURN / AUTOMATIC CONSECUTIVE ENEMY TURNS
app.MapPost("/game-api/campaigns/{campaignId:guid}/combat/end-turn", async (
    Guid campaignId,
    HttpRequest request,
    DiscordSupabaseService service,
    OpenAiGameMasterService ai,
    ApiKeyEncryptionService encryption) =>
{
    Guid player = Guid.Empty;
    Guid turnToken = Guid.Empty;
    var processingLeaseStarted = false;
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        player = await service.GetOrCreatePlayerAsync(user);
        await service.TouchCampaignPresenceAsync(player, campaignId);
        await service.SkipOfflineCurrentCombatTurnAsync(campaignId);
        var character = await service.GetCharacterAsync(player, campaignId);
        if (character is null)
            return Results.NotFound(new { success = false, error = "Character could not be found." });
        var deathState = await service.GetDeathStateAsync(player, campaignId);
        if (deathState?.ViewerIsDeadPlayer == true)
            return Results.Conflict(new { success = false, error = "Your character is dead. Resolve the Respawn screen before ending another turn.", deadCharacter = true });

        var tactical = await service.GetTacticalCombatStateAsync(player, campaignId);
        if (tactical?.Active != true)
            return Results.Conflict(new { success = false, error = "There is no active combat turn to end.", combatLocked = true });
        if (!tactical.ViewerCharacterId.HasValue ||
            !tactical.CurrentTurnType.Equals("character", StringComparison.OrdinalIgnoreCase) ||
            tactical.CurrentTurnCharacterId != tactical.ViewerCharacterId)
            return Results.Conflict(new { success = false, error = $"It is {tactical.CurrentTurnName}'s turn, not yours.", combatLocked = true });

        // Require a configured key before advancing because the next initiative entry may be an enemy.
        // This prevents combat from becoming stranded on an unresolved enemy turn.
        var storedKey = await service.GetStoredOpenAiKeyAsync(player);
        if (storedKey is null || string.IsNullOrWhiteSpace(storedKey.EncryptedValue))
            throw new OpenAiConfigurationException("No OpenAI API key is saved for your Discord account. Open Settings and use Test & Save API Key before ending a combat turn.");

        var playerName = user.GlobalName ?? user.Username;
        var lease = await service.AcquireGmTurnAsync(player, campaignId, playerName);
        if (!lease.IsOwner || !lease.LockToken.HasValue)
            return Results.Conflict(new { success = false, error = "The AI Game Master is currently busy. Try End Turn again after the current GM response finishes.", turnExpired = true });
        turnToken = lease.LockToken.Value;
        await service.BeginGmProcessingAsync(player, campaignId, turnToken);
        processingLeaseStarted = true;

        var campaigns = await service.GetCampaignsAsync(player);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null)
            return Results.NotFound(new { success = false, error = "Campaign could not be found." });

        await service.AddMessageAsync(player, campaignId, "gm", "user", character.CharacterName, "[END TURN]");
        var advanced = await service.EndPlayerCombatTurnAsync(player, campaignId);

        string reply;
        GameMasterTurnResult? enemyTurn = null;
        if (advanced.CurrentTurnType.Equals("monster", StringComparison.OrdinalIgnoreCase))
        {
            var history = await service.GetMessagesAsync(player, campaignId, "gm", 100);
            var inventory = await service.GetInventoryAsync(player, campaignId);
            var spells = await service.GetSpellsAsync(player, campaignId);
            var apiKey = encryption.Decrypt(storedKey.EncryptedValue);
            var syntheticAction = $"[COMBAT END TURN] {character.CharacterName} ended their turn. The server has strictly advanced initiative to {advanced.CurrentTurnName}. Resolve that enemy's complete turn now. After resolving it, call advance_combat_turn. Continue resolving every consecutive enemy turn in strict server initiative order. Stop immediately when initiative reaches a player character or combat ends. Never take a player character's choices for them.";
            enemyTurn = await ai.AskGameMasterAsync(user.Id, apiKey, campaign, character, history, syntheticAction, inventory, spells);
            reply = enemyTurn.Message;
        }
        else
        {
            reply = $"Initiative passes to {advanced.CurrentTurnName}.";
        }

        await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM", reply);
        return Results.Ok(new
        {
            success = true,
            reply,
            nextTurn = new
            {
                roundNumber = advanced.RoundNumber,
                currentTurnType = advanced.CurrentTurnType,
                currentTurnCharacterId = advanced.CurrentTurnCharacterId,
                currentTurnMonsterId = advanced.CurrentTurnMonsterId,
                currentTurnName = advanced.CurrentTurnName
            },
            rolls = enemyTurn is null
                ? Array.Empty<object>()
                : enemyTurn.Rolls.Select(r => (object)new
                {
                    reason = r.Reason,
                    expression = r.Expression,
                    rolls = r.Rolls,
                    keptRoll = r.KeptRoll,
                    modifier = r.Modifier,
                    total = r.Total,
                    mode = r.Mode,
                    dc = r.Dc,
                    success = r.Dc > 0 ? r.Success : (bool?)null
                }).ToArray()
        });
    }
    catch (OpenAiUsageException ex)
    {
        return Results.Json(new { success = false, error = ex.Message, usageIssue = true }, statusCode: 429);
    }
    catch (OpenAiConfigurationException ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message, needsApiKey = true });
    }
    catch (InvalidOperationException ex) when (ex.Message.Contains("turn", StringComparison.OrdinalIgnoreCase))
    {
        return Results.Conflict(new { success = false, error = ex.Message, combatLocked = true });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
    finally
    {
        if (processingLeaseStarted && player != Guid.Empty && turnToken != Guid.Empty)
        {
            try { await service.ReleaseGmTurnAsync(player, campaignId, turnToken); }
            catch { }
        }
    }
});

// COMBAT BUILD 6.1 - RECOVERY FOR AN INTERRUPTED ENEMY TURN
app.MapPost("/game-api/campaigns/{campaignId:guid}/combat/resume-enemy-turns", async (
    Guid campaignId,
    HttpRequest request,
    DiscordSupabaseService service,
    OpenAiGameMasterService ai,
    ApiKeyEncryptionService encryption) =>
{
    Guid player = Guid.Empty;
    Guid turnToken = Guid.Empty;
    var processingLeaseStarted = false;
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        player = await service.GetOrCreatePlayerAsync(user);
        await service.TouchCampaignPresenceAsync(player, campaignId);
        await service.SkipOfflineCurrentCombatTurnAsync(campaignId);
        var character = await service.GetCharacterAsync(player, campaignId);
        if (character is null)
            return Results.NotFound(new { success = false, error = "Character could not be found." });

        var tactical = await service.GetTacticalCombatStateAsync(player, campaignId);
        if (tactical?.Active != true ||
            !tactical.CurrentTurnType.Equals("monster", StringComparison.OrdinalIgnoreCase) ||
            !tactical.CurrentTurnMonsterId.HasValue)
        {
            return Results.Conflict(new
            {
                success = false,
                error = "There is no unresolved enemy initiative turn to resume.",
                combatLocked = true
            });
        }

        var storedKey = await service.GetStoredOpenAiKeyAsync(player);
        if (storedKey is null || string.IsNullOrWhiteSpace(storedKey.EncryptedValue))
            throw new OpenAiConfigurationException("No OpenAI API key is saved for your Discord account. Open Settings and use Test & Save API Key before resuming the GM turn.");

        var playerName = user.GlobalName ?? user.Username;
        var lease = await service.AcquireGmTurnAsync(player, campaignId, playerName);
        if (!lease.IsOwner || !lease.LockToken.HasValue)
            return Results.Conflict(new { success = false, error = "The AI Game Master is already resolving this combat turn.", turnExpired = true });

        turnToken = lease.LockToken.Value;
        await service.BeginGmProcessingAsync(player, campaignId, turnToken);
        processingLeaseStarted = true;

        var campaigns = await service.GetCampaignsAsync(player);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null)
            return Results.NotFound(new { success = false, error = "Campaign could not be found." });

        var history = await service.GetMessagesAsync(player, campaignId, "gm", 100);
        var inventory = await service.GetInventoryAsync(player, campaignId);
        var spells = await service.GetSpellsAsync(player, campaignId);
        var apiKey = encryption.Decrypt(storedKey.EncryptedValue);
        var syntheticAction = $"[RESUME ENEMY INITIATIVE] Combat is currently stopped on enemy {tactical.CurrentTurnName}. Resolve that enemy's complete initiative turn now. Persist all movement, attack/save/damage results and HP changes with trusted tools. Then call advance_combat_turn. Continue every consecutive enemy turn in strict server initiative order and stop immediately when initiative reaches a player character or combat ends. Never take a player character's choices for them.";
        var enemyTurn = await ai.AskGameMasterAsync(user.Id, apiKey, campaign, character, history, syntheticAction, inventory, spells);
        var reply = enemyTurn.Message;
        await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM", reply);

        var refreshed = await service.GetTacticalCombatStateAsync(player, campaignId);
        return Results.Ok(new
        {
            success = true,
            reply,
            nextTurn = new
            {
                roundNumber = Math.Max(1, refreshed?.RoundNumber ?? 1),
                currentTurnType = refreshed?.CurrentTurnType ?? string.Empty,
                currentTurnCharacterId = refreshed?.CurrentTurnCharacterId,
                currentTurnMonsterId = refreshed?.CurrentTurnMonsterId,
                currentTurnName = refreshed?.CurrentTurnName ?? string.Empty
            },
            rolls = enemyTurn.Rolls.Select(r => (object)new
            {
                reason = r.Reason,
                expression = r.Expression,
                rolls = r.Rolls,
                keptRoll = r.KeptRoll,
                modifier = r.Modifier,
                total = r.Total,
                mode = r.Mode,
                dc = r.Dc,
                success = r.Dc > 0 ? r.Success : (bool?)null
            }).ToArray()
        });
    }
    catch (OpenAiUsageException ex)
    {
        return Results.Json(new { success = false, error = ex.Message, usageIssue = true }, statusCode: 429);
    }
    catch (OpenAiConfigurationException ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message, needsApiKey = true });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
    finally
    {
        if (processingLeaseStarted && player != Guid.Empty && turnToken != Guid.Empty)
        {
            try { await service.ReleaseGmTurnAsync(player, campaignId, turnToken); }
            catch { }
        }
    }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/gm", async (
    Guid campaignId, GameMasterRequest body, HttpRequest request, DiscordSupabaseService service, OpenAiGameMasterService ai, ApiKeyEncryptionService encryption) =>
{
    Guid player = Guid.Empty;
    Guid turnToken = Guid.Empty;
    var processingLeaseStarted = false;

    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        player = await service.GetOrCreatePlayerAsync(user);
        await service.TouchCampaignPresenceAsync(player, campaignId);
        await service.SkipOfflineCurrentCombatTurnAsync(campaignId);

        var deathState = await service.GetDeathStateAsync(player, campaignId);
        if (deathState?.ViewerIsDeadPlayer == true)
            return Results.Conflict(new { success = false, error = "Your character is dead. Resolve the Respawn screen before taking another Game Master action.", deadCharacter = true });

        var combatAccess = await service.GetTacticalCombatStateAsync(player, campaignId);
        var setupInitiative = combatAccess?.Active == true && string.IsNullOrWhiteSpace(combatAccess.CurrentTurnType)
            ? await service.GetCombatInitiativeAsync(player, campaignId)
            : new List<CombatInitiativeRow>();
        var combatSetupPending = combatAccess?.Active == true &&
            string.IsNullOrWhiteSpace(combatAccess.CurrentTurnType) &&
            !combatAccess.CurrentTurnCharacterId.HasValue &&
            !combatAccess.CurrentTurnMonsterId.HasValue &&
            setupInitiative.Count == 0;
        if (combatAccess?.Active == true && !combatSetupPending &&
            !(combatAccess.ViewerCharacterId.HasValue &&
              combatAccess.CurrentTurnType.Equals("character", StringComparison.OrdinalIgnoreCase) &&
              combatAccess.CurrentTurnCharacterId == combatAccess.ViewerCharacterId))
        {
            return Results.Conflict(new
            {
                success = false,
                error = string.IsNullOrWhiteSpace(combatAccess.CurrentTurnName)
                    ? "Combat initiative is active. Wait for your character's turn."
                    : $"Combat initiative is active. It is {combatAccess.CurrentTurnName}'s turn.",
                combatLocked = true,
                currentTurnName = combatAccess.CurrentTurnName
            });
        }

        var tokenText = request.Headers["X-RabuShin-GM-Turn-Token"].ToString();
        if (!Guid.TryParse(tokenText, out turnToken))
        {
            return Results.Conflict(new
            {
                success = false,
                error = "Begin typing in the AI Game Master box to claim the 30-second turn before sending.",
                turnExpired = true
            });
        }

        await service.BeginGmProcessingAsync(player, campaignId, turnToken);
        processingLeaseStarted = true;

        var character = await service.GetCharacterAsync(player, campaignId);
        if (character is null)
            return Results.NotFound(new { success = false, error = "Character could not be found." });

        var campaigns = await service.GetCampaignsAsync(player);
        var campaign = campaigns.FirstOrDefault(c => c.CampaignId == campaignId);
        if (campaign is null)
            return Results.NotFound(new { success = false, error = "Campaign could not be found." });

        var sender = character.CharacterName;
        await service.AddMessageAsync(player, campaignId, "gm", "user", sender, body.Message);
        var history = await service.GetMessagesAsync(player, campaignId, "gm", 100);
        var inventory = await service.GetInventoryAsync(player, campaignId);
        var spells = await service.GetSpellsAsync(player, campaignId);
        var storedKey = await service.GetStoredOpenAiKeyAsync(player);
        if (storedKey is null || string.IsNullOrWhiteSpace(storedKey.EncryptedValue))
            throw new OpenAiConfigurationException("No OpenAI API key is saved for your Discord account. Open Settings and use Test & Save API Key.");

        var apiKey = encryption.Decrypt(storedKey.EncryptedValue);
        var settlementLocation = await service.GetPlayerSettlementLocationAsync(player, campaignId);
        var gmPlayerMessage = body.Message;
        var interactiveSettlement = SettlementInteractionCatalog.FindByLocation(campaign.CurrentLocation);
        if (settlementLocation is not null && interactiveSettlement is not null &&
            settlementLocation.SettlementKey.Equals(interactiveSettlement.SettlementKey, StringComparison.OrdinalIgnoreCase))
        {
            gmPlayerMessage = $"[PERSONAL SETTLEMENT LOCATION: {character.CharacterName} is currently at {settlementLocation.PoiName} in {interactiveSettlement.SettlementName}. This location applies only to this character, not the entire party.]\n{body.Message}";
        }
        var turn = await ai.AskGameMasterAsync(user.Id, apiKey, campaign, character, history, gmPlayerMessage, inventory, spells);
        await service.AddMessageAsync(player, campaignId, "gm", "assistant", "RabuShin AI GM", turn.Message);

        return Results.Ok(new
        {
            success = true,
            reply = turn.Message,
            gmControlledDice = true,
            rolls = turn.Rolls.Select(r => new
            {
                reason = r.Reason,
                expression = r.Expression,
                rolls = r.Rolls,
                keptRoll = r.KeptRoll,
                modifier = r.Modifier,
                total = r.Total,
                mode = r.Mode,
                dc = r.Dc,
                success = r.Dc > 0 ? r.Success : (bool?)null
            })
        });
    }
    catch (OpenAiUsageException ex)
    {
        return Results.Json(new { success = false, error = ex.Message, usageIssue = true }, statusCode: 429);
    }
    catch (OpenAiConfigurationException ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message, needsApiKey = true });
    }
    catch (InvalidOperationException ex) when (
        ex.Message.Contains("30-second AI Game Master turn", StringComparison.OrdinalIgnoreCase) ||
        ex.Message.Contains("AI Game Master turn expired", StringComparison.OrdinalIgnoreCase) ||
        ex.Message.Contains("AI Game Master turn", StringComparison.OrdinalIgnoreCase))
    {
        return Results.Conflict(new { success = false, error = ex.Message, turnExpired = true });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { success = false, error = ex.Message });
    }
    finally
    {
        if (processingLeaseStarted && player != Guid.Empty && turnToken != Guid.Empty)
        {
            try
            {
                await service.ReleaseGmTurnAsync(player, campaignId, turnToken);
            }
            catch
            {
                // A stale processing lease self-expires after ten minutes.
            }
        }
    }
});

// Any non-API Activity route should load the Vite application.
// API routes above always take precedence over this fallback.
app.MapFallbackToFile("index.html");

app.Run();

public sealed record DiscordTokenRequest(string Code);
public sealed record RespawnChoiceRequest(bool Respawn);
public sealed record RespawnDonationRequest(int AmountGp);
public sealed record LevelUpChoicesRequest(JsonElement Choices);
public sealed record RestSpellReviewRequest(bool ReviewSpells);
public sealed record SurvivalSettingsRequest(bool Enabled);
public sealed record SettlementMoveRequest(string PoiKey);
public sealed record SettlementShopPurchaseRequest(string ItemKey, int Quantity);
public sealed record SettlementShopSaleRequest(Guid InventoryItemId, int Quantity);
