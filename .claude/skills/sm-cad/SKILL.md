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
- Files (`src/app/files.odin`, README "Files"): OBJ, PLY and STL in and out (`geom.mesh_read_obj`, `mesh_read_ply`,
  `mesh_read_stl`, `mesh_write_*`, `src/geom/mesh_file.odin`; `mesh_file_kind` picks a `Mesh_Kind` by extension, or
  by the bytes for an Android content:// URI; `export_check.py FILE.stl` checks the layout and Blender's import), an
  import cleanup (`mesh_clean`, `mesh_normalize`, `mesh_edges`, `mesh_flip`), vertex colours in (`colors:
  ^[dynamic]geom.Vertex_Color` on the OBJ and PLY readers and `mesh_clean`, which carries them through the weld; the app
  hands them to `object_build_from` as `Surface.color`), several meshes a file (`geom.Mesh_Part`: mesh, colours,
  groups; `mesh_read_obj_parts` splits by `o` through `mesh_split` and groups by `g`, `mesh_read_gltf` in
  `geom/gltf_read.odin` makes a part per placed mesh; `src/usd` reads `.usda` (usda.odin), the `.usdc` crate (usdc.odin: LZ4, integer coding, ValueReps) and `.usdz` into a `Stage` whose Mesh prims `stage_parts` places, no composition followed; `src/fbx` reads FBX through ufbx and our shim (`fbx_shim.c`: Y up, metres, geometry-to-world baked, mirrored nodes turned round, `opts.file_format` forced to FBX since ufbx also reads OBJ), a part per mesh node; `mesh_parts_normalize` sizes them together and centres each per
  axis as `mesh_normalize` does; materials as polypaint: readers given a `geom.Mesh_Look` (`src/geom/mesh_look.odin`: materials' linear colours, borrowed image bytes) fill each part's per-triangle `materials` and per-corner `uvs` (v down from the image's top), the OBJ reader through `obj_look`/`mtl_read` and a `Mesh_Resolve` for files beside it, and `mesh_parts_paint` bakes them into `colors` and drops them BEFORE `mesh_clean`, which knows nothing of corners; past `MESH_PARTS_MAX` `mesh_parts_merge` makes one with a group a part; the app's
  `mesh_file_parse` cleans each part and `import_add_parts` makes an object each in a folder, one undo step: chained
  swaps, then `history_record_arrange(chain = true)` with the layout taken before the folder), and the native `.sculpt` scene (`scene_save`/`scene_open`, levels through
  `sculpt.levels_write`/`levels_read`). `Object.file` keeps where an import was in its file, for export. A new
  per-object field that should survive a save goes in both `scene_save` and `scene_open` with a `SCENE_VERSION` bump,
  and `scene_open` must keep reading the older versions. Every file action ends in one `file_note`. Since v22 the
  header's first field is the preview block (`scene_preview.odin`: `preview_block_put`/`preview_block_skip`,
  `scene_preview_read` reads only the file's start through SDL IO); new header fields go after it, never before.
- Binary glTF out (`geom.mesh_write_glb`, `src/geom/gltf_write.odin`, from `object_export` by the `.glb` name): the
  sculpt layers go as sparse morph targets (`sculpt.sculptor_layer_sparse`), the base written is the shown surface
  less each layer at `layer_weight`, colours linear, the JSON gets a slot sized for its bounds so the big arrays are
  written once, straight into `out`. A change to what an export writes is checked by a scripted run and
  `python scripts/export_check.py FILE.glb --vertices N --triangles N --keys "Layer 1=1.5,Layer 2=0" --colors --material "Gold,1,0.3"`
  (the Khronos validator and a Blender import; `--setup` installs both into `build/export-tools`; a missing tool is
  SKIP, never PASS): e.g. `--script="new_layer; smooth_all; layer 1 1.5" --export=build/x.glb`. Blender reads the
  file Y up into Z up: compare it to an OBJ of the same run as `(x, z, -y)`.
- USD text out (`geom.mesh_write_usda`, `src/geom/usd_write.odin`, by the `.usda` name) takes the same `Mesh_Export`
  plus `quads`/`uvs`/`groups` (USD only); `Mesh_Export.material` (`app.export_material`) goes as a glTF material and a
  bound UsdPreviewSurface, its diffuse reading `displayColor` when painted (paint is then composed over the material colour). Layers are `BlendShape`s named by token (any UTF-8) with prims as sanitized
  identifiers; weights go as default AND a frame-1 time sample (Blender reads only time samples, clamps keys to 0-1);
  an empty shape still names one point (Blender drops a shape with no offsets). `export_check.py FILE.usda` runs
  USD's 30 validators (usd-core's `UsdValidation`) and Blender at frame 1. A `{` in an `fmt.sbprintf` format is
  `{{`: an unescaped one wrote `%!(MISSING ...)` into both writers once.
- Group materials in exports (`app.export_group_materials`): `Mesh_Export.group_materials` + `face_material` (a slot a
  written face, 0 the object's) make glTF one primitive a used slot (every primitive repeats the targets: the mesh's
  weights are for all) and USD a `materialBind` partition of GeomSubsets, slot 0 included, because Blender's importer
  gives faces in no subset the FIRST subset's material, not the mesh binding. Painted: glTF copies seam vertices
  (`geom.mesh_export_split_materials`, morph entries appended for the copies), USD writes `corner_colors` faceVarying.
  Check with `export_check.py FILE --face-materials "Gold=13778,Steel=55112"` (faces a material, by name).
- Lights in exports (`app.export_lights`, `Mesh_Export.lights`, `geom.export_light_place`): glTF KHR_lights_punctual
  (lux / candela in the mesh's units, the writer scales candela by scale²), USD DistantLight / SphereLight treatAsPoint
  (+ ShapingAPI). USD intensities undo Blender's USD importer (sun x4, point x pi) so both formats import with the same
  watts; a sun of strength 1 is pi*683 lux. Check with `export_check.py FILE --lights "SUN=3.1416,SPOT=290.17"`.
  The Blender link sends the same lights in world space as `light` lines of link.txt (`link_manifest_text`); the
  add-on's `set_lights` makes them in a "Sculpt lights" collection; `scripts/link_check.py` checks them in bpy.
  `Export_Light.size` (a sun's angle across in radians, a lamp's radius) goes as the link line's 17th word (Blender's
  `angle` / `shadow_soft_size`) and as a USD DistantLight's `inputs:angle` in degrees (UsdLux: across; Blender reads
  it as half); never a SphereLight radius (USD intensity is per area) and never in glTF (no field).
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
  `remesh_voxel_measured` caps an open mesh's holes before the rays (`mesh_edges_paired` tells, a wrapping hash sum
  over the directed edges, then `mesh_fix` when they do not pair, since a doubled or turned triangle puts the
  winding behind it out by two and hides the holes, then `mesh_close_holes`), so open parts never depend on the rays' direction; its
  `Remesh_Options` (Smooth rounds, Keep detail = projection back within a cell with the old triangle per vertex in the
  `Remesh_Report`, Groups = `mesh_split` by polygroup, each piece on its own lattice-snapped box, `mesh_join`) come from
  the app's `Remesh_Setup` in the `Scene_Command` (`src/app/remesh.odin`), and `remesh_surface` there carries polypaint
  and polygroups through the report onto the rebuilt object (on the long job's thread via `levels_take_surface`).
  `Remesh_Options.quads` builds the marching cubes' dual instead (`dual_cells`: a vertex per surface patch through a
  cell, a quad per crossing, `relax_quads`, two triangles a quad in `Remesh_Report.quads`), and `remesh_take_quads`
  (`src/app/remesh.odin`) keeps them on the base level as `Polys` under `.Smooth` plus `levels_set_quads`, through
  `levels_init`'s `old_to_new` and `tri_from`, on either thread. The marching cubes face rule turns on a face both cells'
  patches would thread twice (`cell_flips`, a crevice thinner than a cell): never make the loops from a static table
  alone, `mc_case_loops(case, flips)` is the one source for the table and the turned cells.
  `python scripts/remesh_check.py [--stability]` runs Remesh, Remesh with Quads and Quad Remesh over twelve fixtures
  (open, overlapping, non-manifold, doubled, flipped, NaN among them) in the debug app and judges each against the plan's
  acceptance (`build/remesh_check/report.md`): run it after any change to `remesh.odin`, `src/retopo` or `quadmesh`.
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
  Knife (`Scene_Command .Knife` → `object_knife`) is the same cut keeping only `back` (destroys `front` at once) and
  rebuilding through `object_rebuild` as Mirror and weld does: one swap step, layers carried; script `knife x|-x|...`.
