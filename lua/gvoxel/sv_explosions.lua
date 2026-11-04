-- Stock weapon_rpg uses rpg_missile -> env_explosion:Explode. Listen to that
-- actual event, including impacts in empty rooms where no entity takes damage.
-- SDK: src/game/server/hl2/weapon_rpg.cpp and src/game/server/explode.cpp.
local V = GVoxel
-- Lua refresh can leave another addon's wrapper holding our previous function.
-- Disable that old layer even if it can no longer be removed from the chain.
if V.ReleaseGlideTankExplosionAdapter then
	V.ReleaseGlideTankExplosionAdapter()
end
local radius = CreateConVar(
	"vm_rpg_crater_radius",
	"112",
	FCVAR_ARCHIVE,
	"Rayon maximum des crateres du RPG, en unites Source",
	48,
	160
)
function V.GetRPGCraterRadius()
	return math.Clamp(radius:GetFloat(), 48, 160)
end
V.NativeExplosionSeen = V.NativeExplosionSeen or setmetatable({}, { __mode = "k" })
local seen = V.NativeExplosionSeen
V.GlideTankExplosionSeen = V.GlideTankExplosionSeen or setmetatable({}, { __mode = "k" })
local glideSeen = V.GlideTankExplosionSeen
local sequence = 0
local slamClasses = { npc_satchel = true, npc_tripmine = true }
local function player(ent)
	return IsValid(ent) and ent.IsPlayer and ent:IsPlayer()
end
local function commonCrater(attacker, position, source)
	sequence = sequence % 65535 + 1
	return V.QueueExplosionCrater(attacker, position, math.floor(V.GetRPGCraterRadius()), sequence, source)
end

local function crater(rocket, attacker, position)
	if not IsValid(rocket) or rocket:GetClass() ~= "rpg_missile" or seen[rocket] then
		return
	end
	seen[rocket] = true
	if not IsValid(attacker) or not attacker:IsPlayer() then
		return
	end
	sequence = sequence % 65535 + 1
	V.QueueRPGCrater(attacker, position, radius:GetFloat(), sequence)
end
local function slamCrater(mine, attacker, position)
	if not IsValid(mine) or not slamClasses[mine:GetClass()] or seen[mine] then
		return
	end
	-- Satchels deliberately clear GetOwner after throwing. The saved thrower
	-- remains the player responsible for the native blast and permissions.
	if not player(attacker) and mine.GetInternalVariable then
		attacker = mine:GetInternalVariable("m_hThrower")
	end
	if not player(attacker) and mine.GetOwner then
		attacker = mine:GetOwner()
	end
	if not player(attacker) then
		return
	end
	seen[mine] = true
	commonCrater(attacker, position, "slam")
end

hook.Add("AcceptInput", "GVoxel.RPGExplosion", function(ent, input)
	if input:lower() ~= "explode" or ent:GetClass() ~= "env_explosion" then
		return
	end
	local rocket = ent:GetInternalVariable("m_hInflictor")
	if IsValid(rocket) and rocket:GetClass() == "rpg_missile" then
		crater(rocket, ent:GetOwner(), ent:GetPos())
	elseif IsValid(rocket) and slamClasses[rocket:GetClass()] then
		slamCrater(rocket, ent:GetOwner(), ent:GetPos())
	end
	-- No return: native damage, effects and other input handlers continue.
end)

-- Compatibility fallback for engine builds which bypass map-input hooks.
-- Every victim of a blast shares its missile; the weak set deduplicates them
-- and the AcceptInput event without retaining removed projectile entities.
hook.Add("EntityTakeDamage", "GVoxel.RPGBlastDamage", function(_, damage)
	if not damage:IsExplosionDamage() then
		return
	end
	local rocket = damage:GetInflictor()
	if IsValid(rocket) and rocket:GetClass() == "rpg_missile" then
		crater(rocket, damage:GetAttacker(), rocket:GetPos())
	elseif IsValid(rocket) and slamClasses[rocket:GetClass()] then
		slamCrater(rocket, damage:GetAttacker(), rocket:GetPos())
	end
end)

-- Both HL2 SLAM modes use CBaseGrenade::Explode, not env_explosion. Its
-- explosion soundscript is emitted even with no damage victim, before removal.
-- Never infer a blast from removal/pickup, arming or the remote detonator sound.
hook.Add("EntityEmitSound", "GVoxel.SLAMExplosion", function(data)
	local mine = data.Entity
	if not IsValid(mine) or not slamClasses[mine:GetClass()] then
		return
	end
	if (data.OriginalSoundName or data.SoundName or ""):lower() ~= "basegrenade.explode" then
		return
	end
	local ok, err = pcall(slamCrater, mine, nil, mine:GetPos())
	if not ok and ErrorNoHalt then
		ErrorNoHalt("[GVoxel] SLAM crater: " .. tostring(err) .. "\n")
	end
	-- No return: the native sound stays unchanged.
end)

