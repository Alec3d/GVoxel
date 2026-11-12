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
local directRegion, directJob
local directBatches, directQueue, directCursor = {}, {}, 1
local lightTools, nextToolSearch = {}, 0
local activeDirectLights, lightEpoch, lastEmitterCount = false, 0, 0
local toolClasses = { "gmod_light", "gmod_lamp" }
local MAX_DIRECT_BATCHES, DIRECT_PROBES, MAX_TOOLS_PER_CLASS = 512, 6, 8
V.VoxelSunBlocked = nil
local function positive(v)
	return Vector(math.max(0, v.x), math.max(0, v.y), math.max(0, v.z))
end
local function solid(p)
	return util.PointContents and bit.band(util.PointContents(p), CONTENTS_SOLID) ~= 0
end
local function dynamic(p, n)
	local color = render.ComputeDynamicLighting and render.ComputeDynamicLighting(p, n)
	if not color or (color.x <= 0 and color.y <= 0 and color.z <= 0) then
		return zero
	end
	return color.x >= 0 and color.y >= 0 and color.z >= 0 and color or positive(color)
end
local function apply(cube, origin)
	render.ResetModelLighting(0, 0, 0)
	for i, color in ipairs(cube) do
		render.SetModelLighting(i - 1, color.x, color.y, color.z)
	end
	render.SetLightingOrigin(origin)
	render.SetLocalModelLights()
end

local function surfaceProbe(source, r, chunk)
	local probe = source.lightOrigin or (chunk and chunk.lightOrigin) or r.base
	local n = source.planeNormal or (source.frame and source.frame.normal)
	-- Prefer air immediately on this face before using a farther source probe.
	if n and source.point then
		local offset = n * 2
		local anchor = (source.lightAnchor or source.point) + offset
		if not solid(anchor) then
			return anchor, false
		end
		if source.lightAnchor and source.lightAnchor ~= source.point then
			local point = source.point + offset
			if not solid(point) then
				return point, false
			end
		end
	end
	return probe, solid(probe)
end

function V.PrepareSurfaceLighting(source, r, chunk)
	if source.voxelEnvironment then
		return source.voxelEnvironment, source.voxelLightProbe
	end
	local probe, inside = surfaceProbe(source, r, chunk)
	local cube
	if inside or not render.ComputeLighting then
		local point = source.lightAnchor or source.point
		local native = point and V.SurfaceLightmap and V.SurfaceLightmap(r, source, point)
		cube = not inside and V.SampleBSPAmbientCube and V.SampleBSPAmbientCube(r.bsp, probe)
		if native then
			cube = { native, native, native, native, native, native }
		elseif not cube then
			cube = r.surfaceAmbientCube
			if not cube then
				local ambient = render.GetAmbientLightColor and positive(render.GetAmbientLightColor()) or zero
				cube = { ambient, ambient, ambient, ambient, ambient, ambient }
				r.surfaceAmbientCube = cube
			end
		end
	else
		-- A static ambient cube depends on the exact air position, independent
		-- of material/chunk. Never quantize across a doorway or a thin wall.
		local key = probe.x .. ":" .. probe.y .. ":" .. probe.z
		local probes = r.surfaceLightProbes
		if not probes then
			probes = { count = 0 }
			r.surfaceLightProbes = probes
		end
		cube = probes[key]
		if not cube then
			cube = {}
			local ambient = V.SampleBSPAmbientCube and V.SampleBSPAmbientCube(r.bsp, probe)
			for i, n in ipairs(directions) do
				-- Freeze only the static part. Moving lamps have their own pass.
				local total, moving = render.ComputeLighting(probe, n), dynamic(probe, n)
				local baked = ambient and ambient[i] or zero
				cube[i] = Vector(
					math.max(baked.x, total.x - moving.x),
					math.max(baked.y, total.y - moving.y),
					math.max(baked.z, total.z - moving.z)
				)
			end
			if probes.count < 4096 then
				probes[key] = cube
				probes.count = probes.count + 1
			end
		end
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
			local cache = { next = now + 0.1, cube = {}, illuminated = false }
			for i, n in ipairs(directions) do
				local color = dynamic(location, n)
				cache.cube[i] = color
				cache.illuminated = cache.illuminated or color:LengthSqr() > 0.000001
			end
			selected.voxelDynamic = cache
		end
	end
	local cache = chunk.voxelDynamic
	return cache and cache.cube, cache and cache.illuminated
