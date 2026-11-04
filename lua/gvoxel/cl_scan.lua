local V = GVoxel
if V.ReleaseClientScan then
	V.ReleaseClientScan()
elseif V.SetVisualRegion then
	V.SetVisualRegion(nil)
end
local scan = nil
local buildQueue = {}
local editQueue = {}
local editWork = nil
local meshStats = {
	slices = 0,
	total = 0,
	max = 0,
	chunks = 0,
	strokes = 0,
	latency = 0,
	transactions = 0,
	lastCPU = 0,
	lastPeak = 0,
	lastFrames = 0,
	lastFramePeak = 0,
}
local editBudget =
	CreateClientConVar("vm_edit_budget_ms", "3", true, false, "Budget CPU souple de reconstruction par image", 0.5, 8)

function V.GetClientScanState()
	return scan
end
function V.GetClientEditStats()
	local copy = {}
	for key, value in pairs(meshStats) do
		copy[key] = value
	end
	return copy
end

function V.ClientSculptBusy()
	return editWork ~= nil or #editQueue > 0
end

function V.GetClientScanRegion()
	return scan and scan.visualReady and scan.region or nil
end

concommand.Add("vm_geometry_stats", function()
	local r = scan and scan.region
	if not r then
		print("[GVoxel] Aucun releve.")
		return
	end
	local fallback = 0
	for _ in pairs(r.bspFallback or {}) do
		fallback = fallback + 1
	end
	print(
		string.format(
			"[GVoxel] Geometrie : %s ; revision %d ; %d operations CSG.",
			r.bsp
					and (fallback > 0 and ("BSP exact + " .. fallback .. " cellules de secours relief/ciel") or "faces BSP exactes")
				or "reconstruction par rayons (BSP indisponible)",
			r.revision,
			#(r.bspEdits or {})
		)
	)
end)

local function destroyChunk(chunk)
	V.ReleaseChunkMeshes(chunk)
end

local function buildChunk(r, item, checkpoint)
	local vertices = V.BuildChunk(r, item.x, item.y, item.z, checkpoint)
	local chunk = { origin = r.origin + Vector(item.x, item.y, item.z) * (8 * r.step), geometryRevision = r.revision }
	chunk.low = chunk.origin
	chunk.high = chunk.origin + Vector(8, 8, 8) * r.step
	chunk.transform = Matrix()
	chunk.transform:Translate(chunk.origin)
	if #vertices > 0 then
		if V.BuildSurfaceBatches then
			chunk.batches = V.BuildSurfaceBatches(r, item, vertices, checkpoint)
			chunk.mesh = chunk.batches[1] and chunk.batches[1].mesh
		else
			chunk.mesh = Mesh(V.ScanSurfaceMaterial)
			if checkpoint then
				checkpoint(chunk.mesh)
			end
			chunk.mesh:BuildFromTriangles(vertices)
			if checkpoint then
				checkpoint()
			end
		end
		local probe = vertices[1]
		for _, vertex in ipairs(vertices) do
			if vertex.normal.z > probe.normal.z then
				probe = vertex
			end
		end
		chunk.lightOrigin = chunk.origin + probe.pos + probe.normal * (r.step * 0.5 + 4)
		local source = chunk.batches and chunk.batches[1] and chunk.batches[1].source
		if source then
			-- Newly excavated geometry lies inside the old BSP, where light
			-- probes can return black. Inherit the original exposed lighting.
			chunk.lightOrigin = source.lightOrigin or source.point + source.frame.normal * (r.step * 0.5 + 4)
		end
	end
	return chunk
end

