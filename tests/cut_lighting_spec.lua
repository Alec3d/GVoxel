-- Numerical and renderer-contract regressions, not a GPU/pixel/FPS test.
function RunCutLightingTests()
    local V=GVoxel
    local saved={util=util,render=render,RealTime=RealTime,FrameNumber=FrameNumber,Mesh=Mesh,
        material=V.SurfaceMaterial,flash=V.SurfaceFlashMaterial,baked=V.SurfaceUsesBaked}
    local queries,dynamicQueries,sunQueries=0,0,0
    local amount,frame=0.2,100000
    local shadow,sunny=Vector(0.03,0.06,0.12),Vector(1.6,1,0.4)
    util={PointContents=function(p) return p.x>0 and p.x<32 and CONTENTS_SOLID or 0 end,
        GetSunInfo=function() sunQueries=sunQueries+1 return {direction=Vector(1,0,0)} end}
    local current,modulation,blend,lights,draws=nil,1,false,{},{}
    render={ComputeLighting=function(p)
            queries=queries+1 return (p.x<=0 and shadow or sunny)+Vector(amount,amount,amount)
        end,
        ComputeDynamicLighting=function() dynamicQueries=dynamicQueries+1 return Vector(amount,amount,amount) end,
        GetAmbientLightColor=function() return Vector(0.9,0.9,0.9) end,
        SetColorModulation=function(r,g,b) assert(r==g and g==b) modulation=r end,
        SetMaterial=function(m) current=m end,
        ResetModelLighting=function() lights={} end,
        SetModelLighting=function(i,r,g,b) lights[i+1]=Vector(r,g,b) end,
        SetLightingOrigin=function() end,SetLocalModelLights=function() end,
        OverrideBlend=function(value) blend=value end,RenderFlashlights=function(fn) fn() end}
    RealTime=function() return frame end FrameNumber=function() return frame end
    local function source(x,n)
        return {point=Vector(x,0,0),planeNormal=n,frame={normal=n,right=Vector(0,1,0),up=Vector(0,0,1)},
            lightOrigin=Vector(x,0,0)+n*2,lightBounds={low=Vector(x,-64,-64),high=Vector(x,64,64)}}
    end
    local a,b=source(0,Vector(-1,0,0)),source(32,Vector(1,0,0))
    local r={step=16,origin=Vector(),base=Vector(),chunks={},surfaceList={a,b}}
    local yields=0
    local job=coroutine.create(function() V.PrepareCutLighting(r,function() yields=yields+1 coroutine.yield() end) end)
    repeat
        assert(not r.cutLighting,"partially built lighting index was published")
        local ok,err=coroutine.resume(job) assert(ok,err)
    until coroutine.status(job)=="dead"
    assert(yields>1 and queries==12 and sunQueries==1 and a.sunFacing==-1 and b.sunFacing==1)
    local n=Vector(0,0,1)
    local previous=-1
    for x=0,32,0.25 do
        local c=V.CutVertexLighting(r,Vector(x,0,0),n)
        assert(c.x>=previous-1e-8,"shade-to-sun transition is not monotonic")
        assert(c.x<=sunny.x+1e-8 and c.z<=sunny.z+1e-8,"ambient/dynamic light added twice")
        previous=c.x
    end
    local dark=V.CutVertexLighting(r,Vector(0,0,0),n)
    local bright=V.CutVertexLighting(r,Vector(32,0,0),n)
    local middle=V.CutVertexLighting(r,Vector(16,0,0),n)
    assert((dark-shadow):Length()<0.001 and (bright-sunny):Length()<0.001)
    assert(middle.x>0.75 and middle.x<0.85 and middle.z>middle.y*0.4,
        "interpolation lost the two faces' measured intensity/color")
    assert(queries==12,"vertex gradient performs new native lighting probes")
    print("PASS: opposite shaded/sunlit faces interpolate monotonically in linear RGB; local boundary values and HDR color retained; scan preparation yields before publication")

    local shared=V.CutVertexLighting({cutLighting=r.cutLighting},Vector(16,0,0),n)
    assert((shared-middle):LengthSqr()==0,"material/chunk boundaries change shared vertex lighting")
    assert(V.CutVertexLighting(r,Vector(16,10000,0),n):LengthSqr()==0,"finite wall treated as infinite light plane")
    local distant=source(0,Vector(-1,0,0)) distant.point=Vector(0,10000,0)
    distant.lightBounds={low=Vector(0,9900,-64),high=Vector(0,10100,64)}
    distant.voxelEnvironment={sunny,sunny,sunny,sunny,sunny,sunny}
    local r2={step=16,base=Vector(),chunks={},surfaceList={a,b,distant}}
    V.PrepareCutLighting(r2)
    assert((V.CutVertexLighting(r2,Vector(16,0,0),n)-middle):LengthSqr()==0,"remote building altered local gradient")
    local slope=source(0,Vector(1,0,1):GetNormalized())
    slope.voxelEnvironment={sunny,sunny,sunny,sunny,sunny,sunny}
    slope.lightBounds={low=Vector(-64,-64,-64),high=Vector(64,64,64)}
    local sloped={step=16,base=Vector(),chunks={},surfaceList={slope}}
    V.PrepareCutLighting(sloped)
    local onPlane=V.CutVertexLighting(sloped,Vector(0,0,0),n)
    local belowPlane=V.CutVertexLighting(sloped,Vector(-48,0,-48),n)
    assert(belowPlane.x<onPlane.x*0.95,"displacement AABB erases actual surface distance")
    print("PASS: common world vertices agree across chunks/materials; finite and sloped faces avoid infinite-plane/floor contamination")

    util.GetSunInfo=function() return nil end
    local black=source(0,Vector(-1,0,0)) black.voxelEnvironment={Vector(),Vector(),Vector(),Vector(),Vector(),Vector()}
    local enclosed={step=16,base=Vector(),chunks={},surfaceList={black}}
    V.PrepareCutLighting(enclosed)
    assert(V.CutVertexLighting(enclosed,Vector(1,0,0),n):LengthSqr()==0,"sky fallback brightens a measured black room")
    local samples=queries
    for i=1,4300 do V.CutVertexLighting(r,Vector(i,1234,4567),n) end
    local count=0 for _ in pairs(r.cutLighting.points) do count=count+1 end
    assert(count==4096 and queries==samples and #r.cutLighting.order==4096,"vertex cache grows unbounded or resamples BSP")
    print("PASS: maps without env_sun and fully dark probes supported; no fake sky brightening; static vertex cache bounded to 4096 points")

    local vertices={}
    for _,c in ipairs({Vector(),Vector(0.03,0.06,0.12),Vector(2,1,0.5)}) do
        vertices[#vertices+1]={pos=Vector(),normal=n,u=0.5,v=0.25,color=Color(255,255,255),cutLight=c}
    end
    local encoded,scale=V.EncodeCutLighting(vertices)
    assert(scale==2 and encoded~=vertices)
    for i,v in ipairs(encoded) do
        local c=v.color
        local decoded=Vector((c.r/255)^2.2,(c.g/255)^2.2,(c.b/255)^2.2)*scale
        assert((decoded-vertices[i].cutLight):Length()<0.015,"shader gamma/HDR round trip changed irradiance")
        assert(vertices[i].color.r==255 and v.u==0.5 and v.v==0.25 and v.normal==n,"encoding mutated reusable cell data/UV/normal")
    end
    print("PASS: UnlitGeneric gamma encoding and HDR gain preserve light values without modifying cached vertices or UVs")

    V.SurfaceMaterial=function(batch) return batch.material end
    V.SurfaceFlashMaterial=function(batch) return batch.flashMaterial end
    V.SurfaceUsesBaked=function(batch) return batch.baked end
    local cut={cutLighting=true,cutScale=2,material={},flashMaterial={},worldCenter=Vector(16,0,0)}
    cut.mesh={IsValid=function() return true end,Draw=function()
        draws[#draws+1]={material=current,modulation=modulation,blend=blend,light=lights[1]}
    end}
    local chunk={lightOrigin=Vector(16,0,0)} r.chunks.test=chunk
    V.DrawSurfaceBatch(r,chunk,cut,true)
    assert(#draws==2 and draws[1].material==cut.material and draws[1].modulation==2 and not draws[1].blend)
    assert(draws[2].material==cut.flashMaterial and draws[2].modulation==1 and draws[2].blend and math.abs(draws[2].light.x-0.2)<1e-9)
    assert(not blend and modulation==1,"HDR/additive state leaked into subsequent props")
    local before=dynamicQueries
    V.DrawSurfaceBatch(r,chunk,cut,false)
    assert(#draws==5 and draws[5].material==cut.flashMaterial and dynamicQueries==before,"flashlight lost or repeated dynamic queries per frame")
    amount=0 frame=frame+1 draws={}
    V.DrawSurfaceBatch(r,chunk,cut,true)
    assert(#draws==1 and modulation==1 and queries==samples,"switched-off lamp or static resampling retained at draw time")
    if V.BuildSurfaceBatches then
        -- Actual batch/cell-cache pipeline, including a shared vertex in two
        -- chunk coordinate systems and separate static/dynamic materials.
        Mesh=function(material)
            return {material=material,IsValid=function() return true end,
                BuildFromTriangles=function(self,list) self.vertices=list end}
        end
        for i,s in ipairs({a,b}) do
            s.identity=i s.nativeFace={} s.materialName="wall" s.span=128 s.center=s.point
            s.interior={} s.interiorCut={} s.slot={material={},litMaterial={}} s.slotIndex=i
        end
        r.surfaceFrozen=true r.surfaceSources={} r.revision=1
        local input={{pos=Vector(0,0,0),normal=n,cell="cut"},{pos=Vector(32,16,0),normal=n,cell="cut"},
            {pos=Vector(32,0,0),normal=n,cell="cut"}}
        local batch=V.BuildSurfaceBatches(r,{key="0:0:0",x=0,y=0,z=0},input)[1]
        assert(batch.cutLighting and not batch.baked and batch.material==batch.source.interiorCut
            and batch.flashMaterial==batch.source.interior and batch.cutScale>1,"cut batch lost gradient material or dynamic albedo")
        assert(batch.mesh.vertices[1].color.r<batch.mesh.vertices[3].color.r,"gradient not uploaded to the real mesh path")
        local cached=r.cutLighting.samples
        local reused=V.BuildSurfaceBatches(r,{key="0:0:0",x=0,y=0,z=0},input)[1]
        assert(r.cutLighting.samples==cached and reused.mesh.vertices[1].color.r==batch.mesh.vertices[1].color.r,
            "cell-cache reuse relights or mutates an unchanged cut")
        local shifted={}
        for _,v in ipairs(input) do shifted[#shifted+1]={pos=v.pos-Vector(128,0,0),normal=n} end
        local neighbor=V.BuildSurfaceBatches(r,{key="1:0:0",x=1,y=0,z=0},shifted)[1]
        for i,v in ipairs(batch.mesh.vertices) do
            assert(v.color.r==neighbor.mesh.vertices[i].color.r and v.color.b==neighbor.mesh.vertices[i].color.b,
                "shared world coordinates changed light across chunk boundaries")
        end
        a.failed=true a.slot.cutMaterial={}
        local failed={source=a,cutLighting=true,material=a.slot.cutMaterial,flashMaterial=a.slot.material}
        assert(saved.material(failed)==a.interiorCut and saved.flash(failed)==a.interior,
            "failed captured albedo reused by gradient or flashlight instead of native fallback")
        a.failed=nil
        print("PASS: actual cut mesh/cell cache uploads gradients, reuses unchanged lighting, keeps dynamic albedo and matches shared vertices across chunk coordinates")
    end
    V.ReleaseVoxelLighting(r) V.ReleaseVoxelLighting(r)
    assert(not r.cutLighting,"region cleanup retained gradient caches")
    print("PASS: gradient draws once, moving lamps add dynamic-only light, flashlight uses untinted albedo; modulation/blend/cache cleanup restored")

    -- Workload size/cost is recorded for comparison, never treated as in-game
    -- FPS or total excavation latency (the engine and GPU are not running).
    local large={step=16,base=Vector(),chunks={},surfaceList={}}
    for y=-4,5 do for z=-4,5 do for _,x in ipairs({0,32}) do
        local s=source(x,Vector(x==0 and -1 or 1,0,0))
        s.point=Vector(x,y*128,z*128)
        s.lightBounds={low=s.point-Vector(0,64,64),high=s.point+Vector(0,64,64)}
        local c=x==0 and shadow or sunny
        s.voxelEnvironment={c,c,c,c,c,c}
        large.surfaceList[#large.surfaceList+1]=s
    end end end
    V.PrepareCutLighting(large)
    local started=os.clock()
    for i=1,2048 do
        V.CutVertexLighting(large,Vector((i%33),((i*13)%128)-64,((i*7)%128)-64),n)
    end
    local cold=(os.clock()-started)*1000
    started=os.clock()
    for i=1,2048 do
        V.CutVertexLighting(large,Vector((i%33),((i*13)%128)-64,((i*7)%128)-64),n)
    end
    local warm=(os.clock()-started)*1000
    assert(large.cutLighting.samples==2048 and large.cutLighting.hits==2048 and queries==samples,
        "steady gradient lookup resamples native BSP or misses repeated points")
    print(string.format("PROFILE: lighting-only Lua adapter, 200 original patches / 2048 vertices: cold %.2f ms, cached %.2f ms, %.1f local candidates/vertex; no in-game FPS claim",
        cold,warm,large.cutLighting.visits/large.cutLighting.samples))

    util=saved.util render=saved.render RealTime=saved.RealTime FrameNumber=saved.FrameNumber Mesh=saved.Mesh
    V.SurfaceMaterial=saved.material V.SurfaceFlashMaterial=saved.flash V.SurfaceUsesBaked=saved.baked
end
