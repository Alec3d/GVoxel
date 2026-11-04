-- Recover architectural planes, including rotated brushes and ramps from the existing BSP scan rays.
-- Shared by meshing, targeting and player collision; brush regions stay smooth.
local V = GVoxel
local names = { "x", "y", "z" }

function V.FeatureAxis(normal)
	for i, name in ipairs(names) do
		if math.abs(normal[name]) > 0.999999 then
			local aligned = true
			for j, other in ipairs(names) do
				if j ~= i and math.abs(normal[other]) > 0.000001 then
					aligned = false
					break
				end
			end
			if aligned then
				return i
			end
		end
	end
end

function V.RecordScanPlane(r, hit)
	if
		not hit.Hit
		or not hit.HitWorld
		or hit.StartSolid
		or hit.HitSky
		or hit.HitTexture == "**studio**"
		or hit.HitTexture == "**displacement**"
	then
		return
	end
	local axis = V.FeatureAxis(hit.HitNormal)
	r.terrainCache = nil
	r.featureBins = nil
	local normal = hit.HitNormal:GetNormalized()
	if normal:LengthSqr() < 0.5 then
		return
	end
	local name = axis and names[axis]
	local distance = axis and hit.HitPos[name] or hit.HitPos:Dot(normal)
	local bucket = math.floor(distance * 64 + 0.5) / 64
	local sign = axis and (hit.HitNormal[name] > 0 and 1 or -1) or 1
	r.featurePlanes = r.featurePlanes or {}
	r.featureLookup = r.featureLookup or {}
	local prefix = (axis and (axis .. ":" .. sign) or string.format("%.4f:%.4f:%.4f", normal.x, normal.y, normal.z))
		.. ":"
	local key = prefix .. bucket
	local plane = r.featureLookup[key]
	if not plane then
		for _, offset in ipairs({ -1, 1 }) do
			plane = r.featureLookup[prefix .. (bucket + offset / 64)]
			if plane then
				r.featureLookup[key] = plane
				break
			end
		end
	end
	if not plane then
		if #r.featurePlanes >= 128 then
			return
		end
		plane = {
			axis = axis or 0,
			sign = sign,
			distance = distance,
			normal = not axis and normal or nil,
			low = Vector(hit.HitPos.x, hit.HitPos.y, hit.HitPos.z),
			high = Vector(hit.HitPos.x, hit.HitPos.y, hit.HitPos.z),
		}
		r.featureLookup[key] = plane
		r.featurePlanes[#r.featurePlanes + 1] = plane
	end
	for _, a in ipairs(names) do
		plane.low[a] = math.min(plane.low[a], math.floor(hit.HitPos[a] * 64 + 0.5) / 64)
		plane.high[a] = math.max(plane.high[a], math.floor(hit.HitPos[a] * 64 + 0.5) / 64)
	end
end

function V.FeaturePlaneNormal(plane)
	if plane.normal then
		return plane.normal
	end
	local n = Vector()
	n[names[plane.axis]] = plane.sign
	return n
end
function V.FeaturePlaneDistance(plane)
	return plane.normal and plane.distance or plane.distance * plane.sign
end
local function nearbyPlanes(r, p)
	r.featureBins = r.featureBins or {}
	local size = r.step * 8
	local x, y, z = math.floor(p.x / size), math.floor(p.y / size), math.floor(p.z / size)
	local key = V.ChunkKey(x, y, z)
	local list = r.featureBins[key]
	if list then
		return list
	end
	list = {}
	local low = r.origin + Vector(x, y, z) * size - Vector(1, 1, 1) * r.step
	local high = low + Vector(10, 10, 10) * r.step
	for _, plane in ipairs(r.featurePlanes) do
		if
			plane.low.x <= high.x
			and plane.high.x >= low.x
			and plane.low.y <= high.y
			and plane.high.y >= low.y
			and plane.low.z <= high.z
			and plane.high.z >= low.z
		then
			list[#list + 1] = plane
		end
	end
	r.featureBins[key] = list
	return list
end

-- Solve up to three independent supporting planes in the free coordinates of
-- this lattice edge/face. Frozen coordinates guarantee identical shared seams.
local function projectPlanes(r, p, world, candidates)
	local free = {}
	for _, a in ipairs(names) do
		local q = p[a] / r.step
		free[a] = math.abs(q - math.floor(q + 0.5)) > 0.000001
	end
	local sorted = {}
	for order, plane in ipairs(candidates) do
		local n = V.FeaturePlaneNormal(plane)
		local error = V.FeaturePlaneDistance(plane) - n:Dot(world)
		if math.abs(error) < r.step * 0.6 then
			local valid = true
			for _, a in ipairs(names) do
				if world[a] < plane.low[a] - r.step or world[a] > plane.high[a] + r.step then
					valid = false
					break
				end
			end
			if valid then
				sorted[#sorted + 1] = { normal = n, error = error, order = order }
			end
		end
	end
	table.sort(sorted, function(a, b)
		local x, y = math.floor(math.abs(a.error) * 1024 + 0.5), math.floor(math.abs(b.error) * 1024 + 0.5)
		return x == y and a.order < b.order or x < y
	end)
	local selected = {}
	local result = p
	for _, candidate in ipairs(sorted) do
		local n = candidate.normal
		local row =
			{ n = Vector(free.x and n.x or 0, free.y and n.y or 0, free.z and n.z or 0), error = candidate.error }
		local count = #selected + 1
		local rows = {}
		for i = 1, count do
			local a = i == count and row or selected[i]
			rows[i] = {}
			for j = 1, count do
				local b = j == count and row or selected[j]
				rows[i][j] = a.n:Dot(b.n)
			end
			rows[i][count + 1] = a.error
		end
		local singular = false
		for k = 1, count do
			local pivot = k
			for i = k + 1, count do
				if math.abs(rows[i][k]) > math.abs(rows[pivot][k]) then
					pivot = i
				end
			end
			rows[k], rows[pivot] = rows[pivot], rows[k]
			if math.abs(rows[k][k]) < 0.000001 then
				singular = true
				break
			end
			local divisor = rows[k][k]
			for j = k, count + 1 do
				rows[k][j] = rows[k][j] / divisor
			end
			for i = 1, count do
				if i ~= k then
					local factor = rows[i][k]
					for j = k, count + 1 do
						rows[i][j] = rows[i][j] - factor * rows[k][j]
					end
				end
			end
		end
		if not singular then
			local delta = Vector()
			for i = 1, count do
				delta = delta + (i == count and row or selected[i]).n * rows[i][count + 1]
			end
			local adjusted = p + delta
			local valid = delta:LengthSqr() < r.step * r.step * 0.81
			for _, a in ipairs(names) do
				if free[a] then
					local low = math.floor(p[a] / r.step) * r.step
					if adjusted[a] < low - 0.00001 or adjusted[a] > low + r.step + 0.00001 then
						valid = false
					end
				end
			end
			if valid then
				selected[count] = row
				result = adjusted
			end
		end
		if #selected == 3 then
			break
		end
	end
	return result
end

function V.FeaturePointEdited(r, p)
	if not r.featureTouched then
		return false
	end
	local q = p / r.step
	for _, axis in ipairs(names) do
		local rounded = math.floor(q[axis] + 0.5)
		if math.abs(q[axis] - rounded) < 0.000001 then
			q[axis] = rounded
		end
	end
	for i, axis in ipairs(names) do
		if math.abs(q[axis]) < 0.000001 or math.abs(q[axis] - r["n" .. axis]) < 0.000001 then
			return false
		end
	end
	local cache, key = V.TerrainCellCache(r, "edited", math.floor(q.x), math.floor(q.y), math.floor(q.z))
	if cache[key] ~= nil then
		return cache[key]
	end
	for z = math.max(0, math.floor(q.z) - 1), math.min(r.nz, math.floor(q.z) + 1) do
		for y = math.max(0, math.floor(q.y) - 1), math.min(r.ny, math.floor(q.y) + 1) do
			for x = math.max(0, math.floor(q.x) - 1), math.min(r.nx, math.floor(q.x) + 1) do
				if r.featureTouched[V.Index(x, y, z, r)] then
					cache[key] = true
					return true
				end
			end
		end
	end
	cache[key] = false
	return false
end

function V.RefineSurfacePoint(r, p)
	-- Density relief gets a local bevel towards its native displacement edge.
	-- This is shared by triangulation and collision, never a render-only skirt.
	if r.seamSource and V.RefineBoundaryPoint then
		p = V.RefineBoundaryPoint(r.seamSource, p)
	end
	if not r.featurePlanes or #r.featurePlanes == 0 or V.FeaturePointEdited(r, p) then
		return p
	end
	local world = r.origin + p
	local candidates = nearbyPlanes(r, p)
	for _, plane in ipairs(candidates) do
		if plane.normal then
			return projectPlanes(r, p, world, candidates)
		end
	end
	local closest = {}
	for _, plane in ipairs(candidates) do
		local name = names[plane.axis]
		local distance = math.abs(world[name] - plane.distance)
		if distance < r.step * 0.6 and (not closest[name] or distance < closest[name].error) then
			local valid = true
			for _, a in ipairs(names) do
				if world[a] < plane.low[a] - r.step or world[a] > plane.high[a] + r.step then
					valid = false
					break
				end
			end
			if valid then
				closest[name] = { plane = plane, error = distance }
			end
		end
	end
	local refined = Vector(p.x, p.y, p.z)
	for name, candidate in pairs(closest) do
		local value = candidate.plane.distance - r.origin[name]
		local q = p[name] / r.step
		-- Keep shared lattice faces fixed, and never move outside the cell.
		-- Thus neighboring chunks, DDA targeting and boundary masks agree.
		if
			math.abs(q - math.floor(q + 0.5)) > 0.000001
			and value >= math.floor(q) * r.step - 0.00001
			and value <= (math.floor(q) + 1) * r.step + 0.00001
		then
			refined[name] = value
		end
	end
	return refined
end

function V.FeatureNormal(r, world, faceNormal, smooth)
	if not r.featurePlanes or #r.featurePlanes == 0 or V.FeaturePointEdited(r, world - r.origin) then
		return smooth
	end
	for _, plane in ipairs(nearbyPlanes(r, world - r.origin)) do
		local n = V.FeaturePlaneNormal(plane)
		if math.abs(world:Dot(n) - V.FeaturePlaneDistance(plane)) < 0.04 and faceNormal:Dot(n) > 0.95 then
			return n
		end
	end
	-- Architectural facets should not be shaded as a continuous rounded blob.
	return faceNormal:Dot(smooth) > 0.85 and smooth or faceNormal
end
