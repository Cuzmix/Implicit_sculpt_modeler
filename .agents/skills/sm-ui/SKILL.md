---
name: sm-ui
description: The Dear ImGui interface in src/app/ui.odin and the frame loop around it — the docked Viewport, Tools (brushes 1–9, symmetry, mask, dynamic topology, the Pen section with its pressure curve editor and tilt), Scene and Stats panels, Viewport_Input (the only thing the camera and tools read), pointer samples with pen pressure and tilt, the brush pie (Space or a right tap), shortcuts, the deferred Scene_Command, the overlay draw list (brush circle, gizmo), the odin-imgui binding's naming, C-vararg Text formatting, Begin/End pairing, and why panels never keep references between frames. Load for ANY task that adds or changes something the user clicks, reads or types, e.g. "add a panel", "add a button to the Scene panel", "add a shortcut", "show X in the Stats panel", "the slider does not update", "the viewport ignores the mouse", "add a settings window". Requires sm-odin and sm-build; what the buttons do is sm-sculpt or sm-cad; pixels in the viewport image are sm-render.
---

# Interface

## Model (README: the app row of "Layout", the paragraph below it, "Controls")
- `Ui_State` (`src/app/ui.odin:18-35`): `viewport_request` (applied next frame), `layout_built`, `show_demo`,
  `sphere_vertices`, `scene_command`, `viewport_draw_list`/`viewport_origin` for the overlay, `viewport_mouse`/`size`/
  `hovered` for shortcuts that act where the pointer is. UI-only state; sculpt and render state live in `App`, and panels
  edit them through pointers handed over each frame, never kept.
- `Viewport_Input` (`src/app/ui.odin:56-71`): size, mouse position and delta, wheel, hovered, dragging, `orbit_drag` (right, or
  Alt+left), `pan_drag` (middle, or Shift+right), `primary` (left without Alt), `press`, `smooth` (Shift), `invert` (Ctrl),
  `samples` oldest first. `draw_viewport` fills it (`ui.odin:199`): `imgui.Image(imgui.TextureRef{_TexID = …}, avail)` then an
  `InvisibleButton` over it with all three buttons so a drag never moves the window; the content size times
  `GetWindowDpiScale()` becomes `viewport_request`.
- `ui_draw` order: dockspace → the default layout once (`build_default_layout`: Viewport | Tools at the right, Scene and
  Stats below it; `IniFilename = nil`, so the layout is rebuilt each run, `src/app/main.odin`) → menu bar (File, Edit,
  View, then the last `file_note` for 15 s, amber for a warning) → Viewport → Tools → Scene → Stats → shortcuts → demo.
  `draw_viewport_overlay` runs after the tools (`main.odin:390`; `ui.odin:255`): the brush circle, the lazy-mouse
  string, the gizmo.
- Panels: Tools (`ui.odin:306`: tool radios, the nine brushes as radio buttons labelled with their keys, three a row,
  from `BRUSH_NAMES`/`BRUSH_HELP` (`ui.odin:73, 85`), radius in px, strength, lazy mouse,
  Symmetry X/Y/Z checkboxes, the Mask section (Clear, Invert, Mask all), the Pen section (`draw_pen_section`, `ui.odin:363`:
  pressure flags, the curve editor `draw_pressure_curve` (`ui.odin:396`: an `InvisibleButton` canvas, handles grabbed on
  `IsItemActivated` within 18 px), `PRESSURE_PRESETS` (`ui.odin:383`), the Tilt slider, the pen readout), the dynamic topology section
  (`draw_dyntopo_section`, `ui.odin:453`: on/off, Detail px, Collapse short edges, its counters), camera distance), Scene (`ui.odin:476`: object list, Position `DragFloat3`, Scale (logarithmic), the levels and HD sections,
  vertex count with presets, Add / Remesh selected / Delete; Subdivide and Divide HD greyed while dynamic topology is on), Stats (`ui.odin:693`: `row(label, ring, unit)` prints p50 and p99, a
  `PlotLines` of frame time, checkboxes bound straight to `app` fields: VSync, Time GPU, partial, cull, cache, simplify).
