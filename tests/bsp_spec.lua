-- File adapter tests the actual installed map, without launching Source.
function BSPTestStream(bytes)
    local stream={pos=1}
    function stream:Size() return #bytes end
    function stream:Read(n) local s=bytes:sub(self.pos,self.pos+n-1) self.pos=self.pos+n return s end
    function stream:Seek(n) self.pos=n+1 end
    function stream:Skip(n) self.pos=self.pos+n end
    function stream:ReadByte() local a=bytes:byte(self.pos) self.pos=self.pos+1 return assert(a) end
    function stream:ReadUShort() local a,b=self:Read(2):byte(1,2) return a+b*256 end
    function stream:ReadShort() local n=self:ReadUShort() return n>=32768 and n-65536 or n end
    function stream:ReadULong() local a,b,c,d=self:Read(4):byte(1,4) return a+b*256+c*65536+d*16777216 end
    function stream:ReadLong() local n=self:ReadULong() return n>=2147483648 and n-4294967296 or n end
    function stream:ReadFloat()
        local n=self:ReadULong() local sign=n>=2147483648 and -1 or 1
        local exponent=math.floor(n/8388608)%256 local mantissa=n%8388608
        assert(exponent<255,"nonfinite BSP float")
        return sign*(exponent==0 and mantissa*2^-149 or (1+mantissa/8388608)*2^(exponent-127))
    end
    return stream
end

local V=GVoxel
local oldHook,oldFile,oldGame=hook,file,game
hook={Add=function() end} file=nil game=nil
function BSPTestRestoreGlobals() hook=oldHook file=oldFile game=oldGame end

