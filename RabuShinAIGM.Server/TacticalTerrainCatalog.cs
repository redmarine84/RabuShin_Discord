using System;
using System.Collections.Generic;
using System.Linq;

public static partial class TacticalTerrainCatalog
{
    private const int GridColumns = 20;
    private const int GridRows = 20;
    private const int FeetPerSquare = 5;

    [Flags]
    private enum TerrainFlags : byte
    {
        None = 0,
        MoveBlock = 1,
        LosBlock = 2,
        ClosedDoor = 4,
        Difficult = 8,
        HalfCover = 16,
        Cliff = 32,
        BridgeOrStairs = 64,
        OpenDoor = 128
    }

    public static TacticalTerrainMap? Find(string? locationKey)
    {
        if (string.IsNullOrWhiteSpace(locationKey)) return null;
        return Maps.TryGetValue(locationKey.Trim(), out var map) ? map : null;
    }

    public static TacticalPathResult FindPath(
        string locationKey,
        int startX,
        int startY,
        int destinationX,
        int destinationY,
        IReadOnlyDictionary<int, bool>? doorStates = null,
        IReadOnlySet<(int X, int Y)>? occupiedSquares = null)
    {
        var map = Find(locationKey);
        if (map is null)
            return TacticalPathResult.Failure($"No tactical terrain definition exists for '{locationKey}'.");

        if (!InsideGrid(startX, startY) || !InsideGrid(destinationX, destinationY))
            return TacticalPathResult.Failure("Tactical destination must be inside the 20x20 encounter grid.");

        if (startX == destinationX && startY == destinationY)
            return new TacticalPathResult(true, 0, new[] { new TacticalGridPoint(startX, startY) }, false, string.Empty);

        if (occupiedSquares is not null && occupiedSquares.Contains((destinationX, destinationY)))
            return TacticalPathResult.Failure("Another active combatant already occupies that square.");

        var start = (X: startX, Y: startY);
        var goal = (X: destinationX, Y: destinationY);
        var frontier = new PriorityQueue<(int X, int Y), int>();
        frontier.Enqueue(start, 0);
        var cost = new Dictionary<(int X, int Y), int> { [start] = 0 };
        var cameFrom = new Dictionary<(int X, int Y), (int X, int Y)>();
        var difficultUsed = false;

        while (frontier.Count > 0)
        {
            var current = frontier.Dequeue();
            if (current == goal) break;

            foreach (var next in Neighbors(current.X, current.Y))
            {
                if (occupiedSquares is not null && next != goal && next != start && occupiedSquares.Contains(next))
                    continue;

                if (MovementBlocked(map, current.X, current.Y, next.X, next.Y, doorStates, out _))
                    continue;

                var difficult = IsDifficultStep(map, current.X, current.Y, next.X, next.Y);
                var stepCost = difficult ? FeetPerSquare * 2 : FeetPerSquare;
                var newCost = cost[current] + stepCost;
                if (cost.TryGetValue(next, out var oldCost) && newCost >= oldCost) continue;

                cost[next] = newCost;
                cameFrom[next] = current;
                var priority = newCost + Chebyshev(next.X, next.Y, goal.X, goal.Y) * FeetPerSquare;
                frontier.Enqueue(next, priority);
            }
        }

        if (!cost.TryGetValue(goal, out var finalCost))
        {
            var directBlock = DescribeDirectBlock(map, startX, startY, destinationX, destinationY, doorStates);
            return TacticalPathResult.Failure(string.IsNullOrWhiteSpace(directBlock)
                ? "No walkable path reaches that square from your current position."
                : directBlock);
        }

        var reversed = new List<TacticalGridPoint> { new(goal.X, goal.Y) };
        var cursor = goal;
        while (cursor != start)
        {
            cursor = cameFrom[cursor];
            reversed.Add(new TacticalGridPoint(cursor.X, cursor.Y));
        }
        reversed.Reverse();

        for (var i = 1; i < reversed.Count; i++)
        {
            if (IsDifficultStep(map, reversed[i - 1].X, reversed[i - 1].Y, reversed[i].X, reversed[i].Y))
            {
                difficultUsed = true;
                break;
            }
        }

        return new TacticalPathResult(true, finalCost, reversed, difficultUsed, string.Empty);
    }

