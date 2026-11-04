-- Tool cursor for the scanned BSP; no separate demo terrain/network queue.
local V = GVoxel
local showCursor = CreateClientConVar("vm_show_cursor", "1", true, false, "Afficher le viseur de creusement", 0, 1)
local brushMaterial = CreateMaterial("vm_brush_v1", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$vertexcolor"] = "1",
	["$vertexalpha"] = "1",
})
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
	if tr.VoxelScan then
		radius = V.ScanBrushRadius(region, radius)
	end
	local adding = ply:KeyDown(IN_ATTACK2)
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
	render.DrawWireframeSphere(center, radius, 16, 12, color, not (onTop and tr.VoxelScan))
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
