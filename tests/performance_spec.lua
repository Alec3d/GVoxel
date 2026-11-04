function RunPerformanceTests()
    local V=GVoxel
    local r=V.NewScanRegion(900,Vector(),16)
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=p.z-3.7 end
    local original=V.RefineSurfacePoint
    local refinements=0
    V.RefineSurfacePoint=function(...) refinements=refinements+1 return original(...) end
    local start,finish=Vector(0,0,100),Vector(0,0,-100)
    local mins,maxs=Vector(-8,-8,0),Vector(8,8,16)
    V.TraceScanRegion(r,start,Vector(0,0,-1),200)
    V.TraceVoxelHull(r,start,finish,mins,maxs)
    local cold=refinements
    local begin=os.clock()
    for _=1,100 do
        assert(V.TraceScanRegion(r,start,Vector(0,0,-1),200))
        assert(V.TraceVoxelHull(r,start,finish,mins,maxs).Hit)
    end
    local elapsed=(os.clock()-begin)*1000
    assert(cold>0 and refinements==cold,"idle hull/target traces rebuild refined geometry")
    -- A stroke in another corner retains the already compiled central cells.
    local cache=r.terrainCache.surfaces["2:2:2"]
    local clone=V.CloneScanField(r)
    V.ApplyBrush(clone,Vector(-220,-220,-20),48,false) clone.revision=clone.revision+1
    assert(clone.terrainCache.surfaces["2:2:2"]==cache,"distant stroke invalidated untouched geometry")
    assert(r.terrainCache.surfaces["2:2:2"]==cache,"staging evicted visible terrain cache")
    local visible=V.TraceScanRegion(r,start,Vector(0,0,-1),200)
    assert(visible and math.abs(visible.HitPos.z-3.7)<0.001)
    V.RefineSurfacePoint=original
    local oldNormal=V.Normal
    local normalCalls=0
    V.Normal=function(...) normalCalls=normalCalls+1 return oldNormal(...) end
    local vertices=V.BuildChunk(r,2,2,2)
    local firstNormalCalls=normalCalls
    assert(firstNormalCalls>0 and firstNormalCalls<#vertices/2,"shared mesh vertices recompute all density gradients")
    V.BuildChunk(r,2,2,2)
    assert(normalCalls==firstNormalCalls,"identical rebuild lost cached vertex gradients")
    V.Normal=oldNormal
    -- Compare the former per-cell edge work with shared chunk edges using
    -- identical fields/meshes. Counts are deterministic; no claimed FPS gain.
    local base=V.NewScanRegion(903,Vector(),16)
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(base,i) base.values[V.Index(x,y,z,base)]=p.z-3.7 end
    V.ApplyBrush(base,Vector(0,0,-25),75,false)
    local a,b=V.CloneScanField(base),V.CloneScanField(base)
    local cacheFunction=V.TerrainCellCache
    local calls=0
    V.RefineSurfacePoint=function(...) calls=calls+1 return original(...) end
    V.TerrainCellCache=function(field,kind,...)
        if kind=="edgePoints" then return {} end
        return cacheFunction(field,kind,...)
    end
    local unshared=V.BuildChunk(a,2,2,1)
    local perCell=calls
    calls=0 V.TerrainCellCache=cacheFunction
    local shared=V.BuildChunk(b,2,2,1)
    local perChunk=calls
    V.RefineSurfacePoint=original
    assert(perChunk<perCell*0.6,"shared edges did not remove redundant interpolation/refinement work")
    assert(#shared==#unshared,"edge sharing changed topology")
    for i,vertex in ipairs(shared) do
        assert(vertex.pos:DistToSqr(unshared[i].pos)<1e-12 and vertex.normal:DistToSqr(unshared[i].normal)<1e-12,
            "edge sharing changed the surface or its normals")
    end
    local pauses=0
    local job=coroutine.create(function()
        return V.BuildChunk(b,2,2,1,function() pauses=pauses+1 coroutine.yield() end)
    end)
    local result
    repeat local ok,value=coroutine.resume(job) assert(ok,value) result=value until coroutine.status(job)=="dead"
    assert(pauses==16 and #result==#shared,"mesh generation did not yield every 32 lattice cells")
    print(string.format("PASS: shared mesh edges: %d -> %d refinements; identical geometry; 16 interruptible cell slices/chunk",perCell,perChunk))
    print(string.format("PASS: 100 cached hull + aim pairs, zero geometry rebuilds (%.2f ms numerical adapter)",elapsed))
end
