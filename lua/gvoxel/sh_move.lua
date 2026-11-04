-- Independent player controller, using Mineable Worlds' custom-Move principle
-- with continuous smooth-voxel hull tests instead of occupied cubic cells.
local V = GVoxel
local axes = { "x", "y", "z" }
local SKIN = 0.03125
local collisions = CreateConVar(
	"vm_player_collision",
	"1",
	FCVAR_ARCHIVE + FCVAR_REPLICATED,
	"Deplacement joueur contre le terrain voxel personnel",
	0,
	1
)
local friction = GetConVar("sv_friction")
local stopSpeed = GetConVar("sv_stopspeed")
local accelerate = GetConVar("sv_accelerate")
local airAccelerate = GetConVar("sv_airaccelerate")

local function nativeTrace(ply, start, finish, mins, maxs, ignoreWorld, options)
	return util.TraceHull({
		start = start,
		endpos = finish,
		mins = mins,
		maxs = maxs,
		filter = function(ent)
			if ent == ply or ent:GetClass() == "vm_voxel_collider" or ent.VMProjectileStopFor then
				return false
			end
			if
				options
				and options.navigation
				and (
					(ent.IsPlayer and ent:IsPlayer())
					or (ent.IsNPC and ent:IsNPC())
					or (ent.IsNextBot and ent:IsNextBot())
				)
			then
				return false
			end
			return true
		end,
		mask = options and options.mask or MASK_PLAYERSOLID,
		collisiongroup = options and options.group or COLLISION_GROUP_PLAYER_MOVEMENT,
		ignoreworld = ignoreWorld or false,
	})
end

local function outsideBlocked(ply, r, start, finish, mins, maxs, options)
	local low, high = Vector(), Vector()
	for _, axis in ipairs(axes) do
		low[axis] = math.min(start[axis], finish[axis]) + mins[axis]
		high[axis] = math.max(start[axis], finish[axis]) + maxs[axis]
	end
	return V.OutsideScanBoxes(r, low, high, function(a, b)
		if b.x - a.x < 0.0001 or b.y - a.y < 0.0001 or b.z - a.z < 0.0001 then
			return false
		end
		local center = (a + b) / 2
		local tr = util.TraceHull({
			start = center,
			endpos = center,
			mins = a - center,
			maxs = b - center,
			mask = options and options.brushMask or MASK_PLAYERSOLID_BRUSHONLY,
			filter = function(ent)
				return ent:IsWorld()
			end,
		})
		return tr.StartSolid or tr.AllSolid
	end)
end

-- All controller sweeps are along one axis. Their swept AABB is exactly their
-- swept volume, so the BSP partition cannot miss thin walls at cube boundaries.
function V.TracePlayerTerrain(ply, r, start, finish, mins, maxs, options)
	local best = V.TraceVoxelHull(r, start, finish, mins, maxs, options and options.checkpoint)
	local function merge(tr)
		if tr.StartSolid or (tr.Hit and tr.Fraction < best.Fraction) then
			best = tr
		end
	end
	merge(nativeTrace(ply, start, finish, mins, maxs, true, options))
	if outsideBlocked(ply, r, start, finish, mins, maxs, options) then
		local delta = finish - start
		local inside = outsideBlocked(ply, r, start, start, mins, maxs, options)
		local lo, hi = 0, 1
		if not inside then
			for _ = 1, 16 do
				local middle = (lo + hi) / 2
				if outsideBlocked(ply, r, start, start + delta * middle, mins, maxs, options) then
					hi = middle
				else
					lo = middle
				end
			end
		else
			hi = 0
		end
		merge({
			Hit = true,
			StartSolid = inside,
			Fraction = hi,
			HitPos = start + delta * hi,
			HitNormal = delta:LengthSqr() > 0 and delta:GetNormalized() * -1 or Vector(),
			HitWorld = true,
		})
	end
	return best
end

local function stop(start, finish, tr)
	if not tr.Hit then
		return finish
	end
	local delta = finish - start
	local distance = math.sqrt(delta:LengthSqr())
	return start + delta * math.max(0, tr.Fraction - (distance > 0 and SKIN / distance or 0))
end

