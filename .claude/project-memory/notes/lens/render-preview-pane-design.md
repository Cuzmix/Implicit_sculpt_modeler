# Lens Later 3: render preview pane

Spec: Lens report, Later: "render preview pane". Render mode (Scene > Render, render/path.odin) path traces the main
view while it stays still and replaces it, so you either sculpt or look at the render. Blender's answer is a second
3D view in Rendered shading; Marmoset and Substance keep a live render beside the work. Here: a view pane (or the
second view) can show the render, built up while the app rests, beside the view you sculpt in.

## What exists when done
- **Render** in a view pane's and the second view's Shows, after Studio: the view path traced as render mode does it
  (the scene's lights with soft shadows, the environment, materials, paint and maps, bounced light, Denoise, Half
  resolution and the lens from Scene > Render and the camera), a sample a frame at rest until Scene > Render's
  Samples, starting over after a stroke or a turn. It never runs while you work, as every pane waits for rest.
- **Camera > Render preview pane**, after the View grid presets (command `Render_Preview`, Search "render preview", scripts `render_preview`): one tap
  for the common case: the grid goes to Side by side (or keeps a grid that has panes) and its first view pane becomes
  Linked with Render, so the render follows the main camera beside it; again, it puts that pane back to Shaded. Its
  row is checked while a view pane shows Render.
- A pane showing Render holds its own copy of the traced scene on the device (as render mode does), given back when
  it shows something else; the note under the pane select says so only in README.
- Exit stats: `pane_render_samples=` (the first view pane's render samples).

## How
- `Second_Pass.Render` appended; heavy; maps to `.Shaded`.
- `Picture.path: render.Path_Render`, destroyed with the picture and when the pass is no longer Render.
- `picture_frame`: fresh draw → `render.render_frame(changed = true, …)`; gathering → `render_frame(changed = false)`
  while `samples < render_samples` and `refused == ""`; shown is `render.render_texture` once it has
  `RENDER_SHOW_MIN` samples, the shaded picture before that. Lights are the picture's view's; the lens is the
  picture camera's (`render_lens` with the picture's orbit). `picture_gathers` covers Studio and Render.
- `Render_Preview` command in commands.odin, the Camera menu row (after the View grid presets, so no row above it moves), palette words, macro skip list as other view
  toggles are not skipped (it is a plain view change, recorded).

## Tests
- Unit: the command sets Side by side + Linked Render and toggles back.
- Touch: `render_preview` in a script: after rest `pane_render_samples` > 0; a stroke in the main view restarts it.
- A dumped screen of the head with a Render pane beside the main view, described.

## After building
- A first try put a switch in Scene > Render beside Render mode; that section then held six controls, past the five a
  section may show, so the row went to the Camera menu after the View grid presets, as first designed.
- On the VM's software GPU the 1.9M head reached 31 samples in 500 frames; the touch scenario waits 240 frames for at
  least 4 and a main-view stroke leaves fewer than 3.
