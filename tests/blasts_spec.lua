local V=GVoxel
local old={}
local callbacks,queued,native={},{},0
local chain=false
local function source(class,pos)
    return {GetClass=function() return class end,GetPos=function() return pos or Vector() end,
        IsWorld=function() return false end,IsWeapon=function() return false end}
end
local inflictor=source("addon_grenade")
local attacker={IsPlayer=function() return true end}
local damage={IsExplosionDamage=function() return true end,GetInflictor=function() return inflictor end,
    GetAttacker=function() return attacker end,GetDamage=function() return 100 end}
function InstallBlastTestFixtures()
    old.convar=CreateConVar old.hook=hook old.queue=V.QueueExplosionCrater old.sessions=V.GetScanSessions
    old.blast=util.BlastDamage old.info=util.BlastDamageInfo
    CreateConVar=function(_,default) return {GetBool=function() return default~="0" end,GetFloat=function() return tonumber(default) end} end
    hook={Add=function(_,name,fn) callbacks[name]=fn end}
    V.GetScanSessions=function() return {[6100]={completed=true,region=V.NewScanRegion(6100,Vector(),16)},
        [6101]={completed=true,region=V.NewScanRegion(6101,Vector(2000,0,0),16)}} end
    V.QueueExplosionCrater=function(ply,pos,radius,seed,kind,id,system)
        queued[#queued+1]={ply=ply,pos=pos,radius=radius,id=id,system=system} return true
    end
    util.BlastDamage=function(...)
        native=native+1
        if select(6,...)~=2 then for _=1,6 do callbacks["GVoxel.GenericBlast"]({},damage) end end
        if chain then
            chain=false
            local nested=source("chain_bomb",Vector(20,0,0))
            util.BlastDamage(nested,attacker,Vector(20,0,0),240,100)
        end
        return "native",nil,select("#",...)
    end
    util.BlastDamageInfo=function() native=native+1 return "info" end
end
function RunBlastTests()
    local a,b,c=util.BlastDamage(inflictor,attacker,Vector(),240,100)
    assert(a=="native" and b==nil and c==5 and native==1,"generic observer changed native arguments/returns")
    assert(#queued==1 and queued[1].radius==112 and queued[1].id==6100,"one Lua explosion produced a crater per victim or wrong zone")
    util.BlastDamage(inflictor,attacker,Vector(),240,100)
    assert(#queued==2,"two actual explosions from a reusable source were merged")
    util.BlastDamageInfo(damage,Vector(2000,0,0),80)
    assert(#queued==3 and queued[3].radius==80 and queued[3].id==6101,"DamageInfo radius/second zone was ignored")
    local before=#queued
    util.BlastDamage(inflictor,attacker,Vector(),240,100,2)
    assert(#queued==before,"explicit non-blast damage override excavated terrain")
    local other=source("native_bomb",Vector(2000,0,0))
    damage.GetInflictor=function() return other end
    for _=1,5 do callbacks["GVoxel.GenericBlast"]({},damage) end
    assert(#queued==before+1,"native damage fallback produced duplicate craters")
    V.ObserveVoxelBlast(source("rpg_missile"),attacker,Vector(),240,100,false)
    assert(#queued==before+1,"generic path duplicated the RPG-specific event")
    V.ObserveVoxelBlast(inflictor,{},Vector(),240,200,false)
    assert(queued[#queued].system,"NPC/world blast cannot use the authoritative queue")
    assert(V.BlastCraterRadius(800,1000,1)>V.BlastCraterRadius(100,1000,1)
        and V.BlastCraterRadius(1e8,10000,1)==512 and not V.BlastCraterRadius(0,100,1),"damage/radius bounds are not monotonic")
    before=#queued chain=true
    util.BlastDamage(inflictor,attacker,Vector(),240,100)
    assert(#queued==before+2,"chain reaction was suppressed as a recursive duplicate")
    local wrapper=util.BlastDamage
    V.ReleaseGenericBlasts() V.ReleaseGenericBlasts()
    assert(util.BlastDamage~=wrapper,"generic wrappers survive repeated release")
    CreateConVar=old.convar hook=old.hook V.QueueExplosionCrater=old.queue V.GetScanSessions=old.sessions
    util.BlastDamage=old.blast util.BlastDamageInfo=old.info
    print("PASS: generic BlastDamage/Info preserve native calls, support victim-free blasts, deduplicate damage victims, scale/cap craters, route second-zone/world blasts and release cleanly")
end
