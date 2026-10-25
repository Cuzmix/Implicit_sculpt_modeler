---
name: sm-ui
description: The Dear ImGui interface in src/app/ui.odin and the frame loop around it — the docked Viewport, Tools (brushes on 1–9 and 0, symmetry, brush alphas, mask, dynamic topology, the Pen section with its pressure curve editor and tilt), Scene and Stats panels, Viewport_Input (the only thing the camera and tools read), pointer samples with pen pressure and tilt, the brush pie (Space or a right tap), shortcuts, the deferred Scene_Command, the overlay draw list (brush circle or alpha square, gizmo), the odin-imgui binding's naming, C-vararg Text formatting, Begin/End pairing, and why panels never keep references between frames. Load for ANY task that adds or changes something the user clicks, reads or types, e.g. "add a panel", "add a button to the Scene panel", "add a shortcut", "show X in the Stats panel", "the slider does not update", "the viewport ignores the mouse", "add a settings window". Requires sm-odin and sm-build; what the buttons do is sm-sculpt or sm-cad; pixels in the viewport image are sm-render.
---

# Interface

## Model (README: the app row of "Layout", the paragraph below it, "Controls")
- `Ui_State` (`src/app/ui.odin:18-37`): `viewport_request` (applied next frame), `layout_built`, `show_demo`,
  `sphere_vertices`, `scene_command`, `viewport_draw_list`/`viewport_origin` for the overlay, `viewport_mouse`/`size`/
  `hovered` for shortcuts that act where the pointer is. UI-only state; sculpt and render state live in `App`, and panels
  edit them through pointers handed over each frame, never kept.
- `Viewport_Input` (`src/app/ui.odin:77-92`): size, mouse position and delta, wheel, hovered, dragging, `orbit_drag` (right, or
  Alt+left), `pan_drag` (middle, or Shift+right), `primary` (left without Alt), `press`, `smooth` (Shift), `invert` (Ctrl),
  `samples` oldest first. `draw_viewport` fills it (`ui.odin:220`): `imgui.Image(imgui.TextureRef{_TexID = …}, avail)` then an
  `InvisibleButton` over it with all three buttons so a drag never moves the window; the content size times
  `GetWindowDpiScale()` becomes `viewport_request`.
- `ui_draw` order: dockspace → the default layout once (`build_default_layout`: Viewport | Tools at the right, Scene and
  Stats below it; `IniFilename = nil`, so the layout is rebuilt each run, `src/app/main.odin`) → menu bar (File, Edit,
  View with Orthographic (P, keypad 5; `camera.Orbit.ortho`), Look from (keypad 1/3/7, Ctrl for the opposite; `camera.orbit_axis_view`; with ortho possible, pixel sizes go through `camera.orbit_world_per_px` and view directions through `camera.orbit_toward`, never the eye distance), Wireframe (Shift+F) and Material, which only set `App.wireframe` and `App.material` (presets in `src/app/material.odin`), then the last `file_note` for 15 s, amber for a warning) → Viewport → Tools → Scene → Stats → shortcuts → demo.
  `draw_viewport_overlay` runs after the tools (`main.odin:408`; `ui.odin:276`): the brush circle (with an alpha, its
  square turned as the next dab, `draw_alpha_outline`, `src/app/alphas.odin:204`), the lazy-mouse string, the gizmo.
- Panels: Tools (`ui.odin:331`: tool radios, the brushes as radio buttons labelled with their keys, three a row,
  from `BRUSH_NAMES`/`BRUSH_HELP` (`ui.odin:94, 106`), radius in px (5-500, logarithmic), the held brush's own strength
  (`Brush_Settings.strengths[kind]` through `brush_strength`), lazy mouse,
  Symmetry X/Y/Z checkboxes, the Falloff section (`draw_falloff_section`: `draw_curve_editor` mirrored, the built-in shape plotted until a handle moves, `FALLOFF_PRESETS`), the Alpha section (`draw_alpha_section`, `src/app/alphas.odin:217`: the round brush and
  each `App.alphas` entry as a 20² thumbnail drawn as filled rects over an `InvisibleButton`, six a row; Load image...;
  the mode radios and the Angle slider, greyed with no alpha), the Mask section (Clear, Invert, Mask all; Blur, Sharpen, Grow, Shrink with the Steps slider, `Ui_State.mask_steps`,
  and the last command's time from `Ui_State.mask_last`), the Pen section (`draw_pen_section`, `ui.odin:399`:
  pressure flags, the curve editor `draw_pressure_curve` (over the shared `draw_curve_editor`) (`ui.odin:432`: an `InvisibleButton` canvas, handles grabbed on
  `IsItemActivated` within 18 px), `PRESSURE_PRESETS` (`ui.odin:419`), the Tilt slider, the pen readout), the dynamic topology section
  (`draw_dyntopo_section`, `ui.odin:489`: on/off, Detail px, Collapse short edges, its counters), camera distance), Scene (`ui.odin:512`: object list, Position `DragFloat3`, Scale (logarithmic), the levels and HD sections,
  vertex count with presets, Add / Remesh selected / Delete; Subdivide and Divide HD greyed while dynamic topology is on), Stats (`ui.odin:729`: `row(label, ring, unit)` prints p50 and p99, a
  `PlotLines` of frame time, checkboxes bound straight to `app` fields: VSync, Time GPU, partial, cull, cache, simplify).