    public static TacticalLineOfSightResult CheckLineOfSight(
        string locationKey,
        int fromX,
        int fromY,
        int toX,
        int toY,
        IReadOnlyDictionary<int, bool>? doorStates = null)
    {
        var map = Find(locationKey);
        if (map is null)
            return new TacticalLineOfSightResult(false, "blocked", "No tactical terrain definition is available.");

        var halfCover = false;
        foreach (var sample in SegmentSamples(map, fromX, fromY, toX, toY))
        {
            var flags = (TerrainFlags)map.Flags[sample.Index];
            var openDoor = (flags & TerrainFlags.OpenDoor) != 0 || HasNearbyFlag(map, sample.X, sample.Y, TerrainFlags.OpenDoor, 2);
            if ((flags & TerrainFlags.ClosedDoor) != 0)
            {
                var doorId = map.DoorIds[sample.Index];
                var isOpen = doorId > 0 && doorStates is not null && doorStates.TryGetValue(doorId, out var open) && open;
                if (!isOpen)
                    return new TacticalLineOfSightResult(false, "blocked", doorId > 0 ? $"Closed door {doorId} blocks line of sight." : "A closed door blocks line of sight.");
            }

            if ((flags & TerrainFlags.LosBlock) != 0 && !openDoor)
                return new TacticalLineOfSightResult(false, "blocked", "A wall or building blocks line of sight.");

            if ((flags & TerrainFlags.HalfCover) != 0)
                halfCover = true;
        }

        return halfCover
            ? new TacticalLineOfSightResult(true, "half", "The target is visible but has half cover from a partial obstruction.")
            : new TacticalLineOfSightResult(true, "none", "Clear line of sight.");
    }

    public static TacticalDoorDefinition? FindNearestDoor(string locationKey, int gridX, int gridY, double maxSquares = 2.5)
    {
        var map = Find(locationKey);
        if (map is null || map.Doors.Count == 0) return null;
        TacticalDoorDefinition? best = null;
        var bestDistance = double.MaxValue;
        foreach (var door in map.Doors)
        {
            var dx = ((gridX + 0.5) / GridColumns) - door.CenterX;
            var dy = ((gridY + 0.5) / GridRows) - door.CenterY;
            var distSquares = Math.Sqrt(Math.Pow(dx * GridColumns, 2) + Math.Pow(dy * GridRows, 2));
            if (distSquares < bestDistance)
            {
                bestDistance = distSquares;
                best = door;
            }
        }
        return bestDistance <= maxSquares ? best : null;
    }

    public static IReadOnlyList<TacticalDoorDefinition> GetDoors(string locationKey) =>
        Find(locationKey)?.Doors ?? Array.Empty<TacticalDoorDefinition>();

    private static bool MovementBlocked(
        TacticalTerrainMap map,
        int fromX,
        int fromY,
        int toX,
        int toY,
        IReadOnlyDictionary<int, bool>? doorStates,
        out string reason)
    {
        foreach (var sample in SegmentSamples(map, fromX, fromY, toX, toY))
        {
            var flags = (TerrainFlags)map.Flags[sample.Index];
            var openDoor = (flags & TerrainFlags.OpenDoor) != 0 || HasNearbyFlag(map, sample.X, sample.Y, TerrainFlags.OpenDoor, 2);
            var bridge = (flags & TerrainFlags.BridgeOrStairs) != 0 || HasNearbyFlag(map, sample.X, sample.Y, TerrainFlags.BridgeOrStairs, 2);

            if ((flags & TerrainFlags.ClosedDoor) != 0)
            {
                var doorId = map.DoorIds[sample.Index];
                var isOpen = doorId > 0 && doorStates is not null && doorStates.TryGetValue(doorId, out var open) && open;
                if (!isOpen)
                {
                    reason = doorId > 0
                        ? $"Closed door {doorId} blocks that path. Tell the Game Master you open the door first."
                        : "A closed door blocks that path.";
                    return true;
                }
            }

            if ((flags & TerrainFlags.MoveBlock) != 0 && !openDoor)
            {
                reason = "A wall or building blocks that path.";
                return true;
            }

            if ((flags & TerrainFlags.Cliff) != 0 && !bridge)
            {
                reason = "A cliff or ledge blocks normal movement along that path.";
                return true;
            }
        }

        reason = string.Empty;
        return false;
    }

    private static string DescribeDirectBlock(TacticalTerrainMap map, int fromX, int fromY, int toX, int toY, IReadOnlyDictionary<int, bool>? doorStates)
    {
        return MovementBlocked(map, fromX, fromY, toX, toY, doorStates, out var reason) ? reason : string.Empty;
    }

    private static bool IsDifficultStep(TacticalTerrainMap map, int fromX, int fromY, int toX, int toY)
    {
        if (GridCellHasFlag(map, toX, toY, TerrainFlags.Difficult)) return true;
        foreach (var sample in SegmentSamples(map, fromX, fromY, toX, toY))
        {
            var flags = (TerrainFlags)map.Flags[sample.Index];
            if ((flags & TerrainFlags.BridgeOrStairs) != 0) continue;
            if ((flags & TerrainFlags.Difficult) != 0) return true;
        }
        return false;
    }

