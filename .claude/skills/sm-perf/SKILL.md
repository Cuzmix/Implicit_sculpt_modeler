---
name: sm-perf
description: Measuring the sculpt modeler's performance — the headless build/bench tables (strokes, culling, --lod, --levels, --hd), the in-app --gpubench, --bench-stroke with the key=value exit stats, the Stats panel rings (Frame, CPU, GPU, Display wait, Raycast, Brush, Normals, Upload, latency), release builds only, vsync and GPU-timing caveats, A/B runs back to back with ranges, --prefault on VMs, and where the usual costs hide (page faults, allocation per dab, serial fallbacks, uploads, full redraws). Load for ANY task that asks how fast something is or makes something faster or slower, e.g. "is this fast enough?", "benchmark 10M vertices", "did my change regress the brush?", "why is the frame 30 ms", "measure the LOD build", "optimize the normals". Requires sm-build; GPU time is sm-render's; a slowdown without an obvious cause goes to the sm-investigator subagent.
---

# Performance

## Rules
- Numbers come from release builds (`build.bat release`, `bench`, `gpubench`: `-o:speed -no-bounds-check`); a debug run
  carries a tracking allocator and only shows trends.
- Compare like with like: the same vertex count (geodesic sizes snap to 10f²+2), `--threads`, flags, window size and
  frame count. Run A and B back to back, alternating (A B A B), and report each side's min–max with the exact command;
  overlapping ranges are noise. A number you did not measure is UNVERIFIED.
- With VSync on, Frame ms is the display's refresh interval whenever the frame is ready in time (README "GPU benchmark
  and frame timing"): compare CPU and GPU, or run `--no-vsync`. `--time-gpu` waits for the GPU each frame, so frames no
  longer overlap: on only to read `gpu_ms`.
- On cloud VMs pass `--prefault=3000` to `bench`, so the first touch of fresh memory does not dominate setup; `peak RSS`
  is read from `/proc` and prints 0 on Windows (`src/bench/main.odin`).
- A render-only optimisation moves no pixel (`ppm.py diff` → 0) and changes no bench table.

## Commands
| Command | What you get |
|---|---|
| `build.bat bench` | 500k, 1M, 5M, 7M, 10M vertices and 10M with an idle second sphere (`src/bench/main.odin:103-105`): the stroke table (Setup s, Mesh MB, RSS MB, per brush size r=0.13 and r=0.04: Verts/dab, Raycast ms, Dab ms, Normals ms/frame, Frame ms, Frame ms max, Upload MB/frame, Stroke end ms, Undo MB/stroke, Undo ms, Redo ms; `:166`), then the culling table from three views (`:172`). 77 dabs, 4 per frame (`:46-47`) |
| `build.bat bench 1000000 --threads=1` | the serial baseline at one size; `--threads=N` otherwise; `--node=N` node size; `--meshes=N` idle meshes |
| `build.bat bench --lod` / `--levels` / `--hd` | the simplified-copy, subdivision-level and HD tables (README "Benchmark") |
| `build.bat bench --brushes` | per kind (all nine, plus Draw with X symmetry, Draw half masked and Draw with the Noise alpha): Verts/dab, Dab ms, Normals ms/frame, Frame ms, Frame ms max, Undo MB/stroke (`src/bench/brushes.odin:20`) |
| `build.bat bench --masks` | every mask command on a half-masked sphere, the neighbourhood ones at 1 and 10 steps: Changed vertices, Command ms, Flush ms, Undo MB, Undo ms (`src/bench/masks.odin:17`) |
| `build.bat bench --remesh` | the voxel remesh after a Grab: Remeshed vertices, Remesh ms, Sculpt-ready ms, edge-length spread before and after (`src/bench/remesh.odin:17`) |
| `build.bat bench --dyntopo` | dynamic topology: enable ms, plain and refining frame ms, splits, collapses, triangles after, upload MB/frame, undo and redo ms, disable ms (`src/bench/dyntopo.odin:21`; "refused" when the mesh cannot be made dynamic) |
| `build.bat gpubench` | six cases per size (orbit with everything on, without simplify, without culling; stroke with partial redraw and culling, without partial, without both), 30 warm-up + 120 measured frames, strokes counting only sculpting frames (`src/app/gpubench.odin:18-44`); writes `build\gpubench.md`. `--vertices=N` for one size, `--gpubench-frames=N` |
| `build\sculpt.exe --vertices=N --bench-stroke=240 --bench-samples=4 --no-vsync --frames=240` | a synthetic stroke, then the exit stats including `raycast_ms`, `brush_ms`, `normals_ms`, `upload_kb`, `latency_ms`, `undo_mb`, `undo_ms`, `redo_ms`, `level_changes_ms`; `--bench-loops=N` circles instead of a wave |
| `build/sculpt --vertices=10000000 --bench-stroke=240 --no-vsync [--autosave=1 --bench-after-autosave]` (release) | the stroke while an autosave writes the file, A/B against none: `brush_ms`, `frame_ms`, and `autosave_serialize_ms`, `autosave_write_ms`, `autosave_mb`; a stroke during the read gives `autosave_aborts` and `autosave_wait_ms` (README "Autosave and recovery") |
| `--orbit`, `--no-cull`, `--no-partial`, `--no-cache`, `--no-simplify`; `--brush=NAME`, `--symmetry=x…`, `--dyntopo --detail=PX` for `--bench-stroke` | the camera-only cost and the A/B toggles (also Stats panel checkboxes) |
| `deps\odin\odin.exe build src\sdf_trial … && build\sdf_trial.exe 256` | the SDF spike's `dab_ms`/`remesh_ms` keys (sm-sdf) |

