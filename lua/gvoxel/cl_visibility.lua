-- Conservative opening frustums, plus bounded native LOS checks for models
-- missing from the camera PVS. No GPU readbacks or world-wide visibility bypass.
local V = GVoxel

-- Named targets live in the material system. Keep a finite set across
-- window resizes. Both tiers fill the entire texture, and callers keep the
-- main camera's aspect so sampling the whole texture preserves projection.
function V.BackgroundTargetSize(w, h)
	if w >= 1024 and h >= 512 then
		return 1024, 512
	end
	return 512, 256
end

function V.ViewFrustum(view, w, h)
	local f = view.angles:Forward()
	local right = view.angles.Right and view.angles:Right() or f:Cross(Vector(0, 0, 1)):GetNormalized()
	if right:LengthSqr() < 0.5 then
		right = Vector(1, 0, 0)
	end
	local up = view.angles.Up and view.angles:Up() or right:Cross(f):GetNormalized()
	local aspect = view.aspect or view.aspectratio
	if not aspect or aspect <= 0 then
		aspect = w / h
	end
	-- Source may report the reference 4:3 FOV or the adjusted horizontal FOV.
	-- The larger cone is conservative for either representation.
	local horizontal = math.tan(math.rad(view.fov or 90) / 2) * math.max(1, aspect / (4 / 3))
	local vertical = horizontal / aspect
	return {
		eye = view.origin,
		planes = { f, f * horizontal + right, f * horizontal - right, f * vertical + up, f * vertical - up },
	}
end

function V.BoundsInView(frustum, low, high)
	if not low or not high then
		return true
	end
	local eye = frustum.eye
	for _, n in ipairs(frustum.planes) do
		local x = n.x >= 0 and high.x or low.x
		local y = n.y >= 0 and high.y or low.y
		local z = n.z >= 0 and high.z or low.z
		if (x - eye.x) * n.x + (y - eye.y) * n.y + (z - eye.z) * n.z < -0.01 then
			return false
		end
	end
	return true
end

function V.VertexBounds(vertices, checkpoint)
	local low, high = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for i, vertex in ipairs(vertices) do
		local p = vertex.pos
		low.x, low.y, low.z = math.min(low.x, p.x), math.min(low.y, p.y), math.min(low.z, p.z)
		high.x, high.y, high.z = math.max(high.x, p.x), math.max(high.y, p.y), math.max(high.z, p.z)
		if checkpoint and i % 128 == 0 then checkpoint() end
	end
	return low, high
end

-- Prepared with the exit mesh. Indoor exits without sky in their native
-- leaves do not need another full sky-camera RenderView every moving frame.
function V.PortalSkyFlags(data, vertices, normal, checkpoint)
	if not data or not data.nodes or not data.leaves then
		return
	end
	local flags = 0
	for i = 1, #vertices, 3 do
		local point = (vertices[i].pos + vertices[i + 1].pos + vertices[i + 2].pos) / 3 + normal * 2
		local leaf = V.BSPLeaf(data, point)
		if leaf.flags == nil then
			return
		end
		flags = bit.bor(flags, bit.band(leaf.flags, 5))
		if bit.band(flags, 1) ~= 0 then
			return flags
		end
		if checkpoint and i % 96 == 1 then
			checkpoint()
		end
	end
	return flags
end

-- Tight cone through an aperture rectangle. Unlike the camera frustum this
-- excludes scenery that cannot contribute a pixel to this particular exit.
local function portalCorners(portal)
	local f = portal.face
	local low, high = portal.low, portal.high
	local a, b, c, d
	if math.abs(f.normal.x) > 0.5 then
		a, b, c, d =
			Vector(low.x, low.y, low.z),
			Vector(low.x, high.y, low.z),
			Vector(low.x, high.y, high.z),
			Vector(low.x, low.y, high.z)
	elseif math.abs(f.normal.y) > 0.5 then
		a, b, c, d =
			Vector(low.x, low.y, low.z),
			Vector(high.x, low.y, low.z),
			Vector(high.x, low.y, high.z),
			Vector(low.x, low.y, high.z)
	else
		a, b, c, d =
			Vector(low.x, low.y, low.z),
			Vector(high.x, low.y, low.z),
			Vector(high.x, high.y, low.z),
			Vector(low.x, high.y, low.z)
	end
	return { a, b, c, d }
