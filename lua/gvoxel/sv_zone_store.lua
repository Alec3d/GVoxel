-- DATA files are runtime saves, not development sources. Work is queued outside net hooks.
local V=GVoxel
local restoreKeys={}
local saveJob,restoreJob
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
local function checkpoint(job)
    if SysTime()>=job.deadline then coroutine.yield() end
end
local function read(job)
    local path=folder.."/"..job.key
    local size=file.Size(path,"DATA")
    if not size or size<1 or size>maxBytes then return nil,"Cache absent ou trop volumineux." end
    local data=file.Read(path,"DATA")
    if type(data)~="string" or #data~=size then return nil,"Cache illisible." end
    coroutine.yield()
    local ok,raw=pcall(util.Decompress,data,maxBytes)
    if not ok or type(raw)~="string" or #raw>maxBytes then return nil,"Compression du cache invalide." end
    data=nil
    coroutine.yield()
    -- One density field already contains 35,937 entries, above GMod's default
    -- 15,000-key JSON limit. This local cache is byte-bounded above and its
    -- complete schema/field/journal is validated below before restoration.
    local parsed,record=pcall(util.JSONToTable,raw,true)
    if not parsed then return nil,"JSON du cache invalide." end
    raw=nil
    coroutine.yield()
    local valid,err=V.ValidateZoneCache(record,game.GetMap(),signature(),function() checkpoint(job) end)
    if not valid then return nil,err or "Cache illisible." end
    valid.key=job.key
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
function V.SaveZone(scan,name,ply,withoutEdits)
    if not scan or not scan.completed or scan.failed or not scan.snapshot or scan.editWork then
        return false,"Zone non prete ou modification en cours."
    end
    if saveJob then return false,"Sauvegarde deja en cours." end
    if name=="" then name=nil end
    name=tostring(name or scan.displayName or ("Zone "..scan.region.id)):gsub("%c",""):sub(1,64)
    if name=="" then name="Zone "..scan.region.id end
    scan.saving=true
    -- The initial density and committed journal prefix are immutable. Edits
    -- made while this job yields must not change the requested snapshot.
    saveJob={scan=scan,name=name,ply=ply,revision=withoutEdits and 0 or scan.region.revision}
    return true
end
local function updateRestorePending()
    V.ZoneRestorePending=restoreJob~=nil or #restoreKeys>0
end
updateRestorePending()
function V.ZoneLibraryAction(ply,action,id,key,name)
    if not V.CanManageScan(ply) then return false,"Administration requise." end
    if action=="save" or action=="save_clean" then
        if id==0 then return false,"Zone non prete ou modification en cours." end
        return V.SaveZone(V.GetScanSession(id),name,ply,action=="save_clean")
    end
    if action=="delete_zone" then
        local scan=V.GetScanSession()
        if id~=(scan and scan.region.id or 0) then return false,"Zone non prete ou modification en cours." end
        if scan then
            local released,err=V.CancelScan(ply,id)
            if not released then return false,err end
        end
        if saveJob then saveJob.scan.saving=nil saveJob=nil end
        restoreKeys,restoreJob={},nil
        updateRestorePending()
        local failed=false
        for _,name in ipairs(file.Find(folder.."/zone_*.dat","DATA") or {}) do
            local key=name:match("^(zone_%d+_%d+%.dat)%.%a+%.dat$") or name
            if keyValid(key) then
                local path=folder.."/"..name
                file.Delete(path)
                if file.Exists(path,"DATA") then failed=true end
            end
        end
        if failed then return false,"Suppression de la sauvegarde impossible." end
        return true
    end
    return false,"Action inconnue."
