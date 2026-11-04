-- Repeatable allocation/work profile on an actual gm_construct scan. This
-- counts Vector construction in a float adapter, not Source frame time.
local V=GVoxel
local newVector=Vector
local allocations=0
function Vector(...) allocations=allocations+1 return newVector(...) end
local previousClock=SysTime SysTime=os.clock
local function phase(label,fn)
    local before=allocations local started=os.clock()
    local result=fn()
    print(string.format("PROFILE A %s: %.1f ms CPU; %d Vector allocations",label,(os.clock()-started)*1000,allocations-before))
    return result
end
local function prepare(r,dirty)
    if dirty then V.PrepareChangedCollisions(r,dirty)
    else V.ForChunks(function(x,y,z) V.PrepareCollisionChunk(r,x,y,z) end,r) end
end
print("PROFILE A: actual scan, 32-bit Vector adapter; CPU includes adapter rounding; excludes engine, GPU, materials, network and native cooks")
local r=V.NewScanRegion(1902,Vector(-1002.375,-478.375,-143.25),16)
V.PrepareBSPRegion(r,_NATIVE_BSP_DATA,nil,false)
r.values={} for i,value in ipairs(_NATIVE_TERRAIN_VALUES) do r.values[i]=value end
collectgarbage("collect")
phase("initial preparation",function()
    V.ForChunks(function(x,y,z)
        V.BuildChunk(r,x,y,z)
        if V.CollisionChunkMayHaveSurface(r,x,y,z) then V.BuildCollisionChunk(r,x,y,z) end
    end,r)
    prepare(r)
end)
collectgarbage("collect")
print(string.format("HEAP A prepared: %.1f KiB Lua adapter",collectgarbage("count")))
for i,op in ipairs({
    {Vector(-850,-480,-168),48,false},
    {Vector(-838,-480,-180),48,false},
    {Vector(-838,-480,-174),32,true},
    {Vector(-842,-480,-193),112,false,913}
}) do
    local field,dirty
    phase(i.." apply",function()
        field=V.CloneScanField(r)
        dirty=V.ApplyBrush(field,op[1],op[2],op[3],op[4]) field.revision=r.revision+1
    end)
    local count,hash,normalHash=0,0,0
    phase(i.." mesh",function()
        -- Sorted order removes table iteration order as a profiling variable.
        V.ForChunks(function(x,y,z)
            if not dirty[V.ChunkKey(x,y,z)] then return end
            for _,vertex in ipairs(V.BuildChunk(field,x,y,z)) do
                count=count+1
                local p=vertex.pos
                hash=(hash+math.floor(p.x*10000+0.5)*17+math.floor(p.y*10000+0.5)*31+math.floor(p.z*10000+0.5)*43)%2147483647
                local n=vertex.normal
                normalHash=(normalHash+math.floor(n.x*100000+0.5)*17+math.floor(n.y*100000+0.5)*31+math.floor(n.z*100000+0.5)*43)%2147483647
            end
        end,field)
    end)
    phase(i.." collision",function() prepare(field,dirty) end)
    phase(i.." native mesh input",function()
        V.ForChunks(function(x,y,z) if dirty[V.ChunkKey(x,y,z)] then V.BuildCollisionChunk(field,x,y,z) end end,field)
    end)
    local hits,solid,height=0,0,0
    for x=-900,-790,11 do for y=-520,-440,10 do
        local a=Vector(x,y,-80)
        local tr=V.TraceVoxelHull(field,a,a-Vector(0,0,240),Vector(-8,-8,0),Vector(8,8,32))
        if tr.Hit then hits=hits+1 height=height+math.floor(tr.HitPos.z*1000+0.5) end
        if tr.StartSolid then solid=solid+1 end
    end end
    print(string.format("SIGNATURE A %d: vertices=%d hash=%d normals=%d hullHits=%d solid=%d height=%d",i,count,hash,normalHash,hits,solid,height))
    r=field
end
Vector=newVector SysTime=previousClock
