function RunGrabTests()
    local V=GVoxel
    local fixture=_VoxelBodyFixture
    local r=V.NewScanRegion(913,Vector(),16)
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=p.z end
    V.ApplyBrush(r,Vector(0,0,-60),100,false) r.revision=1
    fixture.setEntities({}) V.PreparePropRegion(r,{})
    local prop=fixture.entity("prop_physics",Vector(0,0,-60))
    fixture.setEntities({prop})
    for _=1,200 do fixture.advance(0.02) fixture.hooks["GVoxel.PropPhysics"]() if r.propPhysics.readyRevision==r.revision then break end end
    local weapon={GetClass=function() return "weapon_physgun" end}
    local ply={shoot=Vector(0,0,32),alive=true}
    function ply:GetShootPos() return self.shoot end
    function ply:GetAimVector() return Vector(0,0,-1) end
    function ply:GetActiveWeapon() return weapon end
    function ply:Alive() return self.alive end
    function ply:InVehicle() return false end
    function ply:SetNW2Entity(_,e) self.network=e end
    function ply:SetNW2Vector(_,p) self.point=p end
    V.GetServerMovementRegion=function() return r end
    local allowed,drops=false,0
    hook.Run=function(event)
        if event=="PhysgunPickup" then return allowed end
        if event=="PhysgunDrop" then drops=drops+1 end
    end
    util.TraceLine=function(data)
        if not data.ignoreworld then return {Hit=true,HitWorld=true,HitPos=data.start.z<0 and data.start or Vector(),Entity=game.GetWorld()} end
        return {Hit=true,HitWorld=false,HitPos=prop.pos+Vector(0,0,5),Entity=prop,PhysicsBone=0}
    end
    assert(not V.BeginVoxelGrab(ply,weapon) and not V.VoxelGrabs[ply],"fallback bypassed physgun permissions")
    allowed=true
    local function command(buttons,wheel)
        return {buttons=buttons,KeyDown=function(self,key) return bit.band(self.buttons,key)~=0 end,
            RemoveKey=function(self,key) self.buttons=bit.band(self.buttons,bit.bnot(key)) end,
            GetMouseWheel=function() return wheel or 0 end,GetMouseX=function() return 0 end,GetMouseY=function() return 0 end}
    end
    local cmd=command(IN_ATTACK)
    fixture.hooks["GVoxel.PhysgunCommands"](ply,cmd)
    assert(V.VoxelGrabs[ply] and ply.network==prop and prop.worldDisabled,"physgun cannot select visible prop below original BSP")
    assert(fixture.hooks["GVoxel.ProtectTerrainColliders"]({},prop)==false,"native physgun can attach a second controller to fallback-held body")
    assert(not cmd:KeyDown(IN_ATTACK),"native physgun also fired during fallback")
    ply.shoot=ply.shoot+Vector(0,0,20)
    local traceHull=V.TraceVoxelHull
    local conservativeSweeps=0
    -- A floor-touching or rotated prop's enclosing AABB can start solid even
    -- while its physical shape can lift. It must not pin the shadow target.
    V.TraceVoxelHull=function()
        conservativeSweeps=conservativeSweeps+1
        return {Hit=true,StartSolid=true,HitPos=prop.pos,HitNormal=Vector()}
    end
    fixture.advance(1/66) fixture.hooks["GVoxel.PhysgunHold"]()
    V.TraceVoxelHull=traceHull
    assert(conservativeSweeps==0 and prop.phys.shadow.pos.z>prop.phys:GetPos().z,
        "floor contact pinned the held body with a second AABB controller")
    assert(prop.phys.shadow and prop.phys.shadow.teleportdistance==0 and prop.phys.shadow.delta>0,"grab does not use physical shadow control")
    local before=V.VoxelGrabs[ply].distance
    fixture.hooks["GVoxel.PhysgunCommands"](ply,command(IN_ATTACK,1))
    assert(V.VoxelGrabs[ply].distance>before,"scroll distance ignored")
    prop:SetPos(Vector(330,0,30))
    fixture.hooks["GVoxel.PropPhysics"]()
    fixture.hooks["GVoxel.PhysgunHold"]()
    assert(not prop.VMPropRegion and V.VoxelGrabs[ply],"leaving voxel collision dropped the physgun hold")
    prop:SetPos(Vector(0,0,-60))
    fixture.hooks["GVoxel.PhysgunHold"]()
    assert(prop.VMPropRegion==r and V.VoxelGrabs[ply],"held prop failed to rejoin voxel contacts after reentry")
    fixture.hooks["GVoxel.PhysgunCommands"](ply,command(bit.bor(IN_ATTACK,IN_ATTACK2)))
    assert(not V.VoxelGrabs[ply] and not prop.phys.motion and drops==1,"right-click did not freeze/release fallback prop")
    fixture.hooks["GVoxel.PhysgunCommands"](ply,command(IN_ATTACK))
    assert(not V.VoxelGrabs[ply],"freeze immediately repicked object while LMB stayed down")
    fixture.hooks["GVoxel.PhysgunCommands"](ply,command(0))
    fixture.advance(0.2) fixture.hooks["GVoxel.PhysgunCommands"](ply,command(IN_ATTACK))
    assert(V.VoxelGrabs[ply],"prop cannot be picked up again")
    ply.alive=false fixture.hooks["GVoxel.PhysgunHold"]()
    assert(not V.VoxelGrabs[ply] and ply.network==NULL and not prop.VMVoxelGrabber,"death leaked held object")
    assert(V.ReleasePropRegion(r))
    ply.alive=true
    local originalBegin=V.BeginVoxelGrab local attempts=0
    V.BeginVoxelGrab=function() attempts=attempts+1 return false end
    fixture.hooks["GVoxel.PhysgunCommands"](ply,command(0))
    for _=1,100 do fixture.advance(0.1) fixture.hooks["GVoxel.PhysgunCommands"](ply,command(IN_ATTACK)) end
    assert(attempts==1,"held missed physgun press repeatedly retraced terrain")
    fixture.hooks["GVoxel.PhysgunCommands"](ply,command(0))
    fixture.hooks["GVoxel.PhysgunCommands"](ply,command(IN_ATTACK))
    assert(attempts==2) V.BeginVoxelGrab=originalBegin
    local through=V.NewScanRegion(914,Vector(),16)
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(through,i) through.values[V.Index(x,y,z,through)]=p.x end
    V.ApplyBrush(through,Vector(-40,0,30),100,false) through.revision=1
    fixture.setEntities({}) V.PreparePropRegion(through,{})
    for _=1,100 do fixture.advance(0.02) fixture.hooks["GVoxel.PropPhysics"]() if not through.propPhysics.jobs then break end end
    V.GetServerMovementRegion=function() return through end
    prop:SetPos(Vector(400,0,30)) ply.shoot=Vector(-32,0,30)
    ply.GetAimVector=function() return Vector(1,0,0) end
    local exteriorWall=false local queries=0
    util.TraceLine=function(data)
        queries=queries+1
        if not data.ignoreworld and data.start.x<0 then
            return {Hit=true,StartSolid=true,HitWorld=true,HitPos=data.start,Entity=game.GetWorld()}
        end
        if not data.ignoreworld and exteriorWall then
            return {Hit=true,HitWorld=true,HitPos=Vector(350,0,30),Entity=game.GetWorld()}
        end
        return {Hit=true,HitWorld=false,HitPos=prop.pos-Vector(5,0,0),Entity=prop,PhysicsBone=0}
    end
    assert(V.BeginVoxelGrab(ply,weapon) and not prop.worldDisabled,"visible prop beyond the cube cannot be picked up with native collision intact")
    assert(queries==3,"physgun duplicated the initial native trace")
    V.ReleaseVoxelGrabs(through)
    exteriorWall=true
    assert(not V.BeginVoxelGrab(ply,weapon),"physgun passed through an exterior BSP wall")
    assert(V.ReleasePropRegion(through))
    print("PASS: physgun fallback below BSP, permissions, physics hold, scrolling, freeze latch and death cleanup")
    print("PASS: one physgun attempt per press, no duplicate native query, and visible outside props remain protected by exterior BSP")
end
