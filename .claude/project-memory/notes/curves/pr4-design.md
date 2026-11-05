# PR 4 design: the curve object, its file chunk and undo

Plan item 4 (mock state 1, Draw). A curve is a scene object that holds Bézier points and stays editable until Bake.
PR 4 makes the object, draws it, saves it and undoes it; what it makes (Tube, Lathe, Along, Brush path) is PRs 6 to 9,
and pen editing of its points beyond the basics is PR 5.

## The object

- `Object.curve: ^Curve_Part` (new file `src/app/curve_object.odin`), beside `voxel` and `cage`, nil for the rest.
  `Curve_Part{points: [dynamic]geom.Bezier_Point, closed: bool, use: Curve_Use, version: int}` where
  `Curve_Use :: enum u8 {None, Tube, Lathe, Along, Brush_Path}` (only `.None` in PR 4: the curve is drawn as a line).
  Points are in the object's own space; the transform places it as any object (so Move, folders, eyes, ghost, lock,
  spaces and visibility slots all work unchanged).
- Its `levels` hold one empty level, as a voxel object's do, so everything that reads the selected sculptor reads
  nothing. `object_kind` gains `OBJECT_KIND_CURVE :: 3`. Brushes, Model tools, Export, booleans, remesh and anything
  that needs triangles refuse a curve as they refuse a voxel object today (one `object_is_curve` check beside each
  `obj.voxel != nil` refusal that means "no triangles"; a grep lists 31 such sites, each checked by hand).
- Drawn by the overlay (no GPU buffers in PR 4): the curve as a polyline of `bezier_sample` points in the object's
  colour, thicker when selected; its points and handles only while selected in the Curve tool. Picking: a press within
  10 px of the screen polyline picks it (the scene raycast skips curves; `scene_pick` gains a screen test after it).
- Outliner: a curve icon (`ICON_SPLINE`), name "Curve N".

## Drawing (the Curve tool)

- The Curve tool's kind row gains **Curve** first (Tube, Stitches, Zipper stay as today until PR 6/8 turn them into
  uses). With Curve picked: a drag draws freehand on the surface (as today's path), and on release `geom.bezier_fit`
  (tolerance a quarter of the brush radius) makes the points; a tap places a point (on the surface; off it, on the
  view plane through the last point), and a tap on the first point closes it; Enter or the context bar's Done ends a
  tapped curve. Points stand off the surface by `lift` (today's setting).
- A new curve is one undo step (a swap entry with `exists = false` before, as add_made_object does).

## Undo

- Every finished edit of a curve (drawing, a point drag on release, add, delete, smooth/corner, close) is a swap
  entry: `history_snapshot` before, `history_record_swap(kind = .Curve)` after. `History_Kind` gains `.Curve`
  (shown as "Curve" in the History panel). A curve's snapshot is `object_put` of the object: a few hundred bytes, so
  per-edit swaps cost nothing and reuse the tested path (no new entry kind or field in `History_Entry`).
- No undo entry while a point is being dragged; one on release. Undo while dragging cancels the drag first.

## The file: the CURV chunk

- A curve object is written as its own chunk `CURV` (not `OBJ `), so an app of version 36 steps over it and opens the
  rest of the scene as before. Its body is `object_put`'s bytes with kind 3, the levels replaced by:
  `u32 count, u8 closed, u8 use`, then per point `p, h_in, h_out: Vec3, radius, intensity, twist: f32, corner: u8`,
  then the use's settings (none in PR 4; later PRs add them at the chunk's end).
- `SCEN`'s object count stays the count of `OBJ ` chunks, so an older reader's `len(objects) == f.count` holds.
  `SCEN` gains, at its end: `i32 curves` (how many CURV chunks follow) and `i32 selected_any`, the selected index
  in the full list. The old `selected` field is written as the index among non-curve objects, or -1 when a curve
  is selected (checked: an older reader treats -1 as nothing selected).
- Order: each CURV chunk starts with `i32 at`, its index in the full scene list; the reader inserts curves at those
  places after all chunks are read, refusing the file if `at` is out of range or repeated.
- `SCENE_VERSION` does not move (nothing an older reader would misread). `files_test.odin` gains: a scene with two
  meshes and a curve between them round-trips in order with the selection; the same bytes read by the v36 path with
  the CURV chunk stepped over give the two meshes; a damaged CURV (count past its bytes, NaN point, bad `at`) refuses
  the file without an assert.
- Swap snapshots and Duplicate use the same body, read by `object_get` with kind 3 accepted only from a CURV chunk or
  a snapshot (an `OBJ ` chunk with kind 3 is damage).

## Exit stats, README, tests

- `curves=` (curve objects in the scene) and `curve_points=` at exit. README: the Curve tool's Curve kind and the
  outliner row. Tests: drawing by drag fits few points; taps place and close; undo and redo of add and edit; file
  round trip, older reader and damage as above. Touch scenario: a curve drawn by pen, undone, redone.

## Out of PR 4

Rope pull, delete by dragging off, mirror X, the point menu (PR 5); everything a curve makes (PRs 6 to 9).

## Changes after the architect review

- One `object_chunk_tag(obj)` used by both writers: `scene_save` and the autosave thread (autosave.odin writes every
  object as `OBJ ` today; it would have written curves as damage).
- No `at` field: OBJ and CURV chunks are written in list order and the reader appends in file order; `SCEN` keeps the
  `curves` count (catches a file cut at a chunk boundary) and the count check counts non-curve objects only. Curves go
  through `read_object` so `next_id` covers them.
- The old `selected` field: an older reader selects object 0 when it reads -1 (files.odin), so a selected curve is
  written as the nearest non-curve object's index there; `selected_any` at SCEN's end is the real one.
- `object_get` takes which kinds it accepts: OBJ chunks never kind 3; CURV, swap snapshots, Duplicate and Paste do.
- One predicate `object_draws_triangles(obj)` (false for a curve) at the GPU sites: `object_gpu`, the frame's mesh
  branch, object thumbnails, layer pictures, rebuild, print checks, show level; no zero-byte buffers are made.
  Tools refuse curves centrally: `object_editable` false for a curve and a refusal in `scene_apply` beside the voxel
  and cage ones, not site by site.
- Damage: `corner > 1`, a non-finite field, `use` past `Curve_Use`, fewer than 2 points, or `count` past the bytes
  left refuse the file before anything is allocated.
- `history_swap` ends a curve-point drag as it ends strokes and `move.drag`. `.Curve` gets its glyph and colour.
- README says an older app opens the scene without its curves, and saving it there drops them.
