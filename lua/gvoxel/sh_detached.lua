-- Fragment connectivity uses individual collision solids, including pieces
-- smaller than a lattice cell. Uncertain convex contacts remain connected.
local V = GVoxel
local axes = { "x", "y", "z" }
local directions = { {1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1} }
local removalAxes = { 3, 1, 2 }
local removalSigns = { -1, 1 }
local tolerance = 1 / 64

local function readCoordinates(cell, checkpoint)
    if not cell.field then return end
    local _, points = V.CollisionSolidPoints(cell.field, cell.x, cell.y, cell.z, checkpoint)
    for i, vertices in ipairs(points) do
        local coordinates = {}
        for _, p in ipairs(vertices) do
            local n = #coordinates
            coordinates[n+1], coordinates[n+2], coordinates[n+3] = p.x, p.y, p.z
        end
        cell.pieces[i].coordinates = coordinates
        if checkpoint then checkpoint() end
    end
    cell.field = nil
end

local function detachedCell(r, x, y, z, checkpoint, deferCoordinates)
    if not V.ActiveRegionCell(r, x, y, z) or x < 0 or y < 0 or z < 0
        or x >= V.RegionCells(r,"x") or y >= V.RegionCells(r,"y") or z >= V.RegionCells(r,"z") then return end
    local hulls = V.DensityCellSolids(r, x, y, z, checkpoint)
    if #hulls == 0 then return end
    local cell = { x=x, y=y, z=z, key=V.Index(x,y,z,r), pieces={} }
    if #hulls>1 or #hulls[1]~=3 then cell.field=r end
    local sizeX, sizeY, sizeZ = V.RegionAxisSize(r,"x"), V.RegionAxisSize(r,"y"), V.RegionAxisSize(r,"z")
    for i, hull in ipairs(hulls) do
        local piece = { x=x, y=y, z=z, key=cell.key, hull=hull, low=Vector(), high=Vector(), anchored=false }
        for index, axis in ipairs(axes) do
            piece.low[axis], piece.high[axis] = hull[index].low, hull[index].high
        end
        piece.anchored = piece.low.x<=tolerance or piece.low.y<=tolerance or piece.low.z<=tolerance
            or piece.high.x>=sizeX-tolerance or piece.high.y>=sizeY-tolerance or piece.high.z>=sizeZ-tolerance
        cell.pieces[i] = piece
        if checkpoint then checkpoint() end
    end
    if not deferCoordinates then readCoordinates(cell, checkpoint) end
    return cell
end
function V.DetachedCell(r, x, y, z, checkpoint)
    return detachedCell(r, x, y, z, checkpoint, false)
end

local function separatedBy(planes, other, checkpoint)
    local coordinates = other.coordinates
    local cx, cy, cz, sx, sy, sz
    if not coordinates then
        local low, high = other.low, other.high
        cx, cy, cz = (low.x+high.x)/2, (low.y+high.y)/2, (low.z+high.z)/2
        sx, sy, sz = high.x-low.x, high.y-low.y, high.z-low.z
    end
    for _, plane in ipairs(planes) do
        local n = plane.n
        local nx, ny, nz = n.x, n.y, n.z
        local low, high
        if coordinates then
            low, high = math.huge, -math.huge
            for i=1,#coordinates,3 do
                local d = coordinates[i]*nx + coordinates[i+1]*ny + coordinates[i+2]*nz
                low, high = math.min(low,d), math.max(high,d)
            end
        else
            -- A box collider has no separately allocated vertices.
            local center = cx*nx+cy*ny+cz*nz
            local extent = (sx*math.abs(nx)+sy*math.abs(ny)+sz*math.abs(nz))/2
            low, high = center-extent, center+extent
        end
        if high < plane.low-tolerance or low > plane.high+tolerance then return true end
        if checkpoint then checkpoint() end
    end
    return false
end

local function solidsTouch(a, b, aCell, bCell, checkpoint)
    for _, axis in ipairs(axes) do
        if a.high[axis] < b.low[axis]-tolerance or b.high[axis] < a.low[axis]-tolerance then return false end
    end
    if #a.hull == 3 and #b.hull == 3 then return true end
    -- Bounds, support and axis-aligned pairs need no vertex extraction.
    -- The search field is stable while the traversal runs, and only its
    -- original bounds and hull identities are kept for later safety checks.
    if aCell then readCoordinates(aCell, checkpoint) end
    if bCell then readCoordinates(bCell, checkpoint) end
    -- Face normals and edge x grid axes reject diagonal gaps too. A missing
    -- convex edge-pair axis can only preserve a questionable contact, not cut it.
    return not separatedBy(a.hull,b,checkpoint) and not separatedBy(b.hull,a,checkpoint)
end
function V.DetachedSolidsTouch(a, b, _, checkpoint)
    return solidsTouch(a, b, nil, nil, checkpoint)
end

