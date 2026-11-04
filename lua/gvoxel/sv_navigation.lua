-- Session-local routes and temporary navmesh corridors. No map generation,
-- saved nav edits or path building inside the excavation transaction.
local V = GVoxel
if V.ReleaseNavigation then
	V.ReleaseNavigation()
end
local states = {}
local requests = setmetatable({}, { __mode = "k" })
local jobs = {}
local budget =
	CreateConVar("vm_nav_budget_ms", "1", FCVAR_ARCHIVE, "Budget souple global de navigation voxel par tick", 0.25, 2)
local HUMAN_MIN, HUMAN_MAX = Vector(-16, -16, 0), Vector(16, 16, 72)
local stats = { routes = 0, failed = 0, cpu = 0, peak = 0, probes = 0 }
local function validArea(area)
	return area and area.IsValid and area:IsValid()
end
local function removeAreas(state)
	for _, area in pairs(state.areas) do
		if validArea(area) then
			area:Remove()
		end
	end
	state.areas = {}
	state.owned = {}
	state.areaCount = 0
end
function V.ReleaseNavigation(r)
	for region, state in pairs(states) do
		if not r or region == r then
			removeAreas(state)
			states[region] = nil
		end
	end
	for ent, request in pairs(requests) do
		if not r or request.region == r then
			requests[ent] = nil
		end
	end
	for i = #jobs, 1, -1 do
		if not r or jobs[i].region == r then
			table.remove(jobs, i)
		end
	end
end
local function stateFor(r)
	local state = states[r]
	if not state or state.revision ~= r.revision then
		if state then
			removeAreas(state)
		end
		state =
			{ revision = r.revision, areas = {}, owned = {}, areaCount = 0, cache = {}, cacheCount = 0, expires = 0 }
		states[r] = state
	end
	return state
end
function V.TraceNPCNavigation(r, actor, a, b, mins, maxs, checkpoint)
	return V.TracePlayerTerrain(actor, r, a, b, mins, maxs, {
		mask = MASK_NPCSOLID,
		brushMask = MASK_NPCSOLID_BRUSHONLY,
		group = COLLISION_GROUP_NPC,
		navigation = true,
		checkpoint = checkpoint,
	})
end
local function provider(job, mins, maxs)
	local state = job.state
	local profile = table.concat({ mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z }, ":")
	return function(a, b)
		if job.request then
			job.request.probes = (job.request.probes or 0) + 1
		end
		job.checkpoint()
		local key = profile .. ":" .. table.concat({ a.x, a.y, a.z, b.x, b.y, b.z }, ":")
		local hit = state.cache[key]
		if not hit then
			hit = V.TraceNPCNavigation(job.region, job.actor, a, b, mins, maxs, job.checkpoint)
			if state.cacheCount >= 4096 then
				state.cache = {}
				state.cacheCount = 0
			end
			state.cache[key] = hit
			state.cacheCount = state.cacheCount + 1
			stats.probes = stats.probes + 1
		end
		return hit
	end
end
local function anchor(position, state)
	if not navmesh or not navmesh.GetNearestNavArea then
		return
	end
	-- Native LOS sees the old BSP. Physical access is checked below with the
	-- same hull/terrain provider as the route instead of trusting proximity.
	local area = navmesh.GetNearestNavArea(position + Vector(0, 0, 4), false, 80, false, false)
	if validArea(area) and not state.owned[area] and not (area.IsBlocked and area:IsBlocked(-2)) then
		return area, area:GetClosestPointOnArea(position)
	end
end
local function joinRoute(path, pos, trace, checkpoint)
	local best = math.huge
	local index
	for i = 2, #path do
		local q = path[i]
		local distance = pos:DistToSqr(q)
		if distance < best and distance <= 96 ^ 2 then
			local reach = V.NavSurfaceStep(pos, q.x, q.y, trace)
			if reach and math.abs(reach.z - q.z) < 1 then
				best = distance
				index = i
			end
		end
		if checkpoint then
			checkpoint()
		end
	end
	return index
