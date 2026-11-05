---
name: remesh-dynamesh-plan
description: Remesh to DynaMesh level (2026-11-03 thread): side-by-side numbers vs Blender 5.2, the 6-PR plan, and how to re-measure
metadata:
  type: project
  modified: 2026-11-03T10:46:22.153Z
---

Bolt 2026-11-03: bring voxel Remesh to DynaMesh level (best of DynaMesh + Blender). Plan doc: https://claude.ai/artifact/GMgjv5FvEkPiHiz4SexY27

Measured (4-core VM, same meshes, same voxel h; Blender via `pip install bpy` 5.2.3 in a venv, `object.voxel_remesh`):
- Speed: ours 1M 0.25-0.29 s vs Blender 4.2 s; 10M 3.0 s vs 57.8 s; ours 20M 6.5 s / 3.3 GB. In-app 10M = 4.1 s + 2.3 s ready (SwiftShader steals CPU).
- Profile 10M: lattice_rays_cast 27%, page first-touch 11%, relax+relax_quads 12%.
- Repeat 8x at own count: ours count +2%, error 7x even with Keep detail; Blender identical each pass; fixed anchored lattice stays flat.
- Max vertex error bumpy sphere: ours 0.52 h (mid-edge fallback in crossing_on), Blender 0.004 h; Keep detail 0.004 h but 3.4x slower.
- Turned cube edge chamfer: ours 0.40-0.44 h, Blender 0.26-0.28 h.
- Turned slab 0.1 h / 0.2 h thick: ours keeps 0.3% / 2% volume, Blender 51% / 86% closed.
- Mask dropped by ours, kept by Blender.

PRs: 1 steady lattice + cell size (mm via print_mm, object remembers cell), 2 exact crossings + cheaper Keep detail, 3 keep thin parts, 4 keep mask/paint/groups always, 5 keep sharp edges (QEF snap + flips), 6 speed at 10M+ and corpus fixtures.

Built: PR1 #548 anchored lattice + Cell size (also fixed the 0.5 h outliers, so PR2 folded into PR6). PR3 #552 merged, Keep thin parts (remesh_keep_thin, default on): keep_thin_parts scans all 3 axes' hits for in-out spans between two outside points; graze test = a point within 2 across is inside with both ray-neighbours inside AND the opposite side is open (no inside, no candidate); bridge_kept makes 18-diagonals face-joined (else 90 shells); drop_specks (<8, not touching inside); project_thin puts only vertices near kept points back on the source (THIN_HUG 0.1 so they start within a cell). Slab 0.1-0.6 h: 99 % volume, chi 2; spheres/turned cube unchanged. PR4 #554 merged, Keep paint and mask (remesh_keep_paint, on): Remesh_Options.sources -> bvh_closest per vertex within 2h; costs 1M 0.28->0.85 s, 10M 2.8->11.3 s (closest_descend), PR6 should store the hit's triangle during lattice_rays_cast instead.
PR5 sharp edges PARKED 2026-11-03 (not merged): post-hoc QEF snap from source faces (patch /mnt/project-files/notes/remesh/sharp-snap-wip.patch) cut mean error 4x but left slivers and 0.3 h max; dual contouring with hit triangles stored in Lattice_Rays.tris (sharp-dual-contouring-wip.patch, fast: +4 ms at 20k) misses crease cells whose crossings sit on one face (max 0.4 h). Next try: per-cell QEF from source faces in the cell (BVH box) + EMC-style feature vertex; Lattice_Rays.tris also could make Keep paint lookups cheap.

PR6 #558 merged 2026-11-03: slab capacity from crossings (10M 3.05->2.7 s), lattice_rays_cast now [3] axes in one visit (memory-bound on per-ray atomics; plain increments <5 %), points_morton_order for bvh_closest/project_along_normals (2x lookups), LOOKUP_LEAF 16 (morton build serial topology dominates). Keep paint 10M 10.8->6.9 s, Keep detail 10.2->9.3 s; bench --remesh has Keep paint/detail columns to 25M (25M remesh 10 s, 8.2 GB peak). Plan done except PR5 (parked) and remesh_check fixtures (repeat, thin slab, turned cube) not added. Left ideas: relax_quads 14 %, cast memory bound.

Harness: scratch Odin program importing src:geom (`-collection:src=src`), easy to rebuild; Blender scripts load raw .pos/.idx f32/u32 dumps via numpy foreach_set.

**Why:** next thread must not redo the comparison.
**How to apply:** build in order; related [[sculpt-remesh]], [[remesh-quad-build]], [[zremesher-plan]].
