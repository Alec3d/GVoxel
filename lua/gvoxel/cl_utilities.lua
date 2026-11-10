local V=GVoxel
local panels=setmetatable({},{__mode="k"})
local savedWindow
local entries={}
local function refresh()
    net.Start("vm_zones_list") net.SendToServer()
end
local function fillLists()
    for panel in pairs(panels) do
        if IsValid(panel) and IsValid(panel.ZoneList) then
            local selected=panel.ZoneList:GetSelectedLine()
            local old=selected and panel.ZoneList:GetLine(selected)
            local previous=old and old.Zone or panel.LanguageSelection
            local id,key=previous and previous.id,previous and previous.key
            local draft=IsValid(panel.ZoneName) and panel.ZoneName:GetValue()
            panel.LanguageSelection=nil
            panel.ZoneList:Clear()
            for _,entry in ipairs(entries) do
                local line=panel.ZoneList:AddLine(entry.name,V.L(entry.status))
                line.Zone=entry
                if entry.id==id and entry.key==key then panel.ZoneList:SelectItem(line) end
            end
            if draft then panel.ZoneName:SetText(draft) end
        end
    end
end
net.Receive("vm_zones_list",function()
    entries={}
    local count=net.ReadUInt(6)
    for _=1,count do entries[#entries+1]={id=net.ReadUInt(16),name=net.ReadString(),key=net.ReadString(),status=net.ReadString()} end
    fillLists()
end)
hook.Add("AddToolMenuCategories","GVoxel.UtilitiesCategory",function()
    spawnmenu.AddToolCategory("Utilities","GVoxel","GVoxel")
end)
local function buildZones(panel)
    local oldName=IsValid(panel.ZoneName) and panel.ZoneName:GetValue() or ""
    local row=IsValid(panel.ZoneList) and panel.ZoneList:GetSelectedLine()
    local line=row and panel.ZoneList:GetLine(row)
    panel.LanguageSelection=line and line.Zone
    panels[panel]=true
    panel:Clear()
    local ply=LocalPlayer()
    if not IsValid(ply) or not ply:IsAdmin() then
        panel.ZoneList=nil panel.ZoneName=nil panel.Think=nil
        panel:Help(V.L("Outils reserves aux administrateurs.")) return
    end
    local list=vgui.Create("DListView",panel)
    list:SetTall(180) list:AddColumn(V.L("Zone")) list:AddColumn(V.L("Etat"))
    panel:AddItem(list) panel.ZoneList=list
    local name=vgui.Create("DTextEntry",panel)
    panel.ZoneName=name
    name:SetPlaceholderText(V.L("Nom de la sauvegarde")) panel:AddItem(name)
    name:SetText(oldName)
    local function selected()
        local row=list:GetSelectedLine()
        local line=row and list:GetLine(row)
        return line and line.Zone
    end
    list.OnRowSelected=function(_,_,line) name:SetText(line.Zone.name) end
    local function action(label,kind,needsKey)
        local button=vgui.Create("DButton",panel) button:SetText(label) panel:AddItem(button)
        button.DoClick=function()
            local entry=selected()
            if not entry or needsKey and entry.key=="" then return end
            local function send()
                net.Start("vm_zones_action") net.WriteString(kind) net.WriteUInt(entry.id,16)
                net.WriteString(entry.key) net.WriteString(name:GetValue():sub(1,64)) net.SendToServer()
            end
            if kind=="delete" then Derma_Query(V.L("Supprimer cette sauvegarde ? La zone active reste en place."),"GVoxel",V.L("Supprimer"),send,V.L("Annuler"))
            else send() end
        end
    end
    action(V.L("Enregistrer maintenant / renommer"),"save")
    action(V.L("Activer la sauvegarde"),"load",true)
    action(V.L("Retirer la zone active"),"remove")
    action(V.L("Supprimer la sauvegarde"),"delete",true)
    local button=vgui.Create("DButton",panel) button:SetText(V.L("Actualiser")) button.DoClick=refresh panel:AddItem(button)
    panel:Help(V.L("Le cache garde le releve et les modifications. Les maillages et corps physiques natifs sont prepares sous budget au chargement."))
    fillLists()
    local nextPoll=0
    panel.Think=function(self)
        if self:IsVisible() and RealTime()>=nextPoll then nextPoll=RealTime()+2 refresh() end
    end
end
function V.OpenSavedZones()
    if not V.GetActiveVoxelTool() then return end
    if IsValid(savedWindow) then savedWindow:MakePopup() return end
    local frame = vgui.Create("DFrame")
    savedWindow = frame
    frame:SetSize(math.min(465, ScrW() - 16), 440)
    frame:Center()
    frame:SetTitle(V.L("Zones sauvegardees"))
    frame:MakePopup()
    frame.Think = function(self)
        if not V.GetActiveVoxelTool() then self:Close() end
    end
    local panel = vgui.Create("DForm", frame)
    panel:Dock(FILL)
    panel:SetName("")
    buildZones(panel)
    refresh()
end

hook.Add("GVoxel.LanguageChanged", "GVoxel.UtilitiesLanguage", function()
    if IsValid(savedWindow) then savedWindow:SetTitle(V.L("Zones sauvegardees")) end
    for panel in pairs(panels) do
        if IsValid(panel) then buildZones(panel) end
    end
end)

hook.Add("PopulateToolMenu", "GVoxel.UtilitiesZones", function()
    spawnmenu.AddToolMenuOption("Utilities", "GVoxel", "GVoxelZones", "#gvoxel.zones", "", "", function(panel)
        panel:Help(V.L("Ctrl+H avec l'outil en main"))
        if LocalPlayer():IsAdmin() then
            panel:Button(V.L("Nouvelle zone"), "vm_give")
        end
    end)
end)
