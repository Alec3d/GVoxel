-- Preserve captured static lighting. Moving lights add only their dynamic
-- contribution, using the albedo capture with identical UVs and geometry.
local V = GVoxel
local directions =
	{ Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }
local zero = Vector()
local dynamicFrame = -1
local dynamicChunks = setmetatable({}, { __mode = "k" })
local litProps = setmetatable({}, { __mode = "k" })
if V.ReleaseVoxelLighting and V.GetClientScanRegion then
	V.ReleaseVoxelLighting(V.GetClientScanRegion())
end
local modelAnchors = {}
local nativeOverride
V.VoxelSunBlocked = nil
local function positive(v)
	return Vector(math.max(0, v.x), math.max(0, v.y), math.max(0, v.z))
end
local function solid(p)
	return util.PointContents and bit.band(util.PointContents(p), CONTENTS_SOLID) ~= 0
end
local function dynamic(p, n)
	return render.ComputeDynamicLighting and positive(render.ComputeDynamicLighting(p, n)) or zero
end
local function apply(cube, origin)
	render.ResetModelLighting(0, 0, 0)
	for i, color in ipairs(cube) do
		render.SetModelLighting(i - 1, color.x, color.y, color.z)
	end
	render.SetLightingOrigin(origin)
	render.SetLocalModelLights()
end

