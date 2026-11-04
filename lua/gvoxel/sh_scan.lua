local V = GVoxel
local axes = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }

-- Sample the volume, not just a height map: six local ray directions refine
-- brush occupancy and detect displacement surfaces near each lattice point.
-- Providers are injected so this numerical part can be tested without a map.
function V.ScanDensity(r, p, solid, trace, terrainSign)
	local reach = r.step * 1.75
	local distance, displacementDistance, displacementSign = r.step, math.huge, 1
	local planeHits = {}
	for _, axis in ipairs(axes) do
		local start = p + axis * reach
		local delta = axis * (-2 * reach)
		local hit = trace(start, start + delta)
		if hit.StartSolid and not hit.AllSolid and (hit.FractionLeftSolid or 0) > 0 then
			local exit = start + delta * hit.FractionLeftSolid
			distance = math.min(
				distance,
				hit.ExitNormal and math.abs((exit - p):Dot(hit.ExitNormal)) or math.sqrt(exit:DistToSqr(p))
			)
		elseif
			hit.HitWorld
			and hit.Hit
			and not hit.HitSky
			and not hit.StartSolid
			and hit.HitTexture ~= "**studio**"
		then
			local planeDistance = (p - hit.HitPos):Dot(hit.HitNormal)
			local d = math.abs(planeDistance)
			if V.RecordScanPlane and r.analysis and hit.HitTexture ~= "**displacement**" then
				planeHits[#planeHits + 1] = { hit = hit, distance = d }
			end
			distance = math.min(distance, d)
			if hit.HitTexture == "**displacement**" and d < displacementDistance then
				displacementDistance = d
				displacementSign = planeDistance < 0 and -1 or 1
			end
		end
	end
	local sign = solid and -1 or 1
	-- Source contents can be empty BELOW a displacement. Local rays only see
	-- its first few lattice layers; without column continuation this creates
	-- a thin crust over empty space, and a large brush punches right through.
	local continued, bounded
	if not solid and terrainSign then
		continued, bounded = terrainSign(p)
		sign = continued or sign
	end
	-- Record only planes supporting the sampled surface. An underlying brush
	-- must not flatten a displacement that is actually closer to this point.
	if displacementDistance > distance + 0.001 then
		for _, candidate in ipairs(planeHits) do
			if candidate.distance <= distance + 0.001 then
				V.RecordScanPlane(r, candidate.hit)
			end
		end
	end
	-- Displacements are surfaces: their contents alone need not define a solid.
	if not solid and not bounded and continued == nil and displacementDistance <= distance + 0.001 then
		sign = displacementSign
	end
	return math.floor(sign * distance * 64 + 0.5) / 64
end

function V.ScanPoint(r, index)
	local z = math.floor(index / (33 * 33))
	local y = math.floor(index / 33) % 33
	local x = index % 33
	return r.origin + Vector(x, y, z) * r.step, x, y, z
end

-- Press/release semantics are independent of frame rate and SWEP prediction.
function V.ReloadGesture(state, down, now, allowed)
	if not allowed then
		state.pressed = nil
		state.opened = nil
		return
	end
	if down and not state.pressed then
		state.pressed = now
		state.opened = false
	end
	if down and state.pressed and not state.opened and now - state.pressed >= V.ReloadHoldTime then
		state.opened = true
		return "menu"
	end
	if not down and state.pressed then
		local action = state.opened and "release_menu" or (now - state.pressed >= V.ReloadHoldTime and "menu" or "tap")
		state.pressed = nil
		state.opened = nil
		return action
	end
end
