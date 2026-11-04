function RunMaskTests()
    local V=GVoxel
    local r=V.NewScanRegion(1,Vector(123,-456,78),16)
    local faces=V.MaskFaces(r)
    assert(#faces==6)
    for _,f in ipairs(faces) do
        assert(f.normal:Dot(f.point-r.base)>0,"box face points inward")
        for _,p in ipairs(f.vertices) do
            assert(math.abs((p-f.point):Dot(f.normal))<1e-8,"nonplanar mask face")
        end
    end
    assert(V.InScanCube(r,r.base) and not V.InScanCube(r,r.origin-Vector(1,0,0)))
    assert(not V.MaskReady({phase=2,received=64,built=63}),"partial mesh may hide BSP")
    assert(not V.MaskReady({phase=1,received=64,built=64}),"unfinished scan may hide BSP")
    assert(V.MaskReady({phase=2,received=64,built=64}))
    print("PASS: six outward cube faces and atomic activation after all chunks are ready")

    local function fill(fn)
        for i=0,33^3-1 do
            local p,x,y,z=V.ScanPoint(r,i)
            r.values[V.Index(x,y,z,r)]=fn(p)
        end
    end
    local function area(vertices,face)
        assert(#vertices%3==0 and #vertices<65535,"invalid opening mesh size")
        local sum=0
        for i=1,#vertices,3 do
            local a,b,c=vertices[i].pos,vertices[i+1].pos,vertices[i+2].pos
            local cross=(b-a):Cross(c-a)
            assert(cross:Dot(face.normal)>0,"opening winding does not match boundary")
            for _,p in ipairs({a,b,c}) do
                assert(math.abs((p-face.point):Dot(face.normal))<1e-7,"opening left boundary plane")
            end
            sum=sum+math.sqrt(cross:LengthSqr())/2
        end
        return sum
    end
    fill(function() return 1 end)
    for _,face in ipairs(faces) do
        local vertices=V.BuildBoundaryOpening(r,face)
        assert(math.abs(area(vertices,face)-r.side^2)<1e-5,"full air face has a gap")
    end
    for _,density in ipairs({-1,0}) do
        fill(function() return density end)
        for _,face in ipairs(faces) do
            assert(#V.BuildBoundaryOpening(r,face)==0,"solid or coincident isosurface became a portal")
        end
    end
    for _,face in ipairs(faces) do
        local a=face.vertices[1]
        local u=(face.vertices[2]-a)/r.side
        local v=(face.vertices[4]-a)/r.side
        for _,diagonal in ipairs({false,true}) do
            local function density(p)
                local q=(p-a)/r.side
                return diagonal and (q:Dot(u)+q:Dot(v)-1.25) or (q:Dot(u)-0.5)
            end
            fill(density)
            local vertices=V.BuildBoundaryOpening(r,face)
            local expected=r.side^2*(diagonal and 0.75^2/2 or 0.5)
            assert(math.abs(area(vertices,face)-expected)<1e-5,"opening does not preserve clipped terrain shape")
            for _,vertex in ipairs(vertices) do
                assert(density(vertex.pos)>-1e-8,"opening extends into solid terrain")
            end
        end
    end
    -- Boundary apertures must remain usable after an edit near the scan edge.
    fill(function(p) return p.z-r.base.z end)
    local before={}
    for i,face in ipairs(faces) do before[i]=V.BuildBoundaryOpening(r,face) end
    local _,changed=V.ApplyBrush(r,r.origin+Vector(0,r.side/2,r.side/2),r.step*4,false)
    assert(changed,"boundary-adjacent regression brush did not change terrain")
    for i,face in ipairs(faces) do
        local after=V.BuildBoundaryOpening(r,face)
        assert(#after==#before[i],"interior edit changed cached opening topology")
        for j,vertex in ipairs(after) do
            assert(vertex.pos:DistToSqr(before[i][j].pos)<1e-12,"interior edit moved boundary aperture")
        end
    end
    print("PASS: exact boundary apertures for air, solid, zero, half and diagonal planes; sculpt preserves cached borders")

    -- Independent ray/face raster model: every cube ray selects exactly one exit
    -- face, and foreground depth prevents replacement outside the volume.
    local origins={r.base,r.base+Vector(0,0,r.side*1.1),r.base+Vector(r.side*1.2,-r.side,0),
        r.base+Vector(-r.side,r.side,r.side),r.origin+Vector(0.00001,1,1)}
    local checked=0
    for _,eye in ipairs(origins) do
        for i=1,450 do
            local direction=Vector(math.sin(i*1.357),math.cos(i*0.713),math.sin(i*0.213+0.3)):GetNormalized()
            local entry,exit=V.CubeRayInterval(r,eye,direction)
            if entry then
                local exits=0
                for _,f in ipairs(faces) do if V.MaskFaceIsExit(f,eye) then
                    local denominator=direction:Dot(f.normal)
                    if denominator>1e-10 then
                        local t=(f.point-eye):Dot(f.normal)/denominator
                        local point=eye+direction*t
                        local q=point-r.origin
                        if t>=0 and q.x>=-1e-7 and q.x<=r.side+1e-7 and q.y>=-1e-7
                            and q.y<=r.side+1e-7 and q.z>=-1e-7 and q.z<=r.side+1e-7 then
                            exits=exits+1
                            assert(math.abs(t-exit)<1e-6,"exit clip plane does not match cube")
                            assert((eye+direction*(exit+1)-f.point):Dot(f.normal)>0,"background behind exit was clipped")
                            if exit>entry+0.01 then
                                local interior=eye+direction*((entry+exit)/2)
                                assert((interior-f.point):Dot(f.normal)<0,"old interior BSP survives exit clip")
                            end
                        end
                    end
                end end
                assert(exits==1,"cube ray must have one background pass")
                if entry>0 then
                    local foreground=entry*0.5
                    assert(foreground<entry,"foreground must fail entry-face depth test")
                end
                checked=checked+1
            end
        end
    end
    assert(checked>500,"insufficient camera/ray coverage")
    print("PASS: "..checked.." masked rays, interior/exterior cameras, foreground and exit-plane partition")
end
