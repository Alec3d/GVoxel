-- Shared surface seam: edited terrain inside, original BSP outside. No world
-- collision toggle, global trace replacement, or per-car mesh is involved.
local V = GVoxel
local axes = { "x", "y", "z" }
local basis = { Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }
local reverseBasis = { -basis[1], -basis[2], -basis[3] }
V.VehicleHaloWidth = 1024
local tileSize = 256
local EPS = 0.00001
local function clipBox(poly, low, high)
	for i, axis in ipairs(axes) do
		poly = V.ClipBSPPolygon(poly, basis[i], high[axis])
		poly = V.ClipBSPPolygon(poly, reverseBasis[i], -low[axis])
		if #poly < 3 then
			break
		end
	end
	return poly
end
local function bounds(poly)
	local low, high = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for _, p in ipairs(poly) do
		for _, axis in ipairs(axes) do
			low[axis] = math.min(low[axis], p[axis])
			high[axis] = math.max(high[axis], p[axis])
		end
	end
	return low, high
end
function V.PrepareVehicleExterior(r, data, checkpoint)
	if r.vehicleExterior then
		return r.vehicleExterior
	end
	local width = V.VehicleHaloWidth
	-- Only server-side native colliders consume the triangle soup. Both
	-- realms still precompute all swept hulls before publishing the seam.
	local storeVertices = not CLIENT
	local outerLow, outerHigh = Vector(-width, -width, -width), V.RegionSize(r) + Vector(width, width, width)
	local exterior = { groups = {}, width = width, tileSize = tileSize, triangles = 0 }
	local function store(poly, normal)
		if #poly < 3 then
			return
		end
		local low, high = bounds(poly)
		local lo, hi = {}, {}
		for _, axis in ipairs(axes) do
			lo[axis] = math.floor(low[axis] / tileSize)
			hi[axis] = math.max(lo[axis], math.floor((high[axis] - EPS) / tileSize))
		end
		for z = lo.z, hi.z do
			for y = lo.y, hi.y do
				for x = lo.x, hi.x do
					local origin = Vector(x, y, z) * tileSize
					local part = clipBox(poly, origin, origin + Vector(tileSize, tileSize, tileSize))
					local key = V.ChunkKey(x, y, z)
					for i = 2, #part - 1 do
						local a, b, c = part[1], part[i], part[i + 1]
						local cross = (b - a):Cross(c - a)
						if V.PhysicsTriangleUsable(a, b, c, cross) then
							if cross:Dot(normal) > 0 then
								b, c = c, b
							end
							local group = exterior.groups[key]
							if not group then
								group = {
									vertices = storeVertices and {} or nil,
									triangles = {},
									low = origin,
									high = origin + Vector(tileSize, tileSize, tileSize),
								}
								exterior.groups[key] = group
							end
							if storeVertices then
								local vertices = group.vertices
								vertices[#vertices + 1] = a
								vertices[#vertices + 1] = b
								vertices[#vertices + 1] = c
							end
							group.triangles[#group.triangles + 1] = V.VehicleTriangleHull(a, b, c)
							exterior.triangles = exterior.triangles + 1
						end
					end
					if checkpoint then
						checkpoint()
					end
				end
			end
		end
	end
	local function surface(poly, normal)
		local localPoly = {}
		for _, p in ipairs(poly) do
			localPoly[#localPoly + 1] = p - r.origin
		end
		local remaining = clipBox(localPoly, outerLow, outerHigh)
		-- Disjoint exterior slabs. Coplanar lattice boundaries belong to the
		-- voxel mesh, avoiding duplicate contacts along the transition.
		for i, axis in ipairs(axes) do
			if #remaining < 3 then
				break
			end
			local low, high = math.huge, -math.huge
			for _, point in ipairs(remaining) do
				local coordinate = point[axis]
				low, high = math.min(low, coordinate), math.max(high, coordinate)
			end
			if low < -EPS then
				store(V.ClipBSPPolygon(remaining, basis[i], 0), normal)
			end
			remaining = V.ClipBSPPolygon(remaining, reverseBasis[i], 0)
			local size = V.RegionAxisSize(r, axis)
			if high > size + EPS then
				store(V.ClipBSPPolygon(remaining, reverseBasis[i], -size), normal)
			end
			remaining = V.ClipBSPPolygon(remaining, basis[i], size)
		end
	end
	local worldLow, worldHigh = r.origin + outerLow, r.origin + outerHigh
	for _, face in ipairs(data.faces or {}) do
		local low, high = face.dispLow or face.low, face.dispHigh or face.high
		if
			low
			and high
			and V.BoundsOverlap(low, high, worldLow, worldHigh)
			and bit.band(face.tex and face.tex.flags or 0, 8) == 0
		then
			if face.displacement and face.dispGrid then
				V.ForDisplacementTriangles(face, function(points)
					local normal = (points[2] - points[1]):Cross(points[3] - points[1]):GetNormalized()
					if normal:Dot(face.normal) < 0 then
						normal = -normal
					end
					surface(points, normal)
				end, checkpoint)
			elseif not face.displacement then
				surface(face.vertices, face.normal)
			end
		end
		if checkpoint then
			checkpoint()
		end
	end
	r.vehicleExterior = exterior
	return exterior
end

-- Interval during which a moving hull overlaps the cage. Prefix/suffix still
-- use the engine BSP; the middle uses voxel + the unchanged exterior seam.
local function interval(r, start, finish, mins, maxs)
	local first, last = 0, 1
	local delta = finish - start
	for _, axis in ipairs(axes) do
		local low, high = r.origin[axis] - maxs[axis], r.origin[axis] + V.RegionAxisSize(r, axis) - mins[axis]
		local p, d = start[axis], delta[axis]
		if math.abs(d) < 1e-12 then
			if p < low or p > high then
				return
			end
		else
			local a, b = (low - p) / d, (high - p) / d
			if a > b then
				a, b = b, a
			end
			first, last = math.max(first, a), math.min(last, b)
			if first > last then
				return
			end
		end
	end
	return first, last
end
V.VehicleCageInterval = interval

local function exteriorTrace(r, start, finish, mins, maxs)
	local world = r.vehicleExterior
	local result = { Hit = false, Fraction = 1, HitPos = finish, HitNormal = Vector(), StartSolid = false }
	if not world then
		return result
	end
	local delta = finish - start
	local center = start + (mins + maxs) / 2 - r.origin
	local extent = (maxs - mins) / 2
	local pointCast = extent:LengthSqr() < 1e-16
	local low, high = {}, {}
	for _, axis in ipairs(axes) do
		low[axis] = math.floor((math.min(start[axis], finish[axis]) + mins[axis] - r.origin[axis] - EPS) / tileSize)
		high[axis] = math.floor((math.max(start[axis], finish[axis]) + maxs[axis] - r.origin[axis] + EPS) / tileSize)
	end
	for z = low.z, high.z do
		for y = low.y, high.y do
			for x = low.x, high.x do
				local group = world.groups[V.ChunkKey(x, y, z)]
				if group then
					for _, hull in ipairs(group.triangles) do
						local t, n, inside = V.SweepVehicleSolid(hull, center, extent, delta, pointCast)
						if t and (t < result.Fraction or inside) then
							result.Hit = true
							result.Fraction = t
							result.HitNormal = n
							result.StartSolid = inside
							if inside then
								result.HitPos = start
								return result
							end
						end
					end
				end
			end
		end
	end
	result.HitPos = start + delta * result.Fraction
	return result
end
V.TraceVehicleExterior = exteriorTrace

function V.TraceVehicleTerrain(r, data, native)
	local mins, maxs = data.mins or Vector(), data.maxs or Vector()
	local first, last = interval(r, data.start, data.endpos, mins, maxs)
	if not first or data.ignoreworld or (data.mask and bit.band(data.mask, CONTENTS_SOLID or 1) == 0) then
		return native(data)
	end
	local original = {}
	for k, v in pairs(data) do
		original[k] = v
	end
	original.output = nil
	local filter = data.filter
	original.filter = function(ent)
		if ent.VMVoxelCollider or ent.VMProjectileStopFor then
			return false
		end
		if type(filter) == "function" then
			return filter(ent)
		end
		if filter == ent then
			return data.whitelist == true
		end
		if type(filter) == "table" then
			local matched = false
			for _, value in pairs(filter) do
				if value == ent then
					matched = true
					break
				end
				if type(value) == "string" and ent.GetClass then
					local pattern = "^" .. value:gsub("([^%w_*])", "%%%1"):gsub("%*", ".*") .. "$"
					if ent:GetClass():match(pattern) then
						matched = true
						break
					end
				end
			end
			return data.whitelist and matched or not data.whitelist and not matched
		end
		return true
	end
	-- The native wrapper above implements whitelist semantics itself.
	original.whitelist = false
	local start, finish = data.start, data.endpos
	local delta = finish - start
	local best = {
		Hit = false,
		Fraction = 1,
		HitPos = finish,
		HitNormal = Vector(),
		StartSolid = false,
		AllSolid = false,
		HitWorld = false,
		HitNonWorld = false,
		HitSky = false,
		HitNoDraw = false,
		FractionLeftSolid = 0,
		Entity = NULL,
		MatType = 0,
		SurfaceProps = 0,
		HitTexture = "",
		PhysicsBone = 0,
		HitGroup = 0,
		HitBox = 0,
		StartPos = start,
		Normal = delta:GetNormalized(),
	}
	local defaults = best
	local function merge(hit, a, b, terrain)
		if not hit then
			return
		end
		local fraction = a + (b - a) * (hit.Fraction or 1)
		if hit.Hit and (fraction < best.Fraction or (fraction == 0 and hit.StartSolid)) then
			best = hit
			best.Fraction = fraction
			best.HitPos = start + delta * fraction
			if fraction > 0 then
				best.StartSolid = false
				best.AllSolid = false
			end
			if terrain then
				best.HitWorld = true
				best.HitNonWorld = false
				best.Entity = game.GetWorld()
				best.MatType = MAT_DIRT or 68
				best.SurfaceProps = util.GetSurfaceIndex and util.GetSurfaceIndex("dirt") or 0
				best.HitTexture = "gvoxel"
				best.HitSky = false
				best.HitNoDraw = false
			end
		end
	end
	local function segment(a, b, ignore)
		original.start = start + delta * a
		original.endpos = start + delta * b
		original.ignoreworld = ignore
		return native(original)
	end
	if first > EPS then
		merge(segment(0, math.max(0, first - EPS)), 0, math.max(0, first - EPS))
	end
	-- Entity collisions and the caller's filters/masks remain native. Our
	-- hidden physical meshes are replaced by the exact shared terrain query.
	merge(segment(0, 1, true), 0, 1)
	-- An amphibious suspension may request both solid ground and fluids. The
	-- voxel field replaces solids, not the map's water/slime surfaces. Query
	-- only those contents so the hidden BSP cannot return through this path.
	local fluidMask = data.mask and bit.band(data.mask, (CONTENTS_WATER or 32) + (CONTENTS_SLIME or 16)) or 0
	if fluidMask ~= 0 then
		original.mask = fluidMask
		merge(segment(0, 1, false), 0, 1)
		original.mask = data.mask
	end
	local a, b = start + delta * first, start + delta * last
	merge(V.TraceVoxelHull(r, a, b, mins, maxs), first, last, true)
	merge(exteriorTrace(r, a, b, mins, maxs), first, last, true)
	if last < 1 - EPS then
		merge(segment(math.min(1, last + EPS), 1, false), math.min(1, last + EPS), 1)
	end
	for key, value in pairs(defaults) do
		if best[key] == nil then
			best[key] = value
		end
	end
	best.StartPos = start
	best.Normal = delta:GetNormalized()
	if data.output then
		for key in pairs(data.output) do
			data.output[key] = nil
		end
		for key, value in pairs(best) do
			data.output[key] = value
		end
		return data.output
	end
	return best
end
