<p align="center">
  <img src="./docs/images/GVoxel%20Logo.png" alt="GVoxel Logo" width="760">
</p>

# GVoxel

**Dig through walls, reshape the terrain, and open new paths in your Garry’s Mod maps.**

GVoxel is a Lua addon that scans a selected section of a map’s BSP geometry and rebuilds it as editable voxel terrain, with reconstructed surfaces, textures, and collisions.

Create tunnels, excavate the ground, breach buildings, and interact with the resulting openings using players, props, supported vehicles, and explosives.

**One persistent zone per map · Admin-only editing tools · Vehicle and explosive integrations · Multiplayer validation in progress**

## How It Works

1. An administrator selects an area using a standard cage or a custom box.
2. GVoxel analyzes the geometry, terrain, and surface materials inside the selection.
3. A destructible mesh and its collisions take over within the zone.
4. Digging or adding material rebuilds the affected sections without repeating the entire scan.
5. The zone and its modifications are saved for future sessions on the same map.

The original BSP file is never permanently modified. Outside the voxel zone, the map continues to use its normal geometry and collisions.

## Terrain, Textures, and Lighting

- BSP walls, buildings, and ground surfaces.
- Hammer displacement terrain, slopes, and stacked floors.
- Handling for open and single-sided surfaces.
- Material removal and addition inside the scanned area.
- Original material mapping, including texture scale and orientation.
- Surface appearance capture with resolution managed through rendering budgets.
- Approximate lighting for newly exposed surfaces using surrounding environmental information.
- Dynamic lights, lamps, and flashlights.
- Visibility handling for the skybox, surrounding environment, props, and characters through openings.

Newly exposed surfaces use approximate lighting: GVoxel does not rebuild the map’s compiled lightmaps. Complex corners, reflections, and Source visibility optimizations may still require adjustments.

## Players, Props, and NPCs

GVoxel includes collision and trace adaptations for:

- **Players:** movement through excavated areas.
- **Props and ragdolls:** interaction with voxel ground and openings.
- **Physics Gun and Gravity Gun:** object manipulation through holes.
- **GMod lights and lamps:** physical interaction and terrain illumination.
- **Ground NPCs and compatible NextBots:** local movement and passage adaptations.
- **Supported bullets and projectiles:** travel through existing openings while remaining blocked by intact obstacles.

Projectile passage and terrain destruction are separate features. Ordinary bullets can pass through an existing hole without automatically carving one.

NPC navigation uses local adaptations. It does not replace every map navigation network or the custom AI implemented by other addons.

## Vehicle Support

GVoxel includes integrations for these vehicle systems:

| Vehicle system | Integration |
| --- | --- |
| **Native HL2 / GMod vehicles** | Jeep, Jalopy, and wheel-contact adaptations for voxel terrain. |
| **Glide** | Vehicle bodies, wheels, associated assemblies, and supported explosive projectiles. |
| **LVS** | Vehicles and their associated physical components. |
| **Simfphys** | Vehicles and associated physical wheels. |

These integrations are designed to let vehicles drive on voxel surfaces, fall into excavations, and pass through destroyed walls when sufficient clearance is available. They also address wheel visibility and preservation of vehicle appearance.

Compatibility is implemented at the vehicle-system level rather than individually for every model. Custom suspension, constraints, dimensions, and controllers can still require additional testing.

The Airboat retains its native controller and is distinct from the wheeled-vehicle adaptations.

## Explosions and Weapons

Supported explosive events use a shared destruction system, with hole dimensions based on the available explosion information.

Integrations include:

- **Standard Garry’s Mod RPG.**
- **HL2 fragmentation grenades.**
- **HL2 SLAM charges and tripmines.**
- **Glide tank shells:** recognized impacts can create openings sized according to the tank’s dimensions.
- **Glide P-996 Lazer and B-11 Strikeforce aircraft:** supported guided and unguided missiles.
- **Other explosive weapon addons** that emit recognized blast-damage events.

