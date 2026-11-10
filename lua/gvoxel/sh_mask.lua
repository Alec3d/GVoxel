-- Geometry for a volume mask; no render/physics functions in this module.
local V = GVoxel

function V.MaskFaces(r, normals)
	local p = r.origin
	local s = V.RegionSize(r)
	local px, py, pz = p.x, p.y, p.z
	local sx, sy, sz = s.x, s.y, s.z
	-- Geometry vertices are immutable. The six faces share their eight
	-- corners, so later clips can also share classifications/intersections.
	local corners = {}
	-- Each coordinate axis is shared by four faces of this box.
	local openingAxes = not r.bsp and r.values and {} or nil
	local function v(x, y, z)
		local key = 1 + x + 2 * y + 4 * z
		if not corners[key] then
			corners[key] = Vector(px + x * sx, py + y * sy, pz + z * sz)
		end
		return corners[key]
	end
	local function face(normal, a, b, c, d)
		return { normal = normal, point = a, vertices = { a, b, c, d }, openingAxes = openingAxes }
	end
	return {
		face(normals and normals[1] or Vector(-1, 0, 0), v(0, 0, 0), v(0, 0, 1), v(0, 1, 1), v(0, 1, 0)),
		face(normals and normals[2] or Vector(1, 0, 0), v(1, 0, 0), v(1, 1, 0), v(1, 1, 1), v(1, 0, 1)),
		face(normals and normals[3] or Vector(0, -1, 0), v(0, 0, 0), v(1, 0, 0), v(1, 0, 1), v(0, 0, 1)),
		face(normals and normals[4] or Vector(0, 1, 0), v(0, 1, 0), v(0, 1, 1), v(1, 1, 1), v(1, 1, 0)),
		face(normals and normals[5] or Vector(0, 0, -1), v(0, 0, 0), v(0, 1, 0), v(1, 1, 0), v(1, 0, 0)),
		face(normals and normals[6] or Vector(0, 0, 1), v(0, 0, 1), v(1, 0, 1), v(1, 1, 1), v(0, 1, 1)),
	}
end

function V.InScanCube(r, p)
	local q = p - r.origin
	return q.x >= 0
		and q.x <= V.RegionAxisSize(r, "x")
		and q.y >= 0
		and q.y <= V.RegionAxisSize(r, "y")
		and q.z >= 0
		and q.z <= V.RegionAxisSize(r, "z")
end

function V.MaskFaceIsExit(face, eye)
	return (eye - face.point):Dot(face.normal) <= 0
end

-- Slab intersection also used by the mask's independent pixel-level tests.
function V.CubeRayInterval(r, start, direction)
	local q = start - r.origin
	local entry, exit = -math.huge, math.huge
	for _, axis in ipairs({ "x", "y", "z" }) do
		local d, p = direction[axis], q[axis]
		if math.abs(d) < 1e-10 then
			if p < 0 or p > V.RegionAxisSize(r, axis) then
				return
			end
		else
			local a, b = -p / d, (V.RegionAxisSize(r, axis) - p) / d
			if a > b then
				a, b = b, a
			end
			entry, exit = math.max(entry, a), math.min(exit, b)
			if entry > exit then
				return
			end
		end
	end
	if exit < 0 then
		return
	end
	return math.max(0, entry), exit
end

function V.MaskReady(scan)
	return scan and scan.phase == 2 and scan.densityReady and scan.built == scan.chunkCount
end

local axes = { "x", "y", "z" }

local function alignedAxis(edge)
	if edge.x ~= 0 and edge.y == 0 and edge.z == 0 then
		return 1
	end
	if edge.x == 0 and edge.y ~= 0 and edge.z == 0 then
		return 2
	end
	if edge.x == 0 and edge.y == 0 and edge.z ~= 0 then
		return 3
	end
end

local function latticeCoordinate(value, limit)
	return math.max(0, math.min(limit, math.floor(value + 0.5)))
end

local function openingAxis(r, face, origin, direction, count, axis, stride)
	local limit, step = V.RegionCells(r, axis), r.step
	local cache = face.openingAxes
	local start, basis, scale = origin[axis], r.origin[axis], direction[axis]
	local previous = cache and cache[axis]
	if previous and previous.start == start and previous.basis == basis and previous.scale == scale
		and previous.count == count and previous.stride == stride and previous.limit == limit and previous.step == step then
		return previous.coordinate, previous.index, previous.gap
	end
	local coordinate, index = {}, {}
	local gap = math.huge
	local p = Vector()
	for i = 0, count do
		-- The other direction has zero on this axis. Keep each Source vector
		-- rounding step in the original point and lattice-index calculation.
		p:Set(direction)
		p:Mul(i)
		p:Mul(step)
		p:Add(origin)
		coordinate[i] = p[axis]
		p:Sub(r.origin)
		p:Div(step)
		index[i] = latticeCoordinate(p[axis], limit) * stride
		if i > 0 then
			gap = math.min(gap, math.abs(coordinate[i] - coordinate[i - 1]))
		end
	end
	if cache then
		cache[axis] = { start = start, basis = basis, scale = scale, count = count,
			stride = stride, limit = limit, step = step, coordinate = coordinate, index = index, gap = gap }
	end
	return coordinate, index, gap
