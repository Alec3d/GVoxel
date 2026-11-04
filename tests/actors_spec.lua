function RunActorTests()
    local V=GVoxel
    local fixture=_VoxelBodyFixture
    local r=V.NewScanRegion(912,Vector(),16)
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=p.z end
    V.ApplyBrush(r,Vector(0,0,-60),100,false) r.revision=1
    local npc=fixture.entity("npc_citizen",Vector(0,0,10))
    npc.mt=MOVETYPE_STEP npc.mins=Vector(-8,-8,0) npc.maxs=Vector(8,8,72)
    local vehicle=fixture.entity("prop_vehicle_jeep",Vector(150,0,30),Vector(40,20,15))
    local ragdoll=fixture.entity("prop_ragdoll",Vector(-130,0,30))
    for _=1,2 do local phys=fixture.physical() phys.pos=ragdoll.pos ragdoll.bodies[#ragdoll.bodies+1]=phys end
    fixture.setEntities({npc,vehicle,ragdoll})
    V.PreparePropRegion(r,{})
    for _=1,200 do fixture.advance(0.02) fixture.hooks["GVoxel.PropPhysics"]() if r.propPhysics.readyRevision==r.revision then break end end
    fixture.advance(0.2) fixture.hooks["GVoxel.PropPhysics"]()
    assert(vehicle.worldDisabled and ragdoll.worldDisabled,"HL2 vehicle/ragdoll did not join native voxel collision")
    assert(#V.PropState.tracked[ragdoll].constraints==3,"not every ragdoll body bypasses original BSP")
    fixture.hooks["GVoxel.NPCMovement"]()
    assert(V.VoxelActors[npc] and npc.mt==MOVETYPE_NONE,"ground NPC not controlled inside voxel field")
    -- Native ReadyNPC can run after this first enrollment and restore STEP.
    npc.mt=MOVETYPE_STEP
    fixture.advance(0.03) fixture.hooks["GVoxel.NPCMovement"]()
    assert(npc.mt==MOVETYPE_NONE,"native NPC initialization stole voxel movement ownership")
    for _=1,200 do fixture.advance(1/66) fixture.hooks["GVoxel.NPCMovement"]() end
    assert(npc.pos.z< -100 and npc.pos.z> -180,"NPC did not fall into voxel cavity: "..npc.pos.z)
    assert(math.abs(npc.velocity.z)<1,"NPC failed to land on voxel floor")
    assert(V.ReleasePropRegion(r),"actors could not restore native collision")
    assert(npc.mt==MOVETYPE_STEP and npc.pos.z>=0 and not V.VoxelActors[npc],"NPC movement/safe position leaked after clear")
    assert(not vehicle.worldDisabled and not ragdoll.worldDisabled and not next(ragdoll.activePairs),"vehicle/ragdoll world pairs leaked")
    npc:SetPos(Vector(0,0,10)) fixture.setEntities({npc}) V.PreparePropRegion(r,{})
    fixture.advance(0.3) fixture.hooks["GVoxel.NPCMovement"]()
    assert(V.VoxelActors[npc] and r.propPhysics.jobs,"ground NPC waits for native cooking instead of using prepared Lua movement")
    assert(V.ReleasePropRegion(r))
    fixture.setEntities({})
    print("PASS: HL2 vehicle, multi-body ragdoll pairs and ground NPC gravity, landing and safe restoration")
end