end
local nextRestore=0
local function discover()
    file.CreateDir(folder)
    for _,backup in ipairs(file.Find(folder.."/zone_*.previous.dat","DATA") or {}) do
        local key=backup:gsub("%.previous%.dat$","")
        if keyValid(key) and not file.Exists(folder.."/"..key,"DATA") then file.Rename(folder.."/"..backup,folder.."/"..key) end
    end
    local names=file.Find(folder.."/zone_*.dat","DATA") or {}
    restoreKeys={} restoreJob=nil nextRestore=0
    if file.Exists(folder.."/"..canonicalKey,"DATA") then names={canonicalKey}
    elseif file.Exists(singleMarker,"DATA") then names={}
    elseif file.Time then
        table.sort(names,function(a,b) return file.Time(folder.."/"..a,"DATA")>file.Time(folder.."/"..b,"DATA") end)
    end
    -- Old multi-zone files are retained, but only the first valid legacy cache
    -- may migrate. Subsequent saves use one canonical file for this map.
    for _,key in ipairs(names) do
        if keyValid(key) and #restoreKeys<32 then restoreKeys[#restoreKeys+1]=key end
    end
    updateRestorePending()
end
hook.Add("InitPostEntity","GVoxel.LoadZoneCaches",discover)
hook.Add("PostCleanupMap","GVoxel.RestoreZoneCaches",discover)
local function save(job)
    local bsp=signature()
    if not bsp then error("Zone ou BSP non pret.",0) end
    local record,err=V.MakeZoneCache(job.scan,job.name,bsp,function() checkpoint(job) end,job.revision)
    if not record then error(err,0) end
    -- Native JSON, compression and the atomic write cannot yield internally.
    -- Give each its own tick after the cooperative record preparation.
    coroutine.yield()
    local raw=util.TableToJSON(record)
    if not raw or #raw>maxBytes then error("Cache trop volumineux",0) end
    coroutine.yield()
    local packed=util.Compress(raw)
    if not packed or #packed>maxBytes then error("Compression du cache refusee",0) end
    raw=nil
    coroutine.yield()
    file.CreateDir(folder)
    local key=canonicalKey
    if not writeAtomic(folder.."/"..key,packed) then error("Ecriture du cache impossible",0) end
    file.Write(singleMarker,"1")
    job.scan.savedKey=key job.scan.displayName=job.name
end
local function resume(job,work,deadline)
    job.deadline=deadline or SysTime()+0.001
    if not job.thread then job.thread=coroutine.create(work) end
    return coroutine.resume(job.thread,job)
end
local function finishSave(job,ok,err)
    job.scan.saving=nil saveJob=nil
    if not ok then ErrorNoHalt("[GVoxel] Sauvegarde : "..tostring(err).."\n") end
end

hook.Add("ShutDown","GVoxel.FinishRequestedSave",function()
    local job=saveJob
    if not job or V.GetScanSession()~=job.scan then return end
    local ok,err
    repeat
        ok,err=resume(job,save,math.huge)
    until not ok or coroutine.status(job.thread)=="dead"
    finishSave(job,ok,err)
end)

hook.Add("Think","GVoxel.ZoneStorage",function()
    local scan=V.GetScanSession()
    local job=saveJob
    if job then
        if scan~=job.scan then
            job.scan.saving=nil saveJob=nil return
        end
        local ok,err=resume(job,save)
        if not ok or coroutine.status(job.thread)=="dead" then
            finishSave(job,ok,err)
            if IsValid(job.ply) then
                V.Notify(job.ply,ok and "Zone sauvegardee." or tostring(err))
            end
        end
        return
    end
    if not restoreJob then
        if CurTime()<nextRestore or #restoreKeys==0 or (scan and not scan.completed) then return end
        restoreJob={key=table.remove(restoreKeys,1)}
    end
    job=restoreJob
    local ok,record,err=resume(job,read)
    if ok and coroutine.status(job.thread)~="dead" then return end
    if not ok then err=record record=nil end
    if record then
        if not scan or scan.savedKey~=job.key then
            local _,message=V.RestoreCachedZone(record)
            err=message
        end
        restoreKeys={}
    end
    restoreJob=nil nextRestore=CurTime()+0.25 updateRestorePending()
    if err then
        ErrorNoHalt("[GVoxel] Cache "..job.key.." ignore : "..tostring(err).."\n")
    end
end)
