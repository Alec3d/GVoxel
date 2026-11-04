-- Software depth/stencil adapter for the actual native-render orchestration.
-- This verifies invariants, not a GPU/Source engine screenshot.
local V=GVoxel
local hooks,commands={},{}
local currentTarget=nil
local clipping,ignoredZ,suppressed=false,false,false
local tintRed,tintGreen,tintBlue,modelAlpha=1,1,1,1
local planes,matrices,targets=0,0,0
local stencilEnabled=false
local colorOverride,alphaOverride,depthOverride=false,false,false
local writeMask,testMask,reference,comparison=255,255,0,8
local passOperation,failOperation,zfailOperation=1,1,1
local pixel={depth=2000,stencil=0,color="bsp"}
local camera,forward=Vector(-1500,0,100),Vector(1,0,0)
local angles={Forward=function() return forward end}
local renders,terrainDraws,lightQueries,reports=0,0,0,0
local lastError
local rtAllocations,portalBuilds=0,0
local enabled=true
local injectFailure=nil
local now=100
local r
local frame=0
local skyMode="3d"
local tone=Vector(0.7,0.8,0.9)
local models={}
local entitySearches=0
table.Copy=table.Copy or function(source)
    local result={} for key,value in pairs(source) do result[key]=value end return result
end
function FrameNumber() return frame end
local haloCalls=0
local haloEntity=nil
halo={RenderedEntity=function() return haloEntity end}
local events={PostDrawEffects={RenderHalos=function() haloCalls=haloCalls+1 end}}
color_white=Color(255,255,255)
STENCILCOMPARISONFUNCTION_ALWAYS=8 STENCILCOMPARISONFUNCTION_EQUAL=3
STENCILOPERATION_KEEP=1 STENCILOPERATION_ZERO=2 STENCILOPERATION_REPLACE=3 STENCILOPERATION_INCRSAT=4
RT_SIZE_LITERAL=8 MATERIAL_RT_DEPTH_SEPARATE=1 IMAGE_FORMAT_RGBA8888=2
IMAGE_FORMAT_RGBA16161616F=24
CREATERENDERTARGETFLAGS_UNFILTERABLE_OK=0
function CreateClientConVar() return {GetBool=function() return enabled end,GetFloat=function() return 0.5 end} end
function CreateMaterial(_,shader,params) return {shader=shader,params=params} end
function GetRenderTargetEx(_,w,h,mode)
    assert(w==1280 and h==720 and mode==RT_SIZE_LITERAL,"background RT padded or stretched")
    rtAllocations=rtAllocations+1
    return {GetName=function() return "literal_background" end}
end
function LocalPlayer() return {ShouldDrawLocalPlayer=function() return false end} end
function RealTime() return now end
function SysTime() now=now+0.00001 return now end
function ScrW() return 1280 end
function ScrH() return 720 end
function ErrorNoHalt(err) reports=reports+1 lastError=err end
chat={AddText=function() end}
ents={FindInBox=function() entitySearches=entitySearches+1 return models end}
hook={Add=function(event,name,fn)
    hooks[name]=fn events[event]=events[event] or {} events[event][name]=fn
end,Remove=function(event,name) hooks[name]=nil if events[event] then events[event][name]=nil end end,
GetTable=function() return events end}
concommand={Add=function(name,fn) commands[name]=fn end}
cam={
    PushModelMatrix=function() matrices=matrices+1 end,
    PopModelMatrix=function() matrices=matrices-1 end,
    IgnoreZ=function(v) ignoredZ=v end
}
local noop=function() end
local function compare()
    return comparison==8 or bit.band(pixel.stencil,testMask)==bit.band(reference,testMask)
end
local function operation(op)
    if op==1 then return end
    local value=op==2 and 0 or (op==4 and math.min(255,pixel.stencil+1) or reference)
    pixel.stencil=bit.bor(bit.band(pixel.stencil,bit.bnot(writeMask)),bit.band(value,writeMask))
end
local function fragment(distance,color)
    if distance<4 then return end
    if stencilEnabled and not compare() then operation(failOperation) return end
    if not ignoredZ and distance>pixel.depth+1e-6 then
        if stencilEnabled then operation(zfailOperation) end
        return
    end
    if stencilEnabled then operation(passOperation) end
    if not colorOverride then pixel.color=color end
    if not depthOverride then pixel.depth=distance end
