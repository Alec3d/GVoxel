-- Shared spatial lookup. Regions remain independent, bounded and non-overlapping.
local V = GVoxel
V.MaxZones = 1
function V.ZoneDistanceSquared(r, point)
    local d = 0
    for _, axis in ipairs({"x", "y", "z"}) do
        local q = math.max(r.origin[axis] - point[axis], 0, point[axis] - r.origin[axis] - V.RegionAxisSize(r, axis))
        d = d + q * q
    end
    return d
end
function V.NearestZone(records, point, ready)
    local best, distance
    for _, record in pairs(records) do
        local r = record.region
        if r and (not ready or ready(record)) then
            local d = V.ZoneDistanceSquared(r, point)
            if not distance or d < distance or (d == distance and r.id < best.region.id) then best, distance = record, d end
        end
    end
    return best
end
function V.RayZone(records, origin, direction, reach, ready)
    local best, distance
    for _, record in pairs(records) do
        if record.region and (not ready or ready(record)) then
            local entry = V.CubeRayInterval(record.region, origin, direction)
            if entry and entry <= reach and (not distance or entry < distance) then best, distance = record, entry end
        end
    end
    return best
end
function V.ZonesOverlap(a, b)
    for _, axis in ipairs({"x", "y", "z"}) do
        if a.origin[axis] + V.RegionAxisSize(a, axis) <= b.origin[axis]
            or b.origin[axis] + V.RegionAxisSize(b, axis) <= a.origin[axis] then return false end
    end
    return true
end
