# Phase 6 item 4: Posing (rotate gizmo + topological mask)

Roadmap row: "Posing: rotate gizmo + topological mask" (Z064 Transpose, Z115 Gizmo 3D topology masking, C071 3DCoat
Pose tool). Finding 33 (score 11): "Bend a limb in one flow". Finding 77: topological mask by dragging from the gizmo.

## What a user does (the one flow)
1. Move tool (W). Ctrl + drag on the model from the tip of a limb: the mask grows *along the surface* (not through
   space) from the press point as the drag lengthens. Near the press stays unmasked, a soft band follows, the rest is
   masked. The pivot lands on the soft band's middle (the limb's joint).
2. Drag the gizmo's Turn ring: the unmasked part turns about the pivot, the soft band bends, the masked rest stays.
   Move and Scale work the same way. One undo step per drag.
3. Ctrl+I / Alt+M or another Ctrl+drag for the next limb.

This is ZBrush's behaviour: with a mask, the Gizmo deforms the unmasked part instead of moving the SubTool.

## Behaviour rules
- **Pose mode** is on when the Move tool is active, exactly one object is selected, and its current level has a mask
  that is not all 255 (something unmasked to move) and not all 0 (otherwise it is a plain object move, as today).
  `object_has_mask` already answers "has a mask"; posing also needs "not fully masked" (cached with it, by history
  serial). Then gizmo drags (all handles, including the body `.View` drag) deform instead of moving the object, and the
  action bar's Gizmo group caption reads "Pose". Multi-select or no mask: today's object transforms, unchanged.
