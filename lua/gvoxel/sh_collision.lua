-- Swept player AABB against the exact piecewise-linear solid used by the mesh.
-- Continuous separating-axis tests avoid point-sampling holes and tunnelling.
local V = GVoxel
local axes = { "x", "y", "z" }
local basis = { Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }
local EPS = 0.00001
local emptySolids = {}
local function boxHull(r, x, y, z)
	local step = r.step
	return {
		{
			{ n = basis[1], low = x * step, high = (x + 1) * step },
			{ n = basis[2], low = y * step, high = (y + 1) * step },
			{ n = basis[3], low = z * step, high = (z + 1) * step },
		},
	}
end
local function topology(points, normals)
	return { points = points, normals = normals }
end
local cubeEdges = {
	{ 1, 2 },
	{ 2, 3 },
	{ 3, 4 },
	{ 4, 1 },
	{ 5, 6 },
	{ 6, 7 },
	{ 7, 8 },
	{ 8, 5 },
	{ 1, 5 },
	{ 2, 6 },
	{ 3, 7 },
	{
		4,
		8,
	},
}
local function planarCell(r, x, y, z, points, densities)
	local normal, distance, valid = nil, nil, true
	V.ForCellTriangles(r, x, y, z, function(a, b, c, outward)
		local n = (b - a):Cross(c - a):GetNormalized()
		if n:Dot(outward) < 0 then
			n = -n
		end
		if not normal then
			normal = n
			distance = n:Dot(a)
		end
		if
			n:Dot(normal) < 0.9999999
			or math.abs(normal:Dot(a) - distance) > 1e-6
			or math.abs(normal:Dot(b) - distance) > 1e-6
			or math.abs(normal:Dot(c) - distance) > 1e-6
		then
			valid = false
		end
	end)
	if not valid or not normal then
		return
	end
	for i, p in ipairs(points) do
		local d = normal:Dot(p) - distance
		if math.abs(d) > 1e-6 and densities[i] ~= 0 and (d < 0) ~= (densities[i] < 0) then
			return
		end
	end
	local vertices = {}
	for _, p in ipairs(points) do
		if normal:Dot(p) <= distance + 1e-7 then
			vertices[#vertices + 1] = p
		end
	end
	for _, edge in ipairs(cubeEdges) do
		local a, b = points[edge[1]], points[edge[2]]
		local da, db = normal:Dot(a) - distance, normal:Dot(b) - distance
		if da * db < 0 then
			vertices[#vertices + 1] = a + (b - a) * (da / (da - db))
		end
	end
	return topology(vertices, { basis[1], basis[2], basis[3], normal })
end

local function polytope(points, normals, edges, checkpoint)
	local planes = {}
	-- Native Vector component reads cross into the engine. Extract each
	-- vertex once, instead of once per SAT axis, retaining the same doubles.
	local coordinates = {}
	for _, p in ipairs(points) do
		coordinates[#coordinates + 1] = p.x
		coordinates[#coordinates + 1] = p.y
		coordinates[#coordinates + 1] = p.z
	end
	local nx, ny, nz = {}, {}, {}
	local function addAxis(x, y, z)
		local length = x * x + y * y + z * z
		if length < 1e-12 then
			return
		end
		length = math.sqrt(length)
		x, y, z = x / length, y / length, z / length
		for i = 1, #nx do
			if math.abs(nx[i] * x + ny[i] * y + nz[i] * z) > 0.9999999 then
				return
			end
		end
		local low, high = math.huge, -math.huge
		for i = 1, #coordinates, 3 do
			local d = coordinates[i] * x + coordinates[i + 1] * y + coordinates[i + 2] * z
			low, high = math.min(low, d), math.max(high, d)
		end
		local normal = Vector(x, y, z)
		planes[#planes + 1] = { n = normal, low = low, high = high }
		-- Preserve Source's float rounding in axis deduplication.
		nx[#nx + 1] = normal.x
		ny[#ny + 1] = normal.y
		nz[#nz + 1] = normal.z
	end
	local function edgeAxes(x, y, z)
		-- Cross with the three AABB basis vectors, without allocating six
		-- temporary Source vectors per edge (cross + normalized copy).
		addAxis(0, z, -y)
		addAxis(-z, 0, x)
		addAxis(y, -x, 0)
	end
	addAxis(1, 0, 0)
	addAxis(0, 1, 0)
	addAxis(0, 0, 1)
	if normals == basis then
		return planes
	end
	for _, n in ipairs(normals) do
		addAxis(n.x, n.y, n.z)
	end
	if edges then
		for i, edge in ipairs(edges) do
			edgeAxes(edge.x, edge.y, edge.z)
			if checkpoint and i % 8 == 0 then
				checkpoint()
			end
		end
	else
		for i = 1, #points - 1 do
			for j = i + 1, #points do
				local a, b = points[i], points[j]
				edgeAxes(b.x - a.x, b.y - a.y, b.z - a.z)
			end
		end
	end
	return planes
end

-- A sharpened cut can be a non-planar quad. Its convex hull bridges the
-- renderer's diagonal and creates an invisible bulge. Tetrahedralize its actual
-- triangulated boundary instead; shared grid faces use a deterministic fan.
local function refinedSolids(r, p, d, vertices, out, adjustments)
	local center = Vector()
	for _, point in ipairs(vertices) do
		center = center + point / #vertices
	end
	local nodes, edges = {}, {}, {}
	for i = 1, 4 do
		local q = p[i] / r.step
		nodes[i] = {
			pos = p[i],
			d = d[i],
			key = "n:" .. V.Index(math.floor(q.x + 0.5), math.floor(q.y + 0.5), math.floor(q.z + 0.5), r),
		}
	end
	local function edge(i, j)
		if i > j then
			i, j = j, i
		end
		local key = i * 4 + j
		if not edges[key] then
			local point = adjustments[key] or (d[i] == 0 and p[i] or p[j])
			local a, b = nodes[i].key, nodes[j].key
			if a > b then
				a, b = b, a
			end
			edges[key] = { pos = point, d = 0, key = "e:" .. a .. ":" .. b }
		end
		return edges[key]
	end
	local function triangle(a, b, c)
		local ab, ac, ad = b - a, c - a, center - a
		if math.abs(ab:Cross(ac):Dot(ad)) < 0.00000001 then
			return
		end
		local points = { a, b, c, center }
		out[#out + 1] = topology(points, { ab:Cross(ac), ab:Cross(ad), ac:Cross(ad), (c - b):Cross(center - b) })
	end
	for _, face in ipairs({ { 1, 2, 3 }, { 1, 2, 4 }, { 1, 3, 4 }, { 2, 3, 4 } }) do
		local polygon = {}
		local previous = face[#face]
		for _, current in ipairs(face) do
			if (d[previous] <= 0) ~= (d[current] <= 0) then
				polygon[#polygon + 1] = edge(previous, current)
			end
			if d[current] <= 0 then
				polygon[#polygon + 1] = nodes[current]
			end
			previous = current
		end
		local first = 1
		for i = 2, #polygon do
			if polygon[i].key < polygon[first].key then
				first = i
			end
		end
		for i = 2, #polygon - 1 do
			triangle(
				polygon[first].pos,
				polygon[(first + i - 2) % #polygon + 1].pos,
				polygon[(first + i - 1) % #polygon + 1].pos
			)
		end
	end
	local inside, outside = {}, {}
	for i = 1, 4 do
		local list = d[i] < 0 and inside or outside
		list[#list + 1] = i
	end
	if #inside == 1 or #outside == 1 then
		local single = #inside == 1 and inside or outside
		local others = #inside == 1 and outside or inside
		triangle(edge(single[1], others[1]).pos, edge(single[1], others[2]).pos, edge(single[1], others[3]).pos)
	elseif #inside == 2 then
		local a, b = edge(inside[1], outside[1]).pos, edge(inside[1], outside[2]).pos
		local c, e = edge(inside[2], outside[1]).pos, edge(inside[2], outside[2]).pos
		triangle(a, b, c)
		triangle(b, e, c)
	end
end

function V.DensityCellGeometry(r, x, y, z)
	local cache, key = V.TerrainCellCache(r, "densityGeometry", x, y, z)
	local cached = cache[key]
	if cached then
		return cached
	end
	local points, densities = {}, {}
	local negative, positive = false, false
	for i, o in ipairs(V.CellOffsets) do
		points[i] = Vector(x + o[1], y + o[2], z + o[3]) * r.step
		local d = V.Sample(r, x + o[1], y + o[2], z + o[3])
		densities[i] = d
		if d < 0 then
			negative = true
		elseif d > 0 then
			positive = true
		end
	end
	cached = {}
	if negative and not positive then
		-- Fully solid cells need only three box axes.
		cached[1] = topology(points, basis)
	elseif negative then
		local plane = planarCell(r, x, y, z, points, densities)
		if plane then
			cache[key] = { plane }
			return cache[key]
		end
		for _, tet in ipairs(V.CellTetrahedra) do
			local p, d = {}, {}
			local hasSolid = false
			for i, index in ipairs(tet) do
				p[i], d[i] = points[index], densities[index]
				if d[i] < 0 then
					hasSolid = true
				end
			end
			if hasSolid then
				local vertices, adjustments = {}, {}
				local refined = false
				for i = 1, 4 do
					if d[i] <= 0 then
						vertices[#vertices + 1] = p[i]
					end
				end
				for i = 1, 3 do
					for j = i + 1, 4 do
						if (d[i] < 0 and d[j] > 0) or (d[j] < 0 and d[i] > 0) then
							local point = p[i] + (p[j] - p[i]) * (d[i] / (d[i] - d[j]))
							local adjusted = V.RefineSurfacePoint and V.RefineSurfacePoint(r, point) or point
							if point:DistToSqr(adjusted) > 0.00000001 then
								refined = true
							end
							vertices[#vertices + 1] = adjusted
							adjustments[i * 4 + j] = adjusted
						end
					end
				end
				local a, b, c = p[2] - p[1], p[3] - p[1], p[4] - p[1]
				local gradient = (b:Cross(c) * (d[2] - d[1]) + c:Cross(a) * (d[3] - d[1]) + a:Cross(b) * (d[4] - d[1]))
					/ a:Dot(b:Cross(c))
				local normals = { a:Cross(b), b:Cross(c), c:Cross(a), (p[3] - p[2]):Cross(p[4] - p[2]), gradient }
				if refined then
					refinedSolids(r, p, d, vertices, cached, adjustments)
				else
					cached[#cached + 1] = topology(vertices, normals)
				end
			end
		end
	end
	cache[key] = cached
	return cached
end

-- Geometry needs supporting face planes, never the extra edge x AABB axes
-- required by swept player collision. Those axes are prepared separately.
function V.DensityCellPlanes(r, x, y, z)
	local result = {}
	for _, shape in ipairs(V.DensityCellGeometry(r, x, y, z)) do
		if not shape.planes then
			local planes = {}
			for _, n in ipairs(shape.normals) do
				if n:LengthSqr() > 1e-12 then
					n = n:GetNormalized()
					local duplicate = false
					for _, p in ipairs(planes) do
						if math.abs(p.n:Dot(n)) > 0.9999999 then
							duplicate = true
							break
						end
					end
					if not duplicate then
						local low, high = math.huge, -math.huge
						for _, p in ipairs(shape.points) do
							local d = p:Dot(n)
							low = math.min(low, d)
							high = math.max(high, d)
						end
						planes[#planes + 1] = { n = n, low = low, high = high }
					end
				end
			end
			shape.planes = planes
		end
		result[#result + 1] = shape.planes
	end
	return result
end

function V.BSPPieceHull(piece, checkpoint)
	if piece.voxelHull then
		return piece.voxelHull
	end
	local vertices, normals, seen, edges, seenEdges = {}, {}, {}, {}, {}
	for _, face in ipairs(piece.faces) do
		normals[#normals + 1] = face.normal
		for _, p in ipairs(face.vertices) do
			if not seen[p] then
				vertices[#vertices + 1] = p
				seen[p] = #vertices
			end
		end
		for i, p in ipairs(face.vertices) do
			local q = face.vertices[i % #face.vertices + 1]
			local low, high = seen[p], seen[q]
			if low > high then
				low, high = high, low
			end
			local key = high * (high - 1) / 2 + low
			if not seenEdges[key] then
				seenEdges[key] = true
				edges[#edges + 1] = q - p
			end
		end
	end
	piece.voxelHull = polytope(vertices, normals, edges, checkpoint)
	return piece.voxelHull
end

local function cellSolids(r, x, y, z, checkpoint)
	if not V.ActiveRegionCell(r, x, y, z) then
		return emptySolids
	end
	local cache, key = V.TerrainCellCache(r, "hulls", x, y, z)
	if cache[key] then
		return cache[key]
	end
	local unedited = r.bsp and r.bspCellEditBins and not r.bspCellEditBins[key]
	if not r.bsp then
		local solid, air = false, false
		for _, o in ipairs(V.CellOffsets) do
			local d = V.Sample(r, x + o[1], y + o[2], z + o[3])
			if d < 0 then
				solid = true
			elseif d > 0 then
				air = true
			end
		end
		if not solid then
			cache[key] = emptySolids
			return emptySolids
		end
		if not air then
			cache[key] = boxHull(r, x, y, z)
			return cache[key]
		end
	elseif unedited and not V.BSPCellUsesDensity(r, x, y, z) then
		local occupancy = V.BSPCellOccupancy(r, x, y, z, checkpoint)
		if occupancy == 2 then
			cache[key] = emptySolids
			return emptySolids
		end
		if occupancy == 1 then
			cache[key] = boxHull(r, x, y, z)
			return cache[key]
		end
	end
	local cached = {}
	if unedited and V.BSPCellUsesDensity(r, x, y, z) and not V.BSPCellHasDetail(r, x, y, z) then
		-- Unedited displacement cells already have the exact density shape.
		-- Avoid converting it to BSP faces and back into the same SAT axes.
		cached = cellSolids(V.BSPDensityBase(r), x, y, z, checkpoint)
	elseif r.bsp then
		for _, piece in ipairs(V.BSPCellSolids(r, x, y, z, checkpoint)) do
			cached[#cached + 1] = V.BSPPieceHull(piece, checkpoint)
			if checkpoint then
				checkpoint()
			end
		end
	else
		local geometry = V.DensityCellGeometry(r, x, y, z)
		for i, shape in ipairs(geometry) do
			cached[#cached + 1] = polytope(shape.points, shape.normals, nil, checkpoint)
			if checkpoint and (i % 4 == 0 or i == #geometry) then
				checkpoint()
			end
		end
	end
	cache[key] = cached
	return cached
end
V.DensityCellSolids = cellSolids

-- Run during the initial scan, with a yielding checkpoint. Later movement
-- queries reuse these immutable cell hulls instead of clipping cold geometry.
function V.PrepareCollisionChunk(r, cx, cy, cz, checkpoint)
	if not V.ActiveRegionCell(r, cx * 8, cy * 8, cz * 8) then
		return
	end
	local cells = V.TerrainCellCache(r, "hulls", cx * 8, cy * 8, cz * 8)
	for z = cz * 8, math.min(cz * 8 + 7, V.RegionCells(r, "z") - 1) do
		for y = cy * 8, math.min(cy * 8 + 7, V.RegionCells(r, "y") - 1) do
			for x = cx * 8, math.min(cx * 8 + 7, V.RegionCells(r, "x") - 1) do
				if not cells[V.Index(x, y, z, r)] then
					cellSolids(r, x, y, z, checkpoint)
					if checkpoint then
						checkpoint()
					end
				end
				if V.PrepareBSPCollisionCell then
					V.PrepareBSPCollisionCell(r, x, y, z, checkpoint)
				end
			end
		end
	end
end
function V.PrepareChangedCollisions(r, dirty, checkpoint)
	for _, chunk in pairs(dirty) do
		V.PrepareCollisionChunk(r, chunk[1], chunk[2], chunk[3], checkpoint)
	end
end

-- Count only on an explicit diagnostic request, never per frame/command.
function V.CollisionCacheStats(r)
	local result = { cells = 0, solids = 0, axes = 0 }
	local root = r and r.terrainCache
	if root and root.revision == r.revision then
		for _, cells in pairs(root.hulls or {}) do
			for _, solids in pairs(cells) do
				result.cells = result.cells + 1
				result.solids = result.solids + #solids
				for _, planes in ipairs(solids) do
					result.axes = result.axes + #planes
				end
			end
		end
	end
	return result
end

local function sweep(poly, center, extent, delta, pointCast)
	local first, last = -math.huge, math.huge
	local normal = Vector()
	local inside = true
	for _, plane in ipairs(poly) do
		local n = plane.n
		local radius = math.abs(n.x) * extent.x + math.abs(n.y) * extent.y + math.abs(n.z) * extent.z
		local p, d = center:Dot(n), delta:Dot(n)
		local low, high = plane.low - radius, plane.high + radius
		if p <= low + EPS or p >= high - EPS then
			inside = false
		end
		if math.abs(d) < 1e-12 then
			if pointCast then
				-- A ray on a shared cell/leaf face still intersects the union.
				-- Finite hulls retain the open contact test used for walking.
				if p < low - EPS or p > high + EPS then
					return
				end
			elseif p <= low + EPS or p >= high - EPS then
				return
			end
		else
			local enter, exit = (low - p) / d, (high - p) / d
			local face = n * -1
			if enter > exit then
				enter, exit = exit, enter
				face = n
			end
			if enter > first then
				first = enter
				normal = face
			end
			last = math.min(last, exit)
			if first > last + EPS then
				return
			end
		end
	end
	if inside then
		return 0, Vector(), true
	end
	if first < -EPS or first > 1 or last <= EPS then
		return
	end
	return math.max(0, first), normal, false
end
-- Reuse the continuous SAT kernel for the unchanged world around a vehicle's
-- cage. A triangle has no thickness; the swept hull supplies its contact size.
function V.VehicleTriangleHull(a, b, c)
	return polytope({ a, b, c }, { (b - a):Cross(c - a) }, { b - a, c - b, a - c })
end
V.SweepVehicleSolid = sweep

-- Cheap swept cell bounds precede exact SAT construction. Visit nearest cells
-- first; geometry beyond the first collision never needs to be constructed.
local function cellEntry(center, extent, delta, x, y, z, step)
	local first, last = 0, 1
	for i, axis in ipairs(axes) do
		local cell = i == 1 and x or i == 2 and y or z
		local low, high = cell * step - extent[axis] - EPS, (cell + 1) * step + extent[axis] + EPS
		local p, d = center[axis], delta[axis]
		if math.abs(d) < 1e-12 then
			if p < low or p > high then
				return
			end
		else
			local a, b = (low - p) / d, (high - p) / d
			if a > b then
				a, b = b, a
			end
			first, last = math.max(first, a), math.min(last, b)
			if first > last then
				return
			end
		end
	end
	return first
end

function V.TraceVoxelHull(r, start, finish, mins, maxs, checkpoint)
	local delta = finish - start
	local center = start + (mins + maxs) / 2 - r.origin
	local extent = (maxs - mins) / 2
	local pointCast = extent:LengthSqr() < 1e-16
	local low, high = {}, {}
	for _, axis in ipairs(axes) do
		local a, b = start[axis] + mins[axis], finish[axis] + maxs[axis]
		low[axis] = math.max(0, math.floor((math.min(a, finish[axis] + mins[axis]) - r.origin[axis] - EPS) / r.step))
		high[axis] = math.min(
			V.RegionCells(r, axis) - 1,
			math.floor((math.max(b, start[axis] + maxs[axis]) - r.origin[axis] + EPS) / r.step)
		)
	end
	local result =
		{ Hit = false, Fraction = 1, HitPos = finish, HitNormal = Vector(), StartSolid = false, Voxel = true }
	local candidates = {}
	local function candidate(x, y, z)
		local entry = cellEntry(center, extent, delta, x, y, z, r.step)
		if entry then
			candidates[#candidates + 1] = { x = x, y = y, z = z, entry = entry, order = x + r.nx * (y + r.ny * z) }
		end
	end
	local major = 1
	for i = 2, 3 do
		if math.abs(delta[axes[i]]) > math.abs(delta[axes[major]]) then
			major = i
		end
	end
	local axis, u, v = axes[major], axes[major % 3 + 1], axes[(major + 1) % 3 + 1]
	local function range(name, first, last)
		local a, b = center[name] + delta[name] * first, center[name] + delta[name] * last
		return math.max(low[name], math.floor((math.min(a, b) - extent[name] - EPS) / r.step)),
			math.min(high[name], math.floor((math.max(a, b) + extent[name] + EPS) / r.step))
	end
	-- Clip the trajectory to each slab along its longest travel direction.
	-- A diagonal visits only the slab's local footprint, rather than all
	-- cells in the huge start/end bounding box before narrow-phase pruning.
	for cell = low[axis], high[axis] do
		local first, last = 0, 1
		local d = delta[axis]
		if math.abs(d) > 1e-12 then
			first = (cell * r.step - extent[axis] - EPS - center[axis]) / d
			last = ((cell + 1) * r.step + extent[axis] + EPS - center[axis]) / d
			if first > last then
				first, last = last, first
			end
			first, last = math.max(0, first), math.min(1, last)
		end
		if first <= last then
			local ulo, uhi = range(u, first, last)
			local vlo, vhi = range(v, first, last)
			for b = vlo, vhi do
				for a = ulo, uhi do
					if major == 1 then
						candidate(cell, a, b)
					elseif major == 2 then
						candidate(b, cell, a)
					else
						candidate(a, b, cell)
					end
					if checkpoint and a % 8 == 0 then
						checkpoint()
					end
				end
			end
		end
		if checkpoint then
			checkpoint()
		end
	end
	if delta:LengthSqr() > 1e-16 then
		table.sort(candidates, function(a, b)
			return a.entry == b.entry and a.order < b.order or a.entry < b.entry
		end)
	end
	for _, cell in ipairs(candidates) do
		if cell.entry > result.Fraction + EPS then
			break
		end
		for _, poly in ipairs(cellSolids(r, cell.x, cell.y, cell.z, checkpoint)) do
			local fraction, normal, inside = sweep(poly, center, extent, delta, pointCast)
			if fraction and (fraction < result.Fraction or inside) then
				result.Hit = true
				result.Fraction = fraction
				result.HitNormal = normal
				result.StartSolid = inside
				if inside then
					result.HitPos = start
					return result
				end
			end
		end
		if checkpoint then
			checkpoint()
		end
	end
	result.HitPos = start + delta * result.Fraction
	return result
end

function V.HullNearScan(r, pos, mins, maxs, margin)
	for _, axis in ipairs(axes) do
		if
			pos[axis] + maxs[axis] < r.origin[axis] - margin
			or pos[axis] + mins[axis] > r.origin[axis] + V.RegionAxisSize(r, axis) + margin
		then
			return false
		end
	end
	return true
end

function V.HullTouchesModified(r, pos, mins, maxs, margin)
	if r.revision == 0 and not r.modifiedChunks then
		return false
	end
	-- Older retained fields have no index; never drop their collisions.
	if not r.modifiedChunks then
		return true
	end
	local low, high = {}, {}
	local size = r.step * 8
	for _, axis in ipairs(axes) do
		low[axis] = math.max(0, math.floor((pos[axis] + mins[axis] - margin - r.origin[axis]) / size))
		high[axis] = math.min(3, math.floor((pos[axis] + maxs[axis] + margin - r.origin[axis]) / size))
	end
	for z = low.z, high.z do
		for y = low.y, high.y do
			for x = low.x, high.x do
				if r.modifiedChunks[V.ChunkKey(x, y, z)] then
					return true
				end
			end
		end
	end
	return false
end

-- Partition an AABB into its portions outside the scanned cube. Query the BSP
-- only in those boxes, including when half the player straddles a scan edge.
function V.OutsideScanBoxes(r, low, high, query)
	low, high = Vector(low.x, low.y, low.z), Vector(high.x, high.y, high.z)
	for _, axis in ipairs(axes) do
		local bottom, top = r.origin[axis], r.origin[axis] + V.RegionAxisSize(r, axis)
		if low[axis] < bottom then
			local b = Vector(high.x, high.y, high.z)
			b[axis] = math.min(b[axis], bottom)
			if query(low, b) then
				return true
			end
			low[axis] = bottom
		end
		if high[axis] > top then
			local a = Vector(low.x, low.y, low.z)
			a[axis] = math.max(a[axis], top)
			if query(a, high) then
				return true
			end
			high[axis] = top
		end
		if high[axis] <= low[axis] then
			return false
		end
	end
	return false
end
