using QuestsOfRabuShinAIGM;

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
    species = CharacterGenerationService.Species,
    baseSpecies = CharacterGenerationService.BaseSpecies,
    classes = CharacterGenerationService.Classes,
    backgrounds = CharacterGenerationService.Backgrounds,
    alignments = CharacterGenerationService.Alignments
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

app.MapPost("/game-api/campaigns/{campaignId:guid}/characters/random", async (
    Guid campaignId, RandomCharacterRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        if (await service.GetCharacterAsync(playerId, campaignId) is not null)
            return Results.BadRequest(new { success = false, error = "You already have a character in this campaign." });

        var species = CharacterGenerationService.Species.FirstOrDefault(v => v.Equals(body.Species, StringComparison.OrdinalIgnoreCase));
        var className = CharacterGenerationService.Classes.FirstOrDefault(v => v.Equals(body.ClassName, StringComparison.OrdinalIgnoreCase));
        if (species is null) return Results.BadRequest(new { success = false, error = "Invalid species." });
        if (className is null) return Results.BadRequest(new { success = false, error = "Invalid class." });

        var character = new CharacterGenerationService().Generate(species, className, 1, body.CharacterName ?? "");
        var id = await service.CreateCharacterAsync(playerId, campaignId, character);
        return Results.Ok(new { success = true, character = ProgramHelpers.ToClientGeneratedCharacter(id, character) });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/characters/manual", async (
    Guid campaignId, ManualCharacterRequest body, HttpRequest request, DiscordSupabaseService service) =>
{
    try
    {
        var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var playerId = await service.GetOrCreatePlayerAsync(user);
        if (await service.GetCharacterAsync(playerId, campaignId) is not null)
            return Results.BadRequest(new { success = false, error = "You already have a character in this campaign." });

        var character = ManualCharacterCreationService.Create(
            body.CharacterName, body.Species, body.SecondaryHeritage ?? "", body.ClassName,
            body.Background, body.Alignment, body.Level,
            body.Strength, body.Dexterity, body.Constitution, body.Intelligence, body.Wisdom, body.Charisma,
            body.Appearance ?? "", body.Personality ?? "", body.Backstory ?? "", body.Notes ?? "");
        var id = await service.CreateCharacterAsync(playerId, campaignId, character);
        return Results.Ok(new { success = true, character = ProgramHelpers.ToClientGeneratedCharacter(id, character) });
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

        return Results.Ok(new
        {
            success = true,
            campaign = new { campaignId = campaign.CampaignId, campaignName = campaign.CampaignName, joinCode = campaign.JoinCode,
                currentChapter = campaign.CurrentChapter, currentLocation = campaign.CurrentLocation, isOwner = campaign.IsOwner, memberCount = campaign.MemberCount },
            character = ProgramHelpers.ToClientCharacter(character, party.Any(p => p.CharacterId == character.CharacterId && !string.IsNullOrWhiteSpace(p.PortraitPath))),
            party = party.Select(ProgramHelpers.ToClientPartyMember),
            inventory = inventory.Select(InventoryPresentationService.ToClientItem),
            spells = spells.Select(s => new { characterSpellId=s.CharacterSpellId,spellName=s.SpellName,spellLevel=s.SpellLevel,prepared=s.Prepared,sourceTag=s.SourceTag,spellData=s.SpellData }),
            spellSlots = slots.Select(s => new { spellLevel=s.SpellLevel,maxSlots=s.MaxSlots,usedSlots=s.UsedSlots }),
            gmMessages = gm.Select(m => new { messageId=m.MessageId,roleName=m.RoleName,senderName=m.SenderName,messageText=m.MessageText,createdAt=m.CreatedAt }),
            chatMessages = chat.Select(m => new { messageId=m.MessageId,roleName=m.RoleName,senderName=m.SenderName,messageText=m.MessageText,createdAt=m.CreatedAt }),
            journal = journal.Select(j => new { journalId=j.JournalId,category=j.Category,title=j.Title,entryText=j.EntryText,createdAt=j.CreatedAt }),
            openAiConfigured = await service.HasStoredOpenAiKeyAsync(playerId)
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
        var state = await service.GetLocalMapStateAsync(playerId, campaignId);

        object? settlementMap = null;
        object? encounterMap = null;

        if (definition is not null)
        {
            settlementMap = new
            {
                available = true,
                locationKey = definition.LocationKey,
                name = $"{definition.LocationName} Settlement Map",
                imageUrl = definition.SettlementImageUrl,
                imageWidth = definition.SettlementImageWidth,
                imageHeight = definition.SettlementImageHeight
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
            settlementMap,
            encounterMap
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
        return Results.Ok(new
        {
            success = true,
            gold = character.Gold,
            inventory = inventory.Select(InventoryPresentationService.ToClientItem)
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
        var user=await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString()); var player=await service.GetOrCreatePlayerAsync(user);
        var messages=await service.GetMessagesAsync(player,campaignId,"gm",150);
        return Results.Ok(new {success=true,messages=messages.Select(m=>new {messageId=m.MessageId,roleName=m.RoleName,senderName=m.SenderName,messageText=m.MessageText,createdAt=m.CreatedAt})});
    }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.MapPost("/game-api/campaigns/{campaignId:guid}/gm", async (
    Guid campaignId, GameMasterRequest body, HttpRequest request, DiscordSupabaseService service, OpenAiGameMasterService ai, ApiKeyEncryptionService encryption) =>
{
    try
    {
        var user=await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        var player=await service.GetOrCreatePlayerAsync(user);
        var character=await service.GetCharacterAsync(player,campaignId);
        if(character is null) return Results.NotFound(new {success=false,error="Character could not be found."});
        var campaigns=await service.GetCampaignsAsync(player); var campaign=campaigns.FirstOrDefault(c=>c.CampaignId==campaignId);
        if(campaign is null) return Results.NotFound(new {success=false,error="Campaign could not be found."});
        var sender=user.GlobalName??user.Username;
        await service.AddMessageAsync(player,campaignId,"gm","user",sender,body.Message);
        var history=await service.GetMessagesAsync(player,campaignId,"gm",100);
        var inventory=await service.GetInventoryAsync(player,campaignId);
        var spells=await service.GetSpellsAsync(player,campaignId);
        var storedKey=await service.GetStoredOpenAiKeyAsync(player);
        if(storedKey is null || string.IsNullOrWhiteSpace(storedKey.EncryptedValue))
            throw new OpenAiConfigurationException("No OpenAI API key is saved for your Discord account. Open Settings and use Test & Save API Key.");
        var apiKey=encryption.Decrypt(storedKey.EncryptedValue);
        var turn=await ai.AskGameMasterAsync(user.Id,apiKey,campaign,character,history,body.Message,inventory,spells);
        await service.AddMessageAsync(player,campaignId,"gm","assistant","RabuShin AI GM",turn.Message);
        return Results.Ok(new
        {
            success=true,
            reply=turn.Message,
            gmControlledDice=true,
            rolls=turn.Rolls.Select(r=>new
            {
                reason=r.Reason,
                expression=r.Expression,
                rolls=r.Rolls,
                keptRoll=r.KeptRoll,
                modifier=r.Modifier,
                total=r.Total,
                mode=r.Mode,
                dc=r.Dc,
                success=r.Dc>0 ? r.Success : (bool?)null
            })
        });
    }
    catch(OpenAiUsageException ex){ return Results.Json(new {success=false,error=ex.Message,usageIssue=true},statusCode:429); }
    catch(OpenAiConfigurationException ex){ return Results.BadRequest(new {success=false,error=ex.Message,needsApiKey=true}); }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

// Any non-API Activity route should load the Vite application.
// API routes above always take precedence over this fallback.
app.MapFallbackToFile("index.html");

app.Run();

public sealed record DiscordTokenRequest(string Code);
