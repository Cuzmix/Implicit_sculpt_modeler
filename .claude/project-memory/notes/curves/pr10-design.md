# PR 10 design: Pipe and Lathe cages from a curve (Model mode)

Plan item 10. These are quad cages made from a selected curve, as Nomad's Pipe and Lathe build low meshes for modelling.

- `src/poly/curve_cage.odin`:
  - `pipe_cage(points, closed, Curve_Cage_Options{around, steps, caps}, up)` puts a ring of `around` points at each curve point, with `steps` more rings between points. The rings are placed by the curve's own parameter, so a ring always sits on each control point. Each ring takes the radius at its place and is turned by rotation-minimising frames. The faces are quads; an open pipe gets n-gon caps. The ring at a corner point is creased infinitely sharp.
  - `lathe_cage(points, closed, lathe, options)` spins the same rings round the lathe axis. A point on the axis becomes a pole, ringed by triangles. Faces point outward, using the same profile-volume rule as `geom.bezier_lathe`. Corner rings are creased.
  - Built through `mesh_from_polygons`, so the result is an ordinary half-edge cage.
  - `geom.bezier_controls` and `bezier_blend` become public so poly can sample by parameter.
- Scene command `Curve_Cage`, where `on` means lathe.
  - `curve_make_cage` builds the cage (`object_build_cage`) as a new object after the curve, with the curve's transform and folder, and selects it.
  - It is one undo step (`history_record_added`). The curve stays.
  - A lathe uses the curve's lathe options; if the curve has never been a lathe, the axis is the view's vertical.
- Controls:
  - Commands Pipe cage from curve and Lathe cage from curve.
  - A "Cage from curve" section (Around, Steps between points, Cage caps, the two buttons) in the curve's settings and in the Model palette when a curve is selected.
  - The object menu's Model verbs for a curve.
- Exit stat `curve_cages=`. Unit tests in poly. Touch scenarios for both cages, with their screenshots checked.
- No file change and no undo kind beyond the existing added-object swap.

## Changes after the reviewer's pass
- A pole is now a separate point for each fan that meets it. Before, a run of on-axis samples left points no face used, and a profile touching the axis between two rings shared one pole across two fans (non-manifold).
- A partial lathe now creases its corner rings without wrapping round.
- Tests added: a closed half-section, an interior touch on the axis, a partial turn, and pipe faces pointing out.
