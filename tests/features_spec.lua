function RunFeatureTests()
    local V=GVoxel
    local precise=V.NewScanRegion(119,Vector(),16)
    local height=3.712345
    V.RecordScanPlane(precise,{Hit=true,HitWorld=true,HitPos=Vector(0,0,height),HitNormal=Vector(0,0,1),HitTexture="concrete"})
    assert(precise.featurePlanes[1].distance==height,"scan rounded the original BSP floor to 1/64")
    local p=Vector(0,0,height+0.004)-precise.origin
    local projected=precise.origin+V.RefineSurfacePoint(precise,p)
    assert(math.abs(projected.z-height)<1e-10,"fallback floor did not retain measured height")
    local r=V.NewScanRegion(120,Vector(),16)
    local center,half=Vector(3.7,-7.1,2.4),Vector(85,65,45)
    for i=0,33^3-1 do
        local p,x,y,z=V.ScanPoint(r,i)
        local q=p-center
        local a,b,c=math.abs(q.x)-half.x,math.abs(q.y)-half.y,math.abs(q.z)-half.z
        local d=math.sqrt(math.max(a,0)^2+math.max(b,0)^2+math.max(c,0)^2)+math.min(math.max(a,b,c),0)
        r.values[V.Index(x,y,z,r)]=math.floor(d*64+0.5)/64
    end
    local function measure()
        local total,count,edges=0,0,{}
        V.ForChunks(function(x,y,z)
            local offset=r.origin+Vector(x,y,z)*(r.step*8)
            local vertices=V.BuildChunk(r,x,y,z)
            for i=1,#vertices,3 do
                local points={}
                for j=i,i+2 do
                    local p=vertices[j].pos+offset
                    local q=p-center
                    total=total+math.min(math.abs(math.abs(q.x)-half.x),math.abs(math.abs(q.y)-half.y),math.abs(math.abs(q.z)-half.z))
                    count=count+1 points[#points+1]=p
                    assert(vertices[j].pos.x>=-1e-5 and vertices[j].pos.x<=r.step*8+1e-5,"feature moved outside its chunk")
                end
                for a=1,3 do
                    local p,q=points[a],points[a%3+1]
                    local ka=string.format("%.4f:%.4f:%.4f",p.x,p.y,p.z)
                    local kb=string.format("%.4f:%.4f:%.4f",q.x,q.y,q.z)
                    if ka>kb then ka,kb=kb,ka end
                    local key=ka.."/"..kb edges[key]=(edges[key] or 0)+1
                end
            end
        end,r)
        return total/count,edges
    end
    local before=measure()
    local axes={"x","y","z"}
    for _,axis in ipairs(axes) do for _,sign in ipairs({-1,1}) do
        for _,a in ipairs({-1,1}) do for _,b in ipairs({-1,1}) do
            local p=center+Vector(half.x*a,half.y*b,half.z*a)
            p[axis]=center[axis]+half[axis]*sign
            local n=Vector() n[axis]=sign
            V.RecordScanPlane(r,{Hit=true,HitWorld=true,HitPos=p,HitNormal=n,HitTexture="concrete"})
        end end
    end end
    assert(#r.featurePlanes==6,"coplanar BSP hits did not merge")
    local after,edges=measure()
    assert(after<before*0.35,"architectural plane recovery did not materially reduce corner rounding: "..before.." -> "..after)
    for key,count in pairs(edges) do assert(count==2,"sharp feature mesh has an open/overlapping seam: "..key.." ("..count..")") end
    local clone=V.CloneScanField(r)
    V.ApplyBrush(clone,center+Vector(half.x,0,0),48,false)
    assert(clone.featureTouched and not r.featureTouched,"staged sculpt changed visible feature constraints")
    local p=(center+Vector(half.x,0,0))-r.origin
    assert(V.RefineSurfacePoint(clone,p):DistToSqr(p)<1e-12,"brush area is still constrained to old sharp BSP")
    local hit=V.TraceVoxelHull(r,center+Vector(150,0,0),center,Vector(-4,-4,-4),Vector(4,4,4))
    assert(hit.Hit and math.abs(hit.HitPos.x-(center.x+half.x+4))<0.04,"feature mesh/collision plane disagree")
    for i=1,20 do
        local start=center+Vector(math.cos(i*0.7),math.sin(i*0.7),math.sin(i*1.3))*200
        local direction=(center-start):GetNormalized()
        local mesh=V.TraceScanRegion(r,start,direction,500)
        local physical=V.TraceVoxelHull(r,start,start+direction*500,Vector(),Vector())
        assert(mesh and physical.Hit and mesh.HitPos:DistToSqr(physical.HitPos)<0.0025,"sharp-corner mesh and swept collision disagree")
    end
    r=clone r.revision=r.revision+1
    local _,sculpted=measure()
    for key,count in pairs(sculpted) do assert(count==2,"sculpted feature transition opened a seam: "..key) end
    local boundary=V.NewScanRegion(121,Vector(),16)
    for i=0,33^3-1 do
        local p,x,y,z=V.ScanPoint(boundary,i)
        boundary.values[V.Index(x,y,z,boundary)]=p.z-3.7
    end
    boundary.featurePlanes={{axis=3,sign=1,distance=3.703125,low=boundary.origin,
        high=boundary.origin+Vector(1,1,1)*boundary.side}}
    local faces=V.MaskFaces(boundary)
    local beforeOpen={}
    for i,face in ipairs(faces) do beforeOpen[i]=V.BuildBoundaryOpening(boundary,face) end
    V.ApplyBrush(boundary,Vector(boundary.origin.x,0,0),48,false)
    for i,face in ipairs(faces) do
        local afterOpen=V.BuildBoundaryOpening(boundary,face)
        assert(#afterOpen==#beforeOpen[i],"edge sculpt invalidated the cached architectural aperture")
        for j,vertex in ipairs(afterOpen) do assert(vertex.pos:DistToSqr(beforeOpen[i][j].pos)<1e-12) end
    end
    print(string.format("PASS: six recovered architectural planes, closed sharp seams, shared collision and %.3f -> %.3f mean surface error",before,after))
end
