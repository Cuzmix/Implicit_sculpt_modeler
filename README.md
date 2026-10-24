# Sculpt

A performance-focused sculpting prototype in Odin, using SDL3 + SDL_GPU for rendering and Dear ImGui for the surrounding interface.

## Layout

| Path | Owns |
| --- | --- |
| `src/app` | Entry point, frame loop, scene of sculptable objects, Move and Brush tools, ImGui panels, input routing into `Viewport_Input` |
| `src/render` | Every GPU object the app creates: device, pipeline, viewport target, mesh buffers (16 bytes a vertex: float3 position, octahedral normal), per-mesh indirect draws of the visible chunks, simplified copies of far chunks drawn from a second index buffer while the view moves, partial redraws (while the camera and objects stay put, the last frame is kept and only the screen rectangle around what changed is cleared and redrawn), shaders |
| `src/geom` | CPU sculpt geometry (structure-of-arrays triangle mesh, BVH, test spheres, mesh simplification that keeps patch borders), view-culling math (chunk bounds and normal cones, frustum and back-face tests) and the choice of simplified groups to draw; no rendering or UI imports |
| `src/camera` | Orbit camera math; no rendering or UI imports |
| `src/gizmo` | Move gizmo math: projection, handle picking, axis and view-plane drags; no rendering or UI imports |
| `src/sculpt` | Brush dabs on a `geom.Mesh`: mesh split into nodes that own contiguous vertex ranges, parallel draw/smooth, per-frame normal updates, dirty vertex ranges for upload, stroke undo/redo that saves only the nodes a stroke touched (512 MB cap per object), simplified copies of groups of nodes rebuilt between strokes, subdivision levels, HD detail sculpted a window at a time above the top level |
| `src/jobs` | Persistent worker pool (`parallel_for`) used by sculpt and mesh setup |
| `src/bench` | Headless sculpt benchmark at chosen mesh sizes (no window or GPU) |
| `src/sdf_trial` | Standalone SDF/voxel comparison spike (not linked into the app) |

The 3D viewport is rendered by `render` into an offscreen texture that the `Viewport` panel displays. Strokes undo and redo with Ctrl+Z and Ctrl+Shift+Z (or Ctrl+Y), also in the Edit menu; the order runs across objects. ImGui never owns sculpt state: panels read and edit `App` fields through pointers each frame, and the viewport panel reports mouse input as a plain struct the camera and the active tool consume. Each object keeps its mesh in local space with a transform (position, uniform scale), so moving an object never rewrites its vertices; the brush works in the object's local space.

## Pinned versions

See `scripts/versions.env`: Odin `dev-2026-10`, SDL `3.4.18` (Linux; Windows uses the SDL3 shipped with Odin), odin-imgui `a116eb1` (Dear ImGui `1.92.8-docking`).

## Linux

```sh
# once: system packages are listed at the top of the script
./scripts/setup_deps.sh

./build.sh            # debug build with allocation tracking -> build/sculpt
./build.sh release    # optimized build
./build.sh test       # unit tests (geom, camera, sculpt, jobs, gizmo)
./build.sh check      # odin check of every package with the strict flags, then the agent-file mirror check (scripts/agents_sync.py)
./build.sh run -- --vertices=10000000
./build.sh smoke      # 300 frames in GPU debug mode; non-zero exit on assert, GPU error or leak
./build.sh bench      # headless sculpt benchmark at 500k, 1M, 5M, 7M, 10M vertices
./build.sh gpubench   # GPU and CPU frame times while orbiting and sculpting, same sizes
./build.sh wincheck   # compile app and bench for Windows x64 (no link) to catch Windows-only errors
```

Headless (CI or containers): run under `Xvfb` with Mesa's llvmpipe Vulkan driver (`mesa-vulkan-drivers`).

## Windows

From an "x64 Native Tools Command Prompt for VS" with git and python on PATH:

```bat
scripts\setup_deps.bat
build.bat            :: or: build.bat release | test | run | smoke | bench | gpubench | check
```

Shaders are recompiled when `glslangValidator` (Vulkan SDK) is on PATH; otherwise the committed `.spv` files are used.

## App flags

