if SERVER then
	AddCSLuaFile()
end

SWEP.Base = "weapon_base"
SWEP.PrintName = CLIENT and "#gvoxel.tool_name" or "Voxel crowbar"
SWEP.Author = "GVoxel"
SWEP.Instructions = CLIENT and "#gvoxel.tool_instructions" or "Left: dig | Right: add | R: scan / menu | Middle click: custom box points"
SWEP.Category = "GVoxel"
SWEP.Spawnable = true
SWEP.AdminOnly = true
SWEP.UseHands = true
SWEP.ViewModel = "models/weapons/c_crowbar.mdl"
SWEP.WorldModel = "models/weapons/w_crowbar.mdl"
SWEP.ViewModelFOV = 60
SWEP.HoldType = "melee"
SWEP.Slot = 0
SWEP.SlotPos = 5
SWEP.DrawAmmo = false
SWEP.Primary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }

function SWEP:SetupDataTables()
	self:NetworkVar("Int", 0, "BrushRadius")
	self:NetworkVar("Int", 1, "ZoneMetres")
end

function SWEP:Initialize()
	self:SetHoldType("melee")
	if SERVER then
		self:SetBrushRadius(48)
		self:SetZoneMetres(16)
	end
end

function SWEP:Deploy()
    if SERVER and not GVoxel.CanManageScan(self:GetOwner()) then return false end
	self:SendWeaponAnim(ACT_VM_DRAW)
	return true
end

function SWEP:Equip(ply)
    if SERVER and not GVoxel.CanManageScan(ply) then self:Remove() end
end

function SWEP:Sculpt(adding)
	self:SetNextPrimaryFire(CurTime() + 0.25)
	self:SetNextSecondaryFire(CurTime() + 0.25)
	local owner = self:GetOwner()
	if not IsValid(owner) or not owner:IsPlayer() then
		return
	end
	if CLIENT then
		return
	end
	local changed = GVoxel.Edit(owner, self:GetBrushRadius(), adding)
	if changed then
		self:SendWeaponAnim(ACT_VM_HITCENTER)
		owner:SetAnimation(PLAYER_ATTACK1)
		self:EmitSound("Weapon_Crowbar.Melee_Hit", 65, adding and 110 or 90)
	else
		self:SendWeaponAnim(ACT_VM_MISSCENTER)
	end
end

function SWEP:PrimaryAttack()
	self:Sculpt(false)
end
function SWEP:SecondaryAttack()
	self:Sculpt(true)
end

-- Reload is intentionally inert: the client classifies the press on release.
-- Server validation and all world queries remain in sv_scan.lua.
function SWEP:Reload() end

function SWEP:Holster()
	if CLIENT and GVoxel.CloseScanMenu then
		GVoxel.CloseScanMenu(false)
	end
	return true
end

if CLIENT then
	function SWEP:DrawHUD()
		local region = GVoxel.GetClientScanRegion()
		local tr = GVoxel.TraceSculptPreview(LocalPlayer(), region, GVoxel.Reach)
		local valid = tr.VoxelScan
		local radius = region and GVoxel.ScanBrushRadius(region, self:GetBrushRadius()) or self:GetBrushRadius()
		local message = valid and GVoxel.L("Gauche : creuser    Droite : ajouter")
			or GVoxel.L("R court : analyser le BSP    |    R maintenu : dimensions")
		local custom = GVoxel.CustomBlockEnabled()
		if custom then
			message = GVoxel.CustomBlockStatus()
		end
		local x, y = ScrW() / 2, ScrH() - 140
		draw.SimpleTextOutlined(
			message,
			"Trebuchet24",
			x,
			y,
			Color(255, 235, 205),
			TEXT_ALIGN_CENTER,
			TEXT_ALIGN_CENTER,
			1,
			Color(0, 0, 0, 220)
		)
		local detail = custom and GVoxel.L("Custom block | R maintenu : menu / annuler les points")
			or GVoxel.L("Zone : ")
				.. GVoxel.SelectedMetres()
				.. GVoxel.L(" m de cote    |    Rayon : ")
				.. radius
				.. GVoxel.L("    |    Zone partagee")
		draw.SimpleTextOutlined(
			detail,
			"Trebuchet18",
			x,
			y + 28,
			color_white,
			TEXT_ALIGN_CENTER,
			TEXT_ALIGN_CENTER,
			1,
			Color(0, 0, 0, 220)
		)
	end
end