end
function V.PublishVoxelNavBridge(r, path, trace, checkpoint)
	if not navmesh or not navmesh.CreateNavArea or #path < 2 then
		return false
	end
	local state = stateFor(r)
	local first, entry = anchor(path[1], state)
	local last, exit = anchor(path[#path], state)
	if not first or not last or first == last then
		return false
	end
	if math.abs(entry.z - path[1].z) > 18 or math.abs(exit.z - path[#path].z) > 18 then
		return false
	end
	local a = V.NavSurfaceStep(path[1], entry.x, entry.y, trace)
	local b = V.NavSurfaceStep(path[#path], exit.x, exit.y, trace)
	if not a or not b or math.abs(a.z - entry.z) > 1 or math.abs(b.z - exit.z) > 1 then
		return false
	end
	local points = {}
	for _, p in ipairs(path) do
		-- Small, verified tiles: never create a rectangular nav area across
		-- an unchecked wall just because its two endpoints are reachable.
		for _, offset in ipairs({ { -6, -6 }, { 6, -6 }, { 6, 6 }, { -6, 6 } }) do
			local q = V.NavSurfaceStep(p, p.x + offset[1], p.y + offset[2], trace)
			if not q or math.abs(q.z - p.z) > 4 then
				return false
			end
		end
		points[#points + 1] = p
		if checkpoint then
			checkpoint()
		end
	end
	local areas = {}
	local created = {}
	local function rollback()
		for key, area in pairs(created) do
			if validArea(area) then
				area:Remove()
			end
			state.owned[area] = nil
			state.areas[key] = nil
			state.areaCount = state.areaCount - 1
		end
		return false
	end
	for _, p in ipairs(points) do
		local key = table.concat({ p.x, p.y, p.z }, ":")
		local area = state.areas[key]
		if not validArea(area) then
			if state.areaCount >= 128 then
				return rollback()
			end
			area = navmesh.CreateNavArea(p + Vector(-6, -6, -0.25), p + Vector(6, 6, -0.25))
			if not validArea(area) then
				return rollback()
			end
			state.areas[key] = area
			state.owned[area] = true
			state.areaCount = state.areaCount + 1
			created[key] = area
		end
		areas[#areas + 1] = area
		if checkpoint then
			checkpoint()
		end
	end
	local previous = first
	for _, area in ipairs(areas) do
		if previous ~= area then
			previous:ConnectTo(area)
			area:ConnectTo(previous)
			previous = area
		end
	end
	if previous ~= last then
		previous:ConnectTo(last)
		last:ConnectTo(previous)
	end
	return true
end
local function startJob(r, actor, start, goal, mins, maxs, request)
	if #jobs >= 16 then
		return false
	end
	local state = stateFor(r)
	local job = { region = r, actor = actor, state = state, revision = r.revision, request = request }
	job.checkpoint = function()
		if SysTime() >= job.deadline then
			coroutine.yield()
		end
	end
	job.thread = coroutine.create(function()
		local trace = provider(job, mins, maxs)
		local lo = r.origin - Vector(192, 192, 64)
		local hi = r.origin + V.RegionSize(r) + Vector(192, 192, 128)
		local target = Vector(
			math.Clamp(goal.x, lo.x + 24, hi.x - 24),
			math.Clamp(goal.y, lo.y + 24, hi.y - 24),
			math.Clamp(goal.z, lo.z + 1, hi.z - 1)
		)
		local path, reason, visited =
			V.BuildVoxelRoute(start, target, trace, { low = lo, high = hi, spacing = 24, limit = 2048 }, job.checkpoint)
		if path then
			local through = false
			for _, p in ipairs(path) do
				if V.InScanCube(r, p) then
					through = true
					break
				end
			end
			if not through then
				return nil, "trajet hors zone", visited
			end
			-- A small actor may fit where a human/NextBot does not. Public
			-- nav tiles always receive a separate human-clearance validation.
			V.PublishVoxelNavBridge(r, path, provider(job, HUMAN_MIN, HUMAN_MAX), job.checkpoint)
			if actor and IsValid(actor) then
				job.index = joinRoute(path, actor:GetPos(), trace, job.checkpoint)
				if not job.index then
					return nil, "trajet depasse", visited
				end
			end
		end
		return path, reason, visited
	end)
	jobs[#jobs + 1] = job
	return true
end
function V.RequestNPCNavigation(ent, r, goal, force)
	local now = CurTime()
	local old = requests[ent]
	if old and old.region == r and old.revision == r.revision and not force then
		if old.pending or ((old.path or now < old.retry) and old.goal:DistToSqr(goal) < 32 ^ 2) then
			return old
		end
	end
	if old and old.pending then
		old.cancelled = true
	end
	local request =
		{ region = r, revision = r.revision, goal = Vector(goal.x, goal.y, goal.z), retry = now + 1, pending = true }
	if old and not force and old.region == r and old.revision == r.revision then
		request.path = old.path
		request.index = old.index
	end
	local mins, maxs = ent:GetCollisionBounds()
	if not startJob(r, ent, ent:GetPos(), goal, mins, maxs, request) then
		request.pending = false
		request.retry = now + 0.25
	end
	requests[ent] = request
	return request
end
function V.GetNPCNavigationPoint(ent, r, goal, entering)
	local request = V.RequestNPCNavigation(ent, r, goal)
	if request.revision ~= r.revision or not request.path then
		return
	end
	local p = ent:GetPos()
	local index = request.index or 2
	while index < #request.path do
		local q = request.path[index]
		local d = q - p
		local previous = request.path[index - 1] or q
		local along = q - previous
		along.z = 0
		local passed = (p - q):Dot(along) >= 0 and (p - q):LengthSqr() < 32 ^ 2
		if (d.x * d.x + d.y * d.y > 8 ^ 2 and not passed) or math.abs(d.z) > 18 then
			break
		end
		index = index + 1
	end
	request.index = index
	if entering then
		local through = false
		for i = index, #request.path do
			if V.InScanCube(r, request.path[i]) then
				through = true
				break
			end
		end
		if not through then
			return
		end
	end
	-- Round grid corners only after a real hull sweep and ground probes. Cache
	-- the steering target briefly; actual movement still sweeps every tick.
	if CurTime() >= (request.nextSteer or 0) or request.steerIndex ~= index then
		request.nextSteer = CurTime() + 0.12
		request.steerIndex = index
		request.steer = request.path[index]
		local mins, maxs = ent:GetCollisionBounds()
		local trace = function(a, b)
			return V.TraceNPCNavigation(r, ent, a, b, mins, maxs)
		end
		for i = index + 1, math.min(index + 2, #request.path) do
			local q = request.path[i]
			if p:DistToSqr(q) > 72 ^ 2 then
				break
			end
			local reachable = V.NavSurfaceStep(p, q.x, q.y, trace)
			if not reachable or math.abs(reachable.z - q.z) > 1 then
				break
			end
			request.steer = q
		end
	end
	return request.steer or request.path[index], request
end
function V.ForgetNPCNavigation(ent)
	local request = requests[ent]
	if request then
		request.cancelled = true
		requests[ent] = nil
	end
end
function V.GetNPCNavigationStatus(ent)
	local request = requests[ent]
	if not request then
		return { status = "absent" }
	end
	return {
		status = request.pending and "calcul" or request.path and "pret" or "echec",
		reason = request.reason,
		revision = request.revision,
		visited = request.visited,
		probes = request.probes,
		points = request.path and #request.path or 0,
		index = request.index,
	}
end
local function discover(state, r)
	if not navmesh or not navmesh.FindInBox or not r.bspEdits or #r.bspEdits == 0 then
		return
	end
	local edit = r.bspEdits[#r.bspEdits]
	local center = r.origin + edit.center
	local radius = math.min(256, edit.radius + 64)
	local list = navmesh.FindInBox(center - Vector(radius, radius, radius), center + Vector(radius, radius, radius))
	local points = {}
	for _, area in ipairs(list) do
		if #points >= 8 then
			break
		end
		if validArea(area) and not (area.IsBlocked and area:IsBlocked(-2)) then
			local p = area:GetClosestPointOnArea(center) + Vector(0, 0, 0.25)
			points[#points + 1] = p
		end
	end
	local count = 0
	for i = 1, #points - 1 do
		for j = i + 1, #points do
			if count >= 4 then
				return
			end
			if points[i]:DistToSqr(points[j]) > 32 ^ 2 then
				if startJob(r, nil, points[i], points[j], HUMAN_MIN, HUMAN_MAX) then
					count = count + 1
				end
			end
		end
	end
end
hook.Add("Think", "GVoxel.Navigation", function()
	local now = CurTime()
	for r in pairs(V.PropState and V.PropState.regions or {}) do
		local state = stateFor(r)
		if now >= state.expires then
			state.cache = {}
			state.cacheCount = 0
			state.expires = now + 0.5
		end
		if r.revision > 0 and not state.discovered then
			state.discovered = true
			discover(state, r)
		end
	end
	local deadline = SysTime() + budget:GetFloat() / 1000
	while #jobs > 0 and SysTime() < deadline do
		local job = table.remove(jobs, 1)
		local request = job.request
		if
			states[job.region] ~= job.state
			or job.revision ~= job.region.revision
			or (request and request.cancelled)
			or (job.actor and not IsValid(job.actor))
			or not job.region.propPhysics
		then
			if request then
				request.pending = false
				request.retry = now
			end
		else
			job.deadline = deadline
			local started = SysTime()
			local ok, path, reason, visited = coroutine.resume(job.thread)
			local elapsed = SysTime() - started
			stats.cpu = stats.cpu + elapsed
			stats.peak = math.max(stats.peak, elapsed)
			if ok and coroutine.status(job.thread) ~= "dead" then
				jobs[#jobs + 1] = job
			else
				if request then
					request.pending = false
					request.path = ok and path or nil
					request.index = job.index or 2
					request.steer = nil
					request.nextSteer = 0
					request.reason = ok and reason or path
					request.visited = visited
					request.retry = now + (path and 1 or 0.5)
				end
				if ok and path then
					stats.routes = stats.routes + 1
				else
					stats.failed = stats.failed + 1
				end
				if not ok and ErrorNoHalt then
					ErrorNoHalt("[GVoxel] Navigation: " .. tostring(path) .. "\n")
				end
			end
		end
	end
end)
hook.Add("PostCleanupMap", "GVoxel.NavigationCleanup", function()
	V.ReleaseNavigation()
end)
concommand.Add("vm_nav_stats", function(ply)
	if IsValid(ply) and not V.CanManageScan(ply) then
		return
	end
	local areas = 0
	for _, state in pairs(states) do
		areas = areas + state.areaCount
	end
	print(
		string.format(
			"[GVoxel] Navigation : %d routes / %d echecs ; %d travaux ; %d aires temporaires ; %d sondes ; CPU %.2f ms / pic %.2f ms",
			stats.routes,
			stats.failed,
			#jobs,
			areas,
			stats.probes,
			stats.cpu * 1000,
			stats.peak * 1000
		)
	)
	local count = 0
	for ent in pairs(requests) do
		if IsValid(ent) then
			local s = V.GetNPCNavigationStatus(ent)
			print(
				string.format(
					"[GVoxel] %s : %s ; %d points ; %d sondes ; %s",
					ent:GetClass(),
					s.status,
					s.points,
					s.probes or 0,
					s.reason or ""
				)
			)
			count = count + 1
			if count >= 8 then
				break
			end
		end
	end
end)
