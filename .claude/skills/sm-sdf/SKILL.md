---
name: sm-sdf
description: Implicit and SDF modelling for this app — the src/sdf_trial spike (dense n³ f32 grid, 16³ chunks, smooth-union dabs, surface-nets remesh of dirty chunks, key=value timings), SDF primitives and CSG (union, intersection, difference, smooth blends), sign conventions, surface nets versus dual contouring, meshing an SDF into a sound geom.Mesh and handing it to the scene through the sm-cad checklist, and comparing it against the mesh sculptor on equal terms. Load for ANY task that mentions SDFs, signed distance, voxels, implicit surfaces, CSG on fields, smooth blends, marching cubes, surface nets or dual contouring, e.g. "run the sdf trial at 256", "add a box SDF", "make the SDF mesh triangles", "turn the SDF into an object", "compare SDF and mesh dab cost". Requires sm-geom and sm-cad; the timing method is sm-perf.
---

# Implicit surfaces

## What exists: the voxel sculptor (`src/voxel`, README "Voxel sculpting")
- The production voxel core, in the build and test lists: `Volume` (narrow-band SDF, 8³ `Brick` of `i16` at `SCALE`
  4096 units a voxel, `BAND` 3, `CLAMP` ±4 voxels, tiles `TILE_EMPTY`/`TILE_INSIDE` in each chunk's table, 4096³ domain)
  in `volume.odin`; `Clay` (volume + `Surface` + undo + pool) with `clay_init/destroy/fill_sphere/raycast/stroke_begin/dab/
  stroke_end/flush/to_mesh/write/read/undo/redo` in `clay.odin`, `mesh.odin`, `undo.odin`, `file.odin`, `convert.odin`;
  brushes `Add, Subtract, Smooth, Flatten, Inflate` as a stamp `smin`, a 27-mean, a plane clip or fill and an offset
  (`brush.odin`); band repair by Godunov sweeps at `clay_stroke_end` (`band.odin`): the region's bricks run in WAVEFRONTS
  (bricks of one coordinate sum share no face, so a wavefront is one `parallel_for` reading neighbours live: Gauss-Seidel
  across bricks, no snapshot), a sweep per direction (`sweep & 7`), stopping at the first sweep that moves no value by
  more than `REPAIR_SETTLED` (`Clay.repair_sweeps` says how many; `band_repair(c, every_sweep = true)` runs them all for
  the test). Negative is inside, as here.
- Rules it keeps: every new value depends on old values only (serial == parallel, `serial_and_parallel_strokes_agree_bit_for_bit`);
  jobs write disjoint bricks or node slots; the directory changes only in serial passes; a brick dirties the nodes whose
  20³ meshing window sees a change within `NEAR` (3 voxels) of the surface; unused index slots are zeros on a dummy vertex 0;
  the arrays grow only when `Flush.regrow` says so (the GPU copy is remade then). `build/bench --voxel` measures it.
- In the app (`src/app/voxel_object.odin`): `Object.voxel: ^Voxel_Part{clay, gpu, resolution}` is the voxel object kind.
  A voxel object keeps one EMPTY level (`levels_init` with no vertices) so the hundreds of readers of the selected
  object's sculptor see nothing rather than nil; everything that changes a level checks `obj.voxel` first:
  `scene_apply` refuses `MESH_ONLY_COMMANDS`, `stroke_start` refuses brushes `voxel_brush_of` cannot map, dabs go through
  `object_dab` and picking through `object_raycast_local`, `brush_stroke_finish`/`history_step`/`history_drop_redo`/
  `object_forget_history` branch to `clay_stroke_end`/`clay_undo`/`clay_redo`/`clay_clear_redo`/`clay_clear_history`,
  the frame loop branches to `voxel_upload` before `levels_current`, and `object_put_bytes` writes the kind byte and the
  clay in the levels' place (scene file version 13). `Voxel_To_Mesh` is the swap entry that converts (`clay_to_mesh`) and
  `Mesh_To_Voxels` the one that converts the other way (`object_mesh_to_voxels` → `clay_from_mesh`, which clears the
  object's `group_materials` too, since `object_get` refuses a voxel object with any).
- Mesh → voxels (`voxelize.odin`): `clay_from_mesh(c, m, voxel, pool)` lays the voxel grid over the mesh's box (centred in
  the domain, `VOXELIZE_MARGIN` voxels around; `voxel_size_for(bounds, across)` picks the voxel), casts `geom.lattice_rays_cast`
  along x, y and z (the remesh's exact fixed-point crossings, now public in `src/geom/lattice_rays.odin`), takes inside
  = x-ray winding > 0 (an open mesh fills as Remesh fills it), marks the bricks within `VOXELIZE_REACH` of an x crossing
  per z slab, fills the rest as `TILE_INSIDE` or empty, seeds each marked brick in parallel (the sign window, then for a
  voxel beside a sign change the planar distance from its axes' crossings, `CROSSING_MARGIN` away from the lattice
  points), then `band_mark` + `band_repair` + `surface_mark_all`. Refuses (false, nothing allocated) an empty mesh, a bad
  voxel size or a grid past `VOXELIZE_MAX` along an axis. Tests: `voxelize_test.odin` (sphere within a voxel and 5 %
  volume, torus keeps its hole, cube with faces on voxel rows, serial == parallel hash, refusals); `bench --voxel`
  prints `From mesh ms`.
- Manifold surface (`saddle.odin`, `mesh.odin`): the field keeps NO SADDLE FACE (a 2×2 voxel face with the inside
  corners on a diagonal). `resolve_saddles(c, slots, record)` scans the faces with a lower corner in those bricks or
  the layer before them (10³ window, parallel), then flips serially with a worklist (the inside corner with the
  smaller |d| → `SADDLE_FLIP` = +1 unit; ties to the lower z, y, x; a corner in an Inside tile makes a brick; the
  brick is `undo_record`ed when `record`, `band_mark`ed and its nodes marked); a flip only turns inside voxels
  outside, so it ends. Runs at `clay_stroke_end` over the stroke's saved bricks (a per-dab scan cost 1.2 ms a dab
  at 1024, so between dabs a saddle may stand), and `resolve_all_saddles` after `clay_fill_sphere`, `clay_from_mesh`,
  `clay_resample` and `clay_read`. `mesh_node` makes one vertex per LOOP of crossed edges in a cell (`Cell_Verts`,
  edges joined through `CELL_FACES`, `cell_edge(axis, corner)` names the edge a quad takes in each of its four
  cells); with no saddle faces every quad side is in exactly two quads and each vertex's quads form one cycle:
  `mesh_check` reports 0 non-manifold edges. Tests `saddle_test.odin`; the app's `--check-mesh` finishes the stroke
  first.
- Res+ / Res− (`resample.odin`): `clay_resample(c, RESAMPLE_UP | RESAMPLE_DOWN) -> bool` rebuilds the volume at
  half or twice the voxel, the domain kept centred (so ×2 halves it in object space: clay past `DOMAIN/2 − BAND − 2`
  new voxels from the centre is refused, the clay untouched). Candidates are each old brick's 8 children (×2) or
  parent (÷2), filled in parallel from a gathered old window (trilinear; ÷2 lands on old centres); all-clamp ones
  collapse. ×2 needs no repair (the old band covers the new clamp and interpolation error is curvature·voxel²/8); ÷2
  runs `band_repair`, then `grow_band` rounds (dilate_band's face test, no undo) until the band meets the clamp.
  It calls `clay_clear_history` (no stroke may be running) and starts the surface over (`regrow`, so the app's next
  `voxel_upload` remakes the GPU copy). App: `Scene_Command_Kind.Voxel_Resample` (`cmd.voxels` = the new
  resolution, a doubling or halving within VOXELS_MIN..MAX), commands `Voxel_Res_Up`/`Voxel_Res_Down`, swap undo entry
  via `object_voxel_resample`; exit stat `voxel_resolution`. Tests `resample_test.odin`; bench columns `Res− ms`,
  `Res+ ms`.
- Weld by codes (`convert.odin`, `mesh.odin`): every vertex slot has a `Surface.codes` u32 beside its position
  (`Mesh_Result.codes`, copied in the flush, grown in `surface_alloc_verts`, carried by `surface_compact`): the cell as
  its OWNER node indexes it (12 bits), the loop (`CODE_LOOP_SHIFT`), and the axes this node sees the cell at −1 along
  (`CODE_OFFSET_SHIFT`; owner = node − those). A node also makes vertices for its far-face cells (15 along an axis)
  that only the next node's edges cross, so every owned cell has its vertex. `clay_to_mesh` is five `parallel_for`
  passes over nodes (sort owned codes per node, find each copy's owner by binary search through `surface_node_find`,
  prefix sums, write vertices, remap copies and write triangles), the same mesh on one thread and many; a copy with no
  owner (domain edge) keeps its vertex. `clay_to_mesh_by_position` is the old serial sort weld, kept as the test
  oracle (`weld_test.odin`). Zero voxel values are read as `ZERO_OUTSIDE` where a crossing is placed, so no two cells
  put a vertex on one lattice point. Any new per-vertex array (a mask) follows `codes` through those three places.
  Add a voxel path wherever you add a mesh path that touches a level; never call `sculpt.*` on a voxel object expecting
  vertices.

## What exists: the spike (`src/sdf_trial/main.odin`)
- Booleans on the field (`combine.odin`): `clay_combine(c, other_volume, to_other, scale, op, blend)` reads the other
  volume at c's voxel centres through `to_other` (c object space → other object space; `scale` = c units per other
  unit), union = smin, subtract = −smin(−a, o), intersect = −smin(−a, −o), `blend` in c's voxels; only bricks in the
  other's box (± band + blend) are visited, a brick the other is one tile over becomes a tile without computing;
  Intersect first drops every brick and Inside tile outside the box; then resolve_saddles → band_mark → band_repair →
  grow_band rounds, surface_mark_all; history cleared (caller records a swap). `clay_copy` duplicates a clay (node
  indices reset to NODE_NONE). The app (`boolean.odin`) applies marks to a copy of the base, voxelising a mesh mark
  with `clay_from_mesh` at the base's voxel size; the preview uses a cached copy brought ≤ 256 across by Res− steps,
  keyed on `Voxel_Part.edits` (bumped by `voxel_part_edited` at stroke end, undo/redo, resample, boolean, attach).
- Masks on clay (`mask.odin`): `Volume.masks[slot]` → `mask_bricks` (`[512]u8`, 255 masked) or MASK_NONE; tiles have
  none; `volume_brick_collapse` drops the mask, `volume_brick_make` starts unmasked. `dab_brick(..., mask)` weights
  every brush's new value by (1 − m/255) (`masked`); `Brush_Kind.Mask` → `dab_mask_brick` (falloff × strength, invert
  erases), bricks only. `clay_mask_command(.Clear/.Invert/.Fill)`, `clay_mask_shape(c, inside_proc, user, unmask)`
  (the app passes a proc: clip + `sculpt.coverage_at` + front-only via `volume_gradient`); both are undo steps
  (`Saved_Brick.mask` indexes `Undo_Step.masks`). `Surface.mask` per vertex follows codes everywhere (alloc, compact,
  copy pass); `mesh_node` gathers a u8 window only when `volume_masked_over`; the app uploads `surface.mask` as the
  mesh_buffers mask (packed into the normals) when `object_has_mask` (which has a clay branch). SVOX v3 (`pack.odin`): code 3 = masked
  brick; each brick's values packed after a u16 byte count (0 = raw): first value, then LEB128 tokens, 0 = run of the
  last value (count byte follows), else zigzag second difference + 1; masks as (count, value) runs; 46 % of raw on a
  256 sphere (zlib 48 %, measured). v1 and v2 (raw bricks) still read; `clay_write_estimate` is the raw upper bound. `clay_to_mesh(c, mask = &values)` carries the mask to a mesh.
