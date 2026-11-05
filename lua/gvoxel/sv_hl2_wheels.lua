-- Native HL2 suspension rays live in C++, outside the Lua trace adapters.
-- While an assembly uses voxel collision, replace only its wheel forces with
-- bounded ray suspension/tyre impulses. Engine, seats and body physics survive.
local V = GVoxel
if V.ReleaseHL2WheelSimulation then
	V.ReleaseHL2WheelSimulation()
end
local states = {}
local returning = setmetatable({}, { __mode = "k" })
local function refreshContacts(root)
    if V.EachVoxelBody then
        V.EachVoxelBody(root, function(body)
            if body.RecheckCollisionFilter then body:RecheckCollisionFilter() end
            if body.RecheckContactPoints then body:RecheckContactPoints() end
            body:Wake()
        end)
    end
end
function V.RefreshHL2NativeContacts(root)
    if returning[root] and IsValid(root) then refreshContacts(root) end
end
local fields = {
	"suspension_springConstant",
	"suspension_springDamping",
	"suspension_springDampingCompression",
	"suspension_stabilizerConstant",
	"suspension_maxBodyForce",
	"torqueFactor",
	"brakeFactor",
}
local nativeTrace = util.TraceLine
-- r x J is kg*SU^2/s; ApplyTorqueCenter takes kg*m^2*degrees/s.
local TORQUE_UNITS = 0.0254 ^ 2 * 180 / math.pi
local function clamp(x, a, b)
	return math.max(a, math.min(b, x))
end
local function restore(root)
	local state = states[root]
	if not state then
		return
	end
	if IsValid(root) then
		-- Never round-trip engine speeds: getter/setter use different units.
		local ok = pcall(root.SetVehicleParams, root, { axles = state.saved })
		if not ok then
			ErrorNoHalt("[GVoxel] Restauration suspension HL2 impossible : " .. tostring(root) .. "\n")
			return false
		end
	end
	if IsValid(root) then returning[root] = { saved = state.saved, ticks = 3 } end
	states[root] = nil
	return true
end
V.ReleaseHL2WheelSupport = restore
function V.ReleaseHL2WheelSimulation()
	for root in pairs(states) do
		restore(root)
	end
end