`--vertices=N` start with a geodesic sphere of about N vertices (the Scene panel adds spheres or remeshes the selected one at any typed vertex count), `--subdiv=N` icosphere level when `--vertices` is not given (default 6: 40,962 vertices), `--threads=N` sculpt threads including the main one (default: one per core), `--frames=N` exit after N frames, `--spheres=N` start with N spheres of that size side by side, `--subdivide=N` give each starting sphere N subdivision levels above it (`--vertices=40000 --subdivide=4` tops out at 10M), `--level=N` start on level N (1 is the base; default the top), `--no-cache` draw every object every frame instead of caching idle ones (for A/B timing; also a checkbox in the Stats panel), `--bench-stroke=N` synthetic brush stroke over N frames across the first sphere, then print stats (with levels, also the time of each step down to the base and back), `--bench-samples=N` give each of those frames N pointer samples along the path, like a high-rate mouse (default: one position a frame), `--bench-loops=N` make that stroke N circles around the middle of the sphere instead of a wavy line, `--gpu-debug` GPU debug/validation mode, `--no-partial` redraw the whole viewport every frame (also a Stats panel checkbox), `--dump-viewport=PATH` write the last viewport image as a PPM on exit (for comparing renders), `--check-mesh` check every object's mesh on exit (closed, consistently wound, no degenerate triangles or NaN) and print the counts as `mesh_*` lines, `--no-cull` draw every triangle instead of skipping off-screen and back-facing chunks (for A/B timing; also a checkbox in the Stats panel), `--no-vsync` show frames as soon as they are ready (also a Stats panel checkbox), `--no-simplify` draw everything at full detail while the view moves too (also a Stats panel checkbox), `--orbit` turn the camera around the scene by itself, once every 240 frames, `--time-gpu` measure the GPU time of the 3D viewport every frame (also a Stats panel checkbox), `--gpubench=PATH` run the GPU benchmark below and write its tables to PATH, `--gpubench-frames=N` measured frames per benchmark case (default 120), `--hd=N` give each starting sphere an HD level N Loop steps (1 to 3) above its top level, `--hd-open` start sculpting HD on the first sphere, in a window around the side facing the camera, `--hd-window=N` vertices an HD window holds (default 4,000,000; also a slider in the Scene panel), `--width`, `--height`.

`python scripts/ppm.py to-png build/view.ppm build/view.png` turns a `--dump-viewport` file into a PNG; its `uniform`, `diff`, `crop` and `pixel` commands detect a blank frame, count and box the pixels two dumps disagree on, enlarge a region and print values (`python scripts/ppm.py -h`).

## Benchmark

`build/bench [vertex counts...] [--meshes=N] [--threads=N] [--node=N] [--prefault=MB]` builds a sphere of each size (N of them with `--meshes`, only the first sculpted; with no sizes given it also runs 10M with a second idle sphere), prepares it for sculpting, runs the same 77-dab stroke with a large (r=0.13) and a small (r=0.04) brush, and prints a markdown table, including the undo memory of each stroke and the time to undo and redo it. A frame is 4 dabs plus the normal update and is what the app does per frame during a fast stroke. The normal update recomputes every normal of the nodes whose triangles moved, but only the border vertices of their neighbours; the normal cones that back-face culling uses wait until the stroke ends (until then those chunks are simply not back-face culled), and "Stroke end ms" is the frame where that work starts, at most 512 nodes a frame. A second table culls the sculpted sphere from three cameras (whole sphere, close-up, detail) and reports the share of triangles that would be drawn, the number of indirect draw commands, and the CPU time to cull. On cloud VMs, pass `--prefault=3000` so the VM's slow first touch of fresh memory does not dominate setup times.

`build/bench --lod [vertex counts...]` prints a table for simplified drawing instead: at each size, the time to build every group's copy as the app does (a batch a frame), the copies' memory, the triangles drawn and the CPU time to choose them from the culling table's three cameras at full detail and with copies at most 1 px off (on a 1000 px tall viewport), and the time to rebuild what the large-brush stroke made stale.

`build/bench --hd [vertex counts...]` prints a table for HD detail instead: at each size, a sphere as the top level with an HD level one and then two steps above it. It times opening a window of about 4M vertices at the front, the small-brush stroke in it (median frame), storing it on leaving and opening the window again with the stored detail, and gives the window's memory and what the stroke stored. Then the regular levels the HD level stands in for: their memory (estimated past 16M vertices), and while they stay under that, the time to build them and the same stroke on their top level.

`build/bench --levels [vertex counts...]` prints a table for subdivision levels instead: at each size, a base sphere of at most 40k vertices with as few levels above it as reach that size. It times building the levels (all of them, and the top one alone), the same stroke on the top level, stepping down to the base (carrying the stroke down, then the base's normal update), the stroke on the base, and stepping back up (carrying that up through every level, then the top level's normal update, with the megabytes the app would upload).

## GPU benchmark and frame timing