- Mesh repair exists (`src/geom/repair.odin`, Object > Shape > Modify topology, `src/app/repair.odin`): `mesh_close_holes`
  (loops from `border_edges`, back-facing spikes trimmed first, ear clip + slice.odin's `cap_even` along the loop's
  Newell normal, then `cap_settle` raises the new vertices to a membrane by SOR; a loop that crosses itself seen flat
  is fanned), `mesh_weld_points` (cells twice the distance, eight looked up through a radix-sorted `Run_Table`),
  `mesh_fix` (drop broken and duplicate triangles, `orient` piece by piece, turn inward closed pieces) and
  `mesh_integrity` (mesh_check's counts in parallel plus holes, pieces, duplicates, loose vertices; equal to
  `mesh_check`, tested). Each returns a `Repair_Map` (`vertex_from`, `tri_from`, `REPAIR_NEW + k` for cap k) that
  `repair_surface` turns into polypaint and polygroups for `object_rebuild(..., surface)`. All are `Scene_Command
  .Repair` with a `Repair_Kind`, except Check mesh, which changes nothing and runs from its command at once (a
  script statement that leaves the scene unchanged fails). Delete hidden is `object_split(.Hidden, keep_parts = false)`.
- Split and Merge exist (`src/app/split_merge.odin`, the Objects card's Actions): `geom.mesh_components` numbers
  connected pieces and `geom.mesh_split(m, part, count)` makes one mesh per part with `vertex_from`/`tri_from`
  (`src/geom/split.odin`, serial and deterministic). `object_split` follows `object_slice` (layers carried to every
  piece) and `merge_down`/`merge_visible` follow `boolean_make` (whose voxel-base branch runs on the field, sm-sdf); both keep polypaint and polygroups by building with
  `object_build_from(..., surface = Surface{color, groups})`, which asks `levels_init` for `tri_from` and calls
  `sculpt.levels_take_surface`. Merge numbers each source's groups densely after the ones before. `align_objects` and
  `distribute_objects` move positions only, one chained `history_record_transform` per moved object. Past the swap
  limit `history_record_swap` drops whole steps and never the newest, so a chained rebuild and delete undo together.
- Quad Remesh's engine is `src/quadmesh` (sm-geom): AutoRemesher's core behind a C boundary, `quadmesh.remesh(positions, indices, params, progress, share, allocator) -> (Polygon_Mesh, Report, Error, reason)`, nearly all quads with 95 %+ regular vertices, bit-identical for any thread count, desktops only (`AVAILABLE`). Quad Remesh (the work in `src/retopo`, `retopo.compute` returning a `retopo.Result`; the object made from it in `src/app/retopo.odin`; scene command `.Retopo`, command `.Retopologize`, script `retopologize`) runs it by default (`retopo.Engine.Auto`, `app.ui.retopo_engine`, carried in `Scene_Command.engine` so the job thread reads no UI): decimate past `QUAD_REMESH_MAX_TRIANGLES`, `mesh_integrity` refuses non-manifold, flipped, degenerate, duplicate, NaN or fragmented input, then `polygon_mesh_triangulate` (quads along the shorter diagonal, n-gons as fans, unused vertices dropped) and the base level keeps the polygons through `levels_set_polys(..., .Smooth)` after `retopo.polys_renumber` with `levels_init`'s `old_to_new` and `tri_from` (`scene_add_mesh(..., tri_from)`); a refusal or failure falls back to the own `geom.mesh_retopo` (`.Own`, the Built-in tab) with the reason in the result line.
- Dynamic topology (sm-sculpt) splits and collapses edges under the brush; a tool reading a dynamic object's mesh takes
  `sculpt.sculptor_compact_mesh` first, as `object_remesh` does, since the paged layout has unused slots.
- There are no booleans or trims, `Transform` is position, uniform scale and Euler rotation in degrees (`transform_rotation`,
  `to_local`/`to_local_dir`; `Draw_Item.model` must stay a similarity, `src/render/renderer.odin:115-119`), no measurement or snapping. Undo
  stores positions or masks per node, or whole nodes under dynamic topology (`src/sculpt/undo.odin:9-15`); a whole-object
  rebuild (remesh, mirror and weld, dyntopo toggle, level deletion, add/delete/duplicate) is a swap entry in the app's
  `History` ([references/undo-and-topology.md](references/undo-and-topology.md)). The only field CSG is the voxel booleans' smooth minimum (`clay_combine`, sm-sdf);
  `remesh_voxel` is the mesh-level union.

## Three kinds of tool, three plug-in paths
| Kind | Examples | Path |
|---|---|---|
| positions only, topology kept | mirror or symmetrise, relax or smooth all, taper, bend, snap to a surface | keep the sculptor: change `mesh.positions` for whole nodes (a vertex's node is `Level.node_of_vertex`, `src/sculpt/levels.odin:37`), then `sculpt.sculptor_nodes_moved(s, nodes)` (`src/sculpt/brush.odin:944-971`) so bounds, normals, LOD staleness and `edited` catch up and `levels_sync` carries it; upload through `object_show_level` (`scene.odin:354-376`). Undo: only dabs record today, so add a `sculptor_record_nodes(s, nodes)` that exposes `record_hit`/`record_changed` (`undo.odin`) between `sculptor_stroke_begin` and `sculptor_stroke_end`; the tool then is one stroke, and the cross-object `History` works unchanged (`src/app/history.odin:31-64`) |
| topology changes on an object | boolean, trim or slice, extrude, inset, bevel, decimate | copy `object_remesh` (`scene.odin:147-175`): `stroke_finish`, `object_hd_leave`, take the source (`sculptor_compact_mesh` when dynamic), build the new mesh and refuse with `log.warn` + `return true` if that fails, then `_ = sdl.render.wait_idle`, `object_release_mesh` (history, GPU buffers and levels, `:482`) and `object_build_from` (`:462`). The caller in `scene_apply` makes it undoable: `before := history_snapshot(app, obj, "<what>")` first, then `history_record_swap(app, obj.id, before)` if it changed, else `history_snapshot_drop(before)` (`src/app/history.odin`; design in [references/undo-and-topology.md](references/undo-and-topology.md)) |
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
11. A tool that takes seconds at 2M+ runs as a long job (`src/app/long_job.odin`): split its object proc into a pure
    compute half (takes `progress: ^jobs.Progress = nil`, moves it at fixed stage shares, returns not built at the next
    check after `progress_cancelled`) and an apply half (`remesh_apply`, `retopo_apply`); add its kind to
    `long_job_async`'s cases, `JOB_VERBS`, `JOB_NOUNS` and `JOB_BUTTONS`; scripted runs stay inline, `--async-jobs`
    forces the job. A result made in place gets a beside-it builder instead (`levels_subdivide_build` + `_add`,
    `clay_resampled`), reading the object only; a new mesh is prepared on the thread (`long_job_prepare`).

## Measure
- Edge length and area from positions; bounds from `geom.Aabb`/`aabb_grow` (`src/geom/bvh.odin:9-20`); signed volume
  Σ p0·(p1×p2)/6, meaningful only for a closed, outward mesh (`mesh_check` gives it); distance to the surface through
  `geom.closest_on_triangle` and `geom.bvh_closest` (`closest.odin`, Morton trees, exact with a hint); picking through `scene_raycast` (`scene.odin:432-444`),
  which returns world-space hits, and `to_local`/`to_world` (`:34-35`).
- Print sizes (`src/app/print.odin`): one scene-wide `Scene.print_mm` (millimetres per world unit, saved since scene
  v23; read it through `print_scale`, which covers a zero App in tests) times `object_world_bounds`. Export for
  printing (`object_export(..., print = true)`) bakes the placement and the scale into one matrix, turns Y up into Z up
  as `(x, -z, y)`, stands the mesh on Z 0 centred on the origin, and reports `mesh_check_indices` (closed, volume in
  cm³) up to `PRINT_CHECK_MAX` indices, as STL or OBJ; the plain STL export keeps the file's own units instead.
  `print_export` takes `print_objects` (the selection, or every shown object): one object goes through
  `object_export`, more (or any 3MF) through `print_export_many`, which stands all parts on the bed together
  (`print_world` then `print_stand`); 3MF is `geom.mesh_write_3mf_model` zipped with `zip.write` (check a change with
  lib3mf's strict reader: `pip download lib3mf` works from the container).
  The Export sheet's Decimate for this file only travels as `Export_Once` (`export_once_of`, set by `export_run`
  for the dialog's answer, which carries the sheet bit in its userdata): `object_export` and `print_export_many`
  decimate a copy with `geom.mesh_decimate(..., from = &from)` and carry each kept vertex's paint, shape-key deltas
  (`sparse_keep`) and groups through `from`; the object is never touched, so no undo entry. Hollow (`Export_Once.hollow`,
  millimetres) runs `print_hollow` on the print's millimetre positions: `voxel.hollow_inner` voxelises a copy with voxels
  of wall / `HOLLOW_DEPTH`, turns Inside tiles beside the band into bricks and repairs them (else the new surface hits a
  tile's clamp at a brick face, up to two voxels off), shifts every band value by the depth and meshes the zero, flipped.
  The Export sheet's print checks (`print_checks.odin`) key their cache on the object's buffer version, reuse the
  sculptor's `bvh` at once up to `PRINT_CHECK_AT_ONCE` triangles and above it run on their own thread from a copy
  with `context.allocator` set to the heap (a slice freed by `bvh_destroy` must come from the allocator it frees with).

## References (read when the task needs them)
- [references/algorithms.md](references/algorithms.md): boolean semantics worth copying (Manifold), voxel remesh as the
  fallback, QEM decimation already in `simplify.odin`, Loop stencils and boundary rules, plane trims, extrude/inset/bevel
  templates, and the checks-with-numbers recipe from the CAD skill repos.
- [references/undo-and-topology.md](references/undo-and-topology.md): the swap history entry that makes
  topology-changing tools undoable, and why positions-only undo cannot cover them.
