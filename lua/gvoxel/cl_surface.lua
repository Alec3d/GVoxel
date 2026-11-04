local V = GVoxel
if V.ReleaseClientScan then
	V.ReleaseClientScan()
end
-- Keep the albedo fallback small; the visible, baked surface needs more detail.
-- 64 HD + 64 standard slots cap colour storage at 192 MiB (depth excluded).
local SIZE, HD_SIZE, HD_SLOTS, MAX_SLOTS = 256, 512, 64, 128
local captureFlags = bit.bor(TEXTUREFLAGS_CLAMPS or 4, TEXTUREFLAGS_CLAMPT or 8)
local pool = {}
local active = nil
local queue = {}
local textureEnabled =
	CreateClientConVar("vm_surface_textures", "1", true, false, "Textures du BSP sur le terrain voxel", 0, 1)
local cutFallback = CreateMaterial("vm_cut_surface_v1", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$model"] = "1",
	["$nocull"] = "1",
	["$color2"] = "[0.62 0.60 0.55]",
	["$vertexcolor"] = "1",
	["$vertexalpha"] = "0",
})
local frames = {
	{ normal = Vector(1, 0, 0), right = Vector(0, 1, 0), up = Vector(0, 0, 1), angles = Angle(0, 180, 0) },
	{ normal = Vector(-1, 0, 0), right = Vector(0, -1, 0), up = Vector(0, 0, 1), angles = Angle(0, 0, 0) },
	{ normal = Vector(0, 1, 0), right = Vector(-1, 0, 0), up = Vector(0, 0, 1), angles = Angle(0, 270, 0) },
	{ normal = Vector(0, -1, 0), right = Vector(1, 0, 0), up = Vector(0, 0, 1), angles = Angle(0, 90, 0) },
	{ normal = Vector(0, 0, 1), right = Vector(0, -1, 0), up = Vector(1, 0, 0), angles = Angle(90, 0, 0) },
	{ normal = Vector(0, 0, -1), right = Vector(0, -1, 0), up = Vector(-1, 0, 0), angles = Angle(-90, 0, 0) },
}

local function frameFor(normal)
	local index, best = 1, -math.huge
	for i, frame in ipairs(frames) do
		local score = normal:Dot(frame.normal)
		if score > best + 0.00001 then
			index, best = i, score
		end
	end
	return index, frames[index]
end

local function acquire(source)
	local eye = EyePos and EyePos()
	local visible = not eye
		or ((eye - source.point):Dot(source.planeNormal) > 0 and eye:DistToSqr(source.point) < 1536 ^ 2)
	local ranges = visible and { { 1, HD_SLOTS }, { HD_SLOTS + 1, MAX_SLOTS } }
		or { { HD_SLOTS + 1, MAX_SLOTS }, { 1, HD_SLOTS } }
	for _, range in ipairs(ranges) do
		for index = range[1], range[2] do
			local size = index <= HD_SLOTS and HD_SIZE or SIZE
			if not pool[index] then
				local rt = GetRenderTargetEx(
					"vm_ground_snapshot_256_" .. index,
					SIZE,
					SIZE,
					RT_SIZE_LITERAL,
					MATERIAL_RT_DEPTH_SEPARATE,
					captureFlags,
					0,
					IMAGE_FORMAT_RGBA8888
				)
				local lit = GetRenderTargetEx(
					"vm_ground_lit_snapshot_linear_" .. size .. "_" .. index,
					size,
					size,
					RT_SIZE_LITERAL,
					MATERIAL_RT_DEPTH_SEPARATE,
					captureFlags,
					0,
					IMAGE_FORMAT_RGBA16161616F or IMAGE_FORMAT_RGBA8888
				)
				pool[index] = {
					rt = rt,
					lit = lit,
					size = size,
					litMaterial = CreateMaterial(
						"vm_ground_lit_radiance_v2_mat_" .. size .. "_" .. index,
						"UnlitGeneric",
						{
							["$basetexture"] = lit:GetName(),
							["$nocull"] = "1",
							["$vertexcolor"] = "0",
							-- Float captures contain linear radiance. UnlitGeneric's
							-- default sRGB read would darken their shadow values again.
							["$gammacolorread"] = IMAGE_FORMAT_RGBA16161616F and "1" or "0",
						}
					),
					material = CreateMaterial("vm_ground_snapshot_mat_256_" .. index, "VertexLitGeneric", {
						["$basetexture"] = rt:GetName(),
						["$model"] = "1",
						["$nocull"] = "1",
						["$color2"] = "[1 1 1]",
						["$vertexcolor"] = "0",
						["$vertexalpha"] = "0",
					}),
					cutMaterial = CreateMaterial("vm_ground_cut_mat_256_" .. index, "UnlitGeneric", {
						["$basetexture"] = rt:GetName(),
						["$model"] = "1",
						["$nocull"] = "1",
						["$color2"] = "[1 1 1]",
						["$vertexcolor"] = "1",
						["$vertexalpha"] = "0",
					}),
				}
			end
			if not pool[index].used then
				pool[index].used = true
				return pool[index], index
			end
		end
	end
end

function V.BeginSurfaceCapture(r)
	active = r
	queue = {}
	r.cutLighting = nil
	r.surfaceSources = {}
	r.surfaceList = {}
	r.surfaceFinished = 0
	r.surfaceFailed = 0
	r.surfaceChoices = {}
