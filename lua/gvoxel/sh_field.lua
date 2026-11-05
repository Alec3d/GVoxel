-- Negative density = solid. This module deliberately uses standard Lua 5.1.
local V = GVoxel
V.Step = 16
V.ChunkCells = 8
V.Reach = 320
V.MaxEdits = 4096
-- Explicit scale used by the tool: one Source unit is one inch.
V.UnitsPerMetre = 1 / 0.0254
V.ScanSizes = { 16, 32 }
V.ReloadHoldTime = 0.45
function V.IsVoxelTool(weapon)
	if not IsValid(weapon) then
		return false
	end
	local class = weapon:GetClass()
	return class == "weapon_voxel_crowbar"
end

local min, max, floor, ceil, sqrt = math.min, math.max, math.floor, math.ceil, math.sqrt
local nx, ny, nz = 32, 32, 24

local function quantize(value)
	return max(-32767, min(32767, floor(value * 64 + 0.5))) / 64
end

function V.Index(x, y, z, r)
	local sx, sy = r and r.nx or nx, r and r.ny or ny
	return 1 + x + (sx + 1) * (y + (sy + 1) * z)
end

function V.ValidScanSize(metres)
	return metres == 16 or metres == 32
end

-- The lattice keeps its fixed 33-node stride / 64 transport chunks. A custom
-- box activates only the cells within its rectangular bounds, with uniform
-- voxel spacing; inactive cells never sample, render or collide.
function V.RegionSize(r)
	return r.extent or Vector(r.side, r.side, r.side)
end
function V.RegionAxisSize(r, axis)
	return r.extent and r.extent[axis] or r.side
end
function V.RegionCells(r, axis)
	return r.cells and r.cells[axis] or r["n" .. axis] or (axis == "x" and nx or axis == "y" and ny or nz)
end
function V.ActiveRegionCell(r, x, y, z)
	return not r.cells or (x >= 0 and y >= 0 and z >= 0 and x < r.cells.x and y < r.cells.y and z < r.cells.z)
end
V.CustomMaxSide = math.floor(32 * V.UnitsPerMetre * 8) / 8
V.CustomMinSide = 32
function V.CustomBoxBounds(low, high)
	if not low or not high then
		return nil, "Definir les quatre points."
	end
	local origin, size = Vector(), Vector()
	for _, axis in ipairs({ "x", "y", "z" }) do
		local a, b = low[axis], high[axis]
		if type(a) ~= "number" or type(b) ~= "number" or a ~= a or b ~= b or math.abs(a) > 1e6 or math.abs(b) > 1e6 then
			return nil, "Coordonnees de la boite invalides."
		end
		a, b = math.floor(a * 8 + 0.5) / 8, math.floor(b * 8 + 0.5) / 8
		origin[axis] = math.min(a, b)
		size[axis] = math.abs(b - a)
		if size[axis] < V.CustomMinSide then
			return nil, "Chaque dimension doit faire au moins 32 unites."
		end
		if size[axis] > V.CustomMaxSide then
			return nil, "Boite limitee a 32 metres par axe."
		end
	end
	local step = math.max(size.x, size.y, size.z) / 32
	local cells = Vector(
		math.max(2, math.ceil(size.x / step - 1e-7)),
		math.max(2, math.ceil(size.y / step - 1e-7)),
		math.max(2, math.ceil(size.z / step - 1e-7))
	)
	local extent = cells * step
	return { origin = origin, extent = extent, cells = cells, step = step, side = 32 * step, base = origin + extent / 2 }
end
function V.NewCustomScanRegion(id, low, high)
	local bounds, err = V.CustomBoxBounds(low, high)
	if not bounds then
		return nil, err
	end
	local r = V.NewScanRegion(id, bounds.base, 16)
	for key, value in pairs(bounds) do
		r[key] = value
	end
	r.metres = 0
	r.custom = true
	for i = 1, 33 ^ 3 do
		r.values[i] = r.step
	end
	return r
end

function V.NewScanRegion(id, center, metres)
	assert(V.ValidScanSize(metres), "Invalid scan size")
	local side = metres * V.UnitsPerMetre
	local r = {
		id = id,
		base = center,
		origin = center - Vector(side, side, side) / 2,
		nx = 32,
		ny = 32,
		nz = 32,
		step = side / 32,
		metres = metres,
		side = side,
		values = {},
		chunks = {},
		revision = 0,
		analysis = true,
	}
	for i = 1, 33 * 33 * 33 do
		r.values[i] = r.step
	end
	return r
