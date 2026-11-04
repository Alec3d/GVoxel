-- Read the diffuse irradiance at the ORIGINAL world position, not the ambient
-- cube of an adjacent room. Valve BSP RGBExp32 samples are linear, not sRGB.
local V = GVoxel
local powers = {}
for e = 0, 255 do
	powers[e] = 2 ^ (e >= 128 and e - 256 or e) / 255
end

function V.SampleBSPLightmap(data, face, point)
	local tex = face and face.tex
	local bytes = data and data.lighting
	local size, min = face and face.lightSize, face and face.lightMin
	if
		not tex
		or not tex.lu
		or not tex.lv
		or not size
		or not min
		or not bytes
		or not face.lightOffset
		or face.lightOffset < 0
	then
		return
	end
	local w, h = size[1] + 1, size[2] + 1
	if w < 1 or h < 1 or w > 256 or h > 256 then
		return
	end
	-- Each style has a base lightmap, then three directional maps if bumped.
	-- Read style zero only; animated lightstyles are not static shadows.
	local style = 0
	if face.lightStyles then
		style = nil
		for i, value in ipairs(face.lightStyles) do
			if value == 255 then
				break
			end
			if value == 0 then
				style = i - 1
				break
			end
		end
		if not style then
			return
		end
	end
	local bumped = bit.band(tex.flags or 0, 2048) ~= 0
	local start = face.lightOffset + style * w * h * 4 * (bumped and 4 or 1)
	if start < 0 or start + w * h * 4 > #bytes then
		return
	end
	local u = point:Dot(tex.lu) + (tex.luo or 0) - min[1]
	local v = point:Dot(tex.lv) + (tex.lvo or 0) - min[2]
	if u ~= u or v ~= v then
		return
	end
	-- Edges share the border luxels. Clamp roundoff, not arbitrary other walls.
	if u < -1 or v < -1 or u > w or v > h then
		return
	end
	u = math.max(0, math.min(w - 1, u))
	v = math.max(0, math.min(h - 1, v))
	local x, y = math.floor(u), math.floor(v)
	local fx, fy = u - x, v - y
	local red, green, blue = 0, 0, 0
	for dy = 0, 1 do
		for dx = 0, 1 do
			local weight = (dx == 0 and 1 - fx or fx) * (dy == 0 and 1 - fy or fy)
			local offset = start + (math.min(y + dy, h - 1) * w + math.min(x + dx, w - 1)) * 4 + 1
			local r, g, b, e = string.byte(bytes, offset, offset + 3)
			local scale = powers[e] * weight
			red = red + r * scale
			green = green + g * scale
			blue = blue + b * scale
		end
	end
	return Vector(red, green, blue)
end

function V.SurfaceLightmap(r, source, point)
	return source and V.SampleBSPLightmap(r.bsp, source.nativeFace, point)
end
