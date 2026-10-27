---
name: sm-cad
description: CAD-style mesh tools inside this app on geom.Mesh — primitives, booleans and trims, extrude/inset/bevel, mirror, the voxel remesh (DynaMesh) and relax, measure (length, area, volume, bounds) — and the checklist a new tool must follow to plug in: a pure geom proc, a Scene_Command and panel button, what it does to the sculptor, undo, levels, HD, LOD, GPU buffers, tests with geom.mesh_check and the numbers it prints. Load for ANY task that adds or changes a modelling operation other than a brush, e.g. "add a cube primitive", "boolean union two objects", "cut the mesh with a plane", "mirror across X", "measure the volume", "add an extrude tool", "import or export OBJ". Requires sm-geom, sm-sculpt and sm-ui; implicit and SDF modelling is sm-sdf; NOT external CAD programs and NOT a parametric feature tree.
---

# CAD-style tools

## What exists today (so nothing is assumed)
- New objects are spheres (`object_build`), the other `geom.Primitive` shapes (cube and torus as grids, cylinder and cone as
  `geom.lathe` outlines voxel remeshed; `geom.primitive`, `src/geom/primitives.odin`, added by `scene_add_primitive`, the
  Scene tab's Add object shape and `--shape`) or meshes from a file (`scene_add_mesh`), and any
  mesh can become an object through `object_build_from(app, obj, mesh, start)` (`:462`).
- Starters (`geom.is_starter`: Head, Bust, Figure, Hand, Creature; `src/geom/starters.odin`) are ellipsoids and tapered
  sphere chains fused by `remesh_voxel_spacing` at a third of the thinnest part's radius, Taubin-relaxed, remeshed at
  the count (never coarser than half the thinnest radius) and relaxed again; never under `STARTER_MIN_VERTICES`. The app
  builds one with `object_make_primitive` (an object outside the scene) at `vertices >> 2k` and subdivides it k times
  (`starter_levels`). Menu > New scene is `.New_Scene` → `Scene_Command.New` → `scene_new`, which hands the object to
  `scene_replace` (shared with `scene_open`: build first, then free the old scene, clear the History, stop replay,
  timeline and time-lapse). Its guard is `new_scene_run`'s arm-then-confirm, as Settings' Reset everything.
- Files (`src/app/files.odin`, README "Files"): OBJ and PLY in and out (`geom.mesh_read_obj`, `mesh_read_ply`,
  `mesh_write_obj`, `mesh_write_ply`, `src/geom/mesh_file.odin`), an import cleanup (`mesh_clean`, `mesh_normalize`,
  `mesh_edges`, `mesh_flip`), and the native `.sculpt` scene (`scene_save`/`scene_open`, levels through
  `sculpt.levels_write`/`levels_read`). `Object.file` keeps where an import was in its file, for export. A new
  per-object field that should survive a save goes in both `scene_save` and `scene_open` with a `SCENE_VERSION` bump,
  and `scene_open` must keep reading the older versions. Every file action ends in one `file_note`.
- Binary glTF out (`geom.mesh_write_glb`, `src/geom/gltf_write.odin`, from `object_export` by the `.glb` name): the
  sculpt layers go as sparse morph targets (`sculpt.sculptor_layer_sparse`), the base written is the shown surface
  less each layer at `layer_weight`, colours linear, the JSON gets a slot sized for its bounds so the big arrays are
  written once, straight into `out`. A change to what an export writes is checked by a scripted run and
  `python scripts/export_check.py FILE.glb --vertices N --triangles N --keys "Layer 1=1.5,Layer 2=0" --colors`
  (the Khronos validator and a Blender import; `--setup` installs both into `build/export-tools`; a missing tool is
  SKIP, never PASS): e.g. `--script="new_layer; smooth_all; layer 1 1.5" --export=build/x.glb`. Blender reads the
  file Y up into Z up: compare it to an OBJ of the same run as `(x, z, -y)`.
- USD text out (`geom.mesh_write_usda`, `src/geom/usd_write.odin`, by the `.usda` name) takes the same `Mesh_Export`
  plus `quads`/`uvs`/`groups` (USD only). Layers are `BlendShape`s named by token (any UTF-8) with prims as sanitized
  identifiers; weights go as default AND a frame-1 time sample (Blender reads only time samples, clamps keys to 0-1);
  an empty shape still names one point (Blender drops a shape with no offsets). `export_check.py FILE.usda` runs
  USD's 30 validators (usd-core's `UsdValidation`) and Blender at frame 1. A `{` in an `fmt.sbprintf` format is
  `{{`: an unescaped one wrote `%!(MISSING ...)` into both writers once.
