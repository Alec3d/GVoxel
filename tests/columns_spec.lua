function RunColumnTests()
    local V=GVoxel
    local r=V.NewScanRegion(911,Vector(),16)
    local angle=math.rad(27)
    local u,v,w=Vector(math.cos(angle),math.sin(angle),0),Vector(-math.sin(angle),math.cos(angle),0),Vector(0,0,1)
    local center,half=Vector(4,7,-12),{70,90,65}
    local planes={}
    for i,n in ipairs({u,v,w}) do for _,sign in ipairs({-1,1}) do
        planes[#planes+1]={n=n*sign,d=center:Dot(n*sign)+half[i]}
    end end
    local function contents(p)
        for _,plane in ipairs(planes) do if plane.n:Dot(p)>plane.d then return false end end
        return true
    end
    local calls=0
    local function raw(a,b)
        calls=calls+1
        local enter,exit=-math.huge,math.huge
        local enterNormal,exitNormal
        local delta=b-a
        for _,plane in ipairs(planes) do
            local distance,denominator=plane.d-plane.n:Dot(a),plane.n:Dot(delta)
            if math.abs(denominator)<1e-10 then if distance<0 then return {Hit=false} end
            else
                local t=distance/denominator
                if denominator<0 and t>enter then enter=t enterNormal=plane.n
                elseif denominator>0 and t<exit then exit=t exitNormal=plane.n end
            end
        end
        if enter>exit or exit<0 or enter>1 then return {Hit=false} end
        if contents(a) then
            return {StartSolid=true,AllSolid=exit>=1,FractionLeftSolid=exit<1 and exit or 0}
        end
        if enter>=0 and enter<=1 then return {Hit=true,HitWorld=true,HitPos=a+delta*enter,HitNormal=enterNormal,
            HitTexture="concrete",Fraction=enter} end
        return {Hit=false}
    end
    local cached,stats=V.ColumnScanTrace(r,raw,contents)
    for i=0,33^3-1 do
        local p=V.ScanPoint(r,i)
        for _,n in ipairs({Vector(1,0,0),Vector(-1,0,0),Vector(0,1,0),Vector(0,-1,0),Vector(0,0,1),Vector(0,0,-1)}) do
            local a,b=p+n*(r.step*1.75),p-n*(r.step*1.75)
            local hit=cached(a,b)
            if i%79==0 then
                local expected=raw(a,b)
                assert((hit.StartSolid or false)==(expected.StartSolid or false),"column lost solid interval")
                if expected.StartSolid then
                    assert((hit.AllSolid or false)==(expected.AllSolid or false),"column lost exit")
                    assert(math.abs((hit.FractionLeftSolid or 0)-(expected.FractionLeftSolid or 0))<0.00001)
                else
                    assert((hit.Hit or false)==(expected.Hit or false),"column missed a surface")
                    if expected.Hit then assert(hit.HitPos:DistToSqr(expected.HitPos)<0.000001 and hit.HitNormal:Dot(expected.HitNormal)>0.9999) end
                end
            end
        end
    end
    assert(stats.rays<15000 and stats.fallbacks==0,"column cache did not reduce native traces")
    print(string.format("PASS: all six rays at 35937 nodes on rotated brush, %d native rays vs 215622 local queries",stats.rays))
    local ground=V.NewScanRegion(912,Vector(),16)
    local function surface(a,b)
        if math.abs(b.z-a.z)<1e-9 then return {Hit=false} end
        local t=-a.z/(b.z-a.z)
        if t<0 or t>1 then return {Hit=false} end
        return {Hit=true,HitWorld=true,HitPos=a+(b-a)*t,HitNormal=Vector(0,0,1),HitTexture="**displacement**",Fraction=t}
    end
    local query,_,sign=V.ColumnScanTrace(ground,surface,function() return false end)
    for i=0,33^3-1 do
        local p,x,y,z=V.ScanPoint(ground,i)
        ground.values[V.Index(x,y,z,ground)]=V.ScanDensity(ground,p,false,query,sign)
    end
    assert(V.ScanDensity(ground,Vector(0,0,-200),false,query,sign)<0,"displacement is still a thin crust")
    assert(V.ScanDensity(ground,Vector(0,0,200),false,query,sign)>0,"air above displacement was filled")
    V.ApplyBrush(ground,Vector(0,0,-32),80,false) ground.revision=ground.revision+1
    local hit=V.TraceVoxelHull(ground,Vector(0,0,100),Vector(0,0,-250),Vector(-8,-8,0),Vector(8,8,32))
    assert(hit.Hit and hit.HitPos.z< -80 and hit.HitPos.z> -150,"large hole lost its solid floor below the old displacement shell")
    local function room(a,b)
        if a.z< -80 and b.z>= -80 then
            local t=(-80-a.z)/(b.z-a.z)
            return {Hit=true,HitWorld=true,HitPos=a+(b-a)*t,HitNormal=Vector(0,0,-1),HitTexture="concrete",Fraction=t}
        end
        return surface(a,b)
    end
    local roomQuery,_,roomSign=V.ColumnScanTrace(ground,room,function() return false end)
    assert(roomSign(Vector(0,0,-120))==nil,"ground continuation crossed a closer native room ceiling")
    assert(V.ScanDensity(ground,Vector(0,0,-120),false,roomQuery,roomSign)>0,"native room air was filled")
    print("PASS: deep displacement columns remain solid after an 80-unit dig; hull lands on its floor and native room air stays empty")
end
