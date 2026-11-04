-- CPU phases on a thin wall and installed gm_construct architecture. This is
-- deliberately not a frame/FPS/latency claim: no GPU, net or native cooks.
local V=GVoxel
local priorClock=SysTime SysTime=os.clock
local function timed(fn)
    local start=os.clock() local value=fn()
    return (os.clock()-start)*1000,value
end
-- Do not retain destroyed mock meshes in the lifecycle-test adapter's log.
-- GPU upload and native allocation/cooking are deliberately excluded.
Mesh=function() return {BuildFromTriangles=function() end,Destroy=function() end} end
print("PROFILE HOLES: 32-bit Vector adapter; CPU geometry + UV/material batches only; excludes GPU, network, native cooking, scheduling and collection pauses")
for _,scene in ipairs({"wall","gm_construct_wall","gm_construct_corner"}) do
    local center=scene=="wall" and Vector() or scene=="gm_construct_wall" and Vector(-1024,-1104,-24) or Vector(-1024,-1024,-80)
    local data=_NATIVE_BSP_DATA
    if scene=="wall" then
        local n=Vector(1,0,0)
        data={head=0,planes={{normal=n,distance=16},{normal=n,distance=-16}},
            nodes={{plane=1,front=-1,back=1},{plane=2,front=-2,back=-1}},
            leaves={{solid=false},{solid=true}},faces={}}
        for _,sign in ipairs({-1,1}) do
            data.faces[#data.faces+1]={normal=n*sign,distance=16,tex={flags=0},
                low=Vector(sign*16,-1000,-1000),high=Vector(sign*16,1000,1000),
                vertices={Vector(sign*16,-1000,-1000),Vector(sign*16,1000,-1000),Vector(sign*16,1000,1000),Vector(sign*16,-1000,1000)}}
        end
    end
    local r=V.NewScanRegion(1960,center,16)
    V.BeginSurfaceCapture(r)
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=V.BSPSolid(data,p) and -r.step or r.step end
    local scanStarted=os.clock()
    V.PrepareBSPRegion(r,data,nil,false)
    V.ForChunks(function(x,y,z)
        local vertices=V.BuildChunk(r,x,y,z)
        local batches=V.BuildSurfaceBatches(r,{x=x,y=y,z=z,key=V.ChunkKey(x,y,z)},vertices)
        for _,batch in ipairs(batches) do batch.mesh:Destroy() end
        V.PrepareCollisionChunk(r,x,y,z)
        if V.CollisionChunkMayHaveSurface(r,x,y,z) then V.BuildCollisionChunk(r,x,y,z) end
    end,r)
    V.FreezeSurfaceSources(r)
    for _,source in ipairs(r.surfaceList) do source.ready=true source.pendingBatches=nil end
    collectgarbage("collect")
    print(string.format("WARM HOLES %s: %.1f ms CPU; %.1f KiB Lua adapter",scene,(os.clock()-scanStarted)*1000,collectgarbage("count")))
    for _,radius in ipairs({24,48,80}) do
      local reference
      for repetition=1,3 do
       for _,variant in ipairs(_HOLE_BASELINE_API and {"baseline","current"} or {"current"}) do
        local api=variant=="baseline" and _HOLE_BASELINE_API or _HOLE_CURRENT_API
        for k,v in pairs(api) do V[k]=v end
        collectgarbage("collect") collectgarbage("stop")
        local field,dirty
        local apply=timed(function()
            field=V.CloneScanField(r) dirty=V.ApplyBrush(field,center,radius,false) field.revision=1
        end)
        local collision=timed(function() V.PrepareChangedCollisions(field,dirty) end)
        local mesh=timed(function() for _,c in pairs(dirty) do V.BuildChunk(field,c[1],c[2],c[3]) end end)
        local materials=timed(function() for key,c in pairs(dirty) do
            local vertices=V.BuildChunk(field,c[1],c[2],c[3])
            local batches=V.BuildSurfaceBatches(field,{x=c[1],y=c[2],z=c[3],key=key},vertices)
            for _,batch in ipairs(batches) do batch.mesh:Destroy() end
        end end)
        local cooks,triangles,chunks=0,0,0
        local native=timed(function() for _,c in pairs(dirty) do
            local vertices=V.BuildCollisionChunk(field,c[1],c[2],c[3])
            chunks=chunks+1 triangles=triangles+#vertices/3 cooks=cooks+math.ceil(#vertices/384)
        end end)
        local hits,hash=0,0
        for a=-100,100,20 do for b=-100,100,20 do
            local start=center+Vector(-120,a,b)
            local tr=V.TraceVoxelHull(field,start,start+Vector(240,0,0),Vector(-4,-4,-4),Vector(4,4,4))
            if tr.Hit then hits=hits+1 hash=hash+math.floor(tr.Fraction*100000+0.5) end
        end end
        print(string.format("RENDER HOLE %s r%d %s #%d: brush %.1f; collision %.1f; mesh %.1f; materials %.1f; native %.1f; total %.1f ms",scene,radius,variant,repetition,apply,collision,mesh,materials,native,apply+collision+mesh+materials+native))
        print(string.format("SIGNATURE HOLE %s r%d: %d triangles; %d hits; %d fractions",scene,radius,triangles,hits,hash))
        local signature=string.format("%d:%d:%d",triangles,hits,hash)
        reference=reference or signature assert(signature==reference,"hole geometry/collision changed against baseline")
        collectgarbage("restart")
       end
      end
    end
    local states={baseline=r,current=r}
    for stroke=1,8 do
        local expected,expectedSweeps
        for _,variant in ipairs(_HOLE_BASELINE_API and {"baseline","current"} or {"current"}) do
            local api=variant=="baseline" and _HOLE_BASELINE_API or _HOLE_CURRENT_API
            for k,v in pairs(api) do V[k]=v end
            collectgarbage("collect") collectgarbage("stop")
            local evaluations=0 local applyPlanes=V.ApplyBSPBrushPlanes
            V.ApplyBSPBrushPlanes=function(pieces,operations,...)
                evaluations=evaluations+#pieces*#operations
                return applyPlanes(pieces,operations,...)
            end
            local field,dirty,verticesByChunk
            local elapsed=timed(function()
                field=V.CloneScanField(states[variant])
                dirty=V.ApplyBrush(field,center+Vector(0,(stroke-1)*5,0),48,stroke==5,stroke>=7 and 913+stroke or nil)
                field.revision=states[variant].revision+1
                V.PrepareChangedCollisions(field,dirty)
                verticesByChunk={}
                for key,c in pairs(dirty) do
                    local vertices=V.BuildChunk(field,c[1],c[2],c[3]) verticesByChunk[key]=vertices
                    local batches=V.BuildSurfaceBatches(field,{x=c[1],y=c[2],z=c[3],key=key},vertices)
                    for _,batch in ipairs(batches) do batch.mesh:Destroy() end
                    V.BuildCollisionChunk(field,c[1],c[2],c[3])
                end
            end)
            V.ApplyBSPBrushPlanes=applyPlanes
            if expected then
                for key,vertices in pairs(verticesByChunk) do
                    local before=assert(expected[key]) assert(#before==#vertices,"sequence render count changed")
                    for i,p in ipairs(vertices) do
                        assert(p.pos:DistToSqr(before[i].pos)<1e-10 and p.normal:DistToSqr(before[i].normal)<1e-10,
                            "sequence cached surface position/normal differs from baseline")
                    end
                end
            else expected=verticesByChunk end
            local sweeps={}
            for a=-75,75,25 do for b=-75,75,25 do
                local start=center+Vector(-120,a,b)
                for _,extent in ipairs({0,8}) do
                    local e=Vector(extent,extent,extent)
                    local hit=V.TraceVoxelHull(field,start,start+Vector(240,0,0),-e,e)
                    sweeps[#sweeps+1]=hit
                    if expectedSweeps then
                        local prior=expectedSweeps[#sweeps]
                        assert(hit.Hit==prior.Hit and hit.StartSolid==prior.StartSolid and math.abs(hit.Fraction-prior.Fraction)<1e-5,
                            "incremental final solids differ from the archived full-history collision")
                    end
                end
            end end
            expectedSweeps=expectedSweeps or sweeps
            print(string.format("SEQUENCE HOLE %s stroke%d %s: %.1f ms; %d piece x operation evaluations",scene,stroke,variant,elapsed,evaluations))
            states[variant]=field
            collectgarbage("restart")
        end
    end
    V.ReleaseSurfaceCapture(r)
end
SysTime=priorClock
