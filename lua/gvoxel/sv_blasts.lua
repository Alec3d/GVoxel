-- Generic blast events. Observe damage, never replace damage/effects or infer
-- arbitrary explosions from projectile removal. Exact Lua calls work without victims.
local V=GVoxel
if V.ReleaseGenericBlasts then V.ReleaseGenericBlasts() end
local enabled=CreateConVar("vm_blast_enabled","1",FCVAR_ARCHIVE,"Explosions generiques sur les zones voxel",0,1)
local gain=CreateConVar("vm_blast_scale","1",FCVAR_ARCHIVE,"Echelle du creusement par degats d'explosion",0.1,3)
local state={active=true,installed={}}
local recent,newest,cursor={},{},1
local nilSource={}
local sequence=0
local untyped=setmetatable({}, {__mode="k"})
local blastFlags=bit.bor(DMG_BLAST or 64,DMG_BLAST_SURFACE or 134217728)
local function explosive(damage)
    return damage:IsExplosionDamage() or (damage.GetDamageType and bit.band(damage:GetDamageType(),blastFlags)~=0)
end
local known={rpg_missile=true,npc_satchel=true,npc_tripmine=true,glide_projectile=true,glide_missile=true}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<1e12 end
function V.BlastCraterRadius(damage,radius,scale)
    if not finite(damage) or damage<=0 then return end
    local size=112*(damage/100)^(1/3)*(scale or 1)
    if finite(radius) and radius>0 then size=math.min(size,radius) end
    return math.Clamp(math.floor(size+0.5),8,512)
end
local function validPosition(position)
    return position and finite(position.x) and finite(position.y) and finite(position.z)
end
local function repeated(inflictor,position,deduplicate)
    local scope=deduplicate and state.current or state.current and state.current.parent
    while scope do
        if scope.source==inflictor and scope.pos and scope.pos:DistToSqr(position)<16 then return true end
        scope=scope.parent
    end
    if not deduplicate then return false end
    local key=inflictor==nil and nilSource or inflictor
    local last=newest[key]
    if not last then return false end
    local now=CurTime()
    if now-last.time<=0.05 and last.pos:DistToSqr(position)<16 then return true end
    -- A reusable inflictor can trigger two blasts at distinct positions in
    -- one tick. Check older retained positions when its latest one misses.
    for _,event in ipairs(recent) do
        if event~=last and event.key==key and now-event.time<=0.05 and event.pos:DistToSqr(position)<16 then return true end
    end
    return false,now
end
local function dispatch(inflictor,attacker,position,radius,damage,now,deduplicate)
    local size=V.BlastCraterRadius(damage,radius,gain:GetFloat())
    if not size then return end
    if not deduplicate and state.current then state.current.source=inflictor state.current.pos=position end
    local key=inflictor==nil and nilSource or inflictor
    local event=recent[cursor]
    if not event then
        event={} recent[cursor]=event
    elseif newest[event.key]==event then
        newest[event.key]=nil
    end
    event.key,event.pos,event.time=key,Vector(position.x,position.y,position.z),now or CurTime()
    newest[key]=event
    cursor=cursor%64+1
    local system=not (IsValid(attacker) and attacker.IsPlayer and attacker:IsPlayer())
    local records=V.GetScanSessions and V.GetScanSessions() or {}
    for id,scan in pairs(records) do
        if scan.completed and V.ZoneDistanceSquared(scan.region,position)<size*size then
            sequence=sequence%65535+1
            V.QueueExplosionCrater(attacker,position,size,sequence,"blast",id,system)
        end
    end
end
local function observe(inflictor,attacker,position,radius,damage,deduplicate)
    if not state.active or not enabled:GetBool() or not validPosition(position) then return end
    if IsValid(inflictor) and known[inflictor:GetClass()] then return end
    local duplicate,now=repeated(inflictor,position,deduplicate)
    if not duplicate then
        dispatch(inflictor,attacker,position,radius,damage,now,deduplicate)
    end
