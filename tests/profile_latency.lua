-- Comparable CPU phases, including the production local hull preparation.
-- Numerical vectors only: no GPU, network delay or VPhysics cooking.
local V=GVoxel
local previousClock=SysTime
SysTime=os.clock
local function timed(fn)
    local begin=os.clock()
    local result=fn()
    return (os.clock()-begin)*1000,result
end
local function warm(r,dirty)
    if dirty then V.PrepareChangedCollisions(r,dirty)
    else V.ForChunks(function(x,y,z) V.PrepareCollisionChunk(r,x,y,z) end,r) end
end
print("PROFILE: numerical adapter, cumulative CPU; no GPU, material batches, network or native VPhysics cook")
for _,mode in ipairs({"density","exact","mixed"}) do
    local r=V.NewScanRegion(501,Vector(),16)
    local height=3.712345
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=math.floor((p.z-height)*64+0.5)/64 end
    r.featurePlanes={{axis=3,sign=1,distance=height,low=r.origin,high=r.origin+Vector(1,1,1)*r.side}}
    if mode~="density" then
        local face={normal=Vector(0,0,1),tex={flags=0},distance=height,low=Vector(-1000,-1000,height),high=Vector(1000,1000,height),
            vertices={Vector(-1000,-1000,height),Vector(1000,-1000,height),Vector(1000,1000,height),Vector(-1000,1000,height)}}
        local data={head=0,planes={{normal=Vector(0,0,1),distance=height}},nodes={{plane=1,front=-1,back=-2}},
            leaves={{solid=false},{solid=true}},faces={face}}
        if mode=="mixed" then data.faces[2]={normal=Vector(0,0,1),tex={flags=0},displacement=true,
            low=Vector(0,-1000,height),high=Vector(1000,1000,height),vertices={}} end
        V.PrepareBSPRegion(r,data)
    end
    V.ForChunks(function(x,y,z) V.BuildChunk(r,x,y,z) end,r)
    local initial=timed(function() warm(r) end)
    print(string.format("LATENCY %s initial collision preparation %.1f ms (%d cells)",mode,initial,V.CollisionCacheStats(r).cells))
    for stroke=1,4 do
        local field,dirty
        local apply=timed(function()
            field=V.CloneScanField(r)
            dirty=V.ApplyBrush(field,Vector((stroke-1)*10,0,-20-(stroke-1)*10),stroke==4 and 112 or 48,false,stroke==4 and 913 or nil)
            field.revision=r.revision+1
        end)
        local triangles=0
        local mesh=timed(function() for _,c in pairs(dirty) do triangles=triangles+#V.BuildChunk(field,c[1],c[2],c[3])/3 end end)
        local collision=timed(function() warm(field,dirty) end)
        local first=timed(function()
            for i=0,8 do local p=Vector(i*4-16,0,50)
                V.TraceVoxelHull(field,p,p-Vector(0,0,180),Vector(-16,-16,0),Vector(16,16,72))
            end
        end)
        print(string.format("LATENCY %s %s: apply %.1f; mesh %.1f; mandatory collision %.1f; total %.1f ms; first 9 sweeps %.1f ms; %d triangles",
            mode,stroke==4 and "RPG" or ("dig "..stroke),apply,mesh,collision,apply+mesh+collision,first,triangles))
        r=field
    end
end
SysTime=previousClock
