function RunCraterTests()
    local V=GVoxel
    local center,radius,seed=Vector(),112,31415
    local smallest,largest=math.huge,0
    local changed=false
    local directions={}
    for i=0,31 do
        local direction=Vector(math.cos(i*0.71),math.sin(i*0.71),math.sin(i*1.13)):GetNormalized()
        directions[#directions+1]=direction
        -- With direction-only noise the zero along a ray is analytical.
        local reach=radius-V.BrushSample(direction*radius,center,radius,seed)
        smallest=math.min(smallest,reach) largest=math.max(largest,reach)
        assert(reach>=radius*0.6-1e-8 and reach<=radius+1e-8,"crater escaped its guaranteed bounds")
        assert(math.abs(V.BrushSample(direction*reach,center,radius,seed))<1e-8)
        assert(V.BrushSample(direction*reach*0.5,center,radius,seed)<0,"crater core disconnected from its border")
        changed=changed or math.abs(V.BrushSample(direction*radius,center,radius,seed+1)
            -V.BrushSample(direction*radius,center,radius,seed))>0.1
    end
    assert(largest-smallest>radius*0.08 and changed,"procedural crater is still spherical or seed-independent")
    local density=V.NewScanRegion(995,center,16)
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(density,i) density.values[V.Index(x,y,z,density)]=p.z end
    local replay=V.CloneScanField(density)
    local dirty=V.ApplyBrush(density,center,radius,false,seed) density.revision=1
    V.ApplyBrush(replay,center,radius,false,seed) replay.revision=1
    for i,value in ipairs(density.values) do assert(value==replay.values[i],"seeded density differs between peers") end
    assert(next(dirty))
    for z=0,32 do for y=0,32 do for x=0,32 do
        if x==0 or x==32 or y==0 or y==32 or z==0 or z==32 then
            assert(density.values[V.Index(x,y,z,density)]==density.origin.z+z*density.step,"crater changed the sealed lattice border")
        end
    end end end
    assert(V.TraceVoxelHull(density,Vector(0,0,80),Vector(0,0,-200),Vector(-16,-16,0),Vector(16,16,72)).HitPos.z< -40)

    local data={head=-1,nodes={},planes={},leaves={{solid=true}},faces={}}
    local exact=V.NewScanRegion(996,center,16)
    for i=1,#exact.values do exact.values[i]=-exact.step end
    V.PrepareBSPRegion(exact,data)
    V.ApplyBrush(exact,center,160,false,seed) exact.revision=1
    -- A nominal-radius early-out used to erase cells outside a deformed cut.
    local retainedShell=false
    for z=10,22 do for y=10,22 do for x=10,22 do
        local low=exact.origin+Vector(x,y,z)*exact.step
        local whollyInSphere,whollyOutside=true,true
        for _,o in ipairs(V.CellOffsets) do
            local p=low+Vector(o[1],o[2],o[3])*exact.step
            whollyInSphere=whollyInSphere and p:Length()<160
            whollyOutside=whollyOutside and V.BrushSample(p,center,160,seed)>1
        end
        if whollyInSphere and whollyOutside then
            -- A cell center lies on the shared six-tet diagonal; a zero-size
            -- stationary point there is a contact, not a strict StartSolid.
            local p=low+Vector(0.37,0.41,0.53)*exact.step
            assert(V.TraceVoxelHull(exact,p,p,Vector(),Vector()).StartSolid,"spherical shortcut erased the irregular crater's solid rim")
            retainedShell=true
        end
    end end end
    assert(retainedShell,"regression fixture did not exercise the irregular rim")
    local minHit,maxHit=math.huge,0
    for _,direction in ipairs(directions) do
        local a=V.TraceScanRegion(exact,center,direction,210)
        local b=V.TraceVoxelHull(exact,center,direction*210,Vector(),Vector())
        assert(a and b.Hit and not b.StartSolid and a.HitPos:DistToSqr(b.HitPos)<1e-6,"crater visual mesh and collision disagree")
        minHit=math.min(minHit,a.Distance) maxHit=math.max(maxHit,a.Distance)
    end
    assert(maxHit-minHit>10,"actual BSP crater mesh lost the procedural outline")
    assert(exact.bspEdits[1].seed==seed)
    assert(not select(2,V.ApplyBrush(exact,center,160,false,seed)),"identical seeded stroke is not idempotent")
    local _,newSeed=V.ApplyBrush(exact,center,160,false,seed+1)
    assert(newSeed,"new crater seed incorrectly treated as the preceding brush")
    print(string.format("PASS: seeded multiscale crater has %.1f..%.1f radius, connected core, deterministic replay, sealed borders and matching exact BSP mesh/collision",smallest,largest))
end
