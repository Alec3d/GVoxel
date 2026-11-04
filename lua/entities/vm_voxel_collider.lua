AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Voxel terrain collision"
ENT.Spawnable = false
function ENT:Initialize()
	self:SetNoDraw(true)
	self:DrawShadow(false)
	if SERVER then
		self:SetModel("models/props_junk/PopCan01a.mdl")
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_NONE)
		self:SetCustomCollisionCheck(true)
	end
end
function ENT:UpdateTransmitState()
	return TRANSMIT_NEVER
end
-- Use the cooked triangles for native ray contacts too. Inactive staging and
-- the cage guard must never become phantom suspension ground.
function ENT:TestCollision()
	if self.VMActive and not self.VMGuard then
		return true
	end
	return false
end
if CLIENT then
	function ENT:Draw() end
end
