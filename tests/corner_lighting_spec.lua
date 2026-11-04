-- Regression for the approved older lighting plus a narrowly local seam blend.
function RunCornerLightingTests()
    local V=GVoxel
    local bytes=string.char(0,0,0,0):rep(4)..string.char(255,255,255,0):rep(4)
    local wall={normal=Vector(1,0,0),lightOffset=0,lightSize={1,1},lightMin={0,0},lightStyles={0,255,255,255},
        tex={lu=Vector(0,1/16,0),lv=Vector(0,0,1/16),luo=0,lvo=0,flags=0}}
    local floor={normal=Vector(0,0,1),lightOffset=16,lightSize={1,1},lightMin={0,0},lightStyles={0,255,255,255},
        tex={lu=Vector(1/16,0,0),lv=Vector(0,1/16,0),luo=0,lvo=0,flags=0}}
    local data={lighting=bytes}
    local white=Vector(1,1,1)
    local function source(face,point,low,high)
        return {point=point,nativeFace=face,planeNormal=face.normal,frame={normal=face.normal},
            lightBounds={low=low,high=high},voxelEnvironment={white,white,white,white,white,white}}
    end
    local a=source(wall,Vector(0,8,8),Vector(),Vector(0,16,16))
    local b=source(floor,Vector(8,8,0),Vector(),Vector(16,16,0))
    local oldSun=util.GetSunInfo util.GetSunInfo=function() return nil end
    local function region(list,lighting)
        local r={step=16,origin=Vector(),base=Vector(),chunks={},surfaceList=list,bsp=lighting}
        V.PrepareCutLighting(r) return r
    end
    for _,list in ipairs({{a,b},{b,a}}) do
        local r=region(list,data)
        local shared=Vector(0,8,0)
        assert(V.CutVertexLighting(r,shared,wall.normal):LengthSqr()==0,
            "local seam chooses the lit floor instead of its shaded wall")
        assert(math.abs(V.CutVertexLighting(r,shared,floor.normal).x-1)<1e-9,
            "local seam chooses the shaded wall instead of its lit floor")
        local deep=Vector(-40,8,8)
        local reference=region(list,nil)
        assert((V.CutVertexLighting(r,deep,wall.normal)-V.CutVertexLighting(reference,deep,wall.normal)):LengthSqr()<1e-12,
            "a dark boundary again changes the older lighting throughout the interior")
        local hits=r.cutLighting.hits
        local original=V.SampleBSPLightmap
        V.SampleBSPLightmap=function() error("cached seam repeats lightmap reads") end
        for _=1,100 do V.CutVertexLighting(r,shared,wall.normal) V.CutVertexLighting(r,shared,floor.normal) end
        V.SampleBSPLightmap=original
        assert(r.cutLighting.hits==hits+200,"local seam misses the shared position cache")
    end
    print("PASS: old interior light levels preserved away from local seams; perpendicular faces keep distinct shade/sun in either source order; repeated seam queries stay cached")

    local left={normal=Vector(0,0,1),lightOffset=0,lightSize={1,1},lightMin={0,0},lightStyles={0,255,255,255},
        tex={lu=Vector(1/16,0,0),lv=Vector(0,1/16,0),luo=1,lvo=0,flags=0}}
    local right=floor
    local c=source(left,Vector(-8,8,0),Vector(-16,0,0),Vector(0,16,0))
    local d=source(right,Vector(8,8,0),Vector(),Vector(16,16,0))
    for _,list in ipairs({{c,d},{d,c}}) do
        local r=region(list,data)
        local previous=-1
        for x=-8,8,0.25 do
            local light=V.CutVertexLighting(r,Vector(x,8,0),floor.normal)
            assert(light.x>=previous-1e-9 and light.x>=0 and light.x<=1,
                "neighbor seam is discontinuous or exceeds its measured shadow/light")
            previous=light.x
        end
        assert(math.abs(V.CutVertexLighting(r,Vector(0,8,0),floor.normal).x-0.5)<1e-9,
            "two coplanar neighbors do not meet at the same intermediate brightness")
        assert(V.CutVertexLighting(r,Vector(-8,8,0),floor.normal).x<0.1
            and V.CutVertexLighting(r,Vector(8,8,0),floor.normal).x>0.9,
            "small seam blend spreads across the whole neighboring surface")
    end
    util.GetSunInfo=oldSun
    print("PASS: only nearby coplanar neighbors interpolate shaded/lit seams monotonically; values stay bounded and distant parts retain their original contrast")
end
