-- Exact architectural faces + local, piecewise-linear sculpt CSG. Rendering,
-- aiming and collision consume the same cell geometry. Work is cached per chunk.
local V = GVoxel
local names = { "x", "y", "z" }
local boxNormals = { Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1) }
local oppositeBoxNormals = { -boxNormals[1], -boxNormals[2], -boxNormals[3] }
local tangentZ, tangentY = boxNormals[3], boxNormals[2]
local tangentBases = setmetatable({}, { __mode = "k" })
local EPS = 0.0000001
-- Keep plane classification in Lua doubles: Vector:Dot rounds to a float in Source.
local function polygonDistance(p, nx, ny, nz, d, distances)
	local value = distances and distances[p]
	if value == nil then
		value = p.x * nx + p.y * ny + p.z * nz - d
		if distances then
			distances[p] = value
		end
	end
	return value
end

local polygonZero, polygonCenter, polygonDelta = Vector(), Vector(), Vector()
local function orderPolygon(polygon, n)
	local center, delta = polygonCenter, polygonDelta
	center:Set(polygonZero)
	for _, p in ipairs(polygon) do
		delta:Set(p)
		delta:Div(#polygon)
		center:Add(delta)
	end
	local nx, ny, nz = n.x, n.y, n.z
	local frame = tangentBases[n]
	if not frame or frame.x ~= nx or frame.y ~= ny or frame.z ~= nz then
		local u = n:Cross(math.abs(nz) < 0.9 and tangentZ or tangentY):GetNormalized()
		frame = { x = nx, y = ny, z = nz, u = u, v = n:Cross(u) }
		tangentBases[n] = frame
	end
	local u, v = frame.u, frame.v
	local angles = {}
	for _, p in ipairs(polygon) do
		delta:Set(p)
		delta:Sub(center)
		angles[p] = math.atan2(delta:Dot(v), delta:Dot(u))
	end
	table.sort(polygon, function(a, b)
		return angles[a] < angles[b]
	end)
end

function V.ClipBSPPolygon(polygon, n, d, shared)
	local nx, ny, nz = n.x, n.y, n.z
	if nx == 0 and ny == 0 and nz == 0 then
		return d >= -EPS and polygon or {}
	end
	-- A polytope's faces share endpoints. Classify each endpoint once and
	-- keep the same intersection object on both incident faces. The context
	-- belongs to one plane/clip only, never to a mutable global scratch area.
	local distances = shared and shared.distances
	local a = polygon[#polygon]
	if not a then
		return polygon
	end
	local da = distances and distances[a] or polygonDistance(a, nx, ny, nz, d, distances)
	local outside = da > EPS
	local straddles = false
	for i = 1, #polygon - 1 do
		local p = polygon[i]
		local db = distances and distances[p] or polygonDistance(p, nx, ny, nz, d, distances)
		if (db > EPS) ~= outside then
			straddles = true
			break
		end
	end
	if not straddles then
		return outside and {} or polygon
	end
	local out, cuts = {}, {}
	for _, b in ipairs(polygon) do
		local db = distances and distances[b] or polygonDistance(b, nx, ny, nz, d, distances)
		if (da > EPS) ~= (db > EPS) then
			-- Canonical order makes shared cell/face intersections identical.
			local p, q, dp, dq = a, b, da, db
			if p.x > q.x or (p.x == q.x and (p.y > q.y or (p.y == q.y and p.z > q.z))) then
				p, q, dp, dq = q, p, dq, dp
			end
			local edges = shared and shared.edges[p]
			local intersection = edges and edges[q]
			if not intersection then
				local t = math.max(0, math.min(1, dp / (dp - dq)))
				intersection = q - p
				intersection:Mul(t)
				intersection:Add(p)
				if shared then
					if not edges then
						edges = {}
						shared.edges[p] = edges
					end
					edges[q] = intersection
				end
			end
			out[#out + 1] = intersection
			cuts[#cuts + 1] = intersection
		end
		if db <= EPS then
			out[#out + 1] = b
		end
		a, da = b, db
	end
	return out, cuts
end

-- Plane classification is synchronous. Only a real split needs its own
-- endpoint map, since the following face clips share those projections.
local clipDistances = {}
local function clip(poly, n, d, tag, band, shared)
	local nx, ny, nz = n.x, n.y, n.z
	if nx == 0 and ny == 0 and nz == 0 then
		if d >= -EPS then
			return poly
		end
		return
	end
	if not shared then
		local distances
		local inside, outside = false, false
		local insideLower, outsideLower = false, false
		local points = poly.points
		if points then
			for i, p in ipairs(points) do
				local dot = p.x * nx + p.y * ny + p.z * nz
				local v = dot - d
				clipDistances[i] = v
				inside = inside or v < -EPS
				outside = outside or v > EPS
				if band then
					local lower = dot - band.low
					insideLower = insideLower or lower > EPS
					outsideLower = outsideLower or lower < -EPS
				end
			end
		else
			distances = {}
			for _, face in ipairs(poly.faces) do
				for _, p in ipairs(face.vertices) do
					if distances[p] == nil then
						local dot = p.x * nx + p.y * ny + p.z * nz
						local v = dot - d
						distances[p] = v
						inside = inside or v < -EPS
						outside = outside or v > EPS
						if band then
							local lower = dot - band.low
							insideLower = insideLower or lower > EPS
							outsideLower = outsideLower or lower < -EPS
						end
					end
				end
			end
		end
		if not outside then
			-- A support interval has two opposing faces. If the upper face
			-- left the piece intact, the same projections classify the lower.
			if outsideLower then
				if insideLower then
					return clip(poly, band.opposite or -n, -band.low)
				end
				return
			end
			return poly
		end
		if not inside then
			return
		end
		if points then
			distances = {}
			for i, p in ipairs(points) do distances[p] = clipDistances[i] end
		end
		shared = { distances = distances, edges = {} }
	end
	local distances = shared.distances
	local faces, points, cap, seen = {}, {}, {}, {}
	local function addCap(p)
		local state = seen[p] or 0
		if state >= 2 then
			return
		end
		seen[p] = state + 2
		local x, y, z = p.x, p.y, p.z
		local key
		for _, q in ipairs(cap) do
			local qx = q.x
			if math.abs(x - qx) <= 2 * EPS then
				local qy, qz = q.y, q.z
				if math.abs(y - qy) <= 2 * EPS and math.abs(z - qz) <= 2 * EPS then
					-- Preserve the original decimal key for nearby points,
					-- including coordinates that differ only by signed zero.
					key = key or string.format("%.7f:%.7f:%.7f", x, y, z)
					if key == string.format("%.7f:%.7f:%.7f", qx, qy, qz) then
						return
					end
				end
			end
		end
		cap[#cap + 1] = p
	end
	for _, face in ipairs(poly.faces) do
		local polygon, intersections = V.ClipBSPPolygon(face.vertices, n, d, shared)
		if #polygon >= 3 then
			faces[#faces + 1] = polygon == face.vertices and face
				or { vertices = polygon, normal = face.normal, tag = face.tag, appearance = face.appearance }
			-- Keep the intersections explicitly: their stored float coordinates
			-- need not lie within 1e-5 of the plane after rounding.
			if intersections then
				for _, p in ipairs(intersections) do
					addCap(p)
				end
			end
			for _, p in ipairs(polygon) do
				local state = seen[p] or 0
				if state == 0 or state == 2 then
					points[#points + 1] = p
					seen[p] = state + 1
				end
				if state < 2 and math.abs(polygonDistance(p, nx, ny, nz, d, distances)) <= EPS then
					addCap(p)
				end
			end
		end
	end
	if #cap >= 3 then
		orderPolygon(cap, n)
		faces[#faces + 1] = { vertices = cap, normal = n, tag = tag, appearance = poly.appearance }
	end
	if #faces < 4 then
		return
	end
	local result = { faces = faces, points = points, solid = poly.solid, loose = poly.loose, appearance = poly.appearance }
	if band then
		return clip(result, band.opposite or -n, -band.low)
	end
	return result
end
V.ClipBSPPolytope = clip

-- An addition needs both sides of the same plane. Share projections and
-- the canonical edge intersections instead of clipping the same edges twice.
local function clipPair(poly, n, opposite, d, tag)
	local points = poly.points
	if not points then
		return clip(poly, n, d, tag), clip(poly, opposite, -d, tag)
	end
	local nx, ny, nz = n.x, n.y, n.z
	local below, above = false, false
	for i, p in ipairs(points) do
		local q = p.x * nx + p.y * ny + p.z * nz - d
		clipDistances[i] = q
		below = below or q < -EPS
		above = above or q > EPS
	end
	if not above then return poly, not below and poly or nil end
	if not below then return nil, poly end
	local distances, reverse, edges = {}, {}, {}
	for i, p in ipairs(points) do
		local q = clipDistances[i]
		distances[p], reverse[p] = q, -q
	end
	return clip(poly, n, d, tag, nil, { distances = distances, edges = edges }),
		clip(poly, opposite, -d, tag, nil, { distances = reverse, edges = edges })
end

local maskBoxNormals = {
	oppositeBoxNormals[1], boxNormals[1], oppositeBoxNormals[2], boxNormals[2],
	oppositeBoxNormals[3], boxNormals[3],
}
local function box(low, high)
	local r = { origin = low, side = high.x - low.x }
	local faces = V.MaskFaces(r, maskBoxNormals)
	local a, b = faces[1].vertices, faces[2].vertices
	return { faces = faces, points = { a[1], a[2], a[3], a[4], b[1], b[2], b[3], b[4] } }
end
local function localPlaneDistance(r, plane)
	local distances = r.bspLocalDistances
	if not distances then
		distances = {}
		r.bspLocalDistances = distances
	end
	local distance = distances[plane]
	if distance == nil then
		distance = plane.distance - plane.normal:Dot(r.origin)
		distances[plane] = distance
	end
	return distance
end

local function splitWorld(r, poly, index, out, depth, checkpoint, keepAir, points)
	local data = r.bsp
	if not poly then
		return
	end
	assert(depth < 1024, "arbre BSP trop profond")
	if checkpoint and depth % 8 == 0 then
		checkpoint()
	end
	if index < 0 then
		local solid = data.leaves[-index].solid
		if not solid and not keepAir then return end
		poly = { faces = poly.faces, points = poly.points or points, solid = solid }
		out[#out + 1] = poly
		return
	end
	local node = data.nodes[index + 1]
	local plane = data.planes[node.plane]
	local n, d = plane.normal, localPlaneDistance(r, plane)
	points = points or poly.points
	if not points then
		local seen = {}
		points = {}
		for _, face in ipairs(poly.faces) do
			for _, p in ipairs(face.vertices) do
				if not seen[p] then
					seen[p] = true
					points[#points + 1] = p
				end
			end
		end
	end
	-- BSP traversal commonly visits several nodes before the first split.
	-- Classify the same unique vertices until the polytope actually changes.
	local front, back = false, false
	for _, p in ipairs(points) do
		local q = p:Dot(n) - d
		front = front or q > EPS
		back = back or q < -EPS
		if front and back then
			break
		end
	end
	if not back then
		splitWorld(r, poly, node.front, out, depth + 1, checkpoint, keepAir, points)
	elseif not front then
		splitWorld(r, poly, node.back, out, depth + 1, checkpoint, keepAir, points)
	else
		local front = keepAir or node.front >= 0 or data.leaves[-node.front].solid
		local back = keepAir or node.back >= 0 or data.leaves[-node.back].solid
		local backPiece, frontPiece
		if front and back then
			backPiece, frontPiece = clipPair(poly, n, -n, d)
		elseif front then
			frontPiece = clip(poly, -n, -d)
		elseif back then
			backPiece = clip(poly, n, d)
		end
		splitWorld(r, frontPiece, node.front, out, depth + 1, checkpoint, keepAir)
		splitWorld(r, backPiece, node.back, out, depth + 1, checkpoint, keepAir)
	end
end

local function projectedOverlap(points, u, v, loU, hiU, loV, hiV)
	local cu, cv, hu, hv = (loU + hiU) / 2, (loV + hiV) / 2, (hiU - loU) / 2, (hiV - loV) / 2
	for i, p in ipairs(points) do
		local q = points[i % 3 + 1]
		local a, b = -(q[v] - p[v]), q[u] - p[u]
		local low, high = math.huge, -math.huge
		for _, vertex in ipairs(points) do
			local d = a * vertex[u] + b * vertex[v]
			low = math.min(low, d)
			high = math.max(high, d)
		end
		local center, radius = a * cu + b * cv, math.abs(a) * hu + math.abs(b) * hv
		if high <= center - radius + EPS or low >= center + radius - EPS then
			return false
		end
	end
	return true
end

-- A displacement influences its actual projected footprint and the soil side
-- of its shell. Padding its AABB by two cells and extending BOTH directions
-- replaced neighbouring building corners and whole walls with sampled density.
local function indexDisplacement(r, face, checkpoint)
	local axis = 1
	for i = 2, 3 do
		if math.abs(face.normal[names[i]]) > math.abs(face.normal[names[axis]]) then
			axis = i
		end
	end
	local n, u, v = names[axis], names[axis % 3 + 1], names[(axis + 1) % 3 + 1]
	local grid, width = face.dispGrid, face.dispWidth
	local flat = true
	local distance = face.normal:Dot(grid[1])
	for _, p in ipairs(grid) do
		if math.abs(face.normal:Dot(p) - distance) > 0.00001 then
			flat = false
			break
		end
	end
	local function triangle(points)
		local low, high = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
		for _, p in ipairs(points) do
			for _, a in ipairs(names) do
				low[a] = math.min(low[a], p[a])
				high[a] = math.max(high[a], p[a])
			end
		end
		local normal = (points[2] - points[1]):Cross(points[3] - points[1]):GetNormalized()
		if normal:LengthSqr() < 0.5 then
			return
		end
		if normal:Dot(face.normal) < 0 then
			normal = -normal
		end
		-- Rasterize intersections with lattice columns once during analysis.
		-- These compiled surfaces remain available even when Source traces
		-- cannot see the back of a displacement or its ray collision is off.
		local distance = points[1].x * normal.x + points[1].y * normal.y + points[1].z * normal.z
		if r.bspTerrainColumns then
			for i, name in ipairs(names) do
				if math.abs(normal[name]) > 0.000001 then
					local u, v = names[i % 3 + 1], names[(i + 1) % 3 + 1]
					local loU = math.max(0, math.ceil((low[u] - r.origin[u]) / r.step - 0.000001))
					local hiU = math.min(V.RegionCells(r, u), math.floor((high[u] - r.origin[u]) / r.step + 0.000001))
					local loV = math.max(0, math.ceil((low[v] - r.origin[v]) / r.step - 0.000001))
					local hiV = math.min(V.RegionCells(r, v), math.floor((high[v] - r.origin[v]) / r.step + 0.000001))
					for b = loV, hiV do
						for a = loU, hiU do
							local pu, pv = r.origin[u] + a * r.step, r.origin[v] + b * r.step
							local positive, negative = false, false
							for j, p in ipairs(points) do
								local q = points[j % 3 + 1]
								local cross = (q[u] - p[u]) * (pv - p[v]) - (q[v] - p[v]) * (pu - p[u])
								positive = positive or cross > 0.00001
								negative = negative or cross < -0.00001
							end
							if not (positive and negative) then
								local t = (distance - normal[u] * pu - normal[v] * pv) / normal[name]
								-- An exposed top can be outside the vertical scan bounds
								-- while its soil still intersects this zone.
								if t == t then
									local point = Vector()
									point[u] = pu
									point[v] = pv
									point[name] = t
									local key = a + b * 33
									local columns = r.bspTerrainColumns[i]
									columns[key] = columns[key] or {}
									columns[key][#columns[key] + 1] = {
										t = t,
										kind = "surface",
										point = point,
										compiled = true,
										hit = {
											Hit = true,
											HitWorld = true,
											HitPos = point,
											HitNormal = normal,
											HitTexture = "**displacement**",
										},
									}
								end
							end
						end
						if checkpoint and b % 4 == 3 then
							checkpoint()
						end
					end
				end
			end
		end
		local ulo, uhi =
			math.max(0, math.floor((low[u] - r.origin[u] + EPS) / r.step)),
			math.min(V.RegionCells(r, u) - 1, math.floor((high[u] - r.origin[u] - EPS) / r.step))
		local vlo, vhi =
			math.max(0, math.floor((low[v] - r.origin[v] + EPS) / r.step)),
			math.min(V.RegionCells(r, v) - 1, math.floor((high[v] - r.origin[v] - EPS) / r.step))
		-- A zero sample is air. A horizontal top on a lattice plane belongs
		-- to the solid cell BELOW it, a downward face to the cell above it.
		-- Source Vectors round to floats; the polygon epsilon is too small
		-- for ownership at real map coordinates. Stay within network precision.
		local gridEpsilon = 1 / 64
		local ownership = face.normal[n] > 0 and -gridEpsilon or gridEpsilon
		local shellLow, shellHigh =
			math.max(0, math.floor((low[n] - r.origin[n] + ownership) / r.step)),
			math.min(V.RegionCells(r, n) - 1, math.floor((high[n] - r.origin[n] + ownership) / r.step))
		local contactLow = math.max(0, math.floor((low[n] - r.origin[n] - gridEpsilon) / r.step))
		local contactHigh =
			math.min(V.RegionCells(r, n) - 1, math.floor((high[n] - r.origin[n] + gridEpsilon) / r.step))
		local bottom, top = 0, math.min(V.RegionCells(r, n) - 1, math.floor((high[n] - r.origin[n] + EPS) / r.step))
		if face.normal[n] < 0 then
			bottom = math.max(0, math.floor((low[n] - r.origin[n] + EPS) / r.step))
			top = V.RegionCells(r, n) - 1
		end
		local tri =
			{ vertices = points, normal = normal, localSpace = false, flat = flat, source = face.source or face }
		for b = vlo, vhi do
			for a = ulo, uhi do
				local loU, loV = r.origin[u] + a * r.step, r.origin[v] + b * r.step
				if projectedOverlap(points, u, v, loU, loU + r.step, loV, loV + r.step) then
					local function key(c)
						if axis == 1 then
							return V.Index(c, a, b, r)
						elseif axis == 2 then
							return V.Index(b, c, a, r)
						end
						return V.Index(a, b, c, r)
					end
					for c = bottom, top do
						r.bspFallback[key(c)] = true
					end
					-- Classification must see a shell on either side of a grid
					-- boundary. Rendering still assigns it to just one cell.
					for c = contactLow, contactHigh do
						local k = key(c)
						local cell = r.bspTerrainCells[k] or {}
						cell[#cell + 1] = tri
						cell.curved = cell.curved or not flat
						r.bspTerrainCells[k] = cell
					end
					for c = shellLow, shellHigh do
						local k = key(c)
						r.bspTerrainFaces[k] = r.bspTerrainFaces[k] or {}
						r.bspTerrainFaces[k][#r.bspTerrainFaces[k] + 1] = tri
					end
				end
			end
		end
		if checkpoint then
			checkpoint()
		end
	end
	if width then
		V.ForDisplacementTriangles(face, triangle, checkpoint)
	else
		for i = 2, #grid - 1 do
			triangle({ grid[1], grid[i], grid[i + 1] })
		end
	end
end

local function openTerrainFace(data, face)
	-- Rendered world sheets with air on both sides have no closed brush to
	-- supply occupancy. Treat their back as soil, using the authored normal.
	if
		face.displacement
		or not face.vertices
		or math.abs(face.normal.z) < 0.05
		or bit.band(face.tex.flags or 0, 654) ~= 0
	then
		return false
	end
	local p = Vector()
	for _, vertex in ipairs(face.vertices) do
		p = p + vertex / #face.vertices
	end
	return not V.BSPSolid(data, p - face.normal * 0.03125) and not V.BSPSolid(data, p + face.normal * 0.03125)
end

function V.PrepareBSPRegion(r, data, checkpoint, columnSampling)
	r.bsp = data
	r.bspFaces = {}
	r.bspFaceBins = {}
	r.bspFallback = nil
	r.bspDensityBase = nil
	r.bspTerrainFaces = {}
	r.bspTerrainCells = {}
	r.bspFallbackUnknown = {}
	r.bspDensityChoice = {}
	r.bspDensityNodeSigns = {}
	r.bspOccupancyRoots = {}
	r.bspOccupancy = {}
	r.bspCellClipRoots = {}
	r.bspLocalDistances = {}
	r.bspBrushNodes = {}
	r.bspTerrainColumns = columnSampling ~= false and { {}, {}, {} } or nil
	local high = r.origin + V.RegionSize(r)
	-- Displacements have a separate collision representation. Keep the ray
	-- reconstruction in volumes containing them rather than restoring their
	-- underlying flat Hammer brush as if it were the displaced surface.
	for index, face in ipairs(data.faces) do
		local faceLow, faceHigh = face.dispLow or face.low, face.dispHigh or face.high
		if V.BoundsOverlap(faceLow, faceHigh, r.origin, high) then
			local sheet = openTerrainFace(data, face)
			local terrain = face.displacement or sheet
			local fallback = terrain or bit.band(face.tex.flags, 6) ~= 0
			if not fallback then
				r.bspFaces[#r.bspFaces + 1] = face
			end
			if (face.displacement and face.dispGrid and face.dispWidth) or sheet then
				r.bspFallback = r.bspFallback or {}
				if sheet then
					-- A private view shares the original face as provenance;
					-- do not mutate immutable BSP geometry with scan metadata.
					local view = {}
					for k, v in pairs(face) do
						view[k] = v
					end
					view.dispGrid = face.vertices
					view.source = face
					indexDisplacement(r, view, checkpoint)
				else
					indexDisplacement(r, face, checkpoint)
				end
			else
				local lo, hi = (faceLow - r.origin) / r.step, (faceHigh - r.origin) / r.step
				for _, axis in ipairs(names) do
					lo[axis] = math.max(0, math.min(31, math.floor(lo[axis] + 0.0000001) - (fallback and 2 or 0)))
					hi[axis] = math.max(0, math.min(31, math.floor(hi[axis] + 0.0000001) + (fallback and 2 or 0)))
				end
				if face.displacement then
					-- A displacement is an open shell: keep density occupancy
					-- through its column, including the ground below its base.
					local axis = "z"
					for _, a in ipairs(names) do
						if math.abs(face.normal[a]) > math.abs(face.normal[axis]) then
							axis = a
						end
					end
					lo[axis] = 0
					hi[axis] = 31
				end
				for z = lo.z, hi.z do
					for y = lo.y, hi.y do
						for x = lo.x, hi.x do
							local key = V.Index(x, y, z, r)
							if fallback then
								r.bspFallback = r.bspFallback or {}
								r.bspFallback[key] = true
								r.bspFallbackUnknown[key] = true
							else
								r.bspFaceBins[key] = r.bspFaceBins[key] or {}
								r.bspFaceBins[key][#r.bspFaceBins[key] + 1] = face
							end
						end
					end
				end
			end
		end
		if checkpoint and index % 128 == 0 then
			checkpoint()
		end
	end
	for _, columns in ipairs(r.bspTerrainColumns or {}) do
		for key, events in pairs(columns) do
			table.sort(events, function(a, b)
				return a.t < b.t
			end)
			local out = {}
			for _, event in ipairs(events) do
				local last = out[#out]
				if
					not last
					or math.abs(last.t - event.t) > 0.00001
					or last.hit.HitNormal:Dot(event.hit.HitNormal) < 0.99999
				then
					out[#out + 1] = event
				end
			end
			columns[key] = out
			if checkpoint then
				checkpoint()
			end
		end
	end
	r.bspEdits = {}
	r.bspEditBins = {}
	r.bspCellEditBins = {}
	r.bspBrushes = {}
	r.bspBrushBins = {}
	r.bspBrushCells = {}
	for index, brush in ipairs(data.worldBrushes or {}) do
		if V.BoundsOverlap(brush.low, brush.high, r.origin - Vector(1, 1, 1), high + Vector(1, 1, 1)) then
			r.bspBrushes[#r.bspBrushes + 1] = brush
			local lo, hi = (brush.low - r.origin) / (r.step * 8), (brush.high - r.origin) / (r.step * 8)
			for z = math.max(0, math.floor(lo.z)), math.min(3, math.floor(hi.z)) do
				for y = math.max(0, math.floor(lo.y)), math.min(3, math.floor(hi.y)) do
					for x = math.max(0, math.floor(lo.x)), math.min(3, math.floor(hi.x)) do
						local k = V.ChunkKey(x, y, z)
						r.bspBrushBins[k] = r.bspBrushBins[k] or {}
						r.bspBrushBins[k][#r.bspBrushBins[k] + 1] = brush
					end
				end
			end
		end
		if checkpoint and index % 128 == 0 then
			checkpoint()
		end
	end
	return true
end

local function latticePoint(r, x, y, z)
	local point = Vector(x, y, z)
	point:Mul(r.step)
	point:Add(r.origin)
	return point
end

local EMPTY = {}
local EMPTY_BRUSH_CELL = { all = EMPTY, detail = EMPTY }
local function cellBrushes(r, x, y, z, detail)
	if not r.bspBrushCells then
		return EMPTY
	end
	local key = V.Index(x, y, z, r)
	local entry = r.bspBrushCells[key]
	if not entry then
		local bin = r.bspBrushBins[V.ChunkKey(math.floor(x / 8), math.floor(y / 8), math.floor(z / 8))]
		if bin then
			local low = latticePoint(r, x, y, z)
			local high = Vector(r.step, r.step, r.step)
			high:Add(low)
			for _, brush in ipairs(bin) do
				if V.BoundsOverlap(low, high, brush.low, brush.high) then
					entry = entry or { all = {}, detail = EMPTY }
					entry.all[#entry.all + 1] = brush
					-- Structural displacement support is already represented by
					-- the terrain field. Detail/window/grate volumes must survive
					-- even when thinner than the sampling lattice.
					if bit.band(brush.contents, 134217738) ~= 0 then
						if entry.detail == EMPTY then entry.detail = {} end
						entry.detail[#entry.detail + 1] = brush
					end
				end
			end
		end
		entry = entry or EMPTY_BRUSH_CELL
		r.bspBrushCells[key] = entry
	end
	return detail and entry.detail or entry.all
end

local function brushOccupancy(brushes, center, half, initial)
	local result = initial
	for _, brush in ipairs(brushes) do
		local intersects, contains = true, true
		for _, p in ipairs(brush.planes) do
			local n = p.normal
			local d = center:Dot(n) - p.distance
			local extent = (math.abs(n.x) + math.abs(n.y) + math.abs(n.z)) * half
			if d - extent >= -EPS then
				intersects = false
				break
			end
			if d + extent > EPS then
				contains = false
			end
		end
		if intersects then
			if contains then
				return 1
			end
			result = 3
		end
	end
	return result
end

function V.BSPCellHasDetail(r, x, y, z)
	return #cellBrushes(r, x, y, z, true) > 0
end

-- Partition only air pieces; overlapping brushes form a union, not stacked
-- duplicate hulls. This runs lazily for cells actually visited by a body.
local function unionBrushes(pieces, brushes, origin, checkpoint)
	for _, brush in ipairs(brushes) do
		local output = {}
		for _, piece in ipairs(pieces) do
			if piece.solid then
				output[#output + 1] = piece
			else
				local remaining = piece
				for _, plane in ipairs(brush.planes) do
					local n, d = plane.normal, plane.distance - plane.normal:Dot(origin)
					local outside
					remaining, outside = clipPair(remaining, n, -n, d)
					if outside then
						output[#output + 1] = outside
					end
					if not remaining then
						break
					end
				end
				if remaining then
				output[#output + 1] = { faces = remaining.faces, points = remaining.points, solid = true }
				end
			end
		end
		pieces = output
		if checkpoint then
			checkpoint()
		end
	end
	return pieces
end

-- Recover structural crossings only for ambiguous native scan columns. The
-- existing local face bins avoid a map-wide search or another engine ray.
function V.BSPColumnEvents(r, axis, point)
	local result, seen = {}, {}
	if not r.bspFaceBins then
		return result
	end
	local name, u, v = names[axis], names[axis % 3 + 1], names[(axis + 1) % 3 + 1]
	local q = (point - r.origin) / r.step
	local a, b = math.floor(q[u]), math.floor(q[v])
	for c = 0, V.RegionCells(r, name) - 1 do
		for j = math.max(0, b - 1), math.min(V.RegionCells(r, v) - 1, b + 1) do
			for i = math.max(0, a - 1), math.min(V.RegionCells(r, u) - 1, a + 1) do
				local index = axis == 1 and V.Index(c, i, j, r)
					or axis == 2 and V.Index(j, c, i, r)
					or V.Index(i, j, c, r)
				for _, face in ipairs(r.bspFaceBins[index] or {}) do
					if not seen[face] then
						seen[face] = true
						local n, vertices = face.normal, face.vertices
						if
							math.abs(n[name]) > 0.000001
							and #vertices >= 3
							and bit.band(face.tex.flags or 0, 654) == 0
						then
							local positive, negative = false, false
							for k, p in ipairs(vertices) do
								local next = vertices[k % #vertices + 1]
								local cross = (next[u] - p[u]) * (point[v] - p[v])
									- (next[v] - p[v]) * (point[u] - p[u])
								positive = positive or cross > 0.0001
								negative = negative or cross < -0.0001
							end
							if not (positive and negative) then
								local first = vertices[1]
								local t = first[name]
									+ (n[u] * (first[u] - point[u]) + n[v] * (first[v] - point[v])) / n[name]
								local p = Vector(point.x, point.y, point.z)
								p[name] = t
								result[#result + 1] = {
									t = t,
									point = p,
									kind = n[name] > 0 and "exit" or "enter",
									hit = { Hit = true, HitWorld = true, HitPos = p, HitNormal = n },
								}
							end
						end
					end
				end
			end
		end
	end
	return result
end

-- Local face provenance also identifies displacement materials: engine traces
-- return a displacement marker instead of its VMT name. No map-wide searches.
local faceLookup = setmetatable({}, { __mode = "k" })

local function faceLookupGeometry(r, face)
	local tex = face.tex or (face.source and face.source.tex)
	local material = tex and r.bsp and r.bsp.textures and r.bsp.textures[tex.texture]
	local vertices = face.vertices
	if #vertices < 3 or (tex and bit.band(tex.flags or 0, 134) ~= 0)
		or (material and material.name:sub(1, 6) == "tools/")
	then
		return false
	end
	local n = (vertices[2] - vertices[1]):Cross(vertices[3] - vertices[1]):GetNormalized()
	if n:Dot(face.normal) < 0 then
		n = -n
	end
	local anchor = vertices[1]
	local result = { face = face.source or face, nx = n.x, ny = n.y, nz = n.z, x = anchor.x, y = anchor.y, z = anchor.z }
	for i, p in ipairs(vertices) do
		local edge = n:Cross(vertices[i % #vertices + 1] - p)
		result[i] = { x = edge.x, y = edge.y, z = edge.z, px = p.x, py = p.y, pz = p.z }
	end
	return result
end

local function faceLookupCell(r, cache, x, y, z)
	local result, seen = {}, {}
	local function add(faces)
		if not faces then return end
		for _, face in ipairs(faces) do
			if not seen[face] then
				seen[face] = true
				local geometry = cache.faces[face]
				if geometry == nil then
					geometry = faceLookupGeometry(r, face)
					cache.faces[face] = geometry
				end
				if geometry then result[#result + 1] = geometry end
			end
		end
	end
	for iz = math.max(0, z - 1), math.min(31, z + 1) do
		for iy = math.max(0, y - 1), math.min(31, y + 1) do
			for ix = math.max(0, x - 1), math.min(31, x + 1) do
				local key = V.Index(ix, iy, iz, r)
				add(r.bspFaceBins[key])
				add(r.bspTerrainFaces and r.bspTerrainFaces[key])
			end
		end
	end
	return result
end

function V.BSPFaceAt(r, point, normal, maxDistance)
	if not r.bspFaceBins then
		return
	end
	local q = (point - r.origin) / r.step
	local x, y, z = math.floor(q.x), math.floor(q.y), math.floor(q.z)
	if x < -1 or x > 32 or y < -1 or y > 32 or z < -1 or z > 32 then return end
	local cache = faceLookup[r.bspFaceBins]
	if not cache then
		cache = { faces = {}, cells = {} }
		faceLookup[r.bspFaceBins] = cache
	end
	-- Use separate digits for the one-cell halo as well as the 32-cell grid.
	local key = (x + 1) + 34 * ((y + 1) + 34 * (z + 1))
	local candidates = cache.cells[key]
	if not candidates then
		candidates = faceLookupCell(r, cache, x, y, z)
		cache.cells[key] = candidates
	end
	local best, distance = nil, maxDistance or r.step * 2
	local px, py, pz = point.x, point.y, point.z
	local nx, ny, nz = normal.x, normal.y, normal.z
	for _, face in ipairs(candidates) do
		if face.nx * nx + face.ny * ny + face.nz * nz >= 0.5 then
			local d = math.abs(face.nx * (px - face.x) + face.ny * (py - face.y) + face.nz * (pz - face.z))
			if d <= distance then
				local positive, negative = false, false
				for _, edge in ipairs(face) do
					-- Orthogonal plane projection does not change a
					-- point's side relative to these edge planes.
					local side = edge.x * (px - edge.px) + edge.y * (py - edge.py) + edge.z * (pz - edge.pz)
					positive = positive or side > EPS
					negative = negative or side < -EPS
					if positive and negative then break end
				end
				if not (positive and negative) then
					best, distance = face.face, d
				end
			end
		end
	end
	return best
end

function V.BSPCellUsesDensity(r, x, y, z)
	if not r.bsp then
		return true
	end
	local key = V.Index(x, y, z, r)
	if not r.bspFallback or not r.bspFallback[key] then
		return false
	end
	if not r.bspDensityChoice or r.bspFallbackUnknown[key] then
		return true
	end
	if r.bspDensityChoice[key] ~= nil then
		return r.bspDensityChoice[key]
	end
	local terrain = r.bspTerrainCells and r.bspTerrainCells[key]
	if terrain and terrain.curved then
		-- A curved shell requires the sampled path regardless of its
		-- lattice signs or any neighbouring flat displacement patches.
		r.bspDensityChoice[key] = true
		return true
	end
	local values = r.bspDensityBase and r.bspDensityBase.values or r.values
	local signs = r.bspDensityNodeSigns
	local density = false
	for _, o in ipairs(V.CellOffsets) do
		local px, py, pz = x + o[1], y + o[2], z + o[3]
		local index = V.Index(px, py, pz, r)
		local value = values[index]
		if math.abs(value) > 1 / 32 then
			local solid = signs and signs[index]
			if solid == nil then
				local p = r.origin + Vector(px, py, pz) * r.step
				solid = V.BSPSolid(r.bsp, p)
				if signs then
					signs[index] = solid
				end
			end
			if (value < 0) ~= solid then
				density = true
				break
			end
		end
	end
	-- Keep curved/uncertain terrain on the sampled path. A flat patch can
	-- use the exact BSP only if its clipped surface really bounds BSP solid.
	if not density and terrain then
		local low = r.origin + Vector(x, y, z) * r.step
		local high = low + Vector(1, 1, 1) * r.step
		for _, tri in ipairs(terrain) do
			if not tri.flat then
				density = true
				break
			end
			local polygon = tri.vertices
			for i, axis in ipairs(names) do
				polygon = V.ClipBSPPolygon(polygon, boxNormals[i], high[axis])
				polygon = V.ClipBSPPolygon(polygon, oppositeBoxNormals[i], -low[axis])
			end
			if #polygon >= 3 then
				local area = Vector()
				for i = 2, #polygon - 1 do
					area = area + (polygon[i] - polygon[1]):Cross(polygon[i + 1] - polygon[1])
				end
				if area:LengthSqr() > EPS * EPS then
					local center = Vector()
					for _, p in ipairs(polygon) do
						center = center + p / #polygon
					end
					for _, point in ipairs(polygon) do
						local p = point * 0.999 + center * 0.001
						if
							not V.BSPSolid(r.bsp, p - tri.normal * 0.03125)
							or V.BSPSolid(r.bsp, p + tri.normal * 0.03125)
						then
							density = true
							break
						end
					end
				end
			end
			if density then
				break
			end
		end
	end
	r.bspDensityChoice[key] = density
	return density
end

local function leafOccupancy(data, index, depth, center, half, checkpoint)
	assert(depth < 1024, "arbre BSP trop profond")
	if checkpoint and depth % 8 == 0 then
		checkpoint()
	end
	if index < 0 then
		return data.leaves[-index].solid and 1 or 2, index, depth
	end
	local node = data.nodes[index + 1]
	local p = data.planes[node.plane]
	local n = p.normal
	local d = center:Dot(n) - p.distance
	local extent = (math.abs(n.x) + math.abs(n.y) + math.abs(n.z)) * half
	if d - extent >= -EPS then
		local result, root, rootDepth = leafOccupancy(data, node.front, depth + 1, center, half, checkpoint)
		if d - extent > 1 / 64 then return result, root, rootDepth end
		return result, index, depth
	end
	if d + extent <= EPS then
		local result, root, rootDepth = leafOccupancy(data, node.back, depth + 1, center, half, checkpoint)
		if -d - extent > 1 / 64 then return result, root, rootDepth end
		return result, index, depth
	end
	local front = leafOccupancy(data, node.front, depth + 1, center, half, checkpoint)
	if front == 3 then
		return 3, index, depth
	end
	local back = leafOccupancy(data, node.back, depth + 1, center, half, checkpoint)
	return front == back and front or 3, index, depth
end

local function occupancyRoot(r, x, y, z, half, checkpoint)
	local roots = r.bspOccupancyRoots
	if not roots then
		return r.bsp.head, 0, r.bsp.head, 0
	end
	local cx, cy, cz = math.floor(x / 8), math.floor(y / 8), math.floor(z / 8)
	local key = V.ChunkKey(cx, cy, cz)
	local cached = roots[key]
	if cached then
		return cached.index, cached.depth, cached.clipIndex or r.bsp.head, cached.clipDepth or 0
	end
	local x0, y0, z0 = cx * 8, cy * 8, cz * 8
	local low = latticePoint(r, x0 + 0.5, y0 + 0.5, z0 + 0.5)
	local high = latticePoint(
		r,
		math.min(x0 + 8, V.RegionCells(r, "x")) - 0.5,
		math.min(y0 + 8, V.RegionCells(r, "y")) - 0.5,
		math.min(z0 + 8, V.RegionCells(r, "z")) - 0.5
	)
	local extreme = Vector()
	local data = r.bsp
	local index, depth = data.head, 0
	local clipIndex, clipDepth = index, 0
	while index >= 0 do
		assert(depth < 1024, "arbre BSP trop profond")
		if checkpoint and depth % 8 == 0 then
			checkpoint()
		end
		local node = data.nodes[index + 1]
		local plane = data.planes[node.plane]
		local n = plane.normal
		local nx, ny, nz = n.x, n.y, n.z
		local extent = (math.abs(nx) + math.abs(ny) + math.abs(nz)) * half
		-- Use the extreme cell centres and the same float dot product as
		-- leafOccupancy. Every centre lies between these projections.
		extreme.x = nx >= 0 and low.x or high.x
		extreme.y = ny >= 0 and low.y or high.y
		extreme.z = nz >= 0 and low.z or high.z
		local separation = extreme:Dot(n) - plane.distance - extent
		if separation >= -EPS then
			index = node.front
		else
			extreme.x = nx >= 0 and high.x or low.x
			extreme.y = ny >= 0 and high.y or low.y
			extreme.z = nz >= 0 and high.z or low.z
			local d = extreme:Dot(n) - plane.distance
			if d + extent > EPS or d - extent >= -EPS then
				break
			end
			index = node.back
			separation = -d - extent
		end
		-- Clip coordinates are local floats. Only skip a node when the
		-- entire chunk is safely away from its plane in either representation.
		if clipDepth == depth and separation > 1 / 64 then
			clipIndex, clipDepth = index, depth + 1
		end
		depth = depth + 1
	end
	roots[key] = { index = index, depth = depth, clipIndex = clipIndex, clipDepth = clipDepth }
	return index, depth, clipIndex, clipDepth
end

-- Classify a whole unedited cell without constructing clipped leaf boxes.
-- Most cells are entirely air/solid; only mixed leaves need polyhedra/SAT.
function V.BSPCellOccupancy(r, x, y, z, checkpoint)
	local cache = r.bspOccupancyRoots and r.bspOccupancy
	local key = cache and V.Index(x, y, z, r)
	local cached = key and cache[key]
	if cached then return cached end
	local half = r.step * 0.5
	local index, depth, clipIndex, clipDepth = occupancyRoot(r, x, y, z, half, checkpoint)
	local center = index >= 0 and latticePoint(r, x + 0.5, y + 0.5, z + 0.5)
	local result, cellRoot, cellDepth = leafOccupancy(r.bsp, index, depth, center, half, checkpoint)
	if result ~= 1 then
		local brushes = cellBrushes(r, x, y, z)
		if #brushes > 0 then
			center = center or latticePoint(r, x + 0.5, y + 0.5, z + 0.5)
			result = brushOccupancy(brushes, center, half, result)
		end
	end
	if cache then
		cache[key] = result
		if result == 3 and index == clipIndex and depth == clipDepth then
			r.bspCellClipRoots[key] = { index = cellRoot, depth = cellDepth }
		end
	end
	return result
end

local function clipRoot(r, x, y, z, key, checkpoint)
	local cell = r.bspCellClipRoots and r.bspCellClipRoots[key]
	if cell then return cell.index, cell.depth end
	local _, _, index, depth = occupancyRoot(r, x, y, z, r.step / 2, checkpoint)
	return index, depth
end

function V.BSPCellMayHaveSurface(r, x, y, z, index)
	index = index or V.Index(x, y, z, r)
	local edits = r.bspCellEditBins
	if edits and edits[index] then
		return true
	end
	if not edits and r.bspEditBins and r.bspEditBins[V.ChunkKey(math.floor(x / 8), math.floor(y / 8), math.floor(z / 8))] then
		return true
	end
	if not V.BSPCellUsesDensity(r, x, y, z) then
		return r.bspFaceBins[index] ~= nil or r.bspTerrainFaces and r.bspTerrainFaces[index] ~= nil
	end
	if r.bspFaceBins[index] and #cellBrushes(r, x, y, z, true) > 0 then
		return true
	end
	local values = r.bspDensityBase and r.bspDensityBase.values or r.values
	local inside = values[index] < 0
	for _, offset in ipairs(V.CellOffsets) do
		if (values[V.Index(x + offset[1], y + offset[2], z + offset[3], r)] < 0) ~= inside then
			return true
		end
	end
	return false
end

function V.BSPDensityBase(r)
	if not r.bspDensityBase then
		r.bspDensityBase = {
			origin = r.origin,
			side = r.side,
			extent = r.extent,
			cells = r.cells,
			step = r.step,
			nx = r.nx,
			ny = r.ny,
			nz = r.nz,
			values = r.values,
			revision = 0,
			analysis = true,
			featurePlanes = r.featurePlanes,
			seamSource = r,
		}
	end
	return r.bspDensityBase
end

-- Match sampled relief to the original displacement in a one-cell border.
-- Never move frozen lattice coordinates or reach for another floor outside
-- this local cell neighbourhood. Native architectural brushes stay exact.
function V.RefineBoundaryPoint(r, p)
	if not r.bspTerrainCells then
		return p
	end
	local edge = math.min(
		p.x,
		p.y,
		p.z,
		V.RegionAxisSize(r, "x") - p.x,
		V.RegionAxisSize(r, "y") - p.y,
		V.RegionAxisSize(r, "z") - p.z
	)
	if edge >= r.step - 0.00001 then
		return p
	end
	local q = p / r.step
	local free = {}
	for _, a in ipairs(names) do
		free[a] = math.abs(q[a] - math.floor(q[a] + 0.5)) > 0.000001
	end
	local world = p + r.origin
	local best, distance, seen = nil, r.step * 0.6, {}
	for z = math.max(0, math.floor(q.z) - 1), math.min(V.RegionCells(r, "z") - 1, math.floor(q.z) + 1) do
		for y = math.max(0, math.floor(q.y) - 1), math.min(V.RegionCells(r, "y") - 1, math.floor(q.y) + 1) do
			for x = math.max(0, math.floor(q.x) - 1), math.min(V.RegionCells(r, "x") - 1, math.floor(q.x) + 1) do
				for _, face in ipairs(r.bspTerrainCells[V.Index(x, y, z, r)] or {}) do
					if not seen[face] then
						seen[face] = true
						local a, b, c = unpack(face.vertices)
						local n = (b - a):Cross(c - a):GetNormalized()
						local error = (a - world):Dot(n)
						local movable = Vector(free.x and n.x or 0, free.y and n.y or 0, free.z and n.z or 0)
						local denom = movable:LengthSqr()
						if math.abs(error) < distance and denom > 0.000001 then
							local delta = movable * (error / denom)
							local target = world + delta
							local inside = delta:LengthSqr() < r.step * r.step * 0.36
							for i, v in ipairs(face.vertices) do
								local nextVertex = face.vertices[i % 3 + 1]
								if (nextVertex - v):Cross(target - v):Dot(n) < -0.0001 then
									inside = false
									break
								end
							end
							for _, axis in ipairs(names) do
								if free[axis] then
									local low = math.floor(q[axis]) * r.step + r.origin[axis]
									if target[axis] < low or target[axis] > low + r.step then
										inside = false
									end
								end
							end
							if inside then
								best = delta
								distance = math.abs(error)
							end
						end
					end
				end
			end
		end
	end
	if not best then
		return p
	end
	local t = math.max(0, math.min(1, edge / r.step))
	return p + best * ((1 - t) * (1 - t) * (1 + 2 * t))
end

function V.FreezeBSPDensityBase(r)
	if not r.bspFallback then
		return
	end
	local base = V.BSPDensityBase(r)
	if base.values == r.values then
		local values = {}
		for i, value in ipairs(r.values) do
			values[i] = value
		end
		base.values = values
	end
end

local function densityField(r, solid)
	local base = V.BSPDensityBase(r)
	if solid then
		return base
	end
	if not base.air then
		local air = {}
		for k, v in pairs(base) do
			if k ~= "terrainCache" then
				air[k] = v
			end
		end
		-- These cells only read the original field by index. Reversing
		-- individual samples avoids copying a whole zone for the first fill.
		air.values = setmetatable({}, {
			__index = function(_, index)
				local value = base.values[index]
				return value and -value
			end,
		})
		base.air = air
	end
	return base.air
end

local function clipBox(polygon, low, high)
	for i, axis in ipairs(names) do
		polygon = V.ClipBSPPolygon(polygon, boxNormals[i], high[axis])
		polygon = V.ClipBSPPolygon(polygon, oppositeBoxNormals[i], -low[axis])
		if #polygon < 3 then
			break
		end
	end
	return polygon
end

local function cellLeaves(r, x, y, z, needAir, checkpoint)
	local cache, key = V.TerrainCellCache(r, "bspLeaves", x, y, z)
	local density = V.BSPCellUsesDensity(r, x, y, z)
	local brushes = cellBrushes(r, x, y, z, density)
	needAir = needAir or #brushes > 0
	local existing = cache[key]
	if existing and (not needAir or existing.hasAir) then
		return existing
	end
	do
		local low = Vector(x, y, z) * r.step
		local pieces = {}
		if density then
			-- Use the original density tetrahedra as the base solid, then the
			-- SAME brush halfspaces as neighboring exact BSP cells. Mixing
			-- max-at-nodes carving with exact CSG would open seams at joins.
			for _, piece in ipairs(existing or {}) do
				pieces[#pieces + 1] = piece
			end
			local parts = {}
			if not existing then
				parts[#parts + 1] = { field = densityField(r, true), solid = true }
			end
			if needAir then
				parts[#parts + 1] = { field = densityField(r, false), solid = false }
			end
			local cellBox
			for _, part in ipairs(parts) do
				for _, hull in ipairs(V.DensityCellPlanes(part.field, x, y, z)) do
					cellBox = cellBox or box(low, low + Vector(1, 1, 1) * r.step)
					local piece = cellBox
					for _, plane in ipairs(hull) do
						if piece then
							piece = clip(piece, plane.n, plane.high, nil, plane)
						end
					end
					if piece then
						pieces[#pieces + 1] = { faces = piece.faces, points = piece.points, solid = part.solid }
					end
				end
			end
		else
			local index, depth = clipRoot(r, x, y, z, key, checkpoint)
			splitWorld(r, box(low, low + Vector(1, 1, 1) * r.step), index, pieces, depth, checkpoint, needAir)
		end
		pieces = unionBrushes(pieces, brushes, r.origin, checkpoint)
		pieces.hasAir = needAir
		cache[key] = pieces
	end
	return cache[key]
end
local function tetPlanes(points)
	local planes = {}
	for _, ids in ipairs({ { 1, 2, 3, 4 }, { 1, 2, 4, 3 }, { 1, 3, 4, 2 }, { 2, 3, 4, 1 } }) do
		local a, b, c, other = points[ids[1]], points[ids[2]], points[ids[3]], points[ids[4]]
		local n = (b - a):Cross(c - a):GetNormalized()
		if n:Dot(other - a) > 0 then
			n = -n
		end
		planes[#planes + 1] = { normal = n, distance = n:Dot(a) }
	end
	return planes
end
local function brushNodeSample(r, op, p, key)
	-- Adjacent cells use the same quantized lattice samples. Compute each
	-- brush/node pair once, for ordinary tools as well as procedural blasts.
	local cached = op.nodeSamples
	if not cached then
		cached = {}
		op.nodeSamples = cached
	end
	local value = cached[key]
	if value == nil then
		value = op.plane and (op.plane.sign*p[names[op.plane.axis]]-op.plane.distance)
			or V.BrushSample(p, op.center, op.radius, op.seed, op.floorZ)
		for _, axis in ipairs(names) do
			if p[axis] < EPS or p[axis] > V.RegionAxisSize(r, axis) - EPS then
				value = math.max(r.step, value)
				break
			end
		end
		value = math.floor(value * 64 + 0.5) / 64
		cached[key] = value
	end
	return value
end
local function brushSamples(r, op, points, key)
	local values, cached = {}, op.nodeSamples
	local row, layer = r.nx + 1, (r.nx + 1) * (r.ny + 1)
	for i, offset in ipairs(V.CellOffsets) do
		local index = key + offset[1] + offset[2] * row + offset[3] * layer
		values[i] = cached and cached[index] or brushNodeSample(r, op, points[i], index)
	end
	return values
end
local templates = {}
local function tetTemplates(step)
	if templates[step] then
		return templates[step]
	end
	local list = {}
	for i, indices in ipairs(V.CellTetrahedra) do
		local p = {}
		for j, index in ipairs(indices) do
			local o = V.CellOffsets[index]
			p[j] = Vector(o[1], o[2], o[3]) * step
		end
		local a, b, c = p[2] - p[1], p[3] - p[1], p[4] - p[1]
		local det = a:Dot(b:Cross(c))
		local planes = tetPlanes(p)
		for _, plane in ipairs(planes) do
			local n = plane.normal
			-- Interior lattice planes are x=y, x=z or y=z, with either sign.
			if n.x ~= 0 and n.y == -n.x and n.z == 0 then
				plane.diagonal, plane.factor = 1, n.x
			elseif n.x ~= 0 and n.z == -n.x and n.y == 0 then
				plane.diagonal, plane.factor = 2, n.x
			elseif n.y ~= 0 and n.z == -n.y and n.x == 0 then
				plane.diagonal, plane.factor = 3, n.y
			end
		end
		list[i] = { planes = planes, a = b:Cross(c) / det, b = c:Cross(a) / det, c = a:Cross(b) / det }
	end
	templates[step] = list
	return list
end
local constantBrushNormal = Vector()
local brushGradient, brushTerm = Vector(), Vector()
local function operationPlane(op, points, values, indices, template)
	local v1, v2, v3, v4 = values[indices[1]], values[indices[2]], values[indices[3]], values[indices[4]]
	-- A linear function with four strictly positive/negative vertices cannot
	-- cross this tetrahedron. Constant classifiers avoid gradient allocation
	-- and polygon clipping in all of those interior/exterior tetrahedra.
	if math.min(v1, v2, v3, v4) > 0 then
		return { normal = constantBrushNormal, opposite = constantBrushNormal, distance = -1, adding = op.adding, brush = op, misses = true }
	end
	if math.max(v1, v2, v3, v4) < 0 then
		return { normal = constantBrushNormal, opposite = constantBrushNormal, distance = 1, adding = op.adding, brush = op }
	end
	-- Keep the same float operations as the vector expression. The two
	-- temporary vectors are never published and this calculation cannot yield.
	brushGradient:Set(template.a)
	brushGradient:Mul(v2 - v1)
	brushTerm:Set(template.b)
	brushTerm:Mul(v3 - v1)
	brushGradient:Add(brushTerm)
	brushTerm:Set(template.c)
	brushTerm:Mul(v4 - v1)
	brushGradient:Add(brushTerm)
	if brushGradient:LengthSqr() < 1e-16 then
		return { normal = constantBrushNormal, opposite = constantBrushNormal, distance = -v1, adding = op.adding, brush = op, misses = v1 > EPS }
	end
	local length = brushGradient:Length()
	local n = brushGradient / length
	return { normal = n, opposite = -n, distance = n:Dot(points[1]) - v1 / length, adding = op.adding, brush = op }
end
local triangleEdgeA, triangleEdgeB = Vector(), Vector()
local function triangles(polygon, normal, emit)
	if #polygon < 3 then
		return
	end
	for i = 2, #polygon - 1 do
		local a, b, c = polygon[1], polygon[i], polygon[i + 1]
		triangleEdgeA:Set(b)
		triangleEdgeA:Sub(a)
		triangleEdgeB:Set(c)
		triangleEdgeB:Sub(a)
		local cross = triangleEdgeA:Cross(triangleEdgeB)
		if cross:LengthSqr() > 0.000001 then
			emit(a, b, c, normal, cross)
		end
	end
end

-- A tet turns each brush into a halfspace. Latest-first evaluation keeps
-- only the remaining convex outside; final air never needs storing/splitting.
function V.ApplyBSPBrushPlanes(pieces, operations, checkpoint)
	local solids = {}
	local only = operations[1]
	if #operations == 1 and not only.adding then
		local opposite = not only.misses and (only.opposite or -only.normal)
		for _, piece in ipairs(pieces) do
			if piece.solid then
				local kept = only.misses and piece or clip(piece, opposite, -only.distance, "cut")
				if kept then solids[#solids + 1] = kept end
			end
			if checkpoint then checkpoint() end
		end
		return solids
	end
	local firstAdd, firstRemove = math.huge, math.huge
	for i, op in ipairs(operations) do
		if not op.misses then
			if op.adding then
				firstAdd = math.min(firstAdd, i)
			else
				firstRemove = math.min(firstRemove, i)
			end
			if firstAdd < math.huge and firstRemove < math.huge then break end
		end
	end
	local opposites = {}
	for _, piece in ipairs(pieces) do
		local remaining = piece
		for i = #operations, 1, -1 do
			if (piece.solid and i < firstRemove) or (not piece.solid and i < firstAdd) then
				break
			end
			local op = operations[i]
			if not op.misses then
				opposites[i] = opposites[i] or op.opposite or -op.normal
				if op.adding then
					local inside
					inside, remaining = clipPair(remaining, op.normal, opposites[i], op.distance, "cut")
					if inside then
						solids[#solids + 1] = { faces = inside.faces, points = inside.points, solid = true }
					end
				else
					remaining = clip(remaining, opposites[i], -op.distance, "cut")
				end
				if not remaining then
					break
				end
			end
			if checkpoint and i % 8 == 0 then
				checkpoint()
			end
		end
		if remaining and piece.solid then
			solids[#solids + 1] = remaining
		end
		if checkpoint then
			checkpoint()
		end
	end
	return solids
end

local tetEdges = { { 1, 2 }, { 1, 3 }, { 1, 4 }, { 2, 3 }, { 2, 4 }, { 3, 4 } }
local function planeSlice(points, n, d)
	if n:LengthSqr() < 0.5 then
		return {}
	end
	local polygon = {}
	local function add(p)
		for _, q in ipairs(polygon) do
			if p:DistToSqr(q) < 1e-14 then
				return
			end
		end
		polygon[#polygon + 1] = p
	end
	local distances = {}
	for i, p in ipairs(points) do
		distances[i] = p:Dot(n) - d
	end
	for _, edge in ipairs(tetEdges) do
		local a, b = points[edge[1]], points[edge[2]]
		local da, db = distances[edge[1]], distances[edge[2]]
		if math.abs(da) <= EPS then
			add(a)
		end
		if math.abs(db) <= EPS then
			add(b)
		end
		if da * db < 0 then
			local intersection = b - a
			intersection:Mul(da / (da - db))
			intersection:Add(a)
			add(intersection)
		end
	end
	if #polygon < 3 then
		return {}
	end
	orderPolygon(polygon, n)
	return polygon
end

-- Only a coplanar classifier needs a side probe. Ordinary intersections stay
-- on the exact shared plane, avoiding epsilon-width cracks between cells.
local function outsideSide(poly, n, d, probe)
	for _, p in ipairs(poly) do
		if math.abs(p:Dot(n) - d) > EPS then
			return false
		end
	end
	return n:Dot(probe) > EPS
end
local function clipBrushSurface(polygon, brushes, origin, wantSolid, probe, emit, checkpoint)
	if #polygon < 3 then
		return
	end
	if #brushes == 0 then
		if not wantSolid then
			emit(polygon)
		end
		return
	end
	local low, high = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for _, p in ipairs(polygon) do
		for _, axis in ipairs(names) do
			local value = p[axis] + origin[axis]
			low[axis] = math.min(low[axis], value)
			high[axis] = math.max(high[axis], value)
		end
	end
	-- Local/world conversion can move a coplanar face by a few ULPs. Match
	-- the clipping tolerance so the broad phase never rejects its own plane.
	for _, axis in ipairs(names) do
		low[axis] = low[axis] - EPS
		high[axis] = high[axis] + EPS
	end
	local air = { polygon }
	for i, brush in ipairs(brushes) do
		if checkpoint and i % 16 == 0 then checkpoint() end
		if V.BoundsOverlap(low, high, brush.low, brush.high) then
			local remainingAir = {}
			for _, poly in ipairs(air) do
				local inside = poly
				for _, plane in ipairs(brush.planes) do
					local n, d = plane.normal, plane.distance - plane.normal:Dot(origin)
					local lo, hi = math.huge, -math.huge
					for _, p in ipairs(inside) do
						local q = p:Dot(n) - d
						lo = math.min(lo, q)
						hi = math.max(hi, q)
					end
					if lo >= -EPS and hi <= EPS then
						if n:Dot(probe) > EPS then
							remainingAir[#remainingAir + 1] = inside
							inside = {}
							break
						end
					elseif lo >= -EPS then
						remainingAir[#remainingAir + 1] = inside
						inside = {}
						break
					elseif hi > EPS then
						local outside = V.ClipBSPPolygon(inside, -n, -d)
						if #outside >= 3 then
							remainingAir[#remainingAir + 1] = outside
						end
						inside = V.ClipBSPPolygon(inside, n, d)
					end
					if #inside < 3 then
						break
					end
				end
				if wantSolid and #inside >= 3 then
					emit(inside)
				end
			end
			air = remainingAir
			if #air == 0 then
				break
			end
		end
	end
	if not wantSolid then
		for _, poly in ipairs(air) do
			emit(poly)
		end
	end
end

function V.ClipBSPDetailOpening(r, polygon, normal, x, y, z, emit, checkpoint)
	clipBrushSurface(polygon, cellBrushes(r, x, y, z, true), Vector(), false, normal, emit, checkpoint)
end

local function clipDensitySurface(r, x, y, z, polygon, wantSolid, probe, emit)
	for _, shape in ipairs(V.DensityCellPlanes(densityField(r, wantSolid), x, y, z)) do
		local part = polygon
		for _, plane in ipairs(shape) do
			local opposite = plane.opposite or -plane.n
			if outsideSide(part, plane.n, plane.high, probe) or outsideSide(part, opposite, -plane.low, probe) then
				part = {}
				break
			end
			part = V.ClipBSPPolygon(part, plane.n, plane.high)
			if #part < 3 then
				break
			end
			part = V.ClipBSPPolygon(part, opposite, -plane.low)
			if #part < 3 then
				break
			end
		end
		if #part >= 3 then
			emit(part)
		end
	end
end
local function baseOccupancy(r, x, y, z, checkpoint)
	if not V.BSPCellUsesDensity(r, x, y, z) then
		return V.BSPCellOccupancy(r, x, y, z, checkpoint)
	end
	local base = V.BSPDensityBase(r)
	local solid, air = false, false
	for _, o in ipairs(V.CellOffsets) do
		local d = V.Sample(base, x + o[1], y + o[2], z + o[3])
		if d < 0 then
			solid = true
		elseif d > 0 then
			air = true
		end
	end
	local result = not solid and 2 or not air and 1 or 3
	if result == 1 then
		return result
	end
	return brushOccupancy(
		cellBrushes(r, x, y, z, true),
		latticePoint(r, x + 0.5, y + 0.5, z + 0.5),
		r.step / 2,
		result
	)
end

local function clipBaseSurface(r, x, y, z, polygon, wantSolid, probe, emit, occupancy, clipIndex)
	if #polygon < 3 then
		return
	end
	if occupancy and occupancy ~= 3 then
		if (occupancy == 1) == wantSolid then
			emit(polygon)
		end
		return
	end
	if V.BSPCellUsesDensity(r, x, y, z) then
		local brushes = cellBrushes(r, x, y, z, true)
		if wantSolid then
			clipDensitySurface(r, x, y, z, polygon, true, probe, emit)
		end
		-- Displacement air can contribute a solid only through a detail brush.
		if #brushes > 0 then
			clipDensitySurface(r, x, y, z, polygon, false, probe, function(part)
				clipBrushSurface(part, brushes, r.origin, wantSolid, probe, emit)
			end)
		elseif not wantSolid then
			clipDensitySurface(r, x, y, z, polygon, false, probe, emit)
		end
		return
	end
	local function walk(poly, index)
		if #poly < 3 then
			return
		end
		if index < 0 then
			if r.bsp.leaves[-index].solid then
				if wantSolid then
					emit(poly)
				end
			else
				clipBrushSurface(poly, cellBrushes(r, x, y, z), r.origin, wantSolid, probe, emit)
			end
			return
		end
		local node = r.bsp.nodes[index + 1]
		local plane = r.bsp.planes[node.plane]
		local n = plane.normal
		local d = localPlaneDistance(r, plane)
		local lo, hi = math.huge, -math.huge
		for _, p in ipairs(poly) do
			local q = p:Dot(n) - d
			lo = math.min(lo, q)
			hi = math.max(hi, q)
		end
		if lo >= -EPS and hi <= EPS then
			walk(poly, n:Dot(probe) >= 0 and node.front or node.back)
		elseif lo >= -EPS then
			walk(poly, node.front)
		elseif hi <= EPS then
			walk(poly, node.back)
		else
			walk(V.ClipBSPPolygon(poly, -n, -d), node.front)
			walk(V.ClipBSPPolygon(poly, n, d), node.back)
		end
	end
	walk(polygon, clipIndex or r.bsp.head)
end

local function cutSurfaces(r, x, y, z, points, operations, emit, checkpoint, first, occupancy, clipIndex)
	for i = first or 1, #operations do
		local op = operations[i]
		local polygon = planeSlice(points, op.normal, op.distance)
		for j = i + 1, #operations do
			local later = operations[j]
			if #polygon < 3 then
				break
			end
			-- The most recent operation owns coincident brush boundaries.
			local aligned = op.normal:Dot(later.normal)
			if aligned > 0.99999999 and math.abs(op.distance - later.distance) < EPS then
				polygon = {}
				break
			end
			polygon = V.ClipBSPPolygon(polygon, later.opposite, -later.distance)
		end
		if #polygon >= 3 then
			local n = op.adding and op.normal or -op.normal
			local function surface(poly)
				triangles(poly, n, function(a, b, c, normal, cross)
					emit(a, b, c, normal, true, op.brush, nil, cross)
				end)
			end
			-- Earlier brushes are classified latest-first on this 2D slice.
			-- Never construct or split any 3D collision solid for a visual mesh.
			for j = i - 1, 1, -1 do
				if #polygon < 3 then
					break
				end
				local earlier = operations[j]
				local inside = outsideSide(polygon, earlier.normal, earlier.distance, op.normal) and {}
					or V.ClipBSPPolygon(polygon, earlier.normal, earlier.distance)
				if earlier.adding ~= op.adding then
					surface(inside)
				end
				polygon = outsideSide(polygon, earlier.opposite, -earlier.distance, op.normal) and {}
					or V.ClipBSPPolygon(polygon, earlier.opposite, -earlier.distance)
			end
			clipBaseSurface(r, x, y, z, polygon, not op.adding, op.normal, surface, occupancy, clipIndex)
		end
		if checkpoint then
			checkpoint()
		end
	end
end

local function fillWholeBrushCell(r, low, high, last, result, key)
	if
		not last
		or low.x <= EPS
		or low.y <= EPS
		or low.z <= EPS
		or high.x >= V.RegionAxisSize(r, "x") - EPS
		or high.y >= V.RegionAxisSize(r, "y") - EPS
		or high.z >= V.RegionAxisSize(r, "z") - EPS
	then
		return false
	end
	-- Strict quantized samples prove containment in the linear field. Older
	-- journals without this index retain the conservative spherical-core test.

	if not (last.fullCells and last.fullCells[key]) then
		if last.plane then return false end
		if last.floorZ ~= nil and low.z <= last.floorZ + 1 / 64 then
			return false
		end
		local dx = math.max(math.abs(low.x - last.center.x), math.abs(high.x - last.center.x))
		local dy = math.max(math.abs(low.y - last.center.y), math.abs(high.y - last.center.y))
		local dz = math.max(math.abs(low.z - last.center.z), math.abs(high.z - last.center.z))
		local inner = V.BrushInnerRadius(last.radius, last.seed)
		if inner <= 1 / 64 or dx * dx + dy * dy + dz * dz >= (inner - 1 / 64) ^ 2 then
			return false
		end
	end
	result.solids = {}
	if last.adding then
		local piece = box(low, high)
		piece.solid = true
		result.solids[1] = piece
	end
	return true
end

-- Build all geometry once; physics and visual consumers share the result.
function V.BSPCell(r, x, y, z, checkpoint)
	if not V.ActiveRegionCell(r, x, y, z) then
		return { triangles = {}, solids = {} }
	end
	local cache, key = V.TerrainCellCache(r, "bspCells", x, y, z)
	if cache[key] then
		return cache[key]
	end
	local result = { triangles = {}, operationIndex = #r.bspEdits }
	local indexed = r.bspCellEditBins and r.bspCellEditBins[key]
	local low, high
	local lastIndexed = indexed and indexed[#indexed]
	if lastIndexed then
		low = Vector(x, y, z) * r.step
		high = low + Vector(1, 1, 1) * r.step
		-- A final interior has no original face left to recover.
		-- Decide before displacement triangulation/BSP occupancy work.
		if fillWholeBrushCell(r, low, high, lastIndexed, result, key) then
			cache[key] = result
			return result
		end
	end
	if indexed and not r.bspFaceBins[key] and not (r.bspTerrainFaces and r.bspTerrainFaces[key]) then
		local removalOnly = true
		for _, op in ipairs(indexed) do
			if op.adding then
				removalOnly = false
				break
			end
		end
		if removalOnly then
			result.baseOccupancy = baseOccupancy(r, x, y, z, checkpoint)
			if result.baseOccupancy == 2 then
				-- Removing air cannot create either a surface or a solid.
				-- Avoid six CSG tetrahedra, slices and clips in this cell.
				result.solids = {}
				cache[key] = result
				return result
			end
		end
	end
	local function emit(a, b, c, n, curved, brush, source, cross)
		result.triangles[#result.triangles + 1] = { a, b, c, n, curved, brush, source, cross }
	end
	low = low or Vector(x, y, z) * r.step
	high = high or low + Vector(1, 1, 1) * r.step
	local faces = r.bspFaceBins[key] or {}
	local density = V.BSPCellUsesDensity(r, x, y, z)
	if not density and r.bspTerrainFaces and r.bspTerrainFaces[key] then
		local combined = {}
		for _, face in ipairs(faces) do
			combined[#combined + 1] = face
		end
		for _, tri in ipairs(r.bspTerrainFaces[key]) do
			local polygon = {}
			for _, p in ipairs(tri.vertices) do
				local q = p - r.origin
				-- Use the owning cell's exact boundary, rather than clipping
				-- away a coplanar face due to float subtraction roundoff.
				for _, axis in ipairs(names) do
					if math.abs(q[axis] - low[axis]) <= 1 / 64 then
						q[axis] = low[axis]
					elseif math.abs(q[axis] - high[axis]) <= 1 / 64 then
						q[axis] = high[axis]
					end
				end
				polygon[#polygon + 1] = q
			end
			polygon = clipBox(polygon, low, high)
			-- A native building can cover part of a flat terrain patch.
			-- Keep only the exposed side, never a second internal floor.
			clipBaseSurface(r, x, y, z, polygon, false, tri.normal, function(part)
				combined[#combined + 1] =
					{ vertices = part, normal = tri.normal, localSpace = true, source = tri.source }
			end)
		end
		faces = combined
	end
	if density then
		local nativeFaces = faces
		local brushes = cellBrushes(r, x, y, z, true)
		faces = {}
		V.ForCellTriangles(V.BSPDensityBase(r), x, y, z, function(a, b, c, n)
			local normal = (b - a):Cross(c - a):GetNormalized()
			if normal:Dot(n) < 0 then
				normal = -normal
			end
			clipBrushSurface({ a, b, c }, brushes, r.origin, false, normal, function(part)
				faces[#faces + 1] = { vertices = part, normal = normal, localSpace = true, curved = "density" }
			end)
		end)
		if #brushes > 0 then
			for _, face in ipairs(nativeFaces) do
				local polygon = {}
				for _, p in ipairs(face.vertices) do
					polygon[#polygon + 1] = p - r.origin
				end
				polygon = clipBox(polygon, low, high)
				if #polygon >= 3 then
					clipDensitySurface(r, x, y, z, polygon, false, face.normal, function(part)
						clipBrushSurface(part, brushes, r.origin, true, -face.normal, function(solid)
							clipBrushSurface(solid, brushes, r.origin, false, face.normal, function(exposed)
								faces[#faces + 1] =
									{ vertices = exposed, normal = face.normal, localSpace = true, source = face }
							end)
						end)
					end)
				end
			end
		end
	end
	local edits = indexed or EMPTY
	if not r.bspCellEditBins then
		local candidates = r.bspEditBins
			and r.bspEditBins[V.ChunkKey(math.floor(x / 8), math.floor(y / 8), math.floor(z / 8))]
		edits = {}
		for _, op in ipairs(candidates or EMPTY) do
			local target = op.plane and op.plane.cell
			if not target or (x == target[1] and y == target[2] and z == target[3]) then
				-- Legacy chunk bins have no per-cell membership. Apply the
				-- same quantized node test, including clipped and planar edits.
				for _, o in ipairs(V.CellOffsets) do
					local px, py, pz = x + o[1], y + o[2], z + o[3]
					local node = V.Index(px, py, pz, r)
					if brushNodeSample(r, op, Vector(px, py, pz) * r.step, node) <= 0 then
						edits[#edits + 1] = op
						break
					end
				end
			end
		end
	end
	local last = edits[#edits]
	if fillWholeBrushCell(r, low, high, last, result, key) then
		cache[key] = result
		return result
	end
	if #edits == 0 then
		for _, face in ipairs(faces) do
			local polygon = {}
			for _, p in ipairs(face.vertices) do
				polygon[#polygon + 1] = face.localSpace and p or p - r.origin
			end
			triangles(clipBox(polygon, low, high), face.normal, function(a, b, c, n, cross)
				emit(a, b, c, n, face.curved, nil, face.source or (not face.localSpace and face or nil), cross)
			end)
		end
	else
		result.tetrahedra = {}
		result.baseOccupancy = result.baseOccupancy or baseOccupancy(r, x, y, z, checkpoint)
		local previous = V.TerrainCellCache(r, "previousBSP", x, y, z)
		local parent = previous[key]
		local first = 1
		if parent then
			first = #edits + 1
			for i, op in ipairs(edits) do
				if (op.index or 0) > (parent.operationIndex or 0) then
					first = i
					break
				end
			end
		end
		local nodes = {}
		local lattice = r.bspBrushNodes
		if not lattice then
			lattice = {}
			r.bspBrushNodes = lattice
		end
		local row, layer = r.nx + 1, (r.nx + 1) * (r.ny + 1)
		for i, o in ipairs(V.CellOffsets) do
			local index = key + o[1] + o[2] * row + o[3] * layer
			local point = lattice[index]
			if not point then
				point = Vector(x + o[1], y + o[2], z + o[3]) * r.step
				lattice[index] = point
			end
			nodes[i] = point
		end
		local samples, localFaces = {}, {}
		-- The cut slices from this cell use the same BSP in local space.
		local clipIndex = result.baseOccupancy == 3 and not density and clipRoot(r, x, y, z, key, checkpoint)
		local templateList = tetTemplates(r.step)
		for ti, indices in ipairs(V.CellTetrahedra) do
			local oldTet = parent and parent.tetrahedra and parent.tetrahedra[ti]
			local points = oldTet and oldTet.points or {}
			if not oldTet then
				for i, index in ipairs(indices) do
					points[i] = nodes[index]
				end
			end
			local template = templateList[ti]
			local planes = oldTet and oldTet.planes or {}
			if not oldTet then
				for _, plane in ipairs(template.planes) do
					planes[#planes + 1] = { normal = plane.normal, distance = plane.distance + plane.normal:Dot(low) }
				end
			end
			local operations, lookup = {}, {}
			local tetFirst = 1
			local unchanged = oldTet ~= nil
			for i, op in ipairs(edits) do
				local plane = oldTet and oldTet.operationPlanes and oldTet.operationPlanes[op.index]
				if not plane then
					samples[i] = samples[i] or brushSamples(r, op, nodes, key)
					plane = operationPlane(op, points, samples[i], indices, template)
				end
				if not plane.misses then
					operations[#operations + 1] = plane
					if i < first then tetFirst = tetFirst + 1 end
				end
				lookup[op.index] = plane
				if i >= first and (plane.normal:LengthSqr() > 1e-16 or plane.distance >= 0) then
					unchanged = false
				end
			end
			local final = lookup[edits[#edits].index]
			if final and final.normal == constantBrushNormal and final.distance > EPS then
				-- A completely overwritten tetrahedron has no internal
				-- visible face. For a fill, retain the original convex
				-- partition when preparing collision contacts.
				result.tetrahedra[#result.tetrahedra + 1] = {
					points = points,
					planes = planes,
					operations = operations,
					operationPlanes = lookup,
					triangles = {},
					solids = not final.adding and {} or nil,
				}
			elseif unchanged then
				-- This stroke misses the entire tetrahedron. Its geometry
				-- and collision operations remain valid in the new field.
				result.tetrahedra[#result.tetrahedra + 1] = oldTet
				for _, t in ipairs(oldTet.triangles) do
					result.triangles[#result.triangles + 1] = t
				end
			else
				local tet = {
					points = points,
					planes = planes,
					operations = operations,
					triangles = {},
					operationPlanes = lookup,
				}
				-- Removal composes directly with the preceding final solid.
				-- Replaying its entire brush history from the BSP partitions
				-- the same volumes again. Additions still need original air.
				if oldTet and oldTet.solids and final.adding and not final.misses
					and tetFirst == #operations and result.baseOccupancy ~= 3 then
					-- A homogeneous original tetrahedron needs no BSP air
					-- partition. Replace its added halfspace directly.
					tet.previousSolids = oldTet.solids
					tet.addition = final
				elseif oldTet and oldTet.solids then
					local removals = {}
					for i = tetFirst, #operations do
						if operations[i].adding then
							removals = nil
							break
						end
						removals[#removals + 1] = operations[i]
					end
					if removals then
						tet.previousSolids = oldTet.solids
						tet.removals = removals
					end
				end
				result.tetrahedra[#result.tetrahedra + 1] = tet
				local start = #result.triangles + 1
				local function retain(polygon, normal, curved, alreadySplit, brush, source)
					if not alreadySplit then
						for _, plane in ipairs(planes) do
							polygon = V.ClipBSPPolygon(polygon, plane.normal, plane.distance)
							if #polygon < 3 then
								return
							end
						end
					end
					for i = tetFirst, #operations do
						local op = operations[i]
						if op.normal:LengthSqr() > 0.5 then
							local coplanar = true
							for _, p in ipairs(polygon) do
								if math.abs(op.normal:Dot(p) - op.distance) > EPS then
									coplanar = false
									break
								end
							end
							if coplanar then
								polygon = {}
								break
							end
						end
						polygon = V.ClipBSPPolygon(polygon, op.opposite, -op.distance)
						if #polygon < 3 then
							break
						end
					end
					triangles(polygon, normal, function(a, b, c, n, cross)
						emit(a, b, c, n, curved, brush, source, cross)
					end)
				end
				if parent then
					for _, t in ipairs(oldTet and oldTet.triangles or parent.triangles) do
						retain({ t[1], t[2], t[3] }, t[4], t[5], oldTet ~= nil, t[6], t[7])
					end
				else
					for faceIndex, face in ipairs(faces) do
						local polygon = face.localSpace and face.vertices or localFaces[faceIndex]
						if not polygon then
							polygon = {}
							for vertexIndex, point in ipairs(face.vertices) do
								polygon[vertexIndex] = point - r.origin
							end
							localFaces[faceIndex] = polygon
						end
						retain(
							polygon,
							face.normal,
							face.curved,
							false,
							nil,
							face.source or (not face.localSpace and face or nil)
						)
					end
				end
				cutSurfaces(r, x, y, z, points, operations, emit, checkpoint, tetFirst, result.baseOccupancy, clipIndex)
				for i = start, #result.triangles do
					tet.triangles[#tet.triangles + 1] = result.triangles[i]
				end
			end
			if checkpoint then
				checkpoint()
			end
		end
	end
	cache[key] = result
	return result
end

-- Distance to the nearest non-border corner separates by lattice axis.
local function brushAxisDistances(center, first, last, step, extent)
	local distances = {}
	for cell = first, last do
		local a, b = cell * step, (cell + 1) * step
		distances[cell] = math.min(
			a > EPS and math.abs(a - center) or math.huge,
			b < extent - EPS and math.abs(b - center) or math.huge
		) ^ 2
	end
	return distances
end

function V.RecordBSPBrush(r, center, radius, adding, seed, checkpoint, floorZ, plane)
	if not r.bsp then
		return
	end
	local op = {
		center = center - r.origin,
		radius = radius,
		adding = adding,
		seed = seed,
		index = #r.bspEdits + 1,
		fullCells = {},
		floorZ = floorZ ~= nil and floorZ - r.origin.z or nil,
	}
	if plane then op.plane={axis=plane.axis,sign=plane.sign,distance=plane.distance-plane.sign*r.origin[names[plane.axis]],cell=plane.cell} end
	r.bspEdits[#r.bspEdits + 1] = op
	local p, size = op.center, r.step * 8
	local lowZ = op.floorZ ~= nil and math.max(p.z - radius, op.floorZ) or p.z - radius
	for z = math.max(0, math.floor(lowZ / size)), math.min(3, math.floor((p.z + radius) / size)) do
		for y = math.max(0, math.floor((p.y - radius) / size)), math.min(3, math.floor((p.y + radius) / size)) do
			for x = math.max(0, math.floor((p.x - radius) / size)), math.min(3, math.floor((p.x + radius) / size)) do
				local key = V.ChunkKey(x, y, z)
				local list = {}
				for i, value in ipairs(r.bspEditBins[key] or {}) do
					list[i] = value
				end
				list[#list + 1] = op
				r.bspEditBins[key] = list
			end
		end
	end
	if not r.bspCellEditBins then
		-- Keep a legacy journal on its complete chunk index. Creating a
		-- partial cell index would hide every operation before this stroke.
		if #r.bspEdits > 1 then return end
		r.bspCellEditBins = {}
	end
	local step = r.step
	local x0 = math.max(0, math.floor((p.x - radius) / step))
	local y0 = math.max(0, math.floor((p.y - radius) / step))
	local z0 = math.max(0, math.floor(lowZ / step))
	local x1 = math.min(V.RegionCells(r, "x") - 1, math.floor((p.x + radius) / step))
	local y1 = math.min(V.RegionCells(r, "y") - 1, math.floor((p.y + radius) / step))
	local z1 = math.min(V.RegionCells(r, "z") - 1, math.floor((p.z + radius) / step))
	local nearX, nearY, nearZ
	if not op.plane then
		nearX = brushAxisDistances(p.x, x0, x1, step, V.RegionAxisSize(r, "x"))
		nearY = brushAxisDistances(p.y, y0, y1, step, V.RegionAxisSize(r, "y"))
		nearZ = brushAxisDistances(p.z, z0, z1, step, V.RegionAxisSize(r, "z"))
	end
	local nearLimit = (radius - 1 / 128) ^ 2
	local target = op.plane and op.plane.cell
	op.nodeSamples = {}
	for z = z0, z1 do
		for y = y0, y1 do
			for x = x0, x1 do
				if (not target or (x == target[1] and y == target[2] and z == target[3]))
					and (op.plane or nearX[x] + nearY[y] + nearZ[z] < nearLimit) then
					-- The actual quantized corner samples define all six
					-- linear tetrahedra, including procedural explosions.
					-- Strict signs prove the whole cell is missed or filled;
					-- zero samples keep the exact boundary path unchanged.
					local minimum, maximum = math.huge, -math.huge
					for _, o in ipairs(V.CellOffsets) do
						local a, b, c = x + o[1], y + o[2], z + o[3]
						local nodeKey = V.Index(a, b, c, r)
						local sample = op.nodeSamples[nodeKey]
						if sample == nil then
							sample = brushNodeSample(r, op, Vector(a, b, c) * step, nodeKey)
						end
						minimum = math.min(minimum, sample)
						maximum = math.max(maximum, sample)
						if minimum < 0 and maximum > 0 then
							break
						end
					end
					if minimum <= 0 then
						local key = V.Index(x, y, z, r)
						local list = {}
						if maximum < 0 then
							op.fullCells[key] = true
						else
							for i, old in ipairs(r.bspCellEditBins[key] or {}) do
								list[i] = old
							end
						end
						list[#list + 1] = op
						r.bspCellEditBins[key] = list
					end
				end
				if checkpoint and x % 8 == 0 then
					checkpoint()
				end
			end
		end
	end
end

function V.BSPBrushUnchanged(r, center, radius, adding, seed, floorZ, plane)
	local last = r.bspEdits[#r.bspEdits]
	local localFloor = floorZ ~= nil and floorZ - r.origin.z or nil
	if plane or (last and last.plane) then return false end
	return last
		and last.radius == radius
		and last.adding == adding
		and last.seed == seed
		and last.floorZ == localFloor
		and last.center:DistToSqr(center - r.origin) < 0.000000001
end

local tetFaces = { { 1, 2, 3 }, { 1, 2, 4 }, { 1, 3, 4 }, { 2, 3, 4 } }
local function wholeTet(tet)
	local faces = {}
	for i, indices in ipairs(tetFaces) do
		faces[i] = {
			normal = tet.planes[i].normal,
			vertices = { tet.points[indices[1]], tet.points[indices[2]], tet.points[indices[3]] },
		}
	end
	return { faces = faces, points = tet.points, solid = true }
end

-- Prewarm original BSP intersections near the focus. Compile SAT axes only
-- for the final solids that actually survive an edit.
function V.BSPCollisionNearFocus(r, x, y, z, radius)
	local dx, dy, dz =
		x + 0.5 - V.RegionCells(r, "x") / 2, y + 0.5 - V.RegionCells(r, "y") / 2, z + 0.5 - V.RegionCells(r, "z") / 2
	return (dx * dx + dy * dy + dz * dz) * r.step * r.step <= ((radius or 80) + 2 * r.step) ^ 2
end
local function diagonalBounds(piece)
	local bounds = piece.diagonalBounds
	if not bounds then
		local points = piece.points
		if not points then
			points = {}
			for _, face in ipairs(piece.faces) do
				for _, p in ipairs(face.vertices) do
					points[#points + 1] = p
				end
			end
		end
		local minXY, minXZ, minYZ = math.huge, math.huge, math.huge
		local maxXY, maxXZ, maxYZ = -math.huge, -math.huge, -math.huge
		for _, p in ipairs(points) do
			local px, py, pz = p.x, p.y, p.z
			local xy, xz, yz = px - py, px - pz, py - pz
			minXY, maxXY = math.min(minXY, xy), math.max(maxXY, xy)
			minXZ, maxXZ = math.min(minXZ, xz), math.max(maxXZ, xz)
			minYZ, maxYZ = math.min(minYZ, yz), math.max(maxYZ, yz)
		end
		bounds = { minXY, minXZ, minYZ, maxXY, maxXZ, maxYZ }
		piece.diagonalBounds = bounds
	end
	return bounds
end

local function clipLeafToTet(piece, planes, distances)
	local bounds = diagonalBounds(piece)
	for i, plane in ipairs(planes) do
		local axis, factor = plane.diagonal, plane.factor
		if axis then
			local nearest = factor * bounds[factor < 0 and axis + 3 or axis]
			-- Source rounds each clipped coordinate to a float. At the maximum
			-- 32 m scan size, 1/64 SU exceeds the rounding of all earlier cuts.
			-- Near a lattice plane, always run the original clip sequence.
			if nearest - distances[i] > 1 / 64 then
				return
			end
		end
	end
	for i, plane in ipairs(planes) do
		piece = clip(piece, plane.normal, distances[i])
		if not piece then
			return
		end
	end
	return piece
end

local function baseTetrahedra(r, x, y, z, checkpoint, needAir, requested)
	local cache, key = V.TerrainCellCache(r, "bspBaseTets", x, y, z)
	local all = cache[key]
	if not all then
		all = {}
	end
	if requested and all[requested] and (not needAir or all.air and all.air[requested]) then
		return all[requested]
	elseif not requested and all.prepared then
		return all
	end
	local low = Vector(x, y, z) * r.step
	local templates = tetTemplates(r.step)
	local leaves = cellLeaves(r, x, y, z, needAir, checkpoint)
	for ti = requested or 1, requested or #templates do
		local pieces = all[ti]
		if not pieces or needAir and not (all.air and all.air[ti]) then
			pieces = {}
			local planes, distances = templates[ti].planes, {}
			for i, plane in ipairs(planes) do
				distances[i] = plane.distance + plane.normal:Dot(low)
			end
			for _, leaf in ipairs(leaves) do
				if leaf.solid or needAir then
					local piece = clipLeafToTet(leaf, planes, distances)
					if piece then
						pieces[#pieces + 1] = piece
					end
					if checkpoint then
						checkpoint()
					end
				end
			end
			all[ti] = pieces
			if needAir then
				all.air = all.air or {}
				all.air[ti] = true
			end
		end
	end
	if not requested then
		all.prepared = true
	end
	cache[key] = all
	return requested and all[requested] or all
end

function V.PrepareBSPCollisionCell(r, x, y, z, checkpoint)
	if not V.ActiveRegionCell(r, x, y, z) then
		return
	end
	-- Pure displacements use the density shortcut for their initial hulls.
	-- Still compile their later exact CSG partition during the yielding scan.
	if
		r.bsp
		and #r.bspEdits == 0
		and V.BSPCellUsesDensity(r, x, y, z)
		and V.BSPCollisionNearFocus(r, x, y, z)
		and baseOccupancy(r, x, y, z, checkpoint) == 3
	then
		baseTetrahedra(r, x, y, z, checkpoint)
	end
end

-- Unedited mixed BSP cells already have a proven occupancy. The scan
-- can prepare their exact hulls even when no visible face uses that cell.
function V.BSPCellSolids(r, x, y, z, checkpoint, originalMixed)
	if originalMixed then
		if V.BSPCollisionNearFocus(r, x, y, z) then
			baseTetrahedra(r, x, y, z, checkpoint)
		end
		local leaves = cellLeaves(r, x, y, z, false, checkpoint)
		local solids = {}
		for _, piece in ipairs(leaves) do
			if piece.solid then solids[#solids + 1] = piece end
		end
		return solids
	end
	local cell = V.BSPCell(r, x, y, z, checkpoint)
	if not cell.solids then
		local solids = {}
		local needsAir, hasPrevious = nil, false
		for ti, tet in ipairs(cell.tetrahedra or {}) do
			local previous = tet.solids or tet.previousSolids
			if previous and (#previous > 0 or tet.addition) then
				hasPrevious = true
			end
			if not tet.solids and not tet.previousSolids then
				for _, op in ipairs(tet.operations) do
					if op.adding then
						needsAir = needsAir or {}
						needsAir[ti] = true
						break
					end
				end
			end
		end
		local occupancy = cell.baseOccupancy or baseOccupancy(r, x, y, z, checkpoint)
		-- Inside intact solid ground the mesh already owns the six exact
		-- tetrahedra. Don't reconstruct each one by clipping a cube against
		-- its four planes. Originally empty cells cannot gain matter from
		-- removal-only history either.
		if occupancy == 2 and not needsAir and not hasPrevious then
			cell.solids = solids
			return solids
		elseif cell.tetrahedra then
			for ti, tet in ipairs(cell.tetrahedra) do
				-- BSPCell retains an old tetrahedron only when the new brush
				-- misses it. Its immutable final solids remain valid too.
				if not tet.solids then
					if tet.addition then
						local addition = tet.addition
						local filled = clip(wholeTet(tet), addition.normal, addition.distance, "cut")
						local retained = filled and { filled } or {}
						for _, piece in ipairs(tet.previousSolids) do
							local outside = clip(piece, addition.opposite, -addition.distance, "cut")
							if outside then retained[#retained + 1] = outside end
							if checkpoint then checkpoint() end
						end
						tet.solids = retained
						tet.previousSolids, tet.addition = nil, nil
					elseif tet.previousSolids then
						tet.solids = V.ApplyBSPBrushPlanes(tet.previousSolids, tet.removals, checkpoint)
						tet.previousSolids = nil
						tet.removals = nil
					elseif occupancy == 2 and not (needsAir and needsAir[ti]) then
						tet.solids = EMPTY
					else
						local pieces
						if occupancy ~= 3 then
							local piece = wholeTet(tet)
							piece.solid = occupancy == 1
							pieces = { piece }
						else
							local needAir = needsAir and needsAir[ti]
							pieces = baseTetrahedra(r, x, y, z, checkpoint, needAir, ti)
						end
						tet.solids = V.ApplyBSPBrushPlanes(pieces, tet.operations, checkpoint)
					end
				end
				for _, piece in ipairs(tet.solids) do
					solids[#solids + 1] = piece
				end
				if checkpoint then
					checkpoint()
				end
			end
		else
			if occupancy == 3 and V.BSPCollisionNearFocus(r, x, y, z) then
				baseTetrahedra(r, x, y, z, checkpoint)
			end
			if occupancy == 1 then
				local low = Vector(x, y, z) * r.step
				local piece = box(low, low + Vector(1, 1, 1) * r.step)
				piece.solid = true
				solids[1] = piece
			else
				for _, piece in ipairs(cellLeaves(r, x, y, z, false, checkpoint)) do
					if piece.solid then
						solids[#solids + 1] = piece
					end
				end
			end
		end
		cell.solids = solids
	end
	return cell.solids
end

function V.BSPBoundaryOpening(r, face, checkpoint)
	local vertices = {}
	local visits = 0
	local function walk(polygon, index, depth)
		if #polygon < 3 then
			return
		end
		visits = visits + 1
		if checkpoint and visits % 16 == 0 then checkpoint() end
		assert(depth < 1024, "arbre BSP trop profond")
		if index < 0 then
			if not r.bsp.leaves[-index].solid then
				clipBrushSurface(polygon, r.bspBrushes or EMPTY, Vector(), false, face.normal, function(part)
					triangles(part, face.normal, function(a, b, c, n)
						for _, p in ipairs({ a, b, c }) do
							vertices[#vertices + 1] = { pos = p, normal = n, u = 0, v = 0 }
						end
					end)
				end, checkpoint)
			end
			return
		end
		local node = r.bsp.nodes[index + 1]
		local plane = r.bsp.planes[node.plane]
		-- Probe just outside the cube, so coplanar world surfaces choose the
		-- external room rather than the solid side of a boundary wall.
		local d = plane.distance - plane.normal:Dot(face.normal * 0.001)
		walk(V.ClipBSPPolygon(polygon, -plane.normal, -d), node.front, depth + 1)
		walk(V.ClipBSPPolygon(polygon, plane.normal, d), node.back, depth + 1)
	end
	walk(face.vertices, r.bsp.head, 0)
	return vertices
end