end

-- Compile only the air part of each boundary face. Its diagonal is identical
-- to the tetrahedron split, so openings meet the terrain without square caps.
function V.BuildBoundaryOpening(r, face, checkpoint)
	local bsp = r.bsp
	if bsp and not r.bspFallback then
		return V.BSPBoundaryOpening(r, face, checkpoint)
	end
	local densityField = bsp and V.BSPDensityBase(r) or r
	local vertices = {}
	local origin = face.vertices[1]
	local edgeU, edgeV = face.vertices[2] - origin, face.vertices[4] - origin
	local step, normal = r.step, face.normal
	local countU, countV = math.floor(edgeU:Length() / step + 0.5), math.floor(edgeV:Length() / step + 0.5)
	local u = edgeU / (countU * step)
	local v = edgeV / (countV * step)
	local axisU, axisV = alignedAxis(edgeU), alignedAxis(edgeV)
	local position, firstIndex, alongU, alongV, indexU, indexV
	if not bsp and axisU and axisV and axisU ~= axisV and countU > 0 and countV > 0 then
		local strides = { 1, V.Index(0, 1, 0, r) - 1, V.Index(0, 0, 1, r) - 1 }
		local gapU, gapV
		alongU, indexU, gapU = openingAxis(r, face, origin, u, countU, axes[axisU], strides[axisU])
		alongV, indexV, gapV = openingAxis(r, face, origin, v, countV, axes[axisV], strides[axisV])
		-- Skip per-triangle area checks only when the rounded lattice itself
		-- guarantees both triangles have area above the clipping tolerance.
		if gapU * gapV >= 0.002 then
			local q = (origin - r.origin) / step
			local fixed = 6 - axisU - axisV
			position = { origin.x, origin.y, origin.z }
			firstIndex = 1 + strides[fixed] * latticeCoordinate(q[axes[fixed]], V.RegionCells(r, axes[fixed]))
		end
	end
	local function vertex(p)
		return { pos = p, normal = normal, u = 0, v = 0 }
	end
	local sample = V.Sample
	local values = densityField.values
	local strideY, strideZ, latticeStep
	if bsp then
		strideY = V.Index(0, 1, 0, r) - 1
		strideZ = V.Index(0, 0, 1, r) - 1
		latticeStep = densityField.densityVectorStep or Vector(step, 0, 0).x
		densityField.densityVectorStep = latticeStep
	end
	local function latticePoint(corner)
		local point = corner.latticePoint
		if not point then
			local i = corner.lattice - 1
			local x = i % strideY
			local y = math.floor(i % strideZ / strideY)
			local z = math.floor(i / strideZ)
			point = Vector(x * latticeStep, y * latticeStep, z * latticeStep)
			corner.latticePoint = point
		end
		return point
	end
	local function gridVertex(i, j)
		position[axisU], position[axisV] = alongU[i], alongV[j]
		return vertex(Vector(position[1], position[2], position[3]))
	end
	local function row(j)
		local points, density = {}, {}
		local air = 0
		if position then
			position[axisV] = alongV[j]
			local rowIndex = firstIndex + indexV[j]
			for i = 0, countU do
				local value = values[rowIndex + indexU[i]]
				density[i] = value
				if value > 0 then
					air = air + 1
					position[axisU] = alongU[i]
					points[i] = vertex(Vector(position[1], position[2], position[3]))
				end
			end
		else
			for i = 0, countU do
				local p = origin + (u * i + v * j) * step
				local q = (p - r.origin) / step
				local x, y, z = math.floor(q.x + 0.5), math.floor(q.y + 0.5), math.floor(q.z + 0.5)
				local corner = vertex(p)
				if bsp then
					corner.lattice = V.Index(x, y, z, r)
				end
				points[i] = corner
				density[i] = sample(densityField, x, y, z)
			end
		end
		return points, density, air
	end
	local vertexCount = 0
	local function emit(a, b, c)
		vertices[vertexCount + 1], vertices[vertexCount + 2], vertices[vertexCount + 3] = a, b, c
		vertexCount = vertexCount + 3
	end
	local function emitTile(a, b, c, d)
		-- Opening vertices are immutable and may be shared by triangles.
		vertices[vertexCount + 1], vertices[vertexCount + 2], vertices[vertexCount + 3] = a, b, c
		vertices[vertexCount + 4], vertices[vertexCount + 5], vertices[vertexCount + 6] = a, c, d
		vertexCount = vertexCount + 6
	end
	local function nonDegenerate(a, b, c)
		return (b - a):Cross(c - a):LengthSqr() > 0.000001
	end
	local function emitBSP(part)
		for i = 2, #part - 1 do
			local a, b, c = part[1], part[i], part[i + 1]
			if nonDegenerate(a, b, c) then
				emit(vertex(a), vertex(b), vertex(c))
			end
		end
	end
	local function clipEdge(part, last, density, current, nextDensity, edges)
		local currentAir = nextDensity > 0
		if (density > 0) ~= currentAir then
			local p
			if edges then
				-- The retained displacement and its aperture meet on the
				-- same refined lattice edge, including after an interior edit.
				p = V.DensityEdgePoint(
					densityField,
					edges,
					last.lattice,
					current.lattice,
					latticePoint(last),
					latticePoint(current),
					density,
					nextDensity
				)
				p = r.origin + p
			else
				local t = density / (density - nextDensity)
				p = current.pos - last.pos
				p:Mul(t)
				p:Add(last.pos)
				if V.RefineSurfacePoint then
					p:Sub(r.origin)
					p = r.origin + V.RefineSurfacePoint(r, p)
				end
			end
			part[#part + 1] = vertex(p)
		end
		if currentAir then
			part[#part + 1] = current
		end
	end
	local function clip(a, b, c, da, db, dc, x, y, z)
		if da <= 0 and db <= 0 and dc <= 0 then
			return
		end
		if position and da > 0 and db > 0 and dc > 0 then
			emit(a, b, c)
			return
		end
		local part = {}
		local edges = bsp and (da <= 0 or db <= 0 or dc <= 0)
			and V.TerrainCellCache(densityField, "densityEdges", x, y, z)
		clipEdge(part, c, dc, a, da, edges)
		clipEdge(part, a, da, b, db, edges)
		clipEdge(part, b, db, c, dc, edges)
		if bsp and #part >= 3 then
			for i, point in ipairs(part) do
				part[i] = point.pos
			end
			V.ClipBSPDetailOpening(r, part, normal, x, y, z, emitBSP, checkpoint)
		else
			local a = part[1]
			for i = 2, #part - 1 do
				local b, c = part[i], part[i + 1]
				if nonDegenerate(a.pos, b.pos, c.pos) then
					emit(a, b, c)
				end
			end
		end
	end
	local lower, lowerDensity, lowerAir = row(0)
	for j = 0, countV - 1 do
		local upper, upperDensity, upperAir = row(j + 1)
		local firstCheckpoint = checkpoint and (-j * r.nx) % 16
		if position and lowerAir == 0 and upperAir == 0 then
			if checkpoint then
				for i = firstCheckpoint, countU - 1, 16 do
					checkpoint()
				end
			end
		elseif position and lowerAir == countU + 1 and upperAir == countU + 1 then
			for i = 0, countU - 1 do
				emitTile(lower[i], lower[i + 1], upper[i + 1], upper[i])
				if checkpoint and i % 16 == firstCheckpoint then
					checkpoint()
				end
			end
		else
			for i = 0, countU - 1 do
				local a, b, c, d = lower[i], lower[i + 1], upper[i + 1], upper[i]
				local da, db, dc, dd = lowerDensity[i], lowerDensity[i + 1], upperDensity[i + 1], upperDensity[i]
				local x, y, z
				if bsp then
					local center = ((a.pos + c.pos) / 2 - normal * (step * 0.5) - r.origin) / step
					x, y, z = math.floor(center.x + 0.000001), math.floor(center.y + 0.000001),
						math.floor(center.z + 0.000001)
				end
				if bsp and not V.BSPCellUsesDensity(r, x, y, z) then
					local tile = { normal = normal, vertices = { a.pos, b.pos, c.pos, d.pos } }
					for _, point in ipairs(V.BSPBoundaryOpening(r, tile, checkpoint)) do
						vertexCount = vertexCount + 1
						vertices[vertexCount] = point
					end
				elseif position and da > 0 and db > 0 and dc > 0 and dd > 0 then
					emitTile(a, b, c, d)
				elseif da > 0 or db > 0 or dc > 0 or dd > 0 then
					if position then
						-- Fully solid tiles need no vectors. Materialize only the
						-- missing solid corners of tiles the isosurface crosses.
						a, b = a or gridVertex(i, j), b or gridVertex(i + 1, j)
						c, d = c or gridVertex(i + 1, j + 1), d or gridVertex(i, j + 1)
						lower[i], lower[i + 1], upper[i + 1], upper[i] = a, b, c, d
					end
					clip(a, b, c, da, db, dc, x, y, z)
					clip(a, c, d, da, dc, dd, x, y, z)
				end
				if checkpoint and i % 16 == firstCheckpoint then
					checkpoint()
				end
			end
		end
		lower, lowerDensity, lowerAir = upper, upperDensity, upperAir
	end
	return vertices
end
