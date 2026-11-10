-- Shared deterministic brush field: the seed travels with the edit, never a
-- list of random secondary spheres or client-specific math.random state.
local V = GVoxel
local floor, sqrt = math.floor, math.sqrt
local strideX, strideY, strideZ = 73856093, 19349663, 83492791
local modulus = 2147483647

local function hash(n)
	return (((n % modulus) * 48271) % modulus) / 1073741823.5 - 1
end

local function noise(x, y, z, seed)
	local ix, iy, iz = floor(x), floor(y), floor(z)
	local u, v, w = x - ix, y - iy, z - iz
	u = u * u * (3 - 2 * u)
	v = v * v * (3 - 2 * v)
	w = w * w * (3 - 2 * w)
	-- Neighbours differ only by an integer stride. These small lattice
	-- coordinates and network seeds keep all eight sums exact in Lua.
	local a = ix * strideX + iy * strideY + iz * strideZ + seed * 104729
	local b, c = a + strideY, a + strideZ
	local d = c + strideY
	local left = 1 - u
	local ab = (hash(a) * left + hash(a + strideX) * u) * (1 - v)
		+ (hash(b) * left + hash(b + strideX) * u) * v
	local cd = (hash(c) * left + hash(c + strideX) * u) * (1 - v)
		+ (hash(d) * left + hash(d + strideX) * u) * v
	return ab * (1 - w) + cd * w
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
