local V=GVoxel

function RunOptionAAllocationTests()
    local r=V.NewScanRegion(1940,Vector(57.125,-92.375,3.75),16)
    for i=0,33^3-1 do
        local p,x,y,z=V.ScanPoint(r,i)
        r.values[V.Index(x,y,z,r)]=math.floor((p.z+0.12*p.x-0.07*p.y)*64+0.5)/64
    end
    local function density(p)
        local q=(p-r.origin)/r.step
        local x,y,z=math.floor(q.x),math.floor(q.y),math.floor(q.z)
        local u,v,w=q.x-x,q.y-y,q.z-z
        local function row(yy,zz) return V.Sample(r,x,yy,zz)*(1-u)+V.Sample(r,x+1,yy,zz)*u end
        return (row(y,z)*(1-v)+row(y+1,z)*v)*(1-w)+(row(y,z+1)*(1-v)+row(y+1,z+1)*v)*w
    end
    local function normal(p)
        local e=r.step/8
        return Vector(density(p+Vector(e,0,0))-density(p-Vector(e,0,0)),
            density(p+Vector(0,e,0))-density(p-Vector(0,e,0)),
            density(p+Vector(0,0,e))-density(p-Vector(0,0,e))):GetNormalized()
    end
    for i=1,40 do
        local p=r.origin+Vector(i*13.17%r.side,i*27.31%r.side,i*41.73%r.side)
        local before=Vector(p.x,p.y,p.z)
        assert(V.Density(r,p)==density(p),"scratch density changed interpolation")
        local expected=normal(p) local actual=V.Normal(r,p)
        assert(actual:DistToSqr(expected)<1e-20,"scratch normal changed the original sampling arithmetic")
        V.Normal(r,p+Vector(10,10,10))
        assert(actual:DistToSqr(expected)<1e-20 and p:DistToSqr(before)==0,"sampler mutated an input/returned vector")
    end
    local p=Vector(10,20,30) V.Normal(r,p)
    local original=Vector local made=0
    Vector=function(...) made=made+1 return original(...) end
    for _=1,20 do V.Density(r,p) end
    local densityMade=made
    for _=1,20 do V.Normal(r,p) end
    Vector=original
    assert(densityMade==0 and made==20,"steady density/normal sampling allocates temporary vectors")
    print("PASS: option A preserves density/normals and vector ownership; zero temporary Vector allocations in steady sampling")

    local faces=V.MaskFaces({origin=Vector(-10,-10,-10),side=20})
    local cut=assert(V.ClipBSPPolytope({faces=faces},Vector(1,0.6,0.2):GetNormalized(),0.756))
    local byPosition,unique={},0
    for _,face in ipairs(cut.faces) do for _,point in ipairs(face.vertices) do
        local key=string.format("%.8f:%.8f:%.8f",point.x,point.y,point.z)
        if byPosition[key] then assert(byPosition[key]==point,"incident clip faces allocate distinct copies of their shared edge")
        else byPosition[key]=point unique=unique+1 end
    end end
    assert(#cut.faces>=4 and unique>=4,"clipping lost a closed solid")
    print("PASS: option A clipped faces share canonical intersection objects without mutating their input polytope")
end

function RunOptionACacheTests()
    local h=3.712345
    local data={head=0,planes={{normal=Vector(0,0,1),distance=h}},nodes={{plane=1,front=-1,back=-2}},
        leaves={{solid=false},{solid=true}},faces={{normal=Vector(0,0,1),distance=h,tex={flags=0},
            low=Vector(-1000,-1000,h),high=Vector(1000,1000,h),
            vertices={Vector(-1000,-1000,h),Vector(1000,-1000,h),Vector(1000,1000,h),Vector(-1000,1000,h)}}}}
    local r=V.NewScanRegion(1941,Vector(),16)
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=math.floor((p.z-h)*64+0.5)/64 end
    V.PrepareBSPRegion(r,data)
    local dirty=V.ApplyBrush(r,Vector(0,0,-20),48,false) r.revision=1
    V.PrepareChangedCollisions(r,dirty)
    for _,c in pairs(dirty) do V.BuildCollisionChunk(r,c[1],c[2],c[3]) V.BuildChunk(r,c[1],c[2],c[3]) end
    local old={}
    for _,cells in pairs(r.terrainCache.bspCells) do for _,cell in pairs(cells) do
        for _,tet in ipairs(cell.tetrahedra or {}) do if tet.solids then old[tet]=tet.solids end end
    end end
    local field=V.CloneScanField(r)
    dirty=V.ApplyBrush(field,Vector(10,0,-25),48,false) field.revision=2
    local original=V.ApplyBSPBrushPlanes local calls,evaluations=0,0
    V.ApplyBSPBrushPlanes=function(pieces,operations,...)
        calls=calls+1 evaluations=evaluations+#pieces*#operations
        return original(pieces,operations,...)
    end
    V.PrepareChangedCollisions(field,dirty)
    local warmCalls,warmEvaluations=calls,evaluations local reused=0
    for _,cells in pairs(field.terrainCache.bspCells) do for _,cell in pairs(cells) do
        for _,tet in ipairs(cell.tetrahedra or {}) do
            if old[tet] then
                assert(tet.solids==old[tet],"missed tetrahedron lost its immutable solid cache")
                for _,piece in ipairs(tet.solids) do assert(piece.voxelHull,"shared solid lost its prepared SAT hull") end
                reused=reused+1
            end
        end
    end end
    local full=V.CloneScanField(field) full.terrainCache=nil
    calls=0 evaluations=0 V.PrepareChangedCollisions(full,dirty)
    local coldCalls=calls V.ApplyBSPBrushPlanes=original
    assert(warmEvaluations<evaluations,"overlapping removal replayed the entire collision history")
    assert(reused>0 and warmCalls<coldCalls,"overlapping stroke rebuilt every previously prepared tetrahedron")
    for x=-72,72,12 do for y=-72,72,12 do
        local a=Vector(x+0.17,y+0.31,80) local b=a-Vector(0,0,220)
        local lo,hi=Vector(-8,-8,0),Vector(8,8,40)
        local warm,cold=V.TraceVoxelHull(field,a,b,lo,hi),V.TraceVoxelHull(full,a,b,lo,hi)
        assert(warm.Hit==cold.Hit and warm.StartSolid==cold.StartSolid and math.abs(warm.Fraction-cold.Fraction)<1e-6,
            "reused tetrahedron differs from an uncached full-history rebuild")
    end end
    local soups={}
    for key,c in pairs(dirty) do soups[key]=V.BuildCollisionChunk(field,c[1],c[2],c[3]) end
    local triangleReader=V.ForCellTriangles
    V.ForCellTriangles=function() error("unchanged native mesh input was triangulated again") end
    for key,c in pairs(dirty) do
        local again=V.BuildCollisionChunk(field,c[1],c[2],c[3])
        assert(#again==#soups[key],"cached native input lost triangles")
        for i,p in ipairs(again) do assert(p==soups[key][i],"native input did not reuse immutable positions") end
    end
    V.ForCellTriangles=triangleReader
    local retained=0
    local freshRender=V.CloneScanField(field)
    freshRender.terrainCache.renderCells={} freshRender.terrainCache.smoothNormals={}
    for key,c in pairs(dirty) do
        local current=field.terrainCache.renderCells and field.terrainCache.renderCells[key] or {}
        local previous=r.terrainCache.renderCells[key] or {}
        for index,vertices in pairs(current) do
            local journal=field.bspCellEditBins[index]
            if vertices==previous[index] and (not journal or journal[#journal].index~=2) then retained=retained+1 end
        end
        local cached,fresh=V.BuildChunk(field,c[1],c[2],c[3]),V.BuildChunk(freshRender,c[1],c[2],c[3])
        assert(#cached==#fresh,"retained render cells changed triangle count")
        for i,vertex in ipairs(cached) do
            assert(vertex.pos:DistToSqr(fresh[i].pos)<1e-16 and vertex.normal:DistToSqr(fresh[i].normal)<1e-16,
                "retained render cells changed positions/normals")
        end
    end
    assert(retained>0,"local removal discarded all neighbouring render cells")
    print(string.format("PASS: overlapping removal uses %d vs %d piece/operation evaluations; %d render cells retained, matching uncached positions/normals",warmEvaluations,evaluations,retained))
    local uncached=V.CloneScanField(field) uncached.terrainCache.physicsCells={}
    for key,c in pairs(dirty) do
        local fresh=V.BuildCollisionChunk(uncached,c[1],c[2],c[3])
        assert(#fresh==#soups[key],"local physics cache invalidation lost/added triangles")
        for i,p in ipairs(fresh) do assert(p:DistToSqr(soups[key][i])<1e-16,"cached native positions differ from fresh triangulation") end
    end
    print(string.format("PASS: option A reuses %d tetrahedra; %d vs %d brush-volume evaluations, with 169 hull sweeps matching uncached reconstruction",reused,warmCalls,coldCalls))
    print("PASS: option A native triangle input retains winding, tolerance and immutable positions; warm chunks do not retriangulate")
end

function RunOriginalPartitionCacheTests()
    local r=V.NewScanRegion(1942,Vector(),16)
    local data=_BSP_TEST_FLOOR
    local height=data.planes[1].distance
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=math.floor((p.z-height)*64+0.5)/64 end
    V.PrepareBSPRegion(r,data)
    V.ForChunks(function(x,y,z) V.PrepareCollisionChunk(r,x,y,z) end,r)
    local cells=0 local original={}
    for key,bucket in pairs(r.terrainCache.bspBaseTets or {}) do
        original[key]=bucket
        for _,tets in pairs(bucket) do
            cells=cells+1 assert(not tets.hasAir,"scan precompiled all air geometry")
            for _,pieces in ipairs(tets) do for _,piece in ipairs(pieces) do
                assert(piece.solid and piece.voxelHull,"scan retained air or omitted reusable original SAT axes")
            end end
        end
    end
    assert(cells>0 and cells<256,"scan prewarmed an unbounded surface instead of the local brush focus")
    local field=V.CloneScanField(r)
    local dirty=V.ApplyBrush(field,Vector(0,0,-20),48,false) field.revision=1
    V.PrepareChangedCollisions(field,dirty)
    for key,bucket in pairs(original) do assert(field.terrainCache.bspBaseTets[key]==bucket,"a brush invalidated the immutable original partition") end
    print(string.format("PASS: original BSP/tetrahedron intersections and SAT axes prewarm only %d nearby partial cells; no air preparation or brush invalidation",cells))
end