- `handle_shortcuts` (`ui.odin:621-673`) runs only when `!io.WantTextInput`: Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y (undo, redo);
  Ctrl+O, Ctrl+S, Ctrl+Shift+S (open, save, save as); W, B (tools); 1–9 (a brush, in `Brush_Kind` order, and the Brush tool) and X (X symmetry), both only without Ctrl or
  Alt; Alt+M (clear mask), Ctrl+I (invert mask); Ctrl+R (remesh at the object's own count); Ctrl+T (dynamic topology);
  F (focus); A (HD window where the pointer is, or leave it); Ctrl+D, D, Shift+D (subdivide, level up, level down).
  One-shot keys use `IsKeyPressed(.X, false)`. In the viewport Shift turns any brush into Smooth and Ctrl inverts.
- Files (`src/app/files.odin`): menu items and shortcuts call `file_dialog(app, kind)` (SDL's dialogs, whose answer
  may come on another thread into a mutex-guarded `pending` slot) or `file_post` for a known path; the frame loop
  takes the request after the scene command (`file_take`, `file_apply`), so a file action, like a command, never runs
  mid-frame. Each action's outcome goes through `file_note` (log plus menu bar); never only `log`.
- Commands: a panel never mutates the scene; it sets `app.ui.scene_command = {kind = .X, …}` and the frame loop applies
  it at the start of the next frame (`src/app/main.odin:282-285`), so nothing drawn this frame is freed this frame
  (`Scene_Command`, `src/app/scene.odin:84-91`: None, Add, Remesh, Delete, Subdivide, Set_Level, Delete_Higher,
  Delete_Lower, Hd_Enter, Hd_Leave, Hd_Steps, Hd_Delete, Dyntopo). Mask commands go straight to `mask_command`
  (`src/app/history.odin:39`), which records them in the History.
- Events → samples (`src/app/main.odin:322-`): every motion and button event of the frame is kept, pen pressure and tilt
  (degrees, x right, y down) come from `PEN_AXIS`, pen mouse events are marked `PEN_MOUSEID` and carry both; ImGui sees
  every event first, except Space over the viewport (`main.odin:328`), which goes to `Ui_State.pie` instead: with
  keyboard navigation on, ImGui would press the focused widget with it.
- Brush pie (`src/app/pie.odin`): `pie_update` runs in `draw_viewport` right after the input is filled (`ui.odin:246`)
  and, while the pie is open (and until a click that picked from it is let go), clears the input's buttons, drags and
  wheel, so neither tools nor camera see them. It opens on Space (hold: letting go picks) or on `right_tap`
  (`ui.odin:221`: the right button let go under `PIE_TAP` and 4 px, which is also what a pen's side button sends).
  `draw_pie` draws on the foreground list, so it shows whole over the panels; slices follow `Brush_Kind` clockwise from
  the top (`pie_slice`).

## Recipes
| Want | Do |
|---|---|
| a new panel | `draw_x_panel :: proc(app: ^App)` opening with `defer imgui.End()` then `if !imgui.Begin("X") do return`; call it from `ui_draw`; dock it in `build_default_layout` |
| a button that changes the scene | a new `Scene_Command.kind` and a `scene_apply` case (the sm-cad checklist); the panel only sets `scene_command` |
| a new statistic | a `Sample_Ring` in `Frame_Stats` (`src/app/stats.odin:32-69`), `ring_push` where it is measured, a `row(…)` line in the Stats panel and a key in the exit stats |
| a viewport input that tools must not see | clear it in `pie_mute`'s style before the tools read `Viewport_Input`; never filter inside a tool |
| an A/B toggle | `imgui.Checkbox("…", &app.<field>)` plus a `--no-<x>` field in `Options` and a sentence in README "App flags" |
| a shortcut | a line in `handle_shortcuts` and README "Controls" |
| a key for a new brush | nothing: keys 1–9 follow `Brush_Kind`'s order, so a tenth kind needs its own key; add its name to `BRUSH_NAMES` and `BRUSH_HELP` (sm-sculpt has the brush checklist) |
| text with numbers | `imgui.Text("%d", i32(n))`; strings through `fmt.ctprintf` (temp memory, fine within the frame); `count_label`/`bytes_label` for human sizes (`ui.odin:676-691`) |
| a greyed-out control | `imgui.BeginDisabled(cond)` … `imgui.EndDisabled()` pairs |

## Traps
| You might expect | What happens |
|---|---|
| the viewport texture resizes where it is drawn | the request is applied at the start of the next frame, before ImGui references the texture (`src/app/main.odin:364-367`) |
| `Selectable` returns the selected state | it returns clicked; keep the state yourself (`ui.odin:490`) |
| `IsKeyPressed(key)` fires once | it repeats by default; pass `false` for one-shot keys |
| the brush circle sits under the cursor | with lazy mouse it is drawn at `stroke.pos`, on a string to the cursor |
| the camera turns whenever the mouse moves | only while hovered or dragging, and never while `primary` sculpts (`camera_apply_input`) |
| ImGui keeps some of the state | never: it sees pointers per frame (`ui.odin:16-17`); state lives in `App` or `Ui_State` |
| a shortcut fires while typing a number | `WantTextInput` guards all of them |
| Space reaches ImGui like any key | over the viewport the event loop keeps it from ImGui for the pie; elsewhere ImGui's navigation presses the focused widget |
| a right click always orbits | a right press let go quickly without moving is a tap and opens the pie; the few pixels it orbited stay |
| `AddPolyline`/`PathStroke` take `col, flags, thickness`, as older examples show | ImGui 1.92.8 swapped them to `col, thickness, flags` (`DrawList_PathStroke(list, col, 4)`); the old order asserts |

## Verify
- `--frames=120 --dump-viewport` shows the viewport only (ImGui draws into the swapchain); for a panel, log the command
  or state it produced, or read the exit stats; `build.bat smoke` after changing the frame loop.
