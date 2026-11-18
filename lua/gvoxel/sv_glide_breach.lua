local V = GVoxel
local abs, min, max, ceil = math.abs, math.min, math.max, math.ceil
local metre = V.UnitsPerMetre
local lookahead = 10 * metre
local wallLimit = 0.5 * metre
local thinWall = 0.3 * metre
local minimumSpeed = 50 / 3.6 * metre
local lightCarMass, heavyCarMass = 500, 750
local impactWheels = {
    empire_vp_wheel = true,
    lvs_wheeldrive_wheel = true,
    gmod_sent_vehicle_fphysics_wheel = true,
}
local zero, up = Vector(), Vector(0, 0, 1)
local padding = Vector(1, 1, 1) * lookahead
local tolerance = 0.125

local function driver(vehicle)
    local owner = vehicle.GetDriver and vehicle:GetDriver()
    if IsValid(owner) then return owner end
    local seat = vehicle.GetDriverSeat and vehicle:GetDriverSeat()
    if IsValid(seat) and seat.GetDriver then return seat:GetDriver() end
end

local function roadVehicle(vehicle, family)
    if family == "HL2" then
        return vehicle.GetWheelCount and vehicle:GetWheelCount() >= 2
            and vehicle:GetClass() ~= "prop_vehicle_airboat"
    end
    if family == "Glide" then return (vehicle.wheelCount or 0) > 0 end
    if family == "EVP" then return vehicle.EVPProfile and next(vehicle.EVPProfile.wheels or {}) ~= nil end
    return family == "LVS" or family == "Simfphys"
end

local function impactSpeed(velocity, mass, normal, thickness)
    local speed = -velocity:Dot(normal)
    local additional = max(0, ((thickness or 0) - thinWall) / (wallLimit - thinWall))
    local momentum = minimumSpeed * (lightCarMass + (heavyCarMass - lightCarMass) * additional)
    if speed >= minimumSpeed and speed * mass >= momentum then return speed end
end

local function vehicleMass(vehicle, chassisBody)
    local mass = chassisBody:GetMass()
    -- EVP splits the rated mass between the chassis and physical wheels.
    local profile = vehicle.EVPProfile
    if profile and profile.wheels then
        for _, wheel in ipairs(profile.wheels) do
            local ent = wheel.entity
            local body = IsValid(ent) and ent:GetPhysicsObject()
            if IsValid(body) then mass = mass + body:GetMass() end
        end
    end
    return mass
end

local function projection(extent, normal)
    return abs(normal.x) * extent.x + abs(normal.y) * extent.y + abs(normal.z) * extent.z
end

local function pointTrace(r, a, b, checkpoint)
    return V.TraceVoxelHull(r, a, b, zero, zero, checkpoint)
end

local function chassis(vehicle)
    local low, high = vehicle:WorldSpaceAABB()
    return (low + high) / 2, (high - low) / 2
end

local function gravity(vehicle, velocity)
    if vehicle.IsGlideVehicle then
        for _, wheel in pairs(vehicle.wheels or {}) do
            if IsValid(wheel) and wheel.state and wheel.state.isOnGround then return zero end
        end
    elseif vehicle.EVPProfile and vehicle.EVPProfile.wheels then
        for _, wheel in ipairs(vehicle.EVPProfile.wheels) do
            if (wheel.supportLoad or 0) > 0 then return zero end
        end
    elseif (vehicle.DriveWheelsOnGround or 0) > 0 or abs(velocity.z) < 16 then
        -- Native HL2/LVS do not expose the same ground state as Glide.
        -- A level approach can still be prepared without dropping the ray.
        return zero
    end
    return physenv.GetGravity()
end