end

function V.ReleaseSurfaceCapture(r)
	if not r then
		return
	end
	if V.ReleaseVoxelLighting then
		V.ReleaseVoxelLighting(r)
	end
	for _, source in ipairs(r.surfaceList or {}) do
		source.slot.used = false
	end
	if active == r then
		active = nil
		queue = {}
	end
	r.surfaceSources = nil
	r.surfaceList = nil
end

function V.SurfaceCaptureReady(r)
	return r.surfaceList and r.surfaceFinished == #r.surfaceList
end

function V.FreezeSurfaceSources(r)
	r.surfaceFrozen = true
end

local function recoverMaterial(source, r)
	-- Image capture also works on displacements, whose HitTexture is a marker.
	-- Ordinary BSP materials additionally supply an unstretched wall texture.
	local n = source.frame.normal
	local face = source.nativeFace or (V.BSPFaceAt and V.BSPFaceAt(r, source.point, source.planeNormal or n))
	local texture = face and face.tex and r.bsp and r.bsp.textures and r.bsp.textures[face.tex.texture]
	local tr = texture
			and {
				Hit = true,
				HitWorld = true,
				HitPos = source.point,
				HitNormal = source.planeNormal or n,
				HitTexture = texture.name,
			}
		or util.TraceLine({
			start = source.point + n * (r.step * 2 + 2),
			endpos = source.point - n * (r.step * 2 + 2),
			mask = MASK_SOLID_BRUSHONLY,
			filter = function(ent)
				return ent:IsWorld()
			end,
		})
	if tr.HitWorld and tr.Hit and not tr.StartSolid and not tr.HitSky then
		source.lightOrigin = tr.HitPos + tr.HitNormal * (r.step * 0.5 + 4)
		source.planeNormal = source.planeNormal or tr.HitNormal
	end
	local name = tr.HitTexture
	if
		not tr.HitWorld
		or not tr.Hit
		or tr.StartSolid
		or tr.HitSky
		or tr.HitNoDraw
		or type(name) ~= "string"
		or name == ""
		or name:sub(1, 1) == "*"
		or name:sub(1, 6) == "tools/"
	then
		return
	end
	local material = Material(name)
	if material:IsError() then
		return
	end
	local base = material:GetTexture("$basetexture")
	if not base or base:IsError() then
		return
	end
	source.materialName = name
	source.tileU = math.max(16, base:Width() * 0.25)
	source.tileV = math.max(16, base:Height() * 0.25)
	if texture then
		source.nativeFace = face
		source.tex = face.tex
		source.textureSize = texture
		source.tileU = texture.w / math.max(0.000001, face.tex.u:Length())
		source.tileV = texture.h / math.max(0.000001, face.tex.v:Length())
	end
	local params = {
		["$basetexture"] = base:GetName(),
		["$model"] = "1",
		["$nocull"] = "1",
		["$color2"] = "[1 1 1]",
		["$vertexcolor"] = "0",
		["$vertexalpha"] = "0",
	}
	for _, key in ipairs({ "$color", "$color2" }) do
		local tint = material.GetVector and material:GetVector(key)
		if tint then
			params[key] = string.format("[%g %g %g]", tint.x, tint.y, tint.z)
		end
	end
	if material.GetInt then
		for _, key in ipairs({ "$alphatest", "$translucent" }) do
			if material:GetInt(key) == 1 then
				params[key] = "1"
			end
		end
	end
	-- This pass has no lightmap UV channel. Recover base color into a lit mesh
	-- shader; normal maps would additionally need tangent data.
	-- Slot names are reused, but source materials must not inherit old maps.
	source.interior = CreateMaterial("vm_ground_wall_native_" .. util.CRC(name), "VertexLitGeneric", params)
	local cutParams = {}
	for key, value in pairs(params) do
		cutParams[key] = value
	end
	cutParams["$vertexcolor"] = "1"
	-- Excavation reveals a new substrate, not the reflective finish of the
	-- original wall/floor. Keep its diffuse material independent of that finish.
	source.interiorCut = CreateMaterial("vm_ground_wall_reveal_v2_" .. util.CRC(name), "UnlitGeneric", cutParams)
	local surfaceParams = {}
	for key, value in pairs(cutParams) do
		surfaceParams[key] = value
	end
	cutParams = surfaceParams
	-- The compiled BSP commonly resolves env_cubemap to a map-local texture.
	-- Keep that explicit reflection in the static pass only; the dynamic-light
	-- albedo must not add it again. Normal-map alpha masks need tangent data.
	local env = material.GetString and material:GetString("$envmap")
	local normalMask = material.GetInt and material:GetInt("$normalmapalphaenvmapmask") == 1
	if env and env ~= "" and env ~= "env_cubemap" and not normalMask then
		source.nativeReflection = true
		cutParams["$envmap"] = env
		local mask = material:GetString("$envmapmask")
		if mask and mask ~= "" then
			cutParams["$envmapmask"] = mask
		end
		if material.GetInt and material:GetInt("$basealphaenvmapmask") == 1 then
			cutParams["$basealphaenvmapmask"] = "1"
		end
		local tint = material.GetVector and material:GetVector("$envmaptint")
		if tint then
			cutParams["$envmaptint"] = string.format("[%g %g %g]", tint.x, tint.y, tint.z)
		end
		for _, key in ipairs({ "$envmapcontrast", "$envmapsaturation" }) do
			local value = material.GetFloat and material:GetFloat(key)
			if value then
				cutParams[key] = tostring(value)
			end
		end
	end
	source.surfaceCut = CreateMaterial("vm_ground_wall_cut_" .. util.CRC(name), "UnlitGeneric", cutParams)
