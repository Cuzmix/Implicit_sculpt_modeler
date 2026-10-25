# Sculpt

A performance-focused sculpting prototype in Odin, using SDL3 + SDL_GPU for rendering and Dear ImGui for the surrounding interface.

## Layout

| Path | Owns |
| --- | --- |
| `src/app` | Entry point, frame loop, scene of sculptable objects, Move and Brush tools, brush alphas (the built-in ones and loaded images, which way each dab's image faces), ImGui panels, input routing into `Viewport_Input` (pen pressure and tilt included), the brush pie, the File menu (scene save and open, mesh import and export, file dialogs) |
| `src/render` | Every GPU object the app creates: device, pipeline, viewport target, mesh buffers (16 bytes a vertex: float3 position, octahedral normal), per-mesh indirect draws of the visible chunks, simplified copies of far chunks drawn from a second index buffer while the view moves, partial redraws (while the camera and objects stay put, the last frame is kept and only the screen rectangle around what changed is cleared and redrawn), shaders |
| `src/geom` | CPU sculpt geometry (structure-of-arrays triangle mesh, BVH, test spheres, mesh simplification that keeps patch borders), view-culling math (chunk bounds and normal cones, frustum and back-face tests) and the choice of simplified groups to draw, OBJ and PLY reading and writing with cleanup of what is read, response curves (the pen pressure curve); no rendering or UI imports |
| `src/camera` | Orbit camera math, including how a leaning pen turns the brush in the view; no rendering or UI imports |
| `src/gizmo` | Move gizmo math: projection, handle picking, axis and view-plane drags; no rendering or UI imports |
| `src/sculpt` | Brush dabs on a `geom.Mesh`: mesh split into nodes that own contiguous vertex ranges, parallel brushes (Draw, Smooth, Clay, Flatten, Inflate, Pinch, Crease, Grab) with X/Y/Z symmetry, pen tilt and alphas (a grey image that shapes each dab), a per-vertex mask, per-frame normal updates, dirty vertex ranges for upload, stroke undo/redo that saves only the nodes a stroke touched (512 MB cap per object), simplified copies of groups of nodes rebuilt between strokes, subdivision levels, HD detail sculpted a window at a time above the top level, dynamic topology (brushes split and collapse edges as they go), levels in and out of the scene file |
| `src/jobs` | Persistent worker pool (`parallel_for`) used by sculpt and mesh setup |
| `src/bench` | Headless sculpt benchmark at chosen mesh sizes (no window or GPU) |
| `src/sdf_trial` | Standalone SDF/voxel comparison spike (not linked into the app) |

The 3D viewport is rendered by `render` into an offscreen texture that the `Viewport` panel displays. Strokes undo and redo with Ctrl+Z and Ctrl+Shift+Z (or Ctrl+Y), also in the Edit menu; the order runs across objects. Changes that rebuild an object undo the same way: remesh, dynamic topology on or off, Delete higher and Delete lower, and adding, importing or deleting (Delete key) an object. Before such a change the object is kept as the scene file stores it (every level as positions, the mask, dynamic topology); undo rebuilds it from that and keeps the object it replaces, so redo works too. That costs about 37 bytes a base vertex plus 12 a vertex of each level above (about 370 MB for a 10M-vertex object), up to 1.5 GB in all, past which the oldest go; the Stats panel shows the total. The object's strokes from before such a change can no longer be undone one by one, and HD detail is not kept (the HD steps are). Undoing a remesh takes about 0.1 s at 100k vertices and 0.24 s at 1M on the test VM (release build). ImGui never owns sculpt state: panels read and edit `App` fields through pointers each frame, and the viewport panel reports mouse input as a plain struct the camera and the active tool consume. Each object keeps its mesh in local space with a transform (position, uniform scale, rotation), so moving or turning an object never rewrites its vertices; the brush works in the object's local space, and so do symmetry and Mirror and weld. The Scene panel's Rotation turns the selected object (degrees about X, then Y, then Z); scenes save it (scene file version 2, which still opens version 1 files).

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

`--vertices=N` start with a geodesic sphere of about N vertices (the Scene panel adds spheres or remeshes the selected one at any typed vertex count), `--subdiv=N` icosphere level when `--vertices` is not given (default 6: 40,962 vertices), `--threads=N` sculpt threads including the main one (default: one per core), `--frames=N` exit after N frames, `--spheres=N` start with N spheres of that size side by side, `--subdivide=N` give each starting sphere N subdivision levels above it (`--vertices=40000 --subdivide=4` tops out at 10M), `--level=N` start on level N (1 is the base; default the top), `--no-cache` draw every object every frame instead of caching idle ones (for A/B timing; also a checkbox in the Stats panel), `--bench-stroke=N` synthetic brush stroke over N frames across the first sphere, then print stats (with levels, also the time of each step down to the base and back), `--bench-samples=N` give each of those frames N pointer samples along the path, like a high-rate mouse (default: one position a frame), `--bench-loops=N` make that stroke N circles around the middle of the sphere instead of a wavy line, `--gpu-debug` GPU debug/validation mode, `--no-partial` redraw the whole viewport every frame (also a Stats panel checkbox), `--dump-viewport=PATH` write the last viewport image as a PPM on exit (for comparing renders), `--check-mesh` check every object's mesh on exit (closed, consistently wound, no degenerate triangles or NaN) and print the counts as `mesh_*` lines, `--no-cull` draw every triangle instead of skipping off-screen and back-facing chunks (for A/B timing; also a checkbox in the Stats panel), `--no-vsync` show frames as soon as they are ready (also a Stats panel checkbox), `--no-simplify` draw everything at full detail while the view moves too (also a Stats panel checkbox), `--orbit` turn the camera around the scene by itself, once every 240 frames, `--time-gpu` measure the GPU time of the 3D viewport every frame (also a Stats panel checkbox), `--gpubench=PATH` run the GPU benchmark below and write its tables to PATH, `--gpubench-frames=N` measured frames per benchmark case (default 120), `--hd=N` give each starting sphere an HD level N Loop steps (1 to 3) above its top level, `--hd-open` start sculpting HD on the first sphere, in a window around the side facing the camera, `--hd-window=N` vertices an HD window holds (default 4,000,000; also a slider in the Scene panel), `--brush=NAME` start with that brush (draw, smooth, clay, flatten, inflate, pinch, crease, grab or mask; also what `--bench-stroke` uses), `--symmetry=AXES` start with symmetry across those axes (e.g. `x` or `xz`), `--falloff=NAME` start every brush with that falloff preset (smooth, linear, sharp, firm or flat), `--rotate=X,Y,Z` turn the first object that many degrees about each axis before starting, `--mirror=AXIS` mirror and weld the first object before starting (x, y or z keeps that axis's + side, -x, -y or -z the - side; after `--remesh`), `--remesh=N` voxel remesh the first sphere to about N vertices before starting, as Remesh selected does (after `--subdivide` and `--level`), `--dyntopo` turn dynamic topology on for the first sphere before starting (after `--remesh`), as Ctrl+T does, `--detail=PX` its detail in screen pixels (default 10; also a slider in the Tools panel), `--open=PATH` start with the scene saved in that `.sculpt` file instead of spheres, `--import=PATH` start with the mesh in that `.obj` or `.ply` file instead of spheres (after any `--open`), `--export=PATH` on exit, write the selected object's shown level to that `.obj` or `.ply` file, `--save=PATH` on exit, save the scene to that `.sculpt` file (after `--export`), `--tilt-strength=F` how far a leaning pen turns the brush, 0 to 1 (default 0; the Tilt slider in the Tools panel), `--bench-tilt=DEG` lean the synthetic pen of `--bench-stroke` that many degrees to the right (with `--tilt-strength`), `--alpha=NAME` start with that brush alpha: a built-in one (square, noise, rings, stripes, dots or star) or an image file, `--alpha-mode=MODE` which way its top faces: stroke (the default), fixed or random, `--alpha-angle=DEG` turn it that many degrees counter-clockwise on top of the mode, `--width`, `--height`.

