-- One shared region per server. Networking never samples or rebuilds geometry.
-- A late join receives the immutable scan, then the ordered edit journal.
local V = GVoxel
local clients = {}
local session
for _, name in ipairs({
	"request",
	"custom",
	"begin",
	"progress",
	"chunk",
	"cancel",
	"settings",
	"edit",
	"prepare",
	"abort",
	"ready",
	"features",
	"sync",
	"failed",
}) do
	util.AddNetworkString("vm_scan_" .. name)
end
function V.GetScanSession(id)
    if type(id)=="number" and (not session or session.region.id~=id) then return end
    return session
end
function V.GetScanSessions() return session and {[session.region.id]=session} or {} end
function V.RemoveScanSession(scan) if session==scan then session=nil end end
function V.SetScanSession(scan)
	session = scan
end

local function progress(scan, ply, phase, ratio)
	net.Start("vm_scan_progress")
	net.WriteUInt(scan.region.id, 16)
	net.WriteUInt(phase, 2)
	net.WriteUInt(math.Clamp(math.floor(ratio * 255), 0, 255), 8)
	net.WriteUInt(scan.solids, 16)
	net.WriteUInt(scan.rays, 32)
	net.WriteFloat(SysTime() - scan.started)
	net.Send(ply)
end
function V.SendScanProgress(scan, phase, ratio)
	for ply in pairs(scan.peers) do
		if IsValid(ply) then
			progress(scan, ply, phase, ratio)
		end
	end
end
local function attach(scan, ply)
	scan.peers[ply] = { chunk = 0, sent = -1, acknowledged = -1 }
	net.Start("vm_scan_begin")
	net.WriteUInt(scan.region.id, 16)
	net.WriteVector(scan.region.base)
	net.WriteUInt(scan.region.metres, 6)
	if scan.region.custom then
		net.WriteVector(scan.region.origin)
		net.WriteFloat(scan.region.step)
		net.WriteUInt(scan.region.cells.x, 6)
		net.WriteUInt(scan.region.cells.y, 6)
		net.WriteUInt(scan.region.cells.z, 6)
	end
	net.Send(ply)
end
function V.BeginScanSession(scan)
    if session and session~=scan then return false end
	session = scan
	scan.peers = {}
	scan.history = {}
	if IsValid(scan.ply) then clients[scan.ply] = true end
	for ply in pairs(clients) do
		if IsValid(ply) then
			attach(scan, ply)
		else
			clients[ply] = nil
		end
	end
