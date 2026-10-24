# Undo for topology-changing tools: the `Mesh_Swap` entry

## Contents
- Why positions-only undo cannot cover it
- The design
- Interaction with levels, HD and the cross-object history
- Memory cap
- Tests

## Why positions-only undo cannot cover it
A stroke's undo step holds the owned positions of the nodes a dab reached (`src/sculpt/undo.odin:9-13`): it assumes the
node partition, the vertex count and the triangle list are the same before and after. A boolean, trim, extrude, remesh
or decimate changes all three, and `sculptor_init` renumbers the mesh besides, so there is no node to restore into.
Today such a change rebuilds the object and clears its history (`object_remesh`, `src/app/scene.odin:105-111`), which is
correct but not undoable.

## The design
- `History_Entry` (`src/app/history.odin:15-18`) gains a `kind: enum {Stroke, Mesh_Swap}`. A `Mesh_Swap` entry names the
  object and a snapshot slot; the object keeps `swaps: [dynamic]Mesh_Snapshot` with `{positions: []Vec3, indices: []u32,
  transform: Transform, bytes: int}`. The current mesh is always the live `Levels`; a snapshot is the base level's mesh
  before the tool ran (the levels above are derived and are not kept; see below).
- Undoing a `Mesh_Swap` swaps the snapshot with the live base mesh: `stroke_finish`, `object_hd_leave`, wait for the GPU,
  release the levels and GPU buffers (`object_release_mesh` minus the history reset), `levels_init` with the snapshot's
  mesh, recreate the buffers, and store the mesh that was live into the slot, so the entry is its own inverse exactly
  like a stroke step. Redo is the same swap again.
- Stroke entries that were made on the mesh before the swap cannot apply to the swapped-in mesh. They are dropped from
  `history.done` for that object when the swap is recorded (as HD strokes are dropped when the window closes); stroke
  entries made after the swap sit above it and undo first, so the order stays consistent.

## Interaction with levels, HD and the cross-object history
- Levels above the base are rebuilt by the user after an undo, not restored: storing a whole `Levels` per snapshot would
  multiply memory by the number of levels. The entry records how many levels and HD steps existed, and the undo logs
  what was dropped. If this proves annoying in use, the next step is storing the levels' `detail` arrays, which are
  small relative to the meshes.
- The cross-object order is unchanged: `history_step` pops entries newest first; a `Mesh_Swap` entry runs the swap
  instead of `sculptor_undo`. `entry_sculptor` returns nil for it, so the "dropped step" skip must not fire for swaps.

## Memory cap
- Snapshots count against a per-object cap like `UNDO_LIMIT_BYTES` (512 MB): 16 bytes per vertex plus 12 per triangle,
  so a 10M-vertex base costs about 400 MB per snapshot; the oldest snapshot goes first, and the entry that pointed at it
  is removed from the history. Print `swap_mb=` next to `undo_mb=` in the exit stats.

## Tests
- `tests` in `src/app` do not exist (the app has no test package); put the swap logic in `sculpt` or `geom` where it is
  pure (a `Mesh_Snapshot` type and `swap` procs over `geom.Mesh`), test the swap round trip there (`mesh_check` before
  and after, byte-identical positions and indices), and exercise the app path with `--frames` runs that log
  `swap: undone <id> (<v> vertices)` lines plus `--check-mesh`.
