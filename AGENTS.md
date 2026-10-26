# Sculpt — instructions for coding agents

A performance-focused sculpting prototype in Odin (SDL3 + SDL_GPU for rendering, its own kit `src/ui` for the interface), with
ZBrush as the behaviour model. README.md is the only document and describes what exists now; this file is the map and
the skills hold the detail. It builds and runs on Windows (`build.bat`) and Linux (`build.sh`).

## 1. Before you plan: load skills
Skills live in `.claude/skills/<name>/SKILL.md` (mirrored to `.agents/skills/` by `scripts/agents_sync.py`). Load every
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
    python scripts\gate.py                          # section 6 in one command: check, test, build, smoke, touch (+ wincheck, androidcheck on Linux)
    build.bat check                                   # the gate: odin check of every package + the skill mirror check
    build.bat                                         # debug app -> build\sculpt.exe (tracking allocator: a leak exits 1)
    build.bat test                                    # odin test on geom, camera, sculpt, jobs, gizmo, png_write, ui, app
    build.bat smoke                                   # 300 frames under GPU validation, SDL_ASSERT=abort
    python scripts\touch_check.py ['long_press*']    # scripted finger, pen and mouse scenarios (a desktop simulation), in parallel on Linux
    build.bat run -- --vertices=1000000 --frames=120  # at most five arguments here; otherwise run build\sculpt.exe
    build\sculpt.exe --vertices=500000 --frames=60 --dump-viewport=build\v.ppm --check-mesh
    python scripts\ppm.py to-png build\v.ppm build\v.png     # then open the PNG and describe it; diff/crop/pixel/uniform too
    build.bat release | bench [sizes] [--threads=N] | gpubench
    python scripts\agents_sync.py                     # after editing a skill or agent (check verifies the mirror)
    build.bat android | androidrun                    # the Android APK; androidrun installs and starts it on the tablet
    (Linux: ./build.sh <mode>, plus wincheck and androidcheck)
- Fix the first error first; diagnostics are `path(line:col) Error: message`. The app prints key=value stats on exit.

## 4. Map
| Path | What |
|---|---|
| `src/app` | entry point, frame loop, `Options` flags, scene of objects, the tools, the interface's panels (`new_ui.odin`, `kit_*.odin`), keys and pointer (`device.odin`), `Viewport_Input`, cross-object `History`, `--gpubench` |
| `src/render` | every GPU object the app creates: device, pipelines, viewport target, mesh buffers, indirect draws, partial redraw, the idle cache; `shaders/` GLSL with committed `.spv` |
| `src/geom` | CPU geometry: `Mesh`, icosphere and geodesic fixtures, BVHs, topology, culling math, simplification, the LOD walk, `mesh_check` |
| `src/camera`, `src/gizmo` | orbit camera math; move gizmo math (both pure, no rendering or UI) |
| `src/sculpt` | brushes over a `Mesh` split into nodes, dirty ranges, undo, subdivision levels, HD windows, simplified copies |
| `src/ui` | the interface kit: immediate-mode layout, widgets, hit testing, CPU tessellation, fonts (no SDL, no render) |
| `src/jobs` | the persistent worker pool (`parallel_for`, `parallel_ranges`) |
| `src/bench` | the headless CPU benchmark (markdown tables) |
| `src/sdf_trial` | the standalone SDF/voxel comparison spike (not in the build scripts) |
| `android/` | the Android app: Gradle project, manifest, `app/jni/CMakeLists.txt` (SDL3, stb and `src/app` built by Odin into `libmain.so`), `android_main.c` |
| `scripts/` | `setup_deps.*`, `versions.env` (the pins), `gate.py` (the done gate in one command), `agents_sync.py` (skill mirror and validation), `ppm.py` (view and diff viewport dumps), `touch_check.py` (touch, pen and camera scenarios) |
| `deps/`, `build/` | ignored: the pinned toolchain and third-party sources; build outputs and dumps |
| `.vscode/`, `.claude/`, `.agents/` | tasks and launch configurations; skills, agents and permissions; the generated skill mirror (never edited by hand) |

## 5. Hard rules
- Odin is pinned (`scripts/versions.env`, `deps/odin`): never write from memory of older Odin; grep the install.
- Package boundaries: `geom`, `camera`, `gizmo` and `jobs` know nothing of rendering or UI; `ui` knows nothing of SDL or `render`; only `render` and `app`
  import `vendor:sdl3`; `bench` never imports `render` or `app`; `sdf_trial` stands alone.
- Determinism: serial and parallel results are bit-identical and tests compare them; no map order decides output.
- Allocations inside jobs use `runtime.heap_allocator()` for both make and delete; only the frame loop and the setup
  paths call `free_all(context.temp_allocator)`; nothing temp is stored.
- Every vertex move goes through `apply_dab`, `sculptor_grab_move` or `sculptor_nodes_moved`, and every mask change
  through `mask_dab` or `sculptor_mask_command`; triangles change only under dynamic topology inside a stroke. Any other
  topology change (remesh, booleans, …) copies `object_remesh`: end the stroke, leave HD, release and rebuild the object,
  which drops its levels, mask and strokes, and record it as a swap undo entry (`history_snapshot` / `history_record_swap`: `sm-cad`).
- The interface never owns sculpt state; panels keep no references between frames; scene changes are `Scene_Command`s and
  file actions are requests (`file_take`), both applied at the start of the next frame.
- The `.sculpt` scene file is versioned (`SCENE_VERSION`, `src/app/files.odin`): a change to what it stores bumps the
  version and keeps reading every older one; a damaged file is refused, never asserted on.
- GPU: consume every `sdl.*GPU*` result; `WaitForGPUIdle` before freeing buffers; set vsync before acquiring the
  swapchain; `Draw_Item.model` is a similarity: rotation, translation, uniform scale (no shear or non-uniform scale).
- No TODO or FIXME: write it or design it. Comments are full sentences giving reasons. README is updated with any flag,
  control or panel change. No handoff, status or notes files.
- Never edit `deps/`, `build/` or `.agents/`; never sleep, poll, `tail -f` or kill `sculpt.exe` by name; one
  `build.bat` per shell call, never piped into `head`, `tail` or `findstr`.

## 6. Done means
- `python scripts/gate.py` runs every check below in order, one line a step, each log in `build/gate/` (`--fast`, `--only`, `--skip`).
- `build.bat check` and `build.bat test` are green; `build.bat smoke` too for render, app or sculpt changes;
  `scripts/touch_check.py` too for input, camera or panel changes, reported as a desktop simulation (sm-touch-testing).
- You ran it and looked: a described PNG for anything visual, the exit stats or bench rows (release, A/B ranges) for
  anything about speed, `mesh_check` numbers for anything about meshes.
- The App Store and Google Play rules in `sm-store` still hold, or your report says which one the change breaks and why.
- README is updated; `scripts/agents_sync.py` was run if a skill or agent changed; your report says what you verified
  and what you did not.
