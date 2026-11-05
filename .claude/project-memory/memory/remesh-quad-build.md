---
name: remesh-quad-build
description: Build log of the Remesh / Quad Remesh roadmap (PRs #358-#372 + PR 6, 2026-10-30) with what each PR changed, container notes, and what still awaits a Windows/tablet try
metadata:
  type: project
---

Research and decisions: [[remesh-quad-research]] (report https://claude.ai/artifact/Y7oLGn8QV2MmegNP2uYWgV). Full per-PR notes and container gotchas: [[remesh-quad-build-details]].

Bolt approved the roadmap 2026-10-30 07:09; all six PRs merged into odin-sculpt the same day, final report https://claude.ai/artifact/R3YjboKEz3y69WcTbqxSFo (gate 9/9 green at 10:59, touch scenarios skipped: no X11 here).
- #358 PR 1 (07:31): polygon edges in the wireframe (`levels_polygon_edges`, exit stat `poly_edges=`), shelf Retopologize tile runs on a tap.
- #360 PR 2 (07:55): `scripts/build_autoremesher.py` (AUTOREMESHER_COMMIT in versions.env), `src/quadmesh` binding (AVAILABLE = desktops; never compare its output across platforms: unordered_map order).
- #362 PR 3 (08:35): Retopologize is **Quad Remesh**; `Quad_Engine {Auto, Own}` (`retopo_engine`); input capped at 1M tris; `mesh_integrity` refusals fall back to the own engine with the reason; polygons kept via `levels_set_polys(.Smooth)`.
- #366 PR 4 (08:54): Adaptivity, Mirror X/Y/Z (half remeshed with a planar cap, seam quads match), Close first (voxel remesh before the engine); settings retopo_adaptivity/retopo_symmetry/retopo_close_first.
- #369 PR 5a (09:25): Remesh caps holes first (`mesh_edges_paired` hash + `mesh_close_holes`), turns inside-out meshes outward, Smooth 0-8, Keep detail (projection + polypaint/polygroups), Groups (per-polygroup pieces on one lattice); result line notes.
- #372 PR 5b (10:02): Remesh **Quads** (`remesh_quads`): the marching cubes' dual kept as Polys + quad faces; fixed a pre-existing crevice bug (face rule turns via `cell_flips`); ~1.0x the triangle path's time; ~49% four-valent, pole reduction out of scope.
- #376 PR 6 (10:50): `scripts/remesh_check.py [--stability --real FILE]` corpus (12 fixtures x 3 tools; report build/remesh_check/report.md); `bench --quadremesh`; exit stat `peak_rss_mb`; Remesh runs `mesh_fix` before capping (doubled/flipped triangles broke it). Honest FAILs kept: AutoRemesher on the thin rod (fallback) and bumpy sphere -25.4% faces. Engine gives ~half the quads asked at 20k.

- #385 follow-up (13:25): four touch scenarios the series broke (Rebuild's button moved under longer paragraphs and the Quads goal's new controls; Adjust op renamed `quad_remesh`; AutoRemesher's inexact count). Fix: Quads' engine/Adaptivity/Mirror/Close first under Rebuild's More options fold, paragraphs two lines, scenarios tap per goal and pin `set retopo_engine own` for exact counts. Touch scenarios run here one at a time: [[touch-check-offscreen]].

**Why:** the next thread must not redo the roadmap's PRs or re-find the faults the corpus caught.
**How to apply:** everything since #358 awaits Bolt's Windows/tablet try (AutoRemesher needs `scripts\setup_deps.bat` rerun on Windows); run `python scripts/remesh_check.py --stability` after any remesh or quadmesh change. Thread left open for Bolt's try.
