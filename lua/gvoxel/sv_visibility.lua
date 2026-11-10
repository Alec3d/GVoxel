-- Local visibility bridge. No map-wide novis/occlusion/sky convar changes.
local V = GVoxel
if V.ReleaseAllVoxelVisibility then
	V.ReleaseAllVoxelVisibility()
end
local regions = {}
local controlled = {}
local applying = false
local function input(ent, name, value)
	applying = true
	local ok, err = pcall(ent.Input, ent, name, ent, ent, value)
	applying = false
	if not ok then
		ErrorNoHalt("[GVoxel] Visibilite : " .. tostring(err) .. "\n")
	end
end
local function variable(ent, key)
	return ent.GetInternalVariable and ent:GetInternalVariable(key)
end
local function touched(r, entry)
	if entry.touched then return true end
	local history = r.bspEdits
	if not history then return false end
	local low, high = entry.low, entry.high
	for i = (entry.checked or 0) + 1, #history do
		local edit = history[i]
		if not edit.adding then
			local p = r.origin + edit.center
			local dx = math.max(low.x - p.x, 0, p.x - high.x)
			local dy = math.max(low.y - p.y, 0, p.y - high.y)
			local dz = math.max(low.z - p.z, 0, p.z - high.z)
			if dx * dx + dy * dy + dz * dz < edit.radius ^ 2 then
				entry.touched = true
				return true
			end
		end
	end
	entry.checked = #history
	return false
end
function V.PrepareVoxelVisibility(r, checkpoint)
	local state = regions[r]
	if not state then
		state = { entries = {}, revision = -1 }
		regions[r] = state
		for _, class in ipairs({ "func_areaportal", "func_areaportalwindow", "func_occluder" }) do
			for _, ent in ipairs(ents.FindByClass(class)) do
				local key = tonumber(variable(ent, "m_portalNumber"))
				local bounds = key and r.bsp and r.bsp.areaPortals and r.bsp.areaPortals[key]
				local low, high
				if bounds then
					low, high = bounds.low, bounds.high
				else
					low, high = ent:WorldSpaceAABB()
				end
				if V.BoundsOverlap(low, high, r.origin, r.origin + V.RegionSize(r)) then
					state.entries[#state.entries + 1] = { ent = ent, class = class, low = low, high = high }
				end
				if checkpoint then
					checkpoint()
				end
			end
		end
	end
	return state
end
function V.RefreshVoxelVisibility(r)
	if not r or r.revision == 0 then
		return
	end
	local state = V.PrepareVoxelVisibility(r)
	if state.revision == r.revision then
		return
	end
	state.revision = r.revision
	for _, entry in ipairs(state.entries) do
		local ent = entry.ent
		if IsValid(ent) and not controlled[ent] and touched(r, entry) then
			local record = { region = r, class = entry.class }
			if entry.class == "func_areaportal" then
				local value = variable(ent, "m_state")
				if value ~= 0 and value ~= 1 then
					record = nil
				else
					record.restore = { { "Open", value == 1 } }
				end
			elseif entry.class == "func_occluder" then
				local value = variable(ent, "m_bActive")
				if type(value) ~= "boolean" then
					record = nil
				else
					record.restore = { { "Activate", value } }
				end
			else
				local a, b = variable(ent, "m_flFadeStartDist"), variable(ent, "m_flFadeDist")
				if type(a) ~= "number" or type(b) ~= "number" then
					record = nil
				else
					record.restore = { { "SetFadeStartDistance", a }, { "SetFadeEndDistance", b } }
				end
			end
			if record then
				controlled[ent] = record
				if entry.class == "func_areaportal" then
					input(ent, "Open")
				elseif entry.class == "func_occluder" then
					input(ent, "Deactivate")
				else
					input(ent, "SetFadeEndDistance", 1000000)
					input(ent, "SetFadeStartDistance", 999999)
				end
			end
		end
	end
end
function V.ReleaseVoxelVisibility(r)
	regions[r] = nil
	for ent, record in pairs(controlled) do
		if record.region == r then
			controlled[ent] = nil
			if IsValid(ent) then
				for _, item in ipairs(record.restore) do
					local name, value = item[1], item[2]
					if name == "Open" then
						input(ent, value and "Open" or "Close")
					elseif name == "Activate" then
						input(ent, value and "Activate" or "Deactivate")
					else
						input(ent, name, value)
					end
				end
			end
		end
	end
end
function V.ReleaseAllVoxelVisibility()
	local list = {}
	for r in pairs(regions) do
		list[#list + 1] = r
	end
	for _, r in ipairs(list) do
		V.ReleaseVoxelVisibility(r)
	end
end
hook.Add("AcceptInput", "GVoxel.KeepOpenedVisibility", function(ent, name, _, _, value)
	local record = controlled[ent]
	if not record or applying then
		return
	end
	name = name:lower()
	if record.class == "func_areaportal" then
		if name == "open" or name == "close" or name == "toggle" or name == "turnon" or name == "turnoff" then
			local old = record.restore[1][2]
			record.restore[1][2] = name == "toggle" and not old or name == "open" or name == "turnoff"
			return true
		end
	elseif record.class == "func_occluder" then
		if name == "activate" or name == "deactivate" or name == "toggle" then
			record.restore[1][2] = name == "toggle" and not record.restore[1][2] or name == "activate"
			return true
		end
	else
		local index = name == "setfadestartdistance" and 1 or name == "setfadeenddistance" and 2
		if index and tonumber(value) then
			record.restore[index][2] = tonumber(value)
			return true
		end
	end
end)
hook.Add("SetupPlayerVisibility", "GVoxel.OpenRoomPVS", function(ply)
	local r = V.GetServerMovementRegion(ply)
	if not r or r.revision == 0 or not r.visibilityOrigins then
		return
	end
	if ply:GetShootPos():DistToSqr(r.base) > (r.side + 2048) ^ 2 then
		return
	end
	for _, p in ipairs(r.visibilityOrigins) do
		AddOriginToPVS(p)
	end
	if r.bsp and r.bsp.sky and r.bsp.sky.camera then
		AddOriginToPVS(r.bsp.sky.camera.origin)
	end
end)
hook.Add("PostCleanupMap", "GVoxel.RestoreMapVisibility", V.ReleaseAllVoxelVisibility)
hook.Add("ShutDown", "GVoxel.RestoreVisibility", V.ReleaseAllVoxelVisibility)
concommand.Add("vm_visibility_stats", function(ply)
	local r = V.GetServerScanRegion and V.GetServerScanRegion()
	if not r or (IsValid(ply) and V.CanManageScan and not V.CanManageScan(ply)) then
		return
	end
	local state = regions[r]
	local count = 0
	for _, record in pairs(controlled) do
		if record.region == r then
			count = count + 1
		end
	end
	print(
		string.format(
			"[GVoxel] Visibilite : %d origines PVS ; %d controleurs locaux ; %d relaches pour la zone.",
			#(r.visibilityOrigins or {}),
			state and #state.entries or 0,
			count
		)
	)
end)