- Culling and pictures: `mesh_node` ends with the node's normal cone from its triangles' face normals
  (`geom.normal_cone`; never the gradient vertex normals), kept on `Node.cone_axis/cone_cutoff` and passed to the
  `geom.Chunk` by `surface_chunks_rebuild`, so the renderer back-face culls clay nodes as mesh chunks. The Objects
  card's picture of a voxel object draws `vp.gpu` fitted to its surface chunks' bounds (`thumb_shape` in
  `object_thumbs.odin`), keyed on `vp.gpu.version` and the turn.
- A standalone, time-boxed comparison, not part of the app or the build scripts (`:1-5`; README "Layout" and the last
  line of "GPU benchmark and frame timing"). Build and run it with the strict flags, which it passes:
  `deps\odin\odin.exe build src\sdf_trial -o:speed -collection:deps=deps -vet -strict-style -warnings-as-errors
  -out:build\sdf_trial.exe && build\sdf_trial.exe 256`.
- `CHUNK = 16`, `EXTENT = 1.5` (the grid covers [−1.5, 1.5]³) (`:16-17`); `Grid{n, cell, dist []f32, dirty []bool per
  chunk, chunks}` dense, n³ floats (`:19-25`); `grid_make` fills a unit-sphere SDF, negative inside (`:33-45`);
  `smooth_union(a, b, k)` is the polynomial smooth minimum (`:51-54`); `apply_dab(center, radius)` blends a sphere in
  with `k = radius / 2` over a band of `radius + k + 2 cells` and marks the touched chunks dirty, plus the chunk before
  each, since a cell reads its +1 neighbours (`:56-81`); `remesh_chunk` is surface nets: one vertex per cell the surface
  crosses, at the mean of its edge crossings, one quad per crossing edge owned by the chunk owning the edge, winding
  flipped when `d0 < 0` (`:83-156`); `Mesh_Out{positions, quads [4]u32, cell_vert}` holds quads, not triangles (`:27-31`);
  `remesh_dirty` (`:158-167`).
