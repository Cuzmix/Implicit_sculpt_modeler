---
name: sm-sculpt
description: Sculpting in src/sculpt and the app's brush tool — the Sculptor's nodes (BVH leaves owning contiguous vertex ranges), apply_dab and sculptor_flush, dirty ranges for upload, deferred normals and normal cones, per-node stroke undo, subdivision levels (Loop, detail in local frames, sync up and down), HD detail windows, simplified copies between strokes, and the app side: stroke sampling, dab spacing, pressure, lazy mouse, the cross-object History and Scene_Command. Load for ANY task that changes how a brush moves vertices or what happens around a stroke, e.g. "add a brush kind", "undo is wrong", "the levels drift", "HD window border", "dabs skip at high speed", "move vertices from a tool", "make this undoable". Requires sm-geom and sm-build; GPU upload is sm-render; panels are sm-ui; ZBrush is the behaviour model.
---

# Sculpting

## Model (README: "Subdivision levels", "HD detail", "Controls", "Benchmark")
- `Sculptor` (`src/sculpt/brush.odin:77-121`): `mesh ^geom.Mesh`, `pool`, `faces`, `bvh`, `nodes []Node`, `chunks
  []geom.Chunk` (per node, kept current by the flush), `node_of` (BVH leaf → node id), `shared`/`owners`, per-dab scratch,
  `stale`/`dirty_nodes`, `cone_waiting`/`waiting_cones`, `ranges`, `changed_bounds`, `edited`/`edited_nodes`, `history`,
  `lod`, `fade []u8` (0 = never moves). `Node{tri_first, tri_count, vert_first, vert_count, shared_*, owner_*, leaf}`
  (`:46-56`): each node alone writes its owned, contiguous vertex range; a shared vertex belongs to the lowest node id.
- Constants with their reasons (`:23-32`): `NODE_TRIANGLES 1024`, `PARALLEL_MIN_VERTS 2048` (waking workers costs more
  than less work), `MAX_CACHED_FACES 4096`, `CONE_BATCH 512` (cones held back during a stroke, worked off per flush).
- `sculptor_init(s, mesh, pool, node_triangles, old_to_new)` partitions and renumbers the mesh in place; vertex and
  triangle order change (`:123`).
- `Brush{kind, radius (world units), strength 0..1, invert}` (`:39-44`); `falloff` is `(1 − x²)²` over the squared
  distance in radii (`:441-448`). Draw moves along the area-weighted average normal of the hit by `radius · strength ·
  0.1` (`:483-489`); Smooth is one Jacobi step toward the neighbour mean (`:490-500`).
- `apply_dab(s, brush, center)` (`:462-519`): `bvh_query_leaves` → `record_hit` when recording → the kind's `job_*`
  pair → changed leaves → `mark_shape_changed` (stale Shape, LOD stale, edited) → `record_changed` → `job_hit_bounds` →
  `bvh_refit_leaves(recompute_leaves = false)`. Returns how many vertices moved. Positions and BVH bounds are current when
  it returns; normals catch up in the flush.
- `sculptor_flush(s)` (`:391-439`): once a frame before uploading. Sorts `dirty_nodes`, recomputes normals per node
  (Shape: all of them; Edge: only the border vertices), leaves a changed chunk's cone open during a stroke and works the
  waiting cones off `CONE_BATCH` per flush afterwards, sets `changed_bounds` (before and after), and returns coalesced,
  sorted `Vertex_Range`s valid until the next call.
- Other entry points: `sculptor_nodes_moved(s, nodes)` after owned positions changed outside a dab (`:680-707`);
  `sculptor_recompute_all` for a mesh that arrived without normals (`:709`); `sculptor_clear_edited` once levels carried
  the edits (`:716`); `sculptor_raycast`; the brute-force `raycast` for tests.
- Undo (`src/sculpt/undo.odin`): one step per stroke; a node's owned positions are copied the first time a dab touches
  it, so a step costs 12 bytes per vertex reached and nothing for the rest (`:9-13`); undo and redo swap in place;
  `UNDO_LIMIT_BYTES = 512 << 20` drops the oldest steps but always keeps the newest (`:41-42, 91-95`); an empty stroke is
  not a step (`:83-86`); `sculptor_stroke_begin/end`, `sculptor_undo/redo`, `sculptor_clear_redo/history`.
- Levels (`src/sculpt/levels.odin`): a base mesh and finer copies, each one Loop step above the one below, every level a
  whole mesh with its own sculptor; only the current level is shown and sculpted (`:12-25`). `MAX_LEVELS 8`; `Level{mesh,
  sculptor, node_of_vertex, parents [4]u32, detail Vec3, even_of, deps, dependents}` (`:34-44`); detail is an offset in a
  frame that turns with the surface below. `levels_set_current` asserts no HD window and syncs first (`:91-97`);
  `levels_subdivide` returns false at `MAX_LEVELS`, with an HD level, or on an open mesh (`:99-110`);
  `levels_subdivide_estimate` (`:113`); `levels_delete_higher/lower` (`:129-147`). `levels_sync` has three phases: push
  the edit down as moves of the vertices below, re-encode detail, rebuild the levels above (`:177-203`). `frame_at` and
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
  places, then edge vertices by their ends' places), since `sculptor_init` renumbers on every build. Reading
  subdivides, moves the vertices where they were and encodes the detail again (`recode_level(encode = true)`); HD
  detail is not stored (it follows node numbers), only the HD steps. A damaged file returns false, never asserts.
