---
name: sm-cad
description: CAD-style mesh tools inside this app on geom.Mesh — primitives, booleans and trims, extrude/inset/bevel, mirror and symmetry, remesh and relax, measure (length, area, volume, bounds) — and the checklist a new tool must follow to plug in: a pure geom proc, a Scene_Command and panel button, what it does to the sculptor, undo, levels, HD, LOD, GPU buffers, tests with geom.mesh_check and the numbers it prints. Load for ANY task that adds or changes a modelling operation other than a brush, e.g. "add a cube primitive", "boolean union two objects", "cut the mesh with a plane", "mirror across X", "measure the volume", "add an extrude tool", "import or export OBJ". Requires sm-geom, sm-sculpt and sm-ui; implicit and SDF modelling is sm-sdf; NOT external CAD programs and NOT a parametric feature tree.
---

# CAD-style tools

## What exists today (so nothing is assumed)
- Objects are spheres only (`object_build`, `src/app/scene.odin:314-336`); Remesh builds a fresh sphere and drops the
  sculpted detail (`object_remesh`, `:105-111`); there are no booleans, trims or primitives, no rotation (`Transform` is
  position plus uniform scale, `:12-18`, and `Draw_Item.model` must stay so, `src/render/renderer.odin:112-116`), no
  import or export, no measurement or snapping. Undo stores positions per node (`src/sculpt/undo.odin:9-13`), nothing
  about topology. The only CSG anywhere is the SDF spike's smooth union (sm-sdf).

## Three kinds of tool, three plug-in paths
| Kind | Examples | Path |
|---|---|---|
| positions only, topology kept | mirror or symmetrise, relax or smooth all, taper, bend, snap to a surface | keep the sculptor: change `mesh.positions` for whole nodes (a vertex's node is `Level.node_of_vertex`, `src/sculpt/levels.odin:37`), then `sculpt.sculptor_nodes_moved(s, nodes)` (`src/sculpt/brush.odin:680-707`) so bounds, normals, LOD staleness and `edited` catch up and `levels_sync` carries it; upload through `object_show_level` (`scene.odin:221-243`). Undo: only dabs record today, so add a `sculptor_record_nodes(s, nodes)` that exposes `record_hit`/`record_changed` (`undo.odin`) between `sculptor_stroke_begin` and `sculptor_stroke_end`; the tool then is one stroke, and the cross-object `History` works unchanged (`src/app/history.odin:29-40`) |
| topology changes on an object | boolean, trim or slice, extrude, inset, bevel, remesh, decimate | follow Remesh (`scene.odin:107-111, 340-346`): `stroke_finish`, `object_hd_leave`, `_ = sdl.WaitForGPUIdle`, `history_forget`, destroy `obj.gpu[*]` and `hd_gpu`, `levels_destroy`, then `levels_init(&obj.levels, new_mesh, &app.pool)` and `mesh_buffers_create` as `object_build` does, `app.stats = {}`. Levels, HD detail and the stroke history are gone, and the tool itself is not undoable until the `Mesh_Swap` entry in [references/undo-and-topology.md](references/undo-and-topology.md) exists: write that design first |
| a new object | cube, cylinder, torus, plane with options; import | a `geom.<primitive>(…, allocator)` builder shaped like `icosphere`, then a `scene_add_mesh(app, mesh, transform)` modelled on `scene_add_sphere` (`scene.odin:91-103`): `new(Object)`, `levels_init`, `mesh_buffers_create`, `next_id`, select; place it with `next_free_position` (`:289-296`) |

## Plug-in checklist (every item names the file to copy from)
1. Geometry in `src/geom/<tool>.odin`, pure: imports only `core:` and `../jobs`, `allocator := context.allocator` last,
   deterministic, returns `(…, ok)` or counts; parallel only through `jobs.parallel_ranges` with heap-allocated per-job
   scratch (sm-odin).
2. Output meets the sm-geom invariants: closed where levels will be built, consistently wound outward, no degenerate
   triangles, no unused vertices (`sculptor_init` asserts, `brush.odin:269`), normals recomputed or left to
   `sculptor_recompute_all`. Booleans want manifold inputs and give manifold outputs; the robust fallback is a voxel or
   SDF remesh ([references/algorithms.md](references/algorithms.md)).
3. A new `Scene_Command.kind` (`scene.odin:68-74`) with its fields; the panel sets `app.ui.scene_command = {kind = …}`
   (`src/app/ui.odin`, the Add / Remesh buttons); it is applied at the next frame start (`src/app/main.odin:220-223`).
   Never mutate the scene from inside `ui_draw`.
4. A `scene_apply` case (`scene.odin:123-202`): refuse with `log.warn` and `return true` (`:169-180`), fail only a fatal
   GPU error with `return false`; log the result like `object_build` does (`:331-333`).
5. `render.viewport_invalidate(&app.target)` when what is drawn changed without a buffer version bump (`scene.odin:266,
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
  `closest_on_triangle` (promote it from `simplify_test.odin`); picking through `scene_raycast` (`scene.odin:299-311`),
  which returns world-space hits, and `to_local`/`to_world` (`:32-33`).

## References (read when the task needs them)
- [references/algorithms.md](references/algorithms.md): boolean semantics worth copying (Manifold), voxel remesh as the
  fallback, QEM decimation already in `simplify.odin`, Loop stencils and boundary rules, plane trims, extrude/inset/bevel
  templates, and the checks-with-numbers recipe from the CAD skill repos.
- [references/undo-and-topology.md](references/undo-and-topology.md): the `Mesh_Swap` history entry design that makes
  topology-changing tools undoable, and why positions-only undo cannot cover them.
