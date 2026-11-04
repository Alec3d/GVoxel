-- Real Move hook with deterministic engine adapters, followed by numerical
-- movement against actual tetrahedral collision data. No game process runs.
local V=GVoxel
local hooks={}
local enabled=true
local region
local engineWall=nil
SERVER=true CLIENT=false FCVAR_ARCHIVE=1 FCVAR_REPLICATED=2
MOVETYPE_WALK=2 MOVETYPE_NOCLIP=8 MOVETYPE_LADDER=9
FL_ONGROUND=1 FL_DUCKING=2 FL_ANIMDUCKING=4 IN_DUCK=4 IN_SPEED=8 IN_WALK=16 IN_JUMP=32
ACT_MP_STAND_IDLE=100 ACT_MP_WALK=101 ACT_MP_RUN=102 ACT_MP_JUMP=103 ACT_MP_CROUCHWALK=104 ACT_MP_CROUCH_IDLE=105
GESTURE_SLOT_CUSTOM=6 GESTURE_SLOT_JUMP=5 ACT_LAND=106
MASK_PLAYERSOLID=1 MASK_PLAYERSOLID_BRUSHONLY=2 COLLISION_GROUP_PLAYER_MOVEMENT=8
NULL={valid=false}
local world={IsWorld=function() return true end}
function CreateConVar() return {GetBool=function() return enabled end} end
function GetConVar(name)
    local values={sv_gravity=600,sv_friction=4,sv_stopspeed=100,sv_accelerate=10,sv_airaccelerate=10}
    return {GetFloat=function() return values[name] or 600 end}
end
engine={TickInterval=function() return 1/66 end}
game={GetWorld=function() return world end}
hook={Add=function(_,name,fn) hooks[name]=fn end}
local function copy(p) return Vector(p.x,p.y,p.z) end
local function hitPlane(data)
    local bottom=data.start.z+data.mins.z
    local change=data.endpos.z-data.start.z
    local tr={Hit=false,Fraction=1,HitPos=data.endpos,HitNormal=Vector(0,0,1),StartSolid=false}
    if bottom< -0.000001 then tr.Hit=true tr.StartSolid=true tr.Fraction=0 tr.HitPos=data.start
    elseif change<0 and bottom+change<=0 then
        tr.Hit=true tr.Fraction=bottom/(-change) tr.HitPos=data.start+(data.endpos-data.start)*tr.Fraction
    end
    return tr
