local V=GVoxel
function RunExteriorOcclusionTests()
    local originalValid=IsValid
    IsValid=function(entity) return type(entity)=="table" and entity.valid~=false end
    local r=V.NewScanRegion(9900,Vector(),16)
    local eye=Vector(0,0,100)
    local low,high=Vector(500,-10,80),Vector(520,10,120)
    local target={} local observer={}
    local calls=0 local wall=true
    local function trace(data)
        calls=calls+1
        assert(not data.ignoreworld,"visibility ray disables the whole map BSP")
        assert(data.start.x>r.side/2 and data.endpos.x>=500,"visibility ray starts in the removed BSP")
        assert(data.filter[1]==observer,"observer not excluded")
        return wall and {Hit=true,HitWorld=true,Fraction=0.25,Entity={}}
            or {Hit=true,Fraction=0.9,Entity=target}
    end
    local function test(from,actor,lo,hi,native,budget)
        return V.ExteriorLineOfSight(r,from,actor,lo,hi,observer,native,budget)
    end
    assert(not test(eye,target,low,high,trace),"outside prop visible through an opaque native wall")
    assert(calls==9,"occluded object does not use bounded centre/corner samples")
    wall=false calls=0
    assert(test(eye,target,low,high,trace) and calls==1,"directly visible prop is hidden or repeats rays")
    calls=0
    local partial=function(data)
        calls=calls+1
        return data.endpos.y<0 and {Hit=true,Entity=target,Fraction=0.9}
            or {Hit=true,HitWorld=true,Fraction=0.3}
    end
    assert(test(eye,target,low,high,partial),"visible side hidden because its centre is occluded")
    assert(not test(eye,target,low,high,function() return {Hit=false,StartSolid=true} end),"solid outside exit ignored")
    assert(not test(eye,target,low,high,function() return {Hit=true} end),"unknown blocker treated as target ancestry")
    assert(not test(eye,target,low,high,function() return {Hit=true,Entity={GetParent=function() return nil end}} end),
        "unrelated prop does not occlude exterior target")
    local child={GetParent=function() return target end}
    assert(test(eye,target,low,high,function() return {Hit=true,Entity=child,Fraction=0.7} end),"own attachment treated as an unrelated blocker")
    -- GMod NULL is truthy and still exposes Entity methods. Those methods
    -- throw when called, including the parent of a valid unparented entity.
    local nullCalls=0
    local null={valid=false,GetParent=function()
        nullCalls=nullCalls+1 error("Tried to use a NULL entity!")
    end}
    local root={GetParent=function() return null end}
    local unrelated={GetParent=function() return null end}
    local function hit(entity) return function() return {Hit=true,Entity=entity} end end
    local ok,result=pcall(function()
        assert(not test(eye,root,low,high,hit(null)),"NULL trace entity counted as the target")
        assert(not test(eye,root,low,high,hit(unrelated)),"unrelated unparented blocker became visible")
        assert(not test(eye,null,low,high,hit(null)),"two NULL entities counted as related")
        local attached={GetParent=function() return root end}
        assert(test(eye,root,low,high,hit(attached)),"valid child no longer matches its root")
        assert(test(eye,attached,low,high,hit(root)),"valid parent no longer matches its child")
    end)
    assert(ok,result)
    assert(nullCalls==0,"visibility traversal called an Entity method on NULL")
    print("PASS: exterior LOS never calls GetParent on truthy NULL trace hits or NULL parent termini, rejects invalid identity and retains valid attachment relationships")
    local before=calls
    assert(not test(eye,target,low,high,trace,function() return false end),"budget exhaustion reveals an unchecked prop")
    assert(calls==before,"exhausted budget still launches rays")
    local spent=0
    local incomplete=test(eye,target,low,high,function() return {Hit=true,HitWorld=true} end,function()
        spent=spent+1 return spent<=3
    end)
    assert(incomplete==nil and spent==4,"partial occlusion proof was cached as a completed decision")
    local behind=Vector(-1000,0,100) calls=0
    local foreground=function(data)
        calls=calls+1
        assert(data.start.x==behind.x and data.endpos.x<r.origin.x,"foreground BSP was skipped before the cage")
        return {Hit=true,HitWorld=true,Fraction=0.2}
    end
    assert(not test(behind,target,low,high,foreground),"foreground wall before cage ignored")
    IsValid=originalValid
    print("PASS: exterior LOS keeps native walls/props/doors after the cage and foreground before it, permits open/partial views and own attachments, rejects solid starts and hides unchecked objects at the ray budget")
end
