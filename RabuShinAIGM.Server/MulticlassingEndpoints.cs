using System.Text.Json;

public static class MulticlassingEndpoints
{
    public static WebApplication MapMulticlassingEndpoints(this WebApplication app)
    {
        app.MapGet("/game-api/multiclass/rules", () => Results.Ok(new
        {
            success = true,
            rules = MulticlassRules.GetRulesForClient()
        }));

        app.MapGet("/game-api/campaigns/{campaignId:guid}/multiclass", async (
            Guid campaignId, HttpRequest request, DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);
                await service.TouchCampaignPresenceAsync(playerId, campaignId);
                var state = await service.GetMulticlassStateAsync(playerId, campaignId);
                return Results.Ok(new { success = true, state });
            }
            catch (UnauthorizedAccessException ex) { return Results.Json(new { success = false, error = ex.Message }, statusCode: 403); }
            catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
        });

        app.MapPost("/game-api/campaigns/{campaignId:guid}/multiclass/preview", async (
            Guid campaignId, MulticlassPlanRequest body, HttpRequest request, DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);
                var state = await service.GetMulticlassStateAsync(playerId, campaignId);
                var preview = MulticlassRules.Preview(state, body.Plan);
                return Results.Ok(new { success = true, preview });
            }
            catch (UnauthorizedAccessException ex) { return Results.Json(new { success = false, error = ex.Message }, statusCode: 403); }
            catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
        });

        app.MapPost("/game-api/campaigns/{campaignId:guid}/multiclass/apply", async (
            Guid campaignId, MulticlassPlanRequest body, HttpRequest request, DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);
                var state = await service.GetMulticlassStateAsync(playerId, campaignId);
                _ = MulticlassRules.Preview(state, body.Plan); // Server-side validation before mutation.
                var result = await service.ApplyMulticlassLevelPlanAsync(playerId, campaignId, body.Plan);
                return Results.Ok(new { success = true, result });
            }
            catch (UnauthorizedAccessException ex) { return Results.Json(new { success = false, error = ex.Message }, statusCode: 403); }
            catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
        });

        app.MapPost("/game-api/campaigns/{campaignId:guid}/multiclass/hit-die", async (
            Guid campaignId, MulticlassHitDieRequest body, HttpRequest request, DiscordSupabaseService service) =>
        {
            try
            {
                var user = await service.VerifyDiscordUserAsync(request.Headers.Authorization.ToString());
                var playerId = await service.GetOrCreatePlayerAsync(user);
                var result = await service.SpendMulticlassHitDieAsync(playerId, campaignId, body.DieSides);
                return Results.Ok(new { success = true, result });
            }
            catch (UnauthorizedAccessException ex) { return Results.Json(new { success = false, error = ex.Message }, statusCode: 403); }
            catch (Exception ex) { return Results.BadRequest(new { success = false, error = ex.Message }); }
        });

        return app;
    }
}

public sealed class MulticlassPlanRequest
{
    public JsonElement Plan { get; set; } = JsonSerializer.Deserialize<JsonElement>("[]");
}

public sealed class MulticlassHitDieRequest
{
    public int? DieSides { get; set; }
}