end
local function quad(a,b,c,d)
    local normal=(b-a):Cross(c-a):GetNormalized()
    local denominator=forward:Dot(normal)
    if math.abs(denominator)<1e-9 then return end
    local t=(a-camera):Dot(normal)/denominator
    local p=camera+forward*t
    for _,axis in ipairs({"x","y","z"}) do
        if p[axis]<math.min(a[axis],b[axis],c[axis],d[axis])-1e-6
            or p[axis]>math.max(a[axis],b[axis],c[axis],d[axis])+1e-6 then return end
    end
    fragment(t,"quad")
end
function Mesh()
    local m={dead=false}
    function m:IsValid() return not self.dead end
    function m:BuildFromTriangles(vertices)
        portalBuilds=portalBuilds+1
        self.vertices=vertices
        self.normal=vertices[1].normal
        self.point=vertices[1].pos
    end
    function m:Draw()
        assert(not self.dead,"drawing a destroyed portal")
        assert(not currentTarget,"compiled opening drawn recursively into background")
        local denominator=forward:Dot(self.normal)
        if math.abs(denominator)<1e-9 then return end
        local t=(self.point-camera):Dot(self.normal)/denominator
        local p=camera+forward*t
        if V.InScanCube(r,p) and V.Density(r,p)>0.001 then fragment(t,"opening") end
    end
    function m:Destroy() assert(not self.dead) self.dead=true end
    return m
end
render={
    GetToneMappingScaleLinear=function() return tone end,SetToneMappingScaleLinear=function(v) tone=v end,
    SetMaterial=noop,
    DrawQuad=quad,
    ClearStencil=function() pixel.stencil=0 end,
    SetStencilWriteMask=function(v) writeMask=v end,SetStencilTestMask=function(v) testMask=v end,
    SetStencilReferenceValue=function(v) reference=v end,SetStencilCompareFunction=function(v) comparison=v end,
    SetStencilPassOperation=function(v) passOperation=v end,SetStencilFailOperation=function(v) failOperation=v end,
    SetStencilZFailOperation=function(v) zfailOperation=v end,
    SetStencilEnable=function(v) stencilEnabled=v end,
    OverrideColorWriteEnable=function(v) colorOverride=v end,
    OverrideAlphaWriteEnable=function(v) alphaOverride=v end,
    OverrideDepthEnable=function(v,write) depthOverride=v and not write end,
    PerformFullScreenStencilOperation=function() operation(compare() and passOperation or failOperation) end,
    ClearBuffersObeyStencil=function(_,_,_,_,depth)
        assert(not currentTarget,"local clear executed in background")
        if compare() then pixel.color="cleared" if depth then pixel.depth=math.huge end end
    end,
    SuppressEngineLighting=function(v) suppressed=v end,
    ComputeLighting=function() lightQueries=lightQueries+1 return Vector(0.3,0.5,0.7) end,
    ResetModelLighting=noop,SetModelLighting=noop,SetLightingOrigin=noop,SetLocalModelLights=noop,
    RenderFlashlights=function(fn) fn() end,
    SetBlend=function(a) modelAlpha=a end,
    SetColorModulation=function(r,g,b) tintRed,tintGreen,tintBlue=r,g,b end,
    OverrideBlend=noop,
    GetRenderTarget=function() return currentTarget end,
    PushRenderTarget=function(target) assert(not currentTarget) currentTarget=target targets=targets+1 end,
    PopRenderTarget=function() currentTarget=nil targets=targets-1 end,
    EnableClipping=function(v) local previous=clipping clipping=v return previous end,
    PushCustomClipPlane=function() planes=planes+1 end,
    PopCustomClipPlane=function() planes=planes-1 end,
    Clear=function() assert(currentTarget,"unmasked main scene clear") end,
    GetViewSetup=function() return {origin=camera,angles=angles,fov=106,fovviewmodel=60,znearviewmodel=1,zfarviewmodel=500,aspect=1280/720,width=1280,height=720,znear=4,zfar=30000} end,
    DrawScreenQuad=function()
        assert(not currentTarget and stencilEnabled and depthOverride,"unmasked background copy")
        if compare() then pixel.color="background" end
    end,
    RenderView=function(view)
        assert(tone.x==1 and tone.y==0.8 and tone.z==0.9,"secondary world image applies HDR exposure more than once")
        assert(view.viewid==2,"secondary aperture overwrites MAIN SSAO/depth textures")
        assert(currentTarget and planes==0 and clipping,"sky started with world clip plane")
        assert(not V.ComposingTerrain,"RenderView entered main-view compositing/viewmodel stage")
        if skyMode=="3d" then
            hooks["GVoxel.BackgroundSkyBegin"]()
            hooks["GVoxel.Background2DSky"]()
            assert(planes==0 and V.MaskInSkybox,"world plane clips scaled skybox geometry")
            hooks["GVoxel.BackgroundSkyEnd"]()
        elseif skyMode=="2d" then hooks["GVoxel.Background2DSky"]()
        else hooks["GVoxel.BackgroundWorldClip"]() end
        assert(planes==1 and not V.MaskInSkybox,"world plane was not restored after sky")
        hooks["GVoxel.ExteriorMissingContent"](false,false,false)
        assert(not view.drawviewmodel and not view.drawhud and view.fov==106 and view.aspect==1280/720)
        assert(view.viewmodelfov==60 and view.znearviewmodel==1 and view.zfarviewmodel==500,"viewmodel projection was replaced by secondary camera defaults")
        tone=Vector(99,99,99)
        renders=renders+1
        local beforeHalo=haloCalls
        events.PostDrawEffects.RenderHalos()
        assert(haloCalls==beforeHalo,"physgun halo ran inside nested view and overwrote global scene RT")
        local before=terrainDraws
        hooks["GVoxel.ReplaceNativeTerrain"](false,false,false)
        assert(terrainDraws==before,"voxel geometry was rendered through a texture again")
        if injectFailure=="view" then error("injected secondary view failure") end
    end
}

