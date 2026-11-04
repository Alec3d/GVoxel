-- Ground actor bridge: native AI keeps targets/attacks, while a local route
-- and continuous hull controller replace immutable-BSP movement near the zone.
local V = GVoxel
V.VoxelActors = V.VoxelActors or {}
local actors = V.VoxelActors
local nextSearch = 0
local options = { mask = MASK_NPCSOLID, brushMask = MASK_NPCSOLID_BRUSHONLY, group = COLLISION_GROUP_NPC }
local function nextbot(ent)
	return ent.IsNextBot and ent:IsNextBot()
end
local function eligible(ent)
	if not IsValid(ent) or ent:Health() <= 0 or IsValid(ent:GetParent()) then
		return false
	end
	if nextbot(ent) then
		return ent.loco
			and ent.GetEnemy
			and ent:GetMoveType() ~= MOVETYPE_VPHYSICS
			and (not ent.loco.GetGravity or ent.loco:GetGravity() > 0)
	end
	return ent:IsNPC() and ent:GetMoveType() == MOVETYPE_STEP
end
local function goal(ent)
	local enemy = ent.GetEnemy and ent:GetEnemy()
	if IsValid(enemy) and (not enemy.Health or enemy:Health() > 0) then
		return enemy:GetPos(), enemy
	end
	if ent.GetPathDistanceToGoal and (ent:GetPathDistanceToGoal() or 0) > 1 and ent.GetCurWaypointPos then
		return ent:GetCurWaypointPos()
	end
	local target = ent.GetTarget and ent:GetTarget()
	if IsValid(target) then
		return target:GetPos()
	end
end
local function release(ent, record, pos)
	if IsValid(ent) then
		ent:SetPos(pos or ent:GetPos())
		ent:SetLocalVelocity(Vector())
		ent:SetMoveType(record.moveType)
		ent:SetGroundEntity(NULL)
		ent:SetNW2Int("VM_PropRegion", 0)
		if record.playback and ent.SetPlaybackRate then
			ent:SetPlaybackRate(record.playback)
		end
		if not record.skyFlag then
			ent:RemoveEFlags(EFL_IN_SKYBOX)
		end
		if ent.SetSchedule and SCHED_CHASE_ENEMY and IsValid(ent.GetEnemy and ent:GetEnemy()) then
			ent:SetSchedule(SCHED_CHASE_ENEMY)
		end
	end
	actors[ent] = nil
	if V.ForgetNPCNavigation then
		V.ForgetNPCNavigation(ent)
	end
end
function V.ReleaseActorRegion(r)
	local positions = {}
	for ent, record in pairs(actors) do
		if record.region == r and IsValid(ent) then
			local current = ent:GetPos()
			local safe = V.NativeBodyFree(ent, current) and current or V.FindNativeBodySafe(r, ent, record.safe)
			if not safe then
				return false
			end
			positions[ent] = safe
		end
	end
	for ent, record in pairs(actors) do
		if record.region == r then
			release(ent, record, positions[ent])
		end
	end
	return true
end
local function enroll(r, ent)
	if not r.propPhysics or actors[ent] or not eligible(ent) then
		return
	end
	if NPC_STATE_SCRIPT and ent.GetNPCState and ent:GetNPCState() == NPC_STATE_SCRIPT then
		return
	end
	local pos = ent:GetPos()
	if not V.InScanCube(r, pos) then
		-- An approaching zombie needs the shortcut before native nodes would
		-- bring it inside. Keep native motion until a validated route exists.
		local target = goal(ent)
		if not target or not V.GetNPCNavigationPoint or not V.GetNPCNavigationPoint(ent, r, target, true) then
			return
		end
	end
	local mins, maxs = ent:GetCollisionBounds()
	if V.TracePlayerTerrain(ent, r, pos, pos, mins, maxs, options).StartSolid then
		local free
		for up = 1, 8 do
			local p = pos + Vector(0, 0, up)
			if not V.TracePlayerTerrain(ent, r, p, p, mins, maxs, options).StartSolid then
				free = p
				break
			end
		end
		if not free then
			return
		end
		pos = free
	end
	actors[ent] = {
		region = r,
		safe = pos,
		velocity = ent:GetVelocity(),
		moveType = ent:GetMoveType(),
		entered = V.HullNearScan(r, pos, mins, maxs, 0),
		skyFlag = ent:IsEFlagSet(EFL_IN_SKYBOX),
		last = CurTime(),
		nextSafe = 0,
		progressAt = CurTime(),
		progressPos = pos,
		playback = ent.GetPlaybackRate and ent:GetPlaybackRate(),
	}
	ent:SetPos(pos)
	ent:SetMoveType(MOVETYPE_NONE)
	ent:SetNW2Int("VM_PropRegion", r.id)
	ent:AddEFlags(EFL_IN_SKYBOX)
