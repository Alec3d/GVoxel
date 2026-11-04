local V=GVoxel
local function ground()
    local face={normal=Vector(0,0,1),distance=0,tex={flags=0,texture=1},displacement=true,
        low=Vector(-600,-600,0),high=Vector(600,600,0),dispLow=Vector(-600,-600,0),dispHigh=Vector(600,600,120),dispWidth=3,dispGrid={}}
    for y=0,2 do for x=0,2 do face.dispGrid[y*3+x+1]=Vector(-600+x*600,-600+y*600,(x==1 and y==1) and 120 or 0) end end
    local data={head=0,nodes={{plane=1,front=-1,back=-1}},planes={{normal=Vector(0,0,1),distance=0}},
        leaves={{solid=false}},faces={face},worldBrushes={}}
    return data,face
end

function RunDisplacementTests()
    local data=ground()
    local face=data.faces[1]
    local triangles={}
    V.ForDisplacementTriangles(face,function(t) triangles[#triangles+1]=t end)
    assert(#triangles==8 and triangles[3][1]==face.dispGrid[2] and triangles[3][2]==face.dispGrid[5]
        and triangles[3][3]==face.dispGrid[3],"odd displacement quad uses the wrong Source diagonal")
    print("PASS: non-planar displacement quads use Source's alternating triangle diagonals")
    local r=V.NewScanRegion(1701,Vector(0,0,120),16)
    local pauses=0
    local prep=coroutine.create(function() return V.PrepareBSPRegion(r,data,function() pauses=pauses+1 coroutine.yield() end) end)
    repeat local ok,result=coroutine.resume(prep) assert(ok,result) until coroutine.status(prep)=="dead"
    assert(pauses>100,"displacement preparation blocks instead of yielding")
    print("PASS: compiled terrain columns and spatial indexing prepare cooperatively before meshing")
    local native=0
    -- Missing/backface-disabled native ray collision must not erase a known
    -- compiled shell while its old image is hidden by the stencil.
    local query,stats,sign=V.ColumnScanTrace(r,function() native=native+1 return {Hit=false} end,function() return false end)
    assert(sign(Vector(0,0,-100))==-1,"compiled terrain becomes empty when native displacement traces miss")
    assert(sign(Vector(0,0,180))==1,"compiled terrain fills the air above its shell")
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=V.ScanDensity(r,p,false,query,sign) end
    local hit=V.TraceScanRegion(r,Vector(0,0,220),Vector(0,0,-1),300)
    local hull=V.TraceVoxelHull(r,Vector(0,0,220),Vector(0,0,-100),Vector(),Vector())
    assert(hit and hull.Hit and hit.HitPos:DistToSqr(hull.HitPos)<1e-7,"terrain render/selection and collision disagree")
    assert(math.abs(hit.HitPos.z-120)<r.step,"compiled hill vanished or flattened")
    local calls=native
    for _=1,30 do assert(sign(Vector(0,0,-100))==-1) query(Vector(0,0,200),Vector(0,0,-200)) end
    assert(native==calls,"unchanged terrain column repeated native traces")
    assert(stats.compiled>0,"compiled terrain intersections were unused")
    V.ApplyBrush(r,Vector(0,0,100),48,false) r.revision=1
    local excavated=V.TraceScanRegion(r,Vector(0,0,220),Vector(0,0,-1),400)
    local landed=V.TraceVoxelHull(r,Vector(0,0,220),Vector(0,0,-180),Vector(),Vector())
    assert(excavated and landed.Hit and excavated.HitPos.z<90 and excavated.HitPos:DistToSqr(landed.HitPos)<1e-7,"excavation loses the ground below the displacement")
    print("PASS: compiled curved terrain survives missing native traces, stays solid at depth, digs with matching mesh/hull and reuses columns")
    local function room(a,b)
        if a.z< -80 and b.z>= -80 then
            local t=(-80-a.z)/(b.z-a.z)
            return {Hit=true,HitWorld=true,HitPos=a+(b-a)*t,HitNormal=Vector(0,0,-1),HitTexture="concrete",Fraction=t}
        end
        return {Hit=false}
    end
    local roomQuery,_,roomSign=V.ColumnScanTrace(r,room,function() return false end)
    assert(roomSign(Vector(0,0,-120))==nil and V.ScanDensity(r,Vector(0,0,-120),false,roomQuery,roomSign)>0,
        "compiled displacement filled a room behind its closer structural ceiling")
    print("PASS: native architecture takes priority over terrain continuation into underground rooms")
    local ceiling={normal=Vector(0,0,-1),tex={flags=0},vertices={Vector(-100,-100,-80),Vector(100,-100,-80),Vector(100,100,-80),Vector(-100,100,-80)}}
    local bins=r.bspFaceBins
    r.bspFaceBins={[V.Index(16,16,math.floor((-80-r.origin.z)/r.step),r)]={ceiling}}
    local ambiguous,ambStats,ambSign=V.ColumnScanTrace(r,function() return {StartSolid=true,FractionLeftSolid=0} end,function() return false end)
    assert(ambSign(Vector(0,0,0))==-1 and ambSign(Vector(0,0,180))==1,
        "ambiguous native column discarded the known compiled ground")
    assert(ambSign(Vector(0,0,-120))==nil,
        "compiled fallback filled a native room below its structural ceiling")
    local calls=ambStats.rays
    for _=1,20 do assert(ambSign(Vector(0,0,0))==-1) end
    assert(ambStats.rays==calls,"ambiguous compiled column was rebuilt on every sample")
    assert(ambiguous(Vector(0,0,180),Vector(0,0,100)).StartSolid and ambStats.fallbacks==1,
        "compiled sign fallback changed the native local distance trace")
    assert(#V.BSPColumnEvents(r,3,Vector(150,0,0))==0,"finite structural ceiling became an infinite plane")
    r.bspFaceBins=bins
    print("PASS: invalid native FractionLeftSolid retains compiled terrain, preserves structural room air and finite ceilings, caches columns and keeps native local distance queries")
    local client=V.NewScanRegion(1702,Vector(0,0,120),16)
    V.PrepareBSPRegion(client,data,nil,false)
    assert(client.bspTerrainFaces and next(client.bspTerrainFaces) and not client.bspTerrainColumns,
        "client repeats server-only terrain column preparation")
    print("PASS: client keeps terrain geometry/material bins without duplicating server sampling columns")
    local steep=ground()
    for _,p in ipairs(steep.faces[1].dispGrid) do p.z=p.x*5 end
    steep.faces[1].dispLow=Vector(-600,-600,-3000) steep.faces[1].dispHigh=Vector(600,600,3000)
    local slope=V.NewScanRegion(1703,Vector(),16)
    V.PrepareBSPRegion(slope,steep)
    local _,_,slopeSign=V.ColumnScanTrace(slope,function() return {Hit=false} end,function() return false end)
    assert(slopeSign(Vector(0,0,-200))==-1 and slopeSign(Vector(0,0,200))==1,
        "steep compiled terrain becomes a hollow crust beyond its local ray reach")
    print("PASS: steep compiled slopes keep deep soil occupancy instead of becoming a thin crust")
end

function RunNativeDisplacementTests(data)
    local tested=0
    for _,face in ipairs(data.faces) do if face.displacement and face.normal.z>0.7 then
        local p=face.dispGrid[math.floor(#face.dispGrid/2)+1]
        if not V.BSPSolid(data,p+face.normal*40) then
            local r=V.NewScanRegion(1720+tested,p,16)
            V.PrepareBSPRegion(r,data)
            local query,_,sign=V.ColumnScanTrace(r,function() return {Hit=false} end,function(pos) return V.BSPSolid(data,pos) end)
            for i=0,33^3-1 do
                local point,x,y,z=V.ScanPoint(r,i)
                r.values[V.Index(x,y,z,r)]=V.ScanDensity(r,point,V.BSPSolid(data,point),query,sign)
            end
            local start,finish=p+Vector(0,0,80),p-Vector(0,0,150)
            local hit=V.TraceScanRegion(r,start,Vector(0,0,-1),230)
            local hull=V.TraceVoxelHull(r,start,finish,Vector(),Vector())
            assert(hit and hull.Hit and hit.HitPos:DistToSqr(hull.HitPos)<0.00001,
                string.format("installed displacement vanished or differs from its hull at %.1f %.1f %.1f: render %s hull %s / %.4f %.4f",
                    p.x,p.y,p.z,tostring(hit~=nil),tostring(hull.Hit),hit and hit.HitPos.z or 99999,hull.HitPos and hull.HitPos.z or 99999))
            assert(math.abs(hit.HitPos.z-p.z)<r.step*2,"installed displacement drifted from its original height")
            local q=(hit.HitPos-r.origin)/r.step
            local vertices=V.BuildChunk(r,math.min(3,math.floor(q.x/8)),math.min(3,math.floor(q.y/8)),math.min(3,math.floor(q.z/8)))
            assert(#vertices>0,"installed displacement has collision but no render vertices")
            tested=tested+1
            if tested==3 then break end
        end
    end end
    assert(tested>0,"no native displacement tested")
    print("PASS: "..tested.." installed displacement patches retain visible mesh and matching collision even with missing native ray hits")
end