## Reading the numbers
- Stats panel definitions are in README "GPU benchmark and frame timing"; rings keep the last 240 samples and print p50
  and p99 (`src/app/stats.odin:7-30`); the sculpt rows exist only on frames that sculpted; `latency_ms` is the newest
  input event to the submit; `upload_kb` is the dirty vertices times 16 bytes; `lod_build_ms` only on frames that built
  copies; `cull_ms` is CPU culling plus writing the draw commands.
- In `bench`, "Stroke end ms" is the frame the deferred normal cones start on, at most `CONE_BATCH` nodes a frame.

## Where the cost hides
| Symptom | Look at |
|---|---|
| the first run of something is slow, later ones fast | first-touch page faults: scratch kept between calls (`Levels.residual`, `src/sculpt/levels.odin:52-54`), `--prefault` |
| dab ms grows with mesh size at a fixed brush | candidate vertices per node (`NODE_TRIANGLES`, `--node`); the serial fallback below `PARALLEL_MIN_VERTS` |
| normals ms high | nodes marked Shape instead of Edge; the flush recomputes whole nodes |
| frame max spikes when a stroke ends | the waiting cones, `CONE_BATCH` per flush |
| upload MB high | ranges not coalesced (`sculptor_flush` merges adjacent nodes); a whole-mesh `mesh_buffers_create` on a per-frame path |
| GPU ms high while nothing moves | partial redraw off, a damage rect over `PARTIAL_MAX_AREA`, or the cache redrawn every frame (`cache_redraws` climbing) |
| GPU ms high while orbiting | copies not built yet (`lod_pending`), or `--no-simplify` |
| allocations per dab | `parallel_for` allocates nothing by design (`src/jobs/jobs.odin:1-5`); look for `make` in a `job_*` |
| one frame a few ms long when work resumes after a pause | an autosave being stopped (`autosave_wait_ms`; `autosave_settle`/`autosave_guard`): its pieces check the abort flag between 1 MB writes and per node; a new long serial loop in `levels_write` needs an abort check too |
| workers slow to join | `SPIN_TIME` (`jobs.odin:16-17`): a sleeping worker costs tens of microseconds to wake |

## Benchmarks as tests
None exist. If you add one: warm up once, make the timed run take at least 50 ms, assert the result in the same test (fast
and wrong fails), and print a `timing: <name> <value> ms` line so it can be grepped.
