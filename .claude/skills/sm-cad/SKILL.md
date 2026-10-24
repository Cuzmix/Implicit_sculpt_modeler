---
name: sm-cad
description: CAD-style mesh tools inside this app on geom.Mesh — primitives, booleans and trims, extrude/inset/bevel, mirror, the voxel remesh (DynaMesh) and relax, measure (length, area, volume, bounds) — and the checklist a new tool must follow to plug in: a pure geom proc, a Scene_Command and panel button, what it does to the sculptor, undo, levels, HD, LOD, GPU buffers, tests with geom.mesh_check and the numbers it prints. Load for ANY task that adds or changes a modelling operation other than a brush, e.g. "add a cube primitive", "boolean union two objects", "cut the mesh with a plane", "mirror across X", "measure the volume", "add an extrude tool", "import or export OBJ". Requires sm-geom, sm-sculpt and sm-ui; implicit and SDF modelling is sm-sdf; NOT external CAD programs and NOT a parametric feature tree.
---

# CAD-style tools

## What exists today (so nothing is assumed)
- New objects are spheres (`object_build`, `src/app/scene.odin:447`) or meshes from a file (`scene_add_mesh`), and any
  mesh can become an object through `object_build_from(app, obj, mesh, start)` (`:462`).
- Files (`src/app/files.odin`, README "Files"): OBJ and PLY in and out (`geom.mesh_read_obj`, `mesh_read_ply`,
  `mesh_write_obj`, `mesh_write_ply`, `src/geom/mesh_file.odin`), an import cleanup (`mesh_clean`, `mesh_normalize`,
  `mesh_edges`, `mesh_flip`), and the native `.sculpt` scene (`scene_save`/`scene_open`, levels through
  `sculpt.levels_write`/`levels_read`). `Object.file` keeps where an import was in its file, for export. A new
  per-object field that should survive a save goes in both `scene_save` and `scene_open` with a `SCENE_VERSION` bump,
  and `scene_open` must keep reading the older versions. Every file action ends in one `file_note`.
- Voxel remesh exists (README "Voxel remesh (DynaMesh)"): `geom.remesh_voxel(m, target, pool)` and
  `remesh_voxel_spacing(m, h, pool)` (`src/geom/remesh.odin:57, 68`) rebuild a mesh as an even, closed, manifold surface:
  winding-number rays along each axis decide inside, marching cubes with a rule-built table keeps ambiguous faces
  apart, three rounds of tangential relaxation even it out (`:11-29`); overlaps and self-intersections merge, anything
  thinner than the spacing goes; `REMESH_MAX_LATTICE 4096` per axis. Wired as `Scene_Command .Remesh` → `object_remesh`
  (`scene.odin:147-175`), the Scene panel's Remesh selected, Ctrl+R (at the object's own count) and `--remesh=N`.
- Dynamic topology (sm-sculpt) splits and collapses edges under the brush; a tool reading a dynamic object's mesh takes
  `sculpt.sculptor_compact_mesh` first, as `object_remesh` does, since the paged layout has unused slots.
- There are no booleans, trims or primitives besides spheres, no rotation (`Transform` is position plus uniform scale,
  `:14-20`, and `Draw_Item.model` must stay so, `src/render/renderer.odin:115-119`), no measurement or snapping. Undo
  stores positions or masks per node, or whole nodes under dynamic topology (`src/sculpt/undo.odin:9-15`), never an
  object's topology: Remesh is not undoable. The only field CSG is the SDF spike's smooth union (sm-sdf);
  `remesh_voxel` is the mesh-level union.

