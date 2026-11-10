-- Lightweight cursor preview. Native ray queries run in Think only; drawing
-- consumes prepared bounds/points and never builds terrain or collision data.
local V = GVoxel
local enabled = CreateClientConVar("vm_custom_block", "0", true, false, "Selection rectangulaire a quatre points", 0, 1)
local state = { points = {} }
local preview, cursor, lastPose
local pressed, blocked = false, false
local pointRequested = false
local message
function V.CustomBlockEnabled()
	return enabled:GetBool()
end
function V.ResetCustomBlockSelection()
	state = { points = {} }
	preview = nil
	cursor = nil
	lastPose = nil
	message = nil
end
function V.UndoCustomBlockSelection()
	V.CustomSelectionUndo(state)
	lastPose = nil
	message = nil
end
function V.GetCustomBlockSelection()
	return state, preview
end
function V.CustomBlockScanBounds()
	if #state.points ~= 4 or state.moving then
		return nil, V.L("Poser quatre points et verrouiller la boite avant R.")
	end
	local selected = V.CustomSelectionPreview(state)
	if not selected.bounds then
		return nil, selected.error
	end
	-- Send raw snapped corners. Both realms derive the same grid adjustment
	-- once; re-snapping an already adjusted extent would change its dimensions.
	return selected.low, selected.high
end
function V.CustomBlockStatus()
	if not V.CustomBlockEnabled() then
		return
	end
	local instructions = {
		"Molette : point 1, coin de depart",
		"Molette : point 2, largeur X",
		"Molette : point 3, longueur Y",
		"Viser la hauteur puis molette : point 4",
	}
	local text = message and V.L(message)
		or (
			state.moving and V.L("Deplacer en visant ; molette pour verrouiller")
			or V.L(instructions[#state.points + 1] or "R : analyser | Molette : deplacer la boite")
		)
	if preview and preview.low and preview.high then
		local e = (preview.bounds and preview.bounds.extent or preview.high - preview.low) / V.UnitsPerMetre
		text = text
			.. string.format(" | %.2f x %.2f x %.2f m%s", e.x, e.y, e.z, preview.bounds and V.L(" (grille)") or V.L(" (apercu)"))
	end
	local bound = input.LookupBinding("vm_box_point")
	if bound then text = text .. "  [" .. string.upper(bound) .. "]" end
	return V.L(text)
end
concommand.Add("vm_box_point", function() pointRequested = true end)
hook.Add("Think", "GVoxel.CustomBlockSelection", function()
	local requested = pointRequested
	pointRequested = false
	local weapon = V.GetActiveVoxelTool and V.GetActiveVoxelTool()
	local down = input.IsMouseDown(MOUSE_MIDDLE)
	local allowed = V.CustomBlockEnabled()
		and weapon
		and LocalPlayer():Alive()
		and not gui.IsGameUIVisible()
		and not gui.IsConsoleVisible()
		and not vgui.CursorVisible()
	if not allowed then
		if down then
			blocked = true
		else
			blocked = false
		end
		pressed = down
		lastPose = nil
		return
	end
	if blocked then
		if not down then
			blocked = false
		end
		pressed = down
		return
	end
	local ply = LocalPlayer()
	local start, direction = ply:GetShootPos(), ply:GetAimVector()
	if
		not lastPose
		or lastPose.start ~= start
		or lastPose.direction ~= direction
		or lastPose.serial ~= state.serial
	then
		local hit = V.Trace(ply, 2048)
		local point = hit.HitWorld and not hit.HitSky and hit.HitPos or nil
		cursor = V.CustomSelectionPoint(state.points, point, start, direction)
		preview = V.CustomSelectionPreview(state, cursor)
		lastPose = { start = start, direction = direction, serial = state.serial }
	end
	if requested or (down and not pressed) then
		local ok, err = V.CustomSelectionClick(state, cursor)
		message = not ok and err or nil
		lastPose = nil
	end
	pressed = down
end)
function V.DrawCustomBlockPreview()
	if not V.CustomBlockEnabled() or not preview then
		return
	end
	local bounds = preview.bounds
	local color = preview.error and Color(255, 95, 80) or Color(90, 215, 255)
	if preview.low and preview.high then
		local low = bounds and bounds.origin or preview.low
		local extent = bounds and bounds.extent or preview.high - preview.low
		render.DrawWireframeBox(low, angle_zero, Vector(), extent, color, true)
	end
	for i, p in ipairs(preview.points) do
		render.DrawWireframeSphere(p, 3.5, 6, 4, color, true)
		if i > 1 then
			render.DrawLine(preview.points[i - 1], p, color, true)
		end
	end
end