-- Glide shells/missiles call CreateExplosion
-- directly, without env_explosion or a guaranteed damage victim. Observe that
-- exact event; removal alone also means sky contact/cleanup, not an explosion.
local function glideCrater(projectile, attacker, position)
	if not IsValid(projectile) or glideSeen[projectile] or not IsValid(attacker) or not attacker:IsPlayer() then
		return
	end
	local class = projectile:GetClass()
	if class ~= "glide_projectile" and class ~= "glide_missile" then
		return
	end
	local vehicle = projectile:GetOwner()
	local tankType = Glide and Glide.VEHICLE_TYPE and Glide.VEHICLE_TYPE.TANK or 5
	local planeType = Glide and Glide.VEHICLE_TYPE and Glide.VEHICLE_TYPE.PLANE
	if not IsValid(vehicle) or vehicle.IsGlideVehicle ~= true then
		return
	end
	local shell = class == "glide_projectile" and vehicle.VehicleType == tankType and V.QueueGlideTankCrater
	local missile = class == "glide_missile" and planeType and vehicle.VehicleType == planeType
	if not shell and not missile then
		return
	end
	-- Mark before enqueue/native damage: one blast can recurse through many
	-- EntityTakeDamage callbacks. Refused edits must not be retried per victim.
	glideSeen[projectile] = true
	if missile then
		-- Glide predicts contact ahead of the fast missile without moving
		-- its native explosion. Use that scoped terrain contact for the cut,
		-- so a long look-ahead cannot place the crater short of the wall.
		local impact = V.GetGlideMissileVoxelImpact and V.GetGlideMissileVoxelImpact(projectile)
		commonCrater(attacker, impact or position, "glide_missile")
		return
	end
	local direction = projectile.velocity
	if not isvector(direction) or direction:LengthSqr() < 1e-12 then
		direction = projectile:GetForward()
	end
	V.QueueGlideTankCrater(attacker, vehicle, position, direction:GetNormalized())
end
local function safelyQueueGlide(projectile, attacker, position)
	-- A failed edit must never suppress Glide's damage/effects or replace an
	-- error raised by its original explosion function.
	local ok, err = pcall(glideCrater, projectile, attacker, position)
	if not ok and ErrorNoHalt then
		ErrorNoHalt("[GVoxel] Glide crater: " .. tostring(err) .. "\n")
	end
end
function V.ReleaseGlideTankExplosionAdapter()
	local state = V.GlideTankExplosionAdapter
	if not state then
		return
	end
	state.active = false
	if state.api.CreateExplosion == state.wrapper then
		state.api.CreateExplosion = state.original
	end
	V.GlideTankExplosionAdapter = nil
end
function V.InstallGlideTankExplosionAdapter()
	local api = Glide
	if not api or type(api.CreateExplosion) ~= "function" then
		return
	end
	local old = V.GlideTankExplosionAdapter
	if old and old.api == api and api.CreateExplosion == old.wrapper then
		return
	end
	V.ReleaseGlideTankExplosionAdapter()
	local original = api.CreateExplosion
	local state = { api = api, original = original, active = true }
	state.wrapper = function(...)
		if state.active then
			safelyQueueGlide(...)
		end
		-- Tail call preserves every argument/return, including nil, and the
		-- original error without wrapping it in another protected call.
		return original(...)
	end
	api.CreateExplosion = state.wrapper
	V.GlideTankExplosionAdapter = state
end
local nextGlideInstall = 0
hook.Add("Think", "GVoxel.GlideTankExplosions", function()
	if CurTime() < nextGlideInstall then
		return
	end
	nextGlideInstall = CurTime() + 1
	V.InstallGlideTankExplosionAdapter()
end)
V.InstallGlideTankExplosionAdapter()

-- Fallback for older/replaced Glide explosion implementations. It shares the
-- same weak set with the exact event and accepts tank shells/plane missiles.
hook.Add("EntityTakeDamage", "GVoxel.GlideTankBlastDamage", function(_, damage)
	if not damage:IsExplosionDamage() then
		return
	end
	local projectile = damage:GetInflictor()
	if
		IsValid(projectile)
		and (projectile:GetClass() == "glide_projectile" or projectile:GetClass() == "glide_missile")
	then
		safelyQueueGlide(projectile, damage:GetAttacker(), projectile:GetPos())
	end
end)

hook.Add("PostCleanupMap", "GVoxel.ClearRPGBlasts", function()
	seen = setmetatable({}, { __mode = "k" })
	V.NativeExplosionSeen = seen
	sequence = 0
	glideSeen = setmetatable({}, { __mode = "k" })
	V.GlideTankExplosionSeen = glideSeen
end)
