local V=GVoxel
local receivers,hooks,commands={},{},{}
local reads={}
local meshes={}
local clock=0
local visual=nil
local activations=0
local sent,writing={},nil
local captures,allocations,reports=0,0,0
local lastError
local failMeshBuild=false
local target,lighting=nil,0
local tone=Vector(0.31,0.8,1.4)
local expectedCaptureTone=Vector(1,tone.y,tone.z)
IMAGE_FORMAT_RGBA16161616F=24
local captureFailure=false
local hitName="ground/test_grass"
local textured=true
local lastView=nil
CLIENT=true SERVER=false
function CreateClientConVar(_,default) return {GetFloat=function() return tonumber(default) end,GetInt=function() return 16 end,GetBool=function() return textured end} end
function CreateMaterial(name,shader,params) return {name=name,shader=shader,params=params} end
function Angle(pitch,yaw)
    local p,y=math.rad(pitch),math.rad(yaw)
    return {Forward=function() return Vector(math.cos(p)*math.cos(y),math.cos(p)*math.sin(y),-math.sin(p)) end,
        Right=function() return Vector(math.sin(y),-math.cos(y),0) end,
        Up=function() return Vector(math.sin(p)*math.cos(y),math.sin(p)*math.sin(y),math.cos(p)) end}
end

function Material(name)
    local texture={GetName=function() return name.."_base" end,Width=function() return 512 end,
        Height=function() return 256 end,IsError=function() return false end}
    return {IsError=function() return false end,GetTexture=function(_,key) return key=="$basetexture" and texture or nil end,
        GetString=function(_,key) if key=="$envmap" then return "maps/gm_construct/c0_0_0" end end,
        GetVector=function(_,key) if key=="$envmaptint" then return Vector(0.2,0.3,0.4) end end}
end
function GetRenderTargetEx(name,w,h,mode,depth,flags,unused,format)
    local lit=name:find("lit_snapshot",1,true)
    assert((w==256 or lit and w==512) and h==w and mode==RT_SIZE_LITERAL,"ground snapshot size is not bounded/literal")
    assert(bit.band(flags,12)==12,"snapshot edges wrap to the other side of the capture")
    if name:find("lit_snapshot",1,true) then assert(format==IMAGE_FORMAT_RGBA16161616F,"lit capture clips HDR to 8 bits") end
    allocations=allocations+1
    return {GetName=function() return name end,width=w,height=h}
end
util={CRC=function(name) return (name:gsub("[^%w]","_")) end,TraceLine=function(data)
    assert(data.mask==MASK_SOLID_BRUSHONLY and data.filter({IsWorld=function() return true end}))
    return {Hit=true,HitWorld=true,HitPos=Vector(data.start.x,data.start.y,0),HitNormal=Vector(0,0,1),
        HitTexture=type(hitName)=="function" and hitName(data.start) or hitName}
end}
function ErrorNoHalt(message) reports=reports+1 lastError=message end
render={GetRenderTarget=function() return target end,
    GetToneMappingScaleLinear=function() return Vector(tone.x,tone.y,tone.z) end,
    SetToneMappingScaleLinear=function(value) tone=value end,
    PushRenderTarget=function(rt) assert(not target,"recursive terrain capture") target=rt end,
    PopRenderTarget=function() assert(target) target=nil end,
    Clear=function() assert(target,"unscoped texture clear") end,
    SetLightingMode=function(mode) lighting=mode end,
    RenderView=function(view)
        assert(tone.x==1 and tone.y==(lighting==0 and expectedCaptureTone.y or 1)
            and tone.z==(lighting==0 and expectedCaptureTone.z or 1),
            "capture exposure overwrote the native lightmap/reflection scales")
        assert(target and V.CapturingSurface and V.RenderingReplacement and (lighting==0 or lighting==1))
        assert((target:GetName():find("lit_snapshot",1,true)~=nil)==(lighting==0),"lit BSP shadow capture was replaced by fullbright")
        assert(view.w==target.width and view.h==target.height and view.fov>=90 and view.fov<=140 and view.aspect==1 and view.znear==1)
        assert(not view.drawviewmodel and not view.drawviewer and not view.dopostprocess and not view.drawhud)
        assert(hooks["GVoxel.CaptureOpaque"]()==true and hooks["GVoxel.CaptureTranslucent"]()==true,
            "player/prop images may be baked into the ground")
        lastView=view captures=captures+1
        if captureFailure then error("injected ground capture failure") end
    end}
