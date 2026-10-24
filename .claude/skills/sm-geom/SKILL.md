---
name: sm-geom
description: The src/geom package — the structure-of-arrays geom.Mesh and its invariants (counter-clockwise outward triangles, closed manifold where subdivision needs it, every vertex used, no NaN), the icosphere and geodesic sphere fixtures, the SAH and Morton BVHs with refit, raycast and sphere queries, vertex-face CSR topology and spatial sort, chunk bounds and normal cones for culling, octahedral normals, QEM simplification that keeps borders, the LOD walk, and geom.mesh_check for proving a mesh sound with numbers. Load for ANY task that creates, inspects, transforms or tests triangle meshes or spatial queries, e.g. "add a primitive", "why does the raycast miss", "check this mesh is closed", "speed up the BVH build", "write a geom test", "compute the volume". Requires sm-odin and sm-build; brushes, nodes and levels over the mesh are sm-sculpt; CAD-style tools are sm-cad.
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
  use (`:354`); `bvh_refit_leaves` marks a bit per node and walks from the highest index down, since children always
  have larger indices than their parent (`:205-231`); `bvh_raycast` finds the nearest hit on either face, closer child
  first (`:253`); `bvh_query_sphere` returns a superset by leaf bounds (`:312`); `bvh_query_leaves` returns leaf indices
  (`:331`); `tri_bounds`, `leaf_bounds`, `RANGE_GRAIN = 1 << 16`.
- Topology (`src/geom/topology.odin`): `Vertex_Faces` in CSR form; `vertex_faces_build(m, pool)` lists each vertex's
  triangles ascending whatever the thread timing (`:15-62`); `vertex_faces_of`; `mesh_sort_vertices_spatially` reorders
  vertices along a Morton curve and remaps the indices, so a dab touches a narrow index range (`:74-77`).
- Culling (`src/geom/visibility.odin`): `Chunk{bounds, cone_axis, cone_cutoff, first_index, index_count}` with
  `cone_cutoff >= 1` meaning never back-face culled; `CONE_SLACK = 0.01`; `normal_cone` normalises its input in place
  (`:35-52`); `frustum_planes(clip)` leaves the planes unnormalised (`:57`); `chunk_backfacing` is conservative, by the
  bounding sphere (`:83-92`); `cull_chunks` needs chunks sorted by `first_index` and merges adjacent ranges (`:94-114`);
  `oct_encode`/`oct_decode` stay under 0.01° (`:131-155`).
- LOD walk (`src/geom/lod.odin`): `Lod_Group{bounds, cone_axis, cone_cutoff, error, first_index, index_count,
  child_first, child_count, stale}`, `LOD_NONE` for a group without a copy; `cull_lod` draws a group's copy when
  `error <= (max_error_px / px_per_unit) * box_distance(bounds, eye)` and it is neither stale nor hidden (`:43-113`).
- `simplify(positions, indices, target, out)` (`src/geom/simplify.odin:57`): quadric edge collapse into existing
  vertices (Garland–Heckbert), in passes of independent collapses; a vertex on an edge without exactly two triangles
  never moves, so a patch keeps its border exactly, nor does one with more than 32 neighbours (`:7-11, 124-130`); a
  collapse that would turn a triangle by about 75° or more is refused (`:42-50`); returns the RMS error.
- `mesh_check(m)`, `mesh_check_indices(positions, indices)`, `mesh_report_ok`, `mesh_report_print` (`src/geom/check.odin`):
  one pass that counts boundary, inconsistent and non-manifold edges, degenerate triangles and NaN positions and gives
  the signed volume and bounds. The app prints it with `--check-mesh` (sm-build).

## Invariants every geom proc keeps
| Invariant | Who relies on it | How to check |
|---|---|---|
| Triangles wind counter-clockwise seen from outside | the pipeline culls `.BACK` with `.COUNTER_CLOCKWISE` front faces (`src/render/renderer.odin:281`); back-face culling (`visibility.odin:83-92`) | `mesh_check(m).inverted == false` (signed volume > 0 for a closed mesh) |
| Closed manifold: each directed edge once, its twin once | `levels_subdivide` and `level_above` refuse otherwise (`src/sculpt/levels.odin:99-110, 445`); `levels_hd_set_steps` (`src/sculpt/hd.odin:73-82`); `simplify` locks such vertices | `mesh_check(m).closed`; `mesh_report_ok` for the whole contract |
| Every vertex is used by a triangle | `sculptor_init` asserts "mesh has vertices no triangle uses" (`src/sculpt/brush.odin:269`) | remove unused vertices and remap before handing a mesh to a sculptor |
| `len(normals) == len(positions)` | uploads pack one normal per vertex | the fixture builders set it |
| No NaN or infinite position | `aabb_grow` uses plain compares that let NaN through (`bvh.odin:15-20`), so a NaN poisons bounds silently | `mesh_check(m).nan_count == 0` |
| Vertex and triangle order are not stable across `sculptor_init` | anything holding indices across it | take the `old_to_new` it fills (`brush.odin:275`) |

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
| `bvh_query_sphere` returns the triangles inside the sphere | it returns every triangle of every leaf whose box touches it; filter yourself (`bvh.odin:310-311`) |
| `normal_cone` leaves its argument alone | it normalises the face normals in place (`visibility.odin:36`) |
| `cull_chunks` on chunks in any order | it merges adjacent ranges as it goes: chunks must be sorted by `first_index` |
| moving triangles between leaves and refitting | topology is fixed after the build; rebuild the BVH (`bvh.odin:43-44`) |
| `recompute_leaves = false` still recomputes leaf bounds | it recomputes only the ancestors; the caller set the leaf bounds itself (`src/sculpt/brush.odin:516-517`) |
| a flat grid is closed | it has a border, which `simplify` keeps exactly (`simplify_test.odin`, `simplify_keeps_a_patch_border`) |
| `icosphere(n)` has a vertex at (1, 0, 0) | its vertices are the icosahedron's, refined; test bounds with a tolerance (`check_test.odin`) |

## Tests
- `build.bat test` runs geom first. Fixtures: `icosphere(2..7)`, `geodesic_sphere(f)`, small node sizes for sculptors.
- Compare serial with parallel using `jobs.pool_init(&pool, 3)` and expect identical bits; keep helpers
  `@(private = "file")`; replace any hand-rolled closed-mesh check with `mesh_check` when you touch the file.
