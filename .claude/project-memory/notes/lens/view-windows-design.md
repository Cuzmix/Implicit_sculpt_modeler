# Lens Later 4: second-monitor windows (view windows)

Spec: Lens report, Later: "second-monitor windows" (the report's "not now" list named "separate OS windows for a second
monitor"). A sculptor with two screens wants the work on one and a reference view on the other: Blender's extra main
windows (Window > New Main Window, each with its own editors), 3D-Coat's and Maya's torn-off panels, Marmoset's
detachable viewport. Here a **view window** is a second view in its own OS window, which you move to any monitor:
its own camera and pass, drawn at rest exactly as a view pane, at that monitor's size and pixel density.

Desktop only (Windows, Linux): Android has one window per app, so the command is hidden there.

## What exists when done
- **Open in a window** (an icon button on each view pane's head, after Maximise; and the command
  `View_Window_New`, "New view window", Search "window", "monitor", "second screen"; scripts `view_window`): opens a
  new OS window, 960x640 points, titled "Sculpt view N", showing that pane's camera and pass (from the command: the
  first view pane's, else Linked with Shaded). Up to three at once; the fourth press says so in a toast.
- In the window: the picture fills it, with a small head in its top left as a view pane has (camera dot, Camera,
  Shows, link, Close), drawn by its own interface context at the window's own content scale and in the app's look.
  A drag on the picture turns the camera it sees through (a linked one turns the main view and every linked view, an
  independent one only itself, becoming Free), the wheel zooms it: the second view's rules (`second_view_input`).
  Keys typed while it has focus are the main window's (Ctrl+Z, the brush keys), so it never swallows a shortcut.
  Brushes do not work there (Work in any view stays the grid's): it is a view, not a second workspace.
- The picture follows the pane rules: drawn whole, only at rest, at most one picture a frame shared with the panes and
  the second view, heavy passes gathering at rest. Moving a window to a monitor of another density redraws it at the
  new size. Closing it (its Close button, the OS close box, Alt+F4) shuts that window only; closing the main window
  quits as before, shutting every view window.
- Not remembered between runs, as Maximise is not: a monitor may be gone the next time. (A workspace line can come
  later once Bolt has tried it.)
- Exit stats: `view_windows=` (open now), `view_window_opens=`, `view_window_draws=` (pictures drawn into them),
  `view_window_presents=`.

## How
- `src/app/view_window.odin`: `View_Window { window: ^sdl.Window, id: sdl.WindowID, view: Second_View, pic: Picture,
  ctx: ui.Context, pass: render.Ui_Pass, device: Device_State (its pointer), size, pixels }`, `app.view_windows:
  [VIEW_WINDOWS_MAX]^View_Window` (heap, so the ctx never moves).
- Open: `sdl.CreateWindow(..., platform_window_flags())`, `sdl.ClaimWindowForGPUDevice`, swapchain parameters SDR +
  VSYNC (set before any acquire); refuse (toast) if its swapchain format differs from the main window's, since the
  UI pipeline is made for one format (`ui_pipeline` caches by format, so a differing one would still work, but
  refusing keeps one pipeline and is what a mixed HDR setup would need anyway: noted, not hit on SDR). `ui.init`.
- Close: `WaitForGPUIdle`, `picture_destroy`, `ui_pass_destroy`, `ui.destroy`, `ReleaseWindowFromGPUDevice`,
  `DestroyWindow`. All closed in `app` shutdown before the renderer goes.
- Events (main.odin's loop): an event whose window id (motion, button, wheel, finger, pen, window events) is a view
  window's goes to `view_window_event` and nowhere else (not `device_event`, not touch, not the dab wait);
  `WINDOW_CLOSE_REQUESTED` there closes that window (applied after the loop, never inside it); the main window's
  close request quits. Keys stay the main window's. `QUIT` still quits (SDL sends it only when the last window
  closes, but the main one's close request already quit).
- Frame: after `grid_frame`, `view_windows_frame(app, cmd, draws)` runs `picture_frame` for each (size = its pixels).
  After the main present-command's UI pass, each window lays out its head (`ui.frame_begin` with its own input),
  acquires its swapchain with `sdl.AcquireGPUSwapchainTexture` (never the waiting one: a window on a slower monitor
  must not hold the main frame) on the same present command buffer, and draws its UI pass with the picture as its
  image; a nil texture (minimised, or not ready) skips that window this frame. One submit for all.
- `second_view_input` and the pane head's widgets take the context they run in rather than `app.kit.ctx`.
- Idle: a view window's pointer events wake the loop as any event does; `grid_due` covers the window pictures.
- Smoke/tests on Linux: xvfb gives SDL a second window and lavapipe a second swapchain.

## Tests
- Unit: `view_window_route` picks the window for an event by id, and nil for the main window's.
- Touch: `--script=view_window` then rest: `view_windows=1`, `view_window_draws>=1`, `view_window_presents>=1`; a
  stroke in the main view leaves `view_window_draws` growing by one after rest; `view_window close` closes it with
  no leak; the fourth open is refused.
- A dumped picture of the window (`--dump-view-window=PATH`, the window's last frame as the UI pass captures it),
  described.

## After review (sm-architect)
Taken in full; the head stays (a window on another monitor must be steerable without going back), built as follows.
1. **Present only when something changed**: a new picture, the head's look (its hash, as `idle_note` hashes the
   main kit), a press or hover in it, `WINDOW_EXPOSED`, `PIXEL_SIZE_CHANGED`. Even the non-waiting acquire blocks in
   `vkAcquireNextImageKHR`, so a 60 Hz window presented every frame would hold a 144 Hz main one. MAILBOX where the
   device offers it (as `renderer_set_vsync` picks), else VSYNC.
2. **Order**: open/close requests first (top of the frame, before the present command, as `file_take`), then events
   routed, the heads laid out right after `kit_frame` and before `camera_apply_input` (a linked drag turns the main
   camera that frame, and `sv.dragging` is set before `picture_frame`), the pictures after `grid_frame`, and each
   window's upload, acquire, UI pass and submit on **its own command buffer** after the main present; a failure there
   logs and closes that window only, never the app.
3. **Routing** with `sdl.GetWindowFromEvent` (every pointer, wheel, finger, pen, drop and window category), before
   `device_event`, `dab_wait_event`, `touch_event` and the sample appends. `WINDOW_CLOSE_REQUESTED` checks the id. The
   main window's own `WINDOW_MOUSE_LEAVE` and `FOCUS_LOST` still reach `device_event`, so keys typed while a view
   window has focus never open the Space pie or a hover-gated command. A window's first finger is its pointer (a tap
   presses, a drag turns); other fingers are ignored. Keys go to the main window's handling as before.
4. **No format refusal**: each window has its own `Ui_Pass` (uploads do not cycle), whose pipeline cache is keyed by
   format; claiming gives SDR + VSYNC, so swapchain parameters are set only for MAILBOX.
5. **Shared head**: `view_head(app, ctx, sv, index, ...)` is pulled out of `kit_view_pane` and used by both; it and
   `second_view_input` take the context and scale they run in. The look's theme (hold delay included) comes from one
   `kit_theme(app)` used by both contexts. Windows show no proportion guides (the pane's `kit_guides` stays main-kit
   only; noted in README). A window's draws map its own one image; `kit_screen_save`'s capture is shared for
   `--dump-view-window=PATH`.
6. **Idle**: `idle_note` also hashes each window's context and counts its held buttons; `grid_due` covers the windows'
   pictures and a present skipped for a nil texture.
7. **Cost**: a window's picture is drawn at most 2.1M pixels (1920x1080's worth), scaled up smoothly beyond that, so a
   4K monitor costs one 1080p whole-scene draw after a stroke; measured on the head (release, Shaded and Studio).
8. **Colours**: windows have their own camera colours (Theme gains three `window_camera` colours per look), so a
   window's independent camera never shares a pane's.
9. **Tests**: `--ui-events` takes a window target (`FRAME:win1:move:X,Y`, `kit_events_push` stamps the window's id);
   `--view-windows=N` opens N at start so `smoke` runs second swapchains under validation (whether lavapipe gives
   a second X11 swapchain is checked first; if not, the touch scenarios say so and test routing and the head without
   presenting). xvfb has no window manager and one screen at scale 1: nothing depends on focus, and the density change
   is unit-tested as size maths only, reported as not checked on a real second monitor.

## After building
- Under Xvfb lavapipe gives a second X11 swapchain, so `smoke` now runs with `--view-windows=1` under GPU validation
  (no errors, no leaks), and the touch scenarios present for real.
- New view window sits in Search and the palette, not the Camera menu: that menu is full height at 900 px after the
  Render preview row. The fourth request is refused with a toast (the command stays enabled to say why).
- Presents only on change: 2 presents in a 60-frame run at rest; while a Studio window gathers it presents once a
  sample (at rest only).
- Release, 2M stroke in the main window: 16.9 / 16.9 / 19.3 ms frame p50 and 1.8 / 2.0 / 2.2 ms CPU with 0 / 1 / 3
  windows (Xvfb software GPU). Not tried: a real second monitor, a display of another density, Windows.
