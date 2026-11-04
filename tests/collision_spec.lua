function RunCollisionTests()
    local V=GVoxel
    local r=V.NewScanRegion(91,Vector(),16)
    local mins,maxs=Vector(-16,-16,0),Vector(16,16,72)
    local function fill(fn)
        for i=0,33^3-1 do
            local p,x,y,z=V.ScanPoint(r,i)
            r.values[V.Index(x,y,z,r)]=fn(p)
        end
        r.revision=r.revision+1
    end
    fill(function() return 1 end)
    assert(not V.TraceVoxelHull(r,Vector(0,0,100),Vector(0,0,-100),mins,maxs).Hit)
    fill(function() return -1 end)
    assert(V.TraceVoxelHull(r,Vector(),Vector(100,0,0),mins,maxs).StartSolid,"full-solid cell escaped hull collision")
    fill(function() return 0 end)
    assert(not V.TraceVoxelHull(r,Vector(),Vector(100,0,0),mins,maxs).Hit,"zero-only field creates solid matter")
    for _,slope in ipairs({0,0.25,-0.4,1}) do
        fill(function(p) return p.z-slope*p.x-3.7 end)
        local expected=3.7+math.abs(slope)*16
        local hit=V.TraceVoxelHull(r,Vector(0,0,150),Vector(0,0,-150),mins,maxs)
        assert(hit.Hit and not hit.StartSolid,"smooth plane missed")
        assert(math.abs(hit.HitPos.z-expected)<0.0001,"hull does not follow the rendered sloped plane")
        assert(hit.HitNormal:Dot(Vector(-slope,0,1):GetNormalized())>0.99999,"wrong smooth surface normal")
        local resting=Vector(0,0,expected+0.03125)
        assert(not V.TraceVoxelHull(r,resting,resting,mins,maxs).StartSolid,"resting hull intersects smooth floor")
        assert(V.TraceVoxelHull(r,resting,resting-Vector(0,0,1),mins,maxs).Hit)
    end
    fill(function(p) return p.z end)
    local before=V.TraceVoxelHull(r,Vector(0,0,100),Vector(0,0,-250),mins,maxs)
    V.ApplyBrush(r,Vector(0,0,-32),90,false) r.revision=r.revision+1
    local hole=V.TraceVoxelHull(r,Vector(0,0,100),Vector(0,0,-250),mins,maxs)
    assert(hole.Hit and hole.HitPos.z< -65 and hole.HitPos.z> -130,"carved hole did not become traversable")
    assert(before.HitPos.z==0 and hole.HitNormal.z>0.65)
    V.ApplyBrush(r,Vector(0,0,-32),90,true) r.revision=r.revision+1
    local filled=V.TraceVoxelHull(r,Vector(0,0,100),Vector(0,0,-250),mins,maxs)
    assert(filled.HitPos.z>hole.HitPos.z+60,"addition did not update cached collision")
    -- A narrow tunnel has an empty center ray but cannot contain the player.
    fill(function(p) return 14-math.abs(p.x) end)
    local blocked=V.TraceVoxelHull(r,Vector(0,-100,0),Vector(0,100,0),mins,maxs)
    assert(blocked.StartSolid,"hull width was replaced with a center-point test")
    fill(function(p) return p.x end)
    local fast=V.TraceVoxelHull(r,Vector(200,0,0),Vector(-200,0,0),mins,maxs)
    assert(fast.Hit and math.abs(fast.HitPos.x-16)<1e-5,"fast movement tunneled through wall")
    print("PASS: continuous exact tetrahedron hulls, smooth slopes, holes, additions, narrow tunnels and fast walls")

    local function volume(a,b) return (b.x-a.x)*(b.y-a.y)*(b.z-a.z) end
    for _,center in ipairs({r.base,r.origin,r.origin-Vector(1000,0,0),r.origin+Vector(10,10,10)}) do
        local low,high=center-Vector(40,40,40),center+Vector(40,40,40)
        local sum=0
        V.OutsideScanBoxes(r,low,high,function(a,b)
            assert(b.x>=a.x and b.y>=a.y and b.z>=a.z,"invalid exterior box")
            local interior=(a+b)/2
            assert(not V.InScanCube(r,interior),"BSP query includes the replaced interior")
            sum=sum+volume(a,b)
            return false
        end)
        local overlap=1
        for _,axis in ipairs({"x","y","z"}) do
            overlap=overlap*math.max(0,math.min(high[axis],r.origin[axis]+r.side)-math.max(low[axis],r.origin[axis]))
        end
        assert(math.abs(sum-(volume(low,high)-overlap))<1e-6,"exterior BSP partition has gaps or duplicates")
    end
    print("PASS: exact exterior BSP volume partition for inside, outside and straddling hulls")
end
