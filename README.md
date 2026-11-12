<p align="center">
  <img src="./docs/images/Gvoxel%202.png" alt="GVoxel 2" width="760">
</p>

# GVoxel

**Dig through walls, reshape the terrain, and open new paths in your Garry’s Mod maps.**

GVoxel is a Lua addon that scans a selected section of a map’s BSP geometry and rebuilds it as editable voxel terrain, with reconstructed surfaces, textures, and collisions. Create tunnels, excavate the ground, breach buildings, and interact with the resulting openings using players, props, supported vehicles, and explosives.

**One zone per map · Manual saves · Admin-only editing tools · Six interface languages · Vehicle and explosive integrations · Multiplayer validation in progress**

[Release notes](./CHANGELOG.md)

## How It Works

1. An administrator selects an area using a standard cage or a custom box.
2. GVoxel reads the map’s BSP geometry and materials. The tool also offers a ray-based scan.
3. A destructible mesh and its collisions take over within the zone.
4. Digging or adding material rebuilds the affected sections without repeating the entire scan.
5. To keep the zone for another session on the same map, use [**R → Save zone**](#saving-and-restoring-a-zone).

The initial scan preview can be toggled in the tool menu. Once the zone has been edited, its voxel rendering stays enabled so that visible openings match the physical terrain.

The original BSP file is never permanently modified. Outside the voxel zone, the map continues to use its normal geometry and collisions.

## Terrain, Textures, and Lighting

- BSP walls, buildings, and ground surfaces.
- Hammer displacement terrain, slopes, and stacked floors.
- Handling for open and single-sided surfaces.
- Material removal and addition inside the scanned area.
- Original material mapping, including texture scale and orientation.
- Surface appearance capture with resolution managed through rendering budgets.
- Approximate lighting for newly exposed surfaces using surrounding environmental information.
- Dynamic lighting from standard GMod lights and lamps.
- Visibility handling for the skybox, surrounding environment, props, and characters through openings.

Newly exposed surfaces use approximate lighting. Complex corners, reflections, and Source visibility optimizations may still require adjustments.

## Players, Props, and NPCs

- **Players** can move through excavated areas.
- **Props and ragdolls** interact with voxel ground and openings.
- **Physics Gun and Gravity Gun** can move objects through holes.
- **GMod lights and lamps** interact with and illuminate voxel terrain.
- **Ground NPCs and compatible NextBots** can use local movement and passage adaptations.
- **Supported bullets and projectiles** can pass through existing openings while remaining blocked by intact obstacles.

Repeated impacts from supported weapons can gradually chip voxel terrain. The HL2 shotgun, pulse rifle, and crossbow are reference weapons. Projectile passage through an existing hole works independently of terrain damage.

NPC navigation uses local adaptations. Compatibility with custom AI and map navigation varies.

## Vehicle Support

| Vehicle system | Integration |
| --- | --- |
| **Native HL2 / GMod vehicles** | Jeep, Jalopy, and wheel-contact adaptations for voxel terrain. |
| **Glide** | Vehicle bodies, wheels, associated assemblies, and supported explosive projectiles. |
| **LVS** | Vehicles and their associated physical components. |
| **Simfphys** | Vehicles and associated physical wheels. |

Supported vehicles can drive on voxel surfaces, fall into excavations, and pass through destroyed walls when there is enough clearance. The integrations also address wheel visibility and preserve vehicle appearance.

Compatibility depends on the vehicle framework and the model’s suspension, constraints, dimensions, and controllers. The Airboat retains its native controller.

## Explosions and Weapons

Supported explosions create holes based on the available blast information.

- **Standard Garry’s Mod RPG.**
- **HL2 fragmentation grenades.**
- **HL2 SLAM charges and tripmines.**
- **Glide tank shells**, with openings sized according to the tank’s dimensions.
- **Glide P-996 Lazer and B-11 Strikeforce aircraft**, including supported guided and unguided missiles.
- **Other explosive weapon addons** that emit recognized blast-damage events.

Destruction is limited to the voxel zone. Thick walls, small selections, and custom projectile implementations can affect the resulting opening.

Excavation and craters trigger native **ThumperDust** and a short dust effect sized to the impact. Particle counts, distance, and burst rate are capped. Clients can disable dust with `vm_blast_dust 0`.

After edits, GVoxel checks for unsupported fragments. Small groups are removed together where a safe cut is possible, and larger groups erode progressively with dust and breaking sounds. Fragment removal updates collisions and syncs to clients like any other terrain edit. It is included when you save with destruction.

Material connected to a zone boundary is treated as supported. Fragments with uncertain contacts can remain to protect attached terrain. Administrators can disable fragment cleanup with `vm_detached_cleanup 0`.

## Saving and Restoring a Zone

Administrators can work with **one active zone and one save per map**. With the GVoxel tool equipped, press **R → Save zone** and choose what to keep.

| Save option | What comes back next session |
| --- | --- |
| **With destruction** | The zone with all edits committed at the time of the save, including holes and added material. |
| **Without destruction** | The original scan, before any terrain edits. You can keep playing in the edited zone. |

When the map opens again, GVoxel restores the last saved state. A new zone only persists after you save it. Edits made later stay in the current session until you save again.

**R → Saved zones** lets administrators load a save, remove the active zone from play, or delete the save from disk. Removing the active zone keeps the save available for the next session.

Restoring a save reuses the scanned terrain data. GVoxel still prepares meshes, textures, and collisions before the zone is ready. Server saves are stored in `garrysmod/data/gvoxel/zones/<map>/`.

## Installation

**From the Workshop**

Subscribe to GVoxel, let Garry’s Mod download it, then restart the game or server. Server operators must also install the addon on their server.

**From GitHub**

Download and extract this repository. Copy **`lua/` and `addon.json`** into `garrysmod/addons/gvoxel/`. The result should contain `garrysmod/addons/gvoxel/lua/autorun/gvoxel.lua`. Restart the game or server and keep one installed copy of GVoxel.

**Getting started**

As an administrator, choose **Utilities → GVoxel → New zone** to equip the tool, or enter `vm_give` in the console. Press **R**, choose a **16 m** or **32 m** zone or a **Custom box**, then select **New zone**. Aim at the map or place the four custom box points, then press **R** again to scan. The status card shows elapsed time, the number of prepared blocks, and when the zone is ready.

Vehicle frameworks and their content are optional. Install the framework and content for the vehicles you want to use.

## Languages

The interface uses **English by default**. Open the tool panel and click a flag to switch between:

**English · Français · Русский · Español · Italiano · Deutsch**

The language is saved per player and applies to menus, tool hints, HUD status, and usage notifications. Custom save names and console commands keep their original spelling.

## Tool Controls

| Input | Action |
| --- | --- |
| **Tap R** | Open the tool panel, or start scanning after selecting **New zone**. |
| **Ctrl+H or hold R** | Open the tool panel while positioning a zone. |
| **Left click** | Remove material. |
| **Right click** | Add material. |
| **Middle click in Custom box mode** | Place the four points for the origin, X width, Y length, and height. |
| **Middle click after selection** | Toggle between moving and locking the box. |

You can bind `vm_menu` to open the panel and `vm_box_point` to place custom box points. The add-volume slider controls how much material is added with each edit.

## Multiplayer

**Multiplayer synchronization is implemented. Full testing with multiple players is still in progress.**

The server manages the zone, terrain edits, and collisions. Clients receive the initial scan and subsequent edits. Players joining a session in progress catch up to the current state, and the zone remains active when its creator disconnects.

Garry’s Mod distributes the client Lua files through its server download mechanism. Players still need the required map and any external vehicle content. Administrators manage and edit the zone, while other players can see and interact with it.

Latency and client preparation time can affect when edits appear. The server waits for participating clients to prepare an edit before applying the corresponding collision changes.

## Performance and Current Status

GVoxel spreads scan and preparation work across server ticks and rebuilds the sections affected by an edit. BSP indexing and cached terrain data reduce repeated work. Repeated impacts are grouped, and bullet traces can reuse native map results through unchanged terrain.

Rendering uses bounded texture captures and reusable background views. Performance varies with the map, zone size, materials, installed addons, vehicles, and hardware.

Automated tests cover geometry, collision adaptations, saves, permissions, localization, and network behavior. In-game rendering, vehicle handling, NPC movement, and multiplayer performance are tested separately.

Use `vm_profile 10 run_name` to sample frame intervals, Lua memory, and GVoxel hook time for ten seconds. Other diagnostic commands include `vm_diagnose`, `vm_geometry_stats`, `vm_edit_stats`, `vm_render_stats`, `vm_hl2_wheel_stats`, and `vm_audio_stats`.

## Source Package

The GitHub package includes the addon’s Lua sources, `addon.json`, this README, the changelog, and the project images.

- `lua/autorun/` — Addon entry point.
- `lua/gvoxel/sh_*.lua` — Shared geometry, language, collision, and compatibility logic.
- `lua/gvoxel/sv_*.lua` — Terrain, physics, saves, and replication.
- `lua/gvoxel/cl_*.lua` — Rendering, menus, local effects, and diagnostics.
- `lua/weapons/weapon_voxel_crowbar/` — Selection and editing tool.
- `docs/images/` — Project banner and [square icon](./docs/images/gvoxel-square-512.png).

After updating, restart the game or server and reconnect clients so everyone uses the same version.

## Reporting Issues

Please include the map name, zone dimensions and location, steps to reproduce, relevant vehicle or weapon addons, and any console errors. For visual issues, screenshots from the affected angle help. For performance reports, include before-and-after measurements when available.
