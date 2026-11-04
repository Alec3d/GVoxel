-- Compare the fast index with the conservative, uncached CSG path. The latter
-- visits every broad-phase operation and uses no sample-based cell shortcuts.
local V=GVoxel
local function conservative(field)
    local copy=V.CloneScanField(field)
    copy.terrainCache=nil copy.bspCellEditBins=nil copy.bspEdits={} copy.bspEditBins={}
    local operations={}
    for i,old in ipairs(field.bspEdits) do
        local op={}
        for k,value in pairs(old) do if k~="fullCells" and k~="nodeSamples" then op[k]=value end end
        copy.bspEdits[i]=op operations[old]=op
    end
    for key,bin in pairs(field.bspEditBins) do
        local list={} for i,op in ipairs(bin) do list[i]=operations[op] end
        copy.bspEditBins[key]=list
    end
    return copy
end
local function compare(field,reference,impact)
    local probes=0
    for y=-90,90,30 do for z=-45,135,30 do
        local a=impact+Vector(-170,y,z) local b=impact+Vector(170,y,z)
        local lo,hi=Vector(-3,-4,-5),Vector(3,4,5)
        local actual=V.TraceVoxelHull(field,a,b,lo,hi)
        local expected=V.TraceVoxelHull(reference,a,b,lo,hi)
        assert(actual.Hit==expected.Hit and actual.StartSolid==expected.StartSolid
            and math.abs(actual.Fraction-expected.Fraction)<0.00001,"explosion shortcut changed a body sweep")
        local direction=(b-a):GetNormalized()
        local p=V.TraceScanRegion(field,a,direction,340)
        local q=V.TraceScanRegion(reference,a,direction,340)
        assert((p~=nil)==(q~=nil),"explosion shortcut lost a visible wall")
        if p then assert(p.HitPos:DistToSqr(q.HitPos)<0.0001,"explosion shortcut moved the crater surface") end
        probes=probes+1
    end end
    for x=-80,80,40 do for y=-80,80,40 do
        local a=impact+Vector(x,y,170) local b=impact+Vector(x,y,-210)
        local lo,hi=Vector(-4,-4,0),Vector(4,4,12)
        local p=V.TraceVoxelHull(field,a,b,lo,hi)
        local q=V.TraceVoxelHull(reference,a,b,lo,hi)
        assert(p.Hit==q.Hit and p.StartSolid==q.StartSolid and math.abs(p.Fraction-q.Fraction)<0.00001,
            "explosion shortcut changed the ground/support")
        probes=probes+1
    end end
    return probes
end
function RunExplosionOptimizationTests()
    local data={head=0,planes={{normal=Vector(0,0,1),distance=0},{normal=Vector(1,0,0),distance=0},
        {normal=Vector(1,0,0),distance=40}},
        nodes={{plane=1,front=1,back=-2},{plane=2,front=2,back=-1},{plane=3,front=-1,back=-2}},
        leaves={{solid=false},{solid=true}},faces={}}
    for _,face in ipairs({{Vector(0,0,1),Vector(-1000,-1000,0),Vector(1000,1000,0)},
        {Vector(-1,0,0),Vector(0,-1000,0),Vector(0,1000,1000)},
        {Vector(1,0,0),Vector(40,-1000,0),Vector(40,1000,1000)}}) do
        local n,low,high=unpack(face)
        local middle=n.z~=0 and Vector(high.x,low.y,low.z) or Vector(low.x,high.y,low.z)
        local other=n.z~=0 and Vector(low.x,high.y,low.z) or Vector(low.x,low.y,high.z)
        data.faces[#data.faces+1]={normal=n,tex={flags=0},low=low,high=high,vertices={low,middle,high,other}}
    end
    for _,metres in ipairs({16,32}) do
        local r=V.NewScanRegion(2440,Vector(20,0,50),metres)
        for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i)
            r.values[V.Index(x,y,z,r)]=V.BSPSolid(data,p) and -r.step or r.step
        end
        V.PrepareBSPRegion(r,data)
        local probes=0
        for i,op in ipairs({{Vector(0,0,70),112,false,913},{Vector(20,30,45),114,false,719},
            {Vector(8,15,25),48,true,0},{r.base+Vector(r.side/2-4,0,0),160,false,1295}}) do
            local previous=r
            r=V.CloneScanField(previous)
            V.ApplyBrush(r,op[1],op[2],op[3],op[4]) r.revision=i
            local ref=conservative(r)
            probes=probes+compare(r,ref,op[1])
            if i==1 then
                local retained=0 local fast=0
                for _,bin in pairs(r.bspCellEditBins) do
                    for _,edit in ipairs(bin) do assert(edit==r.bspEdits[1]) end
                end
                for _ in pairs(r.bspEdits[1].fullCells) do fast=fast+1 end
                for _,bucket in pairs(r.terrainCache and r.terrainCache.bspCells or {}) do
                    for _,cell in pairs(bucket) do if cell.solids and #cell.solids==0 and not cell.tetrahedra then retained=retained+1 end end
                end
                assert(fast>0 and retained>0,"fixture did not exercise complete-cell crater classification")
                assert(#previous.bspEdits==0 and not next(previous.bspCellEditBins),"preparing a blast modified the visible snapshot")
            end
        end
        print(string.format("PASS: %dm RPG/tank blasts, overlapping addition and sealed cage edge match conservative full-history visual/body/ground traces (%d probes); staging stays private",metres,probes))
    end
end
