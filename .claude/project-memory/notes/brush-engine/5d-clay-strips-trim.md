# 5d Clay strips, Trim dynamic, Flatten's plane height and depth: design note (2026-10-29)

Goal: the two hard-working brushes our set lacks, from Blender's source and named for what ZBrush users reach for:
**Clay strips** (ZBrush's ClayBuildup, Blender's Clay Strips) lays flat-topped strips with square ends that follow the
stroke, and **Trim dynamic** (ZBrush's TrimDynamic, Blender's Multiplane Scrape) cuts a ridge into two planes for hard
surfaces. Flatten gains **Plane height** and **Plane depth** (Blender's Plane brush, where Fill and Scrape are its two
halves). The library's existing "Trim" preset (a Flatten) keeps its name; the new kind is "Trim dynamic".

## New kinds
- `sculpt.Brush_Kind` gains `Clay_Strips` and `Trim_Dynamic` at the end (the enum's values are stored in settings by
  name and in `.strokes` as a byte, so appending keeps every file).
- Both read the area (job_area), honour Lock plane, Stabilize orientation and Sample radius (brush_locks_plane), and
  take alphas as Clay does (an alpha replaces the tip). Not voxel brushes (voxel_brush_allowed refuses them, as it does
  Crease). Category: Clay strips under Clay, Trim dynamic under Smooth (with Flatten and Hard polish).

## The brush frame
- `Brush.stroke_dir`: the way the stroke last went, in the mesh's space (from the previous dab's hit to this one's,
  made by the app; zero on the first dab, which then takes any tangent). sym_brush turns it with each image.
- Frame per dab: z = the area normal n, x = stroke_dir with its n part removed, normalised, y = n x x.

## Clay strips (Blender clay_strips.cc, ours)
- A cube tip: local (u, v) = (x . delta, y . delta) / r, u scaled by 1 / Tip scale (0.25 to 1, default 1: Blender's
  tip_scale_x, a narrower strip along the stroke). Distance d = |max(|(u, v)| - (1 - roundness), 0)| / roundness with
  Tip roundness 0 to 1 (default 0.2); roundness 0 is the square's max norm. The weight is the brush's falloff at d^2
  (built-in, drawn, focal shift and hardness all apply), so the square's corners reach r sqrt(2): the dab's reach is
  r sqrt(2) (the BVH query and d.r2).
- The plane sits CLAY_HEIGHT r above the area plane (Ctrl: below). A vertex at h = (p - plane) . n below the plane
  (above it for Ctrl), within one radius of it, rises toward it by `strength x CLAY_STRIPS_RATE x r x w x 4z(1 - z)`
  with z = -h / r, never past the plane. The z(1 - z) weight is Blender's build-up: vertices well under the plane move
  most and those just under it least, so a strip fills from the middle of its depth and its top stays flat; Plane trim
  is the plane itself (nothing above it moves).
- Pressure: the brush starts on its own response, size p^1.5 with a 0.3 floor (Blender's) and strength linear, as Clay
  starts on Clay's (brush_defaults); Use global takes the global curves as for any brush.
- Settings `clay_tip_roundness`, `clay_tip_scale`; Options shows them for Clay strips.

## Trim dynamic (Blender multiplane_scrape.cc)
- Two planes through the area centre, their normals n turned by +a/2 and -a/2 about x, a the angle. A vertex on the
  +y side takes the first, on the -y side the second; one above its plane (h > 0) is pulled onto it by
  `min(strength x w x PLANE_RATE, 1)` (Ctrl: the angle negated, a valley). Below the planes nothing moves.
- Dynamic (on by default): the angle is sampled per dab from the area normals of the two sides (each a falloff-weighted
  sum over the vertices with y > 0 or y < 0): a = the angle between them about x where the ground is convex, 0 where
  concave (flat planes, no cut), clamped to TRIM_ANGLE_MAX (160 deg), then eased 0.2 a dab toward the last one (kept in
  Sculptor.trim_angle, reset at stroke begin). Off: Angle (0 to 160 deg, default 60) is used as set.
- Settings `trim_angle`, `trim_dynamic`.

## Flatten's plane height and depth
- `Brush.plane_height`, `plane_depth`, 0 to 1 of the radius (default 1): Flatten moves a vertex above the plane only
  within plane_height r of it and one below only within plane_depth r. Height 0 is Fill (only raises), depth 0 Scrape
  (only cuts). At 1 and 1 nothing changes from today (the dab's reach is a radius anyway).
- Settings `plane_height`, `plane_depth`; Options shows them for Flatten.

## Files
- Presets: named values tip_roundness=, tip_scale=, trim_angle=, trim_dynamic=0, plane_height=, plane_depth=.
- `.strokes` version 28: the six values after 27's.
- Built-in presets: "Fill" (Flatten, depth 1, height 0) and "Scrape" (Flatten, height 1, depth 0).

## Tests
- sculpt: Clay strips on a flat grid: a dab's moved region is square (a vertex at (0.6, 0.6) r moves, where Clay's
  round dab leaves it), the strip's top is flat (heights in the middle within 10% of each other after 8 dabs), turns
  with stroke_dir, serial == parallel. Trim dynamic on a roof ridge: the top comes down, the flanks below the planes do
  not move, the sampled angle is near the roof's; on a valley it does nothing. Flatten height 0 leaves what is above
  the plane, depth 0 what is below.
- app: presets round trip, `.strokes` v27 downgrade.
- touch: a Clay strips stroke and a Trim dynamic stroke over a ridge, screenshots. Bench rows at 1M and 10M.
