-- Read the diffuse irradiance at the ORIGINAL world position, not the ambient
-- cube of an adjacent room. Valve BSP RGBExp32 samples are linear, not sRGB.
local V = GVoxel
local powers = {}
for e = 0, 255 do
	powers[e] = 2 ^ (e >= 128 and e - 256 or e) / 255
end

function V.PrepareBSPLightmap(data, face)
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
	return {
		bytes = bytes,
		width = w,
		height = h,
		start = start + 1,
		u = tex.lu,
		v = tex.lv,
		uo = (tex.luo or 0) - min[1],
		vo = (tex.lvo or 0) - min[2],
	}
end

local function texel(bytes, offset)
	local r, g, b, e = string.byte(bytes, offset, offset + 3)
	local scale = powers[e]
	return r * scale, g * scale, b * scale
end

function V.SamplePreparedBSPLightmap(map, point)
	local u = point:Dot(map.u) + map.uo
	local v = point:Dot(map.v) + map.vo
	if u ~= u or v ~= v then
		return
	end
	-- Edges share the border luxels. Clamp roundoff, not arbitrary other walls.
	local w, h = map.width, map.height
	if u < -1 or v < -1 or u > w or v > h then
		return
	end
	u = math.max(0, math.min(w - 1, u))
	v = math.max(0, math.min(h - 1, v))
	local x, y = math.floor(u), math.floor(v)
	local fx, fy = u - x, v - y
	local bytes = map.bytes
	local top = map.start + (y * w + x) * 4
	local r, g, b = texel(bytes, top)
	if fx ~= 0 then
		local rr, gg, bb = texel(bytes, top + 4)
		r, g, b = r + (rr - r) * fx, g + (gg - g) * fx, b + (bb - b) * fx
	end
	if fy ~= 0 then
		local bottom = top + w * 4
		local br, bg, bb = texel(bytes, bottom)
		if fx ~= 0 then
			local rr, gg, blue = texel(bytes, bottom + 4)
			br, bg, bb = br + (rr - br) * fx, bg + (gg - bg) * fx, bb + (blue - bb) * fx
		end
		r, g, b = r + (br - r) * fy, g + (bg - g) * fy, b + (bb - b) * fy
	end
	return Vector(r, g, b)
end

function V.SampleBSPLightmap(data, face, point)
	local map = V.PrepareBSPLightmap(data, face)
	return map and V.SamplePreparedBSPLightmap(map, point)
end

function V.SurfaceLightmap(r, source, point)
	if not source then
		return
	end
	if source.voxelLightmap == nil or source.voxelLightmapFace ~= source.nativeFace
		or source.voxelLightmapBSP ~= r.bsp then
		source.voxelLightmap = V.PrepareBSPLightmap(r.bsp, source.nativeFace) or false
		source.voxelLightmapFace = source.nativeFace
		source.voxelLightmapBSP = r.bsp
	end
	if source.voxelLightmap then
		return V.SamplePreparedBSPLightmap(source.voxelLightmap, point)
	end
end
