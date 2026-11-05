-- Generic blast events. Observe damage, never replace damage/effects or infer
-- arbitrary explosions from projectile removal. Exact Lua calls work without victims.
local V=GVoxel
if V.ReleaseGenericBlasts then V.ReleaseGenericBlasts() end
local enabled=CreateConVar("vm_blast_enabled","1",FCVAR_ARCHIVE,"Explosions generiques sur les zones voxel",0,1)
local gain=CreateConVar("vm_blast_scale","1",FCVAR_ARCHIVE,"Echelle du creusement par degats d'explosion",0.1,3)
local state={active=true,depth=0,installed={},recent={}}
local sequence=0
local untyped=setmetatable({}, {__mode="k"})
local function explosive(damage)
    return damage:IsExplosionDamage() or (damage.GetDamageType and bit.band(damage:GetDamageType(),bit.bor(DMG_BLAST or 64,DMG_BLAST_SURFACE or 134217728))~=0)
end
local known={rpg_missile=true,npc_satchel=true,npc_tripmine=true,glide_projectile=true,glide_missile=true}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<1e12 end
function V.BlastCraterRadius(damage,radius,scale)
    if not finite(damage) or damage<=0 then return end
    local size=112*(damage/100)^(1/3)*(scale or 1)
    if finite(radius) and radius>0 then size=math.min(size,radius) end
    return math.Clamp(math.floor(size+0.5),8,512)
end
local function observe(inflictor,attacker,position,radius,damage,deduplicate)
    if not state.active or not enabled:GetBool() or not position
        or not finite(position.x) or not finite(position.y) or not finite(position.z) then return end
    if IsValid(inflictor) and known[inflictor:GetClass()] then return end
    local size=V.BlastCraterRadius(damage,radius,gain:GetFloat())
    if not size then return end
    local scope=deduplicate and state.current or state.current and state.current.parent
    while scope do
        if scope.source==inflictor and scope.pos and scope.pos:DistToSqr(position)<16 then return end
        scope=scope.parent
    end
    if not deduplicate and state.current then state.current.source=inflictor state.current.pos=position end
    local now=CurTime()
    if deduplicate then
        for _,event in ipairs(state.recent) do
            if event.source==inflictor and now-event.time<=0.05 and event.pos:DistToSqr(position)<16 then return end
        end
    end
    state.recent[#state.recent+1]={source=inflictor,pos=Vector(position.x,position.y,position.z),time=now}
    if #state.recent>64 then table.remove(state.recent,1) end
    local system=not (IsValid(attacker) and attacker.IsPlayer and attacker:IsPlayer())
    local records=V.GetScanSessions and V.GetScanSessions() or {}
    for id,scan in pairs(records) do
        if scan.completed and V.ZoneDistanceSquared(scan.region,position)<size*size then
            sequence=sequence%65535+1
            V.QueueExplosionCrater(attacker,position,size,sequence,"blast",id,system)
        end
    end
end
V.ObserveVoxelBlast=observe
local function pack(...) return {n=select("#",...),...} end
local function install(name,decode)
    local original=util[name]
    if type(original)~="function" then return end
    local wrapper=function(...)
        local scope={parent=state.current}
        state.current=scope
        if state.active then
            local ok,err=pcall(decode,...)
            if not ok then ErrorNoHalt("[GVoxel] Analyse explosion : "..tostring(err).."\n") end
        end
        state.depth=state.depth+1
        local result=pack(pcall(original,...))
        state.depth=state.depth-1
        state.current=scope.parent
        if not result[1] then error(result[2],0) end
        return unpack(result,2,result.n)
    end
    state.installed[#state.installed+1]={name=name,original=original,wrapper=wrapper}
    util[name]=wrapper
end
install("BlastDamage",function(inflictor,attacker,position,radius,damage,damageType)
    if damageType and bit.band(damageType,bit.bor(DMG_BLAST or 64,DMG_BLAST_SURFACE or 134217728))==0 then return end
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
        if not IsValid(source) or source:IsWorld() or source==damage:GetAttacker()
            or source.IsWeapon and source:IsWeapon() or damage:GetDamage()<40 then return end
        local now=CurTime()
        local event=untyped[source]
        if not event or now-event.time>0.05 then
            untyped[source]={time=now,victim=victim,damage=damage:GetDamage(),pos=source:GetPos()}
        elseif event.victim~=victim and not event.sent then
            event.sent=true
            observe(source,damage:GetAttacker(),event.pos,nil,math.max(event.damage,damage:GetDamage()),true)
        end
        return
    end
    local inflictor=damage:GetInflictor()
    local position
    if IsValid(inflictor) and not (inflictor.IsWeapon and inflictor:IsWeapon()) and not inflictor:IsWorld() then
        position=inflictor:GetPos()
    else
        position=damage.GetReportedPosition and damage:GetReportedPosition()
        if not position or position:LengthSqr()==0 then position=damage:GetDamagePosition() end
    end
    observe(inflictor,damage:GetAttacker(),position,nil,damage:GetDamage(),true)
end)
hook.Add("AcceptInput","GVoxel.GenericExplosionInput",function(ent,input)
    if input:lower()~="explode" or (ent:GetClass()~="env_explosion" and ent:GetClass()~="env_physexplosion") then return end
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
function V.ReleaseGenericBlasts()
    state.active=false
    for _,entry in ipairs(state.installed) do if util[entry.name]==entry.wrapper then util[entry.name]=entry.original end end
end
hook.Add("PostCleanupMap","GVoxel.ClearGenericBlasts",function() state.recent={} untyped=setmetatable({}, {__mode="k"}) end)
hook.Add("ShutDown","GVoxel.ReleaseGenericBlasts",V.ReleaseGenericBlasts)