end
local function features(scan, ply)
	local r = scan.region
	local planes = r.featurePlanes or {}
	net.Start("vm_scan_features")
	net.WriteUInt(r.id, 16)
	net.WriteUInt(#planes, 8)
	net.WriteBool(r.bsp ~= nil)
	for _, plane in ipairs(planes) do
		local n = V.FeaturePlaneNormal(plane)
		net.WriteFloat(n.x)
		net.WriteFloat(n.y)
		net.WriteFloat(n.z)
		net.WriteFloat(V.FeaturePlaneDistance(plane))
		net.WriteFloat(plane.low.x)
		net.WriteFloat(plane.low.y)
		net.WriteFloat(plane.low.z)
		net.WriteFloat(plane.high.x)
		net.WriteFloat(plane.high.y)
		net.WriteFloat(plane.high.z)
	end
	net.Send(ply)
end
local function chunk(scan, ply, peer)
	local index = peer.chunk
	local x, y, z = index % 4, math.floor(index / 4) % 4, math.floor(index / 16)
	local r = scan.snapshot
	net.Start("vm_scan_chunk")
	net.WriteUInt(r.id, 16)
	net.WriteUInt(x, 2)
	net.WriteUInt(y, 2)
	net.WriteUInt(z, 2)
	for zz = z * 8 - 1, z * 8 + 9 do
		for yy = y * 8 - 1, y * 8 + 9 do
			for xx = x * 8 - 1, x * 8 + 9 do
				net.WriteInt(math.Clamp(math.floor(V.Sample(r, xx, yy, zz) * 64 + 0.5), -32767, 32767), 16)
			end
		end
	end
	net.Send(ply)
	peer.chunk = index + 1
end
local function strokePacket(name, scan, ply, revision, stroke)
	net.Start(name)
	net.WriteUInt(scan.region.id, 16)
	net.WriteUInt(revision, 16)
	net.WriteVector(stroke.center)
	net.WriteUInt(stroke.radius, 16)
	net.WriteBool(stroke.adding)
	net.WriteUInt(stroke.seed or 0, 16)
	net.WriteBool(stroke.floorZ ~= nil)
	if stroke.floorZ ~= nil then
		net.WriteFloat(stroke.floorZ)
	end
	net.Send(ply)
end
local function edit(scan, ply, peer, revision, stroke)
	strokePacket("vm_scan_edit", scan, ply, revision, stroke)
	peer.sent = revision
end
-- Prepare privately while the server builds SAT/native collision. The normal
-- edit packet remains the publication permit, sent only after physics is ready.
-- Joins replay committed history as before; speculative work is never journaled.
function V.PrepareScanEdit(scan, work)
	for ply, peer in pairs(scan.peers) do
		if IsValid(ply) and peer.done and not peer.failed and peer.acknowledged == scan.region.revision then
			strokePacket("vm_scan_prepare", scan, ply, work.field.revision, work)
		end
	end
	work.previewSent = true
end
function V.AbortScanPreparation(scan, work)
	if not work or not work.previewSent then
		return
	end
	for ply in pairs(scan.peers) do
		if IsValid(ply) then
			net.Start("vm_scan_abort")
			net.WriteUInt(scan.region.id, 16)
			net.WriteUInt(work.field.revision, 16)
			net.Send(ply)
		end
	end
end
-- Two density packets globally per tick. Rotate peers so joins share bandwidth.
function V.PumpScanReplication(scan, deadline)
	if not scan.snapshot then
		return
	end
	local peers = {}
	for ply, peer in pairs(scan.peers) do
		if IsValid(ply) then
			peers[#peers + 1] = { ply, peer }
		else
			scan.peers[ply] = nil
		end
	end
	if #peers == 0 then
		return
	end
	local packets = 0
	local start = (scan.replicationCursor or 0) % #peers
	for i = 1, #peers do
		local pair = peers[(start + i - 1) % #peers + 1]
		local ply, peer = pair[1], pair[2]
		if not peer.features and SysTime() < deadline then
			features(scan, ply)
			peer.features = true
		end
		while peer.features and peer.chunk < 64 and packets < 2 and SysTime() < deadline do
			chunk(scan, ply, peer)
			packets = packets + 1
		end
		if peer.chunk == 64 and scan.completed then
			if not peer.done then
				peer.done = true
				peer.sent = 0
				progress(scan, ply, 2, 1)
			end
			for _ = 1, 8 do
				local revision = peer.sent + 1
				if not scan.history[revision] or SysTime() >= deadline then
					break
				end
				edit(scan, ply, peer, revision, scan.history[revision])
			end
		end
	end
	scan.replicationCursor = start + 1
end
function V.ScanPeersReady(scan, revision)
	local count = 0
	for ply, peer in pairs(scan.peers) do
		if IsValid(ply) then
			count = count + 1
			if not peer.done or peer.failed or peer.acknowledged < revision then
				return false
			end
		end
	end
	return count > 0
end
function V.PublishScanEdit(scan, work)
	local revision = work.field.revision
	scan.history[revision] =
		{ center = work.center, radius = work.radius, adding = work.adding, seed = work.seed, floorZ = work.floorZ }
	work.sent = true
	for ply, peer in pairs(scan.peers) do
		if IsValid(ply) and peer.done and peer.sent == revision - 1 then
			edit(scan, ply, peer, revision, work)
		end
	end
end
function V.GetServerScanRegion()
	return session and session.completed and session.region or nil
end
function V.GetServerMovementRegion(ply)
	local scan = session
	local peer = scan and scan.peers[ply]
	return scan
			and scan.completed
			and peer
			and not peer.failed
			and peer.acknowledged >= scan.region.revision
			and scan.region
		or nil
end
net.Receive("vm_scan_ready", function(_, ply)
	local id, revision = net.ReadUInt(16), net.ReadUInt(16)
	local scan = session
	local peer = scan and scan.peers[ply]
	if not peer or not peer.done or scan.region.id ~= id or revision > peer.sent then
		return
	end
    if revision<=peer.acknowledged and not peer.failed then return end
	peer.acknowledged = math.max(peer.acknowledged, revision)
	peer.failed = nil
	scan.movementReady = V.ScanPeersReady(scan, scan.region.revision)
	if V.CommitScanEdit then
		V.CommitScanEdit(scan)
	end
end)
-- The client announces itself after installing its receivers, also on refresh.
net.Receive("vm_scan_sync", function(_, ply)
	if (ply.VMNextSync or 0) > CurTime() then
		return
	end
	ply.VMNextSync = CurTime() + 5
	clients[ply] = true
	if session then
		if V.ReleaseVoxelMovement and not V.ReleaseVoxelMovement(ply) then
			return
		end
		attach(session, ply)
	end
end)
net.Receive("vm_scan_failed", function(_, ply)
	local id = net.ReadUInt(16)
	local peer = session and session.peers[ply]
	if peer and session.region.id == id and not peer.failed then
		peer.failed = true
		V.Notify(ply, "Reconstruction arretee. Console : vm_resync pour retenter ; revision serveur conservee.")
	end
end)
hook.Add("PlayerDisconnected", "GVoxel.SessionDisconnect", function(ply)
	clients[ply] = nil
	if session then
		session.peers[ply] = nil
		if session.ply == ply then
			session.ply = nil
		end
		if V.CommitScanEdit then
			V.CommitScanEdit(session)
		end
	end
end)
