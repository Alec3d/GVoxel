local V=GVoxel
local f=_VoxelBodyFixture
local function scene(id)
    local r=assert(V.NewCustomScanRegion(id,Vector(-200,-100,-40),Vector(200,100,140)))
    local data={head=0,planes={{normal=Vector(0,0,1),distance=0},{normal=Vector(1,0,0),distance=0},
        {normal=Vector(1,0,0),distance=40},{normal=Vector(0,0,1),distance=160}},
        nodes={{plane=1,front=1,back=-2},{plane=2,front=2,back=-1},{plane=3,front=-1,back=3},{plane=4,front=-1,back=-2}},
        leaves={{solid=false},{solid=true}},faces={}}
    data.faces[1]={normal=Vector(0,0,1),tex={flags=0},low=Vector(-1000,-1000,0),high=Vector(1000,1000,0),
        vertices={Vector(-1000,-1000,0),Vector(1000,-1000,0),Vector(1000,1000,0),Vector(-1000,1000,0)}}
    for _,x in ipairs({0,40}) do data.faces[#data.faces+1]={normal=Vector(x==0 and -1 or 1,0,0),tex={flags=0},
        low=Vector(x,-1000,0),high=Vector(x,1000,160),vertices={Vector(x,-1000,0),Vector(x,1000,0),Vector(x,1000,160),Vector(x,-1000,160)}} end
    for z=0,r.cells.z do for y=0,r.cells.y do for x=0,r.cells.x do
        local p=r.origin+Vector(x,y,z)*r.step r.values[V.Index(x,y,z,r)]=V.BSPSolid(data,p) and -r.step or r.step
    end end end
    V.PrepareBSPRegion(r,data)
    V.PrepareVehicleExterior(r,data)
    return r
end
local function native(t)
    if t.ignoreworld then return {Hit=false,Fraction=1,HitPos=t.endpos,HitNormal=Vector()} end
    local lo,hi=t.start+(t.mins or Vector()),t.start+(t.maxs or Vector())
    local solid=lo.z< -0.001 or (hi.x>0.001 and lo.x<39.999 and hi.z>0.001 and lo.z<159.999)
    return {StartSolid=solid,AllSolid=solid,Hit=solid,Fraction=solid and 0 or 1,HitPos=t.start,HitNormal=Vector(0,0,1)}
end
local function pump(predicate,actors)
    for _=1,10000 do
        f.advance(actors and 1/66 or 0.02) f.hooks["GVoxel.PropPhysics"]() f.hooks["GVoxel.Navigation"]()
        if actors then f.hooks["GVoxel.NPCMovement"]() end
        if predicate() then return end
    end
    error("bounded navigation job never finished",2)
end
_VoxelNavigationFixture={scene=scene,native=native}
function RunZonePropTransitionTests()
    local oldTrace=util.TraceHull util.TraceHull=native
    local r=scene(2600)
    f.setEntities({}) V.PreparePropRegion(r,{})
    pump(function() return r.propPhysics.exteriorReady and not r.propPhysics.jobs end)
    local prop=f.entity("prop_physics",Vector(-210,0,30),Vector(20,8,8))
    f.hooks["GVoxel.HeldPropEntry"]({},prop)
    f.advance(0.001) f.hooks["GVoxel.PropPhysics"]()
    assert(not prop.worldDisabled,"merely touching the zone disabled the native BSP")
    prop:SetPos(Vector(-199,0,30)) prop.phys.asleep=true
    f.advance(0.001) f.hooks["GVoxel.PropPhysics"]()
    assert(prop.worldDisabled and prop.VMPropRegion==r,"held prop centre crossing waited for containment/modified chunks")
    local pair=f.hooks["GVoxel.PropTerrainPairs"]
    local exterior
    for key,collider in pairs(r.propPhysics.colliders) do if key:find("exterior:",1,true) and IsValid(collider) then exterior=collider break end end
    assert(exterior and pair(exterior,prop)==nil and pair(r.propPhysics.guard,prop)==false,
        "straddling prop lacks original exterior support or hits the artificial cage wall")
    prop:SetPos(Vector(-210,0,30)) f.advance(0.001) f.hooks["GVoxel.PropPhysics"]()
    assert(prop.worldDisabled,"native BSP caught the tail while the prop still straddled the voxel opening")
    prop:SetPos(Vector(-230,0,30)) f.advance(0.001) f.hooks["GVoxel.PropPhysics"]()
    assert(not prop.worldDisabled and not prop.VMPropRegion,"fully exited held prop did not restore native BSP")
    f.hooks["GVoxel.HeldPropDrop"]({},prop)
    local light=f.entity("gmod_light",Vector(0,110,30),Vector(8,20,8))
    f.hooks["GVoxel.GravityPropEntry"]({},light)
    f.advance(0.001) f.hooks["GVoxel.PropPhysics"]() assert(not light.worldDisabled)
    light:SetPos(Vector(-100,99,30)) f.advance(0.001) f.hooks["GVoxel.PropPhysics"]()
    assert(light.worldDisabled,"gravity gun entry failed on the short custom side")
    f.hooks["GVoxel.GravityPropDrop"]({},light)
    local huge=f.entity("prop_physics",Vector(-199,0,30),Vector(1500,8,8))
    assert(not V.TryEnrollVoxelBody(r,huge) and not huge.worldDisabled,"prop larger than the original exterior support bypassed the BSP")
    assert(V.ReleasePropRegion(r)) f.setEntities({}) util.TraceHull=oldTrace
    print("PASS: custom props/lights held by physgun or gravity gun enter by centre every tick without modified-chunk/24-SU gates, keep exterior support while straddling, and restore native BSP after full exit")
