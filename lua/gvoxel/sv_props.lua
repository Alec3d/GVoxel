-- Native VPhysics for ordinary props. Only enrolled props bypass the BSP;
-- invisible static colliders follow the refined surface, excluding tiny faces
-- below the VPhysics contact tolerance (see sh_field.lua).
local V = GVoxel
V.PropState = V.PropState or { regions = {}, tracked = {} }
local regions, tracked = V.PropState.regions, V.PropState.tracked
local nextSearch = 0
local held = setmetatable({}, { __mode = "k" })
local budget =
	CreateConVar("vm_prop_build_budget_ms", "2", FCVAR_ARCHIVE, "Budget souple des colliders de props par tick", 0.5, 5)
local axes = { "x", "y", "z" }
local cookStats = { count = 0, total = 0, max = 0, meshTotal = 0 }
V.PropState.cookStats = cookStats
local maxCookVertices = 128 * 3

local function remove(ent)
	if IsValid(ent) then
		for _, part in ipairs(ent.VMAdditionalColliders or {}) do
			if IsValid(part) then
				part:Remove()
			end
		end
		ent:Remove()
	end
end
local function activateCollider(ent)
	if not IsValid(ent) then
		return
	end
	ent.VMActive = true
	ent:CollisionRulesChanged()
	for _, part in ipairs(ent.VMAdditionalColliders or {}) do
		part.VMActive = true
		part:CollisionRulesChanged()
	end
end
local function worldFree(ent, pos)
	local a, b = ent:WorldSpaceAABB()
	local origin = ent:GetPos()
	local tr = util.TraceHull({
		start = pos,
		endpos = pos,
		mins = a - origin,
		maxs = b - origin,
		mask = MASK_SOLID_BRUSHONLY,
		filter = function(e)
			return e:IsWorld()
		end,
	})
	return not tr.StartSolid and not tr.AllSolid
end
local function contained(r, ent, margin)
	local a, b = ent:WorldSpaceAABB()
	for _, axis in ipairs(axes) do
		if a[axis] < r.origin[axis] + margin or b[axis] > r.origin[axis] + V.RegionAxisSize(r, axis) - margin then
			return false
		end
	end
	return true
end
local function eligible(ent)
	if not IsValid(ent) or tracked[ent] then
		return false
	end
	local class = ent:GetClass()
	local supported = class == "prop_physics"
		or class == "prop_physics_multiplayer"
		or class == "prop_ragdoll"
		or class == "prop_vehicle_jeep_old"
		or class == "prop_vehicle_jeep"
		or class == "prop_vehicle_airboat"
		or class == "prop_vehicle_prisoner_pod"
		or class == "prop_vehicle_apc"
		or class == "gmod_light"
		or class == "gmod_lamp"
		or (ent.IsNPC and ent:IsNPC() and ent.GetMoveType and ent:GetMoveType() == MOVETYPE_VPHYSICS)
	if not supported then
		return false
	end
	if
		ent:GetPhysicsObjectCount() < 1
		or ent:GetPhysicsObjectCount() > 64
		or IsValid(ent:GetParent())
		or not IsValid(ent:GetPhysicsObject())
	then
		return false
	end
	-- External constraints need a whole-assembly transfer. Leave those under
	-- native physics; unconstrained ragdolls are transferred one bone at a time.
	if constraint.GetTable then
		for _, link in pairs(constraint.GetTable(ent) or {}) do
			-- The Light tool's default attachment is a flexible rope, not a
			-- rigid assembly. Keep the rope and its anchor; it still limits reach.
			if (class ~= "gmod_light" and class ~= "gmod_lamp") or link.Type ~= "Rope" then
				return false
			end
		end
	end
	return true
end
V.VoxelBodyContained = contained
V.NativeBodyFree = worldFree
function V.FindNativeBodySafe(r, ent, preferred)
	if preferred and worldFree(ent, preferred) then
		return preferred
	end
	local pos = ent:GetPos()
	if worldFree(ent, pos) then
		return pos
	end
	for up = 16, r.side + 1024, 16 do
		local candidate = pos + Vector(0, 0, up)
		if worldFree(ent, candidate) then
			return candidate
		end
	end
