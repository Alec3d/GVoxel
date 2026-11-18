-- Shared deterministic brush field: the seed travels with the edit, never a
-- list of random secondary spheres or client-specific math.random state.
local V = GVoxel
local floor, sqrt = math.floor, math.sqrt
local strideX, strideY, strideZ = 73856093, 19349663, 83492791
local modulus = 2147483647

local function hash(n)
	return (((n % modulus) * 48271) % modulus) / 1073741823.5 - 1
end

local function noise(x, y, z, seed)
	local ix, iy, iz = floor(x), floor(y), floor(z)
	local u, v, w = x - ix, y - iy, z - iz
	u = u * u * (3 - 2 * u)
	v = v * v * (3 - 2 * v)
	w = w * w * (3 - 2 * w)
	-- Neighbours differ only by an integer stride. These small lattice
	-- coordinates and network seeds keep all eight sums exact in Lua.
	local a = ix * strideX + iy * strideY + iz * strideZ + seed * 104729
	local b, c = a + strideY, a + strideZ
	local d = c + strideY
	local left = 1 - u
	local ab = (hash(a) * left + hash(a + strideX) * u) * (1 - v)
		+ (hash(b) * left + hash(b + strideX) * u) * v
	local cd = (hash(c) * left + hash(c + strideX) * u) * (1 - v)
		+ (hash(d) * left + hash(d + strideX) * u) * v
	return ab * (1 - w) + cd * w
end

function V.BrushInnerRadius(radius, seed, centerZ, floorZ)
	local core = seed and seed ~= 0 and radius * 0.6 or radius
	-- A clipped blast's enclosing sphere is not a guaranteed empty core:
	-- cells below the preserved floor must never use the full-sphere shortcut.
	if floorZ ~= nil then
		return math.min(core, math.max(0, centerZ - floorZ))
	end
	return core
end

-- Negative = inside the removal/addition brush. Direction-only noise keeps
-- every radial segment connected to the core, without detached void pockets.
-- The deformed radius is bounded by [0.6 R, R], retaining spherical broadphase.
function V.BrushSample(p, center, radius, seed, floorZ)
	local x, y, z = p.x - center.x, p.y - center.y, p.z - center.z
	local distance = sqrt(x * x + y * y + z * z)
	if not seed or seed == 0 then
		local value = distance - radius
		return floorZ ~= nil and math.max(value, floorZ - p.z) or value
	end
	if distance < 1e-9 then
		local value = -radius * 0.8
		return floorZ ~= nil and math.max(value, floorZ - p.z) or value
	end
	x = x / distance
	y = y / distance
	z = z / distance
	local scale = 0.8
		+ 0.12 * noise(x * 1.7, y * 1.7, z * 1.7, seed)
		+ 0.055 * noise(x * 3.4, y * 3.4, z * 3.4, seed + 101)
		+ 0.025 * noise(x * 6.8, y * 6.8, z * 6.8, seed + 211)
	local value = distance - radius * scale
	return floorZ ~= nil and math.max(value, floorZ - p.z) or value
end

-- Shape dimensions are integer ratios of the tool scale, or an angle for cones.
V.BrushShapes = {
    { "Sphère", {} },
    { "Boîte", { "Longueur (%)", "Largeur (%)", "Hauteur (%)" } },
    { "Cylindre", { "Diamètre (%)", "Hauteur (%)" } },
    { "Cône", { "Angle du cône (°)", "Hauteur (%)" } },
    { "Pyramide", { "Longueur (%)", "Largeur (%)", "Hauteur (%)" } },
    { "Tore", { "Diamètre (%)", "Épaisseur (%)" } },
}

-- Internal cut: half-extents in two-unit steps, then yaw in half-turn steps of 1/128.
V.VehicleBreachShape = 7

