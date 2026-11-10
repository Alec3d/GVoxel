-- Static irradiance on cut geometry. Prefer the nearby original lightmap.
-- Beyond its support, transfer measured air-side light in linear RGB.
local V = GVoxel
local axes = { "x", "y", "z" }
local empty = {}
local black = Vector()
local function key(x, y, z)
	return x .. ":" .. y .. ":" .. z
end

local function irradiance(cube, n)
	local x, y, z = n.x, n.y, n.z
	local a, b, c = (x >= 0 and 0 or 3), (y >= 0 and 6 or 9), (z >= 0 and 12 or 15)
	local xx, yy, zz = x * x, y * y, z * z
	return Vector(
		cube[a + 1] * xx + cube[b + 1] * yy + cube[c + 1] * zz,
		cube[a + 2] * xx + cube[b + 2] * yy + cube[c + 2] * zz,
		cube[a + 3] * xx + cube[b + 3] * yy + cube[c + 3] * zz
	)
end

local function transferCube(r, record)
	local environment = V.PrepareSurfaceLighting(record.source, r)
	local n = record.normal
	local face = environment[n.x >= 0 and 1 or 2] * (n.x * n.x)
		+ environment[n.y >= 0 and 3 or 4] * (n.y * n.y)
		+ environment[n.z >= 0 and 5 or 6] * (n.z * n.z)
	-- An air probe measures model lighting, which can disagree with the
	-- irradiance baked onto the source face. Recover light missing from a
	-- dim probe without spreading a local rim shadow through the whole cut.
	local source = record.source
	local mapped = record.map and V.SamplePreparedBSPLightmap(record.map, source.lightAnchor or source.point)
	if not mapped and record.map and source.lightAnchor then
		mapped = V.SamplePreparedBSPLightmap(record.map, source.point)
	end
	local function calibrate(value, measured, target)
		if target <= measured then return value end
		return measured > 0.0001 and math.max(value, target * math.min(2, value / measured)) or target
	end
	local cube = {}
	for axis, name in ipairs(axes) do
		-- Mix diffuse bounce into the reveal without a second ambient term.
		local bounce = 0.5 * (1 - math.abs(n[name]))
		local direct = 1 - bounce
		for side = 1, 2 do
			local i = (axis - 1) * 2 + side
			local c = environment[i]
			local x, y, z = c.x * direct + face.x * bounce, c.y * direct + face.y * bounce, c.z * direct + face.z * bounce
			cube[(i - 1) * 3 + 1] = mapped and calibrate(x, face.x, mapped.x) or x
			cube[(i - 1) * 3 + 2] = mapped and calibrate(y, face.y, mapped.y) or y
			cube[(i - 1) * 3 + 3] = mapped and calibrate(z, face.z, mapped.z) or z
		end
	end
	record.cube = cube
	return cube
end

