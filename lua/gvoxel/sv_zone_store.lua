-- DATA files are runtime saves, not development sources. Work is queued outside net hooks.
local V=GVoxel
local library,saveJobs,restoreJobs={},{},{}
local map=game.GetMap():lower():gsub("[^a-z0-9_-]","_")
local folder="gvoxel/zones/"..map
local maxBytes=4*1024*1024
local canonicalKey="zone_1_0.dat"
local singleMarker=folder.."/single_zone.txt"
local fingerprint
local function signature()
    if fingerprint then return fingerprint end
    local source=file.Open("maps/"..game.GetMap()..".bsp","rb","GAME")
    if not source then return end
    local header=source:Read(1036)
    local size=source:Size() source:Close()
    if not header or #header<1036 then return end
    fingerprint="zone-v1:"..size..":"..util.CRC(header)
    return fingerprint
end
local function keyValid(key) return type(key)=="string" and #key<80 and key:match("^zone_%d+_%d+%.dat$") end
local function read(key)
    if not keyValid(key) then return nil,"Nom de sauvegarde invalide." end
    local path=folder.."/"..key
    local size=file.Size(path,"DATA")
    if not size or size<1 or size>maxBytes then return nil,"Cache absent ou trop volumineux." end
    local data=file.Read(path,"DATA")
    local ok,raw=pcall(util.Decompress,data,maxBytes)
    if not ok or type(raw)~="string" or #raw>maxBytes then return nil,"Compression du cache invalide." end
    -- One density field already contains 35,937 entries, above GMod's default
    -- 15,000-key JSON limit. This local cache is byte-bounded above and its
    -- complete schema/field/journal is validated below before restoration.
    local parsed,record=pcall(util.JSONToTable,raw,true)
    if not parsed then return nil,"JSON du cache invalide." end
    local valid,err=V.ValidateZoneCache(record,game.GetMap(),signature())
    if not valid then return nil,err or "Cache illisible." end
    valid.key=key
    return valid
end
local function writeAtomic(path,data)
    local temp,backup=path..".pending.dat",path..".previous.dat"
    file.Write(temp,data)
    if file.Read(temp,"DATA")~=data then return false end
    local had=file.Exists(path,"DATA")
    if had then
        file.Delete(backup)
        if not file.Rename(path,backup) then return false end
    end
    if not file.Rename(temp,path) then
        if had then file.Rename(backup,path) end
        return false
    end
    file.Delete(backup)
    return true
end
function V.GetZoneLibrary() return library end
function V.MarkZoneCacheDirty(scan)
    if scan.savedKey then scan.cacheDirtyAt=CurTime()+2 end
end
function V.EnsurePersistentZone(scan)
    if scan.savedKey~=canonicalKey then
        local ok,err=V.SaveZone(scan,scan.displayName,scan.ply)
        if not ok then ErrorNoHalt("[GVoxel] Sauvegarde automatique : "..tostring(err).."\n") end
    end
