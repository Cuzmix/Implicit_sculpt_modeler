# Round 2, PR 1: full-window viewport (Lens)

Screens `sculpt2`, `stroke2` and `clean2` in `/mnt/project-files/ui-direction/round2/screens.js`. This applies to the Lens chrome only: Classic is unchanged except where noted.

## What exists when done

- **Viewport fills the window.** In Lens the grid's room is always the whole window, as if "Views run under panels" were on. That switch is hidden in Lens.
- **See-through top bar.** The Lens top bar is drawn in the frame colour at 74% opacity over the picture, with a white 6% hairline along its bottom, as `.topbar.glass` is. There is no blur: the kit does not blur.
- **Panels fade under strokes.**
  - While a viewport drag with the primary button, finger or pen is held, any panel whose last rect the pointer enters fades to 25% for the rest of that drag (tween `t.hover_time`). It comes back when the pointer lifts.
  - The stroke stays the viewport's: the kit already gives a drag that began in the viewport to the viewport.
  - Applied in `panel_begin`/`panel_end` (a vertex mark and `transform_since`), so it covers the tray, Stats, History, cards and pinned sections, docked or floating.
- **Clean view** (`Clean_View` command; Search "clean", "hide interface", "zen"):
  - It hides all chrome. With "Keep the dial in clean view" on (Settings > Interface, the default; settings row `clean_view_dial`), only the modifier wheel stays.
  - A hint, "Tab or four-finger tap to bring the interface back", shows at the top centre for 3 s.
  - Tab, the four-finger tap or Escape brings the chrome back.
  - Keys: in Lens the default Tab goes to Clean view instead of Palettes (`keymap_rebuild` swaps the default binding while the chrome is Lens). In Classic, Tab stays on Palettes.
  - Four-finger tap's default gesture becomes Clean view (it was empty).
  - Exit stats: `clean_view=`.
- **Frame uses the free area.**
  - `camera.Orbit` gains `shift`: the point the target projects to, in half-heights from the viewport's middle (x right, y up). `orbit_proj` applies it as an NDC translation, so every ray, overlay and picture follows it.
  - `orbit_zoom_toward` and `orbit_roll_about` measure their offsets from that point.
  - The target stays on the model, so turning still turns about the model while it sits in the middle of the free area.
  - In Lens with one view, Frame all, Focus selected and Reset camera set the shift to the centre of the area left free by the chrome: the top bar, the brush bar, the view bar, the modifier wheel's corner aside, the right-hand panels and the dock. They also fit the distance to the smaller side of that area.
  - At start-up, once the chrome has been laid out (frame 3), Lens sets the shift alone.
  - Second views, view panes, thumbnails, the scene preview and the grid's lent cameras drop the shift. Switching to a grid preset, or to Classic, zeroes it.
  - Not saved anywhere, as the shift depends on the layout. Replays keep the camera they recorded, which has no shift; a replay plays in its own frame.
  - Exit stats: `camera_shift=x,y`.

## Tests

- Camera unit test: with a shift, the target projects to the shifted point; zooming toward that point keeps it in place.
- App unit test: the keymap swaps Tab to Clean view under Lens and keeps it on Palettes under Classic.
- Touch scenarios (Lens):
  - Tab toggles clean view (`clean_view=1`, then 0);
  - a four-finger tap does the same;
  - Escape leaves clean view;
  - a stroke that crosses the tray fades it (a new stat, `panels_faded=`, the number of panels faded during the run);
  - Frame all leaves a shift that puts the model left of the window's middle with the tray open.
- Screenshots: Lens at 1600×900 against `sculpt2`, and clean view against `clean2`.
