local V=GVoxel
function RunCustomBlockTests()
    local state={points={}}
    local start=Vector(800,800,250)
    local direction=Vector(-1,-1,0):GetNormalized()
    local function click(hit)
        local p=V.CustomSelectionPoint(state.points,hit,start,direction)
        assert(V.CustomSelectionClick(state,p)) return p
    end
    click(Vector(-100,-200,0)) click(Vector(500,900,80)) click(Vector(10,100,75))
    assert(state.points[2].y==-200 and state.points[2].z==0 and state.points[3].x==500 and state.points[3].z==0)
    local corner=Vector(500,100,150)
    direction=(corner-start):GetNormalized()
    click(nil)
    local selected=V.CustomSelectionPreview(state)
    assert(selected.bounds and selected.bounds.extent:DistToSqr(Vector(600,300,150))<1e-8)
    assert(state.points[4]:DistToSqr(corner)<1e-8,"height ray did not project onto the far vertical corner")
    local original=state.points[1]
    assert(V.CustomSelectionClick(state,Vector()))
    local moved=V.CustomSelectionPreview(state,Vector(100,-50,25))
    assert(moved.bounds.origin:DistToSqr(selected.bounds.origin+Vector(100,-50,25))<1e-8)
    assert(state.points[1]==original and moved.bounds.extent:DistToSqr(selected.bounds.extent)<1e-8)
    assert(V.CustomSelectionClick(state,Vector(100,-50,25)) and not state.moving)
    assert(V.CustomSelectionClick(state,Vector())) V.CustomSelectionUndo(state)
    assert(#state.points==4 and not state.moving,"undoing movement removed a committed selection point")
    V.CustomSelectionUndo(state) assert(#state.points==3)
    assert(not V.CustomSelectionClick({points={Vector()}},Vector(1,0,0)))
    assert(not V.CustomBoxBounds(Vector(),Vector(0/0,100,100)))
    assert(not V.CustomBoxBounds(Vector(),Vector(1e9,100,100)))
    assert(not V.CustomBoxBounds(Vector(),Vector(10,100,100)))
    assert(not V.CustomBoxBounds(Vector(),Vector(2000,100,100)))
    print("PASS: four middle-click selection stages project X/Y/height, preview dimensions, translate immutably, lock/undo, and reject degenerate/nonfinite/oversized boxes")

    local low,high=Vector(-200,-150,-90),Vector(440,150,70)
    local r=assert(V.NewCustomScanRegion(2500,high,low))
    assert(r.cells.x==32 and r.cells.y==15 and r.cells.z==8 and r.step==20)
    assert(V.RegionSize(r):DistToSqr(high-low)<1e-8 and r.base:DistToSqr((low+high)/2)<1e-8)
    assert(V.InScanCube(r,high) and not V.InScanCube(r,high+Vector(0,1,0)))
    local a,b=V.CubeRayInterval(r,Vector(20,200,20),Vector(0,-1,0))
    assert(math.abs(a-50)<1e-6 and math.abs(b-350)<1e-6,"box ray interval used the enclosing cube")
    local faces=V.MaskFaces(r)
    for _,face in ipairs(faces) do for _,p in ipairs(face.vertices) do
        assert(p.x>=low.x and p.x<=high.x and p.y>=low.y and p.y<=high.y and p.z>=low.z and p.z<=high.z)
    end end
    local data={head=0,planes={{normal=Vector(0,0,1),distance=0},{normal=Vector(1,0,0),distance=0},
        {normal=Vector(1,0,0),distance=40}},nodes={{plane=1,front=1,back=-2},{plane=2,front=2,back=-1},{plane=3,front=-1,back=-2}},
        leaves={{solid=false},{solid=true}},faces={}}
    for _,x in ipairs({0,40}) do data.faces[#data.faces+1]={normal=Vector(x==0 and -1 or 1,0,0),tex={flags=0},
        low=Vector(x,-1000,0),high=Vector(x,1000,1000),vertices={Vector(x,-1000,0),Vector(x,1000,0),Vector(x,1000,1000),Vector(x,-1000,1000)}} end
    data.faces[#data.faces+1]={normal=Vector(0,0,1),tex={flags=0},low=Vector(-1000,-1000,0),high=Vector(1000,1000,0),
        vertices={Vector(-1000,-1000,0),Vector(1000,-1000,0),Vector(1000,1000,0),Vector(-1000,1000,0)}}
    for z=0,r.cells.z do for y=0,r.cells.y do for x=0,r.cells.x do
        local p=r.origin+Vector(x,y,z)*r.step
        r.values[V.Index(x,y,z,r)]=V.BSPSolid(data,p) and -r.step or r.step
    end end end
    V.PrepareBSPRegion(r,data)
    local count=0
    V.ForChunks(function(x,y,z)
        for _,vertex in ipairs(V.BuildChunk(r,x,y,z)) do
            local p=vertex.pos+r.origin+Vector(x,y,z)*(8*r.step)
            assert(p.x>=low.x-0.01 and p.x<=high.x+0.01 and p.y>=low.y-0.01 and p.y<=high.y+0.01
                and p.z>=low.z-0.01 and p.z<=high.z+0.01,"mesh escaped the rectangular box")
            count=count+1
        end
    end,r)
    assert(count>0)
    assert(not V.TraceVoxelHull(r,Vector(-100,200,30),Vector(100,200,30),Vector(),Vector()).Hit)
    assert(V.TraceVoxelHull(r,Vector(-100,0,30),Vector(100,0,30),Vector(),Vector()).Hit)
    local border={}
    for z=0,r.cells.z do for y=0,r.cells.y do for x=0,r.cells.x do
        if x==0 or y==0 or z==0 or x==r.cells.x or y==r.cells.y or z==r.cells.z then
            local key=V.Index(x,y,z,r) border[key]=r.values[key]
        end
    end end end
    local field=V.CloneScanField(r)
    local dirty=V.ApplyBrush(field,Vector(20,0,25),80,false,913) field.revision=1
    assert(next(dirty),"rectangular region with partial chunks lost dirty coverage")
    for key,value in pairs(border) do assert(field.values[key]==value,"custom cage border was excavated") end
    local trace=V.TraceVoxelHull(field,Vector(-100,0,30),Vector(120,0,30),Vector(-2,-2,-2),Vector(2,2,2))
    assert(not trace.Hit,"RPG crater does not open the custom rectangular wall")
    for _,c in pairs(dirty) do
        local vertices=V.BuildCollisionChunk(field,c[1],c[2],c[3])
        for _,p in ipairs(vertices) do
            p=p+Vector(c[1],c[2],c[3])*(8*r.step)
            assert(p.y>=-0.01 and p.y<=r.extent.y+0.01 and p.z>=-0.01 and p.z<=r.extent.z+0.01,
                "native collider extends into inactive custom cells")
        end
    end
    assert(#V.DensityCellSolids(field,10,20,10)==0,"inactive cells retained invisible collision")
    for _,face in ipairs(faces) do V.BuildBoundaryOpening(field,face) end
    print("PASS: non-cubic 32x15x8 active lattice keeps rectangular masks/rays/mesh/native hull bounds, sealed borders, partial dirty chunks and working seeded RPG excavation")

    local density=assert(V.NewCustomScanRegion(2501,low,high))
    for z=0,density.cells.z do for y=0,density.cells.y do for x=0,density.cells.x do
        local p=density.origin+Vector(x,y,z)*density.step
        density.values[V.Index(x,y,z,density)]=p.z
    end end end
    for _,face in ipairs(V.MaskFaces(density)) do
        for _,vertex in ipairs(V.BuildBoundaryOpening(density,face)) do
            assert(V.InScanCube(density,vertex.pos),"density opening used 32 tiles along a short box edge")
        end
    end
    assert(not V.TraceVoxelHull(density,Vector(20,200,40),Vector(20,200,-70),Vector(),Vector()).Hit)
    assert(V.TraceVoxelHull(density,Vector(100,0,40),Vector(100,0,-70),Vector(),Vector()).Hit)
    print("PASS: sampled Hammer-style ground and boundary apertures respect short custom axes; outside soil has no voxel collision")
    if V.PrepareVehicleExterior then
        V.PrepareVehicleExterior(r,data)
        local exterior=V.TraceVehicleExterior(r,Vector(-100,200,40),Vector(-100,200,-70),Vector(),Vector())
        assert(exterior.Hit and math.abs(exterior.HitPos.z)<0.01,"short-side exterior support was cut at the enclosing cube instead of the box")
        assert(not V.TraceVehicleExterior(r,Vector(-100,0,40),Vector(-100,0,-70),Vector(),Vector()).Hit,
            "exterior support restored the original BSP inside the rectangular box")
        print("PASS: rectangular vehicle exterior retains the original ground outside short sides and excludes it inside the custom box")
    end
    if V.ColumnScanTrace then
        local face={normal=Vector(0,0,1),tex={flags=0},displacement=true,low=Vector(-600,-600,0),high=Vector(600,600,0),
            dispLow=Vector(-600,-600,0),dispHigh=Vector(600,600,30),dispWidth=3,dispGrid={}}
        for y=0,2 do for x=0,2 do face.dispGrid[y*3+x+1]=Vector(-600+x*600,-600+y*600,x==1 and y==1 and 30 or 0) end end
        local terrain=assert(V.NewCustomScanRegion(2502,low,high))
        local map={head=-1,nodes={},planes={},leaves={{solid=false}},faces={face},worldBrushes={}}
        V.PrepareBSPRegion(terrain,map)
        local query,_,sign=V.ColumnScanTrace(terrain,function() return {Hit=false} end,function() return false end)
        for z=0,terrain.cells.z do for y=0,terrain.cells.y do for x=0,terrain.cells.x do
            local p=terrain.origin+Vector(x,y,z)*terrain.step
            terrain.values[V.Index(x,y,z,terrain)]=V.ScanDensity(terrain,p,false,query,sign)
        end end end
        local a=V.TraceScanRegion(terrain,Vector(0,0,65),Vector(0,0,-1),140)
        local b=V.TraceVoxelHull(terrain,Vector(0,0,65),Vector(0,0,-75),Vector(),Vector())
        assert(a and b.Hit and a.HitPos.z>15 and a.HitPos:DistToSqr(b.HitPos)<0.0001,
            "compiled Hammer displacement vanished or disagreed with collision in a custom box")
        V.ApplyBrush(terrain,Vector(0,0,10),48,false) terrain.revision=1
        a=V.TraceScanRegion(terrain,Vector(0,0,65),Vector(0,0,-1),140)
        b=V.TraceVoxelHull(terrain,Vector(0,0,65),Vector(0,0,-75),Vector(),Vector())
        assert(a and b.Hit and a.HitPos.z<15 and a.HitPos:DistToSqr(b.HitPos)<0.0001)
        for _,face in ipairs(V.MaskFaces(terrain)) do V.BuildBoundaryOpening(terrain,face) end
        print("PASS: compiled curved Hammer displacement survives missing native rays in a custom box and retains matching mesh/hull/short-side apertures after digging")
    end
end