end
local function eachBody(ent, fn)
	local wheels = ent.GetWheelCount and ent.GetWheel
	local seen = wheels and {}
	for bone = 0, ent:GetPhysicsObjectCount() - 1 do
		local phys = ent.GetPhysicsObjectNum and ent:GetPhysicsObjectNum(bone) or ent:GetPhysicsObject()
		if IsValid(phys) then
			if seen then
				seen[phys] = true
			end
			fn(phys, bone)
		end
	end
	-- Vehicle wheels can be separate native bodies, outside the entity's
	-- numbered body list. Wake/restore them too. NoCollide is entity-wide;
	-- wheel indices are NOT ragdoll physics-bone indices.
	if wheels then
		for wheel = 0, math.min(ent:GetWheelCount(), 16) - 1 do
			local phys = ent:GetWheel(wheel)
			if IsValid(phys) and not seen[phys] then
				seen[phys] = true
				fn(phys)
			end
		end
	end
end
V.EachVoxelBody = eachBody

local function makeCollider(r, origin, vertices)
	if #vertices == 0 then
		return false
	end
	local ent = ents.Create("vm_voxel_collider")
	if not IsValid(ent) then
		return nil
	end
	ent.VMVoxelCollider = true
	ent.VMVoxelRegion = r
	ent.VMActive = false
	ent:SetPos(origin)
	ent:Spawn()
	local started = SysTime()
	local ok, built = pcall(ent.PhysicsFromMesh, ent, vertices, "dirt")
	local elapsed = (SysTime() - started) * 1000
	cookStats.count = cookStats.count + 1
	cookStats.total = cookStats.total + elapsed
	cookStats.max = math.max(cookStats.max, elapsed)
	if not ok or not built then
		remove(ent)
		return nil
	end
	-- Ray broadphase must cover the triangle soup, not the placeholder model.
	local low, high = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for _, p in ipairs(vertices) do
		for _, axis in ipairs({ "x", "y", "z" }) do
			low[axis] = math.min(low[axis], p[axis])
			high[axis] = math.max(high[axis], p[axis])
		end
	end
	ent:SetCollisionBounds(low - Vector(0.1, 0.1, 0.1), high + Vector(0.1, 0.1, 0.1))
	ent:SetMoveType(MOVETYPE_NONE)
	ent:SetSolid(SOLID_VPHYSICS)
	ent:EnableCustomCollisions(true)
	ent:SetCustomCollisionCheck(true)
	local phys = ent:GetPhysicsObject()
	if not IsValid(phys) then
		remove(ent)
		return nil
	end
	phys:EnableMotion(false)
	return ent
end