## Three kinds of tool, three plug-in paths
| Kind | Examples | Path |
|---|---|---|
| positions only, topology kept | mirror or symmetrise, relax or smooth all, taper, bend, snap to a surface | keep the sculptor: change `mesh.positions` for whole nodes (a vertex's node is `Level.node_of_vertex`, `src/sculpt/levels.odin:37`), then `sculpt.sculptor_nodes_moved(s, nodes)` (`src/sculpt/brush.odin:895-922`) so bounds, normals, LOD staleness and `edited` catch up and `levels_sync` carries it; upload through `object_show_level` (`scene.odin:354-376`). Undo: only dabs record today, so add a `sculptor_record_nodes(s, nodes)` that exposes `record_hit`/`record_changed` (`undo.odin`) between `sculptor_stroke_begin` and `sculptor_stroke_end`; the tool then is one stroke, and the cross-object `History` works unchanged (`src/app/history.odin:29-55`) |
| topology changes on an object | boolean, trim or slice, extrude, inset, bevel, decimate | copy `object_remesh` (`scene.odin:147-175`): `stroke_finish`, `object_hd_leave`, take the source (`sculptor_compact_mesh` when dynamic), build the new mesh and refuse with `log.warn` + `return true` if that fails, then `_ = sdl.WaitForGPUIdle`, `object_release_mesh` (history, GPU buffers and levels, `:482`) and `object_build_from` (`:462`). Levels, HD detail, the mask, dynamic topology and the stroke history are gone, and the tool is not undoable until the `Mesh_Swap` entry in [references/undo-and-topology.md](references/undo-and-topology.md) exists: write that design first |
| a new object | cube, cylinder, torus, plane with options | a `geom.<primitive>(…, allocator)` builder shaped like `icosphere`, then `scene_add_mesh(app, mesh, name, file = {scale = 1}, t, start)` (`scene.odin:122`), as `scene_import` does (`src/app/files.odin:200`); place it with `next_free_position` (`scene.odin:422-429`) |

## Plug-in checklist (every item names the file to copy from)
1. Geometry in `src/geom/<tool>.odin`, pure: imports only `core:` and `../jobs`, `allocator := context.allocator` last,
   deterministic, returns `(…, ok)` or counts; parallel only through `jobs.parallel_ranges` with heap-allocated per-job
   scratch (sm-odin).
2. Output meets the sm-geom invariants: closed where levels will be built, consistently wound outward, no degenerate
   triangles, no unused vertices (`sculptor_init` asserts, `brush.odin:315`), normals recomputed or left to
   `sculptor_recompute_all`. Booleans want manifold inputs and give manifold outputs; the robust fallback is a voxel or
   SDF remesh ([references/algorithms.md](references/algorithms.md)).
3. A new `Scene_Command.kind` (`scene.odin:84-91`) with its fields; the panel sets `app.ui.scene_command = {kind = …}`
   (`src/app/ui.odin`, the Add / Remesh buttons); it is applied at the next frame start (`src/app/main.odin:282-285`).
   Never mutate the scene from inside `ui_draw`.
4. A `scene_apply` case (`scene.odin:245-335`): refuse with `log.warn` and `return true` (`:298-313`), fail only a fatal
   GPU error with `return false`; log the result like `object_build` does (`:473-475`).
5. `render.viewport_invalidate(&app.target)` when what is drawn changed without a buffer version bump (`scene.odin:399,
   283`); a new `Mesh_Buffers` or `mesh_buffers_upload_ranges` bumps the version and forces a full redraw by itself.
6. Range uploads must stay within `vertex_capacity`; a tool that adds vertices recreates the buffers.
7. A shortcut only inside `handle_shortcuts` (guarded by `WantTextInput`), and README "Controls" plus the Scene panel
   text updated.
8. Tests in `src/geom/<tool>_test.odin`: `mesh_check` on the output; counts (V − E + F = 2 per closed shell); signed
   volume, area and bounds against the intent (a unit cube is 1; a union is at most the sum; a mirror's bounds are
   symmetric; a trim's bounds stop at the plane); a planted fault; serial equals parallel when jobs are used.
9. Numbers printed: `log.infof("<tool>: %d vertices, %d triangles, %.0f ms", …)` and, for booleans and trims,
   `volume_before= volume_after= boundary_edges= non_manifold_edges=` in the exit-stats style; `--check-mesh` must stay
   green after the tool.
10. A `bench` mode or `--bench-*` flag when the tool runs per frame or on 10M-vertex meshes (sm-perf).

## Measure
- Edge length and area from positions; bounds from `geom.Aabb`/`aabb_grow` (`src/geom/bvh.odin:9-20`); signed volume
  Σ p0·(p1×p2)/6, meaningful only for a closed, outward mesh (`mesh_check` gives it); distance to the surface through
  `closest_on_triangle` (promote it from `simplify_test.odin`); picking through `scene_raycast` (`scene.odin:432-444`),
  which returns world-space hits, and `to_local`/`to_world` (`:34-35`).

## References (read when the task needs them)
- [references/algorithms.md](references/algorithms.md): boolean semantics worth copying (Manifold), voxel remesh as the
  fallback, QEM decimation already in `simplify.odin`, Loop stencils and boundary rules, plane trims, extrude/inset/bevel
  templates, and the checks-with-numbers recipe from the CAD skill repos.
- [references/undo-and-topology.md](references/undo-and-topology.md): the `Mesh_Swap` history entry design that makes
  topology-changing tools undoable, and why positions-only undo cannot cover them.
