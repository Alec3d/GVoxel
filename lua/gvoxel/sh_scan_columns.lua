-- Cache complete axis columns instead of tracing the same nearby surfaces at
-- every node. Complex/ambiguous columns fall back to the original local rays.
local V = GVoxel
local names = { "x", "y", "z" }
local uAxes, vAxes = { "y", "z", "x" }, { "z", "x", "y" }
function V.ColumnScanTrace(r, raw, contents)
	local columns = { {}, {}, {} }
	local stats = { rays = 0, hits = 0, fallbacks = 0, compiled = 0 }
	local noHit = { Hit = false, StartSolid = false, AllSolid = false, Fraction = 1 }
	local allSolid = { Hit = false, StartSolid = true, AllSolid = true, Fraction = 1 }
	local function trace(a, b)
		stats.rays = stats.rays + 1
		return raw(a, b)
	end
	local function buildRaw(axis, a)
		local name = names[axis]
		local low = Vector(a.x, a.y, a.z)
		low[name] = r.origin[name] - r.step * 2
		local high = Vector(low.x, low.y, low.z)
		high[name] = r.origin[name] + V.RegionAxisSize(r, name) + r.step * 2
		local direction = Vector()
		direction[name] = 1
		local pos = low
		local column = { solid = contents(low), events = {} }
		for _ = 1, 128 do
			local tr = trace(pos, high)
			local point, kind, hit
			if tr.StartSolid then
				if tr.AllSolid then
					return column
				end
				local fraction = tr.FractionLeftSolid or 0
				if fraction <= 0 or fraction >= 1 then
					return false
				end
				point = pos + (high - pos) * fraction
				kind = "exit"
				hit = trace(point + direction * 0.125, point - direction * 0.125)
				if not hit.HitWorld or not hit.HitNormal or hit.HitNormal:LengthSqr() < 0.5 then
					return false
				end
			elseif tr.Hit and tr.HitWorld and tr.HitPos then
				point = tr.HitPos
				hit = tr
				if tr.HitTexture == "**studio**" then
					return false
				end
				kind = tr.HitTexture == "**displacement**" and "surface" or "enter"
			else
				return column
			end
			if point[name] < pos[name] - 0.00001 or point[name] > high[name] then
				return false
			end
			column.events[#column.events + 1] = { t = point[name], kind = kind, hit = hit, point = point }
			pos = point + direction * 0.03125
			if pos[name] >= high[name] then
				return column
			end
		end
		return false
	end
	local function build(axis, a, x, y)
		local column = buildRaw(axis, a)
		local compiled
		if r.bspTerrainColumns then
			compiled = r.bspTerrainColumns[axis][x + y * 33]
		end
		if not column then
			if not compiled or #compiled == 0 then
				return false
			end
			-- Source sometimes cannot report FractionLeftSolid on a long
			-- column. Keep known terrain plus authored structural boundaries;
			-- local distance queries still use the untouched engine trace.
			column =
				{ solid = false, events = V.BSPColumnEvents and V.BSPColumnEvents(r, axis, a) or {}, fallback = true }
		end
		local events = {}
		for _, event in ipairs(column.events) do
			if not compiled or event.kind ~= "surface" then
				events[#events + 1] = event
			end
		end
		for _, event in ipairs(compiled or {}) do
			events[#events + 1] = event
			stats.compiled = stats.compiled + 1
		end
		table.sort(events, function(a, b)
			return a.t < b.t
		end)
		-- Follow oriented entry/exit boundaries, rather than splitting the
		-- gap halfway between two unrelated surfaces. A second upward sheet
		-- inside soil is not a new air pocket. Native ceilings reopen air.
		local inside
		local active = {}
		for i = #events, 1, -1 do
			local event = events[i]
			local n = event.hit.HitNormal[names[axis]]
			if math.abs(n) > 0.000001 then
				if inside == nil then
					inside = n < 0
				end
				local after = n > 0
				if event.kind ~= "surface" or inside ~= after then
					active[#active + 1] = event
				end
				inside = after
			else
				active[#active + 1] = event
			end
		end
		column.events = {}
		for i = #active, 1, -1 do
			column.events[#column.events + 1] = active[i]
		end
		return column
	end
	local function columnAt(axis, a)
		local u, v = uAxes[axis], vAxes[axis]
		local x = math.floor((a[u] - r.origin[u]) / r.step + 0.5)
		local y = math.floor((a[v] - r.origin[v]) / r.step + 0.5)
		local rows = columns[axis]
		local row = rows[y]
		if not row then
			row = {}
			rows[y] = row
		end
		local column = row[x]
		if column == nil then
			column = build(axis, a, x, y)
			row[x] = column
		end
		return column
	end
	local function query(a, b)
		local axis = a.x ~= b.x and 1 or (a.y ~= b.y and 2 or 3)
		local name = names[axis]
		local column = columnAt(axis, a)
		if not column or column.fallback then
			stats.fallbacks = stats.fallbacks + 1
			return trace(a, b)
		end
		stats.hits = stats.hits + 1
		local solid = column.solid
		local start, span = a[name], b[name] - a[name]
		for _, e in ipairs(column.events) do
			if e.t > start then
				break
			end
			if e.kind ~= "surface" then
				solid = e.kind == "enter"
			end
		end
		local sign = span > 0 and 1 or -1
		local first, last, increment = 1, #column.events, 1
		if sign < 0 then
			first, last, increment = #column.events, 1, -1
		end
		for i = first, last, increment do
			local e = column.events[i]
			local f = (e.t - start) / span
			if f > 0.0000001 and f <= 1 then
				if solid then
					if (sign > 0 and e.kind == "exit") or (sign < 0 and e.kind == "enter") then
						return {
							StartSolid = true,
							AllSolid = false,
							FractionLeftSolid = f,
							ExitNormal = e.hit.HitNormal,
						}
					end
				else
					return {
						Hit = true,
						HitWorld = true,
						StartSolid = false,
						AllSolid = false,
						HitPos = e.point,
						Fraction = f,
						HitNormal = e.hit.HitNormal,
						HitTexture = e.hit.HitTexture,
						HitSky = e.hit.HitSky,
						HitNoDraw = e.hit.HitNoDraw,
					}
				end
			end
		end
		return solid and allSolid or noHit
	end
	local function terrainSign(p)
		local column = columnAt(3, p)
		if not column then
			return
		end
		local below, above
		for _, event in ipairs(column.events) do
			if math.abs(event.hit.HitNormal.z) > 0.000001 and not event.hit.HitSky then
				if event.t >= p.z then
					above = event
					break
				end
				below = event
			end
		end
		local nearest = above or below
		if
			nearest
			and nearest.kind == "surface"
			and not nearest.hit.HitSky
			and math.abs(nearest.hit.HitNormal.z) > (nearest.compiled and 0.000001 or 0.5)
		then
			return (p - nearest.point):Dot(nearest.hit.HitNormal) < 0 and -1 or 1, true
		end
		-- The structural boundary is authoritative even when native contents
		-- are empty. Tell ScanDensity not to override this air with a nearby
		-- displacement ray pointing at another layer.
		if nearest then
			return nil, true
		end
	end
	return query, stats, terrainSign
end
