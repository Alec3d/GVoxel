local V=GVoxel local f=_VoxelBodyFixture
MASK_SHOT=1 MOVETYPE_FLY=4 MOVETYPE_FLYGRAVITY=5 MOVETYPE_NOCLIP=8 SOLID_BBOX=2 FSOLID_NOT_SOLID=4
NULL={valid=false} engine={TickInterval=function() return 1/66 end}
timer={Simple=function(_,fn) fn() end}
local current local victims={} local outsideWall
V.GetServerScanRegion=function() return current end
local world=game.GetWorld()
local create=ents.Create
ents.Create=function(class)
    local ent=create(class)
    if class=="vm_projectile_stop" then
        function ent:SetNoDraw(on) self.hidden=on end
        function ent:DrawShadow(on) self.shadow=on end
        function ent:SetModel(model) self.model=model end
        function ent:SetCollisionBounds(a,b) self.mins=a self.maxs=b end
        function ent:SetCustomCollisionCheck(on) self.customCheck=on end
        function ent:SetSolid(solid) self.solid=solid end
        function ent:Spawn() _ProjectileStopDefinition.Initialize(self) end
        function ent:UpdateTransmitState() return _ProjectileStopDefinition.UpdateTransmitState(self) end
    end
    return ent
end
local function boxHit(t,lo,hi)
    lo=lo-(t.maxs or Vector()) hi=hi-(t.mins or Vector())
    local delta=t.endpos-t.start local first,last=0,1 local normal=Vector() local inside=true
    for _,axis in ipairs({"x","y","z"}) do
        if t.start[axis]<=lo[axis] or t.start[axis]>=hi[axis] then inside=false end
        if math.abs(delta[axis])<1e-8 then if t.start[axis]<lo[axis] or t.start[axis]>hi[axis] then return end
        else
            local a,b=(lo[axis]-t.start[axis])/delta[axis],(hi[axis]-t.start[axis])/delta[axis]
            local n=Vector() n[axis]=delta[axis]>0 and -1 or 1
            if a>b then a,b=b,a end
            if a>first then first=a normal=n end
            last=math.min(last,b) if first>last then return end
        end
    end
    return first,normal,inside
end
local function native(t)
    local hit={Hit=false,StartSolid=false,Fraction=1,HitPos=t.endpos,HitNormal=Vector(),Entity=NULL,HitWorld=false,
        StartPos=t.start,Normal=(t.endpos-t.start):GetNormalized(),HitGroup=0}
    local function merge(low,high,ent,worldHit)
        local frac,normal,inside=boxHit(t,low,high)
        if frac and (frac<hit.Fraction or inside) then
            hit.Hit=true hit.StartSolid=inside hit.Fraction=frac hit.HitPos=t.start+(t.endpos-t.start)*frac
            hit.HitNormal=normal hit.HitWorld=worldHit hit.Entity=ent hit.HitGroup=worldHit and 0 or 1
        end
    end
    if not t.ignoreworld then
        merge(Vector(0,-1000,0),Vector(40,1000,160),world,true)
        if outsideWall then merge(Vector(320,-1000,0),Vector(330,1000,160),world,true) end
    end
    for _,ent in ipairs(victims) do if not t.filter or t.filter(ent) then local a,b=ent:WorldSpaceAABB() merge(a,b,ent,false) end end
    return hit
end
util.TraceLine=native util.TraceHull=native
local function damage()
    return {amount=10,SetDamagePosition=function(self,p) self.pos=p end,GetDamageType=function() return 2 end}
end
local function prepare(id)
    local r=_VoxelNavigationFixture.scene(id)
    V.ApplyBrush(r,Vector(20,0,55),105,false,0,nil,0) r.revision=1
    current=r
    return r
