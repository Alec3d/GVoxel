-- Ordered module manifest. Only the server owns scans, edits and physics.
if SERVER then
	AddCSLuaFile()
end
GVoxel = GVoxel or {}
local V = GVoxel
if SERVER and V.ShutdownServerScan and not V.ShutdownServerScan() then
	ErrorNoHalt("[GVoxel] Rechargement refuse : liberer la zone avant de recharger Lua.\n")
	return
end
if CLIENT and V.ReleaseClientScan then
	V.ReleaseClientScan()
end
local shared = {
	"sh_language",
	"sh_field",
	"sh_crater",
	"sh_features",
	"sh_scan",
	"sh_scan_columns",
	"sh_mask",
	"sh_zones",
	"sh_bsp",
	"sh_bsp_light",
	"sh_bsp_geometry",
	"sh_sculpt",
	"sh_custom_block",
	"sh_collision",
	"sh_detached",
	"sh_vehicle_world",
	"sh_vehicle_methods",
	"sh_ballistics",
	"sh_vehicle_compat",
	"sh_move",
}
local client = {
	"cl_dust",
	"cl_mesh",
	"cl_terrain",
	"cl_surface",
	"cl_lighting",
	"cl_cut_lighting",
	"cl_visibility",
	"cl_sky",
	"cl_mask",
	"cl_scan",
	"cl_acoustics",
	"cl_custom_block",
	"cl_tool",
	"cl_diagnostics",
}
local server = {
	"sv_dust",
	"sv_terrain",
	"sv_session",
	"sv_scan",
	"sv_detached",
	"sv_visibility",
	"sv_tank",
	"sv_explosions",
	"sv_blasts",
	"sv_props",
	"sv_vehicles",
	"sv_hl2_wheels",
	"sv_projectiles",
	"sv_nav_graph",
	"sv_navigation",
	"sv_actors",
	"sv_zone_cache",
	"sv_zone_store",
	"sv_zone_ui",
}
local function load(modules, send)
	for _, name in ipairs(modules) do
		local path = "gvoxel/" .. name .. ".lua"
		if SERVER and send then
			AddCSLuaFile(path)
		end
		if not (SERVER and send == "client") then
			include(path)
		end
	end
end
load(shared, true)
if SERVER then
	load(client, "client")
	load(server)
else
	load(client)
end
if SERVER then
	AddCSLuaFile("gvoxel/sh_grab.lua")
end
include("gvoxel/sh_grab.lua")
