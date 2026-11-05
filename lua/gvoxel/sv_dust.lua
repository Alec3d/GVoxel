-- One bounded visual event when a crater is accepted, never per victim/tick.
local V=GVoxel
util.AddNetworkString("vm_blast_dust")
function V.EmitBlastDust(scan,work)
    if work.dustSent then return end
    local now=CurTime()
    if (scan.nextDust or 0)>now then return end
    scan.nextDust=now+0.1
    local r=scan.region
    local high=r.origin+V.RegionSize(r)
    local e=Vector(work.radius,work.radius,work.radius)
    local lo,hi=work.center-e,work.center+e
    for _,axis in ipairs({"x","y","z"}) do lo[axis]=math.max(lo[axis],r.origin[axis]) hi[axis]=math.min(hi[axis],high[axis]) end
    local p=(lo+hi)/2
    local radius=math.Clamp(work.radius,16,1024)
    local recipients={}
    for _,ply in ipairs(player.GetHumans()) do
        if ply:GetPos():DistToSqr(p)<(2048+radius)^2 then recipients[#recipients+1]=ply end
    end
    if #recipients==0 then return end
    net.Start("vm_blast_dust") net.WriteVector(p) net.WriteUInt(math.ceil(radius),11) net.WriteBool(work.source=="collapse") net.Send(recipients)
    work.dustSent=true
end
