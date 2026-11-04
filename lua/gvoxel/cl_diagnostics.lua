local V = GVoxel
if V.StopFrameProfile then
	V.StopFrameProfile()
end
local session
local function finish()
	if not session then
		return
	end
	local s = session
	session = nil
	hook.Remove("Think", "GVoxel.ProfileFrames")
	for _, entry in ipairs(s.wrapped) do
		local event = hook.GetTable()[entry.event]
		if event and event[entry.name] == entry.wrapper then
			hook.Add(entry.event, entry.name, entry.original)
		end
	end
	s.wrapped = nil
	s.previous = nil
	table.sort(s.frames)
	local sum = 0
	for _, ms in ipairs(s.frames) do
		sum = sum + ms
	end
	local count = #s.frames
	s.meanMS = sum / math.max(1, count)
	s.p95MS = s.frames[math.max(1, math.ceil(count * 0.95))] or 0
	s.render = V.GetVoxelRenderStats and V.GetVoxelRenderStats()
	local r = V.GetClientScanRegion()
	s.revision = r and r.revision
	file.CreateDir("gvoxel")
	local path = "gvoxel/profile_" .. os.date("%Y%m%d_%H%M%S") .. "_" .. s.label .. ".json"
	file.Write(path, util.TableToJSON(s, true))
	print(
		string.format(
			"[GVoxel] Profil %s : %d images | moyenne %.2f ms (%.0f FPS) | p95 %.2f ms | data/%s",
			s.label,
			count,
			s.meanMS,
			1000 / math.max(0.001, s.meanMS),
			s.p95MS,
			path
		)
	)
	V.LastFrameProfile = s
	if s.returnToMenu then
		gui.ActivateGameUI()
	end
end
local function pack(...)
	return { n = select("#", ...), ... }
end
V.StopFrameProfile = finish
concommand.Add("vm_profile", function(_, _, args)
	if session then
		print("[GVoxel] Un profil est deja en cours.")
		return
	end
	local duration = math.Clamp(tonumber(args[1]) or 5, 2, 30)
	local s = {
		label = (args[2] or "terrain"):gsub("[^%w_-]", ""),
		duration = duration,
		map = game.GetMap(),
		width = ScrW(),
		height = ScrH(),
		frames = {},
		hooks = {},
		wrapped = {},
		returnToMenu = args[3] == "menu",
	}
	session = s
	local ply = LocalPlayer()
	if IsValid(ply) then
		s.position = ply:GetPos()
		s.angles = ply:EyeAngles()
	end
	-- Instrument only our own hooks, temporarily. Inclusive CPU times include
	-- nested RenderView work; frame intervals also expose GPU/engine stalls.
	for event, entries in pairs(hook.GetTable()) do
		for name, fn in pairs(entries) do
			if isstring(name) and name:sub(1, 11) == "GVoxel." then
				local key = event .. "/" .. name
				local row = { calls = 0, totalMS = 0, maxMS = 0 }
				s.hooks[key] = row
				local wrapper = function(...)
					local start = SysTime()
					local results = pack(fn(...))
					local elapsed = (SysTime() - start) * 1000
					row.calls = row.calls + 1
					row.totalMS = row.totalMS + elapsed
					row.maxMS = math.max(row.maxMS, elapsed)
					return unpack(results, 1, results.n)
				end
				s.wrapped[#s.wrapped + 1] = { event = event, name = name, original = fn, wrapper = wrapper }
				hook.Add(event, name, wrapper)
			end
		end
	end
	hook.Add("Think", "GVoxel.ProfileFrames", function()
		if gui.IsGameUIVisible() or gui.IsConsoleVisible() then
			s.previous = nil
			return
		end
		local now = SysTime()
		s.started = s.started or now + 0.5
		if now < s.started then
			return
		end
		if s.previous then
			s.frames[#s.frames + 1] = (now - s.previous) * 1000
		end
		s.previous = now
		if now - s.started >= duration then
			finish()
		end
	end)
	print("[GVoxel] Profil pret : retourne en jeu et attends " .. duration .. " secondes.")
end)
concommand.Add("vm_profile_stop", finish)
