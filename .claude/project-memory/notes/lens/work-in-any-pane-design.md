# Lens Later 1: work in any pane (strokes in view panes)

Spec: Lens report, Later: "strokes in any pane". Today pane 0 of the view grid is the main view, where the camera, the
tools and the heavy passes live; panes 1 to 3 are view panes drawn only at rest, and a drag in one only turns its own
camera (grid.odin, thumbnail.odin `second_view_input`). Blender lets you sculpt in any of its quad views; ZBrush and
Nomad have one view. The rule the grid keeps (a big mesh is never drawn twice a frame while you work) must hold.

## What exists when done
- **A press in a view pane works there**, as a press in the main view would: a brush stroke, a mask, a gizmo drag, a
  tool's press, a one-finger orbit on empty space, a two-finger pan and pinch, a right or middle drag by the mouse
  scheme, the pie. The dab lands under the finger, seen through that pane's camera, and the pane draws live (every
  frame, partial redraws and all) for as long as the gesture lasts.
- **The main view's role travels for the gesture, then comes home.** While you work in pane i, the main view (its
  target, camera, cursor, overlay, pass) is drawn in pane i's cell through pane i's camera and pass; the main cell
  shows a still copy of what it showed when the press began. When the gesture is over (the pointer is up, the stroke
  has laid its last dab, a tap's waiting dab has played) the main camera goes back to where it was, the main cell
  draws live again, and pane i's own picture is drawn that same frame, so nothing flashes. Only one view draws live
  in any frame; the other panes still wait for rest.
- **The pane keeps what the gesture did to its camera.** A pane's camera that the gesture turned, panned or zoomed
  becomes Free at the new view (an axis view so turned is no longer that axis); a linked pane (Follow) turns the main
  camera itself, as dragging a linked pane does today; a Mirrored pane turns the main camera mirrored. A gesture that
  left the camera alone changes nothing about the pane, so a stroke never marks the workspace modified.
- **What only the main view has stays in the main cell's terms**: the studio render, render mode and live occlusion
  pause while working in a view pane (the pane draws its own cheap pass through the main view's renderer), and the
  wipe compare and the peek are not shown there. Proportion guides draw in both, as now.
- **A setting**: Settings > Interface > VIEW GRID "Work in any pane" (on; settings row `panes_work`). Off keeps
  today's: a drag in a view pane turns its camera only. The wheel over a view pane zooms that pane either way (no
  press, nothing to travel).
- Hover: a pen or mouse hovering a view pane shows no brush cursor until it presses (the cursor is the main view's).
- Exit stats: `pane_work=` (the view pane worked in now, 0 for none), `pane_works=` (gestures worked in a view pane),
  `pane_work_dabs=` (dabs laid while in one).

## How
- `View_Grid` gains `work: int` (the view pane 1..3 the main role is in, 0 home), `work_back: camera.Orbit` (the main
  camera to restore), `work_pass` (the main pass to restore), `work_from: camera.Orbit` (the pane's orbit at the
  press, to see whether the gesture moved it), `work_ending: bool`, counters.
- **Start** (in `kit_grid`, before `g.main` is set): when `panes_work` is on, a press (`ctx.input.pressed != {}`,
  `ctx.active == 0`) has `ctx.pointer_root` equal to view pane i's root (`ui.id` of "view pane %d"), and the press is
  not on the pane's head (its own root, drawn after), then: `work = i`; `work_back = app.camera`; `app.camera =
  second_orbit(app, sv)`; the main pass is set to the pane's (`second_view_pass`); `ctx.viewport_drag = true`,
  `ctx.pointer_root = 0` so the press is the viewport's this very frame. `g.main` becomes pane i's cell (or the room
  when it is maximised), so `viewport_origin` and `input.size` are pane i's and `kit_viewport_input` maps the press
  into it; the stroke starts this frame through the pane's camera.
- **The still copy**: on the start frame, before the viewport is drawn, the shown viewport texture
  (`viewport_shown(app)` or `app.target.color`) is blitted into `app.work_still` (a texture the size of the target,
  made or remade on demand; `render.texture_blit` in a copy pass, `WaitForGPUIdle` before freeing). The main cell
  draws `KIT_WORK_STILL_IMAGE` while `work != 0`.
- **The first frame's size**: the target is resized at the start of the next frame from `viewport_request`, so on the
  start frame the target still has the main cell's size. On that frame pane i's cell keeps showing its own picture
  (`app.panes[i-1].shown`, still right) and the main cell the still copy; from the next frame pane i's cell shows the
  target. So the first dab shows one frame later than in the main view, and nothing is ever drawn stretched.
- **End**: each frame in `kit_grid`, when `work != 0` and the gesture is over: `!ctx.viewport_drag`, no stroke under
  way, `app.dab_wait.active` false, no gizmo or tool drag held. Then in two steps, for the same reason as the start:
  frame E asks for the main cell's size again (`work_ending = true`, everything still drawn as while working); frame
  E+1, after the resize, writes the camera back (as above), restores `app.camera = work_back` and the pass, marks pane
  i's picture due now (bypassing the 0.1 s throttle, so it is drawn this frame in `grid_frame`), sets `work = 0`, and
  the main cell draws live again.
- A stroke that is still laying dabs when the pointer is up keeps the work going until it ends; a press in another
  view pane during `work_ending` starts over from the main camera restored.
- What reads `app.camera` (picking, symmetry, the cursor, alphas, the gizmo, the guides) needs nothing new: for the
  gesture the main camera is the pane's. Camera history (Back and Forward) does not record the travel or the return,
  only what the gesture did to a linked pane's main camera.
- Studio, render mode and live occlusion: `studio_running`, `render_running` and `live_ao_wanted` are false while
  `work != 0`, so their accumulations are left alone and resume at home; the wipe and the peek check `work == 0`.
- Undo and the stroke recorder: a stroke made in a pane is an ordinary stroke (its undo entry holds no camera). A
  recorded stroke keeps the camera it was drawn through, which is the pane's.

## Tests
- Unit: start and end bookkeeping on a fake grid (camera swapped and restored bit for bit; a moved axis pane becomes
  Free at the moved orbit; a moved linked pane moves the main camera; an unmoved pane is untouched); the end waits
  for a pending dab.
- Touch at Four (`set panes_under_panels off`): a stroke in the Front pane lays dabs (`pane_work_dabs > 0`), the main
  camera is the same after (`camera_still`), Front's camera is still Front, the stroke landed on the model's front
  (mesh changed, `pane_works=1`); a one-finger drag on empty space in the Front pane turns it (`pane_camera=Free`) and
  leaves the main camera; a linked pane's drag turns the main camera; with `set panes_work off` a pane drag only turns
  its camera as before; a pinch in a pane zooms it only.
- Dumped screens mid-stroke (pane live, main cell still) and after (both right, no stretch), described.
- Perf: a release 2M stroke in a view pane against the same stroke in the main view: frame p50 within a few percent
  (one live view either way), plus the one-off full draws at start and end.

## Not in this
Heavy passes in view panes (the next Later item), a brush cursor while hovering a view pane, the thumbnail window.

## After review (sm-architect)
- **Gesture over** = `!ctx.viewport_drag && app.drag.owner == .None && app.touch.fingers.count == 0 && !move_busy &&
  !app.ui.light_press.active && !app.ui.pie.open && app.ui.adjust.kind == .None` (a pinch releases the pointer while
  the fingers still navigate). No inertia exists; a stroke ends on its release frame; a tap's waiting dab keeps its own
  camera and size, so it needs no wait. Never start while the turntable, timeline playback or a replay moves the
  camera, while anything floats (`kit_floating`, `popup_open_prev`, a select list, the pie's or adjust's swallow).
- **Resize at once**: on the start and end frames `msaa_viewport_resize` runs again right after `kit_frame` (nothing
  has recorded GPU work on the target yet), so there is no `work_ending`, no stale first frame and no delayed dab. The
  still copy is recorded and submitted in its own command buffer before that resize (CopyGPUTextureToTexture, RGBA8,
  SAMPLER usage, WaitForGPUIdle before freeing), its source taken before `work` is set (studio/AO pictures included).
- **`main_camera(app)`** returns `work_back` while working: `second_orbit`, the main cell's guides, the scene header
  writer and the thumbnail window use it; `camera_history_frame` returns early while working; `grid_frame` skips pane
  `work`. The pass is never written: `viewport_pass` returns the pane's pass while working, `wipe_shown`,
  `pass_shaded` and `live_ao_strengths` return false/zero (pausing studio, render mode, scene preview, live AO); their
  accumulations start over at home.
- The overlay layer (`k.layer`) is marked just after pane i's picture while working; kit_draws maps a still image id;
  `edge_inner`'s top band uses the window, not the pane; the maximised room is pixel-snapped too.
- At the end the pane's picture takes a copy of the live target (same size) instead of a second full draw; the main
  cell draws live that frame. Live, the pane uses the resting picture's look (Silhouette without wire, pane colour).
- Fix found on the way: `dab_wait_event` compares window coordinates with pane coordinates (navigate.odin:661 vs 456),
  so a double tap in a non-origin main pane never matches; convert with `viewport_point`.
