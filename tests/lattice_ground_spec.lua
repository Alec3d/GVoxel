-- Actual gm_construct field recorded in Source: flat displaced ground at z=250.
-- The ground coincides with the lattice's middle plane at large coordinates.
local V=GVoxel
local r=V.NewScanRegion(62001,Vector(-4384,-1920,250),16)
V.PrepareBSPRegion(r,_NATIVE_BSP_DATA,nil,false)
r.values=_NATIVE_LATTICE_VALUES
local count=0
for y=-80,80,16 do for x=-80,80,16 do
    local start=Vector(-4384+x,-1920+y,350)
    local hit=V.TraceScanRegion(r,start,Vector(0,0,-1),220)
    assert(hit and math.abs(hit.HitPos.z-250)<0.05,"flat ground on a lattice plane disappeared into the buried ceiling")
    local body=V.TraceVoxelHull(r,start,Vector(start.x,start.y,200),Vector(),Vector())
    assert(body.Hit and math.abs(body.HitPos.z-250)<0.05,"flat ground render and collision disagree at the lattice boundary: "..tostring(body.Hit).." z="..body.HitPos.z)
    count=count+1
end end
local triangles=0
V.ForChunks(function(x,y,z)
    for _,vertex in ipairs(V.BuildChunk(r,x,y,z)) do
        local height=vertex.pos.z+r.origin.z+z*8*r.step
        if math.abs(height-250)<0.05 then triangles=triangles+1 end
    end
end,r)
assert(triangles>200,"valid ground ray hits were omitted by the visible chunk builder")
print(string.format("PASS: %d native-field flat displacement rays/hulls at z=250 and visible chunk vertices survive exact lattice ownership with Source float Vectors",count))
