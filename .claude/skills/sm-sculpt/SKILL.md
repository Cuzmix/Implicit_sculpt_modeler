---
name: sm-sculpt
description: Sculpting in src/sculpt and the app's brush tool — the Sculptor's nodes (BVH leaves owning contiguous vertex ranges), the nine brushes (Draw, Smooth, Clay, Flatten, Inflate, Pinch, Crease, Grab, Mask), masking, X/Y/Z symmetry, dynamic topology, apply_dab and sculptor_flush, dirty ranges for upload, deferred normals and normal cones, per-node stroke undo, subdivision levels (Loop, detail in local frames, sync up and down), HD detail windows, simplified copies between strokes, and the app side: stroke sampling, dab spacing, pressure and pen tilt, lazy mouse, the cross-object History and Scene_Command. Load for ANY task that changes how a brush moves vertices or what happens around a stroke, e.g. "add a brush kind", "the mask leaks", "symmetry is off", "undo is wrong", "the levels drift", "HD window border", "dabs skip at high speed", "move vertices from a tool", "make this undoable". Requires sm-geom and sm-build; GPU upload is sm-render; panels are sm-ui; ZBrush is the behaviour model.
---

# Sculpting

## Model (README: "Subdivision levels", "HD detail", "Controls", "Benchmark")
- `Sculptor` (`src/sculpt/brush.odin:113-164`): `mesh ^geom.Mesh`, `pool`, `faces`, `bvh`, `nodes []Node`, `chunks
  []geom.Chunk` (per node, kept current by the flush), `node_of` (BVH leaf → node id), `shared`/`owners`, per-dab scratch,
  `stale`/`dirty_nodes`, `cone_waiting`/`waiting_cones`, `ranges`, `changed_bounds`, `edited`/`edited_nodes`, `history`,
  `lod`, `fade []u8` (0 = never moves). `Node{tri_first, tri_count, vert_first, vert_count, shared_*, owner_*, leaf}`
  (`:79-89`): each node alone writes its owned, contiguous vertex range; a shared vertex belongs to the lowest node id.
- Constants with their reasons (`:23-32`): `NODE_TRIANGLES 1024`, `PARALLEL_MIN_VERTS 2048` (waking workers costs more
  than less work), `MAX_CACHED_FACES 4096`, `CONE_BATCH 512` (cones held back during a stroke, worked off per flush).
- `sculptor_init(s, mesh, pool, node_triangles, old_to_new)` partitions and renumbers the mesh in place; vertex and
  triangle order change (`:166`).
