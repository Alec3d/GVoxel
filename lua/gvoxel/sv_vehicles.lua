-- Transfer complete native assemblies before they touch the cage boundary.
-- Frameworks retain their suspension; native HL2 wheels have a local relay in
-- sv_hl2_wheels.lua because their C++ traces cannot be adapted through Lua.
local V = GVoxel
V.VehicleStates = V.VehicleStates or {}
local states = V.VehicleStates
local nextSearch = 0
local LIMIT = 256
local function physical(ent)
	return IsValid(ent)
		and not (ent.IsPlayer and ent:IsPlayer())
		and not ent.VMVoxelCollider
		and ent.GetPhysicsObjectCount
		and ent:GetPhysicsObjectCount() > 0
		and ent:GetPhysicsObjectCount() <= 64
		and IsValid(ent:GetPhysicsObject())
end
local function collect(root)
	local queue, seen, parts = { root }, { [root] = true }, {}
	local function enqueue(ent)
		if IsValid(ent) and not seen[ent] and not (ent.IsPlayer and ent:IsPlayer()) then
			seen[ent] = true
			queue[#queue + 1] = ent
		end
	end
	local i = 1
	while queue[i] do
		local ent = queue[i]
		i = i + 1
		if #queue > LIMIT then
			return nil, "assemblage trop grand"
		end
		if IsValid(ent) and not (ent.IsPlayer and ent:IsPlayer()) then
			if physical(ent) then
				parts[#parts + 1] = ent
			end
			for _, child in ipairs(ent.GetChildren and ent:GetChildren() or {}) do
				enqueue(child)
			end
			for _, link in pairs(constraint.GetTable(ent) or {}) do
				if link.Type ~= "NoCollide" then
					local members = link.Entity or { { Entity = link.Ent1 }, { Entity = link.Ent2 } }
					for _, entry in pairs(members) do
						local other = entry.Entity
						if other and other.IsWorld and other:IsWorld() then
							return nil, "contrainte attachee au monde"
						end
						enqueue(other)
					end
				end
			end
		end
	end
	return parts
end
V.CollectVoxelVehicle = collect
local function bounds(parts)
	local low, high = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for _, ent in ipairs(parts) do
		if IsValid(ent) then
			local a, b = ent:WorldSpaceAABB()
			for _, axis in ipairs({ "x", "y", "z" }) do
				low[axis] = math.min(low[axis], a[axis])
				high[axis] = math.max(high[axis], b[axis])
			end
		end
	end
	return low, high
end
local function nativeFree(parts, delta)
	for _, ent in ipairs(parts) do
		if IsValid(ent) and not V.NativeBodyFree(ent, ent:GetPos() + delta) then
			return false
		end
	end
	return true
end
local function safeOffset(r, parts)
	if nativeFree(parts, Vector()) then
		return Vector()
	end
	for up = 16, r.side + 2048, 16 do
		local delta = Vector(0, 0, up)
		if nativeFree(parts, delta) then
			return delta
		end
	end
end
local function release(root, state, delta)
	if V.ReleaseHL2WheelSupport then
		V.ReleaseHL2WheelSupport(root)
	end
	for _, ent in ipairs(state.parts) do
		V.ReleaseVoxelNativeBody(ent, delta and IsValid(ent) and ent:GetPos() + delta or nil)
	end
	states[root] = nil
end
function V.ReleaseVehicleRegion(r)
	local offsets = {}
	for root, state in pairs(states) do
		if state.region == r then
			-- A world anchor added after entry must not be stretched by evacuation.
			local _, reason = collect(root)
			local delta
			if reason then
				if nativeFree(state.parts, Vector()) then
					delta = Vector()
				end
			else
				delta = safeOffset(r, state.parts)
			end
			if not delta then
				return false
			end
			offsets[root] = delta
		end
	end
	for root, delta in pairs(offsets) do
		release(root, states[root], delta:LengthSqr() > 0 and delta or nil)
	end
	return true
end
function V.TryEnrollVoxelVehicle(r, root, refresh)
	if states[root] and not refresh then
		return states[root].region == r
	end
	local physics = r.propPhysics
	if
		not physical(root)
		or not V.VoxelVehicleFamily(root)
		or not r.vehicleExterior
		or not physics
		or not physics.exteriorReady
		or physics.jobs
		or physics.failed
		or physics.readyRevision ~= r.revision
	then
		return false
	end
	local parts, reason = collect(root)
	if not parts or #parts == 0 then
		root.VMVehicleBlocked = reason
		return false
	end
	local low, high = bounds(parts)
	local width = r.vehicleExterior.width - 64
	if
		low.x < r.origin.x - width
		or low.y < r.origin.y - width
		or low.z < r.origin.z - width
		or high.x > r.origin.x + V.RegionAxisSize(r, "x") + width
		or high.y > r.origin.y + V.RegionAxisSize(r, "y") + width
		or high.z > r.origin.z + V.RegionAxisSize(r, "z") + width
	then
		root.VMVehicleBlocked = "assemblage hors du support exterieur"
		return false
	end
	local margin = 128
	if
		not V.BoundsOverlap(
			low,
			high,
			r.origin - Vector(margin, margin, margin),
			r.origin + (V.RegionSize(r) + Vector(margin, margin, margin))
		)
	then
		return false
	end
	if not V.HullTouchesModified(r, root:GetPos(), low - root:GetPos(), high - root:GetPos(), margin) then
		return false
	end
	-- Do not search vertically in a Think/physics entry path. A chassis AABB
	-- can overlap a slope or wall while its real shape is clear. Evacuation
	-- computes a common safe offset only when the region is explicitly closed.
	local enrolled = {}
	local previousRoots = {}
	for _, ent in ipairs(parts) do
		if V.AdaptVoxelVehicleEntity then
			V.AdaptVoxelVehicleEntity(ent)
		end
		local existing = V.PropState.tracked[ent]
		if existing and existing.region ~= r then
			for _, part in ipairs(enrolled) do
				V.ReleaseVoxelNativeBody(part)
			end
			return false
		end
		if not V.EnrollVoxelNativeBody(r, ent, ent:GetPos(), root) then
			for _, part in ipairs(enrolled) do
				V.ReleaseVoxelNativeBody(part)
			end
			root.VMVehicleBlocked = "paire physique monde refusee"
			return false
		end
		if existing and existing.vehicleRoot and existing.vehicleRoot ~= root then
			previousRoots[existing.vehicleRoot] = true
		end
		if not existing then
			enrolled[#enrolled + 1] = ent
		end
	end
	-- Commit ownership only after every new world pair succeeded. Joined
	-- trailers/vehicles become one assembly without deleting their constraints.
	local present = {}
	for _, ent in ipairs(parts) do
		present[ent] = true
		V.PropState.tracked[ent].vehicleRoot = root
		ent.VMVehicleRoot = root
	end
	local previous = states[root]
	-- Broken-off wheels keep their current voxel support until they leave the
	-- cage, independently of the moving chassis. Cleanup must not tow them.
	if previous then
		for _, ent in ipairs(previous.parts) do
			if IsValid(ent) and not present[ent] then
				V.PropState.tracked[ent].vehicleRoot = ent
				ent.VMVehicleRoot = ent
				states[ent] = { region = r, parts = { ent }, detached = true }
			end
		end
	end
	for other in pairs(previousRoots) do
		states[other] = nil
	end
	states[root] = { region = r, parts = parts, nextTopology = CurTime() + 0.5 }
	root.VMVehicleBlocked = nil
	return true
end
hook.Add("Think", "GVoxel.VehicleAssemblies", function()
	local now = CurTime()
	for root, state in pairs(states) do
		if not IsValid(root) then
			local delta = safeOffset(state.region, state.parts)
			if delta then
				release(root, state, delta:LengthSqr() > 0 and delta or nil)
			end
		else
			local low, high = bounds(state.parts)
			local r = state.region
			local near = V.BoundsOverlap(
				low,
				high,
				r.origin - Vector(48, 48, 48),
				r.origin + (V.RegionSize(r) + Vector(48, 48, 48))
			)
			-- Outside the cage the proxy is the unchanged BSP itself. Restore
			-- that same collision at the same pose, retaining driving velocity.
			-- An enclosing AABB would falsely reject tyres resting on slopes.
			if not near then
				release(root, state)
			elseif not state.detached and now >= state.nextTopology then
				state.nextTopology = now + 0.5
				V.TryEnrollVoxelVehicle(r, root, true)
			end
		end
	end
	if now < nextSearch then
		return
	end
	nextSearch = now + 0.1
	local r = V.GetServerScanRegion and V.GetServerScanRegion()
	if not r or r.revision == 0 or not r.propPhysics or not r.propPhysics.exteriorReady then
		return
	end
	local seen = {}
	for _, ent in
		ipairs(ents.FindInBox(r.origin - Vector(128, 128, 128), r.origin + (V.RegionSize(r) + Vector(128, 128, 128))))
	do
		local root = V.GetVoxelVehicleRoot(ent)
		if root and not seen[root] then
			seen[root] = true
			V.TryEnrollVoxelVehicle(r, root)
		end
	end
end)
concommand.Add("vm_vehicle_stats", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then
		return
	end
	local r = V.GetServerScanRegion and V.GetServerScanRegion()
	print(
		string.format(
			"[GVoxel] Support vehicules : exterieur %s | triangles %d",
			r and r.propPhysics and r.propPhysics.exteriorReady and "pret" or "indisponible",
			r and r.vehicleExterior and r.vehicleExterior.triangles or 0
		)
	)
	for root, state in pairs(states) do
		print(
			string.format(
				"[GVoxel] %s : %s / %d corps, zone %d",
				tostring(root),
				V.VoxelVehicleFamily(root) or "ensemble",
				#state.parts,
				state.region.id
			)
		)
	end
	if not r then
		return
	end
	local seen = {}
	for _, ent in
		ipairs(ents.FindInBox(r.origin - Vector(128, 128, 128), r.origin + (V.RegionSize(r) + Vector(128, 128, 128))))
	do
		local root = V.GetVoxelVehicleRoot(ent)
		if root and not states[root] and not seen[root] then
			seen[root] = true
			print(
				string.format(
					"[GVoxel] %s : %s / attente : %s",
					tostring(root),
					V.VoxelVehicleFamily(root) or "ensemble",
					root.VMVehicleBlocked or "support physique/revision ou ouverture a proximite"
				)
			)
		end
	end
end)
