# PR 7 design: Lathe, a curve's second use

Plan item 7 (mock: "The curve spun round the view's vertical, world X, Y or Z, with an angle and segment count").
A curve whose use is Lathe holds the surface made by spinning it round an axis, live like a tube until Bake.

## Geometry (src/geom/bezier_lathe.odin)

`bezier_lathe(points, closed, o: Lathe_Options) -> (Mesh, ok)`, pure and deterministic:

- `Lathe_Options{axis: Vec3, through: Lathe_Through, angle: f32, segments: int, caps: bool}`. `axis` is the direction in
  the curve's own space; `through` says which point the axis passes through: `Start` (the first point, the default,
  so a half outline drawn from the axis outward spins into a vase), `End`, or `Middle` (the curve's origin). Computed
  from the points at build time, so editing the points keeps the axis where the user expects.
- The curve is sampled at even steps sized so the quads come out about square (circumference at the widest place over
  `segments`, at most `LATHE_RINGS_MAX` rings). Each sample becomes a ring of `segments` points round the axis
  (`segments + 1` for less than 360 degrees). A sample on the axis becomes one pole vertex, so a profile whose ends
  touch the axis closes into a watertight solid with no degenerate triangles.
- `caps`: an open curve's ends off the axis are closed with a fan onto the axis. A closed curve spins into a torus
  and has no caps. Less than 360 degrees leaves the two sides open.
- Winding: the triangles are flipped as a whole if the signed volume about the axis is negative, so the result always
  faces out whichever way the curve was drawn.
- Tests: a half circle with its ends on the axis gives a closed sphere facing out, two poles, about the right volume;
  ends off the axis with caps is closed, without caps has two boundary loops; 180 degrees has open sides; a closed
  curve gives a closed torus.

## The object

- `Curve_Use.Lathe` already exists. `Curve_Part.lathe: geom.Lathe_Options`, written after the tube's options in
  `curve_part_put`, read only where bytes are left (a PR 6 curve reads with the defaults), checked field by field
  (a finite non-zero axis, a known `through`, angle 1 to 360, segments 3 to 256, caps 0 or 1; a block only partly
  there is damage). Same Curve_Look scene command, which gains the lathe options; one undo step per change.
- `curve_part_attach` builds the lathe for `.Lathe` as it builds a tube for `.Tube`; Bake works for any use whose
  level has triangles, so a lathe bakes the same way.

## Controls

- The selected curve's settings: Use tabs become Line, Tube, Lathe. Picking Lathe sets the axis to the view's
  vertical in the curve's space (Nomad's default). For Lathe: Axis tabs View (sets it to the view's vertical now),
  X, Y, Z (world axes in the curve's space); Through tabs Start, End, Middle; Angle slider (degrees); Segments slider;
  Caps switch for an open curve.
- While a Lathe curve is selected in the Curve tool, its axis is drawn as a dashed line over the view.
- The chip says "Curve · Lathe".

## Exit stats, README

`curve_lathes=` (curves with use Lathe). README's Curve paragraph gains Lathe. Touch scenario: a curve drawn by pen
switched to Lathe from the palette (a script verb `curve_use lathe` is not needed: the palette has Set curve use),
looked at.

## Left for later

Moving the axis by dragging it on screen, and the selected object's axis as a choice, come with the Model mode
Lathe cage (PR 10), which needs the same axis picking.

## Changes after the architect review

- One `curve_part_mesh(cp)` picks the mesh by use, so attaching and Bake both build lathes and tubes.
- Segments are written as u16 (`CURVE_LATHE_BYTES`). Tests cover a cut-off lathe block (refused), a PR 6 curve (lathe
  defaults) and an axis of zero (refused).
- `Curve_Look {use, tube, lathe}` is one value: `Curve_Part` embeds it, and the scene command carries it whole. The
  command carries the computed axis, never "View", so the shape never moves with the camera and undo restores it exactly.
- Exit stats count tubes and lathes by use.
- Choosing Lathe for a closed curve puts the axis through Middle, so a loop spins into a ring rather than pinching.
- Which way the surface faces comes from the profile (the sign of the sum of r² dh), not the mesh. A flat profile
  faces +axis, so the result is deterministic either way.
- Points are capped at `LATHE_VERTICES_MAX`. Angles within half a degree of 360 count as a whole turn.
- Middle is the curve's origin, which stays put as points are edited (README says so).
- Not done: a profile that crosses the axis, or runs along it in the middle, still spins (overlapping, or touching
  at a point). Cutting it at the axis comes with the axis drag in PR 10.