local function newJob(r, item)
	local job = { item = item, meshes = {} }
	job.thread = coroutine.create(function()
		local function checkpoint(mesh)
			if mesh then
				job.meshes[#job.meshes + 1] = mesh
			end
			if SysTime() >= (job.deadline or 0) then
				coroutine.yield()
			end
		end
		local chunk = buildChunk(r, item, checkpoint)
		if V.PrepareCollisionChunk then
			V.PrepareCollisionChunk(r, item.x, item.y, item.z, checkpoint)
		end
		return chunk
	end)
	return job
end

local function cancelJob(job)
	if not job then
		return
	end
	local meshes = job.meshes
	job.meshes = {}
	job.thread = nil
	for _, mesh in ipairs(meshes) do
		V.ReleaseMesh(mesh)
	end
end

local function resumeJob(job, deadline)
	if not job.thread or coroutine.status(job.thread) == "dead" then
		cancelJob(job)
		return nil, false, "Tache de maillage deja terminee ou annulee", 0
	end
	job.deadline = deadline
	local begin = SysTime()
	local ok, result = coroutine.resume(job.thread)
	local elapsed = SysTime() - begin
	meshStats.slices = meshStats.slices + 1
	meshStats.total = meshStats.total + elapsed
	meshStats.max = math.max(meshStats.max, elapsed)
	if not ok then
		cancelJob(job)
		return nil, false, result, elapsed
	end
	if coroutine.status(job.thread) == "dead" then
		meshStats.chunks = meshStats.chunks + 1
		job.meshes = {}
		job.thread = nil
		return result, true, nil, elapsed
	end
	return nil, false, nil, elapsed
end

local function discard()
	local previous, work = scan, editWork
	scan = nil
	editWork = nil
	buildQueue = {}
	editQueue = {}
	-- No render or Think callback may retain a released chunk, even if a
	-- later cleanup step fails. Detach all displayed and staged ownership.
	local chunks = previous and previous.region.chunks or {}
	if previous then
		previous.region.chunks = {}
	end
	V.SetVisualRegion(nil)
	if previous then
		cancelJob(previous.buildJob)
		previous.buildJob = nil
		previous.geometryJob = nil
		previous.lightingJob = nil
	end
	for _, chunk in pairs(chunks) do
		destroyChunk(chunk)
	end
	if work then
		cancelJob(work.task)
		work.task = nil
		work.applyJob = nil
		local staged = work.chunks
		work.chunks = {}
		for _, chunk in pairs(staged) do
			destroyChunk(chunk)
		end
	end
	if V.ReleaseSurfaceCapture and previous then
		V.ReleaseSurfaceCapture(previous.region)
	end
end
V.ReleaseClientScan = discard

local function buildFailed(err)
	local id = scan and scan.region.id
	discard()
	ErrorNoHalt("[GVoxel] Reconstruction annulee : " .. tostring(err) .. "\n")
	if id then
		net.Start("vm_scan_failed")
		net.WriteUInt(id, 16)
		net.SendToServer()
	end
end

net.Receive("vm_scan_begin", function()
	local id, center, metres = net.ReadUInt(16), net.ReadVector(), net.ReadUInt(6)
	local r
	if metres == 0 then
		local origin, step = net.ReadVector(), net.ReadFloat()
		local cells = Vector(net.ReadUInt(6), net.ReadUInt(6), net.ReadUInt(6))
		if
			step ~= step
			or step <= 0
			or step > V.CustomMaxSide / 32
			or cells.x < 2
			or cells.y < 2
			or cells.z < 2
			or cells.x > 32
			or cells.y > 32
			or cells.z > 32
		then
			return
		end
		r = V.NewScanRegion(id, center, 16)
		r.custom = true
		r.metres = 0
		r.origin = origin
		r.step = step
		r.side = step * 32
		r.cells = cells
		r.extent = cells * step
		r.base = origin + r.extent / 2
	else
		r = V.NewScanRegion(id, center, metres)
	end
	discard()
	scan = { region = r, phase = 0, ratio = 0, solids = 0, rays = 0, elapsed = 0, received = 0, built = 0, seen = {} }
	if V.BeginSurfaceCapture then
		V.BeginSurfaceCapture(scan.region)
	end
end)

net.Receive("vm_scan_progress", function()
	local id, phase, ratio = net.ReadUInt(16), net.ReadUInt(2), net.ReadUInt(8) / 255
	local solids, rays, elapsed = net.ReadUInt(16), net.ReadUInt(32), net.ReadFloat()
	if not scan or scan.region.id ~= id then
		return
	end
	if phase == 3 then
		discard()
		return
	end
	scan.phase, scan.ratio, scan.solids, scan.rays, scan.elapsed = phase, ratio, solids, rays, elapsed
end)

net.Receive("vm_scan_chunk", function()
	local id = net.ReadUInt(16)
	local cx, cy, cz = net.ReadUInt(2), net.ReadUInt(2), net.ReadUInt(2)
	if not scan or scan.region.id ~= id then
		return
	end
	local r = scan.region
	for z = cz * 8 - 1, cz * 8 + 9 do
		for y = cy * 8 - 1, cy * 8 + 9 do
			for x = cx * 8 - 1, cx * 8 + 9 do
				local value = net.ReadInt(16) / 64
				if x >= 0 and x <= 32 and y >= 0 and y <= 32 and z >= 0 and z <= 32 then
					r.values[V.Index(x, y, z, r)] = value
				end
			end
		end
	end
	local key = V.ChunkKey(cx, cy, cz)
	if not scan.seen[key] then
		scan.seen[key] = true
		scan.received = scan.received + 1
		buildQueue[#buildQueue + 1] = { x = cx, y = cy, z = cz, key = key }
	end
end)

net.Receive("vm_scan_features", function()
	local id, count = net.ReadUInt(16), net.ReadUInt(8)
	if not scan or scan.region.id ~= id then
		return
	end
	scan.exactBSP = net.ReadBool()
	local planes = {}
	for i = 1, count do
		planes[i] = {
			normal = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat()),
			distance = net.ReadFloat(),
			low = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat()),
			high = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat()),
		}
		local axis = V.FeatureAxis(planes[i].normal)
		if axis then
			local name = ({ "x", "y", "z" })[axis]
			local sign = planes[i].normal[name] > 0 and 1 or -1
			planes[i].axis = axis
			planes[i].sign = sign
			planes[i].distance = planes[i].distance * sign
			planes[i].normal = nil
		end
	end
	scan.region.featurePlanes = planes
	scan.featuresReady = true
