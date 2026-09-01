using System;
using System.Collections.Generic;
using System.Linq;

public static partial class TacticalTerrainCatalog
{
    public static bool IsSafeInitialSpawnSquare(
        string locationKey,
        int gridX,
        int gridY,
        IReadOnlyDictionary<int, bool>? doorStates = null,
        bool allowDifficultTerrain = false,
        bool allowHalfCover = false)
    {
        var map = Find(locationKey);
        if (map is null || !InsideGrid(gridX, gridY)) return false;

        if (GridCellHasFlag(map, gridX, gridY, TerrainFlags.MoveBlock) ||
            GridCellHasFlag(map, gridX, gridY, TerrainFlags.LosBlock) ||
            GridCellHasFlag(map, gridX, gridY, TerrainFlags.Cliff) ||
            GridCellHasFlag(map, gridX, gridY, TerrainFlags.ClosedDoor))
            return false;

        if (!allowDifficultTerrain && GridCellHasFlag(map, gridX, gridY, TerrainFlags.Difficult))
            return false;
        if (!allowHalfCover && GridCellHasFlag(map, gridX, gridY, TerrainFlags.HalfCover))
            return false;

        return true;
    }

    public static TacticalSpawnPoint FindInitialPartyAnchor(
        string locationKey,
        IReadOnlyDictionary<int, bool>? doorStates = null,
        IReadOnlySet<(int X, int Y)>? occupiedSquares = null,
        bool allowDifficultTerrain = false,
        bool allowHalfCover = false)
    {
        var map = Find(locationKey)
            ?? throw new InvalidOperationException($"No tactical terrain definition exists for '{locationKey}'.");

        var candidates = new List<(int X, int Y, int Score)>();
        for (var y = 1; y < GridRows - 1; y++)
        {
            for (var x = 1; x < GridColumns - 1; x++)
            {
                if (occupiedSquares?.Contains((x, y)) == true) continue;
                if (!IsSafeInitialSpawnSquare(locationKey, x, y, doorStates, allowDifficultTerrain, allowHalfCover)) continue;

                var clearNeighbors = Neighbors(x, y)
                    .Count(p => IsSafeInitialSpawnSquare(locationKey, p.X, p.Y, doorStates, allowDifficultTerrain, allowHalfCover));
                if (clearNeighbors < 4) continue;

                // Prefer broad open ground near the center of the encounter map. The barrier
                // masks do not label roads directly, so this is the safest general proxy for
                // a path/clearing while still avoiding buildings, walls, cliffs and obstacles.
                var centerDistance = Math.Abs(x - 9) + Math.Abs(y - 9);
                var edgeDistance = Math.Min(Math.Min(x, GridColumns - 1 - x), Math.Min(y, GridRows - 1 - y));
                var score = clearNeighbors * 50 - centerDistance * 3 + edgeDistance;
                candidates.Add((x, y, score));
            }
        }

        var best = candidates.OrderByDescending(c => c.Score).ThenBy(c => c.Y).ThenBy(c => c.X).FirstOrDefault();
        if (candidates.Count == 0)
            throw new InvalidOperationException($"No safe initial tactical square could be found on '{locationKey}'.");
        return new TacticalSpawnPoint(best.X, best.Y, 0, "open party anchor");
    }

    public static TacticalSpawnPoint FindInitialSpawnNear(
        string locationKey,
        int targetX,
        int targetY,
        int desiredDistanceFeet,
        int maximumDistanceFeet,
        IReadOnlyDictionary<int, bool>? doorStates = null,
        IReadOnlySet<(int X, int Y)>? occupiedSquares = null,
        bool requireLineOfSight = true,
        bool allowDifficultTerrain = false,
        bool allowHalfCover = false)
    {
        var map = Find(locationKey)
            ?? throw new InvalidOperationException($"No tactical terrain definition exists for '{locationKey}'.");

        var desired = Math.Clamp(desiredDistanceFeet, FeetPerSquare, (GridColumns - 1) * FeetPerSquare);
        var maximum = Math.Clamp(Math.Max(desired, maximumDistanceFeet), FeetPerSquare, (GridColumns - 1) * FeetPerSquare);
        var candidates = new List<(int X, int Y, int Distance, int Score, string Note)>();

        void Collect(bool allowDifficult, bool allowCover, bool requireLos)
        {
            for (var y = 0; y < GridRows; y++)
            {
                for (var x = 0; x < GridColumns; x++)
                {
                    if (x == targetX && y == targetY) continue;
                    if (occupiedSquares?.Contains((x, y)) == true) continue;
                    if (!IsSafeInitialSpawnSquare(locationKey, x, y, doorStates, allowDifficult, allowCover)) continue;

                    var distance = Chebyshev(targetX, targetY, x, y) * FeetPerSquare;
                    if (distance < FeetPerSquare || distance > maximum) continue;

                    var los = CheckLineOfSight(locationKey, targetX, targetY, x, y, doorStates);
                    if (requireLos && !los.Visible) continue;

                    // Close/melee staging must also be reachable within the stated engagement
                    // distance; a wall/cliff detour cannot count as "10 feet away" in practice.
                    if (maximum <= 15)
                    {
                        var path = FindPath(locationKey, targetX, targetY, x, y, doorStates, occupiedSquares);
                        if (!path.Success || path.CostFt > maximum) continue;
                    }

                    var distancePenalty = Math.Abs(distance - desired) * 20;
                    var difficultPenalty = GridCellHasFlag(map, x, y, TerrainFlags.Difficult) ? 100 : 0;
                    var coverPenalty = GridCellHasFlag(map, x, y, TerrainFlags.HalfCover) ? 40 : 0;
                    var edgePenalty = Math.Min(Math.Min(x, GridColumns - 1 - x), Math.Min(y, GridRows - 1 - y)) == 0 ? 10 : 0;
                    var score = -(distancePenalty + difficultPenalty + coverPenalty + edgePenalty);
                    candidates.Add((x, y, distance, score, los.Cover == "half" ? "half cover" : "clear"));
                }
            }
        }

        Collect(allowDifficultTerrain, allowHalfCover, requireLineOfSight);
        // Terrain allowances are literal: if the fiction did not explicitly allow difficult
        // terrain or half cover, staging must not silently place a token there.
        // A ranged/visible engagement that explicitly requires line of sight must never
        // silently fall back to an obstructed square. Fail staging instead so the GM can
        // choose a different legal range/target rather than begin combat through a wall.
        if (candidates.Count == 0)
            throw new InvalidOperationException($"No legal initial tactical square could be found within {maximum} ft. of the target.");

        var best = candidates
            .OrderByDescending(c => c.Score)
            .ThenBy(c => Math.Abs(c.Distance - desired))
            .ThenBy(c => c.Y)
            .ThenBy(c => c.X)
            .First();
        return new TacticalSpawnPoint(best.X, best.Y, best.Distance, best.Note);
    }
}

public sealed record TacticalSpawnPoint(int GridX, int GridY, int DistanceFeet, string Note);
