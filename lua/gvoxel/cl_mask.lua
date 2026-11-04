-- Original renderer informed by Mineable Worlds (Workshop 3821244221):
-- stencil -> local depth clear -> world-space terrain -> background openings.
-- No Mineable Worlds scripts or assets are bundled with this implementation.
local V = GVoxel
if V.ReleaseClientScan then
	V.ReleaseClientScan()
elseif V.SetVisualRegion then
	V.SetVisualRegion(nil)
end
local enabled = CreateClientConVar("vm_replace_visual", "1", true, false, "Remplacement visuel du BSP scanne", 0, 1)
local stats = { passes = 0, ms = 0, terrain = 0, openings = 0, chunks = 0, culled = 0, reused = 0, native = 0 }
function V.GetVoxelRenderStats()
	return table.Copy(stats)
end
local region, faces, failure
local portals = {}
local compileFace = 0
local openingJob
local nativeBackground
local prepared = false
local targets = {}
local backgroundPlane, frameViews
local preparing = false
local targetPushed, clipPushed, matrixPushed = false, false, false
local clipState
local toneState
local cachedEntities = {}
local nextEntityRefresh = 0
local exteriorEntities = {}
local nextExteriorRefresh = 0
local exteriorProof = setmetatable({}, { __mode = "k" })
local exteriorFrame, exteriorStart, exteriorCursor, exteriorDeferred = 0, 1, 1, false
local exteriorRays, exteriorTraceTime = 0, 0
local backgroundContext
local visibilityControllers = { func_areaportal = true, func_areaportalwindow = true, func_occluder = true }
local composing = false
local maskMaterial = CreateMaterial("vm_native_mask_v2", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$nocull"] = "1",
})
V.ScanSurfaceMaterial = CreateMaterial("vm_scan_surface_v1", "VertexLitGeneric", {
	["$basetexture"] = "color/white",
	["$model"] = "1",
	["$nocull"] = "1",
	["$color2"] = "[0.62 0.60 0.55]",
	["$vertexcolor"] = "0",
	["$vertexalpha"] = "0",
})

-- Remove the old multi-view terrain compositor during Lua refresh as well.
for event, names in pairs({
	PreDrawOpaqueRenderables = { "GVoxel.MaskScene" },
	PostDrawOpaqueRenderables = { "GVoxel.MaskRestoreWorldClip" },
	PreDrawSkyBox = { "GVoxel.MaskSkyBegin" },
	PostDrawSkyBox = { "GVoxel.MaskSkyEnd" },
	PostDrawTranslucentRenderables = { "GVoxel.ReplaceScanVisual" },
}) do
	for _, name in ipairs(names) do
		hook.Remove(event, name)
	end
end

local function freePortals()
	local old = portals
	portals = {}
	for _, portal in ipairs(old) do
		V.ReleaseChunkMeshes(portal)
	end
end

function V.SetVisualRegion(r)
	region = nil
	faces = nil
	frameViews = nil
	compileFace = 0
	openingJob = nil
	prepared = false
	freePortals()
	region = r
	faces = r and V.MaskFaces(r) or nil
	compileFace = r and 1 or 0
	openingJob = nil
	prepared = false
	nativeBackground = nil
	failure = nil
	frameViews = nil
	cachedEntities = {}
	nextEntityRefresh = 0
	exteriorEntities = {}
	nextExteriorRefresh = 0
	exteriorProof = setmetatable({}, { __mode = "k" })
	exteriorFrame = -1
	exteriorCursor = 1
end

function V.VisualReplacementEnabled()
	return enabled:GetBool() and region ~= nil and prepared and not failure
end

-- Compile the aperture meshes once. Brush edits preserve the outer lattice,
-- so these meshes remain valid while interior terrain chunks are replaced.
hook.Add("Think", "GVoxel.CompileOpenings", function()
	if compileFace == 0 or not region then
		return
	end
	local index = compileFace
	openingJob = openingJob
		or coroutine.create(function()
			if index == 1 then
				nativeBackground = V.BuildNativeBackgroundData(region, coroutine.yield)
			end
			local vertices = V.BuildBoundaryOpening(region, faces[index], region.bspFallback and function()
				coroutine.yield()
			end or nil)
			local sky = V.PortalSkyFlags(region.bsp, vertices, faces[index].normal, coroutine.yield)
			return vertices, sky
		end)
	local deadline = SysTime() + 0.001
	local vertices, sky
	repeat
		local ok, result, flags = coroutine.resume(openingJob)
		if not ok then
			failure = tostring(result)
			compileFace = 0
			openingJob = nil
			ErrorNoHalt("[GVoxel] Ouvertures annulees : " .. failure .. "\n")
			return
		end
		vertices, sky = result, flags
	until coroutine.status(openingJob) == "dead" or SysTime() >= deadline
	if coroutine.status(openingJob) ~= "dead" then
		return
	end
	openingJob = nil
	if #vertices > 0 then
		local object = Mesh(maskMaterial)
		object:BuildFromTriangles(vertices)
		local low, high = V.VertexBounds(vertices)
		portals[#portals + 1] = {
			face = faces[index],
			mesh = object,
			low = low,
			high = high,
			slot = index,
			sky3D = sky == nil or bit.band(sky, 1) ~= 0,
		}
	end
	compileFace = index + 1
	if compileFace > 6 then
		compileFace = 0
		prepared = true
		stats.openings = #portals
	end
end)

