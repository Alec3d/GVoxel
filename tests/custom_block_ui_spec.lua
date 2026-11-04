-- Exercise the actual client input/menu/preview modules without controlling GMod.
function RunCustomBlockUITests(customChunk,toolChunk)
    local names={"GVoxel","CreateClientConVar","CreateMaterial","RunConsoleCommand","IsValid","LocalPlayer",
        "input","gui","vgui","hook","concommand","net","render","angle_zero","RealTime","IN_RELOAD","MOUSE_MIDDLE"}
    local saved={} for _,name in ipairs(names) do saved[name]={value=_G[name]} end
    local original=GVoxel local V={} for k,value in pairs(original) do V[k]=value end
    GVoxel=V V.CloseScanMenu=nil
    local f={vars={vm_custom_block=1,vm_show_zone=1},hooks={},commands={},panels={},sent={},mouse=false,ui=false,
        start=Vector(800,800,250),direction=Vector(-1,-1,0):GetNormalized(),rays=0,boxes=0,notices=0}
    local weapon={GetClass=function() return "weapon_voxel_crowbar" end,GetBrushRadius=function() return 48 end}
    local ply={GetActiveWeapon=function() return weapon end,Alive=function() return true end,KeyDown=function() return false end,
        GetShootPos=function() return f.start end,GetAimVector=function() return f.direction end,ChatPrint=function() f.notices=f.notices+1 end}
    IsValid=function(e) return type(e)=="table" and e.valid~=false end
    LocalPlayer=function() return ply end RealTime=function() return 100 end
    MOUSE_MIDDLE=3 IN_RELOAD=8192 angle_zero={}
    CreateClientConVar=function(name,default)
        if f.vars[name]==nil then f.vars[name]=tonumber(default) end
        return {GetInt=function() return f.vars[name] end,GetBool=function() return f.vars[name]~=0 end,GetFloat=function() return f.vars[name] end}
    end
    RunConsoleCommand=function(name,value) f.vars[name]=tonumber(value) end
    CreateMaterial=function() return {} end
    input={IsMouseDown=function(key) assert(key==MOUSE_MIDDLE) return f.mouse end}
    gui={IsGameUIVisible=function() return false end,IsConsoleVisible=function() return false end}
    local noop=function() end
    vgui={CursorVisible=function() return f.ui end,Create=function(kind,parent)
        local p={kind=kind,parent=parent,Center=noop,SetTitle=noop,SetDeleteOnClose=noop,SetWrap=noop,
            SetMin=noop,SetMax=noop,SetDecimals=noop}
        function p:SetSize(w,h) self.width=w self.height=h end
        function p:SetPos(x,y) self.x=x self.y=y end
        function p:SetText(text) self.text=text end
        function p:SetConVar(name) self.convar=name end
        function p:SetValue(value) self.value=value end
        function p:GetValue() return self.value end
        function p:MakePopup() f.ui=true end
        function p:Remove() self.valid=false f.ui=false end
        f.panels[#f.panels+1]=p return p
    end}
    hook={Add=function(_,name,fn) f.hooks[name]=fn end}
    concommand={Add=function(name,fn) f.commands[name]=fn end}
    local writing
    net={Start=function(name) writing={name=name,data={}} end,
        WriteUInt=function(value) writing.data[#writing.data+1]=value end,
        WriteVector=function(value) writing.data[#writing.data+1]=value end,
        SendToServer=function() f.sent[#f.sent+1]=writing writing=nil end}
    render={DrawWireframeBox=function() f.boxes=f.boxes+1 end,DrawWireframeSphere=noop,DrawLine=noop}
    V.GetClientScanState=function() return nil end
    V.Trace=function() f.rays=f.rays+1 return {HitWorld=f.hit~=nil,HitPos=f.hit} end
    V.ApplyBrush=function() error("preview ran a terrain edit") end
    V.BuildChunk=function() error("preview rebuilt terrain") end
    local ok,err=pcall(function()
        customChunk() toolChunk()
        local think=f.hooks["GVoxel.CustomBlockSelection"]
        local function click(hit)
            if hit then f.direction=(hit-f.start):GetNormalized() end
            f.hit=hit f.mouse=false think() f.mouse=true think()
            for _=1,3 do think() end -- Held middle button is one click only.
            f.mouse=false think()
        end
        f.commands.vm_scan()
        assert(#f.sent==0 and f.notices==1,"incomplete selection was sent to the server")
        click(Vector(-100,-200,0)) click(Vector(500,900,80)) click(Vector(10,100,75))
        f.direction=(Vector(500,100,150)-f.start):GetNormalized()
        click(nil)
        local state,preview=V.GetCustomBlockSelection()
        assert(#state.points==4 and preview.bounds,"four real input edges did not define the custom box")
        f.commands.vm_scan()
        local packet=f.sent[#f.sent]
        assert(packet.name=="vm_scan_custom" and #packet.data==2 and packet.data[1]:DistToSqr(Vector(-100,-200,0))<1e-8)
        local rays=f.rays
        for _=1,40 do think() f.hooks["GVoxel.PlacementPreview"]() end
        assert(f.rays==rays,"stationary custom cursor repeats native traces every frame")
        f.hooks["GVoxel.SelectionCube"](false,false,false)
        assert(f.rays==rays and f.boxes>0,"selection draw traces or does not display the box")
        V.OpenScanMenu()
        local custom
        for _,panel in ipairs(f.panels) do if panel.convar=="vm_custom_block" then custom=panel end end
        assert(custom,"actual menu lacks the custom-block checkbox")
        f.mouse=true think() V.CloseScanMenu(false) think()
        assert(not state.moving,"held click leaked from the menu into box movement")
        f.mouse=false think()
        click(Vector(0,0,0)) assert(state.moving)
        f.hit=Vector(100,-50,25) think()
        click(f.hit) assert(not state.moving)
        f.commands.vm_scan() packet=f.sent[#f.sent]
        assert(packet.data[1]:DistToSqr(Vector(0,-250,25))<1e-8,"moved selection sends different bounds from its preview")
        V.UndoCustomBlockSelection() assert(#state.points==3)
        V.ResetCustomBlockSelection() state=V.GetCustomBlockSelection() assert(#state.points==0)
        print("PASS: actual custom-block menu/input/request/render paths handle four middle-click edges, focus gating, movement, lock/undo/reset and cached previews without geometry or draw-time traces")
    end)
    for name,row in pairs(saved) do _G[name]=row.value end
    if not ok then error(err,0) end
end