function Matrix() return {Translate=function() end} end
function SysTime() clock=clock+0.0001 return clock end
local captureRenderer=render
function Mesh(material)
    local mesh={dead=false,material=material}
    function mesh:IsValid() return not self.dead end
    function mesh:BuildFromTriangles(vertices)
        assert(not self.dead,"build after mesh destruction")
        if failMeshBuild then failMeshBuild=false error("injected native mesh build failure") end
        assert(not self.vertices or #self.vertices==#vertices,"rebuilt IMesh changed its native vertex count")
        self.vertices=vertices
    end
    function mesh:Destroy() assert(not self.dead,"mesh destroyed twice") self.dead=true end
    function mesh:Draw() assert(not self.dead,"draw after mesh destruction") end
    meshes[#meshes+1]=mesh
    return mesh
end

function RunExteriorCaptureFailureTests()
    local savedRender,savedContents,savedMaterial=render,util.PointContents,Material
    render=captureRenderer util.PointContents=nil
    Material=function(name) local mat=savedMaterial(name) mat.GetString=nil return mat end
    local r=V.NewScanRegion(197,Vector(),16)
    local tex={texture=1,u=Vector(1,0,0),v=Vector(0,1,0),uo=0,vo=0,
        lu=Vector(1/16,0,0),lv=Vector(0,1/16,0),luo=-r.origin.x/16,lvo=-r.origin.y/16,flags=0}
    local face={tex=tex,normal=Vector(0,0,1),lightOffset=0,lightMin={0,0},lightSize={8,8},lightStyles={0,255,255,255}}
    local bytes={}
    for y=0,8 do for x=0,8 do bytes[#bytes+1]=string.char(x*30,x*30,x*30,0) end end
    r.bsp={textures={{name="ground/test_grass",w=512,h=256}},lighting=table.concat(bytes)}
    V.BeginSurfaceCapture(r)
    local vertices={}
    for _,p in ipairs({Vector(20,20,40),Vector(20,100,40),Vector(100,20,40)}) do
        vertices[#vertices+1]={pos=p,normal=Vector(0,0,1),nativeFace=face}
    end
    local batches=V.BuildSurfaceBatches(r,{key="0:0:0",x=0,y=0,z=0},vertices)
    local source=r.surfaceList[1] local batch=batches[1] local mesh=batch.mesh
    assert(batch.baked and source.pendingBatches[1].fallback,"lightmap fallback was not prepared under the mesh budget")
    local white=Vector(1,1,1) source.voxelEnvironment={white,white,white,white,white,white}
    captureFailure=true hooks["GVoxel.CaptureGround"]() captureFailure=false
    assert(batch.mesh==mesh and batch.surfaceLight and batch.cutLighting and not batch.baked
        and batch.material==source.surfaceCut and batch.flashMaterial==source.interior,
        "failed capture did not reuse its mesh with local-lightmap colors and separate albedo")
    assert(mesh.vertices[1].color.r<mesh.vertices[3].color.r and not source.pendingBatches,
        "capture failure erased the native shadow gradient or retained fallback staging")
    assert(tone.x==0.31 and tone.y==0.8 and tone.z==1.4,"native fallback leaked capture exposure")
    mesh:Destroy() V.ReleaseSurfaceCapture(r)
    render=savedRender util.PointContents=savedContents Material=savedMaterial
    print("PASS: failed native capture atomically reuses precomputed local-lightmap fallback on the same mesh, keeps reflections separate and restores exposure")
end

function RunClientMeshLifecycleTests(reloadScan)
    local alias=Mesh()
    local chunk={mesh=alias,batches={{mesh=alias},{mesh=alias}}}
    V.ReleaseChunkMeshes(chunk) V.ReleaseChunkMeshes(chunk)
    assert(alias.dead and not chunk.mesh and not chunk.batches,"chunk retained released ownership")
    assert(V.DrawMesh(alias)==false,"released mesh was submitted for rendering")
    print("PASS: duplicate mesh aliases and repeated cleanup release once; invalid meshes never draw")

    local function begin(id)
        meshes={} lastError=nil
        local source=V.NewScanRegion(id,Vector(),16)
        for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(source,i) source.values[V.Index(x,y,z,source)]=p.z end
        reads={id,source.base,16} receivers.vm_scan_begin()
        reads={id,0,false} receivers.vm_scan_features()
        V.ForChunks(function(x,y,z)
            reads={id,x,y,z}
            for zz=z*8-1,z*8+9 do for yy=y*8-1,y*8+9 do for xx=x*8-1,x*8+9 do
                reads[#reads+1]=math.floor(V.Sample(source,xx,yy,zz)*64+0.5)
            end end end
            receivers.vm_scan_chunk()
        end,source)
        reads={id,2,255,100,0,1} receivers.vm_scan_progress()
        for _=1,4000 do hooks["GVoxel.CaptureGround"]() hooks["GVoxel.ScanMeshes"]() if visual then break end end
        return assert(V.GetClientScanRegion(),lastError)
    end
    local r=begin(91)
    local invalid
    for _,displayed in pairs(r.chunks) do if displayed.mesh then invalid=displayed.mesh break end end
    assert(invalid) invalid:Destroy() -- Reproduce an already released native mesh in the displayed region.
    assert(not V.DrawMesh(invalid))
    local errors,messages=reports,#sent
    failMeshBuild=true
    reads={91,1,Vector(0,0,-12),24,false,0} receivers.vm_scan_edit()
    for _=1,10000 do hooks["GVoxel.ScanMeshes"]() if reports>errors then break end end
    assert(reports==errors+1 and lastError:find("injected native mesh build failure",1,true),"lost original build failure")
    assert(not V.GetClientScanRegion() and not visual and not V.ClientSculptBusy() and not next(r.chunks),"failed scan retained render/work ownership")
    assert(#sent==messages+1 and sent[#sent].name=="vm_scan_failed","failed build did not report exactly once")
    for _=1,40 do hooks["GVoxel.ScanMeshes"]() end
    assert(reports==errors+1 and #sent==messages+1,"failed coroutine was retried every frame")
    for _,mesh in ipairs(meshes) do assert(mesh.dead,"failed build leaked a displayed or in-progress native mesh") end
    V.ReleaseClientScan() hooks["GVoxel.ReleaseScan"]()
    print("PASS: native build failure with an already destroyed visible mesh cancels once, frees staged allocation and never resumes a dead coroutine")

    r=begin(92)
    local count=#meshes
    reads={92,1,Vector(0,0,-12),24,false,0} receivers.vm_scan_edit()
    for _=1,10000 do hooks["GVoxel.ScanMeshes"]() if #meshes>count then break end end
    assert(#meshes>count and r.revision==0 and V.ClientSculptBusy(),"refresh fixture did not suspend an allocated mesh")
    local oldThink=hooks["GVoxel.ScanMeshes"]
    reloadScan()
    assert(hooks["GVoxel.ScanMeshes"]~=oldThink and not V.GetClientScanRegion() and not visual and not next(r.chunks),"refresh did not detach previous state")
    for _,mesh in ipairs(meshes) do assert(mesh.dead,"refresh leaked an old displayed/staged mesh") end
    for _=1,20 do oldThink() hooks["GVoxel.ScanMeshes"]() end
    V.ReleaseClientScan() hooks["GVoxel.ReleaseScan"]()
    print("PASS: reloading cl_scan during a suspended edit releases old resources; both old and new callbacks remain inert")
end

function RunClientBSPPreparationTests()
    local prepare,get,build=V.PrepareBSPRegion,V.GetBSPGeometry,V.BuildChunk
    local data,entered={},0
    V.GetBSPGeometry=function() return data,true end
    V.PrepareBSPRegion=function(r,d,checkpoint,sampling)
        assert(d==data and sampling==false,"client unnecessarily prepares terrain sampling columns")
        r.bsp=d -- Deliberately publish the same partial metadata as the real preparer.
        for _=1,3 do entered=entered+1 coroutine.yield() end
        error("cancelled preparation was resumed")
    end
    V.BuildChunk=function() error("mesh construction started with incomplete BSP metadata") end
    reads={94,Vector(),16} receivers.vm_scan_begin()
    reads={94,0,true} receivers.vm_scan_features()
    reads={94,0,0,0} for _=1,11^3 do reads[#reads+1]=64 end
    receivers.vm_scan_chunk()
    local errors,count=reports,#meshes
    for _=1,3 do hooks["GVoxel.ScanMeshes"]() end
    assert(entered==3 and reports==errors and #meshes==count and not visual,
        "client resumed meshing before cooperative BSP preparation finished")
    V.ReleaseClientScan() hooks["GVoxel.ScanMeshes"]()
    assert(reports==errors and not V.GetClientScanRegion(),"cancelled geometry preparation kept running")
    V.PrepareBSPRegion=prepare V.GetBSPGeometry=get V.BuildChunk=build
    print("PASS: partial BSP metadata cannot start client meshing; deferred geometry preparation resumes and cancels cleanly")
end

function RunClientLightingCancellationTests()
    local prepare=V.PrepareCutLighting
    local entered=0
    V.PrepareCutLighting=function()
        entered=entered+1 coroutine.yield()
        error("cancelled lighting preparation resumed")
    end
    local before=#sent
    reads={96,Vector(),16} receivers.vm_scan_begin()
    reads={96,0,false} receivers.vm_scan_features()
    V.ForChunks(function(x,y,z)
        reads={96,x,y,z} for _=1,11^3 do reads[#reads+1]=64 end
        receivers.vm_scan_chunk()
    end,V.GetClientScanState().region)
    reads={96,2,255,100,0,1} receivers.vm_scan_progress()
    for _=1,5000 do hooks["GVoxel.ScanMeshes"]() if entered>0 then break end end
    local state=V.GetClientScanState()
    assert(entered==1 and state.lightingJob and not state.region.cutLighting and not visual and #sent==before,
        "incomplete lighting activated or was not scheduled")
    V.ReleaseClientScan()
    for _=1,10 do hooks["GVoxel.ScanMeshes"]() end
    assert(not state.lightingJob and not V.GetClientScanState() and entered==1,"cancelled lighting job retained")
    V.PrepareCutLighting=prepare
    print("PASS: clearing a scan during suspended lighting preparation discards the coroutine without activation, ACK or resumption")
end
hook={Add=function(_,name,fn) hooks[name]=fn end,Remove=function(_,name) hooks[name]=nil end}
concommand={Add=function(name,fn) commands[name]=fn end}
local function read() return table.remove(reads,1) end
net={Receive=function(name,fn) receivers[name]=fn end,
    WriteBool=function(value) writing.values[#writing.values+1]=value end,
    ReadUInt=read,ReadInt=read,ReadVector=read,ReadFloat=read,ReadBool=read,
    Start=function(name) writing={name=name,values={}} end,WriteUInt=function(value) writing.value=writing.value or value writing.values[#writing.values+1]=value end,
    SendToServer=function() sent[#sent+1]=writing writing=nil end}
V.SetVisualRegion=function(r) visual=r if r then activations=activations+1 end end
chat={AddText=function() error("unexpected client desynchronization") end}

function RunSurfaceProjectionTests()
    local directions={Vector(1,0,0),Vector(-1,0,0),Vector(0,1,0),Vector(0,-1,0),Vector(0,0,1),Vector(0,0,-1)}
    local function vertices(normal,right,up)
        local center=Vector(78,78,78)
        local a,b,c=center-right*20-up*20,center+up*20,center+right*20-up*20
        return {{pos=a,normal=normal},{pos=b,normal=normal},{pos=c,normal=normal}}
    end
    for _,n in ipairs(directions) do
        local right=math.abs(n.z)>0.5 and Vector(0,-1,0) or Vector(n.y,-n.x,0)
        local up=n:Cross(right)
        local r=V.NewScanRegion(100,Vector(),16)
        V.BeginSurfaceCapture(r)
        local batches=V.BuildSurfaceBatches(r,{x=0,y=0,z=0,key="0:0:0"},vertices(n,right,up))
        assert(#r.surfaceList==1 and not V.SurfaceCaptureReady(r))
        local source=r.surfaceList[1]
        assert(source.frame.normal:Dot(n)>0.99999,"source capture direction is inverted")
        hooks["GVoxel.CaptureGround"]()
        assert(V.SurfaceCaptureReady(r) and not target and lighting==0 and not V.RenderingReplacement and not V.CapturingSurface)
        assert(tone.x==0.31 and tone.y==0.8 and tone.z==1.4,"capture changed the main view exposure")
        assert(not source.pendingBatches,"successful snapshot retained temporary vertex data")
        assert(batches[1].mesh.material.shader=="UnlitGeneric" and batches[1].mesh.material.params["$vertexcolor"]=="1",
            "capture mesh omitted the color stream needed by a local-lightmap fallback")
        local view=lastView
        local sample=source.center+source.frame.right*14+source.frame.up*11+n*3
        local q=sample-view.origin
        local depth=q:Dot(view.angles:Forward())
        local expectedU=0.5+q:Dot(view.angles:Right())/(2*depth)
        local expectedV=0.5-q:Dot(view.angles:Up())/(2*depth)
        local u,v=V.SurfaceUV(source,sample,n,true)
        assert(math.abs(u-expectedU)<1e-10 and math.abs(v-expectedV)<1e-10,"snapshot UVs mirror or drift from capture camera")
        assert(source.interior.params["$basetexture"]=="ground/test_grass_base","BSP base material not recovered")
        assert(source.surfaceCut.params["$envmap"]=="maps/gm_construct/c0_0_0"
            and source.surfaceCut.params["$envmaptint"]=="[0.2 0.3 0.4]"
            and not source.interiorCut.params["$envmap"] and not source.interior.params["$envmap"],
            "original finish leaked its cubemap into newly exposed soil or dynamic albedo")
        assert(source.interiorCut.shader=="UnlitGeneric" and source.interiorCut.params["$vertexcolor"]=="1"
            and source.interior.params["$vertexcolor"]=="0" and source.slot.cutMaterial.shader=="UnlitGeneric",
            "static gradients use a shader that ignores vertex colors or tint the dynamic-light albedo")
        assert(source.lightBounds and source.lightAnchor,"finite original face bounds/probe anchor discarded")
        assert(source.tileU==128 and source.tileV==64,"native texture dimensions lost")
        local a,b=V.SurfaceUV(source,Vector(0,0,0),Vector(1,0,0),false)
        local c,d=V.SurfaceUV(source,Vector(0,0,32),Vector(1,0,0),false)
        assert(math.abs(d-b)>0.1,"vertical cut walls collapse to a ground UV line")
        textured=false assert(V.SurfaceMaterial(batches[1])==V.ScanSurfaceMaterial) textured=true
        local sampled=vertices(n,right,up)
        for _,vertex in ipairs(sampled) do vertex.pos=vertex.pos+n*4 end
        local initial=V.BuildSurfaceBatches(r,{x=0,y=0,z=0,key="0:0:0"},sampled)
        assert(initial[1].baked,"original sampled terrain was misclassified as new underground soil")
        local edited=V.FeaturePointEdited
        V.FeaturePointEdited=function() return true end
        V.FreezeSurfaceSources(r)
        local excavated=V.BuildSurfaceBatches(r,{x=0,y=0,z=0,key="0:0:0"},sampled)
        assert(not excavated[1].baked,"a later excavation reused original-terrain classification")
        for _,batch in ipairs(initial) do batch.mesh:Destroy() end
        for _,batch in ipairs(excavated) do batch.mesh:Destroy() end
        local repaired=V.BuildSurfaceBatches(r,{x=0,y=0,z=0,key="0:0:0"},vertices(n,right,up))
        V.FeaturePointEdited=edited
        assert(repaired[1].baked and repaired[1].material==batches[1].material,
            "a coplanar patch around a hole discarded its original shadow/reflection capture")
        for _,batch in ipairs(repaired) do batch.mesh:Destroy() end
        for _,batch in ipairs(batches) do batch.mesh:Destroy() end
        V.ReleaseSurfaceCapture(r)
    end
    assert(allocations==2,"successive scans leaked paired snapshot targets instead of reusing their slots")
    -- The old 90-degree camera is beyond a ceiling. Its origin is FREE on the
    -- other side: contents at the camera alone cannot detect this occlusion.
    local room=V.NewScanRegion(106,Vector(),16)
    local floor=room.origin.z+78
    local nativeTrace=util.TraceLine
    util.PointContents=function(p)
        return (p.z<floor or (p.z>=floor+65 and p.z<=floor+70)) and CONTENTS_SOLID or 0
    end
    util.TraceLine=function(data)
        if data.start.z<floor+65 and data.endpos.z>=floor+65 then
            return {Hit=true,HitWorld=true,Fraction=(floor+65-data.start.z)/(data.endpos.z-data.start.z)}
        end
        return nativeTrace(data)
    end
    local roomVertices={}
    for _,p in ipairs({Vector(5,5,78),Vector(5,150,78),Vector(150,5,78)}) do
        roomVertices[#roomVertices+1]={pos=p,normal=Vector(0,0,1)}
    end
    V.BeginSurfaceCapture(room)
    local roomBatches=V.BuildSurfaceBatches(room,{x=0,y=0,z=0,key="0:0:0"},roomVertices)
    local camera=room.surfaceList[1]
    assert(not camera.failed and camera.cameraDistance<65 and camera.cameraFov>90,
        "enclosed camera did not move below the ceiling and widen its FOV before constructing UVs")
    hooks["GVoxel.CaptureGround"]()
    assert(not camera.failed and V.SurfaceCaptureReady(room) and roomBatches[1].baked)
    local view=lastView
    local tangent=math.tan(math.rad(view.fov/2))
    for _,p in ipairs(roomVertices) do
        local q=p.pos+room.origin-view.origin
        local depth=q:Dot(view.angles:Forward())
        local u,v=V.SurfaceUV(camera,p.pos+room.origin,Vector(0,0,1),true)
        assert(u>=0 and u<=1 and v>=0 and v<=1,"close camera cropped the original floor")
        assert(math.abs(u-(0.5+q:Dot(view.angles:Right())/(2*depth*tangent)))<1e-9
            and math.abs(v-(0.5-q:Dot(view.angles:Up())/(2*depth*tangent)))<1e-9,
            "adapted capture FOV no longer matches the mesh projection")
    end
    for _,batch in ipairs(roomBatches) do batch.mesh:Destroy() end
    V.ReleaseSurfaceCapture(room)
    util.PointContents=nil util.TraceLine=nativeTrace
    local slope=V.NewScanRegion(105,Vector(),16)
    V.BeginSurfaceCapture(slope)
    local n=Vector(1,0,1):GetNormalized()
    local slopeVertices=vertices(n,Vector(0,-2.5,0),n:Cross(Vector(0,-2.5,0)))
    local slopeBatches=V.BuildSurfaceBatches(slope,{x=0,y=0,z=0,key="0:0:0"},slopeVertices)
    assert(#slopeBatches==1 and slopeBatches[1].baked,"steep original surface incorrectly classified as a cut wall")
    assert(slope.surfaceList[1].cameraDistance>slope.step*4+4,"steep capture did not fit its near edge")
    for _,batch in ipairs(slopeBatches) do for _,vertex in ipairs(batch.mesh.vertices) do
        assert(vertex.u>=0 and vertex.u<=1 and vertex.v>=0 and vertex.v<=1,"ramp capture still cropped")
    end batch.mesh:Destroy() end
    V.ReleaseSurfaceCapture(slope)
    local corner=V.NewScanRegion(103,Vector(),16)
    V.BeginSurfaceCapture(corner)
    local both=vertices(Vector(0,0,1),Vector(0,-1,0),Vector(1,0,0))
    for _,vertex in ipairs(vertices(Vector(1,0,0),Vector(0,1,0),Vector(0,0,1))) do both[#both+1]=vertex end
    local cornerBatches=V.BuildSurfaceBatches(corner,{x=0,y=0,z=0,key="0:0:0"},both)
    assert(#corner.surfaceList==2 and #cornerBatches==2,"a floor and wall in one chunk share an incorrect single capture")
    for _,batch in ipairs(cornerBatches) do assert(batch.baked and batch.material.shader=="UnlitGeneric") batch.mesh:Destroy() end
    V.ReleaseSurfaceCapture(corner)
    -- Two cuts in one capture patch must recover their local material, even
    -- though the same snapshot contains both ground appearances.
    local mixed=V.NewScanRegion(102,Vector(),16)
    V.BeginSurfaceCapture(mixed)
    local batches=V.BuildSurfaceBatches(mixed,{x=0,y=0,z=0,key="0:0:0"},vertices(Vector(0,0,1),Vector(0,-1,0),Vector(1,0,0)))
    V.FreezeSurfaceSources(mixed)
    local source=mixed.surfaceList[1]
    hitName=function(p) return p.x<source.center.x and "ground/grass" or "ground/concrete" end
    local cut={}
    for _,x in ipairs({30,120}) do
        local triangle={Vector(x,40,30),Vector(x,40,50),Vector(x,60,30)}
        for _,p in ipairs(triangle) do cut[#cut+1]={pos=p,normal=Vector(1,0,0)} end
    end
    local cutBatches=V.BuildSurfaceBatches(mixed,{x=0,y=0,z=0,key="0:0:0"},cut)
    assert(#cutBatches==2,"different cut-wall materials merged into one batch")
    local recovered={}
    for _,batch in ipairs(cutBatches) do recovered[batch.material.params["$basetexture"]]=true batch.mesh:Destroy() end
    assert(recovered["ground/grass_base"] and recovered["ground/concrete_base"],"local ground material boundary lost")
    local crossing={{pos=Vector(20,40,20),normal=Vector(0,0,1)},
        {pos=Vector(130,40,20),normal=Vector(0,0,1)},{pos=Vector(20,120,20),normal=Vector(0,0,1)}}
    local split=V.BuildSurfaceBatches(mixed,{x=0,y=0,z=0,key="0:0:0"},crossing)
    local area,count=0,0
    for _,batch in ipairs(split) do
        local list=batch.mesh.vertices
        for i=1,#list,3 do
            area=area+math.sqrt((list[i+1].pos-list[i].pos):Cross(list[i+2].pos-list[i].pos):LengthSqr())/2
            count=count+1
        end
        batch.mesh:Destroy()
    end
    assert(#split==2 and count>1 and math.abs(area-4400)<1e-6,"material-boundary subdivision changed geometry or kept one material per large triangle")
    for _,batch in ipairs(batches) do batch.mesh:Destroy() end
    V.ReleaseSurfaceCapture(mixed)
    local r=V.NewScanRegion(101,Vector(),16)
    V.BeginSurfaceCapture(r) hitName="**displacement**"
    local batches=V.BuildSurfaceBatches(r,{x=0,y=0,z=0,key="0:0:0"},vertices(Vector(0,0,1),Vector(0,-1,0),Vector(1,0,0)))
    assert(not r.surfaceList[1].interior,"displacement marker was loaded as a material")
    captureFailure=true hooks["GVoxel.CaptureGround"]() captureFailure=false hitName="ground/test_grass"
    assert(reports==1 and V.SurfaceCaptureReady(r) and r.surfaceFailed==1,"failed snapshot blocked terrain forever")
    assert(not target and lighting==0 and not V.CapturingSurface and not V.RenderingReplacement,"capture exception leaked render state")
    assert(tone.x==0.31 and tone.y==0.8 and tone.z==1.4,"failed capture leaked its fixed exposure")
    assert(V.SurfaceMaterial(batches[1])==V.ScanSurfaceMaterial,"failed snapshot left an uninitialized texture")
    for _,batch in ipairs(batches) do batch.mesh:Destroy() end
    V.ReleaseSurfaceCapture(r)
    local enclosed=V.NewScanRegion(104,Vector(),16)
    V.BeginSurfaceCapture(enclosed)
    local enclosedBatches=V.BuildSurfaceBatches(enclosed,{x=0,y=0,z=0,key="0:0:0"},vertices(Vector(0,0,1),Vector(0,-1,0),Vector(1,0,0)))
    local beforeCaptures=captures
    util.PointContents=function() return CONTENTS_SOLID end
    hooks["GVoxel.CaptureGround"]()
    util.PointContents=nil
    assert(captures==beforeCaptures and enclosed.surfaceFailed==1,"camera inside BSP baked a black/invalid image")
    assert(reports==1,"expected BSP obstruction emitted another Lua error/traceback")
    assert(V.SurfaceMaterial(enclosedBatches[1]).shader=="VertexLitGeneric","invalid capture lost native material fallback")
    assert(not enclosedBatches[1].baked and not enclosed.surfaceList[1].pendingBatches,
        "fallback kept baked lighting or retained temporary vertex data")
    for _,vertex in ipairs(enclosedBatches[1].mesh.vertices) do
        local u,v=V.SurfaceUV(enclosed.surfaceList[1],vertex.pos+enclosed.origin,vertex.normal,false)
        assert(vertex.u==u and vertex.v==v,"native fallback uses perspective snapshot UVs instead of tiled wall UVs")
    end
    assert(not target and lighting==0 and not V.CapturingSurface and not V.RenderingReplacement)
    for _,batch in ipairs(enclosedBatches) do batch.mesh:Destroy() end
    V.ReleaseSurfaceCapture(enclosed)
    -- Detect an impossible camera before allocating a pair or baking UVs.
    local blocked=V.NewScanRegion(107,Vector(),16)
    local beforeAllocations=allocations
    util.PointContents=function() return CONTENTS_SOLID end
    V.BeginSurfaceCapture(blocked)
    local blockedBatches=V.BuildSurfaceBatches(blocked,{x=0,y=0,z=0,key="0:0:0"},roomVertices)
    util.PointContents=nil
    assert(V.SurfaceCaptureReady(blocked) and blocked.surfaceFailed==1 and allocations==beforeAllocations)
    assert(not blockedBatches[1].baked and blockedBatches[1].material.shader=="VertexLitGeneric",
        "obstructed source was queued with invalid capture UVs")
    for _,batch in ipairs(blockedBatches) do batch.mesh:Destroy() end
    V.ReleaseSurfaceCapture(blocked)
    local layered=V.NewScanRegion(108,Vector(),16)
    layered.bsp={textures={{name="road/asphalt",w=512,h=256},{name="ground/soil",w=128,h=64}}}
    local planes,layerVertices={},{}
    for layer=1,2 do
        local face={tex={texture=layer,u=Vector(0,2,0),v=Vector(-4,0,0),uo=13,vo=-29}}
        planes[layer]=face
        for _,p in ipairs({Vector(20,20,40+layer*12),Vector(20,120,40+layer*12),Vector(120,20,40+layer*12)}) do
            layerVertices[#layerVertices+1]={pos=p,normal=Vector(0,0,1),nativeFace=face}
        end
    end
    hitName="**displacement**"
    util.PointContents=function() return CONTENTS_SOLID end -- force native fallback, no screenshot dependency
    V.BeginSurfaceCapture(layered)
    local layerBatches=V.BuildSurfaceBatches(layered,{x=0,y=0,z=0,key="0:0:0"},layerVertices)
    util.PointContents=nil hitName="ground/test_grass"
    assert(#layered.surfaceList==2 and #layerBatches==2,"parallel floors merged into an averaged capture plane")
    local seen={}
    for _,source in ipairs(layered.surfaceList) do
        local index=source.nativeFace.tex.texture local tex=layered.bsp.textures[index]
        assert(source.materialName==tex.name,"BSP material ignored in favour of trace displacement marker")
        assert(math.abs(source.point.z-layered.origin.z-40-index*12)<1e-8,"layer capture anchored at the wrong height")
        seen[index]=true
        local point=Vector(17,25,40)
        local u,v=V.SurfaceUV(source,point,Vector(0,0,1),false)
        assert(math.abs(u-(50+13)/tex.w)<1e-10 and math.abs(v-(-68-29)/tex.h)<1e-10,"compiled texture rotation, scale or offset lost")
        local _,v1=V.SurfaceUV(source,Vector(0,0,0),Vector(1,0,0),false)
        local _,v2=V.SurfaceUV(source,Vector(0,0,20),Vector(1,0,0),false)
        assert(math.abs(v2-v1)>0.01,"native top texture collapses on a vertical cut")
    end
    assert(seen[1] and seen[2])
    for _,batch in ipairs(layerBatches) do batch.mesh:Destroy() end
    V.ReleaseSurfaceCapture(layered)
    print("PASS: parallel floors retain distinct BSP materials and capture heights; displacement marker bypassed; native UV rotation/scale/offset retained")
    print("PASS: paired captures, six projections, occluded/solid camera planning, FOV-correct UVs, tiled fallback, materials, pooling and scoped failures")
    local retired=V.NewScanRegion(109,Vector(),16)
    V.BeginSurfaceCapture(retired)
    local pending=V.BuildSurfaceBatches(retired,{x=0,y=0,z=0,key="0:0:0"},vertices(Vector(0,0,1),Vector(0,-1,0),Vector(1,0,0)))
    V.ReleaseChunkMeshes({batches=pending})
    captureFailure=true hooks["GVoxel.CaptureGround"]() captureFailure=false
    assert(V.SurfaceCaptureReady(retired) and retired.surfaceFailed==1,"retired pending batch broke texture fallback")
    V.ReleaseSurfaceCapture(retired)
    print("PASS: texture fallback skips retired batches instead of rebuilding a destroyed mesh")
end

function RunSurfaceResolutionTests()
    local eyeBefore=EyePos
    EyePos=function() return Vector(0,0,300) end
    local r=V.NewScanRegion(7300,Vector(),16)
    V.BeginSurfaceCapture(r)
    local vertices={{pos=Vector(20,20,78),normal=Vector(0,0,1)},
        {pos=Vector(20,100,78),normal=Vector(0,0,1)},
        {pos=Vector(100,20,78),normal=Vector(0,0,1)}}
    local meshesToFree={}
    for i=1,130 do
        local batches=V.BuildSurfaceBatches(r,{x=0,y=0,z=0,key="resolution:"..i},vertices)
        for _,batch in ipairs(batches) do meshesToFree[#meshesToFree+1]=batch.mesh end
    end
    local hd,standard,bytes,seen=0,0,0,{}
    for _,source in ipairs(r.surfaceList) do if not source.uncaptured then
        assert(not seen[source.slotIndex],"capture slot leased twice") seen[source.slotIndex]=true
        if source.slot.size==512 then hd=hd+1 else standard=standard+1 end
        bytes=bytes+source.slot.size^2*8+256^2*4
    end end
    assert(hd==64 and standard==64 and bytes==192*1024*1024 and r.surfaceFailed==2,
        "HD pool exceeded its slot/memory cap or discarded the standard fallback")
    for _=1,128 do hooks["GVoxel.CaptureGround"]() end
    assert(V.SurfaceCaptureReady(r),"HD/standard captures did not finish at one source per frame")
    for _,mesh in ipairs(meshesToFree) do mesh:Destroy() end
    V.ReleaseSurfaceCapture(r)
    local before=allocations
    local far=V.NewScanRegion(7301,Vector(),16) V.BeginSurfaceCapture(far)
    EyePos=function() return Vector(0,0,10000) end
    local batches=V.BuildSurfaceBatches(far,{x=0,y=0,z=0,key="far"},vertices)
    assert(far.surfaceList[1].slot.size==256,"distant source took a priority HD slot")
    hooks["GVoxel.CaptureGround"]()
    assert(allocations==before,"successive HD scan leaked immutable render targets")
    for _,batch in ipairs(batches) do batch.mesh:Destroy() end
    V.ReleaseSurfaceCapture(far) EyePos=eyeBefore
    print("PASS: near surfaces use 512px baked captures; bounded 64 HD/64 standard pool stores 192 MiB colours, falls back at saturation and reuses targets across scans")
end

function RunSurfaceExposureTests()
    local savedTone,savedExpected=tone,expectedCaptureTone
    local vertices={{pos=Vector(20,20,78),normal=Vector(0,0,1)},
        {pos=Vector(20,100,78),normal=Vector(0,0,1)},
        {pos=Vector(100,20,78),normal=Vector(0,0,1)}}
    for i,input in ipairs({Vector(0.25,16,8),Vector(2,16,8),Vector(1,1,1)}) do
        tone=input expectedCaptureTone=Vector(1,input.y,input.z)
        local r=V.NewScanRegion(7310+i,Vector(),16) V.BeginSurfaceCapture(r)
        local batches=V.BuildSurfaceBatches(r,{x=0,y=0,z=0,key="0:0:0"},vertices)
        for _=1,#r.surfaceList do hooks["GVoxel.CaptureGround"]() end
        local source=r.surfaceList[1]
        assert(source.ready and not source.failed,"native exposure capture failed: "..tostring(lastError))
        assert(tone.x==input.x and tone.y==input.y and tone.z==input.z,"capture changed the main view exposure")
        for _,value in ipairs({0,0.01,0.1,0.25,0.8,2}) do
            -- Source's UnlitGeneric enables sRGB reads unless gammacolorread
            -- is set. A float capture already contains linear scene radiance.
            local read=source.slot.litMaterial.params["$gammacolorread"]=="1" and value
                or (value<=0.04045 and value/12.92 or ((value+0.055)/1.055)^2.4)
            assert(math.abs(read-value)<1e-9,"linear captured shadows are gamma-decoded a second time")
        end
        assert(source.slot.material.params["$gammacolorread"]~="1"
            and source.slot.cutMaterial.params["$gammacolorread"]~="1","sRGB albedo decoding was disabled")
        for _,batch in ipairs(batches) do batch.mesh:Destroy() end
        V.ReleaseSurfaceCapture(r)
    end
    tone=savedTone expectedCaptureTone=savedExpected
    print("PASS: initial captures preserve native lightmap/reflection scales at different exposures; linear HDR shadows/HDR values round-trip without decoding albedo incorrectly")
end

function RunClientCustomBlockTests()
    V.ReleaseClientScan()
    local source=assert(V.NewCustomScanRegion(2510,Vector(-150,-100,-60),Vector(250,100,40)))
    for z=0,source.cells.z do for y=0,source.cells.y do for x=0,source.cells.x do
        local p=source.origin+Vector(x,y,z)*source.step source.values[V.Index(x,y,z,source)]=p.z
    end end end
    reads={source.id,source.base,0,source.origin,source.step,source.cells.x,source.cells.y,source.cells.z}
    receivers.vm_scan_begin()
    local region=V.GetClientScanState().region
    assert(region.custom and region.origin:DistToSqr(source.origin)<1e-8
        and region.extent:DistToSqr(source.extent)<1e-8 and region.step==source.step,"client decoded a custom box as a cube")
    reads={source.id,0,false} receivers.vm_scan_features()
    V.ForChunks(function(x,y,z)
        reads={source.id,x,y,z}
        for zz=z*8-1,z*8+9 do for yy=y*8-1,y*8+9 do for xx=x*8-1,x*8+9 do
            reads[#reads+1]=math.floor(V.Sample(source,xx,yy,zz)*64+0.5)
        end end end
        receivers.vm_scan_chunk()
    end,source)
    reads={source.id,2,255,100,0,1} receivers.vm_scan_progress()
    for _=1,5000 do hooks["GVoxel.CaptureGround"]() hooks["GVoxel.ScanMeshes"]() if V.GetClientScanRegion() then break end end
    assert(V.GetClientScanRegion()==region and region.revision==0,lastError or "custom client never became ready")
    local p=Vector(0,0,0)
    reads={source.id,1,p,60,false,713,false} receivers.vm_scan_prepare()
    for _=1,1500 do hooks["GVoxel.ScanMeshes"]() end
    assert(region.revision==0 and visual==region,"custom preparation published before its server permit")
    reads={source.id,1,p,60,false,713,false} receivers.vm_scan_edit()
    for _=1,5000 do hooks["GVoxel.ScanMeshes"]() if region.revision==1 then break end end
    assert(region.revision==1,"custom prepared edit did not publish")
    V.ApplyBrush(source,p,60,false,713)
    for z=0,source.cells.z do for y=0,source.cells.y do for x=0,source.cells.x do
        local key=V.Index(x,y,z,source)
        assert(region.values[key]==source.values[key],"custom client crater differs from authoritative replay")
    end end end
    V.ReleaseClientScan()
    print("PASS: actual client custom metadata/chunks decode rectangular bounds, finish mesh/collision/captures, keep private preparation hidden, publish on permit and replay identical seeded density")
end

function RunClientEditTests()
    meshes={} captures=0 lastError=nil
    local prepareLighting,lightingSlices=V.PrepareCutLighting,0
    V.PrepareCutLighting=function(region)
        assert(V.SurfaceCaptureReady(region),"lighting prepared before original captures completed")
        for _=1,3 do
            assert(not visual and #sent==0,"scan activated/ACKed before its lighting index")
            lightingSlices=lightingSlices+1 coroutine.yield()
        end
        region.cutLighting={sourceCount=0} -- Other tests here concern geometry.
    end
    local source=V.NewScanRegion(31,Vector(),16)
    for i=0,33^3-1 do
        local p,x,y,z=V.ScanPoint(source,i)
        source.values[V.Index(x,y,z,source)]=math.floor(p.z*64+0.5)/64
    end
    reads={31,source.base,16} receivers.vm_scan_begin()
    reads={31,0} receivers.vm_scan_features()
    V.ForChunks(function(x,y,z)
        reads={31,x,y,z}
        for zz=z*8-1,z*8+9 do for yy=y*8-1,y*8+9 do for xx=x*8-1,x*8+9 do
            reads[#reads+1]=math.floor(V.Sample(source,xx,yy,zz)*64+0.5)
        end end end
        receivers.vm_scan_chunk()
    end,source)
    reads={31,2,255,100,215622,1} receivers.vm_scan_progress()
    assert(not V.GetClientScanRegion() and not visual,"partial initial mesh exposed for editing")
    for _=1,100 do hooks["GVoxel.ScanMeshes"]() end
    assert(not visual and #sent==0,"terrain/collisions activated before its ground snapshots")
    for _=1,4000 do hooks["GVoxel.CaptureGround"]() hooks["GVoxel.ScanMeshes"]() if visual then break end end
    local r=V.GetClientScanRegion()
    assert(r and r==visual and activations==1,"completed scan not activated exactly once")
    assert(lightingSlices==3 and not V.GetClientScanState().lightingJob,"lighting preparation was skipped or retained after completion")
    V.PrepareCutLighting=prepareLighting
    print("PASS: scan waits for cooperative lighting preparation after captures, publishes and ACKs only when lighting is complete")
    assert(#sent==1 and sent[1].name=="vm_scan_ready" and sent[1].value==31,"collision readiness not acknowledged after full reconstruction")
    assert(V.CollisionCacheStats(r).cells>32^3/2,"client scan did not prepare the full collision volume")
    assert(r.surfaceFrozen and #r.surfaceList==16 and captures==32,"flat terrain did not capture its original 16 lit/albedo surface pairs")
    local slots=allocations
    local sourceCount=#r.surfaceList
    local values=r.values
    local farCell=V.Index(22,22,15,r)
    local farVertices=r.terrainCache.renderCells["2:2:1"][farCell]
    local farMaterial=r.terrainCache.surfaceCells["2:2:1"][farCell]
    assert(farVertices and farMaterial,"initial rendering did not retain cell vertex/material data")
    local oldMeshes={}
    for _,mesh in ipairs(meshes) do oldMeshes[#oldMeshes+1]=mesh end
    local function receiveStroke(revision,center,radius,adding,seed)
        local dirty=V.ApplyBrush(source,center,radius,adding,seed)
        reads={31,revision,center,radius,adding,seed or 0} receivers.vm_scan_edit()
        return dirty
    end
    local beforePrepare=#meshes local beforeMessages=#sent
    reads={31,1,Vector(0,0,-12),24,false,0} receivers.vm_scan_prepare()
    for _=1,2000 do hooks["GVoxel.ScanMeshes"]() end
    assert(r.revision==0 and #sent==beforeMessages and #meshes>beforePrepare and V.ClientSculptBusy(),
        "speculative preparation published a hole or did not prepare privately")
    reads={31,1} receivers.vm_scan_abort()
    assert(r.revision==0 and not V.ClientSculptBusy(),"aborted server physics retained speculative client work")
    for i=beforePrepare+1,#meshes do assert(meshes[i].dead,"aborted preparation leaked a mesh") end
    local center=V.SnapScanPosition(Vector(0,0,-14.4))
    reads={31,1,center,48,false,0} receivers.vm_scan_prepare()
    for _=1,2000 do hooks["GVoxel.ScanMeshes"]() end
    assert(r.revision==0 and r.values==values and not r.modifiedChunks,"stroke field/index committed before all meshes")
    for _,mesh in ipairs(oldMeshes) do assert(not mesh.dead,"visible mesh destroyed during partial stroke") end
    local preparedMeshes=#meshes
    receiveStroke(1,center,48,false)
    hooks["GVoxel.ScanMeshes"]()
    assert(#meshes==preparedMeshes,"publication permit rebuilt the already prepared hole")
    print("PASS: parallel client preparation stays private until physics permit; abort frees meshes; finished geometry publishes and ACKs in one Think")
    assert(r.revision==1 and r.values~=values,"atomic stroke never committed")
    assert(sent[#sent].name=="vm_scan_ready" and sent[#sent].values[2]==1,"first displayed hole was not acknowledged")
    assert(r.modifiedChunks and next(r.modifiedChunks),"modified movement index missing from committed field")
    assert(V.CollisionCacheStats(r).cells>32^3/2,"displayed hole still waits for dirty-chunk collision preparation")
    assert(r.terrainCache.renderCells["2:2:1"][farCell]==farVertices and r.terrainCache.surfaceCells["2:2:1"][farCell]==farMaterial,
        "a local hole regenerated distant vertices/UVs/material choices in the same dirty chunk")
    for i,value in ipairs(source.values) do assert(r.values[i]==value,"client field does not match server stroke") end
    local hit=V.TraceScanRegion(r,Vector(0,0,100),Vector(0,0,-1),320)
    assert(hit and hit.HitPos.z< -10,"client targeting did not follow rebuilt hole")
    local originalBuild=V.BuildChunk
    local builds={}
    V.BuildChunk=function(field,x,y,z,...)
        local key=V.ChunkKey(x,y,z) builds[key]=(builds[key] or 0)+1
        return originalBuild(field,x,y,z,...)
    end
    local dirtyA=receiveStroke(2,V.SnapScanPosition(Vector(0,0,-5)),48,true)
    local dirtyB=receiveStroke(3,V.SnapScanPosition(Vector(25,0,-30)),48,false)
    for _=1,200 do
        hooks["GVoxel.ScanMeshes"]()
        assert(r.revision~=2,"coalesced strokes exposed an unnecessary intermediate mesh")
        if r.revision==3 then break end
    end
    V.BuildChunk=originalBuild
    for key in pairs(dirtyA) do assert(builds[key]==1,"overlapping queued strokes rebuilt the same chunk twice") end
    for key in pairs(dirtyB) do assert(builds[key]==1,"coalesced dirty chunk was missed/rebuilt twice") end
    assert(r.revision==3 and activations==1,"queued strokes did not commit sequentially")
    assert(sent[#sent].values[2]==3 and V.CollisionCacheStats(r).cells>32^3/2,
        "later displayed revision did not acknowledge its field without collision precache")
    for _,chunk in pairs(r.chunks) do
        if chunk.batches then assert(chunk.lightOrigin.z>0,"underground cut inherited an unlit probe inside original BSP") end
    end
    hooks["GVoxel.CaptureGround"]()
    assert(captures==32 and allocations==slots and #r.surfaceList==sourceCount,"sculpting recaptured or reallocated original ground textures")
    for i,value in ipairs(source.values) do assert(r.values[i]==value,"queued edits diverged from server field") end
    print("PASS: real client snapshot/brush handlers, atomic mesh swaps and ordered field updates")
    print("PASS: ordered queued strokes coalesce into one dirty-chunk rebuild without an intermediate revision")
    local progressed=false
    for revision=4,43 do
        receiveStroke(revision,V.SnapScanPosition(Vector((revision%7)*3-10,0,-20-(revision%5)*2)),48,false)
        -- Keep arrivals continuous and faster than the real tool (4 Hz),
        -- while allowing several render slices per stroke. The fake clock
        -- charges 0.1 ms for every budget poll.
        for _=1,4 do hooks["GVoxel.ScanMeshes"]() end
        if r.revision>3 then progressed=true end
    end
    assert(progressed,"holding dig indefinitely restarts the in-flight mesh before displaying any change")
    for _=1,2000 do hooks["GVoxel.ScanMeshes"]() if r.revision==43 then break end end
    assert(r.revision==43,"continuous-stroke backlog did not drain")
    assert(V.CollisionCacheStats(r).cells>32^3/2,"continuous strokes discarded unchanged prepared cells")
    for i,value in ipairs(source.values) do assert(r.values[i]==value,"continuous-stroke snapshots lost/reordered a brush") end
    print("PASS: visible progress during 40 continuously arriving strokes; ordered backlog drains without field/mesh mismatch")
    receiveStroke(44,V.SnapScanPosition(Vector(80,0,0)),112,false,913)
    assert(r.revision==43,"RPG crater committed directly in the network receiver")
    for _=1,4000 do hooks["GVoxel.ScanMeshes"]() if r.revision==44 then break end end
    assert(r.revision==44 and sent[#sent].values[2]==44 and V.CollisionCacheStats(r).cells>32^3/2,
        "client RPG crater did not commit without eager collision work: revision "..r.revision..", cells "..V.CollisionCacheStats(r).cells..", error "..tostring(lastError))
    for i,value in ipairs(source.values) do assert(r.values[i]==value,"client RPG seed or radius lost during replay") end
    assert(captures==32 and allocations==slots,"RPG recaptured original ground textures")
    print("PASS: real client network receiver replays seeded RPG crater under budget and acknowledges its atomic mesh/collision swap")
    local tankCenter,tankFloor=V.SnapScanPosition(Vector(-40,0,-32)),-64.125
    local beforeTank=#sent
    V.ApplyBrush(source,tankCenter,300,false,0,nil,tankFloor)
    reads={31,45,tankCenter,300,false,0,true,tankFloor} receivers.vm_scan_prepare()
    for _=1,6000 do hooks["GVoxel.ScanMeshes"]() end
    assert(r.revision==44 and #sent==beforeTank,"clipped tank preparation published without permission")
    local preparedTank=#meshes
    reads={31,45,tankCenter,300,false,0,true,tankFloor} receivers.vm_scan_edit()
    hooks["GVoxel.ScanMeshes"]()
    assert(r.revision==45 and sent[#sent].values[2]==45 and #meshes==preparedTank,
        "tank permit rebuilt/lost its prepared mesh")
    for i,value in ipairs(source.values) do assert(r.values[i]==value,"clipped tank floor/radius differed on client replay") end
    assert(captures==32 and allocations==slots,"tank shell recaptured BSP surface textures")
    print("PASS: client privately prepares a 300-SU shell with fractional preserved floor; publication atomically swaps identical field/mesh without a second rebuild")
    receiveStroke(46,V.SnapScanPosition(Vector(210,0,-90)),48,false)
    local meshCount=#meshes
    for _=1,100 do hooks["GVoxel.ScanMeshes"]() if #meshes>meshCount then break end end
    assert(r.revision==45 and #meshes>meshCount,"cancellation fixture did not suspend an allocated/staged mesh")
    commands.vm_scan_clear()
    assert(visual and V.GetClientScanRegion(),"client removed terrain before server could evacuate the player")
    reads={31,3,0,0,0,0} receivers.vm_scan_progress()
    assert(not visual and not V.GetClientScanRegion(),"cleared scan still visible/targetable")
    for _,mesh in ipairs(meshes) do assert(mesh.dead,"cleared scan leaked a visible or staged mesh") end
    local replacement=V.NewScanRegion(32,Vector(),16)
    V.BeginSurfaceCapture(replacement)
    local vertices=V.BuildChunk(source,0,0,1)
    local batches=V.BuildSurfaceBatches(replacement,{x=0,y=0,z=1,key="0:0:1"},vertices)
    assert(replacement.surfaceList[1].slotIndex==1,"cleared scan left its first texture slot reserved")
    for _,batch in ipairs(batches) do batch.mesh:Destroy() end
    V.ReleaseSurfaceCapture(replacement)
    print("PASS: canceling a partial client stroke frees both staged and displayed meshes")
    print("PASS: captured textures gate activation, survive atomic sculpting and release pooled slots on clear")
end