local function drawFace(face)
	local p = face.vertices
	render.DrawQuad(p[1], p[2], p[3], p[4], color_white)
end

local directions =
	{ Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }
local function drawTerrain(frustum)
	local visible = {}
	render.SuppressEngineLighting(true)
	for _, chunk in pairs(region.chunks) do
		if chunk.mesh and V.BoundsInView(frustum, chunk.low, chunk.high) then
			stats.chunks = stats.chunks + 1
			visible[#visible + 1] = chunk
			if not chunk.batches or not V.DrawSurfaceBatch then
				if not chunk.light or (chunk.nextLight or 0) <= RealTime() then
					chunk.light = {}
					for i, normal in ipairs(directions) do
						chunk.light[i] = render.ComputeLighting(chunk.lightOrigin, normal)
					end
					chunk.nextLight = RealTime() + 0.1
				end
				render.ResetModelLighting(0, 0, 0)
				for i, light in ipairs(chunk.light) do
					render.SetModelLighting(i - 1, light.x, light.y, light.z)
				end
				render.SetLightingOrigin(chunk.lightOrigin)
			end
			cam.PushModelMatrix(chunk.transform)
			matrixPushed = true
			if chunk.batches then
				for _, batch in ipairs(chunk.batches) do
					if V.DrawSurfaceBatch then
						V.DrawSurfaceBatch(region, chunk, batch, true)
					else
						render.SetMaterial(V.SurfaceMaterial(batch))
						V.DrawMesh(batch.mesh)
					end
				end
			else
				render.SetMaterial(V.ScanSurfaceMaterial)
				V.DrawMesh(chunk.mesh)
			end
			cam.PopModelMatrix()
			matrixPushed = false
		end
	end
	-- Enumerate projected lights once for the complete visible terrain.
	render.RenderFlashlights(function()
		for _, chunk in ipairs(visible) do
			cam.PushModelMatrix(chunk.transform)
			matrixPushed = true
			if chunk.batches then
				for _, batch in ipairs(chunk.batches) do
					render.SetMaterial(
						V.SurfaceFlashMaterial and V.SurfaceFlashMaterial(batch) or V.SurfaceMaterial(batch)
					)
					V.DrawMesh(batch.mesh)
				end
			else
				render.SetMaterial(V.ScanSurfaceMaterial)
				V.DrawMesh(chunk.mesh)
			end
			cam.PopModelMatrix()
			matrixPushed = false
		end
	end)
	render.SuppressEngineLighting(false)
	render.ResetModelLighting(1, 1, 1)
	render.SetLocalModelLights()
	stats.terrain = stats.terrain + 1
end

local function firstPersonModel(ent, me, viewmodel)
	for _ = 1, 16 do
		local class = ent:GetClass()
		if
			ent == viewmodel
			or class == "viewmodel"
			or class == "predicted_viewmodel"
			or class == "gmod_hands"
			or (ent == me and not me:ShouldDrawLocalPlayer())
		then
			return true
		end
		local parent = ent.GetParent and ent:GetParent()
		if not IsValid(parent) then
			return false
		end
		if parent == ent then
			return true
		end
		ent = parent
	end
	return true
end

local function drawEntityModel(ent)
	-- Manual DrawModel does not inherit the engine render-list color setup.
	-- Read each part's own live RGBA; never tint wheels with chassis color.
	local red, green, blue, alpha = 255, 255, 255, 255
	if ent.GetColor4Part then
		red, green, blue, alpha = ent:GetColor4Part()
	elseif ent.GetColor then
		local color = ent:GetColor()
		red, green, blue, alpha = color.r, color.g, color.b, color.a
	end
	if alpha == 0 then
		return
	end
	render.SetColorModulation(red / 255, green / 255, blue / 255)
	render.SetBlend(alpha / 255)
	ent:DrawModel()
	render.SetBlend(1)
	render.SetColorModulation(1, 1, 1)
end

local function redrawEntities()
	if RealTime() >= nextEntityRefresh then
		-- The partition omits clientside models. Vehicle wheels/trim can be
		-- children of the chassis or of a separate physical wheel. Redraw
		-- each descendant once, including when it is also in FindInBox.
		cachedEntities = {}
		local seen = {}
		local function add(ent)
			if not IsValid(ent) or seen[ent] then
				return
			end
			seen[ent] = true
			cachedEntities[#cachedEntities + 1] = ent
		end
		for _, ent in ipairs(ents.FindInBox(region.origin, region.origin + V.RegionSize(region))) do
			add(ent)
		end
		local index = 1
		while cachedEntities[index] do
			local ent = cachedEntities[index]
			index = index + 1
			for _, child in ipairs(ent.GetChildren and ent:GetChildren() or {}) do
				add(child)
			end
		end
		nextEntityRefresh = RealTime() + 0.15
	end
	local me = LocalPlayer()
	local viewmodel = me.GetViewModel and me:GetViewModel()
	for _, ent in ipairs(cachedEntities) do
		if
			IsValid(ent)
			and not ent:IsWorld()
			and not ent:IsWeapon()
			and not ent:GetNoDraw()
			and not visibilityControllers[ent:GetClass()]
			and not firstPersonModel(ent, me, viewmodel)
			and ent:GetModel()
			and ent:GetModel() ~= ""
			and (not ent:IsPlayer() or (ent:Alive() and (ent ~= me or me:ShouldDrawLocalPlayer())))
		then
			local lit = V.LightVoxelProp and V.LightVoxelProp(region, ent)
			drawEntityModel(ent)
			if ent:IsPlayer() or ent:IsNPC() then
				local weapon = ent:GetActiveWeapon()
				if IsValid(weapon) then
					drawEntityModel(weapon)
				end
			end
			if lit then
				if V.RestoreVoxelPropLighting then
					V.RestoreVoxelPropLighting()
				else
					render.SuppressEngineLighting(false)
					render.ResetModelLighting(1, 1, 1)
					render.SetLocalModelLights()
				end
			end
		end
	end
end

local function exteriorTrace(data)
	local started = SysTime()
	local hit = util.TraceLine(data)
	exteriorTraceTime = exteriorTraceTime + SysTime() - started
	stats.exteriorTraceMS = exteriorTraceTime * 1000
	return hit
end

local function exteriorVisible(ent, eye, low, high, observer)
	local proof = exteriorProof[ent]
	local now = RealTime()
	if
		proof
		and now < proof.untilTime
		and proof.revision == region.revision
		and proof.eye:DistToSqr(eye) == 0
		and proof.low:DistToSqr(low) == 0
		and proof.high:DistToSqr(high) == 0
	then
		stats.exteriorCached = stats.exteriorCached + 1
		return proof.visible
	end
	if exteriorRays >= 96 or exteriorTraceTime >= 0.00075 then
		stats.exteriorDeferred = stats.exteriorDeferred + 1
		return
	end
	local visible = V.ExteriorLineOfSight(region, eye, ent, low, high, observer, exteriorTrace, function()
		if exteriorRays >= 96 or exteriorTraceTime >= 0.00075 then
			return false
		end
		exteriorRays = exteriorRays + 1
		stats.exteriorTraces = exteriorRays
		return true
	end)
	if visible == nil then
		stats.exteriorDeferred = stats.exteriorDeferred + 1
		return
	end
	exteriorProof[ent] = {
		eye = Vector(eye.x, eye.y, eye.z),
		low = Vector(low.x, low.y, low.z),
		high = Vector(high.x, high.y, high.z),
		revision = region.revision,
		untilTime = now + 0.05,
		visible = visible,
	}
	return visible
end

-- Native RenderView can omit entities in the old camera PVS. Repair only
-- received, non-dormant models in the exit cone with proven native LOS.
local function redrawExterior(context)
	if exteriorFrame ~= FrameNumber() then
		exteriorFrame = FrameNumber()
		exteriorRays = 0
		exteriorTraceTime = 0
		exteriorStart = exteriorCursor
		exteriorDeferred = false
		stats.exteriorTraces = 0
		stats.exteriorTraceMS = 0
		stats.exteriorCached = 0
		stats.exteriorHidden = 0
		stats.exteriorDeferred = 0
	end
	if RealTime() >= nextExteriorRefresh then
		exteriorEntities = {}
		local seen = {}
		local function add(ent)
			if not IsValid(ent) or seen[ent] then
				return
			end
			seen[ent] = true
			exteriorEntities[#exteriorEntities + 1] = ent
		end
		if ents.Iterator then
			for _, ent in ents.Iterator() do
				add(ent)
			end
		else
			for _, ent in ipairs(ents.GetAll and ents.GetAll() or {}) do
				add(ent)
			end
		end
		local index = 1
		while exteriorEntities[index] do
			local ent = exteriorEntities[index]
			index = index + 1
			for _, child in ipairs(ent.GetChildren and ent:GetChildren() or {}) do
				add(child)
			end
		end
		nextExteriorRefresh = RealTime() + 0.15
	end
	local me = LocalPlayer()
	local viewmodel = me.GetViewModel and me:GetViewModel()
	local high = region.origin + V.RegionSize(region)
	for offset = 1, #exteriorEntities do
		local index = (exteriorStart + offset - 2) % #exteriorEntities + 1
		local ent = exteriorEntities[index]
		if
			IsValid(ent)
			and ent.WorldSpaceAABB
			and not ent:IsWorld()
			and not ent:IsWeapon()
			and not ent:GetNoDraw()
			and not visibilityControllers[ent:GetClass()]
			and not (ent.IsDormant and ent:IsDormant())
			and not firstPersonModel(ent, me, viewmodel)
			and ent:GetModel()
			and ent:GetModel() ~= ""
			and (not ent:IsPlayer() or (ent:Alive() and (ent ~= me or me:ShouldDrawLocalPlayer())))
		then
			local low, big = ent:WorldSpaceAABB()
			local contained = low.x >= region.origin.x
				and low.y >= region.origin.y
				and low.z >= region.origin.z
				and big.x <= high.x
				and big.y <= high.y
				and big.z <= high.z
			if
				not contained
				and V.BoundsInView(context.frustum, low, big)
				and (not ent.TestPVS or not ent:TestPVS(context.view.origin))
			then
				local visible = exteriorVisible(ent, context.view.origin, low, big, me)
				if visible then
					if ent.SetupBones then
						ent:SetupBones()
					end
					drawEntityModel(ent)
					if ent:IsPlayer() or ent:IsNPC() then
						local weapon = ent:GetActiveWeapon()
						if IsValid(weapon) then
							drawEntityModel(weapon)
						end
					end
				else
					stats.exteriorHidden = stats.exteriorHidden + 1
					-- Rotate the first deferred model to the front next frame;
					-- busy scenery must not starve every later entity forever.
					if visible == nil and not exteriorDeferred then
						exteriorCursor = index
						exteriorDeferred = true
					end
				end
			end
		end
	end
end

local function stencilDefaults()
	render.SetStencilEnable(false)
	render.SetStencilWriteMask(255)
	render.SetStencilTestMask(255)
	render.SetStencilReferenceValue(0)
	render.SetStencilCompareFunction(STENCILCOMPARISONFUNCTION_ALWAYS)
	render.SetStencilPassOperation(STENCILOPERATION_KEEP)
	render.SetStencilFailOperation(STENCILOPERATION_KEEP)
	render.SetStencilZFailOperation(STENCILOPERATION_KEEP)
end

local function cleanup()
	-- DrawModel can invoke a vehicle's custom Draw callback and fail there.
	-- Restore its temporary native light origin on that error path as well.
	if V.RestoreVoxelPropLighting then
		V.RestoreVoxelPropLighting()
	end
	if matrixPushed then
		cam.PopModelMatrix()
		matrixPushed = false
	end
	if clipPushed then
		render.PopCustomClipPlane()
		clipPushed = false
	end
	if clipState ~= nil then
		render.EnableClipping(clipState)
		clipState = nil
	end
	if targetPushed then
		render.PopRenderTarget()
		targetPushed = false
	end
	if toneState then
		render.SetToneMappingScaleLinear(toneState)
		toneState = nil
	end
	V.RenderingReplacement = false
	backgroundPlane = nil
	V.ComposingTerrain = false
	composing = false
	V.MaskInSkybox = false
	backgroundContext = nil
	if render.DepthRange then
		render.DepthRange(0, 1)
	end
	render.OverrideColorWriteEnable(false)
	render.OverrideAlphaWriteEnable(false)
	render.OverrideDepthEnable(false)
	render.OverrideBlend(false)
	render.SuppressEngineLighting(false)
	render.ResetModelLighting(1, 1, 1)
	render.SetLocalModelLights()
	render.SetBlend(1)
	render.SetColorModulation(1, 1, 1)
	cam.IgnoreZ(false)
	stencilDefaults()
end

local function volumeMask(eye)
	render.ClearStencil()
	render.SetStencilEnable(true)
	render.SetStencilWriteMask(255)
	render.SetStencilTestMask(255)
	render.SetStencilReferenceValue(1)
	render.SetStencilCompareFunction(STENCILCOMPARISONFUNCTION_ALWAYS)
	render.SetStencilPassOperation(STENCILOPERATION_REPLACE)
	render.SetStencilFailOperation(STENCILOPERATION_KEEP)
	render.SetStencilZFailOperation(STENCILOPERATION_KEEP)
	render.SetMaterial(maskMaterial)
	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, false)
	render.OverrideDepthEnable(true, false)
	-- Exit projection handles cameras crossing an entry/near plane.
	cam.IgnoreZ(true)
	for _, face in ipairs(faces) do
		if V.MaskFaceIsExit(face, eye) then
			drawFace(face)
		end
	end
	cam.IgnoreZ(false)
	render.SetStencilReferenceValue(0)
	render.SetStencilPassOperation(STENCILOPERATION_KEEP)
	render.SetStencilZFailOperation(STENCILOPERATION_REPLACE)
	for _, face in ipairs(faces) do
		if not V.MaskFaceIsExit(face, eye) then
			drawFace(face)
		end
	end
	render.SetStencilZFailOperation(STENCILOPERATION_KEEP)
	render.OverrideColorWriteEnable(false)
	render.OverrideAlphaWriteEnable(false)
	render.OverrideDepthEnable(false)
	render.SetStencilReferenceValue(1)
	render.SetStencilCompareFunction(STENCILCOMPARISONFUNCTION_EQUAL)
end

local function ensureTarget(index, w, h)
	local slot = targets[index]
	if slot and slot.w == w and slot.h == h then
		return slot
	end
	local name = "vm_background_hdr_v4_" .. index .. "_" .. w .. "x" .. h
	local rt = GetRenderTargetEx(
		name,
		w,
		h,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_SEPARATE,
		12,
		0,
		IMAGE_FORMAT_RGBA16161616F or IMAGE_FORMAT_RGBA8888
	)
	slot = {
		w = w,
		h = h,
		target = rt,
		material = CreateMaterial(name .. "_mat", "UnlitGeneric", {
			["$basetexture"] = rt:GetName(),
			["$ignorez"] = "1",
			["$nocull"] = "1",
			["$gammacolorread"] = IMAGE_FORMAT_RGBA16161616F and "1" or "0",
		}),
	}
	targets[index] = slot
	return slot
end

local function activateWorldClip()
	if not backgroundPlane or clipPushed or V.MaskInSkybox then
		return
	end
	render.PushCustomClipPlane(backgroundPlane.normal, backgroundPlane.distance)
	clipPushed = true
end
hook.Add("PreDrawSkyBox", "GVoxel.BackgroundSkyBegin", function()
	if not backgroundPlane then
		return
	end
	if backgroundContext then
		backgroundContext.nativeSky = true
	end
	if clipPushed then
		render.PopCustomClipPlane()
		clipPushed = false
	end
	V.MaskInSkybox = true
end)
hook.Add("PostDrawSkyBox", "GVoxel.BackgroundSkyEnd", function()
	if not backgroundPlane then
		return
	end
	V.MaskInSkybox = false
	activateWorldClip()
end)
hook.Add("PostDraw2DSkyBox", "GVoxel.Background2DSky", function()
	if backgroundContext then
		backgroundContext.nativeSky = true
	end
	activateWorldClip()
end)
hook.Add("SetupWorldFog", "GVoxel.BackgroundWorldClip", activateWorldClip)

hook.Add("PostDrawOpaqueRenderables", "GVoxel.ExteriorMissingContent", function(depth, _, sky3D)
	if not backgroundContext or depth or sky3D then
		return
	end
	if not backgroundContext.nativeSky and V.DrawVoxelSky then
		V.DrawVoxelSky(backgroundContext.view, backgroundContext.sky)
	end
	redrawExterior(backgroundContext)
end)

local function renderBackground(portal, view, slot)
	V.RenderingReplacement = true
	-- One sky-camera view shared by all exits in the same frame. Its own
	-- separate depth target must finish before this exit target is pushed.
	local sky
	if region.revision > 0 and portal.sky3D and V.PrepareVoxelSky then
		local leaf = region.bsp and V.BSPLeaf(region.bsp, view.origin)
		if not leaf or leaf.solid or bit.band(leaf.flags or 0, 5) == 0 then
			sky = V.PrepareVoxelSky(region, view)
		end
	end
	if render.GetToneMappingScaleLinear and render.SetToneMappingScaleLinear then
		toneState = render.GetToneMappingScaleLinear()
	end
	if toneState then
		render.SetToneMappingScaleLinear(Vector(1, toneState.y, toneState.z))
	end
	render.PushRenderTarget(slot.target)
	targetPushed = true
	render.Clear(8, 8, 8, 255, true, true)
	clipState = render.EnableClipping(true)
	-- Start with NO world plane: 2D/3D skyboxes use a different coordinate
	-- space. Hooks install it only after the sky has finished drawing.
	backgroundPlane = { normal = portal.face.normal, distance = portal.face.normal:Dot(portal.face.point) + 0.02 }
	backgroundContext =
		{ view = view, sky = sky, frustum = V.PortalFrustum(V.ViewFrustum(view, view.w, view.h), portal) }
	render.RenderView(view)
	backgroundContext = nil
	if clipPushed then
		render.PopCustomClipPlane()
		clipPushed = false
	end
	backgroundPlane = nil
	V.MaskInSkybox = false
	render.EnableClipping(clipState)
	clipState = nil
	render.PopRenderTarget()
	targetPushed = false
	if toneState then
		render.SetToneMappingScaleLinear(toneState)
		toneState = nil
	end
	V.RenderingReplacement = false
	stats.passes = stats.passes + 1
	slot.origin = Vector(view.origin.x, view.origin.y, view.origin.z)
	slot.forward = view.angles:Forward()
	slot.right = view.angles.Right and view.angles:Right() or nil
	slot.fov = view.fov
	slot.aspect = view.aspect
	slot.znear = view.znear
	slot.zfar = view.zfar
	slot.renderedAt = RealTime()
	slot.portal = portal
	if render.GetToneMappingScaleLinear then
		local tone = render.GetToneMappingScaleLinear()
		slot.tone = Vector(tone.x, tone.y, tone.z)
	end
end

local function cachedBackground(slot, portal, view)
	if slot.portal ~= portal or not slot.origin or RealTime() - (slot.renderedAt or 0) > 1 / 30 then
		return false
	end
	if slot.origin:DistToSqr(view.origin) > 0.000001 or slot.forward:DistToSqr(view.angles:Forward()) > 1e-12 then
		return false
	end
	if slot.right and slot.right:DistToSqr(view.angles:Right()) > 1e-12 then
		return false
	end
	if slot.tone and slot.tone:DistToSqr(render.GetToneMappingScaleLinear()) > 1e-10 then
		return false
	end
	return slot.fov == view.fov and slot.aspect == view.aspect and slot.znear == view.znear and slot.zfar == view.zfar
end

-- Secondary views finish BEFORE the engine sets up its main world/viewmodel
-- camera. No RenderView call can overwrite that setup during compositing.
hook.Add("RenderScene", "GVoxel.PrepareBackgrounds", function(origin, angles, fov)
	if preparing or V.RenderingReplacement or V.CapturingSurface or not V.VisualReplacementEnabled() then
		return
	end
	if render.GetRenderTarget() ~= nil then
		return
	end
	preparing = true
	stats.passes = 0
	stats.culled = 0
	stats.reused = 0
	stats.native = 0
	local started = SysTime()
	local ok, err = xpcall(function()
		local setup = render.GetViewSetup(true)
		local w, h = ScrW(), ScrH()
		local view = {
			origin = origin,
			angles = angles,
			fov = fov,
			aspect = setup.aspect or setup.aspectratio or w / h,
			x = 0,
			y = 0,
			w = w,
			h = h,
			znear = setup.znear,
			zfar = setup.zfar,
			viewmodelfov = setup.fovviewmodel or setup.viewmodelfov,
			znearviewmodel = setup.znearviewmodel,
			zfarviewmodel = setup.zfarviewmodel,
			drawviewmodel = false,
			drawhud = false,
			drawmonitors = false,
			dopostprocess = false,
			bloomtone = false,
			-- A monitor view must not regenerate the MAIN SSAO/depth and
			-- screen-effect textures once per aperture.
			viewid = VIEW_MONITOR or 2,
			drawviewer = LocalPlayer():ShouldDrawLocalPlayer(),
		}
		local frustum = V.ViewFrustum(view, w, h)
		frameViews = {
			frame = FrameNumber(),
			region = region,
			origin = origin,
			angles = angles,
			fov = fov,
			slots = {},
			native = {},
		}
		if not V.BoundsInView(frustum, region.origin, region.origin + V.RegionSize(region)) then
			return
		end
		for _, portal in ipairs(portals) do
			if V.MaskFaceIsExit(portal.face, origin) then
				if V.BoundsInView(frustum, portal.low, portal.high) then
					if not V.PortalNeedsBackground(nativeBackground, portal, frustum) then
						frameViews.native[portal] = true
						stats.native = stats.native + 1
					else
						local slot = ensureTarget(portal.slot, w, h)
						if cachedBackground(slot, portal, view) then
							stats.reused = stats.reused + 1
						else
							renderBackground(portal, view, slot)
						end
						frameViews.slots[portal] = slot
					end
				else
					stats.culled = stats.culled + 1
				end
			end
		end
	end, debug.traceback)
	cleanup()
	stats.backgroundMS = (SysTime() - started) * 1000
	preparing = false
	if not ok then
		failure = err
		frameViews = nil
		ErrorNoHalt("[GVoxel] Vue exterieure : " .. tostring(err) .. "\n")
	end
end)

local function markOpening(portal)
	render.SetStencilReferenceValue(1)
	render.SetStencilCompareFunction(STENCILCOMPARISONFUNCTION_EQUAL)
	render.SetStencilPassOperation(STENCILOPERATION_INCRSAT)
	render.SetStencilFailOperation(STENCILOPERATION_KEEP)
	render.SetStencilZFailOperation(STENCILOPERATION_KEEP)
	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, false)
	render.OverrideDepthEnable(true, false)
	render.SetMaterial(maskMaterial)
	-- Depth-test against the newly drawn voxel surface, never IgnoreZ.
	-- A portal behind terrain must not overwrite that terrain.
	V.DrawMesh(portal.mesh)
	render.OverrideColorWriteEnable(false)
	render.OverrideAlphaWriteEnable(false)
	render.OverrideDepthEnable(false)
end

local function preserveNativeBackgrounds()
	-- Native air rays already contain the correct color AND real world depth.
	-- Mark them 3 before clearing the old solid. No copy, RT or extra view.
	render.SetStencilTestMask(1)
	render.SetStencilReferenceValue(3)
	render.SetStencilCompareFunction(STENCILCOMPARISONFUNCTION_EQUAL)
	render.SetStencilPassOperation(STENCILOPERATION_REPLACE)
	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, false)
	render.OverrideDepthEnable(true, false)
	render.SetMaterial(maskMaterial)
	-- volumeMask already excludes foreground outside the cube. Keep native
	-- props inside it as well, even when their depth is before the exit plane.
	cam.IgnoreZ(true)
	for portal in pairs(frameViews.native) do
		V.DrawMesh(portal.mesh)
	end
	cam.IgnoreZ(false)
	render.OverrideDepthEnable(false)
	render.OverrideColorWriteEnable(false)
	render.OverrideAlphaWriteEnable(false)
	render.SetStencilTestMask(255)
	render.SetStencilReferenceValue(1)
