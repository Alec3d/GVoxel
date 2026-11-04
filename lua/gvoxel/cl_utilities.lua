local V=GVoxel
local panels=setmetatable({},{__mode="k"})
local entries={}
local function refresh()
    net.Start("vm_zones_list") net.SendToServer()
end
net.Receive("vm_zones_list",function()
    entries={}
    local count=net.ReadUInt(6)
    for _=1,count do entries[#entries+1]={id=net.ReadUInt(16),name=net.ReadString(),key=net.ReadString(),status=net.ReadString()} end
    for panel in pairs(panels) do
        if IsValid(panel) and IsValid(panel.ZoneList) then
            local selected=panel.ZoneList:GetSelectedLine()
            local old=selected and panel.ZoneList:GetLine(selected)
            local id,key=old and old.Zone.id,old and old.Zone.key
            panel.ZoneList:Clear()
            for _,entry in ipairs(entries) do
                local line=panel.ZoneList:AddLine(entry.name,entry.status)
                line.Zone=entry
                if entry.id==id and entry.key==key then panel.ZoneList:SelectItem(line) end
            end
        end
    end
end)
hook.Add("AddToolMenuCategories","GVoxel.UtilitiesCategory",function()
    spawnmenu.AddToolCategory("Utilities","GVoxel","GVoxel")
end)
hook.Add("PopulateToolMenu","GVoxel.UtilitiesZones",function()
    spawnmenu.AddToolMenuOption("Utilities","GVoxel","GVoxelZones","Zones persistantes","","",function(panel)
        if not IsValid(LocalPlayer()) or not LocalPlayer():IsAdmin() then
            panel:ClearControls() panel:Help("Outils reserves aux administrateurs.") return
        end
        panel:ClearControls() panels[panel]=true
        panel:Help("Une seule zone par map. Calcul et sauvegarde automatiques, puis restauration aux parties suivantes. Outils reserves aux administrateurs.")
        panel:Button("Obtenir l'outil de selection","vm_give")
        panel:Button("Dimensions / boite personnalisee","vm_menu")
        panel:Button("Analyser une nouvelle zone (R court)","vm_scan")
        panel:Help("Viser avec l'outil, fermer le menu puis appuyer sur R pour creer une zone. Creuser / ajouter : clic gauche / droit.")
        local list=vgui.Create("DListView",panel)
        list:SetTall(180) list:AddColumn("Zone") list:AddColumn("Etat")
        panel:AddItem(list) panel.ZoneList=list
        local name=vgui.Create("DTextEntry",panel)
        name:SetPlaceholderText("Nom de la sauvegarde") panel:AddItem(name)
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
                if kind=="delete" then Derma_Query("Supprimer cette sauvegarde ? La zone active reste en place.","GVoxel","Supprimer",send,"Annuler")
                else send() end
            end
        end
        action("Enregistrer maintenant / renommer","save")
        action("Activer la sauvegarde","load",true)
        action("Retirer la zone active","remove")
        action("Supprimer la sauvegarde","delete",true)
        local button=vgui.Create("DButton",panel) button:SetText("Actualiser") button.DoClick=refresh panel:AddItem(button)
        panel:Help("Le cache garde le releve et les modifications. Les maillages et corps physiques natifs sont prepares sous budget au chargement.")
        refresh()
        local nextPoll=0
        panel.Think=function(self)
            if self:IsVisible() and RealTime()>=nextPoll then nextPoll=RealTime()+2 refresh() end
        end
    end)
end)