-- This callback runs inside VPhysics. Remember the hit and let the existing
-- scan job edit terrain on Think, after the collision has been processed.
function V.RecordVehicleBreachImpact(vehicle, data)
    local scan = V.GetScanSession()
    if not scan or not scan.completed or scan.failed or not IsValid(vehicle) then return end
    local r, other = scan.region, data.HitEntity
    local voxel = IsValid(other) and other.VMActive and other.VMVoxelRegion == r
        and not other.VMGuard and not other.VMVehicleExterior
    if not voxel and not (other and other.IsWorld and other:IsWorld()) then return end
    local point, normal, velocity = data.HitPos, data.HitNormal, data.OurOldVelocity
    if not point or not normal or not velocity or abs(normal.z) > 0.3
        or not V.HullNearScan(r, point, zero, zero, 6) then return end
    local phys, owner = vehicle:GetPhysicsObject(), driver(vehicle)
    if not IsValid(phys) or not IsValid(owner) or not V.CanEdit(owner, r) then return end
    if velocity:Dot(normal) > 0 then normal = -normal end
    local mass = vehicleMass(vehicle, phys)
    local speed = impactSpeed(velocity, mass, normal)
    if not speed then return end
    scan.vehicleImpacts = scan.vehicleImpacts or {}
    local previous = scan.vehicleImpacts[vehicle]
    if previous and previous.expires > CurTime() and previous.speed >= speed then return end
    scan.vehicleImpacts[vehicle] = {
        vehicle = vehicle, driver = owner, point = point, normal = normal,
        velocity = velocity, mass = mass, speed = speed, expires = CurTime() + 1.25,
    }
end

local function watchCollision(ent, root)
    if ent.VMVehicleBreachCallback or not ent.AddCallback then return end
    if ent.VMGlideImpactCallback and ent.RemoveCallback then
        ent:RemoveCallback("PhysicsCollide", ent.VMGlideImpactCallback)
        ent.VMGlideImpactCallback = nil
    end
    ent.VMVehicleBreachCallback = ent:AddCallback("PhysicsCollide", function(entity, data)
        local vehicle = root and V.GetVoxelVehicleRoot(entity) or entity
        -- A detached wheel must never open a wall on its own.
        if not root or vehicle == root then V.RecordVehicleBreachImpact(vehicle, data) end
    end)
end

hook.Add("PlayerEnteredVehicle", "GVoxel.VehicleWallImpact", function(_, seat)
    local vehicle = V.GetVoxelVehicleRoot(seat)
    if vehicle and roadVehicle(vehicle, V.VoxelVehicleFamily(vehicle)) then watchCollision(vehicle) end
end)

function V.NextVehicleBreach(scan)
    local r, now = scan.region, CurTime()
    local physics = r.propPhysics
    if not physics or not physics.exteriorReady or physics.jobs or physics.readyRevision ~= r.revision then return end
    for vehicle, impact in pairs(scan.vehicleImpacts or {}) do
        scan.vehicleImpacts[vehicle] = nil
        if now <= impact.expires and IsValid(vehicle) and driver(vehicle) == impact.driver and V.CanEdit(impact.driver, r) then
            return { source = "vehicle_breach", adding = false, breach = impact }
        end
    end
    if (scan.nextVehicleSearch or 0) > now then return end
    scan.nextVehicleSearch = now + 0.08
    scan.vehicleProbeTimes = scan.vehicleProbeTimes or setmetatable({}, { __mode = "k" })
    local candidate
    for _, ent in ipairs(ents.FindInBox(r.origin - padding, r.origin + V.RegionSize(r) + padding)) do
        local family = V.VoxelVehicleFamily(ent)
        if roadVehicle(ent, family) then
            watchCollision(ent)
            if not candidate and (scan.vehicleProbeTimes[ent] or 0) <= now then
                local owner, phys = driver(ent), ent:GetPhysicsObject()
                if IsValid(phys) and IsValid(owner) and V.CanEdit(owner, r) then
                    local velocity = phys:GetVelocity()
                    if velocity.x ^ 2 + velocity.y ^ 2 >= minimumSpeed ^ 2
                        and velocity:Length() * vehicleMass(ent, phys) >= minimumSpeed * lightCarMass then
                        scan.vehicleProbeTimes[ent] = now + 0.16
                        candidate = {
                            source = "vehicle_breach", adding = false,
                            breach = { vehicle = ent, driver = owner, expires = now + 1 },
                        }
                    end
                end
            end
        elseif ent.GetClass and impactWheels[ent:GetClass()] then
            local root = V.GetVoxelVehicleRoot(ent)
            if root and root ~= ent and roadVehicle(root, V.VoxelVehicleFamily(root)) then watchCollision(ent, root) end
        end
    end
    return candidate
