local V=GVoxel
local panels=setmetatable({},{__mode="k"})
local languagePanels=setmetatable({},{__mode="k"})
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
    panel.LanguageSelection=row and panel.ZoneList:GetLine(row).Zone
    panels[panel]=true
    if not IsValid(LocalPlayer()) or not LocalPlayer():IsAdmin() then
        panel:ClearControls() panel.ZoneList=nil panel.ZoneName=nil panel.Think=nil
        panel:Help(V.L("Outils reserves aux administrateurs.")) return
    end
    panel:ClearControls()
    panel:Help(V.L("Une seule zone par map. Calcul et sauvegarde automatiques, puis restauration aux parties suivantes. Outils reserves aux administrateurs."))
    panel:Button(V.L("Obtenir l'outil de selection"),"vm_give")
    panel:Button(V.L("Dimensions / boite personnalisee"),"vm_menu")
    panel:Button(V.L("Analyser une nouvelle zone (R court)"),"vm_scan")
    panel:Help(V.L("Viser avec l'outil, fermer le menu puis appuyer sur R pour creer une zone. Creuser / ajouter : clic gauche / droit."))
    local list=vgui.Create("DListView",panel)
    list:SetTall(180) list:AddColumn(V.L("Zone")) list:AddColumn(V.L("Etat"))
    panel:AddItem(list) panel.ZoneList=list
    local name=vgui.Create("DTextEntry",panel)
    panel.ZoneName=name
    name:SetPlaceholderText(V.L("Nom de la sauvegarde")) panel:AddItem(name)
    name:SetText(oldName)
    local function selected() local row=list:GetSelectedLine() return row and list:GetLine(row).Zone end
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
local function buildLanguage(panel)
    languagePanels[panel]=true
    panel:ClearControls()
    panel:Help(V.L("Choose your language. Changes apply immediately."))
    local choice=vgui.Create("DComboBox",panel)
    choice:SetTall(28)
    for _,option in ipairs(V.LanguageOptions) do
        choice:AddChoice(option[2],option[1],option[1]==V.GetLanguage())
    end
    choice.OnSelect=function(_,_,_,code)
        RunConsoleCommand("gvoxel_language",V.ValidLanguage(code))
    end
    panel:AddItem(choice)
end
hook.Add("GVoxel.LanguageChanged","GVoxel.UtilitiesLanguage",function()
    for panel in pairs(panels) do
        if IsValid(panel) then buildZones(panel) end
    end
    for panel in pairs(languagePanels) do
        if IsValid(panel) then buildLanguage(panel) end
    end
end)
hook.Add("PopulateToolMenu","GVoxel.UtilitiesZones",function()
    spawnmenu.AddToolMenuOption("Utilities","GVoxel","GVoxelLanguage","#gvoxel.language","","",buildLanguage)
    spawnmenu.AddToolMenuOption("Utilities","GVoxel","GVoxelZones","#gvoxel.zones","","",function(panel)
        buildZones(panel)
        if IsValid(LocalPlayer()) and LocalPlayer():IsAdmin() then refresh() end
    end)
end)
