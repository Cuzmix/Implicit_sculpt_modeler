# PR 11 design: Spine, Extrude and Knife follow a curve; Loop to curve

Plan item 11. The mock says: "Spine and Extrude: press a face, then tap a curve to follow it. Knife: tap a curve to
cut along it. Edge loop to curve: makes a curve from a picked loop." No new Scene_Command, no file change, no new
undo kind: every change is one existing swap entry (the cage's `history_snapshot` / `model_commit`, or
`curve_object_add`'s own).

## Gestures (one gesture each, nothing new to learn)

- **Spine**: press on a face as now and lift over a curve (the pen within `CURVE_PICK_PX` of its line): the faces
  grow along the curve instead of the path drawn. The path is the curve in the cage's space, started at the end
  nearer the faces' middle (a closed curve at its point nearest it, round and back), moved so that start sits on the
  faces' middle. The size along the way is the curve's radius over its radius at the start (as a pen's pressure
  sets it on a drawn path), clamped as now. Symmetry mirrors it as now. The view need not look across the faces.
- **Extrude**: press a face and drag as now; lifting over a curve puts the cage back as pressed (the extrude drag
  keeps a copy, as Bevel does) and grows the faces along the curve as Spine does, one undo step (the drag's own
  snapshot). A lift anywhere else is the plain extrude.
- **Knife**: a tap on a curve cuts the pressed or selected cage along the curve's line as seen, as if the line were
  the stroke; a closed curve whose first and last cuts share a face closes the cut. A tap on an edge away from
  curves is the multi-cut tap as now.
- **Loop to curve** (new Model action, last in the enum so stored indices hold, targets Edge loop and Border loop):
  a tap on an edge makes a curve object through its loop's points as shown (`cage_point`), smooth points, closed for
  a closed loop, radius a tenth of its mean edge, as ZBrush's Frame mesh makes curves from edges. Also a button in
  the curve's Cage from curve section.
- While Spine, Extrude or Knife is in hand, the curve under the pen is drawn in the selection colour, so the user
  sees what will be followed before lifting.

## Code

- `model_tool.odin`: `model_spine` split into the faces' base (middle, normal, step), the path (drawn or
  followed) and `model_spine_grow` (steps, mirror runs, `spine_faces`, commit) which Extrude's follow calls too.
  `model_follow_path(app, cage_obj, curve_obj, middle)` gives path and scale. `model_knife` gains `close`.
  `model_loop_curve`.
- Exit stats: `model_follows=` (Spine, Extrude and Knife along a curve) and `model_loop_curves=`.
- Tests: `model_follow_path` on a straight and a closed curve (start, direction, scale) in app tests; touch
  scenarios: Knife tap on a drawn curve cuts the cube; Spine lifted on a curve grows along it; Extrude lifted on a
  curve grows along it; Loop to curve makes a curve; each one undo step.

## Left out

The curve's twist does not turn the faces (spine steps carry no roll); a curve far from the faces is moved to them,
never followed where it lies.
