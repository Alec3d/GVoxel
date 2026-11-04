-- Static irradiance transfer onto newly exposed geometry. The native BSP is
-- immutable: sampling inside its old solids gives invalid/black probes. Sample
-- the original air-facing surfaces once, then interpolate locally in linear RGB.
-- This is a diffuse approximation, not a new lightmap or shadow-map renderer.
local V = GVoxel
local axes = { "x", "y", "z" }
local function key(x, y, z)
	return x .. ":" .. y .. ":" .. z
end
local function irradiance(cube, n)
	return cube[n.x >= 0 and 1 or 2] * (n.x * n.x)
		+ cube[n.y >= 0 and 3 or 4] * (n.y * n.y)
		+ cube[n.z >= 0 and 5 or 6] * (n.z * n.z)
end

function V.PrepareCutLighting(r, checkpoint)
	if r.cutLighting then
		return
	end
	local size = r.step * 8
	local state = {
		size = size,
		radius = size * 2,
		bins = {},
		points = {},
		order = {},
		cursor = 1,
		bsp = r.bsp,
		samples = 0,
		hits = 0,
		visits = 0,
		sourceCount = 0,
	}
	local sun = util.GetSunInfo and util.GetSunInfo()
	state.sunDirection = sun and sun.enabled ~= false and sun.direction and sun.direction:GetNormalized() or nil
	-- GetAmbientLightColor is already included in ComputeLighting. It is only
	-- a fallback for an unavailable native probe, never added a second time.
	for _, source in ipairs(r.surfaceList or {}) do
		local n = source.planeNormal or (source.frame and source.frame.normal)
		if n and source.point then
			local environment = V.PrepareSurfaceLighting(source, r)
			local face = irradiance(environment, n)
			local cube = {}
			for axis, name in ipairs(axes) do
				-- Diffuse transfer from the original face onto its reveal.
				-- A convex mixture preserves true black and HDR/color; it
				-- cannot invent a sun merely because a normal faces the sky.
				local bounce = 0.5 * (1 - math.abs(n[name]))
				for side = 1, 2 do
					local i = (axis - 1) * 2 + side
					local c = environment[i] * (1 - bounce) + face * bounce
					cube[(i - 1) * 3 + 1] = c.x
					cube[(i - 1) * 3 + 2] = c.y
					cube[(i - 1) * 3 + 3] = c.z
				end
			end
			local bounds = source.lightBounds or { low = source.point, high = source.point }
			local record = {
				cube = cube,
				low = bounds.low,
				high = bounds.high,
				normal = n,
				plane = source.point:Dot(n),
				face = source.nativeFace,
			}
			source.sunFacing = state.sunDirection and n:Dot(state.sunDirection) or nil
			state.sourceCount = state.sourceCount + 1
			-- Expanded finite face bounds keep another floor/building from
			-- contributing as if its infinite plane crossed this excavation.
			local a, b =
				(bounds.low - Vector(1, 1, 1) * state.radius) / size,
				(bounds.high + Vector(1, 1, 1) * state.radius) / size
			for x = math.floor(a.x), math.floor(b.x) do
				for y = math.floor(a.y), math.floor(b.y) do
					for z = math.floor(a.z), math.floor(b.z) do
						local k = key(x, y, z)
						state.bins[k] = state.bins[k] or {}
						state.bins[k][#state.bins[k] + 1] = record
					end
				end
				if checkpoint then
					checkpoint()
				end
			end
		end
		if checkpoint then
			checkpoint()
		end
	end
	-- Publish only a complete index. A cancelled scan retains no partial job.
	r.cutLighting = state
end

local function pointCube(state, point, checkpoint)
	-- World coordinates, independent of chunk and material. Adjacent meshes
	-- receive the same irradiance at a shared vertex. Bounded FIFO cache.
	local k = key(point.x, point.y, point.z)
	local cached = state.points[k]
	if cached then
		state.hits = state.hits + 1
		return cached
	end
	local sum = {}
	for i = 1, 18 do
		sum[i] = 0
	end
	local radius2 = state.radius * state.radius
	local epsilon2 = (state.size / 8 * 0.01) ^ 2
	-- A small black weight gives finite support a continuous fade into deep
	-- unexposed solid, instead of a discontinuous bright nearest-probe fallback.
	local weight = 1 / radius2
	local rims
	local candidates = state.bins[key(
		math.floor(point.x / state.size),
		math.floor(point.y / state.size),
		math.floor(point.z / state.size)
	)] or {}
	for index, record in ipairs(candidates) do
		local low, high = record.low, record.high
		local dx = math.max(low.x - point.x, 0, point.x - high.x)
		local dy = math.max(low.y - point.y, 0, point.y - high.y)
		local dz = math.max(low.z - point.z, 0, point.z - high.z)
		local d2 = dx * dx + dy * dy + dz * dz
		-- Sloped BSP/displacement faces have a volumetric AABB. Retain their
		-- actual plane distance, otherwise points inside that box all look lit.
		local plane = point:Dot(record.normal) - record.plane
		d2 = math.max(d2, plane * plane)
		if
			state.bsp
			and record.face
			and record.face.lightOffset
			and record.face.lightOffset >= 0
			and d2 < (state.size / 8) ^ 2
		then
			-- Keep a few local boundaries; the receiving normal chooses the
			-- correct plane at a wall/floor corner. Global transfer is kept
			-- identical to the pre-corners version below.
			rims = rims or {}
			local index = #rims + 1
			while index > 1 and rims[index - 1].d2 > d2 do
				index = index - 1
			end
			if index <= 8 then
				table.insert(rims, index, { record = record, d2 = d2, plane = plane })
				if #rims > 8 then
					table.remove(rims)
				end
			end
		end
		if d2 < radius2 then
			-- Inverse-square interpolation has zero slope at either face of
			-- a two-sided wall: shaded and sunlit probes meet without a step.
			local taper = 1 - d2 / radius2
			local w = taper * taper / (d2 + epsilon2)
			weight = weight + w
			for i = 1, 18 do
				sum[i] = sum[i] + record.cube[i] * w
			end
		end
		if checkpoint and index % 32 == 0 then
			checkpoint()
		end
	end
	local cube = {}
	for i = 1, 6 do
		cube[i] = Vector(sum[(i - 1) * 3 + 1] / weight, sum[(i - 1) * 3 + 2] / weight, sum[(i - 1) * 3 + 3] / weight)
	end
	cube.rims = rims
	if rims then
		cube.rimColors = {}
	end
	state.samples = state.samples + 1
	state.visits = state.visits + #candidates
	local previous = state.order[state.cursor]
	if previous then
		state.points[previous] = nil
	end
	state.order[state.cursor] = k
	state.points[k] = cube
	state.cursor = state.cursor % 4096 + 1
	return cube
end

function V.CutVertexLighting(r, point, normal, checkpoint)
	local state = r.cutLighting
	if not state then
		return
	end
	local cube = pointCube(state, point, checkpoint)
	local result = irradiance(cube, normal)
	if not cube.rims or not V.SampleBSPLightmap then
		return result
	end
	local function sample(candidate)
		local record = candidate.record
		local color = cube.rimColors[record]
		if color == nil then
			color = V.SampleBSPLightmap(state.bsp, record.face, point - record.normal * candidate.plane) or false
			cube.rimColors[record] = color
		end
		return color
	end
	local best, score = nil, math.huge
	for _, candidate in ipairs(cube.rims) do
		local alignment = math.max(0, normal:Dot(candidate.record.normal))
		local s = candidate.d2 + (1 - alignment) * (state.size / 8 * 0.15) ^ 2
		if s < score and sample(candidate) then
			best, score = candidate, s
		end
	end
	if not best then
		return result
	end
	-- Only neighboring pieces of the same oriented plane share a seam.
	-- Opposite sides of a wall and a perpendicular roof/floor stay distinct.
	-- A small tangent blend (one eighth cell) softens the seam without
	-- spreading a dark lightmap over the rest of the excavation.
	local light, total = Vector(), 0
	local epsilon2 = (state.size / 8 * 0.125) ^ 2
	for _, candidate in ipairs(cube.rims) do
		local a, b = best.record, candidate.record
		if a.normal:Dot(b.normal) > 0.98 and math.abs(best.plane - candidate.plane) < state.size / 8 * 0.05 then
			local color = sample(candidate)
			if color then
				local w = 1 / (candidate.d2 + epsilon2)
				light = light + color * w
				total = total + w
			end
		end
	end
	if total > 0 then
		local t = 1 - math.sqrt(best.d2) / (state.size / 8)
		t = t * t * (3 - 2 * t)
		result = result * (1 - t) + (light / total) * t
	end
	return result
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
	for i, vertex in ipairs(vertices) do
		-- Source's UnlitGeneric vertex shader decodes vertex RGB with pow(2.2).
		-- Interpolate linear light first; encode only at this upload boundary.
		local c = vertex.cutLight / peak
		result[i] = {
			pos = vertex.pos,
			normal = vertex.normal,
			u = vertex.u,
			v = vertex.v,
			color = Color(
				math.floor(c.x ^ (1 / 2.2) * 255 + 0.5),
				math.floor(c.y ^ (1 / 2.2) * 255 + 0.5),
				math.floor(c.z ^ (1 / 2.2) * 255 + 0.5),
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