function V.FindDetachedComponents(r, low, high, checkpoint)
    local records, seen, result = {}, {}, {}
    local maxX,maxY,maxZ=V.RegionCells(r,"x"),V.RegionCells(r,"y"),V.RegionCells(r,"z")
    local function get(x,y,z,overrideCheckpoint)
        if x<0 or y<0 or z<0 or x>=maxX or y>=maxY or z>=maxZ then return end
        local key = V.Index(x,y,z,r)
        local check = overrideCheckpoint or checkpoint
        if records[key]==nil then records[key]=detachedCell(r,x,y,z,check,true) or false end
        if check then check() end
        return records[key] or nil
    end
    local function connect(cell,piece,marker,stack)
        if not cell then return end
        for _, other in ipairs(cell.pieces) do
            local previous = seen[other]
            if previous ~= marker and solidsTouch(piece,other,records[piece.key],cell,checkpoint) then
                if previous and previous.anchored then marker.anchored=true return end
                if not previous then seen[other]=marker stack[#stack+1]=other end
            end
            if checkpoint then checkpoint() end
        end
    end
    local function visit(first)
        local marker = { anchored=false }
        local stack, component = {first}, {}
        seen[first] = marker
        while #stack>0 do
            local top=#stack
            local piece=stack[top]
            stack[top]=nil
            component[#component+1] = piece
            if piece.anchored then marker.anchored=true break end
            connect(get(piece.x,piece.y,piece.z),piece,marker,stack)
            for _, d in ipairs(directions) do
                if marker.anchored then break end
                connect(get(piece.x+d[1],piece.y+d[2],piece.z+d[3]),piece,marker,stack)
            end
            if marker.anchored then break end
        end
        if not marker.anchored then
            for i,piece in ipairs(component) do
                readCoordinates(records[piece.key],checkpoint)
                if checkpoint and i%32==0 then checkpoint() end
            end
            result[#result+1]=component
        end
    end
    for z=math.max(0,low.z),math.min(maxZ-1,high.z) do
        for y=math.max(0,low.y),math.min(maxY-1,high.y) do
            for x=math.max(0,low.x),math.min(maxX-1,high.x) do
                local cell = get(x,y,z)
                if cell then for _, piece in ipairs(cell.pieces) do if not seen[piece] then visit(piece) end end end
            end
        end
    end
    -- The lookup pins the original solids for safety checks across our own
    -- removal-only edits. An external edit cancels the entire plan.
    return result, get
end

function V.DetachedRemovalSafe(r, center, radius, allowed, checkpoint, plane)
    local q = center-r.origin
    local reach = radius+(not r.bsp and r.step*math.sqrt(3) or 0)
    local reach2=(reach+tolerance)^2
    local planeAxis=plane and axes[plane.axis]
    local planeLimit=plane and plane.distance-plane.sign*r.origin[planeAxis]+tolerance
    local lo,hi = {},{}
    for index, axis in ipairs(axes) do
        lo[axis]=math.max(0,math.floor((q[axis]-reach)/r.step))
        hi[axis]=math.min(V.RegionCells(r,axis)-1,math.floor((q[axis]+reach)/r.step))
        if q[axis]-reach<=0 or q[axis]+reach>=V.RegionAxisSize(r,axis) then return false end
        if plane and plane.cell then
            lo[axis],hi[axis]=plane.cell[index],plane.cell[index]
            if hi[axis]>=V.RegionCells(r,axis) then return false end
        end
        if plane and (lo[axis]==0 or hi[axis]==V.RegionCells(r,axis)-1) then return false end
    end
    local lookup=allowed.lookup
    for z=lo.z,hi.z do for y=lo.y,hi.y do for x=lo.x,hi.x do
        local cell
        if lookup then cell=lookup(x,y,z,checkpoint)
        else cell=detachedCell(r,x,y,z,checkpoint,true) end
        if cell then for _, piece in ipairs(cell.pieces) do
            if not allowed[piece.hull] then
                if plane then
                    local minimum=plane.sign==1 and piece.low[planeAxis] or -piece.high[planeAxis]
                    if minimum<=planeLimit then return false end
                else
                    local d2 = 0
                    for _, axis in ipairs(axes) do
                        local d=math.max(piece.low[axis]-q[axis],0,q[axis]-piece.high[axis])
                        d2=d2+d*d
                    end
                    if d2<=reach2 then return false end
                end
            end
        end end
        if checkpoint then checkpoint() end
    end end end
    return true
end

-- A tiny sphere can miss every lattice corner. A proved separating plane
-- uses the existing exact tetrahedron clipper, bounded to these edit cells.
-- It is used only when no other solid in those cells can be touched.
function V.DetachedRemovalPlane(r, center, radius, bounds, allowed, checkpoint)
    if not r.bsp then return end
    local cell=bounds.x and {bounds.x,bounds.y,bounds.z} or nil
    for _,index in ipairs(removalAxes) do
        local axis=axes[index]
        for _,sign in ipairs(removalSigns) do
            local edge=sign==1 and bounds.high[axis]+0.125 or bounds.low[axis]-0.125
            local plane={axis=index,sign=sign,distance=sign*(r.origin[axis]+edge),cell=cell}
            if V.DetachedRemovalSafe(r,center,radius,allowed,checkpoint,plane) then return plane end
        end
    end
end

function V.DetachedCellStroke(r, piece)
    local low, high = piece.low or Vector(piece.x,piece.y,piece.z)*r.step,
        piece.high or Vector(piece.x+1,piece.y+1,piece.z+1)*r.step
    return V.SnapScanPosition(r.origin+(low+high)/2),math.ceil((high-low):Length()/2+0.5)
end