end)

net.Receive("vm_scan_edit", function()
	local id, revision = net.ReadUInt(16), net.ReadUInt(16)
	local center, radius, adding, seed = net.ReadVector(), net.ReadUInt(16), net.ReadBool(), net.ReadUInt(16)
	local floorZ = net.ReadBool() and net.ReadFloat() or nil
	if not scan or scan.region.id ~= id then
		return
	end
	if revision ~= (scan.receivedRevision or 0) + 1 then
		buildFailed("Modification hors sequence : vm_resync pour retenter")
		return
	end
	scan.receivedRevision = revision
	scan.permittedRevision = revision
	if scan.preparingRevision == revision then
		scan.preparingRevision = nil
		return
	end
	editQueue[#editQueue + 1] = {
		revision = revision,
		center = center,
		radius = radius,
		adding = adding,
		seed = seed,
		floorZ = floorZ,
		receivedAt = SysTime(),
	}
end)

net.Receive("vm_scan_prepare", function()
	local id, revision = net.ReadUInt(16), net.ReadUInt(16)
	local center, radius, adding, seed = net.ReadVector(), net.ReadUInt(16), net.ReadBool(), net.ReadUInt(16)
	local floorZ = net.ReadBool() and net.ReadFloat() or nil
	if
		not scan
		or scan.region.id ~= id
		or not scan.visualReady
		or editWork
		or #editQueue > 0
		or scan.preparingRevision
		or revision ~= (scan.receivedRevision or 0) + 1
	then
		return
	end
	scan.preparingRevision = revision
	editQueue[1] = {
		revision = revision,
		center = center,
		radius = radius,
		adding = adding,
		seed = seed,
		floorZ = floorZ,
		receivedAt = SysTime(),
	}
end)

