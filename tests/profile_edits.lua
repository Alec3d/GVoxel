-- CPU-only numerical adapter. Excludes Source vectors, GPU and VPhysics cook.
local V=GVoxel
print("PROFILE: numerical LuaJIT adapter; total CPU, not Source frame/FPS timings")
for _,mode in ipairs({"density","exact","mixed"}) do
    local r=V.NewScanRegion(500,Vector(),16)
    local height=3.712345
    for i=0,33^3-1 do local p,x,y,z=V.ScanPoint(r,i) r.values[V.Index(x,y,z,r)]=math.floor((p.z-height)*64+0.5)/64 end
    r.featurePlanes={{axis=3,sign=1,distance=height,low=r.origin,high=r.origin+Vector(1,1,1)*r.side}}
    if mode~="density" then
        local face={normal=Vector(0,0,1),tex={flags=0},distance=height,low=Vector(-1000,-1000,height),high=Vector(1000,1000,height),
            vertices={Vector(-1000,-1000,height),Vector(1000,-1000,height),Vector(1000,1000,height),Vector(-1000,1000,height)}}
        local data={head=0,planes={{normal=Vector(0,0,1),distance=height}},nodes={{plane=1,front=-1,back=-2}},
            leaves={{solid=false},{solid=true}},faces={face}}
        if mode=="mixed" then data.faces[2]={normal=Vector(0,0,1),tex={flags=0},displacement=true,
            low=Vector(0,-1000,height),high=Vector(1000,1000,height),vertices={}} end
        V.PrepareBSPRegion(r,data)
    end
    local begin=os.clock()
    V.ForChunks(function(x,y,z) V.BuildChunk(r,x,y,z) end,r)
    print(string.format("PROFILE %s initial %.1f ms",mode,(os.clock()-begin)*1000))
    for stroke=1,3 do
        begin=os.clock()
        local field=V.CloneScanField(r)
        local dirty=V.ApplyBrush(field,Vector((stroke-1)*10,0,-20-(stroke-1)*10),48,false)
        field.revision=r.revision+1
        local chunks,triangles=0,0
        for _,c in pairs(dirty) do chunks=chunks+1 triangles=triangles+#V.BuildChunk(field,c[1],c[2],c[3])/3 end
        local visual=(os.clock()-begin)*1000
        begin=os.clock()
        for _,c in pairs(dirty) do V.BuildCollisionChunk(field,c[1],c[2],c[3]) end
        local collider=(os.clock()-begin)*1000
        begin=os.clock()
        V.TraceVoxelHull(field,Vector(0,0,50),Vector(0,0,-100),Vector(-16,-16,0),Vector(16,16,72))
        local hull=(os.clock()-begin)*1000
        print(string.format("PROFILE %s stroke %d: visual %.1f ms; collider triangles %.1f ms; hull %.1f ms; %d chunks / %d triangles",mode,stroke,visual,collider,hull,chunks,triangles))
        r=field
    end
end
