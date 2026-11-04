-- Tank explosions use the RPG crater at the actual detonation point.
-- Model dimensions choose a radius; they never gate an impact or move it.
local V = GVoxel
local clearance = 1.05
local function finite(n)
	return type(n) == "number" and n == n and math.abs(n) < 1e7
end
local function point(p)
	return p and finite(p.x) and finite(p.y) and finite(p.z)
end

function V.MeasureTankOpening(tank)
	if not IsValid(tank) or not tank.GetModelBounds or not tank.LocalToWorld then
		return
	end
	local mins, maxs = tank:GetModelBounds()
	local scale = tank.GetModelScale and tank:GetModelScale() or 1
	if not point(mins) or not point(maxs) or not finite(scale) or scale <= 0 then
		return
	end
	mins, maxs = mins * scale, maxs * scale
	local lowY, highY = mins.y, maxs.y
	local floorZ, topZ = math.huge, -math.huge
	for _, x in ipairs({ mins.x, maxs.x }) do
		for _, y in ipairs({ mins.y, maxs.y }) do
			for _, z in ipairs({ mins.z, maxs.z }) do
				local p = tank:LocalToWorld(Vector(x, y, z))
				if not point(p) then
					return
				end
				floorZ = math.min(floorZ, p.z)
				topZ = math.max(topZ, p.z)
			end
		end
	end
	-- Glide's wheel centers are updated by its suspension. Include their
	-- contact bottoms, which can hang below the compiled chassis model.
	for _, wheel in pairs(tank.wheels or {}) do
		if IsValid(wheel) and wheel.GetRadius and wheel.GetPos then
			local p, radius = wheel:GetPos(), wheel:GetRadius()
			if point(p) and finite(radius) and radius > 0 then
				floorZ = math.min(floorZ, p.z - radius)
				topZ = math.max(topZ, p.z + radius)
				if tank.WorldToLocal then
					local localPos = tank:WorldToLocal(p)
					lowY = math.min(lowY, localPos.y - radius * 0.2)
					highY = math.max(highY, localPos.y + radius * 0.2)
				end
			end
		end
	end
	local width, height = highY - lowY, topZ - floorZ
	if width <= 0 or height <= 0 or not finite(width) or not finite(height) then
		return
	end
	return { width = width, height = height, halfWidth = width * clearance / 2, heightClear = height * clearance }
end

-- Clear the obsolete exported preflight on a Lua refresh.
V.PrepareTankOpening = nil
local sequence = 0
function V.TankCraterRadius(shape)
	local base = V.GetRPGCraterRadius and V.GetRPGCraterRadius() or 112
	-- The RPG noise retains a guaranteed core of 0.6 R. Aim for at least
	-- model width/height diameters +5% at the impact plane, without a floor
	-- test or the much larger circumscribed chassis/depth sphere.
	local section = shape and math.max(shape.halfWidth, shape.heightClear / 2) / 0.6 or base
	return math.ceil(math.max(base, section))
end
function V.QueueGlideTankCrater(ply, tank, impact)
	if not point(impact) then
		return false
	end
	local shape = V.MeasureTankOpening(tank)
	local radius = V.TankCraterRadius(shape)
	sequence = sequence % 65535 + 1
	local accepted = V.QueueExplosionCrater(ply, impact, radius, sequence, "glide_tank")
	if accepted then
		local r = V.GetServerScanRegion and V.GetServerScanRegion()
		if r then
			r.tankStats = {
				status = "impact RPG en file",
				mode = "rpg",
				width = shape and shape.width or 0,
				height = shape and shape.height or 0,
				openingWidth = shape and shape.halfWidth * 2 or 0,
				radius = radius,
				seed = sequence,
				impact = V.SnapScanPosition(impact),
			}
		end
	end
	return accepted
end
concommand.Add("vm_tank_stats", function(ply)
	if IsValid(ply) and not V.CanManageScan(ply) then
		return
	end
	local scan = V.GetScanSession()
	local s = scan and scan.region.tankStats
	if not s then
		print("[GVoxel] Aucun impact de char mesure.")
		return
	end
	print(
		string.format(
			"[GVoxel] Char : %s | cratere RPG au point d'impact | modele %.2f x %.2f SU | largeur visee %.2f (+5%%) | rayon %d | graine %d",
			s.status,
			s.width,
			s.height,
			s.openingWidth or 0,
			s.radius or 0,
			s.seed or 0
		)
	)
	if s.impact then
		print(string.format("[GVoxel] Impact : %.3f %.3f %.3f", s.impact.x, s.impact.y, s.impact.z))
	end
end)