-- Numerical controller separated from engine/prediction glue for regression tests.
function V.SimulateVoxelPlayer(state, trace)
	local pos = Vector(state.pos.x, state.pos.y, state.pos.z)
	local vel = Vector(state.vel.x, state.vel.y, state.vel.z)
	local dt = state.dt
	local step = state.step or 18
	local down = trace(pos, pos - Vector(0, 0, 0.6))
	local grounded = vel.z <= 1 and down.Hit and not down.StartSolid and down.HitNormal.z >= 0.65
	local wasGrounded = grounded
	local wish = state.wish or Vector()
	-- Source-style ground friction stops the player in finite time. The old
	-- interpolation left residual speed indefinitely, producing ice skating.
	if grounded then
		local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y)
		if speed < 1 then
			vel.x = 0
			vel.y = 0
		else
			local nextSpeed = math.max(0, speed - math.max(speed, state.stopSpeed or 100) * (state.friction or 4) * dt)
			vel.x = vel.x * nextSpeed / speed
			vel.y = vel.y * nextSpeed / speed
		end
	end
	local wishSpeed = math.sqrt(wish.x * wish.x + wish.y * wish.y)
	if wishSpeed > 0 then
		local x, y = wish.x / wishSpeed, wish.y / wishSpeed
		local target = grounded and wishSpeed or math.min(30, wishSpeed)
		local extra = target - vel.x * x - vel.y * y
		if extra > 0 then
			local amount =
				math.min(extra, (grounded and (state.accelerate or 10) or (state.airAccelerate or 10)) * dt * wishSpeed)
			vel.x = vel.x + x * amount
			vel.y = vel.y + y * amount
		end
	end
	if grounded then
		vel.z = 0
	end
	if grounded and state.jump then
		vel.z = state.jumpPower or 200
		grounded = false
	end
	if not grounded then
		vel.z = math.max(-3500, vel.z - state.gravity * dt / 2)
	end
	for _, axis in ipairs({ "x", "y" }) do
		if math.abs(vel[axis] * dt) > 1e-8 then
			local target = Vector(pos.x, pos.y, pos.z)
			target[axis] = target[axis] + vel[axis] * dt
			local tr = trace(pos, target)
			local direct = stop(pos, target, tr)
			local stepped = false
			if tr.Hit and not tr.StartSolid and grounded and step > 0 then
				local upTarget = pos + Vector(0, 0, step)
				local up = trace(pos, upTarget)
				local raised = stop(pos, upTarget, up)
				local acrossTarget = Vector(raised.x, raised.y, raised.z)
				acrossTarget[axis] = acrossTarget[axis] + vel[axis] * dt
				local across = stop(raised, acrossTarget, trace(raised, acrossTarget))
				local endTarget = across - Vector(0, 0, step + 0.6)
				local floor = trace(across, endTarget)
				if
					floor.Hit
					and not floor.StartSolid
					and floor.HitNormal.z >= 0.65
					and math.abs(across[axis] - pos[axis]) > math.abs(direct[axis] - pos[axis]) + 0.001
				then
					pos = stop(across, endTarget, floor)
					stepped = true
				end
			end
			if not stepped then
				pos = direct
				if tr.Hit then
					vel[axis] = 0
				end
			end
		end
	end
	grounded = false
	if math.abs(vel.z * dt) > 1e-8 then
		local target = pos + Vector(0, 0, vel.z * dt)
		local tr = trace(pos, target)
		pos = stop(pos, target, tr)
		if tr.Hit then
			if vel.z <= 0 and tr.HitNormal.z >= 0.65 then
				grounded = true
				vel.z = 0
			elseif tr.HitNormal.z > 0 and vel.z < 0 then
				vel = vel - tr.HitNormal * vel:Dot(tr.HitNormal)
			else
				vel.z = 0
			end
		elseif vel.z ~= 0 then
			vel.z = math.max(-3500, vel.z - state.gravity * dt / 2)
		end
	end
	if wasGrounded and not state.jump and vel.z <= 0 then
		local endTarget = pos - Vector(0, 0, step + 0.6)
		local floor = trace(pos, endTarget)
		if floor.Hit and not floor.StartSolid and floor.HitNormal.z >= 0.65 then
			pos = stop(pos, endTarget, floor)
			vel.z = 0
			grounded = true
		end
	end
	return pos, vel, grounded
