-- A short-lived native contact at an actual terrain impact. This lets native
-- Touch handlers own detonation, sticking, damage and launcher reload.
AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.Spawnable = false
function ENT:Initialize()
	self:SetNoDraw(true)
	self:DrawShadow(false)
	if SERVER then
		self:SetModel("models/props_junk/PopCan01a.mdl")
		self:SetMoveType(MOVETYPE_NONE)
		self:SetSolid(SOLID_BBOX)
		self:SetCollisionBounds(Vector(-0.5, -0.5, -0.5), Vector(0.5, 0.5, 0.5))
		self:SetCustomCollisionCheck(true)
	end
end
function ENT:UpdateTransmitState()
	return TRANSMIT_NEVER
end
if CLIENT then
	function ENT:Draw() end
end
