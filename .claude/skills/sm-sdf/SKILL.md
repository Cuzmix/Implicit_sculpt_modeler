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
  (`brush.odin`); band repair by Godunov sweeps at `clay_stroke_end` (`band.odin`). Negative is inside, as here.
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
  volume, torus keeps its hole, serial == parallel hash, refusals); `bench --voxel` prints `From mesh ms`.
  Add a voxel path wherever you add a mesh path that touches a level; never call `sculpt.*` on a voxel object expecting
  vertices.

## What exists: the spike (`src/sdf_trial/main.odin`)
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