end

local function groundState(ply, grounded)
	ply:SetGroundEntity(grounded and game.GetWorld() or NULL)
	if grounded then
		ply:AddFlags(FL_ONGROUND)
	else
		ply:RemoveFlags(FL_ONGROUND)
	end
end

local function clearMode(ply, preserveMoveType)
	ply.VMVoxelActive = nil
	ply.VMVoxelRecovery = nil
	if SERVER then
		ply:SetNW2Bool("VM_VoxelMovement", false)
	end
	if not preserveMoveType and ply:GetMoveType() == MOVETYPE_NOCLIP then
		ply:SetMoveType(MOVETYPE_WALK)
	end
	ply:RemoveFlags(FL_DUCKING + FL_ANIMDUCKING)
	ply:SetCurrentViewOffset(ply:GetViewOffset())
	groundState(ply, false)
end

-- Before dropping a scan, return a player buried in the original BSP to the
-- most recent native-safe position. No client coordinates are trusted.
function V.ReleaseVoxelMovement(ply, moveOrigin)
	if not ply.VMVoxelActive and not ply:GetNW2Bool("VM_VoxelMovement") then
		return true
	end
	local relocated = nil
	if SERVER and ply:Alive() and not ply:InVehicle() then
		local mins, maxs = ply:GetHull()
		local pos = moveOrigin or ply:GetPos()
		local function free(p)
			return not nativeTrace(ply, p, p, mins, maxs).StartSolid
		end
		if not free(pos) then
			local safe = ply.VMVoxelSafe
			if not safe or not free(safe) then
				safe = nil
				for height = 8, 1536, 8 do
					local candidate = pos + Vector(0, 0, height)
					if free(candidate) then
						safe = candidate
						break
					end
				end
			end
			if not safe then
				return false
			end
			if not moveOrigin then
				ply:SetPos(safe)
				ply:SetLocalVelocity(Vector())
			end
			relocated = safe
		end
	end
	clearMode(ply, ply:InVehicle())
	return true, relocated
end

local function movementRegion(ply)
	if SERVER then
		return V.GetServerMovementRegion and V.GetServerMovementRegion(ply)
	end
	if ply == LocalPlayer() then
		return V.GetClientScanRegion and V.GetClientScanRegion()
	end
end

local function releaseFromMove(ply, mv)
	local released, pos = V.ReleaseVoxelMovement(ply, mv:GetOrigin())
	if pos then
		mv:SetOrigin(pos)
		mv:SetVelocity(Vector())
	end
	if not released then
		mv:SetVelocity(Vector())
		return true
	end
end

