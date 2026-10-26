---
name: sm-sculpt
description: Sculpting in src/sculpt and the app's brush tool — the Sculptor's nodes (BVH leaves owning contiguous vertex ranges), the 14 brushes (Draw to Mask, Layer, Snake hook, Morph, Paint, Cloth), masking, polypaint, polygroups, sculpt layers, X/Y/Z symmetry, brush alphas, dynamic topology, apply_dab and sculptor_flush, dirty ranges for upload, deferred normals and normal cones, per-node stroke undo, subdivision levels (Loop, detail in local frames, sync up and down), HD detail windows, simplified copies between strokes, and the app side: stroke sampling, dab spacing, pressure and pen tilt, lazy mouse, the cross-object History and Scene_Command. Load for ANY task that changes how a brush moves vertices or what happens around a stroke, "add a brush kind", "symmetry is off", "undo is wrong", "the levels drift", "HD window border", "dabs skip at high speed", "move vertices from a tool", "make this undoable". Requires sm-geom and sm-build; GPU upload is sm-render; panels are sm-ui; ZBrush is the behaviour model.
---

# Sculpting

## Model (README: "Subdivision levels", "HD detail", "Controls", "Benchmark")
- `Sculptor` (`src/sculpt/brush.odin:119-170`): `mesh ^geom.Mesh`, `pool`, `faces`, `bvh`, `nodes []Node`, `chunks
  []geom.Chunk` (per node, kept current by the flush), `node_of` (BVH leaf → node id), `shared`/`owners`, per-dab scratch,
  `stale`/`dirty_nodes`, `cone_waiting`/`waiting_cones`, `ranges`, `changed_bounds`, `edited`/`edited_nodes`, `history`,
  `lod`, `fade []u8` (0 = never moves). `Node{tri_first, tri_count, vert_first, vert_count, shared_*, owner_*, leaf}`
  (`:85-95`): each node alone writes its owned, contiguous vertex range; a shared vertex belongs to the lowest node id.
- Constants with their reasons (`:23-32`): `NODE_TRIANGLES 1024`, `PARALLEL_MIN_VERTS 2048` (waking workers costs more
  than less work), `MAX_CACHED_FACES 4096`, `CONE_BATCH 512` (cones held back during a stroke, worked off per flush).
- `sculptor_init(s, mesh, pool, node_triangles, old_to_new)` partitions and renumbers the mesh in place; vertex and
  triangle order change (`:172`).