end

local function findWall(r, plan, center, extent, velocity, acceleration, checkpoint)
    if plan.point then
        return pointTrace(r, plan.point + plan.normal * 12, plan.point - plan.normal * 12, checkpoint)
    end
    local direction = velocity:GetNormalized()
    local horizon = (lookahead + projection(extent, direction)) / velocity:Length()
    local segments = acceleration:LengthSqr() > 0 and 3 or 1
    local function along(start)
        local from = start
        for i = 1, segments do
            local time = horizon * i / segments
            local to = start + velocity * time + acceleration * (0.5 * time ^ 2)
            local hit = pointTrace(r, from, to, checkpoint)
            if hit.Hit then return hit end
            from = to
        end
    end
    local hit = along(center)
    if hit and not hit.StartSolid and abs(hit.HitNormal.z) <= 0.25 then return hit end
    -- A corner can strike the wall even when the middle of the nose misses.
    local side = up:Cross(direction):GetNormalized()
    local offset = side * (projection(extent, side) * 0.8)
    for _, point in ipairs({ center + offset, center - offset }) do
        local edge = along(point)
        if edge and not edge.StartSolid and abs(edge.HitNormal.z) <= 0.25
            and (not hit or (edge.HitPos - center):Dot(direction) < (hit.HitPos - center):Dot(direction)) then
            hit = edge
        end
    end
    return hit
end

function V.PrepareVehicleBreach(r, work, checkpoint)
    local plan = work.breach
    local vehicle, impact = plan.vehicle, plan.point ~= nil
    local phys = vehicle:GetPhysicsObject()
    if not IsValid(phys) then return false end
    local velocity, mass = plan.velocity or phys:GetVelocity(), plan.mass or vehicleMass(vehicle, phys)
    if velocity:LengthSqr() < minimumSpeed ^ 2 then return false end
    local center, extent = chassis(vehicle)
    local acceleration = impact and zero or gravity(vehicle, velocity)
    local hit = findWall(r, plan, center, extent, velocity, acceleration, checkpoint)
    if not hit or not hit.Hit or hit.StartSolid or abs(hit.HitNormal.z) > 0.25 then return false end
    local point, normal = hit.HitPos, hit.HitNormal
    local back = pointTrace(r, point - normal * (wallLimit + tolerance), point - normal * tolerance, checkpoint)
    local thickness = (point - back.HitPos):Dot(normal)
    if not back.Hit or back.StartSolid or back.HitNormal:Dot(normal) > -0.7
        or thickness <= tolerance or thickness >= wallLimit then return false end
    local speed = impactSpeed(velocity, mass, normal, thickness)
    if not speed then return false end

    local reach = projection(extent, normal)
    local distance = (center - point):Dot(normal) - reach
    if not impact and distance > lookahead then return false end
    local time = impact and 0 or max(0, distance / speed)
    local arrival = center + velocity * time + acceleration * (0.5 * time ^ 2)
    local tangent = up:Cross(normal):GetNormalized()
    local lateral = (arrival - point):Dot(tangent)
    local drift = velocity:Dot(tangent) * (2 * reach + thickness) / speed
    local width = projection(extent, tangent) + abs(drift) / 2 + metre
    local cut = point - normal * (thickness / 2) + tangent * (lateral + drift / 2)
    local halfDepth = ceil((thickness / 2 + r.step * 1.15 + width * 0.013 + 2) / 2)
    local sill = arrival.z - extent.z
    local bottom, top = sill - metre, arrival.z + extent.z + metre
    local foundGround = false
    local height = abs(velocity.z + acceleration.z * time) * (thickness + r.step) / speed
    top = top + height

    for _, offset in ipairs({ -width * 0.8, 0, width * 0.8 }) do
        for _, side in ipairs({ -1, 1 }) do
            local p = cut + tangent * offset + normal * (side * (halfDepth * 2 + 2))
            p.z = sill + max(12, r.step * 0.65)
            local ground = pointTrace(r, p, Vector(p.x, p.y, sill - metre - r.step), checkpoint)
            if ground.StartSolid then
                bottom = max(bottom, p.z)
            elseif ground.Hit then
                bottom = max(bottom, ground.HitPos.z + (r.bsp and tolerance or r.step))
                foundGround = true
            end
        end
    end
    if not foundGround then bottom = max(bottom, sill - min(12, r.step / 2)) end
    if bottom >= top then return false end
    bottom = ceil(bottom * 8) / 8
    local halfWidth, halfHeight = ceil(width / 2), ceil((top - bottom) / 4)
    cut.z = bottom + halfHeight * 2
    local angle = math.floor(math.atan2(normal.y, normal.x) / math.pi * 128 + 0.5) % 128
    work.center = V.SnapScanPosition(cut)
    work.radius = 2 * max(halfDepth, halfWidth, halfHeight)
    work.shape = { V.VehicleBreachShape, halfDepth, halfWidth, halfHeight, angle }
    plan.wall, plan.faceNormal, plan.thickness = point, normal, thickness
    plan.tangent, plan.width = tangent, width
    return V.ValidShapedStroke(work.shape, work.radius, false)