local function prepare(root, region)
	if
		not root.GetWheelCount
		or not root.GetVehicleParams
		or not root.SetVehicleParams
		or V.VoxelVehicleFamily(root) ~= "HL2"
	then
		return
	end
	local count = root:GetWheelCount()
	if count < 2 or count > 16 then
		return
	end -- Seats, airboats and aircraft.
	local handoff = returning[root]
    if handoff then
        pcall(root.SetVehicleParams, root, {axles=handoff.saved})
        returning[root]=nil
    end
	local params = root:GetVehicleParams()
	if
		not params
		or not params.axles
		or #params.axles < 2
		or params.wheelsPerAxle ~= 2
		or #params.axles * 2 ~= count
	then
		return
	end
	local forward = params.axles[1].offset - params.axles[#params.axles].offset
	forward.z = 0
	if forward:LengthSqr() < 1 then
		return
	end
	local state = {
		region = region,
		wheels = {},
		saved = {},
		params = params,
		forward = forward:GetNormalized(),
		contacts = 0,
		queries = 0,
	}
	-- Admission already guarantees complete cooked terrain + exterior meshes.
	-- Raycast those exact active shapes in C++, bypassing BSP and avoiding any
	-- cold Lua SAT/geometry construction in the suspension tick.
	state.query = {
		mask = MASK_SOLID,
		ignoreworld = true,
		filter = function(ent)
			if
				ent == root
				or ent == state.driver
				or ent == state.assemblyRoot
				or ent.VMVehicleRoot == state.assemblyRoot
			then
				return false
			end
			if ent.VMVoxelCollider then
				return ent.VMActive == true and not ent.VMGuard and ent.VMVoxelRegion == region
			end
			return true
		end,
	}
	local patch = { axles = {} }
	for i, axle in ipairs(params.axles) do
		local radius = axle.wheels_radius
		if not radius or radius <= 0 or radius > 256 then
			return
		end
		state.saved[i] = {}
		patch.axles[i] = {}
		for _, field in ipairs(fields) do
			if type(axle[field]) ~= "number" then
				return
			end
			state.saved[i][field] = axle[field]
			patch.axles[i][field] = 0
		end
		for side = 0, 1 do
			local index = (i - 1) * 2 + side
			local wheel = root:GetWheel(index)
			if not IsValid(wheel) then
				return
			end
			local travel = clamp(math.abs(root:GetWheelTotalHeight(index)), 4, 64)
			state.wheels[#state.wheels + 1] = {
				anchor = axle.offset + axle.wheelOffset * (side == 0 and -1 or 1),
				radius = radius,
				travel = travel,
				front = i == 1,
				drive = math.max(0, axle.torqueFactor),
			}
		end
	end
	returning[root] = nil
	-- Save before changing anything, including partial setter failures.
	states[root] = state
	local ok = pcall(root.SetVehicleParams, root, patch)
	local after = ok and root:GetVehicleParams()
	for i, axle in ipairs(patch.axles) do
		for field, value in pairs(axle) do
			if
				not after
				or not after.axles
				or not after.axles[i]
				or math.abs((after.axles[i][field] or math.huge) - value) > 0.0001
			then
				ok = false
			end
		end
	end
	if not ok then
		restore(root)
		root.VMHL2WheelError = "parametres suspension refuses"
		return
	end
	root.VMHL2WheelError = nil
	return state
end

-- Forces are integrated once per server tick, with a tyre budget proportional
-- to actual normal load. No contact => no traction or invisible floor.
function V.HL2WheelImpulse(normal, up, forward, velocity, compression, mass, gravity, dt, throttle, brake, maxSpeed)
	local alignment = normal:Dot(up)
	if alignment < 0.25 then
		return Vector(), 0
	end
	local load = mass * clamp(gravity * alignment + 100 * compression - 20 * velocity:Dot(normal), 0, gravity * 6)
	local tangent = forward - normal * forward:Dot(normal)
	if tangent:LengthSqr() < 0.0001 then
		return normal * (load * dt), load
	end
	tangent = tangent:GetNormalized()
	local lateral = tangent:Cross(normal)
	local speed = velocity:Dot(tangent)
	local accel = throttle * 320
	if throttle * speed > 0 then
		accel = accel * clamp(1 - math.abs(speed) / math.max(1, maxSpeed), 0, 1)
	end
	local longitudinal = mass * (accel * dt - speed * (1 - math.exp(-dt * (brake and 12 or 0.2))))
	local sideways = -mass * velocity:Dot(lateral) * (1 - math.exp(-dt * 10))
	local friction = tangent * longitudinal + lateral * sideways
	local limit = load * dt * 1.1
	if friction:LengthSqr() > limit * limit then
		friction = friction:GetNormalized() * limit
	end
	return normal * (load * dt) + friction, load
end

local function simulate(root, state, dt)
	state.contacts = 0
	state.queries = 0
	state.startsSolid = 0
	state.recoveries = 0
	local phys = root:GetPhysicsObject()
	if not IsValid(phys) or not phys:IsMotionEnabled() then
		return
	end
	-- Sleeping empty cars do not consume terrain queries until disturbed.
	local driver = root:GetDriver()
	state.driver = driver
	if phys:IsAsleep() and not IsValid(driver) then
		state.contacts = 0
		state.queries = 0
		return
	end
	local up = root:GetUp()
	local forward = (root:LocalToWorld(state.forward) - root:GetPos()):GetNormalized()
	local right = forward:Cross(up):GetNormalized()
	local steering, throttle, brake = 0, 0, false
	if IsValid(driver) then
		steering = (driver:KeyDown(IN_MOVERIGHT) and 1 or 0) - (driver:KeyDown(IN_MOVELEFT) and 1 or 0)
		brake = driver:KeyDown(IN_JUMP)
		local requested = (driver:KeyDown(IN_FORWARD) and 1 or 0) - (driver:KeyDown(IN_BACK) and 1 or 0)
		if state.input and CurTime() - state.input.time < 0.25 then
			steering = state.input.steering
			brake = state.input.brake
			requested = state.input.throttle
		end
		-- Native throttle may be zeroed by its old BSP wheel contact result.
		-- Read the driver's command before that C++ ground check instead.
		if root:IsEngineStarted() and not root:IsVehicleBodyInWater() then
			throttle = requested
		end
	else
		brake = true
	end
	-- Native script steering rates/speed limits still define the car's feel.
	state.steer = (state.steer or 0) + (steering - (state.steer or 0)) * math.min(1, dt * 5)
	local p = state.params
	local slow = p.steering and p.steering.degreesSlow or 35
	local fast = p.steering and p.steering.degreesFast or slow
	local speed = math.abs(phys:GetVelocityAtPoint(phys:GetPos()):Dot(forward))
	local ratio = clamp(speed / math.max(1, p.engine and p.engine.maxSpeed or 600), 0, 1)
	local degrees = (slow + (fast - slow) * ratio) * state.steer
	local angle = math.rad(clamp(degrees, -55, 55))
	local steered = forward * math.cos(angle) + right * math.sin(angle)
	local engine = p.engine or {}
	local maxSpeed = throttle < 0 and engine.maxRevSpeed
		or (root:IsBoosting() and engine.boostMaxSpeed or engine.maxSpeed)
	local gravity = physenv.GetGravity():Length()
	local mass = phys:GetMass() * (1 + math.max(0, p.body and p.body.addGravity or 0)) / #state.wheels
	local center = phys:LocalToWorld(phys:GetMassCenter())
	local impulse, torque = Vector(), Vector()
	for _, wheel in ipairs(state.wheels) do
		local hub = root:LocalToWorld(wheel.anchor)
		local start = hub + up * (wheel.travel * 0.5)
		local finish = hub - up * (wheel.radius + wheel.travel)
		local trace = state.query
		trace.start = start
		trace.endpos = finish
		local hit = nativeTrace(trace)
		state.queries = state.queries + 1
		if hit.StartSolid or hit.AllSolid then
			-- A transition/step can put the short probe's origin inside a
			-- cooked shape. Rejecting that result forever only recovers when
			-- the chassis is manually lifted. Retry ONCE from above this
			-- wheel's bounded suspension envelope, against the same active
			-- shapes. No BSP fallback, teleports or remembered phantom floor.
			state.startsSolid = state.startsSolid + 1
			trace.start = hub + up * (wheel.radius + wheel.travel + 2)
			hit = nativeTrace(trace)
			state.queries = state.queries + 1
			if hit.Hit and not hit.StartSolid and not hit.AllSolid then
				local distance = (hub - hit.HitPos):Dot(up)
				if
					distance >= -wheel.radius
					and distance <= wheel.radius + wheel.travel
					and hit.HitNormal:Dot(up) >= 0.25
				then
					state.recoveries = state.recoveries + 1
				else
					hit = { Hit = false }
				end
			end
		end
		if hit.Hit and not hit.StartSolid and not hit.AllSolid and hit.HitNormal:Dot(up) >= 0.25 then
			local distance = (hub - hit.HitPos):Dot(up)
			local compression = wheel.travel * 0.5 - (distance - wheel.radius)
			local support = hit.Entity
			local supportPhys = IsValid(support) and support.GetPhysicsObject and support:GetPhysicsObject()
			local velocity = phys:GetVelocityAtPoint(hit.HitPos)
			if IsValid(supportPhys) then
				velocity = velocity - supportPhys:GetVelocityAtPoint(hit.HitPos)
			end
			local force = V.HL2WheelImpulse(
				hit.HitNormal,
				up,
				wheel.front and steered or forward,
				velocity,
				compression,
				mass,
				gravity,
				dt,
				wheel.drive > 0 and throttle or 0,
				brake,
				maxSpeed or 600
			)
			impulse = impulse + force
			torque = torque + (hit.HitPos - center):Cross(force)
			state.contacts = state.contacts + 1
			if IsValid(supportPhys) and supportPhys:IsMotionEnabled() then
				supportPhys:Wake()
				supportPhys:ApplyForceCenter(force * -1)
				supportPhys:ApplyTorqueCenter(
					(hit.HitPos - supportPhys:LocalToWorld(supportPhys:GetMassCenter())):Cross(force * -1)
						* TORQUE_UNITS
				)
			end
		end
	end
	if state.contacts > 0 then
		phys:ApplyForceCenter(impulse)
		phys:ApplyTorqueCenter(torque * TORQUE_UNITS)
	end
end
V.HL2WheelStates = states
hook.Add("StartCommand", "GVoxel.HL2WheelInput", function(ply, cmd)
	local root = ply:GetVehicle()
	local state = states[root]
	if not state then
		return
	end
	local throttle = (cmd:KeyDown(IN_FORWARD) and 1 or 0) - (cmd:KeyDown(IN_BACK) and 1 or 0)
	local steering = (cmd:KeyDown(IN_MOVERIGHT) and 1 or 0) - (cmd:KeyDown(IN_MOVELEFT) and 1 or 0)
	state.input = state.input or {}
	state.input.throttle = throttle ~= 0 and throttle or clamp(cmd:GetForwardMove() / 400, -1, 1)
	state.input.steering = steering ~= 0 and steering or clamp(cmd:GetSideMove() / 400, -1, 1)
	state.input.brake = cmd:KeyDown(IN_JUMP)
	state.input.time = CurTime()
end)
hook.Add("Tick", "GVoxel.HL2Wheels", function()
    -- Let world NoCollide removal settle, then rebuild the native contacts.
    -- A short verified handoff replaces the manual Physgun lift/drop cycle.
    for root, entry in pairs(returning) do
        if not IsValid(root) or states[root] then returning[root] = nil
        else
            local params = root:GetVehicleParams()
            local matches = true
            for index, axle in ipairs(entry.saved) do
                for field, value in pairs(axle) do
                    local actual = params and params.axles and params.axles[index] and params.axles[index][field]
                    if type(actual) ~= "number" or math.abs(actual-value) > 0.0001 then matches=false end
                end
            end
            if not matches then
                pcall(root.SetVehicleParams, root, {axles=entry.saved})
                params=root:GetVehicleParams() matches=true
                for index,axle in ipairs(entry.saved) do for field,value in pairs(axle) do
                    local actual=params and params.axles and params.axles[index] and params.axles[index][field]
                    if type(actual)~="number" or math.abs(actual-value)>0.0001 then matches=false end
                end end
            end
            refreshContacts(root)
            entry.ticks=entry.ticks-1
            if entry.ticks<=0 then
                if not matches then root.VMHL2WheelError="native suspension restoration not confirmed" end
                returning[root]=nil
            end
        end
    end
	for root, state in pairs(states) do
		local assembly = IsValid(root) and V.VehicleStates[root.VMVehicleRoot or root]
		if not IsValid(root) or not assembly or assembly.region ~= state.region then
			restore(root)
		end
	end
	local dt = math.min(engine.TickInterval(), 0.05)
	for assemblyRoot, assembly in pairs(V.VehicleStates) do
		for _, root in ipairs(assembly.parts) do
			if IsValid(root) then
				local state = states[root]
				if not state and not root.VMHL2WheelError then
					state = prepare(root, assembly.region)
				end
				if state then
					state.assemblyRoot = assemblyRoot
					local started = SysTime()
					simulate(root, state, dt)
					state.ms = (SysTime() - started) * 1000
					state.maxMs = math.max(state.maxMs or 0, state.ms)
				end
			end
		end
	end
end)
hook.Add("ShutDown", "GVoxel.ReleaseHL2Wheels", V.ReleaseHL2WheelSimulation)
concommand.Add("vm_hl2_wheel_stats", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then
		return
	end
	for root, state in pairs(states) do
		print(
			string.format(
				"[GVoxel] Roues HL2 %s : %d / %d contacts ; %d sondes/tick ; %d departs solides / %d appuis recuperes ; %.3f ms (pic %.3f)",
				tostring(root),
				state.contacts,
				#state.wheels,
				state.queries,
				state.startsSolid or 0,
				state.recoveries or 0,
				state.ms or 0,
				state.maxMs or 0
			)
		)
	end
	for root in pairs(V.VehicleStates) do
		if root.VMHL2WheelError then
			print("[GVoxel] " .. tostring(root) .. " : " .. root.VMHL2WheelError)
		end
	end
end)