- **Deformation.** For a gizmo transform `t` computed exactly as today from `drag.start`, the local-space map is
  `M(p) = to_local(start, to_world(t, p))`. Each vertex with weight `w = (255 - mask) / 255 > 0` goes to
  `start_pos + w * (M(start_pos) - start_pos)`. Hidden vertices (fade 0) do not move; `fade` scales `w` as for brushes.
  Symmetry is not applied (a pose is one-sided, as ZBrush's gizmo).
- **Pivot.** On pose start, if the user placed no pivot (Pivot latch) the gizmo sits at the weighted centroid of the
  soft band (vertices with 0 < mask < 255); if there is no soft band, the centroid of the unmasked vertices that touch a
  masked one; else the unmasked centroid. Cached by history serial; the Pivot latch still overrides.
- **Undo.** One `.Stroke` history entry ("Pose: turn", "Pose: move", "Pose: scale") per drag, recorded at release;
  Escape or a second finger cancels back to the start positions.
- **Typed values** (tap a handle) pose by the typed amount in pose mode, as one step.
- **Levels.** Posing works on any level (levels_sync carries it like a stroke). Refused in an HD window (warning,
  as hiding is) and allowed under dynamic topology (positions only).

## Topological mask
- **Gesture.** Move tool, Ctrl + press on the model (mouse or pen), or with the rail's Mask latch on and a finger/pen
  press on the model, then drag. Ctrl+press on a gizmo handle still snaps (handles take precedence, as now). With Alt:
  the inverse (near masked, far unmasked).
- **Reach.** `reach = |drag on screen| * world-per-pixel at the press point`, so the mask follows the finger.
  Geodesic distance along edges (Dijkstra over the triangle edges from the press triangle's corners, seeded with their
  exact distance to the hit point). `mask = 0` for `d < reach * 0.75`, a smoothstep to 255 over `[0.75, 1.0] * reach`,
  255 beyond. Hidden vertices keep their mask.
- **Incremental.** One Dijkstra per gesture, extended frame by frame as `reach` grows (a min-heap of the frontier and a
  per-vertex distance array, heap-allocated for the gesture, `f32` = 4 bytes a vertex: 40 MB at 10M, freed on release).
  Shrinking just re-thresholds what was reached. Each frame rewrites only vertices whose mask value changes, through
  the stroke recorder (`record_mask` / `record_painted` / `mark_stale(.Paint)`) so the gesture is one mask undo step.
- **Pivot** moves with it: the soft band's centroid (above), updated on release.

## Sculpt API (src/sculpt/pose.odin, new file in the existing package)
- `sculptor_pose_begin(s) -> bool`: ends a stroke, refuses in HD (fade without hide), begins a stroke, builds the list of
  moving vertices (w > 0) per node and saves their start positions (heap, freed at end), records the nodes.
- `sculptor_pose_apply(s, m: matrix[4,4]f32)`: positions from the starts, parallel over the moving nodes, then
  `sculptor_nodes_moved` on them (the only vertex-moving path besides apply_dab/grab, per AGENTS.md: posing goes through
  sculptor_nodes_moved as Smooth all does).
- `sculptor_pose_end(s) -> bool` (= stroke end), `sculptor_pose_cancel(s)` (apply identity, then end without a step).
- `sculptor_topo_mask_begin(s, tri: u32, hit: Vec3, invert: bool)`, `sculptor_topo_mask_reach(s, reach: f32)`,
  `sculptor_topo_mask_end(s) -> bool`.
- `sculptor_mask_centroid(s) -> (Vec3, bool)` for the pivot.
- Determinism: Dijkstra is serial with ties broken by vertex index; pose apply is per vertex, so serial = parallel.

## App
- `move_tool.odin`: in `move_tool_frame`, when pose mode is on, `drag.start` stays the object's transform; instead of
  `obj.transform = t` it calls `sculptor_pose_apply(local map)`. `move_end` records `history_record(.Stroke, "Pose: …")`
  when `sculptor_pose_end` returns true; `move_cancel` cancels. A Ctrl press (or Mask latch) on the model in pose-capable
  state starts the topological mask instead of selecting/moving.
- `kit_action_bar`: Gizmo group caption "Pose" in pose mode. Move inspector tab: one paragraph on posing.
- Exit stats: `pose_drags`, `pose_moved` (vertices moved by the last pose), `topo_reach`.
- README (Move tool, Masking), help glossary "Pose", skills sm-sculpt / sm-touch-testing.

## Tests
- sculpt: pose turn of an unmasked half about a pivot equals the rigid turn for w = 1 and nothing for w = 0, a soft
  vertex goes partway; undo restores bit-identically; serial = parallel; hidden vertices stay.
- sculpt: topological mask on a sphere: reach grows monotonically, distance is along the surface (a vertex on the far
  side at small straight-line but large surface distance on a folded fixture stays masked: use a thin U-shaped mesh),
  shrink re-thresholds, one undo step.
- Scenarios: Ctrl+drag on the sphere then turn ring drag moves vertices (`pose_moved` > 0, object transform unchanged,
  `undo_steps` 2), Ctrl+Z puts positions back; a finger with the Mask latch makes the topological mask; with no mask
  the gizmo still moves the object (existing scenarios unchanged).

## Not in this item
- Transpose-line UI, multi-object pose (Transpose Master), rigs, mirrored posing.

## Architect review outcome (2026-10-26) — adopted
Required changes taken as written: (1) `stroke_finish` ends a pose/topological mask (split out `brush_stroke_finish`
for main's per-frame call); (2) cancel via new `sculptor_stroke_discard` (no step left); (3) `drag.posed` replaces the
transform-equality checks in move_end, the value entry and the readout; (4) no start-position copy: read the starts
from the undo step's saved nodes; (5) posing refused under dyntopo (topological mask allowed); (6) topological mask:
indexed heap with decrease-key, settle order array, per-frame vertex budget, gesture stays open until settled, reach in
local units, begin raycasts itself; (7) Turn weights the angle (rotate by w·θ), Move/Scale blend linearly, API takes a
`Pose{kind, pivot, axis, angle, delta, factor}`; (8) gestures key off `Viewport_Input.mask_shape || mask`, Alt inverts,
tap selects only, fingers go live past the slop; (9) `move_busy` covers the gesture in history_busy etc.; (10) pivot
stored in `app.move.pivot` at mask release / when pose mode turns on, carried by Move poses; (11) typed values are
offsets/factors/degrees in pose mode; (12) docs incl. AGENTS.md §5.
Suggestions taken: the body drag still moves the whole object in pose mode (only handles pose); record as `.Deform`;
HD refused app-side with one toast; Dijkstra crosses hidden triangles without writing them; "Pose:" readout prefix.

## Split
- PR 4a: sculptor_stroke_discard + pose.odin; app hooks (brush_stroke_finish split, move_busy, Mask_Seen.free,
  pose_mode, posed flag, stored pivot via mask centroid, typed values, caption/readout/stats); scenarios with masks
  made by existing tools.
- PR 4b: topological mask (sculpt + gesture + Help/README/AGENTS.md).