end
function RunNavigationTests()
    local oldTrace=util.TraceHull util.TraceHull=native
    local r=scene(2601)
    local mins,maxs=Vector(-16,-16,0),Vector(16,16,72)
    local trace=function(a,b) return V.TraceNPCNavigation(r,nil,a,b,mins,maxs) end
    local bounds={low=Vector(-150,-75,-35),high=Vector(150,75,138),limit=128}
    local start,finish=Vector(-120,-35,0.25),Vector(140,35,0.25)
    assert(not V.BuildVoxelRoute(start,finish,trace,bounds),"closed BSP wall acquired a fictitious navigation bridge")
    V.ApplyBrush(r,Vector(20,0,55),105,false,0,nil,0) r.revision=1
    local path,reason=V.BuildVoxelRoute(start,finish,trace,bounds)
    assert(path and #path>3,reason or "open wall did not become walkable")
    for _,p in ipairs(path) do assert(not trace(p,p).StartSolid and p.z>0 and p.z<1,"route crosses solid matter or lost its floor") end
    local pauses=0 local sliced
    local thread=coroutine.create(function()
        sliced=V.BuildVoxelRoute(start,finish,trace,bounds,function() pauses=pauses+1 coroutine.yield() end)
    end)
    repeat local ok,err=coroutine.resume(thread) assert(ok,err) until coroutine.status(thread)=="dead"
    assert(sliced and pauses>4,"path search did not support cooperative scheduling")
    local low=scene(2602)
    V.ApplyBrush(low,Vector(20,0,40),40,false,0) low.revision=1
    local cramped=function(a,b) return V.TraceNPCNavigation(low,nil,a,b,mins,maxs) end
    assert(not V.BuildVoxelRoute(start,finish,cramped,bounds),"NPC route ignored headroom/ground clearance")
    local gap=function(a,b)
        if a.z>b.z and not (b.x>0 and b.x<24) then
            return {Hit=true,Fraction=a.z/(a.z-b.z),HitPos=Vector(b.x,b.y,0),HitNormal=Vector(0,0,1)}
        end
        return {Hit=false,Fraction=1,HitPos=b,HitNormal=Vector()}
    end
    assert(not V.NavSurfaceStep(Vector(-12,0,0.25),36,0,gap),"supported endpoints bridged a gap without a floor at the middle")
    print("PASS: bounded hull-sized surface A* rejects intact walls and low passages, crosses an excavated wall with support, and yields throughout search")

    local oldNav=navmesh local all={} local removed=0
    local function area(p)
        local a={p=p,links={},valid=true}
        function a:IsValid() return self.valid end
        function a:GetClosestPointOnArea() return self.p end
        function a:ConnectTo(other) assert(other~=self) self.links[other]=true end
        function a:Remove() self.valid=false removed=removed+1 end
        return a
    end
    local left,right=area(path[1]-Vector(0,0,0.25)),area(path[#path]-Vector(0,0,0.25))
    navmesh={GetNearestNavArea=function(p) return p.x<20 and left or right end,
        CreateNavArea=function(a,b) local result=area((a+b)/2) all[#all+1]=result return result end}
    assert(V.PublishVoxelNavBridge(r,path,trace))
    assert(#all>0 and next(left.links) and next(right.links),"temporary corridor did not connect both native floors")
    local count=#all
    local nearest=navmesh.GetNearestNavArea
    navmesh.GetNearestNavArea=function() return all[1] end
    assert(not V.PublishVoxelNavBridge(r,path,trace) and #all==count,"temporary areas were mistaken for original native anchors")
    navmesh.GetNearestNavArea=nearest
    right.p=right.p+Vector(0,0,100)
    assert(not V.PublishVoxelNavBridge(r,path,trace) and #all==count,"unreachable upper floor became a native anchor")
    right.p=right.p-Vector(0,0,100)
    V.ApplyBrush(r,Vector(20,0,55),105,true,0,nil,0) r.revision=r.revision+1
    local actor=f.entity("npc_zombie",start) actor.mins=mins actor.maxs=maxs
    V.RequestNPCNavigation(actor,r,finish)
    assert(removed==count,"old corridor survived a terrain revision")
    assert(not V.BuildVoxelRoute(start,finish,trace,bounds),"refilled wall kept a fictitious route")
    V.ReleaseNavigation(r)
    assert(removed==count and left.valid and right.valid,"navigation cleanup modified native areas or leaked temporary tiles")
    navmesh=oldNav
    print("PASS: temporary nav corridor checks native anchors, rejects upper/owned areas, invalidates on refill, cleans only owned tiles and preserves the original navmesh")

    -- Controller integration starts from a fresh excavation. The refill case
    -- above deliberately leaves solid matter and must not retain a shortcut.
    r=scene(2603)
    V.ApplyBrush(r,Vector(20,0,55),105,false,0,nil,0) r.revision=1
    f.setEntities({}) V.PreparePropRegion(r,{})
    pump(function() return r.propPhysics.exteriorReady and not r.propPhysics.jobs end)
    local enemy=f.entity("player",Vector(260,0,0.25))
    local zombie=f.entity("npc_zombie",Vector(-240,0,0.25),Vector(16,16,36))
    zombie.mt=MOVETYPE_STEP zombie.mins=mins zombie.maxs=maxs
    function zombie:GetEnemy() return enemy end
    function zombie:GetIdealMoveSpeed() return 90*(self.playback or 1) end
    ACT_IDLE=1 ACT_WALK=6 FL_ONGROUND=1
    zombie.playback=0.8 zombie.animations=0
    function zombie:GetPlaybackRate() return self.playback end
    function zombie:SetPlaybackRate(rate) self.playback=rate end
    function zombie:GetMovementActivity() return ACT_WALK end
    function zombie:GetSequenceGroundSpeed() return 100 end
    function zombie:GetSequence() return 1 end
    function zombie:SetIdealActivity(activity) self.activity=activity end
    function zombie:MaintainActivity() self.animations=self.animations+1 end
    function zombie:AddFlags(flag) self.groundFlag=flag end
    function zombie:RemoveFlags() self.groundFlag=nil end
    local lastMotion,maxPause,reversals,walked=0,0,0,0
    local setPos=zombie.SetPos local firstRequest
    function zombie:SetPos(p)
        if V.VoxelActors[self] and (p-self.pos):LengthSqr()>0.001 then
            if p.x<self.pos.x-0.1 then reversals=reversals+1 end
            if lastMotion>0 then maxPause=math.max(maxPause,CurTime()-lastMotion) end
            lastMotion=CurTime() walked=walked+1
            local request=V.RequestNPCNavigation(self,r,enemy:GetPos())
            if not firstRequest then firstRequest=request else assert(firstRequest==request,"unchanged target restarted a valid route") end
        end
        setPos(self,p)
    end
    f.setEntities({zombie})
    local ok,err=pcall(pump,function() return zombie:GetPos().x>200 and not V.VoxelActors[zombie] end,true)
    if not ok then local s=V.GetNPCNavigationStatus(zombie) local p=zombie:GetPos()
        error(string.format("%s: zombie %.2f %.2f %.2f, controlled=%s, nav=%s reason=%s visited=%s probes=%s points=%s index=%s",err,p.x,p.y,p.z,tostring(V.VoxelActors[zombie]~=nil),s.status,tostring(s.reason),tostring(s.visited),tostring(s.probes),tostring(s.points),tostring(s.index)))
    end
    assert(zombie.mt==MOVETYPE_STEP and zombie:GetPos().z>=0,"zombie did not hand off to native movement outside the box")
    assert(walked>100 and maxPause<0.016 and reversals==0,"NPC motion skipped ticks or backtracked to stale route points")
    assert(zombie.animations>100 and zombie.activity==ACT_WALK and zombie.playback==0.8,"ground animation was not driven/restored with real voxel motion")
    for _=1,200 do f.advance(0.02) f.hooks["GVoxel.Navigation"]() f.hooks["GVoxel.NPCMovement"]() end
    assert(not V.VoxelActors[zombie] and zombie.mt==MOVETYPE_STEP,"finished shortcut recaptured an NPC outside the zone")
    local bot=f.entity("test_ground_nextbot",Vector(-240,0,0.25))
    bot.mt=MOVETYPE_STEP bot.mins=mins bot.maxs=maxs
    function bot:IsNextBot() return true end
    function bot:GetEnemy() return enemy end
    bot.loco={GetGravity=function() return 600 end,GetDesiredSpeed=function() return 100 end}
    f.setEntities({bot})
    pump(function() return bot:GetPos().x>200 and not V.VoxelActors[bot] end,true)
    assert(bot.mt==MOVETYPE_STEP,"compatible ground NextBot did not restore its native move type")
    assert(V.ReleasePropRegion(r)) f.setEntities({}) util.TraceHull=oldTrace
    print("PASS: asynchronous requests/controller guide a zombie and a compatible ground NextBot from outside through the wall shortcut, restore native movement and do not recapture finished actors")
    print("PASS: NPC position and ground animation update at 66 Hz without alternate-tick gaps, route churn/backtracking, and restore original playback outside")
end
