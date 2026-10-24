---
name: sm-geom
description: The src/geom package — the structure-of-arrays geom.Mesh and its invariants (counter-clockwise outward triangles, closed manifold where subdivision needs it, every vertex used, no NaN), the icosphere and geodesic sphere fixtures, the SAH and Morton BVHs with refit, raycast and sphere queries, vertex-face CSR topology and spatial sort, chunk bounds and normal cones for culling, octahedral normals, QEM simplification that keeps borders, the LOD walk, the voxel remesh (DynaMesh), response curves (pen pressure), and geom.mesh_check for proving a mesh sound with numbers. Load for ANY task that creates, inspects, transforms or tests triangle meshes or spatial queries, e.g. "add a primitive", "why does the raycast miss", "check this mesh is closed", "speed up the BVH build", "write a geom test", "compute the volume", "the remesh leaves a hole". Requires sm-odin and sm-build; brushes, nodes and levels over the mesh are sm-sculpt; CAD-style tools are sm-cad.
---

# Geometry

## Model (README "Layout", the geom row)
- `Mesh{positions, normals: [dynamic]Vec3, indices: [dynamic]u32}`: three indices per triangle, counter-clockwise seen
  from outside; the mesh owns its arrays (`mesh_destroy`); `mesh_recompute_normals` is area-weighted (`src/geom/mesh.odin`).
- Fixtures: `icosphere(subdivisions, radius = 1)` has 10·4ⁿ+2 vertices; `geodesic_sphere(frequency, pool)` has 10f²+2,
  filled in parallel over the 20 faces; `geodesic_frequency_for(vertices)` picks f (`src/geom/icosphere.odin:11, 82, 91`).
- BVH (`src/geom/bvh.odin`): `Bvh_Node{bounds, first, count, parent}`, `count == 0` for an internal node whose children
  sit at `first` and `first + 1`, `BVH_NONE` for the root's parent. `bvh_build` splits by a binned surface area heuristic,
  12 bins (`:72`); `bvh_build_morton(m, leaf_size, pool)` radix-sorts Morton codes in linear time and is what sculptors
  use (`:359`); `bvh_refit_leaves` marks a bit per node and walks from the highest index down, since children always
  have larger indices than their parent (`:205-231`); `bvh_raycast` finds the nearest hit on either face, closer child
  first (`:253`); `bvh_query_sphere` returns a superset by leaf bounds (`:313`); `bvh_query_leaves` returns leaf indices
  (`:336`); `tri_bounds`, `leaf_bounds`, `RANGE_GRAIN = 1 << 16`. `bvh_build_over(boxes, first, count, leaf_of)` builds
  a tree whose leaves are runs of triangle ids (one per item, `leaf_size` 1) for dynamic topology's pages (`:443`): its
  `tri_order` is nil and `tri_leaf` empty, which `leaf_bounds`, `bvh_raycast` and `bvh_query_sphere` handle and
  `bvh_refit_triangles` does not.
- Topology (`src/geom/topology.odin`): `Vertex_Faces` in CSR form; `vertex_faces_build(m, pool)` lists each vertex's
  triangles ascending whatever the thread timing (`:15-62`); `vertex_faces_of`; `mesh_sort_vertices_spatially` reorders
  vertices along a Morton curve and remaps the indices, so a dab touches a narrow index range (`:74-77`).
- Culling (`src/geom/visibility.odin`): `Chunk{bounds, cone_axis, cone_cutoff, first_index, index_count}` with
  `cone_cutoff >= 1` meaning never back-face culled; `CONE_SLACK = 0.01`; `normal_cone` normalises its input in place
  (`:35-52`); `frustum_planes(clip)` leaves the planes unnormalised (`:57`); `chunk_backfacing` is conservative, by the
  bounding sphere (`:83-92`); `cull_chunks` needs chunks sorted by `first_index` and merges adjacent ranges (`:94-114`);
  `oct_encode`/`oct_decode` stay under 0.01° (`:133, 168`); `oct_encode_masked(n, mask)` keeps the top 12 bits of each
  half for the normal and carries the mask's two nibbles in the low 4 bits, about 0.1° (`:149`; `oct_masked_decode`
  for tests, `:161`). The renderer packs every normal with it (sm-render).
- LOD walk (`src/geom/lod.odin`): `Lod_Group{bounds, cone_axis, cone_cutoff, error, first_index, index_count,
  child_first, child_count, stale}`, `LOD_NONE` for a group without a copy; `cull_lod` draws a group's copy when
  `error <= (max_error_px / px_per_unit) * box_distance(bounds, eye)` and it is neither stale nor hidden (`:43-113`).
- `simplify(positions, indices, target, out)` (`src/geom/simplify.odin:57`): quadric edge collapse into existing
  vertices (Garland–Heckbert), in passes of independent collapses; a vertex on an edge without exactly two triangles
  never moves, so a patch keeps its border exactly, nor does one with more than 32 neighbours (`:7-11, 124-130`); a
  collapse that would turn a triangle by about 75° or more is refused (`:42-50`); returns the RMS error.
- Mesh files (`src/geom/mesh_file.odin`): `mesh_read_obj(data, pool)` (parallel chunks, polygons as fans, negative and
  `v/vt/vn` indices) and `mesh_read_ply(data, pool)` (ASCII and both binary orders) return `(Mesh, Mesh_File_Error,
  line)`; `mesh_clean` welds bit-identical positions and drops repeated-corner triangles and unused vertices;
  `mesh_sculptable` is what a sculptor needs of a mesh from a file (three different in-range corners per triangle,
  every vertex used, every position finite);
  `mesh_edges` gives border and bad edge counts and the signed volume (`mesh_edges_closed`), `mesh_flip` turns
  every triangle, `mesh_normalize` centres and sizes to radius 1. `mesh_write_obj`/`mesh_write_ply` take a scale and
  offset and skip them when they are the identity (so -0 survives); `format_f32` writes nine significant digits,
  which read back bit for bit. `Byte_Reader` with `byte_get*` (a short read turns `ok` false and later reads give
  zero) and `byte_put*` are the binary helpers the scene file uses.
