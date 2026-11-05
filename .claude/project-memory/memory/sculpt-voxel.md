---
name: sculpt-voxel
description: Voxel sculpting workstream (3D-Coat-style) — design decisions, PR #127 core and #132 app integration, VM numbers, report URL; roadmap stages are in sculpt-voxel-roadmap
metadata:
  type: project
  modified: 2026-10-27T09:15:35.181Z
---

# Voxel sculpting (thread "Add high-performance voxel sculpting", 2026-10-27)

- Bolt asked for 3D-Coat-style voxel sculpting as a first-class object kind; research by a Fable agent (79 sources) in
  /mnt/project-files/notes/voxel/voxel-research.md; design voxel-sculpt-design.md; sm-architect review (13 MUSTs, mostly
  app crash sites) voxel-design-review.md; bench log bench-voxel-vm.md. Report: https://claude.ai/artifact/3Ak33tfrBu1VrzSZUvFj2e
- Decisions: sparse narrow-band SDF, 8³ i16 bricks (SCALE 4096/voxel, BAND 3, CLAMP ±4), tiles Empty/Inside, 4096³ domain
  of 128³ chunks; brushes Add/Subtract (smin with a stamp sphere), Smooth, Flatten, Inflate; surface nets per 16³ node
  (20³ window) into per-node slots of one geom.Mesh reusing render.Mesh_Buffers (10% slot reserve, compaction at stroke
  end); COW per-brick undo (self-inverse swap); band repair at stroke end by Godunov sweeps (GS in brick, Jacobi across,
  settled bricks skipped); "SVOX" file section. Dual contouring, dense grids, VDB-style trees rejected (design §5).
- PR #127 merged (src/voxel + bench --voxel + tests). PR #132 merged (app): `Object.voxel: ^Voxel_Part{clay, gpu,
  resolution}`; a voxel object keeps ONE EMPTY sculpt level so `object_sculptor` readers see nothing instead of nil; only
  level-changing paths branch on `obj.voxel`. Add as voxels (Scene palette `new_voxels`, Objects card "Voxel sphere",
  `--voxels=N` 32..1024), Draw/Clay/Layer→Add (Ctrl subtracts), Smooth, Flatten, Inflate (others refused with a toast),
  symmetry, History entry per stroke, `MESH_ONLY_COMMANDS` refused with a warning, SCENE_VERSION 13, Convert to mesh
  (swap entry), exit stats `voxel_*`.
- VM numbers (4 threads, 2026-10-27): 256³ 347k verts: dab 0.35 ms, flush 1.15 ms, stroke end 42 ms; 512³ 1.39M:
  0.97 / 4.1 / 190; 1024³ 5.57M: 4.45 / 15 / 1190; first mesh 76 / 344 / 1108 ms; to mesh 252 / 1172 / 1714 ms.
- 2026-10-27 Bolt: "Let's do the full roadmap" → [[sculpt-voxel-roadmap]] (stages 3-8, one PR a stage, self-merged).

**Why:** Bolt wants performance-first voxel sculpting that coexists with the mesh workflow; the research chose this over
dense/octree designs on brush latency and memory.
**How to apply:** keep voxel work in `src/voxel` (imports geom + jobs only); any app change goes through the MUST lists in
voxel-design-review.md and voxel-roadmap-review.md; measure with `build/bench --voxel` and quote hardware. Related:
[[sculpt-decisions]], [[sculpt-voxel-roadmap]].
