# PR 6 design: Tube, a curve's first use, and Bake

Plan item 6 (mock state 2). A curve object whose use is Tube shows a live tube swept along it, rebuilt as its points
change, until Bake makes a sculptable mesh of it.

## Geometry (src/geom/bezier_tube.odin)

`bezier_tube(points, closed, opts) -> (Mesh, ok)`: the curve sampled at even steps (`bezier_sample`, spacing from
`opts.density` rings per unit of the mean radius), rotation-minimising frames with each point's twist
(`bezier_frames`), and at each ring the profile scaled by the radius there:

- `Tube_Options{profile: Tube_Profile, sides: int, radius: Tube_Radius, one: f32, caps: Tube_Caps, flatness: f32}`.
- `Tube_Profile :: enum {Round, Square, Ribbon, Star, Half_Round}`: a closed 2D outline of `sides` points (Ribbon a flat
  rectangle `flatness` thick, Star five points, Half_Round a D with its flat side down the surface normal).
- `Tube_Radius :: enum {One, Ends, Each}` as Nomad cycles it: One uses `one` everywhere, Ends blends the first point's
  radius to the last's along the length, Each the points' own radii as sampled.
- `Tube_Caps :: enum {Flat, Round, Open}`: a fan, a hemisphere of rings shrinking by a quarter circle, or nothing.
  A closed curve has no caps and joins its last ring to the first.
- Pure, deterministic, no allocation left behind but the mesh; tests: ring and vertex counts, a closed loop is
  watertight (`mesh_check`), radius modes, caps.

## The object

- `Curve_Part.tube: Tube_Options`, written after the points at the end of `curve_part_put` and read only where bytes are
  left (a curve from PR 4 reads with the defaults). `use` already exists.
- A curve's one level holds the tube (empty for `.None`). `object_draws_triangles` becomes "not a curve, or a curve whose
  level has triangles", so the frame, thumbnails and picking treat a tube like any mesh; `object_editable` still refuses
  it, so brushes, masks and mesh commands do not touch it.
- `curve_rebuild(app, obj)` makes the tube again: `render.wait_idle`, the level and its buffers released and made from
  the new mesh. Called after each edit and at most once a frame while a point is dragged (a tube of 16 sides and a few
  hundred rings builds in well under a millisecond; a job is only worth it past that, measured in the PR).
- Reading (file chunk, snapshot, Duplicate, Paste) builds the tube from the points, so nothing derived is stored.

## Controls

- The Curve tool's **Tube** kind now draws a curve object with use Tube (radius from Width, Lift as an offset of the
  points along the surface normal, Sides), so today's tube becomes editable. Stitches and Zipper stay until PR 8.
- With a curve selected, the tool's card shows **Use** (None, Tube) and, for Tube: Profile, Radius (One, Ends, Each; One
  shows a slider), Sides, Density, Caps, and Flatness for Ribbon. Each change is one undo step of the curve.
- **Bake** (context bar and the object menu's conversion row, `Curve_Bake`): a new mesh object of the tube, in the
  curve's place, selected; the curve is hidden (its eye off) so it can be taken back; one undo step (two chained swaps).
- An `Object_Type.Curve` gives the chip "Curve", a spline icon, its menu verbs (Bake; Close) and Bake as its conversion.

## Exit stats, tests, README

`curve_tube_vertices=` (all tubes' vertices) and `curve_bakes=`. Tests: geometry as above; a Tube curve has triangles
and is still refused by brushes; reading a PR 4 curve gives default options; Bake adds a mesh object and hides the
curve. Touch scenario: a tube drawn by pen, a point dragged, Bake; a screenshot looked at.

## Left for later

A drawn profile, per-point profiles, the taper graph and live mirror X are not in this PR: they come after Lathe and
Along, so the uses settle first.

## Changes after the architect review

- Bake: a hidden curve could not be undone (history_swap carries the live eye over), so Bake adds the mesh and deletes
  the curve as one chained step, as the live boolean's apply does; Undo brings the curve back as it was. "Keep the
  curve" is Duplicate, then Bake. (Differs from round 1's "Bake keeps the curve hidden": the same going back, by Undo.)
- Curves are left out of `scene_raycast_surface` while drawing and dragging points, so a point never climbs its own
  tube.
- `curve_rebuild` copies `cage_rebuild`: autosave settles, the curve is taken off the object, wait_idle, release,
  rebuild, the curve put back. It runs at most once a frame during a drag (timed in the PR).
- `curve_part_get` takes the app and returns (read, made), so a GPU failure is one; `object_discard` frees a curve.
- Tube options are written field by field after the points, checked (enums, sides 3 to 64, finite floats, a block
  only partly there is damage), in a fixed order Lathe and Along append after.
- A tube is printed and exported like any shown object; a press on a tube in Sculpt picks it and is refused, as a cage.
- `Object_Type.Curve` with Bake as its conversion and verbs in every space; Bake is a Scene_Command.
