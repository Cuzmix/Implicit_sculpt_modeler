# PR 8 design: Along, copies along a curve (Stitches and Zipper become presets)

Plan item 8. A curve whose use is Along holds copies of a part set one after another along it, each turned to the
curve's frame there and sized by the curve's radius there, live like a tube until Bake.

## Geometry (src/geom/bezier_along.odin)

`bezier_along(points, closed, part: Mesh, o: Along_Options) -> (Mesh, ok)`, pure and deterministic:

- The part is given in unit space: x across the curve (1 wide), y out from the surface, z along it; its origin sits
  on the curve.
- `Along_Options{gap: f32, alternate: bool, lift: f32, up: Vec3}`. A copy at length s is scaled by the curve's width
  there (twice the radius); the next copy starts its own depth along times (1 + gap) further on, so copies of a
  curve whose radius swells grow and spread. `alternate` turns every other copy half round N (zipper teeth). `lift`
  raises each copy along N by that share of its width. `up` is the first frame's normal: the surface normal where a
  curve was drawn on a model, so stitches lie on it; the frames follow by rotation-minimising transport
  (`bezier_frames`) with each point's twist.
- Copies are placed on a dense sampling of the curve (positions found by length, never by sample index), at most
  `ALONG_COPIES_MAX` and a vertex cap. A closed curve stops before the last copy would overlap the first.
- `curve_stitch_part` and `curve_tooth_part` (already in curve_mesh.odin) give the presets at width 1; Sphere is an
  icosphere of diameter 1.
- Tests: copy count for a straight curve with a known gap; sizes follow radius; alternate flips; closed curves don't
  overlap; deterministic.

## The object

- `Curve_Look.along: Along_Look{part: Along_Part {Stitch, Tooth, Sphere, Object}, object: int, options}`, written
  after the lathe's block, read only where bytes are left (PR 7 curves take the defaults), checked field by field.
- Part Object copies another object's current shown mesh, centred and scaled so its largest side is 1. The curve
  takes the mesh when it builds (each edit, Undo, opening); after a scene opens, curves along an object are built
  again once all objects are read, since the object may come later in the file. A missing object (deleted) makes
  nothing; the settings say so. A curve never copies itself or another curve.
- `curve_part_mesh` gains `.Along`; Bake works unchanged.

## Controls

- The Curve tool's Stitches and Zipper kinds now draw a curve with use Along and part Stitch or Tooth (Zipper with
  Alternate), `up` the surface normal at the first point, radius half the Width; they become editable. The tool's
  four kinds stay as they are, so nothing is lost.
- Settings: Use gains Along; for Along: Part tabs (Stitch, Tooth, Sphere, Object) and, for Object, a picker of the
  scene's other mesh objects; Gap slider; Alternate switch; Lift slider. One undo step each.
- Exit stats: `curve_alongs= curve_along_vertices=`.

## Left for later

Copies following each point's own scale curve (a taper graph), random jitter, and counts by number rather than gap.

## Changes after the architect review

- The Object part is out of this PR. A curve copying another object would have to rebuild whenever that object is
  sculpted, deleted, brought back by Undo, remeshed or merged. Its curves would have to build after `scene_replace`
  when a scene opens, so ids never resolve against the old scene. And a paste into another scene must not pick up
  whatever object has the same id. That needs a dependency mark in the frame, which is a design of its own.
  The parts are Stitch, Tooth and Sphere.
- `curve_part_mesh` stays pure: the parts are geometry with no scene lookup.
- `CURVE_ALONG_BYTES` is part, gap, alternate, lift and up, counted in `object_put_estimate`. Gap is clamped to
  -0.9..10, lift to -4..4, and up to a unit vector.