`build.sh gpubench` (or `build.bat gpubench`) builds the release app and runs it on one sphere at 500k, 1M, 5M, 7M and 10M vertices (only one size with `--vertices=N`). At each size it runs six cases: the camera orbiting once around the sphere with everything on, with simplified drawing off, and with view culling off too, and a brush stroke with partial redraw and culling both on, partial redraw off, and both off. The stroke drags the 60 px Draw brush back and forth across the sphere at 30 px a frame (two dabs a frame, like a fast real stroke) and is undone after each case. Each case runs 30 warm-up frames and then measures 120; stroke cases count only the frames that sculpted. It prints three markdown tables, GPU time of the 3D viewport and CPU time per frame (p50 / p99) and triangles drawn per frame, and writes them to `build/gpubench.md`. It needs a display, and only a real GPU gives meaningful numbers. Vsync is turned off during the run where the display allows it.

The Stats panel shows the same timings live:

- **Frame**: the whole frame, waits included. With VSync on this is the display's refresh interval whenever the frame is ready in time, so it does not show what a speed setting saves; compare CPU and GPU instead, or turn VSync off.
- **CPU**: the frame minus its waits.
- **GPU (3D)**: the GPU time of the 3D viewport's uploads and drawing, shown while "Time GPU work" is on. The 3D work goes in its own command buffer; with timing on, the app waits for the previous frame first and then for this one, so the time from submit to its fence is the GPU's alone. Frames then no longer overlap, so leave it off when not measuring.
- **Display wait**: time spent waiting for the display, at the start of the frame and while presenting.
- **VSync**: off uses mailbox where the display offers it (no tearing), else immediate (may tear). The app reads input after the wait at the start of the frame, so a driver that makes the app wait there for the next screen image no longer delays that frame's input. Drivers that wait while presenting instead (Mesa does) still add up to a refresh interval of lag with VSync on; turning it off removes that.

The SDF/voxel comparison spike from step 3 builds separately: `deps/odin/odin build src/sdf_trial -o:speed -collection:deps=deps`.

## Idle objects

Only the selected object is sculpted or moved, so the viewport draws every other object once into a cached colour + depth image and reuses it while the camera and those objects stay put (all through a brush stroke). Each frame then costs a screen-sized copy plus the selected object's triangles, however many idle objects there are. Orbiting, panning, zooming, selecting another object or changing an idle one redraws the cache. On the CPU side idle objects already cost nothing per frame (`build/bench` with `--meshes=2`).

## Simplified drawing while the view moves

While the camera orbits, pans or zooms, or an object moves, far parts of each mesh are drawn from simplified copies, then everything is drawn at full detail once the view has stayed put for a quarter of a second. The chunks a mesh is split into for culling are grouped along its BVH, four to six at a time, then groups of groups, up to one group for the whole mesh. Each group has a copy of the triangles under it with about a quarter of them, made from its children's copies by collapsing edges into existing vertices, cheapest first by quadric error. A copy never moves a vertex on its group's border, so any mix of copies and chunks meets without cracks. Each frame, the renderer draws a group's copy instead of what lies under it when the copy strays less than "Largest error" (1 px by default) from the full mesh, as seen from the camera; nearby chunks stay at full detail. On a 10M vertex sphere seen whole this draws about 500k triangles instead of 8.6M (`build/bench --lod`).

Copies are built a few milliseconds a frame, for one object at a time and never during a stroke, so a new 10M vertex mesh takes a few seconds to get all of them; until then, and for the groups an edit made stale until they are rebuilt, the chunks under them are drawn instead. Meshes under 262,144 triangles get no copies. The Stats panel turns it off ("Simplify while moving"), sets the largest error, shows how many groups are left to build and the build time per frame.

## Subdivision levels

As in ZBrush, an object can have up to 8 subdivision levels: its base mesh and finer copies, each made from the one below by one step of Loop subdivision, which splits every triangle into four and smooths the result. Each level is a whole mesh with its own sculpt data and GPU buffers, so sculpting on a level costs what it costs on a plain mesh of that size, and only the current level is drawn. Every vertex above the base stores its offset from where subdivision puts it, in a frame that turns with the surface of the level below. When the current level changes, the levels are brought up to date with the edits made on the one being left: levels above are rebuilt from their offsets, so fine detail rides on a coarse change, and levels below move each vertex by half its own change plus half the average change around it, so they follow the large shapes of a fine edit while the detail stays on top. Only the parts of each level an edit reached are visited.

Ctrl+D (or Subdivide in the Scene panel) adds a level above the top one and goes to it; D and Shift+D go up and down a level, and the Scene panel has a level slider. The panel shows how many vertices and how much memory the next level would take (Subdivide is refused past 12 GB), the memory all levels use, and how long the last level change took. Delete lower makes the current level the base; Delete higher drops the levels above it; both clear that object's undo history. Undo and redo walk back across levels, switching the object to the level each stroke was made on.

## HD detail

