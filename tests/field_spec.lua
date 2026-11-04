-- Minimal Vector adapter: numerical/geometry tests, not an engine simulation.
local vec = {}
vec.__index = vec
function Vector(x,y,z) return setmetatable({x=x or 0,y=y or 0,z=z or 0},vec) end
function vec:Set(b) self.x,self.y,self.z=b.x,b.y,b.z end
function vec:Add(b) self.x,self.y,self.z=self.x+b.x,self.y+b.y,self.z+b.z end
function vec:Sub(b) self.x,self.y,self.z=self.x-b.x,self.y-b.y,self.z-b.z end
function vec:Mul(b) self.x,self.y,self.z=self.x*b,self.y*b,self.z*b end
function vec:Div(b) self.x,self.y,self.z=self.x/b,self.y/b,self.z/b end
function vec:Normalize()
    local length=math.sqrt(self:LengthSqr())
    if length>0 then self:Div(length) end
end
function Color(r,g,b,a) return {r=r,g=g,b=b,a=a or 255} end
function vec.__add(a,b) return Vector(a.x+b.x,a.y+b.y,a.z+b.z) end
function vec.__sub(a,b) return Vector(a.x-b.x,a.y-b.y,a.z-b.z) end
function vec.__unm(a) return Vector(-a.x,-a.y,-a.z) end
function vec:Length() return math.sqrt(self:LengthSqr()) end
function vec.__mul(a,b)
    if type(a)=="number" then a,b=b,a end
    return Vector(a.x*b,a.y*b,a.z*b)
end

