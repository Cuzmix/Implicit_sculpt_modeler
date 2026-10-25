# Undo for topology-changing tools: swap entries

## Contents
- Why positions-only undo cannot cover it
- What exists
- Rules for a new tool
- Limits

## Why positions-only undo cannot cover it
A stroke's undo step holds the owned positions (or masks) of the nodes a dab reached (`src/sculpt/undo.odin`): it
assumes the node partition, the vertex count and the triangle list are the same before and after. A boolean, trim,
extrude, remesh or decimate changes all three, and `sculptor_init` renumbers the mesh besides, so there is no node to
restore into. Dynamic topology undoes topology inside one sculptor by saving whole pages (`record_full`,
`dyn_step_swap` in `src/sculpt/dyntopo.odin`); an object-wide change needs the whole object.

## What exists (`src/app/history.odin`)
- `History_Entry.swap: ^Object_Snapshot` (nil for strokes). A snapshot is the object as `object_put`
  (`src/app/files.odin`) writes it into the scene file, i.e. `levels_write`: every level as positions, the mask, dynamic
  topology, name and transforms; or `exists = false` for "the object did not exist" (undoing an add).
- `history_swap` trades the live object for the snapshot: it snapshots the live one, rebuilds from the bytes with
  `object_get` (same id, `levels_read`, buffers), frees the live object and puts the rebuilt one at the snapshot's index,
  then stores the live snapshot in the entry. The entry is its own inverse, so undo and redo run the same code.
- Recording or applying a swap drops that object's *stroke* entries in both lists (`history_forget_strokes`): their
  sculptors are gone. Swap entries are kept, since each holds the whole object. `object_release_mesh` therefore forgets
  only strokes; `scene_open` calls `history_clear` because the file's ids can collide with the old scene's.
- Recorded today for: Add sphere and Import (`history_record_added`), Delete (`scene_delete_selected`, Delete key),
  Remesh, Dynamic topology on/off, Delete higher, Delete lower (all in `scene_apply`). Startup flags (`--remesh`,
  `--dyntopo`) record nothing.

## Rules for a new tool
- In `scene_apply`: `before := history_snapshot(app, obj, "<what>")`, run the tool, then
  `history_record_swap(app, obj.id, before)` when it changed something, else `history_snapshot_drop(before)`.
- The `what` string is shown in the Edit menu ("Undo remesh") and must be a constant (not owned).
- HD detail is not in a snapshot (the HD steps are); `object_put` leaves any HD window first.

## Limits
- About 37 bytes a base vertex plus 12 a vertex of each level above per snapshot. `SWAP_LIMIT_BYTES` (1.5 GB) over
  all snapshots; past it the oldest swap entry and everything older in `done` go (never the newest). Stats panel shows
  the total.
- Cost: an object_put plus a `levels_read` per undo; 100k vertices ~0.1 s on the VM; a 10M scene read is ~3.4 s on
  the VM (much less on a desktop).