net.Receive("vm_scan_abort", function()
	local id, revision = net.ReadUInt(16), net.ReadUInt(16)
	if not scan or scan.region.id ~= id or scan.preparingRevision ~= revision then
		return
	end
	scan.preparingRevision = nil
	editQueue = {}
	if editWork then
		cancelJob(editWork.task)
		for _, chunk in pairs(editWork.chunks) do
			destroyChunk(chunk)
		end
		editWork = nil
	end
end)

hook.Add("Think", "GVoxel.ScanMeshes", function()
	if not scan then
		return
	end
	if not scan.featuresReady then
		return
	end
	local deadline = SysTime() + editBudget:GetFloat() / 1000
	if scan.exactBSP and not scan.geometryPrepared then
		local data, done, err = V.GetBSPGeometry()
		if not done then
			return
		end
		if not data then
			buildFailed(err or "Geometrie BSP differente du serveur")
			return
		end
		scan.geometryJob = scan.geometryJob
			or coroutine.create(function()
				-- Density samples arrive from the server. Only geometric/material
				-- bins are needed here, not another set of sampling columns.
				local function checkpoint()
					if SysTime() >= scan.geometryDeadline then
						coroutine.yield()
					end
				end
				local result = V.PrepareBSPRegion(scan.region, data, checkpoint, false)
				if V.PrepareVehicleExterior then
					V.PrepareVehicleExterior(scan.region, data, checkpoint)
				end
				return result
			end)
		scan.geometryDeadline = deadline
		local ok, result = coroutine.resume(scan.geometryJob)
		if not ok then
			buildFailed(result)
			return
		end
		if coroutine.status(scan.geometryJob) ~= "dead" then
			return
		end
		if not result then
			buildFailed("Preparation du terrain incomplete")
			return
		end
		scan.geometryPrepared = true
		scan.geometryJob = nil
	end
	while (scan.buildJob or #buildQueue > 0) and SysTime() < deadline do
		local r = scan.region
		scan.buildJob = scan.buildJob or newJob(r, table.remove(buildQueue, 1))
		local chunk, done, err = resumeJob(scan.buildJob, deadline)
		if err then
			buildFailed(err)
			return
		end
		if done then
			r.chunks[scan.buildJob.item.key] = chunk
			scan.built = scan.built + 1
			scan.buildJob = nil
		end
	end
	if not scan.sourcesFrozen and scan.featuresReady and V.MaskReady(scan) then
		if V.FreezeSurfaceSources then
			V.FreezeSurfaceSources(scan.region)
		end
		scan.sourcesFrozen = true
	end
	if
		not scan.visualReady
		and scan.phase == 2
		and scan.featuresReady
		and V.MaskReady(scan)
		and (not V.SurfaceCaptureReady or V.SurfaceCaptureReady(scan.region))
	then
		if V.PrepareCutLighting and not scan.region.cutLighting then
			scan.lightingJob = scan.lightingJob
				or coroutine.create(function()
					V.PrepareCutLighting(scan.region, function()
						if SysTime() >= scan.lightingDeadline then
							coroutine.yield()
						end
					end)
				end)
			scan.lightingDeadline = deadline
			local ok, err = coroutine.resume(scan.lightingJob)
			if not ok then
				buildFailed(err)
				return
			end
			if coroutine.status(scan.lightingJob) ~= "dead" then
				return
			end
			scan.lightingJob = nil
		end
		V.SetVisualRegion(scan.region)
		scan.visualReady = true
		net.Start("vm_scan_ready")
		net.WriteUInt(scan.region.id, 16)
		net.WriteUInt(0, 16)
		net.SendToServer()
	end
	if not scan.visualReady then
		return
	end
	local editFrameStarted = SysTime()
	-- Stage field and meshes together. Keep the old region visible/traceable
	-- until every affected chunk is ready, then commit this bounded group.
	-- New arrivals cannot starve the in-flight transaction.
	if not editWork and #editQueue > 0 then
		local started = SysTime()
		-- Freeze this transaction. New strokes wait for the next one instead
		-- of repeatedly cancelling the same not-yet-displayed excavation.
		editWork = {
			jobs = {},
			chunks = {},
			edits = editQueue,
			receivedAt = editQueue[1].receivedAt,
			cpu = SysTime() - started,
			peak = 0,
		}
		editQueue = {}
	end
	if editWork then
		editWork.frames = (editWork.frames or 0) + 1
		while (editWork.applyJob or #editWork.edits > 0) and SysTime() < deadline do
			if not editWork.applyJob then
				local edit = table.remove(editWork.edits, 1)
				local job = { edit = edit }
				job.thread = coroutine.create(function()
					local function checkpoint()
						if SysTime() >= job.deadline then
							coroutine.yield()
						end
					end
					if not editWork.field then
						editWork.field = V.CloneScanField(scan.region, checkpoint)
					end
					return V.ApplyBrush(editWork.field, edit.center, edit.radius, edit.adding, edit.seed, function()
						if SysTime() >= job.deadline then
							coroutine.yield()
						end
					end, edit.floorZ)
				end)
				editWork.applyJob = job
				meshStats.strokes = meshStats.strokes + 1
			end
			local job = editWork.applyJob
			job.deadline = deadline
			local started = SysTime()
			local ok, dirty, changed = coroutine.resume(job.thread)
			local elapsed = SysTime() - started
			editWork.cpu = editWork.cpu + elapsed
			editWork.peak = math.max(editWork.peak, elapsed)
			if not ok then
				buildFailed(dirty)
				return
			end
			if coroutine.status(job.thread) == "dead" then
				local cache = editWork.field.terrainCache
				-- A replay can be numerically redundant. Advancing its wire
				-- revision must not discard all prepared, unchanged hulls.
				if not changed and cache and cache.revision == editWork.field.revision then
					cache.revision = job.edit.revision
				end
				editWork.field.revision = job.edit.revision
				editWork.applyJob = nil
				for key, c in pairs(dirty) do
					if editWork.task and editWork.task.item.key == key then
						cancelJob(editWork.task)
						editWork.task = nil
					end
					destroyChunk(editWork.chunks[key])
					editWork.chunks[key] = nil
					editWork.jobs[key] = { key = key, x = c[1], y = c[2], z = c[3] }
				end
			end
		end
		while
			not editWork.applyJob
			and #editWork.edits == 0
			and (editWork.task or next(editWork.jobs))
			and SysTime() < deadline
		do
			if not editWork.task then
				local key, item = next(editWork.jobs)
				editWork.jobs[key] = nil
				editWork.task = newJob(editWork.field, item)
			end
			local chunk, done, err, elapsed = resumeJob(editWork.task, deadline)
			editWork.cpu = editWork.cpu + elapsed
			editWork.peak = math.max(editWork.peak, elapsed)
			if err then
				buildFailed(err)
				return
			end
			if done then
				editWork.chunks[editWork.task.item.key] = chunk
				editWork.task = nil
			end
		end
		if #editWork.edits == 0 and not editWork.applyJob and not editWork.task and not next(editWork.jobs) then
			editWork.preparedAt = editWork.preparedAt or SysTime()
		end
		if editWork.preparedAt and editWork.field.revision <= (scan.permittedRevision or 0) then
			local committedAt = SysTime()
			local r = scan.region
			for key, chunk in pairs(editWork.chunks) do
				destroyChunk(r.chunks[key])
				r.chunks[key] = chunk
			end
			V.PublishScanField(r, editWork.field)
			-- The server keeps the preceding field until this display swap.
			-- Player hulls are derived only along actual collision queries.
			net.Start("vm_scan_ready")
			net.WriteUInt(r.id, 16)
			net.WriteUInt(r.revision, 16)
			net.SendToServer()
			local committedCost = SysTime() - committedAt
			editWork.cpu = editWork.cpu + committedCost
			editWork.peak = math.max(editWork.peak, committedCost)
			meshStats.latency = SysTime() - editWork.receivedAt
			meshStats.transactions = meshStats.transactions + 1
			meshStats.lastCPU = editWork.cpu * 1000
			meshStats.lastPeak = editWork.peak * 1000
			meshStats.lastFrames = editWork.frames
			meshStats.lastPreparation = (editWork.preparedAt - editWork.receivedAt) * 1000
			meshStats.lastPermitWait = (SysTime() - editWork.preparedAt) * 1000
			meshStats.lastFramePeak = math.max(editWork.framePeak or 0, SysTime() - editFrameStarted) * 1000
			editWork = nil
		else
			editWork.framePeak = math.max(editWork.framePeak or 0, SysTime() - editFrameStarted)
		end
	end
end)

hook.Add("ShutDown", "GVoxel.ReleaseScan", discard)
concommand.Add("vm_scan_clear", function()
	net.Start("vm_scan_cancel")
	net.SendToServer()
end)
concommand.Add("vm_edit_stats", function()
	local pending = 0
	for _ in pairs(editWork and editWork.jobs or {}) do
		pending = pending + 1
	end
	print(
		string.format(
			"[GVoxel] Reconstruction : %d coups | %d blocs | %d tranches | moyenne %.3f ms | maximum %.3f ms | attente %d coups / %d blocs | dernier affichage %.1f ms | revision %d/%d | dernier CPU %.2f ms / pic tranche %.2f ms | %d images / pic calcul par image %.2f ms",
			meshStats.strokes,
			meshStats.chunks,
			meshStats.slices,
			meshStats.total * 1000 / math.max(1, meshStats.slices),
			meshStats.max * 1000,
			#editQueue + (editWork and #editWork.edits or 0),
			pending + (editWork and editWork.task and 1 or 0),
			meshStats.latency * 1000,
			scan and scan.region.revision or 0,
			scan and scan.receivedRevision or 0,
			meshStats.lastCPU,
			meshStats.lastPeak,
			meshStats.lastFrames,
			meshStats.lastFramePeak
		)
	)
	print(
		string.format(
			"[GVoxel] Preparation client %.2f ms reels | attente autorisation physique %.2f ms (preparation client/serveur en parallele)",
			meshStats.lastPreparation or 0,
			meshStats.lastPermitWait or 0
		)
	)
end)
concommand.Add("vm_diagnose", function()
	for _, command in ipairs({
		"vm_geometry_stats",
		"vm_edit_stats",
		"vm_collision_stats",
		"vm_collision_server_stats",
		"vm_render_stats",
		"vm_texture_stats",
		"vm_sky_stats",
		"vm_visibility_stats",
		"vm_prop_stats",
		"vm_vehicle_stats",
	}) do
		RunConsoleCommand(command)
	end
end)

concommand.Add("vm_collision_stats", function()
	local r = scan and scan.region
	if not r then
		print("[GVoxel] Aucun releve.")
		return
	end
	local stats = V.CollisionCacheStats(r)
	print(
		string.format(
			"[GVoxel] Collisions client a la demande : %d / %d cellules utilisees | %d solides / %d axes | revision %d | modification en preparation : %s",
			stats.cells,
			V.RegionCells(r, "x") * V.RegionCells(r, "y") * V.RegionCells(r, "z"),
			stats.solids,
			stats.axes,
			r.revision,
			V.ClientSculptBusy() and "oui" or "non"
		)
	)
end)

local function synchronize()
	net.Start("vm_scan_sync")
	net.SendToServer()
end
concommand.Add("vm_resync", synchronize)
-- First valid client Think works both after join and after Lua refresh.
local announced = false
hook.Add("Think", "GVoxel.JoinSession", function()
	if not announced and IsValid(LocalPlayer()) then
		announced = true
		synchronize()
	end
end)