`python scripts/ppm.py to-png build/view.ppm build/view.png` turns a `--dump-viewport` file into a PNG; its `uniform`, `diff`, `crop` and `pixel` commands detect a blank frame, count and box the pixels two dumps disagree on, enlarge a region and print values (`python scripts/ppm.py -h`).

## Benchmark

`build/bench [vertex counts...] [--meshes=N] [--threads=N] [--node=N] [--prefault=MB]` builds a sphere of each size (N of them with `--meshes`, only the first sculpted; with no sizes given it also runs 10M with a second idle sphere), prepares it for sculpting, runs the same 77-dab stroke with a large (r=0.13) and a small (r=0.04) brush, and prints a markdown table, including the undo memory of each stroke and the time to undo and redo it. A frame is 4 dabs plus the normal update and is what the app does per frame during a fast stroke. The normal update recomputes every normal of the nodes whose triangles moved, but only the border vertices of their neighbours; the normal cones that back-face culling uses wait until the stroke ends (until then those chunks are simply not back-face culled), and "Stroke end ms" is the frame where that work starts, at most 512 nodes a frame. A second table culls the sculpted sphere from three cameras (whole sphere, close-up, detail) and reports the share of triangles that would be drawn, the number of indirect draw commands, and the CPU time to cull. On cloud VMs, pass `--prefault=3000` so the VM's slow first touch of fresh memory does not dominate setup times.

`build/bench --lod [vertex counts...]` prints a table for simplified drawing instead: at each size, the time to build every group's copy as the app does (a batch a frame), the copies' memory, the triangles drawn and the CPU time to choose them from the culling table's three cameras at full detail and with copies at most 1 px off (on a 1000 px tall viewport), and the time to rebuild what the large-brush stroke made stale.

