local V=GVoxel
local fixtureTrace
local originalLine=util.TraceLine
-- Loaded just before the module, so its captured engine function is testable
-- without making production suspension use a mutable global trace function.
util.TraceLine=function(data) if fixtureTrace then return fixtureTrace(data) end return originalLine(data) end
function RunHL2WheelTests()
    local up,forward=Vector(0,0,1),Vector(0,1,0)
    local j,load=V.HL2WheelImpulse(up,up,forward,Vector(),0,250,600,0.015,1,false,600)
    assert(math.abs(j.z-2250)<0.001 and j.y>0 and load==150000)
    local side=V.HL2WheelImpulse(up,up,forward,Vector(500,0,0),0,250,600,0.015,0,false,600)
    assert(side.x<0 and math.abs(side.x)<=side.z*1.1+0.001,"unbounded lateral tyre impulse")
    local wall=V.HL2WheelImpulse(Vector(1,0,0),up,forward,Vector(),10,250,600,0.015,1,false,600)
    assert(wall:LengthSqr()==0,"vertical wall became suspension ground")
    local limit=V.HL2WheelImpulse(up,up,forward,forward*700,0,250,600,0.015,1,false,600)
    assert(limit.y<0,"engine accelerates beyond its script speed limit")
    print("PASS: HL2 ray tyre solver supports rest load, bounds friction by ground load, rejects walls and respects script speed limits")

    local oldEngine,oldEnv,oldStates=engine,physenv,V.VehicleStates
    engine={TickInterval=function() return 0.015 end}
    physenv={GetGravity=function() return up*600 end}
    local params={wheelsPerAxle=2,engine={maxSpeed=616,maxRevSpeed=246},body={addGravity=0},axles={}}
    local fields={suspension_springConstant=40,suspension_springDamping=0.7,
        suspension_springDampingCompression=9,suspension_stabilizerConstant=10,
        suspension_maxBodyForce=9,torqueFactor=0.5,brakeFactor=0.5}
    for i=1,2 do
        local axle={offset=Vector(0,i==1 and 50 or -50,30),wheelOffset=Vector(40,0,0),wheels_radius=18}
        for k,v in pairs(fields) do axle[k]=v end params.axles[i]=axle
    end
    IN_FORWARD=IN_FORWARD or 8 IN_BACK=IN_BACK or 16 IN_JUMP=IN_JUMP or 2
    IN_MOVERIGHT=IN_MOVERIGHT or 1024 IN_MOVELEFT=IN_MOVELEFT or 512
    local refused,changes,impulses,queries=false,0,0,0
    local driver={valid=false,KeyDown=function() return false end}
    local lastImpulse
    local body={IsMotionEnabled=function() return true end,IsAsleep=function() return false end,
        GetMass=function() return 1000 end,GetMassCenter=function() return Vector() end,GetPos=function() return Vector() end,
        LocalToWorld=function(_,v) return v end,GetVelocityAtPoint=function() return Vector() end,
        ApplyForceCenter=function(_,force) assert(force.z>0) lastImpulse=force impulses=impulses+1 end,
        ApplyTorqueCenter=function(_,torque) assert(torque:Length()<50000,"torque unit conversion missing") end}
    local car={GetWheelCount=function() return 4 end,GetClass=function() return "prop_vehicle_jeep" end,
        IsVehicle=function() return true end,GetWheel=function() return {} end,
        GetWheelTotalHeight=function() return 20 end,GetDriver=function() return driver end,
        GetPhysicsObject=function() return body end,GetUp=function() return up end,
        GetPos=function() return Vector() end,LocalToWorld=function(_,v) return v end,
        IsBoosting=function() return false end,IsEngineStarted=function() return true end,
        IsVehicleBodyInWater=function() return false end,GetThrottle=function() return 0 end}
    function car:GetVehicleParams()
        local copy={wheelsPerAxle=2,engine=params.engine,body=params.body,axles={}}
        for i,a in ipairs(params.axles) do copy.axles[i]={} for k,v in pairs(a) do copy.axles[i][k]=v end end
        return copy
    end
    function car:SetVehicleParams(patch)
        assert(not patch.engine and not patch.body and not patch.steering,"unrelated native parameters round-tripped")
        changes=changes+1
        for i,a in ipairs(patch.axles) do for k,v in pairs(a) do
            if not refused or v~=0 then params.axles[i][k]=v end
        end end
    end
    local hole=false
    fixtureTrace=function(data)
        queries=queries+1 assert(data.filter(car)==false and not data.filter({VMVehicleRoot=car.VMVehicleRoot or car}))
        assert(data.ignoreworld,"native BSP leaked into the suspension ray")
        assert(not data.filter({VMVoxelCollider=true,VMActive=false}),"staged collider supplied suspension")
        assert(not data.filter({VMVoxelCollider=true,VMActive=true,VMGuard=true}),"cage guard supplied suspension")
        assert(data.filter({VMVoxelCollider=true,VMActive=true,VMVoxelRegion=V.VehicleStates[car.VMVehicleRoot or car].region}),"active cooked terrain filtered out")
        return {Hit=not hole,StartSolid=false,HitNormal=up,HitPos=Vector(data.start.x,data.start.y,0),Entity=game.GetWorld()}
    end
    V.VehicleStates={[car]={region={},parts={car}}}
    local tick=_VoxelBodyFixture.hooks["GVoxel.HL2Wheels"]
    tick()
    assert(V.HL2WheelStates[car] and queries==4 and impulses==1 and changes==1,
        string.format("state=%s queries=%d impulses=%d changes=%d error=%s",tostring(V.HL2WheelStates[car]),queries,impulses,changes,tostring(car.VMHL2WheelError)))
    assert(params.axles[1].suspension_springConstant==0 and params.engine.maxSpeed==616)
    driver.valid=true driver.GetVehicle=function() return car end
    local command={KeyDown=function(_,key) return key==IN_FORWARD end,
        GetForwardMove=function() return 400 end,GetSideMove=function() return 0 end}
    _VoxelBodyFixture.hooks["GVoxel.HL2WheelInput"](driver,command)
    tick() assert(lastImpulse.y>0,"native airborne throttle zero blocked the driver's command")
    _VoxelBodyFixture.advance(0.3)
    tick() assert(lastImpulse.y==0,"stale disconnected driver command kept accelerating")
    hole=true tick()
    assert(queries==16 and impulses==3 and V.HL2WheelStates[car].contacts==0,"hole retained invisible support")
    V.VehicleStates[car]=nil tick()
    assert(not V.HL2WheelStates[car] and changes==2 and params.axles[1].suspension_springConstant==40)
    V.ReleaseHL2WheelSupport(car) assert(changes==2,"duplicate release rewrote native parameters")
    print("PASS: HL2 wheel lifecycle neutralizes only native axles, uses four bounded terrain rays, removes hole support and restores original suspension/speed on exit")
    print("PASS: HL2 command capture supplies traction when native airborne throttle is zero and expires stale driver input")
    local tow={}
    car.VMVehicleRoot=tow V.VehicleStates={[tow]={region={},parts={car}}}
    tick() assert(V.HL2WheelStates[car],"native wheeled member of an assembly lost its suspension")
    V.ReleaseHL2WheelSupport(car) car.VMVehicleRoot=nil V.VehicleStates={}
    assert(params.axles[1].suspension_springConstant==40)
    print("PASS: native wheeled members retain support in a constrained assembly and ignore their complete assembly in wheel rays")
    refused=true V.VehicleStates[car]={region={},parts={car}} tick()
    assert(not V.HL2WheelStates[car] and car.VMHL2WheelError and params.axles[1].suspension_springConstant==40)
    local before=changes tick() assert(changes==before,"refused native setter retried every tick")
    print("PASS: unsupported HL2 suspension setters roll back without double forces or per-tick retries")
    V.VehicleStates={} V.ReleaseHL2WheelSimulation()
    fixtureTrace=nil util.TraceLine=originalLine
    engine,physenv,V.VehicleStates=oldEngine,oldEnv,oldStates
end
