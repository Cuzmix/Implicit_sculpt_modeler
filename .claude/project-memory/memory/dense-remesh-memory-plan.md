---
name: dense-remesh-memory-plan
description: 2026-11-04 plan to stop the iPad crash when remeshing a 25M object again (undo memory + op peak): findings, 6 PRs, PR1-4 merged (#617 #619 #620 #621 #664), PR6 Build levels merged #670
metadata:
  type: project
  modified: 2026-11-04T10:29:04.204Z
---

Bolt 2026-11-04: on iPad Air M2, remesh to ~25M then remesh again runs out of memory and crashes; asked to plan (no code yet): clear history / popup / Settings limit for remesh and subdivision, see how Nomad does it. Plan: https://claude.ai/artifact/9mmo3S83hHYZ8HBsaE1dMs

Findings (code, 2026-11-04):
- Swap undo entry = full serialized object copy (~37 B/base vertex; ~0.9-1.2 GB at 25M). SWAP_LIMIT_BYTES fixed 1.5 GB + sculpt UNDO_LIMIT_BYTES 512 MB per sculptor, not device-aware ("Automatic").
- Second remesh peak (est. from VM bench): live 25M 3.6 GB (CPU 2.6 + GPU 0.96, unified on iPad) + undo 1.5 + long_job_copy 0.9 + remesh work/new object ~5 GB => ~11 GB vs iPad app limit ~5-6 GB. Clearing history alone frees ~1-1.5 GB: not enough for 25M->25M. history_swap (undo of a rebuild) also holds both objects + two copies.
- LOW_MEMORY event is queued but unhandled (idle.odin). MAX_SUBDIVIDE_BYTES fixed 12 GB. platform_ram/process_memory exist; no os_proc_available_memory yet. iOS build signs with the profile's entitlements; increased-memory-limit unknown.
- Nomad: History limit (Mb), Maximum undoable, Memory stats; no pre-step warning found; voxel res cap 1200. ZBrush: Reserved Undo Memory, spills undo to disk.

Bolt 2026-11-04: popup must always offer "Continue anyway" (autosave first; keeps history if it would fit after freeing, else frees history and tries); also a Settings choice. Mock v2 updated.

Plan PRs: 1 measure headroom per platform + phase footprint logs + LOW_MEMORY drops old rebuild copies (Bolt sends sculpt-log from a 25M pair); 2 preflight estimate + popup (Free history and remesh / Remesh to N instead / Cancel, "don't ask again") + device-based Automatic history budget; 3 Settings > Performance > Mesh size (Largest remesh, Largest subdivision, Automatic per device: iPad ~12M, PC ~50M at 32 GB); 4 big rebuild copies on disk (LZ4, thread); 5 lower the peak (no job input copy, free old GPU first, undo without 2nd RAM copy).

**Why:** next thread builds from this without redoing the analysis.
**How to apply:** Bolt said proceed 2026-11-04; PR1 check+popup merged #617 (memory_check.odin, --memory-free=MB); PR2 Mesh size limits + device History budgets + LOW_MEMORY merged #619 (mesh_limits.odin); awaits Bolt iPad 25Mx2 log; PR3a remesh reads level in place #620 merged (-40 B/vertex); PR3b two-phase remesh + held view (Bolt chose Hold the picture) merged #621 (6M peak 2959->2128 MB); PR4 undo copies on disk merged #664 (undo_disk.odin, undo/<pid>/N.swap, 3M second-remesh peak 1497->1393 MB); 2026-11-05 Bolt said commit+push first, test after, do everything else; PR5 (packed normals/derived tri_leaf) skipped by Bolt 2026-11-05 (would slow strokes); PR6 Build levels in Remesh (Remesh_Setup.levels 0-3, remesh_levels setting, remesh_build_levels fits the top with project_along_normals; never held) merged #670 (1M->4M: flat 1.8 s 1140 MB, 2 levels 4.1 s 1750 MB; fit 2.7 s is the slow part); none of it may touch the stroke path (time stroke start/end/undo each PR). Related: [[perf-25m-study]], [[remesh-dynamesh-plan]], [[crash-log]].

Bolt 2026-11-04 picked option A (preflight check + popup with Continue anyway). Then asked: what makes 15M comfortable, and Nomad's Build multiresolution. Measured (scratch probe over src/geom+src/sculpt, VM, bumpy 15M sphere, CPU RSS): live sculpt-ready 1.28 GB counted / 1.8 GB resident (faces CSR 401 MB, indices 343, positions 172, normals 172, tri_leaf 114); remesh 15M->15M +0.7 GB copy +1.74 GB peak 6-8 s; ready +1.1 GB 1.9 s while old object alive. Multires (remesh 1/16, subdivide x2, project_along_normals): 15 s, peak +3.3 GB, lands on surface, lower levels +0.5 GB: a feature, not a memory saver; projection 9 s is the slow part. 15M fixes: release old object before ready (-1.8 CPU -0.6 GPU), no job copy (-0.7), packed normals/derived tri_leaf/return resident slack (-0.7), undo on disk (-0.55). Toolchain in this container: git clone Odin dev-2026-10 + apt llvm-18-dev, ./build_odin.sh release (GitHub release downloads are 403 here).

Research 2026-11-04 (compare/contrast in the plan doc): every app caps undo by MB/steps, none checks a heavy step before running it; only ZBrush spills undo to scratch disk (with Compacting-memory pauses). Nomad dev: "If you hit the memory limit it's over, the app quits"; Free readout = iOS's number; forum advice 10-12M total on a 16 GB iPad, 22M+ saves crashed (2022); 12.5M max on a 4 GB iPad. Blender: Undo Steps 32/256, Undo Memory Limit 0=none; voxel remesh memory bug left as is. Final PR order (v4 of doc): 1 check+popup, 2 Settings mesh size + automatic budgets + LOW_MEMORY (Bolt iPad run), 3 two-phase job no copy + free old CPU object before ready, 4 undo on disk, 5 slimmer object, 6 Build levels.