- App side (`src/app/sculpt_tool.odin`): `Brush_Settings` with the radius in pixels (`:12-19`); `Input_Sample{pos, pressure,
  kind}`, every motion event of a frame kept (`:21-35`); `DAB_SPACING 0.25` radii, `MIN_DAB_SPACING_PX 1`,
  `MAX_DABS_PER_FRAME 64`, `MAX_PENDING_SAMPLES 4096` (`:53-57`); `sculpt_frame` → `stroke_follow` (lazy mouse `:141-147`;
  leftovers go to `pending` `:148-153`) → `stroke_start` (`scene_raycast`, select, `sculptor_stroke_begin`, first dab
  `:160-178`) → `stroke_walk` (a dab every spacing pixels `:184-206`) → `stroke_dab` (`sculptor_raycast` in local space; a
  miss is skipped `:212-223`); `brush_at` turns pixels into world units at the hit's distance and divides by the object's
  scale (`:228-239`). `History` orders strokes across objects and levels, newest last, `HD_LEVEL = -1`; undoing a stroke
  from another level switches to it first (`src/app/history.odin:5-20, 54-68`); `stroke_finish` ends and records a stroke
  (`:29-40`). `Scene_Command` kinds and `scene_apply` (`src/app/scene.odin:65-74, 123-202`).

## Rules that bite
- Every position change goes through `apply_dab` or `sculptor_nodes_moved`; otherwise BVH bounds, normals, chunks, LOD
  staleness and `edited` drift apart (tests `incremental_updates_match_full_recompute`, `flush_leaves_no_stale_normal`,
  `synced_levels_stay_consistent`).
- Call `sculptor_flush` once per frame per visible level and upload what it returns (`src/app/main.odin:329-331`).
- `stroke_finish` before any level, HD or scene change (`scene.odin:163, 253, 277`); leave the HD window before
  `levels_set_current` or a delete (the asserts at `levels.odin:92, 130, 138`).
- A new `Brush_Kind` is a `job_*` pair in `apply_dab`'s switch, honours `s.fade` as Draw and Smooth do, and gets a test
  that compares serial with parallel bit for bit and one that proves the falloff (`brush_test.odin`).
- Strokes undo per node: a tool that moves nodes without recording them breaks undo (sm-cad has the plan).
- With dynamic topology the triangles change during a stroke by design; everything else about a topology change
  (end the stroke, leave HD, clear the history, recreate the GPU buffers) happens when it is turned on or off
  (`object_set_dyntopo`). The app uploads changed index pages with `level_upload`, which remakes the buffers when the
  pages outgrow them. Never read `len(mesh.positions)` as a vertex count on a dynamic object.
- Simplified copies are never built during a stroke (`main.odin:333-335`, `lod.odin:164`); the brush works in the
  object's local space (`scene.odin:12-14`).

## Traps
| You might expect | What happens |
|---|---|
| a sample off the surface ends the stroke | it is skipped; the stroke resumes where the path meets the surface again (`sculpt_tool.odin:208-211`) |
| every Ctrl+Z undoes a stroke | entries whose step the byte limit dropped are skipped silently (`history.odin:56-60`) |
| HD strokes stay in the history | closing the window forgets them (`scene.odin:273-282`); Delete higher/lower and Remesh clear the object's history (`:189, 197, 342`) |
| a `fade == 0` vertex moves a little | never: an HD window's border meets the level drawn around it |
| `sculptor_lod_update` returns ranges mid-stroke | nothing while `history.recording` (`lod.odin:164`) |
| more than 64 dabs land in one frame | the rest of the path waits for the next frame; a lagging stroke drops its oldest samples past 4096 |
| a frame lays every dab its samples ask for | it stops once its dabs have taken `MAX_BRUSH_MS_PER_FRAME` (10 ms), as heavy dynamic topology can; the rest waits |
| a split edge's opposite vertex can sit on it | splits bisect each triangle across its longest side, so slivers never form; `dyn_long_stroke_keeps_a_clean_surface` checks angles and folds |

## Tests
- Fixtures: `sculptor_init(&s, &m, nil, 64)` for small nodes; `levels_make(subdiv, steps, pool)` (`levels_test.odin`),
  `hd_make` (`hd_test.odin`), `lod_sphere(…, min_triangles = 0)` (`lod_test.odin`); `snapshot`/`expect_state`
  (`undo_test.odin`); `expect_decoded` (`levels_test.odin`). `build.bat test` runs sculpt third.
