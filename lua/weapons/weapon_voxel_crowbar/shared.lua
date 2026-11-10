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
	local hudBackground = Color(18, 24, 34, 220)
	local hudAccent = Color(255, 151, 62)
	local function binding(command, fallback)
		return string.upper(input.LookupBinding(command) or fallback)
	end

	function SWEP:DrawHUD()
		local region = GVoxel.GetClientScanRegion()
		local action
		if GVoxel.CustomBlockEnabled() then
			action = GVoxel.CustomBlockStatus()
		elseif region then
			action = binding("+attack", "Mouse1") .. " / " .. binding("+attack2", "Mouse2")
				.. "  ·  " .. GVoxel.L("Gauche : creuser    Droite : ajouter")
		else
			action = binding("+reload", "R") .. "  ·  " .. GVoxel.L("R court : analyser le BSP    |    R maintenu : dimensions")
		end
		local hint = GVoxel.L("Ctrl+H avec l'outil en main")
		surface.SetFont("Trebuchet18")
		local w = math.max(surface.GetTextSize(action), surface.GetTextSize(hint)) + 30
		local x, y = math.max(8, (ScrW() - w) / 2), ScrH() - 109
		draw.RoundedBox(7, x, y, w, 52, hudBackground)
		draw.SimpleText(action, "Trebuchet18", x + 15, y + 8, color_white)
		draw.SimpleText(hint, "Trebuchet18", x + 15, y + 29, hudAccent)
	end
end