end

local function sealBackgroundDepth(portal)
	-- RenderView already contains exterior translucency, decals and shadows.
	-- The color copy carries no depth. Leaving infinity here lets the main
	-- scene draw those same exterior effects a SECOND time over the image.
	-- Seal only the filled stencil pixels at the exit plane: interior effects
	-- in front of it remain visible, exterior effects belong to the RT view.
	render.OverrideColorWriteEnable(true, false)
	render.OverrideAlphaWriteEnable(true, false)
	render.OverrideDepthEnable(true, true)
	render.SetMaterial(maskMaterial)
	V.DrawMesh(portal.mesh)
	render.OverrideDepthEnable(false)
	render.OverrideColorWriteEnable(false)
	render.OverrideAlphaWriteEnable(false)
end

local function renderNative()
	stats.terrain = 0
	stats.chunks = 0
	local setup = render.GetViewSetup(true)
	local w, h = setup.width or setup.w or ScrW(), setup.height or setup.h or ScrH()
	local frustum = V.ViewFrustum(setup, w, h)
	if not V.BoundsInView(frustum, region.origin, region.origin + V.RegionSize(region)) then
		return
	end
	if not frameViews or frameViews.frame ~= FrameNumber() or frameViews.region ~= region then
		return
	end
	local eye = setup.origin
	if eye:DistToSqr(frameViews.origin) > 0.01 then
		return
	end
	volumeMask(eye)
	preserveNativeBackgrounds()
	render.SetStencilPassOperation(STENCILOPERATION_KEEP)
	-- This is the key step used by Mineable Worlds: discard the old surface
	-- depth locally, then write real terrain depth in the current camera.
	render.ClearBuffersObeyStencil(8, 8, 8, 255, true)
	-- Both 1 (cleared solid) and 3 (native air) receive new voxel geometry.
	-- In particular, adding matter must still occlude preserved scenery.
	render.SetStencilTestMask(1)
	drawTerrain(frustum)
	redrawEntities()
	render.SetStencilTestMask(255)
	for _, portal in ipairs(portals) do
		if V.MaskFaceIsExit(portal.face, eye) then
			local slot = frameViews.slots[portal]
			if slot and V.BoundsInView(frustum, portal.low, portal.high) then
				markOpening(portal)
				render.SetStencilReferenceValue(2)
				render.SetStencilCompareFunction(STENCILCOMPARISONFUNCTION_EQUAL)
				render.SetStencilPassOperation(STENCILOPERATION_KEEP)
				render.ClearBuffersObeyStencil(8, 8, 8, 255, true)
				render.OverrideDepthEnable(true, false)
				render.SetMaterial(slot.material)
				render.DrawScreenQuad()
				render.OverrideDepthEnable(false)
				sealBackgroundDepth(portal)
				-- Claim only pixels that were just filled. Later openings
				-- cannot paint the same pixel, regardless of traversal order.
				render.SetStencilPassOperation(STENCILOPERATION_INCRSAT)
				render.PerformFullScreenStencilOperation()
			end
		end
	end
