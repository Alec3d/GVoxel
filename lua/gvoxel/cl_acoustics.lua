-- Source can retain a processed room after its native selectors return to zero.
-- Reload that stale DSP state once on a stable wet -> dry transition near an
-- edited zone. Never replace soundscapes or write their parameter values.
local V = GVoxel
local axes = {"x", "y", "z"}
local enabled = CreateClientConVar("vm_audio_repair", "1", true, false,
    "Clear stale native room DSP after leaving a reverberant voxel area", 0, 1)
local nextCheck, nextRepair = 0, 0
local region, recentUntil, wetSince, drySince
local armed = false
local repairs = 0
local status = "idle"

local function reset()
    region, recentUntil, wetSince, drySince = nil, nil, nil, nil
    armed = false
    status = "idle"
end
V.ResetVoxelAcoustics = reset

local function near(r, pos)
    for _, axis in ipairs(axes) do
        local d = pos[axis] - r.origin[axis]
        if d < -64 or d > V.RegionAxisSize(r, axis) + 64 then return false end
    end
    return true
end

hook.Add("Think", "GVoxel.NativeAcoustics", function()
    local now = RealTime()
    if now < nextCheck then return end
    nextCheck = now + 0.1
    local r = V.GetClientScanRegion and V.GetClientScanRegion()
    local ply = LocalPlayer()
    if not enabled:GetBool() or not r or r.revision == 0 or not IsValid(ply) or not ply:Alive() then reset() return end
    if region ~= r then reset() region = r end
    if near(r, ply:EyePos()) then recentUntil = now + 10 end
    if not recentUntil or now > recentUntil then reset() return end

    local room, automatic, playerDSP = GetConVar("dsp_room"), GetConVar("dsp_automatic"), GetConVar("dsp_player")
    if not room or not automatic or not playerDSP then reset() status = "unsupported" return end
    local preset, auto = room:GetInt(), automatic:GetInt()
    if preset > 0 then
        drySince = nil
        wetSince = wetSince or now
        if now - wetSince >= 0.3 then armed = true end
        status = "native-room"
        return
    end
    wetSince = nil
    if not armed or preset ~= 0 or auto ~= 0 then drySince = nil status = "native" return end
    drySince = drySince or now
    if now - drySince < 0.35 then status = "settling" return end
    -- A reload resets processor state too. Defer it while another native
    -- effect owns the listener; its settings must not be cancelled by a hole.
    if playerDSP:GetInt() ~= 0 or ply:WaterLevel() >= 3 then status = "deferred-effect" return end
    local off = GetConVar("dsp_off")
    if off and off:GetBool() then status = "dsp-disabled" return end
    if now < nextRepair then status = "cooldown" return end

    -- Engine convars cannot be restored with ConVar:SetInt. The native reload
    -- command clears the stale buffers without forcing generic room presets.
    RunConsoleCommand("dsp_reload")
    repairs = repairs + 1
    nextRepair = now + 5
    armed, drySince = false, nil
    status = "reloaded"
end)

function V.GetVoxelAcousticStats()
    return {repairs = repairs, status = status, armed = armed}
end
hook.Add("PostCleanupMap", "GVoxel.ResetAcoustics", reset)
hook.Add("ShutDown", "GVoxel.ReleaseAcoustics", reset)
