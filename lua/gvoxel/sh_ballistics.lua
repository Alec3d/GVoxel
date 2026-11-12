-- One trace contract for bullets and projectile adapters. Only the published
-- field replaces world solids inside the scan; outside BSP/entities stay native.
local V = GVoxel
if V.ReleaseBallistics then
	V.ReleaseBallistics()
end
local active = true
V.BulletCallbackOrigins = V.BulletCallbackOrigins or setmetatable({}, { __mode = "k" })
local origins = V.BulletCallbackOrigins
local rayMemos = setmetatable({}, { __mode = "k" })
local memoRegion = setmetatable({}, { __mode = "v" })
local stats = { pellets = 0, native = 0, redirected = 0, damage = 0 }
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
local function finishBullet(old, attacker, trace, damage, weaponClass, bulletDamage, native)
	local track = active and weaponClass and V.RecordBallisticImpact and trace.HitWorld
	local initial = track and damage:GetDamage()
	local result = old and old(attacker, native or trace, damage)
	if track and (not result or result.damage ~= false) then
		local amount = damage:GetDamage()
		if amount > 0 or initial == 0 then
			V.RecordBallisticImpact(attacker, trace, weaponClass, amount == 0 and bulletDamage or amount)
		end
	end
	return result
end
local function editedCells(r, x, y, z, lowX, lowY, lowZ, highX, highY, highZ)
	local edits, fallback = r.bspCellEditBins, r.bspFallback
	if not edits then return true end
	local x0, x1 = math.max(x * 8, lowX), math.min(x * 8 + 7, highX)
	local y0, y1 = math.max(y * 8, lowY), math.min(y * 8 + 7, highY)
	local z0, z1 = math.max(z * 8, lowZ), math.min(z * 8 + 7, highZ)
	-- Diagonal paths can have a large bounding box. Leave those to the
	-- ordinary trace instead of scanning a large volume of cells here.
	if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > 32 then return true end
	for cellZ = z0, z1 do
		for cellY = y0, y1 do
			local index = V.Index(x0, cellY, cellZ, r)
			for offset = 0, x1 - x0 do
				local key = index + offset
				if edits[key] or (fallback and fallback[key]) then return true end
			end
		end
	end
	return false
end

-- A native hit stops the ray. In an exact BSP region, only cells
-- touched by an edit or sampled as density can change the path to it.
local function nativeWorldPath(r, start, direction, first, last, native)
	if not native.HitWorld or native.StartSolid then return false end
	local stop = (native.HitPos - start):Dot(direction)
	if stop < first - 0.05 then return true end
	if not r.bsp or not r.bspEditBins then return false end
	local modified, fallback = r.modifiedChunks, r.bspFallback
	local entry = start + direction * first - r.origin
	local finish = start + direction * math.min(stop, last) - r.origin
	local step = r.step
	local lowX = math.max(0, math.floor((math.min(entry.x, finish.x) - 0.05) / step))
	local lowY = math.max(0, math.floor((math.min(entry.y, finish.y) - 0.05) / step))
	local lowZ = math.max(0, math.floor((math.min(entry.z, finish.z) - 0.05) / step))
	local highX = math.min(31, math.floor((math.max(entry.x, finish.x) + 0.05) / step))
	local highY = math.min(31, math.floor((math.max(entry.y, finish.y) + 0.05) / step))
	local highZ = math.min(31, math.floor((math.max(entry.z, finish.z) + 0.05) / step))
	for z = math.floor(lowZ / 8), math.floor(highZ / 8) do
		for y = math.floor(lowY / 8), math.floor(highY / 8) do
			for x = math.floor(lowX / 8), math.floor(highX / 8) do
				local key = V.ChunkKey(x, y, z)
				if (r.bspEditBins[key] or (modified and modified[key]) or fallback)
					and editedCells(r, x, y, z, lowX, lowY, lowZ, highX, highY, highZ)
				then
					return false
				end
			end
		end
	end
	return true
end

function V.WrapVoxelBullet(shooter, bullet)
	if not active then return false end
	local r = region()
	local weaponClass
	if SERVER and V.RecordBallisticImpact and (r or V.GetServerScanRegion()) then
		local weapon = shooter:IsWeapon() and shooter or shooter.GetActiveWeapon and shooter:GetActiveWeapon()
		if IsValid(weapon) then weaponClass = weapon:GetClass() end
	end
	if not r and not weaponClass then return false end
	local old = bullet.Callback
	if old and origins[old] then
		old = origins[old].original
	end
	-- Capture values, not a reusable SWEP bullet table. Spread/damage remain
	-- engine-owned and the callback sees each actual post-spread pellet.
	local distance = bullet.Distance or 56756
	local size = math.max(0, bullet.HullSize or 0)
	local ignore = bullet.IgnoreEntity
	local bulletDamage = bullet.Damage
	local settings = { Tracer = bullet.Tracer, TracerName = bullet.TracerName }
	local mins = size > 0 and Vector(-size, -size, -size) or nil
	local maxs = size > 0 and Vector(size, size, size) or nil
	local function filter(ent)
		return ent ~= shooter and ent ~= ignore and not ent.VMVoxelCollider and not ent.VMProjectileStopFor
	end
	local wrapper = function(attacker, native, damage)
		local r = active and region()
		if not r then
			return finishBullet(old, attacker, native, damage, weaponClass, bulletDamage)
		end
		local start = native.StartPos
		if not start then
			if old then
				return old(attacker, native, damage)
			end
			return
		end
		local direction = native.Normal or (native.HitPos - start):GetNormalized()
		local first, last = V.CubeRayInterval(r, start, direction)
		if not first or first > distance then
			if old then
				return old(attacker, native, damage)
			end
			return
		end
		stats.pellets = stats.pellets + 1
		if not mins and nativeWorldPath(r, start, direction, first, last, native) then
			stats.native = stats.native + 1
			return finishBullet(old, attacker, native, damage, weaponClass, bulletDamage)
		end
		local memo
		if not mins then
			if memoRegion[1] ~= r then
				rayMemos = setmetatable({}, { __mode = "k" })
				memoRegion[1] = r
			end
			memo = rayMemos[shooter]
			if not memo then
				memo = {}
				rayMemos[shooter] = memo
			end
		end
		local data = { start = start, endpos = start + direction * distance, mask = MASK_SHOT,
			filter = filter, mins = mins, maxs = maxs, terrainMemo = memo }
		local resolved = V.TraceProjectileTerrain(r, data)
		if not changed(native, resolved) then
			return finishBullet(old, attacker, resolved, damage, weaponClass, bulletDamage, native)
		end
		stats.redirected = stats.redirected + 1
		damage:SetDamagePosition(resolved.HitPos)
		local result = finishBullet(old, attacker, resolved, damage, weaponClass, bulletDamage)
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
				"[GVoxel] Tirs : %d trajectoires ; %d BSP natifs ; %d impacts corriges ; %d victimes",
				stats.pellets,
				stats.native,
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