end

hook.Add("PostDrawOpaqueRenderables", "GVoxel.ReplaceNativeTerrain", function(depth, _, sky3D)
	if depth or sky3D or composing or V.RenderingReplacement or not V.VisualReplacementEnabled() then
		return
	end
	if halo and halo.RenderedEntity and IsValid(halo.RenderedEntity()) then
		return
	end
	if render.GetRenderTarget() ~= nil then
		return
	end
	composing = true
	V.ComposingTerrain = true
	local started = SysTime()
	local ok, err = xpcall(renderNative, debug.traceback)
	cleanup()
	stats.ms = (SysTime() - started) * 1000 + (stats.backgroundMS or 0)
	if not ok then
		failure = err
		ErrorNoHalt("[GVoxel] Rendu du terrain desactive : " .. tostring(err) .. "\n")
		chat.AddText(Color(255, 160, 80), "[GVoxel] Erreur de rendu : details dans la console.")
	end
end)

hook.Add("PostDrawTranslucentRenderables", "GVoxel.NativeBrush", function(depth, _, sky3D)
	if depth or sky3D or composing or V.RenderingReplacement or not V.VisualReplacementEnabled() then
		return
	end
	if halo and halo.RenderedEntity and IsValid(halo.RenderedEntity()) then
		return
	end
	if render.GetRenderTarget() ~= nil then
		return
	end
	if V.DrawBrushPreview then
		V.DrawBrushPreview(true)
	end
end)