end
V.ObserveVoxelBlast=observe
local function pack(...) return {n=select("#",...),...} end
local function install(name,decode)
    local original=util[name]
    if type(original)~="function" then return end
    local wrapper=function(...)
        if not state.active then return original(...) end
        local scope={parent=state.current}
        state.current=scope
        local ok,err=pcall(decode,...)
        if not ok then ErrorNoHalt("[GVoxel] Analyse explosion : "..tostring(err).."\n") end
        local result=pack(pcall(original,...))
        state.current=scope.parent
        if not result[1] then error(result[2],0) end
        return unpack(result,2,result.n)
    end
    state.installed[#state.installed+1]={name=name,original=original,wrapper=wrapper}
    util[name]=wrapper
end
install("BlastDamage",function(inflictor,attacker,position,radius,damage,damageType)
    if damageType and bit.band(damageType,blastFlags)==0 then return end
    observe(inflictor,attacker,position,radius,damage,false)
end)
install("BlastDamageInfo",function(damage,position,radius)
    if explosive(damage) then observe(damage:GetInflictor(),damage:GetAttacker(),position,radius,damage:GetDamage(),false) end
end)
hook.Add("EntityTakeDamage","GVoxel.GenericBlast",function(victim,damage)
    if not state.active or not enabled:GetBool() then return end
    if not explosive(damage) then
        -- Some scripted bombs omit DMG_BLAST. Require a genuine multi-victim
        -- damage area from a non-weapon entity; a large bullet is not a blast.
        local source=damage:GetInflictor()
        if not IsValid(source) or source:IsWorld() or source.IsWeapon and source:IsWeapon() then return end
        local attacker=damage:GetAttacker()
        if source==attacker then return end
        local amount=damage:GetDamage()
        if amount<40 then return end
        local now=CurTime()
        local event=untyped[source]
        if not event or now-event.time>0.05 then
            untyped[source]={time=now,victim=victim,damage=amount,pos=source:GetPos()}
        elseif event.victim~=victim and not event.sent then
            event.sent=true
            observe(source,attacker,event.pos,nil,math.max(event.damage,amount),true)
        end
        return
    end
    local inflictor=damage:GetInflictor()
    local position
    local valid=IsValid(inflictor)
    if valid and known[inflictor:GetClass()] then return end
    if valid and not (inflictor.IsWeapon and inflictor:IsWeapon()) and not inflictor:IsWorld() then
        position=inflictor:GetPos()
    else
        position=damage.GetReportedPosition and damage:GetReportedPosition()
        if not position or position:LengthSqr()==0 then position=damage:GetDamagePosition() end
    end
    if not validPosition(position) then return end
    local duplicate,now=repeated(inflictor,position,true)
    if not duplicate then
        dispatch(inflictor,damage:GetAttacker(),position,nil,damage:GetDamage(),now,true)
    end
end)
hook.Add("AcceptInput","GVoxel.GenericExplosionInput",function(ent,input)
    if input:lower()~="explode" then return end
    local class=ent:GetClass()
    if class~="env_explosion" and class~="env_physexplosion" then return end
    local inflictor=ent:GetInternalVariable("m_hInflictor")
    local damage=tonumber(ent:GetInternalVariable("m_iMagnitude")) or tonumber(ent:GetInternalVariable("m_magnitude")) or 100
    local radius=tonumber(ent:GetInternalVariable("m_iRadiusOverride")) or tonumber(ent:GetInternalVariable("m_radius"))
    observe(IsValid(inflictor) and inflictor or ent,ent:GetOwner(),ent:GetPos(),radius,damage,true)
end)
hook.Add("EntityEmitSound","GVoxel.FragExplosion",function(data)
    local ent=data.Entity
    if not IsValid(ent) or ent:GetClass()~="npc_grenade_frag"
        or (data.OriginalSoundName or data.SoundName or ""):lower()~="basegrenade.explode" then return end
    local attacker=ent.GetInternalVariable and ent:GetInternalVariable("m_hThrower") or ent:GetOwner()
    local damage=ent.GetInternalVariable and tonumber(ent:GetInternalVariable("m_flDamage")) or 100
    observe(ent,attacker,ent:GetPos(),nil,damage or 100,true)
end)
local function clearRecent()
    recent,newest,cursor={},{},1
    untyped=setmetatable({}, {__mode="k"})
end
function V.ReleaseGenericBlasts()
    if not state.active then return end
    state.active=false
    for _,entry in ipairs(state.installed) do if util[entry.name]==entry.wrapper then util[entry.name]=entry.original end end
    state.installed={}
    clearRecent()
end
hook.Add("PostCleanupMap","GVoxel.ClearGenericBlasts",clearRecent)
hook.Add("ShutDown","GVoxel.ReleaseGenericBlasts",V.ReleaseGenericBlasts)
