-- Sky backdrop for eyes excavated into original BSP solid, where Source skips
-- its sky pass. Geometry/depth of the real scene stays in front of this layer.
local V = GVoxel
local materials, nameCache, skyTarget, skyMaterial, skyView, rendering, skySettings
local failed = setmetatable({}, { __mode = "k" })
local stats = { views = 0, cubes = 0, missing = 0 }
local sides = {
	{ "rt", Vector(1, 0, 0), 180 },
	{ "lf", Vector(-1, 0, 0), 180 },
	{ "bk", Vector(0, 1, 0), 180 },
	{ "ft", Vector(0, -1, 0), 180 },
	{ "up", Vector(0, 0, 1), 0 },
	{ "dn", Vector(0, 0, -1), 0 },
}
local function skyMaterials()
	local setting = GetConVar and GetConVar("sv_skyname")
	local name = setting and setting:GetString()
	if not name or name == "" then
		return
	end
	if nameCache == name then
		return materials
	end
	materials = {}
	nameCache = name
	for _, side in ipairs(sides) do
		local source = Material("skybox/" .. name .. side[1])
		if not source:IsError() then
			local material = source
			if source:GetShader() ~= "g_sky" then
				local texture = source:GetTexture("$basetexture")
				if texture and not texture:IsError() then
					local w, h = texture:Width(), texture:Height()
					local inset = math.max(0.5, 1 - 1 / math.max(1, w))
					local transform = string.format("center 0.5 0.5 scale %g %g rotate 0 translate 0 0", inset, inset)
					if w ~= h then
						transform = string.format(
							"center 0.5 0 scale %g %g rotate 0 translate 0 %g",
							inset,
							w / math.max(1, h) * inset,
							1 - inset
						)
					end
					material = CreateMaterial("vm_sky_" .. util.CRC(name) .. "_" .. side[1], "UnlitGeneric", {
						["$basetexture"] = texture:GetName(),
						["$basetexturetransform"] = transform,
						["$nocull"] = "1",
						["$nofog"] = "1",
					})
				else
					material = nil
				end
			end
			if material then
				materials[#materials + 1] = { material = material, direction = side[2], rotation = side[3] }
			end
		end
	end
	stats.missing = 6 - #materials
	return materials
end
local function cube(view)
	local list = skyMaterials()
	if not list or #list == 0 then
		return
	end
	local distance = (view.zfar or 30000) * 0.45
	for _, side in ipairs(list) do
		render.SetMaterial(side.material)
		render.DrawQuadEasy(
			view.origin + side.direction * distance,
			-side.direction,
			distance * 2,
			distance * 2,
			color_white,
			side.rotation
		)
	end
	stats.cubes = stats.cubes + 1
end
function V.DrawVoxelSky(view, texture)
	local oldClip = render.EnableClipping(false)
	render.OverrideDepthEnable(true, false)
	render.DepthRange(0.999999, 1)
	render.SetColorModulation(1, 1, 1)
	if texture then
		skyMaterial:SetTexture("$basetexture", texture)
		local forward, right, up = view.angles:Forward(), view.angles:Right(), view.angles:Up()
		local d = (view.zfar or 30000) * 0.45
		local width = d * math.tan(math.rad(view.fov) / 2)
		local height = width / view.aspect
		local center = view.origin + forward * d
		render.SetMaterial(skyMaterial)
		render.DrawQuad(
			center - right * width + up * height,
			center + right * width + up * height,
			center + right * width - up * height,
			center - right * width - up * height,
			color_white
		)
	else
		cube(view)
	end
	render.DepthRange(0, 1)
	render.OverrideDepthEnable(false)
	render.EnableClipping(oldClip)
end
function V.VoxelSkyView(r, view)
	local camera = r.bsp and r.bsp.sky and r.bsp.sky.camera
	if not camera then
		return
	end
	return {
		origin = camera.origin + view.origin / camera.scale,
		angles = view.angles,
		fov = view.fov,
		aspect = view.aspect,
		x = 0,
		y = 0,
		w = view.w,
		h = view.h,
		znear = 1,
		zfar = 56756,
		viewid = VIEW_3DSKY or 1,
		drawviewmodel = false,
		drawhud = false,
		drawmonitors = false,
		drawviewer = false,
		dopostprocess = false,
		bloomtone = false,
	}
end
function V.PrepareVoxelSky(r, view)
	local sky = V.VoxelSkyView(r, view)
	if not sky or rendering then
		return
	end
	if not skyTarget or skyTarget.w ~= view.w or skyTarget.h ~= view.h then
		local tag = view.w .. "x" .. view.h
		local target = GetRenderTargetEx(
			"vm_sky3d_hdr_" .. tag,
			view.w,
			view.h,
			RT_SIZE_LITERAL,
			MATERIAL_RT_DEPTH_SEPARATE,
			12,
			0,
			IMAGE_FORMAT_RGBA16161616F or IMAGE_FORMAT_RGBA8888
		)
		skyTarget = { target = target, w = view.w, h = view.h }
		skyMaterial = CreateMaterial("vm_sky3d_hdr_material_" .. tag, "UnlitGeneric", {
			["$basetexture"] = target:GetName(),
			["$nofog"] = "1",
			["$nocull"] = "1",
			["$gammacolorread"] = IMAGE_FORMAT_RGBA16161616F and "1" or "0",
		})
	end
	local frame = FrameNumber()
	if failed[r] then
		return
	end
	if
		skyTarget.frame == frame
		and skyTarget.origin:DistToSqr(sky.origin) < 1e-10
		and skyTarget.forward:DistToSqr(sky.angles:Forward()) < 1e-10
		and skyTarget.fov == view.fov
		and skyTarget.aspect == view.aspect
	then
		return skyTarget.target
	end
	local oldReplacement = V.RenderingReplacement
	local tone = render.GetToneMappingScaleLinear()
	local oldClip = render.EnableClipping(false)
	local pushed = false
	rendering = true
	skyView = sky
	skySettings = r.bsp.sky.camera
	V.RenderingReplacement = true
	local ok, err = xpcall(function()
		render.SetToneMappingScaleLinear(Vector(1, tone.y, tone.z))
		render.PushRenderTarget(skyTarget.target)
		pushed = true
		render.Clear(0, 0, 0, 255, true, true)
		render.RenderView(sky)
	end, debug.traceback)
	if pushed then
		render.PopRenderTarget()
	end
	render.DepthRange(0, 1)
	render.OverrideDepthEnable(false)
	render.EnableClipping(oldClip)
	render.SetToneMappingScaleLinear(tone)
	rendering = false
	skyView = nil
	skySettings = nil
	V.RenderingReplacement = oldReplacement
	if not ok then
		failed[r] = true
		ErrorNoHalt("[GVoxel] Ciel 3D : " .. tostring(err) .. "\n")
		return
	end
	skyTarget.frame = frame
	skyTarget.origin = sky.origin
	skyTarget.forward = sky.angles:Forward()
	skyTarget.fov = view.fov
	skyTarget.aspect = view.aspect
	stats.views = stats.views + 1
	return skyTarget.target
end
hook.Add("PostDrawOpaqueRenderables", "GVoxel.SkyCameraBackdrop", function(depth, _, sky3D)
	if rendering and not depth and not sky3D then
		V.DrawVoxelSky(skyView)
	end
end)
hook.Add("SetupWorldFog", "GVoxel.SkyCameraFog", function()
	if not rendering then
		return
	end
	local settings = skySettings
	local fog = settings and settings.fog
	if not fog or not fog.enabled then
		render.FogMode(MATERIAL_FOG_NONE or 0)
		return true
	end
	render.FogMode(MATERIAL_FOG_LINEAR or 1)
	render.FogStart(fog.start / settings.scale)
	render.FogEnd(fog.finish / settings.scale)
	render.FogColor(fog.red, fog.green, fog.blue)
	render.FogMaxDensity(math.max(0, math.min(1, fog.density)))
	return true
end)
concommand.Add("vm_sky_stats", function()
	print(
		string.format(
			"[GVoxel] Ciel : %d vues 3D ; %d fonds ; %d textures manquantes.",
			stats.views,
			stats.cubes,
			stats.missing
		)
	)
end)
