local V=GVoxel
util.AddNetworkString("vm_zones_action")
net.Receive("vm_zones_action",function(length,ply)
    if length>2048 or not V.CanManageScan(ply) or (ply.VMZoneNextAction or 0)>CurTime() then return end
    ply.VMZoneNextAction=CurTime()+0.5
    local action=net.ReadString()
    local id=net.ReadUInt(16)
    local key,name=net.ReadString(),net.ReadString()
    if #key>80 or #name>64 then return end
    local ok,err=V.ZoneLibraryAction(ply,action,id,key,name)
    if not ok then V.Notify(ply,err or "Action refusee ; verifier que la zone est libre.") end
    if ok and action=="delete_zone" then V.Notify(ply,"Zone supprimee.") end
end)