`build/bench --brushes [vertex counts...]` prints a table with one row per brush instead: the main table's stroke with the large brush, for every brush kind, then Draw with X symmetry, Draw over a sphere masked on one side and Draw with the Noise alpha (see Brushes, masking and symmetry and Brush alphas below).

`build/bench --masks [vertex counts...]` prints a table for the mask commands instead: at each size, each command on a sphere masked on one side, with how many vertices it changed and its undo (see Brushes, masking and symmetry below).

`build/bench --remesh [vertex counts...]` prints a table for voxel remesh instead: at each size, a sphere with one Grab move that pulls a wide spike out of it, remeshed back to the same vertex count (see Voxel remesh below).

`build/bench --dyntopo [vertex counts...]` prints a table for dynamic topology instead: at each size, the main table's stroke with the large brush on the usual layout, then with dynamic topology on, once with nothing to split, once refining and once more over what it refined, with undo, redo and the time to turn it on and off (see Dynamic topology below).

`build/bench --files [vertex counts...]` prints a table for files instead: at each size, a sphere written as OBJ and as PLY and parsed back, cleaned up and made ready to sculpt as File > Import mesh does, then saved and read back as a scene; and a second table for scenes with subdivision levels, laid out as `--levels` lays them out (see Files below). It works in memory, without the disk.

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

Ctrl+D (or Subdivide in the Scene panel) adds a level above the top one and goes to it; D and Shift+D go up and down a level, and the Scene panel has a level slider. The panel shows how many vertices and how much memory the next level would take (Subdivide is refused past 12 GB), the memory all levels use, and how long the last level change took. Delete lower makes the current level the base; Delete higher drops the levels above it; both are undo steps (that object's earlier strokes can no longer be undone one by one). Undo and redo walk back across levels, switching the object to the level each stroke was made on.

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

## Brushes, masking and symmetry

Nine brushes, picked in the Tools panel or with keys 1 to 9 in this order:

| Key | Brush | What it does (Ctrl inverts) |
| --- | --- | --- |
| 1 | Draw | Pushes the surface out along the average normal under the brush (in). |
| 2 | Smooth | Moves each vertex toward the average of its neighbours. Shift smooths with any brush. |
| 3 | Clay | Builds up toward a plane just above the surface, moving only what lies below it, so dips fill first and strokes leave flat-topped layers (digs). |
| 4 | Flatten | Pulls toward the plane through the area under the brush (pushes away from it). |
| 5 | Inflate | Pushes each vertex along its own normal, so shapes swell evenly (shrinks). |
| 6 | Pinch | Pulls the surface together toward the brush's centre, along the surface (pushes apart). |
| 7 | Crease | Cuts a sharp groove: draws in with a narrow falloff and pinches toward the stroke (a sharp ridge). |
| 8 | Grab | ZBrush's Move: picks up what is under the brush where the stroke starts and drags it with the pointer, in the plane facing the camera, each vertex by its falloff weight. |
| 9 | Mask | Paints the mask (erases it). |

Masking works as in ZBrush: each vertex has a mask from 0 to 255, and every brush moves it only by what the mask leaves (a fully masked vertex never moves). Masked areas are drawn darker. The Tools panel's Clear (Alt+M), Invert (Ctrl+I) and Mask all change the whole mask at once; mask strokes and these commands are undo steps like any stroke. Blur, Sharpen, Grow and Shrink move the mask's edge, as ZBrush's BlurMask, SharpenMask, GrowMask and ShrinkMask and Blender's mask filters do, a step at a time: each vertex takes from the corners of its triangles their average (Blur), their highest value (Grow) or their lowest (Shrink), so a step reaches one ring of triangles further, and Sharpen pushes each partly masked vertex toward masked or unmasked against half a Blur step, which narrows a soft edge to a sharp one that stays smooth along the triangles. Mask cavities masks the creases and dents, as ZBrush's Mask By Cavity does: each vertex is masked by how far it sits below the average of its neighbours along its normal, measured against their distance, so grooves and pores go dark and flat or bulging parts stay free; Blur after it softens the result. Steps sets how many steps a press takes (3 by default): since a step is a ring of triangles, a denser mesh needs more for the same distance. The section shows what the last command did and how long it took. The mask is carried when the object changes subdivision level (a vertex that continues one of the level below takes its mask, a new edge vertex the average of the edge's ends), so it holds on every level. An HD window starts unmasked and its mask is dropped when it closes. The mask costs no GPU memory or upload: it rides in the low 4 bits of each of the two 16-bit halves of the vertex's packed normal, which still places the normal within 0.1 degrees.