-- The engine halo module stores the scene in GLOBAL screen-effect textures.
-- Running it from nested RenderView overwrites the physgun's main scene copy.
-- Scope the stock hook, keeping its pending halo list for the actual main view.
local function protectHalos()
	local events = hook.GetTable and hook.GetTable()
	local native = events and events.PostDrawEffects and events.PostDrawEffects.RenderHalos
	if not native or V.ProtectedHaloHook then
		return
	end
	V.NativeHaloHook = native
	V.ProtectedHaloHook = function(...)
		if V.RenderingReplacement or V.CapturingSurface or V.ComposingTerrain then
			return
		end
		return V.NativeHaloHook(...)
	end
	hook.Add("PostDrawEffects", "RenderHalos", V.ProtectedHaloHook)
end
protectHalos()
hook.Add("Think", "GVoxel.ProtectNativeHalos", protectHalos)
hook.Add("ShutDown", "GVoxel.RestoreNativeHalos", function()
	local events = hook.GetTable and hook.GetTable()
	if
		V.ProtectedHaloHook
		and events
		and events.PostDrawEffects
		and events.PostDrawEffects.RenderHalos == V.ProtectedHaloHook
	then
		hook.Add("PostDrawEffects", "RenderHalos", V.NativeHaloHook)
	end
end)

hook.Add("ShutDown", "GVoxel.FreeOpenings", freePortals)
concommand.Add("vm_render_stats", function()
	local state = failure and "erreur" or (not V.VisualReplacementEnabled() and "inactif" or "voxel")
	print(
		string.format(
			"[GVoxel] Rendu: %s | passes terrain: %d | vues d'ouverture: %d | ouvertures: %d | %.2f ms CPU | chunks visibles: %d | vues ecartees: %d | vues reutilisees: %d | sorties natives: %d | exterieur %.2f ms CPU",
			state,
			stats.terrain,
			stats.passes,
			stats.openings,
			stats.ms,
			stats.chunks,
			stats.culled,
			stats.reused,
			stats.native,
			stats.backgroundMS or 0
		)
	)
	print(
		string.format(
			"[GVoxel] Visibilite exterieure : %d rayons / %.3f ms CPU | %d preuves reutilisees | %d modeles masques | %d controles reportes (derniere image calculee)",
			stats.exteriorTraces or 0,
			stats.exteriorTraceMS or 0,
			stats.exteriorCached or 0,
			stats.exteriorHidden or 0,
			stats.exteriorDeferred or 0
		)
	)
end)
