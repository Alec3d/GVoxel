local V = GVoxel
local axes = { "x", "y", "z" }

function V.SnapScanPosition(p)
	return Vector(math.floor(p.x * 8 + 0.5) / 8, math.floor(p.y * 8 + 0.5) / 8, math.floor(p.z * 8 + 0.5) / 8)
end

function V.ScanBrushRadius(r, radius)
	return math.max(math.ceil(r.step), math.min(80, math.max(24, math.floor(radius))))
end

local function triangleDistance(start, direction, a, b, c)
	local ab, ac = b - a, c - a
	if ab:Cross(ac):LengthSqr() < 0.000001 then
		return
	end
	local h = direction:Cross(ac)
	local determinant = ab:Dot(h)
	if math.abs(determinant) < 1e-9 then
		return
	end
	local s = start - a
	local u = s:Dot(h) / determinant
	if u < -1e-7 or u > 1 + 1e-7 then
		return
	end
	local q = s:Cross(ab)
	local v = direction:Dot(q) / determinant
	if v < -1e-7 or u + v > 1 + 1e-7 then
		return
	end
	return ac:Dot(q) / determinant
end

-- Walk lattice cells, intersecting the same tetrahedron triangles as BuildChunk.
-- No trace against the hidden BSP can stop a ray inside a voxel hole.
function V.TraceScanRegion(r, start, direction, reach, occlusionOnly, checkpoint)
	local first, last = V.CubeRayInterval(r, start, direction)
	if not first or first > reach then
		return
	end
	last = math.min(last, reach)
	local t = math.min(first + 0.00001, last)
	local q = (start + direction * t - r.origin) / r.step
	local cell = {
		x = math.max(0, math.min(V.RegionCells(r, "x") - 1, math.floor(q.x))),
		y = math.max(0, math.min(V.RegionCells(r, "y") - 1, math.floor(q.y))),
		z = math.max(0, math.min(V.RegionCells(r, "z") - 1, math.floor(q.z))),
	}
	local nextT, delta, increment = {}, {}, {}
	for _, axis in ipairs(axes) do
		local d = direction[axis]
		increment[axis] = d > 0 and 1 or -1
		if math.abs(d) < 1e-10 then
			nextT[axis] = math.huge
			delta[axis] = math.huge
		else
			local plane = r.origin[axis] + (cell[axis] + (d > 0 and 1 or 0)) * r.step
			nextT[axis] = (plane - start[axis]) / d
			delta[axis] = r.step / math.abs(d)
		end
	end
	local localStart = start - r.origin
	while t <= last + 0.00001 do
		local boundary = math.min(nextT.x, nextT.y, nextT.z, last)
		local best, bestNormal, bestCurved, bestBrush = nil, nil, nil, nil
		V.ForCellTriangles(r, cell.x, cell.y, cell.z, function(a, b, c, outward, curved, brush)
			local distance = triangleDistance(localStart, direction, a, b, c)
			if
				distance
				and distance >= first - 0.00001
				and distance >= t - 0.0001
				and distance <= boundary + 0.0001
				and (not best or distance < best)
			then
				best = distance
				bestNormal = (b - a):Cross(c - a):GetNormalized()
				bestCurved = curved
				bestBrush = brush
				if bestNormal:Dot(outward) < 0 then
					bestNormal = bestNormal * -1
				end
			end
		end, checkpoint)
		if best then
			if occlusionOnly then
				return true
			end
			local p = start + direction * best
			local normal = bestNormal
			if bestBrush then
				normal = (bestBrush.seed or bestBrush.floorZ ~= nil or bestBrush.plane) and bestNormal
					or (p - r.origin - bestBrush.center):GetNormalized() * (bestBrush.adding and 1 or -1)
			elseif not r.bsp or bestCurved then
				normal = V.Normal(r, p)
				if normal:LengthSqr() < 0.5 then
					normal = bestNormal
				end
				if V.FeatureNormal then
					normal = V.FeatureNormal(r, p, bestNormal, normal)
				end
			end
			return {
				Hit = true,
				VoxelScan = true,
				ScanRegion = r,
				HitWorld = false,
				HitPos = p,
				HitNormal = normal,
				Distance = best,
				Fraction = best / reach,
			}
		end
		if boundary >= last then
			break
		end
		for _, axis in ipairs(axes) do
			if nextT[axis] <= boundary + 0.000001 then
				cell[axis] = cell[axis] + increment[axis]
				if cell[axis] < 0 or cell[axis] >= V.RegionCells(r, axis) then
					return
				end
				nextT[axis] = nextT[axis] + delta[axis]
			end
		end
		t = boundary
		if checkpoint then
			checkpoint()
		end
	end
end

