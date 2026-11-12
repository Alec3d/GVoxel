local V = GVoxel
local axes = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }
local rayStep, rayStarts, rayDeltas

local function scanRays(step)
	if rayStep ~= step then
		local reach = step * 1.75
		rayStarts, rayDeltas = {}, {}
		for i, axis in ipairs(axes) do
			rayStarts[i], rayDeltas[i] = axis * reach, axis * (-2 * reach)
		end
		rayStep = step
	end
	return rayStarts, rayDeltas
end

local function surfaceDistance(delta, planeDistance)
	local distance = math.abs(planeDistance)
	-- A nearly parallel ray may touch a finite face far from this lattice
	-- point. Its infinite plane is not evidence for a zero-distance node.
	if distance < 1 / 128 and delta:LengthSqr() > 1 / 64 then
		return math.sqrt(delta:LengthSqr())
	end
	return distance
end

-- Sample the volume, not just a height map: six local ray directions refine
-- brush occupancy and detect displacement surfaces near each lattice point.
-- Providers are injected so this numerical part can be tested without a map.
function V.ScanDensity(r, p, solid, trace, terrainSign)
	local starts, deltas = scanRays(r.step)
	local distance, displacementDistance, displacementSign = r.step, math.huge, 1
	local planeHits
	for i = 1, #starts do
		local start = p + starts[i]
		local delta = deltas[i]
		local hit = trace(start, start + delta)
		if hit.StartSolid and not hit.AllSolid and (hit.FractionLeftSolid or 0) > 0 then
			local exit = p - (start + delta * hit.FractionLeftSolid)
			distance = math.min(
				distance,
				hit.ExitNormal and surfaceDistance(exit, exit:Dot(hit.ExitNormal)) or exit:Length()
			)
		elseif
			hit.HitWorld
			and hit.Hit
			and not hit.HitSky
			and not hit.StartSolid
			and hit.HitTexture ~= "**studio**"
		then
			local offset = p - hit.HitPos
			local planeDistance = offset:Dot(hit.HitNormal)
			local d = surfaceDistance(offset, planeDistance)
			if V.RecordScanPlane and r.analysis and hit.HitTexture ~= "**displacement**" then
				planeHits = planeHits or {}
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
	if planeHits and displacementDistance > distance + 0.001 then
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
	local origin, step = r.origin, r.step
	local coordinates = r.scanCoordinates
	if not coordinates or coordinates.ox ~= origin.x or coordinates.oy ~= origin.y
		or coordinates.oz ~= origin.z or coordinates.step ~= step
	then
		coordinates = { ox = origin.x, oy = origin.y, oz = origin.z, step = step, x = {}, y = {}, z = {} }
		for i = 0, 32 do
			-- Preserve Source's float multiply and add rounding.
			local p = origin + Vector(i, i, i) * step
			coordinates.x[i], coordinates.y[i], coordinates.z[i] = p.x, p.y, p.z
		end
		r.scanCoordinates = coordinates
	end
	return Vector(coordinates.x[x], coordinates.y[y], coordinates.z[z]), x, y, z
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

-- Optional server-authored separating plane for subcell fragment cleanup.
-- No client request accepts this payload; it travels only in the edit journal.
function V.WriteEditPlane(plane)
    net.WriteBool(plane~=nil)
    if plane then
        net.WriteUInt(plane.axis-1,2)
        net.WriteBool(plane.sign==1)
        net.WriteFloat(plane.distance)
        net.WriteBool(plane.cell~=nil)
        if plane.cell then for i=1,3 do net.WriteUInt(plane.cell[i],5) end end
    end
end
function V.ReadEditPlane()
    if not net.ReadBool() then return end
    local plane={axis=net.ReadUInt(2)+1,sign=net.ReadBool() and 1 or -1,distance=net.ReadFloat()}
    if net.ReadBool() then plane.cell={net.ReadUInt(5),net.ReadUInt(5),net.ReadUInt(5)} end
    return plane
end
