using QuestsOfRabuShinAIGM;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHttpClient<DiscordSupabaseService>();
builder.Services.AddHttpClient<OpenAiGameMasterService>();
builder.Services.AddSingleton<OpenAiKeyStore>();
builder.Services.AddSingleton<CampaignCanonService>();
builder.WebHost.UseUrls("http://localhost:3002");

var app = builder.Build();

app.MapGet("/game-api/health", () => Results.Ok(new
{
    success = true,
    game = "RabuShinAIGM",
    version = "Discord Completion Package",
    server = "ASP.NET Core",
    gameEngine = "VB.NET",
    message = "RabuShin Discord server is running."
}));

app.MapPost("/game-api/dice/roll", (DiceRollRequest body) =>
{
    try
    {
        var dice = new DiceService();
        var result = body.Sides == 20 && (body.Advantage || body.Disadvantage)
            ? dice.RollD20(body.Modifier, body.Advantage, body.Disadvantage)
            : dice.Roll(Math.Max(1, body.Count), Math.Max(2, body.Sides), body.Modifier);
        return Results.Ok(new { success = true, result.Expression, result.Rolls, result.Modifier, result.Total, result.Mode, result.KeptRoll });
    }
    catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
});

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
    Guid campaignId, HttpRequest request, DiscordSupabaseService service, OpenAiGameMasterService ai) =>
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
            character = ProgramHelpers.ToClientCharacter(character),
            party = party.Select(p => new { characterId=p.CharacterId,playerId=p.PlayerId,displayName=p.DisplayName,discordUsername=p.DiscordUsername,characterName=p.CharacterName,speciesName=p.SpeciesName,className=p.ClassName,level=p.Level,currentHp=p.CurrentHp,maxHp=p.MaxHp,armorClass=p.ArmorClass }),
            inventory = inventory.Select(i => new { inventoryItemId=i.InventoryItemId,itemName=i.ItemName,quantity=i.Quantity,equipped=i.Equipped,attuned=i.Attuned,sourceName=i.SourceName,notes=i.Notes,itemData=i.ItemData }),
            spells = spells.Select(s => new { characterSpellId=s.CharacterSpellId,spellName=s.SpellName,spellLevel=s.SpellLevel,prepared=s.Prepared,sourceTag=s.SourceTag,spellData=s.SpellData }),
            spellSlots = slots.Select(s => new { spellLevel=s.SpellLevel,maxSlots=s.MaxSlots,usedSlots=s.UsedSlots }),
            gmMessages = gm.Select(m => new { messageId=m.MessageId,roleName=m.RoleName,senderName=m.SenderName,messageText=m.MessageText,createdAt=m.CreatedAt }),
            chatMessages = chat.Select(m => new { messageId=m.MessageId,roleName=m.RoleName,senderName=m.SenderName,messageText=m.MessageText,createdAt=m.CreatedAt }),
            journal = journal.Select(j => new { journalId=j.JournalId,category=j.Category,title=j.Title,entryText=j.EntryText,createdAt=j.CreatedAt }),
            openAiConfigured = ai.HasApiKey(user.Id)
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

app.MapGet("/game-api/settings/openai", async (HttpRequest request, DiscordSupabaseService service, OpenAiGameMasterService ai) =>
{
    try
    {
        var user=await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        return Results.Ok(new {success=true,configured=ai.HasApiKey(user.Id)});
    }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.MapPost("/game-api/settings/openai", async (OpenAiKeyRequest body, HttpRequest request, DiscordSupabaseService service, OpenAiGameMasterService ai) =>
{
    try
    {
        var user=await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
        ai.SetSessionApiKey(user.Id,body.ApiKey);
        return Results.Ok(new {success=true,configured=true});
    }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.MapDelete("/game-api/settings/openai", async (HttpRequest request, DiscordSupabaseService service, OpenAiGameMasterService ai) =>
{
    try
    {
        var user=await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString()); ai.ClearSessionApiKey(user.Id);
        return Results.Ok(new {success=true});
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
    Guid campaignId, GameMasterRequest body, HttpRequest request, DiscordSupabaseService service, OpenAiGameMasterService ai) =>
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
        var reply=await ai.AskGameMasterAsync(user.Id,campaign,character,history,body.Message);
        await service.AddMessageAsync(player,campaignId,"gm","assistant","RabuShin AI GM",reply);
        return Results.Ok(new {success=true,reply});
    }
    catch(OpenAiUsageException ex){ return Results.Json(new {success=false,error=ex.Message,usageIssue=true},statusCode:429); }
    catch(OpenAiConfigurationException ex){ return Results.BadRequest(new {success=false,error=ex.Message,needsApiKey=true}); }
    catch(Exception ex){ return Results.BadRequest(new {success=false,error=ex.Message}); }
});

app.Run();