local function architecture(center,half,yaw,tilt)
    local cy,sy,ct,st=math.cos(yaw),math.sin(yaw),math.cos(tilt),math.sin(tilt)
    local function rotate(p) return Vector(cy*ct*p.x-sy*p.y+cy*st*p.z,sy*ct*p.x+cy*p.y+sy*st*p.z,-st*p.x+ct*p.z) end
    local data={planes={},nodes={},leaves={{solid=false,cluster=0},{solid=true,cluster=-1}},faces={},head=0}
    local faces=V.MaskFaces({origin=-half,side=half.x*2})
    -- Use a cube; rotation covers non-axis-aligned floors and 90-degree corners.
    for i,face in ipairs(faces) do
        local normal=rotate(face.normal) local vertices={}
        local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
        for _,p in ipairs(face.vertices) do
            p=rotate(p)+center vertices[#vertices+1]=p
            for _,axis in ipairs({"x","y","z"}) do low[axis]=math.min(low[axis],p[axis]) high[axis]=math.max(high[axis],p[axis]) end
        end
        local distance=normal:Dot(vertices[1])
        data.planes[i]={normal=normal,distance=distance}
        data.nodes[i]={plane=i,front=-1,back=i==6 and -2 or i}
        data.faces[i]={normal=normal,distance=distance,vertices=vertices,low=low,high=high,tex={flags=0}}
    end
    return data
end

function RunBSPGeometryTests()
    for _,rotation in ipairs({{0,0},{0.57,0.31}}) do
        local center,half=Vector(3.71234,-7.12345,2.45678),Vector(65,65,65)
        local data=architecture(center,half,rotation[1],rotation[2])
        local r=V.NewScanRegion(900,Vector(),16)
        assert(V.PrepareBSPRegion(r,data))
        local area,points,polygons=0,{},0
        V.ForChunks(function(x,y,z)
            local offset=r.origin+Vector(x,y,z)*(r.step*8)
            local vertices=V.BuildChunk(r,x,y,z)
            for i=1,#vertices,3 do
                local a,b,c=vertices[i].pos+offset,vertices[i+1].pos+offset,vertices[i+2].pos+offset
                area=area+(b-a):Cross(c-a):Length()/2 polygons=polygons+1
                for _,p in ipairs({a,b,c}) do
                    local error=math.huge
                    for _,plane in ipairs(data.planes) do error=math.min(error,math.abs(p:Dot(plane.normal)-plane.distance)) end
                    assert(error<0.000001,"architecture drifted from original BSP plane: "..error)
                    points[string.format("%.5f:%.5f:%.5f",p.x,p.y,p.z)]=true
                end
            end
        end,r)
        assert(math.abs(area-6*130^2)<0.01,"original area/dimensions lost or duplicate faces: "..area)
        for _,face in ipairs(data.faces) do for _,p in ipairs(face.vertices) do
            assert(points[string.format("%.5f:%.5f:%.5f",p.x,p.y,p.z)],"original sharp corner was rounded off")
        end end
        assert(not r.terrainCache.bspLeaves,"visual scan unnecessarily built 32768 collision volumes")
        local function checkRays()
            for i=1,18 do
                local direction=Vector(math.cos(i),math.sin(i),math.sin(i*0.7)):GetNormalized()
                local start=center+direction*160
                local ray=V.TraceScanRegion(r,start,-direction,320)
                local hull=V.TraceVoxelHull(r,start,center-direction*160,Vector(),Vector())
                assert((ray~=nil)==hull.Hit,"exact BSP mesh and collision disagree on hit")
                if ray then assert(ray.HitPos:DistToSqr(hull.HitPos)<0.001,"BSP mesh/collision intersection mismatch") end
            end
        end
        checkRays()
        local initial=V.CloneScanField(r)
        local dirty,changed=V.ApplyBrush(r,center+Vector(0,0,half.z),44,false)
        assert(changed and next(dirty) and #r.bspEdits==1 and #initial.bspEdits==0,"CSG stroke leaked into visible snapshot")
        assert(not next(initial.bspEditBins),"CSG spatial index mutated old field")
        local repeated,repeatedChange=V.ApplyBrush(r,center+Vector(0,0,half.z),44,false)
        assert(not repeatedChange and not next(repeated) and #r.bspEdits==1,"identical CSG stroke rebuilt the terrain")
        r.revision=1 checkRays()
        V.ApplyBrush(r,center+Vector(0,0,half.z),30,true) r.revision=2 checkRays()
    end
    print("PASS: exact BSP dimensions, original sharp corners, rotated/tilted architecture, lazy collision, ordered carve/add and shared mesh/hull intersections")

    -- A floor exactly aligned with a lattice plane must have one owner, no
    -- double surface and no quantized 1/64-unit vertical offset.
    local z=3.712345
    local data={planes={{normal=Vector(0,0,1),distance=z}},nodes={{plane=1,front=-1,back=-2}},
        leaves={{solid=false,cluster=0},{solid=true,cluster=-1}},head=0,faces={{normal=Vector(0,0,1),distance=z,
        low=Vector(-1000,-1000,z),high=Vector(1000,1000,z),tex={flags=0},
        vertices={Vector(-1000,-1000,z),Vector(1000,-1000,z),Vector(1000,1000,z),Vector(-1000,1000,z)}}}}
    local r=V.NewScanRegion(901,Vector(0,0,z),16) assert(V.PrepareBSPRegion(r,data))
    _BSP_TEST_FLOOR=data
    local area=0
    V.ForChunks(function(x,y,zz)
        local offset=r.origin+Vector(x,y,zz)*(r.step*8)
        local verts=V.BuildChunk(r,x,y,zz)
        for i=1,#verts,3 do
            local a,b,c=verts[i].pos+offset,verts[i+1].pos+offset,verts[i+2].pos+offset
            assert(math.abs(a.z-z)<1e-9,"floor offset") area=area+(b-a):Cross(c-a):Length()/2
        end
    end,r)
    assert(math.abs(area-r.side^2)<0.01,"lattice-aligned floor doubled or missing: "..area)
    local hit=V.TraceVoxelHull(r,Vector(0,0,z+100),Vector(0,0,z-100),Vector(-4,-4,-4),Vector(4,4,4))
    assert(hit.Hit and math.abs(hit.HitPos.z-(z+4))<1e-6,"floor collision height differs")
    local openings=V.BSPBoundaryOpening(r,V.MaskFaces(r)[5])
    assert(#openings==0,"solid underside exposed as a room")
    assert(#V.BSPBoundaryOpening(r,V.MaskFaces(r)[6])>0,"air outside cube hidden")
    local origins=V.BSPVisibilityOrigins(data,r) assert(#origins==1,"duplicate PVS clusters")
    print("PASS: sub-1/64 floor alignment, no doubled lattice face, exact player height and external-room apertures/PVS origins")

    -- Two unrelated visibility clusters: seeing room 0 does not imply room 1.
    local visibility={head=0,nodes={{plane=1,front=-1,back=-2}},planes={{normal=Vector(0,0,1),distance=0}},
        leaves={{solid=false,cluster=0,area=1},{solid=false,cluster=1,area=2}},pvsRows={},
        visibility=string.char(2,0,0,0,20,0,0,0,20,0,0,0,21,0,0,0,21,0,0,0,1,2)}
    local row,area=V.BSPVisibleClusters(visibility,Vector(0,0,1))
    assert(area==1 and V.BSPClustersInPVS(row,{0}) and not V.BSPClustersInPVS(row,{1}),"separate-room PVS decoded incorrectly")
    assert(V.BSPVisibleClusters(visibility,Vector(0,0,2))==row,"PVS row was rebuilt while moving in same cluster")
    print("PASS: separate room PVS rows, target cluster selection and cached visibility decoding")

    local thin=architecture(Vector(),Vector(65,65,65),0,0)
    for i,face in ipairs(thin.faces) do
        local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
        for _,p in ipairs(face.vertices) do
            p.x=p.x*(0.8/130)
            for _,axis in ipairs({"x","y","z"}) do low[axis]=math.min(low[axis],p[axis]) high[axis]=math.max(high[axis],p[axis]) end
        end
        face.low,face.high=low,high face.distance=face.normal:Dot(face.vertices[1])
        thin.planes[i].distance=face.distance
    end
    local detail=V.NewScanRegion(902,Vector(),16)
    assert(V.PrepareBSPRegion(detail,thin))
    local trace=V.TraceScanRegion(detail,Vector(-50,0,0),Vector(1,0,0),100)
    local hull=V.TraceVoxelHull(detail,Vector(-50,0,0),Vector(50,0,0),Vector(),Vector())
    assert(trace and hull.Hit and math.abs(trace.HitPos.x+0.4)<1e-6 and trace.HitPos:DistToSqr(hull.HitPos)<1e-8,
        "sub-cell wall mismatch: ray="..tostring(trace and trace.HitPos.x)..", hull="..tostring(hull.Hit)..":"..hull.HitPos.x)
    assert(trace.HitNormal.x< -0.999999,"exact thin-wall brush normal came from the empty coarse density field")
    thin.faces[1].displacement=true
    local displaced=V.NewScanRegion(903,Vector(),16)
    assert(V.PrepareBSPRegion(displaced,thin) and displaced.bspFallback,"displacement did not retain density occupancy")
    assert(V.BSPCellUsesDensity(displaced,16,16,16),"displacement column replaced by a flat support brush")
    thin.faces[1].displacement=false thin.faces[1].tex.flags=4
    local sky=V.NewScanRegion(904,Vector(),16)
    assert(V.PrepareBSPRegion(sky,thin) and sky.bspFallback,"sky did not retain local density reconstruction")
    print("PASS: 0.8-unit wall retained between empty coarse nodes; displacement/sky fallback is local")

    local hybrid=V.NewScanRegion(905,Vector(0,0,z),16)
    local displacedFace={normal=Vector(0,0,1),distance=z,tex={flags=0},displacement=true,
        low=Vector(210,-80,z),high=Vector(270,80,z),vertices={}}
    local mixed={head=data.head,nodes=data.nodes,planes=data.planes,leaves=data.leaves,faces={data.faces[1],displacedFace}}
    assert(V.PrepareBSPRegion(hybrid,mixed))
    for i=0,33^3-1 do local p,x,y,zz=V.ScanPoint(hybrid,i) hybrid.values[V.Index(x,y,zz,hybrid)]=p.z-z end
    assert(not V.BSPCellUsesDensity(hybrid,16,16,15) and V.BSPCellUsesDensity(hybrid,27,16,15))
    local exact=V.TraceScanRegion(hybrid,Vector(0,0,z+40),Vector(0,0,-1),80)
    assert(exact and math.abs(exact.HitPos.z-z)<1e-9,"nearby displacement shifted the architectural floor")
    local approximate=V.TraceScanRegion(hybrid,Vector(220,0,z+40),Vector(0,0,-1),80)
    local contact=V.TraceVoxelHull(hybrid,Vector(220,0,z+40),Vector(220,0,z-40),Vector(),Vector())
    assert(approximate and contact.Hit and approximate.HitPos:DistToSqr(contact.HitPos)<1e-9,"mixed density mesh/collision mismatch")
    local aperture=V.BuildBoundaryOpening(hybrid,V.MaskFaces(hybrid)[4])
    for _,v in ipairs(aperture) do assert(v.pos.z>=z-1e-8,"hybrid aperture exposes the solid floor") end
    local distant=V.BSPCell(hybrid,22,22,15)
    V.BSPCellSolids(hybrid,22,22,15)
    local leaves=hybrid.terrainCache.bspLeaves and hybrid.terrainCache.bspLeaves["2:2:1"]
    local solids=distant.solids
    assert(solids and not leaves,"fully solid base cell still constructs clipped BSP leaves")
    local staged=V.CloneScanField(hybrid)
    V.ApplyBrush(staged,Vector(5,5,z-10),24,false) staged.revision=1
    assert((staged.terrainCache.bspLeaves and staged.terrainCache.bspLeaves["2:2:1"])==leaves,"static BSP leaves rebuilt for a brush")
    assert(V.BSPCell(staged,22,22,15)==distant,"distant cell in dirty chunk was discarded")
    assert(V.BSPCell(staged,22,22,15).solids==solids,"distant cached solid was discarded")
    assert(V.BSPCell(hybrid,22,22,15)==distant,"staging mutated displayed cache")
    local border=hybrid.origin.x+24*hybrid.step
    assert(not V.BSPCellUsesDensity(hybrid,23,16,15) and V.BSPCellUsesDensity(hybrid,24,16,15))
    V.BSPDensityBase(hybrid)
    for pass=1,2 do
        local _,changed=V.ApplyBrush(hybrid,Vector(border,0,z+(pass==1 and -10 or 5)),pass==1 and 48 or 30,pass==2)
        assert(changed) hybrid.revision=hybrid.revision+1
        for y=-25,25,10 do
            local left=V.TraceScanRegion(hybrid,Vector(border-0.0001,y,z+100),Vector(0,0,-1),200)
            local right=V.TraceScanRegion(hybrid,Vector(border+0.0001,y,z+100),Vector(0,0,-1),200)
            assert(left and right and math.abs(left.HitPos.z-right.HitPos.z)<0.01,"mixed exact/density CSG opened a seam")
            local hull=V.TraceVoxelHull(hybrid,Vector(border+0.0001,y,z+100),Vector(border+0.0001,y,z-100),Vector(),Vector())
            assert(hull.Hit and right.HitPos:DistToSqr(hull.HitPos)<1e-6,"mixed CSG mesh and hull differ")
        end
    end
    assert(V.BSPDensityBase(hybrid).values~=hybrid.values and math.abs(V.BSPDensityBase(hybrid).values[V.Index(24,16,16,hybrid)])<1e-9,
        "sculpting modified the original relief field")
    print("PASS: mixed relief/architecture retains exact floor and matching apertures/hulls; cached solids and distant cells survive local edits")
    print("PASS: carve then add across exact/density boundary stays joined and shares visual/physical surfaces")
    local covered=V.NewScanRegion(906,Vector(0,0,z),16)
    V.PrepareBSPRegion(covered,data)
    local point=covered.origin+Vector(16.5,16.5,12.5)*covered.step
    V.ApplyBrush(covered,point,80,false) covered.revision=1
    local removed=V.BSPCell(covered,16,16,12)
    assert(#removed.triangles==0 and #removed.solids==0 and not covered.terrainCache.bspLeaves,
        "fully removed cell still partitions the BSP/history")
    V.ApplyBrush(covered,point,80,true) covered.revision=2
    local filled=V.BSPCell(covered,16,16,12)
    assert(#filled.triangles==0 and #filled.solids==1 and not covered.terrainCache.bspLeaves,
        "fully filled cell still partitions the BSP/history")
    print("PASS: fully overwritten cells bypass BSP partition/history for both digging and filling")
    local visualOnly=V.NewScanRegion(907,Vector(0,0,z),16)
    V.PrepareBSPRegion(visualOnly,mixed)
    for i=0,33^3-1 do local p,x,y,zz=V.ScanPoint(visualOnly,i) visualOnly.values[V.Index(x,y,zz,visualOnly)]=p.z-z end
    V.ApplyBrush(visualOnly,Vector(border,0,z-10),48,false) visualOnly.revision=1
    V.BuildChunk(visualOnly,3,2,1)
    assert(not visualOnly.terrainCache.bspLeaves and not visualOnly.terrainCache.hulls,
        "a visual stroke still builds collision volumes/SAT axes before displaying the hole")
    print("PASS: visual CSG uses 2D boundary cuts; collision volumes and SAT axes stay lazy after a stroke")
    local incremental=V.NewScanRegion(908,Vector(0,0,z),16)
    V.PrepareBSPRegion(incremental,data)
    local rebuilt=V.CloneScanField(incremental)
    for stroke=1,12 do
        local center=Vector((stroke%4)*7-10,(stroke%3)*8-8,z-15+(stroke%2)*5)
        local adding=stroke%4==0
        V.ApplyBrush(incremental,center,36,adding) incremental.revision=stroke
        V.ApplyBrush(rebuilt,center,36,adding) rebuilt.revision=stroke rebuilt.terrainCache=nil
        for y=-15,15,15 do for x=-15,15,15 do
            local start=Vector(x,y,z+90)
            local a=V.TraceScanRegion(incremental,start,Vector(0,0,-1),200)
            local b=V.TraceScanRegion(rebuilt,start,Vector(0,0,-1),200)
            assert(a and b and a.HitPos:DistToSqr(b.HitPos)<1e-8,"incremental CSG differs from a full ordered replay")
            local hull=V.TraceVoxelHull(incremental,start,Vector(x,y,z-110),Vector(),Vector())
            assert(hull.Hit and a.HitPos:DistToSqr(hull.HitPos)<1e-6,"incremental boundary and lazy collision differ")
        end end
    end
    print("PASS: 12 overlapping incremental carve/add strokes match full replay and exact lazy collision")
end

function RunBSPBrushPerformanceTests()
    local base={faces=GVoxel.MaskFaces({origin=Vector(-20,-20,-20),side=40}),solid=true}
    local clip=V.ClipBSPPolytope
    local function legacy(operations)
        local pieces={base}
        for _,op in ipairs(operations) do
            local out={}
            for _,piece in ipairs(pieces) do
                if piece.solid==op.adding then out[#out+1]=piece else
                    local outside=clip(piece,-op.normal,-op.distance,"cut")
                    local inside=clip(piece,op.normal,op.distance,"cut")
                    if outside then out[#out+1]=outside end
                    if inside then out[#out+1]={faces=inside.faces,solid=op.adding} end
                end
            end
            pieces=out
        end
        local solid={} for _,p in ipairs(pieces) do if p.solid then solid[#solid+1]=p end end
        return solid
    end
    local polygonClip=V.ClipBSPPolygon local count=0
    V.ClipBSPPolygon=function(...) count=count+1 return polygonClip(...) end
    local operations={}
    for i=1,32 do
        local n=Vector(math.cos(i*0.37),math.sin(i*0.37),0.3*math.sin(i)):GetNormalized()
        operations[i]={normal=n,distance=-6+(i%5)*0.2,adding=false}
    end
    local old=legacy(operations) local before=count count=0
    local current=V.ApplyBSPBrushPlanes({base},operations) local after=count
    V.ClipBSPPolygon=polygonClip
    assert(after<before*0.65,"CSG still partitions accumulated air: "..before.." -> "..after)
    local function contains(pieces,p)
        for _,piece in ipairs(pieces) do
            local inside=true
            for _,face in ipairs(piece.faces) do if (p-face.vertices[1]):Dot(face.normal)>1e-6 then inside=false break end end
            if inside then return true end
        end
        return false
    end
    for pass=1,2 do
        if pass==2 then
            for i,op in ipairs(operations) do op.adding=i%3==0 end
            old=legacy(operations) current=V.ApplyBSPBrushPlanes({base},operations)
        end
        for x=-18,18,6 do for y=-18,18,6 do for z=-18,18,6 do
            local p=Vector(x,y,z) local expected=true
            for _,op in ipairs(operations) do if op.normal:Dot(p)<op.distance then expected=op.adding end end
            assert(contains(current,p)==expected and contains(old,p)==expected,"ordered CSG occupancy changed")
        end end end
    end
    print(string.format("PASS: 32 overlapping brushes: %d -> %d polygon clips; identical sampled ordered remove/add occupancy",before,after))
end