end

function V.SurfaceLighting(r, chunk, batch, staticOnly)
	local source = batch.source or chunk
	local environment, probe = V.PrepareSurfaceLighting(source, r, chunk)
	local moving = not staticOnly and dynamicAt(chunk, batch.worldCenter or chunk.lightOrigin or probe) or nil
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

local function resetDirectLighting(r)
	directRegion, directJob = r, nil
	directBatches, directQueue, directCursor = {}, {}, 1
	lightTools, nextToolSearch = {}, 0
	activeDirectLights, lightEpoch, lastEmitterCount = false, 0, 0
end

local function emitterColor(color, brightness)
	if not color then return Vector(brightness, brightness, brightness) end
	return Vector(color.r / 255, color.g / 255, color.b / 255) * brightness
end

local function sandboxEmitters(now)
	if now >= nextToolSearch then
		nextToolSearch = now + 0.25
		lightTools = {}
		if ents and ents.FindByClass then
			for _, class in ipairs(toolClasses) do
				local count = 0
				for _, ent in ipairs(ents.FindByClass(class)) do
					if IsValid(ent) and not ent:IsDormant() and ent.GetOn and ent:GetOn() then
						lightTools[#lightTools + 1] = { entity = ent, spot = class == "gmod_lamp" }
						count = count + 1
						if count == MAX_TOOLS_PER_CLASS then break end
					end
				end
			end
		end
	end
	local emitters = {}
	for _, tool in ipairs(lightTools) do
		local ent = tool.entity
		if IsValid(ent) and not ent:IsDormant() and ent.GetOn and ent:GetOn() then
			local range = tool.spot and ent:GetDistance() or ent:GetLightSize()
			local brightness = math.min(tool.spot and 8 or 6, ent:GetBrightness())
			-- Sandbox's LightWorld variable is the dlight `noworld` flag.
			if range > 0 and brightness > 0 and (tool.spot or not ent:GetLightWorld()) then
				local light = { entity = ent, pos = ent:GetPos(), range = math.min(2048, range),
					color = emitterColor(ent:GetColor(), brightness) }
				if tool.spot then
					local info = ent.GetLightInfo and ent:GetLightInfo()
					if info then light.pos = ent:LocalToWorld(info.Offset - Vector(5, 0, 0)) end
					light.direction = info and ent:LocalToWorldAngles(info.Angle):Forward() or ent:GetForward()
					light.cone = math.cos(math.rad(math.max(10, math.min(170, ent:GetLightFOV())) / 2))
				end
				emitters[#emitters + 1] = light
			end
		end
	end
	return emitters
end

local function throughVoxelOpening(r, light, point, direction, distance, checkpoint)
	local finish = point - direction * 0.25
	local parameters = { start = light.pos, endpos = finish, mask = MASK_SOLID,
		filter = function(ent) return ent ~= light.entity and ent:GetClass() ~= "vm_voxel_collider" end }
	local native = util.TraceLine(parameters)
	if not native.Hit and not native.StartSolid then
		-- Both tools use this path for voxel surfaces, including projectors
		-- in native air. An added voxel wall can still occlude the light.
		return r.revision == 0 or not V.TraceScanRegion
			or not V.TraceScanRegion(r, light.pos, direction, distance - 0.25, true, checkpoint)
	end
	if r.revision == 0 or not V.TraceScanRegion or not V.InScanCube then return false end
	local stale = native.StartSolid and V.InScanCube(r, light.pos)
		or native.HitWorld and native.HitPos and V.InScanCube(r, native.HitPos)
	if not stale or not V.InScanCube(r, point) then return false end
	parameters.ignoreworld = true
	local object = util.TraceLine(parameters)
	if object.Hit or object.StartSolid then return false end
	return not V.TraceScanRegion(r, light.pos, direction, distance - 0.25, true, checkpoint)
end

local function sampleDirect(r, state, emitters, checkpoint)
	local normal = state.normal
	local point = state.point + normal * 0.75
	local total = zero
	if not util.TraceLine then return zero end
	for _, light in ipairs(emitters) do
		local delta = point - light.pos
		local distance = delta:Length()
		if distance > 0.25 and distance < light.range then
			local direction = delta / distance
			local facing = -normal:Dot(direction)
			local angular = light.direction and (light.direction:Dot(direction) - light.cone) / (1 - light.cone) or 1
			if facing > 0 and angular > 0 and throughVoxelOpening(r, light, point, direction, distance, checkpoint) then
				local falloff = 1 - distance / light.range
				local color = light.color * (falloff * falloff * facing * math.min(1, angular * 2))
				total = total + color
			end
		end
		checkpoint()
	end
	-- This additive layer supplements an already lit surface. Cap its
	-- gain without changing the light's hue on bright or overlapping tools.
	local peak = math.max(total.x, total.y, total.z)
	return peak > 0.5 and total * (0.5 / peak) or total
end

local function inCone(state, light)
	local x, y, z = state.x - light.x, state.y - light.y, state.z - light.z
	local distance2 = x * x + y * y + z * z
	if distance2 >= light.range * light.range or state.nx * x + state.ny * y + state.nz * z >= 0 then return false end
	if not light.direction then return true end
	local facing = x * light.dx + y * light.dy + z * light.dz
	return facing > 0 and facing * facing > distance2 * light.cone * light.cone
end

local function nextVisibleBatch(frame, focus, deadline)
	for i = 1, #directQueue do
		if #directQueue == 0 or i % 16 == 0 and SysTime() >= deadline then return end
		if directCursor > #directQueue then directCursor = 1 end
		local state = directQueue[directCursor]
		if state.seen < frame - 2 then
			directBatches[state.mesh] = nil
			directQueue[directCursor] = directQueue[#directQueue]
			directQueue[#directQueue] = nil
		else
			directCursor = directCursor + 1
			if state.probedFrame ~= frame and (not focus or inCone(state, focus)) then
				state.probedFrame = frame
				return state
			end
		end
	end
end

hook.Add("Think", "GVoxel.LiveSurfaceLighting", function()
	local r = directRegion
	if not r then return end
	if V.GetClientScanRegion and V.GetClientScanRegion() ~= r then resetDirectLighting(nil) return end
	local now, frame = RealTime(), FrameNumber()
	local emitters = sandboxEmitters(now)
	activeDirectLights = #emitters > 0
	if #emitters ~= lastEmitterCount then
		lastEmitterCount, lightEpoch = #emitters, lightEpoch + 1
	end
	if not activeDirectLights then
		if #directQueue > 0 then directBatches, directQueue, directCursor = {}, {}, 1 end
		directJob = nil
		return
	end
	if #directQueue == 0 then return end
	local focus = emitters[1]
	for _, light in ipairs(emitters) do
		if light.direction then
			focus = light
			break
		end
	end
	if focus then
		focus.x, focus.y, focus.z = focus.pos.x, focus.pos.y, focus.pos.z
		if focus.direction then focus.dx, focus.dy, focus.dz = focus.direction.x, focus.direction.y, focus.direction.z end
	end
	local deadline = SysTime() + 0.0006
	for i = 1, math.min(DIRECT_PROBES, #directQueue) do
		if SysTime() >= deadline then break end
		if directJob and (directJob.revision ~= r.revision or directJob.lightEpoch ~= lightEpoch) then
			directJob = nil
		end
		if not directJob then
			local state = focus and i <= 4 and nextVisibleBatch(frame, focus, deadline)
			if not state then
				focus = nil
				state = nextVisibleBatch(frame, nil, deadline)
			end
			if not state then return end
			local job = { state = state, revision = r.revision, lightEpoch = lightEpoch }
			job.thread = coroutine.create(function()
				return sampleDirect(r, state, emitters, function()
					if SysTime() >= job.deadline then coroutine.yield() end
				end)
			end)
			directJob = job
		end
		local job = directJob
		job.deadline = deadline
		local ok, light = coroutine.resume(job.thread)
		if not ok then
			directJob = nil
			if ErrorNoHalt then ErrorNoHalt("[GVoxel] Lumiere locale : " .. tostring(light) .. "\n") end
			return
		end
		if coroutine.status(job.thread) ~= "dead" then return end
		job.state.light = light
		job.state.occlusionRevision, job.state.sampledAt, job.state.lightEpoch = r.lightOcclusionRevision, now, lightEpoch
		directJob = nil
	end
end)

local function directLight(r, batch)
	if directRegion ~= r then resetDirectLighting(r) end
	if not activeDirectLights then return zero end
	local mesh = batch.mesh
	local state = directBatches[mesh]
	if not state then
		if #directQueue >= MAX_DIRECT_BATCHES then return zero end
		local p, n = batch.worldCenter, batch.normal
		state = { mesh = mesh, point = p, normal = n, x = p.x, y = p.y, z = p.z, nx = n.x, ny = n.y, nz = n.z }
		directBatches[mesh] = state
		directQueue[#directQueue + 1] = state
	end
	state.seen = FrameNumber()
	if state.occlusionRevision ~= r.lightOcclusionRevision or state.lightEpoch ~= lightEpoch
		or not state.sampledAt or RealTime() - state.sampledAt > 0.25 then
		return zero
	end
	return state.light
end

-- Reloading this module restores the regular terrain renderer as well.
function V.DrawSurfaceBatch(r, chunk, batch, deferFlashlights)
	if not batch.mesh or not batch.mesh:IsValid() then
		return
	end
	local material = V.SurfaceMaterial(batch)
	if not material then return end
	local baked = V.SurfaceUsesBaked(batch)
	if not baked and not batch.cutLighting then
		local light = V.SurfaceLighting(r, chunk, batch, V.SurfaceDirectLightMaterial ~= nil)
		apply(light.total, light.probe)
	end
	-- UnlitGeneric consumes gamma-encoded vertex colors; a >=1 modulation
	-- restores their HDR range. Never carry this gain into dynamic/flash passes.
	local scale = batch.cutLighting and batch.cutScale or 1
	render.SetColorModulation(scale, scale, scale)
	render.SetMaterial(material)
	batch.mesh:Draw()
	if batch.cutLighting then
		render.SetColorModulation(1, 1, 1)
	end
	local direct = V.SurfaceDirectLightMaterial and not batch.translucent and batch.worldCenter
		and batch.normal and batch.normal:LengthSqr() > 0.5
	if direct then
		local light = directLight(r, batch)
		local material = light:LengthSqr() > 0.000001 and V.SurfaceDirectLightMaterial(batch)
		if material then
			render.SetColorModulation(light.x, light.y, light.z)
			render.SetMaterial(material)
			render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
			batch.mesh:Draw()
			render.OverrideBlend(false)
			render.SetColorModulation(1, 1, 1)
		end
	elseif not V.SurfaceDirectLightMaterial and not batch.translucent and (baked or batch.cutLighting) then
		local moving, illuminated = dynamicAt(chunk, batch.worldCenter or chunk.lightOrigin or r.base)
		if illuminated then
			-- Zero ambient: never add the captured map lighting a second time.
			-- ComputeDynamicLighting includes the standard Sandbox Light tool.
			apply(moving, batch.worldCenter or chunk.lightOrigin or r.base)
			render.SetMaterial(V.SurfaceDynamicMaterial and V.SurfaceDynamicMaterial(batch) or V.SurfaceFlashMaterial(batch))
			render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
			batch.mesh:Draw()
			render.OverrideBlend(false)
		end
	end
	if not deferFlashlights and not batch.translucent then
		render.SetMaterial(V.SurfaceFlashMaterial(batch))
		local mesh = V.SurfaceFlashMesh and V.SurfaceFlashMesh(batch) or batch.mesh
		render.RenderFlashlights(function()
			mesh:Draw()
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
	if directRegion == r then resetDirectLighting(nil) end
	r.cutLighting = nil
	r.surfaceLightProbes = nil
	r.surfaceAmbientCube = nil
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