end
local function attack(ent)
	if not ent.IsCurrentSchedule then
		return false
	end
	for _, schedule in pairs({
		SCHED_MELEE_ATTACK1,
		SCHED_MELEE_ATTACK2,
		SCHED_RANGE_ATTACK1,
		SCHED_RANGE_ATTACK2,
		SCHED_RELOAD,
	}) do
		if ent:IsCurrentSchedule(schedule) then
			return true
		end
	end
	return false
end
local function animate(ent, record, velocity, grounded, attacking, dt)
	if ent.AddFlags and FL_ONGROUND then
		if grounded then
			ent:AddFlags(FL_ONGROUND)
		else
			ent:RemoveFlags(FL_ONGROUND)
		end
	end
	if attacking or ent:Health() <= 0 then
		if record.rate and ent.SetPlaybackRate then
			ent:SetPlaybackRate(record.playback or 1)
			record.rate = nil
		end
		return
	end
	local speed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
	local activity = speed > 4 and (ent.GetMovementActivity and ent:GetMovementActivity() or ACT_WALK) or ACT_IDLE
	if speed > 4 and (not activity or activity == ACT_IDLE or activity < 0) then
		activity = ACT_WALK
	end
	if not activity then
		return
	end
	if nextbot(ent) then
		if record.activity ~= activity and ent.StartActivity then
			ent:StartActivity(activity)
		end
		-- Scripted BodyUpdate remains owned by the NextBot. Calling BodyMoveXY
		-- here as well would advance its animation twice on many bases.
	else
		if ent.SetIdealActivity then
			ent:SetIdealActivity(activity)
		end
		if ent.MaintainActivity then
			ent:MaintainActivity()
		end
		if ent.GetSequenceGroundSpeed and ent.GetSequence and ent.SetPlaybackRate then
			local sequenceSpeed = ent:GetSequenceGroundSpeed(ent:GetSequence())
			local rate = speed > 4 and sequenceSpeed > 1 and math.Clamp(speed / sequenceSpeed, 0.1, 2) or 1
			record.rate = (record.rate or rate) + (rate - (record.rate or rate)) * math.min(1, dt * 12)
			ent:SetPlaybackRate(record.rate)
		end
	end
	record.activity = activity
end
local function desiredSpeed(ent, record)
	if nextbot(ent) and ent.loco.GetDesiredSpeed then
		return math.min(300, ent.loco:GetDesiredSpeed())
	end
	local activity = ent.GetMovementActivity and ent:GetMovementActivity()
	local sequence = ent.GetSequence and ent:GetSequence()
	if not record.speed or record.speedActivity ~= activity or record.speedSequence ~= sequence then
		-- Some native ideal-speed getters include playback rate. Sampling that
		-- rate after our animation correction would feed speed back into itself.
		local rate = ent.GetPlaybackRate and ent:GetPlaybackRate()
		if rate and record.rate and ent.SetPlaybackRate then
			ent:SetPlaybackRate(record.playback or 1)
		end
		local speed = ent.GetIdealMoveSpeed and ent:GetIdealMoveSpeed() or 0
		if speed <= 0 and sequence and ent.GetSequenceGroundSpeed then
			speed = ent:GetSequenceGroundSpeed(sequence) * (record.playback or 1)
		end
		if rate and record.rate and ent.SetPlaybackRate then
			ent:SetPlaybackRate(rate)
		end
		record.speed = speed > 0 and math.min(300, speed) or 80
		record.speedActivity = activity
		record.speedSequence = sequence
	end
	return record.speed