    private static bool GridCellHasFlag(TacticalTerrainMap map, int gridX, int gridY, TerrainFlags wanted)
    {
        var x0 = gridX * map.MaskWidth / GridColumns;
        var x1 = Math.Max(x0 + 1, (gridX + 1) * map.MaskWidth / GridColumns);
        var y0 = gridY * map.MaskHeight / GridRows;
        var y1 = Math.Max(y0 + 1, (gridY + 1) * map.MaskHeight / GridRows);
        var total = 0;
        var hits = 0;
        for (var y = y0; y < y1; y++)
        {
            for (var x = x0; x < x1; x++)
            {
                total++;
                if ((((TerrainFlags)map.Flags[y * map.MaskWidth + x]) & wanted) != 0) hits++;
            }
        }
        // A small marked portion is enough to make a 5-ft square terrain-aware,
        // while avoiding a single anti-aliased boundary pixel changing the whole square.
        return hits >= Math.Max(2, total / 40);
    }

    private static IEnumerable<(int X, int Y, int Index)> SegmentSamples(TacticalTerrainMap map, int fromX, int fromY, int toX, int toY)
    {
        var x0 = (int)Math.Round(((fromX + 0.5) / GridColumns) * (map.MaskWidth - 1));
        var y0 = (int)Math.Round(((fromY + 0.5) / GridRows) * (map.MaskHeight - 1));
        var x1 = (int)Math.Round(((toX + 0.5) / GridColumns) * (map.MaskWidth - 1));
        var y1 = (int)Math.Round(((toY + 0.5) / GridRows) * (map.MaskHeight - 1));
        var dx = Math.Abs(x1 - x0);
        var sx = x0 < x1 ? 1 : -1;
        var dy = -Math.Abs(y1 - y0);
        var sy = y0 < y1 ? 1 : -1;
        var error = dx + dy;
        var x = x0;
        var y = y0;
        while (true)
        {
            if (x >= 0 && x < map.MaskWidth && y >= 0 && y < map.MaskHeight)
                yield return (x, y, y * map.MaskWidth + x);
            if (x == x1 && y == y1) break;
            var e2 = 2 * error;
            if (e2 >= dy) { error += dy; x += sx; }
            if (e2 <= dx) { error += dx; y += sy; }
        }
    }

    private static bool HasNearbyFlag(TacticalTerrainMap map, int x, int y, TerrainFlags wanted, int radius)
    {
        for (var yy = Math.Max(0, y - radius); yy <= Math.Min(map.MaskHeight - 1, y + radius); yy++)
            for (var xx = Math.Max(0, x - radius); xx <= Math.Min(map.MaskWidth - 1, x + radius); xx++)
                if ((((TerrainFlags)map.Flags[yy * map.MaskWidth + xx]) & wanted) != 0) return true;
        return false;
    }

    private static IEnumerable<(int X, int Y)> Neighbors(int x, int y)
    {
        for (var dy = -1; dy <= 1; dy++)
        {
            for (var dx = -1; dx <= 1; dx++)
            {
                if (dx == 0 && dy == 0) continue;
                var nx = x + dx;
                var ny = y + dy;
                if (InsideGrid(nx, ny)) yield return (nx, ny);
            }
        }
    }

    private static bool InsideGrid(int x, int y) => x >= 0 && x < GridColumns && y >= 0 && y < GridRows;
    private static int Chebyshev(int x1, int y1, int x2, int y2) => Math.Max(Math.Abs(x2 - x1), Math.Abs(y2 - y1));
}

public sealed record TacticalTerrainMap(
    string LocationKey,
    int SourceWidth,
    int SourceHeight,
    int MaskWidth,
    int MaskHeight,
    byte[] Flags,
    byte[] DoorIds,
    IReadOnlyList<TacticalDoorDefinition> Doors);

public sealed record TacticalDoorDefinition(
    int DoorId,
    double CenterX,
    double CenterY,
    double MinX,
    double MinY,
    double MaxX,
    double MaxY);

public sealed record TacticalGridPoint(int X, int Y);

public sealed record TacticalPathResult(
    bool Success,
    int CostFt,
    IReadOnlyList<TacticalGridPoint> Path,
    bool UsesDifficultTerrain,
    string Error)
{
    public static TacticalPathResult Failure(string error) => new(false, 0, Array.Empty<TacticalGridPoint>(), false, error);
}

public sealed record TacticalLineOfSightResult(bool Visible, string Cover, string Reason);
