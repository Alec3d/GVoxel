-- Geometric visibility proofs on the installed BSP; no Source/GPU simulation.
local V=GVoxel
function RunNativeBackgroundTests(data)
    -- A hill outside the scan cannot occlude the local, flat air aperture.
    -- Test both paths: old files without grid metadata remain conservative.
    local r=V.NewScanRegion(1,Vector(),16)
    local face={displacement=true,vertices={},low=Vector(-1000,-1000,0),high=Vector(1000,1000,0),
        dispLow=Vector(-1000,-1000,0),dispHigh=Vector(1000,1000,1000)}
    local native={faces={face}} r.bsp=native
    local originalSolid=V.BSPSolid
    V.BSPSolid=function(d,p) if d==native then return false end return originalSolid(d,p) end
    local eye=Vector(0,0,64)
    local frustum=V.ViewFrustum({origin=eye,angles={Forward=function() return Vector(1,0,0) end},fov=90},1280,720)
    local exit
    for _,f in ipairs(V.MaskFaces(r)) do if f.normal.x>0.5 then exit=f end end
    local portal={face=exit,low=Vector(exit.point.x,-r.side/2,32),high=Vector(exit.point.x,r.side/2,r.side/2)}
    assert(V.PortalNeedsBackground(V.BuildNativeBackgroundData(r),portal,frustum),"unknown displaced bounds were treated as empty")
    face.dispWidth=5 face.dispGrid={}
    for y=0,4 do for x=0,4 do face.dispGrid[y*5+x+1]=Vector(-1000+x*500,-1000+y*500,x==4 and 1000 or 0) end end
    assert(not V.PortalNeedsBackground(V.BuildNativeBackgroundData(r),portal,frustum),"distant displacement peak still triggers a local exterior view")
    V.BSPSolid=originalSolid
    for _,f in ipairs(data.faces) do if f.displacement then
        assert(f.dispGrid and #f.dispGrid==f.dispWidth^2,"native displacement grid was discarded")
    end end
    print("PASS: native displacement grids retain conservative local patch bounds; a distant hill no longer forces an exterior scene")
    local tested,fast=0,0
    local results={}
    local grass={}
    for _,face in ipairs(data.faces) do
        local tex=data.textures[face.tex.texture]
        if tex.name:lower():find("grass",1,true) and face.normal.z>0.99 and face.high.z<2000 then grass[#grass+1]=face end
    end
    table.sort(grass,function(a,b) return (a.dispHigh or a.high).z-(a.dispLow or a.low).z<(b.dispHigh or b.high).z-(b.dispLow or b.low).z end)
    -- Include both flat platforms and relief, not the miniature 3D skybox.
    for sample=1,6 do
        local face=grass[sample<=3 and sample or #grass-sample+4]
        local tex=data.textures[face.tex.texture]
        if tex.name:lower():find("grass",1,true) and face.normal.z>0.99 and face.high.z<2000 then
            local center=(face.low+face.high)*0.5
            local eye=center+Vector(0,0,64)
            if not V.BSPSolid(data,eye) then
                local r=V.NewScanRegion(1,center,16)
                for i=0,33^3-1 do
                    local p,x,y,z=V.ScanPoint(r,i)
                    r.values[V.Index(x,y,z,r)]=p.z-center.z
                end
                V.PrepareBSPRegion(r,data)
                local original=V.BuildNativeBackgroundData(r)
                local frustum=V.ViewFrustum({origin=eye,angles={Forward=function() return Vector(1,0,-0.1):GetNormalized() end},fov=90},1280,720)
                local candidates,secondary=0,0
                for _,f in ipairs(V.MaskFaces(r)) do
                    local vertices=V.BuildBoundaryOpening(r,f)
                    if #vertices>0 and V.MaskFaceIsExit(f,eye) then
                        local low,high=V.VertexBounds(vertices)
                        local portal={face=f,low=low,high=high}
                        if V.BoundsInView(frustum,low,high) then
                            candidates=candidates+1
                            local needs=V.PortalNeedsBackground(original,portal,frustum)
                            if needs then secondary=secondary+1 end

                        end
                    end
                end
                assert(candidates>0,"outdoor test missed all apertures")
                if secondary<candidates then fast=fast+1 end
                local message=string.format("PASS: gm_construct (%.0f,%.0f,%.0f): secondary views %d -> %d (geometry only)",center.x,center.y,center.z,candidates,secondary)
                results[#results+1]=message print(message)
                tested=tested+1
            end
        end
    end
    assert(fast>0,"native outdoor visibility did not reduce work: "..fast.."\n"..table.concat(results,"\n"))
    if tested==0 then
        local names={} for _,tex in ipairs(data.textures) do if tex.name:lower():find("grass",1,true) then names[#names+1]=tex.name end end
        error("installed gm_construct grass not exercised: "..table.concat(names,","))
    end
end