function RunClientMaskTests()
    r=V.NewScanRegion(1,Vector(),16)
    for i=0,33^3-1 do
        local p,x,y,z=V.ScanPoint(r,i)
        r.values[V.Index(x,y,z,r)]=p.z
    end
    r.chunks.one={lightOrigin=Vector(0,0,4),transform={},mesh={IsValid=function() return true end,Draw=function()
        assert(not currentTarget,"terrain must render in native main view")
        terrainDraws=terrainDraws+1
        local beforeRecursive=terrainDraws
        hooks["GVoxel.ReplaceNativeTerrain"](false,false,false)
        assert(terrainDraws==beforeRecursive,"native draw reentered compositor")
        if injectFailure=="mesh" then error("injected native mesh failure") end
        if math.abs(forward.z)>1e-9 then
            local t=-camera.z/forward.z
            if V.InScanCube(r,camera+forward*t) then fragment(t,"voxel") end
        end
    end}}
    local function draw(depth,sky,sky3D)
        frame=frame+1
        if not depth and not sky3D and not haloEntity then hooks["GVoxel.PrepareBackgrounds"](camera,angles,106) end
        hooks["GVoxel.ReplaceNativeTerrain"](depth,sky,sky3D)
    end
    local function balanced()
        assert(targets==0 and matrices==0 and planes==0 and not currentTarget,"render stack leak")
        assert(tone:DistToSqr(Vector(0.7,0.8,0.9))<1e-12,"secondary view changed main HDR exposure")
        assert(not clipping and not V.RenderingReplacement and not ignoredZ and not suppressed,"scene state leak")
        assert(not stencilEnabled and not colorOverride and not alphaOverride and not depthOverride,"write state leak")
        assert(tintRed==1 and tintGreen==1 and tintBlue==1 and modelAlpha==1,"entity color/alpha leaked into the next pass")
    end
    local function prepare()
        V.SetVisualRegion(r)
        assert(not V.VisualReplacementEnabled(),"openings exposed before compilation")
        for _=1,6 do hooks["GVoxel.CompileOpenings"]() end
        assert(V.VisualReplacementEnabled(),"compiled terrain not activated")
    end
    for _,class in ipairs({"predicted_viewmodel","gmod_hands"}) do
        models[#models+1]={IsWorld=function() return false end,IsWeapon=function() return false end,GetNoDraw=function() return false end,
            GetClass=function() return class end,GetParent=function() return {valid=false} end,
            DrawModel=function() error("first-person model redrawn as world geometry") end}
    end
    prepare()
    assert(V.ScanSurfaceMaterial.shader=="VertexLitGeneric")
    camera=Vector(0,0,100) forward=Vector(1,0,0)
    pixel={depth=2000,stencil=0,color="native idle"}
    for _=1,60 do draw(false,false,false) end
    assert(terrainDraws>0,"prepared scan did not replace the BSP before the first hole")
    balanced()
    print("PASS: prepared revision zero renders the complete replacement terrain before the first hole")
    local initialDraws=terrainDraws
    r.revision=1
    draw(true,false,false) draw(false,true,true)
    assert(terrainDraws==initialDraws)
    terrainDraws=0 renders=0
    camera=Vector(0,0,100) forward=Vector(0,0,-1)
    pixel={depth=100,stencil=0,color="bsp"}
    draw(false,false,false)
    assert(pixel.color=="voxel" and math.abs(pixel.depth-100)<1e-6,"native terrain lost its depth")
    assert(terrainDraws==2,"terrain drawn once per background face instead of once plus flashlight")
    assert(lightQueries==6,"lighting not cached")
    assert(renders==0,"looking at solid floor still renders invisible exterior views")
    events.PostDrawEffects.RenderHalos()
    assert(haloCalls==1,"main-view physgun halo was disabled")
    haloEntity={}
    local beforeHaloDraw=terrainDraws
    draw(false,false,false)
    assert(terrainDraws==beforeHaloDraw,"compositor entered a halo model pass")
    haloEntity=nil
    balanced()
    local previousSurface=V.SurfaceMaterial
    V.SurfaceMaterial=function(batch) return batch.material end
    local first=r.chunks.one.mesh
    r.chunks.one.batches={{mesh=first,material={}},{mesh=first,material={}}}
    local beforeBatches=terrainDraws
    draw(false,false,false)
    assert(terrainDraws==beforeBatches+4 and pixel.color=="voxel","textured batches lost main-view depth/flashlight rendering")
    r.chunks.one.batches=nil V.SurfaceMaterial=previousSurface
    local compiled=portalBuilds
    for _,eye in ipairs({Vector(-1500,0,100),Vector(1500,0,100),Vector(0,-1500,100),Vector(0,1500,100)}) do
        camera=eye
        forward=(Vector(0,0,0)-eye):GetNormalized()
        pixel={depth=math.sqrt(eye:LengthSqr()),stencil=0,color="bsp"}
        draw(false,false,false)
        assert(pixel.color=="voxel","terrain vanished at rotated external camera")
        assert(pixel.depth<math.huge,"native mesh did not write depth")
        balanced()
    end
    assert(portalBuilds==compiled,"boundary openings rebuilt per camera/frame")
    camera=r.origin+Vector(-1,r.side/2,r.side/2+100) forward=Vector(1,0,0)
    pixel={depth=2000,stencil=0,color="bsp"}
    draw(false,true,false)
    assert(pixel.color=="background","near-plane aperture or 2D sky view not filled")
    balanced()
    camera=r.origin+Vector(-100,r.side/2,r.side/2+100)
    pixel={depth=20,stencil=0,color="foreground"}
    draw(false,false,false)
    assert(pixel.color=="foreground" and pixel.depth==20,"foreground outside volume overwritten")
    camera=Vector(0,0,100) forward=Vector(1,0,0)
    pixel={depth=2000,stencil=0,color="bsp"}
    draw(false,false,false)
    assert(pixel.color=="background","inside camera missed opening")
    assert(pixel.depth<math.huge,"background color has no exit depth; exterior effects can be drawn twice")
    local exteriorDepth=pixel.depth
    fragment(exteriorDepth+10,"duplicate exterior shadow")
    assert(pixel.color=="background","main translucent pass repainted an already-composited exterior")
    local beforeCached=renders
    pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(renders==beforeCached,"stationary digging re-renders the unchanged exterior every frame")
    assert(rtAllocations<=6,"background RTs not pooled between frames")
    for _,mode in ipairs({"2d","none"}) do
        skyMode=mode pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
        assert(pixel.color=="background","sky/world clip transition lost background on "..mode)
        balanced()
    end
    skyMode="3d"
    local oldAll,oldSky,oldPrepareSky=ents.GetAll,V.DrawVoxelSky,V.PrepareVoxelSky
    local outsideDraws,skyDraws=0,0
    local outside={class="prop_physics"}
    function outside:IsWorld() return false end function outside:IsWeapon() return false end
    function outside:GetNoDraw() return false end function outside:IsPlayer() return self.player==true end
    function outside:IsNPC() return self.npc==true end function outside:GetClass() return self.class end
    function outside:Alive() return true end
    function outside:GetModel() return "models/test.mdl" end function outside:GetParent() return {valid=false} end
    function outside:WorldSpaceAABB() return Vector(500,-10,80),Vector(520,10,120) end
    function outside:TestPVS() return self.native==true end
    function outside:IsDormant() return self.dormant==true end
    function outside:DrawModel() assert(currentTarget and planes==1,"outside model escaped clipped exit view") outsideDraws=outsideDraws+1 end
    ents.GetAll=function() return {outside} end
    local oldTrace=util.TraceLine
    local exteriorWall=false
    local rayCalls=0
    util.TraceLine=function(data)
        rayCalls=rayCalls+1
        assert(not data.ignoreworld and data.start.x>r.origin.x+V.RegionAxisSize(r,"x"),"exterior LOS removed native world outside cage")
        return exteriorWall and {Hit=true,HitWorld=true,Fraction=0.2} or {Hit=true,Entity=outside,Fraction=0.9}
    end
    V.DrawVoxelSky=function() assert(currentTarget,"sky fallback painted the main scene") skyDraws=skyDraws+1 end
    V.PrepareVoxelSky=function() return nil end
    camera=Vector(0,0,100) forward=Vector(1,0,0) skyMode="none" now=now+0.16
    pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(outsideDraws>0 and skyDraws>0,"missing native PVS entity/sky was not repaired through the opening")
    local unobstructed=outsideDraws
    exteriorWall=true now=now+0.06
    pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(outsideDraws==unobstructed and rayCalls>=10,"PVS repair revealed an exterior prop behind a native wall")
    exteriorWall=false now=now+0.06
    pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(outsideDraws>unobstructed,"visible exterior prop stayed hidden after its blocker was removed")
    local beforeRays=rayCalls
    now=now+0.034 pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(rayCalls==beforeRays,"stationary exterior visibility does not reuse its short-lived proof")
    local beforeMove=outsideDraws
    camera=Vector(0,1,100) exteriorWall=true
    pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(outsideDraws==beforeMove and rayCalls>beforeRays,"moving camera reused stale positive LOS through a wall")
    camera=Vector(0,0,100) exteriorWall=false now=now+0.06
    local before=outsideDraws outside.native=true now=now+0.05
    pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(outsideDraws==before,"native-PVS model drawn a second time")
    outside.native=false outside.dormant=true now=now+0.05
    pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(outsideDraws==before,"stale dormant exterior model rendered")
    outside.dormant=false outside.class="func_occluder" now=now+0.05
    pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(outsideDraws==before,"invisible optimization brush redrawn as a solid model")
    outside.class="npc_citizen" outside.npc=true
    local weapons=0
    outside.GetActiveWeapon=function() return {DrawModel=function() weapons=weapons+1 end} end
    now=now+0.05 pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(outsideDraws>before and weapons==outsideDraws-before,"outside NPC/held weapon missing from the opening")
    before=outsideDraws outside.npc=false outside.player=true outside.class="player"
    now=now+0.05 pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(outsideDraws>before,"outside living player missing from the opening")
    -- Force more blocked candidates than one frame can afford. No unchecked
    -- object may leak through, and next frame must advance past the prefix.
    local crowded={}
    for i=1,30 do
        local ent=setmetatable({npc=false,player=false,class="prop_physics"},{__index=outside})
        ent.WorldSpaceAABB=function() return Vector(500+i*10,-10,80),Vector(520+i*10,10,120) end
        crowded[i]=ent
    end
    ents.GetAll=function() return crowded end
    local farthest=0
    util.TraceLine=function(data)
        farthest=math.max(farthest,data.endpos.x)
        return {Hit=true,HitWorld=true,Fraction=0.2}
    end
    now=now+0.16 before=outsideDraws
    pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    local visibilityStats=V.GetVoxelRenderStats()
    assert(visibilityStats.exteriorTraces<=96 and visibilityStats.exteriorDeferred>0 and outsideDraws==before,
        "crowded exterior exceeded its ray budget or displayed unchecked models")
    local firstFarthest=farthest
    now=now+0.034 pixel={depth=2000,stencil=0,color="bsp"} draw(false,false,false)
    assert(farthest>firstFarthest and outsideDraws==before,"deferred exterior models starved behind the same blocked prefix")
    ents.GetAll=oldAll util.TraceLine=oldTrace V.DrawVoxelSky=oldSky V.PrepareVoxelSky=oldPrepareSky skyMode="3d" now=now+0.16
    print("PASS: absent engine sky gets an exit-only fallback; exterior models missing from native PVS draw in the clipped view while native and dormant models are not duplicated")
    print("PASS: exterior fallback rejects native occluders, expires moving-camera proofs, shares cached LOS and bounds crowded-frame ray work without revealing unchecked or starving deferred models")
    balanced()
    local litModel,litWeapon=0,0
    local heldWeapon={DrawModel=function() assert(suppressed,"NPC weapon lost cavity lighting") litWeapon=litWeapon+1 end}
    local actor={IsWorld=function() return false end,IsWeapon=function() return false end,GetNoDraw=function() return false end,
        GetParent=function() return {valid=false} end,GetClass=function() return "npc_citizen" end,
        GetModel=function() return "models/test.mdl" end,IsPlayer=function() return false end,IsNPC=function() return true end,
        GetActiveWeapon=function() return heldWeapon end,
        DrawModel=function() assert(suppressed,"NPC model lost cavity lighting") litModel=litModel+1 end}
    local previousLight=V.LightVoxelProp
    V.LightVoxelProp=function(_,ent) if ent==actor then render.SuppressEngineLighting(true) return true end end
    models[#models+1]=actor
    now=now+0.16
    draw(false,false,false)
    assert(litModel>0 and litWeapon==litModel,"NPC/attached weapon were not drawn with the same lighting: "..tostring(lastError))
    balanced()
    models[#models]=nil V.LightVoxelProp=previousLight
    -- A visual wheel can be absent from the spatial partition and parented
    -- to a separate, invisible physics wheel. Find it without a global scan.
    local originalModels=models
    local counts={}
    local function model(name,class,parent)
        local ent={class=class,parent=parent,children={},paint="original",material="native",color=color_white}
        function ent:IsWorld() return false end function ent:IsWeapon() return false end
        function ent:GetNoDraw() return self.hidden or false end
        function ent:GetParent() return self.parent end function ent:GetChildren() return self.children end
        function ent:GetClass() return self.class end function ent:GetModel() return "models/test.mdl" end
        function ent:IsPlayer() return false end function ent:IsNPC() return false end
        function ent:GetColor4Part() return self.color.r,self.color.g,self.color.b,self.color.a end
        function ent:GetColor() return self.color end
        function ent:DrawModel()
            assert(not suppressed and self.paint=="original" and self.material=="native","vehicle render lost native lighting/paint/material")
            assert(math.abs(tintRed-self.color.r/255)<1e-9 and math.abs(tintGreen-self.color.g/255)<1e-9
                and math.abs(tintBlue-self.color.b/255)<1e-9 and math.abs(modelAlpha-self.color.a/255)<1e-9,
                "vehicle manual redraw lost its own RGBA or inherited another part's tint")
            counts[name]=(counts[name] or 0)+1
            if self.Draw then return self:Draw() end
        end
        return ent
    end
    local car=model("car","base_glide")
    local wheel=model("glide","glide_wheel",car)
    local physWheel=model("physics","gmod_sent_vehicle_fphysics_wheel")
    physWheel.Draw=function() return false end -- Stock Simfphys invisible body.
    local ghost=model("ghost","gmod_sent_vehicle_fphysics_attachment",physWheel)
    local hidden=model("hidden","base_anim",car) hidden.hidden=true
    local vm=model("viewmodel","predicted_viewmodel")
    local vmChild=model("vm_child","base_anim",vm)
    car.children={wheel,hidden} physWheel.children={ghost} wheel.children={car} vm.children={vmChild}
    models={car,wheel,physWheel,vm} -- Ghost is clientside; wheel is duplicated.
    now=now+0.16 draw(false,false,false)
    assert(counts.car==1 and counts.glide==1 and counts.ghost==1 and counts.physics==1,
        "parented/client-only vehicle parts vanished, duplicated, or bypassed native DrawModel")
    assert(not counts.hidden and not counts.viewmodel and not counts.vm_child,"hidden/first-person attachment drawn in the world")
    local searches=entitySearches
    for _=1,10 do draw(false,false,false) end
    assert(counts.car==11 and counts.glide==11 and counts.ghost==11 and entitySearches==searches,
        "vehicle children were rediscovered per frame or escaped deduplication")
    balanced()
    car.color=Color(35,105,210,200)
    wheel.color=Color(70,70,70,255)
    ghost.color=Color(190,60,25,128) ghost.GetColor4Part=nil -- Legacy Color getter path.
    local invisible=model("invisible","prop_vehicle_prisoner_pod",car) invisible.color=Color(255,255,255,0)
    car.children[#car.children+1]=invisible
    now=now+0.16 draw(false,false,false)
    assert(V.VisualReplacementEnabled() and counts.car==12 and counts.glide==12 and counts.ghost==12,
        "colored vehicle redraw stopped or lost its RGBA: "..tostring(lastError))
    assert(not counts.invisible,"zero-alpha vehicle seat drew invisible depth")
    car.color=Color(180,45,90,255) -- A live paint change inside the cached list.
    local beforePaintSearch=entitySearches
    draw(false,false,false)
    assert(V.VisualReplacementEnabled() and counts.car==13 and counts.glide==13 and counts.ghost==13,
        "live vehicle repaint stopped the compositor: "..tostring(lastError))
    assert(entitySearches==beforePaintSearch,"painting a vehicle forced entity rediscovery")
    assert(car.color.r==180 and wheel.color.r==70 and ghost.color.r==190,"redraw mutated an entity's stored paint")
    balanced()
    print("PASS: colored vehicles and wheels retain their own live RGB/alpha on manual redraw, repaint without cache invalidation, skip invisible seats and never leak tint to adjacent models")
    models=originalModels now=now+0.16
    print("PASS: parented Glide wheels and Simfphys ghost wheels redraw once, including client-only descendants; native Draw/paint/materials, hidden models and viewmodel trees are preserved with cached discovery")
    enabled=false
    local before=terrainDraws
    draw(false,false,false)
    assert(terrainDraws==before)
    enabled=true injectFailure="view" now=now+0.05
    draw(false,false,false)
    assert(reports==1 and not V.VisualReplacementEnabled())
    balanced()
    injectFailure=nil prepare()
    injectFailure="mesh"
    draw(false,false,false)
    assert(reports==2 and not V.VisualReplacementEnabled())
    balanced()
    injectFailure=nil V.SetVisualRegion(nil)
    assert(not V.VisualReplacementEnabled())
    -- Regression: an oblique outdoor camera sees side exits above a flat
    -- floor. Their large AABBs pass the camera frustum even though the native
    -- image already supplies every exterior pixel. Previously each exit
    -- triggered a full-map RenderView on every moving frame.
    camera=Vector(0,0,100) forward=Vector(1,0,-0.1):GetNormalized()
    prepare() now=now+0.05
    local previousOutdoor=renders
    pixel={depth=2000,stencil=0,color="native exterior"} draw(false,false,false)
    assert(renders>previousOutdoor,"outdoor regression did not exercise the previous full-view path")
    local viewsPerFrame=renders-previousOutdoor
    local oldSolid,oldOverlap=V.BSPSolid,V.BoundsOverlap
    V.BoundsOverlap=function(a,b,c,d) return a.x<=d.x and b.x>=c.x and a.y<=d.y and b.y>=c.y and a.z<=d.z and b.z>=c.z end
    V.BSPSolid=function(_,p) return p.z<0 end
    local oldOpening=V.BuildBoundaryOpening
    V.BuildBoundaryOpening=function(field,face,checkpoint)
        local bsp=field.bsp field.bsp=nil
        local vertices=oldOpening(field,face,checkpoint)
        field.bsp=bsp return vertices
    end
    local s=r.side/2
    local floor={vertices={Vector(-s,-s,0),Vector(s,-s,0),Vector(s,s,0),Vector(-s,s,0)},
        low=Vector(-s,-s,0),high=Vector(s,s,0)}
    r.bsp={faces={floor}}
    prepare()
    local outdoorViews=renders
    camera=Vector(0,0,100) forward=Vector(1,0,-0.1):GetNormalized()
    for i=1,24 do
        now=now+0.05 camera=camera+Vector(0,0.1,0)
        forward=Vector(math.cos(i*0.2),math.sin(i*0.2),-0.1):GetNormalized()
        pixel={depth=2000,stencil=0,color="native exterior"}
        draw(false,false,false)
        assert(pixel.color=="native exterior" and pixel.depth==2000,"native outdoor color/depth were cleared or replaced by exit-plane depth")
        balanced()
    end
    assert(renders==outdoorViews,"moving outdoor camera still re-renders full map through native air")
    fragment(1900,"exterior translucent")
    assert(pixel.color=="exterior translucent","native exterior translucency blocked by proxy depth")
    fragment(2100,"occluded effect")
    assert(pixel.color=="exterior translucent","original world depth was lost")
    pixel={depth=80,stencil=0,color="native prop inside cube"} draw(false,false,false)
    assert(pixel.color=="native prop inside cube" and pixel.depth==80,"native prop inside air region was cleared without a background view")
    -- New matter must render into the preserved native-air stencil as well.
    local floorMesh=r.chunks.one.mesh
    r.chunks.one.mesh={IsValid=function() return true end,Draw=function() terrainDraws=terrainDraws+1 fragment(50,"added voxel") end}
    pixel={depth=2000,stencil=0,color="native exterior"} draw(false,false,false)
    assert(pixel.color=="added voxel" and pixel.depth==50,"preserved native air prevents adding voxel matter")
    r.chunks.one.mesh=floorMesh
    forward=Vector(1,0,-0.1):GetNormalized()
    -- A real original wall between eye and exit still requires a secondary
    -- view, as does an eye excavated into the old solid BSP.
    local wall={vertices={Vector(50,-s,0),Vector(50,s,0),Vector(50,s,s),Vector(50,-s,s)},
        low=Vector(50,-s,0),high=Vector(50,s,s)}
    r.bsp={faces={floor,wall}} prepare() now=now+0.05
    pixel={depth=50,stencil=0,color="old wall"} draw(false,false,false)
    assert(renders>outdoorViews and pixel.color=="background","newly opened room behind native wall was incorrectly preserved")
    V.SetVisualRegion(nil) r.bsp=nil V.BSPSolid=oldSolid V.BoundsOverlap=oldOverlap V.BuildBoundaryOpening=oldOpening
    -- A vehicle's DrawModel may fail after assigning a native light origin.
    -- Cleanup must restore it before disabling the failed compositor.
    prepare() now=now+0.16
    local restore=V.RestoreVoxelPropLighting
    local light=V.LightVoxelProp
    local activeOrigin=false
    local broken=model("broken","base_glide")
    broken.DrawModel=function() assert(activeOrigin) error("injected vehicle Draw failure") end
    V.LightVoxelProp=function(_,ent) if ent==broken then activeOrigin=true return true end end
    V.RestoreVoxelPropLighting=function() activeOrigin=false end
    models={broken}
    draw(false,false,false)
    assert(not activeOrigin and not V.VisualReplacementEnabled(),"vehicle render error leaked a temporary light origin")
    balanced()
    V.RestoreVoxelPropLighting=restore V.LightVoxelProp=light models=originalModels
    V.SetVisualRegion(nil)
    print("PASS: vehicle DrawModel failure restores the temporary native lighting origin and balances the compositor state")
    print("PASS: outdoor view regression "..viewsPerFrame.." -> 0 secondary views/frame; 24 moving frames preserve native color/depth/translucency/props, added matter and views through removed walls")
    print("PASS: one native terrain pass, real main depth, no voxel RT projection and literal background viewport")
    print("PASS: camera rotations, near-plane coverage, foreground, cached openings and scoped render failures")
end
