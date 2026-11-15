-- Tool cursor for the scanned BSP; no separate demo terrain/network queue.
local V = GVoxel
local showCursor = CreateClientConVar("vm_show_cursor", "1", true, false, "Afficher le viseur de creusement", 0, 1)
local brushMaterial = CreateMaterial("vm_brush_v1", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$vertexcolor"] = "1",
	["$vertexalpha"] = "1",
})
local function drawShape(center, shape, radius, color, depth)
	local x,y,z,ring=V.BrushShapeDimensions(shape,radius)
	local id=shape[1]
	if id==2 then
		render.DrawWireframeBox(center,angle_zero,Vector(-x,-y,-z),Vector(x,y,z),color,depth)
		return
	end
	local segments=id==5 and 4 or 20
	local phase=id==5 and math.pi/4 or 0
	local scale=id==5 and math.sqrt(2) or 1
	local function point(index,rx,ry,height)
		local angle=index*math.pi*2/segments+phase
		return center+Vector(math.cos(angle)*rx,math.sin(angle)*ry,height)
	end
	for i=0,segments-1 do
		if id==6 then
			for _, band in ipairs({{x,0},{ring-z,0},{ring,z},{ring,-z}}) do
				render.DrawLine(point(i,band[1],band[1],band[2]),point(i+1,band[1],band[1],band[2]),color,depth)
			end
		else
			local bottom=point(i,x*scale,y*scale,-z)
			render.DrawLine(bottom,point(i+1,x*scale,y*scale,-z),color,depth)
			if id==3 then
				local top=point(i,x,y,z)
				render.DrawLine(top,point(i+1,x,y,z),color,depth)
				if i%5==0 then render.DrawLine(bottom,top,color,depth) end
			elseif id==5 or i%5==0 then
				render.DrawLine(bottom,center+Vector(0,0,z),color,depth)
			end
		end
	end
end

function V.DrawBrushPreview(onTop)
	if not showCursor:GetBool() then
		return
	end
	local ply = LocalPlayer()
	if not IsValid(ply) then
		return
	end
	local weapon = ply:GetActiveWeapon()
	if not V.IsVoxelTool(weapon) then
		return
	end
	local region = V.GetClientScanRegion and V.GetClientScanRegion()
	local tr = V.TraceSculptPreview(ply, region, V.Reach)
	if not tr.Hit or tr.HitSky then
		return
	end
	local valid = tr.VoxelScan
	local radius = weapon:GetBrushRadius()
	if radius < 24 then
		radius = 48
	end
	local adding = ply:KeyDown(IN_ATTACK2)
	if tr.VoxelScan then
		radius = V.ScanBrushRadius(region, radius, adding and V.GetAddPower and V.GetAddPower())
	end
	local center = V.BrushCenter(tr, radius, adding)
	if tr.VoxelScan then
		center = V.SnapScanPosition(center)
	end
	local color = valid and (adding and Color(80, 200, 255, 230) or Color(255, 170, 60, 230)) or Color(255, 75, 75, 220)
	render.SetMaterial(brushMaterial)
	-- This is an aiming overlay, drawn after compositing so the hidden BSP
	-- depth cannot swallow the cursor inside an excavated voxel cavity.
	cam.IgnoreZ(onTop and tr.VoxelScan or false)
	render.OverrideDepthEnable(true, false)
	local depth = not (onTop and tr.VoxelScan)
	local shape = V.GetLocalBrushShape and V.GetLocalBrushShape()
	if shape then drawShape(center,shape,radius,color,depth)
	else render.DrawWireframeSphere(center,radius,16,12,color,depth) end
	render.DrawLine(tr.HitPos, tr.HitPos + tr.HitNormal * 24, color, not (onTop and tr.VoxelScan))
	render.OverrideDepthEnable(false)
	cam.IgnoreZ(false)
end

hook.Add("PostDrawTranslucentRenderables", "GVoxel.BrushPreview", function(depth, _, sky3D)
	if depth or sky3D or V.MaskInSkybox or V.RenderingReplacement or V.ComposingTerrain then
		return
	end
	if V.VisualReplacementEnabled and V.VisualReplacementEnabled() then
		return
	end
	V.DrawBrushPreview(false)
end)
