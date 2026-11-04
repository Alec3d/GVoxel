-- Versioned, bounded cache. Never serialize Lua code, entities or native physics handles.
local V=GVoxel
local function finite(n,limit) return type(n)=="number" and n==n and math.abs(n)<(limit or 1e7) end
local function point(p)
    return type(p)=="table" and #p==3 and finite(p[1]) and finite(p[2]) and finite(p[3])
end
local function xyz(p) return {p.x,p.y,p.z} end
function V.MakeZoneCache(scan,name,signature,checkpoint)
    if not scan.completed or not scan.snapshot or scan.editWork then return nil,"Zone non prete ou modification en cours." end
    local r=scan.region
    local record={schema=1,map=game.GetMap(),signature=signature,name=name,metres=r.metres,
        base=xyz(r.base),origin=xyz(r.origin),step=r.step,cells=xyz(r.cells or Vector(32,32,32)),
        values={},planes={},history={}}
    for index=0,33^3-1 do
        record.values[index+1]=scan.snapshot.values[index] or r.step
        if checkpoint and index%128==0 then checkpoint() end
    end
    for _,p in ipairs(r.featurePlanes or {}) do
        record.planes[#record.planes+1]={normal=xyz(V.FeaturePlaneNormal(p)),distance=V.FeaturePlaneDistance(p),low=xyz(p.low),high=xyz(p.high)}
    end
    for i=1,r.revision do
        local stroke=scan.history[i]
        if not stroke then return nil,"Journal de zone incomplet." end
        record.history[i]={center=xyz(stroke.center),radius=stroke.radius,adding=stroke.adding,
            seed=stroke.seed or 0,floorZ=stroke.floorZ}
        if checkpoint and i%32==0 then checkpoint() end
    end
    return record
end
function V.ValidateZoneCache(record,map,signature)
    if type(signature)~="string" or type(record)~="table" or record.schema~=1 or record.map~=map or record.signature~=signature then
        return nil,"Cache obsolete : carte ou version differente."
    end
    if type(record.name)~="string" or #record.name>64 or not point(record.base) or not point(record.origin)
        or not point(record.cells) or not finite(record.step,64) or record.step<=0 or record.step>V.CustomMaxSide/32
        or (record.metres~=0 and record.metres~=16 and record.metres~=32) then return nil,"Dimensions invalides." end
    for _,n in ipairs(record.cells) do if n<2 or n>32 or n~=math.floor(n) then return nil,"Grille invalide." end end
    if record.metres~=0 then
        local expected=record.metres*V.UnitsPerMetre/32
        if math.abs(record.step-expected)>0.001 then return nil,"Pas de grille invalide." end
    end
    if type(record.values)~="table" or #record.values~=33^3 or type(record.history)~="table"
        or #record.history>V.MaxEdits or type(record.planes)~="table" or #record.planes>128 then return nil,"Charge de cache invalide." end
    for _,value in ipairs(record.values) do if not finite(value,513) then return nil,"Densite invalide." end end
    for _,s in ipairs(record.history) do
        if not point(s.center) or not finite(s.radius,65536) or s.radius<1 or type(s.adding)~="boolean"
            or not finite(s.seed,65536) or s.seed<0 or s.seed~=math.floor(s.seed)
            or (s.floorZ~=nil and not finite(s.floorZ)) then return nil,"Operation invalide." end
    end
    for _,p in ipairs(record.planes) do
        if not point(p.normal) or not point(p.low) or not point(p.high) or not finite(p.distance)
            or math.abs(p.normal[1]^2+p.normal[2]^2+p.normal[3]^2-1)>0.01 then return nil,"Plan invalide." end
    end
    return record
end
