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
	"density",
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
	-- Existing participants keep the atomic display/collision barrier. A late
	-- join replays history without stopping everyone until it catches up.
	scan.peers[ply] = { nextLayer = 0, sent = -1, acknowledged = -1, blocking = not scan.everReady }
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
-- Each lattice point is sent once, as a little-endian signed 16-bit
-- density. A two-byte payload represents a uniform horizontal layer.
local function densityWord(value)
	local word = math.Clamp(math.floor(value * 64 + 0.5), -32767, 32767) % 65536
	return word % 256, math.floor(word / 256)
end
local function uniformLayer(values, r, z, maxX, maxY)
	local first = values[V.Index(0, 0, z, r)]
	for y = 0, maxY do
		local start = V.Index(0, y, z, r)
		for i = start, start + maxX do
			if values[i] ~= first then return end
		end
	end
	return string.char(densityWord(first))
end
local function densityLayer(scan, z)
	local r = scan.region
	scan.densityLayers = scan.densityLayers or {}
	local data = scan.densityLayers[z]
	if not data then
		local values = scan.snapshot.values
		local maxX, maxY = V.RegionCells(r, "x"), V.RegionCells(r, "y")
		data = uniformLayer(values, r, z, maxX, maxY)
		if not data then
			local rows, bytes = {}, {}
			local last, low, high
			for y = 0, maxY do
				local start = V.Index(0, y, z, r)
				local j = 1
				for i = start, start + maxX do
					local value = values[i]
					if value ~= last then
						last = value
						low, high = densityWord(value)
					end
					bytes[j], bytes[j + 1] = low, high
					j = j + 2
				end
				rows[y + 1] = string.char(unpack(bytes))
			end
			data = table.concat(rows)
		end
		scan.densityLayers[z] = data
	end
	return data