function RunPhysicsGeometryTests()
    local V=GVoxel
    -- Real coordinates reported by VPhysics, including the 3D sliver at z=0.
    local slivers={
        {Vector(137.76,19.65,153.76),Vector(137.80,19.69,153.76),Vector(137.80,19.65,153.76)},
        {Vector(59.02,59.02,153.76),Vector(59.06,59.06,153.76),Vector(59.06,59.02,153.76)},
        {Vector(118.11,118.03,0),Vector(118.11,118.11,0.02),Vector(118.13,118.11,0.02)},
        {Vector(19.69,39.45,0),Vector(19.70,39.39,0.02),Vector(19.69,39.39,0.02)},
        {Vector(78.74,58.97,0),Vector(78.74,59.06,0.02),Vector(78.76,59.06,0.02)},
        {Vector(0,0,0),Vector(100,0,0),Vector(50,0.01,0)}
    }
    local vertices={}
    for _,t in ipairs(slivers) do
        assert(not V.PhysicsTriangleUsable(t[1],t[2],t[3]),"logged sliver still reaches native physics")
        assert(not V.PhysicsTriangleUsable(t[3],t[2],t[1]),"reversing winding bypassed physics validation")
        for _,p in ipairs(t) do vertices[#vertices+1]={pos=p} end
    end
    local a,b,c=Vector(0,0,0),Vector(0,20,0),Vector(20,0,0)
    for _,p in ipairs({a,b,c}) do vertices[#vertices+1]={pos=p} end
    local clean=V.PhysicsVertices(vertices)
    assert(#clean==3 and clean[1]==a and clean[2]==b and clean[3]==c,"physics cleanup moved or rewound valid triangles")
    assert(#V.PhysicsVertices({a,b,c})==3,"plain-vector physics input broke")
    assert(not V.PhysicsTriangleUsable(a,a,c) and not V.PhysicsTriangleUsable(a,b,Vector(0,40,0)))
    -- Verify the scanned-collider path uses the filter, while the visible
    -- triangulation keeps small but nonzero faces, avoiding visual cracks.
    local original=V.ForCellTriangles
    V.ForCellTriangles=function(_,x,y,z,emit)
        if x==0 and y==0 and z==0 then
            emit(slivers[1][1],slivers[1][2],slivers[1][3],Vector(0,0,1))
            emit(a,b,c,Vector(0,0,1))
        end
    end
    local r=V.TestRegion(888,Vector())
    local contact=V.BuildCollisionChunk(r,0,0,0)
    local visible=V.BuildChunk(r,0,0,0)
    V.ForCellTriangles=original
    assert(#contact==3 and #visible==6,"physics tolerance deleted visible terrain or missed scanned collider")
    print("PASS: logged sub-tolerance physics slivers and thin triangles rejected; valid winding and visible geometry preserved")
end
function vec.__div(a,b) return Vector(a.x/b,a.y/b,a.z/b) end
function vec:Dot(b) return self.x*b.x+self.y*b.y+self.z*b.z end
function vec:Cross(b) return Vector(self.y*b.z-self.z*b.y,self.z*b.x-self.x*b.z,self.x*b.y-self.y*b.x) end
function vec:LengthSqr() return self:Dot(self) end
function vec:GetNormalized()
    local length=math.sqrt(self:LengthSqr())
    return length>0 and self/length or Vector()
end
function vec:DistToSqr(b) return (self-b):LengthSqr() end
GVoxel = {}

-- Synthetic closed-box density fixture; never loaded by the game addon.
function GVoxel.TestRegion(id,base)
    local V=GVoxel
    local r={id=id,base=base,origin=base+Vector(-256,-256,-16),values={},revision=0,edits={},chunks={}}
    for z=0,24 do for y=0,32 do for x=0,32 do
        local dx,dy,dz=math.abs(x*16-256)-232,math.abs(y*16-256)-232,math.abs(z*16-100)-84
        local value=math.sqrt(math.max(dx,0)^2+math.max(dy,0)^2+math.max(dz,0)^2)+math.min(math.max(dx,dy,dz),0)
        r.values[V.Index(x,y,z)]=math.max(-32767,math.min(32767,math.floor(value*64+0.5)))/64
    end end end
    return r
end

local function count(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
local function pointKey(p) return string.format("%.5f,%.5f,%.5f",p.x,p.y,p.z) end

function RunFieldTests()
    local V=GVoxel
    local r=V.TestRegion(1,Vector(0,0,0))
    assert(#r.values==33*33*25,"wrong lattice size")
    assert(V.Density(r,Vector(0,0,80))<0,"inside must be solid")
    assert(V.Density(r,Vector(0,0,200))>0,"above must be air")
    assert(math.abs(V.Density(r,Vector(0,0,168)))<0.001,"top must be at 168")
    assert(V.Density(r,Vector(250,0,80))>0,"side boundary must be air")
    print("PASS: initial bounded density field")

    local center=Vector(0,0,144)
    local _,changed=V.ApplyBrush(r,center,48,false)
    assert(changed and V.Density(r,center)>0,"carve did not create air")
    local _,duplicate=V.ApplyBrush(r,center,48,false)
    assert(not duplicate,"identical brush must be idempotent")
    V.ApplyBrush(r,center,48,true)
    assert(V.Density(r,center)<0,"addition did not restore solid")
    for _,value in ipairs(r.values) do assert(value*64==math.floor(value*64),"network quantization mismatch") end
    print("PASS: subtract, add, idempotence and exact network quantization")

    r=V.TestRegion(2,Vector())
    local dirty=V.ApplyBrush(r,r.origin+Vector(128,128,128),32,false)
    assert(dirty["0:0:0"] and dirty["1:1:1"],"shared-node neighboring chunks not marked")
    for z=0,24 do for y=0,32 do for x=0,32 do
        if x==0 or x==32 or y==0 or y==32 or z==0 or z==24 then
            assert(V.Sample(r,x,y,z)>=0,"outer boundary lost its seal")
        end
    end end end
    local outside=V.ApplyBrush(r,r.origin-Vector(200,200,200),24,true)
    assert(count(outside)==0,"outside brush dirtied the region")
    print("PASS: boundary seal, distant brush and chunk invalidation")

    local function validateSurface(region,label)
        local edges,triangles,maximum={},0,0
        V.ForChunks(function(cx,cy,cz)
            local vertices=V.BuildChunk(region,cx,cy,cz)
            assert(#vertices%3==0 and #vertices<65535,"invalid mesh size")
            maximum=math.max(maximum,#vertices)
            local offset=Vector(cx,cy,cz)*128
            for i=1,#vertices,3 do
                local a,b,c=vertices[i].pos+offset,vertices[i+1].pos+offset,vertices[i+2].pos+offset
                local cross=(b-a):Cross(c-a)
                assert(cross:LengthSqr()>0.000001,"degenerate triangle")
                local normal=V.Normal(region,region.origin+(a+b+c)/3)
                -- Verify the deliberate Source clockwise triangle convention.
                assert(cross:Dot(normal)<=0.01,"inward/outward winding inconsistency")
                for j=i,i+2 do
                    local n=vertices[j].normal:LengthSqr()
                    assert(n>0.99 and n<1.01,"invalid normal")
                end
                for _,pair in ipairs({{a,b},{b,c},{c,a}}) do
                    local ka,kb=pointKey(pair[1]),pointKey(pair[2])
                    if ka>kb then ka,kb=kb,ka end
                    local key=ka.."/"..kb
                    edges[key]=(edges[key] or 0)+1
                end
                triangles=triangles+1
            end
        end)
        for edge,n in pairs(edges) do assert(n==2,label.." nonmanifold/cracked edge ("..n.."): "..edge) end
        assert(triangles>0,"empty surface")
        print(string.format("PASS: %s closed mesh, normals, winding, %d triangles; max %d vertices/chunk",label,triangles,maximum))
    end
    validateSurface(V.TestRegion(3,Vector()),"initial")
    local shaped=V.TestRegion(4,Vector(900,-700,2))
    V.ApplyBrush(shaped,shaped.base+Vector(0,0,144),64,false)
    V.ApplyBrush(shaped,shaped.base+Vector(48,24,112),48,false)
    V.ApplyBrush(shaped,shaped.base+Vector(-80,0,184),48,true)
    V.ApplyBrush(shaped,shaped.base+Vector(220,0,80),48,false)
    validateSurface(shaped,"sculpted across chunk seams")

    -- Verify that sending a chunk plus halo reproduces its geometry and normals.
    local client=V.TestRegion(4,shaped.base)
    local cx,cy,cz=1,1,1
    for z=cz*8-1,cz*8+9 do for y=cy*8-1,cy*8+9 do for x=cx*8-1,cx*8+9 do
        client.values[V.Index(x,y,z)]=V.Sample(shaped,x,y,z)
    end end end
    local a,b=V.BuildChunk(shaped,cx,cy,cz),V.BuildChunk(client,cx,cy,cz)
    assert(#a==#b,"snapshot topology differs")
    for i=1,#a do
        assert(a[i].pos:DistToSqr(b[i].pos)<1e-12,"snapshot position differs")
        assert(a[i].normal:DistToSqr(b[i].normal)<1e-12,"snapshot normal differs")
    end
    print("PASS: client/server chunk and halo reconstruction")

    -- Changed-node invalidation must cover every triangle/normal change.
    local before=V.TestRegion(5,Vector())
    local after=V.TestRegion(6,Vector())
    local touched=V.ApplyBrush(after,after.base+Vector(-143,0,144),24,false)
    V.ForChunks(function(x,y,z)
        local first,second=V.BuildChunk(before,x,y,z),V.BuildChunk(after,x,y,z)
        local differs=#first~=#second
        if not differs then for i=1,#first do
            if first[i].pos:DistToSqr(second[i].pos)>1e-12 or first[i].normal:DistToSqr(second[i].normal)>1e-12 then differs=true break end
        end end
        assert(not differs or touched[V.ChunkKey(x,y,z)],"changed chunk was not scheduled")
    end)
    print("PASS: dirty chunk coverage includes neighboring gradient normals")
end