end
function V.SaveZone(scan,name,ply)
    if not scan or not scan.completed or scan.editWork or not signature() then return false,"Zone ou BSP non pret." end
    if scan.saving then return false,"Sauvegarde deja en cours." end
    name=tostring(name or scan.displayName or ("Zone "..scan.region.id)):gsub("%c",""):sub(1,64)
    if name=="" then name="Zone "..scan.region.id end
    scan.saving=true
    saveJobs[#saveJobs+1]={scan=scan,name=name,ply=ply}
    return true
end
local function load(key,ply)
    local record,err=read(key)
    if not record then return false,err end
    return V.RestoreCachedZone(record,ply)
end
function V.ZoneLibraryAction(ply,action,id,key,name)
    if not V.CanManageScan(ply) then return false,"Administration requise." end
    if action=="save" then return V.SaveZone(V.GetScanSession(id),name,ply) end
    if action=="load" then return load(key,ply) end
    if action=="remove" then V.CancelScan(ply,id) return not V.GetScanSession(id) end
    if action=="delete" then
        if not keyValid(key) then return false,"Nom de sauvegarde invalide." end
        for _,job in ipairs(saveJobs) do if job.scan.savedKey==key then job.cancelled=true end end
        file.Delete(folder.."/"..key)
        file.Delete(folder.."/"..key..".previous.dat")
        file.Delete(folder.."/"..key..".pending.dat")
        file.Write(singleMarker,"1")
        library[key]=nil
        for _,scan in pairs(V.GetScanSessions()) do if scan.savedKey==key then scan.savedKey=nil scan.cacheDirtyAt=nil end end
        return true
    end
    return false,"Action inconnue."
end
local function discover()
    file.CreateDir(folder)
    for _,backup in ipairs(file.Find(folder.."/zone_*.previous.dat","DATA") or {}) do
        local key=backup:gsub("%.previous%.dat$","")
        if keyValid(key) and not file.Exists(folder.."/"..key,"DATA") then file.Rename(folder.."/"..backup,folder.."/"..key) end
    end
    local names=file.Find(folder.."/zone_*.dat","DATA") or {}
    restoreJobs={}
    if file.Exists(folder.."/"..canonicalKey,"DATA") then names={canonicalKey}
    elseif file.Exists(singleMarker,"DATA") then names={}
    elseif file.Time then
        table.sort(names,function(a,b) return file.Time(folder.."/"..a,"DATA")>file.Time(folder.."/"..b,"DATA") end)
    end
    -- Old multi-zone files are retained, but only the first valid legacy cache
    -- may migrate. Subsequent saves use one canonical file for this map.
    for _,key in ipairs(names) do
        if keyValid(key) and #restoreJobs<32 then restoreJobs[#restoreJobs+1]=key end
    end
    V.ZoneRestorePending=#restoreJobs>0
end
hook.Add("InitPostEntity","GVoxel.LoadZoneCaches",discover)
hook.Add("PostCleanupMap","GVoxel.RestoreZoneCaches",discover)
local nextRestore=0
hook.Add("Think","GVoxel.ZoneStorage",function()
    for _,scan in pairs(V.GetScanSessions()) do
        if scan.cacheDirtyAt and CurTime()>=scan.cacheDirtyAt and not scan.editWork and not scan.saving then
            V.SaveZone(scan,scan.displayName) scan.cacheDirtyAt=nil
        end
    end
    local job=saveJobs[1]
    if job then
        if job.cancelled or V.GetScanSession(job.scan.region.id)~=job.scan then
            job.scan.saving=nil table.remove(saveJobs,1) return
        end
        job.deadline=SysTime()+0.001
        job.thread=job.thread or coroutine.create(function()
            local record,err=V.MakeZoneCache(job.scan,job.name,signature(),function()
                if SysTime()>=job.deadline then coroutine.yield() end
            end)
            if not record then error(err) end
            local raw=util.TableToJSON(record)
            if not raw or #raw>maxBytes then error("Cache trop volumineux") end
            local packed=util.Compress(raw)
            if not packed or #packed>maxBytes then error("Compression du cache refusee") end
            file.CreateDir(folder)
            local key=canonicalKey
            if not writeAtomic(folder.."/"..key,packed) then error("Ecriture du cache impossible") end
            file.Write(singleMarker,"1")
            record.key=key library={} library[key]={key=key,name=record.name}
            job.scan.savedKey=key job.scan.displayName=job.name job.scan.savedRevision=#record.history
            if job.scan.region.revision>#record.history then V.MarkZoneCacheDirty(job.scan) end
        end)
        local ok,err=coroutine.resume(job.thread)
        if not ok or coroutine.status(job.thread)=="dead" then
            job.scan.saving=nil table.remove(saveJobs,1)
            if not ok then ErrorNoHalt("[GVoxel] Sauvegarde : "..tostring(err).."\n") end
            if IsValid(job.ply) then V.Notify(job.ply,ok and "Zone sauvegardee." or tostring(err)) end
        end
        return
    end
    if CurTime()<nextRestore or #restoreJobs==0 then return end
    -- Restore serially; all zones share scan/collision preparation budgets.
    for _,scan in pairs(V.GetScanSessions()) do if not scan.completed then return end end
    nextRestore=CurTime()+0.25
    local key=table.remove(restoreJobs,1)
    V.ZoneRestorePending=#restoreJobs>0
    local record,err=read(key)
    if record then
        library={} library[key]={key=key,name=record.name}
        local active=false
        for _,scan in pairs(V.GetScanSessions()) do if scan.savedKey==key then active=true end end
        if not active then
            local scan,message=V.RestoreCachedZone(record)
            if not scan then ErrorNoHalt("[GVoxel] Cache "..key.." : "..tostring(message).."\n") end
        end
        restoreJobs={} V.ZoneRestorePending=false
    else ErrorNoHalt("[GVoxel] Cache "..key.." ignore : "..tostring(err).."\n") end
end)
