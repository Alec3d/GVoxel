-- Open terrain sheets are volume boundaries, not automatically closed boxes.
local V=GVoxel
local function sheet(z,normal,half)
    half=half or 256
    local vertices={Vector(-half,-half,z),Vector(half,-half,z),Vector(half,half,z),Vector(-half,half,z)}
    return {vertices=vertices,normal=Vector(0,0,normal),distance=z*normal,tex={flags=0},
        low=Vector(-half,-half,z),high=Vector(half,half,z)}
end
local function region(faces,id)
    local r=assert(V.NewCustomScanRegion(id,Vector(-96,-96,-160),Vector(96,96,160)))
    local data={head=-1,planes={},nodes={},leaves={{solid=false}},faces=faces,worldBrushes={}}
    local pauses=0
    V.PrepareBSPRegion(r,data,function() pauses=pauses+1 end)
    local native=0
    local query,stats,sign=V.ColumnScanTrace(r,function() native=native+1 return {Hit=false} end,function() return false end)
    for z=0,r.cells.z do for y=0,r.cells.y do for x=0,r.cells.x do
        local p=r.origin+Vector(x,y,z)*r.step
        r.values[V.Index(x,y,z,r)]=V.ScanDensity(r,p,false,query,sign)
    end end end
    return r,sign,query,function() return native end,stats,pauses
end

function RunOpenLayerTests()
    local top=sheet(80,1)
    local single,sign,query,calls,stats,pauses=region({top},2810)
    assert(pauses>0 and stats.compiled>0 and next(single.bspFallback),"open ordinary world face not indexed as terrain")
    assert(sign(Vector(0,0,100))==1 and sign(Vector(0,0,-140))==-1,"one upward face requires an underside to retain deep matter")
    local count=calls()
    for _=1,100 do sign(Vector(0,0,-140)) query(Vector(0,0,140),Vector(0,0,-140)) end
    assert(calls()==count,"open-sheet classification repeats native traces")
    V.ApplyBrush(single,Vector(0,0,60),56,false)
    local floor=V.TraceScanRegion(single,Vector(0,0,130),Vector(0,0,-1),260)
    local body=V.TraceVoxelHull(single,Vector(0,0,130),Vector(0,0,-130),Vector(),Vector())
    assert(floor and body.Hit and floor.HitPos.z<60 and floor.HitPos.z> -60
        and floor.HitPos:DistToSqr(body.HitPos)<0.0001,"digging one open face loses soil or disagrees with collision")
    print("PASS: one ordinary open world face retains deep soil without a closed brush/underside; digging and collision agree, columns stay cached")

    local faces={sheet(96,1),sheet(64,1),sheet(32,-1),sheet(-64,1),sheet(-128,-1)}
    local r,layerSign,layerQuery=region(faces,2811)
    for _,case in ipairs({{120,1},{90,-1},{70,-1},{50,-1},{20,1},{-20,1},{-80,-1},{-110,-1},{-145,1}}) do
        assert(layerSign(Vector(0,0,case[1]))==case[2],"layered sheets invent a midpoint floor or fill an exposed air interval at z="..case[1])
    end
    local buried=V.ScanDensity(r,Vector(0,0,64),false,layerQuery,layerSign)
    assert(buried< -r.step*0.9,"buried same-facing sheet creates a false zero-density shell")
    local start,finish=Vector(0,0,140),Vector(0,0,-150)
    local original=V.TraceScanRegion(r,start,Vector(0,0,-1),290)
    assert(original and math.abs(original.HitPos.z-96)<r.step,"top sheet did not become the first surface")
    V.ApplyBrush(r,Vector(0,0,64),60,false)
    local lower=V.TraceScanRegion(r,start,Vector(0,0,-1),290)
    local hull=V.TraceVoxelHull(r,start,finish,Vector(),Vector())
    assert(lower and hull.Hit and math.abs(lower.HitPos.z+64)<r.step and lower.HitPos:DistToSqr(hull.HitPos)<0.0001,
        "upper excavation did not open into the world-air gap above the next floor")
    V.ApplyBrush(r,Vector(0,0,-96),56,false)
    assert(not V.TraceScanRegion(r,start,Vector(0,0,-1),290),"second excavation left a cap between the two open tunnels")
    local passage=V.TraceVoxelHull(r,start,finish,Vector(-8,-8,0),Vector(8,8,36))
    assert(not passage.Hit,"connected tunnel is visible but body collision remains")
    local side=V.TraceScanRegion(r,Vector(76,0,140),Vector(0,0,-1),290)
    assert(side and math.abs(side.HitPos.z-96)<r.step,"linking two tunnel segments erased remote ground")
    print("PASS: stacked oriented sheets retain real air gaps, suppress buried duplicate tops and connect two excavations into one visible/body-clear passage")

    local finite=sheet(80,1,40)
    local limited,finiteSign=region({finite},2812)
    assert(finiteSign(Vector(0,0,-100))==-1 and finiteSign(Vector(90,0,-100))==nil,
        "open terrain footprint became an infinite plane")
    assert(not V.TraceVoxelHull(limited,Vector(90,0,130),Vector(90,0,-140),Vector(),Vector()).Hit,
        "open face creates collision outside its footprint")
    print("PASS: open-sheet continuation stays inside the finite footprint and custom zone bounds")
end