hook.Add("Move", "GVoxel.SmoothMovement", function(ply, mv)
	local custom = ply.VMVoxelActive or ply:GetNW2Bool("VM_VoxelMovement")
	if not ply:Alive() or ply:InVehicle() then
		if custom then
			clearMode(ply, ply:InVehicle())
		end
		return
	end
	local mt = ply:GetMoveType()
	if custom and mt ~= MOVETYPE_NOCLIP and mt ~= MOVETYPE_WALK then
		clearMode(ply)
		return
	end
	if not custom and mt ~= MOVETYPE_WALK then
		return
	end
	local r = collisions:GetBool() and movementRegion(ply)
	if not r then
		if custom then
			return releaseFromMove(ply, mv)
		end
		return
	end
	local pos = mv:GetOrigin()
	local standMin, standMax = ply:GetHull()
	local margin = custom and 32 or 4
	if
		not V.HullNearScan(r, pos, standMin, standMax, margin)
		or not V.HullTouchesModified(r, pos, standMin, standMax, margin)
	then
		if not custom then
			return
		end
		local lo, hi = standMin, standMax
		if ply:IsFlagSet(FL_DUCKING) then
			lo, hi = ply:GetHullDuck()
		end
		-- An unchanged chunk is not necessarily a safe BSP stance. Keeping
		-- this controller until the native hull is clear avoids teleporting
		-- back to the last safe position at mixed floors and zone borders.
		if not nativeTrace(ply, pos, pos, lo, hi).StartSolid then
			clearMode(ply)
			return
		end
	end
	if not custom then
		ply.VMVoxelActive = true
		ply.VMVoxelNextSafe = 0
		if SERVER then
			ply:SetNW2Bool("VM_VoxelMovement", true)
		end
		ply:SetMoveType(MOVETYPE_NOCLIP)
	end
	if SERVER and CurTime() >= (ply.VMVoxelNextSafe or 0) then
		ply.VMVoxelNextSafe = CurTime() + 0.25
		if not nativeTrace(ply, pos, pos, standMin, standMax).StartSolid then
			ply.VMVoxelSafe = Vector(pos.x, pos.y, pos.z)
		end
	end
	local mins, maxs = standMin, standMax
	local crouched = ply:IsFlagSet(FL_DUCKING)
	local duckMin, duckMax = ply:GetHullDuck()
	if mv:KeyDown(IN_DUCK) then
		crouched = true
	elseif crouched and not V.TracePlayerTerrain(ply, r, pos, pos, standMin, standMax).StartSolid then
		crouched = false
	end
	if crouched then
		mins, maxs = duckMin, duckMax
		ply:AddFlags(FL_DUCKING + FL_ANIMDUCKING)
	else
		ply:RemoveFlags(FL_DUCKING + FL_ANIMDUCKING)
	end
	local trace = function(a, b)
		return V.TracePlayerTerrain(ply, r, a, b, mins, maxs)
	end
	if trace(pos, pos).StartSolid then
		-- A completed scan may differ slightly from the BSP at the feet. Find
		-- a nearby clear stance vertically before enabling walking.
		-- An impossible stance used to run 64 full SAT/world probes on EVERY
		-- predicted command. Resume a bounded search; retry failed searches
		-- only occasionally, or immediately if position/field/stance changes.
		local recovery = ply.VMVoxelRecovery
		if
			not recovery
			or recovery.region ~= r
			or recovery.revision ~= r.revision
			or recovery.pos:DistToSqr(pos) > 1e-8
			or recovery.mins:DistToSqr(mins) > 1e-8
			or recovery.maxs:DistToSqr(maxs) > 1e-8
		then
			recovery = {
				region = r,
				revision = r.revision,
				pos = Vector(pos.x, pos.y, pos.z),
				mins = Vector(mins.x, mins.y, mins.z),
				maxs = Vector(maxs.x, maxs.y, maxs.z),
				height = 1,
			}
			ply.VMVoxelRecovery = recovery
		end
		if recovery.retry and CurTime() < recovery.retry then
			groundState(ply, false)
			mv:SetVelocity(Vector())
			return true
		end
		if recovery.retry then
			recovery.retry = nil
			recovery.height = 1
		end
		local free = nil
		for height = recovery.height, math.min(64, recovery.height + 3) do
			local candidate = pos + Vector(0, 0, height)
			if not trace(candidate, candidate).StartSolid then
				free = candidate
				break
			end
			recovery.height = height + 1
		end
		if free then
			pos = free
			ply.VMVoxelRecovery = nil
		else
			if recovery.height > 64 then
				recovery.retry = CurTime() + 0.25
			end
			groundState(ply, false)
			mv:SetVelocity(Vector())
			return true
		end
	else
		ply.VMVoxelRecovery = nil
	end
	local angle = mv:GetMoveAngles()
	local forward, right = angle:Forward(), angle:Right()
	forward.z = 0
	right.z = 0
	forward = forward:GetNormalized()
	right = right:GetNormalized()
	local wish = forward * mv:GetForwardSpeed() + right * mv:GetSideSpeed()
	local speed = mv:KeyDown(IN_SPEED) and ply:GetRunSpeed() or ply:GetWalkSpeed()
	if mv:KeyDown(IN_WALK) then
		speed = ply:GetSlowWalkSpeed()
	end
	if crouched then
		speed = ply:GetWalkSpeed() * ply:GetCrouchedWalkSpeed()
	end
	speed = math.min(speed, mv:GetMaxSpeed() > 0 and mv:GetMaxSpeed() or speed)
	local length = math.sqrt(wish:LengthSqr())
	if length > 0 then
		wish = wish * (math.min(speed, length) / length)
	end
	local gravity = ply:GetGravity()
	local nextPos, velocity, grounded = V.SimulateVoxelPlayer({
		pos = pos,
		vel = mv:GetVelocity(),
		wish = wish,
		dt = engine.TickInterval(),
		step = ply:GetStepSize(),
		jump = mv:KeyPressed(IN_JUMP),
		friction = friction and friction:GetFloat() or 4,
		stopSpeed = stopSpeed and stopSpeed:GetFloat() or 100,
		accelerate = accelerate and accelerate:GetFloat() or 10,
		airAccelerate = airAccelerate and airAccelerate:GetFloat() or 10,
		jumpPower = ply:GetJumpPower(),
		gravity = GetConVar("sv_gravity"):GetFloat() * (gravity > 0 and gravity or 1),
	}, trace)
	local view = crouched and ply:GetViewOffsetDucked() or ply:GetViewOffset()
	ply:SetCurrentViewOffset(view)
	groundState(ply, grounded)
	mv:SetOrigin(nextPos)
	mv:SetVelocity(velocity)
	return true
end)