-- Enrolled bodies cannot escape into unconverted solid BSP at a cube edge.
-- Above the old surface they recover normal world collision BEFORE this guard.
local function guardVertices(r)
	local vertices = {}
	for _, face in ipairs(V.MaskFaces(r)) do
		local p = face.vertices
		for _, indices in ipairs({ { 1, 2, 3 }, { 1, 3, 4 }, { 3, 2, 1 }, { 4, 3, 1 } }) do
			for _, i in ipairs(indices) do
				vertices[#vertices + 1] = p[i] - r.origin
			end
		end
	end
	return vertices
end

local function wakeChangedProps(r, dirty)
	local boxes = {}
	for _, c in pairs(dirty) do
		local low = r.origin + Vector(c[1], c[2], c[3]) * (r.step * 8) - Vector(1, 1, 1) * r.step
		boxes[#boxes + 1] = { low, low + Vector(10, 10, 10) * r.step }
	end
	for ent, record in pairs(tracked) do
		if record.region == r and IsValid(ent) then
			local a, b = ent:WorldSpaceAABB()
			for _, box in ipairs(boxes) do
				local low, high = box[1], box[2]
				if
					a.x <= high.x
					and b.x >= low.x
					and a.y <= high.y
					and b.y >= low.y
					and a.z <= high.z
					and b.z >= low.z
				then
					eachBody(ent, function(phys)
						phys:Wake()
					end)
					break
				end
			end
		end
	end
end

local function publishPhysics(r, physics)
	for key, ent in pairs(physics.staged) do
		remove(physics.colliders[key])
		physics.colliders[key] = ent
		activateCollider(ent)
	end
	wakeChangedProps(r, physics.dirty)
	physics.jobs = nil
	physics.staged = {}
	physics.dirty = {}
	physics.readyRevision = physics.targetRevision
	if physics.targetRevision == r.revision then
		r.terrainCache = physics.field.terrainCache
	end
	physics.field = nil
	physics.preparedRevision = nil
	physics.deferPublish = nil
	local pending = physics.pendingDirty
	physics.pendingDirty = nil
	if pending and next(pending) then
		V.QueuePropColliders(r, pending)
	end
end

function V.QueuePropColliders(r, dirty, requested, field)
	local physics = r.propPhysics
	if not physics then
		return
	end
	if not physics.initialized then
		-- Player movement uses its own local hull queries. An empty zone
		-- must not cook 64 VPhysics chunks because of its first excavation.
		-- Wait for an eligible body, then build the complete current support
		-- BEFORE that body is allowed to bypass the native BSP.
		if not requested then
			physics.waiting = r.revision > 0
			return
		end
		physics.waiting = nil
		dirty = {}
		V.ForChunks(function(x, y, z)
			dirty[V.ChunkKey(x, y, z)] = { x, y, z }
		end, r)
		physics.initialized = true
	end
	if physics.jobs and not physics.failed then
		physics.pendingDirty = physics.pendingDirty or {}
		for key, c in pairs(dirty) do
			physics.pendingDirty[key] = c
		end
		return
	end
	local pending = {}
	for key, c in pairs(physics.dirty or {}) do
		pending[key] = c
	end
	for key, c in pairs(dirty) do
		pending[key] = c
	end
	physics.staged = physics.staged or {}
	-- Retain completed/current work outside the new brush. A rapid sequence
	-- must not throw away every staged collider and restart the entire union.
	for key in pairs(dirty) do
		remove(physics.staged[key])
		physics.staged[key] = nil
		if physics.current and physics.current.key == key then
			remove(physics.current.collider)
			physics.current = nil
		end
	end
	physics.dirty = pending
	physics.jobs = {}
	physics.failed = false
	for key, c in pairs(pending) do
		if physics.staged[key] == nil and (not physics.current or physics.current.key ~= key) then
			physics.jobs[#physics.jobs + 1] = { key = key, x = c[1], y = c[2], z = c[3] }
		end
	end
	if r.vehicleExterior and not physics.exteriorQueued then
		for key, group in pairs(r.vehicleExterior.groups) do
			physics.jobs[#physics.jobs + 1] = { key = "exterior:" .. key, exterior = group }
		end
		physics.exteriorQueued = true
	end
	physics.targetRevision = (field or r).revision
	-- Fields are immutable while a transaction is prepared. The edit job
	-- already owns a private copy; do not clone all its density samples again.
	physics.field = field or (r.revision == 0 and r or V.CloneScanField(r))
end

function V.StagePropEdit(r, field, dirty)
	if not r.propPhysics then
		return
	end
	r.propPhysics.deferPublish = true
	V.QueuePropColliders(r, dirty, true, field)
end
function V.PropEditReady(r, revision)
	local physics = r.propPhysics
	return not physics or (not physics.failed and physics.preparedRevision == revision)
end
function V.CommitPropEdit(r)
	if r.propPhysics and r.propPhysics.preparedRevision == r.revision then
		publishPhysics(r, r.propPhysics)
	end
end
function V.AbortPropEdit(r)
	local physics = r.propPhysics
	if not physics or not physics.deferPublish then
		return
	end
	for _, ent in pairs(physics.staged) do
		remove(ent)
	end
	if physics.current then
		remove(physics.current.collider)
	end
	physics.staged = {}
	physics.jobs = nil
	physics.current = nil
	physics.field = nil
	physics.pendingDirty = nil
	physics.dirty = {}
	physics.failed = false
	physics.deferPublish = nil
	physics.preparedRevision = nil
	physics.targetRevision = r.revision
end

function V.PreparePropRegion(r, owner)
	if r.propPhysics then
		return
	end
	r.propPhysics = { owner = owner, colliders = {}, staged = {}, readyRevision = 0 }
	regions[r] = true
	V.QueuePropColliders(r, {}, true)
end

local function release(ent, record, pos)
	if V.ReleaseHL2WheelSupport then
		V.ReleaseHL2WheelSupport(ent)
	end
	if IsValid(ent) then
		if pos then
			local delta = pos - ent:GetPos()
			local positions = {}
			eachBody(ent, function(phys)
				if phys.GetPos then
					positions[phys] = phys:GetPos()
				end
			end)
			ent:SetPos(pos)
			eachBody(ent, function(phys)
				if positions[phys] then
					phys:SetPos(positions[phys] + delta)
				end
				phys:SetVelocity(Vector())
			end)
		end
		ent.VMPropRegion = nil
		ent.VMVehicleRoot = nil
		ent:SetNW2Int("VM_PropRegion", 0)
		if not record.skyFlag then
			ent:RemoveEFlags(EFL_IN_SKYBOX)
		end
		for _, pair in ipairs(record.constraints or { record.constraint }) do
			remove(pair)
		end
		ent:CollisionRulesChanged()
		eachBody(ent, function(phys)
			phys:Wake()
		end)
	else
		for _, pair in ipairs(record.constraints or { record.constraint }) do
			remove(pair)
		end
	end
	tracked[ent] = nil
end
function V.ReleaseVoxelNativeBody(ent, pos)
	local record = tracked[ent]
	if record then
		release(ent, record, pos)
	end
end

function V.ReleasePropRegion(r, force)
	if not r or not r.propPhysics then
		return true
	end
	if V.ReleaseVehicleRegion and not V.ReleaseVehicleRegion(r, force) then
		return false
	end
	local destinations = {}
	for ent, record in pairs(tracked) do
		if record.region == r and IsValid(ent) then
			local pos = ent:GetPos()
			if not worldFree(ent, pos) then
				pos = record.safe
				if not worldFree(ent, pos) then
					pos = nil
					for up = 16, r.side + 1024, 16 do
						local candidate = ent:GetPos() + Vector(0, 0, up)
						if worldFree(ent, candidate) then
							pos = candidate
							break
						end
					end
				end
				if not pos then
					if not force then
						return false
					end
					-- The entry was valid when the prop was enrolled. Retain the
					-- terrain if even that position no longer clears the world.
					return false
				end
			end
			destinations[ent] = pos
		end
	end
	if V.ReleaseActorRegion and not V.ReleaseActorRegion(r) then
		return false
	end
	if V.ReleaseVoxelProjectiles then
		V.ReleaseVoxelProjectiles(r)
	end
	if V.ReleaseNavigation then
		V.ReleaseNavigation(r)
	end
	if V.ReleaseVoxelGrabs then
		V.ReleaseVoxelGrabs(r)
	end
	for ent, record in pairs(tracked) do
		if record.region == r then
			release(ent, record, destinations[ent])
		end
	end
	local physics = r.propPhysics
	for _, ent in pairs(physics.colliders) do
		remove(ent)
	end
	for _, ent in pairs(physics.staged) do
		remove(ent)
	end
	if physics.current then
		remove(physics.current.collider)
	end
	remove(physics.guard)
	r.propPhysics = nil
	regions[r] = nil
	return true
end

function V.EnrollVoxelNativeBody(r, ent, safe, vehicleRoot)
	if tracked[ent] then
		return tracked[ent].region == r
	end
	local worldPairs = {}
	local success = true
	eachBody(ent, function(_, bone)
		if bone == nil then
			return
		end
		-- Preserve a pre-existing user NoCollide with the world. Removing the
		-- voxel region must never re-enable a collision the user disabled.
		for _, link in pairs(constraint.GetTable and constraint.GetTable(ent) or {}) do
			if
				link.Type == "NoCollide"
				and (
					(link.Ent1 and link.Ent1.IsWorld and link.Ent1:IsWorld())
					or (link.Ent2 and link.Ent2.IsWorld and link.Ent2:IsWorld())
				)
			then
				return
			end
		end
		local pair = constraint.NoCollide(ent, game.GetWorld(), bone, 0, true)
		if IsValid(pair) then
			worldPairs[#worldPairs + 1] = pair
		else
			success = false
		end
	end)
	if not success then
		for _, pair in ipairs(worldPairs) do
			remove(pair)
		end
		return false
	end
	tracked[ent] = {
		region = r,
		constraints = worldPairs,
		safe = safe,
		skyFlag = ent:IsEFlagSet(EFL_IN_SKYBOX),
		vehicleRoot = vehicleRoot,
		exterior = r.propPhysics and r.propPhysics.exteriorReady or false,
	}
	ent.VMPropRegion = r
	ent.VMVehicleRoot = vehicleRoot
	ent:SetNW2Int("VM_PropRegion", r.id)
	ent:AddEFlags(EFL_IN_SKYBOX)
	ent:CollisionRulesChanged()
	eachBody(ent, function(phys)
		phys:Wake()
	end)
	return true
end
local function enroll(r, ent)
	if not r.propPhysics then
		return false
	end
	if ent.VMPropRegion == r then
		return true
	end
	if V.TryEnrollVoxelVehicle and r.propPhysics.exteriorReady then
		local root = V.GetVoxelVehicleRoot(ent)
		if root then
			return V.TryEnrollVoxelVehicle(r, root) and ent.VMPropRegion == r
		end
	end
	if not eligible(ent) or not V.InScanCube(r, ent:GetPos()) then
		return false
	end
	local physics = r.propPhysics
	local pos = ent:GetPos()
	-- Native world pairs affect the complete body. A straddling prop needs
	-- the immutable exterior support, just like a vehicle. Without it retain
	-- the conservative full-body fallback instead of dropping outside walls.
	if not physics.exteriorReady and not contained(r, ent, 0) then
		return false
	end
	if
		physics.exteriorReady
		and not contained(r, ent, -((r.vehicleExterior and r.vehicleExterior.width or V.VehicleHaloWidth or 1024) - 64))
	then
		return false
	end
	if not physics.initialized then
		if physics.waiting then
			V.QueuePropColliders(r, {}, true)
		end
		return false
	end
	if physics.jobs or physics.failed or physics.readyRevision ~= r.revision then
		return false
	end
	-- VPhysics owns the actual rotated shape and its voxel contacts. An AABB
	-- preflight pins held props against floors. Native evacuation is searched
	-- only during explicit cleanup, never on the pickup/entry hot path.
	return V.EnrollVoxelNativeBody(r, ent, pos)
end
V.TryEnrollVoxelBody = enroll

-- Never mutate collision rules in this hook: Source can be inside VPhysics.
hook.Add("ShouldCollide", "GVoxel.PropTerrainPairs", function(a, b)
	local collider, other
	if a.VMVoxelCollider then
		collider, other = a, b
	elseif b.VMVoxelCollider then
		collider, other = b, a
	else
		return
	end
	if not collider.VMActive or other.VMPropRegion ~= collider.VMVoxelRegion then
		return false
	end
	local record = tracked[other]
	local exterior = other.VMVehicleRoot or (record and record.exterior)
	if collider.VMGuard and exterior then
		return false
	end
	if collider.VMVehicleExterior and not exterior then
		return false
	end
end)
local function pickedUp(_, ent)
	if IsValid(ent) then
		held[ent] = true
	end
end
local function dropped(_, ent)
	held[ent] = nil
end
hook.Add("OnPhysgunPickup", "GVoxel.HeldPropEntry", pickedUp)
hook.Add("GravGunOnPickedUp", "GVoxel.GravityPropEntry", pickedUp)
hook.Add("OnPlayerPhysicsPickup", "GVoxel.UsePropEntry", pickedUp)
hook.Add("PhysgunDrop", "GVoxel.HeldPropDrop", dropped)
hook.Add("GravGunOnDropped", "GVoxel.GravityPropDrop", dropped)
hook.Add("OnPlayerPhysicsDrop", "GVoxel.UsePropDrop", dropped)
hook.Add("PhysgunPickup", "GVoxel.ProtectTerrainColliders", function(_, ent)
	if ent.VMVoxelCollider then
		return false
	end
	if IsValid(ent.VMVoxelGrabber) then
		return false
	end
end)

hook.Add("Think", "GVoxel.PropPhysics", function()
	local deadline = SysTime() + budget:GetFloat() / 1000
	local cooked = 0
	for r in pairs(regions) do
		local physics = r.propPhysics
		-- Shared terrain belongs to the session, never to an entity's validity.
		-- In particular IsValid(game.GetWorld()) is false in the real engine.
		-- Session cleanup explicitly calls ReleasePropRegion after evacuation.
		if physics then
			if physics.jobs and not physics.failed then
				while (physics.current or #physics.jobs > 0) and SysTime() < deadline do
					if not physics.current then
						local job = table.remove(physics.jobs, 1)
						job.thread = coroutine.create(function()
							if job.exterior then
								return job.exterior.vertices
							end
							if not V.CollisionChunkMayHaveSurface(physics.field, job.x, job.y, job.z) then
								return {}
							end
							return V.BuildCollisionChunk(physics.field, job.x, job.y, job.z, function()
								if SysTime() >= (job.deadline or 0) then
									coroutine.yield()
								end
							end)
						end)
						physics.current = job
					end
					local job = physics.current
					job.deadline = deadline
					if not job.vertices then
						local began = SysTime()
						local ok, vertices = coroutine.resume(job.thread)
						cookStats.meshTotal = cookStats.meshTotal + (SysTime() - began) * 1000
						if not ok then
							physics.failed = true
							physics.current = nil
							ErrorNoHalt("[GVoxel] Reconstruction physique annulee : " .. tostring(vertices) .. "\n")
							break
						end
						if coroutine.status(job.thread) == "dead" then
							job.vertices = vertices
							job.offset = 1
							job.collider = false
						end
					end
					if job.vertices then
						if job.offset <= #job.vertices then
							-- Native cooking cannot yield. Bound both input and
							-- elapsed budget, but don't waste a whole tick after a
							-- cheap cook. The hard cap also bounds fast hardware.
							if cooked >= 4 or SysTime() >= deadline then
								break
							end
							local vertices = {}
							local last = math.min(#job.vertices, job.offset + maxCookVertices - 1)
							for i = job.offset, last do
								vertices[#vertices + 1] = job.vertices[i]
							end
							local origin = job.exterior and r.origin
								or r.origin + Vector(job.x, job.y, job.z) * (r.step * 8)
							local ent = makeCollider(r, origin, vertices)
							if IsValid(ent) and job.exterior then
								ent.VMVehicleExterior = true
							end
							cooked = cooked + 1
							if ent == nil then
								remove(job.collider)
								physics.current = nil
								physics.failed = true
								ErrorNoHalt(
									"[GVoxel] Echec d'un collider : le BSP reste actif pour les nouveaux props.\n"
								)
								break
							end
							if not job.collider then
								job.collider = ent
							else
								local parts = job.collider.VMAdditionalColliders or {}
								parts[#parts + 1] = ent
								job.collider.VMAdditionalColliders = parts
							end
							job.offset = last + 1
						end
						if job.offset > #job.vertices then
							physics.staged[job.key] = job.collider
							physics.current = nil
						end
					end
				end
				if
					#physics.jobs == 0
					and not physics.current
					and not physics.failed
					and (IsValid(physics.guard) or (cooked < 4 and SysTime() < deadline))
				then
					if not IsValid(physics.guard) then
						cooked = cooked + 1
					end
					physics.guard = IsValid(physics.guard) and physics.guard
						or makeCollider(r, r.origin, guardVertices(r))
					if not IsValid(physics.guard) then
						physics.failed = true
					else
						physics.guard.VMActive = true
						physics.guard.VMGuard = true
						physics.guard:CollisionRulesChanged()
						if physics.exteriorQueued then
							physics.exteriorReady = true
						end
						if physics.deferPublish then
							physics.jobs = nil
							physics.preparedRevision = physics.targetRevision
						else
							publishPhysics(r, physics)
						end
					end
				end
			end
		end
	end
	-- Boundary checks are cheap and independent of mesh construction. Sleeping
	-- props need no repeated world trace until a rebuild or physgun wakes them.
	for ent, record in pairs(tracked) do
		if not IsValid(ent) then
			release(ent, record)
		else
			local phys = ent:GetPhysicsObject()
			if not IsValid(phys) then
				release(ent, record)
			else
				local awake = false
				eachBody(ent, function(body)
					if not body:IsAsleep() then
						awake = true
					end
				end)
				if (awake or held[ent]) and not record.vehicleRoot and not record.projectile then
					local a, b = ent:WorldSpaceAABB()
					local r = record.region
					local atEdge = record.exterior and not V.BoundsOverlap(a, b, r.origin, r.origin + V.RegionSize(r))
						or not record.exterior and not contained(r, ent, 0)
					if atEdge or CurTime() >= (record.nextProbe or 0) then
						record.nextProbe = CurTime() + 0.2
						local free = worldFree(ent, ent:GetPos())
						if free then
							record.safe = ent:GetPos()
						end
						if atEdge and free then
							release(ent, record)
						end
					end
				end
			end
		end
	end
	-- A held object may travel many units between periodic discovery passes.
	-- Observe its centre each tick, even when the native gun sleeps its body.
	for ent in pairs(held) do
		if not IsValid(ent) then
			held[ent] = nil
		elseif not tracked[ent] then
			for r in pairs(regions) do
				if V.InScanCube(r, ent:GetPos()) then
					enroll(r, ent)
					break
				end
			end
		end
	end
	if CurTime() < nextSearch then
		return
	end
	nextSearch = CurTime() + 0.15
	for r in pairs(regions) do
		local physics = r.propPhysics
		if
			physics.waiting
			or (physics.initialized and not physics.jobs and not physics.failed and physics.readyRevision == r.revision)
		then
			for _, ent in ipairs(ents.FindInBox(r.origin, r.origin + V.RegionSize(r))) do
				enroll(r, ent)
			end
		end
	end
end)

concommand.Add("vm_prop_stats", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then
		return
	end
	local count, bodies, jobs, waiting = 0, 0, 0, 0
	for r in pairs(regions) do
		for _, ent in pairs(r.propPhysics.colliders) do
			if IsValid(ent) then
				count = count + 1 + #(ent.VMAdditionalColliders or {})
			end
		end
		if r.propPhysics.waiting then
			waiting = waiting + 1
		end
		jobs = jobs + #(r.propPhysics.jobs or {}) + (r.propPhysics.current and 1 or 0)
	end
	for _ in pairs(tracked) do
		bodies = bodies + 1
	end
	print(
		string.format(
			"[GVoxel] Physique : %d colliders | %d props | %d chunks a reconstruire | %d zones sans besoin physique | cuisson native moyenne %.2f ms / max %.2f ms",
			count,
			bodies,
			jobs,
			waiting,
			cookStats.total / math.max(1, cookStats.count),
			cookStats.max
		)
	)
end)
