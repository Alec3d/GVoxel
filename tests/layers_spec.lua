local V=GVoxel
local function addBox(data,low,high,texture)
    local brush={low=low,high=high,planes={},contents=134217729}
    local faces=V.MaskFaces({origin=Vector(),side=1})
    for _,face in ipairs(faces) do
        local vertices={} local lo,hi=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
        for _,p in ipairs(face.vertices) do
            local point=Vector(low.x+p.x*(high.x-low.x),low.y+p.y*(high.y-low.y),low.z+p.z*(high.z-low.z))
            vertices[#vertices+1]=point
            for _,a in ipairs({"x","y","z"}) do lo[a]=math.min(lo[a],point[a]) hi[a]=math.max(hi[a],point[a]) end
        end
        local distance=face.normal:Dot(vertices[1])
        brush.planes[#brush.planes+1]={normal=face.normal,distance=distance}
        data.faces[#data.faces+1]={vertices=vertices,normal=face.normal,distance=distance,low=lo,high=hi,
            tex={flags=0,u=Vector(0,2,0),v=Vector(-4,0,0),uo=13,vo=-29,texture=texture or 1}}
    end
    data.worldBrushes[#data.worldBrushes+1]=brush
    return brush
end

function RunLayerTests()
    local data={head=0,nodes={{plane=1,front=-1,back=-1}},planes={{normal=Vector(0,0,1),distance=0}},
        leaves={{solid=false,cluster=0}},faces={},worldBrushes={},textures={{name="test/road",w=512,h=256}}}
    addBox(data,Vector(-400,-400,-20),Vector(400,400,-19.2))
    addBox(data,Vector(-400,-400,3.2),Vector(400,400,4))
    addBox(data,Vector(70,-140,0),Vector(72,140,110))
    data.leaves[1].brushes=data.worldBrushes
    assert(not V.BSPLeaf(data,Vector(0,0,3.5)).solid and V.BSPSolid(data,Vector(0,0,3.5)),"detail road absent from an air leaf")
    for _,hybrid in ipairs({false,true}) do
        local r=V.NewScanRegion(1001,Vector(),16)
        V.PrepareBSPRegion(r,data)
        if hybrid then
            r.bspFallback={} r.bspFallbackUnknown={}
            for z=0,31 do for y=0,31 do for x=0,31 do local key=V.Index(x,y,z,r) r.bspFallback[key]=true r.bspFallbackUnknown[key]=true end end end
        end
        -- The road is thinner than a lattice cell and all density nodes are
        -- deliberately air. Only the compiled brush volumes can preserve it.
        local function floor(start,expected)
            local ray=V.TraceScanRegion(r,start,Vector(0,0,-1),100)
            local hit=V.TraceVoxelHull(r,start,start-Vector(0,0,100),Vector(),Vector())
            assert(ray and hit.Hit and math.abs(hit.HitPos.z-expected)<1e-6 and ray.HitPos:DistToSqr(hit.HitPos)<1e-8,
                "layer mesh/hull lost: hybrid="..tostring(hybrid).." expected="..expected.." actual="..tostring(hit.HitPos.z))
        end
        floor(Vector(0,0,20),4) floor(Vector(0,0,0),-19.2)
        local aperture=V.BuildBoundaryOpening(r,V.MaskFaces(r)[1])
        for i=1,#aperture,3 do
            local z=(aperture[i].pos.z+aperture[i+1].pos.z+aperture[i+2].pos.z)/3
            assert(not (z>3.2+1e-6 and z<4-1e-6) and not (z> -20+1e-6 and z< -19.2-1e-6),"boundary aperture exposes a solid detail layer")
        end
        local changed
        _,changed=V.ApplyBrush(r,Vector(71,0,64),30,false) assert(changed) r.revision=1
        floor(Vector(0,0,20),4) floor(Vector(0,0,0),-19.2)
        _,changed=V.ApplyBrush(r,Vector(0,0,4),12,false) assert(changed) r.revision=2
        floor(Vector(0,0,20),-19.2)
        floor(Vector(-60,0,20),4)
        -- Source identity survives carving/clipping into neighboring cells.
        local found=false
        for _,v in ipairs(V.BuildChunk(r,1,1,2)) do if v.nativeFace then found=true assert(v.nativeFace.tex.texture==1) end end
        assert(found,"original face provenance lost after carving")
    end
    print("PASS: two sub-cell detail floors in air leaves; wall excavation keeps support; road hole reaches lower floor; exact and mixed-density mesh/SAT agree")

    -- A nearby displacement must not replace an intact building's upper
    -- corners with rounded density triangles through its entire column.
    local terrain={normal=Vector(0,0,1),distance=-100,tex={flags=0,texture=1},displacement=true,
        low=Vector(-200,-200,-100),high=Vector(200,200,-100),dispWidth=2,dispGrid={
            Vector(-200,-200,-100),Vector(200,-200,-100),Vector(-200,200,-100),Vector(200,200,-100)}}
    data.faces[#data.faces+1]=terrain
    local r=V.NewScanRegion(1002,Vector(),16)
    V.PrepareBSPRegion(r,data)
    local q=(Vector(71,0,100)-r.origin)/r.step
    assert(not V.BSPCellUsesDensity(r,math.floor(q.x),math.floor(q.y),math.floor(q.z)),"ground displacement still rounds the wall above it")
    local source=V.BSPFaceAt(r,Vector(0,0,4),Vector(0,0,1),1)
    assert(source and source.distance==4,"local texture lookup chose another parallel floor")
    source=V.BSPFaceAt(r,Vector(0,0,-100),Vector(0,0,1),1)
    assert(source==terrain,"displacement material provenance lost")
    print("PASS: displacement footprint leaves architecture above it exact; local material lookup distinguishes parallel floors and displaced ground")
end

function RunMapLayerTests(data)
    local candidates,exercised=0,0
    local coldPeak,warmTotal=0,0
    for _,face in ipairs(data.faces) do
        if not face.displacement and face.normal.z>0.999 and face.high.x-face.low.x>40 and face.high.y-face.low.y>40 then
            local p=Vector() for _,vertex in ipairs(face.vertices) do p=p+vertex/#face.vertices end
            local below=p-Vector(0,0,0.125)
            if not V.BSPLeaf(data,below).solid and V.BSPSolid(data,below) and not V.BSPSolid(data,p+Vector(0,0,1)) then
                candidates=candidates+1
                if exercised<6 then
                    local r=V.NewScanRegion(1100+exercised,p,16)
                    for i=0,33^3-1 do local point,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=V.BSPSolid(data,point) and -r.step or r.step end
                    V.PrepareBSPRegion(r,data)
                    local start=p+Vector(0,0,1)
                    local hit=V.TraceVoxelHull(r,start,p-Vector(0,0,1),Vector(),Vector())
                    assert(hit.Hit and math.abs(hit.HitPos.z-p.z)<1e-5,"real detail floor absent from collision")
                    local begin=os.clock()
                    local player=V.TraceVoxelHull(r,start,p-Vector(0,0,1),Vector(-16,-16,0),Vector(16,16,72))
                    coldPeak=math.max(coldPeak,(os.clock()-begin)*1000)
                    assert(player.Hit and not player.StartSolid and math.abs(player.HitPos.z-p.z)<1e-5,"standing player has no real detail support")
                    V.ApplyBrush(r,p+Vector(80,0,64),30,false) r.revision=1
                    local after=V.TraceVoxelHull(r,start,p-Vector(0,0,1),Vector(),Vector())
                    assert(after.Hit and after.HitPos:DistToSqr(hit.HitPos)<1e-8,"unrelated real-map excavation removed the floor")
                    begin=os.clock()
                    for _=1,30 do
                        local support=V.TraceVoxelHull(r,start,p-Vector(0,0,1),Vector(-16,-16,0),Vector(16,16,72))
                        assert(support.Hit and not support.StartSolid and math.abs(support.HitPos.z-p.z)<1e-5,"player fell through after wall edit")
                    end
                    warmTotal=warmTotal+(os.clock()-begin)*1000
                    print(string.format("PASS: real detail floor (%.2f %.2f %.2f) survives nearby excavation",p.x,p.y,p.z))
                    exercised=exercised+1
                end
            end
        end
    end
    assert(candidates>0 and exercised==6,"real detail floor regression not exercised")
    print("PASS: real BSP has "..#data.worldBrushes.." collidable world brushes; "..candidates.." upward detail faces previously absent from leaf-only occupancy")
    print(string.format("PROFILE: real-map player hull: cold peak %.2f ms; 180 warm sweeps %.2f ms total (Lua vector adapter, not in-game)",coldPeak,warmTotal))
end
