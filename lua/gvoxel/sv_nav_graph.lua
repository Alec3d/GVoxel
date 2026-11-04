-- Bounded A* over WALKABLE surfaces, not empty voxels. A node has hull-sized
-- clearance and support; edges cannot jump gaps or walk through a filled wall.
-- Providers/checkpoints keep the graph testable and cooperatively scheduled.
local V = GVoxel
local UP = Vector(0, 0, 1)
local function clear(hit)
	return not hit.Hit and not hit.StartSolid and not hit.AllSolid
end
local function floorAt(p, drop, trace)
	local hit = trace(p, p - UP * drop)
	if hit.Hit and not hit.StartSolid and not hit.AllSolid and hit.HitNormal.z >= 0.65 then
		return hit.HitPos + UP * 0.25
	end
end
function V.NavSurfaceStep(from, x, y, trace, step, drop)
	step, drop = step or 18, drop or 48
	local finish = Vector(x, y, from.z)
	local function supported(a, b)
		local ground = floorAt(b, drop, trace)
		if not ground then
			return
		end
		-- A supported endpoint alone could bridge a deep hole in one edge.
		local slices = math.max(2, math.ceil((b - a):Length() / 24))
		for i = 1, slices - 1 do
			if not floorAt(a + (b - a) * (i / slices), drop, trace) then
				return
			end
		end
		return ground
	end
	if clear(trace(from, finish)) then
		return supported(from, finish)
	end
	local raised = from + UP * step
	if not clear(trace(from, raised)) then
		return
	end
	finish = Vector(x, y, raised.z)
	if clear(trace(raised, finish)) then
		return supported(raised, finish)
	end
end
local function key(p, spacing)
	return math.floor(p.x / spacing) .. ":" .. math.floor(p.y / spacing) .. ":" .. math.floor(p.z * 4 + 0.5)
end
local function push(heap, item)
	local i = #heap + 1
	while i > 1 do
		local parent = math.floor(i / 2)
		if heap[parent].score <= item.score then
			break
		end
		heap[i] = heap[parent]
		i = parent
	end
	heap[i] = item
end
local function pop(heap)
	local result, last = heap[1], table.remove(heap)
	if #heap > 0 then
		local i = 1
		while i * 2 <= #heap do
			local child = i * 2
			if heap[child + 1] and heap[child + 1].score < heap[child].score then
				child = child + 1
			end
			if last.score <= heap[child].score then
				break
			end
			heap[i] = heap[child]
			i = child
		end
		heap[i] = last
	end
	return result
end
function V.BuildVoxelRoute(start, goal, trace, options, checkpoint)
	options = options or {}
	local spacing = options.spacing or 24
	local root = floorAt(start, 48, trace)
	if not root then
		return nil, "depart sans support"
	end
	local target = floorAt(goal + UP * 18, 96, trace)
	if not target then
		return nil, "arrivee sans support"
	end
	local function inside(p)
		local lo, hi = options.low, options.high
		return not lo or (p.x >= lo.x and p.y >= lo.y and p.z >= lo.z and p.x <= hi.x and p.y <= hi.y and p.z <= hi.z)
	end
	local function heuristic(p)
		return (p - target):Length()
	end
	local rootKey = key(root, spacing)
	local heap = { { pos = root, key = rootKey, cost = 0, score = heuristic(root) } }
	local costs = { [rootKey] = 0 }
	local closed = {}
	local parents = {}
	local positions = { [rootKey] = root }
	local visited = 0
	while #heap > 0 and visited < (options.limit or 4096) do
		local node = pop(heap)
		if not closed[node.key] then
			closed[node.key] = true
			visited = visited + 1
			if
				math.abs(node.pos.x - target.x) <= spacing
				and math.abs(node.pos.y - target.y) <= spacing
				and math.abs(node.pos.z - target.z) <= 48
			then
				local finish = V.NavSurfaceStep(node.pos, target.x, target.y, trace)
				if finish and math.abs(finish.z - target.z) < 1 then
					local path = { finish }
					local k = node.key
					while k do
						table.insert(path, 1, positions[k])
						k = parents[k]
					end
					return path, nil, visited
				end
			end
			for _, offset in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
				local gx, gy =
					math.floor(node.pos.x / spacing) + offset[1], math.floor(node.pos.y / spacing) + offset[2]
				local x, y = (gx + 0.5) * spacing, (gy + 0.5) * spacing
				if inside(Vector(x, y, node.pos.z)) then
					local nextPos = V.NavSurfaceStep(node.pos, x, y, trace)
					if nextPos and inside(nextPos) then
						local k = key(nextPos, spacing)
						local cost = node.cost + (nextPos - node.pos):Length()
						if not closed[k] and (not costs[k] or cost < costs[k]) then
							costs[k] = cost
							parents[k] = node.key
							positions[k] = nextPos
							push(heap, { pos = nextPos, key = k, cost = cost, score = cost + heuristic(nextPos) })
						end
					end
				end
				if checkpoint then
					checkpoint()
				end
			end
		end
		if checkpoint then
			checkpoint()
		end
	end
	return nil, visited >= (options.limit or 4096) and "limite locale atteinte" or "aucun passage praticable", visited
end