- `Brush{kind, radius (world units), strength 0..1, invert, symmetry, detail, collapse, tilt, alpha, alpha_up,
  alpha_mirror}` (`:55-75`; `detail`/`collapse` are dynamic topology's; `tilt` is a rotation of the area normal from a
  leaning pen, zero for none; `alpha` is the bullet on alphas below, nil for none); `falloff` is `(1 − x²)²` over the squared distance in radii (`:511-515`). `Brush.falloff_shape: ^Falloff` (nil = built-in) swaps it for a drawn curve: `falloff_set_curve` fills a 257-entry table over x² from `geom.curve_at(curve, 1 - d)`, `falloff_drawn` lerps it; `dab_weight` and `grab_follow` read it (the alpha's height fade and the area sampling keep the built-in). App: `Brush_Settings.falloffs[kind]`, tables cached in `App.falloff_tables` by `brush_falloff`. Strengths with
  their reasons: `DRAW_HEIGHT 0.1` radii, `CLAY_HEIGHT 0.08`, `PLANE_RATE 0.5`, `PINCH_RATE 0.25`, `CREASE_PINCH 0.2`
  (`:78-83`).
- The fourteen kinds, in key order 1–9 then 0 (Snake hook, Morph, Paint and Cloth have no key) (`Brush_Kind`; README "Brushes, masking and symmetry" has the user's view):
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
  | Layer | each vertex along its own normal toward `radius · strength · LAYER_HEIGHT`, `LAYER_RATE · w` of the way a dab; heights kept per stroke in `Sculptor.layer` (`Layer_Height{stroke, height}`, valid where `stroke == layer_stroke`, which `sculptor_stroke_begin` bumps; grown when dynamic topology adds vertices) | lowers |
  | Morph | toward `Sculptor.morph` (`morph.odin`: `sculptor_morph_store`/`_clear`/`has_morph`; refused under dynamic topology, dropped by `sculptor_dyn_enable`) by `strength · w · MORPH_RATE`; nothing without a target | — |
  | Paint | nothing: colours (`paint.odin`, bullet below) | takes coverage off |
| Snake_Hook | by `Brush.drag · w` (mirrored per image); the app (`hook_follow`, `src/app/sculpt_tool.odin`) moves the hook point after the pointer on the camera-facing plane in steps of at most `DAB_SPACING` radii and dabs at it without raycasting | — |
  | Cloth | a cloth simulation of the region within `CLOTH_REACH` radii (`cloth.odin`): `sculptor_cloth_begin` (record_hit, sim vertices with pin/drive weights, edge links via `vertex_faces_of`), `sculptor_cloth_step` each frame (Verlet + `Cloth_Mode` force, Jacobi edge rounds with buckle and bending, write back, `sculptor_nodes_moved` + `record_changed_node`), `sculptor_cloth_end` in `stroke_finish`; app `cloth_follow`; not with dyntopo, no symmetry | Pinch↔Expand, Gravity rises |
- Drag rectangle (`Stroke_Mode.Drag_Rect`, app `rect_follow`): each frame `sculptor_stroke_restore` (`undo.odin`) copies the
  current step's saved nodes back (keeping them, so the stroke stays one step; refused under dynamic topology), then one dab
  at the start point sized by the drag.
- Front faces only: `Brush.facing` (mesh-space way toward the viewer, mirrored per image; zero = off) scales each vertex
  by `facing_weight` (a ramp over normal · facing) in `displace`, Smooth and `mask_dab`; Grab ignores it. Mask shapes take
  `Front_Only{on, parallel, eye, toward}` (`mask.odin`) and skip vertices facing away.
- `apply_dab(s, brush, center)` (`brush.odin:570-584`) returns 0 for Grab, else runs `dab_once` at every mirror image:
  `mirrors(symmetry)` gives `{1,1,1}` then the sign flips, up to 8 (`brush.odin:588-600`); each image gets the tilt
  mirrored too (`S·R·S`: element `[i, j]` times `sign[i]·sign[j]`, `brush.odin:577`), and `alpha_up` times the sign with
  `alpha_mirror` toggled on an odd number of flips (`brush.odin:579-580`). `dab_once` (`brush.odin:612-693`):
  `bvh_query_leaves` out to the reach (the radius, or `radius · alpha.reach`, `brush.odin:614`) → dynamic topology first
  when on (the bullet below) → `job_area` unless Smooth or Mask without an alpha (falloff-weighted normal and centre over
  the round radius: `d.normal`, `d.plane`, the normal then turned by `tilt` (`brush.odin:649`), so Draw, Clay, Flatten,
  Pinch and Crease lean with the pen; not for Smooth, `brush.odin:790`; then `alpha_frame` with an alpha) → Mask returns
  `mask_dab` → otherwise `record_hit` when recording → the kind's `job_*` → `finish_move` (`brush.odin:698-715`: `mark_shape_changed`, `record_changed`, `job_hit_bounds`,
  `bvh_refit_leaves(recompute_leaves = false)`). Returns how many vertices moved; positions and BVH bounds are current when
  it returns, normals catch up in the flush.
- Each moving kind's `job_*` is a one-line call to `displace(d, i, $K)` (`brush.odin:822`), specialised per kind with `when`, so the
  vertex loop never branches on the kind; the weight is `dab_weight(d, delta, d²) · shield(fade, mask, v)` (`dab_weight`,
  `brush.odin:541`: `falloff(d² / r²)`, or the alpha's value; `shield`, `brush.odin:604`: HD fade × (255 − mask) / 255).
  Smooth's and Mask's weights go through `dab_weight` too.
- Alphas (`src/sculpt/alpha.odin`): `Alpha{size, values (size², rows from the top), reach}` (`:13`), six built-in
  `Alpha_Shape`s made by `alpha_make` (`:68`, 256²), `alpha_from_grey` for an image (pads to a square, box-averages to at
  most `ALPHA_MAX_SIZE` 512, `:114`), and `alpha_measure` (`:146`): `reach` is the farthest pixel above 0 plus one
  pixel, at most √2, so an image that fades out inside its circle costs no more than the round brush (an all-√2 reach
  made a 10M dab 2.2× Draw; measured, it is +19% a dab, +8% a frame). `alpha_frame` (`brush.odin:520`) lays the image
  on the plane across `d.normal`: `d.au`, `d.av`, `d.an` are its right, up and normal over the radius, up being
  `alpha_up` made perpendicular to the normal, right `up × normal`, negated when mirrored. `dab_weight` then reads
  `alpha_sample(u, v)` (bilinear, 0 outside the square, `alpha.odin:53`) times `falloff(h²)` for the height `h` off
  that plane in radii.
- Grab (`src/sculpt/grab.odin`): `sculptor_grab_begin(s, brush, center)` gathers the leaves at every mirror image, saves
  them for undo once (`record_hit`), stores start positions and a per-vertex, per-axis follow weight (the signed sum of
  falloffs over the images, times `shield`) (`:34`); `sculptor_grab_move(s, offset)` sets `start + offset · follow`,
  absolute rather than incremental, then `finish_move` (`:98`); `sculptor_grab_end` (`:124`, called by `stroke_finish`).
- Mask (`src/sculpt/mask.odin`): `Sculptor.mask []u8` per vertex, nil until first used, 255 = brushes leave the vertex
  alone. `sculptor_mask_shape(s, clip, ndc_polygon, unmask)` masks every vertex whose clip-space projection falls in the polygon (even-odd, through a 1024² `Coverage` grid), committing through the shared `mask_commit` like the commands; app side `src/app/mask_shape.odin` (Ctrl + drag from empty space, Alt unmasks). `mask_dab` (`:35`) paints by `255 · strength · falloff · fade`, marks nodes stale `.Paint` (GPU data only, no
  normal recompute) and records them as `painted`; `sculptor_mask_command(s, command, steps)` is one undo step (`:82`):
  Clear, Invert and Fill are one pass, and Cavity (`mask_cavity`) masks each vertex by how far it sits below the average of its
  triangles' corners along its normal, over their mean distance, times `CAVITY_GAIN` (works with no mask yet); Blur, Sharpen, Grow and Shrink (`mask_steps`, `:159`) give each vertex the
  average, a push away from half masked against half that average (`SHARPEN_PUSH`), the highest or the lowest of its
  triangles' corners a step (`mask_filtered`, `:288`). A vertex whose corners all share its value (0 or 255 for Sharpen)
  is a fixed point, so a step works only on the nodes with uneven corners (`node_uneven`, `:253`) and their owners,
  and rechecks only nodes with a moved corner (the owner and the nodes listing it): 10 ms a press at 10M instead of
  85-107 ms a step; the whole mask is built in a copy first so only changed nodes are recorded; `levels_carry_mask` copies it to the level being shown (`:327`); an HD window starts unmasked and its mask is
  dropped when it closes. On the GPU the mask rides in the low 4 bits of each normal half (`geom.oct_encode_masked`, sm-render).
- Polypaint (`src/sculpt/paint.odin`): `Sculptor.color []Color` (`[4]u8`: sRGB and coverage), nil until painted; `paint_dab`
  (from `dab_once` like `mask_dab`, no area pass without an alpha) mixes with `paint_mix` (paint laid over: coverage grows by `w`
  of what is left, colour mixed by coverage, at least one step a dab), marks `.Paint`, saves `Saved_Node.colors` through
  `record_color` (`History.color_saved` stamps, nodes listed in `painted`); `sculptor_paint_command(.Fill | .Clear)`. Polygroups
  (`src/sculpt/groups.odin`): `Sculptor.groups{tris []u16, vertex, lead, edited}`; `sculptor_group_command(.Visible | .Masked |
  .Creases | .Clear)` → `groups_commit` (one step, `Saved_Node.groups`, `Undo_Step.grouped`) → `groups_refresh` picks the group
  each vertex carries and each triangle's lead corner (`drawn_triangle`), bumps `paint_stamp` and queues every node through the
  hidden-index path (`sculptor_hidden_indices` turns triangles to start at their lead corner); `sculptor_hide_group` (hide.odin),
  `sculptor_mask_group` (mask.odin), `sculptor_group_at`. Levels: `levels_carry_paint` carries colours (`levels_carry_color`) and
  groups (`levels_carry_groups`, via `level_tri_parents`) only when `color_edited`/`groups.edited`, and always into a new level;
  files: `LEVELS_PAINT` flag, groups in `tri_canon` order. None under dynamic topology (`sculptor_dyn_enable` drops them) or in HD
  (the app refuses, `paint_allowed`). App: `src/app/paint.odin` (`paint_upload` → `render.mesh_buffers_upload_paint`).
- Sculpt layers (`src/sculpt/sculpt_layers.odin`, not the Layer brush's `s.layer`): `Sculptor.layers{list, recording (index+1,
  0 none), named}`, each `Sculpt_Layer{name [32]u8, strength, visible, delta [][]Vec3}` (per node, nil where unmoved); positions
  always hold base + Σ weight·delta. `sculptor_stroke_end` calls `layer_take_stroke` (adds live − saved positions of each saved
  node to the recording layer, appending `Saved_Node{is_delta, delta (old), delta_layer}`, swapped by pointer on undo).
  `Undo_Step.layer_op` (add/remove; the step `held`s a removed layer) and `.layer_set` (old strength/visible) are swapped in
  `layer_step_swap`; `step_move` re-counts `h.bytes` since swaps change what a step holds. `sculptor_layer_set` begins or
  continues a stroke (a drag = one step; app ends it on release), `layer_displace` moves only nodes with delta. Files:
  `LEVELS_LAYERS` flag, every level's layers in canon order. Baked by `sculptor_dyn_enable`; app refuses in HD/dyntopo
  (`src/app/layers.odin`).
- Chunk groups (`brush.odin`, `sculptor_chunk_groups`): one `geom.chunk_group` per 64 chunks for grouped culling; every
  write to `s.chunks[id]` must call `chunk_touched(s, id)` so the group is remade; nil under dyntopo.
- `sculptor_flush(s)` (`brush.odin:443-506`): once a frame before uploading. Sorts `dirty_nodes`, recomputes normals per node
  (Shape: all of them; Edge: only the border vertices), leaves a changed chunk's cone open during a stroke and works the
  waiting cones off `CONE_BATCH` per flush afterwards, sets `changed_bounds` (before and after), and returns coalesced,
  sorted `Vertex_Range`s valid until the next call.
- Other entry points: `sculptor_nodes_moved(s, nodes)` after owned positions changed outside a dab (`brush.odin:944-971`);
  `sculptor_recompute_all` for a mesh that arrived without normals (`brush.odin:973`); `sculptor_clear_edited` once levels carried
  the edits (`brush.odin:980`); `sculptor_raycast`; the brute-force `raycast` for tests.
- Undo (`src/sculpt/undo.odin`): one step per stroke; a node's owned positions (12 B a vertex) or, for mask strokes, its
  masks (1 B) are copied the first time the stroke touches it, and nothing for the rest (`:9-15`). `Undo_Step{nodes,
  painted}` lists node ids (`:32`); `Saved_Node{node, positions | masks, full, indices, …}` (`:42`), where `full` entries
  are dynamic topology's whole-node saves. `record_hit(s, masks)` (`:171`) picks `record_mask`, `record_full` (dynamic)
  or positions; a dab's new position saves past `RECORD_PARALLEL_VERTS` (64k vertices, e.g. a clip) share one unzeroed
  allocation (`Saved_Node.block` on the first, `borrowed` on the rest, freed once) and copy in parallel. Clip
  (`src/sculpt/clip.odin`): `sculptor_clip(s, []Clip_Plane)` finds the nodes with a free vertex past a plane, saves them
  through `record_hit`, projects (shield-weighted) and calls `sculptor_nodes_moved`; one step, refused under dyntopo; app
  gesture `src/app/clip.odin` (Ctrl+Shift drag with `app.gesture == .Clip`, Alt flips, planes mirrored by
  `sculpt.mirrors`). Hiding (`src/sculpt/hide.odin`): `Hide.tris` per triangle; a vertex is hidden when every
  triangle of it is, and then its `fade` is 0, so `shield` keeps brushes, Clip and Grab off it (mask commands check
  `vertex_hidden`); `hide_refresh` rebuilds `fade`, `units` (chunks plus LOD groups, for `Draw_Item.hidden`) and bumps
  `stamp`, which `hidden_upload` in app/scene.odin compares to re-upload packed indices with hidden triangles zeroed.
  `sculptor_hide_shape`/`sculptor_hide_command` are undo steps (`Undo_Step.shown`, `Saved_Node.hidden`); refused under
  dyntopo or in HD, never hide everything; `bvh_raycast` skips hidden triangles. Smooth all
  (`src/sculpt/smooth_all.odin`) follows the same shape: `sculptor_smooth_all(s, steps, strength, gpu)` weighs every
  vertex by `strength · shield`, saves the free nodes, runs `smooth_all_cpu` (Jacobi steps over vertex ranges, two
  buffers) or the `Smooth_Gpu` callback the app fills with `render.smooth_compute_run` (falls back to the CPU when it
  returns false), then `sculptor_nodes_moved`; `smooth_vertex` and `smooth_all.comp` share one arithmetic order. Project detail
  (`src/sculpt/project.odin`) too: `sculptor_project(s, next, colors, strength)` lerps owned positions toward `next` (and
  paint toward `colors`) by `strength · shield`, saving moved and painted nodes as one step; refused under dyntopo. Undo and redo swap in place (`step_move`, `:134`); `UNDO_LIMIT_BYTES = 512 << 20` drops the oldest steps
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
  file returns false, never asserts. The base also stores its node layout (`LEVELS_LAYOUT`: `sculptor_layout`, per
  node its triangle and owned-vertex counts), and `levels_init(layout = ...)` builds it with
  `sculptor_init_laid_out` (`src/sculpt/layout.odin`), which keeps the mesh's order, derives shared/owners and a
  `bvh_build_over` tree, and returns false on any layout that does not fit (then the full `sculptor_init` runs).
- App side (`src/app/sculpt_tool.odin`): `Brush_Settings` with the radius in pixels, `symmetry`, `detail_px`, `collapse`,
  `alpha` (an index into `App.alphas`, -1 for round), `alpha_mode`, `alpha_angle` (`:13-30`); `Input_Sample{pos, pressure, kind, tilt}`, every motion event of a frame kept (`:32-47`); `DAB_SPACING 0.25`
  radii, `MIN_DAB_SPACING_PX 1`, `MAX_DABS_PER_FRAME 64`, `MAX_PENDING_SAMPLES 4096`, `MAX_BRUSH_MS_PER_FRAME 10`
  (`:69-76`); `sculpt_frame` → `stroke_follow` (lazy mouse `:164-170`; leftovers go to `pending` `:171-176`) →
  `stroke_start` (`scene_raycast`, select, `sculptor_stroke_begin`, first dab, or `sculptor_grab_begin` for Grab, `:183`)
  → `stroke_walk` (a dab every spacing pixels until the dab or time budget runs out, `:239-263`) → `stroke_dab`
  (`sculptor_raycast` in local space; a miss is skipped, `:269`). Grab instead follows only the frame's last sample
  (`grab_follow`, `:214`: the pointer ray meets the plane through the anchor that faces the camera, the offset is divided
  by the object's scale). `brush_at` turns pixels into world units at the hit's distance, divides by the object's scale,
  maps pressure through the pressure curve (`pressure_curved`, `:317`, `geom.curve_at`), turns the pen's lean into
  `tilt` with `camera.orbit_tilt` when the Tilt slider is above 0, passes `symmetry`, makes `detail` a share of the radius, and with an alpha (none for Grab or Shift's
  smoothing, `brush_alpha`) passes it and `alpha_up` from `alpha_world_up` (`:287-309`). `src/app/alphas.odin` turns the
  mode into a screen angle (`alpha_screen_angle`, `:173`: Follow stroke uses `Stroke.dir`, set in `stroke_walk` and zero
  at a stroke's start; Random steps `App.alpha_seed`) and that into a world direction in the view plane (`:194`). Symmetry planes go through the mesh's local
  origin; X toggles X. `History` orders strokes and mask commands across objects and levels, newest last, `HD_LEVEL =
  -1`; undoing a stroke from another level switches to it first (`src/app/history.odin:7-22, 78-92`); `stroke_finish`
  ends Grab and records the stroke (`:31`), `mask_command` records a mask command (`:43`). `Scene_Command` kinds and
  `scene_apply` (`src/app/scene.odin:84-91, 245`). Placing an object (gizmo drag, inspector Transform drag, Reset
  transform) is a `.Transform` entry: `history_record_transform(app, obj, before, what)` stores `before`/`after`, level 0,
  no sculptor; `history_step` sets one or the other, the forget procs keep it unless every level is forgotten, and
  `history_busy` refuses undo while a stroke, `app.move.drag` or `app.ui.transform_drag` is open (`move_tool.odin`:
  `move_end` records on release, `move_cancel` restores unrecorded, `transform_drag_changed`/`transform_drag_end` make an
  inspector drag one step). A new kind of change to where an object sits goes through these, never a bare write.

## Rules that bite
- Every position change goes through `apply_dab` or `sculptor_nodes_moved`; otherwise BVH bounds, normals, chunks, LOD
  staleness and `edited` drift apart (tests `incremental_updates_match_full_recompute`, `flush_leaves_no_stale_normal`,
  `synced_levels_stay_consistent`).
- Call `sculptor_flush` once per frame per visible level and upload what it returns (`src/app/main.odin:431-440`).
- `stroke_finish` before any level, HD or scene change (`scene.odin:292, 386, 410`); leave the HD window before
  `levels_set_current` or a delete (the asserts at `levels.odin:93, 131, 139`).
- A new `Brush_Kind`: a `when` branch in `displace` and a one-line `job_*` (or its own pair, as Smooth), a case in
  `dab_once`'s switch, weights through `shield` so the mask and the HD fade hold, a row in `BRUSHES`
  (`src/app/brushes.odin`: name, help, icon, fresh strength, flags; its key follows the enum order), a test that proves what it moves, and a place in
  `new_brushes_parallel_match_serial` (`brushes_test.odin`), which compares serial with parallel bit for bit.
- Strokes undo per node: a tool that moves nodes without recording them breaks undo (sm-cad has the plan).
- With dynamic topology the triangles change during a stroke by design; everything else about a topology change
  (end the stroke, leave HD, clear the history, recreate the GPU buffers) happens when it is turned on or off
  (`object_set_dyntopo`). The app uploads changed index pages with `level_upload`, which remakes the buffers when the
  pages outgrow them. Never read `len(mesh.positions)` as a vertex count on a dynamic object.
- Simplified copies are never built during a stroke (`main.odin:440-441`, `lod.odin:164`); the brush works in the
  object's local space (`scene.odin:14-16`), symmetry included.
- A mask-only change is stale `.Paint`: it re-uploads the node's vertices without recomputing normals; pass
  `sculptor.mask` to every `mesh_buffers_create`/`upload_ranges`, or the mask vanishes from the screen (sm-render).

- The autosave thread reads every object with `levels_write` (`Write_Options{serial, abort, synced, hd_open}`) while
  the frame loop runs: anything that changes a sculptor, a level or the scene must happen after `autosave_guard`
  (once the frame's events are read) or inside a scene command or file request (both `autosave_settle` first), and
  anything that changes the scene without a press must make `autosave_quiet` false while it runs (a replay, the
  timeline). A change that is saved but not in the History bumps `app.scene_edits`, or autosave never notices it
  (`scene_fingerprint`). A new loop in `levels_write` checks `w.abort` per node or piece and runs serially when
  `pool` is nil; `levels_file_is_the_same_written_serially` and `levels_file_write_stops_when_asked` cover both.

## Traps
| You might expect | What happens |
|---|---|
| the selected object can be out of view | never: `scene_selection_fix` (each frame, after every `scene_view`) moves the selection off an object whose eye is off or that is a ghost; whatever draws or picks objects asks `object_shown`/`object_pickable` (`scene_tree.odin`) instead of reading `Object.off`, `ghost` and `Scene.solo`; view changes count in `app.view_edits` (autosave), not `scene_edits` (which ends Adjust last); and `scene_raycast`/`scene_raycast_surface` skip what cannot be picked |
| undoing a swap brings back the old eye | no: `history_swap` copies the live object's `off`, `ghost` and `folder` onto the one it restores; the eye is view state, saved but never an undo step |
| a folder's objects can sit apart in the list | never for long: `scene_folders_normalize` (each frame, after a layout, a swap or a file) gathers them where the first one is and clears unknown folder ids; code that adds an object anywhere may rely on it |
| a tree change is a swap | no: folders, renames and moves into folders are `.Arrange` entries (`id` 0) holding a `Scene_Layout` before and after (`scene_tree.odin`); `layout_apply` skips objects that are gone and leaves unlisted ones in place, so a chain of Arrange then swaps (Delete folder) undoes in any order |
| a sample off the surface ends the stroke | it is skipped; the stroke resumes where the path meets the surface again (`sculpt_tool.odin:265-268`) |
| every Ctrl+Z undoes a stroke | entries whose step the byte limit dropped are skipped silently (`history.odin:80-84`) |
| HD strokes stay in the history | closing the window forgets them (`object_hd_leave`, `scene.odin:408`); Delete higher/lower, Remesh and turning dynamic topology on or off clear the object's history (`:322, 328, 484`; `object_set_dyntopo` `:180`) |
| Shift smooths only the Draw brush | Shift turns any kind into Smooth, Grab and Mask included (`brush_at`) |
| the mask stops the Mask brush | it does not: the Mask brush is weighted by falloff and HD fade only, so it can erase |
| an alpha's square is one radius across its middle | yes, but its corners reach √2 radii, so the query and dynamic topology look out to `radius · alpha.reach` while `job_area` still averages over the round radius |
| an alpha shapes Grab or Shift's smoothing | neither: `brush_alpha` gives Grab none and `brush_at` drops it under Shift; the Smooth brush picked as a kind does use it |
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
  `mask_follows_levels`, `mask_grow_and_shrink_move_the_edge_a_ring`, `mask_blur_softens_and_sharpen_narrows_the_edge`,
  `mask_steps_match_a_full_pass` (guards the edge-only skipping), `new_brushes_parallel_match_serial`, and for alphas
  `alphas_fade_out_and_sample_between_pixels`, `alpha_stamps_its_shape_facing_up` and `alpha_mirrors_with_symmetry`.
- Fixtures: `sculptor_init(&s, &m, nil, 64)` for small nodes; `levels_make(subdiv, steps, pool)` (`levels_test.odin`),
  `hd_make` (`hd_test.odin`), `lod_sphere(…, min_triangles = 0)` (`lod_test.odin`); `snapshot`/`expect_state`
  (`undo_test.odin`); `expect_decoded` (`levels_test.odin`). `build.bat test` runs sculpt third.
