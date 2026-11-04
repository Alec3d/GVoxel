function RunLoaderTests(boot)
    local oldV,oldServer,oldClient,oldInclude,oldSend=GVoxel,SERVER,CLIENT,include,AddCSLuaFile
    local function run(server)
        local includes,sent={},{}
        SERVER=server CLIENT=not server GVoxel={}
        include=function(path) includes[#includes+1]=path end
        AddCSLuaFile=function(path) sent[path or "autorun/gvoxel.lua"]=true end
        boot()
        local index={}
        for i,path in ipairs(includes) do
            assert(not path:find("matter",1,true),"removed module is still loaded")
            index[path]=i
            if server and path:find("/sh_",1,true) then assert(sent[path],"shared code missing from client downloads") end
            if not server then assert(not path:find("/sv_",1,true),"server authority included on a client") end
        end
        if server then
            assert(index["gvoxel/sv_session.lua"]<index["gvoxel/sv_scan.lua"])
            assert(sent["gvoxel/cl_scan.lua"] and sent["gvoxel/cl_tool.lua"] and sent["gvoxel/sh_grab.lua"])
            assert(sent["gvoxel/cl_sky.lua"] and index["gvoxel/sv_visibility.lua"],"visibility modules not distributed/loaded")
        else
            assert(index["gvoxel/cl_scan.lua"]<index["gvoxel/cl_tool.lua"])
            assert(index["gvoxel/cl_sky.lua"]<index["gvoxel/cl_mask.lua"],"sky helpers loaded after compositor")
        end
    end
    run(true) run(false)
    GVoxel=oldV SERVER=oldServer CLIENT=oldClient include=oldInclude AddCSLuaFile=oldSend
    print("PASS: actual loader orders server authority and client UI, distributes shared/client modules and omits removed modules")
end