- `Brush{kind, radius (world units), strength 0..1, invert, symmetry, detail, collapse, tilt}` (`:55-69`; `detail`/`collapse`
  are dynamic topology's; `tilt` is a rotation of the area normal from a leaning pen, zero for none); `falloff` is `(1 − x²)²` over the squared distance in radii (`:505-509`). Strengths with
  their reasons: `DRAW_HEIGHT 0.1` radii, `CLAY_HEIGHT 0.08`, `PLANE_RATE 0.5`, `PINCH_RATE 0.25`, `CREASE_PINCH 0.2`
  (`:72-77`).
- The nine kinds, in key order 1–9 (`Brush_Kind`, `:34-44`; README "Brushes, masking and symmetry" has the user's view):
  | Kind | Moves | Inverted |
  |---|---|---|
  | Draw | out along the area-weighted average normal by `radius · strength · DRAW_HEIGHT` | in |
  | Smooth | one Jacobi step toward the neighbour mean (`job_smooth_targets`/`_apply`) | — |
  | Clay | toward a plane `CLAY_HEIGHT` radii above the surface; only vertices below it, capped at it | digs |
  | Flatten | toward the plane through the falloff-weighted centre | pushes away |
  | Inflate | each vertex along its own normal | deflates |
  | Pinch | along the surface toward the centre | pushes away |
  | Crease | in, with a narrow falloff (w²), and pinches | a ridge |
  | Grab | drags with the pointer, once per stroke (`grab.odin`, below) | — |
  | Mask | paints the mask (`mask.odin`, below) | erases |
- `apply_dab(s, brush, center)` (`brush.odin:529-540`) returns 0 for Grab, else runs `dab_once` at every mirror image:
  `mirrors(symmetry)` gives `{1,1,1}` then the sign flips, up to 8 (`brush.odin:544-556`); each image gets the tilt
  mirrored too (`S·R·S`: element `[i, j]` times `sign[i]·sign[j]`, `brush.odin:536`). `dab_once` (`brush.odin:568-644`):
  `bvh_query_leaves` → dynamic topology first when on (the bullet below) → Mask returns `mask_dab` → otherwise
  `record_hit` when recording → `job_area` (falloff-weighted normal and centre: `d.normal`, `d.plane`, the normal then
  turned by `tilt` (`brush.odin:605`), so Draw, Clay, Flatten, Pinch and Crease lean with the pen; not for Smooth,
  `brush.odin:741`) → the kind's `job_*` → `finish_move` (`brush.odin:649-666`: `mark_shape_changed`, `record_changed`, `job_hit_bounds`,
  `bvh_refit_leaves(recompute_leaves = false)`). Returns how many vertices moved; positions and BVH bounds are current when
  it returns, normals catch up in the flush.
- Each moving kind's `job_*` is a one-line call to `displace(d, i, $K)` (`brush.odin:773`), specialised per kind with `when`, so the
  vertex loop never branches on the kind; the weight is `falloff(d² / r²) · shield(fade, mask, v)` (`shield`, `brush.odin:560`:
  HD fade × (255 − mask) / 255).
- Grab (`src/sculpt/grab.odin`): `sculptor_grab_begin(s, brush, center)` gathers the leaves at every mirror image, saves
  them for undo once (`record_hit`), stores start positions and a per-vertex, per-axis follow weight (the signed sum of
  falloffs over the images, times `shield`) (`:34`); `sculptor_grab_move(s, offset)` sets `start + offset · follow`,
  absolute rather than incremental, then `finish_move` (`:98`); `sculptor_grab_end` (`:124`, called by `stroke_finish`).
- Mask (`src/sculpt/mask.odin`): `Sculptor.mask []u8` per vertex, nil until first used, 255 = brushes leave the vertex
  alone. `mask_dab` (`:21`) paints by `255 · strength · falloff · fade`, marks nodes stale `.Paint` (GPU data only, no
  normal recompute) and records them as `painted`; `sculptor_mask_command(s, .Clear | .Invert | .Fill)` is one undo step
  (`:67`); `levels_carry_mask` copies it to the level being shown (`:129`); an HD window starts unmasked and its mask is
  dropped when it closes. On the GPU the mask rides in the low 4 bits of each normal half (`geom.oct_encode_masked`, sm-render).
- `sculptor_flush(s)` (`brush.odin:437-500`): once a frame before uploading. Sorts `dirty_nodes`, recomputes normals per node
  (Shape: all of them; Edge: only the border vertices), leaves a changed chunk's cone open during a stroke and works the
  waiting cones off `CONE_BATCH` per flush afterwards, sets `changed_bounds` (before and after), and returns coalesced,
  sorted `Vertex_Range`s valid until the next call.
- Other entry points: `sculptor_nodes_moved(s, nodes)` after owned positions changed outside a dab (`brush.odin:895-922`);
  `sculptor_recompute_all` for a mesh that arrived without normals (`brush.odin:924`); `sculptor_clear_edited` once levels carried
  the edits (`brush.odin:931`); `sculptor_raycast`; the brute-force `raycast` for tests.
- Undo (`src/sculpt/undo.odin`): one step per stroke; a node's owned positions (12 B a vertex) or, for mask strokes, its
  masks (1 B) are copied the first time the stroke touches it, and nothing for the rest (`:9-15`). `Undo_Step{nodes,
  painted}` lists node ids (`:32`); `Saved_Node{node, positions | masks, full, indices, …}` (`:42`), where `full` entries
  are dynamic topology's whole-node saves. `record_hit(s, masks)` (`:171`) picks `record_mask`, `record_full` (dynamic)
  or positions. Undo and redo swap in place (`step_move`, `:134`); `UNDO_LIMIT_BYTES = 512 << 20` drops the oldest steps
  but always keeps the newest (`:53`); a stroke that moved and painted nothing is not a step (`:100`).
- Levels (`src/sculpt/levels.odin`): a base mesh and finer copies, each one Loop step above the one below, every level a
  whole mesh with its own sculptor; only the current level is shown and sculpted (`:12-25`). `MAX_LEVELS 8`; `Level{mesh,
  sculptor, node_of_vertex, parents [4]u32, detail Vec3, even_of, deps, dependents}` (`:34-44`); detail is an offset in a
  frame that turns with the surface below. `levels_set_current` asserts no HD window and syncs first (`:92-99`);
  `levels_subdivide` returns false at `MAX_LEVELS`, with an HD level, or on an open mesh (`:101-113`);
  `levels_subdivide_estimate` (`:138`); `levels_delete_higher/lower` (`:154-172`). `levels_sync` has three phases: push
  the edit down as moves of the vertices below, re-encode detail, rebuild the levels above (`:202-228`). `frame_at` and
  `frame_point` are `#force_no_inline` so every level decodes the same bits.
- HD (`src/sculpt/hd.odin:13-31`): detail `steps` Loop steps above the top level, stored per top-level node and only for
  sculpted nodes; sculpted one window at a time (`levels_hd_enter`: the nearest top-level nodes up to a vertex budget,
  with their stored detail, as a level like any other); the window border never moves and brushes fade toward it over
  `HD_FADE_EDGES = 8` edges; `levels_hd_leave` stores what changed. `HD_MAX_STEPS 3`, `HD_WINDOW_VERTICES 4_000_000`
  (`:33-37`); `levels_hd_set_steps` refuses while detail is stored, a window is open or the top level is not closed (`:73-91`).
- Simplified copies (`src/sculpt/lod.odin:10-18`): chunks grouped along the BVH; each group holds a copy of about a quarter
  of the triangles under it with its border vertices kept; a stale group is never drawn, only its children. Constants
  `:21-37`; `sculptor_lod_update` does nothing during a stroke and builds lowest groups first within `LOD_FRAME_BUDGET`
  (`:151-187`); `sculptor_lod_pending`.
- Dynamic topology (`src/sculpt/dyntopo.odin`, README "Dynamic topology"): `Sculptor.dyn` is non-nil while it is on.
  Node id = page: node `id` owns vertex slots `id * DYN_PAGE_VERTS` (1280) and triangle slots `id * DYN_PAGE_TRIS`
  (2048) and uses the first `vert_count`/`tri_count`; unused triangle slots are (0,0,0); `vert_page`/`tri_page` map a
  slot to its node. Per-vertex triangle lists replace `s.faces` (`dyn_faces`, up to `DYN_FACES` 16) and per-node
  `dyn.shared`/`dyn.owners` replace the flat lists; go through `faces_of`, `tri_node`, `node_shared`, `node_owners`
  (`brush.odin`), which work in both layouts. `dab_once` calls `dyn_dab_topology` before moving anything when
  `brush.detail > 0` (detail size = `radius * detail`; collapse below 0.4 of it): longest-edge (Rivara) splits, then
  guarded collapses, at most `DYN_MAX_SPLITS`/`DYN_MAX_COLLAPSES` (2048) a dab; a full page splits its node
  (`split_node`, renumbering vertices); `after_edits` refreshes shared lists and bounds and rebuilds the BVH
  (`geom.bvh_build_over`, `tri_order` nil: leaves are runs of ids) or refits it. Undo saves whole nodes (`record_full`,
  called through `touch` before any edit) and `dyn_step_swap` swaps them. The flush also fills `sculptor_index_ranges`
  (whole changed pages) for the app to upload. `sculptor_vertex_count`/`triangle_count` count used slots; the mesh's
  array lengths do not. `sculptor_dyn_enable/disable` (levels: `levels_dyn_enable/disable`, single level, no HD);
  `sculptor_compact_mesh` gives the plain mesh. No LOD copies while on. Open surfaces work: `split_edge` splits a
  border edge's one triangle (`split_border_edge`), `collapse_edge` refuses when either end is on the border
  (`on_border`) or when its worst triangle would get worse and stay under `DYN_MIN_QUALITY` (0.3, `triangle_quality`
  = 2√3·|cross|/Σ|e|²); enable is refused on non-manifold or inconsistently wound edges (`edges_manifold`).
- Levels in files (`src/sculpt/levels_file.odin`): `levels_write`/`levels_read` store every level as positions, the
  base in its own order and each level above in `level_canon` order (vertices continuing the level below at their
  places, then edge vertices by their ends' places, counted rather than sorted), since `sculptor_init` renumbers on
  every build. Reading subdivides, moves the vertices where they were and encodes the detail again
  (`recode_level(encode = true)`); HD detail is not stored (it follows node numbers), only the HD steps. A damaged
  file returns false, never asserts.
- App side (`src/app/sculpt_tool.odin`): `Brush_Settings` with the radius in pixels, `symmetry`, `detail_px`, `collapse`
  (`:13-27`); `Input_Sample{pos, pressure, kind, tilt}`, every motion event of a frame kept (`:29-44`); `DAB_SPACING 0.25`
  radii, `MIN_DAB_SPACING_PX 1`, `MAX_DABS_PER_FRAME 64`, `MAX_PENDING_SAMPLES 4096`, `MAX_BRUSH_MS_PER_FRAME 10`
  (`:65-72`); `sculpt_frame` → `stroke_follow` (lazy mouse `:160-166`; leftovers go to `pending` `:167-172`) →
  `stroke_start` (`scene_raycast`, select, `sculptor_stroke_begin`, first dab, or `sculptor_grab_begin` for Grab, `:179`)
  → `stroke_walk` (a dab every spacing pixels until the dab or time budget runs out, `:234-257`) → `stroke_dab`
  (`sculptor_raycast` in local space; a miss is skipped, `:263`). Grab instead follows only the frame's last sample
  (`grab_follow`, `:209`: the pointer ray meets the plane through the anchor that faces the camera, the offset is divided
  by the object's scale). `brush_at` turns pixels into world units at the hit's distance, divides by the object's scale,
  maps pressure through the pressure curve (`pressure_curved`, `:306`, `geom.curve_at`), turns the pen's lean into
  `tilt` with `camera.orbit_tilt` when the Tilt slider is above 0, passes `symmetry`, and makes `detail` a share of the radius (`:281-298`). Symmetry planes go through the mesh's local
  origin; X toggles X. `History` orders strokes and mask commands across objects and levels, newest last, `HD_LEVEL =
  -1`; undoing a stroke from another level switches to it first (`src/app/history.odin:5-20, 69-83`); `stroke_finish`
  ends Grab and records the stroke (`:29`), `mask_command` records a mask command (`:39`). `Scene_Command` kinds and
  `scene_apply` (`src/app/scene.odin:84-91, 245`).

## Rules that bite
- Every position change goes through `apply_dab` or `sculptor_nodes_moved`; otherwise BVH bounds, normals, chunks, LOD
  staleness and `edited` drift apart (tests `incremental_updates_match_full_recompute`, `flush_leaves_no_stale_normal`,
  `synced_levels_stay_consistent`).
- Call `sculptor_flush` once per frame per visible level and upload what it returns (`src/app/main.odin:413-422`).
- `stroke_finish` before any level, HD or scene change (`scene.odin:292, 386, 410`); leave the HD window before
  `levels_set_current` or a delete (the asserts at `levels.odin:93, 131, 139`).
- A new `Brush_Kind`: a `when` branch in `displace` and a one-line `job_*` (or its own pair, as Smooth), a case in
  `dab_once`'s switch, weights through `shield` so the mask and the HD fade hold, a name in `BRUSH_NAMES`/`BRUSH_HELP`
  (`src/app/ui.odin`, and its key follows the enum order), a test that proves what it moves, and a place in
  `new_brushes_parallel_match_serial` (`brushes_test.odin`), which compares serial with parallel bit for bit.
- Strokes undo per node: a tool that moves nodes without recording them breaks undo (sm-cad has the plan).
- With dynamic topology the triangles change during a stroke by design; everything else about a topology change
  (end the stroke, leave HD, clear the history, recreate the GPU buffers) happens when it is turned on or off
  (`object_set_dyntopo`). The app uploads changed index pages with `level_upload`, which remakes the buffers when the
  pages outgrow them. Never read `len(mesh.positions)` as a vertex count on a dynamic object.
- Simplified copies are never built during a stroke (`main.odin:422-423`, `lod.odin:164`); the brush works in the
  object's local space (`scene.odin:14-16`), symmetry included.
- A mask-only change is stale `.Paint`: it re-uploads the node's vertices without recomputing normals; pass
  `sculptor.mask` to every `mesh_buffers_create`/`upload_ranges`, or the mask vanishes from the screen (sm-render).

## Traps
| You might expect | What happens |
|---|---|
| a sample off the surface ends the stroke | it is skipped; the stroke resumes where the path meets the surface again (`sculpt_tool.odin:259-262`) |
| every Ctrl+Z undoes a stroke | entries whose step the byte limit dropped are skipped silently (`history.odin:71-75`) |
| HD strokes stay in the history | closing the window forgets them (`object_hd_leave`, `scene.odin:408`); Delete higher/lower, Remesh and turning dynamic topology on or off clear the object's history (`:322, 328, 484`; `object_set_dyntopo` `:180`) |
| Shift smooths only the Draw brush | Shift turns any kind into Smooth, Grab and Mask included (`brush_at`) |
| the mask stops the Mask brush | it does not: the Mask brush is weighted by falloff and HD fade only, so it can erase |
| a mirrored dab is one dab | each image is a full `dab_once` (its own query, jobs and, with dynamic topology, splits); all land in the same undo step |
| Grab moves by each frame's delta | it sets `start + offset · follow` from the grab's start, so frames never accumulate error |
| a `fade == 0` vertex moves a little | never: an HD window's border meets the level drawn around it |
| `sculptor_lod_update` returns ranges mid-stroke | nothing while `history.recording` (`lod.odin:164`) |
| more than 64 dabs land in one frame | the rest of the path waits for the next frame; a lagging stroke drops its oldest samples past 4096 |
| a frame lays every dab its samples ask for | it stops once its dabs have taken `MAX_BRUSH_MS_PER_FRAME` (10 ms), as heavy dynamic topology can; the rest waits |
| a split edge's opposite vertex can sit on it | splits bisect each triangle across its longest side, so slivers never form; `dyn_long_stroke_keeps_a_clean_surface` checks angles and folds |

## Tests
- Brushes: `brushes_test.odin` (`sphere_make(subdiv, pool)` with nodes of 64, `top_vertex`, `mirror_map`); one test per
  kind, `symmetric_dabs_mirror`, `grab_drags_by_the_offset`, `mask_shields_vertices`, `mask_undo_and_upload`,
  `mask_follows_levels`, and `new_brushes_parallel_match_serial`.
- Fixtures: `sculptor_init(&s, &m, nil, 64)` for small nodes; `levels_make(subdiv, steps, pool)` (`levels_test.odin`),
  `hd_make` (`hd_test.odin`), `lod_sphere(…, min_triangles = 0)` (`lod_test.odin`); `snapshot`/`expect_state`
  (`undo_test.odin`); `expect_decoded` (`levels_test.odin`). `build.bat test` runs sculpt third.
