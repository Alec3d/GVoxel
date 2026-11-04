-- Actual dictionaries and client callbacks, with engine UI adapters only.
function RunLocalizationTests(clientChunk)
    local V=GVoxel
    local count=0
    for key,entry in pairs(V.Translations) do
        count=count+1
        for _,option in ipairs(V.LanguageOptions) do
            local code=option[1]
            assert(type(entry[code])=="string" and #entry[code]>0,"missing "..code..": "..key)
            -- Validate printf argument order and literal percentage escaping.
            local function signature(text)
                local result={}
                text=text:gsub("%%%%", "")
                for token in text:gmatch("%%[%d%.]*([dfs])") do result[#result+1]=token end
                return table.concat(result,",")
            end
            assert(signature(entry.en)==signature(entry[code]),"format changed: "..code.." / "..key)
        end
    end
    assert(count>=100)
    assert(V.L("Zones persistantes")=="Persistent zone")
    assert(V.Localize("Supprimer","ru")=="Удалить")
    assert(V.Localize("Supprimer","../../bad.lua")=="Delete")
    assert(V.Localize("user-provided-zone-name","es")=="user-provided-zone-name")
    assert(V.Localize("Analyse de la zone : %d %%","en",42)=="Scanning zone: 42 %")
    print("PASS: six complete localization dictionaries, matching format arguments, English default and safe unknown-language fallback")

    local names={"CLIENT","CreateClientConVar","cvars","language","hook","spawnmenu","vgui","net",
        "LocalPlayer","IsValid","RealTime","RunConsoleCommand"}
    local saved={} for _,name in ipairs(names) do saved[name]={value=_G[name]} end
    local original={} for key,value in pairs(V) do original[key]=value end
    local callbacks,phrases,hooks,options={},{},{},{}
    local selected="en"
    local creations=0
    local admin=false
    local ply={IsAdmin=function() return admin end}
    local function panel()
        local p={items={},valid=true}
        function p:ClearControls() self.items={} end
        function p:Help(text) self.items[#self.items+1]={text=text} end
        function p:AddItem(child) self.items[#self.items+1]=child end
        function p:Button(text) self.items[#self.items+1]={text=text} end
        function p:IsVisible() return true end
        return p
    end
    local ok,err=pcall(function()
        CLIENT=true
        CreateClientConVar=function(name,default,archive,userinfo)
            assert(name=="gvoxel_language" and default=="en" and archive and userinfo)
            creations=creations+1
            return {GetString=function() return selected end}
        end
        cvars={AddChangeCallback=function(name,fn,id)
            assert(name=="gvoxel_language" and id=="GVoxel.Language") callbacks[id]=fn
        end}
        language={Add=function(key,value) phrases[key]=value end}
        hook={Run=function(event,...)
            for _,fn in pairs(hooks[event] or {}) do fn(...) end
        end,Add=function(event,name,fn) hooks[event]=hooks[event] or {} hooks[event][name]=fn end}
        clientChunk()
        assert(V.GetLanguage()=="en" and phrases["gvoxel.zones"]=="Persistent zone")
        selected="ru" callbacks["GVoxel.Language"]()
        assert(V.L("Etat")=="Состояние" and phrases["gvoxel.tool_name"]=="Воксельный лом")
        selected="untrusted/value" callbacks["GVoxel.Language"]()
        assert(V.GetLanguage()=="en")
        selected="de" clientChunk()
        assert(creations==2 and V.GetLanguage()=="de", "reload lost archived preference")
        print("PASS: archived per-client language, userinfo for server notifications, live phrase refresh and reload-safe callback ownership")

        IsValid=function(value) return type(value)=="table" and value.valid~=false end
        LocalPlayer=function() return ply end
        RealTime=function() return 0 end
        spawnmenu={AddToolCategory=function() end,AddToolMenuOption=function(_,_,id,_,_,_,fn) options[id]=fn end}
        local receives={}
        net={Receive=function(name,fn) receives[name]=fn end,Start=function() end,SendToServer=function() end}
        RunConsoleCommand=function(name,code)
            assert(name=="gvoxel_language") selected=code callbacks["GVoxel.Language"]()
        end
        vgui={Create=function(kind)
            local child=panel() child.kind=kind
            function child:SetTall() end
            function child:AddChoice(label,data,chosen)
                self.choices=self.choices or {} self.choices[#self.choices+1]={label,data,chosen}
            end
            function child:AddColumn() end
            function child:SetPlaceholderText(text) self.placeholder=text end
            function child:SetText(text) self.text=text end
            function child:GetValue() return self.text or "" end
            function child:Clear() self.rows={} end
            function child:GetSelectedLine() return self.selected end
            function child:GetLine(index) return self.rows[index] end
            function child:AddLine(name,status)
                local line={name=name,status=status}
                self.rows=self.rows or {} self.rows[#self.rows+1]=line
                return line
            end
            function child:SelectItem(line)
                for index,row in ipairs(self.rows) do if row==line then self.selected=index end end
                if self.OnRowSelected then self.OnRowSelected(self,self.selected,line) end
            end
            return child
        end}
        _LANGUAGE_UTILITIES_CHUNK()
        hook.Run("PopulateToolMenu")
        local languagePanel=panel()
        options.GVoxelLanguage(languagePanel)
        local choice=languagePanel.items[2]
        assert(#choice.choices==6)
        choice.OnSelect(choice,3,"Русский","ru")
        assert(V.GetLanguage()=="ru" and languagePanel.items[1].text:find("Выберите",1,true))
        local zonesPanel=panel()
        options.GVoxelZones(zonesPanel)
        assert(#zonesPanel.items==1 and zonesPanel.items[1].text==V.L("Outils reserves aux administrateurs."))
        admin=true
        options.GVoxelZones(zonesPanel)
        local integers={1,7}
        local strings={"My custom save","zone_1_0.dat","Sauvegardee"}
        net.ReadUInt=function() return table.remove(integers,1) end
        net.ReadString=function() return table.remove(strings,1) end
        receives.vm_zones_list()
        assert(zonesPanel.ZoneList.rows[1].status=="Сохранена")
        zonesPanel.ZoneList:SelectItem(zonesPanel.ZoneList.rows[1])
        zonesPanel.ZoneName:SetText("My renamed save")
        selected="it" callbacks["GVoxel.Language"]()
        assert(zonesPanel.ZoneName:GetValue()=="My renamed save", "language change overwrote a user save name")
        assert(zonesPanel.items[2].text=="Ottieni lo strumento di selezione")
        assert(zonesPanel.ZoneList:GetSelectedLine()==1 and zonesPanel.ZoneList.rows[1].status=="Salvata",
            "language change lost selection or left an untranslated zone status")
        print("PASS: actual Utilities language selector has six choices, changes labels immediately, preserves user names and keeps editing admin-only")
    end)
    for _,name in ipairs(names) do _G[name]=saved[name].value end
    for key in pairs(V) do V[key]=nil end
    for key,value in pairs(original) do V[key]=value end
    if not ok then error(err,0) end
end
