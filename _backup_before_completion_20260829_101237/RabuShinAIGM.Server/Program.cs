using QuestsOfRabuShinAIGM;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHttpClient<DiscordSupabaseService>();

// ---------------------------------------------------------
// RABUSHIN SERVER
// ---------------------------------------------------------

builder.WebHost.UseUrls("http://localhost:3002");

var app = builder.Build();


// ---------------------------------------------------------
// SERVER TEST
// ---------------------------------------------------------

app.MapGet("/game-api/health", () =>
{
    return Results.Ok(new
    {
        success = true,
        game = "RabuShinAIGM",
        version = "4.2.1",
        server = "ASP.NET Core",
        gameEngine = "VB.NET",
        message = "RabuShin Discord server is running."
    });
});


// ---------------------------------------------------------
// DICE ROLLER
// ---------------------------------------------------------

app.MapPost("/game-api/dice/roll", (DiceRollRequest request) =>
{
    try
    {
        var diceService = new DiceService();

        DiceRollResult result;


        // ---------------------------------------------
        // Advantage / Disadvantage
        // ---------------------------------------------

        if (
            request.Count == 1 &&
            request.Sides == 20 &&
            (request.Advantage || request.Disadvantage)
        )
        {
            result = diceService.RollD20(
                request.Modifier,
                request.Advantage,
                request.Disadvantage
            );
        }


        // ---------------------------------------------
        // Normal dice
        // ---------------------------------------------

        else
        {
            result = diceService.Roll(
                request.Count,
                request.Sides,
                request.Modifier
            );
        }


        // ---------------------------------------------
        // SEND RESULT TO DISCORD
        // ---------------------------------------------

        return Results.Ok(new
        {
            success = true,

            expression = result.Expression,

            rolls = result.Rolls,

            modifier = result.Modifier,

            total = result.Total,

            mode = result.Mode,

            keptRoll = result.KeptRoll
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new
        {
            success = false,
            error = ex.Message
        });
    }
});

app.MapGet(
    "/game-api/campaigns",
    async (
        HttpRequest request,
        DiscordSupabaseService service
    ) =>
    {
        try
        {
            var discordUser =
                await service.VerifyDiscordUserAsync(
                    request.Headers.Authorization.ToString()
                );


            var playerId =
                await service.GetOrCreatePlayerAsync(
                    discordUser
                );


            var campaigns =
                await service.GetCampaignsAsync(
                    playerId
                );


            // Convert the Supabase snake_case model into
            // clean camelCase JSON for the Discord client.
            var clientCampaigns =
                campaigns.Select(
                    campaign => new
                    {
                        campaignId =
                            campaign.CampaignId,

                        campaignName =
                            campaign.CampaignName,

                        joinCode =
                            campaign.JoinCode,

                        currentChapter =
                            campaign.CurrentChapter,

                        currentLocation =
                            campaign.CurrentLocation,

                        isOwner =
                            campaign.IsOwner,

                        memberCount =
                            campaign.MemberCount
                    }
                )
                .ToList();


            return Results.Ok(
                new
                {
                    success = true,
                    campaigns = clientCampaigns
                }
            );
        }
        catch (
            UnauthorizedAccessException ex
        )
        {
            return Results.Json(
                new
                {
                    success = false,
                    error = ex.Message
                },
                statusCode: 401
            );
        }
        catch (Exception ex)
        {
            return Results.BadRequest(
                new
                {
                    success = false,
                    error = ex.Message
                }
            );
        }
    }
);

app.MapPost(
    "/game-api/campaigns",
    async (
        HttpRequest request,
        CreateDiscordCampaignRequest body,
        DiscordSupabaseService service
    ) =>
    {
        try
        {
            var discordUser =
                await service.VerifyDiscordUserAsync(
                    request.Headers.Authorization
                        .ToString()
                );


            var playerId =
                await service.GetOrCreatePlayerAsync(
                    discordUser
                );


            var campaignId =
                await service.CreateCampaignAsync(
                    playerId,
                    body.CampaignName
                );


            return Results.Ok(
                new
                {
                    success = true,
                    campaignId
                }
            );
        }
        catch (
            UnauthorizedAccessException ex
        )
        {
            return Results.Json(
                new
                {
                    success = false,
                    error = ex.Message
                },
                statusCode: 401
            );
        }
        catch (Exception ex)
        {
            return Results.BadRequest(
                new
                {
                    success = false,
                    error = ex.Message
                }
            );
        }
    }
);

app.MapPost(
    "/game-api/campaigns/join",
    async (
        HttpRequest request,
        JoinDiscordCampaignRequest body,
        DiscordSupabaseService service
    ) =>
    {
        try
        {
            var discordUser =
                await service.VerifyDiscordUserAsync(
                    request.Headers.Authorization
                        .ToString()
                );


            var playerId =
                await service.GetOrCreatePlayerAsync(
                    discordUser
                );


            var campaignId =
                await service.JoinCampaignAsync(
                    playerId,
                    body.JoinCode
                );


            return Results.Ok(
                new
                {
                    success = true,
                    campaignId
                }
            );
        }
        catch (
            UnauthorizedAccessException ex
        )
        {
            return Results.Json(
                new
                {
                    success = false,
                    error = ex.Message
                },
                statusCode: 401
            );
        }
        catch (Exception ex)
        {
            return Results.BadRequest(
                new
                {
                    success = false,
                    error = ex.Message
                }
            );
        }
    }
);

app.MapGet(
    "/game-api/character-options",
    () =>
    {
        return Results.Ok(
            new
            {
                success = true,

                species =
                    CharacterGenerationService.Species,

                baseSpecies =
                    CharacterGenerationService.BaseSpecies,

                classes =
                    CharacterGenerationService.Classes,

                backgrounds =
                    CharacterGenerationService.Backgrounds,

                alignments =
                    CharacterGenerationService.Alignments
            }
        );
    }
);
app.MapGet(
    "/game-api/campaigns/{campaignId:guid}/character",
    async (
        Guid campaignId,
        HttpRequest request,
        DiscordSupabaseService service
    ) =>
    {
        try
        {
            var discordUser =
                await service.VerifyDiscordUserAsync(
                    request.Headers.Authorization
                        .ToString()
                );


            var playerId =
                await service.GetOrCreatePlayerAsync(
                    discordUser
                );


            var character =
                await service.GetCharacterAsync(
                    playerId,
                    campaignId
                );


            if (character is null)
            {
                return Results.Ok(
                    new
                    {
                        success = true,
                        hasCharacter = false
                    }
                );
            }


            return Results.Ok(
                new
                {
                    success = true,

                    hasCharacter = true,

                    character = new
                    {
                        characterId =
                            character.CharacterId,

                        characterName =
                            character.CharacterName,

                        speciesName =
                            character.SpeciesName,

                        className =
                            character.ClassName,

                        backgroundName =
                            character.BackgroundName,

                        level =
                            character.Level,

                        experience =
                            character.Experience,

                        currentHp =
                            character.CurrentHp,

                        maxHp =
                            character.MaxHp,

                        armorClass =
                            character.ArmorClass,

                        strength =
                            character.Strength,

                        dexterity =
                            character.Dexterity,

                        constitution =
                            character.Constitution,

                        intelligence =
                            character.Intelligence,

                        wisdom =
                            character.Wisdom,

                        charisma =
                            character.Charisma,

                        initiative =
                            character.Initiative,

                        passivePerception =
                            character.PassivePerception,

                        proficiencyBonus =
                            character.ProficiencyBonus,

                        speed =
                            character.Speed,

                        sizeName =
                            character.SizeName,

                        gold =
                            character.Gold
                    }
                }
            );
        }
        catch (Exception ex)
        {
            return Results.BadRequest(
                new
                {
                    success = false,
                    error = ex.Message
                }
            );
        }
    }
);

app.MapPost(
    "/game-api/campaigns/{campaignId:guid}/characters/random",
    async (
        Guid campaignId,
        RandomCharacterRequest body,
        HttpRequest request,
        DiscordSupabaseService service
    ) =>
    {
        try
        {
            var discordUser =
                await service.VerifyDiscordUserAsync(
                    request.Headers.Authorization
                        .ToString()
                );


            var playerId =
                await service.GetOrCreatePlayerAsync(
                    discordUser
                );


            // Make sure they do not already have one.

            var existing =
                await service.GetCharacterAsync(
                    playerId,
                    campaignId
                );


            if (existing is not null)
            {
                return Results.BadRequest(
                    new
                    {
                        success = false,
                        error =
                            "You already have a character in this campaign."
                    }
                );
            }


            // Validate species.

            var species =
                CharacterGenerationService.Species
                    .FirstOrDefault(
                        value =>
                            value.Equals(
                                body.Species,
                                StringComparison.OrdinalIgnoreCase
                            )
                    );


            if (species is null)
            {
                return Results.BadRequest(
                    new
                    {
                        success = false,
                        error =
                            "Invalid species."
                    }
                );
            }


            // Validate class.

            var className =
                CharacterGenerationService.Classes
                    .FirstOrDefault(
                        value =>
                            value.Equals(
                                body.ClassName,
                                StringComparison.OrdinalIgnoreCase
                            )
                    );


            if (className is null)
            {
                return Results.BadRequest(
                    new
                    {
                        success = false,
                        error =
                            "Invalid class."
                    }
                );
            }


            // ==================================================
            // THIS IS YOUR EXISTING VB.NET CHARACTER GENERATOR
            // ==================================================

            var generator =
                new CharacterGenerationService();


            var character =
                generator.Generate(
                    species,
                    className,
                    1,
                    body.CharacterName ?? ""
                );


            // Save the generated character.

            var characterId =
                await service.CreateCharacterAsync(
                    playerId,
                    campaignId,
                    character
                );


            return Results.Ok(
                new
                {
                    success = true,

                    character = new
                    {
                        characterId,

                        characterName =
                            character.CharacterName,

                        speciesName =
                            character.SpeciesName,

                        className =
                            character.ClassName,

                        backgroundName =
                            character.BackgroundName,

                        level =
                            character.Level,

                        currentHp =
                            character.CurrentHitPoints,

                        maxHp =
                            character.MaxHitPoints,

                        armorClass =
                            character.ArmorClass,

                        strength =
                            character.Strength,

                        dexterity =
                            character.Dexterity,

                        constitution =
                            character.Constitution,

                        intelligence =
                            character.Intelligence,

                        wisdom =
                            character.Wisdom,

                        charisma =
                            character.Charisma,

                        initiative =
                            character.Initiative,

                        passivePerception =
                            character.PassivePerception,

                        proficiencyBonus =
                            character.ProficiencyBonus,

                        speed =
                            character.Speed,

                        sizeName =
                            character.SizeName,

                        gold =
                            character.Gold,

                        appearance =
                            character.Appearance,

                        personality =
                            character.Personality,

                        backstory =
                            character.Backstory,

                        languages =
                            character.Languages,

                        proficiencies =
                            character.Proficiencies,

                        features =
                            character.Features
                    }
                }
            );
        }
        catch (Exception ex)
        {
            return Results.BadRequest(
                new
                {
                    success = false,
                    error = ex.Message
                }
            );
        }
    }
);

app.MapPost(
    "/game-api/campaigns/{campaignId:guid}/characters/manual",
    async (
        Guid campaignId,
        ManualCharacterRequest body,
        HttpRequest request,
        DiscordSupabaseService service
    ) =>
    {
        try
        {
            var discordUser =
                await service.VerifyDiscordUserAsync(
                    request.Headers.Authorization
                        .ToString()
                );


            var playerId =
                await service.GetOrCreatePlayerAsync(
                    discordUser
                );


            // One character per player/campaign.

            var existing =
                await service.GetCharacterAsync(
                    playerId,
                    campaignId
                );


            if (existing is not null)
            {
                return Results.BadRequest(
                    new
                    {
                        success = false,

                        error =
                            "You already have a character in this campaign."
                    }
                );
            }


            // =================================================
            // CREATE USING VB.NET
            // =================================================

            var character =
                ManualCharacterCreationService.Create(

                    body.CharacterName,

                    body.Species,

                    body.SecondaryHeritage ?? "",

                    body.ClassName,

                    body.Background,

                    body.Alignment,

                    body.Level,

                    body.Strength,

                    body.Dexterity,

                    body.Constitution,

                    body.Intelligence,

                    body.Wisdom,

                    body.Charisma,

                    body.Appearance ?? "",

                    body.Personality ?? "",

                    body.Backstory ?? "",

                    body.Notes ?? ""
                );


            var characterId =
                await service.CreateCharacterAsync(
                    playerId,
                    campaignId,
                    character
                );


            return Results.Ok(
                new
                {
                    success = true,

                    character = new
                    {
                        characterId,

                        characterName =
                            character.CharacterName,

                        speciesName =
                            character.SpeciesName,

                        className =
                            character.ClassName,

                        backgroundName =
                            character.BackgroundName,

                        alignment =
                            character.Alignment,

                        level =
                            character.Level,

                        currentHp =
                            character.CurrentHitPoints,

                        maxHp =
                            character.MaxHitPoints,

                        armorClass =
                            character.ArmorClass,

                        strength =
                            character.Strength,

                        dexterity =
                            character.Dexterity,

                        constitution =
                            character.Constitution,

                        intelligence =
                            character.Intelligence,

                        wisdom =
                            character.Wisdom,

                        charisma =
                            character.Charisma,

                        initiative =
                            character.Initiative,

                        passivePerception =
                            character.PassivePerception,

                        proficiencyBonus =
                            character.ProficiencyBonus,

                        speed =
                            character.Speed,

                        sizeName =
                            character.SizeName,

                        gold =
                            character.Gold
                    }
                }
            );
        }
        catch (Exception ex)
        {
            return Results.BadRequest(
                new
                {
                    success = false,
                    error = ex.Message
                }
            );
        }
    }
);

app.MapGet(
    "/game-api/campaigns/{campaignId:guid}/character/setup",
    async (
        Guid campaignId,
        HttpRequest request,
        DiscordSupabaseService service
    ) =>
    {
        try
        {
            var discordUser =
                await service.VerifyDiscordUserAsync(
                    request.Headers.Authorization
                        .ToString()
                );


            var playerId =
                await service.GetOrCreatePlayerAsync(
                    discordUser
                );


            var state =
                await service.GetCharacterSetupStateAsync(
                    playerId,
                    campaignId
                );


            if (state is null)
            {
                return Results.NotFound(
                    new
                    {
                        success = false,
                        error =
                            "Character could not be found."
                    }
                );
            }


            return Results.Ok(
                new
                {
                    success = true,

                    characterId =
                        state.CharacterId,

                    equipmentComplete =
                        state.EquipmentComplete
                }
            );
        }
        catch (Exception ex)
        {
            return Results.BadRequest(
                new
                {
                    success = false,
                    error = ex.Message
                }
            );
        }
    }
);

app.MapGet(
    "/game-api/campaigns/{campaignId:guid}/starting-equipment",
    async (
        Guid campaignId,
        HttpRequest request,
        DiscordSupabaseService service
    ) =>
    {
        try
        {
            var discordUser =
                await service.VerifyDiscordUserAsync(
                    request.Headers.Authorization
                        .ToString()
                );


            var playerId =
                await service.GetOrCreatePlayerAsync(
                    discordUser
                );


            var character =
                await service.GetCharacterAsync(
                    playerId,
                    campaignId
                );


            if (character is null)
            {
                return Results.NotFound(
                    new
                    {
                        success = false,

                        error =
                            "Character could not be found."
                    }
                );
            }


            var classPackages =
                StartingEquipmentService
                    .GetClassPackages(
                        character.ClassName
                    );


            var backgroundPackages =
                StartingEquipmentService
                    .GetBackgroundPackages(
                        character.BackgroundName
                    );


            object MapPackage(
                StartingEquipmentPackage package,
                int index
            )
            {
                var choiceKind =
                    StartingEquipmentService
                        .GetChoiceKind(
                            package
                        );


                return new
                {
                    index,

                    label =
                        package.Label,

                    gold =
                        package.Gold,

                    choiceKind,

                    choiceOptions =
                        StartingEquipmentService
                            .GetChoiceOptions(
                                choiceKind
                            ),

                    items =
                        package.Items.Select(
                            item => new
                            {
                                itemName =
                                    item.ItemName,

                                quantity =
                                    item.Quantity,

                                choiceKind =
                                    item.ChoiceKind
                            }
                        )
                };
            }


            return Results.Ok(
                new
                {
                    success = true,

                    className =
                        character.ClassName,

                    backgroundName =
                        character.BackgroundName,

                    classPackages =
                        classPackages
                            .Select(
                                (item, index) =>
                                    MapPackage(
                                        item,
                                        index
                                    )
                            ),

                    backgroundPackages =
                        backgroundPackages
                            .Select(
                                (item, index) =>
                                    MapPackage(
                                        item,
                                        index
                                    )
                            )
                }
            );
        }
        catch (Exception ex)
        {
            return Results.BadRequest(
                new
                {
                    success = false,
                    error = ex.Message
                }
            );
        }
    }
);

app.MapPost(
    "/game-api/campaigns/{campaignId:guid}/starting-equipment",
    async (
        Guid campaignId,
        StartingEquipmentSelectionRequest body,
        HttpRequest request,
        DiscordSupabaseService service
    ) =>
    {
        try
        {
            var discordUser =
                await service.VerifyDiscordUserAsync(
                    request.Headers.Authorization
                        .ToString()
                );


            var playerId =
                await service.GetOrCreatePlayerAsync(
                    discordUser
                );


            var character =
                await service.GetCharacterAsync(
                    playerId,
                    campaignId
                );


            if (character is null)
            {
                return Results.NotFound(
                    new
                    {
                        success = false,

                        error =
                            "Character could not be found."
                    }
                );
            }


            var classPackages =
                StartingEquipmentService
                    .GetClassPackages(
                        character.ClassName
                    );


            var backgroundPackages =
                StartingEquipmentService
                    .GetBackgroundPackages(
                        character.BackgroundName
                    );


            if (
                body.ClassPackageIndex < 0 ||
                body.ClassPackageIndex >=
                    classPackages.Count
            )
            {
                return Results.BadRequest(
                    new
                    {
                        success = false,

                        error =
                            "Invalid class equipment package."
                    }
                );
            }


            if (
                body.BackgroundPackageIndex < 0 ||
                body.BackgroundPackageIndex >=
                    backgroundPackages.Count
            )
            {
                return Results.BadRequest(
                    new
                    {
                        success = false,

                        error =
                            "Invalid background equipment package."
                    }
                );
            }


            var classPackage =
                classPackages[
                    body.ClassPackageIndex
                ];


            var backgroundPackage =
                backgroundPackages[
                    body.BackgroundPackageIndex
                ];


            var classChoice =
                ResolveEquipmentChoice(
                    classPackage,
                    body.ClassChoice
                );


            var backgroundChoice =
                ResolveEquipmentChoice(
                    backgroundPackage,
                    body.BackgroundChoice
                );


            var items =
                new List<
                    DiscordStartingInventoryItem
                >();


            foreach (
                var entry in
                    StartingEquipmentService
                        .ResolveItems(
                            classPackage,
                            classChoice
                        )
            )
            {
                items.Add(
                    new DiscordStartingInventoryItem
                    {
                        ItemName =
                            entry.ItemName,

                        Quantity =
                            entry.Quantity,

                        Equipped =
                            StartingEquipmentService
                                .ShouldStartEquipped(
                                    entry.ItemName
                                ),

                        SourceName =
                            "Class",

                        Notes =
                            "2024 class starting equipment"
                    }
                );
            }


            foreach (
                var entry in
                    StartingEquipmentService
                        .ResolveItems(
                            backgroundPackage,
                            backgroundChoice
                        )
            )
            {
                items.Add(
                    new DiscordStartingInventoryItem
                    {
                        ItemName =
                            entry.ItemName,

                        Quantity =
                            entry.Quantity,

                        Equipped =
                            StartingEquipmentService
                                .ShouldStartEquipped(
                                    entry.ItemName
                                ),

                        SourceName =
                            "Background",

                        Notes =
                            "2024 background starting equipment"
                    }
                );
            }


            var gold =
                classPackage.Gold +
                backgroundPackage.Gold;


            await service.SaveStartingEquipmentAsync(
                playerId,
                campaignId,
                gold,
                items
            );


            return Results.Ok(
                new
                {
                    success = true,

                    gold,

                    itemCount =
                        items.Sum(
                            item =>
                                item.Quantity
                        )
                }
            );
        }
        catch (Exception ex)
        {
            return Results.BadRequest(
                new
                {
                    success = false,
                    error = ex.Message
                }
            );
        }
    }
);

string ResolveEquipmentChoice(
    StartingEquipmentPackage package,
    string? requestedChoice
)
{
    var choiceKind =
        StartingEquipmentService
            .GetChoiceKind(
                package
            );


    if (
        string.IsNullOrWhiteSpace(
            choiceKind
        )
    )
    {
        return string.Empty;
    }


    var choices =
        StartingEquipmentService
            .GetChoiceOptions(
                choiceKind
            );


    var match =
        choices.FirstOrDefault(
            choice =>
                choice.Equals(
                    requestedChoice ?? "",
                    StringComparison.OrdinalIgnoreCase
                )
        );


    if (match is null)
    {
        throw new ArgumentException(
            "Choose a valid starting equipment option."
        );
    }


    return match;
}

app.Run();


// ---------------------------------------------------------
// REQUEST MODEL
// ---------------------------------------------------------

public sealed record DiceRollRequest(
    int Count,
    int Sides,
    int Modifier,
    bool Advantage,
    bool Disadvantage
);

public sealed record CreateDiscordCampaignRequest(
    string CampaignName
);


public sealed record JoinDiscordCampaignRequest(
    string JoinCode
);

public sealed record RandomCharacterRequest(
    string? CharacterName,
    string Species,
    string ClassName
);

public sealed record ManualCharacterRequest(
    string CharacterName,
    string Species,
    string? SecondaryHeritage,
    string ClassName,
    string Background,
    string Alignment,
    int Level,
    int Strength,
    int Dexterity,
    int Constitution,
    int Intelligence,
    int Wisdom,
    int Charisma,
    string? Appearance,
    string? Personality,
    string? Backstory,
    string? Notes
);

public sealed record StartingEquipmentSelectionRequest(
    int ClassPackageIndex,
    string? ClassChoice,
    int BackgroundPackageIndex,
    string? BackgroundChoice
);
