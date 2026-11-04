-- Scan and edit jobs. Geometry work yields; no geometry runs in net/weapon hooks.
local V = GVoxel
local nextID = 0
function V.AllocateZoneID()
    repeat nextID=nextID%65535+1 until not V.GetScanSession(nextID)
    return nextID
end
local scanBudget =
	CreateConVar("vm_scan_budget_ms", "3", FCVAR_ARCHIVE, "Budget scanner et replication par tick (ms)", 0.5, 8)
local editBudget = CreateConVar(
	"vm_server_edit_budget_ms",
	"2",
	FCVAR_ARCHIVE,
	"Budget calcul des modifications par tick (ms)",
	0.5,
	4
)
local function worldTrace(a, b)
	return util.TraceLine({
		start = a,
		endpos = b,
		mask = MASK_SOLID_BRUSHONLY,
		filter = function(ent)
			return ent:IsWorld()
		end,
	})
end
local function release(scan)
	for ply in pairs(scan.peers) do
		if IsValid(ply) and V.ReleaseVoxelMovement and not V.ReleaseVoxelMovement(ply) then
			return false
		end
	end
	if V.ReleasePropRegion and not V.ReleasePropRegion(scan.region) then
		return false
	end
	if V.ReleaseVoxelVisibility then
		V.ReleaseVoxelVisibility(scan.region)
	end
	V.SendScanProgress(scan, 3, 0)
	if V.RemoveScanSession then V.RemoveScanSession(scan) else V.SetScanSession(nil) end
	return true
