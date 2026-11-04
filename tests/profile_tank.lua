-- Repeatable CPU-only comparison. No engine scheduling, GPU, network or
-- PhysicsFromMesh is exercised by these standard-Lua adapters.
local V=GVoxel
local previousClock=SysTime
SysTime=os.clock
local function timed(fn)
    local started=os.clock()
    local result=fn()
    return (os.clock()-started)*1000,result
end
local function median(list)
    table.sort(list)
    return list[math.floor(#list/2)+1]
end

local n=Vector(1,0,0)
local data={head=0,
    planes={{normal=Vector(0,0,1),distance=0},{normal=n,distance=0},{normal=n,distance=40}},
    nodes={{plane=1,front=1,back=-2},{plane=2,front=2,back=-1},{plane=3,front=-1,back=-2}},
    leaves={{solid=false},{solid=true}},faces={}}
data.faces[1]={normal=Vector(0,0,1),tex={flags=0},low=Vector(-1000,-1000,0),high=Vector(1000,1000,0),
    vertices={Vector(-1000,-1000,0),Vector(1000,-1000,0),Vector(1000,1000,0),Vector(-1000,1000,0)}}
for _,x in ipairs({0,40}) do data.faces[#data.faces+1]={normal=n*(x==0 and -1 or 1),tex={flags=0},
    low=Vector(x,-1000,0),high=Vector(x,1000,1000),
    vertices={Vector(x,-1000,0),Vector(x,1000,0),Vector(x,1000,1000),Vector(x,-1000,1000)}} end
local center=Vector(20,0,58)
local base=V.NewScanRegion(2312,center,16)
for i=0,33^3-1 do
    local p,x,y,z=V.ScanPoint(base,i)
    base.values[V.Index(x,y,z,base)]=V.BSPSolid(data,p) and -base.step or base.step
end
local scan=timed(function()
    V.PrepareBSPRegion(base,data)
    V.ForChunks(function(x,y,z)
        V.BuildChunk(base,x,y,z)
        V.PrepareCollisionChunk(base,x,y,z)
        if V.CollisionChunkMayHaveSurface(base,x,y,z) then V.BuildCollisionChunk(base,x,y,z) end
    end,base)
end)
local tankRadius=math.ceil(math.sqrt(68^2+58^2+20^2)+base.step)
print("PROFILE TANK: Source float Vector adapter, CPU only; excludes engine timing, GPU, network, native cooking and FPS")
print(string.format("WARM TANK: 16 m region / step %.4f SU; BSP wall 40 SU; prepared mesh/SAT/input %.2f ms; tank radius %d SU",base.step,scan,tankRadius))

local rpgRadius=V.TankCraterRadius({halfWidth=129.703*1.05/2,heightClear=110.620*1.05})
print("PREFLIGHT TANK: none; tank uses the RPG crater at the actual explosion point")
if ProfileExplosionDetails then ProfileExplosionDetails() end

for _,case in ipairs({{name="tool_r80",radius=80},{name="sphere_tank_radius",radius=tankRadius},
    {name="legacy_floor_clipped",radius=tankRadius,floorZ=0},
    {name="rpg_impact",radius=112,seed=913,center=Vector(0,0,70)},
    {name="tank_rpg_impact",radius=rpgRadius,seed=719,center=Vector(0,0,70)}}) do
    if not _PROFILE_EXPLOSIONS_ONLY or case.seed then
    local samples={clone={},brush={},collision={},mesh={},native={},total={}}
    local signature
    for trial=1,5 do
        collectgarbage("collect")
        local field,dirty
        local clone=timed(function() field=V.CloneScanField(base) end)
        local brush=timed(function() dirty=V.ApplyBrush(field,case.center or center,case.radius,false,case.seed or 0,nil,case.floorZ) field.revision=1 end)
        local collision=timed(function() V.PrepareChangedCollisions(field,dirty) end)
        local mesh=timed(function() for _,c in pairs(dirty) do V.BuildChunk(field,c[1],c[2],c[3]) end end)
        local chunks,triangles,cooks=0,0,0
        local native=timed(function() for _,c in pairs(dirty) do
            local vertices=V.BuildCollisionChunk(field,c[1],c[2],c[3])
            chunks=chunks+1 triangles=triangles+#vertices/3 cooks=cooks+math.ceil(#vertices/384)
        end end)
        local tr=V.TraceVoxelHull(field,Vector(-70,0,0),Vector(110,0,0),Vector(-16,-68,0.5),Vector(16,68,116.5))
        local current=string.format("%d/%d/%d/%s",chunks,triangles,cooks,tostring(tr.Hit))
        if signature then assert(signature==current,"tank profile geometry changed across trials") end
        signature=current
        if trial>=3 then
            for key,value in pairs({clone=clone,brush=brush,collision=collision,mesh=mesh,native=native,
                total=clone+brush+collision+mesh+native}) do samples[key][#samples[key]+1]=value end
        end
        if case.floorZ~=nil then assert(not tr.Hit,"profile tank opening does not admit the requested hull") end
    end
    print(string.format("TANK %s r%d: clone %.2f; brush %.2f; SAT %.2f; mesh %.2f; native input %.2f; total %.2f ms CPU (median last 3 of 5)",
        case.name,case.radius,median(samples.clone),median(samples.brush),median(samples.collision),median(samples.mesh),median(samples.native),median(samples.total)))
    print(string.format("SIGNATURE TANK %s: chunks/triangles/prospective 128-triangle cooks/hull blocked = %s",case.name,signature))
    if ProfileExplosionDetails then ProfileExplosionDetails() end
    end
end
SysTime=previousClock
