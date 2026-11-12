-- ThumperDust plus a bounded, depth-tested volume cover. Draw explicitly:
-- the original BSP can otherwise cull an emitter located inside an excavated wall.
local V=GVoxel
if V.ReleaseDust then V.ReleaseDust() end
local enabled=CreateClientConVar("vm_blast_dust","1",true,false,"Short dust cover for voxel edits",0,1)
local tokens,last,nativeAt=32,0,0
local clouds, previews = {}, {}
function V.ReleaseDust()
    for _,cloud in ipairs(clouds) do if cloud.emitter:IsValid() then cloud.emitter:Finish() end end
    clouds={}
    for _, preview in ipairs(previews) do if preview.emitter:IsValid() then preview.emitter:Finish() end end
    previews={}
end

local function previewImpact(point)
    if not enabled:GetBool() or EyePos():DistToSqr(point) > 768^2 then return end
    local emitter = ParticleEmitter(point)
    if not emitter then return end
    emitter:SetNoDraw(true)
    if emitter.SetParticleCullRadius then emitter:SetParticleCullRadius(16) end
    for _=1,3 do
        local particle = emitter:Add("particle/particle_smokegrenade", point)
        if particle then
            particle:SetVelocity(VectorRand()*10)
            particle:SetDieTime(0.25)
            particle:SetStartAlpha(175) particle:SetEndAlpha(0)
            particle:SetStartSize(2) particle:SetEndSize(6)
            particle:SetColor(106,100,91)
            particle:SetCollide(false) particle:SetLighting(false)
        end
    end
    if #previews >= 6 then
        local old = table.remove(previews,1)
        if old.emitter:IsValid() then old.emitter:Finish() end
    end
    previews[#previews+1] = {emitter=emitter,expires=RealTime()+0.25}
end

net.Receive("vm_blast_dust",function()
    local p,radius,breaking=net.ReadVector(),net.ReadUInt(11),net.ReadBool()
    if radius==4 and not breaking then previewImpact(p) return end
    if radius<16 or radius>1024 or EyePos():DistToSqr(p)>(2048+radius)^2 then return end
    if breaking then sound.Play("physics/concrete/concrete_break2.wav",p,70,math.random(94,106),0.65) end
    if not enabled:GetBool() then return end
    local now=RealTime()
    tokens=math.min(32,tokens+math.max(0,now-last)*16) last=now
    local count=math.min(math.floor(tokens),math.Clamp(math.ceil(radius/24),6,12))
    if count<4 then return end
    -- Keep the burst on the visible side of the old surface while the new
    -- mesh is prepared; never move it to an unrelated foreground wall.
    local trace=util.TraceLine({start=EyePos(),endpos=p,mask=MASK_SOLID_BRUSHONLY})
    if trace.HitWorld and trace.HitPos:DistToSqr(p)<radius*radius*1.5 then p=trace.HitPos+trace.HitNormal*8 end
    if now>=nativeAt then
        local data=EffectData() data:SetOrigin(p) data:SetScale(math.Clamp(radius/96,0.5,4))
        util.Effect("ThumperDust",data,true,true) nativeAt=now+0.35
    end
    local emitter=ParticleEmitter(p)
    if not emitter then return end
    emitter:SetNoDraw(true)
    if emitter.SetParticleCullRadius then emitter:SetParticleCullRadius(radius*2) end
    tokens=tokens-count
    for _=1,count do
        local direction=VectorRand():GetNormalized()
        local particle=emitter:Add("particle/particle_smokegrenade",p+direction*radius*0.22)
        if particle then
            particle:SetVelocity(direction*radius*0.18+Vector(0,0,16))
            particle:SetDieTime(math.Rand(1.25,2))
            particle:SetStartAlpha(220) particle:SetEndAlpha(0)
            particle:SetStartSize(radius*0.8) particle:SetEndSize(radius*1.1)
            particle:SetRoll(math.Rand(-math.pi,math.pi)) particle:SetRollDelta(math.Rand(-0.6,0.6))
            particle:SetColor(158,144,119) particle:SetAirResistance(110)
            particle:SetGravity(Vector(0,0,-8)) particle:SetCollide(false)
            -- Engine probes inside the old solid can return black.
            particle:SetLighting(false)
        end
    end
    -- Finish invalidates Lua access: keep this emitter alive until its last
    -- manual draw, then release it rather than finishing before Draw().
    if #clouds>=3 then
        local old=table.remove(clouds,1)
        if old.emitter:IsValid() then old.emitter:Finish() end
    end
    clouds[#clouds+1]={emitter=emitter,expires=now+2}
end)
local function drawClouds(list, now)
    for index=#list,1,-1 do
        local cloud=list[index]
        if cloud.expires<=now or not cloud.emitter:IsValid() then
            if cloud.emitter:IsValid() then cloud.emitter:Finish() end
            table.remove(list,index)
        else cloud.emitter:Draw() end
    end
end
hook.Add("PostDrawTranslucentRenderables","GVoxel.DustCover",function(depth,_,sky)
    if (#clouds==0 and #previews==0) or depth or sky or V.CapturingSurface or V.RenderingReplacement or V.ComposingTerrain then return end
    local now=RealTime()
    drawClouds(clouds, now)
    drawClouds(previews, now)
end)
hook.Add("ShutDown","GVoxel.ReleaseDust",V.ReleaseDust)
