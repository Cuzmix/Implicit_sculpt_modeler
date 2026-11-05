---
name: keep-symmetry
description: Keep symmetry switch (2026-10-31) for Quad Remesh, Decimate and Remesh, following the brush's symmetry; how it works and what was left
metadata:
  type: project
  modified: 2026-10-31T16:09:52.895Z
---

Bolt 2026-10-31: "quad remesh doesn't keep symmetry; add an option, on by default when symmetry is active; double check remesh and decimate".
Merged as #441 into odin-sculpt 2026-10-31; awaits Bolt's device try:
- One "Keep symmetry X" switch under More options of Rebuild's Even, Fewer and Quads (settings `remesh_keep_symmetry`, `decimate_keep_symmetry`, `retopo_keep_symmetry`, all default on; greyed with no symmetry on). Planes = `symmetry_planes(app, obj)` (brush symmetry + `symmetry_center`, Local aware).
- Quad Remesh's old Mirror X/Y/Z tabs (`retopo_symmetry`, AutoRemesher only, origin only) were removed; `retopo.Options.mirror` replaces them; both engines mirror now (iPad/Android only have the built-in engine).
- Decimate was not symmetric before; now cuts the + part, decimates with `Simplify_Guide.seam`, mirrors. Other side takes this side's paint/groups.
- Remesh already followed symmetry (lattice even about planes); only the switch was added.
- Geometry: `src/geom/mirror_half.odin` (mirror_cut, mirror_seam, mirror_polygons, mesh_mirror); `mesh_slice` got `front_from`.
- Known: AutoRemesher with symmetry can leave a few pentagons at some counts (creature at 2500 quads: 8), so no UVs then; built-in engine legs messy with or without symmetry (pre-existing).
Pictures: /mnt/project-files/notes/keep-symmetry/.

**Why:** next thread should not rebuild this or re-add per-axis Mirror tabs.
**How to apply:** symmetry for any new rebuild tool goes through `symmetry_planes` + mirror_half.odin. Related: [[remesh-quad-build]], [[decimate-options]].