end
hook.Add("Think", "GVoxel.NPCMovement", function()
	local now = CurTime()
	for ent, record in pairs(actors) do
		if not IsValid(ent) then
			actors[ent] = nil
		elseif not record.region.propPhysics then
			local safe = V.FindNativeBodySafe(record.region, ent, record.safe)
			if safe then
				release(ent, record, safe)
			end
		elseif ent:GetMoveType() == MOVETYPE_VPHYSICS then
			actors[ent] = nil
			ent:SetNW2Int("VM_PropRegion", 0)
			if not record.skyFlag then
				ent:RemoveEFlags(EFL_IN_SKYBOX)
			end
			V.TryEnrollVoxelBody(record.region, ent)
		elseif now > record.last then
			if ent:GetMoveType() ~= MOVETYPE_NONE then
				ent:SetMoveType(MOVETYPE_NONE)
			end
			local r = record.region
			local dt = math.min(0.05, math.max(0, now - record.last))
			record.last = now
			local pos = ent:GetPos()
			local mins, maxs = ent:GetCollisionBounds()
			local wish = Vector()
			local target, enemy = goal(ent)
			local attacking = attack(ent)
			if ent:Health() > 0 and target and not attacking then
				local point = V.GetNPCNavigationPoint and V.GetNPCNavigationPoint(ent, r, target)
				if point then
					local delta = point - pos
					delta.z = 0
					local distance = enemy and (target - pos):LengthSqr() or math.huge
					if delta:LengthSqr() > 4 and distance > 40 ^ 2 then
						wish = delta:GetNormalized() * desiredSpeed(ent, record)
					end
				elseif
					not V.GetNPCNavigationPoint
					and ent.GetPathDistanceToGoal
					and ent:GetPathDistanceToGoal() > 1
				then
					local delta = target - pos
					delta.z = 0
					if delta:LengthSqr() > 16 then
						wish = delta:GetNormalized() * math.min(300, math.max(0, ent:GetIdealMoveSpeed()))
					end
				end
			end
			local nextPos, velocity, grounded = V.SimulateVoxelPlayer({
				pos = pos,
				vel = record.velocity,
				wish = wish,
				dt = dt,
				gravity = GetConVar("sv_gravity"):GetFloat(),
				step = 18,
				jump = false,
			}, function(a, b)
				return V.TracePlayerTerrain(ent, r, a, b, mins, maxs, options)
			end)
			ent:SetPos(nextPos)
			ent:SetLocalVelocity(velocity)
			record.velocity = velocity
			ent:SetGroundEntity(grounded and game.GetWorld() or NULL)
			if ent.SetMoveVelocity then
				ent:SetMoveVelocity(velocity)
			end
			animate(ent, record, velocity, grounded, attacking, dt)
			if wish:LengthSqr() > 1 and ent.SetIdealYawAndUpdate then
				ent:SetIdealYawAndUpdate(math.deg(math.atan2(wish.y, wish.x)))
			end
			if now - record.progressAt > 0.75 then
				if
					target
					and wish:LengthSqr() > 1
					and nextPos:DistToSqr(record.progressPos) < 4
					and V.RequestNPCNavigation
				then
					V.RequestNPCNavigation(ent, r, target, true)
				end
				record.progressAt = now
				record.progressPos = nextPos
			end
			local a, b = ent:WorldSpaceAABB()
			local outside = not V.HullNearScan(r, nextPos, a - nextPos, b - nextPos, 0)
			if not outside then
				record.entered = true
			end
			if outside or now >= record.nextSafe then
				record.nextSafe = now + 0.25
				if V.NativeBodyFree(ent, nextPos) then
					record.safe = nextPos
					if outside and record.entered then
						release(ent, record, nextPos)
					elseif
						outside
						and not record.entered
						and (not target or not V.GetNPCNavigationPoint(ent, r, target, true))
					then
						release(ent, record, nextPos)
					end
				end
			end
		end
	end
	if now < nextSearch then
		return
	end
	nextSearch = now + 0.2
	for r in pairs(V.PropState.regions) do
		if r.propPhysics then
			local margin = Vector(192, 192, 128)
			for _, ent in ipairs(ents.FindInBox(r.origin - margin, r.origin + V.RegionSize(r) + margin)) do
				enroll(r, ent)
			end
		end
	end
end)