Mask shapes work as ZBrush's: with the Brush tool, Ctrl and a left drag that starts on empty space (not on an object) draws a rectangle, or a lasso when the Mask section says so, and letting go masks everything of the selected object inside it, through to the back side; with Alt held too it unmasks. Each shape is an undo step. The polygon is filled into a 1024 x 1024 coverage grid first, so a lasso of any length costs a lookup per vertex: at 10M vertices a shape takes about 25 ms on the test VM, 2 ms at 1M (`build/bench --masks` has the rows). A drag that starts on an object is a stroke as before, and Alt + left drag without Ctrl still orbits.

Symmetry (the X, Y and Z boxes in the Tools panel; the X key toggles X) mirrors every dab across those planes through the object's origin, up to 8 images with all three; Grab drags each image the mirrored way.

Each brush costs about what Draw does (`build/bench --brushes`, 4 threads, this repo's cloud VM, the large brush; a frame is 4 dabs plus the normal update, and Grab is one move a frame):

| Brush | 1M: verts/dab | 1M: dab ms | 1M: frame ms | 10M: verts/dab | 10M: dab ms | 10M: frame ms | 10M: frame ms max |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Draw | 3875 | 0.031 | 0.20 | 38810 | 0.262 | 1.67 | 2.39 |
| Smooth | 3936 | 0.047 | 0.27 | 39403 | 0.500 | 2.62 | 3.82 |
| Clay | 3914 | 0.030 | 0.19 | 39204 | 0.271 | 1.78 | 2.04 |
| Flatten | 3937 | 0.030 | 0.18 | 39414 | 0.287 | 1.80 | 2.69 |
| Inflate | 3871 | 0.029 | 0.18 | 38766 | 0.301 | 1.88 | 5.44 |
| Pinch | 4018 | 0.032 | 0.20 | 40240 | 0.319 | 1.92 | 2.39 |
| Crease | 4023 | 0.040 | 0.26 | 40294 | 0.332 | 1.94 | 3.65 |
| Grab | 3724 | 0.013 | 0.05 | 37162 | 0.117 | 0.44 | 1.27 |
| Mask | 3178 | 0.013 | 0.06 | 31831 | 0.107 | 0.55 | 4.59 |
| Draw, X symmetry | 7734 | 0.083 | 0.56 | 77453 | 0.507 | 3.16 | 5.51 |
| Draw, half masked | 1931 | 0.039 | 0.26 | 19376 | 0.202 | 1.42 | 1.76 |
| Draw, Noise alpha | 3966 | 0.055 | 0.35 | 39727 | 0.371 | 2.07 | 2.56 |

For Grab, verts/dab is what it holds and dab ms is one move. Smooth costs more because it reads every neighbour of each vertex, symmetry costs a dab per image, and fully masked vertices cost almost nothing. Mask strokes skip the normal update and only send the painted vertices to the GPU again.

A vertex whose triangles' corners all share its value, fully masked or unmasked, stays as it is under every mask command, so after one quick check of every node a step works only on the nodes around the mask's edge, and the step after it only rechecks the nodes next to what moved. A press costs about one pass over the mask whatever the steps, then a little per step for the edge (`build/bench --masks`, 4 threads, this repo's cloud VM, a sphere masked on one side):

| Command | Steps | 1M: changed | 1M: ms | 10M: changed | 10M: ms | 10M: undo MB |
| --- | --- | --- | --- | --- | --- | --- |
| Clear | 1 | 499k | 1.0 | 5.00M | 14.5 | 6.0 |
| Invert | 1 | 998k | 1.4 | 10.00M | 20.8 | 11.9 |
| Blur | 1 | 3k | 1.8 | 11k | 10.8 | 0.2 |
| Blur | 10 | 20k | 11.6 | 64k | 61.4 | 0.4 |
| Sharpen | 1 | 3k | 1.8 | 11k | 10.5 | 0.2 |
| Grow | 1 | 1k | 1.5 | 5k | 10.3 | 0.2 |
| Grow | 10 | 18k | 7.6 | 59k | 43.6 | 0.4 |
| Shrink | 1 | 1k | 1.5 | 6k | 10.1 | 0.2 |

Before working only near the edge, a step at 10M took 85 to 107 ms and ten steps 750 ms. The undo holds only the nodes that changed, and the upload after a command takes under 0.3 ms unless it changes the whole mask.

## Voxel remesh (DynaMesh)

Remesh selected in the Scene panel (or Ctrl+R, at the object's own vertex count) rebuilds the selected object as an even surface of about that many vertices, as ZBrush's DynaMesh does: stretched triangles from Grab or long strokes become even again, overlapping or self-intersecting parts merge into one closed surface, and anything thinner than the lattice spacing goes. It keeps the shape of the level the object is on; its levels, HD detail and mask go, and Ctrl+Z brings them back (HD detail apart).

How it works (`src/geom/remesh.odin`): the object is laid on a lattice whose spacing gives about the asked-for vertex count (at most 4,096 lattice points along any axis, DynaMesh's top resolution). A ray along each lattice row finds where it crosses the mesh and which way, using exact fixed-point tests so a ray through a shared edge or vertex counts it once, and a lattice point is inside where the winding number is positive. Rays along y and z find where the surface crosses those lattice edges. Marching cubes then joins the crossings, with one rule on ambiguous cube faces that makes the result closed and manifold (every edge between exactly two triangles), and three rounds of relaxation along the surface even out the triangles. Rays, crossings and cells are stored only where the surface is, so memory grows with the surface's area rather than the lattice's volume.

`build/bench --remesh` (4 threads, this repo's cloud VM, `--prefault=3000`). Sculpt-ready is the same preparation as any new mesh of that size (BVH, chunks, normals). Edge spread is the 99th percentile and the longest edge over the median edge, before and after:

| Vertices | Remeshed vertices | Remesh ms | Sculpt-ready ms | Edge p99 / median before | after | Max / median before | after |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 500k | 504k | 160 | 67 | 3.38 | 1.59 | 4.5 | 1.7 |
| 1.00M | 1.00M | 298 | 154 | 3.38 | 1.59 | 4.5 | 1.7 |
| 5.00M | 5.03M | 1519 | 686 | 3.37 | 1.59 | 4.5 | 1.7 |
| 7.00M | 7.05M | 2434 | 919 | 3.37 | 1.59 | 4.5 | 1.7 |
| 10.00M | 10.06M | 4310 | 1315 | 3.37 | 1.59 | 4.5 | 1.7 |

The remesh itself runs on every thread; on this VM a large share of it is first touches of new memory, which are much cheaper on a desktop. Peak memory at 10M was 2.3 GB, the old and new meshes included.

## Mirror and weld, duplicate

Mirror and weld in the Scene panel (as ZBrush's Mirror And Weld and Blender's Symmetrize) replaces one half of the selected object with a mirror image of the other, across the object's own X, Y or Z plane (the one brush symmetry uses), keeping the + side unless "keep the - side" is ticked. Triangles crossing the plane are cut at it and the two halves are welded along the cut (`geom.mesh_symmetrize`, `src/geom/symmetrize.odin`), so a closed object stays closed; vertices within 1/100,000 of the object's size of the plane move onto it so the cut makes no slivers. It works on the level the object is on and rebuilds the object like a remesh: levels, HD detail and mask go, and Ctrl+Z brings them back. 100k vertices take about 0.1 s on the test VM. Flag: `--mirror=x` (or `-x`, `y`, `-y`, `z`, `-z`) does it to the first object before starting.

Duplicate selected (Ctrl+Shift+D) adds a copy of the selected object beside it, with every subdivision level, the mask and dynamic topology (HD detail is not copied, as in a saved scene), and selects it; Ctrl+Z removes it.

## Dynamic topology

Ctrl+T, or the checkbox under Dynamic topology in the Tools panel, turns dynamic topology on for the selected object, as Sculptris Pro in ZBrush and dyntopo in Blender do: each dab first splits the edges under the brush longer than Detail pixels on screen and, with Collapse short edges (on by default), collapses the ones shorter than 0.4 of that. The brush makes triangles where it goes, as many as the detail you see needs, so you can start from a coarse ball and pull out horns and folds without stretching anything. Since Detail is in pixels, zooming in makes finer triangles. On a dense mesh seen from afar the edges are already shorter than Detail, and with collapse on the brush coarsens what it touches; lower Detail or untick collapse to keep the density. Every brush works with it, symmetry too; Grab and Mask leave the triangles as they are, and so do fully masked areas. The object needs a single subdivision level and no HD level, and turning it on or off is an undo step of its own (its earlier strokes can no longer be undone one by one). Remesh selected works on a dynamic object and turns it off.

How it works (`src/sculpt/dyntopo.odin`): the sculptor works per node as it does on a fixed mesh, but each node gets a page of the mesh's arrays (1,280 vertex slots and 2,048 triangle slots) and uses the first of them, so it grows and shrinks in place; unused triangle slots hold zeros, which draw nothing. A node whose page fills up splits in two along its longest axis, and the BVH over the nodes is rebuilt then, in well under a millisecond. Each vertex lists its triangles (up to 16), so splits and collapses only touch what is around them. Splits go longest first and cut each triangle across its longest side (Rivara's bisection): when either triangle beside an edge has a longer one, that splits first, even just outside the brush. Triangles stay well shaped however often an area is refined: no angle went below 24 degrees in our measurements, and a test strokes one ring 160 times and checks for angles under 15 degrees, folds and the whole layout every 20 dabs. A collapse is refused where it would fold or pinch the surface, give a vertex more than 12 triangles, make an edge longer than Detail, or leave its worst triangle thinner than before and under 0.3 on a scale where an equilateral triangle is 1 (2√3 times the area over the sum of the squared sides), so thin slivers do not pile up where the brush coarsens. Surfaces that are not closed work too (an imported scan, say): an edge on the border splits its one triangle, and collapses leave border vertices where they are, so the border keeps its shape. Turning it on is refused on a mesh with an edge shared by more than two triangles or with triangles facing opposite ways across an edge. A dab makes at most 2,048 splits and 2,048 collapses, and the app stops laying dabs for a frame once they have taken 10 ms, so a large brush over a coarse area keeps the frame rate and catches up over the next frames. Undo saves each node a stroke changes, whole, before its first change, and swaps it back. The GPU gets the index pages that changed along with the changed vertices; when the mesh outgrows its buffers, they are made again at the larger size.

`build/bench --dyntopo` (4 threads, this repo's cloud VM). A frame is 4 dabs plus the normal update, as in the main table. Fixed is the large-brush stroke on the usual layout, Plain the same with dynamic topology on but nothing to split, Refine with a detail that splits every edge under the brush once (each triangle into four), which is far more than a stroke on a coarse mesh asks for: from 5M up every dab stops at its 2,048 splits. Upload is the changed vertices plus the changed index pages:

| Vertices | Turn on ms | Fixed frame ms | Plain frame ms | Refine frame ms | Splits | Triangles after | Upload MB/frame | Undo ms | Redo ms | Turn off ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 500k | 34 | 0.23 | 0.24 | 13.1 | 117k | 1.16M | 0.91 | 11.6 | 9.9 | 83 |
| 1M | 71 | 0.34 | 0.35 | 16.8 | 157k | 2.27M | 1.46 | 35.0 | 33.0 | 191 |
| 5M | 319 | 0.99 | 1.04 | 22.4 | 157k | 10.31M | 2.07 | 46.4 | 43.4 | 714 |
| 7M | 994 | 1.58 | 1.51 | 28.8 | 157k | 14.33M | 2.43 | 60.1 | 57.7 | 1053 |
| 10M | 1312 | 1.83 | 2.70 | 31.7 | 157k | 20.32M | 2.78 | 74.6 | 72.1 | 1446 |

A split or collapse costs about 1.5 microseconds at 500k and 4 at 10M, normals included. Plain strokes cost about what they do on the fixed layout, up to half again at 10M (this VM's timings vary by about that much from run to run). The pages cost memory: right after turning it on each node fills about half its page, so the mesh takes about twice its fixed-layout memory, mostly in the per-vertex triangle lists; peak memory at 10M was 2.5 GB. Turning it on at 7M and 10M is mostly the VM's slow first touch of that memory. Turning it off packs the mesh and prepares it as any new mesh of that size.

## Files

The File menu opens and saves scenes and imports and exports meshes, each through the system's file dialog (SDL's); what the dialog picks runs at the start of the next frame. The outcome shows in the menu bar for 15 seconds, in amber when something failed or needs attention (hover for the whole text), and goes to the log.

**Scenes** (`.sculpt`: Open scene, Save scene, Save scene as): every object with all its subdivision levels as shown, the mask of its current level, dynamic topology if on, its name and place, and the camera. Each level is stored as positions, so it opens exactly as it was saved. Since the vertex numbering changes whenever a level is built, the levels above the base store their vertices in an order the topology alone decides: the vertices that continue the level below first, then those on its edges, by the edge's ends. Opening builds every level again from the base, as subdividing does, and moves its vertices where they were, so it takes about as long as subdividing to that size. HD detail is not saved, only each object's number of HD steps; the HD section says so while an object has stored detail, and so does the note after saving. Nor is the undo history. Opening reads and uploads the whole new scene before the old one goes, so a damaged file leaves the scene as it was (both are in memory for a moment). Saving writes beside the file and renames over it, so a failed save never leaves a half-written file. The format is little-endian binary with a version number: `scene_save` in `src/app/files.odin`, then per object `levels_write` in `src/sculpt/levels_file.odin`.

**Import** (Import mesh, `.obj` or `.ply`): OBJ `v` and `f` lines (polygons become fans of triangles; negative indices and `v/vt/vn` corners work; everything else is skipped), read in parallel chunks of 4 MB. PLY in ASCII or binary of either byte order, with any vertex properties (x, y and z are kept) and polygon faces. Then a cleanup: vertices at exactly the same place are welded (exporters split vertices along UV seams), triangles left with a repeated corner and vertices no triangle uses are dropped, and a closed surface that faces inward is turned outward. The mesh is centred and sized like a sphere (radius 1) and placed beside the other objects; its place in the file is kept for export. A surface that is not closed sculpts, also with dynamic topology, which keeps its border, but subdivision, HD and remesh need a closed one, and the note says so.

**Export** (Export selected, `.obj` or `.ply` by the name, or by the dialog's filter when the name has none): the selected object's shown level (packed, when dynamic), as OBJ with nine significant digits, which read back as the same floats, or as binary PLY. It goes back where it was in the file it came from, so an imported mesh exported again lines up with the original; Move tool placement is not written.

Normal and displacement map baking is not there yet: it needs UVs, which nothing makes yet.

`build/bench --files` (4 threads, this repo's cloud VM, in memory, so without the disk). Parse is the reader alone, Clean the weld, centring and edge check after it, Sculpt-ready the setup any new mesh of that size gets (nodes, BVH, normals). Scene read includes that setup:

| Vertices | OBJ MB | OBJ write ms | OBJ parse ms | PLY MB | PLY write ms | PLY parse ms | Clean ms | Sculpt-ready ms | Scene MB | Scene write ms | Scene read ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 500k | 40 | 71 | 49 | 18 | 4 | 7 | 61 | 61 | 17 | 27 | 92 |
| 1M | 81 | 127 | 62 | 36 | 7 | 14 | 117 | 122 | 34 | 50 | 145 |
| 5M | 430 | 680 | 438 | 181 | 36 | 77 | 770 | 900 | 172 | 229 | 1202 |
| 7M | 605 | 1271 | 595 | 254 | 50 | 107 | 1025 | 1349 | 241 | 390 | 2144 |
| 10M | 866 | 1796 | 1547 | 362 | 75 | 149 | 1747 | 1815 | 343 | 534 | 3417 |

Scenes with subdivision levels, laid out as in the `--levels` table (a base of at most 40k vertices). Only the base's triangles are stored, so the file is a third smaller than one level of that size; reading builds every level, as subdividing does:

| Top vertices | Levels | Base vertices | Scene MB | Scene write ms | Scene read ms |
| --- | --- | --- | --- | --- | --- |
| 501k | 3 | 31k | 8 | 24 | 188 |
| 1.02M | 4 | 16k | 16 | 38 | 354 |
| 4.96M | 5 | 19k | 76 | 259 | 3151 |
| 6.92M | 5 | 27k | 106 | 306 | 4433 |
| 9.84M | 5 | 38k | 151 | 435 | 6300 |

Much of the time from 5M up is this VM's slow first touch of fresh memory (about 0.5 s per GB, sometimes several seconds), which a desktop does far faster: copying 120 MB into fresh memory took 0.7 s here. A real disk adds its read or write time; the Scene panel shows the last file's times (for an import, reading the disk and parsing apart).

## Pen and brush pie

The Tools panel's Pen section holds what a drawing tablet changes. "Pressure sets strength" and "size" choose what pen pressure scales; a mouse counts as full pressure. The pressure curve below them maps how hard the pen presses (along) to how much that counts as (up): a cubic Bézier from corner to corner whose two handles drag anywhere in the square, so it never falls back. Linear, Soft (light pressure goes far), Firm (it takes a press) and S are presets. A dot on the curve follows the pen. The Tilt slider (0 by default) lets a leaning pen turn the brush: the direction Draw, Clay, Flatten, Pinch and Crease push in leans toward the pen's top, by the pen's lean times the slider, at most 81 degrees, as Blender's tilt does; mirrored dabs lean the mirrored way. With tilt on, a line from the brush circle shows the lean. The readout under it shows the last pressure, what it counts as, and the lean. Tilt costs one small rotation a dab: a 2M stroke took the same brush time with it and without (1.27 to 1.33 ms p50 either way, run to run). SDL reports pen pressure and tilt on Windows (pointer messages) and on Linux (X11 and Wayland); neither is tested on a real tablet yet.

The brush pie puts the nine brushes in a ring around the pointer, in key order clockwise from the top. Hold Space over the viewport, point toward a brush and let go to pick it, so a flick picks without aiming. A tap of Space, or a right click without dragging (a pen's side button sends one), leaves it open: click a brush, or click the middle, press Escape or tap again to close it. While it is open, nothing reaches the tools or the camera. The slice of the brush in use has a band along its outer edge.

## Brush falloff

The Tools panel's Falloff section shows how strongly the brush in use works from its centre (left) to its rim (right). By default it is the built-in smooth falloff, (1 − d²)² for the distance d in radii. Dragging either handle draws your own: a cubic curve read from the rim in, as the pressure curve is drawn, so it is always 0 at the rim and full at the centre. Presets: Smooth (the built-in), Linear (a cone), Sharp (a point in the middle, for creases and pores), Firm (most of the radius at full strength) and Flat (full strength to the rim, a hard-edged stamp). Each brush keeps its own falloff, Grab and Mask included; an alpha replaces it. The sculptor reads a drawn falloff from a 257-entry table over the squared distance, so it costs no square root: a 2M stroke's brush time was 7 to 12% higher with one than with the built-in (0.24 vs 0.25 to 0.27 ms p50, release, test VM). Flag: `--falloff=NAME` starts every brush with that preset.

## Brush alphas

An alpha, as in ZBrush (Blender calls it a brush texture), is a square grey image that shapes each dab in place of the round falloff: white moves fully, black not at all. The Tools panel's Alpha section shows the round brush and every alpha as thumbnails; click one to use it. Six are built in: Square (flat stamps and edges), Noise (bumps of every size, for skin, stone and bark), Rings, Stripes (ridges along the image's up, so along a stroke they rake parallel grooves), Dots (rivets, scales) and Star. "Load image..." adds a PNG, JPEG, BMP, TGA or QOI file: its brightness times its opacity, padded to a square and averaged down to at most 512 pixels a side, so a grey height map and a white shape on a transparent ground both work. Every brush but Grab uses the alpha; Shift's smoothing stays round.

The image lies on the plane across the area under the brush, its middle on the dab's centre and its sides one radius away, so a stamp sits flat on a curved surface. A vertex takes the image's value where it falls, blended between pixels, and fades as it lies further above or below that plane. Which way the image's top faces is the mode: Follow stroke turns it with the stroke, Fixed keeps it to the screen's up, and Random turns every dab a new way, for texture without a visible repeat; Angle turns it further. The brush outline becomes the image's square, turned as the next dab will be, with a tick at its top. Symmetry mirrors the image too, so a stamp on the left reads backwards on the right as a mirror would show it.

A dab looks for vertices as far out as the image is above 0, measured when it loads: up to the square's corners, 1.41 radii, but no further than the round brush for images that fade out inside their circle, like the built-in ones but Square. With the Noise alpha a dab costs about a fifth more than Draw and a frame under a tenth more (`build/bench --brushes`, the large brush; Draw measured 0.037 and 0.312 ms a dab and 0.27 and 1.91 ms a frame at 1M and 10M in the same run, beside the alpha row in the table above), the extra being three dot products and one image lookup a vertex.

## Viewport materials and wireframe

View > Material picks how objects are shaded: Clay (the default, as before), Red wax, White, Grey and Skin. Each sets the selected object's colour, a muted one for the others, and the light's ambient, highlight and wrap (wax and skin let the light reach past the shadow line, as scattering does). View > Wireframe, or Shift+F as ZBrush's PolyFrame, draws the selected object's triangle edges over it: the same visible chunks again with line fill, pulled toward the eye by a depth bias so they sit on the surface, so it roughly doubles the selected object's draw cost while it is on. Flags: `--material=NAME`, `--wireframe`.

## Controls

Files: Ctrl+O opens a scene, Ctrl+S saves it (where it was last saved or opened, else it asks), Ctrl+Shift+S saves it somewhere else.

Tools: W selects Select / Move, B selects Brush. F points the camera at the selected object; Shift+F shows its wireframe. Delete deletes it (Ctrl+Z brings it back). Ctrl+D subdivides the selected object; D and Shift+D go up and down its levels; Ctrl+Shift+D duplicates it. Ctrl+R remeshes it at its own vertex count. Ctrl+T turns dynamic topology on or off for it. A opens an HD window where the pointer is on an object with an HD level, or closes the open one.

Select / Move: click an object to select it, drag it to move it in the view plane, or drag a gizmo arm (red X, green Y, blue Z) to move along that axis. Position and scale can also be typed in the Scene panel.

Brush: left drag sculpts the object under the cursor, which becomes selected (Shift smooths, Ctrl inverts; the Mask brush then erases). Keys 1 to 9 pick a brush, X toggles X symmetry, Alt+M clears the mask and Ctrl+I inverts it. Ctrl + drag from empty space masks a rectangle or lasso (Ctrl+Alt unmasks). The brush follows every mouse or pen sample, not just where the pointer is once a frame: dabs go along the path the pointer took on screen, a quarter of the radius apart, each where that point meets the surface. Pen pressure scales the strength, and the size too with "Pressure sets size" in the Tools panel, through the pressure curve there; a mouse counts as full pressure. Space (hold and let go, or tap) or a right click without dragging opens the brush pie (see Pen and brush pie above). S over the viewport sizes the brush where it is (move away from or toward the circle's middle, then click or press S again; a right click or Escape puts the old size back), and U does the same for the strength; [ and ] step the size, Shift+[ and Shift+] the strength. Each brush keeps its own strength, and Shift-smoothing uses the Smooth brush's. Lazy mouse makes the brush trail the cursor on a string that many pixels long, for steadier lines. With an alpha (see Brush alphas above) the outline is the alpha's square.

Scene panel: type a vertex count (or pick a preset), then Add sphere, or Remesh selected to rebuild the selected object as an even mesh of about that count that keeps its shape (see Voxel remesh above). Geodesic spheres come in steps of 10f² + 2 vertices; the panel shows the exact count it will build.

Orbit: right drag or Alt + left drag. Pan: middle drag or Shift + right drag. Zoom: mouse wheel. P (or keypad 5) switches between perspective and orthographic (parallel) projection, as wide at the orbit centre as the perspective view, so the object keeps its size on screen. Keypad 1, 3 and 7 look from the front, right and top, with Ctrl from the back, left and bottom (View > Look from). In orthographic projection the far-chunk simplification while orbiting is off. Flags: `--ortho`, `--view=front|back|right|left|top|bottom`.
