# Sculpt — instructions for coding agents

A performance-focused sculpting prototype in Odin (SDL3 for windows and input, its own Vulkan and Metal renderers, its own kit `src/ui` for the interface), with
ZBrush as the behaviour model. README.md is the only document and describes what exists now; this file is the map and
the skills hold the detail. It builds and runs on Windows (`build.bat`) and Linux (`build.sh`).

## 1. Before you plan: load skills
Skills live in `.claude/skills/<name>/SKILL.md` (mirrored to `.agents/skills/` by `scripts/agents_sync.py`, which also writes the agents as Codex's `.codex/agents/*.toml`). Load every
skill whose description fits the request BEFORE you form a plan.
- Always: `sm-odin` (rules for the pinned Odin) and `sm-build` (the build, run and verify loop).
- Meshes, BVH, culling math, mesh tests: `sm-geom`. Brushes, undo, subdivision levels, HD, simplified copies, the stroke
  pipeline, masking, symmetry, dynamic topology: `sm-sculpt`. Modelling tools other than brushes (voxel remesh, primitives, booleans, trims, mirror, measure): `sm-cad`.
  SDFs, voxels, implicit surfaces: `sm-sdf`. Anything drawn or uploaded: `sm-render`. Panels, input, shortcuts: `sm-ui`.
  How fast anything is: `sm-perf`. Anything that ships to users (dependencies, permissions, files, network, data,
  payments, platform builds, new screens or controls, app lifecycle): `sm-store`. Fingers, the pen, gestures, the
  camera's feel, or anything to try on a tablet: `sm-touch-testing`. Designing or changing a screen, panel or control
  in Figma, or building one from a Figma design: `sm-figma-ui`. Before calling anything done: `sm-lint`.
- Subagents (`.claude/agents/`): `sm-architect` reviews designs (read-only), `sm-investigator` root-causes bugs with a
  hypothesis ledger, `sm-verifier` builds, runs, dumps the viewport and describes what it saw, `sm-reviewer` reviews a
  finished diff against these rules (read-only). Where a role is not offered by name, start a general-purpose agent
  whose prompt says to read `.claude/agents/<role>.md` first and act as it.

## 2. First reply to a feature request
- Restate in 2–4 sentences what will exist when you are done.
- Ask only questions whose answers change what you build; give each a default, and start on the default.
- Write a design and stop for review (or ask `sm-architect`) before: a new package, a new `Scene_Command` kind, anything
  touching undo or the `History`, a topology-changing tool, a new GPU buffer layout, a shader, or more than ~300 lines.

## 3. The loop: small change → check → run → look
    python scripts\gate.py                          # section 6 in one command: check, reports, test, build, smoke, touch, iphonecheck, maccheck (+ wincheck, androidcheck on Linux)
    python scripts\gate.py --changed                # each PR of a series: only what the branch's changes reach; the full gate ends the series
    build.bat check                                   # the gate: odin check of every package + the skill mirror check
    build.bat                                         # debug app -> build\sculpt.exe (tracking allocator: a leak exits 1)
    build.bat test                                    # odin test on geom, poly, camera, sculpt, jobs, gizmo, png_write, zip, hdri, voxel, ui, luau, usd, fbx, quadmesh, retopo, app
    python scripts\test_only.py sculpt 'deform_*'     # just those tests of one package, while working
    build.bat smoke                                   # 300 frames under GPU validation, SDL_ASSERT=abort
    python scripts\touch_check.py ['long_press*']    # scripted finger, pen and mouse scenarios (a desktop simulation), in parallel on Linux
    build.bat run -- --vertices=1000000 --frames=120  # at most five arguments here; otherwise run build\sculpt.exe
    build\sculpt.exe --vertices=500000 --frames=60 --dump-viewport=build\v.ppm --check-mesh
    python scripts\ppm.py to-png build\v.ppm build\v.png     # then open the PNG and describe it; diff/crop/pixel/uniform too
    build.bat release | bench [sizes] [--threads=N] | gpubench
    python scripts\agents_sync.py                     # after editing a skill or agent (check verifies the mirror)
    build.bat android | androidrun                    # the Android APK; androidrun installs and starts it on the tablet
    build.bat web | webcheck                          # the web version into build\web\site (scripts/web_build.py: --serve, --test)
    build.bat iphonecheck                             # the app compiled for the iPad to an object (no Mac): iOS-only compile errors
    build.bat maccheck                                # the app compiled for the Mac (Apple silicon) to an object: Mac-only compile errors
    python scripts\try_it.py [names] [--debug]      # on a real machine: 11 checks on its own GPU, build\try_it\report.md and build\try_it.zip
    python scripts\ipad_build.py [--latest]           # the pushed branch's IPA built on GitHub, saved as build\ios\Sculpt.ipa
    build.bat all | clean                             # everything that builds (no display needed); remove build\ and Android's outputs
    (Linux: ./build.sh <mode>, plus wincheck and androidcheck; macOS: ./build.sh ios | iosupload | mac | macnotarize, the iPad IPA
    and the Mac app, which .github/workflows/ipad.yml and mac.yml run)
- Fix the first error first; diagnostics are `path(line:col) Error: message`. The app prints key=value stats on exit.

## 4. Map
| Path | What |
|---|---|
| `src/app` | entry point and set-up (`main.odin` `run`), the frame (`frame.odin`: `frame_settle`, `frame_events`, `frame_step`), the exit stats (`exit_stats.odin`), `Options` flags, scene of objects, the tools, the interface's panels (`new_ui.odin`, `kit_*.odin`), keys (`Key`, `keys.odin`) and pointer (`device.odin`), system services (`platform.odin`), `Viewport_Input`, cross-object `History`, `--gpubench` |
| `src/render` | every GPU object the app creates: device, pipelines, viewport target, mesh buffers, indirect draws, partial redraw, the idle cache; the seam `hal.odin` answered by the own Vulkan backend (`vk_*.odin`) or on Darwin the own Metal backend (`mtl_*.odin`), SDL_GPU retired (`backend.odin`); `shaders/` Slang with committed `.spv` and `.msl` (`shaders.odin` picks per platform) |
| `src/geom` | CPU geometry: `Mesh`, icosphere and geodesic fixtures, BVHs, topology, culling math, simplification, the LOD walk, `mesh_check` |
| `src/camera`, `src/gizmo` | orbit camera math; move gizmo math (both pure, no rendering or UI) |
| `src/poly` | Model mode's cage: half-edge polygon mesh, build and check, triangulation, targets (loops, rings, islands, paths), primitives, topology edits as polygon-list rebuilds |
| `src/sculpt` | brushes over a `Mesh` split into nodes, dirty ranges, undo, subdivision levels, HD windows, simplified copies |
| `src/ui` | the interface kit: immediate-mode layout, widgets, hit testing, CPU tessellation, fonts (no SDL, no render) |
| `src/jobs` | the persistent worker pool (`parallel_for`, `parallel_ranges`) |
| `src/zip` | ZIP archives in, as content packs come: entries, names checked against zip slip and case clashes, inflating capped by the declared size |
| `src/bench` | the headless CPU benchmark (markdown tables) |
| `src/luau` | the binding to Luau (script plugins): the C API the plugins use, linked from `deps/luau` on the desktop builds only (`AVAILABLE`) |
| `src/fbx` | FBX in (Import) through ufbx (`deps/ufbx-src`, built with our C shim `fbx_shim.c` by `scripts/build_ufbx.py`, by Android's CMakeLists and by `build.sh ios`): a few C calls, each mesh node a `geom.Mesh_Part` with its polygons and its parent node as its folder, materials and textures into a `geom.Mesh_Look`, skins, animations and shape keys counted; `build.sh`/`build.bat` rebuild it when the shim changes |
| `src/quadmesh` | Quad Remesh's engine: the binding to AutoRemesher's core (`deps/autoremesher-src` at `AUTOREMESHER_COMMIT`, built with our C boundary `quadmesh_shim.cpp` and the TBB stand-ins in `shim/tbb` by `scripts/build_autoremesher.py`; desktops only, `AVAILABLE`): `remesh` turns triangles into a `Polygon_Mesh` of nearly all quads, with progress and cancel |
| `src/retopo` | Quad Remesh's work with no scene: about so many quads on a mesh by AutoRemesher or the own engine (`geom.mesh_retopo`), Close first, symmetry and UVs (`compute`, `Result`, `Options`); run by the app's long job and by `bench --quadremesh` |
| `src/hdri` | environment panoramas in: Radiance `.hdr`, OpenEXR (all but its newest compressions, HTJ2K and ZSTD) and pictures, as linear RGB halved to a width, and their nine-term diffuse light; decoded on a thread, uploaded by `app` |
| `src/usd` | USD in (Import): `.usda` text, the `.usdc` binary crate (LZ4, integer coding) and `.usdz` through `zip`, read into a stage whose Mesh prims become `geom.Mesh_Part`s; composition not followed |
| `src/voxel` | voxel sculpting: narrow-band SDF in 8³ bricks, Add/Subtract/Smooth/Flatten/Inflate dabs, surface nets into mesh slots, per-brick undo, band repair, `SVOX` file section, conversion to a `Mesh` |
| `src/web` | the web version's entry (js_wasm64p32 only): the engine in a browser tab, pointer, wheel and key events through Odin's js runtime, one thread; `scripts/web_build.py` builds it from a copy of `src` without test files, with `web/odin_overlay` over Odin's `base/` (README "Web") |
| `src/render/webgpu` | the web version's WebGPU viewport (`vendor:wgpu`): one mesh and the brush ring, until render's seam has a WebGPU backend |
| `web/` | the web page (`index.html`: canvas, brush rail, bar, status) and `odin_overlay` (the js heap allocator Odin's runtime lacks) |
| `android/` | the Android app: Gradle project, manifest, `app/jni/CMakeLists.txt` (SDL3, stb and `src/app` built by Odin into `libmain.so`), `android_main.c` |
| `ios/` | the iPad app: `Info.plist`, `PrivacyInfo.xcprivacy` (also the Mac's) and `sculpt_ios.m` (the file dialogs SDL lacks on iOS), linked with SDL3, stb and `src/app` by `./build.sh ios` on macOS |
| `mac/` | the Mac app's `Info.plist`; `./build.sh mac` links SDL3, stb and `src/app` into `Sculpt.app` on macOS |
| `scripts/` | `setup_deps.*`, `versions.env` (the pins), `build_luau.py` (Luau from source, which setup_deps runs), `build_autoremesher.py` (AutoRemesher's core with our boundary, which setup_deps runs), `ipad_build.py` (the IPA from GitHub's Mac, or a TestFlight upload), `sdl_ios.sh` and `sdl_mac.sh` (SDL for the iPad and the Mac, which `build.sh ios` and `mac` run and their workflows cache), `build_shadercross.py` and `shaders_msl.py` (each shader's Metal source from its `.spv`; `check` runs `--check`), `gate.py` (the done gate in one command; `--changed` for one PR), `headless.py` (how scripts open the app's window with no display: offscreen SDL or Xvfb), `input_report.py` (analyses an Input diagnostics report; its tests and samples beside it), `test_only.py` (some tests of one package), `try_it.py` (a real machine's run: short checks on its GPU, a report and a zip to send back), `agents_sync.py` (skill mirror and validation), `ppm.py` (view and diff viewport dumps), `parity_check.py` (19 scenes against a baseline build, pixel for pixel), `touch_check.py` (touch, pen and camera scenarios), `export_check.py` (a glTF or USD export through its validator and Blender), `remesh_check.py` (Remesh and Quad Remesh over a fixture corpus, judged against the plan's acceptance), `link_check.py` (the Blender link's round trip through the add-on in bpy) |
| `tools/blender/` | the Blender add-on of the Blender link (`sculpt_link`, Python, GPL-3.0-or-later as Blender requires): outside the build, never in the APK |
| `deps/`, `build/` | ignored: the pinned toolchain and third-party sources; build outputs and dumps |
| `.vscode/`, `.claude/`, `.agents/`, `.codex/agents/` | tasks and launch configurations by device; skills, agents and permissions; the generated skill mirror and Codex's copies of the agents (never edited by hand) |

## 5. Hard rules
- Odin is pinned (`scripts/versions.env`, `deps/odin`): never write from memory of older Odin; grep the install.
- Package boundaries: `geom`, `camera`, `gizmo`, `jobs`, `zip`, `hdri`, `voxel`, `poly`, `luau`, `usd`, `fbx`, `quadmesh` and `retopo` know nothing of rendering or UI; `ui` knows nothing of SDL or `render`; only `render` and, in `app`, the
  platform files (windows, device, touch, pen, dialogs, `platform.odin`; `APP_SDL_FILES`) import `vendor:sdl3`, the rest naming keys by `Key` (`keys.odin`), and only `render` names the GPU API: `app` holds `render.Cmd`, `render.Texture`,
  `render.Fence` and `render.Sample_Count` and calls render's procs (`render.wait_idle`, `cmd_begin`, `cmd_submit`,
  `swapchain_acquire`, `ui_present`; `src/render/gpu.odin`), and inside render every GPU call goes through `hal.odin`'s
  `gpu_*` (Metal on Darwin, Vulkan elsewhere) and nothing calls SDL_GPU's procs, both enforced by `scripts/boundary_check.py` in `check`;
  `bench` never imports `render` or `app`.
- Determinism: serial and parallel results are bit-identical and tests compare them; no map order decides output.
- Allocations inside jobs use `runtime.heap_allocator()` for both make and delete; only the frame loop and the setup
  paths call `free_all(context.temp_allocator)` (the autosave thread frees its own arena); nothing temp is stored.
- Every vertex move goes through `apply_dab`, `sculptor_grab_move` or `sculptor_nodes_moved` (posing too), and every
  mask change through `mask_dab`, `sculptor_mask_command`, `sculptor_mask_values`, `sculptor_topo_mask_reach` or
  `sculptor_stroke_adjust`; triangles change only under dynamic topology inside a stroke. Any other
  topology change (remesh, booleans, …) copies `object_remesh`: end the stroke, leave HD, release and rebuild the object,
  which drops its levels, mask and strokes, and record it as a swap undo entry (`history_snapshot` / `history_record_swap`: `sm-cad`).
- The interface never owns sculpt state; panels keep no references between frames; scene changes are `Scene_Command`s and
  file actions are requests (`file_take`), both applied at the start of the next frame.
- The `.sculpt` scene file is chunks from version 36 (`SCENE_VERSION`, `src/app/files.odin`): a new field goes at the
  end of its chunk (`SCEN` the scene's own, `OBJ ` an object's, read only where the chunk has bytes left) or in a new
  chunk, which older apps step over; `SCENE_VERSION` moves only for a change an older reader would misread. Every older
  version keeps reading (1 to 35 field after field, frozen); a damaged file is refused, never asserted on.
- GPU: consume every `gpu_*` result (in `render`; `hal.odin` marks them `require_results`); `render.wait_idle` before freeing buffers; set vsync before acquiring the
  swapchain; `Draw_Item.model` is a similarity: rotation, translation, uniform scale (no shear or non-uniform scale).
- No TODO or FIXME: write it or design it. Comments are full sentences giving reasons. README is updated with any flag,
  control or panel change. No handoff, status or notes files.
- Never edit `deps/`, `build/`, `.agents/` or `.codex/agents/`; never sleep, poll, `tail -f` or kill `sculpt.exe` by name; one
  `build.bat` per shell call, never piped into `head`, `tail` or `findstr`.

## 6. Done means
- `python scripts/gate.py` runs every check below in order, one line a step, each log in `build/gate/` (`--fast`, `--changed`, `--only`, `--skip`).
  Each PR of a series passes `gate.py --changed`; the last one passes the full gate.
- `build.bat check` and `build.bat test` are green; `build.bat smoke` too for render, app or sculpt changes;
  `scripts/touch_check.py` too for input, camera or panel changes, reported as a desktop simulation (sm-touch-testing).
- You ran it and looked: a described PNG for anything visual, the exit stats or bench rows (release, A/B ranges) for
  anything about speed, `mesh_check` numbers for anything about meshes.
- The App Store and Google Play rules in `sm-store` still hold, or your report says which one the change breaks and why.
- README is updated; `scripts/agents_sync.py` was run if a skill or agent changed; your report says what you verified
  and what you did not.