end
function V.ShutdownServerScan()
    local list={}
    for _, scan in pairs(V.GetScanSessions and V.GetScanSessions() or {V.GetScanSession()}) do list[#list+1]=scan end
    for _, scan in ipairs(list) do if not release(scan) then return false end end
    return true
end
function V.CancelScan(ply, id)
    if not V.CanManageScan(ply) then return end
	local scan = V.GetScanSession(id or (ply.GetPos and ply:GetPos()))
	if not scan or not V.CanManageScan(ply) then
		return
	end
	if not release(scan) then
		V.Notify(ply, "Zone encore occupee : rejoindre une sortie avant de restaurer le BSP.")
	end
end
function V.PlaceRegion(ply, metres, low, high)
	local custom = metres == 0
	if not V.CanManageScan(ply) or (not custom and not V.ValidScanSize(metres)) then
		return
	end
	if (ply.VMNextScan or 0) > CurTime() then
		return
	end
    if V.ZoneRestorePending then V.Notify(ply,"Chargement de la zone sauvegardee en cours.") return end
    local count=0
    for _, existing in pairs(V.GetScanSessions and V.GetScanSessions() or {}) do
        count=count+1
        if not existing.completed then V.Notify(ply,"Une analyse est deja en cours.") return end
    end
    if count >= 1 then V.Notify(ply,"Une seule zone est autorisee. Retirer la zone actuelle avant d'en creer une autre.") return end
	local weapon = ply:GetActiveWeapon()
	if not V.IsVoxelTool(weapon) then
		return
	end
	local tr, r
	if custom then
		local bounds, err = V.CustomBoxBounds(low, high)
		if not bounds then
			V.Notify(ply, err)
			return
		end
		if ply:GetShootPos():DistToSqr(bounds.base) > 4096 ^ 2 then
			V.Notify(ply, "Boite trop eloignee (4096 unites maximum).")
			return
		end
	else
		tr = V.Trace(ply, 2048)
		if not tr.HitWorld or tr.HitSky then
			V.Notify(ply, "Viser une surface de la map.")
			return
		end
	end
	ply.VMNextScan = CurTime() + 3
	nextID = V.AllocateZoneID()
	r = custom and V.NewCustomScanRegion(nextID, low, high)
		or V.NewScanRegion(nextID, V.SnapScanPosition(tr.HitPos), metres)
	r.id = nextID
    for _, existing in pairs(V.GetScanSessions and V.GetScanSessions() or {}) do
        if V.ZonesOverlap and V.ZonesOverlap(r,existing.region) then
            V.Notify(ply,"Cette zone chevauche une zone existante.") return
        end
    end
	local scan = { ply = ply, region = r, index = 0, solids = 0, rays = 0, started = SysTime(), nextProgress = 0 }
	scan.trace, scan.traceStats, scan.terrainSign = V.ColumnScanTrace(r, worldTrace, function(p)
		return bit.band(util.PointContents(p), 16395) ~= 0
	end)
	weapon:SetZoneMetres(metres)
	V.BeginScanSession(scan)
end
function V.RestoreCachedZone(record, ply)
    local r=V.NewScanRegion(V.AllocateZoneID(),Vector(unpack(record.base)),record.metres==32 and 32 or 16)
    if record.metres==0 then
        r.custom=true r.metres=0 r.origin=Vector(unpack(record.origin)) r.step=record.step
        r.side=r.step*32 r.cells=Vector(unpack(record.cells)) r.extent=r.cells*r.step
        r.base=r.origin+r.extent/2
    end
    local count=0
    for _, existing in pairs(V.GetScanSessions()) do
        count=count+1
        if V.ZonesOverlap(r,existing.region) then return false,"Zone deja active ou chevauchement." end
    end
    if count>=V.MaxZones then return false,"Limite de zones atteinte." end
    local scan={ply=ply,region=r,index=0,solids=0,rays=0,started=SysTime(),nextProgress=0,
        cachedRecord=record,traceStats={rays=0},savedKey=record.key,displayName=record.name}
    V.BeginScanSession(scan)
    return scan
end
net.Receive("vm_scan_request", function(_, ply)
	V.PlaceRegion(ply, net.ReadUInt(6))
end)
net.Receive("vm_scan_custom", function(_, ply)
	local low, high = net.ReadVector(), net.ReadVector()
	V.PlaceRegion(ply, 0, low, high)
end)
net.Receive("vm_scan_cancel", function(_, ply)
	V.CancelScan(ply)
end)
net.Receive("vm_scan_settings", function(_, ply)
	local metres, radius = net.ReadUInt(6), net.ReadUInt(7)
	if not V.ValidScanSize(metres) or radius < 24 or radius > 80 or not V.CanEdit(ply, V.GetServerScanRegion()) then
		return
	end
	if (ply.VMNextSettings or 0) > CurTime() then
		return
	end
	local weapon = ply:GetActiveWeapon()
	if not V.IsVoxelTool(weapon) then
		return
	end
	ply.VMNextSettings = CurTime() + 0.1
	weapon:SetZoneMetres(metres)
	weapon:SetBrushRadius(radius)
end)

function V.CommitScanEdit(scan)
	local work = scan.editWork
	if not work or not work.sent or work.thread or not V.ScanPeersReady(scan, work.field.revision) then
		return
	end
	if V.PropEditReady and not V.PropEditReady(scan.region, work.field.revision) then
		return
	end
	local r = scan.region
	local chunks = 0
	for _ in pairs(work.dirty) do
		chunks = chunks + 1
	end
	local cooks = V.PropState and V.PropState.cookStats
	V.PublishScanField(r, work.field)
	if V.RefreshVoxelVisibility then
		V.RefreshVoxelVisibility(r)
	end
	if V.CommitPropEdit then
		V.CommitPropEdit(r)
	elseif V.QueuePropColliders then
		V.QueuePropColliders(r, work.dirty)
	end
	r.editStats = {
		total = work.total or 0,
		peak = work.peak or 0,
		latency = SysTime() - work.started,
		prepare = work.preparedAt and work.preparedAt - work.started or 0,
		physicsWait = work.sentAt and work.sentAt - (work.preparedAt or work.started) or 0,
		displayWait = work.sentAt and SysTime() - work.sentAt or 0,
		phases = work.phases,
		chunks = chunks,
		nativeCount = cooks and cooks.count - (work.nativeCount or cooks.count) or 0,
		nativeCPU = cooks and cooks.total - (work.nativeCPU or cooks.total) or 0,
		nativeMeshCPU = cooks and (cooks.meshTotal or 0) - (work.nativeMeshCPU or cooks.meshTotal or 0) or 0,
		source = work.source or "tool",
		radius = work.radius,
		floorZ = work.floorZ,
	}
	scan.editWork = nil
    if V.MarkZoneCacheDirty then V.MarkZoneCacheDirty(scan) end
end
local function startEdit(scan, work, prepare)
	work.started = SysTime()
	local cooks = V.PropState and V.PropState.cookStats
	work.nativeCount = cooks and cooks.count or 0
	work.nativeCPU = cooks and cooks.total or 0
	work.nativeMeshCPU = cooks and cooks.meshTotal or 0
	work.phases = {}
	work.thread = coroutine.create(function()
		local phase, phaseStarted = "trace", SysTime()
		local function account()
			local now = SysTime()
			work.phases[phase] = (work.phases[phase] or 0) + now - phaseStarted
			phaseStarted = now
		end
		local function checkpoint()
			if SysTime() >= work.deadline then
				account()
				coroutine.yield()
				phaseStarted = SysTime()
			end
		end
		local function nextPhase(name)
			account()
			phase = name
		end
		if prepare and not prepare(work, checkpoint) then
			scan.editWork = nil
			return
		end
		nextPhase("clone")
		work.field = V.CloneScanField(scan.region, checkpoint)
		checkpoint()
		nextPhase("brush")
		local dirty, changed =
			V.ApplyBrush(work.field, work.center, work.radius, work.adding, work.seed, checkpoint, work.floorZ)
		if not changed then
			scan.editWork = nil
			return
		end
		work.field.revision = scan.region.revision + 1
		work.dirty = dirty
		account()
		if V.PrepareScanEdit then
			V.PrepareScanEdit(scan, work)
		end
		phase = "collision"
		phaseStarted = SysTime()
		if V.PrepareChangedCollisions then
			V.PrepareChangedCollisions(work.field, dirty, checkpoint)
		end
		nextPhase("stage")
		if V.StagePropEdit then
			V.StagePropEdit(scan.region, work.field, dirty)
		end
		account()
		work.preparedAt = SysTime()
	end)
	scan.editWork = work
end
function V.EditScannedTerrain(ply, radius, adding)
    local scan = V.RayZone and V.GetScanSessions and V.RayZone(V.GetScanSessions(),ply:GetShootPos(),ply:GetAimVector(),V.Reach,
        function(s) return s.completed end) or V.GetScanSession()
	if not scan or not scan.completed then
		return nil
	end
	local r = scan.region
	if
		not V.CanEdit(ply, r)
		or not V.ScanPeersReady(scan, r.revision)
		or scan.editWork
		or (scan.explosions and #scan.explosions > 0)
	then
		return false
	end
	if (r.nextEdit or 0) > CurTime() or r.revision >= V.MaxEdits then
		return false
	end
	radius = V.ScanBrushRadius(r, radius)
	local start, direction = ply:GetShootPos(), ply:GetAimVector()
	startEdit(scan, {}, function(work, checkpoint)
		local tr = V.TraceSculpt(ply, r, V.Reach, checkpoint, start, direction)
		if not tr.VoxelScan then
			return false
		end
		work.center = V.SnapScanPosition(V.BrushCenter(tr, radius, adding))
		work.radius = radius
		work.adding = adding
		if adding and V.BrushIntersectsBody and V.BrushIntersectsBody(work.center, radius) then
			V.Notify(ply, "Ajout bloque : un corps occupe cette zone.")
			return false
		end
		return true
	end)
	r.nextEdit = CurTime() + 0.2
	return true
end
function V.QueueTerrainExplosion(ply, work)
    local scan = work.zoneID and V.GetScanSession(work.zoneID) or V.GetScanSession(work.center)
	if not scan or not scan.completed or (not work.system and (not V.GetServerMovementRegion(ply) or not V.CanEdit(ply, scan.region))) then
		return false
	end
	local r = scan.region
	if r.revision >= V.MaxEdits then
		return false
	end
	local center = work.center
	local radius = math.ceil(work.radius)
	if radius < 1 or radius > 65535 then
		return false
	end
	local distance = 0
	for _, axis in ipairs({ "x", "y", "z" }) do
		local d = math.max(r.origin[axis] - center[axis], 0, center[axis] - r.origin[axis] - V.RegionAxisSize(r, axis))
		distance = distance + d * d
	end
	if distance >= radius * radius then
		return false
	end
	scan.explosions = scan.explosions or {}
	if #scan.explosions >= 16 then
		return false
	end
	work.center = V.SnapScanPosition(center)
	work.radius = radius
	work.adding = false
	work.author = ply
	scan.explosions[#scan.explosions + 1] = work
	return true
end
function V.QueueExplosionCrater(ply, center, radius, seed, source, zoneID, system)
    if not zoneID and V.GetScanSessions and V.ZoneDistanceSquared then
        local accepted=false
        for id,scan in pairs(V.GetScanSessions()) do
            if scan.completed and V.ZoneDistanceSquared(scan.region,center)<radius*radius then
                accepted=V.QueueExplosionCrater(ply,center,radius,seed,source,id,system) or accepted
            end
        end
        return accepted
    end
	return V.QueueTerrainExplosion(ply, {
		center = center,
		radius = math.ceil(radius),
		seed = math.Clamp(math.floor(seed), 1, 65535),
		source = source or "rpg",
        zoneID=zoneID, system=system,
	})
end
function V.QueueRPGCrater(ply, center, radius, seed)
	return V.QueueExplosionCrater(ply, center, math.Clamp(math.floor(radius), 48, 160), seed, "rpg")
end
local function resume(thread, deadline, owner)
	owner.deadline = deadline
	local started = SysTime()
	local ok, result = coroutine.resume(thread)
	local elapsed = SysTime() - started
	owner.total = (owner.total or 0) + elapsed
	owner.peak = math.max(owner.peak or 0, elapsed)
	if not ok then
		return false, result
	end
	return coroutine.status(thread) == "dead"
end
local function sample(scan, deadline)
	local data, done
	if V.GetBSPGeometry then
		data, done = V.GetBSPGeometry()
	end
	if not scan.geometryPrepared then
		if not done and V.GetBSPGeometry then
			return
		end
		if data then
			scan.geometryThread = scan.geometryThread
				or coroutine.create(function()
					V.PrepareBSPRegion(scan.region, data, function()
						if SysTime() >= scan.deadline then
							coroutine.yield()
						end
					end)
					if V.PrepareVehicleExterior then
						V.PrepareVehicleExterior(scan.region, data, function()
							if SysTime() >= scan.deadline then
								coroutine.yield()
							end
						end)
					end
					scan.region.visibilityOrigins = V.BSPVisibilityOrigins(data, scan.region, function()
						if SysTime() >= scan.deadline then
							coroutine.yield()
						end
					end)
					if V.PrepareVoxelVisibility then
						V.PrepareVoxelVisibility(scan.region, function()
							if SysTime() >= scan.deadline then
								coroutine.yield()
							end
						end)
					end
				end)
			local ready, err = resume(scan.geometryThread, deadline, scan)
			if err then
				error(err)
			end
			if not ready then
				return
			end
			scan.geometryThread = nil
		end
		scan.geometryPrepared = true
	end
    if scan.cachedRecord and not scan.cacheReplayed then
        scan.cacheThread=scan.cacheThread or coroutine.create(function()
            local record=scan.cachedRecord
            for i,value in ipairs(record.values) do
                scan.region.values[i-1]=value
                if i%128==0 and SysTime()>=scan.deadline then coroutine.yield() end
            end
            scan.initialValues=scan.region.values
            scan.region.featurePlanes={}
            for _,p in ipairs(record.planes or {}) do
                scan.region.featurePlanes[#scan.region.featurePlanes+1]={normal=Vector(unpack(p.normal)),distance=p.distance,
                    low=Vector(unpack(p.low)),high=Vector(unpack(p.high))}
            end
            for _,stroke in ipairs(record.history) do
                local checkpoint=function() if SysTime()>=scan.deadline then coroutine.yield() end end
                local work=V.CloneScanField(scan.region,checkpoint)
                local center=Vector(unpack(stroke.center))
                V.ApplyBrush(work,center,stroke.radius,stroke.adding,stroke.seed,checkpoint,stroke.floorZ)
                work.revision=scan.region.revision+1
                V.PublishScanField(scan.region,work)
                scan.history[#scan.history+1]={center=center,radius=stroke.radius,adding=stroke.adding,seed=stroke.seed,floorZ=stroke.floorZ}
            end
        end)
        local ready,err=resume(scan.cacheThread,deadline,scan)
        if err then error(err) end
        if not ready then return end
        scan.cacheThread=nil scan.cacheReplayed=true scan.cachedRecord=nil scan.index=33^3
    end
	while scan.index < 33 ^ 3 and SysTime() < deadline do
		local cells = scan.region.cells
		if cells then
			local z = math.floor(scan.index / (33 * 33))
			if z > cells.z then
				scan.index = 33 ^ 3
				break
			end
			local y = math.floor(scan.index / 33) % 33
			if y > cells.y then
				scan.index = (z + 1) * 33 * 33
			elseif scan.index % 33 > cells.x then
				scan.index = scan.index + 33 - scan.index % 33
			end
			if scan.index >= 33 ^ 3 then
				break
			end
		end
		local p, x, y, z = V.ScanPoint(scan.region, scan.index)
		local r = scan.region
		if not r.cells or (x <= r.cells.x and y <= r.cells.y and z <= r.cells.z) then
			local solid = bit.band(util.PointContents(p), 16395) ~= 0
			local value = V.ScanDensity(r, p, solid, scan.trace, scan.terrainSign)
			r.values[V.Index(x, y, z, r)] = value
			if value < 0 then
				scan.solids = scan.solids + 1
			end
		end
		scan.index = scan.index + 1
	end
	scan.rays = scan.traceStats.rays
	if scan.index == 33 ^ 3 then
		scan.trace = nil
		scan.terrainSign = nil
		scan.region.bspTerrainColumns = nil
		scan.snapshot = { id = scan.region.id, nx = 32, ny = 32, nz = 32, values = scan.initialValues or scan.region.values }
		if V.PreparePropRegion then
			V.PreparePropRegion(scan.region, game.GetWorld())
		end
		scan.preparation = coroutine.create(function()
			V.ForChunks(function(x, y, z)
				V.PrepareCollisionChunk(scan.region, x, y, z, function()
					if SysTime() >= scan.deadline then
						coroutine.yield()
					end
				end)
			end, scan.region)
		end)
	end
end
local function tick(scan)
	local deadline = math.min(V.ZoneTickDeadline or math.huge,SysTime() + scanBudget:GetFloat() / 1000)
	if not scan.snapshot then
		sample(scan, deadline)
	end
	if scan.preparation and SysTime() < deadline then
		local done, err = resume(scan.preparation, deadline, scan)
		if err then
			error(err)
		end
		if done then
			scan.preparation = nil
			scan.prepared = true
		end
	end
	local physics = scan.region.propPhysics
	if physics and physics.failed then
		if scan.editWork and not scan.editWork.sent then
			if V.AbortScanPreparation then
				V.AbortScanPreparation(scan, scan.editWork)
			end
			V.AbortPropEdit(scan.region)
			scan.editWork = nil
			ErrorNoHalt("[GVoxel] Preparation physique refusee : modification annulee, terrain conserve.\n")
		else
			error("Preparation VPhysics refusee")
		end
	end
	if scan.prepared and not scan.completed and (not physics or (not physics.jobs and not physics.current)) then
		scan.completed = true
        if V.RefreshVoxelVisibility then V.RefreshVoxelVisibility(scan.region) end
        if V.EnsurePersistentZone then V.EnsurePersistentZone(scan) end
	end
	V.PumpScanReplication(scan, deadline)
	if not scan.completed and SysTime() >= scan.nextProgress then
		V.SendScanProgress(scan, scan.snapshot and 1 or 0, scan.index / (33 ^ 3))
		scan.nextProgress = SysTime() + 0.15
	end
	if not scan.completed then
		return
	end
	local r = scan.region
	if not scan.editWork and scan.explosions and #scan.explosions > 0 and V.ScanPeersReady(scan, r.revision) then
		local work = table.remove(scan.explosions, 1)
		if r.revision < V.MaxEdits and (work.system or V.CanEdit(work.author, r)) then
			startEdit(scan, work, function(_, checkpoint)
				if work.prepare and not work.prepare(work, r, checkpoint) then
					return false
				end
				local e = Vector(work.radius, work.radius, work.radius)
				return V.TraceVoxelHull(r, work.center, work.center, -e, e, checkpoint).StartSolid
			end)
		end
	end
	local work = scan.editWork
	if not work then
		return
	end
	if work.thread then
		local done, err = resume(work.thread, math.min(V.ZoneTickDeadline or math.huge,SysTime() + editBudget:GetFloat() / 1000), work)
		if err then
			if V.AbortScanPreparation then
				V.AbortScanPreparation(scan, work)
			end
			scan.editWork = nil
			if V.AbortPropEdit then
				V.AbortPropEdit(r)
			end
			ErrorNoHalt("[GVoxel] Modification annulee, terrain conserve : " .. tostring(err) .. "\n")
			return
		end
		if not done then
			return
		end
		work.thread = nil
	end
	if scan.editWork ~= work then
		return
	end
	if not work.sent and (not V.PropEditReady or V.PropEditReady(r, work.field.revision)) then
		work.sentAt = SysTime()
		V.PublishScanEdit(scan, work)
	end
	V.CommitScanEdit(scan)
end
hook.Add("Think", "GVoxel.BSPScan", function()
    V.ScanReplicationTick=(V.ScanReplicationTick or 0)+1
    local scan=V.GetScanSession()
    if not scan or scan.failed then return end
    V.ZoneTickDeadline=SysTime()+(scanBudget:GetFloat()+editBudget:GetFloat())/1000
	local ok, err = xpcall(function()
		tick(scan)
	end, debug.traceback)
	if not ok then
		-- Report once. Keep any committed terrain supporting occupants.
		if not scan.failed then
			ErrorNoHalt("[GVoxel] Analyse suspendue : " .. tostring(err) .. "\n")
		end
		scan.failed = true
	end
    V.ZoneTickDeadline=nil
end)
hook.Add("PostCleanupMap", "GVoxel.CancelScans", function()
	V.ShutdownServerScan()
end)
concommand.Add("vm_collision_server_stats", function(ply)
	if IsValid(ply) and not V.CanManageScan(ply) then
		return
	end
	local scan = V.GetScanSession()
	if not scan then
		print("[GVoxel] Aucun releve.")
		return
	end
	local r, work = scan.region, scan.editWork
	local stats, last = V.CollisionCacheStats(r), r.editStats or {}
	print(
		string.format(
			"[GVoxel] Zone partagee %d | revision %d | cellules %d | travail %s | dernier CPU %.2f ms / pic %.2f ms / delai %.2f ms",
			r.id,
			r.revision,
			stats.cells,
			work and (work.sent and "attente clients" or "preparation") or "aucun",
			(last.total or 0) * 1000,
			(last.peak or 0) * 1000,
			(last.latency or 0) * 1000
		)
	)
	local phases = last.phases or {}
	print(
		string.format(
			"[GVoxel] Dernier trou : visee %.2f | copie %.2f | brosse %.2f | SAT %.2f | file physique %.2f ms CPU ; %d chunks ; preparation %.2f | attente physique %.2f | attente affichage %.2f ms reels (client prepare en parallele)",
			(phases.trace or 0) * 1000,
			(phases.clone or 0) * 1000,
			(phases.brush or 0) * 1000,
			(phases.collision or 0) * 1000,
			(phases.stage or 0) * 1000,
			last.chunks or 0,
			(last.prepare or 0) * 1000,
			(last.physicsWait or 0) * 1000,
			(last.displayWait or 0) * 1000
		)
	)
	print(
		string.format(
			"[GVoxel] Entree VPhysics %.2f ms CPU | cuisson %d appels / %.2f ms CPU natif ; cible clic -> terrain : 250 ms ; dernier serveur (reception -> publication) %.2f ms",
			last.nativeMeshCPU or 0,
			last.nativeCount or 0,
			last.nativeCPU or 0,
			(last.latency or 0) * 1000
		)
	)
	if last.source then
		print(
			string.format(
				"[GVoxel] Origine %s | rayon %d SU | plancher %s",
				last.source,
				last.radius or 0,
				tostring(last.floorZ)
			)
		)
	end
	for ply, peer in pairs(scan.peers) do
		print(
			string.format(
				"[GVoxel] %s : paquets %d/64 | envoye %d | affiche %d%s",
				tostring(ply),
				peer.chunk,
				peer.sent,
				peer.acknowledged,
				peer.failed and " | ECHEC" or ""
			)
		)
	end
end)
