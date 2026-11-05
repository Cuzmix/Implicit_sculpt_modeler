# Lens Later 2: heavy passes per pane

Spec: Lens report, Later: "heavy passes per pane". View panes and the second view show only the cheap passes
(Silhouette, Shaded, Normals, Depth, Curvature), which need no buffers of their own; live occlusion, the studio render
and render mode are singletons on App that only the main view runs. The rule stays: a view pane is drawn only at rest.

## What exists when done
- **Two more passes for a view pane and the second view**, after Curvature in Shows:
  - **AO only**: the scene's occlusion alone, as the main view's AO pass shows it (live occlusion at full strength,
    its Reach from Scene > Studio render).
  - **Studio**: the studio render: shaded, with soft shadows and occlusion at the studio's strengths and samples,
    gathering samples while the app rests, as the main view's studio does.
  (Render mode in a pane is the next Later item, the render preview pane.)
- They follow the pane rules: nothing is drawn while a stroke or a turn goes on; once at rest the picture is drawn
  again and then Studio gathers a sample a frame (sharing the one-picture-a-frame budget with the other panes) until
  it has the studio's sample count, keeping the frames coming meanwhile, as the main studio does.
- Working in such a pane (Work in any view): AO only shows live occlusion there while you work; Studio shows Shaded
  while you work, as the main view's studio waits for rest, and gathers again after.
- Workspaces and the settings keep them by name (`pane 1 Front Studio`, `second_pass studio`); older files never
  name them, so nothing to migrate. Inspect stays as it is.
- Exit stats: `pane_samples=` (the first view pane's studio samples), `pane_heavy=` (view panes showing a heavy pass).

## How
- `Second_Pass` gains `Occlusion` ("AO only") and `Studio`, appended; `second_view_pass` maps them to `.AO` and
  `.Shaded`; `second_pass_heavy(p)`.
- `Picture` gains `ao: render.Live_AO` and `studio: render.Studio`, destroyed with it (WaitForGPUIdle first).
- `picture_frame`: after `thumbnail_view_draw`, AO only runs `render.live_ao_frame` on the picture's own target (zero
  stats: a full run; strength 1; the app's reach; `LIVE_AO_SCALE`) and shows `live_ao_texture`; Studio runs
  `render.studio_frame(changed = true)` and shows `studio_texture`. A key that has not changed returns early unless
  Studio still gathers (`samples < studio_samples`), when it runs `studio_frame(changed = false)` once, counted in
  `pictures_drawn`, never while moving, a stroke or work goes on. Lights are turned into the picture's view for every
  shaded pass (Shaded, AO only, Studio) as for Shaded now. AO only and Studio need the device to read depth
  (`live_ao_supported`); where it cannot, they draw as Shaded and the select names them unavailable.
- `idle.odin` keeps frames coming while a picture gathers (its `due`).
- Work in any view: `live_ao_strengths` gives 1 to an AO pass while working (the pane's), `viewport_shown` returns
  live occlusion's texture then; the end of work copies the shown texture (not always the target's colour) and, for a
  heavy pass, leaves the key cleared so the picture is drawn again at rest (its depth is the pane's own).

## Tests
- Unit: the pass names read back in a layout; `second_view_pass` for the new ones.
- Touch: Four with the Front pane on Studio: after rest `pane_samples` reaches the studio's count and a stroke in the
  main view starts it over; AO only shows (`pane_heavy=1`); a dumped screen of Four with AO only and Studio panes.
- Perf: a stroke in the main view with two Studio panes costs the same frame p50 as with Shaded panes.