function V.PrepareSurfaceLighting(source, r, chunk)
	if source.voxelEnvironment then
		return source.voxelEnvironment, source.voxelLightProbe
	end
	local probe = source.lightOrigin or (chunk and chunk.lightOrigin) or r.base
	local candidates = {}
	local n = source.planeNormal or (source.frame and source.frame.normal)
	if n and source.point then
		candidates[#candidates + 1] = (source.lightAnchor or source.point) + n * 2
		candidates[#candidates + 1] = source.point + n * 2
	end
	candidates[#candidates + 1] = probe
	-- Never borrow the first free probe from an unrelated wall. A large
	-- offset can cross a narrow room; prefer the air immediately at this face.
	for _, point in ipairs(candidates) do
		if not solid(point) then
			probe = point
			break
		end
	end
	local cube = {}
	local inside = solid(probe)
	local ambient = render.GetAmbientLightColor and positive(render.GetAmbientLightColor()) or zero
	for i, n in ipairs(directions) do
		-- ComputeLighting includes dynamic light. Freeze only the static part;
		-- moving lamps on cuts are sampled separately with a global limit.
		cube[i] = inside and ambient or positive(render.ComputeLighting(probe, n) - dynamic(probe, n))
	end
	source.voxelEnvironment = cube
	source.voxelLightProbe = probe
	return cube, probe
end

local function dynamicAt(chunk, point)
	local now = RealTime()
	local frame = FrameNumber()
	local state = dynamicChunks[chunk]
	if not state then
		state = {}
		dynamicChunks[chunk] = state
	end
	state.point = point
	state.frame = frame
	if frame ~= dynamicFrame then
		dynamicFrame = frame
		-- Oldest visible sample first. At low FPS, updating the first drawn
		-- chunk every frame would otherwise starve every following chunk.
		local selected, location, oldest = nil, nil, math.huge
		for candidate, state in pairs(dynamicChunks) do
			local cache = candidate.voxelDynamic
			local stamp = cache and cache.next or -math.huge
			if state.frame >= frame - 1 and now >= stamp and stamp < oldest then
				selected, location, oldest = candidate, state.point, stamp
			end
		end
		if selected then
			local cache = { next = now + 0.1, cube = {} }
			for i, n in ipairs(directions) do
				cache.cube[i] = dynamic(location, n)
			end
			selected.voxelDynamic = cache
		end
	end
	local cache = chunk.voxelDynamic
	return cache and cache.cube
end

function V.SurfaceLighting(r, chunk, batch)
	local source = batch.source or chunk
	local environment, probe = V.PrepareSurfaceLighting(source, r, chunk)
	local moving = dynamicAt(chunk, batch.worldCenter or chunk.lightOrigin or probe)
	if batch.lighting and batch.staticLight == environment and batch.movingLight == moving then
		return batch.lighting
	end
	local total = {}
	for i, color in ipairs(environment) do
		total[i] = color + (moving and moving[i] or zero)
	end
	batch.staticLight = environment
	batch.movingLight = moving
	batch.lighting = { environment = environment, dynamic = moving, total = total, probe = probe }
	return batch.lighting
end

-- Reloading this module restores the regular terrain renderer as well.
function V.DrawSurfaceBatch(r, chunk, batch, deferFlashlights)
	if not batch.mesh or not batch.mesh:IsValid() then
		return
	end
	local baked = V.SurfaceUsesBaked(batch)
	if not baked and not batch.cutLighting then
		local light = V.SurfaceLighting(r, chunk, batch)
		apply(light.total, light.probe)
	end
	-- UnlitGeneric consumes gamma-encoded vertex colors; a >=1 modulation
	-- restores their HDR range. Never carry this gain into dynamic/flash passes.
	local scale = batch.cutLighting and batch.cutScale or 1
	render.SetColorModulation(scale, scale, scale)
	render.SetMaterial(V.SurfaceMaterial(batch))
	batch.mesh:Draw()
	if batch.cutLighting then
		render.SetColorModulation(1, 1, 1)
	end
	if baked or batch.cutLighting then
		local moving = dynamicAt(chunk, batch.worldCenter or chunk.lightOrigin or r.base)
		local illuminated = false
		for _, color in ipairs(moving or {}) do
			if color:LengthSqr() > 0.000001 then
				illuminated = true
				break
			end
		end
		if illuminated then
			-- Zero ambient: never add the captured map lighting a second time.
			-- ComputeDynamicLighting includes the standard Sandbox Light tool.
			apply(moving, batch.worldCenter or chunk.lightOrigin or r.base)
			render.SetMaterial(V.SurfaceFlashMaterial(batch))
			render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
			batch.mesh:Draw()
			render.OverrideBlend(false)
		end
	end
	if not deferFlashlights then
		render.SetMaterial(V.SurfaceFlashMaterial(batch))
		render.RenderFlashlights(function()
			batch.mesh:Draw()
		end)
	end
end

function V.RestoreVoxelPropLighting()
	if nativeOverride then
		local state = nativeOverride
		nativeOverride = nil
		if IsValid(state.ent) and state.ent:GetLightingOriginEntity() == state.anchor then
			state.ent:SetLightingOriginEntity(state.previous)
		end
	end
	render.SuppressEngineLighting(false)
	render.ResetModelLighting(1, 1, 1)
	render.SetLocalModelLights()
end

local function propLightingState(r, ent, point)
	local state = ent.VMVoxelLight
	if not state or state.region ~= r or point:DistToSqr(state.anchor) > (r.step * 4) ^ 2 then
		local source, distance = nil, math.huge
		for _, candidate in ipairs(r.surfaceList or {}) do
			local d = point:DistToSqr(candidate.point)
			if d < distance then
				source, distance = candidate, d
			end
		end
		source = source or { lightOrigin = r.base + Vector(0, 0, 16) }
		state = {
			region = r,
			anchor = point,
			chunk = { lightOrigin = source.lightOrigin or source.point },
			batch = {
				source = source,
			},
		}
		ent.VMVoxelLight = state
		litProps[ent] = true
	end
	return state
end

local function lightVehicle(r, ent, point)
	-- Keep Source's material, cubemap, directional/specular and dynamic-light
	-- setup. An ambient cube cannot reproduce a car's native paint lighting.
	render.SuppressEngineLighting(false)
	if not ent.GetLightingOriginEntity or not ent.SetLightingOriginEntity then
		return false
	end
	local previous = ent:GetLightingOriginEntity()
	if IsValid(previous) then
		return false
	end -- Origin owned by the framework.
	local state = propLightingState(r, ent, point)
	local _, probe = V.PrepareSurfaceLighting(state.batch.source, r, state.chunk)
	if solid(probe) then
		return false
	end
	local anchor = modelAnchors[r]
	if not IsValid(anchor) then
		if not ClientsideModel then
			return false
		end
		anchor = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl")
		if not IsValid(anchor) then
			return false
		end
		anchor:SetNoDraw(true)
		modelAnchors[r] = anchor
	end
	if not anchor.VMVoxelProbe or anchor.VMVoxelProbe:DistToSqr(probe) > 0.000001 then
		anchor:SetPos(probe)
		anchor.VMVoxelProbe = probe
	end
	nativeOverride = { ent = ent, anchor = anchor, previous = previous, region = r }
	ent:SetLightingOriginEntity(anchor)
	return true
end

function V.LightVoxelProp(r, ent)
	local point = ent:WorldSpaceCenter()
	-- Enrollment in voxel physics is not a reason to replace valid map light.
	if not V.InScanCube(r, point) or not solid(point) then
		return false
	end
	if V.GetVoxelVehicleRoot and V.GetVoxelVehicleRoot(ent) then
		return lightVehicle(r, ent, point)
	end
	local state = propLightingState(r, ent, point)
	state.batch.worldCenter = point
	local light = V.SurfaceLighting(r, state.chunk, state.batch)
	render.SuppressEngineLighting(true)
	apply(light.total, light.probe)
	return true
end

function V.ReleaseVoxelLighting(r)
	if not r then
		return
	end
	r.cutLighting = nil
	if nativeOverride and nativeOverride.region == r then
		V.RestoreVoxelPropLighting()
	end
	if IsValid(modelAnchors[r]) then
		modelAnchors[r]:Remove()
	end
	modelAnchors[r] = nil
	for _, chunk in pairs(r.chunks) do
		dynamicChunks[chunk] = nil
	end
	for ent in pairs(litProps) do
		local state = ent.VMVoxelLight
		if state and state.region == r then
			dynamicChunks[state.chunk] = nil
			ent.VMVoxelLight = nil
			litProps[ent] = nil
		end
	end
end

hook.Add("ShutDown", "GVoxel.ReleaseModelLightAnchors", function()
	V.RestoreVoxelPropLighting()
	for r, anchor in pairs(modelAnchors) do
		if IsValid(anchor) then
			anchor:Remove()
		end
		modelAnchors[r] = nil
	end
end)