- Voxel remesh exists (README "Voxel remesh (DynaMesh)"): `geom.remesh_voxel(m, target, pool)` and
  `remesh_voxel_spacing(m, h, pool)` (`src/geom/remesh.odin:57, 68`) rebuild a mesh as an even, closed, manifold surface:
  winding-number rays along each axis decide inside, marching cubes with a rule-built table keeps ambiguous faces
  apart, three rounds of tangential relaxation even it out (`:11-29`); overlaps and self-intersections merge, anything
  thinner than the spacing goes; `REMESH_MAX_LATTICE 4096` per axis. Wired as `Scene_Command .Remesh` → `object_remesh`
  (`scene.odin:147-175`), Object > Shape > Rebuild's Even, Ctrl+R (at the object's own count) and the script `set rebuild_even N; rebuild`.
  The lattice has one definition: `mesh_area_bounds` (area and triangle box, fixed ranges summed in order, so serial,
  parallel and `mesh_area_parts` a few ranges at a time agree bit for bit) feeds `remesh_lattice(area, bounds, target)`
  (spacing with the 4096 clamp, origin `bounds.lo - 1.5 h`), and `remesh_run` takes that box. `object_remesh` measures
  the uncompacted level before compacting and calls `remesh_voxel_measured`, so Rebuild's density checkerboard
  (`src/app/rebuild.odin`) shows exactly the cells the remesh builds on; never compute a spacing another way.
- Decimate exists: `geom.mesh_decimate(m, triangles, pool)` (`src/geom/decimate.odin`) runs `simplify` with `strict = true`
  (no two corners of a triangle move in one pass, no needles, shorter edges first on ties) in parallel cell rounds
  (`DECIMATE_ROUND_KEEP`, shifted cells), then whole; wired as `Scene_Command .Decimate` → `object_decimate`, the Object
  tab's Decimate and the script `set rebuild_goal fewer; set rebuild_fewer N; rebuild`. The LOD copies keep the non-strict `simplify`.
- Mirror and weld exists: `geom.mesh_symmetrize(m, axis, keep_positive, pool)` (`src/geom/symmetrize.odin`) cuts at the
  axis plane (snapping vertices within 1e-5 of the size onto it), clips crossing triangles with cut points computed
  from the lower-numbered edge end so they weld bit-exactly in `mesh_clean`, mirrors with reversed winding. Wired as
  `Scene_Command .Symmetrize` → `object_symmetrize`, the Object tab's Mirror and weld, the script `set mirror_axis 0; mirror_weld`. Duplicate
  (`.Duplicate` → `scene_duplicate`, Ctrl+Shift+D) copies an object through `object_put`/`object_get`.
- Slice exists: `geom.mesh_slice(m, point, normal, close, pool)` (`src/geom/slice.odin`) splits along any plane into
  front (the normal's side) and back, caps each border loop (ear clipping, holes bridged) and evens the cap (longest
  edge bisection, Delaunay flips, guarded smoothing). Wired as `Scene_Command .Slice` → `object_slice` (front becomes
  a new object; both swaps undo as one through `History_Entry.chain`), the Slice gesture tool, the script verb `slice x|y|z`.
