-- One trace contract for bullets and projectile adapters. Only the published
-- field replaces world solids inside the scan; outside BSP/entities stay native.
local V = GVoxel
if V.ReleaseBallistics then
	V.ReleaseBallistics()
end
local active = true
V.BulletCallbackOrigins = V.BulletCallbackOrigins or setmetatable({}, { __mode = "k" })
local origins = V.BulletCallbackOrigins
local stats = { pellets = 0, redirected = 0, damage = 0 }
local nativeProjectiles = { prop_combine_ball = true, hunter_flechette = true, npc_satchel = true, npc_tripmine = true }
local function region()
	local r = SERVER and V.GetServerScanRegion and V.GetServerScanRegion()
		or CLIENT and V.GetClientScanRegion and V.GetClientScanRegion()
	if r and r.revision > 0 and r.vehicleExterior then
		return r
	end
end
function V.IsVoxelProjectileClass(name, definition)
	if name == "vm_projectile_stop" or name == "vm_voxel_collider" then
		return false
	end
	if definition and (definition.IsProjectile == true or definition.IsMissile == true) then
		return true
	end
	name = name:lower()
	if nativeProjectiles[name] then
		return true
	end
	return name:find("missile", 1, true) ~= nil
		or name:find("projectile", 1, true) ~= nil
		or name:find("rocket", 1, true) ~= nil
		or name:find("bullet", 1, true) ~= nil
		or name:find("grenade", 1, true) ~= nil
		or name:find("bolt", 1, true) ~= nil
end
function V.IsVoxelProjectile(ent)
	if not ent or not ent.GetClass or (ent.IsWeapon and ent:IsWeapon()) or (ent.IsPlayer and ent:IsPlayer()) then
		return false
	end
	if ent.VMProjectileStopFor or ent.VMVoxelCollider then
		return false
	end
	local name = ent:GetClass()
	if ent.IsProjectile == true or ent.IsMissile == true or nativeProjectiles[name] then
		return true
	end
	if (ent.IsNPC and ent:IsNPC()) or (ent.IsNextBot and ent:IsNextBot()) then
		return false
	end
	if V.IsVoxelProjectileClass(name, ent) then
		return true
	end
	local seen = {}
	for _ = 1, 12 do
		if seen[name] or not scripted_ents or not scripted_ents.GetStored then
			return false
		end
		seen[name] = true
		local stored = scripted_ents.GetStored(name)
		if not stored or not stored.t then
			return false
		end
		name = stored.t.Base
		if not name then
			return false
		end
		if V.IsVoxelProjectileClass(name, stored.t) then
			return true
		end
	end
	return false
end
function V.TraceProjectileTerrain(r, data, native)
	return V.TraceVehicleTerrain(r, data, native or (data.mins and util.TraceHull or util.TraceLine))
end
local function changed(a, b)
	return a.Entity ~= b.Entity
		or a.Hit ~= b.Hit
		or a.StartSolid ~= b.StartSolid
		or (a.HitPos - b.HitPos):LengthSqr() > 0.01
end
local function effects(shooter, bullet, tr, damage)
	if not EffectData or not util.Effect then
		return
	end
	local every = bullet.Tracer == nil and 1 or bullet.Tracer
	shooter.VMVoxelTracer = (shooter.VMVoxelTracer or 0) + 1
	if every > 0 and shooter.VMVoxelTracer % every == 0 then
		local e = EffectData()
		e:SetStart(tr.StartPos)
		e:SetOrigin(tr.HitPos)
		e:SetEntity(shooter)
		e:SetScale(1)
		util.Effect(bullet.TracerName or "Tracer", e)
	end
	if tr.Hit and not tr.HitSky then
		local e = EffectData()
		e:SetOrigin(tr.HitPos)
		e:SetStart(tr.StartPos)
		e:SetNormal(tr.HitNormal)
		e:SetSurfaceProp(tr.SurfaceProps or 0)
		e:SetDamageType(damage:GetDamageType())
		if IsValid(tr.Entity) then
			e:SetEntity(tr.Entity)
		end
		util.Effect("Impact", e)
	end
end
function V.WrapVoxelBullet(shooter, bullet)
	if not active or not region() then
		return false
	end
	local old = bullet.Callback
	if old and origins[old] then
		old = origins[old].original
	end
	-- Capture values, not a reusable SWEP bullet table. Spread/damage remain
	-- engine-owned and the callback sees each actual post-spread pellet.
	local distance = bullet.Distance or 56756
	local size = math.max(0, bullet.HullSize or 0)
	local ignore = bullet.IgnoreEntity
	local settings = { Tracer = bullet.Tracer, TracerName = bullet.TracerName }
	local wrapper = function(attacker, native, damage)
		local r = active and region()
		local start = native.StartPos
		if not start then
			if old then
				return old(attacker, native, damage)
			end
			return
		end
		local direction = native.Normal or (native.HitPos - start):GetNormalized()
		local first = r and start and V.CubeRayInterval(r, start, direction)
		if not first or first > distance then
			if old then
				return old(attacker, native, damage)
			end
			return
		end
		stats.pellets = stats.pellets + 1
		local data = {
			start = start,
			endpos = start + direction * distance,
			mask = MASK_SHOT,
			filter = function(ent)
				return ent ~= shooter and ent ~= ignore and not ent.VMVoxelCollider and not ent.VMProjectileStopFor
			end,
		}
		if size > 0 then
			data.mins = Vector(-size, -size, -size)
			data.maxs = Vector(size, size, size)
		end
		local resolved = V.TraceProjectileTerrain(r, data)
		if not changed(native, resolved) then
			if old then
				return old(attacker, native, damage)
			end
			return
		end
		stats.redirected = stats.redirected + 1
		damage:SetDamagePosition(resolved.HitPos)
		local result = old and old(attacker, resolved, damage)
		if
			SERVER
			and (not result or result.damage ~= false)
			and resolved.Hit
			and IsValid(resolved.Entity)
			and not resolved.HitWorld
			and not resolved.Entity:IsWorld()
		then
			resolved.Entity:DispatchTraceAttack(damage, resolved, direction)
			stats.damage = stats.damage + 1
		end
		if not result or result.effects ~= false then
			effects(shooter, settings, resolved, damage)
		end
		-- The engine still owns its original trace. Suppress that hit instead
		-- of assuming that mutating the Lua copy changes the C++ victim.
		return { damage = false, effects = false }
	end
	origins[wrapper] = { original = old }
	bullet.Callback = wrapper
	return true
end
hook.Add("EntityFireBullets", "GVoxel.Bullets", function(ent, data)
	if V.WrapVoxelBullet(ent, data) then
		return true
	end
end)
function V.ReleaseBallistics()
	active = false
end
if SERVER then
	concommand.Add("vm_projectile_stats", function(ply)
		if IsValid(ply) and not V.CanManageScan(ply) then
			return
		end
		print(
			string.format(
				"[GVoxel] Tirs : %d trajectoires ; %d impacts corriges ; %d victimes",
				stats.pellets,
				stats.redirected,
				stats.damage
			)
		)
		if V.GetProjectileStats then
			local s = V.GetProjectileStats()
			print(
				string.format(
					"[GVoxel] Projectiles : %d vols / %d physiques ; %d contacts temporaires ; %d balayages ; %d impacts",
					s.flights,
					s.physical,
					s.stops,
					s.sweeps,
					s.contacts
				)
			)
		end
	end)
end
