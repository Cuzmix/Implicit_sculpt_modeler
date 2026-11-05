# 2e Grab and Elastic under dynamic topology: design note (2026-10-29)

Goal: a Grab or Elastic stroke on an object with dynamic topology on ends with the stretched area refined to the
detail size, as Sculptris Pro's Move does in ZBrush, so pulling out a long shape never leaves long thin triangles;
in the same undo step as the drag.

## What exists
- Grab and Elastic already run on dynamic objects: `sculptor_grab_begin` fixes its vertex list at the press and
  `sculptor_grab_move` only moves them, so triangles stretch but nothing splits.
- `dyn_dab_topology(s, dab, pool)`: for the hit leaves, splits edges longer than `radius * detail` with their middle
  inside the dab's sphere (Rivara longest-edge first), collapses the too-short ones, up to DYN_MAX_SPLITS a call,
  and records changed nodes for undo.

## Design
- Splitting during the drag would add vertices the grab's fixed list does not hold (they would stay behind), so the
  refinement runs once, at the release, before `sculptor_grab_end`: `sculptor_grab_refine(s) -> (splits: int)`.
- Region: the BVH leaves that hold grabbed vertices (`s.grab.leaves`, refitted by the moves) and, as the dab sphere,
  the sphere round the bounds of the grabbed vertices' current positions; detail and collapse as the press's brush
  had them (kept in `Grab` at begin). Calls `dyn_dab_topology` repeatedly (each call is capped) until it changes
  nothing or 32 calls, refinding the leaves between calls (splits can split nodes).
- New vertices sit on the chords of the stretched triangles; a tangential smoothing pass (2 Jacobi steps toward the
  neighbours' average with the normal part removed) evens their spacing along the stretch without flattening it.
  The vertices are the ones `split_edge` made during the refine (`Dyn.fresh`, collected only while refining).
- Undo: the edits go through the same recording as dabs' do, inside the open stroke, so one undo puts the drag and
  the refinement back together.
- Cost: once per stroke; a long pull at 1M can split tens of thousands of edges (a few tens of ms). Stats
  `grab_refine_splits`, `grab_refine_ms` on exit.

## App
- `stroke_end` calls `sculpt.sculptor_grab_refine` for a grab stroke on a dynamic object before ending the grab.
  No switch: dynamic topology on means it refines. README: the dynamic topology section and the Grab row.

## Tests
- sculpt: a dynamic sphere, a Grab pulled out 1 radius: before the refine the longest edge in the moved region is
  over twice the detail; after, every edge with a moved end is at most the detail (allowing Rivara's x1.0001);
  mesh_check closed and manifold; one undo restores the original vertex and triangle counts and positions.
- Elastic the same with a smaller pull.
- touch: a Grab on a dynamic sphere, screenshot with wireframe.
