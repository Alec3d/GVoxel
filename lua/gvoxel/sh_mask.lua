-- Geometry for a volume mask; no render/physics functions in this module.
local V = GVoxel

function V.MaskFaces(r)
	local p = r.origin
	local s = V.RegionSize(r)
	-- Geometry vertices are immutable. The six faces share their eight
	-- corners, so later clips can also share classifications/intersections.
	local corners = {}
	local function v(x, y, z)
		local key = 1 + x + 2 * y + 4 * z
		if not corners[key] then
			corners[key] = p + Vector(x * s.x, y * s.y, z * s.z)
		end
		return corners[key]
	end
	local function face(normal, a, b, c, d)
		return { normal = normal, point = a, vertices = { a, b, c, d } }
	end
	return {
		face(Vector(-1, 0, 0), v(0, 0, 0), v(0, 0, 1), v(0, 1, 1), v(0, 1, 0)),
		face(Vector(1, 0, 0), v(1, 0, 0), v(1, 1, 0), v(1, 1, 1), v(1, 0, 1)),
		face(Vector(0, -1, 0), v(0, 0, 0), v(1, 0, 0), v(1, 0, 1), v(0, 0, 1)),
		face(Vector(0, 1, 0), v(0, 1, 0), v(0, 1, 1), v(1, 1, 1), v(1, 1, 0)),
		face(Vector(0, 0, -1), v(0, 0, 0), v(0, 1, 0), v(1, 1, 0), v(1, 0, 0)),
		face(Vector(0, 0, 1), v(0, 0, 1), v(1, 0, 1), v(1, 1, 1), v(0, 1, 1)),
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
	return scan and scan.phase == 2 and scan.received == 64 and scan.built == 64
end

-- Compile only the air part of each boundary face. Its diagonal is identical
-- to the tetrahedron split, so openings meet the terrain without square caps.
function V.BuildBoundaryOpening(r, face, checkpoint)
	if r.bsp and not r.bspFallback then
		return V.BSPBoundaryOpening(r, face)
	end
	local vertices = {}
	local a = face.vertices[1]
	local edgeU, edgeV = face.vertices[2] - a, face.vertices[4] - a
	local countU, countV = math.floor(edgeU:Length() / r.step + 0.5), math.floor(edgeV:Length() / r.step + 0.5)
	local u = edgeU / (countU * r.step)
	local v = edgeV / (countV * r.step)
	local function node(i, j)
		local p = a + (u * i + v * j) * r.step
		local q = (p - r.origin) / r.step
		return { pos = p, density = V.Sample(r, math.floor(q.x + 0.5), math.floor(q.y + 0.5), math.floor(q.z + 0.5)) }
	end
	local function clipTriangle(points, x, y, z)
		local polygon = {}
		local previous = points[#points]
		for _, current in ipairs(points) do
			local prevAir, currentAir = previous.density > 0, current.density > 0
			if prevAir ~= currentAir then
				local t = previous.density / (previous.density - current.density)
				local p = previous.pos + (current.pos - previous.pos) * t
				if V.RefineSurfacePoint then
					p = r.origin + V.RefineSurfacePoint(r, p - r.origin)
				end
				polygon[#polygon + 1] = { pos = p, density = 0 }
			end
			if currentAir then
				polygon[#polygon + 1] = current
			end
			previous = current
		end
		local positions = {}
		for _, point in ipairs(polygon) do
			positions[#positions + 1] = point.pos
		end
		local function emit(part)
			for i = 2, #part - 1 do
				local p, b, c = part[1], part[i], part[i + 1]
				if (b - p):Cross(c - p):LengthSqr() > 0.000001 then
					for _, point in ipairs({ p, b, c }) do
						vertices[#vertices + 1] = { pos = point, normal = face.normal, u = 0, v = 0 }
					end
				end
			end
		end
		if r.bsp and #positions >= 3 then
			V.ClipBSPDetailOpening(r, positions, face.normal, x, y, z, emit)
		else
			emit(positions)
		end
	end
	for j = 0, countV - 1 do
		for i = 0, countU - 1 do
			local p, b, c, d = node(i, j), node(i + 1, j), node(i + 1, j + 1), node(i, j + 1)
			local center = ((p.pos + c.pos) / 2 - face.normal * (r.step * 0.5) - r.origin) / r.step
			local x, y, z =
				math.floor(center.x + 0.000001), math.floor(center.y + 0.000001), math.floor(center.z + 0.000001)
			if r.bsp and not V.BSPCellUsesDensity(r, x, y, z) then
				local tile = { normal = face.normal, vertices = { p.pos, b.pos, c.pos, d.pos } }
				for _, vertex in ipairs(V.BSPBoundaryOpening(r, tile)) do
					vertices[#vertices + 1] = vertex
				end
			else
				clipTriangle({ p, b, c }, x, y, z)
				clipTriangle({ p, c, d }, x, y, z)
			end
			if checkpoint and (i + j * r.nx) % 16 == 0 then
				checkpoint()
			end
		end
	end
	return vertices
end
