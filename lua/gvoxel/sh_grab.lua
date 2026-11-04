-- Supplement the engine physgun only when its BSP trace hides a visible body
-- inside a voxel cavity. Selection, permissions and physics stay server-side.
local V = GVoxel
if SERVER then
	V.VoxelGrabs = V.VoxelGrabs or {}
	local grabs = V.VoxelGrabs
	local function stop(ply)
		local grab = grabs[ply]
		if not grab then
			return
		end
		grabs[ply] = nil
		if IsValid(ply) then
			ply:SetNW2Entity("VM_GrabEntity", NULL)
		end
		if IsValid(grab.ent) then
			grab.ent.VMVoxelGrabber = nil
			if IsValid(ply) then
				hook.Run("PhysgunDrop", ply, grab.ent)
			end
		end
	end
	function V.ReleaseVoxelGrabs(r)
		for ply, grab in pairs(grabs) do
			if not r or grab.region == r then
				stop(ply)
			end
		end
	end
	function V.BeginVoxelGrab(ply, weapon)
		if grabs[ply] then
			return false
		end
		local r = V.GetServerMovementRegion(ply)
		if not r or not r.propPhysics or r.propPhysics.jobs or r.propPhysics.failed then
			return false
		end
		local range = GetConVar("physgun_maxrange")
		local reach = math.Clamp(range and range:GetFloat() or 4096, 64, 8192)
		local start = ply:GetShootPos()
		local direction = ply:GetAimVector()
		local function trace(a, b, ignore)
			return util.TraceLine({
				start = a,
				endpos = b,
				ignoreworld = ignore,
				mask = MASK_SOLID,
				filter = function(ent)
					return ent ~= ply and not ent.VMVoxelCollider
				end,
			})
		end
		local native = trace(start, start + direction * reach, false)
		local hidden = (native.HitWorld and native.HitPos and V.InScanCube(r, native.HitPos))
			or (native.StartSolid and V.InScanCube(r, start))
		if not hidden then
			return false
		end
		local hit = V.ResolveSculptTrace(r, start, direction, reach, trace, native)
		local ent = hit.Entity
		if
			not IsValid(ent)
			or ent:IsWorld()
			or ent:IsPlayer()
			or ent.VMVoxelCollider
			or ent.VMVoxelGrabber
			or (ent.IsPlayerHolding and ent:IsPlayerHolding())
			or not hit.HitPos
		then
			return false
		end
		if hook.Run("PhysgunPickup", ply, ent) == false then
			return false
		end
		local enrolled = V.TryEnrollVoxelBody(r, ent)
		-- A prop beyond the far side of the cube can be visible through the
		-- hole. Keep its native world collision until it enters the region.
		if not enrolled and (V.InScanCube(r, hit.HitPos) or not V.NativeBodyFree(ent, ent:GetPos())) then
			return false
		end
		local bone = math.max(0, math.min(ent:GetPhysicsObjectCount() - 1, hit.PhysicsBone or 0))
		local phys = ent:GetPhysicsObjectNum(bone)
		if not IsValid(phys) then
			return false
		end
		local distance = math.sqrt(start:DistToSqr(hit.HitPos))
		local grab = {
			ent = ent,
			phys = phys,
			bone = bone,
			region = r,
			weapon = weapon,
			reach = reach,
			distance = math.max(40, distance),
			point = phys:WorldToLocal(hit.HitPos),
			angle = phys:GetAngles(),
			last = CurTime(),
			enrolled = enrolled,
		}
		grabs[ply] = grab
		ent.VMVoxelGrabber = ply
		phys:EnableMotion(true)
		phys:Wake()
		ply:SetNW2Entity("VM_GrabEntity", ent)
		ply:SetNW2Vector("VM_GrabPoint", ent:WorldToLocal(hit.HitPos))
		return true
	end
	hook.Add("StartCommand", "GVoxel.PhysgunCommands", function(ply, cmd)
		local weapon = ply:GetActiveWeapon()
		local allowed = ply:Alive()
			and not ply:InVehicle()
			and IsValid(weapon)
			and weapon:GetClass() == "weapon_physgun"
		if ply.VMGrabMustRelease then
			if cmd:KeyDown(IN_ATTACK) then
				cmd:RemoveKey(IN_ATTACK)
				return
			end
			ply.VMGrabMustRelease = nil
		end
		if not allowed or not cmd:KeyDown(IN_ATTACK) then
			ply.VMGrabAttempted = nil
			stop(ply)
			return
		end
		-- One authoritative selection per press, including misses. Holding
		-- the button against an intact wall must not trace it eight times/s.
		if not grabs[ply] and not ply.VMGrabAttempted then
			ply.VMGrabAttempted = true
			V.BeginVoxelGrab(ply, weapon)
		end
		local grab = grabs[ply]
		if not grab then
			return
		end
		cmd:RemoveKey(IN_ATTACK)
		grab.distance = math.Clamp(grab.distance + cmd:GetMouseWheel() * 24, 40, grab.reach)
		if cmd:KeyDown(IN_USE) then
			grab.angle = Angle(grab.angle.p + cmd:GetMouseY() * 0.3, grab.angle.y + cmd:GetMouseX() * 0.3, grab.angle.r)
		end
		if cmd:KeyDown(IN_ATTACK2) then
			cmd:RemoveKey(IN_ATTACK2)
			if hook.Run("OnPhysgunFreeze", weapon, grab.phys, grab.ent, ply) ~= false then
				grab.phys:EnableMotion(false)
				stop(ply)
				-- Require releasing LMB before another fallback pickup.
				ply.VMGrabMustRelease = true
			end
		end
	end)
	hook.Add("Think", "GVoxel.PhysgunHold", function()
		for ply, grab in pairs(grabs) do
			if
				not IsValid(ply)
				or not ply:Alive()
				or ply:InVehicle()
				or not IsValid(grab.ent)
				or not IsValid(grab.phys)
				or ply:GetActiveWeapon() ~= grab.weapon
				or not grab.region.propPhysics
			then
				stop(ply)
			else
				grab.enrolled = grab.ent.VMPropRegion == grab.region
				if not grab.enrolled then
					grab.enrolled = V.TryEnrollVoxelBody(grab.region, grab.ent)
				end
				local now = CurTime()
				local dt = math.Clamp(now - grab.last, 0.001, 0.05)
				grab.last = now
				local hit = ply:GetShootPos() + ply:GetAimVector() * grab.distance
				local offset = grab.phys:LocalToWorld(grab.point) - grab.phys:GetPos()
				local target = hit - offset
				local current = grab.phys:GetPos()
				local delta = target - current
				local length = math.sqrt(delta:LengthSqr())
				if length > 1000 * dt then
					target = current + delta * (1000 * dt / length)
				end
				-- VPhysics resolves contacts against prepared voxel colliders.
				-- An entity AABB at a physics-bone origin is neither that body
				-- nor its rotated shape, and pins floor-touching props in place.
				grab.phys:ComputeShadowControl({
					pos = target,
					angle = grab.angle,
					secondstoarrive = 0.04,
					maxangular = 5000,
					maxangulardamp = 10000,
					maxspeed = 1000,
					maxspeeddamp = 2000,
					dampfactor = 0.8,
					teleportdistance = 0,
					delta = dt,
				})
				grab.phys:Wake()
			end
		end
	end)
	hook.Add("PlayerDisconnected", "GVoxel.PhysgunDisconnect", stop)
	hook.Add("PlayerDeath", "GVoxel.PhysgunDeath", stop)
	return
