-- Versioned, bounded cache. Never serialize Lua code, entities or native physics handles.
local V=GVoxel
local function finite(n,limit) return type(n)=="number" and n==n and math.abs(n)<(limit or 1e7) end
local function point(p)
    return type(p)=="table" and #p==3 and finite(p[1]) and finite(p[2]) and finite(p[3])
end
local function xyz(p) return {p.x,p.y,p.z} end
function V.MakeZoneCache(scan,name,signature,checkpoint,revision)
    if not scan.completed or not scan.snapshot or (revision==nil and scan.editWork) then
        return nil,"Zone non prete ou modification en cours."
    end
    local r,values=scan.region,scan.snapshot.values
    revision=revision or r.revision
    local record={schema=2,map=game.GetMap(),signature=signature,name=name,metres=r.metres,
        base=xyz(r.base),origin=xyz(r.origin),step=r.step,cells=xyz(r.cells or Vector(32,32,32)),
        values=values,planes={},history={},byRays=r.bsp==nil}
    -- Edits publish a different values array. The original scan is immutable
    -- and can be serialized directly while a newer revision is being prepared.
    for index=1,33^3 do
        if values[index]==nil then return nil,"Densite initiale incomplete." end
        if checkpoint and index%128==0 then checkpoint() end
    end
    for _,p in ipairs(r.featurePlanes or {}) do
        record.planes[#record.planes+1]={normal=xyz(V.FeaturePlaneNormal(p)),distance=V.FeaturePlaneDistance(p),low=xyz(p.low),high=xyz(p.high)}
    end
    for i=1,revision do
        local stroke=scan.history[i]
        if not stroke then return nil,"Journal de zone incomplet." end
        record.history[i]={center=xyz(stroke.center),radius=stroke.radius,adding=stroke.adding,
            seed=stroke.seed or 0,floorZ=stroke.floorZ,plane=stroke.plane}
        if checkpoint and i%32==0 then checkpoint() end
    end
    return record
end
function V.ValidateZoneCache(record,map,signature,checkpoint)
    if type(signature)~="string" or type(record)~="table" or (record.schema~=1 and record.schema~=2) or record.map~=map or record.signature~=signature then
        return nil,"Cache obsolete : carte ou version differente."
    end
    if type(record.name)~="string" or #record.name>64 or not point(record.base) or not point(record.origin)
        or (record.byRays~=nil and type(record.byRays)~="boolean")
        or not point(record.cells) or not finite(record.step,64) or record.step<=0 or record.step>V.UnitsPerMetre+0.0001
        or (record.metres~=0 and record.metres~=16 and record.metres~=32) then return nil,"Dimensions invalides." end
    for _,n in ipairs(record.cells) do if n<2 or n>32 or n~=math.floor(n) then return nil,"Grille invalide." end end
    if record.metres~=0 then
        local expected=record.metres*V.UnitsPerMetre/32
        if math.abs(record.step-expected)>0.001 or record.cells[1]~=32 or record.cells[2]~=32 or record.cells[3]~=32 then return nil,"Pas de grille invalide." end
    elseif record.step<1 or math.max(unpack(record.cells))~=32 then
        return nil,"Pas de boite invalide."
    end
    for i,n in ipairs(record.cells) do
        local extent=n*record.step
        local maximum=record.metres==0 and V.CustomMaxSide or record.metres*V.UnitsPerMetre
        if extent<V.CustomMinSide-0.001 or extent>maximum+0.001
            or math.abs(record.base[i]-record.origin[i]-extent/2)>0.125 then return nil,"Bornes de grille invalides." end
    end
    if type(record.values)~="table" or #record.values~=33^3 or type(record.history)~="table"
        or #record.history>V.MaxEdits or type(record.planes)~="table" or #record.planes>128 then return nil,"Charge de cache invalide." end
    for index=1,33^3 do
        if not finite(record.values[index],513) then return nil,"Densite invalide." end
        if checkpoint and index%128==0 then checkpoint() end
    end
    for index=1,#record.history do
        local s=record.history[index]
        if type(s)~="table" or not point(s.center) or not finite(s.radius,65536) or s.radius<1 or s.radius~=math.floor(s.radius) or type(s.adding)~="boolean"
            or not finite(s.seed,65536) or s.seed<0 or s.seed~=math.floor(s.seed)
            or (s.floorZ~=nil and not finite(s.floorZ))
            or (s.plane~=nil and (s.adding or s.seed~=0 or s.floorZ~=nil or not V.ValidRemovalPlane(s.plane))) then return nil,"Operation invalide." end
        if checkpoint and index%32==0 then checkpoint() end
    end
    for index=1,#record.planes do
        local p=record.planes[index]
        if type(p)~="table" or not point(p.normal) or not point(p.low) or not point(p.high) or not finite(p.distance)
            or math.abs(p.normal[1]^2+p.normal[2]^2+p.normal[3]^2-1)>0.01 then return nil,"Plan invalide." end
    end
    if record.schema==1 then
        -- Version 1 stored a phantom zero index and omitted the final lattice
        -- node. Preserve every available value; restore samples only that one
        -- missing native corner rather than rescanning the zone.
        local migrated={}
        for key,value in pairs(record) do migrated[key]=value end
        migrated.schema=2 migrated.values={} migrated.legacyTail=true
        for index=1,33^3 do
            migrated.values[index]=record.values[index+1] or record.step
            if checkpoint and index%128==0 then checkpoint() end
        end
        return migrated
    end
    return record
end