end
function RunBallisticsTests()
    local r=prepare(2700)
    local shooter=f.entity("player",Vector(-260,0,40))
    function shooter:FireBullets() error("recursive FireBullets call") end
    local target=f.entity("prop_physics",Vector(260,0,40),Vector(5,5,5))
    local hits=0 local called=0
    function target:DispatchTraceAttack(d,tr,dir)
        assert(d.amount==27 and tr.HitGroup==1 and dir.x>0.99 and d.pos.x>250)
        hits=hits+1
    end
    local hidden=f.entity("vm_projectile_stop",Vector(70,0,40)) hidden.VMProjectileStopFor=shooter
    victims={hidden,target}
    assert(not V.IsVoxelProjectile(hidden),"internal contact helpers became projectile candidates")
    local data={Src=shooter:GetPos(),Dir=Vector(1,0,0),Distance=800,Num=8,Spread=Vector(0.2,0.2,0),Tracer=0,
        Callback=function(_,tr,d) called=called+1 assert(tr.Entity==target) d.amount=27 end}
    assert(V.WrapVoxelBullet(shooter,data))
    local t={start=data.Src,endpos=data.Src+Vector(800,0,0)}
    local original=native(t)
    assert(original.HitWorld and original.HitPos.x==0)
    local ret=data.Callback(shooter,original,damage())
    assert(ret.damage==false and ret.effects==false and hits==1 and called==1,"bullet stopped at BSP or damaged twice")
    assert(data.Num==8 and data.Spread.x>0 and data.Dir.x==1,"wrapper changed engine spread/pellet count")
    local callbacks=0
    local reused={Distance=800,Tracer=0,Callback=function(_,tr)
        callbacks=callbacks+1 assert(tr.Entity==target) return {damage=false,effects=false}
    end}
    V.WrapVoxelBullet(shooter,reused) V.WrapVoxelBullet(shooter,reused)
    reused.Callback(shooter,original,damage())
    assert(callbacks==1 and hits==1,"reused bullet table stacked callback wrappers or ignored an internal helper")
    data.Callback=function(_,tr) called=called+1 assert(tr.HitWorld and tr.HitPos.x<41) end
    assert(V.WrapVoxelBullet(shooter,data))
    local blocked=native({start=Vector(-260,80,130),endpos=Vector(540,80,130)})
    data.Callback(shooter,blocked,damage())
    assert(hits==1 and called==2,"actual pellet direction failed to respect an intact wall")
    data.Callback=function(_,tr) assert(tr.Entity==target) return {damage=false,effects=false} end
    V.WrapVoxelBullet(shooter,data) data.Callback(shooter,original,damage())
    assert(hits==1,"original callback veto was bypassed")
    outsideWall=true target:SetPos(Vector(400,0,40))
    data.Callback=function(_,tr) assert(tr.HitWorld and math.abs(tr.HitPos.x-320)<0.1) return {effects=false} end
    V.WrapVoxelBullet(shooter,data) data.Callback(shooter,original,damage())
    assert(hits==1,"bullet ignored original BSP beyond the scan")
    outsideWall=false victims={}
    V.ApplyBrush(r,Vector(100,0,40),30,true) r.revision=2
    data.Callback=function(_,tr) assert(tr.HitWorld and tr.HitPos.x>60 and tr.HitPos.x<100) return {effects=false} end
    V.WrapVoxelBullet(shooter,data) data.Callback(shooter,original,damage())
    local callback=data.Callback current=nil
    assert(not V.WrapVoxelBullet(shooter,data) and data.Callback==callback,"unscanned shots were modified")
    print("PASS: actual post-spread pellet passes BSP hole, damages its real victim once with original callback/damage/hitgroup; callback veto, intact/added voxels and exterior BSP block correctly without recursive FireBullets")
end
local function projectile(class,pos,velocity,mt)
    local ent=f.entity(class,pos,Vector(1,1,1)) ent.mt=mt ent.velocity=velocity ent.solid=SOLID_BBOX
    function ent:GetSolid() return self.solid end
    function ent:SetSolid(s) self.solid=s end
    function ent:GetOwner() return NULL end
    function ent:RemoveSolidFlags(flag) self.removedSolidFlag=flag end
    return ent