As with ZBrush's HD geometry, an object can be sculpted up to 3 Loop steps finer than its top level without building those levels. Divide HD in the Scene panel adds an HD level (on a closed mesh), and A over the object opens a window: the finer subdivision of the top-level chunks nearest the pointer, up to the window size (4M vertices by default; the panel's slider sets 1 to 16M). The window sculpts like any level and is drawn in place of the chunks it covers; A again (or Leave HD) stores what changed and closes it. Detail is stored per top-level chunk, only for chunks that were sculpted, as each vertex's offset from where subdivision of the top level puts it, in a frame that turns with that surface, so it rides on later changes to the top level and the levels below. Outside a window it is kept but not shown, as in ZBrush.

The window's border stays where the top level is drawn around it. Brushes fade out over the last 8 top-level edges toward it, so a stroke across it leaves a slope rather than a cliff, and flat seal triangles close the join between the two meshes so it draws without pinholes. Strokes in the window undo one by one; closing it stores them and drops them from the undo history, and undoing an older stroke closes the window first. Subdivide is refused while an HD level exists (Delete HD first), Delete higher drops it with the top level, and Remesh drops it.

A window opens in about a second and its stroke frames cost what the same mesh would; the stored detail is a few megabytes where the levels it stands in for would take gigabytes (`build/bench --hd`, 4 threads, this repo's cloud VM):

| Top vertices | HD steps | HD level vertices | Window vertices | Open ms | Stroke frame ms | Leave ms | Reopen ms | Window MB | Stored MB | Levels instead MB | Levels build s | Levels stroke frame ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 501k | 1 | 2.01M | 2.01M | 535 | 0.15 | 12 | 600 | 265 | 0.2 | 242 | 0.36 | 0.18 |
| 501k | 2 | 8.03M | 4.01M | 1422 | 0.24 | 36 | 1003 | 530 | 0.8 | 967 | 2.55 | 0.28 |
| 998k | 1 | 3.99M | 3.99M | 1111 | 0.29 | 68 | 1216 | 528 | 0.4 | 481 | 0.69 | 0.19 |
| 998k | 2 | 15.98M | 4.01M | 1047 | 0.40 | 65 | 1161 | 530 | 1.5 | 1924 | 5.61 | 0.33 |
| 5.00M | 1 | 19.99M | 4.01M | 1148 | 0.44 | 37 | 1142 | 529 | 1.7 | 2574 (estimate) | n/a | n/a |
| 5.00M | 2 | 79.98M | 4.01M | 887 | 1.11 | 45 | 1153 | 530 | 6.0 | 12871 (estimate) | n/a | n/a |
| 7.01M | 1 | 28.02M | 4.00M | 1189 | 0.49 | 43 | 1133 | 529 | 2.4 | 3608 (estimate) | n/a | n/a |
| 7.01M | 2 | 112.09M | 4.01M | 923 | 1.47 | 45 | 968 | 530 | 8.2 | 18039 (estimate) | n/a | n/a |
| 10.00M | 1 | 40.00M | 4.01M | 1479 | 0.64 | 39 | 1104 | 529 | 3.3 | 5150 (estimate) | n/a | n/a |
| 10.00M | 2 | 160.00M | 4.01M | 1261 | 2.46 | 56 | 996 | 530 | 11.2 | 25749 (estimate) | n/a | n/a |

The stroke frame grows with the top level's size because the same brush covers more HD vertices (about 64k a dab at 10M with two steps). About half of the open time is preparing the window for sculpting (its BVH, chunks and normals), as for any mesh of that size; the rest is the subdivision itself and decoding the stored detail.

## Controls

Tools: W selects Select / Move, B selects Brush. F points the camera at the selected object. Ctrl+D subdivides the selected object; D and Shift+D go up and down its levels. A opens an HD window where the pointer is on an object with an HD level, or closes the open one.

Select / Move: click an object to select it, drag it to move it in the view plane, or drag a gizmo arm (red X, green Y, blue Z) to move along that axis. Position and scale can also be typed in the Scene panel.

Brush: left drag sculpts the object under the cursor, which becomes selected (Shift smooths, Ctrl inverts). The brush follows every mouse or pen sample, not just where the pointer is once a frame: dabs go along the path the pointer took on screen, a quarter of the radius apart, each where that point meets the surface. Pen pressure scales the strength, and the size too with "Pressure sets size" in the Tools panel; a mouse counts as full pressure. Lazy mouse makes the brush trail the cursor on a string that many pixels long, for steadier lines.

Scene panel: type a vertex count (or pick a preset), then Add sphere, or Remesh selected to rebuild the selected sphere at that count, with one level (sculpted detail is not kept yet). Geodesic spheres come in steps of 10f² + 2 vertices; the panel shows the exact count it will build.

Orbit: right drag or Alt + left drag. Pan: middle drag or Shift + right drag. Zoom: mouse wheel.