Destruction remains limited to the voxel zone. Thick walls, small selections, and custom projectile implementations may limit the resulting opening.

Purely visual explosions without a detectable event cannot automatically trigger terrain destruction.

## Persistent Zone and Administration

GVoxel supports **one active, saved zone per map**.

- Standard **16- or 32-meter cages**.
- **Custom block mode:** an axis-aligned box defined using four points.
- Boundary and dimension previews before scanning.
- Automatic saving after scanning and committed edits.
- Automatic restoration when starting another session on the same map.
- Management through **Utilities → GVoxel → Zones persistantes**.
- **Administrator-only** creation, editing, and management tools.

The cache avoids repeating the full terrain sampling process. Meshes, visual captures, and physics objects still require preparation when loading.

Server saves are stored in:

`garrysmod/data/gvoxel/zones/<map>/`

Runtime saves are not included in this source repository.

## Installation

1. Place the runtime **gvoxel** folder inside `garrysmod/addons/`.
2. Restart the game or server.
3. As an administrator, enter `vm_give` in the console to obtain the tool.
4. Select an area, scan it, and start editing.

The vehicle frameworks listed above are optional. Install the frameworks and content required for the vehicles you want to use.

GWater integration is not included in this active version.

## Tool Controls

| Input | Action |
| --- | --- |
| **Hold R** | Open selection, size, and radius settings. |
| **Tap R** | Scan the selected area. |
| **Left click** | Remove material. |
| **Right click** | Add material. |
| **Middle click in Custom block mode** | Place the four points: origin, X width, Y length, and height. |
| **Middle click after selection** | Toggle between moving and locking the box. |

## Multiplayer

**Multiplayer synchronization is implemented, but complete testing with multiple players is still pending.**

The server manages the zone, terrain modifications, and collisions. Clients receive the initial state and ordered edits. Players joining an existing session receive the information needed to reconstruct the current zone.

The zone remains active when its creator disconnects.

Client Lua files are distributed through Garry’s Mod’s server download mechanism, so other players do not need to copy the script manually. Required maps and external vehicle content must still be available to clients.

Editing tools remain administrator-only. Other players can see the zone and interact with its physical environment.

Latency and client preparation speed can affect edit confirmation times. A client that stops acknowledging updates can still delay operations waiting for its response.

## Performance and Current Status

GVoxel spreads preparation work across ticks and prioritizes local rebuilding. Reusable data is cached, while captures, background tasks, and additional views operate within defined budgets.

Performance depends on the map, zone size, materials, vehicles, installed addons, and hardware. No fixed FPS or excavation-time guarantee is provided.

Automated tests cover geometry, collision adaptations, caches, permissions, and network logic. They do not replace in-game testing of rendering, driving, NPC behavior, performance, or real multiplayer sessions.

Diagnostic commands include:

- `vm_diagnose`
- `vm_geometry_stats`
- `vm_edit_stats`
- `vm_render_stats`

## Development

Repository structure:

- `lua/` — Shared, server, and client addon code.
- `tools/` — Deployment and packaging utilities.
- `tests/` — Automated checks and engine adapters.
- `docs/images/` — README images.

In the reference workspace, development sources live under:

`garrysmod/addons/all source file/gvoxel_sources/`

Deployed runtime files live under:

`garrysmod/addons/gvoxel/`

Development commands:

    python -B tests/run_tests.py
    python -B tests/run_tests.py --zones
    python -B tools/deploy_runtime.py --write
    python -B tools/build_workshop.py

Tests use LuaJIT supplied with the Garry’s Mod installation. Some optional checks require the corresponding maps or Workshop addons.

The build generates `dist/gvoxel.gma` and `dist/gvoxel-workshop.zip` without publishing automatically.

## Reporting Issues

Please include:

- The map name.
- Zone dimensions and location.
- Steps to reproduce the issue.
- Relevant vehicle or weapon addons.
- Console errors and diagnostic results.
- Before-and-after measurements for performance reports.

Clearly distinguish automated test results from behavior observed directly in the game.
