local V = GVoxel
if V.StopFrameProfile then
	V.StopFrameProfile()
end
local session
local HOOK_PREFIX = "GVoxel."
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
	local rate = count > 0 and string.format("%.0f FPS", 1000 / math.max(0.001, s.meanMS)) or "aucune image"
	s.p95MS = s.frames[math.max(1, math.ceil(count * 0.95))] or 0
	s.p99MS = s.frames[math.max(1, math.ceil(count * 0.99))] or 0
	s.maxMS = s.frames[count] or 0
	s.luaEndKiB = collectgarbage("count")
	s.luaPeakKiB = math.max(s.luaPeakKiB, s.luaEndKiB)
	s.render = V.GetVoxelRenderStats and V.GetVoxelRenderStats()
	local r = V.GetClientScanRegion()
	s.revision = r and r.revision
	file.CreateDir("gvoxel")
	local path = "gvoxel/profile_" .. os.date("%Y%m%d_%H%M%S") .. "_" .. s.label .. ".json"
	file.Write(path, util.TableToJSON(s, true))
	print(
		string.format(
			"[GVoxel] Profil %s : %d images | moyenne %.2f ms (%s) | p95 %.2f / p99 %.2f / max %.2f ms | data/%s",
			s.label,
			count,
			s.meanMS,
			rate,
			s.p95MS,
			s.p99MS,
			s.maxMS,
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
	local luaStart = collectgarbage("count")
	local s = {
		label = (args[2] or "terrain"):gsub("[^%w_-]", ""):sub(1, 48),
		duration = duration,
		map = game.GetMap(),
		width = ScrW(),
		height = ScrH(),
		frames = {},
		luaStartKiB = luaStart,
		luaPeakKiB = luaStart,
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
			if type(name) == "string" and name:sub(1, #HOOK_PREFIX) == HOOK_PREFIX then
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
		s.luaPeakKiB = math.max(s.luaPeakKiB, collectgarbage("count"))
		if now - s.started >= duration then
			finish()
		end
	end)
	print("[GVoxel] Profil pret : retourne en jeu et attends " .. duration .. " secondes.")
end)
concommand.Add("vm_profile_stop", finish)

-- Read-only, on-demand: never reset a player's DSP to diagnose an echo.
concommand.Add("vm_audio_stats", function()
	print("[GVoxel] Native audio diagnostics (read-only).")
	if V.GetVoxelAcousticStats then
		local stats = V.GetVoxelAcousticStats()
		print(string.format("[GVoxel] Room repair: %s; %d reload requests; transition armed %s.",
			stats.status, stats.repairs, tostring(stats.armed)))
	end
	for _, name in ipairs({"dsp_room", "dsp_automatic", "dsp_player", "dsp_water", "dsp_spatial", "dsp_off"}) do
		local value = GetConVar(name)
		print("[GVoxel] " .. name .. " = " .. (value and value:GetInt() or "unavailable"))
	end
	local ply = LocalPlayer()
	local r = V.GetClientScanRegion()
	if not IsValid(ply) then return end
	local pos = ply:EyePos()
	local leaf = r and r.bsp and V.BSPLeaf(r.bsp, pos)
	local solid = r and r.bsp and V.BSPSolid(r.bsp, pos)
	print(string.format("[GVoxel] Listener %.1f %.1f %.1f; zone %s; original solid %s; cluster %s; area %s; voxel movement %s.",
		pos.x, pos.y, pos.z, r and r.id or "none", tostring(solid), leaf and leaf.cluster or "unknown",
		leaf and leaf.area or "unknown", tostring(ply:GetNW2Bool("VM_VoxelMovement"))))
	local view = render.GetViewSetup and render.GetViewSetup(true)
	if view and view.origin then
		print(string.format("[GVoxel] Last render origin %.1f %.1f %.1f; move type %s.",
			view.origin.x, view.origin.y, view.origin.z, tostring(ply:GetMoveType())))
	end
end)
