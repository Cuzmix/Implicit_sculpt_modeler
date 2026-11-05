---
name: sculpt-voxel-roadmap
description: Voxel roadmap stages 3-8 all merged 2026-10-27 (#157-#181) — what each PR did, numbers; stage 9 is Bolt's Windows/tablet run (notes/voxel/stage9-windows-run.md)
metadata:
  type: project
  modified: 2026-10-27T10:12:36.036Z
---

# Voxel roadmap (thread "Add high-performance voxel sculpting", from 2026-10-27T07:02Z)

- Design: /mnt/project-files/notes/voxel/voxel-roadmap-design.md; sm-architect review with 10 MUSTs in
  voxel-roadmap-review.md (saddle worklist + resolve after clay_read, group_materials cleared on convert, Res+ domain
  check, owner-local cell codes, Intersect over the whole base, Voxel_Part.edits stamp for live booleans, .Boolean out
  of MESH_ONLY_COMMANDS, cones from face normals, clay mask readers). Follow it. One PR a stage into odin-sculpt.
- Stage 3 PR #157: geom/lattice_rays.odin public, voxel.clay_from_mesh, Convert to voxels (Mesh_To_Voxels swap entry,
  `voxel_across` slider). Stage 4 PR #159: clay_resample (×2 no repair, ÷2 band_repair + grow_band rounds), Res+/Res−.
- Stage 5 PR #162: saddle.odin (resolve_saddles at stroke end) + one vertex per loop of crossings → surface closed and
  manifold (`--check-mesh` 0 non-manifold edges).
- Stage 6 PR #165 (merged 2026-10-27T10:10Z): band repair in wavefronts (Gauss-Seidel across bricks, stops when no
  value moves > 1/256 voxel, 8 sweeps; the old Jacobi order never settled), weld by per-vertex codes (owner-local
  cell + loop + offset axes; `clay_to_mesh_by_position` kept as test oracle), ZERO_OUTSIDE nudge. 1024 across: To mesh
  7.1 s → 0.35 s, stroke end 1.19 → 0.84 s (target 200 ms NOT met: 8 sweeps × 24k bricks is the floor), From mesh
  6.8 → 3.9 s, Res− 1.7 → 1.5 s. Codes cost ~5 % on flush.
- Stage 7 PR #168 (merged 2026-10-27T10:40Z): voxel/combine.odin `clay_combine` (field CSG, blend = smin), `clay_copy`;
  app boolean.odin `boolean_apply`/`boolean_coarse` (preview copy ≤256 keyed on `Voxel_Part.edits`), Make swaps the
  base's clay, Blend slider; `.Boolean` out of MESH_ONLY_COMMANDS; bench Union column 335/1235/6174 ms (256/512/1024).
- Stage 8a PR #171 (merged 2026-10-27T11:10Z): voxel/mask.odin, mask bricks (byte a voxel) in the Volume, Mask brush,
  other brushes weighted by the unmasked share, Clear/Invert/Fill + rectangle/lasso on clay, Surface.mask per vertex,
  SVOX v2 (code 3 masked brick, v1 still reads), Convert to mesh carries the mask. 36 voxel tests.
- Stage 8b PR #176 (merged 2026-10-27T11:36Z): node normal cones from face normals in mesh_node (637 of 1160 nodes
  culled on an orbited 256 sphere, pixel-identical to --no-cull), Objects card pictures of voxel objects (thumb_shape).
- Stage 8c PR #181 (merged 2026-10-27T12:00Z): voxel/pack.odin, SVOX v3: bricks as second differences + run tokens
  (46 % of raw; plain RLE 62 %, zlib 48 %), masks as runs, raw fallback per brick, v1/v2 still read; 256 sphere scene
  file 7.8 → 3.7 MB; save 82 → 132 ms (serial packing).
- All stages done 2026-10-27T12:00Z. Stage 9 is Bolt's: /mnt/project-files/notes/voxel/stage9-windows-run.md says what
  to run (bench rows 256/512/1024, orbit with and without --no-cull with --time-gpu, --bench-stroke, hand tests, tablet
  at 256/512). Open target: stroke end at 1024 is 788 ms on the VM against 200 ms wanted (band repair floor).
- Build note: since #161 the debug/test/release builds need deps/luau (`python3 scripts/build_luau.py`); without it
  build.sh exits 1 and the gate fails at test.

**Why:** Bolt asked for the whole roadmap autonomously while away.
**How to apply:** restart branch `claude/project-thread-wp91l3` from origin/odin-sculpt after each merge; gate
(`python3 scripts/gate.py`) green before each PR; update README bench table and sm-sdf skill per stage; say in each
PR which app's idea each design choice came from (best of all worlds). Related: [[sculpt-voxel]], [[bolt-preferences]].
