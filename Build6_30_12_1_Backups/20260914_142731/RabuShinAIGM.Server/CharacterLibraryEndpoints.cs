using QuestsOfRabuShinAIGM;

public static class CharacterLibraryEndpoints
{
    // BUILD 6.30.9 - Character Library and Campaign Membership routes.
    public static WebApplication MapCharacterLibraryEndpoints(this WebApplication app)
    {
        app.MapGet("/game-api/characters/library", async (
            HttpRequest request,
            DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);
                var characters = await service.GetCharacterLibraryAsync(playerId);
                return Results.Ok(new
                {
                    success = true,
                    maxCharacters = 10,
                    slotCount = characters.Count(c => c.LibrarySlot.HasValue),
                    characters = characters.Select(ToClientLibraryCharacter)
                });
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

        app.MapPost("/game-api/characters/library/random", async (
            EnhancedRandomCharacterRequest body,
            HttpRequest request,
            DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);

                var gender = CharacterFeatureRules.NormalizeGender(body.Gender);
                var validSpecies = CharacterFeatureRules.WithTortleSpecies(CharacterGenerationService.Species);
                var species = validSpecies.FirstOrDefault(v => v.Equals(body.Species, StringComparison.OrdinalIgnoreCase));
                var className = CharacterGenerationService.Classes.FirstOrDefault(v => v.Equals(body.ClassName, StringComparison.OrdinalIgnoreCase));
                if (species is null) return Results.BadRequest(new { success = false, error = "Invalid species." });
                if (className is null) return Results.BadRequest(new { success = false, error = "Invalid class." });

                var generationSpecies = CharacterFeatureRules.IsHalfRace(species)
                    ? CharacterFeatureRules.PrimaryHeritage(species)
                    : species;
                var engineSpecies = CharacterFeatureRules.EngineSpecies(generationSpecies, CharacterGenerationService.Species);
                var generated = new CharacterGenerationService().Generate(
                    engineSpecies, className, 1, body.CharacterName ?? string.Empty, false);

                var scores = CharacterFeatureRules.ApplyRandomAbilityScores(
                    species,
                    generated.Strength, generated.Dexterity, generated.Constitution,
                    generated.Intelligence, generated.Wisdom, generated.Charisma,
                    body.RacialAbilityChoices,
                    body.Subrace, body.SecondaryHeritage, body.SecondarySubrace,
                    body.SecondaryRacialAbilityChoices);

                var profile = CharacterFeatureRules.BuildProfile(
                    species, body.SecondaryHeritage, scores,
                    body.Subrace, body.SecondarySubrace,
                    body.DragonbornAncestry, body.SecondaryDragonbornAncestry,
                    body.HighElfCantrip, body.HighElfLanguage,
                    body.SecondaryHighElfCantrip, body.SecondaryHighElfLanguage,
                    body.DwarfTool, body.SecondaryDwarfTool,
                    body.TortleSize, body.TortleNatureSkill, body.TortleLanguage,
                    body.SecondaryTortleSize, body.SecondaryTortleNatureSkill, body.SecondaryTortleLanguage);

                var id = await service.CreateLibraryCharacterWithFeaturesAsync(
                    playerId, generated, species, scores, profile,
                    string.Empty, string.Empty, string.Empty, string.Empty, gender);

                var saved = (await service.GetCharacterLibraryAsync(playerId))
                    .FirstOrDefault(c => c.CharacterId == id);
                return Results.Ok(new
                {
                    success = true,
                    character = saved is null
                        ? new { characterId = id, characterName = generated.CharacterName, speciesName = species, className, level = generated.Level }
                        : ToClientLibraryCharacter(saved)
                });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { success = false, error = ex.Message });
            }
        });

        app.MapPost("/game-api/characters/library/manual", async (
            EnhancedManualCharacterRequest body,
            HttpRequest request,
            DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);

                var gender = CharacterFeatureRules.NormalizeGender(body.Gender);
                var validSpecies = CharacterFeatureRules.WithTortleSpecies(CharacterGenerationService.Species);
                var species = validSpecies.FirstOrDefault(v => v.Equals(body.Species, StringComparison.OrdinalIgnoreCase));
                if (species is null) return Results.BadRequest(new { success = false, error = "Invalid species." });

                var secondaryHeritage = CharacterFeatureRules.ResolveSecondaryHeritage(species, body.SecondaryHeritage);

                var scores = CharacterFeatureRules.ApplyAbilityScores(
                    species,
                    body.Strength, body.Dexterity, body.Constitution,
                    body.Intelligence, body.Wisdom, body.Charisma,
                    body.RacialAbilityChoices,
                    body.Subrace, secondaryHeritage, body.SecondarySubrace,
                    body.SecondaryRacialAbilityChoices);

                var profile = CharacterFeatureRules.BuildProfile(
                    species, secondaryHeritage, scores,
                    body.Subrace, body.SecondarySubrace,
                    body.DragonbornAncestry, body.SecondaryDragonbornAncestry,
                    body.HighElfCantrip, body.HighElfLanguage,
                    body.SecondaryHighElfCantrip, body.SecondaryHighElfLanguage,
                    body.DwarfTool, body.SecondaryDwarfTool,
                    body.TortleSize, body.TortleNatureSkill, body.TortleLanguage,
                    body.SecondaryTortleSize, body.SecondaryTortleNatureSkill, body.SecondaryTortleLanguage);

                var primaryHeritage = CharacterFeatureRules.PrimaryHeritage(species);
                var legacyPrimarySupported = CharacterFeatureRules.LegacyCoreSupportsHeritage(
                    primaryHeritage, CharacterGenerationService.BaseSpecies);
                var legacySecondarySupported = string.IsNullOrWhiteSpace(secondaryHeritage)
                    || CharacterFeatureRules.LegacyCoreSupportsHeritage(
                        secondaryHeritage, CharacterGenerationService.BaseSpecies);

                var useLegacyHybrid = CharacterFeatureRules.IsHalfRace(species)
                    && legacyPrimarySupported && legacySecondarySupported;
                var legacySpeciesRequest = useLegacyHybrid ? species : primaryHeritage;
                var engineSpecies = CharacterFeatureRules.EngineSpecies(
                    legacySpeciesRequest, CharacterGenerationService.Species);
                var engineSecondaryHeritage = useLegacyHybrid ? secondaryHeritage : string.Empty;

                var character = ManualCharacterCreationService.Create(
                    body.CharacterName, engineSpecies, engineSecondaryHeritage, body.ClassName,
                    body.Background, body.Alignment, body.Level,
                    scores.Strength, scores.Dexterity, scores.Constitution,
                    scores.Intelligence, scores.Wisdom, scores.Charisma,
                    body.Appearance ?? string.Empty, body.Personality ?? string.Empty,
                    body.Backstory ?? string.Empty, body.Notes ?? string.Empty);

                var id = await service.CreateLibraryCharacterWithFeaturesAsync(
                    playerId, character, species, scores, profile,
                    body.Appearance ?? string.Empty,
                    body.Personality ?? string.Empty,
                    body.Backstory ?? string.Empty,
                    body.Notes ?? string.Empty,
                    gender);

                var saved = (await service.GetCharacterLibraryAsync(playerId))
                    .FirstOrDefault(c => c.CharacterId == id);
                return Results.Ok(new
                {
                    success = true,
                    character = saved is null
                        ? new { characterId = id, characterName = character.CharacterName, speciesName = species, className = character.ClassName, level = character.Level }
                        : ToClientLibraryCharacter(saved)
                });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { success = false, error = ex.Message });
            }
        });

        app.MapPost("/game-api/campaigns/{campaignId:guid}/character-library/{characterId:guid}/assign", async (
            Guid campaignId,
            Guid characterId,
            HttpRequest request,
            DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);
                await service.AssignLibraryCharacterAsync(playerId, campaignId, characterId);
                return Results.Ok(new { success = true, characterId, campaignId });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { success = false, error = ex.Message });
            }
        });

        app.MapDelete("/game-api/characters/library/{characterId:guid}", async (
            Guid characterId,
            HttpRequest request,
            DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);
                await service.DeleteLibraryCharacterAsync(playerId, characterId);
                return Results.Ok(new { success = true, message = "Character deleted." });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { success = false, error = ex.Message });
            }
        });

        app.MapPost("/game-api/characters/pending/{characterId:guid}/resolve", async (
            Guid characterId,
            PendingCharacterResolutionRequest body,
            HttpRequest request,
            DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);
                var result = await service.ResolvePendingCharacterAsync(
                    playerId, characterId, body.Action, body.ReplaceCharacterId);
                return Results.Ok(new
                {
                    success = true,
                    characterId = result.CharacterId,
                    characterStatus = result.CharacterStatus,
                    librarySlot = result.LibrarySlot,
                    deleted = result.WasDeleted
                });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { success = false, error = ex.Message });
            }
        });

        app.MapGet("/game-api/campaigns/{campaignId:guid}/character-departure-preview", async (
            Guid campaignId,
            Guid? characterId,
            HttpRequest request,
            DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);
                var preview = await service.GetCharacterDeparturePreviewAsync(playerId, campaignId, characterId);
                return Results.Ok(new
                {
                    success = true,
                    hasCharacter = preview is not null,
                    preview = preview is null ? null : new
                    {
                        characterId = preview.CharacterId,
                        characterName = preview.CharacterName,
                        isLibraryCharacter = preview.IsLibraryCharacter,
                        requiresStoreDeleteChoice = preview.RequiresStoreDeleteChoice,
                        librarySlot = preview.LibrarySlot
                    }
                });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { success = false, error = ex.Message });
            }
        });

        app.MapGet("/game-api/campaigns/{campaignId:guid}/members/manage", async (
            Guid campaignId,
            HttpRequest request,
            DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);
                var members = await service.GetCampaignMembersForManagementAsync(playerId, campaignId);
                return Results.Ok(new
                {
                    success = true,
                    members = members.Select(m => new
                    {
                        playerId = m.PlayerId,
                        displayName = m.DisplayName,
                        discordUsername = m.DiscordUsername,
                        role = m.Role,
                        isOwner = m.IsOwner,
                        characterName = m.CharacterName
                    })
                });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { success = false, error = ex.Message });
            }
        });

        app.MapPost("/game-api/campaigns/{campaignId:guid}/members/{targetPlayerId:guid}/kick", async (
            Guid campaignId,
            Guid targetPlayerId,
            HttpRequest request,
            DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var ownerPlayerId = await service.GetOrCreatePlayerAsync(user);
                await service.KickCampaignPlayerAsync(ownerPlayerId, campaignId, targetPlayerId);
                return Results.Ok(new
                {
                    success = true,
                    message = "Player removed from the campaign. Their reusable character was returned or queued for their Store/Delete decision."
                });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { success = false, error = ex.Message });
            }
        });

        app.MapPost("/game-api/campaigns/{campaignId:guid}/solo-party/characters/{characterId:guid}/remove", async (
            Guid campaignId,
            Guid characterId,
            SoloCharacterRemovalRequest body,
            HttpRequest request,
            DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var ownerPlayerId = await service.GetOrCreatePlayerAsync(user);

                var removal = await service.RemoveSoloCharacterAsync(ownerPlayerId, campaignId, characterId);

                if (removal.CharacterStatus == "pending_storage")
                {
                    var action = (body.Action ?? string.Empty).Trim().ToLowerInvariant();
                    if (action is "store" or "delete")
                    {
                        var resolved = await service.ResolvePendingCharacterAsync(
                            ownerPlayerId, characterId, action, body.ReplaceCharacterId);
                        return Results.Ok(new
                        {
                            success = true,
                            characterId,
                            characterStatus = resolved.CharacterStatus,
                            librarySlot = resolved.LibrarySlot,
                            deleted = resolved.WasDeleted
                        });
                    }
                }

                return Results.Ok(new
                {
                    success = true,
                    characterId,
                    characterStatus = removal.CharacterStatus,
                    librarySlot = removal.LibrarySlot,
                    deleted = false
                });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { success = false, error = ex.Message });
            }
        });

        return app;
    }

    private static object ToClientLibraryCharacter(CharacterLibraryInfo c) => new
    {
        characterId = c.CharacterId,
        characterName = c.CharacterName,
        speciesName = c.SpeciesName,
        className = c.ClassName,
        backgroundName = c.BackgroundName,
        alignment = c.Alignment,
        gender = c.Gender,
        level = c.Level,
        experience = c.Experience,
        currentHp = c.CurrentHp,
        maxHp = c.MaxHp,
        armorClass = c.ArmorClass,
        librarySlot = c.LibrarySlot,
        characterOrigin = c.CharacterOrigin,
        characterStatus = c.CharacterStatus,
        pendingReason = c.PendingReason,
        campaignId = c.CampaignId,
        campaignName = c.CampaignName,
        equipmentComplete = c.EquipmentComplete,
        spellsComplete = c.SpellsComplete
    };
}

public sealed class PendingCharacterResolutionRequest
{
    public string Action { get; set; } = string.Empty;
    public Guid? ReplaceCharacterId { get; set; }
}

public sealed class SoloCharacterRemovalRequest
{
    public string? Action { get; set; }
    public Guid? ReplaceCharacterId { get; set; }
}