- Response curves (`src/geom/curve.odin`, the pen pressure curve): `Curve{c1, c2}` is a cubic Bézier from (0, 0) to
  (1, 1); `curve_at(curve, x)` clamps the controls into the unit square (`curve_clamped`), which keeps x monotone in the
  parameter, finds the parameter by 24 bisection steps and returns exact 0 and 1 at the ends; `CURVE_LINEAR` is y = x.
- `mesh_check(m)`, `mesh_check_indices(positions, indices)`, `mesh_report_ok`, `mesh_report_print` (`src/geom/check.odin`):
  one pass that counts boundary, inconsistent and non-manifold edges, degenerate triangles and NaN positions and gives
  the signed volume and bounds. The app prints it with `--check-mesh` (sm-build).
- Voxel remesh (`src/geom/remesh.odin`, README "Voxel remesh (DynaMesh)"): `remesh_voxel(m, target, pool)` picks the
  spacing from the area (`remesh_spacing`, `:45`) and `remesh_voxel_spacing(m, h, pool)` remeshes at a given one
  (`:57, 68`); winding-number rays with exact fixed-point edge tests decide inside, marching cubes from a rule-built table
  keeps the result closed and manifold, three rounds of tangential relaxation even it out (`:11-29`); storage grows with
  the surface, not the volume; at most `REMESH_MAX_LATTICE` (4096) per axis. Tests in `remesh_test.odin`
  (`expect_closed_manifold`, Euler characteristic 2, distance to the sphere within 0.6 of the spacing).

## Invariants every geom proc keeps
| Invariant | Who relies on it | How to check |
|---|---|---|
| Triangles wind counter-clockwise seen from outside | the pipeline culls `.BACK` with `.COUNTER_CLOCKWISE` front faces (`src/render/renderer.odin:284`); back-face culling (`visibility.odin:83-92`) | `mesh_check(m).inverted == false` (signed volume > 0 for a closed mesh) |
| Closed manifold: each directed edge once, its twin once | `levels_subdivide` and `level_above` refuse otherwise (`src/sculpt/levels.odin:101-113, 470`); `levels_hd_set_steps` (`src/sculpt/hd.odin:73-82`); `simplify` locks such vertices | `mesh_check(m).closed`; `mesh_report_ok` for the whole contract |
| Every vertex is used by a triangle | `sculptor_init` asserts "mesh has vertices no triangle uses" (`src/sculpt/brush.odin:321`) | remove unused vertices and remap before handing a mesh to a sculptor. A dynamic-topology sculptor's mesh has unused page slots and (0,0,0) triangles by design: check `sculpt.sculptor_compact_mesh` instead, as `--check-mesh` does |
| `len(normals) == len(positions)` | uploads pack one normal per vertex | the fixture builders set it |
| No NaN or infinite position | `aabb_grow` uses plain compares that let NaN through (`bvh.odin:15-20`), so a NaN poisons bounds silently | `mesh_check(m).nan_count == 0` |
| Vertex and triangle order are not stable across `sculptor_init` | anything holding indices across it | take the `old_to_new` it fills (`brush.odin:327`) |

## Verify with numbers, not pictures
- After any mesh operation print or expect: vertex and triangle counts (one closed genus-0 shell has V − E + F = 2, i.e.
  E = 3F/2), the `mesh_check` counts, the bounds, and the signed volume (negative = inside out; a unit cube is 1, a unit
  icosphere a little under 4π/3). A planted fault must be caught: flip one triangle, drop one, duplicate one, and watch
  the counts move (`src/geom/check_test.odin` does exactly that).
- Distances to a surface: `closest_on_triangle` / `distance_to_surface` live in `simplify_test.odin` and `lod_test.odin`
  as file-private helpers; promote them into geom when production code needs them.

## Traps
| You might expect | What happens |
|---|---|
| `b.tri_order[i]` works on any BVH | nil on a `bvh_build_over` tree (dynamic topology): go through `sculpt`'s `tri_node`, or the leaf's run of ids |
| `bvh_query_sphere` returns the triangles inside the sphere | it returns every triangle of every leaf whose box touches it; filter yourself (`bvh.odin:311-312`) |
| `normal_cone` leaves its argument alone | it normalises the face normals in place (`visibility.odin:36`) |
| `cull_chunks` on chunks in any order | it merges adjacent ranges as it goes: chunks must be sorted by `first_index` |
| moving triangles between leaves and refitting | topology is fixed after the build; rebuild the BVH (`bvh.odin:43-44`) |
| `recompute_leaves = false` still recomputes leaf bounds | it recomputes only the ancestors; the caller set the leaf bounds itself (`finish_move`, `src/sculpt/brush.odin:713`) |
| a flat grid is closed | it has a border, which `simplify` keeps exactly (`simplify_test.odin`, `simplify_keeps_a_patch_border`) |
| `icosphere(n)` has a vertex at (1, 0, 0) | its vertices are the icosahedron's, refined; test bounds with a tolerance (`check_test.odin`) |

## Tests
- `build.bat test` runs geom first. Fixtures: `icosphere(2..7)`, `geodesic_sphere(f)`, small node sizes for sculptors.
- Compare serial with parallel using `jobs.pool_init(&pool, 3)` and expect identical bits; keep helpers
  `@(private = "file")`; replace any hand-rolled closed-mesh check with `mesh_check` when you touch the file.
