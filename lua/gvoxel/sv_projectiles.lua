-- Fast, bounded discovery; per-tick sweeps only for moving projectile entities
-- near the published zone. No global trace or weapon replacement.
local V = GVoxel
if V.ReleaseVoxelProjectiles then
	V.ReleaseVoxelProjectiles()
end
local candidates = setmetatable({}, { __mode = "k" })
local flights = {}
local physical = {}
local stops = {}
local nextSearch = 0
local stats = { sweeps = 0, contacts = 0, physical = 0 }
function V.GetProjectileStats()
	local snapshot = { sweeps = stats.sweeps, contacts = stats.contacts, flights = 0, physical = 0, stops = 0 }
	for _ in pairs(flights) do
		snapshot.flights = snapshot.flights + 1
	end
	for _ in pairs(physical) do
		snapshot.physical = snapshot.physical + 1
	end
	for _ in pairs(stops) do
		snapshot.stops = snapshot.stops + 1
	end
	return snapshot
end
local function region()
	local r = V.GetServerScanRegion and V.GetServerScanRegion()
	return r and r.revision > 0 and r.vehicleExterior and r.propPhysics and r or nil
end
local function restore(ent, state)
	if IsValid(ent) then
		ent:SetSolid(state.solid)
		ent:SetMoveType(state.moveType)
		ent:SetNW2Int("VM_PropRegion", 0)
		if not state.skyFlag then
			ent:RemoveEFlags(EFL_IN_SKYBOX)
		end
		ent:CollisionRulesChanged()
	end
	flights[ent] = nil
end
function V.ReleaseVoxelProjectiles(r)
	for ent, region in pairs(physical) do
		if not r or region == r then
			V.ReleaseVoxelNativeBody(ent)
			physical[ent] = nil
		end
	end
	for ent, state in pairs(flights) do
		if not r or state.region == r then
			-- Clearing the replacement restores native contact rather than leaving
			-- a projectile permanently non-solid. Native Touch may then detonate it.
			restore(ent, state)
		end
	end
	for stop, state in pairs(stops) do
		if not r or state.region == r then
			if IsValid(stop) then
				stop:Remove()
			end
			stops[stop] = nil
		end
	end
end
local function contact(ent, state, hit, velocity)
	local speed = velocity:Length()
	local direction = speed > 0.001 and velocity / speed or -hit.HitNormal
	local stop = ents.Create("vm_projectile_stop")
	if not IsValid(stop) then
		return false
	end
	local mins, maxs = ent:GetCollisionBounds()
	local front = math.abs(direction.x) * math.max(math.abs(mins.x), math.abs(maxs.x))
		+ math.abs(direction.y) * math.max(math.abs(mins.y), math.abs(maxs.y))
		+ math.abs(direction.z) * math.max(math.abs(mins.z), math.abs(maxs.z))
	stop.VMProjectileStopFor = ent
	stop:SetPos(hit.HitPos + direction * (front + 1))
	stop:Spawn()
	stops[stop] = { region = state.region, expires = CurTime() + 0.15, projectile = ent }
	ent:SetPos(hit.HitPos - direction * 0.25)
	restore(ent, state)
	-- Launch grace ignores entity contacts, but would still hit world terrain.
	-- Our proxy represents that terrain and must not inherit a grace exemption.
	if hit.HitWorld and ent.RemoveSolidFlags and FSOLID_NOT_SOLID then
		ent:RemoveSolidFlags(FSOLID_NOT_SOLID)
	end
	ent:SetLocalVelocity(velocity)
	candidates[ent] = CurTime() + 0.16
	stats.contacts = stats.contacts + 1
	return true
end
local function add(ent)
	if IsValid(ent) and V.IsVoxelProjectile(ent) then
		candidates[ent] = 0
		if V.AdaptVoxelVehicleEntity then
			V.AdaptVoxelVehicleEntity(ent)
		end
	end
end
hook.Add("OnEntityCreated", "GVoxel.ProjectileDiscovery", function(ent)
	-- Fields/owner can be assigned after Spawn. No class-wide scan per shot.
	timer.Simple(0, function()
		add(ent)
	end)
end)
hook.Add("ShouldCollide", "GVoxel.ProjectileContact", function(a, b)
	if a.VMProjectileStopFor then
		return a.VMProjectileStopFor == b
	end
	if b.VMProjectileStopFor then
		return b.VMProjectileStopFor == a
	end
end)
hook.Add("PhysgunPickup", "GVoxel.ProtectProjectileContacts", function(_, ent)
	if ent.VMProjectileStopFor then
		return false
	end
end)
local function bounds(ent)
	return ent:GetCollisionBounds()
end
local function near(r, pos, velocity, mins, maxs, dt)
	return V.HullNearScan(r, pos, mins, maxs, velocity:Length() * dt * 2 + 8)
end
local function supported(r, ent)
	local a, b = ent:WorldSpaceAABB()
	local width = r.vehicleExterior.width - 64
	for _, axis in ipairs({ "x", "y", "z" }) do
		if a[axis] < r.origin[axis] - width or b[axis] > r.origin[axis] + V.RegionAxisSize(r, axis) + width then
			return false
		end
	end
	return true