local function addBins(bins, record, size, radius, checkpoint)
	local low, high = record.low, record.high
	local radius2 = radius * radius
	for x = math.floor((low.x - radius) / size), math.floor((high.x + radius) / size) do
		local dx = math.max(low.x - (x + 1) * size, 0, x * size - high.x)
		for y = math.floor((low.y - radius) / size), math.floor((high.y + radius) / size) do
			local dy = math.max(low.y - (y + 1) * size, 0, y * size - high.y)
			local d2 = dx * dx + dy * dy
			for z = math.floor((low.z - radius) / size), math.floor((high.z + radius) / size) do
				local dz = math.max(low.z - (z + 1) * size, 0, z * size - high.z)
				if d2 + dz * dz < radius2 then
					local k = key(x, y, z)
					local bin = bins[k]
					if not bin then
						bin = {}
						bins[k] = bin
					end
					bin[#bin + 1] = record
				end
			end
		end
		if checkpoint then
			checkpoint()
		end
	end
end

local function prepareRimEdges(polygon, normal)
	local edges = {}
	for i, p in ipairs(polygon) do
		local delta = polygon[i % #polygon + 1] - p
		local length2 = delta:LengthSqr()
		if length2 > 0 then
			local side = normal:Cross(delta)
			edges[#edges + 1] = {
				x = p.x, y = p.y, z = p.z,
				dx = delta.x, dy = delta.y, dz = delta.z, inverseLength2 = 1 / length2,
				sx = side.x, sy = side.y, sz = side.z,
			}
		end
	end
	return edges
end

function V.PrepareCutLighting(r, checkpoint)
	if r.cutLighting then
		return
	end
	local size = r.step * 8
	local radius = size * 2
	local state = {
		size = size,
		rimSize = r.step * 2,
		radius2 = radius * radius,
		edge2 = r.step * r.step,
		epsilon2 = (r.step * 0.01) ^ 2,
		bins = {},
		rimBins = {},
		points = {},
		order = {},
		cursor = 1,
		samples = 0,
		hits = 0,
		visits = 0,
		sourceCount = 0,
	}
	local sun = util.GetSunInfo and util.GetSunInfo()
	state.sunDirection = sun and sun.enabled ~= false and sun.direction and sun.direction:GetNormalized() or nil
	local maps = {}
	for _, source in ipairs(r.surfaceList or empty) do
		local n = source.planeNormal or (source.frame and source.frame.normal)
		if n and source.point then
			local bounds, face = source.lightBounds, source.nativeFace
			local record = {
				source = source,
				low = bounds and bounds.low or source.point,
				high = bounds and bounds.high or source.point,
				normal = n,
				plane = source.point:Dot(n),
				face = face,
			}
			if face and maps[face] == nil then
				maps[face] = V.PrepareBSPLightmap(r.bsp, face) or false
			end
			local map = face and maps[face]
			if map then
				record.map = map
				state.hasRims = true
				if not face.displacement and face.vertices and #face.vertices >= 3 and face.normal then
					record.rimNormal = face.normal
					record.rimPlane = face.distance or face.vertices[1]:Dot(face.normal)
					map.rimEdges = map.rimEdges or prepareRimEdges(face.vertices, face.normal)
					record.rimEdges = map.rimEdges
				end
				addBins(state.rimBins, record, state.rimSize, r.step, checkpoint)
			else
				transferCube(r, record)
			end
			source.sunFacing = state.sunDirection and n:Dot(state.sunDirection) or nil
			state.sourceCount = state.sourceCount + 1
			addBins(state.bins, record, size, radius, checkpoint)
		end
		if checkpoint then
			checkpoint()
		end
	end
	-- Publish only a complete index. A cancelled scan retains no partial job.
	r.cutLighting = state
end

local function boundsDistance2(record, x, y, z)
	local low, high = record.low, record.high
	local dx = math.max(low.x - x, 0, x - high.x)
	local dy = math.max(low.y - y, 0, y - high.y)
	local dz = math.max(low.z - z, 0, z - high.z)
	return dx * dx + dy * dy + dz * dz
end

local function fallbackCube(r, state, entry, point, checkpoint)
	if entry.cube then
		return entry.cube
	end
	local candidates = state.bins[entry.bin]
	state.visits = state.visits + #candidates
	local radius2 = state.radius2
	-- A small black weight gives finite support a smooth fade into deep solid.
	local weight = 1 / radius2
	local x, y, z = point.x, point.y, point.z
	-- Accumulate the six RGB faces directly. This is the hot loop for
	-- every uncached cut vertex, even if its material was already known.
	local r1, g1, b1, r2, g2, b2, r3, g3, b3 = 0, 0, 0, 0, 0, 0, 0, 0, 0
	local r4, g4, b4, r5, g5, b5, r6, g6, b6 = 0, 0, 0, 0, 0, 0, 0, 0, 0
	for index, record in ipairs(candidates) do
		local d2 = boundsDistance2(record, x, y, z)
		if d2 < radius2 then
			-- A sloped face's AABB alone can contain points far from its plane.
			local n = record.normal
			local plane = x * n.x + y * n.y + z * n.z - record.plane
			d2 = math.max(d2, plane * plane)
			if d2 < radius2 then
				local taper = 1 - d2 / radius2
				local w = taper * taper / (d2 + state.epsilon2)
				local cube = record.cube or transferCube(r, record)
				weight = weight + w
				r1, g1, b1 = r1 + cube[1] * w, g1 + cube[2] * w, b1 + cube[3] * w
				r2, g2, b2 = r2 + cube[4] * w, g2 + cube[5] * w, b2 + cube[6] * w
				r3, g3, b3 = r3 + cube[7] * w, g3 + cube[8] * w, b3 + cube[9] * w
				r4, g4, b4 = r4 + cube[10] * w, g4 + cube[11] * w, b4 + cube[12] * w
				r5, g5, b5 = r5 + cube[13] * w, g5 + cube[14] * w, b5 + cube[15] * w
				r6, g6, b6 = r6 + cube[16] * w, g6 + cube[17] * w, b6 + cube[18] * w
			end
		end
		if checkpoint and index % 32 == 0 then
			checkpoint()
		end
	end
	local inverse = 1 / weight
	entry.cube = {
		r1 * inverse, g1 * inverse, b1 * inverse,
		r2 * inverse, g2 * inverse, b2 * inverse,
		r3 * inverse, g3 * inverse, b3 * inverse,
		r4 * inverse, g4 * inverse, b4 * inverse,
		r5 * inverse, g5 * inverse, b5 * inverse,
		r6 * inverse, g6 * inverse, b6 * inverse,
	}
	return entry.cube
end

local function closestRimPoint(edges, projected)
	local x, y, z = projected.x, projected.y, projected.z
	local positive, negative = false, false
	for _, edge in ipairs(edges) do
		local side = edge.sx * (x - edge.x) + edge.sy * (y - edge.y) + edge.sz * (z - edge.z)
		positive = positive or side > 0.0001
		negative = negative or side < -0.0001
		if positive and negative then
			-- Border luxels are only borrowed at the actual face edge.
			local cx, cy, cz, distance2 = x, y, z, math.huge
			for _, e in ipairs(edges) do
				local dx, dy, dz = x - e.x, y - e.y, z - e.z
				local t = math.max(0, math.min(1, (dx * e.dx + dy * e.dy + dz * e.dz) * e.inverseLength2))
				dx, dy, dz = dx - e.dx * t, dy - e.dy * t, dz - e.dz * t
				local d2 = dx * dx + dy * dy + dz * dz
				if d2 < distance2 then
					cx, cy, cz, distance2 = x - dx, y - dy, z - dz, d2
				end
			end
			return Vector(cx, cy, cz), distance2
		end
	end
	return projected, 0
end

local function localRims(state, bin, point, checkpoint)
	local candidates = state.rimBins[bin]
	if not candidates then
		return
	end
	local rims = {}
	local x, y, z = point.x, point.y, point.z
	for index, record in ipairs(candidates) do
		local d2 = boundsDistance2(record, x, y, z)
		local limit = rims[8] and rims[8].d2 or state.edge2
		local normal = record.rimNormal or record.normal
		local plane = d2 < limit and (point:Dot(normal) - (record.rimPlane or record.plane))
		local plane2 = plane and plane * plane
		if plane2 and plane2 < limit then
			local projected = point - normal * plane
			local tangent2 = boundsDistance2(record, projected.x, projected.y, projected.z)
			d2 = math.max(d2, plane2 + tangent2)
			if record.rimEdges and d2 < limit then
				local polygonDistance2
				projected, polygonDistance2 = closestRimPoint(record.rimEdges, projected)
				tangent2 = math.max(tangent2, polygonDistance2)
				d2 = math.max(d2, plane2 + tangent2)
			end
			if d2 < limit then
				local existing
				for i, candidate in ipairs(rims) do
					if candidate.face == record.face then
						existing = i
						break
					end
				end
				if not existing or d2 < rims[existing].d2 then
					local color = V.SamplePreparedBSPLightmap(record.map, projected)
					if color then
						if existing then
							table.remove(rims, existing)
						end
						local i = #rims + 1
						while i > 1 and rims[i - 1].d2 > d2 do
							i = i - 1
						end
						table.insert(rims, i, {
							face = record.face,
							normal = normal,
							d2 = d2,
							plane = plane,
							tangent2 = tangent2,
							color = color,
						})
						if #rims > 8 then
							table.remove(rims)
						end
					end
				end
			end
		end
		if checkpoint and index % 32 == 0 then
			checkpoint()
		end
	end
	return #rims > 0 and rims or nil
end

local function pointEntry(state, point, checkpoint)
	-- World coordinates, independent of chunk/material. The FIFO is bounded.
	local k = key(point.x, point.y, point.z)
	local entry = state.points[k]
	if entry then
		state.hits = state.hits + 1
		return entry
	end
	local size = state.size
	local bin = key(math.floor(point.x / size), math.floor(point.y / size), math.floor(point.z / size))
	entry = { bin = bin }
	if state.hasRims then
		local rimSize = state.rimSize
		local rimBin = key(math.floor(point.x / rimSize), math.floor(point.y / rimSize), math.floor(point.z / rimSize))
		entry.rims = localRims(state, rimBin, point, checkpoint)
	end
	state.samples = state.samples + 1
	local previous = state.order[state.cursor]
	if previous then
		state.points[previous] = nil
	end
	state.order[state.cursor] = k
	state.points[k] = entry
	state.cursor = state.cursor % 4096 + 1
	return entry
end

local function rimLighting(r, rims, normal)
	local best, score = nil, math.huge
	local step = r.step
	for _, candidate in ipairs(rims) do
		local alignment = normal:Dot(candidate.normal)
		local s = candidate.d2 + (1 - math.max(0, alignment)) * (step * 0.15) ^ 2
		if alignment >= -0.25 and s < score then
			best, score = candidate, s
		end
	end
	if not best then
		return
	end
	-- Confine the seam to close coplanar edges. A parallel backface or a
	-- perpendicular roof/floor cannot erase the chosen original shadow.
	local light, total = best.color, 1
	local epsilon2 = (step * 0.125) ^ 2
	local seam2 = (step * 0.25) ^ 2
	for _, candidate in ipairs(rims) do
		local tangent = candidate.tangent2 - best.tangent2
		if candidate ~= best and tangent < seam2 and best.normal:Dot(candidate.normal) > 0.98
			and math.abs(best.plane - candidate.plane) < step * 0.05 then
			local taper = 1 - math.max(0, tangent) / seam2
			local w = taper * taper * (best.d2 + epsilon2) / (candidate.d2 + epsilon2)
			light = light + candidate.color * w
			total = total + w
		end
	end
	return total == 1 and light or light / total, best.d2
end

function V.CutVertexLighting(r, point, normal, checkpoint)
	local state = r.cutLighting
	if not state then
		return
	end
	local entry = pointEntry(state, point, checkpoint)
	local x, y, z = normal.x, normal.y, normal.z
	if entry.light and entry.nx == x and entry.ny == y and entry.nz == z then
		return entry.light
	end
	local light, d2
	if entry.rims then
		light, d2 = rimLighting(r, entry.rims, normal)
	end
	if not d2 or d2 >= 0.00000001 then
		local fallback = black
		if state.bins[entry.bin] then
			fallback = irradiance(fallbackCube(r, state, entry, point, checkpoint), normal)
		end
		if light then
			local t = 1 - math.sqrt(d2) / r.step
			t = t * t * (3 - 2 * t)
			light = fallback * (1 - t) + light * t
		else
			light = fallback
		end
	end
	entry.nx, entry.ny, entry.nz, entry.light = x, y, z, light
	return light
end
function V.EncodeCutLighting(vertices, checkpoint)
	-- Keep cached cell vertices immutable: different rebuilt batches may
	-- choose different HDR scales while sharing these exact cell records.
	local peak = 1
	for i, vertex in ipairs(vertices) do
		local c = vertex.cutLight
		peak = math.max(peak, c.x, c.y, c.z)
		if checkpoint and i % 192 == 0 then
			checkpoint()
		end
	end
	local result = {}
	local inversePeak = 1 / peak
	for i, vertex in ipairs(vertices) do
		-- Source's UnlitGeneric vertex shader decodes vertex RGB with pow(2.2).
		-- Interpolate linear light first; encode only at this upload boundary.
		local c = vertex.cutLight
		result[i] = {
			pos = vertex.pos,
			normal = vertex.normal,
			u = vertex.u,
			v = vertex.v,
			color = Color(
				math.floor((c.x * inversePeak) ^ (1 / 2.2) * 255 + 0.5),
				math.floor((c.y * inversePeak) ^ (1 / 2.2) * 255 + 0.5),
				math.floor((c.z * inversePeak) ^ (1 / 2.2) * 255 + 0.5),
				255
			),
		}
		if checkpoint and i % 96 == 0 then
			checkpoint()
		end
	end
	return result, peak
end

concommand.Add("vm_lighting_stats", function()
	local r = V.GetClientScanRegion and V.GetClientScanRegion()
	local s = r and r.cutLighting
	if not s then
		print("[GVoxel] Eclairage interieur : aucun releve pret.")
		return
	end
	print(
		string.format(
			"[GVoxel] Eclairage interieur : %d sondes ; %d sommets calcules ; %d reutilisations ; %.1f sondes/sommet ; cache %d/4096 ; soleil %s.",
			s.sourceCount,
			s.samples,
			s.hits,
			s.visits / math.max(1, s.samples),
			#s.order,
			s.sunDirection and "repere" or "eclairage BSP"
		)
	)
end)