end

function V.ChunkKey(x, y, z)
	return x .. ":" .. y .. ":" .. z
end

-- Geometry, hulls and feature tests share a chunk-local cache. A stroke evicts
-- only its dirty chunks; an unexpected revision change still invalidates all.
function V.TerrainCellCache(r, kind, x, y, z)
	if not r.terrainCache or r.terrainCache.revision ~= r.revision then
		r.terrainCache = { revision = r.revision }
	end
	local root = r.terrainCache
	root[kind] = root[kind] or {}
	local key = V.ChunkKey(floor(x / 8), floor(y / 8), floor(z / 8))
	root[kind][key] = root[kind][key] or {}
	return root[kind][key], V.Index(x, y, z, r)
end

function V.InvalidateTerrainCaches(r, dirty, low, high)
	local cache = r.terrainCache
	if not cache or cache.revision ~= r.revision then
		r.terrainCache = nil
		return
	end
	local geometryLow = low and low + Vector(2, 2, 2)
	local geometryHigh = high and high - Vector(2, 2, 2)
	local normalLow = low and low + Vector(1, 1, 1)
	local normalHigh = high and high - Vector(1, 1, 1)
	local latest = r.bsp and r.bspEdits and #r.bspEdits
	local function geometryChanged(index)
		if not latest or not r.bspCellEditBins then
			return true
		end
		local edits = r.bspCellEditBins[index]
		return edits and edits[#edits] and edits[#edits].index == latest
	end
	if r.bsp and low then
		cache.previousBSP = cache.previousBSP or {}
		for key in pairs(dirty) do
			local previous = {}
			for index, value in pairs(cache.previousBSP[key] or {}) do
				previous[index] = value
			end
			for index, value in pairs(cache.bspCells and cache.bspCells[key] or {}) do
				local i = index - 1
				local x, y, z = i % (r.nx + 1), floor(i / (r.nx + 1)) % (r.ny + 1), floor(i / ((r.nx + 1) * (r.ny + 1)))
				if
					x >= geometryLow.x
					and x <= geometryHigh.x
					and y >= geometryLow.y
					and y <= geometryHigh.y
					and z >= geometryLow.z
					and z <= geometryHigh.z
					and geometryChanged(index)
				then
					previous[index] = value
				end
			end
			cache.previousBSP[key] = previous
		end
	end
	for kind, chunks in pairs(cache) do
		if
			kind ~= "revision"
			and kind ~= "previousBSP"
			and not (r.bsp and (kind == "bspLeaves" or kind == "bspBaseTets"))
		then
			for key in pairs(dirty) do
				local cells = chunks[key]
				if
					cells
					and low
					and (
						kind == "bspCells"
						or kind == "hulls"
						or kind == "physicsCells"
						or kind == "renderCells"
						or kind == "surfaceCells"
						or kind == "densityGeometry"
						or kind == "surfaces"
						or kind == "edited"
					)
				then
					-- Copy on write: displayed snapshots still own the old
					-- bucket. A local stroke must retain distant cells in it.
					local kept = {}
					local lo, hi = normalLow, normalHigh
					if r.bsp and (kind == "bspCells" or kind == "hulls" or kind == "physicsCells") then
						lo, hi = geometryLow, geometryHigh
					end
					for index, value in pairs(cells) do
						local i = index - 1
						local x, y, z =
							i % (r.nx + 1), floor(i / (r.nx + 1)) % (r.ny + 1), floor(i / ((r.nx + 1) * (r.ny + 1)))
						local exactGeometry = r.bsp
							and (kind == "bspCells" or kind == "hulls" or kind == "physicsCells")
						-- Architectural normals/UVs and cut lighting depend
						-- on immutable faces, not neighbouring density nodes.
						-- Keep their completed render/material work when this
						-- stroke misses the cell. Displacement normals still
						-- need the density-gradient halo around a changed node.
						if
							r.bsp
							and (kind == "renderCells" or kind == "surfaceCells")
							and not V.BSPCellUsesDensity(r, x, y, z)
						then
							exactGeometry = true
						end
						if
							x < lo.x
							or x > hi.x
							or y < lo.y
							or y > hi.y
							or z < lo.z
							or z > hi.z
							or (exactGeometry and not geometryChanged(index))
						then
							kept[index] = value
						end
					end
					chunks[key] = kept
				else
					chunks[key] = nil
				end
			end
		end
	end
	cache.revision = r.revision + 1
end

function V.Sample(r, x, y, z)
	x, y, z =
		max(0, min(V.RegionCells(r, "x") or nx, x)),
		max(0, min(V.RegionCells(r, "y") or ny, y)),
		max(0, min(V.RegionCells(r, "z") or nz, z))
	return r.values[V.Index(x, y, z, r)]
end

-- These samplers are synchronous: no checkpoint, callback or engine hook can
-- yield while their private scratch vectors are live. Native in-place vector
-- operations preserve Source's float rounding without temporary userdata.
local densityPoint, normalPoint = Vector(), Vector()
local normalOffsets = {}
function V.Density(r, p)
	local q = densityPoint
	q:Set(p)
	q:Sub(r.origin)
	q:Div(r.step or V.Step)
	local x, y, z = floor(q.x), floor(q.y), floor(q.z)
	local u, v, w = q.x - x, q.y - y, q.z - z
	local function row(yy, zz)
		return V.Sample(r, x, yy, zz) * (1 - u) + V.Sample(r, x + 1, yy, zz) * u
	end
	return (row(y, z) * (1 - v) + row(y + 1, z) * v) * (1 - w) + (row(y, z + 1) * (1 - v) + row(y + 1, z + 1) * v) * w
end

local function normalSample(r, p, offset, negative)
	normalPoint:Set(p)
	if negative then
		normalPoint:Sub(offset)
	else
		normalPoint:Add(offset)
	end
	return V.Density(r, normalPoint)
end
function V.Normal(r, p)
	local e = (r.step or V.Step) / 8
	local offsets = normalOffsets[e]
	if not offsets then
		offsets = { Vector(e, 0, 0), Vector(0, e, 0), Vector(0, 0, e) }
		normalOffsets[e] = offsets
	end
	local normal = Vector(
		normalSample(r, p, offsets[1]) - normalSample(r, p, offsets[1], true),
		normalSample(r, p, offsets[2]) - normalSample(r, p, offsets[2], true),
		normalSample(r, p, offsets[3]) - normalSample(r, p, offsets[3], true)
	)
	normal:Normalize()
	return normal
end

function V.ValidRemovalPlane(plane)
	local valid=type(plane)=="table" and (plane.axis==1 or plane.axis==2 or plane.axis==3)
		and (plane.sign==1 or plane.sign==-1) and type(plane.distance)=="number"
		and plane.distance==plane.distance and math.abs(plane.distance)<1e7
	if not valid then return false end
	if plane.cell then
		if type(plane.cell)~="table" or #plane.cell~=3 then return false end
		for i=1,3 do
			local n=plane.cell[i]
			if type(n)~="number" or n~=n or n<0 or n>31 or n~=math.floor(n) then return false end
		end
	end
	return true
end

function V.ApplyBrush(r, center, radius, adding, seed, checkpoint, floorZ, plane)
	if plane and (adding or not r.bsp or not V.ValidRemovalPlane(plane)) then return {},false end
	seed = seed and seed ~= 0 and seed or nil
	if r.bsp and V.BSPBrushUnchanged(r, center, radius, adding, seed, floorZ, plane) then
		return {}, false
	end
	if r.bsp then
		V.FreezeBSPDensityBase(r)
	end
	local nx, ny, nz = V.RegionCells(r, "x") or nx, V.RegionCells(r, "y") or ny, V.RegionCells(r, "z") or nz
	local step = r.step or V.Step
	local q = center - r.origin
	local planeAxis = plane and ({"x","y","z"})[plane.axis]
	local localFloor = floorZ ~= nil and floorZ - r.origin.z or nil
	local lo = {
		max(1, floor((q.x - radius) / step)),
		max(1, floor((q.y - radius) / step)),
		max(1, floor((q.z - radius) / step)),
	}
	if localFloor ~= nil then
		lo[3] = max(lo[3], ceil(localFloor / step))
	end
	local hi = {
		min(nx - 1, ceil((q.x + radius) / step)),
		min(ny - 1, ceil((q.y + radius) / step)),
		min(nz - 1, ceil((q.z + radius) / step)),
	}
	local dirty, changed = {}, false
	for z = lo[3], hi[3] do
		for y = lo[2], hi[2] do
			for x = lo[1], hi[1] do
				local d = sqrt((x * step - q.x) ^ 2 + (y * step - q.y) ^ 2 + (z * step - q.z) ^ 2)
				-- Preserve the outer lattice: scanned borders must keep matching the BSP.
				local sample = d - radius
				if plane then
					local value=plane.axis==1 and x or plane.axis==2 and y or z
					sample=plane.sign*(r.origin[planeAxis]+value*step)-plane.distance
				elseif seed and d < radius then
					sample = V.BrushSample(Vector(x * step, y * step, z * step), q, radius, seed, localFloor)
				elseif localFloor ~= nil then
					sample = max(sample, localFloor - z * step)
				end
				if sample < 0 then
					local index = V.Index(x, y, z, r)
					local old = r.values[index]
					local value = quantize(adding and min(old, sample) or max(old, -sample))
					if value ~= old then
						r.values[index], changed = value, true
						if r.analysis then
							r.featureTouched = r.featureTouched or {}
							r.featureTouched[index] = true
						end
						-- A changed node belongs to up to eight adjacent chunks.
						for cz = max(0, floor((z - 2) / 8)), min(floor((nz - 1) / 8), floor((z + 1) / 8)) do
							for cy = max(0, floor((y - 2) / 8)), min(floor((ny - 1) / 8), floor((y + 1) / 8)) do
								for cx = max(0, floor((x - 2) / 8)), min(floor((nx - 1) / 8), floor((x + 1) / 8)) do
									dirty[V.ChunkKey(cx, cy, cz)] = { cx, cy, cz }
								end
							end
						end
					end
				end
				if checkpoint and (x - lo[1] + (hi[1] - lo[1] + 1) * (y - lo[2])) % 16 == 0 then
					checkpoint()
				end
			end
		end
	end
	if r.bsp then
		-- Thin BSP details can exist between lattice nodes. Their exact CSG
		-- must update even when the coarse density samples did not change.
		local lowZ = localFloor ~= nil and max(q.z - radius, localFloor) or q.z - radius
		for cz = max(0, floor(lowZ / step / 8)), min(floor((nz - 1) / 8), floor((q.z + radius) / step / 8)) do
			for cy = max(0, floor((q.y - radius) / step / 8)), min(floor((ny - 1) / 8), floor((q.y + radius) / step / 8)) do
				for cx = max(0, floor((q.x - radius) / step / 8)), min(floor((nx - 1) / 8), floor((q.x + radius) / step / 8)) do
					dirty[V.ChunkKey(cx, cy, cz)] = { cx, cy, cz }
					changed = true
				end
			end
		end
	end
	if changed then
		-- Immutable roots let staged client/physics snapshots share this
		-- small index without enabling custom movement before mesh commit.
		local modified = {}
		for key, value in pairs(r.modifiedChunks or {}) do
			modified[key] = value
		end
		for key in pairs(dirty) do
			modified[key] = true
		end
		r.modifiedChunks = modified
		if V.RecordBSPBrush then
			V.RecordBSPBrush(r, center, radius, adding, seed, checkpoint, floorZ, plane)
		end
		local low, high
		low =
			Vector(floor((q.x - radius) / step) - 2, floor((q.y - radius) / step) - 2, floor((q.z - radius) / step) - 2)
		high =
			Vector(floor((q.x + radius) / step) + 2, floor((q.y + radius) / step) + 2, floor((q.z + radius) / step) + 2)
		V.InvalidateTerrainCaches(r, dirty, low, high)
	end
	return dirty, changed
end

-- Consistent six-tetrahedron split, including shared faces between chunks.
local offsets =
	{ { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 1, 0, 1 }, { 1, 1, 1 }, { 0, 1, 1 } }
local tetrahedra = { { 1, 2, 3, 7 }, { 1, 3, 4, 7 }, { 1, 4, 8, 7 }, { 1, 8, 5, 7 }, { 1, 5, 6, 7 }, { 1, 6, 2, 7 } }
V.CellOffsets, V.CellTetrahedra = offsets, tetrahedra
local scanColor = Color(255, 255, 255)

local function buildCellTriangles(r, x, y, z, emit)
	local step = r.step or V.Step
	local positions, densities, indices = {}, {}, {}
	local hasSolid, hasAir = false, false
	for i, o in ipairs(offsets) do
		indices[i] = V.Index(x + o[1], y + o[2], z + o[3], r)
		local d = r.values[indices[i]]
		densities[i] = d
		if d < 0 then
			hasSolid = true
		else
			hasAir = true
		end
	end
	if not hasSolid or not hasAir then
		return
	end
	for i, o in ipairs(offsets) do
		positions[i] = Vector(x + o[1], y + o[2], z + o[3]) * step
	end
	local edges = V.TerrainCellCache(r, "edgePoints", x, y, z)
	local function edge(i, j)
		if indices[i] > indices[j] then
			i, j = j, i
		end
		-- Shared tetrahedron/cell edges interpolate and refine only once per
		-- chunk. Canonical node order also makes the floating-point result
		-- identical on either side of a lattice face.
		local key = indices[i] * 40000 + indices[j]
		if densities[i] == 0 then
			key = -indices[i]
		elseif densities[j] == 0 then
			key = -indices[j]
		end
		if edges[key] then
			return edges[key]
		end
		local p = positions[i] + (positions[j] - positions[i]) * (densities[i] / (densities[i] - densities[j]))
		p = V.RefineSurfacePoint and V.RefineSurfacePoint(r, p) or p
		edges[key] = p
		return p
	end
	for _, t in ipairs(tetrahedra) do
		local inside, outside = {}, {}
		for _, i in ipairs(t) do
			local list = densities[i] < 0 and inside or outside
			list[#list + 1] = i
		end
		if #inside > 0 and #outside > 0 then
			local outward = Vector()
			for _, i in ipairs(outside) do
				outward = outward + positions[i] / #outside
			end
			for _, i in ipairs(inside) do
				outward = outward - positions[i] / #inside
			end
			if #inside == 1 or #outside == 1 then
				local singleton = #inside == 1 and inside or outside
				local others = #inside == 1 and outside or inside
				emit(
					edge(singleton[1], others[1]),
					edge(singleton[1], others[2]),
					edge(singleton[1], others[3]),
					outward
				)
			else
				local a, b = edge(inside[1], outside[1]), edge(inside[1], outside[2])
				local c, d = edge(inside[2], outside[1]), edge(inside[2], outside[2])
				emit(a, b, c, outward)
				emit(b, d, c, outward)
			end
		end
	end
end

function V.ForCellTriangles(r, x, y, z, emit, checkpoint)
	if not V.ActiveRegionCell(r, x, y, z) then
		return
	end
	if r.bsp then
		for i, t in ipairs(V.BSPCell(r, x, y, z, checkpoint).triangles) do
			emit(t[1], t[2], t[3], t[4], t[5], t[6], t[7])
			if checkpoint and i % 32 == 0 then
				checkpoint()
			end
		end
		return
	end
	local cache, key = V.TerrainCellCache(r, "surfaces", x, y, z)
	local triangles = cache[key]
	if not triangles then
		triangles = {}
		buildCellTriangles(r, x, y, z, function(a, b, c, n)
			triangles[#triangles + 1] = { a, b, c, n }
		end)
		cache[key] = triangles
	end
	for _, t in ipairs(triangles) do
		emit(t[1], t[2], t[3], t[4], r.bsp and "density" or nil)
	end
end

local function mayHaveSurface(r, x, y, z, index)
	if not V.ActiveRegionCell(r, x, y, z) then
		return false
	end
	if r.bsp then
		return V.BSPCellMayHaveSurface(r, x, y, z, index)
	end
	if not r.analysis then
		return true
	end
	index = index or V.Index(x, y, z, r)
	local inside = r.values[index] < 0
	for _, offset in ipairs(offsets) do
		if (r.values[V.Index(x + offset[1], y + offset[2], z + offset[3], r)] < 0) ~= inside then
			return true
		end
	end
	return false
end

-- Nonzero area alone is insufficient for native physics cooking: near-lattice
-- intersections can leave 0.02-unit slivers rejected by VPhysics. Keep this
-- conservative contact tolerance separate from the
-- visible surface and the exact player/tool queries (0.1 SU is about 2.5 mm).
local physicsToleranceSqr = 0.1 ^ 2
function V.PhysicsTriangleUsable(a, b, c, cross)
	local ab2, ac2, bc2 = a:DistToSqr(b), a:DistToSqr(c), b:DistToSqr(c)
	local longest = math.max(ab2, ac2, bc2)
	local area2 = (cross or (b - a):Cross(c - a)):LengthSqr()
	-- Test edges AND altitude; a long, almost collinear triangle also fails.
	return math.min(ab2, ac2, bc2) >= physicsToleranceSqr
		and area2 >= longest * physicsToleranceSqr
		and longest < math.huge
		and area2 < math.huge
end

function V.PhysicsVertices(vertices)
	local result = {}
	for i = 1, #vertices, 3 do
		local a, b, c = vertices[i], vertices[i + 1], vertices[i + 2]
		a, b, c = a.pos or a, b.pos or b, c.pos or c
		if V.PhysicsTriangleUsable(a, b, c) then
			result[#result + 1] = a
			result[#result + 1] = b
			result[#result + 1] = c
		end
	end
	return result
end

-- Static VPhysics needs positions only. Preserve refinement and winding while
-- excluding sub-tolerance slivers. Avoid computing UVs and gradients.
local emptyPhysicsCell = {}
function V.BuildCollisionChunk(r, cx, cy, cz, checkpoint)
	if not V.ActiveRegionCell(r, cx * 8, cy * 8, cz * 8) then
		return {}
	end
	local vertices = {}
	local offset = Vector(cx, cy, cz) * ((r.step or V.Step) * 8)
	local cells = V.TerrainCellCache(r, "physicsCells", cx * 8, cy * 8, cz * 8)
	for z = cz * 8, min(cz * 8 + 7, V.RegionCells(r, "z") - 1) do
		for y = cy * 8, min(cy * 8 + 7, V.RegionCells(r, "y") - 1) do
			for x = cx * 8, min(cx * 8 + 7, V.RegionCells(r, "x") - 1) do
				local key = V.Index(x, y, z, r)
				local cached = cells[key]
				if not cached then
					cached = emptyPhysicsCell
					if mayHaveSurface(r, x, y, z, key) then
						cached = {}
						V.ForCellTriangles(r, x, y, z, function(a, b, c, n)
							local cross = (b - a):Cross(c - a)
							if not V.PhysicsTriangleUsable(a, b, c, cross) then
								return
							end
							if cross:Dot(n) > 0 then
								b, c = c, b
							end
							cached[#cached + 1] = a - offset
							cached[#cached + 1] = b - offset
							cached[#cached + 1] = c - offset
						end, checkpoint)
					end
					-- Immutable positions only. A new native mesh can share distant
					-- cells without repeating tolerance tests or Vector construction.
					cells[key] = cached
				end
				for _, point in ipairs(cached) do
					vertices[#vertices + 1] = point
				end
				if checkpoint and (x - cx * 8 + 8 * (y - cy * 8) + 64 * (z - cz * 8) + 1) % 32 == 0 then
					checkpoint()
				end
			end
		end
	end
	return vertices
end

local emptyRenderCell = {}
-- Cheap broad phase for native collision jobs. Uniform chunks without BSP
-- faces or edited solids cannot contain a surface; no triangulation needed.
function V.CollisionChunkMayHaveSurface(r, cx, cy, cz)
	if not V.ActiveRegionCell(r, cx * 8, cy * 8, cz * 8) then
		return false
	end
	if not r.analysis then
		return true
	end
	local first = r.values[V.Index(cx * 8, cy * 8, cz * 8, r)] < 0
	for z = cz * 8, cz * 8 + 8 do
		for y = cy * 8, cy * 8 + 8 do
			for x = cx * 8, cx * 8 + 8 do
				local key = V.Index(x, y, z, r)
				if (r.values[key] < 0) ~= first then
					return true
				end
				if x < cx * 8 + 8 and y < cy * 8 + 8 and z < cz * 8 + 8 then
					if
						r.bsp
						and (
							(r.bspFaceBins and r.bspFaceBins[key])
							or (r.bspTerrainFaces and r.bspTerrainFaces[key])
							or (r.bspCellEditBins and r.bspCellEditBins[key])
						)
					then
						return true
					end
				end
			end
		end
	end
	return false
end
function V.BuildChunk(r, cx, cy, cz, checkpoint)
	if not V.ActiveRegionCell(r, cx * 8, cy * 8, cz * 8) then
		return {}
	end
	local vertices = {}
	local light = not r.analysis and Vector(0.35, -0.25, 0.9):GetNormalized()
	local chunkOrigin = Vector(cx, cy, cz) * ((r.step or V.Step) * 8)
	local normalCache = V.TerrainCellCache(r, "smoothNormals", cx * 8, cy * 8, cz * 8)
	local vertexCache = {}
	local cells = V.TerrainCellCache(r, "renderCells", cx * 8, cy * 8, cz * 8)
	local currentCell
	local function emit(a, b, c, outward, curved, brush, nativeFace)
		local cross = (b - a):Cross(c - a)
		if cross:LengthSqr() < 0.000001 then
			return
		end
		if cross:Dot(outward) > 0 then
			b, c = c, b
		end
		local faceNormal = (b - a):Cross(c - a):GetNormalized() * -1
		for _, p in ipairs({ a, b, c }) do
			local data = vertexCache[p]
			if not data then
				local world = r.origin + p
				local normal = normalCache[p]
				if not normal then
					normal = brush
							and ((brush.seed or brush.floorZ ~= nil or brush.plane) and faceNormal or (p - brush.center):GetNormalized() * (brush.adding and 1 or -1))
						or (r.bsp and not curved and faceNormal or V.Normal(r, world))
					normalCache[p] = normal
				end
				data = { world = world, pos = p - chunkOrigin, normal = normal, u = world.x / 128, v = world.y / 128 }
				vertexCache[p] = data
			end
			local world, normal = data.world, data.normal
			if brush and (brush.seed or brush.floorZ ~= nil or brush.plane) then
				normal = faceNormal
			end
			if r.bsp and curved ~= "density" then
				if not curved or normal:LengthSqr() < 0.5 then
					normal = faceNormal
				end
			elseif V.FeatureNormal then
				normal = V.FeatureNormal(r, world, faceNormal, normal)
			end
			local color = scanColor
			if light then
				local shade = 0.45 + 0.55 * max(0, normal:Dot(light))
				color = Color(155 * shade, 121 * shade, 82 * shade)
			end
			local u, v = data.u, data.v
			vertices[#vertices + 1] = {
				pos = data.pos,
				normal = normal,
				color = color,
				u = u,
				v = v,
				cell = currentCell,
				nativeFace = nativeFace,
			}
		end
	end
	for z = cz * 8, min(cz * 8 + 7, V.RegionCells(r, "z") - 1) do
		for y = cy * 8, min(cy * 8 + 7, V.RegionCells(r, "y") - 1) do
			for x = cx * 8, min(cx * 8 + 7, V.RegionCells(r, "x") - 1) do
				currentCell = V.Index(x, y, z, r)
				local cached = cells[currentCell]
				if cached then
					for _, vertex in ipairs(cached) do
						vertices[#vertices + 1] = vertex
					end
				else
					cached = emptyRenderCell
					if mayHaveSurface(r, x, y, z, currentCell) then
						cached = {}
						local first = #vertices + 1
						V.ForCellTriangles(r, x, y, z, emit, checkpoint)
						for i = first, #vertices do
							cached[#cached + 1] = vertices[i]
						end
					end
					-- An empty render cell is also a completed result. Retain it so
					-- small edits don't resample every full/empty cell in each chunk.
					cells[currentCell] = cached
				end
				if checkpoint and (x - cx * 8 + 8 * (y - cy * 8) + 64 * (z - cz * 8) + 1) % 32 == 0 then
					checkpoint()
				end
			end
		end
	end
	return vertices
end
function V.ForChunks(callback, r)
	for z = 0, (r and r.nz or nz) / 8 - 1 do
		for y = 0, (r and r.ny or ny) / 8 - 1 do
			for x = 0, (r and r.nx or nx) / 8 - 1 do
				callback(x, y, z)
			end
		end
	end
end

function V.Trace(ply, reach)
	return util.TraceLine({
		start = ply:GetShootPos(),
		endpos = ply:GetShootPos() + ply:GetAimVector() * reach,
		filter = function(ent)
			return ent ~= ply and ent:GetClass() ~= "vm_voxel_collider"
		end,
		mask = MASK_SOLID,
	})
end

function V.BrushCenter(trace, radius, adding)
	return trace.HitPos + trace.HitNormal * (adding and radius * 0.3 or -radius * 0.3)
end
