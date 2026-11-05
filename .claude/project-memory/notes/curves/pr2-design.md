# PR 2 design: hold to edit a stroke

Plan: https://claude.ai/artifact/BnWpcs912G7Vtrcb6K122Y (state 6). Builds on PR 1, `src/geom/bezier.odin`.

## What the person sees
- Any Dots stroke laying dabs (a sculpting brush, Paint, Mask) on a mesh object: keep the pen (or mouse button) still
  for `Hold to edit` seconds (0.45 by default, Settings > Pen) at the end of the stroke, within `HOLD_SLOP_PX` (6 px).
  The stroke becomes a curve drawn over it: control points, handles, a white radius dot and a green intensity dot per
  point (Each), or one of each at the middle (One).
- Lifting the pen keeps the stroke open. Drag a point, handle, radius dot or intensity dot: the stroke is laid again.
  Tap a point: smooth ↔ corner. Tap the curve: a point there. Drop a point on its neighbour: they merge.
- The context bar (`kit_action_bar.odin`) shows a new group `Stroke`: Validate, Cancel, Radius One/Each, Intensity
  One/Each. The brush card shows Smoothness (the fit tolerance; changing it fits the drawn path again).
- Validate (Enter, or a press anywhere that is not on the curve, which then starts the next stroke) ends the stroke as
  one undo step, on the active sculpt layer. Cancel (Esc) puts the surface back and records nothing.

## Where it is refused (the hold does nothing; the stroke ends as drawn)
Grab, Snake hook, Cloth, Rectangle, Drag dot, Spray, Roll, a straight line or joined stroke, dynamic topology, voxel
clay, HD windows only where `sculptor_stroke_restore` refuses (the same rule as the Line switch: `line_allowed`), and
while a Take records (a take replays pointer samples, and a hold's timing is wall time, so the replay would differ).

## How it works (no new sculpt API)
- `Stroke` gains `path: [dynamic]Stroke_Path_Point{at: Vec3 (object space), pressure: f32}`, appended in `stroke_dab`
  after each hit, cleared by `stroke_start` and `stroke_restart`; and the hold watch `still_pos`, `still_since`.
- New file `src/app/stroke_edit.odin`, `Stroke_Edit{open, points: [dynamic]geom.Bezier_Point, radius_each,
  intensity_each, smoothness, drag (what is held), dirty, relay_at (progress of a bounded re-lay)}` on `App`.
- Entering: `geom.bezier_fit(path positions, smoothness · mean dab radius)`; each point's radius and intensity start
  from the pressure at its source sample through `pressure_sized` and `pressure_curved` (so the first re-lay matches
  what was drawn); Each is on when they differ by more than 10 %, else One with their mean.
- Re-lay, at most once a frame and only when `dirty`: `sculpt.sculptor_stroke_restore` (exactly what the Line switch
  does), then walk the curve in object space: `geom.bezier_sample` at a fine step, a dab each time the travelled
  length reaches `dot_spacing · radius_world(at) · point radius`. Each dab goes through `stroke_dab` at the sample's
  screen projection under the current camera with pressure 1 and `Dab_Scatter{size = radius, strength = intensity}`,
  so `apply_dab`, symmetry, Even strength, alpha and mask all hold. Bounded by `MAX_DABS_PER_FRAME` and
  `MAX_BRUSH_MS_PER_FRAME` like `line_lay`, continued next frame from `relay_at`; a new edit restarts it.
  Orbiting while editing re-lays nothing; the next edit lays the dabs from the new view onto the same surface points.
- Validate: finish any re-lay unbounded (as `line_complete`), then `stroke_finish`. Cancel: restore, then end the
  sculptor stroke with nothing changed, so `history_record` keeps no step (checked in a test).
- Tool change, object change, scene replace, undo or redo while open: Validate first (as a mid-stroke tool change
  ends the stroke today), except undo/redo, which Cancel.
- Overlay: drawn in `draw_curve_overlay`'s neighbour in `overlay.odin`, from the points projected each frame.
- Input: while open, `sculpt_frame` routes presses to `stroke_edit_frame` first; one that hits nothing validates and
  falls through to `stroke_start`.

## Files and tests
- `stroke_edit.odin`, `sculpt_tool.odin` (path, hold watch, routing), `kit_action_bar.odin` (Stroke group),
  `commands.odin` (Stroke_Validate, Stroke_Cancel, Stroke_Radius_Each, Stroke_Intensity_Each), `overlay.odin`,
  settings (hold seconds, on/off), README Controls, Help.
- App tests: a held stroke opens; the first re-lay equals the drawn stroke within the fit's error (positions compared);
  a moved point changes only nodes near it; Cancel leaves the mesh bit-identical and no History entry; Validate is one
  entry; refused cases do nothing. Touch scenario `stroke_hold_edit` (press, drag, hold, drag a point, Validate).

## Open choice with a default
Pen pressure after the fit lives in the points' radius and intensity, not in a pressure curve along the stroke. That
matches Nomad and keeps one model for all uses; the first re-lay differs from the drawn stroke only by the fit.

## Changes after the architect review (approved with changes)
1. Cancel uses `sculpt.sculptor_stroke_discard`, sets the stroke inactive and records nothing in the History.
2. While the edit is open, `sculpt_frame` hands every frame (hover, press, release) to `stroke_edit_frame` before its
   release branch, so lifting the pen does not end the stroke.
3. The edit closes inside `brush_stroke_finish` (validating), so every caller (tool switch, jobs, files, replays,
   commands) closes it.
4. Undo and redo Cancel the edit first (`history_busy` blocks them while a stroke is active); autosave waits as for
   any stroke under way.
5. The re-lay lives in `sculpt_tool.odin` beside the private `stroke_dab`/`brush_at`, `stroke_edit.odin` holds the
   state, input and overlay.
6. The re-lay uses the stroke's own invert and smooth mode, not the live modifiers; tilt is kept per point.
7. No screen projection: each dab goes straight to the object-space sample (`object_dab` with
   `object_normal_local`), with the world radius taken at entry, so orbiting changes nothing.
8. Edits during a drag coalesce as `line_lay` does: the lay under way finishes, then starts again if the curve changed.
Voxel clay is refused explicitly.