- The run: the same 77-dab, r = 0.13 wavy stroke as `bench` (`:194-211`), then `grid= voxel= grid_mb= build_ms=`,
  `full_remesh_ms= vertices= triangles= mesh_mb=`, `dabs= dab_ms_p50= dab_ms_max=`, `remesh_ms_p50= remesh_ms_max=
  chunks_per_dab=` (`:226-230`). The first argument is n, rounded down to a multiple of 16 (`:170-174`).

## Numbers to know
| Quantity | Value |
|---|---|
| grid memory | n³ × 4 B: 128³ = 8 MB, 256³ = 64 MB, 512³ = 512 MB; `cell_vert` adds another 4 B per voxel |
| voxel size | 3 / n of the unit sphere's diameter scale (`cell = 2·EXTENT / n`) |
| voxels a dab touches | about (2 · reach / cell)³ with reach = 1.5 r + 2 cells |
| surface-nets vertices | about one per cell the surface crosses: surface area / cell² |

## Rules
- Negative is inside, everywhere (`grid_make`, `emit_quads`). CSG on fields: union `min(a, b)`, intersection `max(a, b)`,
  difference `max(a, −b)`, with smooth variants that keep `smooth_union`'s meaning of `k` (the blend radius).
- Only the blend band changes: keep dirty marking as tight as `apply_dab`'s, and remember the −1 neighbour chunk.
- Remeshing renumbers vertices, so there are no stable vertex ranges for `mesh_buffers_upload_ranges`: upload per chunk
  into its own slot or recreate the buffers (sm-render).