end
function RunProjectileFlightTests()
    local r=prepare(2701) victims={}
    f.setEntities({}) V.PreparePropRegion(r,{})
    for _=1,500 do f.advance(0.02) f.hooks["GVoxel.PropPhysics"]() if r.propPhysics.exteriorReady and not r.propPhysics.jobs then break end end
    assert(r.propPhysics.exteriorReady)
    local rocket=projectile("rpg_missile",Vector(-220,0,40),Vector(1500,0,0),MOVETYPE_FLY)
    f.hooks["GVoxel.ProjectileDiscovery"](rocket) f.hooks["GVoxel.Projectiles"]()
    assert(rocket.mt==MOVETYPE_NOCLIP and rocket.solid==SOLID_NONE,"rocket was not transferred before reaching original BSP")
    rocket:SetPos(Vector(80,0,40)) f.advance(0.02) f.hooks["GVoxel.Projectiles"]()
    assert(rocket.mt==MOVETYPE_NOCLIP and rocket:GetPos().x==80,"rocket hit hidden BSP inside excavated opening")
    rocket:SetPos(Vector(400,0,40)) f.advance(0.02) f.hooks["GVoxel.Projectiles"]()
    assert(rocket.mt==MOVETYPE_FLY and rocket.solid==SOLID_BBOX and rocket.network==0,"rocket failed to restore native flight outside")
    rocket:Remove()
    local blocked=projectile("crossbow_bolt",Vector(-220,80,130),Vector(1500,0,0),MOVETYPE_FLY)
    f.hooks["GVoxel.ProjectileDiscovery"](blocked) f.hooks["GVoxel.Projectiles"]()
    blocked:SetPos(Vector(80,80,130)) f.advance(0.02) f.hooks["GVoxel.Projectiles"]()
    assert(blocked.mt==MOVETYPE_FLY and blocked.solid==SOLID_BBOX and blocked.pos.x<1,"fast native projectile crossed intact voxel wall")
    assert(blocked.removedSolidFlag==FSOLID_NOT_SOLID,"launch grace let the projectile ignore a real voxel/world impact")
    local stop
    for _,ent in ipairs(f.created) do if ent.VMProjectileStopFor==blocked then stop=ent break end end
    assert(stop and f.hooks["GVoxel.ProjectileContact"](stop,blocked)==true
        and f.hooks["GVoxel.ProjectileContact"](stop,rocket)==false,"native impact proxy affects unrelated entities")
    assert(stop.customCheck and stop.hidden and not stop.shadow and stop.solid==SOLID_BBOX
        and stop:UpdateTransmitState()==TRANSMIT_NEVER,"actual contact entity lacks solid/custom filtering or leaks to client rendering")
    blocked:Remove() f.advance(0.2) f.hooks["GVoxel.Projectiles"]()
    assert(not IsValid(stop),"impact proxy leaked after removal")
    local grenade=projectile("grenade_ar2",Vector(-210,0,40),Vector(1200,0,0),MOVETYPE_VPHYSICS)
    f.hooks["GVoxel.ProjectileDiscovery"](grenade) f.hooks["GVoxel.Projectiles"]()
    assert(grenade.worldDisabled and grenade.VMPropRegion==r,"physical projectile failed to bypass BSP before entry")
    f.hooks["GVoxel.PropPhysics"]()
    assert(grenade.worldDisabled,"prop exit loop prematurely restored a projectile approaching the cage")
    grenade:SetPos(Vector(400,0,40)) f.advance(0.02) f.hooks["GVoxel.Projectiles"]()
    assert(not grenade.worldDisabled,"physical projectile left its world pair active after exit")
    grenade:Remove()
    local custom=projectile("third_party_round",Vector(-220,0,40),Vector(1500,0,0),MOVETYPE_FLY) custom.IsProjectile=true
    f.hooks["GVoxel.ProjectileDiscovery"](custom) f.hooks["GVoxel.Projectiles"]()
    assert(custom.mt==MOVETYPE_NOCLIP)
    V.ReleaseVoxelProjectiles(r)
    assert(custom.mt==MOVETYPE_FLY and custom.solid==SOLID_BBOX,"cleanup left a custom projectile non-solid")
    custom:Remove()
    local water=projectile("third_party_missile",Vector(-210,0,40),Vector(1500,0,0),MOVETYPE_FLY)
    f.hooks["GVoxel.ProjectileDiscovery"](water) f.hooks["GVoxel.Projectiles"]()
    water:SetMoveType(MOVETYPE_VPHYSICS) water:SetSolid(SOLID_VPHYSICS)
    f.hooks["GVoxel.Projectiles"]()
    assert(water.mt==MOVETYPE_VPHYSICS and water.solid==SOLID_VPHYSICS and water.worldDisabled,"native underwater physics transition was overridden")
    V.ReleaseVoxelProjectiles(r) water:Remove()
    local stuck=projectile("third_party_bolt",Vector(-210,0,40),Vector(1500,0,0),MOVETYPE_FLY)
    f.hooks["GVoxel.ProjectileDiscovery"](stuck) f.hooks["GVoxel.Projectiles"]()
    stuck:SetMoveType(MOVETYPE_NONE)
    f.hooks["GVoxel.Projectiles"]()
    assert(stuck.mt==MOVETYPE_NONE,"native finished projectile was revived")
    stuck:Remove() assert(V.ReleasePropRegion(r)) current=nil
    print("PASS: swept RPG/custom native flight crosses opening, intact wall hands back native contact through a projectile-only temporary proxy; VPhysics grenade world-pair entry/exit and cleanup restore original state (native Touch execution requires in-game validation)")
end