end
util={TraceHull=function(data)
    if not data.ignoreworld then return hitPlane(data) end
    if engineWall then
        local p=data.start.x+data.maxs.x
        local delta=data.endpos.x-data.start.x
        if p>engineWall then return {Hit=true,StartSolid=true,Fraction=0,HitPos=data.start,HitNormal=Vector(-1,0,0)} end
        if delta>0 and p+delta>=engineWall then
            local f=(engineWall-p)/delta
            return {Hit=true,Fraction=f,HitPos=data.start+(data.endpos-data.start)*f,HitNormal=Vector(-1,0,0)}
        end
    end
    return {Hit=false,Fraction=1,HitPos=data.endpos,HitNormal=Vector(),StartSolid=false}
end}
local ply={pos=Vector(0,0,1),velocity=Vector(),flags=0,mt=MOVETYPE_WALK,network=false,alive=true,vehicle=false}
function ply:GetHull() return Vector(-16,-16,0),Vector(16,16,72) end
function ply:GetHullDuck() return Vector(-16,-16,0),Vector(16,16,36) end
function ply:GetPos() return self.pos end
function ply:SetPos(p) self.setPosCalls=(self.setPosCalls or 0)+1 self.pos=copy(p) end
function ply:SetLocalVelocity(v) self.velocity=copy(v) end
function ply:GetMoveType() return self.mt end
function ply:SetMoveType(mt) self.mt=mt end
function ply:GetNW2Bool() return self.network end
function ply:SetNW2Bool(_,v) self.network=v end
function ply:IsFlagSet(flag) return bit.band(self.flags,flag)~=0 end
function ply:AddFlags(flag) self.flags=bit.bor(self.flags,flag) end
function ply:RemoveFlags(flag) self.flags=bit.band(self.flags,bit.bnot(flag)) end
function ply:GetViewOffset() return Vector(0,0,64) end
function ply:GetViewOffsetDucked() return Vector(0,0,28) end
function ply:SetCurrentViewOffset(v) self.view=v end
function ply:SetGroundEntity(ent) self.ground=ent end
function ply:Alive() return self.alive end
function ply:InVehicle() return self.vehicle end
function ply:GetRunSpeed() return 400 end
function ply:GetWalkSpeed() return 200 end
function ply:GetSlowWalkSpeed() return 100 end
function ply:GetCrouchedWalkSpeed() return 0.3 end
function ply:GetStepSize() return 18 end
function ply:GetJumpPower() return 200 end
function ply:GetGravity() return 1 end
function ply:GetTable() return self end
function ply:AnimResetGestureSlot(slot) self.resetSlot=slot end
function ply:AnimRestartGesture(slot,activity) self.gesture=activity end
function ply:SetIK(value) self.ik=value end
V.GetServerMovementRegion=function() return region end
local angles={Forward=function() return Vector(1,0,0) end,Right=function() return Vector(0,1,0) end}
local mv={pos=ply.pos,velocity=Vector(),buttons=0,pressed=0,forward=0,side=0}
function mv:GetOrigin() return self.pos end
function mv:SetOrigin(p) self.pos=copy(p) end
function mv:GetVelocity() return self.velocity end
function mv:SetVelocity(v) self.velocity=copy(v) end
function mv:GetMoveAngles() return angles end
function mv:GetForwardSpeed() return self.forward end
function mv:GetSideSpeed() return self.side end
function mv:GetMaxSpeed() return 1000 end
function mv:KeyDown(flag) return bit.band(self.buttons,flag)~=0 end
function mv:KeyPressed(flag) return bit.band(self.pressed,flag)~=0 end

