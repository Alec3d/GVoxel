-- Tool permissions and entry points for the scanned BSP only.
local V = GVoxel
function V.CanManageScan(ply)
	return IsValid(ply) and ply:IsPlayer() and ply:IsAdmin()
end
function V.CanEdit(ply, region)
	return V.CanManageScan(ply)
end
hook.Add("PlayerCanPickupWeapon","GVoxel.AdminToolPickup",function(ply,weapon)
    if V.IsVoxelTool(weapon) and not V.CanManageScan(ply) then return false end
end)
function V.Notify(ply, message)
	if IsValid(ply) then
		local code = ply.GetInfo and ply:GetInfo("gvoxel_language") or "en"
		ply:ChatPrint("[GVoxel] " .. (V.Localize and V.Localize(message, code) or message))
	end
end
function V.BrushIntersectsBody(center, radius)
	for _, ent in ipairs(ents.FindInSphere(center, radius + 128)) do
		if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:GetMoveType() == MOVETYPE_VPHYSICS then
			local lo, hi = ent:WorldSpaceAABB()
			local nearest = Vector(
				math.Clamp(center.x, lo.x, hi.x),
				math.Clamp(center.y, lo.y, hi.y),
				math.Clamp(center.z, lo.z, hi.z)
			)
			if nearest:DistToSqr(center) < (radius + 4) ^ 2 then
				return true
			end
		end
	end
	return false
end
function V.Edit(ply, radius, adding)
	local result = V.EditScannedTerrain and V.EditScannedTerrain(ply, radius, adding)
	if result == nil then
		V.Notify(ply, "Analyse d'abord une zone BSP avec un appui court sur R.")
	end
	return result or false
end
concommand.Add("vm_give", function(ply)
	if not V.CanEdit(ply, V.GetServerScanRegion and V.GetServerScanRegion()) then
		return
	end
	ply:Give("weapon_voxel_crowbar")
	ply:SelectWeapon("weapon_voxel_crowbar")
end)
concommand.Add("vm_clear", function(ply)
	if V.CanManageScan(ply) and V.CancelScan then
		V.CancelScan(ply)
	end
end)
