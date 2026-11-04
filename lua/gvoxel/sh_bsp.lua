-- Read-only access to compiled world geometry. No VMF, engine convars or BSP writes.
-- Layouts follow Valve's public bspfile.h (Source BSP 19/20).
local V = GVoxel
local state = {}
local band = bit.band
local axes = { "x", "y", "z" }
-- Only sky settings are retained from the entity text; never execute map data.
function V.BSPSkySettings(text)
	local settings = {}
	for block in text:gmatch("{([^{}]*)}") do
		local fields = {}
		for k, v in block:gmatch('"([^"\r\n]+)"%s*"([^"\r\n]*)"') do
			fields[k] = v
		end
		if fields.classname == "worldspawn" then
			settings.name = fields.skyname
		end
		if fields.classname == "sky_camera" and not settings.camera then
			local x, y, z = (fields.origin or ""):match("^%s*([%+%-%.%deE]+)%s+([%+%-%.%deE]+)%s+([%+%-%.%deE]+)%s*$")
			x, y, z = tonumber(x), tonumber(y), tonumber(z)
			local scale = tonumber(fields.scale) or 16
			if
				x
				and y
				and z
				and math.abs(x) < 1e6
				and math.abs(y) < 1e6
				and math.abs(z) < 1e6
				and scale > 0
				and scale < 1e6
			then
				settings.camera = { origin = Vector(x, y, z), scale = scale }
				local red, green, blue = (fields.fogcolor or "128 128 128"):match("^(%d+)%s+(%d+)%s+(%d+)")
				settings.camera.fog = {
					enabled = fields.fogenable == "1",
					start = tonumber(fields.fogstart) or 0,
					finish = tonumber(fields.fogend) or 10000,
					density = tonumber(fields.fogmaxdensity) or 1,
					red = tonumber(red) or 128,
					green = tonumber(green) or 128,
					blue = tonumber(blue) or 128,
				}
			end
		end
	end
	return settings
end
local function overlap(a, b, c, d)
	return a.x <= d.x and b.x >= c.x and a.y <= d.y and b.y >= c.y and a.z <= d.z and b.z >= c.z
end
V.BoundsOverlap = overlap

-- Source alternates the diagonal of adjacent displacement quads. A fixed
-- diagonal changes the height of non-planar patches and their border joins.
function V.ForDisplacementTriangles(face, emit, checkpoint)
	local grid, width = face.dispGrid, face.dispWidth
	for y = 0, width - 2 do
		for x = 0, width - 2 do
			local index = y * width + x + 1
			local a, b, c, d = grid[index], grid[index + 1], grid[index + width], grid[index + width + 1]
			if (index - 1) % 2 == 1 then
				emit({ a, c, b })
				emit({ b, c, d })
			else
				emit({ a, c, d })
				emit({ a, d, b })
			end
			if checkpoint and x % 8 == 7 then
				checkpoint()
			end
		end
	end
end

