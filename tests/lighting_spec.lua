-- Core lighting: preserve the original capture and bound work on new cuts.
local V=GVoxel
local now,frame=200,0
local material,draws,queries,dynamicQueries=nil,0,0,0
local dynamicAmount=0
local black=false
local lights={}
local suppressed=false
local additive=false
local originalClientsideModel=ClientsideModel
local originalVehicleRoot=V.GetVoxelVehicleRoot
local originalNull=NULL
NULL=NULL or {valid=false}
local anchorCreates,anchorRemoves=0,0
local anchors={}
function ClientsideModel(model,group)
    anchorCreates=anchorCreates+1
    local anchor={model=model,group=group,valid=true,pos=Vector()}
    function anchor:SetNoDraw(value) self.hidden=value end
    function anchor:GetNoDraw() return self.hidden==true end
    function anchor:SetPos(point) self.pos=Vector(point.x,point.y,point.z) end
    function anchor:GetPos() return self.pos end
    function anchor:Spawn() end
    function anchor:Remove()
        assert(self.valid,"lighting anchor removed twice")
        self.valid=false anchorRemoves=anchorRemoves+1
    end
    anchors[#anchors+1]=anchor
    return anchor
end
V.GetVoxelVehicleRoot=function(ent) return ent.vehicleRoot or (ent.vehicle and ent or nil) end
local function vehicle(point,region)
    local ent={valid=true,vehicle=true,point=point,lightOrigin=NULL,lightOriginWrites=0}
    function ent:WorldSpaceCenter() return self.point end
    function ent:GetNW2Int() return region.id end
    function ent:GetLightingOriginEntity() return self.lightOrigin end
    function ent:SetLightingOriginEntity(value) self.lightOrigin=value self.lightOriginWrites=self.lightOriginWrites+1 end
    return ent
end
BLEND_ONE=1 BLENDFUNC_ADD=0
local originalBaked=V.SurfaceUsesBaked
V.SurfaceUsesBaked=function(batch) return batch.baked end
function CreateClientConVar() error("core lighting introduced extra controls") end
function FrameNumber() return frame end
function RealTime() return now end
util.PointContents=function(p) return p.z<0 and CONTENTS_SOLID or 0 end
util.GetSunInfo=function() error("removed solar shading still runs") end
local oldTrace=V.TraceScanRegion
V.TraceScanRegion=function() error("lighting still traces voxel geometry") end
render={
    ComputeLighting=function() queries=queries+1 return black and Vector(dynamicAmount,dynamicAmount,dynamicAmount) or Vector(0.4+dynamicAmount,0.5+dynamicAmount,0.6+dynamicAmount) end,
    ComputeDynamicLighting=function() dynamicQueries=dynamicQueries+1 return Vector(dynamicAmount,dynamicAmount,dynamicAmount) end,
    GetAmbientLightColor=function() return Vector(0.1,0.1,0.1) end,
    SetMaterial=function(m) material=m end,
    SetColorModulation=function(r,g,b) assert(r==1 and g==1 and b==1,"captured source lighting tinted") end,
    ResetModelLighting=function() lights={} end,
    SetModelLighting=function(i,r,g,b) lights[i+1]=Vector(r,g,b) end,
    SetLightingOrigin=function() end,SetLocalModelLights=function() end,
    SuppressEngineLighting=function(value) suppressed=value end,
    RenderFlashlights=function(fn) fn() end,
    OverrideDepthEnable=function() error("removed additive pass writes depth") end,
    OverrideBlend=function(enabled,a,b,fn)
        if enabled then assert(a==BLEND_ONE and b==BLEND_ONE and fn==BLENDFUNC_ADD) end
        additive=enabled
    end
}
function RunLightingTests()
    local r=V.NewScanRegion(130,Vector(),16)
    local source={lightOrigin=Vector(0,0,16),point=Vector(),failed=false}
    r.surfaceList={source}
    local baked={baked=true,source=source,material={},flashMaterial={}}
    baked.mesh={IsValid=function() return true end,Draw=function() draws=draws+1 assert(material==baked.material or material==baked.flashMaterial) end}
    local chunk={lightOrigin=source.lightOrigin}
    for i=1,200 do frame=frame+1 now=now+0.02 V.DrawSurfaceBatch(r,chunk,baked,true) end
    assert(draws==200 and queries==0 and dynamicQueries<=6*200,"unlit captured faces add ambient passes or exceed the light-query budget")
    V.DrawSurfaceBatch(r,chunk,baked,false)
    assert(draws==202,"native flashlight pass was removed")
    dynamicAmount=0.2 frame=frame+1 now=now+0.2
    V.DrawSurfaceBatch(r,chunk,baked,true)
    assert(draws==204 and not additive and math.abs(lights[5].x-0.2)<1e-9,
        "captured face missed the dynamic-only light pass, double-counted static lighting or leaked blend state")
    dynamicAmount=0 frame=frame+1 now=now+0.2
    V.DrawSurfaceBatch(r,chunk,baked,true)
    assert(draws==205 and not additive,"switched-off light retained an additive pass")
    dynamicAmount=0.2 frame=frame+1 now=now+0.2
    V.PrepareSurfaceLighting(source,r)
    assert(queries==6,"exterior light cube not sampled once")
    local cut={source=source,worldCenter=Vector(0,0,-30)}
    local light=V.SurfaceLighting(r,chunk,cut)
    assert(math.abs(light.environment[5].x-0.4)<1e-9 and math.abs(light.total[5].x-0.6)<1e-9,"external ambient/dynamic light lost or counted twice")
    local first=dynamicQueries
    V.SurfaceLighting(r,chunk,{source=source})
    local other={lightOrigin=source.lightOrigin}
    V.SurfaceLighting(r,other,{source=source})
    assert(dynamicQueries==first,"per-frame dynamic-light limit not shared across chunks")
    frame=frame+1 now=now+0.01
    V.SurfaceLighting(r,other,{source=source})
    assert(dynamicQueries==first+6,"deferred chunk never receives dynamic light")
    local before=queries
    for i=1,100 do frame=frame+1 now=now+0.02 V.SurfaceLighting(r,chunk,cut) end
    assert(queries==before,"static exterior lighting still polled per frame")
    local prop={WorldSpaceCenter=function() return Vector(0,0,-30) end,GetNW2Int=function() return r.id end}
    assert(V.LightVoxelProp(r,prop) and suppressed and lights[5].x>=0.4,"buried object lost exterior lighting")
    render.SuppressEngineLighting(false)
    local nativeQueries,nativeDynamic=queries,dynamicQueries
    local inAir=vehicle(Vector(0,0,30),r)
    assert(not V.LightVoxelProp(r,inAir) and not suppressed and inAir:GetLightingOriginEntity()==NULL,
        "vehicle in BSP air lost native map lighting merely because VM_PropRegion was set")
    local airProp={WorldSpaceCenter=function() return Vector(0,0,20) end,GetNW2Int=function() return r.id end}
    assert(not V.LightVoxelProp(r,airProp) and not suppressed,"ordinary object in BSP air received synthetic voxel lighting")
    assert(queries==nativeQueries and dynamicQueries==nativeDynamic and anchorCreates==0,
        "native BSP air lighting performs extra light samples or creates an anchor")
    local car=vehicle(Vector(0,0,-30),r)
    assert(V.LightVoxelProp(r,car) and not suppressed,
        "vehicle in a carved BSP solid still suppresses native model lighting")
    local anchor=car:GetLightingOriginEntity()
    assert(IsValid(anchor) and anchor~=NULL and anchor:GetNoDraw() and util.PointContents(anchor:GetPos())==0,
        "vehicle lighting origin is not an invisible anchor positioned in BSP air")
    assert(anchor:GetPos():DistToSqr(source.lightOrigin)<1e-9 and anchorCreates==1,
        "vehicle lighting did not reuse the scanned air probe")
    assert(type(V.RestoreVoxelPropLighting)=="function","vehicle lighting origin has no scoped restoration")
    V.RestoreVoxelPropLighting()
    assert(car:GetLightingOriginEntity()==NULL and not suppressed,
        "vehicle draw leaked its temporary lighting origin or suppressed lighting")
    local otherCar=vehicle(Vector(12,0,-42),r)
    for i=1,50 do
        frame=frame+1 now=now+0.02
        V.LightVoxelProp(r,car)
        assert(car:GetLightingOriginEntity()==anchor and not suppressed,
            "cached vehicle draw changed the lighting anchor or disabled engine lighting")
        V.RestoreVoxelPropLighting()
        V.LightVoxelProp(r,otherCar)
        assert(otherCar:GetLightingOriginEntity()==anchor and not suppressed,
            "vehicles from one region do not share their invisible lighting anchor")
        V.RestoreVoxelPropLighting()
    end
    assert(anchorCreates==1 and anchorRemoves==0,"vehicle lighting allocates clientside models per vehicle or frame")
    local addonOrigin={valid=true,GetPos=function() return Vector(20,0,20) end}
    local customized=vehicle(Vector(0,0,-45),r)
    customized.lightOrigin=addonOrigin
    local writes=customized.lightOriginWrites
    V.LightVoxelProp(r,customized)
    assert(customized:GetLightingOriginEntity()==addonOrigin and customized.lightOriginWrites==writes and not suppressed,
        "voxel lighting overwrote an origin defined by the vehicle addon")
    V.RestoreVoxelPropLighting()
    assert(customized:GetLightingOriginEntity()==addonOrigin and anchorCreates==1,
        "scoped restoration erased the addon's original lighting origin")
    print("PASS: BSP-air vehicles preserve native lighting; buried vehicles share one invisible air probe, keep engine lighting and restore NULL/addon lighting origins")
    black=true dynamicAmount=0 frame=frame+1 now=now+1
    local dark=V.SurfaceLighting(r,{lightOrigin=Vector(0,0,16)},{source={lightOrigin=Vector(0,0,16)}})
    assert(dark.total[5]:LengthSqr()==0,"extra artificial ambient repainted a genuinely dark source")
    local slow={chunk,{lightOrigin=source.lightOrigin},{lightOrigin=source.lightOrigin}}
    for i=1,6 do
        frame=frame+1 now=now+0.5
        for _,visible in ipairs(slow) do V.SurfaceLighting(r,visible,{source=source}) end
    end
    for _,visible in ipairs(slow) do assert(visible.voxelDynamic,"first visible chunk starves later lamps at 2 FPS") end
    V.LightVoxelProp(r,car)
    assert(car:GetLightingOriginEntity()==anchor,"cleanup regression did not start with an active native light origin")
    V.ReleaseVoxelLighting(r)
    assert(car:GetLightingOriginEntity()==NULL and not suppressed,"region cleanup retained its active temporary light origin")
    assert(prop.VMVoxelLight==nil,"discarded region retained by a prop's light cache")
    assert(anchorRemoves==1 and not IsValid(anchor),"discarded region retained its invisible lighting anchor")
    assert(car.VMVoxelLight==nil and otherCar.VMVoxelLight==nil and customized.VMVoxelLight==nil,
        "discarded region retained a vehicle's lighting cache")
    V.ReleaseVoxelLighting(r)
    assert(anchorRemoves==1,"repeated lighting cleanup removed its anchor twice")
    assert(V.VoxelSunBlocked==nil,"solar ray system retained")
    V.TraceScanRegion=oldTrace V.SurfaceUsesBaked=originalBaked
    ClientsideModel=originalClientsideModel V.GetVoxelVehicleRoot=originalVehicleRoot NULL=originalNull
    print("PASS: captured faces retain static contrast; unlit faces use one pass, dynamic lamps use albedo plus dynamic-only light, blend state restored, native flashlights and buried-object lighting preserved")
end