function V.ValidBrushShape(shape)
    if type(shape)~="table" or type(shape[1])~="number" then return false end
    if shape[1] == V.VehicleBreachShape then
        if #shape ~= 5 then return false end
        for i = 2, 5 do
            local n = shape[i]
            if type(n) ~= "number" or n < (i == 5 and 0 or 1) or n > 127 or n ~= math.floor(n) then return false end
        end
        return true
    end
    local entry=V.BrushShapes[shape[1]]
    if not entry or shape[1]==1 or #shape~=#entry[2]+1 then return false end
    for index,label in ipairs(entry[2]) do
        local value=shape[index+1]
        local angle=label=="Angle du cône (°)"
        if type(value)~="number" or value<(angle and 10 or 25) or value>(angle and 60 or 100)
            or value~=math.floor(value) then return false end
    end
    return true
end

function V.ValidShapedStroke(shape, radius, adding, seed, floorZ, plane)
    if not V.ValidBrushShape(shape) or plane or floorZ or (seed or 0) ~= 0 then return false end
    if shape[1] == V.VehicleBreachShape then
        return not adding and radius == 2 * math.max(shape[2], shape[3], shape[4])
    end
    return radius >= 1 and radius <= 80
end

function V.BrushShapeFromSettings(ply)
    local function setting(name,default,low,high)
        local value=ply:GetInfoNum(name,default)
        if value~=value then return default end
        return math.floor(math.Clamp(value,low,high)+0.5)
    end
    local id=setting("vm_brush_shape",1,1,#V.BrushShapes)
    if id==1 then return end
    local shape={id}
    for index,label in ipairs(V.BrushShapes[id][2]) do
        local angle=label=="Angle du cône (°)"
        shape[index+1]=setting("vm_brush_shape_"..id.."_"..index,angle and 45 or 100,angle and 10 or 25,angle and 60 or 100)
    end
    return shape
end

function V.BrushShapeDimensions(shape,radius)
    local id=shape[1]
    if id == V.VehicleBreachShape then
        local a, b, c = 2 * shape[2], 2 * shape[3], 2 * shape[4]
        local angle = shape[5] * math.pi / 128
        local cos, sin = math.cos(angle), math.sin(angle)
        return a * math.abs(cos) + b * math.abs(sin), a * math.abs(sin) + b * math.abs(cos), c, {cos, sin, a, b}
    end
    local a,b,c=shape[2]*radius/100,shape[3]*radius/100,(shape[4] or 100)*radius/100
    if id==2 or id==5 then return a,b,c end
    if id==3 then return a,a,b end
    if id==4 then
        local slope=math.tan(math.rad(shape[2]))
        local height=math.min(b,radius/(2*slope))
        local base=2*height*slope
        return base,base,height
    end
    local tube=a*shape[3]/225
    return a,a,tube,a-tube
end

function V.SampleBrushShape(id,x,y,z,a,b,c,ring)
    if id==2 then return math.max(math.abs(x)-a,math.abs(y)-b,math.abs(z)-c) end
    if id==V.VehicleBreachShape then
        return math.max(math.abs(x*ring[1]+y*ring[2])-ring[3], math.abs(y*ring[1]-x*ring[2])-ring[4], math.abs(z)-c)
    end
    if id==5 then
        local taper=(c-z)/(2*c)
        return math.max(-z-c,z-c,math.abs(x)-a*taper,math.abs(y)-b*taper)
    end
    local radial=math.sqrt(x*x+y*y)
    if id==3 then return math.max(radial-a,math.abs(z)-c) end
    if id==4 then return math.max(-z-c,z-c,radial-a*(c-z)/(2*c)) end
    local offset=radial-ring
    return math.sqrt(offset*offset+z*z)-c
end

function V.WriteBrushShape(shape)
    net.WriteBool(shape~=nil)
    if not shape then return end
    net.WriteUInt(shape[1],3)
    for index=2,#shape do net.WriteUInt(shape[index],7) end
end

function V.ReadBrushShape()
    if not net.ReadBool() then return end
    local id=net.ReadUInt(3)
    local entry=V.BrushShapes[id]
    local shape={id}
    if id == V.VehicleBreachShape then
        for index=2,5 do shape[index]=net.ReadUInt(7) end
    elseif entry then
        for index=1,#entry[2] do shape[index+1]=net.ReadUInt(7) end
    end
    return shape
end
