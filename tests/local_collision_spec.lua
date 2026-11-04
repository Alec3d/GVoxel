-- Compare spatial pruning with the former exhaustive cell traversal.
local function exhaustive(r,start,finish,mins,maxs)
    local delta=finish-start
    local center=start+(mins+maxs)/2-r.origin
    local extent=(maxs-mins)/2
    local pointCast=extent:LengthSqr()<1e-16
    local low,high={},{}
    local EPS=0.00001
    for _,axis in ipairs({"x","y","z"}) do
        low[axis]=math.max(0,math.floor((math.min(start[axis],finish[axis])+mins[axis]-r.origin[axis]-EPS)/r.step))
        high[axis]=math.min(r["n"..axis]-1,math.floor((math.max(start[axis],finish[axis])+maxs[axis]-r.origin[axis]+EPS)/r.step))
    end
    local result={Hit=false,Fraction=1,StartSolid=false}
    for z=low.z,high.z do for y=low.y,high.y do for x=low.x,high.x do
        for _,poly in ipairs(GVoxel.DensityCellSolids(r,x,y,z)) do
            local first,last=-math.huge,math.huge
            local inside,miss=true,false
            for _,plane in ipairs(poly) do
                local n=plane.n
                local radius=math.abs(n.x)*extent.x+math.abs(n.y)*extent.y+math.abs(n.z)*extent.z
                local p,d=center:Dot(n),delta:Dot(n)
                local lo,hi=plane.low-radius,plane.high+radius
                if p<=lo+EPS or p>=hi-EPS then inside=false end
                if math.abs(d)<1e-12 then
                    if pointCast and (p<lo-EPS or p>hi+EPS) or not pointCast and (p<=lo+EPS or p>=hi-EPS) then miss=true break end
                else
                    local a,b=(lo-p)/d,(hi-p)/d
                    if a>b then a,b=b,a end
                    first,last=math.max(first,a),math.min(last,b)
                    if first>last+EPS then miss=true break end
                end
            end
            if not miss then
                if inside then return {Hit=true,Fraction=0,StartSolid=true} end
                if first>=-EPS and first<=1 and last>EPS and first<result.Fraction then result.Hit=true result.Fraction=math.max(0,first) end
            end
        end
    end end end
    return result
end

function RunLocalCollisionTests(nativeBSP)
    local V=GVoxel
    assert(not V.NewCollisionPrecache and not V.PrecacheCollisionChunk and not V.ResumeCollisionPrecache,
        "removed eager collision preparation remains available")
    for _,mode in ipairs({"density16","density32","architecture16","gm_construct16"}) do
        local center=mode=="gm_construct16" and Vector(352,650,0)
            or mode=="architecture16" and Vector(0,0,_BSP_TEST_FLOOR.planes[1].distance) or Vector()
        local r=V.NewScanRegion(990,center,mode=="density32" and 32 or 16)
        for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=p.z-center.z end
        if mode=="gm_construct16" then V.PrepareBSPRegion(r,nativeBSP) end
        if mode=="architecture16" then V.PrepareBSPRegion(r,_BSP_TEST_FLOOR) end
        V.ForChunks(function(x,y,z) V.BuildChunk(r,x,y,z) end,r)
        assert(V.CollisionCacheStats(r).cells==0,"initial render forced player hull construction")
        local oldValues=r.values
        local field=V.CloneScanField(r)
        local dirty=V.ApplyBrush(field,center+Vector(0,0,-25),80,false)
        field.revision=1
        for _,c in pairs(dirty) do V.BuildChunk(field,c[1],c[2],c[3]) end
        assert(V.CollisionCacheStats(field).cells==0,"hole render forced player hull construction")
        assert(r.values==oldValues and r.revision==0 and not r.modifiedChunks,"staging changed the displayed field")
        local start,finish=center+Vector(-220,-220,180),center+Vector(220,220,-180)
        local mins,maxs=Vector(-16,-16,0),Vector(16,16,72)
        local first=V.TraceVoxelHull(field,start,finish,mins,maxs)
        local localCells=V.CollisionCacheStats(field).cells
        local boundingCells=1
        for _,axis in ipairs({"x","y","z"}) do
            local low=math.max(0,math.floor((math.min(start[axis],finish[axis])+mins[axis]-r.origin[axis]-0.00001)/r.step))
            local high=math.min(r["n"..axis]-1,math.floor((math.max(start[axis],finish[axis])+maxs[axis]-r.origin[axis]+0.00001)/r.step))
            boundingCells=boundingCells*(high-low+1)
        end
        assert(localCells>0 and localCells<boundingCells/8,mode.." diagonal sweep constructed "..localCells.." / "..boundingCells.." cells")
        local reference=V.CloneScanField(field) reference.terrainCache=nil
        local expected=exhaustive(reference,start,finish,mins,maxs)
        assert(first.Hit==expected.Hit and first.StartSolid==expected.StartSolid and math.abs(first.Fraction-expected.Fraction)<1e-7,
            "cold diagonal sweep changed collision")
        for i=0,23 do
            local a=i*math.pi*2/24
            local p=center+Vector(math.cos(a)*145,math.sin(a)*145,90+(i%3)*15)
            local q=center+Vector(math.sin(a)*90,math.cos(a)*90,-135)
            local lo,hi=mins,maxs
            if i%4==0 then lo,hi=Vector(),Vector() end
            if i%5==0 then q=p end
            field.terrainCache.hulls=nil -- exercise first contact, never eager preparation
            if field.bspDensityBase and field.bspDensityBase.terrainCache then field.bspDensityBase.terrainCache.hulls=nil end
            local hit=V.TraceVoxelHull(field,p,q,lo,hi)
            local truth=exhaustive(reference,p,q,lo,hi)
            assert(hit.Hit==truth.Hit and hit.StartSolid==truth.StartSolid and math.abs(hit.Fraction-truth.Fraction)<1e-7,
                mode.." pruned query changed continuous collision "..i)
        end
        local pauses=0
        local thread=coroutine.create(function()
            return V.TraceVoxelHull(field,center+Vector(200,200,200),center+Vector(200,200,200),
                Vector(-80,-80,-80),Vector(80,80,80),function() pauses=pauses+1 coroutine.yield() end)
        end)
        repeat local ok,err=coroutine.resume(thread) assert(ok,err) until coroutine.status(thread)=="dead"
        assert(pauses>0,"explosion overlap preflight cannot yield")
        print(string.format("PASS: %s: no collision precache; cold diagonal uses %d cells; 25 cold sweeps equal exhaustive SAT; explosion preflight yields",mode,localCells))
    end
end
