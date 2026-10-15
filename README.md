# Sculpt

A performance-focused sculpting prototype in Odin, using SDL3 + SDL_GPU for rendering and Dear ImGui for the surrounding interface.

## Layout

| Path | Owns |
| --- | --- |
| `src/app` | Entry point, frame loop, scene of sculptable objects, Move and Brush tools, ImGui panels, input routing into `Viewport_Input` |
| `src/render` | Every GPU object the app creates: device, pipeline, viewport target, mesh buffers, shaders |
| `src/geom` | CPU sculpt geometry (structure-of-arrays triangle mesh, BVH, test spheres); no rendering or UI imports |
| `src/camera` | Orbit camera math; no rendering or UI imports |
| `src/gizmo` | Move gizmo math: projection, handle picking, axis and view-plane drags; no rendering or UI imports |
| `src/sculpt` | Brush dabs on a `geom.Mesh`: mesh split into nodes that own contiguous vertex ranges, parallel draw/smooth, per-frame normal updates, dirty vertex ranges for upload |
| `src/jobs` | Persistent worker pool (`parallel_for`) used by sculpt and mesh setup |
| `src/bench` | Headless sculpt benchmark at chosen mesh sizes (no window or GPU) |
| `src/sdf_trial` | Standalone SDF/voxel comparison spike (not linked into the app) |

The 3D viewport is rendered by `render` into an offscreen texture that the `Viewport` panel displays. ImGui never owns sculpt state: panels read and edit `App` fields through pointers each frame, and the viewport panel reports mouse input as a plain struct the camera and the active tool consume. Each object keeps its mesh in local space with a transform (position, uniform scale), so moving an object never rewrites its vertices; the brush works in the object's local space.

## Pinned versions

See `scripts/versions.env`: Odin `dev-2026-10`, SDL `3.4.18` (Linux; Windows uses the SDL3 shipped with Odin), odin-imgui `a116eb1` (Dear ImGui `1.92.8-docking`).

## Linux

```sh
# once: system packages are listed at the top of the script
./scripts/setup_deps.sh

./build.sh            # debug build with allocation tracking -> build/sculpt
./build.sh release    # optimized build
./build.sh test       # unit tests (geom, camera, sculpt, jobs)
./build.sh run -- --vertices=10000000
./build.sh smoke      # 300 frames in GPU debug mode; non-zero exit on assert, GPU error or leak
./build.sh bench      # headless sculpt benchmark at 500k, 1M, 5M, 7M, 10M vertices
```

Headless (CI or containers): run under `Xvfb` with Mesa's llvmpipe Vulkan driver (`mesa-vulkan-drivers`).

## Windows (untested so far)

From an "x64 Native Tools Command Prompt for VS" with git and python on PATH:

```bat
scripts\setup_deps.bat
build.bat            :: or: build.bat release | test | run | smoke | bench
```

Shaders are recompiled when `glslangValidator` (Vulkan SDK) is on PATH; otherwise the committed `.spv` files are used.

## App flags

`--vertices=N` start with a geodesic sphere of about N vertices (the Scene panel adds spheres or remeshes the selected one at any typed vertex count), `--subdiv=N` icosphere level when `--vertices` is not given (default 6: 40,962 vertices), `--threads=N` sculpt threads including the main one (default: one per core), `--frames=N` exit after N frames, `--spheres=N` start with N spheres of that size side by side, `--no-cache` draw every object every frame instead of caching idle ones (for A/B timing; also a checkbox in the Stats panel), `--bench-stroke=N` synthetic brush stroke over N frames across the first sphere, then print stats, `--gpu-debug` GPU debug/validation mode, `--width`, `--height`.

## Benchmark

`build/bench [vertex counts...] [--meshes=N] [--threads=N] [--node=N] [--prefault=MB]` builds a sphere of each size (N of them with `--meshes`, only the first sculpted; with no sizes given it also runs 10M with a second idle sphere), prepares it for sculpting, runs the same 77-dab stroke with a large (r=0.13) and a small (r=0.04) brush, and prints a markdown table. A frame is 4 dabs plus the normal update and is what the app does per frame during a fast stroke. On cloud VMs, pass `--prefault=3000` so the VM's slow first touch of fresh memory does not dominate setup times.

The SDF/voxel comparison spike from step 3 builds separately: `deps/odin/odin build src/sdf_trial -o:speed -collection:deps=deps`.

## Idle objects

Only the selected object is sculpted or moved, so the viewport draws every other object once into a cached colour + depth image and reuses it while the camera and those objects stay put (all through a brush stroke). Each frame then costs a screen-sized copy plus the selected object's triangles, however many idle objects there are. Orbiting, panning, zooming, selecting another object or changing an idle one redraws the cache. On the CPU side idle objects already cost nothing per frame (`build/bench` with `--meshes=2`).

## Controls

Tools: W selects Select / Move, B selects Brush. F points the camera at the selected object.

Select / Move: click an object to select it, drag it to move it in the view plane, or drag a gizmo arm (red X, green Y, blue Z) to move along that axis. Position and scale can also be typed in the Scene panel.

Brush: left drag sculpts the object under the cursor, which becomes selected (Shift smooths, Ctrl inverts).

Scene panel: type a vertex count (or pick a preset), then Add sphere, or Remesh selected to rebuild the selected sphere at that count (sculpted detail is not kept yet). Geodesic spheres come in steps of 10f² + 2 vertices; the panel shows the exact count it will build.

Orbit: right drag or Alt + left drag. Pan: middle drag or Shift + right drag. Zoom: mouse wheel.