function RunMovementTests()
    local r=V.NewScanRegion(92,Vector(),16)
    local mins,maxs=ply:GetHull()
    local function fill(fn)
        for i=0,33^3-1 do
            local p,x,y,z=V.ScanPoint(r,i)
            r.values[V.Index(x,y,z,r)]=fn(p)
        end
        r.revision=r.revision+1
    end
    fill(function(p) return p.z end)
    local trace=function(a,b) return V.TraceVoxelHull(r,a,b,mins,maxs) end
    local p,v=Vector(0,0,80),Vector()
    local grounded=false
    local function tick(wish,jump)
        p,v,grounded=V.SimulateVoxelPlayer({pos=p,vel=v,wish=wish,dt=1/66,gravity=600,jump=jump,step=18},trace)
    end
    for _=1,90 do tick(Vector()) end
    assert(grounded and p.z>=0 and p.z<0.04,"player did not land on the scanned floor")
    for _=1,30 do tick(Vector(200,0,0)) end
    assert(v.x>190,"walking never reaches the configured ground speed")
    local brakingStart=p.x
    for _=1,35 do tick(Vector()) end
    assert(v.x==0 and p.x-brakingStart<45,"ground friction leaves the player sliding after release")
    local stopped=p.x
    for _=1,40 do tick(Vector()) end
    assert(p.x==stopped,"stationary grounded player still drifts")
    p=Vector(0,0,0.03125) v=Vector()
    local top=p.z
    tick(Vector(),true)
    assert(v.z>150 and not grounded,"grounded jump failed")
    for _=1,100 do tick(Vector()) top=math.max(top,p.z) end
    assert(top>30 and grounded and p.z<0.04,"jump/gravity/landing failed")
    V.ApplyBrush(r,Vector(0,0,-32),90,false) r.revision=r.revision+1
    for _=1,150 do tick(Vector()) end
    assert(grounded and p.z< -65 and p.z> -130,"player cannot descend to the excavated floor")
    print("PASS: real smooth hull movement falls into a carved mine, lands, jumps and respects gravity")
    print("PASS: Source-style ground acceleration, finite braking and no residual drift after releasing movement")

    fill(function(point) return point.z-0.25*point.x end)
    p=Vector(-100,0,-20.9) v=Vector()
    for _=1,75 do tick(Vector(100,0,0)) end
    assert(p.x> -10 and p.z>0,"walking up a smooth slope failed")
    assert(grounded and math.abs(p.z-(0.25*(p.x+16)))<0.1,"ramp support differs from visible surface")
    fill(function(point) return math.min(point.z,point.x<0 and 100 or point.z-12) end)
    p=Vector(-80,0,0.03125) v=Vector()
    for _=1,65 do tick(Vector(100,0,0)) end
    assert(p.x>0 and p.z>11 and grounded,"low terrain step cannot be climbed")
    print("PASS: smooth slope support and automatic terrain step climbing")

    fill(function() return 1 end)
    local boundary=r.origin.x+r.side
    local start=Vector(boundary-50,0,-100)
    local endpos=start+Vector(100,0,0)
    local tr=V.TracePlayerTerrain(ply,r,start,endpos,mins,maxs)
    assert(tr.Hit and not tr.StartSolid and math.abs(tr.HitPos.x-(boundary-16))<0.005,"BSP collision leaked or vanished across scan boundary")
    tr=V.TracePlayerTerrain(ply,r,Vector(0,0,5),Vector(0,0,-100),mins,maxs)
    assert(not tr.Hit,"hidden interior BSP still blocks descending")
    engineWall=50
    tr=V.TracePlayerTerrain(ply,r,Vector(0,0,5),Vector(100,0,5),mins,maxs)
    assert(tr.Hit and math.abs(tr.HitPos.x-34)<1e-5,"ordinary prop/door hull ignored inside scan")
    engineWall=nil
    print("PASS: hidden BSP ignored only inside cube; exterior BSP and dynamic blockers preserved")

    fill(function(point) return point.z end)
    local move=hooks["GVoxel.SmoothMovement"]
    region=nil
    assert(move(ply,mv)==nil and ply.mt==MOVETYPE_WALK,"activated without a ready scan")
    region=V.NewScanRegion(93,Vector(),16)
    local oldHull=V.TraceVoxelHull
    V.TraceVoxelHull=function() error("virgin scan runs voxel collision while standing still") end
    for _=1,100 do assert(move(ply,mv)==nil and ply.mt==MOVETYPE_WALK and not ply.network) end
    region.revision=1 region.modifiedChunks={[V.ChunkKey(0,0,0)]=true}
    assert(move(ply,mv)==nil,"distant modified chunk captured native movement")
    V.TraceVoxelHull=oldHull
    region=r
    assert(move(ply,mv)==true and ply.mt==MOVETYPE_NOCLIP and ply.network,"custom controller not activated")
    for _=1,10 do move(ply,mv) ply.pos=copy(mv.pos) end
    assert(ply:IsFlagSet(FL_ONGROUND) and ply.ground==world,"ground contact not published to native player flags")
    local activity=hooks["GVoxel.WalkingActivity"]
    assert(activity(ply,Vector())==ACT_MP_STAND_IDLE and ply.resetSlot==GESTURE_SLOT_CUSTOM,"grounded idle still selects noclip flight")
    assert(activity(ply,Vector(90,0,0))==ACT_MP_WALK and activity(ply,Vector(200,0,0))==ACT_MP_RUN)
    mv.pressed=IN_JUMP move(ply,mv) mv.pressed=0
    assert(not ply:IsFlagSet(FL_ONGROUND) and ply.ground==NULL and activity(ply,mv.velocity)==ACT_MP_JUMP,
        "jump retained grounded flags or flying activity")
    mv.pos=Vector(0,0,0.03125) mv.velocity=Vector() ply.pos=copy(mv.pos)
    ply.pos=copy(mv.pos)
    mv.buttons=IN_DUCK
    assert(move(ply,mv)==true and ply:IsFlagSet(FL_DUCKING) and ply.view.z==28,"crouching/view offset failed")
    assert(ply:IsFlagSet(FL_ANIMDUCKING) and activity(ply,Vector(20,0,0))==ACT_MP_CROUCHWALK,
        "crouch did not select native crouch-walk activity")
    mv.buttons=0 move(ply,mv)
    assert(not ply:IsFlagSet(FL_DUCKING) and ply.view.z==64,"standing up failed")
    fill(function(point) return math.min(point.z,55-point.z) end)
    mv.pos=Vector(0,0,0.03125) mv.velocity=Vector() ply.pos=copy(mv.pos)
    mv.buttons=IN_DUCK move(ply,mv)
    mv.buttons=0 move(ply,mv)
    assert(ply:IsFlagSet(FL_DUCKING),"player stood up through a low tunnel ceiling")
    local roof=V.TracePlayerTerrain(ply,r,mv.pos,mv.pos+Vector(0,0,60),ply:GetHullDuck())
    assert(roof.Hit and roof.HitNormal.z< -0.99,"crouched head passed through tunnel ceiling")
    fill(function(point) return point.z end)
    move(ply,mv)
    assert(not ply:IsFlagSet(FL_DUCKING),"player could not stand after leaving low ceiling")
    V.ApplyBrush(r,Vector(0,0,-32),90,false) r.revision=r.revision+1
    for _=1,140 do move(ply,mv) ply.pos=copy(mv.pos) end
    assert(ply.pos.z< -65,"actual Move hook cannot descend beneath native BSP")
    local touched=V.HullTouchesModified
    V.HullTouchesModified=function() return false end
    local beforePosition=copy(mv.pos)
    local beforeTeleports=ply.setPosCalls or 0
    assert(move(ply,mv)==true and ply.network,"unsafe native handoff disabled voxel walking")
    assert((ply.setPosCalls or 0)==beforeTeleports and mv.pos:DistToSqr(beforePosition)<1,
        "mixed-floor/unchanged-chunk handoff rolled back to the last native-safe position")
    V.HullTouchesModified=touched
    local released,relocated=V.ReleaseVoxelMovement(ply)
    assert(released and relocated and ply.pos.z>=0,"deleting underground scan did not evacuate player")
    assert(ply.mt==MOVETYPE_WALK and not ply.network and not ply.VMVoxelActive,"controller not released")
    mv.pos=copy(ply.pos) mv.velocity=Vector()
    move(ply,mv)
    assert(hooks["GVoxel.ManualFlight"](ply)==false and not ply.network and ply.mt==MOVETYPE_NOCLIP)
    assert(move(ply,mv)==nil,"manual flight was captured by the custom controller")
    assert(activity(ply,Vector(100,0,0))==nil,"genuine free-flight animation overridden by voxel walking")
    ply.mt=MOVETYPE_WALK move(ply,mv)
    ply.alive=false hooks["GVoxel.DeathMovement"](ply)
    assert(not ply.network and ply.mt==MOVETYPE_WALK,"death left noclip movement enabled")
    ply.alive=true hooks["GVoxel.ResetMovement"](ply)
    assert(not ply.VMVoxelSafe,"respawn retained stale recovery location")
    mv.pos=Vector(0,0,2) ply.pos=copy(mv.pos) move(ply,mv)
    mv.pos=Vector(r.origin.x+r.side+100,0,2) ply.pos=copy(mv.pos)
    assert(move(ply,mv)==nil and ply.mt==MOVETYPE_WALK and not ply.network,"exiting scan did not restore native walking")
    mv.pos=Vector(0,0,2) ply.pos=copy(mv.pos) move(ply,mv)
    ply.vehicle=true
    local vehicleType=ply.mt
    assert(move(ply,mv)==nil and not ply.network and ply.mt==vehicleType,"vehicle engine movement was overwritten")
    ply.vehicle=false ply.mt=MOVETYPE_WALK
    move(ply,mv) enabled=false
    move(ply,mv)
    assert(ply.mt==MOVETYPE_WALK and not ply.network,"server disable did not restore native movement")
    print("PASS: actual Move activation, low-ceiling crouch, mine descent, safe removal, noclip, death, respawn, exits, vehicles and disable")
    print("PASS: 100 idle movement commands on a virgin scan and a distant edit use zero voxel hull queries")

    enabled=true region=r
    local previousLocal,previousRegion=LocalPlayer,V.GetClientScanRegion
    LocalPlayer=function() return ply end
    V.GetClientScanRegion=function() return region end
    local expected={}
    for _,server in ipairs({true,false}) do
        SERVER=server CLIENT=not server
        ply.pos=Vector(0,0,2) ply.mt=MOVETYPE_WALK ply.network=false
        ply.flags=0 ply.VMVoxelActive=nil ply.VMVoxelSafe=nil
        mv.pos=copy(ply.pos) mv.velocity=Vector() mv.side=0
        for i=1,90 do
            mv.forward=i>40 and 100 or 0
            mv.buttons=i<20 and IN_DUCK or 0
            mv.pressed=i==60 and IN_JUMP or 0
            assert(move(ply,mv)==true)
            ply.pos=copy(mv.pos)
            if server then expected[i]={p=copy(mv.pos),v=copy(mv.velocity),flags=ply.flags}
            else
                assert(mv.pos:DistToSqr(expected[i].p)<1e-12 and mv.velocity:DistToSqr(expected[i].v)<1e-12
                    and ply.flags==expected[i].flags,"server/client movement prediction diverged")
            end
        end
    end
    SERVER=true CLIENT=false LocalPlayer=previousLocal V.GetClientScanRegion=previousRegion
    print("PASS: identical authoritative-server and predicted-local-client command replay")
    print("PASS: walking/crouching/jumping activities and ground flags; unsafe native handoff has no SetPos or rollback")

    region=r enabled=true
    ply.alive=true ply.vehicle=false ply.mt=MOVETYPE_WALK ply.flags=0 ply.network=false
    ply.VMVoxelActive=nil ply.VMVoxelRecovery=nil
    mv.pos=Vector(0,0,2) mv.velocity=Vector() mv.buttons=0
    local actualTrace=V.TracePlayerTerrain
    local probes=0
    V.TracePlayerTerrain=function(_,_,a)
        probes=probes+1
        return {Hit=true,StartSolid=true,Fraction=0,HitPos=a}
    end
    for _=1,16 do
        local before=probes
        assert(move(ply,mv)==true)
        assert(probes-before<=5,"blocked movement still performs an unbounded recovery search")
    end
    assert(ply.VMVoxelRecovery.retry and probes==80,"bounded recovery did not finish its 64 candidates")
    local before=probes move(ply,mv)
    assert(probes-before==1,"failed recovery repeats the same 64 probes every command")
    r.revision=r.revision+1
    before=probes move(ply,mv)
    assert(probes-before==5,"terrain edit did not invalidate failed recovery")
    V.TracePlayerTerrain=function(_,_,a)
        probes=probes+1
        return {Hit=true,StartSolid=a.z<11,Fraction=0,HitPos=a,HitNormal=Vector(0,0,1)}
    end
    ply.VMVoxelRecovery=nil
    mv.pos=Vector(0,0,2) mv.velocity=Vector() mv.forward=0 mv.pressed=0
    for _=1,3 do move(ply,mv) end
    assert(mv.pos.z>=11 and not ply.VMVoxelRecovery,"bounded search never recovers a clear stance")
    V.TracePlayerTerrain=actualTrace
    print("PASS: blocked stance uses at most four recovery probes/command, backs off after failure and resets on terrain changes")
end