end
hook.Add("Tick", "GVoxel.Projectiles", function()
	local now = CurTime()
	local r = region()
	for stop, state in pairs(stops) do
		if not IsValid(stop) or not IsValid(state.projectile) or now >= state.expires then
			if IsValid(stop) then
				stop:Remove()
			end
			stops[stop] = nil
		end
	end
	for ent, state in pairs(flights) do
		if not IsValid(ent) then
			flights[ent] = nil
		elseif not r or state.region ~= r then
			restore(ent, state)
		else
			local pos = ent:GetPos()
			local velocity = ent:GetVelocity()
			local mt = ent:GetMoveType()
			if mt ~= MOVETYPE_NOCLIP and mt ~= MOVETYPE_FLY and mt ~= MOVETYPE_FLYGRAVITY then
				-- A scripted missile may finish/stick, or switch to VPhysics
				-- underwater. Keep that native transition instead of reviving it.
				state.moveType = mt
				state.solid = ent:GetSolid()
				restore(ent, state)
			else
				if mt ~= MOVETYPE_NOCLIP then
					state.moveType = mt
				end
				-- Native homing/ignition continues to own velocity and angles.
				ent:SetMoveType(MOVETYPE_NOCLIP)
				ent:SetSolid(SOLID_NONE)
				local mins, maxs = bounds(ent)
				local hit = V.TraceProjectileTerrain(r, {
					start = state.last,
					endpos = pos,
					mins = mins,
					maxs = maxs,
					mask = MASK_SHOT,
					filter = function(other)
						return other ~= ent
							and other ~= ent:GetOwner()
							and not other.VMVoxelCollider
							and not other.VMProjectileStopFor
					end,
				})
				stats.sweeps = stats.sweeps + 1
				if hit.Hit then
					if not contact(ent, state, hit, velocity) then
						ent:SetPos(state.last)
						ent:SetLocalVelocity(Vector())
					end
				else
					state.last = pos
					if state.moveType == MOVETYPE_FLYGRAVITY then
						local dt = math.min(0.05, now - state.time)
						local gravity = ent.GetGravity and ent:GetGravity() or 1
						ent:SetLocalVelocity(
							velocity
								- Vector(
									0,
									0,
									GetConVar("sv_gravity"):GetFloat() * (gravity == 0 and 1 or gravity) * dt
								)
						)
					end
					state.time = now
					if not near(r, pos, velocity, mins, maxs, engine.TickInterval()) then
						restore(ent, state)
					end
				end
			end
		end
	end
	for ent, owner in pairs(physical) do
		if not IsValid(ent) then
			physical[ent] = nil
		elseif not r or r ~= owner then
			V.ReleaseVoxelNativeBody(ent)
			physical[ent] = nil
		else
			local mins, maxs = bounds(ent)
			if
				not near(r, ent:GetPos(), ent:GetVelocity(), mins, maxs, engine.TickInterval())
				and V.NativeBodyFree(ent, ent:GetPos())
			then
				V.ReleaseVoxelNativeBody(ent)
				physical[ent] = nil
			end
		end
	end
	if not r then
		return
	end
	-- One local discovery after scan/load catches pre-existing projectiles.
	if now >= nextSearch then
		nextSearch = now + 0.5
		for _, ent in
			ipairs(ents.FindInBox(r.origin - Vector(256, 256, 256), r.origin + V.RegionSize(r) + Vector(256, 256, 256)))
		do
			if candidates[ent] == nil and not flights[ent] then
				add(ent)
			end
		end
	end
	for ent, retry in pairs(candidates) do
		if not IsValid(ent) then
			candidates[ent] = nil
		elseif not flights[ent] and now >= retry then
			local velocity = ent:GetVelocity()
			local mt = ent:GetMoveType()
			if velocity:LengthSqr() > 1 then
				local mins, maxs = bounds(ent)
				local pos = ent:GetPos()
				if near(r, pos, velocity, mins, maxs, engine.TickInterval()) and supported(r, ent) then
					if mt == MOVETYPE_VPHYSICS then
						local p = r.propPhysics
						local entry = V.CubeRayInterval(r, pos, velocity)
						if
							p.exteriorReady
							and not p.jobs
							and not p.failed
							and p.readyRevision == r.revision
							and entry
							and entry <= engine.TickInterval() * 2
							and not ent.VMPropRegion
						then
							if V.EnrollVoxelNativeBody(r, ent, pos) then
								V.PropState.tracked[ent].projectile = true
								physical[ent] = r
								stats.physical = stats.physical + 1
							end
						end
					elseif mt == MOVETYPE_FLY or mt == MOVETYPE_FLYGRAVITY then
						local state = {
							region = r,
							moveType = mt,
							solid = ent:GetSolid(),
							last = pos,
							time = now,
							skyFlag = ent:IsEFlagSet(EFL_IN_SKYBOX),
						}
						flights[ent] = state
						ent:SetMoveType(MOVETYPE_NOCLIP)
						ent:SetSolid(SOLID_NONE)
						ent:SetNW2Int("VM_PropRegion", r.id)
						ent:AddEFlags(EFL_IN_SKYBOX)
						ent:CollisionRulesChanged()
					end
				end
			end
		end
	end
end)
hook.Add("PostCleanupMap", "GVoxel.ProjectileCleanup", function()
	V.ReleaseVoxelProjectiles()
end)
