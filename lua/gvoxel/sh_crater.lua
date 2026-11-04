-- Shared deterministic brush field: the seed travels with the edit, never a
-- list of random secondary spheres or client-specific math.random state.
local V = GVoxel
local floor, sqrt = math.floor, math.sqrt
local function hash(x, y, z, seed)
	local n = (x * 73856093 + y * 19349663 + z * 83492791 + seed * 104729) % 2147483647
	return ((n * 48271) % 2147483647) / 1073741823.5 - 1
end
local function noise(x, y, z, seed)
	local ix, iy, iz = floor(x), floor(y), floor(z)
	local u, v, w = x - ix, y - iy, z - iz
	u = u * u * (3 - 2 * u)
	v = v * v * (3 - 2 * v)
	w = w * w * (3 - 2 * w)
	local function row(y, z)
		return hash(ix, y, z, seed) * (1 - u) + hash(ix + 1, y, z, seed) * u
	end
	return (row(iy, iz) * (1 - v) + row(iy + 1, iz) * v) * (1 - w)
		+ (row(iy, iz + 1) * (1 - v) + row(iy + 1, iz + 1) * v) * w
end

function V.BrushInnerRadius(radius, seed, centerZ, floorZ)
	local core = seed and seed ~= 0 and radius * 0.6 or radius
	-- A clipped blast's enclosing sphere is not a guaranteed empty core:
	-- cells below the preserved floor must never use the full-sphere shortcut.
	if floorZ ~= nil then
		return math.min(core, math.max(0, centerZ - floorZ))
	end
	return core
end

-- Negative = inside the removal/addition brush. Direction-only noise keeps
-- every radial segment connected to the core, without detached void pockets.
-- The deformed radius is bounded by [0.6 R, R], retaining spherical broadphase.
function V.BrushSample(p, center, radius, seed, floorZ)
	local x, y, z = p.x - center.x, p.y - center.y, p.z - center.z
	local distance = sqrt(x * x + y * y + z * z)
	if not seed or seed == 0 then
		local value = distance - radius
		return floorZ ~= nil and math.max(value, floorZ - p.z) or value
	end
	if distance < 1e-9 then
		local value = -radius * 0.8
		return floorZ ~= nil and math.max(value, floorZ - p.z) or value
	end
	x = x / distance
	y = y / distance
	z = z / distance
	local scale = 0.8
		+ 0.12 * noise(x * 1.7, y * 1.7, z * 1.7, seed)
		+ 0.055 * noise(x * 3.4, y * 3.4, z * 3.4, seed + 101)
		+ 0.025 * noise(x * 6.8, y * 6.8, z * 6.8, seed + 211)
	local value = distance - radius * scale
	return floorZ ~= nil and math.max(value, floorZ - p.z) or value
end
