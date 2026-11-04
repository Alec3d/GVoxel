-- Four-point, axis-aligned selection. Pure geometry/state, no input or render.
local V = GVoxel
function V.CustomSelectionPoint(points, hit, start, direction)
	local count = #points
	if count == 3 then
		-- Height is constrained to the far corner's vertical line. Intersect
		-- the view ray with a vertical plane facing the player at that corner.
		local anchor = Vector(points[2].x, points[3].y, points[1].z)
		local normal = Vector(start.x - anchor.x, start.y - anchor.y, 0):GetNormalized()
		local denominator = normal:Dot(direction)
		if math.abs(denominator) > 1e-7 then
			local distance = normal:Dot(anchor - start) / denominator
			if distance >= 0 and distance <= 4096 then
				local p = start + direction * distance
				return V.SnapScanPosition(Vector(anchor.x, anchor.y, p.z))
			end
		end
		if hit then
			return V.SnapScanPosition(Vector(anchor.x, anchor.y, hit.z))
		end
		return
	end
	if not hit then
		return
	end
	hit = V.SnapScanPosition(hit)
	if count == 1 then
		return Vector(hit.x, points[1].y, points[1].z)
	end
	if count == 2 then
		return Vector(points[2].x, hit.y, points[1].z)
	end
	return hit
end
function V.CustomSelectionPreview(state, cursor)
	local points = {}
	for i, p in ipairs(state.points or {}) do
		points[i] = p
	end
	if state.moving and cursor and state.moveStart then
		local delta = V.SnapScanPosition(cursor - state.moveStart)
		for i, p in ipairs(points) do
			points[i] = p + delta
		end
	elseif #points < 4 and cursor then
		points[#points + 1] = cursor
	end
	if #points == 0 then
		return { points = points }
	end
	local first = points[1]
	local opposite = points[#points]
	local low = Vector(math.min(first.x, opposite.x), math.min(first.y, opposite.y), math.min(first.z, opposite.z))
	local high = Vector(math.max(first.x, opposite.x), math.max(first.y, opposite.y), math.max(first.z, opposite.z))
	local bounds, err
	if #points == 4 then
		bounds, err = V.CustomBoxBounds(low, high)
	end
	return { points = points, low = low, high = high, bounds = bounds, error = err }
end
function V.CustomSelectionClick(state, cursor)
	state.points = state.points or {}
	if not cursor then
		return false, "Viser une surface ou la hauteur de la boite."
	end
	local count = #state.points
	if count == 1 and math.abs(cursor.x - state.points[1].x) < V.CustomMinSide then
		return false, "Ecarter le point sur l'axe X (32 unites minimum)."
	end
	if count == 2 and math.abs(cursor.y - state.points[1].y) < V.CustomMinSide then
		return false, "Ecarter le point sur l'axe Y (32 unites minimum)."
	end
	if count == 3 then
		local preview = V.CustomSelectionPreview(state, cursor)
		if not preview.bounds then
			return false, preview.error
		end
	end
	if count < 4 then
		state.points[count + 1] = cursor
	elseif not state.moving then
		state.moving = true
		state.moveStart = cursor
	else
		local preview = V.CustomSelectionPreview(state, cursor)
		state.points = preview.points
		state.moving = false
		state.moveStart = nil
	end
	state.serial = (state.serial or 0) + 1
	return true
end
function V.CustomSelectionUndo(state)
	if state.moving then
		state.moving = false
		state.moveStart = nil
	else
		table.remove(state.points or {})
	end
	state.serial = (state.serial or 0) + 1
end
