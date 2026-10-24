---
name: sm-ui
description: The Dear ImGui interface in src/app/ui.odin and the frame loop around it — the docked Viewport, Tools, Scene and Stats panels, Viewport_Input (the only thing the camera and tools read), pointer samples and pen pressure, shortcuts, the deferred Scene_Command, the overlay draw list (brush circle, gizmo), the odin-imgui binding's naming, C-vararg Text formatting, Begin/End pairing, and why panels never keep references between frames. Load for ANY task that adds or changes something the user clicks, reads or types, e.g. "add a panel", "add a button to the Scene panel", "add a shortcut", "show X in the Stats panel", "the slider does not update", "the viewport ignores the mouse", "add a settings window". Requires sm-odin and sm-build; what the buttons do is sm-sculpt or sm-cad; pixels in the viewport image are sm-render.
---

# Interface

## Model (README: the app row of "Layout", the paragraph below it, "Controls")
- `Ui_State` (`src/app/ui.odin:14-29`): `viewport_request` (applied next frame), `layout_built`, `show_demo`,
  `sphere_vertices`, `scene_command`, `viewport_draw_list`/`viewport_origin` for the overlay, `viewport_mouse`/`size`/
  `hovered` for shortcuts that act where the pointer is. UI-only state; sculpt and render state live in `App`, and panels
  edit them through pointers handed over each frame, never kept.
- `Viewport_Input` (`:50-64`): size, mouse position and delta, wheel, hovered, dragging, `orbit_drag` (right, or
  Alt+left), `pan_drag` (middle, or Shift+right), `primary` (left without Alt), `press`, `smooth` (Shift), `invert` (Ctrl),
  `samples` oldest first. `draw_viewport` fills it (`:132-177`): `imgui.Image(imgui.TextureRef{_TexID = …}, avail)` then an
  `InvisibleButton` over it with all three buttons so a drag never moves the window; the content size times
  `GetWindowDpiScale()` becomes `viewport_request`.
- `ui_draw` order: dockspace → the default layout once (`build_default_layout`: Viewport | Tools at the right, Scene and
  Stats below it; `IniFilename = nil`, so the layout is rebuilt each run, `src/app/main.odin`) → menu bar → Viewport →
  Tools → Scene → Stats → shortcuts → demo. `draw_viewport_overlay` runs after the tools (`main.odin:306`): the brush
  circle, the lazy-mouse string, the gizmo.
- Panels: Tools (`:222-258`: tool radios, brush kind, radius in px, strength, lazy mouse, pressure flags, pen state,
  camera distance), Scene (`:260-387`: object list, Position `DragFloat3`, Scale (logarithmic), the levels and HD sections,
  vertex count with presets, Add / Remesh / Delete), Stats (`:438-`: `row(label, ring, unit)` prints p50 and p99, a
  `PlotLines` of frame time, checkboxes bound straight to `app` fields: VSync, Time GPU, partial, cull, cache, simplify).
- `handle_shortcuts` (`:389-419`) runs only when `!io.WantTextInput`: Ctrl+Z, Ctrl+Shift+Z, Ctrl+Y, W, B, F, A (HD
  window where the pointer is), Ctrl+D, D, Shift+D. One-shot keys use `IsKeyPressed(.X, false)`.
- Commands: a panel never mutates the scene; it sets `app.ui.scene_command = {kind = .X, …}` and the frame loop applies
  it at the start of the next frame (`main.odin:220-223`), so nothing drawn this frame is freed this frame
  (`src/app/scene.odin:65-74`).
- Events → samples (`main.odin:252-`): every motion and button event of the frame is kept, pen pressure comes from
  `PEN_AXIS`, pen mouse events are marked `PEN_MOUSEID`; ImGui sees every event first.

## Recipes
| Want | Do |
|---|---|
| a new panel | `draw_x_panel :: proc(app: ^App)` opening with `defer imgui.End()` then `if !imgui.Begin("X") do return`; call it from `ui_draw`; dock it in `build_default_layout` |
| a button that changes the scene | a new `Scene_Command.kind` and a `scene_apply` case (the sm-cad checklist); the panel only sets `scene_command` |
| a new statistic | a `Sample_Ring` in `Frame_Stats` (`src/app/stats.odin:32-56`), `ring_push` where it is measured, a `row(…)` line in the Stats panel and a key in the exit stats |
| an A/B toggle | `imgui.Checkbox("…", &app.<field>)` plus a `--no-<x>` field in `Options` and a sentence in README "App flags" |
| a shortcut | a line in `handle_shortcuts` and README "Controls" |
| text with numbers | `imgui.Text("%d", i32(n))`; strings through `fmt.ctprintf` (temp memory, fine within the frame); `count_label`/`bytes_label` for human sizes (`:421-436`) |
| a greyed-out control | `imgui.BeginDisabled(cond)` … `imgui.EndDisabled()` pairs |

## Traps
| You might expect | What happens |
|---|---|
| the viewport texture resizes where it is drawn | the request is applied at the start of the next frame, before ImGui references the texture (`main.odin:280-283`) |
| `Selectable` returns the selected state | it returns clicked; keep the state yourself (`:274`) |
| `IsKeyPressed(key)` fires once | it repeats by default; pass `false` for one-shot keys |
| the brush circle sits under the cursor | with lazy mouse it is drawn at `stroke.pos`, on a string to the cursor |
| the camera turns whenever the mouse moves | only while hovered or dragging, and never while `primary` sculpts (`camera_apply_input`) |
| ImGui keeps some of the state | never: it sees pointers per frame (`ui.odin:12-13`); state lives in `App` or `Ui_State` |
| a shortcut fires while typing a number | `WantTextInput` guards all of them |

## Verify
- `--frames=120 --dump-viewport` shows the viewport only (ImGui draws into the swapchain); for a panel, log the command
  or state it produced, or read the exit stats; `build.bat smoke` after changing the frame loop.