- Surface nets can produce non-manifold edges on ambiguous cells: run `geom.mesh_check` after every remesh and print its
  line. Dual contouring (Ju et al. 2002) places the vertex by a QEF over Hermite data (crossing points and normals) and
  keeps sharp features; manifold dual contouring (libfive's mesher) guarantees a manifold result when that matters.
- Report the spike's key=value timings for every change and compare them with the mesh benchmark at the same vertex
  count, release builds, same thread count (sm-perf).

## Turning an SDF into a scene object (the sm-cad checklist applies)
1. Triangulate each quad as `(q0, q1, q2), (q0, q2, q3)`, keeping the quad's winding; vertices are already shared per
   cell, so no weld is needed; drop degenerate triangles.
2. Build `geom.Mesh{positions, normals, indices}` and `mesh_recompute_normals`; `mesh_check` must report closed with a
   positive volume (flip every triangle if the volume is negative).
3. Hand it to `scene_add_mesh` (the new-object path); later dabs that remesh go through the topology-change path, which
   drops levels and strokes; record it as a swap entry (sm-cad references/undo-and-topology.md) so Ctrl+Z restores the object.
4. Numbers: vertices, triangles, `mesh_check` line, volume against the analytic one (a unit sphere's is 4π/3 ≈ 4.189).

## Traps
| You might expect | What happens |
|---|---|
| `sdf_trial.exe 200` uses a 200³ grid | n is rounded down to a multiple of 16: 192 (`:174`) |
| a dab outside [−1.5, 1.5]³ grows the grid | `EXTENT` is fixed; the band is clamped to the grid (`:63-66`) |
| the printed `_max` is a p99 | the helper named `p99` returns the maximum (`:218-222`) |
| `Mesh_Out` is a triangle mesh | quads; triangle count is `2 · len(quads)` (`:191`) |
| `smooth_union` with `k = 0` | divides by k: use plain `min` when k is 0 |

## References
- [references/implicit.md](references/implicit.md): SDF primitive formulas, CSG and smooth-minimum variants, field
  transforms, normals from gradients, surface nets versus dual contouring versus marching cubes, chunked and sparse
  grids, and the comparison-table template against `bench`.
