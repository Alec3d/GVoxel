local V=GVoxel
local data=_NATIVE_BSP_DATA
local grass={}
for _,face in ipairs(data.faces) do
    local tex=data.textures[face.tex.texture]
    if tex.name:lower():find("grass",1,true) and face.normal.z>0.99 and face.high.z<2000 then grass[#grass+1]=face end
end
table.sort(grass,function(a,b) return (a.dispHigh or a.high).z-(a.dispLow or a.low).z<(b.dispHigh or b.high).z-(b.dispLow or b.low).z end)
for sample=1,math.min(9,#grass) do
    local face=grass[sample]
    local center=(face.low+face.high)*0.5
    local r=V.NewScanRegion(1,center,16)
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=p.z-center.z end
    V.PrepareBSPRegion(r,data)
    local eye=center+Vector(0,0,64)
    local original=V.BuildNativeBackgroundData(r)
    local frustum=V.ViewFrustum({origin=eye,angles={Forward=function() return Vector(1,0,-0.1):GetNormalized() end},fov=90},1280,720)
    print(string.format("JOIN (%.0f %.0f %.0f) patch (%.0f %.0f)..(%.0f %.0f) BSP below=%s above=%s",center.x,center.y,center.z,face.low.x,face.low.y,face.high.x,face.high.y,tostring(V.BSPSolid(data,center-Vector(0,0,10))),tostring(V.BSPSolid(data,eye))))
    for _,f in ipairs(V.MaskFaces(r)) do
        local vertices=V.BuildBoundaryOpening(r,f)
        if #vertices>0 and V.MaskFaceIsExit(f,eye) then
            local low,high=V.VertexBounds(vertices)
            local portal={face=f,low=low,high=high}
            if V.BoundsInView(frustum,low,high) then
                local needs,why=V.PortalNeedsBackground(original,portal,frustum)
                print(string.format("  exit %.0f %.0f %.0f z %.2f..%.2f secondary %s obstruction z %s..%s",f.normal.x,f.normal.y,f.normal.z,low.z,high.z,tostring(needs),tostring(why and why.low.z),tostring(why and why.high.z)))
            end
        end
    end
end