end
local function sendDensity(scan, ply, peer, data)
	net.Start("vm_scan_density")
	net.WriteUInt(scan.region.id, 16)
	net.WriteUInt(peer.nextLayer, 8)
	net.WriteData(data, #data)
	net.Send(ply)
	peer.nextLayer = peer.nextLayer + 1
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
	V.WriteEditPlane(stroke.plane)
	net.Send(ply)
end
local function edit(scan, ply, peer, revision, stroke)
	strokePacket("vm_scan_edit", scan, ply, revision, stroke)
	peer.sent = revision
end
-- Prepare privately while the server builds SAT/native collision. The normal
-- edit packet remains the publication permit, sent only after physics is ready.
-- Joins replay committed history as before; speculative work is never journaled.
local function preparePeer(scan, work, ply, peer)
	if not peer.done or peer.failed or peer.acknowledged ~= scan.region.revision then return end
	work.previewPeers = work.previewPeers or {}
	if work.previewPeers[ply] == peer then return end
	strokePacket("vm_scan_prepare", scan, ply, work.revision, work)
	work.previewPeers[ply] = peer
	work.previewSent = true
end
function V.PrepareScanEdit(scan, work)
	work.revision = work.revision or work.field.revision
	work.previewReady = true
	for ply, peer in pairs(scan.peers) do
		if IsValid(ply) then preparePeer(scan, work, ply, peer) end
	end
end
function V.AbortScanPreparation(scan, work)
	if not work or not work.previewPeers then
		return
	end
	local recipients = work.previewPeers
	work.previewPeers = nil
	for ply, peer in pairs(recipients) do
		if IsValid(ply) and scan.peers[ply] == peer and not peer.failed then
			net.Start("vm_scan_abort")
			net.WriteUInt(scan.region.id, 16)
			net.WriteUInt(work.revision, 16)
			net.Send(ply)
		end
	end
end
-- Budget catch-up traffic as a group. Full layers retain the two-packet cap;
-- uniform layers can advance in the same tick without a dense-layer burst.
local REPLICATION_BYTES = 8 * 1024
local REPLICATION_PACKETS = 32
local EDIT_PACKET_BYTES = 40 -- Upper bound including the optional clip plane and cell.
local PROGRESS_PACKET_BYTES = 17
function V.PumpScanReplication(scan, deadline)
	if not scan.snapshot then
		return
	end
	local peers, count = scan.replicationPeers, 0
	local latest = #scan.history
	local layers = V.RegionCells(scan.region, "z") + 1
	for ply, peer in pairs(scan.peers) do
		if IsValid(ply) then
			if not peer.failed and (not peer.features or peer.nextLayer < layers
				or (scan.completed and (not peer.done or peer.sent < latest))) then
				if not peers then peers = {} scan.replicationPeers = peers end
				count = count + 1
				peers[count] = ply
			end
		else
			scan.peers[ply] = nil
		end
	end
	if peers then for i = #peers, count + 1, -1 do peers[i] = nil end end
	if count == 0 then
		return
	end
	local bytes, packets = REPLICATION_BYTES, REPLICATION_PACKETS
	local density, dense, metadata, edits = 0, 0, 0, 0
	local planes = scan.region.featurePlanes
	local planeBytes = 7 + (planes and #planes or 0) * 40
	local start = (scan.replicationCursor or 0) % count
	local layersPerPeer = count == 1 and 8 or 4
	for i = 1, count do
		if bytes < 7 or packets == 0 or SysTime() >= deadline then break end
		local ply = peers[(start + i - 1) % count + 1]
		local peer = scan.peers[ply]
		if not peer.features and metadata < 2 and bytes >= planeBytes then
			features(scan, ply)
			peer.features = true
			metadata = metadata + 1
			bytes, packets = bytes - planeBytes, packets - 1
		end
		for _ = 1, layersPerPeer do
			if not peer.features or peer.nextLayer >= layers or density >= 8 or dense >= 2
				or bytes < 8 or packets == 0 or SysTime() >= deadline then break end
			local data = densityLayer(scan, peer.nextLayer)
			local packetBytes = #data + 6
			if bytes < packetBytes or SysTime() >= deadline then break end
			sendDensity(scan, ply, peer, data)
			density = density + 1
			if #data > 2 then dense = dense + 1 end
			bytes, packets = bytes - packetBytes, packets - 1
		end
		if peer.nextLayer == layers and scan.completed and SysTime() < deadline then
			if not peer.done and bytes >= PROGRESS_PACKET_BYTES and packets > 0 then
				peer.done = true
				peer.sent = 0
				progress(scan, ply, 2, 1)
				bytes, packets = bytes - PROGRESS_PACKET_BYTES, packets - 1
			end
			for _ = 1, 8 do
				local revision = peer.sent + 1
				if not peer.done or edits >= 16 or not scan.history[revision]
					or bytes < EDIT_PACKET_BYTES or packets == 0 or SysTime() >= deadline then
					break
				end
				edit(scan, ply, peer, revision, scan.history[revision])
				edits = edits + 1
				bytes, packets = bytes - EDIT_PACKET_BYTES, packets - 1
			end
		end
	end
	scan.replicationCursor = start + 1
end
function V.ScanPeersReady(scan, revision)
	local count = 0
	for ply, peer in pairs(scan.peers) do
		if IsValid(ply) and peer.blocking ~= false then
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
		{ center = work.center, radius = work.radius, adding = work.adding, seed = work.seed, floorZ = work.floorZ, plane = work.plane }
	work.sent = true
	for ply, peer in pairs(scan.peers) do
		if IsValid(ply) and not peer.failed and peer.done and peer.sent == revision - 1 then
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
net.Receive("vm_scan_ready", function(length, ply)
	if length ~= 32 then return end
	local scan = session
	local peer = scan and scan.peers[ply]
	if not peer or not peer.done then return end
	local id, revision = net.ReadUInt(16), net.ReadUInt(16)
	if not peer or not peer.done or scan.region.id ~= id or revision > peer.sent then
		return
	end
    if revision<=peer.acknowledged and not peer.failed then return end
	peer.acknowledged = math.max(peer.acknowledged, revision)
	peer.failed = nil
	if revision >= scan.region.revision then peer.blocking = true end
	scan.movementReady = V.ScanPeersReady(scan, scan.region.revision)
	if scan.movementReady then scan.everReady = true end
	local work = scan.editWork
	if work and work.previewReady and not work.sent then preparePeer(scan, work, ply, peer) end
	if V.CommitScanEdit then
		V.CommitScanEdit(scan)
	end
end)
-- The client announces itself after installing its receivers, also on refresh.
net.Receive("vm_scan_sync", function(length, ply)
	if length ~= 0 then return end
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
net.Receive("vm_scan_failed", function(length, ply)
	if length ~= 16 then return end
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
		local waiting = session.replicationPeers
		for i = waiting and #waiting or 0, 1, -1 do
			if waiting[i] == ply then
				table.remove(waiting, i)
				break
			end
		end
		local previews = session.editWork and session.editWork.previewPeers
		if previews then previews[ply] = nil end
		if session.ply == ply then
			session.ply = nil
		end
		if V.CommitScanEdit then
			V.CommitScanEdit(session)
		end
	end
end)