end
function V.PortalFrustum(frustum, portal, portalOnly)
	local eye = frustum.eye
	local f = portal.face
	local result = { eye = eye, planes = {} }
	if not portalOnly then
		for _, n in ipairs(frustum.planes) do
			result.planes[#result.planes + 1] = n
		end
	end
	-- A camera on the exit plane has a degenerate cone; keep the wider view.
	if math.abs((eye - f.point):Dot(f.normal)) < 0.01 then
		return result
	end
	local corners = portalCorners(portal)
	local center = (portal.low + portal.high) * 0.5 - eye
	for i = 1, 4 do
		local n = (corners[i] - eye):Cross(corners[i % 4 + 1] - eye):GetNormalized()
		if n:Dot(center) < 0 then
			n = -n
		end
		result.planes[#result.planes + 1] = n
	end
	return result
end

local function belongsTo(entity, target)
	if not IsValid(target) then
		return false
	end
	for _ = 1, 16 do
		-- NULL is truthy and exposes Entity methods, but GetParent on it
		-- throws. An unparented valid entity returns NULL, not Lua nil.
		if not IsValid(entity) then
			return false
		end
		if entity == target then
			return true
		end
		if not entity.GetParent then
			return false
		end
		local parent = entity:GetParent()
		if parent == entity then
			return false
		end
		entity = parent
	end
	return false
end

-- Only the old BSP INSIDE the cage is replaced. Trace the native foreground
-- and the scenery after the exit separately, including doors and solid props.
-- Voxel depth is already drawn by the compositor and still masks this model.
-- nil means the caller's trace budget ran out: never treat that as visibility.
function V.ExteriorLineOfSight(r, eye, target, low, high, observer, nativeTrace, takeBudget)
	nativeTrace = nativeTrace or util.TraceLine
	local center = (low + high) * 0.5
	local half = (high - low) * 0.45
	local filter = { observer }
	local mask = MASK_VISIBLE_AND_NPCS or MASK_VISIBLE or MASK_SOLID
	local function clear(a, b)
		if takeBudget and not takeBudget() then
			return
		end
		local hit = nativeTrace({ start = a, endpos = b, filter = filter, mask = mask })
		if not hit or hit.StartSolid or hit.AllSolid then
			return false
		end
		if not hit.Hit then
			return true
		end
		return not hit.HitWorld and (belongsTo(hit.Entity, target) or belongsTo(target, hit.Entity))
	end
	for sample = 0, 8 do
		local point = center
		if sample > 0 then
			local corner = sample - 1
			point = center
				+ Vector(
					corner % 2 == 0 and -half.x or half.x,
					math.floor(corner / 2) % 2 == 0 and -half.y or half.y,
					corner < 4 and -half.z or half.z
				)
		end
		local delta = point - eye
		local distance = delta:Length()
		if distance > 0.01 then
			local direction = delta / distance
			local entry, exit = V.CubeRayInterval(r, eye, direction)
			local visible
			if not entry or entry >= distance then
				visible = clear(eye, point)
			else
				visible = true
				if entry > 0.01 then
					visible = clear(eye, eye + direction * (entry - 0.01))
				end
				if visible and exit < distance then
					visible = clear(eye + direction * math.min(distance, exit + 0.01), point)
				end
			end
			if visible == nil then
				return
			end
			if visible then
				return true
			end
		end
	end
	return false
end

local function clipInside(polygon, n, d)
	local out = {}
	local a = polygon[#polygon]
	if not a then
		return out
	end
	local da = a:Dot(n) - d
	for _, b in ipairs(polygon) do
		local db = b:Dot(n) - d
		if (da >= 0) ~= (db >= 0) then
			out[#out + 1] = a + (b - a) * (da / (da - db))
		end
		if db >= 0 then
			out[#out + 1] = b
		end
		a, da = b, db
	end
	return out
end

-- Immutable original occluders, clipped once to the scan. Sculpture does not
-- change this list: it describes what the native BSP could hide, not voxels.
function V.BuildNativeBackgroundData(r, checkpoint)
	if not r.bsp then
		return
	end
	local result = { data = r.bsp, faces = {} }
	local high = r.origin + V.RegionSize(r)
	local function addBounds(low, big)
		if not V.BoundsOverlap(low, big, r.origin, high) then
			return
		end
		result.faces[#result.faces + 1] = {
			low = Vector(math.max(low.x, r.origin.x), math.max(low.y, r.origin.y), math.max(low.z, r.origin.z)),
			high = Vector(math.min(big.x, high.x), math.min(big.y, high.y), math.min(big.z, high.z)),
		}
	end
	for i, face in ipairs(r.bsp.faces) do
		local low, big = face.dispLow or face.low, face.dispHigh or face.high
		if V.BoundsOverlap(low, big, r.origin, high) then
			-- Non-flat displacements are only known by conservative bounds.
			-- Never infer visibility through their flat support polygon.
			local displaced = face.displacement
				and (low:DistToSqr(face.low) > 1e-10 or big:DistToSqr(face.high) > 1e-10)
			if displaced and face.dispGrid then
				-- The maximum height of a distant hill must not turn the
				-- entire support quad into an opaque box. Each native grid
				-- patch is enclosed separately, conservatively covering BOTH
				-- diagonal triangulations without approximating visibility.
				local grid, width = face.dispGrid, face.dispWidth
				for y = 0, width - 2 do
					for x = 0, width - 2 do
						local a, b = grid[y * width + x + 1], grid[y * width + x + 2]
						local c, d = grid[(y + 1) * width + x + 1], grid[(y + 1) * width + x + 2]
						local small = Vector(
							math.min(a.x, b.x, c.x, d.x),
							math.min(a.y, b.y, c.y, d.y),
							math.min(a.z, b.z, c.z, d.z)
						)
						local big = Vector(
							math.max(a.x, b.x, c.x, d.x),
							math.max(a.y, b.y, c.y, d.y),
							math.max(a.z, b.z, c.z, d.z)
						)
						addBounds(small, big)
						if checkpoint and (y * (width - 1) + x) % 64 == 63 then
							checkpoint()
						end
					end
				end
			elseif displaced then
				-- A large displacement extends far beyond the exit plane.
				-- Only its intersection with this cube could be an OLD
				-- occluder removed by sculpture; the exterior stays native.
				addBounds(low, big)
			else
				local polygon = face.vertices
				for _, axis in ipairs({ "x", "y", "z" }) do
					local n = Vector()
					n[axis] = 1
					polygon = clipInside(polygon, n, r.origin[axis])
					polygon = clipInside(polygon, -n, -high[axis])
				end
				if #polygon >= 3 then
					local vertices = {}
					for _, p in ipairs(polygon) do
						vertices[#vertices + 1] = { pos = p }
					end
					local a, b = V.VertexBounds(vertices)
					result.faces[#result.faces + 1] = { low = a, high = b, polygon = polygon }
				end
			end
		end
		if checkpoint and i % 128 == 0 then
			checkpoint()
		end
	end
	return result
end

function V.PortalNeedsBackground(data, portal, frustum)
	if not data then
		return true
	end
	local eye = frustum.eye
	if V.BSPSolid(data.data, eye) then
		return true
	end
	local cone = V.PortalFrustum(frustum, portal)
	if cone == frustum then
		return true
	end
	local exitNormal = -portal.face.normal
	local exitDistance = exitNormal:Dot(portal.face.point)
	for _, face in ipairs(data.faces) do
		local possible = true
		for _, n in ipairs(cone.planes) do
			local p = Vector(
				n.x >= 0 and face.high.x or face.low.x,
				n.y >= 0 and face.high.y or face.low.y,
				n.z >= 0 and face.high.z or face.low.z
			)
			-- Touching a cone edge is zero projected area, not an occluder.
			if n:Dot(p - eye) <= 1e-7 then
				possible = false
				break
			end
		end
		if possible then
			if not face.polygon then
				return true, face
			end -- uncertain displacement
			local polygon = face.polygon
			for _, n in ipairs(cone.planes) do
				polygon = clipInside(polygon, n, n:Dot(eye))
				if #polygon < 3 then
					break
				end
			end
			polygon = clipInside(polygon, exitNormal, exitDistance)
			if #polygon >= 3 then
				local area = Vector()
				for j = 2, #polygon - 1 do
					area = area + (polygon[j] - polygon[1]):Cross(polygon[j + 1] - polygon[1])
				end
				if area:LengthSqr() > 1e-10 then
					return true, face
				end
			end
		end
	end
	return false
end
