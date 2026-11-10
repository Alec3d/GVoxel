-- Deferred cleanup uses ordinary authoritative edits: meshes, native collisions,
-- late joins and saved journals all follow the existing atomic publication path.
local V=GVoxel
local axes={"x","y","z"}
local enabled=CreateConVar("vm_detached_cleanup","1",FCVAR_ARCHIVE,"Gradually remove detached voxel fragments",0,1)
function V.ScheduleDetachedCleanup(scan,work)
    if work.source=="collapse" then return end
    local previous=scan.detached
    scan.detached=nil
    if not enabled:GetBool() then return end
    local r=scan.region
    local q=(work.center-r.origin)/r.step
    local span=math.ceil(work.radius/r.step)+1
    scan.detached={revision=r.revision,low=Vector(math.floor(q.x)-span,math.floor(q.y)-span,math.floor(q.z)-span),
        high=Vector(math.floor(q.x)+span,math.floor(q.y)+span,math.floor(q.z)+span),pending={},nextAt=CurTime()+0.15}
    if previous then
        for _,axis in ipairs(axes) do
            scan.detached.low[axis]=math.min(scan.detached.low[axis],previous.low[axis])
            scan.detached.high[axis]=math.max(scan.detached.high[axis],previous.high[axis])
        end
    end
end
hook.Add("Think","GVoxel.DetachedCleanup",function()
    local scan=V.GetScanSession()
    local state=scan and scan.detached
    if not state or scan.failed or not enabled:GetBool() then if scan then scan.detached=nil end return end
    if scan.editWork or not scan.completed then return end
    local r=scan.region
    if state.thread and state.revision~=r.revision then scan.detached=nil return end
    state.thread=state.thread or (not state.ready and coroutine.create(function()
        local function checkpoint() if SysTime()>=state.deadline then coroutine.yield() end end
        local components, lookup = V.FindDetachedComponents(r,state.low,state.high,checkpoint)
        for _, component in ipairs(components) do
            local allowed, groups, byCell = {lookup=lookup}, {}, {}
            for _, piece in ipairs(component) do
                allowed[piece.hull] = true
                local group = byCell[piece.key]
                local low = piece.low or Vector(piece.x,piece.y,piece.z)*r.step
                local high = piece.high or low+Vector(r.step,r.step,r.step)
                if not group then
                    group={x=piece.x,y=piece.y,z=piece.z,low=Vector(low.x,low.y,low.z),high=Vector(high.x,high.y,high.z)}
                    byCell[piece.key]=group groups[#groups+1]=group
                end
                for _, axis in ipairs(axes) do
                    group.low[axis]=math.min(group.low[axis],low[axis])
                    group.high[axis]=math.max(group.high[axis],high[axis])
                    state.low[axis]=math.min(state.low[axis],piece[axis])
                    state.high[axis]=math.max(state.high[axis],piece[axis])
                end
                checkpoint()
            end
            local function queueBounds(bounds)
                local center,radius=V.DetachedCellStroke(r,bounds)
                local plane=V.DetachedRemovalPlane(r,center,radius,bounds,allowed,checkpoint)
                if plane or V.DetachedRemovalSafe(r,center,radius,allowed,checkpoint) then
                    state.pending[#state.pending+1]={center=center,radius=radius,allowed=allowed,plane=plane}
                    return true
                end
            end
            local combined=false
            if #groups<=8 then
                local low,high=Vector(math.huge,math.huge,math.huge),Vector(-math.huge,-math.huge,-math.huge)
                for _, group in ipairs(groups) do
                    for _, axis in ipairs(axes) do
                        low[axis]=math.min(low[axis],group.low[axis])
                        high[axis]=math.max(high[axis],group.high[axis])
                    end
                    checkpoint()
                end
                combined=queueBounds({low=low,high=high})
            end
            if not combined then
                for _, group in ipairs(groups) do queueBounds(group) checkpoint() end
            end
        end
        state.ready=true
    end))
    if state.thread then
        state.deadline=SysTime()+0.001
        local ok,err=coroutine.resume(state.thread)
        if not ok then scan.detached=nil ErrorNoHalt("[GVoxel] Fragment cleanup stopped: "..tostring(err).."\n") return end
        if coroutine.status(state.thread)~="dead" then return end
        state.thread=nil
    end
    if CurTime()<state.nextAt or (scan.explosions and #scan.explosions>0) or not V.ScanPeersReady(scan,r.revision) then return end
    local cursor=state.cursor or 1
    local stroke=state.pending[cursor]
    state.pending[cursor]=false state.cursor=cursor+1
    if not stroke then scan.detached=nil return end
    state.nextAt=CurTime()+0.15
    V.QueueTerrainExplosion(nil,{center=stroke.center,radius=stroke.radius,seed=0,source="collapse",system=true,zoneID=r.id,plane=stroke.plane,
        prepare=function(work,field,check)
            return scan.detached==state and V.DetachedRemovalSafe(field,work.center,work.radius,stroke.allowed,check,work.plane)
        end})
end)