- Split and Merge exist (`src/app/split_merge.odin`, the Objects card's Actions): `geom.mesh_components` numbers
  connected pieces and `geom.mesh_split(m, part, count)` makes one mesh per part with `vertex_from`/`tri_from`
  (`src/geom/split.odin`, serial and deterministic). `object_split` follows `object_slice` (layers carried to every
  piece) and `merge_down`/`merge_visible` follow `boolean_make`; both keep polypaint and polygroups by building with
  `object_build_from(..., surface = Surface{color, groups})`, which asks `levels_init` for `tri_from` and calls
  `sculpt.levels_take_surface`. Merge numbers each source's groups densely after the ones before. `align_objects` and
  `distribute_objects` move positions only, one chained `history_record_transform` per moved object. Past the swap
  limit `history_record_swap` drops whole steps and never the newest, so a chained rebuild and delete undo together.
- Dynamic topology (sm-sculpt) splits and collapses edges under the brush; a tool reading a dynamic object's mesh takes
  `sculpt.sculptor_compact_mesh` first, as `object_remesh` does, since the paged layout has unused slots.
- There are no booleans or trims, `Transform` is position, uniform scale and Euler rotation in degrees (`transform_rotation`,
  `to_local`/`to_local_dir`; `Draw_Item.model` must stay a similarity, `src/render/renderer.odin:115-119`), no measurement or snapping. Undo
  stores positions or masks per node, or whole nodes under dynamic topology (`src/sculpt/undo.odin:9-15`); a whole-object
  rebuild (remesh, mirror and weld, dyntopo toggle, level deletion, add/delete/duplicate) is a swap entry in the app's
  `History` ([references/undo-and-topology.md](references/undo-and-topology.md)). The only field CSG is the SDF spike's smooth union (sm-sdf);
  `remesh_voxel` is the mesh-level union.

## Three kinds of tool, three plug-in paths
| Kind | Examples | Path |
|---|---|---|
| positions only, topology kept | mirror or symmetrise, relax or smooth all, taper, bend, snap to a surface | keep the sculptor: change `mesh.positions` for whole nodes (a vertex's node is `Level.node_of_vertex`, `src/sculpt/levels.odin:37`), then `sculpt.sculptor_nodes_moved(s, nodes)` (`src/sculpt/brush.odin:944-971`) so bounds, normals, LOD staleness and `edited` catch up and `levels_sync` carries it; upload through `object_show_level` (`scene.odin:354-376`). Undo: only dabs record today, so add a `sculptor_record_nodes(s, nodes)` that exposes `record_hit`/`record_changed` (`undo.odin`) between `sculptor_stroke_begin` and `sculptor_stroke_end`; the tool then is one stroke, and the cross-object `History` works unchanged (`src/app/history.odin:31-64`) |
| topology changes on an object | boolean, trim or slice, extrude, inset, bevel, decimate | copy `object_remesh` (`scene.odin:147-175`): `stroke_finish`, `object_hd_leave`, take the source (`sculptor_compact_mesh` when dynamic), build the new mesh and refuse with `log.warn` + `return true` if that fails, then `_ = sdl.WaitForGPUIdle`, `object_release_mesh` (history, GPU buffers and levels, `:482`) and `object_build_from` (`:462`). The caller in `scene_apply` makes it undoable: `before := history_snapshot(app, obj, "<what>")` first, then `history_record_swap(app, obj.id, before)` if it changed, else `history_snapshot_drop(before)` (`src/app/history.odin`; design in [references/undo-and-topology.md](references/undo-and-topology.md)) |
| a new object | cube, cylinder, torus, plane with options | a `geom.<primitive>(…, allocator)` builder shaped like `icosphere`, then `scene_add_mesh(app, mesh, name, file = {scale = 1}, t, start)` (`scene.odin:122`), as `scene_import` does (`src/app/files.odin:207`); place it with `next_free_position` (`scene.odin:422-429`) |

## Plug-in checklist (every item names the file to copy from)
1. Geometry in `src/geom/<tool>.odin`, pure: imports only `core:` and `../jobs`, `allocator := context.allocator` last,
   deterministic, returns `(…, ok)` or counts; parallel only through `jobs.parallel_ranges` with heap-allocated per-job
   scratch (sm-odin).
2. Output meets the sm-geom invariants: closed where levels will be built, consistently wound outward, no degenerate
   triangles, no unused vertices (`sculptor_init` asserts, `brush.odin:321`), normals recomputed or left to
   `sculptor_recompute_all`. Booleans want manifold inputs and give manifold outputs; the robust fallback is a voxel or
   SDF remesh ([references/algorithms.md](references/algorithms.md)).
3. A new `Scene_Command.kind` (`scene.odin:84-91`) with its fields; the panel sets `app.ui.scene_command = {kind = …}`
   (`src/app/kit_object.odin` and `kit_scene.odin`, the Remesh and Add buttons); it is applied at the next frame start
   (`src/app/main.odin`). Never mutate the scene from inside the layout (`kit_frame` and the `kit_*` sections).
4. A `scene_apply` case (`scene.odin:245-335`): refuse with `log.warn` and `return true` (`:298-313`), fail only a fatal
   GPU error with `return false`; log the result like `object_build` does (`:473-475`).
5. `render.viewport_invalidate(&app.target)` when what is drawn changed without a buffer version bump (`scene.odin:399,
   283`); a new `Mesh_Buffers` or `mesh_buffers_upload_ranges` bumps the version and forces a full redraw by itself.
6. Range uploads must stay within `vertex_capacity`; a tool that adds vertices recreates the buffers.
7. A shortcut only as a command and a binding in `src/app/commands.odin` (`COMMANDS`, `DEFAULT_BINDINGS`; off while `typing(app)`), and README "Controls"
   plus the tool's section text updated.
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
  `geom.closest_on_triangle` and `geom.bvh_closest` (`closest.odin`, Morton trees, exact with a hint); picking through `scene_raycast` (`scene.odin:432-444`),
  which returns world-space hits, and `to_local`/`to_world` (`:34-35`).

## References (read when the task needs them)
- [references/algorithms.md](references/algorithms.md): boolean semantics worth copying (Manifold), voxel remesh as the
  fallback, QEM decimation already in `simplify.odin`, Loop stencils and boundary rules, plane trims, extrude/inset/bevel
  templates, and the checks-with-numbers recipe from the CAD skill repos.
- [references/undo-and-topology.md](references/undo-and-topology.md): the swap history entry that makes
  topology-changing tools undoable, and why positions-only undo cannot cover them.