end

function V.ValidateVehicleBreach(field, work, checkpoint)
    local plan = work.breach
    local point, normal = plan.wall, plan.faceNormal
    local opening = pointTrace(field, point + normal * 2, point - normal * (plan.thickness + 2), checkpoint)
    return not opening.Hit
end

-- A predicted cut can publish just before contact. A verified impact also
-- authorizes publishing after contact, even if VPhysics has stopped the car.
function V.VehicleBreachContact(scan, work)
    local plan, r = work.breach, scan.region
    local vehicle = plan.vehicle
    if not IsValid(vehicle) or driver(vehicle) ~= plan.driver or not V.CanEdit(plan.driver, r) then return end
    if CurTime() > plan.expires then return end
    if not plan.wall then return false end
    local impact = scan.vehicleImpacts and scan.vehicleImpacts[vehicle]
    local normal, tangent = plan.faceNormal, plan.tangent
    if not plan.point and impact and impact.vehicle == vehicle and CurTime() <= impact.expires then
        local offset = impact.point - plan.wall
        if abs(offset:Dot(normal)) <= 8 and abs(offset:Dot(tangent)) < plan.width
            and abs(impact.point.z - work.center.z) < work.shape[4] * 2
            and impact.normal:Dot(normal) > 0.7 and impactSpeed(impact.velocity, impact.mass, normal, plan.thickness) then
            plan.point, plan.expires = impact.point, impact.expires
            scan.vehicleImpacts[vehicle] = nil
        end
    end
    if plan.point then return true end
    local phys = vehicle:GetPhysicsObject()
    if not IsValid(phys) then return end
    local velocity = phys:GetVelocity()
    local speed = impactSpeed(velocity, vehicleMass(vehicle, phys), normal, plan.thickness)
    if not speed then return end
    local center, extent = chassis(vehicle)
    local distance = (center - plan.wall):Dot(normal) - projection(extent, normal)
    if distance < -8 or distance > lookahead then return end
    local time = max(0, distance / speed)
    local arrival = center + velocity * time + gravity(vehicle, velocity) * (0.5 * time ^ 2)
    local halfHeight = work.shape[4] * 2
    if abs((arrival - work.center):Dot(tangent)) + projection(extent, tangent) > plan.width
        or arrival.z + extent.z > work.center.z + halfHeight or arrival.z < work.center.z - halfHeight then return end
    return distance <= speed * engine.TickInterval() * 1.25 + tolerance
end
