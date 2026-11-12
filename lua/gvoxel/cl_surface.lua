local V = GVoxel
if V.ReleaseClientScan then
	V.ReleaseClientScan()
end
-- Keep the albedo fallback small; the visible, baked surface needs more detail.
-- 32 HD + 96 standard slots cap HDR colour storage at 144 MiB (depth excluded).
local SIZE, HD_SIZE, HD_SLOTS, MAX_SLOTS = 256, 512, 32, 128
local captureFlags = bit.bor(TEXTUREFLAGS_CLAMPS or 4, TEXTUREFLAGS_CLAMPT or 8)
local pools = { hdr = {}, ldr = {} }
local active = nil
local captureTargetName
local queue = {}
local queueHead = 1
local surfacePartIds = setmetatable({}, { __mode = "k" })
local nextSurfacePartId = 0
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
local dirtFallback = CreateMaterial("vm_cut_dirt_v1", "UnlitGeneric", {
	["$basetexture"] = "nature/dirtfloor001a",
	["$model"] = "1",
	["$nocull"] = "1",
	["$vertexcolor"] = "1",
})
local dirtAlbedo = CreateMaterial("vm_cut_dirt_albedo_v1", "UnlitGeneric", {
	["$basetexture"] = "nature/dirtfloor001a",
	["$model"] = "1",
	["$nocull"] = "1",
})
-- Projected lights need a lit shader, even for the unknown cut material.
-- The unlit diffuse fallback belongs only in the explicit additive pass.
local dirtFlash = CreateMaterial("vm_cut_dirt_projected_v1", "VertexLitGeneric", {
	["$basetexture"] = "nature/dirtfloor001a",
	["$model"] = "1",
	["$nocull"] = "1",
	["$vertexcolor"] = "0",
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
	local x, y, z = normal.x, normal.y, normal.z
	local index, best = 1, x
	-- The frames are the six signed world axes, in this tie-break order.
	if -x > best + 0.00001 then index, best = 2, -x end
	if y > best + 0.00001 then index, best = 3, y end
	if -y > best + 0.00001 then index, best = 4, -y end
	if z > best + 0.00001 then index, best = 5, z end
	if -z > best + 0.00001 then index = 6 end
	return index, frames[index]
end

local function acquire(source, hdr)
	-- The image format enum exists even when the current map renders in LDR.
	-- Keep the two encodings separate because Source caches RTs by name.
	local encoding = hdr and "hdr" or "ldr"
	local pool = pools[encoding]
	local litTargetPrefix = hdr and "vm_ground_lit_snapshot_linear_" or "vm_ground_lit_snapshot_ldr_"
	local litMaterialPrefix = hdr and "vm_ground_lit_radiance_v2_mat_" or "vm_ground_lit_ldr_mat_"
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
					litTargetPrefix .. size .. "_" .. index,
					size,
					size,
					RT_SIZE_LITERAL,
					MATERIAL_RT_DEPTH_SEPARATE,
					captureFlags,
					0,
					hdr and IMAGE_FORMAT_RGBA16161616F or IMAGE_FORMAT_RGBA8888
				)
				pool[index] = {
					rt = rt,
					lit = lit,
					size = size,
					litMaterial = CreateMaterial(
						litMaterialPrefix .. size .. "_" .. index,
						"UnlitGeneric",
						{
							["$basetexture"] = lit:GetName(),
							["$nocull"] = "1",
							["$vertexcolor"] = "0",
							-- Float captures contain linear radiance. UnlitGeneric's
							-- default sRGB read would darken their shadow values again.
							["$gammacolorread"] = hdr and "1" or "0",
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
	r.surfaceHDR = IMAGE_FORMAT_RGBA16161616F and render.GetHDREnabled and render.GetHDREnabled()
	queue = {}
	queueHead = 1
	r.cutLighting = nil
	r.surfaceSources = {}
	r.surfaceList = {}
	r.surfaceMaterials = {}
	r.surfaceByFace = {}
	r.surfaceNeighbors = {}
	r.surfaceFinished = 0
	r.surfaceFailed = 0
	r.surfaceFrozen = false
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
		queueHead = 1
	end
	r.surfaceSources = nil
	r.surfaceList = nil
	r.surfaceMaterials = nil
	r.surfaceByFace = nil
	r.surfaceNeighbors = nil
end

function V.SurfaceCaptureReady(r)
	return r.surfaceList and r.surfaceFinished == #r.surfaceList
end

function V.FreezeSurfaceSources(r)
	r.surfaceFrozen = true
end

local function validTexture(texture)
	return texture and not texture:IsError() and not (texture.IsErrorTexture and texture:IsErrorTexture())
end

local function vectorParam(value)
	return string.format("[%g %g %g]", value.x, value.y, value.z)
end

local function materialProjection(material, key)
	local matrix = material.GetMatrix and material:GetMatrix(key)
	if not matrix or matrix:IsIdentity() then
		return
	end
	local values = {}
	for row = 1, 4 do
		for column = 1, 4 do
			values[#values + 1] = tostring(matrix:GetField(row, column))
		end
	end
	return { matrix = matrix, key = table.concat(values, ",") }
end

local function wallMaterial(variant, shader, name, params, projection)
	-- CreateMaterial retains named materials. Include the settings so a
	-- newly mounted or refreshed material cannot reuse an old reflection.
	local definition = {}
	for key, value in pairs(params) do
		definition[#definition + 1] = key .. "=" .. value
	end
	table.sort(definition)
	local material = CreateMaterial(
		"vm_ground_wall_" .. variant .. "_" .. util.CRC(name .. table.concat(definition, ";") .. (projection and projection.key or "")),
		shader,
		params
	)
	if projection then
		material:SetMatrix("$basetexturetransform", projection.matrix)
	end
	return material
end

local function readMaterial(name, secondLayer)
	local material = Material(name)
	if material:IsError() then
		return
	end
	local shader = material.GetShader and material:GetShader()
	local secondary = material:GetTexture("$basetexture2")
	local useSecond = secondLayer and shader == "WorldVertexTransition" and validTexture(secondary)
	local base = useSecond and secondary or material:GetTexture("$basetexture")
	if not validTexture(base) then
		return
	end
	local function getInt(key)
		return material.GetInt and material:GetInt(key)
	end
	local function getFloat(key)
		local value = material.GetFloat and material:GetFloat(key)
		if value and value == value and math.abs(value) < math.huge then
			return value
		end
	end
	local function getVector(key)
		return material.GetVector and material:GetVector(key)
	end
	local function getString(key)
		return material.GetString and material:GetString(key)
	end
	local flags = getInt("$flags") or 0
	local function flag(key, mask)
		return getInt(key) == 1 or bit.band(flags, mask) ~= 0
	end
	local projection = materialProjection(material, useSecond and "$basetexturetransform2" or "$basetexturetransform")
	local params = {
		["$basetexture"] = base:GetName(),
		["$model"] = "1",
		["$nocull"] = "1",
		["$color2"] = "[1 1 1]",
		["$vertexcolor"] = "0",
		["$vertexalpha"] = "0",
		["$opaquetexture"] = "1",
	}
	for _, key in ipairs({ "$color", "$color2" }) do
		local tint = getVector(key)
		if tint then
			params[key] = vectorParam(tint)
		end
	end
	-- Newly exposed matter inherits the diffuse texture and tint. Native BSP
	-- detail and reflection layers belong to the authored surface shader.
	local cutAlbedo, cutParams = {}, {}
	for key, value in pairs(params) do
		cutAlbedo[key], cutParams[key] = value, value
	end
	cutParams["$vertexcolor"] = "1"
	local detail = material:GetTexture("$detail")
	local detailMode = getInt("$detailblendmode") or 0
	local compatibleDetail = validTexture(detail) and detailMode >= 0 and detailMode <= 2
		and getInt("$separatedetailuvs") ~= 1 and not materialProjection(material, "$detailtexturetransform")
	if compatibleDetail then
		-- Native grass (including gm_construct) uses a second diffuse
		-- detail texture even on BSP faces with only one base texture.
		params["$detail"] = detail:GetName()
		params["$detailblendmode"] = tostring(detailMode)
		for _, key in ipairs({ "$detailscale", "$detailblendfactor" }) do
			local value = getFloat(key)
			if value then params[key] = tostring(value) end
		end
	end
	local result = {
		materialName = name,
		tileU = math.max(16, (base.GetMappingWidth and base:GetMappingWidth() or base:Width()) * 0.25),
		tileV = math.max(16, (base.GetMappingHeight and base:GetMappingHeight() or base:Height()) * 0.25),
		interior = wallMaterial("native_v3", "VertexLitGeneric", name, params, projection),
		interiorCut = wallMaterial("reveal_v4", "UnlitGeneric", name, cutParams, projection),
		interiorCutLit = wallMaterial("reveal_lit_v4", "VertexLitGeneric", name, cutAlbedo, projection),
	}
	local surfaceParams = {}
	for key, value in pairs(params) do
		surfaceParams[key] = value
	end
	surfaceParams["$vertexcolor"] = "1"
	surfaceParams["$opaquetexture"] = flag("$opaquetexture", 16777216) and "1" or nil
	local alphaTest = flag("$alphatest", 256)
	local reference = alphaTest and getFloat("$alphatestreference")
	local alphaReference = reference and tostring(reference) or nil
	local alpha = getFloat("$alpha")
	local translucent = flag("$translucent", 2097152) or alpha and alpha < 1
	local selfIllum = flag("$selfillum", 64)
	if alphaTest or translucent then
		surfaceParams["$opaquetexture"] = nil
	end
	if alphaTest then
		result.alphaTest = true
		surfaceParams["$alphatest"] = "1"
		surfaceParams["$alphatestreference"] = alphaReference
	end
	local directMaterial, directCutout, directReveal
	result.directLight = function(retained)
		if not retained then
			if not directReveal then
				directReveal = wallMaterial("reveal_direct_v4", "UnlitGeneric", name, cutAlbedo, projection)
			end
			return directReveal
		end
		if alphaTest then
			if not directCutout then
				local albedo = {}
				for key, value in pairs(params) do
					albedo[key] = value
				end
				albedo["$opaquetexture"] = nil
				albedo["$alphatest"] = "1"
				albedo["$alphatestreference"] = alphaReference
				directCutout = wallMaterial("direct_cutout", "UnlitGeneric", name, albedo, projection)
			end
			return directCutout
		end
		if not directMaterial then
			directMaterial = wallMaterial("direct", "UnlitGeneric", name, params, projection)
		end
		return directMaterial
	end
	if translucent then
		surfaceParams["$translucent"] = "1"
		surfaceParams["$alpha"] = alpha and tostring(alpha) or nil
		result.translucent = true
	end
	if alphaTest and not translucent then
		local albedo = {}
		for key, value in pairs(surfaceParams) do
			albedo[key] = value
		end
		albedo["$vertexcolor"] = "0"
		result.surfaceAlbedo = wallMaterial("surface_albedo_v4", "VertexLitGeneric", name, albedo, projection)
	end

	-- Only a resolved cube and a compatible mask may be transplanted into
	-- UnlitGeneric. The dynamic and flashlight albedo has no cubemap.
	local cube = material:GetTexture("$envmap")
	local cubeName = validTexture(cube) and cube:GetName()
	local resolved = cubeName and cubeName ~= "" and cubeName:lower() ~= "env_cubemap"
	local mask = material:GetTexture("$envmapmask")
	local maskName = validTexture(mask) and mask:GetName()
	local authoredMask = getString("$envmapmask")
	local badMask = (mask or authoredMask and authoredMask ~= "") and not maskName
	local maskProjection = maskName and materialProjection(material, "$envmapmasktransform")
	local sameMaskUV = not maskName or (maskProjection and maskProjection.key) == (projection and projection.key)
	local normalMask = flag("$normalmapalphaenvmapmask", 4194304)
	local baseMask = flag("$basealphaenvmapmask", 1048576)
	local tintByAlpha = getInt("$blendtintbybasealpha") == 1
	-- A mask in base alpha must never turn a retained wall transparent
	-- merely because its cubemap is unavailable.
	if not alphaTest and not translucent and (baseMask or selfIllum or tintByAlpha) then
		surfaceParams["$opaquetexture"] = "1"
	end
	if resolved and not badMask and not normalMask and sameMaskUV
		and not (baseMask and (maskName or alphaTest or translucent or tintByAlpha))
	then
		result.nativeReflection = true
		surfaceParams["$envmap"] = cubeName
		surfaceParams["$envmapmask"] = maskName
		surfaceParams["$basealphaenvmapmask"] = baseMask and "1" or nil
		local tint = getVector("$envmaptint")
		if tint then
			surfaceParams["$envmaptint"] = vectorParam(tint)
		end
		for _, key in ipairs({ "$envmapcontrast", "$envmapsaturation" }) do
			local value = getFloat(key)
			if value then
				surfaceParams[key] = tostring(value)
			end
		end
	end
	result.surfaceCut = wallMaterial("surface_v3", "UnlitGeneric", name, surfaceParams, projection)
	if not alphaTest and not translucent and not baseMask and not normalMask and not selfIllum
		and not tintByAlpha and not validTexture(secondary)
	then
		local blend
		result.cutBlend = function()
			if not blend then
				-- Use only the diffuse shader inputs for the transition layer.
				local layer = {
					["$basetexture"] = params["$basetexture"], ["$color"] = params["$color"],
					["$color2"] = params["$color2"], ["$model"] = "1", ["$nocull"] = "1",
					["$translucent"] = "1", ["$vertexcolor"] = "1", ["$vertexalpha"] = "1",
				}
				blend = wallMaterial("cut_transition_v2", "UnlitGeneric", name, layer, projection)
			end
			return blend
		end
	end
	result.directBaked = shader == "LightmappedGeneric" and not secondary and not cube and not detail and not projection
		and not alphaTest and not translucent and not baseMask and not normalMask and not authoredMask
		and not selfIllum and not tintByAlpha and not material:GetTexture("$bumpmap")
	if translucent then
		-- Preserve the same authored reflection when no BSP lightmap is
		-- available. The engine samples the cubemap from the live view.
		local glass = {}
		for key, value in pairs(surfaceParams) do
			glass[key] = value
		end
		glass["$vertexcolor"] = "0"
		result.surfaceAlbedo = wallMaterial("surface_glass", "VertexLitGeneric", name, glass, projection)
	end

	-- The skin shader needs tangent data even for a base-alpha Phong mask.
	-- A neutral Source normal reserves the normal stream if the VMT used
	-- only base alpha. The actual flashlight supplies the specular direction.
	if getInt("$phong") == 1 and not alphaTest and not translucent and not selfIllum and not projection
		and not baseMask and not tintByAlpha and not material:GetTexture("$phongwarptexture")
		and getInt("$ssbump") ~= 1
	then
		local exponent = getFloat("$phongexponent")
		local exponentMap = material:GetTexture("$phongexponenttexture")
		local boost = getFloat("$phongboost")
		local bump = material:GetTexture("$bumpmap")
		local basePhong = getInt("$basemapalphaphongmask") == 1
		local bumpName = validTexture(bump) and bump:GetName() or (not bump and basePhong and "dev/flat_normal")
		if not bumpName or not exponent or exponent <= 0 or not boost or boost <= 0
			or materialProjection(material, "$bumptransform")
			or (exponentMap and not validTexture(exponentMap))
		then
			return result
		end
		local phong = {}
		for key, value in pairs(params) do
			phong[key] = value
		end
		phong["$opaquetexture"] = nil
		phong["$phong"] = "1"
		phong["$basemapalphaphongmask"] = basePhong and "1" or nil
		phong["$bumpmap"] = bumpName
		-- Retain the color stream for the main pass. Vertex alpha is 255
		-- throughout; the flashlight material ignores static vertex RGB.
		phong["$vertexalpha"] = "1"
		phong["$phongexponent"] = tostring(exponent)
		phong["$phongboost"] = tostring(math.min(boost * 0.25, 0.25))
		if exponentMap then
			phong["$phongexponenttexture"] = exponentMap:GetName()
			local factor = getFloat("$phongexponentfactor")
			if factor then
				phong["$phongexponentfactor"] = tostring(factor)
			end
		end
		for _, key in ipairs({ "$phongtint", "$phongfresnelranges" }) do
			local value = getVector(key)
			if value then
				phong[key] = vectorParam(value)
			end
		end
		for _, key in ipairs({ "$phongalbedotint", "$invertphongmask" }) do
			local value = getInt(key)
			if value then
				phong[key] = tostring(value)
			end
		end
		result.adjacentFlash = wallMaterial("phong_v3", "VertexLitGeneric", name, phong)
	end
	return result
end

local function recoverMaterial(source, r, findFace)
	-- Image capture also works on displacements, whose HitTexture is a marker.
	-- Ordinary BSP materials additionally supply an unstretched wall texture.
	local n = source.frame.normal
	local face = source.nativeFace or (findFace and V.BSPFaceAt and r.bsp and V.BSPFaceAt(r, source.point, source.planeNormal or n))
	local texture = face and face.tex and r.bsp and r.bsp.textures and r.bsp.textures[face.tex.texture]
	if texture and bit.band(face.tex.flags or 0, 134) ~= 0 then
		return
	end
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
	if findFace and not texture and tr.HitWorld and tr.Hit
		and (tr.HitNormal:Dot(n) < 0.5 or math.abs((tr.HitPos - source.point):Dot(n)) > r.step)
	then
		-- A texture probe from an unproven capture must not jump to a
		-- facing wall or a second floor farther along the trace.
		return
	end
	if tr.HitWorld and tr.Hit and not tr.StartSolid and not tr.HitSky then
		source.lightOrigin = tr.HitPos + tr.HitNormal * (r.step * 0.5 + 4)
		source.planeNormal = source.planeNormal or tr.HitNormal
	end
	local name = type(tr.HitTexture) == "string" and tr.HitTexture:gsub("\\", "/"):lower()
	if
		not tr.HitWorld
		or not tr.Hit
		or tr.StartSolid
		or tr.HitSky
		or tr.HitNoDraw
		or not name
		or name == ""
		or name:sub(1, 1) == "*"
		or name:sub(1, 6) == "tools/"
	then
		return
	end
	local materials = r.surfaceMaterials
	local secondLayer = texture and face.dispAlphaMin == 255
	local key = secondLayer and (name .. "#2") or name
	if materials[key] == nil then
		materials[key] = readMaterial(name, secondLayer) or false
	end
	local definition = materials[key]
	if not definition then
		return
	end
	for key, value in pairs(definition) do
		source[key] = value
	end
	if texture then
		source.nativeFace = face
		source.tex = face.tex
		source.textureSize = texture
		source.tileU = texture.w / math.max(0.000001, face.tex.u:Length())
		source.tileV = texture.h / math.max(0.000001, face.tex.v:Length())
		source.textureNormal = face.tex.u:Cross(face.tex.v):GetNormalized()
	end
end

local function solid(point)
	return util.PointContents and bit.band(util.PointContents(point), CONTENTS_SOLID) ~= 0
end

local function traceWorld(start, finish)
	return util.TraceLine({
		start = start,
		endpos = finish,
		mask = MASK_SOLID_BRUSHONLY,
		filter = function(ent)
			return ent:IsWorld()
		end,
	})
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
		local tr = traceWorld(anchor, origin)
		-- Also reject a free camera on the far side of a ceiling/wall.
		if tr.StartSolid or tr.AllSolid or (tr.Hit and tr.Fraction and tr.Fraction < 0.9999) then
			return false
		end
		-- A clear anchor does not prove the edges of the same face are
		-- visible. Check actual triangle samples, not empty box corners.
		for _, sample in ipairs(source.captureChecks or {}) do
			tr = traceWorld(origin, sample)
			if tr.StartSolid or tr.AllSolid
				or (tr.Hit and tr.Fraction and (1 - tr.Fraction) ^ 2 * origin:DistToSqr(sample) > source.captureTolerance2)
			then
				return false
			end
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

local function windingEdges(face)
	local vertices = face.vertices
	if face.displacement or not vertices or #vertices < 3 then
		return
	end
	local center = Vector()
	for _, p in ipairs(vertices) do
		center = center + p
	end
	center = center / #vertices
	local result = {}
	for i, p in ipairs(vertices) do
		local direction = vertices[i % #vertices + 1] - p
		local length = direction:LengthSqr()
		if length > 0.000001 then
			local inward = direction:Cross(face.normal)
			if inward:Dot(center - p) < 0 then
				inward = -inward
			end
			result[#result + 1] = {
				x = p.x, y = p.y, z = p.z,
				dx = direction.x, dy = direction.y, dz = direction.z, inverseLength = 1 / length,
				nx = inward.x, ny = inward.y, nz = inward.z, distance = inward:Dot(p),
			}
		end
	end
	return result
end

local captureAxes = { "x", "y", "z" }
local function extendCaptureBounds(box, a, b, c, offset, center)
	for axisIndex, axis in ipairs(captureAxes) do
		local av, bv, cv = a[axis], b[axis], c[axis]
		local lo, hi = math.min(av, bv, cv), math.max(av, bv, cv)
		local shift = offset[axis]
		if lo + shift < box.low[axis] then
			box.low[axis] = lo + shift
			box.extremes[axisIndex] = { lo == av and a or lo == bv and b or c, center }
		end
		if hi + shift > box.high[axis] then
			box.high[axis] = hi + shift
			box.extremes[axisIndex + 3] = { hi == av and a or hi == bv and b or c, center }
		end
	end
end

local function registerSources(r, item, vertices, checkpoint)
	local scores, points, normals, bounds, anchors, orientations, faces, first = {}, {}, {}, {}, {}, {}, {}, {}
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
		first[index] = first[index] or i
		orientations[index] = orientation
		faces[index] = face
		scores[index] = (scores[index] or 0) + area
		points[index] = (points[index] or Vector()) + center * area
		normals[index] = (normals[index] or Vector()) + cross * -1
		if not anchors[index] or area > anchors[index].area then
			anchors[index] = { area = area, point = center, normal = cross:GetNormalized() * -1 }
		end
		local box = bounds[index]
		if not box then
			box = { low = Vector(math.huge, math.huge, math.huge), high = Vector(-math.huge, -math.huge, -math.huge) }
			if face and util.PointContents then
				box.extremes = {}
			end
			bounds[index] = box
		end
		if box.extremes then
			extendCaptureBounds(box, a, b, c, offset, center)
		else
			local low, high = box.low, box.high
			low.x = math.min(low.x, math.min(a.x, b.x, c.x) + offset.x)
			low.y = math.min(low.y, math.min(a.y, b.y, c.y) + offset.y)
			low.z = math.min(low.z, math.min(a.z, b.z, c.z) + offset.z)
			high.x = math.max(high.x, math.max(a.x, b.x, c.x) + offset.x)
			high.y = math.max(high.y, math.max(a.y, b.y, c.y) + offset.y)
			high.z = math.max(high.z, math.max(a.z, b.z, c.z) + offset.z)
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
		return a.score > b.score or (a.score == b.score and first[a.index] < first[b.index])
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
		if bounds[index].extremes then
			local checks, seen = {}, {}
			for _, entry in ipairs(bounds[index].extremes) do
				local vertex, triangleCenter = entry[1], entry[2]
				if not seen[vertex] then
					seen[vertex] = true
					local point = vertex + offset
					-- Inset along the triangle so an edge shared with another
					-- face cannot be rejected on a floating-point tie.
					checks[#checks + 1] = point + (triangleCenter - point) * 0.05
				end
			end
			source.captureChecks = checks
			source.captureTolerance2 = math.max(0.25, math.min(2, r.step * 0.05)) ^ 2
			bounds[index].extremes = nil
		end
		recoverMaterial(source, r, false)
		local lightmap = source.directBaked and V.SurfaceLightmap
		-- Ground shadows need texel detail, especially along walls. Prefer
		-- the engine capture there; blocked or exhausted captures fall back
		-- to the original BSP luxels.
		if lightmap and source.planeNormal.z < 0.65 and source.nativeFace and not source.nativeFace.displacement then
			source.preferLightmap = V.SurfaceLightmap(r, source, anchor.point) ~= nil
			for _, check in ipairs(source.captureChecks or {}) do
				if not V.SurfaceLightmap(r, source, check) then
					source.preferLightmap = false
					break
				end
			end
		end
		local planned = not source.preferLightmap and not source.translucent
			and planCapture(source, bounds[index], anchor.point, anchor.normal)
		if not source.nativeFace then
			local box = bounds[index]
			local low, high = box.low - source.center, box.high - source.center
			local u0, u1 = low:Dot(source.frame.right), high:Dot(source.frame.right)
			local v0, v1 = low:Dot(source.frame.up), high:Dot(source.frame.up)
			source.sampleLowU, source.sampleHighU = math.min(u0, u1), math.max(u0, u1)
			source.sampleLowV, source.sampleHighV = math.min(v0, v1), math.max(v0, v1)
		end
		local slot, slotIndex
		if planned then
			slot, slotIndex = acquire(source, r.surfaceHDR)
		end
		local uncaptured = not slot
		source.slot = slot or { material = V.ScanSurfaceMaterial, litMaterial = V.ScanSurfaceMaterial }
		source.slotIndex = slotIndex or 0
		source.ready = uncaptured
		source.failed = uncaptured and not source.translucent and not source.preferLightmap
		source.uncaptured = uncaptured
		source.fallbackReason = not source.translucent and not source.preferLightmap
			and (not planned and "camera BSP obstruee" or uncaptured and "budget de captures" or nil) or nil
		sources[#sources + 1] = source
		r.surfaceList[#r.surfaceList + 1] = source
		if source.nativeFace then
			sources[source.nativeFace] = source
			local byFace = r.surfaceByFace
			local patches = byFace[source.nativeFace] or {}
			source.winding = patches[1] and patches[1].winding or windingEdges(source.nativeFace)
			patches[#patches + 1] = source
			byFace[source.nativeFace] = patches
		end
		if uncaptured then
			source.captureChecks = nil
			r.surfaceFinished = r.surfaceFinished + 1
			if source.failed then r.surfaceFailed = r.surfaceFailed + 1 end
		else
			queue[#queue + 1] = { region = r, source = source }
		end
		if checkpoint then
			checkpoint()
		end
	end
	r.surfaceSources[item.key] = sources
	return sources
end

local function axisGap(lo, hi, otherLo, otherHi)
	return math.max(lo - otherHi, 0, otherLo - hi)
end

local function patchDistance(source, point, limit)
	local x, y, z = point.x, point.y, point.z
	local bounds, n, p = source.lightBounds, source.planeNormal, source.point
	local low, high = bounds.low, bounds.high
	local dx = math.max(low.x - x, 0, x - high.x)
	local dy = math.max(low.y - y, 0, y - high.y)
	local dz = math.max(low.z - z, 0, z - high.z)
	local plane = (x - p.x) * n.x + (y - p.y) * n.y + (z - p.z) * n.z
	local box = math.max(dx * dx + dy * dy + dz * dz, plane * plane)
	if source.winding and (not limit or box <= limit * limit) then
		-- Adjacent triangular BSP patches can have overlapping boxes. Use
		-- their winding as well so the first registered texture cannot win
		-- across the other side of a diagonal material boundary.
		local closest = math.huge
		for _, edge in ipairs(source.winding) do
			if edge.nx * x + edge.ny * y + edge.nz * z < edge.distance - 0.00001 then
				local ex, ey, ez = x - edge.x, y - edge.y, z - edge.z
				local t = math.Clamp((ex * edge.dx + ey * edge.dy + ez * edge.dz) * edge.inverseLength, 0, 1)
				ex, ey, ez = ex - edge.dx * t, ey - edge.dy * t, ez - edge.dz * t
				closest = math.min(closest, ex * ex + ey * ey + ez * ez)
			end
		end
		if closest < math.huge then
			box = math.max(box, closest)
		end
	end
	return math.sqrt(box)
end

local function nearbySources(r, item, offset, reach, checkpoint)
	local cache = r.surfaceNeighbors or {}
	r.surfaceNeighbors = cache
	local result = cache[item.key]
	if result then
		return result
	end
	result = { cells = {} }
	local width = r.step * 8
	for index, source in ipairs(r.surfaceList) do
		local bounds = source.lightBounds
		local dx = axisGap(bounds.low.x, bounds.high.x, offset.x, offset.x + width)
		local dy = axisGap(bounds.low.y, bounds.high.y, offset.y, offset.y + width)
		local dz = axisGap(bounds.low.z, bounds.high.z, offset.z, offset.z + width)
		if dx * dx + dy * dy + dz * dz <= reach * reach then
			result[#result + 1] = source
		end
		if checkpoint and index % 48 == 0 then
			checkpoint()
		end
	end
	cache[item.key] = result
	return result
end

local function cellSources(r, list, cell, reach)
	if type(cell) ~= "number" or #list < 2 then
		return list
	end
	local cached = list.cells[cell]
	if cached then
		return cached
	end
	local i = cell - 1
	local sx, sy = (r.nx or 32) + 1, (r.ny or 32) + 1
	local p = r.origin + Vector(i % sx + 0.5, math.floor(i / sx) % sy + 0.5, math.floor(i / (sx * sy)) + 0.5) * r.step
	local radius = r.step * 0.867
	local limit = reach + radius
	local distances = {}
	local best = math.huge
	for j, source in ipairs(list) do
		local d = patchDistance(source, p, limit)
		distances[j] = d
		best = math.min(best, d)
	end
	if best + radius <= reach then
		-- Distance to a patch changes by at most the distance moved.
		-- Keep every patch that can win anywhere in the cell, including
		-- the maximum possible change in the orientation term.
		limit = math.min(limit, best + 2 * radius + r.step * 0.5)
	end
	cached = {}
	for j, source in ipairs(list) do
		if distances[j] <= limit then
			cached[#cached + 1] = source
		end
	end
	list.cells[cell] = cached
	return cached
end

local function nearestSource(point, normal, list, reach, step, skip)
	local best, score, nextScore = nil, math.huge, math.huge
	local x, y, z = normal.x, normal.y, normal.z
	local angleWeight = step * 0.25
	for _, source in ipairs(list) do
		if not skip or source ~= skip and source.interior then
			local distance = patchDistance(source, point, math.min(nextScore, reach))
			-- A small orientation penalty breaks nearby ties. It cannot
			-- make a distant parallel wall win over an adjacent cross-cut.
			local n = source.planeNormal
			local adjusted = distance + (1 - x * n.x - y * n.y - z * n.z) * angleWeight
			if distance <= reach and adjusted < score then
				best, score, nextScore = source, adjusted, math.min(score, nextScore)
			elseif adjusted < nextScore then
				nextScore = adjusted
			end
		end
	end
	-- Include the reach limit in the margin, so a triangle spanning the
	-- edge of the bounded lookup still samples its vertices.
	return best, best and math.min(nextScore - score, reach - score) or 0
end

local function materialAt(r, source, point)
	if source.nativeFace then
		return source
	end
	-- A capture can contain grass next to concrete. Recover the original
	-- material at cell resolution, rather than painting the whole cut with
	-- the one material found at the middle of its chunk.
	local q = point - source.center
	local u = math.Clamp(q:Dot(source.frame.right), source.sampleLowU, source.sampleHighU)
	local v = math.Clamp(q:Dot(source.frame.up), source.sampleLowV, source.sampleHighV)
	local x = math.max(0, math.min(15, math.floor(8 + u / source.span * 16)))
	local y = math.max(0, math.min(15, math.floor(8 + v / source.span * 16)))
	local key = x + y * 16
	if not source.materialCells[key] then
		local sampleU = math.Clamp(((x + 0.5) / 16 - 0.5) * source.span, source.sampleLowU, source.sampleHighU)
		local sampleV = math.Clamp(((y + 0.5) / 16 - 0.5) * source.span, source.sampleLowV, source.sampleHighV)
		local p = source.center + source.frame.right * sampleU + source.frame.up * sampleV
		local sample = {
			frame = source.frame,
			point = p,
			span = source.span,
			center = source.center,
			slotIndex = source.slotIndex,
		}
		recoverMaterial(sample, r, true)
		source.materialCells[key] = sample
	end
	return source.materialCells[key]
end

local function foldedTexture(source, projection)
	local tex = source.tex
	local direction = source.textureNormal
	-- Both signs of a world axis use the same UV basis, including on
	-- opposite sides of a crater. Keep compiled UVs on the dominant axis.
	projection = projection - (projection - 1) % 2
	local nativeProjection = frameFor(direction)
	nativeProjection = nativeProjection - (nativeProjection - 1) % 2
	if projection == nativeProjection then
		return tex
	end
	local folds = source.textureFolds
	if not folds then
		folds = {}
		source.textureFolds = folds
	end
	if not folds[projection] then
		local target = frames[projection].normal
		local cosine = direction:Dot(target)
		if cosine < 0 then
			target, cosine = -target, -cosine
		end
		local axis = direction:Cross(target)
		local function rotate(vector)
			local crossed = axis:Cross(vector)
			return vector + crossed + axis:Cross(crossed) / (1 + cosine)
		end
		local u, v = rotate(tex.u), rotate(tex.v)
		local face = source.nativeFace
		local point = face.vertices and face.vertices[1] or source.point
		local anchor = direction * point:Dot(direction)
		folds[projection] = { u = u, v = v, uo = tex.uo + anchor:Dot(tex.u - u), vo = tex.vo + anchor:Dot(tex.v - v) }
	end
	return folds[projection]
end

local function tiledUV(source, world, frame, tex)
	if tex then
		local size = source.textureSize
		return (world:Dot(tex.u) + tex.uo) / size.w, (world:Dot(tex.v) + tex.vo) / size.h
	end
	return world:Dot(frame.right) / (source.tileU or source.span), -world:Dot(frame.up) / (source.tileV or source.span)
end

function V.SurfaceUV(source, world, normal, original, retained)
	if original then
		local frame = source.frame
		local q = world - source.center
		-- Exact projection of the frozen square camera, including its FOV
		-- and depth, keeps sloped original surfaces aligned between captures.
		local depth = (source.cameraDistance or source.span / 2 + 4) - q:Dot(frame.normal)
		if depth <= 1 then
			return -1, -1
		end
		local scale = 2 * depth * (source.cameraTangent or 1)
		return 0.5 + q:Dot(frame.right) / scale, 0.5 - q:Dot(frame.up) / scale
	end
	-- Keep compiled UVs on parallel faces. An absolute world frame gives
	-- cross-sections two nonzero UV axes and keeps neighboring cells in phase.
	local projection, wall = frameFor(normal)
	local tex = source.tex and (retained and source.tex or foldedTexture(source, projection))
	return tiledUV(source, world, wall, tex)
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
		local u, v = V.SurfaceUV(source, world, vertex.normal, false, true)
		fallback[i] = { pos = vertex.pos, normal = vertex.normal, u = u, v = v, cutLight = light }
		if checkpoint and i % 48 == 0 then
			checkpoint()
		end
	end
	return V.EncodeCutLighting(fallback, checkpoint)
end

local function partId(part)
	local id = surfacePartIds[part]
	if not id then
		nextSurfacePartId = nextSurfacePartId + 1
		id = nextSurfacePartId
		surfacePartIds[part] = id
	end
	return id
end

local function mergeSurfacePart(group, source)
	if not group then
		group = {}
		for key, value in pairs(source) do
			group[key] = value
		end
		group.vertices = {}
	else
		group.px = group.px + source.px
		group.py = group.py + source.py
		group.pz = group.pz + source.pz
		group.nx = group.nx + source.nx
		group.ny = group.ny + source.ny
		group.nz = group.nz + source.nz
		group.weight = group.weight + source.weight
	end
	local count = #group.vertices
	for i, vertex in ipairs(source.vertices) do
		group.vertices[count + i] = vertex
	end
	return group
end

local function reuseSurfaceBatch(previous, partCount, checkpoint)
	if #previous.partIds ~= partCount or (previous.flashMesh and not previous.flashMesh:IsValid()) then
		return
	end
	local object = V.RetainMesh(previous.mesh)
	if not object then
		return
	end
	if checkpoint then
		checkpoint(object)
	end
	if previous.flashMesh then
		V.RetainMesh(previous.flashMesh)
		if checkpoint then checkpoint(previous.flashMesh) end
	end
	-- The native triangle stream is shared, while the new chunk keeps
	-- independent lighting and ownership metadata.
	local result = {}
	for key, value in pairs(previous) do
		if key ~= "lighting" and key ~= "staticLight" and key ~= "movingLight" then
			result[key] = value
		end
	end
	return result
end

function V.BuildSurfaceBatches(r, item, vertices, checkpoint, previousBatches)
	if #vertices == 0 then
		return {}
	end
	local own = r.surfaceSources[item.key]
	if not own and not r.surfaceFrozen then
		own = registerSources(r, item, vertices, checkpoint)
	end
	local offset = r.origin + Vector(item.x, item.y, item.z) * (r.step * 8)
	local reach = r.step * 4
	local candidates
	local currentCell
	local refinedCuts = 0
	local cellCandidates
	local worldByPosition = {}
	local cutByPosition = {}
	local function worldPoint(vertex)
		local pos = vertex.pos
		local world = worldByPosition[pos]
		if not world then
			world = pos + offset
			worldByPosition[pos] = world
		end
		return world
	end
	local function cutVertex(vertex, world)
		local cached = cutByPosition[vertex.pos]
		if cached and cached.normal == vertex.normal then
			return cached.light
		end
		local light = V.CutVertexLighting(r, world or worldPoint(vertex), vertex.normal, checkpoint)
		cutByPosition[vertex.pos] = { normal = vertex.normal, light = light }
		return light
	end
	local function neighbors()
		if not candidates then
			candidates = nearbySources(r, item, offset, reach, checkpoint)
		end
		return candidates
	end
	local function closest(point, normal, skip)
		if not skip and not cellCandidates then
			cellCandidates = cellSources(r, neighbors(), currentCell, reach)
		end
		return nearestSource(point, normal, skip and neighbors() or cellCandidates, reach, r.step, skip)
	end
	local function appearanceAt(source, point, normal)
		if not source then
			return nil, nil
		end
		local sample = materialAt(r, source, point)
		if sample.interior then
			return sample, source
		end
		if source.interior then
			return source, source
		end
		local other = closest(point, normal, source)
		if other then
			sample = materialAt(r, other, point)
			return sample.interior and sample or other, other
		end
		return nil, nil
	end
	local groups = {}
	local targetGroups = groups
	local captureUV = {}
	local cells = V.TerrainCellCache(r, "surfaceCells", item.x * 8, item.y * 8, item.z * 8)
	local epoch = r.surfaceEpoch or 0
	local recordParts = V.RetainMesh and vertices[1].cell ~= nil
	local previousByKey = {}
	if recordParts and r.surfaceFrozen then
		for _, batch in ipairs(previousBatches or {}) do
			if batch.surfaceEpoch == epoch and batch.partIds and (not batch.source or batch.source.ready) then
				previousByKey[batch.surfaceKey] = batch
			end
		end
	end
	local function triangleCenter(a, b, c)
		local p, q, s = a.pos, b.pos, c.pos
		return Vector(
			offset.x + (p.x + q.x + s.x) / 3,
			offset.y + (p.y + q.y + s.y) / 3,
			offset.z + (p.z + q.z + s.z) / 3
		)
	end
	local function flatten(parts)
		local group
		for i, source in ipairs(parts) do
			group = mergeSurfacePart(group, source)
			if checkpoint and i % 16 == 0 then
				checkpoint()
			end
		end
		return group
	end
	local function prefixIds(previous, count)
		local ids = {}
		for i = 1, count do
			ids[i] = previous.partIds[i]
		end
		return ids
	end
	local function merge(other)
		for key, source in pairs(other) do
			local id = recordParts and partId(source)
			local group, previous = groups[key], previousByKey[key]
			local count = previous and group and #group.parts or 0
			if previous and previous.partIds[count + 1] == id then
				if not group then
					group = { parts = {} }
					groups[key] = group
				end
				group.parts[count + 1] = source
			else
				if previous then
					previousByKey[key] = nil
					if group then
						group = flatten(group.parts)
						group.partIds = prefixIds(previous, count)
					end
				end
				group = mergeSurfacePart(group, source)
				groups[key] = group
				if id then
					local ids = group.partIds or {}
					ids[#ids + 1] = id
					group.partIds = ids
				end
			end
		end
	end
	local function append(a, b, c, center, weight, source, normal, bakedUV, appearance, surfaceLight, adjacent, retained, nativeCut, blendAlpha)
		local original = bakedUV ~= nil
		local freshCut = not retained and not original
		local material = original and source.slot.litMaterial
			or appearance and (freshCut and appearance.interiorCutLit or appearance.surfaceAlbedo or appearance.interior)
			or (freshCut and dirtFlash or V.ScanSurfaceMaterial)
		local flashMaterial = original and source.slot.material or material
		local cutLighting = surfaceLight
			or (not retained and not original and r.cutLighting ~= nil and r.cutLighting.sourceCount > 0 and V.CutVertexLighting ~= nil)
		if cutLighting then
			material = appearance
					and (surfaceLight and appearance.surfaceCut or appearance.interiorCut)
				or (freshCut and dirtFallback or cutFallback)
		end
		if blendAlpha then material = appearance.cutBlend() end
		local projection, frame
		if not original then
			projection, frame = frameFor(normal)
		end
		local key = source
				and (original and (source.slotIndex .. ":surface") or ("wall:" .. source.identity .. ":" .. projection .. ":" .. (appearance and appearance.materialName or "plain")))
			or "plain"
		if blendAlpha then
			key = key .. ":blend"
		elseif cutLighting then
			key = key .. (surfaceLight and ":lightmap" or adjacent and ":adjacent" or ":gradient")
		elseif retained and not original then
			key = key .. ":retained"
		end
		if not targetGroups[key] then
			targetGroups[key] = {
				material = material,
				vertices = {},
				source = source,
				baked = original,
				retained = retained,
				translucent = blendAlpha ~= nil or (retained and appearance and appearance.translucent) or nil,
				blendOverlay = blendAlpha ~= nil,
				flashMaterial = flashMaterial,
				directLight = appearance and appearance.directLight,
				phongFlash = cutLighting and adjacent and appearance.adjacentFlash or nil,
				phongTex = cutLighting and adjacent and appearance.tex or nil,
				cutLighting = cutLighting,
				surfaceLight = surfaceLight ~= nil,
				freshCut = freshCut,
				lightOrigin = appearance and appearance.lightOrigin or source and source.lightOrigin,
				px = 0, py = 0, pz = 0,
				nx = 0, ny = 0, nz = 0,
				weight = 0,
			}
		end
		local group = targetGroups[key]
		group.px = group.px + center.x * weight
		group.py = group.py + center.y * weight
		group.pz = group.pz + center.z * weight
		group.nx = group.nx + normal.x * weight
		group.ny = group.ny + normal.y * weight
		group.nz = group.nz + normal.z * weight
		group.weight = group.weight + weight
		local tex = not original and appearance and appearance.tex
			and ((retained or nativeCut) and appearance.tex or foldedTexture(appearance, projection))
		local count = #group.vertices
		-- Separate just the color layer from the opaque surface. UVs and
		-- lighting continue to use the exact unshifted position.
		local lift = blendAlpha and normal * math.min(r.step / 1024, 0.025)
		for index = 1, 3 do
			local old = index == 1 and a or index == 2 and b or c
			local u, v = old.u, old.v
			local world
			if bakedUV then
				u, v = bakedUV[index * 2 - 1], bakedUV[index * 2]
			elseif appearance then
				world = worldPoint(old)
				u, v = tiledUV(appearance, world, frame, tex)
			elseif freshCut then
				world = worldPoint(old)
				u, v = world:Dot(frame.right) / 128, -world:Dot(frame.up) / 128
			end
			group.vertices[count + index] = {
				pos = lift and old.pos + lift or old.pos,
				normal = old.normal,
				u = u,
				v = v,
				color = blendAlpha and Color(255, 255, 255, blendAlpha[index]) or color_white,
				cutLight = surfaceLight and surfaceLight[index]
					or cutLighting and cutVertex(old, world)
					or nil,
			}
		end
	end
	local blendWidth = math.min(r.step * 0.6, 12)
	local transitionDistances = {}
	local function patchScore(patch, point, normal, sharedVertex)
		local distance
		if sharedVertex then
			local distances = transitionDistances[patch]
			if not distances then distances = {} transitionDistances[patch] = distances end
			distance = distances[point]
			if distance == nil then
				distance = patchDistance(patch, point, reach)
				distances[point] = distance
			end
		else
			distance = patchDistance(patch, point, reach)
		end
		return distance + (1 - normal:Dot(patch.planeNormal)) * r.step * 0.25
	end
	local function cutTransition(a, b, c, center, normal, patch, margin)
		if not currentCell or not patch or not patch.cutBlend or not patch.nativeFace then return end
		local extent = math.sqrt(math.max(a.pos:DistToSqr(b.pos), b.pos:DistToSqr(c.pos), c.pos:DistToSqr(a.pos)))
		if margin > blendWidth + 2 * extent then return end
		cellCandidates = cellCandidates or cellSources(r, neighbors(), currentCell, reach)
		local other, score = nil, math.min(reach, patchScore(patch, center, normal) + blendWidth + 2 * extent)
		for _, candidate in ipairs(cellCandidates) do
			if candidate.cutBlend and candidate.nativeFace and candidate.materialName ~= patch.materialName then
				local d = patchScore(candidate, center, normal)
				if d < score then other, score = candidate, d end
			end
		end
		if not other then return end
		-- Choose the same layer order on both sides of a material boundary.
		local base, overlay = patch, other
		if overlay.materialName < base.materialName then base, overlay = overlay, base end
		local alpha, low, high = {}, 255, 0
		for i, vertex in ipairs({a, b, c}) do
			local p, n = worldPoint(vertex), vertex.normal
			local d = patchScore(base, p, n, true) - patchScore(overlay, p, n, true)
			local t = math.Clamp(0.5 + d / (2 * blendWidth), 0, 1)
			local opacity = math.floor(t * t * (3 - 2 * t) * 255 + 0.5)
			alpha[i], low, high = opacity, math.min(low, opacity), math.max(high, opacity)
		end
		if high == 0 or low == 255 then return end
		return base, overlay, alpha
	end

	local function splitCut(a, b, c, normal, depth, source, margin, center, weight)
		center = center or triangleCenter(a, b, c)
		if margin == nil then
			source, margin = closest(center, normal)
		end
		local appearance, patch = appearanceAt(source, center, normal)
		if appearance == patch then
			local base, overlay, alpha = cutTransition(a, b, c, center, normal, patch, margin)
			if base then
				weight = weight or math.sqrt((b.pos - a.pos):Cross(c.pos - a.pos):LengthSqr())
				append(a, b, c, center, weight, base, normal, nil, base)
				append(a, b, c, center, weight, overlay, normal, nil, overlay, nil, nil, nil, nil, alpha)
				return
			end
		end
		local ab, bc, ca
		local different = false
		-- The normal chunk path already clips geometry to a voxel cell.
		-- Native materials use that triangle's exact centroid. Retain the
		-- older subdivision for mixed traced captures and larger input.
		local sampleBoundary = not currentCell or (source and not source.nativeFace)
		if sampleBoundary and depth < 3 then
			ab, bc, ca = a.pos:DistToSqr(b.pos), b.pos:DistToSqr(c.pos), c.pos:DistToSqr(a.pos)
		end
		if ab and math.max(ab, bc, ca) > (r.step * 0.125) ^ 2 then
			-- Each patch distance varies by at most the point displacement.
			-- A proven winner for this whole triangle needs no corner queries.
			local fixed = source and margin > 2 * math.sqrt(math.max(ab, bc, ca))
			if not (fixed and patch == source and source.nativeFace) then
				for _, vertex in ipairs({ a, b, c }) do
					local world = worldPoint(vertex)
					local candidate = fixed and source or closest(world, normal)
					local sample = appearanceAt(candidate, world, normal)
					if (sample and sample.materialName) ~= (appearance and appearance.materialName) then
						different = true
						break
					end
				end
			end
		end
		if different then
			local first, second = a, b
			if bc >= ab and bc >= ca then
				first, second = b, c
			elseif ca >= ab and ca >= bc then
				first, second = c, a
			end
			local middle =
				{ pos = (first.pos + second.pos) / 2, normal = (first.normal + second.normal):GetNormalized() }
			if first == a then
				splitCut(a, middle, c, normal, depth + 1)
				splitCut(middle, b, c, normal, depth + 1)
			elseif first == b then
				splitCut(a, b, middle, normal, depth + 1)
				splitCut(a, middle, c, normal, depth + 1)
			else
				splitCut(a, b, middle, normal, depth + 1)
				splitCut(middle, b, c, normal, depth + 1)
			end
		else
			-- A shallow, parallel dent keeps the actual BSP texture
			-- coordinates, including on matte surfaces.
			local nativeCut = appearance and patch == appearance and patch.nativeFace and appearance.tex
				and normal:Dot(patch.planeNormal) > 0.95
			if nativeCut then
				local limit = math.min(r.step * 0.3, 6)
				nativeCut = patchDistance(patch, worldPoint(a), limit) <= limit
					and patchDistance(patch, worldPoint(b), limit) <= limit
					and patchDistance(patch, worldPoint(c), limit) <= limit
			end
			local adjacent = nativeCut and appearance.adjacentFlash ~= nil
			weight = weight or math.sqrt((b.pos - a.pos):Cross(c.pos - a.pos):LengthSqr())
			if a.fineCut and refinedCuts < 2 and weight > math.max(8, r.step * r.step * 0.045)
				and (a.normal:Dot(b.normal) < 0.98 or b.normal:Dot(c.normal) < 0.98 or c.normal:Dot(a.normal) < 0.98)
			then
				-- A centroid split adds a lighting sample to the curved
				-- cut while preserving every edge shared with other cells.
				refinedCuts = refinedCuts + 1
				local middle = { pos = (a.pos + b.pos + c.pos) / 3,
					normal = (a.normal + b.normal + c.normal):GetNormalized() }
				local part = weight / 3
				append(a, b, middle, triangleCenter(a, b, middle), part, patch, normal, nil, appearance, nil, adjacent, nil, nativeCut)
				append(b, c, middle, triangleCenter(b, c, middle), part, patch, normal, nil, appearance, nil, adjacent, nil, nativeCut)
				append(c, a, middle, triangleCenter(c, a, middle), part, patch, normal, nil, appearance, nil, adjacent, nil, nativeCut)
			else
				append(a, b, c, center, weight, patch, normal, nil, appearance, nil, adjacent, nil, nativeCut)
			end
		end
	end
	local function triangle(i)
		local a, b, c = vertices[i], vertices[i + 1], vertices[i + 2]
		local center = triangleCenter(a, b, c)
		local cross = (b.pos - a.pos):Cross(c.pos - a.pos)
		local normal = type(a.cell) == "number" and a.nativeFace and a.normal == b.normal and a.normal == c.normal
			and a.normal or cross:GetNormalized() * -1
		local weight = math.sqrt(cross:LengthSqr())
		local face = a.nativeFace or a.surfaceFace
		local scanSource = r.surfaceFrozen and not a.freshCut and a.scanSource and r.surfaceList[a.scanSource]
		local source = scanSource or (face and own and own[face])
		local margin
		if not source and face and r.surfaceByFace[face] then
			source = nearestSource(center, normal, r.surfaceByFace[face], math.huge, r.step)
		end
		if not source then
			if r.surfaceFrozen then
				source, margin = closest(center, normal)
			else
				source = nearestSource(center, normal, own or r.surfaceList, math.huge, r.step)
			end
		end
		-- Native provenance survives clipping around a hole, including
		-- displacements. No geometric lookup is needed for a proven face.
		-- An unchanged sampled triangle may sit away from its patch plane.
		-- Its original render cell retains the source chosen before any edit.
		if not r.surfaceFrozen and not face and type(a.cell) == "number" then
			a.scanSource = source and source.identity
		end
		local proven = not a.freshCut and (scanSource or (source and face and face == source.nativeFace))
		local onSurface = proven or not a.freshCut and source and normal:Dot(source.planeNormal) > 0.9
		if onSurface and not proven then
			for j = i, i + 2 do
				if patchDistance(source, worldPoint(vertices[j]), r.step * 0.1) > r.step * 0.1 then
					onSurface = false
					break
				end
			end
		end
		if onSurface and r.surfaceFrozen and not face and source.nativeFace and V.BSPFaceAt and r.bspFaceBins then
			onSurface = V.BSPFaceAt(r, center, normal, r.step * 0.1) == source.nativeFace
		end
		-- The first mesh is entirely original terrain, including sampled
		-- displacement vertices a few units away from their source plane.
		-- Do not misclassify those vertices as freshly exposed underground soil.
		local original = source and (onSurface or not r.surfaceFrozen)
			and not source.failed and not source.translucent and not source.preferLightmap
		local bakedUV
		if original then
			bakedUV = captureUV
			for j = i, i + 2 do
				local u, v = V.SurfaceUV(source, worldPoint(vertices[j]), normal, true)
				if u < -0.0001 or u > 1.0001 or v < -0.0001 or v > 1.0001 then
					original = false
					bakedUV = nil
					break
				end
				local k = (j - i) * 2
				bakedUV[k + 1], bakedUV[k + 2] = u, v
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
			local lightA = V.SurfaceLightmap(r, source, worldPoint(a))
			local lightB = V.SurfaceLightmap(r, source, worldPoint(b))
			local lightC = V.SurfaceLightmap(r, source, worldPoint(c))
			if lightA and lightB and lightC then
				-- When the camera cannot supply a usable capture, use the
				-- native texture and the compiled light at this exact face.
				surfaceLight = { lightA, lightB, lightC }
				original = false
			end
		end
		if surfaceLight then
			append(a, b, c, center, weight, source, normal, nil, source, surfaceLight, nil, true)
		elseif r.surfaceFrozen and not onSurface then
			splitCut(a, b, c, normal, 0, source, margin, center, weight)
		else
			append(a, b, c, center, weight, source, normal, bakedUV, source, nil, nil, true)
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
		elseif recordParts then
			-- Uncached input is never a proof that the native stream stayed
			-- unchanged. Drain earlier parts before appending direct triangles.
			for key, group in pairs(groups) do
				if group.parts then
					groups[key] = flatten(group.parts)
				end
			end
			recordParts = false
			previousByKey = {}
		end
		local cached = cell and cells[cell]
		if cached and cached.epoch == (r.surfaceEpoch or 0) then
			merge(cached.groups)
		else
			targetGroups = cell and {} or groups
			currentCell, cellCandidates, refinedCuts = cell, nil, 0
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
	local function buildBatch(key, group)
		-- The primary stream uses the color layout of the diffuse shader.
		-- Masked Phong also needs tangents, in a separate projected-light mesh.
		local object = Mesh((group.baked and group.source.slot.cutMaterial) or group.material)
		if checkpoint then
			checkpoint(object)
		end
		local meshVertices, cutScale = group.vertices, nil
		if group.cutLighting then
			meshVertices, cutScale = V.EncodeCutLighting(group.vertices, checkpoint, group.freshCut)
		end
		object:BuildFromTriangles(meshVertices)
		if checkpoint then checkpoint() end
		local flashMesh
		if group.phongFlash then
			flashMesh = Mesh(group.phongFlash)
			if checkpoint then checkpoint(flashMesh) end
			local tex, vertices = group.phongTex, {}
			for i, vertex in ipairs(group.vertices) do
				local n = vertex.normal
				local tangent = tex.v:Cross(n):GetNormalized()
				if tangent:Dot(tex.u) < 0 then
					tangent = -tangent
				end
				if tangent:LengthSqr() < 0.5 then
					tangent = n:Cross(tex.u):GetNormalized()
				end
				local handedness = n:Cross(tangent):Dot(tex.v) < 0 and -1 or 1
				vertices[i] = { pos = vertex.pos, normal = n, u = vertex.u, v = vertex.v,
					color = vertex.color, userdata = { tangent.x, tangent.y, tangent.z, handedness } }
				if checkpoint and i % 96 == 0 then checkpoint() end
			end
			flashMesh:BuildFromTriangles(vertices)
			if checkpoint then checkpoint() end
		end
		local weight = math.max(group.weight, 0.000001)
		local batch = {
			mesh = object,
			flashMesh = flashMesh,
			material = group.material,
			source = group.source,
			baked = group.baked,
			retained = group.retained,
			translucent = group.translucent,
			blendOverlay = group.blendOverlay,
			flashMaterial = group.flashMaterial,
			directLight = group.directLight,
			phongFlash = group.phongFlash,
			lightOrigin = group.lightOrigin,
			cutLighting = group.cutLighting,
			cutScale = cutScale,
			surfaceLight = group.surfaceLight,
			freshCut = group.freshCut,
			worldCenter = Vector(group.px / weight, group.py / weight, group.pz / weight),
			normal = Vector(group.nx, group.ny, group.nz):GetNormalized(),
		}
		if recordParts then
			batch.surfaceKey = key
			batch.surfaceEpoch = epoch
			batch.partIds = group.partIds
		end
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
		return batch
	end
	for key, group in pairs(groups) do
		local reused
		if group.parts then
			local previous, count = previousByKey[key], #group.parts
			reused = reuseSurfaceBatch(previous, count, checkpoint)
			if not reused then
				group = flatten(group.parts)
				group.partIds = prefixIds(previous, count)
			end
		end
		batches[#batches + 1] = reused or buildBatch(key, group)
	end
	for _, source in ipairs(own or {}) do
		source.building = false
	end
	return batches
end

-- Capture only the BSP. Players, props, selection overlays and the voxel
-- replacement itself must never become part of the frozen ground image.
local function inSurfaceCapture()
	if captureTargetName then
		local target = render.GetRenderTarget()
		return target and target:GetName() == captureTargetName
	end
end

hook.Add("PreDrawOpaqueRenderables", "GVoxel.CaptureOpaque", function(depth)
	if not depth and inSurfaceCapture() then
		return true
	end
end)
hook.Add("PreDrawTranslucentRenderables", "GVoxel.CaptureTranslucent", function()
	if inSurfaceCapture() then
		return true
	end
end)

local function finishCapture(source, failed, reason)
	source.ready = true
	source.failed = failed
	source.fallbackReason = reason
	source.captureChecks = nil
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
				batch.flashMaterial = source.surfaceAlbedo or source.interior or V.ScanSurfaceMaterial
				batch.cutLighting = true
				batch.surfaceLight = true
				batch.cutScale = pending.scale
				batch.baked = false
			else
				for _, vertex in ipairs(pending.vertices) do
					vertex.u, vertex.v = V.SurfaceUV(source, vertex.pos + pending.offset, vertex.normal, false, true)
				end
				batch.mesh:BuildFromTriangles(pending.vertices)
				batch.material = source.surfaceAlbedo or source.interior or V.ScanSurfaceMaterial
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
			captureTargetName = pass.rt:GetName()
			render.Clear(80, 74, 65, 255, true, true)
			if captureTone then
				render.SetToneMappingScaleLinear(pass.mode == 0 and captureTone or Vector(1, 1, 1))
			end
			render.SetLightingMode(pass.mode)
			render.RenderView(view)
			captureTargetName = nil
			render.PopRenderTarget()
			pushed = false
		end
	end, debug.traceback)
	captureTargetName = nil
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
	local job = queue[queueHead]
	if not job or job.source.building then
		return
	end
	queue[queueHead] = false
	queueHead = queueHead + 1
	if job.region ~= active then
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
		if batch.blendOverlay then return end
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
			or batch.retained and batch.source.surfaceAlbedo
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
		return (batch.retained and batch.source.surfaceAlbedo) or batch.source.interior or V.ScanSurfaceMaterial
	end
	return (batch.flashMesh and batch.flashMesh:IsValid() and batch.phongFlash) or batch.flashMaterial or batch.material
end

function V.SurfaceFlashMesh(batch)
	local mesh = textureEnabled:GetBool() and batch.flashMesh
	return mesh and mesh:IsValid() and mesh or batch.mesh
end

function V.SurfaceDynamicMaterial(batch)
	if batch.phongFlash and textureEnabled:GetBool() then
		return batch.flashMaterial
	end
	return V.SurfaceFlashMaterial(batch)
end

local directFallback
function V.SurfaceDirectLightMaterial(batch)
	if batch.translucent then
		return
	end
	if textureEnabled:GetBool() then
		if V.SurfaceUsesBaked(batch) then
			-- A screenshot has no original alpha coverage or native UVs.
			if batch.source.alphaTest then
				return
			end
			local slot = batch.source.slot
			if not slot.directLight then
				local name = slot.rt:GetName()
				slot.directLight = CreateMaterial(name .. "_direct", "UnlitGeneric", {
					["$basetexture"] = name,
					["$nocull"] = "1",
				})
			end
			return slot.directLight
		elseif batch.directLight then
			return batch.directLight(batch.retained)
		elseif batch.freshCut and not batch.source then
			return dirtAlbedo
		end
	end
	if not directFallback then
		directFallback = CreateMaterial("vm_ground_direct_fallback", "UnlitGeneric", {
			["$basetexture"] = "color/white",
			["$nocull"] = "1",
			["$color2"] = "[0.62 0.60 0.55]",
		})
	end
	return directFallback
end

concommand.Add("vm_texture_stats", function()
	local count, hd = 0, 0
	local pool = pools[active and active.surfaceHDR and "hdr" or "ldr"]
	for _, slot in pairs(pool) do
		count = count + 1
		if slot.used and slot.size == HD_SIZE then hd = hd + 1 end
	end
	print(
		string.format(
			"[GVoxel] Textures: %d / %d sources pretes | secours: %d | paires reutilisables: %d / %d | HD %d / %d (%d px ; couleurs <=144 MiB)",
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