-- Engine queries remain local to the weapon. Global traces and collisions stay
-- untouched; props and BSP outside the scanned cube still block editing.
function V.ResolveSculptTrace(r, start, direction, reach, trace, physical, checkpoint)
	local finish = start + direction * reach
	physical = physical or trace(start, finish, false)
	if not r then
		return physical
	end
	-- Untouched terrain is exactly the native BSP; don't build voxel cells
	-- just to aim. Actual strokes keep fresh authoritative queries below.
	if r.revision == 0 and not r.modifiedChunks then
		if
			physical.Hit
			and physical.HitWorld
			and not physical.HitSky
			and not physical.StartSolid
			and V.InScanCube(r, physical.HitPos)
		then
			physical.VoxelScan = true
			physical.ScanRegion = r
			physical.Distance = (physical.HitPos - start):Length()
		end
		return physical
	end
	local voxel = V.TraceScanRegion(r, start, direction, reach, nil, checkpoint)
	local blocker = physical
	if
		(
			physical.HitWorld
			and physical.Hit
			and physical.HitTexture ~= "**studio**"
			and V.InScanCube(r, physical.HitPos)
		) or (physical.StartSolid and V.InScanCube(r, start))
	then
		blocker = trace(start, finish, true)
		local _, exit = V.CubeRayInterval(r, start, direction)
		if exit and exit < reach then
			local outside = trace(start + direction * (exit + 0.05), finish, false)
			if
				outside.Hit and (not blocker.Hit or outside.HitPos:DistToSqr(start) < blocker.HitPos:DistToSqr(start))
			then
				blocker = outside
			end
		end
	end
	if voxel and (not blocker.Hit or voxel.Distance ^ 2 <= blocker.HitPos:DistToSqr(start) + 0.01) then
		return voxel
	end
	return blocker
end

function V.TraceSculpt(ply, r, reach, checkpoint, start, direction)
	return V.ResolveSculptTrace(
		r,
		start or ply:GetShootPos(),
		direction or ply:GetAimVector(),
		reach,
		function(start, finish, ignoreWorld)
			return util.TraceLine({
				start = start,
				endpos = finish,
				filter = function(ent)
					return ent ~= ply and ent:GetClass() ~= "vm_voxel_collider"
				end,
				mask = MASK_SOLID,
				ignoreworld = ignoreWorld,
			})
		end,
		nil,
		checkpoint
	)
end

-- HUD/render hooks only request a display trace. Cold BSP cells can require
-- clipping, so evaluate them cooperatively in Think, never on the render stack.
-- The last completed display trace is shared; server actions remain fresh.
local preview, previewJob
function V.TraceSculptPreview(ply, r, reach)
	local frame = FrameNumber()
	local revision = r and r.revision
	if
		not preview
		or preview.ply ~= ply
		or preview.region ~= r
		or preview.revision ~= revision
		or preview.reach ~= reach
	then
		preview = { ply = ply, region = r, revision = revision, reach = reach, trace = {} }
		previewJob = nil
	end
	if preview.frame ~= frame and not previewJob and not preview.failed then
		preview.frame = frame
		local start, direction = ply:GetShootPos(), ply:GetAimVector()
		if
			preview.start
			and preview.start:DistToSqr(start) < 0.000001
			and preview.direction:DistToSqr(direction) < 1e-12
		then
			return preview.trace
		end
		local job = { target = preview, start = start, direction = direction }
		job.thread = coroutine.create(function()
			return V.TraceSculpt(ply, r, reach, function()
				if SysTime() >= job.deadline then
					coroutine.yield()
				end
			end, job.start, job.direction)
		end)
		previewJob = job
	end
	return preview.trace
end
function V.ResumeSculptPreview(deadline)
	local job = previewJob
	if not job then
		return
	end
	if job.target.region and job.target.region.revision ~= job.target.revision then
		previewJob = nil
		return
	end
	job.deadline = deadline
	local ok, result = coroutine.resume(job.thread)
	if not ok then
		preview.failed = true
		previewJob = nil
		ErrorNoHalt("[GVoxel] Viseur suspendu : " .. tostring(result) .. "\n")
	elseif coroutine.status(job.thread) == "dead" then
		preview.trace = result or {}
		preview.start = job.start
		preview.direction = job.direction
		previewJob = nil
	end
end
if CLIENT then
	hook.Add("Think", "GVoxel.CursorTrace", function()
		V.ResumeSculptPreview(SysTime() + 0.001)
	end)
end

function V.CloneScanField(r, checkpoint)
	local copy = {}
	for key, value in pairs(r) do
		if key ~= "values" and key ~= "chunks" and key ~= "terrainCache" then
			copy[key] = value
		end
	end
	-- Density nodes are private; immutable geometry and untouched cell caches
	-- remain shared. Yield while copying, before any mesh/physics is exposed.
	copy.values = {}
	for i, value in ipairs(r.values) do
		copy.values[i] = value
		if checkpoint and i % 512 == 0 then
			checkpoint()
		end
	end
	copy.chunks = {}
	if r.terrainCache and r.terrainCache.revision == r.revision then
		copy.terrainCache = { revision = r.revision }
		for kind, chunks in pairs(r.terrainCache) do
			if kind ~= "revision" then
				copy.terrainCache[kind] = {}
				for key, cells in pairs(chunks) do
					copy.terrainCache[kind][key] = cells
				end
			end
		end
	end
	if r.featureTouched then
		copy.featureTouched = {}
		for key, value in pairs(r.featureTouched) do
			copy.featureTouched[key] = value
		end
	end
	if r.bspEdits then
		copy.bspEdits = {}
		for i, value in ipairs(r.bspEdits) do
			copy.bspEdits[i] = value
		end
		copy.bspEditBins = {}
		for key, value in pairs(r.bspEditBins) do
			copy.bspEditBins[key] = value
		end
		copy.bspCellEditBins = {}
		for key, value in pairs(r.bspCellEditBins or {}) do
			copy.bspCellEditBins[key] = value
		end
	end
	return copy
end

-- The sole field publication boundary, shared by client and server.
function V.PublishScanField(region, field)
	for _, key in ipairs({
		"values",
		"modifiedChunks",
		"featureTouched",
		"bspEdits",
		"bspEditBins",
		"bspCellEditBins",
		"bspDensityBase",
		"revision",
		"terrainCache",
	}) do
		region[key] = field[key]
	end
end