- `handle_shortcuts` (`ui.odin:657-709`) runs only when `!io.WantTextInput`: Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y (undo, redo);
  Ctrl+O, Ctrl+S, Ctrl+Shift+S (open, save, save as); W, B (tools); 1–9 and 0 (the first ten brushes, in `Brush_Kind` order, and the Brush tool) and X (X symmetry), both only without Ctrl or
  Alt; [ and ] (size steps; with Shift the strength); Alt+M (clear mask), Ctrl+I (invert mask); Ctrl+R (remesh at the object's own count); Ctrl+T (dynamic topology);
  F (focus); A (HD window where the pointer is, or leave it); Ctrl+D, D, Shift+D (subdivide, level up, level down).
  One-shot keys use `IsKeyPressed(.X, false)`.
  S and U over the viewport (Brush tool, no modifiers) start the modal size or strength adjustment in
  `src/app/adjust.odin` (`adjust_update`, called after `pie_update` in `draw_viewport`; `Ui_State.adjust`): the
  circle stays put, the value follows the pointer's distance from its middle, a click or the same key keeps it, a
  right click or Escape restores it, and `viewport_mute` hides the pointer from tools and camera meanwhile. In the viewport Shift turns any brush into Smooth and Ctrl inverts; Ctrl+Shift + drag anywhere is the Tools panel's `Gesture_Tool` (`clip_frame`, before the mask shape: hide rectangle or lasso, clip line or slice line; a click shows all; `draw_clip` draws it), Ctrl+H shows all and Ctrl+Shift+H inverts hiding; Ctrl + drag starting on empty space is a mask shape (`mask_shape_frame`, run before `sculpt_frame` in the Brush case; `Viewport_Input.alt` unmasks; Alt+left orbits only without Ctrl).
- Files (`src/app/files.odin`): menu items and shortcuts call `file_dialog(app, kind)` (SDL's dialogs, whose answer
  may come on another thread into a mutex-guarded `pending` slot) or `file_post` for a known path; the frame loop
  takes the request after the scene command (`file_take`, `file_apply`), so a file action, like a command, never runs
  mid-frame. Each action's outcome goes through `file_note` (log plus menu bar); never only `log`. `.Alpha` opens
  `IMAGE_FILTERS` and its request runs `alpha_load` (`src/app/alphas.odin:94`: `core:image` decodes PNG, JPEG, BMP,
  TGA and QOI, 8 or 16 bits a channel, each registered by a blank import).
- Commands: a panel never mutates the scene; it sets `app.ui.scene_command = {kind = .X, …}` and the frame loop applies
  it at the start of the next frame (`src/app/main.odin:300-303`), so nothing drawn this frame is freed this frame
  (`Scene_Command`, `src/app/scene.odin:84-91`: None, Add, Remesh, Delete, Subdivide, Set_Level, Delete_Higher,
  Delete_Lower, Hd_Enter, Hd_Leave, Hd_Steps, Hd_Delete, Dyntopo). Mask commands go straight to `mask_command`
  (`src/app/history.odin:43`), which times them, passes the step count and records them in the History.
- Events → samples (`src/app/main.odin:340-`): every motion and button event of the frame is kept, pen pressure and tilt
  (degrees, x right, y down) come from `PEN_AXIS`, pen mouse events are marked `PEN_MOUSEID` and carry both; ImGui sees
  every event first, except Space over the viewport (`main.odin:346`), which goes to `Ui_State.pie` instead: with
  keyboard navigation on, ImGui would press the focused widget with it.
- Brush pie (`src/app/pie.odin`): `pie_update` runs in `draw_viewport` right after the input is filled (`ui.odin:267`)
  and, while the pie is open (and until a click that picked from it is let go), clears the input's buttons, drags and
  wheel, so neither tools nor camera see them. It opens on Space (hold: letting go picks) or on `right_tap`
  (`ui.odin:242`: the right button let go under `PIE_TAP` and 4 px, which is also what a pen's side button sends).
  `draw_pie` draws on the foreground list, so it shows whole over the panels; slices follow `Brush_Kind` clockwise from
  the top (`pie_slice`).

## Recipes
| Want | Do |
|---|---|
| a new panel | `draw_x_panel :: proc(app: ^App)` opening with `defer imgui.End()` then `if !imgui.Begin("X") do return`; call it from `ui_draw`; dock it in `build_default_layout` |
| a button that changes the scene | a new `Scene_Command.kind` and a `scene_apply` case (the sm-cad checklist); the panel only sets `scene_command` |
| a new statistic | a `Sample_Ring` in `Frame_Stats` (`src/app/stats.odin:32-69`), `ring_push` where it is measured, a `row(…)` line in the Stats panel and a key in the exit stats |
| a viewport input that tools must not see | clear it with `viewport_mute` (`src/app/adjust.odin`) before the tools read `Viewport_Input`; never filter inside a tool |
| an A/B toggle | `imgui.Checkbox("…", &app.<field>)` plus a `--no-<x>` field in `Options` and a sentence in README "App flags" |
| a shortcut | a line in `handle_shortcuts` and README "Controls" |
| a setting that should survive a restart | a `key values` line in both `settings_save` and `settings_load` (`src/app/settings.odin`; unknown keys are skipped, values clamped); a flag that sets it too must only override when given, since the load runs before the flags |
| a key for a new brush | nothing: keys 1–9 and 0 follow `Brush_Kind`'s order, so the eleventh kind on (Snake hook, Morph) has none and is picked in the panel or pie; add its name to `BRUSH_NAMES` and `BRUSH_HELP` (sm-sculpt has the brush checklist) |
| text with numbers | `imgui.Text("%d", i32(n))`; strings through `fmt.ctprintf` (temp memory, fine within the frame); `count_label`/`bytes_label` for human sizes (`ui.odin:712-727`) |
| a greyed-out control | `imgui.BeginDisabled(cond)` … `imgui.EndDisabled()` pairs |

## Traps
| You might expect | What happens |
|---|---|
| the viewport texture resizes where it is drawn | the request is applied at the start of the next frame, before ImGui references the texture (`src/app/main.odin:382-385`) |
| `Selectable` returns the selected state | it returns clicked; keep the state yourself (`ui.odin:526`) |
| `IsKeyPressed(key)` fires once | it repeats by default; pass `false` for one-shot keys |
| the brush circle sits under the cursor | with lazy mouse it is drawn at `stroke.pos`, on a string to the cursor |
| the alpha outline turns with the stroke while hovering | between strokes it shows the angle alone (Follow stroke faces up, Random shows no turn), as the next stroke's first dab will |
| a thumbnail needs a GPU texture | it is a 20² grey array drawn as rects (`Alpha_Entry.thumb`); fine for dozens of alphas, a texture once there are hundreds |
| the camera turns whenever the mouse moves | only while hovered or dragging, and never while `primary` sculpts (`camera_apply_input`) |
| ImGui keeps some of the state | never: it sees pointers per frame (`ui.odin:16-17`); state lives in `App` or `Ui_State` |
| a shortcut fires while typing a number | `WantTextInput` guards all of them |
| Space reaches ImGui like any key | over the viewport the event loop keeps it from ImGui for the pie; elsewhere ImGui's navigation presses the focused widget |
| a right click always orbits | a right press let go quickly without moving is a tap and opens the pie; the few pixels it orbited stay |
| `AddPolyline`/`PathStroke` take `col, flags, thickness`, as older examples show | ImGui 1.92.8 swapped them to `col, thickness, flags` (`DrawList_PathStroke(list, col, 4)`); the old order asserts |

## Verify
- `--frames=120 --dump-viewport` shows the viewport only (ImGui draws into the swapchain); for a panel, log the command
  or state it produced, or read the exit stats; `build.bat smoke` after changing the frame loop.
