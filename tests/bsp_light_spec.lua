function RunBSPLightTests()
    local V=GVoxel
    local function rgb(r,g,b,e) return string.char(r,g,b,e or 0) end
    local data={lighting=rgb(0,0,0)..rgb(255,128,64)..rgb(0,0,0)..rgb(255,128,64)}
    local face={lightOffset=0,lightSize={1,1},lightMin={-2,3},lightStyles={0,255,255,255},
        tex={lu=Vector(1/16,0,0),lv=Vector(0,1/16,0),luo=-2,lvo=3,flags=0}}
    assert(V.SampleBSPLightmap(data,face,Vector()):LengthSqr()==0,"native shadow replaced by an ambient floor")
    local bright=V.SampleBSPLightmap(data,face,Vector(16,0,0))
    local middle=V.SampleBSPLightmap(data,face,Vector(8,8,0))
    assert(math.abs(bright.x-1)<1e-9 and math.abs(middle.x-0.5)<1e-9 and math.abs(middle.y-64/255)<1e-9,
        "world-to-luxel offsets, linear bilinear interpolation or RGB tint incorrect")
    local hdr={lighting=rgb(255,128,64,2)..rgb(255,128,64,2)..rgb(255,128,64,2)..rgb(255,128,64,2)}
    assert(math.abs(V.SampleBSPLightmap(hdr,face,Vector()).x-4)<1e-9,"HDR RGBExp32 clipped")
    local negative={lighting=rgb(255,128,64,255):rep(4)}
    assert(math.abs(V.SampleBSPLightmap(negative,face,Vector()).x-0.5)<1e-9,"RGBExp32 exponent read as unsigned")
    face.lightStyles={7,0,255,255} face.tex.flags=2048
    local bumped={lighting=rgb(255,0,0):rep(16)..data.lighting}
    assert((V.SampleBSPLightmap(bumped,face,Vector(8,8,0))-middle):LengthSqr()<1e-12,
        "animated/bump sample blocks mistaken for the static style-zero lightmap")
    face.lightStyles={7,255,255,255}
    assert(not V.SampleBSPLightmap(bumped,face,Vector()),"animated-only lightmap frozen as a static shadow")
    face.lightStyles={0,255,255,255} face.tex.flags=0
    assert(not V.SampleBSPLightmap({lighting=""},face,Vector()),"truncated lightmap accepted")
    face.lightOffset=-1 assert(not V.SampleBSPLightmap(data,face,Vector())) face.lightOffset=0
    assert(not V.SampleBSPLightmap(data,face,Vector(1000,0,0)),"unrelated far surface clamped to a border luxel")
    print("PASS: BSP local shadows/color, bilinear luxels, signed RGBExp32/HDR, bumped style strides, animated-only and missing-data fallback")

    local sun=util.GetSunInfo util.GetSunInfo=function() return nil end
    local white=Vector(1,1,1)
    local source={point=Vector(8,8,0),frame={normal=Vector(0,0,1),right=Vector(0,-1,0),up=Vector(1,0,0)},
        planeNormal=Vector(0,0,1),nativeFace=face,lightBounds={low=Vector(),high=Vector(16,16,0)},
        voxelEnvironment={white,white,white,white,white,white}}
    local r={step=16,origin=Vector(),base=Vector(),chunks={},surfaceList={source},bsp=data}
    V.PrepareCutLighting(r)
    local darkLip=V.CutVertexLighting(r,Vector(0,8,0),Vector(1,0,0))
    local litLip=V.CutVertexLighting(r,Vector(16,8,0),Vector(1,0,0))
    assert(darkLip:LengthSqr()==0 and math.abs(litLip.x-1)<1e-9,
        "hole lip still averages sunlight over the original local shadow")
    local justInside=V.CutVertexLighting(r,Vector(0,8,-0.001),Vector(1,0,0))
    local deep=V.CutVertexLighting(r,Vector(0,8,-16),Vector(1,0,0))
    assert(justInside.x<0.00001 and deep.x>0.1,"lightmap lip does not blend continuously into interior transfer")
    util.GetSunInfo=sun
    print("PASS: excavation lip matches the original black/sunlit luxel at the same world position and blends into interior lighting")

    if V.BuildSurfaceBatches then
        source.span=128 source.center=source.point source.identity=1 source.slotIndex=0
        source.failed=true source.ready=true source.uncaptured=true source.materialName="wall"
        source.interior={} source.interiorCut={} source.slot={material={},litMaterial={}}
        r.surfaceFrozen=true r.surfaceSources={["0:0:0"]={source}} r.revision=0
        -- No cut-light index: original scan/fallback must already receive its
        -- own spatial lighting, before the interior index has been prepared.
        r.cutLighting=nil
        local vertices={{pos=Vector(),normal=Vector(0,0,1),cell="exterior"},
            {pos=Vector(0,16,0),normal=Vector(0,0,1),cell="exterior"},
            {pos=Vector(16,0,0),normal=Vector(0,0,1),cell="exterior"}}
        local batches=V.BuildSurfaceBatches(r,{key="0:0:0",x=0,y=0,z=0},vertices)
        local batch=batches[1]
        assert(batch.surfaceLight and batch.cutLighting and not batch.baked and batch.material==source.interiorCut
            and batch.flashMaterial==source.interior,"exterior fallback still uses a uniform ambient cube")
        assert(batch.mesh.vertices[1].color.r==0 and batch.mesh.vertices[3].color.r==255,
            "per-position original shadow not uploaded to exterior geometry")
        local sample=V.SurfaceLightmap
        V.SurfaceLightmap=function() error("unchanged surface cell resampled") end
        local cached=V.BuildSurfaceBatches(r,{key="0:0:0",x=0,y=0,z=0},vertices)
        V.SurfaceLightmap=sample
        assert(cached[1].mesh.vertices[1].color.r==0)
        source.failed=false source.nativeReflection=true
        for _,v in ipairs(vertices) do v.cell="reflective" end
        local reflective=V.BuildSurfaceBatches(r,{key="0:0:0",x=0,y=0,z=0},vertices)
        assert(reflective[1].baked and not reflective[1].surfaceLight and reflective[1].material==source.slot.litMaterial,
            "available native reflection/bump capture was discarded for a generic shader")
        for _,b in ipairs(batches) do b.mesh:Destroy() end
        for _,b in ipairs(cached) do b.mesh:Destroy() end
        for _,b in ipairs(reflective) do b.mesh:Destroy() end
        local upper,lower={},{}
        for k,v in pairs(source) do upper[k]=v lower[k]=v end
        upper.identity=10 upper.failed=true upper.point=Vector(100,100,0)
        upper.lightBounds={low=Vector(-100,-100,0),high=Vector(100,100,0)}
        lower.identity=11 lower.failed=true lower.point=Vector(0,0,-5)
        lower.lightBounds={low=Vector(-5,-5,-5),high=Vector(5,5,-5)}
        r.surfaceSources["0:0:0"]={lower,upper}
        local patch={{pos=Vector(),normal=Vector(0,0,1),cell="finite"},
            {pos=Vector(0,1,0),normal=Vector(0,0,1),cell="finite"},
            {pos=Vector(1,0,0),normal=Vector(0,0,1),cell="finite"}}
        local selected=V.BuildSurfaceBatches(r,{key="0:0:0",x=0,y=0,z=0},patch)
        assert(selected[1].source==upper,"surface material was taken from a buried floor with a closer centroid")
        for _,b in ipairs(selected) do b.mesh:Destroy() end
        print("PASS: finite surface/plane distance keeps the ground material instead of a buried ceiling with a closer centroid")
        print("PASS: initial exterior fallback uploads native per-vertex shadow before the interior index, retains dynamic albedo and reuses unchanged cell lighting")
    end