end

local function solid(point)
	return util.PointContents and bit.band(util.PointContents(point), CONTENTS_SOLID) ~= 0
end

local function cameraClear(source, center, distance, tangent, anchor)
	local frame = source.frame
	local origin = center + frame.normal * distance
	if solid(origin) then
		return false
	end
	-- Check the near plane as well; a free origin immediately next to a wall
	-- can still put part of the image inside the BSP.
	if util.PointContents then
		for _, x in ipairs({ -1, 1 }) do
			for _, y in ipairs({ -1, 1 }) do
				if solid(origin - frame.normal + frame.right * (x * tangent) + frame.up * (y * tangent)) then
					return false
				end
			end
		end
		if solid(anchor) then
			return false
		end
		local tr = util.TraceLine({
			start = anchor,
			endpos = origin,
			mask = MASK_SOLID_BRUSHONLY,
			filter = function(ent)
				return ent:IsWorld()
			end,
		})
		-- Also reject a free camera on the far side of a ceiling/wall.
		if tr.StartSolid or tr.AllSolid or (tr.Hit and tr.Fraction and tr.Fraction < 0.9999) then
			return false
		end
	end
	return true
end

local function planCapture(source, box, anchorPoint, anchorNormal)
	local frame = source.frame
	local corners = {}
	for _, x in ipairs({ box.low.x, box.high.x }) do
		for _, y in ipairs({ box.low.y, box.high.y }) do
			for _, z in ipairs({ box.low.z, box.high.z }) do
				corners[#corners + 1] = Vector(x, y, z)
			end
		end
	end
	local originalCenter = source.center
	-- First keep the usual camera. In an enclosed room try progressively
	-- closer cameras, then center on an actual face instead of a chunk center
	-- which may sit on the wrong side of a corner. Freeze this BEFORE UVs.
	for _, candidate in ipairs({
		{ center = originalCenter, point = source.point, normal = source.planeNormal },
		{ center = source.point, point = source.point, normal = source.planeNormal },
		{ center = anchorPoint, point = anchorPoint, normal = anchorNormal },
	}) do
		local center = candidate.center
		local distance = source.span / 2 + 4
		for _, p in ipairs(corners) do
			local q = p - center
			distance = math.max(
				distance,
				q:Dot(frame.normal) + math.max(math.abs(q:Dot(frame.right)), math.abs(q:Dot(frame.up))) + 4
			)
		end
		local anchor = candidate.point + candidate.normal * 2
		for attempt = 0, 7 do
			local d = distance * 0.75 ^ attempt
			local tangent, valid = 1, true
			for _, p in ipairs(corners) do
				local q = p - center
				local depth = d - q:Dot(frame.normal) - 2
				if depth <= 1 then
					valid = false
					break
				end
				tangent = math.max(tangent, math.abs(q:Dot(frame.right)) / depth, math.abs(q:Dot(frame.up)) / depth)
			end
			if valid and tangent <= math.tan(math.rad(70)) and cameraClear(source, center, d, tangent, anchor) then
				source.center = center
				source.cameraDistance = d
				source.cameraTangent = tangent
				source.cameraFov = math.deg(math.atan(tangent)) * 2
				source.cameraAnchor = anchor
				return true
			end
		end
	end
	return false
end

local function registerSources(r, item, vertices, checkpoint)
	local scores, points, normals, bounds, anchors, orientations, faces = {}, {}, {}, {}, {}, {}, {}
	local offset = r.origin + Vector(item.x, item.y, item.z) * (r.step * 8)
	for i = 1, #vertices, 3 do
		local a, b, c = vertices[i].pos, vertices[i + 1].pos, vertices[i + 2].pos
		local cross = (b - a):Cross(c - a)
		local area = math.sqrt(cross:LengthSqr())
		-- Render triangles use Source clockwise winding.
		local orientation = frameFor(cross * -1)
		local center = (a + b + c) / 3 + offset
		local face = vertices[i].nativeFace
			or (V.BSPFaceAt and r.bsp and V.BSPFaceAt(r, center, cross:GetNormalized() * -1))
		-- Preserve the original sampled triangle's material provenance. The
		-- closest source centroid may belong to a buried parallel ceiling.
		vertices[i].surfaceFace = face
		-- Separate parallel floors as well as orientation. A road and the
		-- ground beneath it must never average into an imaginary middle plane.
		local index = face or orientation
		orientations[index] = orientation
		faces[index] = face
		scores[index] = (scores[index] or 0) + area
		points[index] = (points[index] or Vector()) + ((a + b + c) / 3 + offset) * area
		normals[index] = (normals[index] or Vector()) + cross * -1
		if not anchors[index] or area > anchors[index].area then
			anchors[index] = { area = area, point = (a + b + c) / 3 + offset, normal = cross:GetNormalized() * -1 }
		end
		bounds[index] = bounds[index]
			or { low = Vector(math.huge, math.huge, math.huge), high = Vector(-math.huge, -math.huge, -math.huge) }
		for _, point in ipairs({ a, b, c }) do
			for _, axis in ipairs({ "x", "y", "z" }) do
				bounds[index].low[axis] = math.min(bounds[index].low[axis], point[axis] + offset[axis])
				bounds[index].high[axis] = math.max(bounds[index].high[axis], point[axis] + offset[axis])
			end
		end
		if checkpoint and i % 96 == 1 then
			checkpoint()
		end
	end
	local order = {}
	for index, score in pairs(scores) do
		order[#order + 1] = { index = index, score = score }
	end
	table.sort(order, function(a, b)
		return a.score > b.score
	end)
	local sources = {}
	for _, entry in ipairs(order) do
		local index, best = entry.index, entry.score
		local source = {
			region = r,
			frame = frames[orientations[index]],
			nativeFace = faces[index],
			point = points[index] / best,
			span = r.step * 8,
			center = offset + Vector(1, 1, 1) * (r.step * 4),
			materialCells = {},
			building = true,
		}
		source.identity = #r.surfaceList + 1
		source.planeNormal = normals[index]:GetNormalized()
		local n = source.frame.normal
        if source.nativeFace then
            -- Spend capture texels on the real wall/floor patch, not empty
            -- space around a small ledge or ceiling inside its chunk.
            source.center=(bounds[index].low+bounds[index].high)*0.5
            local size=bounds[index].high-bounds[index].low
            local function extent(axis) return math.abs(axis.x)*size.x+math.abs(axis.y)*size.y+math.abs(axis.z)*size.z end
            source.span=math.max(8,extent(source.frame.right),extent(source.frame.up))
        end
		source.center = source.center + n * (source.point - source.center):Dot(n)
		local anchor = anchors[index]
		source.lightBounds = bounds[index]
		source.lightAnchor = anchor.point
		local planned = planCapture(source, bounds[index], anchor.point, anchor.normal)
		local slot, slotIndex
		if planned then
			slot, slotIndex = acquire(source)
		end
		local uncaptured = not slot
		source.slot = slot or { material = V.ScanSurfaceMaterial, litMaterial = V.ScanSurfaceMaterial }
		source.slotIndex = slotIndex or 0
		source.ready = uncaptured
		source.failed = uncaptured
		source.uncaptured = uncaptured
		source.fallbackReason = not planned and "camera BSP obstruee" or uncaptured and "budget de captures" or nil
		recoverMaterial(source, r)
		sources[#sources + 1] = source
		r.surfaceList[#r.surfaceList + 1] = source
		if uncaptured then
			r.surfaceFinished = r.surfaceFinished + 1
			r.surfaceFailed = r.surfaceFailed + 1
		else
			queue[#queue + 1] = { region = r, source = source }
		end
	end
	r.surfaceSources[item.key] = sources
	return sources
end

local function nearestSource(r, point, normal, list, nativeFace)
	local choices, key
	if r.surfaceFrozen and (not list or #list == 0) then
		-- New underground chunks have no original face of their own. Reuse
		-- source selection on the material grid instead of scanning every
		-- captured source again for every tiny triangle.
		r.surfaceChoices = r.surfaceChoices or {}
		choices = r.surfaceChoices
		local q = (point - r.origin) / (r.step * 0.5)
		key = math.floor(q.x) + 65 * (math.floor(q.y) + 65 * math.floor(q.z)) + 274625 * frameFor(normal)
		local cached = choices[key]
		if cached and (not nativeFace or cached.nativeFace == nativeFace) then
			return cached
		end
	end
	local best, distance = nil, math.huge
	for _, source in ipairs(list and #list > 0 and list or r.surfaceList) do
		if nativeFace and source.nativeFace == nativeFace then
			return source
		end
		local bounds = source.lightBounds
		local d = point:DistToSqr(source.point)
		if bounds then
			local low, high = bounds.low, bounds.high
			local dx = math.max(low.x - point.x, 0, point.x - high.x)
			local dy = math.max(low.y - point.y, 0, point.y - high.y)
			local dz = math.max(low.z - point.z, 0, point.z - high.z)
			local plane = (point - source.point):Dot(source.planeNormal or source.frame.normal)
			d = math.max(dx * dx + dy * dy + dz * dz, plane * plane)
		end
		d = d + (1 - normal:Dot(source.frame.normal)) * r.step * r.step * 64
		if d < distance then
			best, distance = source, d
		end
	end
	if choices then
		choices[key] = best
	end
	return best
end

local function materialAt(r, source, point)
	if source.nativeFace then
		return source
	end
	-- A capture can contain grass next to concrete. Recover the original
	-- material at cell resolution, rather than painting the whole cut with
	-- the one material found at the middle of its chunk.
	local q = point - source.center
	local x = math.max(0, math.min(15, math.floor(8 + q:Dot(source.frame.right) / source.span * 16)))
	local y = math.max(0, math.min(15, math.floor(8 + q:Dot(source.frame.up) / source.span * 16)))
	local key = x + y * 16
	if not source.materialCells[key] then
		local p = source.center
			+ source.frame.right * ((x + 0.5) / 16 - 0.5) * source.span
			+ source.frame.up * ((y + 0.5) / 16 - 0.5) * source.span
		local sample = {
			frame = source.frame,
			point = p,
			span = source.span,
			center = source.center,
			slotIndex = source.slotIndex,
		}
		recoverMaterial(sample, r)
		source.materialCells[key] = sample
	end
	return source.materialCells[key]
end

function V.SurfaceUV(source, world, normal, original)
	local frame = source.frame
	local q = world - source.center
	if original then
		-- Exact projection of the frozen square camera, including its FOV
		-- and depth, keeps sloped original surfaces aligned between captures.
		local depth = (source.cameraDistance or source.span / 2 + 4) - q:Dot(frame.normal)
		if depth <= 1 then
			return -1, -1
		end
		local scale = 2 * depth * (source.cameraTangent or 1)
		return 0.5 + q:Dot(frame.right) / scale, 0.5 - q:Dot(frame.up) / scale
	end
	if source.tex and source.textureSize then
		local tex, size = source.tex, source.textureSize
		-- The compiled axes retain scale, rotation and phase on parallel
		-- surfaces. Cross-sections use a frame with two non-zero UV axes.
		local projected = tex.u:Cross(tex.v):GetNormalized()
		if math.abs(normal:Dot(projected)) > 0.9 then
			return (world:Dot(tex.u) + tex.uo) / size.w, (world:Dot(tex.v) + tex.vo) / size.h
		end
	end
	local _, wall = frameFor(normal)
	-- Absolute world coordinates keep adjacent edited chunks in phase. A
	-- different projection on vertical walls prevents a collapsed ground UV.
	return world:Dot(wall.right) / (source.tileU or source.span), -world:Dot(wall.up) / (source.tileV or source.span)
end

local function lightmapFallback(r, source, vertices, offset, checkpoint)
	if not V.SurfaceLightmap or not V.EncodeCutLighting then
		return
	end
	local fallback = {}
	for i, vertex in ipairs(vertices) do
		local world = vertex.pos + offset
		local light = V.SurfaceLightmap(r, source, world)
		if not light then
			return
		end
		local u, v = V.SurfaceUV(source, world, vertex.normal, false)
		fallback[i] = { pos = vertex.pos, normal = vertex.normal, u = u, v = v, cutLight = light }
		if checkpoint and i % 48 == 0 then
			checkpoint()
		end
	end
	return V.EncodeCutLighting(fallback, checkpoint)
end

function V.BuildSurfaceBatches(r, item, vertices, checkpoint)
	if #vertices == 0 then
		return {}
	end
	local own = r.surfaceSources[item.key]
	if not own and not r.surfaceFrozen then
		own = registerSources(r, item, vertices, checkpoint)
	end
	local offset = r.origin + Vector(item.x, item.y, item.z) * (r.step * 8)
	local groups = {}
	local targetGroups = groups
	local cells = V.TerrainCellCache(r, "surfaceCells", item.x * 8, item.y * 8, item.z * 8)
	local function merge(other)
		for key, source in pairs(other) do
			local group = groups[key]
			if not group then
				group = {}
				for k, v in pairs(source) do
					group[k] = v
				end
				group.vertices = {}
				group.pointSum = Vector()
				group.normalSum = Vector()
				group.weight = 0
				groups[key] = group
			end
			for _, vertex in ipairs(source.vertices) do
				group.vertices[#group.vertices + 1] = vertex
			end
			group.pointSum = group.pointSum + source.pointSum
			group.normalSum = group.normalSum + source.normalSum
			group.weight = group.weight + source.weight
		end
	end
	local function append(a, b, c, source, normal, original, appearance, surfaceLight)
		local material = source
				and (original and source.slot.litMaterial or appearance.interior or source.slot.material)
			or V.ScanSurfaceMaterial
		local flashMaterial = original and source.slot.material or material
		local cutLighting = surfaceLight
			or (not original and r.cutLighting ~= nil and r.cutLighting.sourceCount > 0 and V.CutVertexLighting ~= nil)
		if cutLighting then
			material = appearance and (surfaceLight and appearance.surfaceCut or appearance.interiorCut)
				or source and source.slot.cutMaterial
				or cutFallback
		end
		local projection = not original and frameFor(normal)
		local key = source
				and (original and (source.slotIndex .. ":surface") or ("wall:" .. (source.identity or source.slotIndex) .. ":" .. projection .. ":" .. (appearance.materialName or ("snapshot:" .. source.slotIndex))))
			or "plain"
		if cutLighting then
			key = key .. (surfaceLight and ":lightmap" or ":gradient")
		end
		if not targetGroups[key] then
			targetGroups[key] = {
				material = material,
				vertices = {},
				source = source,
				baked = original,
				flashMaterial = flashMaterial,
				cutLighting = cutLighting,
				surfaceLight = surfaceLight ~= nil,
				lightOrigin = appearance and appearance.lightOrigin or source and source.lightOrigin,
				pointSum = Vector(),
				normalSum = Vector(),
				weight = 0,
			}
		end
		local group = targetGroups[key]
		local weight = math.sqrt((b.pos - a.pos):Cross(c.pos - a.pos):LengthSqr())
		group.pointSum = group.pointSum + ((a.pos + b.pos + c.pos) / 3 + offset) * weight
		group.normalSum = group.normalSum + normal * weight
		group.weight = group.weight + weight
		for index, old in ipairs({ a, b, c }) do
			local u, v = old.u, old.v
			if source then
				u, v = V.SurfaceUV(appearance, old.pos + offset, normal, original)
			end
			group.vertices[#group.vertices + 1] = {
				pos = old.pos,
				normal = old.normal,
				u = u,
				v = v,
				color = color_white,
				cutLight = surfaceLight and surfaceLight[index]
					or cutLighting and V.CutVertexLighting(r, old.pos + offset, old.normal, checkpoint)
					or nil,
			}
		end
	end
	local function splitCut(a, b, c, source, normal, depth)
		-- Native-face provenance already proves a single material. Testing
		-- four points and edge lengths cannot discover a texture boundary.
		if source.nativeFace then
			append(a, b, c, source, normal, false, source)
			return
		end
		local center = (a.pos + b.pos + c.pos) / 3 + offset
		local appearance = materialAt(r, source, center)
		local different = false
		for _, vertex in ipairs({ a, b, c }) do
			local sample = materialAt(r, source, vertex.pos + offset)
			if sample.materialName ~= appearance.materialName then
				different = true
				break
			end
		end
		local ab, bc, ca = a.pos:DistToSqr(b.pos), b.pos:DistToSqr(c.pos), c.pos:DistToSqr(a.pos)
		if different and depth < 3 and math.max(ab, bc, ca) > (r.step * 0.125) ^ 2 then
			local first, second = a, b
			if bc >= ab and bc >= ca then
				first, second = b, c
			elseif ca >= ab and ca >= bc then
				first, second = c, a
			end
			local middle =
				{ pos = (first.pos + second.pos) / 2, normal = (first.normal + second.normal):GetNormalized() }
			if first == a then
				splitCut(a, middle, c, source, normal, depth + 1)
				splitCut(middle, b, c, source, normal, depth + 1)
			elseif first == b then
				splitCut(a, b, middle, source, normal, depth + 1)
				splitCut(a, middle, c, source, normal, depth + 1)
			else
				splitCut(a, b, middle, source, normal, depth + 1)
				splitCut(middle, b, c, source, normal, depth + 1)
			end
		else
			append(a, b, c, source, normal, false, appearance)
		end
	end
	local function triangle(i)
		local center = (vertices[i].pos + vertices[i + 1].pos + vertices[i + 2].pos) / 3 + offset
		local normal = (vertices[i + 1].pos - vertices[i].pos)
			:Cross(vertices[i + 2].pos - vertices[i].pos)
			:GetNormalized() * -1
		local face = vertices[i].nativeFace
			or vertices[i].surfaceFace
			or (V.BSPFaceAt and r.bsp and V.BSPFaceAt(r, center, normal, r.step * 0.5))
		local source = nearestSource(r, center, normal, own, face)
		local planeNormal = source and (source.planeNormal or source.frame.normal)
		local onSurface = source and normal:Dot(planeNormal) > 0.9
		if onSurface then
			for j = i, i + 2 do
				if math.abs((vertices[j].pos + offset - source.point):Dot(planeNormal)) > r.step * 0.1 then
					onSurface = false
					break
				end
			end
		end
		-- Provenance survives clipping a BSP polygon around a hole. A touched
		-- cell is not necessarily a new interior face: keep its original
		-- shadow/reflection capture, including native displacement triangles.
		if
			source
			and (vertices[i].nativeFace or vertices[i].surfaceFace)
			and (vertices[i].nativeFace or vertices[i].surfaceFace) == source.nativeFace
		then
			onSurface = true
		end
		-- The first mesh is entirely original terrain, including sampled
		-- displacement vertices a few units away from their source plane.
		-- Do not misclassify those vertices as freshly exposed underground soil.
		local original = source and (onSurface or not r.surfaceFrozen) and not source.failed
		if original then
			for j = i, i + 2 do
				local u, v = V.SurfaceUV(source, vertices[j].pos + offset, normal, true)
				if u < -0.0001 or u > 1.0001 or v < -0.0001 or v > 1.0001 then
					original = false
					break
				end
			end
		end
		local surfaceLight
		if
			source
			and not original
			and (onSurface or not r.surfaceFrozen)
			and V.SurfaceLightmap
			and V.EncodeCutLighting
		then
			local a = V.SurfaceLightmap(r, source, vertices[i].pos + offset)
			local b = V.SurfaceLightmap(r, source, vertices[i + 1].pos + offset)
			local c = V.SurfaceLightmap(r, source, vertices[i + 2].pos + offset)
			if a and b and c then
				-- Keep the native capture whenever possible. A generic mesh
				-- shader cannot reproduce the world's bump/Fresnel reflection.
				surfaceLight = { a, b, c }
				original = false
			end
		end
		if surfaceLight then
			append(vertices[i], vertices[i + 1], vertices[i + 2], source, normal, false, source, surfaceLight)
		elseif source and not original then
			splitCut(vertices[i], vertices[i + 1], vertices[i + 2], source, normal, 0)
		else
			append(vertices[i], vertices[i + 1], vertices[i + 2], source, normal, original, source)
		end
		if checkpoint and i % 48 == 1 then
			checkpoint()
		end
	end
	local i = 1
	while i <= #vertices do
		local cell = vertices[i].cell
		local finish = i + 3
		if cell then
			while finish <= #vertices and vertices[finish].cell == cell do
				finish = finish + 3
			end
		end
		local cached = cell and cells[cell]
		if cached and cached.epoch == (r.surfaceEpoch or 0) then
			merge(cached.groups)
		else
			targetGroups = cell and {} or groups
			for index = i, finish - 3, 3 do
				triangle(index)
			end
			if cell then
				cells[cell] = { groups = targetGroups, epoch = r.surfaceEpoch or 0 }
				merge(targetGroups)
			end
		end
		i = finish
		if checkpoint then
			checkpoint()
		end
	end
	local batches = {}
	for _, group in pairs(groups) do
		-- Keep normals in the vertex layout for the flashlight pass and a
		-- possible native-material fallback, even when the main pass is unlit.
		-- The PC UnlitGeneric layout retains normals AND vertex color. A
		-- pending capture can therefore fall back to a lightmap-colored mesh
		-- without changing its native vertex format or allocating another mesh.
		local object = Mesh(group.baked and group.source.slot.cutMaterial or group.material)
		if checkpoint then
			checkpoint(object)
		end
		local meshVertices, cutScale = group.vertices, nil
		if group.cutLighting then
			meshVertices, cutScale = V.EncodeCutLighting(group.vertices, checkpoint)
		end
		object:BuildFromTriangles(meshVertices)
		if checkpoint then
			checkpoint()
		end
		local batch = {
			mesh = object,
			material = group.material,
			source = group.source,
			baked = group.baked,
			flashMaterial = group.flashMaterial,
			lightOrigin = group.lightOrigin,
			cutLighting = group.cutLighting,
			cutScale = cutScale,
			surfaceLight = group.surfaceLight,
			worldCenter = group.pointSum / math.max(group.weight, 0.000001),
			normal = group.normalSum:GetNormalized(),
		}
		batches[#batches + 1] = batch
		if batch.baked and not batch.source.ready then
			-- Retain only until this source completes. If capture fails after
			-- UV construction, reproject the SAME mesh to native tiled UVs.
			batch.source.pendingBatches = batch.source.pendingBatches or {}
			local fallback, scale = lightmapFallback(r, batch.source, group.vertices, offset, checkpoint)
			table.insert(
				batch.source.pendingBatches,
				{ batch = batch, vertices = group.vertices, offset = offset, fallback = fallback, scale = scale }
			)
		end
	end
	for _, source in ipairs(own or {}) do
		source.building = false
	end
	return batches
end

-- Capture only the BSP. Players, props, selection overlays and the voxel
-- replacement itself must never become part of the frozen ground image.
hook.Add("PreDrawOpaqueRenderables", "GVoxel.CaptureOpaque", function(depth)
	if V.CapturingSurface and not depth then
		return true
	end
end)
hook.Add("PreDrawTranslucentRenderables", "GVoxel.CaptureTranslucent", function()
	if V.CapturingSurface then
		return true
	end
end)

local function finishCapture(source, failed, reason)
	source.ready = true
	source.failed = failed
	source.fallbackReason = reason
	if V.PrepareSurfaceLighting and source.region then
		V.PrepareSurfaceLighting(source, source.region)
	end
	if failed and source.region then
		source.region.surfaceEpoch = (source.region.surfaceEpoch or 0) + 1
	end
	for _, pending in ipairs(source.pendingBatches or {}) do
		if failed and pending.batch.mesh and pending.batch.mesh:IsValid() then
			local batch = pending.batch
			if pending.fallback then
				batch.mesh:BuildFromTriangles(pending.fallback)
				batch.material = source.surfaceCut or source.interiorCut or cutFallback
				batch.flashMaterial = source.interior or V.ScanSurfaceMaterial
				batch.cutLighting = true
				batch.surfaceLight = true
				batch.cutScale = pending.scale
				batch.baked = false
			else
				for _, vertex in ipairs(pending.vertices) do
					vertex.u, vertex.v = V.SurfaceUV(source, vertex.pos + pending.offset, vertex.normal, false)
				end
				batch.mesh:BuildFromTriangles(pending.vertices)
				batch.material = source.interior or V.ScanSurfaceMaterial
				batch.flashMaterial = batch.material
				batch.baked = false
			end
		end
	end
	source.pendingBatches = nil
end

local function capture(source)
	-- Geometry obstruction is an expected fallback, not a Lua exception. Do
	-- not move the camera here: its projection is already frozen into UVs.
	local distance = source.cameraDistance or source.span / 2 + 4
	if
		not cameraClear(
			source,
			source.center,
			distance,
			source.cameraTangent or 1,
			source.cameraAnchor or source.point + source.planeNormal * 2
		)
	then
		finishCapture(source, true, "camera BSP obstruee")
		return
	end
	local pushed = false
	local tone = render.GetToneMappingScaleLinear
		and render.SetToneMappingScaleLinear
		and render.GetToneMappingScaleLinear()
	-- X is exposure; Y and Z decode the engine's lightmaps and cubemaps.
	-- Neutralizing all three underexposes baked shadows on HDR maps.
	local captureTone = tone and Vector(1, tone.y, tone.z)
	V.CapturingSurface = true
	V.RenderingReplacement = true
	local ok, err = xpcall(function()
		-- All patches use one exposure. Otherwise the player's eye adaptation
		-- while scanning is baked into neighboring images with different gains.
		if captureTone then
			render.SetToneMappingScaleLinear(captureTone)
		end
		local half = source.span / 2
		local view = {
			origin = source.center + source.frame.normal * distance,
			angles = source.frame.angles,
			x = 0,
			y = 0,
			w = SIZE,
			h = SIZE,
			aspect = 1,
			fov = source.cameraFov or 90,
			znear = 1,
			zfar = math.max(source.span + 8, distance + half + 4),
			drawhud = false,
			drawviewmodel = false,
			drawmonitors = false,
			drawviewer = false,
			dopostprocess = false,
			bloomtone = false,
			viewid = VIEW_MONITOR or 2,
		}
		-- Keep the engine's original sky lighting and baked shadows intact.
		-- A second, unlit albedo capture is reserved for new cut geometry.
		for _, pass in ipairs({
			{ rt = source.slot.lit, mode = 0, size = source.slot.size },
			{
				rt = source.slot.rt,
				mode = 1,
				size = SIZE,
			},
		}) do
			view.w = pass.size
			view.h = pass.size
			render.PushRenderTarget(pass.rt)
			pushed = true
			render.Clear(80, 74, 65, 255, true, true)
			if captureTone then
				render.SetToneMappingScaleLinear(pass.mode == 0 and captureTone or Vector(1, 1, 1))
			end
			render.SetLightingMode(pass.mode)
			render.RenderView(view)
			render.PopRenderTarget()
			pushed = false
		end
	end, debug.traceback)
	render.SetLightingMode(0)
	if pushed then
		render.PopRenderTarget()
	end
	if tone then
		render.SetToneMappingScaleLinear(tone)
	end
	V.CapturingSurface = false
	V.RenderingReplacement = false
	finishCapture(source, not ok, not ok and "erreur du rendu" or nil)
	if not ok then
		ErrorNoHalt("[GVoxel] Capture de texture impossible : " .. tostring(err) .. "\n")
	end
end

hook.Add("PostRender", "GVoxel.CaptureGround", function()
	if V.CapturingSurface or V.RenderingReplacement or render.GetRenderTarget() ~= nil then
		return
	end
	-- One bounded snapshot per frame. Rebuilding a stroke never recaptures the
	-- map, and the bounded render-target pool is reused across successive scans.
	local job = queue[1]
	if job and job.source.building then
		return
	end
	table.remove(queue, 1)
	if not job or job.region ~= active then
		return
	end
	capture(job.source)
	active.surfaceFinished = active.surfaceFinished + 1
	if job.source.failed then
		active.surfaceFailed = active.surfaceFailed + 1
	end
end)

function V.SurfaceMaterial(batch)
	if not textureEnabled:GetBool() then
		return batch.cutLighting and cutFallback or V.ScanSurfaceMaterial
	end
	if
		batch.source
		and batch.source.failed
		and not batch.source.uncaptured
		and (
			batch.baked
			or batch.material == batch.source.slot.material
			or batch.material == batch.source.slot.cutMaterial
		)
	then
		return batch.cutLighting and (batch.source.interiorCut or cutFallback)
			or batch.source.interior
			or V.ScanSurfaceMaterial
	end
	return batch.material
end

function V.SurfaceUsesBaked(batch)
	return textureEnabled:GetBool() and batch.baked and batch.source and not batch.source.failed
end

function V.SurfaceFlashMaterial(batch)
	if not textureEnabled:GetBool() then
		return V.ScanSurfaceMaterial
	end
	if
		batch.source
		and batch.source.failed
		and not batch.source.uncaptured
		and (
			batch.baked
			or batch.material == batch.source.slot.material
			or batch.material == batch.source.slot.cutMaterial
		)
	then
		return batch.source.interior or V.ScanSurfaceMaterial
	end
	return batch.flashMaterial or batch.material
end

concommand.Add("vm_texture_stats", function()
	local count, hd = 0, 0
	for _, slot in pairs(pool) do
		count = count + 1
		if slot.used and slot.size == HD_SIZE then
			hd = hd + 1
		end
	end
	print(
		string.format(
			"[GVoxel] Textures: %d / %d sources pretes | secours: %d | paires reutilisables: %d / %d | HD %d / %d (%d px ; couleurs <=192 MiB)",
			active and active.surfaceFinished or 0,
			active and #active.surfaceList or 0,
			active and active.surfaceFailed or 0,
			count,
			MAX_SLOTS,
			hd,
			HD_SLOTS,
			HD_SIZE
		)
	)
	local captured, lightmaps, interior, fallback = 0, 0, 0, 0
	for _, chunk in pairs(active and active.chunks or {}) do
		for _, batch in ipairs(chunk.batches or {}) do
			if batch.baked and not batch.source.failed then
				captured = captured + 1
			elseif batch.surfaceLight then
				lightmaps = lightmaps + 1
			elseif batch.cutLighting then
				interior = interior + 1
			else
				fallback = fallback + 1
			end
		end
	end
	print(
		string.format(
			"[GVoxel] Eclairage des groupes : capture %d ; lightmap locale %d (%s) ; interieur %d ; sonde de secours %d.",
			captured,
			lightmaps,
			active and active.bsp and active.bsp.lightingHDR and "HDR" or "LDR",
			interior,
			fallback
		)
	)
end)
hook.Add("ShutDown", "GVoxel.ReleaseSurfaceTextures", function()
	V.ReleaseSurfaceCapture(active)
end)