end

local beam = Material("cable/physbeam")
hook.Add("DrawPhysgunBeam", "GVoxel.HideNativeFallbackBeam", function(ply)
	if V.RenderingReplacement or V.CapturingSurface then
		return false
	end
	if IsValid(ply:GetNW2Entity("VM_GrabEntity")) then
		return false
	end
end)
hook.Add("PostDrawTranslucentRenderables", "GVoxel.DrawFallbackGrab", function(depth, _, sky3D)
	if depth or sky3D or V.RenderingReplacement or V.ComposingTerrain or V.MaskInSkybox then
		return
	end
	for _, ply in ipairs(player.GetAll()) do
		local ent = ply:GetNW2Entity("VM_GrabEntity")
		if IsValid(ent) then
			local weapon = ply:GetActiveWeapon()
			local model = ply == LocalPlayer() and not ply:ShouldDrawLocalPlayer() and ply:GetViewModel() or weapon
			local attachment = IsValid(model) and model:GetAttachment(1)
			local start = attachment and attachment.Pos or ply:GetShootPos()
			local finish = ent:LocalToWorld(ply:GetNW2Vector("VM_GrabPoint"))
			render.SetMaterial(beam)
			render.DrawBeam(start, finish, 2, 0, 1, Color(100, 190, 255))
		end
	end
end)