end

function RunNativeBSPLightTests(data)
    local samples,lowest,highest=0,math.huge,0
    for _,face in ipairs(data.faces) do
        assert(face.lightStyles and #face.lightStyles==4,"compiled face styles not decoded")
        local p=Vector()
        for _,vertex in ipairs(face.vertices) do p=p+vertex end
        p=p/#face.vertices
        local c=GVoxel.SampleBSPLightmap(data,face,p)
        if c then
            samples=samples+1
            local brightness=(c.x+c.y+c.z)/3
            lowest=math.min(lowest,brightness) highest=math.max(highest,brightness)
        end
    end
    assert(samples>100 and highest>lowest+0.1,"installed map's spatial lightmaps were not exercised")
    print(string.format("PASS: installed gm_construct %s lightmaps: %d original face positions sampled, linear brightness %.4f..%.4f (no GPU calibration)",
        data.lightingHDR and "HDR" or "LDR",samples,lowest,highest))
end

function RunHDRLightReaderTests(bytes)
    local oldClient,oldConVar=CLIENT,GetConVar
    CLIENT=true
    GetConVar=function(name)
        if name=="mat_hdr_level" then return {GetInt=function() return 2 end} end
        return oldConVar and oldConVar(name)
    end
    local data=GVoxel.ReadBSP(BSPTestStream(bytes))
    -- An unsupported compressed HDR section must not break usable LDR maps.
    local offset=8+53*16+12
    local compressed=bytes:sub(1,offset)..string.char(1,0,0,0)..bytes:sub(offset+5)
    local fallback=GVoxel.ReadBSP(BSPTestStream(compressed))
    CLIENT=oldClient GetConVar=oldConVar
    assert(data.lightingHDR,"client HDR selection ignored paired HDR faces/light samples")
    assert(not fallback.lightingHDR and #fallback.faces==#data.faces,"compressed HDR did not retain valid LDR geometry/lighting")
    RunNativeBSPLightTests(data)
    print("PASS: unsupported compressed HDR falls back to a consistent LDR face/lightmap pair")
end