-- NOCLIP is only an engine collision bypass here: VPhysics' native player
-- shadow must not push the player out of the hidden, uncut BSP. Keep normal
-- walking/jumping/crouching activities and IK for this controller only.
-- Genuine user noclip still uses the stock flying animation.
hook.Add("CalcMainActivity", "GVoxel.WalkingActivity", function(ply, velocity)
	local controlled = (ply.VMVoxelActive or ply:GetNW2Bool("VM_VoxelMovement")) and ply:Alive() and not ply:InVehicle()
	local data = ply:GetTable()
	if not controlled then
		if data.VMVoxelAnimation then
			data.VMVoxelAnimation = nil
			data.m_bJumping = false
			data.m_fGroundTime = nil
			data.m_bWasOnGround = ply:IsFlagSet(FL_ONGROUND)
		end
		return
	end
	if not data.VMVoxelAnimation then
		data.VMVoxelAnimation = true
		data.m_bWasNoclipping = nil
		data.m_bJumping = false
		data.m_fGroundTime = nil
		ply:AnimResetGestureSlot(GESTURE_SLOT_CUSTOM)
		if CLIENT then
			ply:SetIK(true)
		end
	end
	local grounded = ply:IsFlagSet(FL_ONGROUND)
	local speed = velocity.x * velocity.x + velocity.y * velocity.y
	local activity
	if not grounded then
		activity = ACT_MP_JUMP
	elseif ply:IsFlagSet(FL_DUCKING) then
		activity = speed > 0.25 and ACT_MP_CROUCHWALK or ACT_MP_CROUCH_IDLE
	elseif speed > 22500 then
		activity = ACT_MP_RUN
	elseif speed > 0.25 then
		activity = ACT_MP_WALK
	else
		activity = ACT_MP_STAND_IDLE
	end
	if grounded and data.m_bWasOnGround == false then
		ply:AnimRestartGesture(GESTURE_SLOT_JUMP, ACT_LAND, true)
	end
	data.m_bWasOnGround = grounded
	data.CalcIdeal = activity
	data.CalcSeqOverride = -1
	return activity, -1
end)

hook.Add("PlayerSpawn", "GVoxel.ResetMovement", function(ply)
	if ply.VMVoxelActive or ply:GetNW2Bool("VM_VoxelMovement") then
		clearMode(ply)
	end
	ply.VMVoxelSafe = nil
end)
hook.Add("PlayerDeath", "GVoxel.DeathMovement", function(ply)
	if ply.VMVoxelActive or ply:GetNW2Bool("VM_VoxelMovement") then
		clearMode(ply)
	end
end)
hook.Add("PlayerNoClip", "GVoxel.ManualFlight", function(ply)
	if not ply.VMVoxelActive and not ply:GetNW2Bool("VM_VoxelMovement") then
		return
	end
	clearMode(ply)
	-- The noclip key switches from controlled walking to genuine free flight.
	ply:SetMoveType(MOVETYPE_NOCLIP)
	return false
end)
