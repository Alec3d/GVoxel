local V=GVoxel
util.AddNetworkString("vm_zones_list")
util.AddNetworkString("vm_zones_action")
function V.SendZoneLibrary(ply)
    if not V.CanManageScan(ply) then return end
    local entries={}
    for id,scan in pairs(V.GetScanSessions()) do
        entries[#entries+1]={id=id,name=scan.displayName or ("Zone "..id),key=scan.savedKey or "",
            status=scan.failed and "Erreur" or not scan.completed and "Preparation" or scan.saving and "Sauvegarde" or "Active"}
    end
    for key,record in pairs(V.GetZoneLibrary()) do
        local found=false
        for _,entry in ipairs(entries) do if entry.key==key then found=true break end end
        if not found then entries[#entries+1]={id=0,name=record.name,key=key,status="Sauvegardee"} end
    end
    table.sort(entries,function(a,b) return a.name<b.name end)
    net.Start("vm_zones_list")
    net.WriteUInt(math.min(48,#entries),6)
    for i=1,math.min(48,#entries) do
        local e=entries[i]
        net.WriteUInt(e.id,16) net.WriteString(e.name) net.WriteString(e.key) net.WriteString(e.status)
    end
    net.Send(ply)
end
net.Receive("vm_zones_list",function(_,ply)
    if not V.CanManageScan(ply) or (ply.VMZoneNextList or 0)>CurTime() then return end
    ply.VMZoneNextList=CurTime()+0.5 V.SendZoneLibrary(ply)
end)
net.Receive("vm_zones_action",function(length,ply)
    if length>2048 or not V.CanManageScan(ply) or (ply.VMZoneNextAction or 0)>CurTime() then return end
    ply.VMZoneNextAction=CurTime()+0.5
    local action=net.ReadString()
    local id=net.ReadUInt(16)
    local key,name=net.ReadString(),net.ReadString()
    if #key>80 or #name>64 then return end
    local ok,err=V.ZoneLibraryAction(ply,action,id,key,name)
    if not ok then V.Notify(ply,err or "Action refusee ; verifier que la zone est libre.") end
    if action~="load" or not ok then V.SendZoneLibrary(ply) end
end)