function V.ReadBSP(stream, checkpoint)
	local size = stream:Size()
	assert(stream:Read(4) == "VBSP", "signature BSP inconnue")
	local version = stream:ReadLong()
	assert(version == 19 or version == 20, "version BSP non prise en charge : " .. version)
	local lumps = {}
	for i = 0, 63 do
		local o, n, v, compressed = stream:ReadLong(), stream:ReadLong(), stream:ReadLong(), stream:ReadLong()
		assert(o >= 0 and n >= 0 and o + n <= size, "section BSP hors fichier")
		lumps[i] = { offset = o, length = n, version = v, compressed = compressed }
	end
	local function section(id, stride)
		local l = lumps[id]
		assert(l.compressed == 0, "section BSP compressee non prise en charge : " .. id)
		assert(not stride or l.length % stride == 0, "taille de section BSP invalide : " .. id)
		stream:Seek(l.offset)
		return l.length / (stride or 1)
	end
	local function vec()
		return Vector(stream:ReadFloat(), stream:ReadFloat(), stream:ReadFloat())
	end
	local function tick(i)
		if checkpoint and i % 128 == 0 then
			checkpoint()
		end
	end
	local data = { planes = {}, nodes = {}, leaves = {}, faces = {}, texinfo = {}, textures = {}, pvsRows = {} }
	if lumps[0].compressed == 0 and lumps[0].length > 0 then
		local count = section(0)
		data.sky = V.BSPSkySettings(stream:Read(count))
	end
	-- Area portals lose their brush model at compile time. Their entity
	-- origin/AABB cannot locate a bank window; use its compiled portal key.
	local portalVertices = {}
	for i = 1, section(41, 12) do
		portalVertices[i] = vec()
		tick(i)
	end
	data.areaPortals = {}
	for i = 1, section(21, 12) do
		local key = stream:ReadUShort()
		stream:ReadUShort()
		local first, count = stream:ReadUShort(), stream:ReadUShort()
		stream:ReadLong()
		if key > 0 and count > 0 and first + count <= #portalVertices then
			local bounds = data.areaPortals[key]
				or { low = Vector(math.huge, math.huge, math.huge), high = Vector(-math.huge, -math.huge, -math.huge) }
			for j = 1, count do
				local p = portalVertices[first + j]
				for _, axis in ipairs(axes) do
					bounds.low[axis] = math.min(bounds.low[axis], p[axis])
					bounds.high[axis] = math.max(bounds.high[axis], p[axis])
				end
			end
			data.areaPortals[key] = bounds
		end
		tick(i)
	end
	for i = 1, section(1, 20) do
		data.planes[i] = { normal = vec(), distance = stream:ReadFloat() }
		stream:ReadLong()
		tick(i)
	end
	for i = 1, section(5, 32) do
		local node = { plane = stream:ReadLong() + 1, front = stream:ReadLong(), back = stream:ReadLong() }
		stream:Skip(20)
		data.nodes[i] = node
		tick(i)
	end
	local leafStride = lumps[10].version == 0 and 56 or 32
	for i = 1, section(10, leafStride) do
		local contents = stream:ReadLong()
		local leaf = { contents = contents, solid = band(contents, 1) ~= 0, cluster = stream:ReadShort() }
		local packed = stream:ReadUShort()
		leaf.area = band(packed, 511)
		leaf.flags = math.floor(packed / 512)
		leaf.low = Vector(stream:ReadShort(), stream:ReadShort(), stream:ReadShort())
		leaf.high = Vector(stream:ReadShort(), stream:ReadShort(), stream:ReadShort())
		leaf.firstFace = stream:ReadUShort()
		leaf.numFaces = stream:ReadUShort()
		leaf.firstBrush = stream:ReadUShort()
		leaf.numBrushes = stream:ReadUShort()
		stream:Skip(leafStride - 28)
		data.leaves[i] = leaf
		tick(i)
	end
	section(14, 48)
	stream:Skip(36)
	data.head = stream:ReadLong()
	local firstFace, faceCount = stream:ReadLong(), stream:ReadLong()
	-- Detail brushes do not split the visibility tree. An air leaf may still
	-- contain a solid floor, road or wall: leaf.contents alone loses these.
	local sides, brushes, leafBrushes = {}, {}, {}
	for i = 1, section(19, 8) do
		sides[i] = stream:ReadUShort() + 1
		stream:Skip(6)
		tick(i)
	end
	for i = 1, section(18, 12) do
		local first, count, contents = stream:ReadLong(), stream:ReadLong(), stream:ReadLong()
		if band(contents, 16395) ~= 0 then
			assert(first >= 0 and count >= 4 and first + count <= #sides, "brush BSP invalide")
			local brush = {
				planes = {},
				contents = contents,
				id = i,
				low = Vector(-32768, -32768, -32768),
				high = Vector(32768, 32768, 32768),
			}
			for j = 1, count do
				local plane = assert(data.planes[sides[first + j]], "plan de brush invalide")
				brush.planes[#brush.planes + 1] = plane
				for _, axis in ipairs(axes) do
					if plane.normal[axis] == 1 then
						brush.high[axis] = math.min(brush.high[axis], plane.distance)
					elseif plane.normal[axis] == -1 then
						brush.low[axis] = math.max(brush.low[axis], -plane.distance)
					end
				end
			end
			brushes[i] = brush
		end
		tick(i)
	end
	for i = 1, section(17, 2) do
		leafBrushes[i] = stream:ReadUShort() + 1
		tick(i)
	end
	data.worldBrushes = {}
	local seen, visited = {}, {}
	local function world(index, depth)
		assert(depth < 1024, "arbre BSP cyclique")
		if visited[index] then
			return
		end
		visited[index] = true
		if index < 0 then
			local leaf = assert(data.leaves[-index], "feuille BSP invalide")
			leaf.brushes = {}
			for j = 1, leaf.numBrushes do
				local brush = brushes[leafBrushes[leaf.firstBrush + j]]
				if brush then
					leaf.brushes[#leaf.brushes + 1] = brush
					if not seen[brush] then
						seen[brush] = true
						data.worldBrushes[#data.worldBrushes + 1] = brush
					end
				end
			end
		else
			local node = assert(data.nodes[index + 1], "noeud BSP invalide")
			world(node.front, depth + 1)
			world(node.back, depth + 1)
		end
		if checkpoint then
			checkpoint()
		end
	end
	world(data.head, 0)
	local vertices, edges, surfedges = {}, {}, {}
	for i = 1, section(3, 12) do
		vertices[i] = vec()
		tick(i)
	end
	for i = 1, section(12, 4) do
		edges[i] = { stream:ReadUShort() + 1, stream:ReadUShort() + 1 }
		tick(i)
	end
	for i = 1, section(13, 4) do
		surfedges[i] = stream:ReadLong()
		tick(i)
	end
	local strings
	section(43)
	strings = stream:Read(lumps[43].length)
	local offsets = {}
	for i = 1, section(44, 4) do
		offsets[i] = stream:ReadLong() + 1
	end
	for i = 1, section(2, 32) do
		vec()
		local index = stream:ReadLong() + 1
		local w, h = stream:ReadLong(), stream:ReadLong()
		stream:Skip(8)
		local start = assert(offsets[index], "index de texture invalide")
		local finish = strings:find("\0", start, true)
		assert(finish, "nom de texture incomplet")
		data.textures[i] = { name = strings:sub(start, finish - 1), w = math.max(1, w), h = math.max(1, h) }
		tick(i)
	end
	for i = 1, section(6, 72) do
		local tex = {
			u = vec(),
			uo = stream:ReadFloat(),
			v = vec(),
			vo = stream:ReadFloat(),
			lu = vec(),
			luo = stream:ReadFloat(),
			lv = vec(),
			lvo = stream:ReadFloat(),
			flags = stream:ReadLong(),
			texture = stream:ReadLong() + 1,
		}
		data.texinfo[i] = tex
		tick(i)
	end
	-- Faces and light samples must come from the same LDR/HDR pair: offsets
	-- are not interchangeable. The server needs geometry, not HDR lighting.
	local hdr = CLIENT and GetConVar and GetConVar("mat_hdr_level")
	local useHDR = hdr
		and hdr:GetInt() > 1
		and lumps[53].length > 0
		and lumps[58].length > 0
		and lumps[53].compressed == 0
		and lumps[58].compressed == 0
	local facesID, lighting = 7, 8
	if useHDR or lumps[7].length == 0 or lumps[8].length == 0 then
		if lumps[58].length > 0 and lumps[53].length > 0 then
			facesID, lighting = 58, 53
		end
	end
	section(lighting)
	data.lighting = lumps[lighting].length > 0 and stream:Read(lumps[lighting].length) or ""
	data.lightingHDR = lighting == 53
	local count = section(facesID, 56)
	assert(firstFace >= 0 and firstFace + faceCount <= count, "modele monde invalide")
	local faceIDs = {}
	for i = 1, count do
		local planeIndex, side = stream:ReadUShort() + 1, stream:ReadByte()
		stream:Skip(1)
		local edgeStart, edgeCount = stream:ReadLong(), stream:ReadShort()
		local texIndex, displacement = stream:ReadShort() + 1, stream:ReadShort()
		stream:Skip(2)
		local styles = { stream:ReadByte(), stream:ReadByte(), stream:ReadByte(), stream:ReadByte() }
		local lightOffset = stream:ReadLong()
		stream:Skip(4)
		local lightMin = { stream:ReadLong(), stream:ReadLong() }
		local lightSize = { stream:ReadLong(), stream:ReadLong() }
		stream:Skip(12)
		if i > firstFace and i <= firstFace + faceCount and edgeCount >= 3 then
			local plane = assert(data.planes[planeIndex], "plan de face invalide")
			local normal = plane.normal * (side == 0 and 1 or -1)
			local polygon = {}
			local low, high = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
			for j = 1, edgeCount do
				local edgeIndex = assert(surfedges[edgeStart + j], "surfedge invalide")
				local edge = assert(edges[math.abs(edgeIndex) + 1], "edge invalide")
				local p = assert(vertices[edge[edgeIndex >= 0 and 1 or 2]], "sommet invalide")
				polygon[#polygon + 1] = p
				for _, a in ipairs(axes) do
					low[a] = math.min(low[a], p[a])
					high[a] = math.max(high[a], p[a])
				end
			end
			local tex = data.texinfo[texIndex]
			if tex then
				local face = {
					vertices = polygon,
					normal = normal,
					distance = plane.distance * (side == 0 and 1 or -1),
					low = low,
					high = high,
					tex = tex,
					displacement = displacement >= 0,
					displacementIndex = displacement + 1,
					lightOffset = lightOffset,
					lightMin = lightMin,
					lightSize = lightSize,
					lightStyles = styles,
					clusters = {},
					areas = {},
				}
				data.faces[#data.faces + 1] = face
				faceIDs[i - 1] = face
			end
		end
		tick(i)
	end
	-- Bounds of the displaced shell, not just its flat Hammer support quad.
	-- Otherwise an elevated/sideways displacement can be outside the base
	-- face's AABB and incorrectly enable brush-only reconstruction there.
	local dispInfo, dispVerts = {}, {}
	for i = 1, section(26, 176) do
		dispInfo[i] = { start = vec(), first = stream:ReadLong(), tri = stream:ReadLong(), power = stream:ReadLong() }
		stream:Skip(152)
		tick(i)
	end
	for i = 1, section(33, 20) do
		local direction = vec()
		local distance = stream:ReadFloat()
		stream:Skip(4)
		dispVerts[i] = direction * distance
		tick(i)
	end
	for i, face in ipairs(data.faces) do
		if face.displacement then
			local info = assert(dispInfo[face.displacementIndex], "displacement absent")
			assert(#face.vertices == 4 and info.power >= 2 and info.power <= 4, "displacement invalide")
			local first, dist = 1, math.huge
			for j, p in ipairs(face.vertices) do
				local d = p:DistToSqr(info.start)
				if d < dist then
					first, dist = j, d
				end
			end
			local p = {}
			for j = 0, 3 do
				p[j + 1] = face.vertices[(first + j - 1) % 4 + 1]
			end
			local low, high = Vector(face.low.x, face.low.y, face.low.z), Vector(face.high.x, face.high.y, face.high.z)
			local intervals = 2 ^ info.power
			local width = intervals + 1
			local grid = {}
			for y = 0, intervals do
				local a = p[1] + (p[2] - p[1]) * (y / intervals)
				local b = p[4] + (p[3] - p[4]) * (y / intervals)
				for x = 0, intervals do
					local point = a
						+ (b - a) * (x / intervals)
						+ assert(dispVerts[info.first + y * width + x + 1], "sommet displacement absent")
					grid[y * width + x + 1] = point
					for _, axis in ipairs(axes) do
						low[axis] = math.min(low[axis], point[axis])
						high[axis] = math.max(high[axis], point[axis])
					end
				end
				if checkpoint then
					checkpoint()
				end
			end
			face.dispLow, face.dispHigh = low, high
			face.dispGrid, face.dispWidth = grid, width
		end
		tick(i)
	end
	local leafFaces = {}
	for i = 1, section(16, 2) do
		leafFaces[i] = stream:ReadUShort()
		tick(i)
	end
	for i, leaf in ipairs(data.leaves) do
		if leaf.cluster >= 0 then
			for j = 1, leaf.numFaces do
				local face = faceIDs[leafFaces[leaf.firstFace + j]]
				if face then
					face.clusters[leaf.cluster] = true
					face.areas[leaf.area] = true
				end
			end
		end
		tick(i)
	end
	for i, face in ipairs(data.faces) do
		local clusters = {}
		for cluster in pairs(face.clusters) do
			clusters[#clusters + 1] = cluster
		end
		table.sort(clusters)
		face.clusters = clusters
		face.clusterKey = table.concat(clusters, ",")
		tick(i)
	end
	section(4)
	data.visibility = lumps[4].length > 0 and stream:Read(lumps[4].length) or ""
	assert(data.nodes[data.head + 1] and #data.leaves > 0, "arbre BSP absent")
	return data
end

function V.BSPLeaf(data, p)
	local index = data.head
	for _ = 1, 1024 do
		if index < 0 then
			return data.leaves[-index]
		end
		local node = data.nodes[index + 1]
		local plane = data.planes[node.plane]
		index = plane.normal:Dot(p) >= plane.distance and node.front or node.back
	end
	error("arbre BSP cyclique")
end
function V.BSPBrushContains(brush, p)
	if not overlap(p, p, brush.low, brush.high) then
		return false
	end
	for _, plane in ipairs(brush.planes) do
		if plane.normal:Dot(p) > plane.distance + 0.0000001 then
			return false
		end
	end
	return true
end
function V.BSPSolid(data, p)
	local leaf = V.BSPLeaf(data, p)
	if leaf.solid then
		return true
	end
	for _, brush in ipairs(leaf.brushes or {}) do
		if V.BSPBrushContains(brush, p) then
			return true
		end
	end
	return false
end

local function uint(bytes, pos)
	local a, b, c, d = bytes:byte(pos, pos + 3)
	if not d then
		return
	end
	return a + b * 256 + c * 65536 + d * 16777216
end
function V.BSPClusterPVS(data, cluster)
	if cluster < 0 or not data.visibility or #data.visibility < 4 then
		return
	end
	local cached = data.pvsRows[cluster]
	if cached then
		return cached
	end
	local count = uint(data.visibility, 1)
	local offset = uint(data.visibility, 5 + cluster * 8)
	if not count or count < 1 or count > 65536 or cluster >= count or not offset or offset >= #data.visibility then
		return
	end
	local row, pos = {}, offset + 1
	while #row < math.ceil(count / 8) do
		local byte = data.visibility:byte(pos)
		pos = pos + 1
		if not byte then
			return
		end
		if byte == 0 then
			local run = data.visibility:byte(pos)
			pos = pos + 1
			if not run or run == 0 then
				return
			end
			for _ = 1, math.min(run, math.ceil(count / 8) - #row) do
				row[#row + 1] = 0
			end
		else
			row[#row + 1] = byte
		end
	end
	data.pvsRows[cluster] = row
	return row
end
function V.BSPVisibleClusters(data, eye)
	local leaf = V.BSPLeaf(data, eye)
	return V.BSPClusterPVS(data, leaf.cluster), leaf.area
end
function V.BSPClustersInPVS(row, clusters)
	if not row or not clusters or #clusters == 0 then
		return false
	end
	for _, cluster in ipairs(clusters) do
		if band(row[math.floor(cluster / 8) + 1] or 0, 2 ^ (cluster % 8)) ~= 0 then
			return true
		end
	end
	return false
end

function V.BSPVisibilityOrigins(data, r, checkpoint)
	local origins, clusters = {}, {}
	local function add(p, expected)
		local leaf = V.BSPLeaf(data, p)
		local cluster = leaf.cluster
		local key = cluster and (cluster .. ":" .. (leaf.area or 0))
		if
			(not expected or leaf == expected)
			and not V.BSPSolid(data, p)
			and cluster
			and cluster >= 0
			and not clusters[key]
		then
			clusters[key] = true
			origins[#origins + 1] = p
			return true
		end
	end
	-- Intersect the LOCAL cage with the visibility tree. A face centroid can
	-- be hundreds of metres outside it; a coarse grid misses thin rooms.
	-- Partition once during the yielding scan, never while drawing/editing.
	local function walk(piece, index, depth)
		if not piece then
			return
		end
		assert(depth < 1024, "arbre BSP trop profond")
		if checkpoint then
			checkpoint()
		end
		if index < 0 then
			local leaf = data.leaves[-index]
			if
				leaf.solid
				or not leaf.cluster
				or leaf.cluster < 0
				or clusters[leaf.cluster .. ":" .. (leaf.area or 0)]
			then
				return
			end
			local points, seen = {}, {}
			local center = Vector()
			for _, face in ipairs(piece.faces) do
				for _, p in ipairs(face.vertices) do
					if not seen[p] then
						seen[p] = true
						points[#points + 1] = p
						center = center + p
					end
				end
			end
			if #points == 0 then
				return
			end
			center = center / #points
			if not add(center, leaf) then
				for _, p in ipairs(points) do
					if add(p * 0.9 + center * 0.1, leaf) then
						break
					end
				end
			end
			return
		end
		local node = data.nodes[index + 1]
		local plane = data.planes[node.plane]
		walk(V.ClipBSPPolytope(piece, -plane.normal, -plane.distance), node.front, depth + 1)
		walk(V.ClipBSPPolytope(piece, plane.normal, plane.distance), node.back, depth + 1)
	end
	local margin = Vector(2, 2, 2)
	walk({ faces = V.MaskFaces({ origin = r.origin - margin, extent = V.RegionSize(r) + margin * 2 }) }, data.head, 0)
	return origins
end

function V.GetBSPGeometry()
	return state.data, state.done, state.error
end
local function start()
	if state.thread or state.done then
		return
	end
	state.thread = coroutine.create(function()
		local stream = assert(file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME"), "BSP introuvable")
		state.stream = stream
		local data = V.ReadBSP(stream, coroutine.yield)
		stream:Close()
		state.stream = nil
		return data
	end)
end
hook.Add("InitPostEntity", "GVoxel.ReadWorldGeometry", start)
hook.Add("Think", "GVoxel.ReadWorldGeometry", function()
	if not state.thread then
		return
	end
	local deadline = SysTime() + 0.002
	repeat
		local ok, result = coroutine.resume(state.thread)
		if not ok or coroutine.status(state.thread) == "dead" then
			if state.stream then
				state.stream:Close()
				state.stream = nil
			end
			state.done = true
			state.thread = nil
			if ok then
				state.data = result
			else
				state.error = tostring(result)
				ErrorNoHalt("[GVoxel] Geometrie BSP : " .. state.error .. " ; scan par rayons conserve.\n")
			end
			return
		end
	until SysTime() >= deadline
end)
-- Auto-refresh after InitPostEntity also starts the read, outside render hooks.
if file and game then
	start()
end
