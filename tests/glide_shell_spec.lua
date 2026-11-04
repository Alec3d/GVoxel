-- Event adapters only: no native physics, pixels or frame-rate claims.
-- Runner: PrepareGlideShellTests(); load sv_explosions; then
-- RunGlideShellTests(reloadModule, optionalCreateExplosionChunk, optionalExplodeChunk).
local fixture
local function pack(...) return {n=select("#",...),...} end
function PrepareGlideShellTests()
    assert(not fixture,"Glide shell fixture already active")
    local names={"GVoxel","Glide","hook","CreateConVar","FCVAR_ARCHIVE","IsValid","isvector",
        "CurTime","ErrorNoHalt","util","net","ENT","VSWEP","SERVER","Angle"}
    local saved={} for _,name in ipairs(names) do saved[name]={value=_G[name]} end
    fixture={saved=saved,hooks={},queued={},errors={},native=0,now=100}
    local f=fixture
    GVoxel={}
    Glide=nil
    hook={Add=function(_,name,fn) f.hooks[name]=fn end}
    FCVAR_ARCHIVE=1
    CreateConVar=function() return {GetFloat=function() return 112 end} end
    IsValid=function(ent) return type(ent)=="table" and ent.valid~=false end
    isvector=function(value) return type(value)=="table" and type(value.LengthSqr)=="function" end
    CurTime=function() return f.now end
    ErrorNoHalt=function(message) f.errors[#f.errors+1]=message end
    Angle=function() return {} end
    GVoxel.QueueRPGCrater=function() error("tank shell entered the RPG path") end
    GVoxel.QueueExplosionCrater=function(attacker,origin,radius,seed,source)
        f.queued[#f.queued+1]={attacker=attacker,origin=origin,radius=radius,seed=seed,source=source}
        if f.queueError then error(f.queueError) end
        return false
    end
    GVoxel.QueueGlideTankCrater=function(attacker,tank,origin,direction)
        f.queued[#f.queued+1]={attacker=attacker,tank=tank,origin=origin,direction=direction}
        if f.queueError then error(f.queueError) end
        return false -- Refusal still permits the original explosion exactly once.
    end
end
local function player() return {IsPlayer=function() return true end} end
local function tank(kind) return {IsGlideVehicle=true,VehicleType=kind or 5} end
local function shell(owner,class)
    local e={owner=owner,pos=Vector(12,34,56),velocity=Vector(10,2,0)}
    function e:GetClass() return class or "glide_projectile" end
    function e:GetOwner() return self.owner end
    function e:GetPos() return self.pos end
    function e:GetForward() return Vector(0,1,0) end
    function e:Remove() self.valid=false end
    return e
end
local function damage(projectile,attacker,explosive)
    return {IsExplosionDamage=function() return explosive~=false end,
        GetInflictor=function() return projectile end,GetAttacker=function() return attacker end}
end
local function emitFallback(projectile,attacker)
    local f=fixture
    for _=1,5 do assert(f.hooks["GVoxel.GlideTankBlastDamage"]({},damage(projectile,attacker))==nil) end
end
local function installedSources(explosionChunk,explodeChunk,missileChunk,launcherChunk,planeChunks)
    local f,V=fixture,GVoxel
    V.ReleaseGlideTankExplosionAdapter()
    local nativeDamage,effects=0,0
    Glide={VEHICLE_TYPE={TANK=5,PLANE=4},EXPLOSION_TYPE={MISSILE=1},MAX_EXPLOSION_DISTANCE=5000,
        GetNearbyPlayers=function() return {},0 end,
        StartCommand=function() effects=effects+1 end,CMD_CREATE_EXPLOSION=7}
    util={BlastDamage=function(projectile,attacker)
            nativeDamage=nativeDamage+1 emitFallback(projectile,attacker)
        end,ScreenShake=function() effects=effects+1 end}
    net={WriteVector=function() end,WriteUInt=function() end,Send=function() effects=effects+1 end}
    ENT={}
    explosionChunk()
    explodeChunk()
    local explode=assert(ENT.Explode)
    V.InstallGlideTankExplosionAdapter()
    local car,attacker=tank(),player()
    local projectile=shell(car) projectile.attacker=attacker projectile.radius=350 projectile.damage=550
    local before=#f.queued
    explode(projectile)
    assert(#f.queued==before+1 and f.queued[#f.queued].attacker==attacker,
        "real Glide Explode lost its attacker before queuing")
    assert(nativeDamage==1 and effects==3 and projectile.hasExploded and projectile.valid==false and projectile.attacker==nil,
        "real Glide damage/effects/removal were changed")
    explode(projectile)
    assert(nativeDamage==1 and #f.queued==before+1,"real Glide repeated explosion was not idempotent")
    print("PASS: installed Glide CreateExplosion and projectile Explode enqueue once before attacker cleanup and preserve native damage/effects/removal")
    if missileChunk then
        ENT={} missileChunk() local missileExplode=assert(ENT.Explode)
        local lastMissile
        VSWEP={} SERVER=true launcherChunk() local primary=assert(VSWEP.PrimaryAttack)
        for _,chunk in ipairs(planeChunks) do
            ENT={} chunk() local features=assert(ENT.CreateFeatures)
            local aircraft=tank(4) local weapons={}
            aircraft.wheels={}
            function aircraft:CreateSeat() end
            function aircraft:CreateWheel() end
            function aircraft:ChangeWheelRadius() end
            function aircraft:CreateWeapon(name,params) weapons[name]=params end
            features(aircraft)
            assert(weapons.homing_launcher and weapons.missile_launcher,"installed aircraft lost a missile mode")
            function aircraft:LocalToWorld(p) return p end
            function aircraft:GetAngles() return {} end
            function aircraft:GetSeatDriver() return attacker end
            function aircraft:GetLockOnState() return 2 end
            local target={} function aircraft:GetLockOnTarget() return target end
            function aircraft:FireMissile(_,_,who,locked)
                local m=shell(self,"glide_missile") m.attacker=who m.radius=350 m.damage=100 m.Explode=missileExplode
                function m:SetModelScale(scale) self.modelScale=scale end
                function m:SetModel(model) self.model=model end
                m.target=locked lastMissile=m return m
            end
            for _,mode in ipairs({"homing_launcher","missile_launcher"}) do
                local params=weapons[mode]
                local weapon={Vehicle=aircraft,EnableLockOn=mode=="homing_launcher",FireDelay=params.FireDelay,
                    ProjectileOffsets=params.ProjectileOffsets,MissileModelScale=params.MissileModelScale or 1,
                    MissileModel=params.MissileModel or "",projectileOffsetIndex=1}
                function weapon:TakePrimaryAmmo() end
                function weapon:SetNextPrimaryFire() end
                function weapon:IncrementProjectileIndex() end
                function weapon:ShootEffects() end
                -- Strikeforce barrage: each missile gets one crater, even at
                -- identical positions and during many damage callbacks.
                local repeats=mode=="missile_launcher" and 6 or 1
                local prior=#f.queued local priorDamage=nativeDamage
                for _=1,repeats do
                    primary(weapon)
                    assert(lastMissile.target==(mode=="homing_launcher" and target or nil))
                    lastMissile:Explode() lastMissile:Explode()
                    assert(not lastMissile.valid and lastMissile.attacker==nil)
                    local queued=f.queued[#f.queued]
                    assert(queued.source=="glide_missile" and queued.attacker==attacker
                        and queued.radius==112 and queued.seed>0 and queued.origin==lastMissile.pos)
                end
                assert(#f.queued==prior+repeats and nativeDamage==priorDamage+repeats,
                    "aircraft missile was lost or carved more than once per explosion")
            end
        end
        print("PASS: installed Lazer/Strikeforce weapon configurations and missile launcher/Explode use one optimized RPG crater per guided missile or barrage rocket; native damage, lock-on, model and removal remain")
    end
end
function RunGlideShellTests(reloadModule,explosionChunk,explodeChunk,missileChunk,launcherChunk,planeChunks)
    local f=assert(fixture,"call PrepareGlideShellTests first")
    local ok,err=pcall(function()
        local V=GVoxel
        assert(not V.GlideTankExplosionAdapter,"missing Glide was wrapped")
        local attacker,car=player(),tank()
        local arguments
        local function original(...)
            f.native=f.native+1 arguments=pack(...)
            local projectile,owner=...
            if IsValid(projectile) then emitFallback(projectile,owner) end
            return "native",nil,arguments[3],false
        end
        Glide={VEHICLE_TYPE={TANK=5,PLANE=4},CreateExplosion=original}
        f.hooks["GVoxel.GlideTankExplosions"]()
        local wrapper=Glide.CreateExplosion
        assert(wrapper~=original,"late-loaded Glide did not acquire the event adapter")
        for _=1,4 do V.InstallGlideTankExplosionAdapter() end
        assert(Glide.CreateExplosion==wrapper,"repeated installation stacked wrappers")
        local projectile=shell(car)
        local values=pack(Glide.CreateExplosion(projectile,attacker,projectile.pos,350,nil,Vector(1,0,0),1,nil))
        assert(values.n==4 and values[1]=="native" and values[2]==nil and values[3]==projectile.pos and values[4]==false)
        assert(arguments.n==8 and arguments[1]==projectile and arguments[2]==attacker and arguments[5]==nil and arguments[8]==nil,
            "adapter changed native explosion arguments")
        assert(#f.queued==1 and f.queued[1].tank==car and f.queued[1].origin==projectile.pos
            and f.queued[1].direction:DistToSqr(projectile.velocity:GetNormalized())<1e-12,
            "tank owner, origin or projectile travel direction was lost")
        Glide.CreateExplosion(projectile,attacker,projectile.pos)
        assert(#f.queued==1 and f.native==2,"damage victims/exact event queued the same shell more than once")
        Glide.CreateExplosion()
        assert(arguments.n==0,"zero-argument native call was expanded with nil arguments")
        print("PASS: late Glide event adapter preserves arguments/nil returns, queues once before damage recursion and accepts queue refusal")

        local count=#f.queued
        for _,p in ipairs({shell(tank(1)),shell(car,"glide_missile"),shell({valid=false}),shell({VehicleType=5})}) do
            Glide.CreateExplosion(p,attacker,p.pos)
        end
        local invalid=shell(car)
        Glide.CreateExplosion(invalid,{IsPlayer=function() return false end},invalid.pos)
        f.hooks["GVoxel.GlideTankBlastDamage"]({},damage(shell(car),attacker,false))
        assert(#f.queued==count,"non-tank/other missile/non-player/non-explosion carved terrain")
        V.ReleaseGlideTankExplosionAdapter()
        assert(Glide.CreateExplosion==original)
        local fallback=shell(car) emitFallback(fallback,attacker)
        assert(#f.queued==count+1,"missing exact adapter fallback did not deduplicate real tank damage")
        local retained=shell(car) wrapper(retained,attacker,retained.pos)
        -- The disabled wrapper still invokes the native function, whose damage
        -- independently reaches the fallback; it must not enqueue a second time.
        assert(#f.queued==count+2)
        print("PASS: Glide filter excludes other weapons/vehicles and explosion-damage fallback deduplicates tank shells")

        local mine=shell(nil,"npc_satchel")
        function mine:GetInternalVariable(name) assert(name=="m_hThrower") return attacker end
        local sound=f.hooks["GVoxel.SLAMExplosion"]
        count=#f.queued
        assert(sound({Entity=mine,OriginalSoundName="BaseGrenade.Explode",SoundName="weapons/grenade.wav"})==nil)
        assert(#f.queued==count+1 and f.queued[#f.queued].source=="slam"
            and f.queued[#f.queued].radius==112 and f.queued[#f.queued].attacker==attacker,
            "victim-free SLAM explosion lost its thrower or common RPG descriptor")
        for _=1,5 do f.hooks["GVoxel.RPGBlastDamage"]({},damage(mine,attacker)) end
        local laser=shell(nil,"npc_tripmine")
        function laser:GetInternalVariable() return attacker end
        for _=1,5 do f.hooks["GVoxel.RPGBlastDamage"]({},damage(laser,attacker)) end
        assert(sound({Entity=laser,SoundName="BaseGrenade.Explode"})==nil)
        assert(#f.queued==count+2,"SLAM sound/damage callbacks duplicated an explosion")
        print("PASS: both HL2 SLAM modes share the RPG radius/seeded queue, recover the cleared owner from m_hThrower and deduplicate sound/damage in either order, including blasts with no victims")
        count=#f.queued
        for _,name in ipairs({"SatchelCharge.Pickup","TripmineGrenade.PowerUp","TripmineGrenade.StopSound","Weapon_SLAM.SatchelDetonate"}) do
            sound({Entity=shell(attacker,"npc_tripmine"),OriginalSoundName=name})
        end
        sound({Entity=shell(attacker,"npc_grenade_frag"),OriginalSoundName="BaseGrenade.Explode"})
        sound({Entity=shell(nil,"npc_satchel"),OriginalSoundName="BaseGrenade.Explode"})
        f.hooks["GVoxel.RPGBlastDamage"]({},damage(shell(attacker,"npc_satchel"),attacker,false))
        assert(#f.queued==count,"pickup, arming, unrelated weapons or missing thrower carved terrain")
        local planeMissile=shell(tank(4),"glide_missile")
        local impact=Vector(90,34,56)
        V.GetGlideMissileVoxelImpact=function(p) if p==planeMissile then return impact end end
        V.InstallGlideTankExplosionAdapter()
        Glide.CreateExplosion(planeMissile,attacker,planeMissile.pos)
        assert(#f.queued==count+1 and f.queued[#f.queued].source=="glide_missile"
            and f.queued[#f.queued].origin==impact,"plane missile did not use its predicted voxel contact")
        V.GetGlideMissileVoxelImpact=nil
        print("PASS: SLAM arming/pickup/non-blast events do not carve; Glide plane missile uses its scoped voxel impact rather than a distant pre-contact origin")

        V.InstallGlideTankExplosionAdapter()
        f.queueError="deliberate queue failure"
        local failed=shell(car)
        local nativeBefore=f.native
        assert(Glide.CreateExplosion(failed,attacker,failed.pos)=="native")
        assert(f.native==nativeBefore+1 and #f.errors==1,"queue error suppressed native explosion or repeated per victim")
        f.queueError=nil
        local marker={}
        local throwing=function() error(marker) end
        Glide.CreateExplosion=throwing V.InstallGlideTankExplosionAdapter()
        local succeeds,errorValue=pcall(Glide.CreateExplosion)
        assert(not succeeds and errorValue==marker,"adapter replaced the original native error")
        print("PASS: a crater failure preserves native effects and the original explosion error is propagated unchanged")

        Glide.CreateExplosion=original V.InstallGlideTankExplosionAdapter()
        local current=Glide.CreateExplosion
        local duplicate=shell(car) Glide.CreateExplosion(duplicate,attacker,duplicate.pos)
        count=#f.queued
        assert(type(reloadModule)=="function","runner must provide a compiled sv_explosions reload")
        reloadModule()
        assert(Glide.CreateExplosion~=current,"reload did not replace its old adapter")
        Glide.CreateExplosion(duplicate,attacker,duplicate.pos)
        assert(#f.queued==count,"Lua refresh lost projectile deduplication")
        sound=f.hooks["GVoxel.SLAMExplosion"] sound({Entity=mine,OriginalSoundName="BaseGrenade.Explode"})
        assert(#f.queued==count,"Lua refresh duplicated an already exploded SLAM")
        Glide.CreateExplosion(planeMissile,attacker,planeMissile.pos)
        assert(#f.queued==count,"Lua refresh duplicated an already exploded aircraft missile")
        local fresh=shell(car) nativeBefore=f.native
        Glide.CreateExplosion(fresh,attacker,fresh.pos)
        assert(#f.queued==count+1 and f.native==nativeBefore+1,"Lua refresh stacked native explosion calls")
        local previousAPI=Glide
        Glide={VEHICLE_TYPE={TANK=5,PLANE=4},CreateExplosion=original}
        V.InstallGlideTankExplosionAdapter()
        assert(previousAPI.CreateExplosion==original,"replaced Glide API retained an active wrapper")
        f.hooks["GVoxel.ClearRPGBlasts"]()
        count=#f.queued Glide.CreateExplosion(duplicate,attacker,duplicate.pos)
        assert(#f.queued==count+1,"map cleanup did not release the deduplication set")
        print("PASS: Glide adapter refresh/reinstallation and API replacement remain idempotent and map cleanup releases event deduplication")
        if explosionChunk or explodeChunk then
            assert(type(explosionChunk)=="function" and type(explodeChunk)=="function","both compiled installed Glide source fragments are required")
            installedSources(explosionChunk,explodeChunk,missileChunk,launcherChunk,planeChunks)
        end
    end)
    if GVoxel.ReleaseGlideTankExplosionAdapter then GVoxel.ReleaseGlideTankExplosionAdapter() end
    for name,row in pairs(f.saved) do _G[name]=row.value end
    fixture=nil
    if not ok then error(err,0) end
end
