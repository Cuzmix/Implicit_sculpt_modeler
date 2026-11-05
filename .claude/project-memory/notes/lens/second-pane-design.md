# Lens P0-5: a second view grown from the thumbnail window

Spec: Lens report roadmap item 5 ("Grow the thumbnail window into a pane with its own camera, view presets and cheap passes; after-stroke refresh; maximise and restore"). The report gives it about three PRs. This is the first and P0's last: one second view, in the window the thumbnail already is. Panes tiled into the viewport (the view grid), strokes in the second view and heavy passes per pane come later.

## What exists when done
- **The thumbnail window becomes the second view.** It keeps its command (`Thumbnail`, label "Second view", and Search still finds "thumbnail"), its panel (it can float, dock in a column and be pinned by workspaces) and its after-stroke refresh. A picture is never drawn while a stroke or a turn of the view goes on, and at most every 0.1 s.
- **Camera** (a select under the picture): Follow (as now: the main camera), Front, Back, Left, Right, Top, Bottom, or Free.
  - A preset looks at the scene's middle from that side, at the main camera's distance, orthographic for the axis views. The main camera's orthographic setting doesn't matter. This is the likeness and symmetry check the Lens report's proportion use asks for, after ZBrush's and Blender's ortho views.
  - A drag on the picture by finger, pen or mouse turns its own camera, so the camera becomes Free. The mouse wheel or a pinch on the picture zooms it. Double-tap returns to Follow.
- **Pass** (a select beside the camera's): Silhouette (as now), Shaded (as now), Normals, Depth, Curvature. These are the cheap passes, drawn with the same `render.View_Pass` uniform as the viewport. AO only and the studio, which need per-pane buffers, are left out.
- **Flip** stays. **Maximise** (new) grows the window to fill most of the viewport (60% of its width, up to the space between the columns), and Restore brings it back. It is never saved: a restart or a workspace switch brings it back small, as the Lens report says.
- **Workspaces** hold the view: a `second` line (`second <camera> <pass> <flip>`), written only when it differs from Follow, Silhouette and no flip. Inspect's built-in shows Front with Shaded, the proportion check. The existing `thumbnail_shaded` and `thumbnail_flip` settings are read once into the Sculpt layout and no longer written.
- **Exit stats:** `thumbnail=` stays, plus `second_camera= second_pass= second_max=`.

## Code
- `Second_View` in `Kit_State` (`second`): `camera: Second_Camera` (Follow, Front, Back, Left, Right, Top, Bottom, Free), `pass: render.View_Pass`, `flip`, `max`. It replaces `thumbnail_shaded` and `thumbnail_flip`. `App.second_orbit: camera.Orbit` holds the Free camera.
- `second_camera(app) -> camera.Orbit`:
  - Follow returns `app.camera`;
  - a preset returns a copy of `app.camera` with `orbit_axis_view` and `ortho = true`;
  - Free returns `app.second_orbit`.
  - The first drag starts from the camera shown.
- `thumbnail_frame` takes that camera's view and projection, and `Keyed` gains the camera and pass. `thumbnail_view_draw(..., pass)` replaces `silhouette: bool`: Silhouette keeps its item recipe and paper, other passes go through `pass_items`, and Depth gets a black ground.
- Picture input: `ui.drag_delta` on the picture rect. It turns `second_orbit` with `camera.orbit_rotate` at the viewport's degrees per point, and the wheel or pinch calls `orbit_zoom`. Gestures inside the window never reach the viewport, as a window's content already doesn't.
- Maximise: the width is `THUMBNAIL_W`, or `0.6 × viewport width` clamped between the columns while `max` is set, so `kit_thumbnail_px` follows it.
- The layout: a `second` line in `kit_layout_text` (written only when it differs from the default) and a reader in `kit_layout_put`. The Inspect built-in text gains `second Front Shaded 0`. Settings migrate `thumbnail_shaded`/`thumbnail_flip` into the live Sculpt layout once.
- Tests:
  - the layout round-trip with and without a `second` line;
  - Inspect's text;
  - `second_camera` per preset (the view direction is the axis);
  - an old settings file's `thumbnail_shaded 1` becomes Shaded.
- Touch scenarios:
  - the camera select picks Front, and `second_camera=Front`;
  - a drag on the picture makes it Free and turns it, while the main camera stays still;
  - Maximise grows `thumbnail_px` and Restore shrinks it back.
- A dumped screen shows Front with Normals next to the main view.

## Not in this PR
Tiling the view grid into the viewport, linking cameras across panes, strokes and the gizmo in the second view, its own live AO or studio, wipe compare, and proportion guides.

## After review (sm-architect)
- Its own `Second_Pass :: enum u8 {Silhouette, Shaded, Normals, Depth, Curvature}` (zero is today's default) mapped to `render.View_Pass`; `Second_Camera` maps to `camera.Axis_View` by name.
- Not in the workspace layout in this PR: the camera, pass and flip stay global settings (`second_camera`, `second_pass`, `thumbnail_flip`), as the thumbnail's were; `thumbnail_shaded 1` from an older file reads as Shaded. That avoids the migration order trap (rows read before `workspaces_loaded`) and the zero-value dot; panes in layouts come with the view grid (P1). Inspect's built-in is unchanged.
- No pinch (the touch router gives two fingers on a panel to the interface) and no double tap: the wheel zooms the Free camera, and Follow in the select goes back. The picture is a `ui.area`; Free starts once the drag passes the slop, seeded from the camera shown, with the viewport's orbit sign; Free is not saved (a restart shows Follow).
- Scene lights are built for the second camera (a `viewport_lights` variant taking the camera), so a Front + Shaded view is lit as the scene is.
- `thumbnail_frame` calls `pass_items` with the second view (Depth's range from it) and Silhouette uses the pass and `pass_ground` instead of its own recipe.
- While the picture is dragged it redraws every frame (the main camera is still); otherwise the 0.1 s and after-stroke rules stay.
- Maximise only while the window floats (a docked column's width is its widest panel's); height clamped to the room; no supersampling while maximised; no size animation.
