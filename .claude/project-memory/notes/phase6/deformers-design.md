# Phase 6 item 8: deformers (bend, twist, taper, lattice)

Roadmap row: "Deformers: bend, twist, taper, lattice | Z067, N022, C071 | L". ZBrush has 27 gizmo
deformers, Nomad a lattice (2.9), 3DCoat bend/twist/lattice; Nomad users round-trip to Blender
for this. We have posing (sculpt/pose.odin): a gizmo drag moves, turns or scales the part a
mask leaves free, one stroke from the saved start positions, one undo step.

## What will exist

- Object tab > Deformation gains a **Deformers** part: kind tabs Bend / Twist / Taper / Lattice,
  axis tabs X / Y / Z (the object's own axes), and an **Amount** slider.
- Dragging Amount deforms the part the mask leaves free (the whole object with no mask), live
  every frame, from where the drag began; letting go is one undo step ("Bend", "Twist",
  "Taper"). The slider springs back to 0 after the step, so each drag is a fresh relative
  deformation (as ZBrush's deformer sliders do once applied); the result line says what it did
  ("Bent Sphere 1 by 40° along Y (12 ms)") and Adjust last operation re-runs it with a new
  amount.
- More (Basic/More rule, at most 5 Basic controls): "Fixed end" (- or +) for Bend and Taper, and
  "Toward" for Bend (one of the two other axes, with a sign from the amount's sign).
- **Lattice**: a switch "Show lattice" with Points 2 to 5 per side. With the Move tool on, the
  lattice's points are drawn round the free part (in its bounds, padded) and a point dragged
  (mouse, finger or pen) deforms the free part smoothly (Bernstein FFD, Sederberg-Parry). Each
  point drag is one undo step "Lattice". Any other step (undo, a stroke) puts the lattice back
  at rest round the surface as it is then.

## Sculpt side (src/sculpt/pose.odin, about 150 lines)

`Pose_Kind` gains `Bend, Twist, Taper, Lattice`. `Pose` gains:

    along:  Axis   // Bend/Twist/Taper: the axis the deformation runs along
    toward: Axis   // Bend: the axis it bends toward (amount's sign picks the side)
    from_plus: bool // Bend/Taper: the fixed end is the + end
    amount: f32    // Bend/Twist: radians over the range; Taper: the far end's scale - 1
    lattice: Lattice_Move // Lattice: box, points per side, the point and its offset

`sculptor_pose_begin` also finds the free vertices' bounds in the mesh's own space (one more
reduction in the same parallel pass, summed per node and merged in node order, so serial and
threaded results are bit-identical), kept as `s.pose.box` and returned by
`sculptor_pose_box(s)`. Bend/Twist/Taper run over that range along `along`, from the fixed end.

Per free vertex at start `a`, weight `w = shield(...)` (unchanged rule: masked and hidden stay,
half-masked goes half):

- **Twist**: `t = clamp((s - lo) / L, 0, 1)`, s the coordinate along the axis; turn about the
  axis line through the box centre by `w * t * amount` (Rodrigues, as Turn uses, so distance to
  the axis is kept).
- **Taper**: scale the across-axis part about the axis line by `1 + w * t * amount`
  (amount from -0.95 to 3).
- **Bend** (Blender's SimpleDeform bend, written out): with L the range, R = L / amount,
  s' = s - lo (or hi - s from the + end), x the coordinate toward `toward`: inside the range
  φ = s' / R, s'' = (R - x) sin φ, x'' = R - (R - x) cos φ; past the far end the rest
  continues straight along the tangent; before the fixed end nothing moves. A half-free vertex
  goes to `lerp(a, bent, w)`. Near amount 0 (|amount| < 1e-5) it is the identity.
- **Lattice**: FFD is linear in the points' offsets, so one point's drag moves each vertex by
  `w * B_i(u) B_j(v) B_k(w) * offset`, (u, v, w) its place in the rest box; outside the box
  nothing moves. Successive point drags therefore compose exactly with no lattice state in the
  sculptor; the app keeps the points to draw them.

Then `sculptor_nodes_moved` as every pose does (layers, normals, culling, undo ranges all as
today). Not under dynamic topology or in HD, as posing already refuses.

## App side (about 250 lines plus the lattice overlay, about 200)

- `src/app/deformers.odin`: the panel part, `deform_drag_*` following the layer strength drag
  (begin on the first change while pressed: `stroke_finish`, `pose_begin`; apply each frame;
  end when the pointer lets go or before a scene command or undo, through a
  `deform_drag_finish` called where `layer_drag_finish` is), the result report and Adjust last.
- Lattice: `Lattice_View` in `App.move` (box, points, rest offsets, the history serial it was
  made at); drawn in `overlay_viewport` with `overlay_line`/`overlay_disc`; a point is picked
  before gizmo handles when "Show lattice" is on, the drag projects the pointer onto the plane
  facing the camera through the point (as the gizmo's free move does), and each frame poses
  with that point's offset.
- Commands (registry): Bend, Twist, Taper open the section with that kind (palette finds
  "bend"); Show lattice is a toggle command. Settings remembers kind, axis and lattice points.
- No file format change: deformers leave plain vertex positions; the lattice is not saved.

## Undo

A deformer drag is a stroke like a pose: saved positions of the free nodes, recorded as
`.Deform` with its name. No new History kind, no snapshot, no change to `History`.

## Tests

- sculpt: each kind against a closed-form expectation on a small mesh (twist of a vertical
  bar turns the top by amount, keeps radius; taper's far end scales by 1 + amount; bend's arc
  length along the axis is kept and its far end's tangent turns by amount); masked vertices stay;
  a half-masked vertex goes half; threads match one thread bit for bit; amount 0 is the
  identity; two lattice drags equal one drag of the summed offsets (linearity); undo restores.
- app: a slider drag is one step, a scene command mid-drag ends it first, undo mid-drag too.
- touch_check: `deformers` scenario (drag Amount with mouse, finger, pen; one step each), a
  lattice point drag with finger and pen.
- PNG of a bent cylinder (`--primitive=cylinder`), a twisted cube and a lattice-pulled sphere.

## Split

- 8a: Bend, Twist, Taper (sculpt kinds, panel, drag, commands, tests, scenario, README).
- 8b: Lattice (kind, overlay, picking, drag, tests, scenario, README).

## Cost

One parallel pass over the free nodes per frame of a drag, as a pose turn: expected under a
few ms at 10M on the desktop (measured in the PR with `--frames` stats on release).

## Architect review (adopted, 2026-10-26)

Verdict: adopt 8a with changes; rework lattice composition before 8b. Adopted:

- R1 Lattice composition: the sculptor keeps each free vertex's place in the rest box (12 B per
  free vertex, about 120 MB at 10M, only while the lattice is shown), so each point drag moves
  `start + w·B(rest place)·Δoffset` and drags compose exactly; the drawn cage then matches.
  Freed when the lattice is hidden or reset.
- R2 Bend in f32: φ = s'·amount/L, s'' = s'·sinφ/φ − x·sinφ, x'' = x·cosφ + s'·2sin²(φ/2)/φ,
  with a series below |φ| 1e-4; no R. x is measured from the box centre. Amount capped so the
  bend never folds over itself (R at least the half extent toward `toward`).
- R3 A section of its own, Deformers (Surface page), not inside Deformation: Bend's widest
  state is kind, axis, Amount, Fixed end, Toward = 5; Lattice's is kind, Show lattice, Points.
- R4 Twist gets Fixed end too; with a mask, the default fixed end is the box end nearest the
  mask's soft edge (sculptor_mask_centroid), so a freed limb stays attached at the joint.
- R5 Ending the drag: not in stroke_finish (the frame runs it whenever the viewport is not
  pressed, which a slider drag is not), so a `ui_drags_finish` ends the layer and deformer
  drags wherever a command runs (the registry's run, scene_apply, undo and redo).
- R6 Lattice point drags are `app.move.drag` with posed = true, so move_end, move_cancel,
  Escape, gesture cancel and history_busy cover them.
- R7 `sculptor_free_bounds(s)` starts nothing; the app caches it by the Pose_Seen key.
- R8 Lattice reset key is (id, level, levels, serial), the serial stored after its own step.
  Lattice is not in Adjust last.
- R9 Zero length along the axis (a flat free part) and a degenerate box refuse with a note.
- R10 Lattice touch: the gizmo hides while the lattice shows; the nearest front-most point is
  picked; Points 2 to 4.
- R11 Adjust last keeps kind, axis, fixed end, toward and amount; its popover shows the real
  Amount; the re-run recomputes the same box.
- Nits: Bend scales the angle by w (as Turn and Twist do) instead of lerp; the before/after
  range branches are dropped (the box is the free bounds); bounds are min/max per node, order
  free; the controls disable in HD and under dynamic topology; README says Taper at a lower
  level keeps full-size detail.
- 8a as built: the section's kind and axes are not remembered across runs (like the
  Deformation section's Smooth settings); the palette's Bend/Twist/Taper open and scroll to
  the section. Review fixes: Auto's end is found only when a drag starts; a drag ended under
  a held pointer waits for the release; a deformation adjusts only on its own level.
