---
name: sm-build
description: Build, run, test and verify the sculpt modeler through build.bat (Windows) and build.sh (Linux) — the modes check|debug|release|test|run|smoke|bench|gpubench|wincheck|androidcheck|android|androidrun, the strict compile flags, leak-tracked tests and the debug app's tracking allocator, the smoke run under GPU validation, reading Odin diagnostics, the key=value stats the app prints on exit, viewport dumps to PPM and scripts/ppm.py to look at them, and the evidence ladder that decides when work is done. Load for ANY task that compiles, runs, tests or claims something works, e.g. "build this", "run it with 1M vertices", "the build fails", "add a test", "show me the viewport", "is it done?". Requires sm-odin when code is written.
---

# Build, run, verify

## One entry point
| Command (Windows; Linux is `./build.sh <mode>`) | What it does |
|---|---|
| `build.bat check` | `odin check` of all thirteen packages with the strict flags (`-no-entry-point`: the libraries have no `main`), then `python scripts/agents_sync.py --check`. No link, no shaders, no `build\`. The gate: run it first and last |
| `build.bat` | the debug app, `-debug`, into `build\sculpt.exe`; `ODIN_DEBUG` wraps the allocator in `mem.Tracking_Allocator` and the process exits 1 on any leak or bad free; copies `SDL3.dll` from `deps\odin\vendor\sdl3` next to it |
| `build.bat release` | `-o:speed -no-bounds-check`: the only build whose timings count (sm-perf) |
| `build.bat test` | `odin test` on geom, camera, sculpt, jobs, gizmo, png_write, zip, ui and app in that order, stopping at the first failing package; render has no tests, and app's need no window (they test pure logic such as the command registry); the runner tracks memory, so a leak fails a test |
| `build.bat run -- <args>` | debug build, then run. **build.bat forwards at most five arguments** (`%2 %3 %4 %5 %6`); for more, run `build\sculpt.exe` yourself after `build.bat` |
| `build.bat smoke` | debug build, then `SDL_ASSERT=abort build\sculpt.exe --frames=300 --gpu-debug`: validation on, an SDL assert aborts, a leak exits 1. Needs a display |
| `build\sculpt.exe --frames=60 --run=setup.cmd` (or `--script="set rebuild_even 500000; rebuild; brush clay"` on Linux) | set a run up by command script (README "Command scripts"): checked whole first, exit 2 on an error or a statement that does nothing; `--frames` and `--ui-events` count from its end, and nothing it did is in the History |
| `python scripts\test_only.py <package> [names or patterns] [--list]` | while working: only the named tests of one package (`deform_*`, `sections_*`), with the strict flags, the package's own name (app's is `main`) and SDL3's linker flags put together for `-define:ODIN_TEST_NAMES`; a pattern that picks nothing fails, no names runs the package. Seconds, not the minute of `build.bat test`, which still decides done |
| `python scripts\gate.py [--fast] [--only a,b] [--skip a,b] [--keep-going] [-- touch args]` | the whole done gate (AGENTS.md section 6) in order: check, test, debug build, smoke, touch_check, and on Linux wincheck and androidcheck. One line a step (seconds, test counts, scenarios, leaks), each step's full output in `build\gate\<step>.log`, the log's end on a failure. On Linux without a display it runs smoke and touch under `xvfb-run`. Use it instead of chaining the steps by hand |
| `python scripts\touch_check.py [names or patterns] [--list] [--screens] [--jobs=N]` | after `build.bat`: drives the debug app with scripted fingers, pen and mouse (`--ui-events`) through the touch, camera and Settings scenarios and checks the exit stats; `--screens` writes `build\touch\<name>.png`; a name may be a pattern (`'long_press*'`). On Linux with Xvfb the scenarios run side by side, one private display each (a window losing focus forgets its fingers, so they never share one); elsewhere one at a time. A desktop simulation, not a tablet (sm-touch-testing). Needs a display |
| `build.bat bench [sizes] [--threads=N] [--lod\|--levels\|--hd] [--meshes=N] [--node=N] [--prefault=MB]` | release headless CPU benchmark printing markdown tables (sm-perf) |
| `build.bat gpubench [--vertices=N] [--gpubench-frames=N]` | release app timing the GPU and CPU per case; writes `build\gpubench.md` (sm-perf) |
| `./build.sh wincheck` | Linux only: compiles app and bench for `windows_amd64` to objects, catching Windows-only errors without a Windows SDK |
| `./build.sh androidcheck` | Linux only: compiles the app for Android arm64 to one object, as the Android build does, without the NDK; run it after any app, render or ui change, since `when ODIN_PLATFORM_SUBTARGET == .Android` code only compiles there |
| `build.bat android` / `androidrun` | the Android debug APK through `android/gradlew` (needs Android Studio's SDK and NDK, and `scripts\setup_android.bat` once); `androidrun` installs it on the tablet adb sees and starts it. Its log is `adb logcat -s SDL/APP` |
| `deps\odin\odin.exe check src\<pkg> -no-entry-point -collection:deps=deps -vet -strict-style -warnings-as-errors` | one package, no binary: what `check` runs nine times |
| `deps\odin\odin.exe build src\sdf_trial -o:speed -collection:deps=deps -out:build\sdf_trial.exe` | the SDF spike (sm-sdf); not in the scripts |

- Shaders: `build.bat` recompiles `src/render/shaders/*.vert|*.frag` to `.spv` only when `glslangValidator` is on PATH
  (it is not on this machine), otherwise the committed `.spv` are used; `build.sh` calls it unconditionally under
  `set -e`, so Linux needs `glslang-tools` (the package list at the top of `scripts/setup_deps.sh`).
- VS Code: `.vscode/tasks.json` (check, builds, tests, an Odin problem matcher) and `launch.json` (cppvsdbg on the PDBs;
  the "GPU validation" configuration sets `SDL_ASSERT=break`).

## Reading output
- Odin diagnostics are `path(line:col) Error: message`. Fix the first error first. A "declared but not used" that
  appears only in release means a `when ODIN_DEBUG`-only use (sm-odin: `@(require) import`).
- The app logs `GPU: <name> (<backend>, driver <version>)`, `sculpt threads: N`, `mesh: V vertices, T triangles; ready to
  sculpt in … ms, uploaded in … ms`, and at exit `allocation tracking: no leaks` or `leak: N bytes at file:line` /
  `bad free at …`.
- Exit stats (key=value, printed when `--frames` runs out or the window closes): `frames= dabs= objects= vertices=`; with
  `--check-mesh` one `mesh_closed=true mesh_boundary_edges=0 … mesh_volume=…` line per object (a dynamic object's
  compacted mesh); per dynamic object `dyntopo object= triangles= splits= collapses= pages= gpu_regrows=`; `idle_cache= cache_redraws=
  last_frame_triangles=`; `cull= last_frame_draws= chunks= culled_view= culled_back= cull_ms=`; `partial= partial_frames=
  last_frame_partial= last_frame_redrawn_px= viewport_px=`; `simplify= last_frame_lod_px= last_frame_simplified=
  lod_pending=`; then `<name>_p50= <name>_p99=` for `lod_build_ms`, `frame_ms`, `cpu_ms`, `wait_ms`, `gpu_ms` (with
  `--time-gpu`), `ui_ms`, `cursor_ms` (once the brush ring lay on the surface), and after dabs `raycast_ms`,
  `brush_ms`, `normals_ms`, `upload_kb`, `latency_ms`; with `--bench-stroke` `undo_mb= undo_ms= redo_ms=` and
  `level_changes_ms=`; always `camera_yaw= camera_pitch= camera_roll= camera_distance= camera_target=x,y,z`,
  `orbit_pivot=x,y,z pivot_source=centre|stroke|pointer|object` (the last orbit's), `undo_steps= redo_steps=
  brush_radius_px= brush_strength= selected=`, `inspector_scroll= settings_scroll= settings_open=`, `cursor_hit=
  cursor_normal=x,y,z` and `window_inspector= window_stats= window_history= window_settings=` (each
  `open,folded,left,top`): what scripted input did. These are the numbers to quote; `--frames=N` ends a run by itself.

## Seeing the viewport
    build\sculpt.exe --vertices=500000 --frames=60 --dump-viewport=build\view.ppm
    python scripts\ppm.py uniform build\view.ppm                  # exit 1 = a blank frame: a failure, not a pass
    python scripts\ppm.py to-png build\view.ppm build\view.png    # open the PNG with Read and describe it
- The dump is the 3D viewport only (the interface draws into the swapchain; `--dump-screen` writes the whole window), as the last frame left it: the selected object is
  clay, idle ones grey, the background dark blue-grey. Say what is where, how it is lit, whether the stroke shows.
- A/B: `python scripts\ppm.py diff a.ppm b.ppm [--threshold N] [--out d.png]` prints the changed-pixel count, a
  `bbox=x,y,w,h` to paste into `ppm.py crop … --rect`, and paints the changed pixels red. Two runs with the same flags
  give 0 differing pixels: the render is deterministic, so a render-only change that moves a pixel changed behaviour
  (sm-render). `ppm.py pixel f.ppm x,y` prints exact values.

## Exit codes
0 ok · 1 a failed step (`|| exit /b 1`), a GPU failure (`run` returned false), a leak or bad free, a failing test ·
under `SDL_ASSERT=abort` an assert kills the process · compile errors print before the status.

## Evidence ladder — match the depth to the change
0. `build.bat check` (always). 1. Build the touched target: debug, and release too when speed is claimed. 2. Run it.
Anything visual: `--dump-viewport`, PNG, open it and describe it (black, uniform or unchanged = not done). Anything
behavioural: the exit stats or the `--check-mesh` lines. 3. `build.bat test`, with a new test in the package's
`*_test.odin`. 4. `build.bat smoke` for render, app or sculpt changes; `python scripts\touch_check.py` for anything about input, the
camera, gestures or panels that scroll. 5. sm-perf numbers for anything about speed.
6. Report what you verified and what you did not.

## Anti-patterns
- Claiming success from `check` alone, or from a stale `build\sculpt.exe` (every mode rebuilds; use the script).
- Piping `build.bat` into `head`, `tail` or `findstr`: the exit status is lost. Let it print and read the first error.
- Running the app without `--frames=N` from a script: it runs until the window is closed.
- Shell redirection into `build\` (`> build\x.log`) is denied by `.claude/settings.json`; programs may write there
  themselves (`--dump-viewport=build\x.ppm`, `ppm.py … build\x.png`), logs go to the scratchpad.
- Comparing a debug run's timings (tracking allocator) with a release run's; sleeping, polling or killing `sculpt.exe`
  by name; editing `deps\` or `build\` by hand.
- Adding a mode to `build.bat` as an `if "%MODE%"=="x" ( … )` block: an `exit /b 1` inside a parenthesised block returns
  0 to `cmd /c build.bat`, so the failure is lost. Modes are labels (`goto x`), and loops inside blocks `goto fail`.
- Writing a new file without first looking for one of that name: `src/app` is one package of many files, and a whole-
  file write over an existing one (`adjust.odin` is the S/U brush adjust) shows up only as a flood of unrelated
  "undeclared name" errors. `ls src/app/<name>.odin` first.
