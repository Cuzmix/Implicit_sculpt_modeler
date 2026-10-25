---
name: sm-ui
description: The interface — the kit in src/ui (containers, widgets, hit testing, the gesture arena, scrolling, fingers, tokens, motion, popovers, layers, text fields) and its use in src/app (new_ui.odin's toolbars, dock, inspector and menus; kit_tool, kit_object, kit_scene, kit_stats, kit_settings; each feature's kit_*_section; the History panel in timeline.odin) — and the frame loop: the Device, touch and pen routing (touch.odin, navigate.odin), Viewport_Input, pen samples, the viewport overlay, the brush pie, shortcuts, Scene_Command, remembered settings. Load for ANY task that adds or changes something the user taps, reads or types, e.g. "add a section to the Object tab", "add a shortcut", "add a setting", "show X in the Stats panel", "the slider does not update", "the viewport ignores the pointer", "a finger turns the view by itself". Requires sm-odin and sm-build; testing touch is sm-touch-testing; what buttons do is sm-sculpt or sm-cad; viewport pixels are sm-render; touch targets and store rules are sm-store.
---

# Interface

## Model (README: the app row of "Layout", "Interface", "Controls")
- One interface, drawn by the kit (`src/ui`, no SDL or `render` imports) through the renderer's UI pass
  (`src/render/ui_pass.odin`). The viewport fills the window: `ui.image` draws it first, then the panels float over it.
- The frame (`src/app/main.odin`): `kit_events_push` (`--ui-events` as SDL events) → events → `device_event`
  (`src/app/device.odin:59`), `touch_event` (`touch.odin`), pointer samples → `device_frame_end` (modifiers) →
  `viewport_target_resize` → `kit_frame` (`new_ui.odin:392`: `kit_begin` builds the kit's `ui.Input` from the Device,
  then the viewport image, `ui.layer_mark`, `kit_layout`, `kit_viewport_input`, `commands_handle_keys`, `layer_drag_end`,
  text input on/off, F11/Tab/Escape) → `camera_apply_input` (`navigate.odin`) and the active tool →
  `draw_viewport_overlay` (`overlay.odin:82`) → the 3D work → `kit_upload` (`ui.frame_end`) → `ui_pass_draw`.
- `Device` (`device.odin:12`): this frame's keys (`Key_Press`, unshifted key codes from the scancode, with the Ctrl/Shift/Alt held when each went down), Shift/Ctrl/Alt,
  the pointer in window coordinates and how far it moved, which kind drives it (`pointer`: `ui.Pointer_Kind` Mouse,
  Finger or Pen), buttons down/pressed/released, `cancel` (the system took the pointer back), the wheel, typed text,
  the right button's tap (`right_tap`, for the pie) and `input_at` (latency). `key_pressed(d, sdl.K_X, repeat)`;
  `device_pointing(d)` is false for a finger that is not touching (its last position is no hover).
- `Viewport_Input` (`ui.odin:108`), filled by `kit_viewport_input` (`new_ui.odin:436`): size and pointer in window
  coordinates, `hovered` (pointer over no panel), `dragging` (a press that began on the viewport, `ui.viewport_dragging`),
  `orbit_drag`, `pan_drag`, `zoom_drag`, `mouse_delta`, `primary`, `press`, `smooth` (Shift), `invert` (Ctrl), `alt`,
  `samples`, `pen_tilt`, the fingers' `touch_pan`, `touch_zoom`, `touch_zoom_at`, `touch_roll`; `touch_route` and
  `pointer_route` fill the navigation and decide who gets the press, then `pie_update` and `adjust_update` may mute it
  (`viewport_mute`). Nothing else reaches the camera or the tools.
- `Ui_State` (`ui.odin:15`): `viewport_request`, `scene_command`, the pointer over the viewport for shortcuts that act
  there, the pie, the S/U adjust, curve handles, and each section's own settings and last results. `Kit_State`
  (`new_ui.odin:30`): the kit context, which tab, which sections are open (`Kit_Section`), menus, Stats (Simple or
  Advanced), Settings (open, tab, scroll) and History panels, the interface size (`ui_scale`), the inspector's scroll,
  add shape and size, the overlay's `layer`, text input on or off.
- Layout (`kit_layout`, `new_ui.odin:360`): top left menu, undo and redo (tooltips name the step) and the History
  button; top middle the tools (`Tool` order: W, B, C, I) and X/Y/Z symmetry; top right View menu and the inspector
  button; left the tall size and strength sliders; bottom the brush dock and the brush browser; bottom right the
  object's status; then the four windows in `k.order` (back to front) and last the popovers.
- Windows (`src/ui/window.odin`, `Kit_Window` in `new_ui.odin`): the inspector, Stats, History and Settings are
  `ui.window_begin(ctx, name, title, &k.windows[which], x, y, offset, box, close_keys)` … `ui.window_end`: a title
  bar (drag it to move, Minimise folds to it, a tap on a folded title opens it, Close) over the caller's body, which
  is laid out only while `body` is true. A moved window keeps to its nearer edges (`ui.Window.x/y/offset`) and its
  title bar stays in the safe area. `raised` (a press anywhere on it) moves it to the end of `k.order` with
  `window_raise`; the draw order is the hit-test order from the next frame. `window_room` is the height it has where
  it is; `window_slide` the side it slides from. Positions and folds are `window` lines in the settings;
  `windows_reset` puts them back (Settings > Interface > Reset panel positions).
- Inspector (`kit_inspector`, `new_ui.odin:486`): tabs Tool (`kit_tool_tab`, `kit_tool.odin`: the brush's Stroke,
  Colour, Falloff, Alpha, Pen, Options and Stroke recorder; Curve and Insert settings; Move help), Object
  (`kit_object.odin`: Transform, levels, HD, dynamic topology, mask, hide/clip/slice, paint and groups, morph, layers,
  deformation, remesh, mirror, retopo, project, booleans, extract) and Scene (`kit_scene.odin`: objects, Add, Material,
  Studio render, Camera). A feature's section lives beside its code (`kit_layers_section` in `layers.odin`,
  `kit_boolean_section` in `boolean.odin`, `kit_alpha_section` in `alphas.odin`, …). Under its title bar the tabs and
  content are the clipped "inspector body", which scrolls (`ui.scroll_update` before it, `ui.scroll_take` after with
  the window as root, `drag_scroll` on it; see Input routing); where it starts it stops above the status chip and, on
  narrow windows, the dock. While Settings is open the inspector is hidden and inert.
- Settings panel (`kit_settings.odin`): tabs Interface, Camera, Touch, Performance (`Settings_Tab`), anchored right
  in the inspector's place, its body scrolling as the inspector does; each tab ends in "Reset <tab> settings"
  (`settings_reset`), the foot holds Reset everything (a second tap within `SETTINGS_WIPE_TIME` confirms) and Done
  (`settings_close` saves). Camera and touch preferences are `app.nav` (`Nav_Prefs`, `NAV_DEFAULT`, `navigate.odin`).
- Stats panel (`kit_stats.odin`): Simple (plain labels in Performance, While sculpting, Mesh, Memory groups; p50 is
  "typical", p99 "slower moments", never "worst") and Advanced (exact key names, p50/p99, graph, drawing switches);
  "What do these numbers mean?" explains them. Show only what is measured: an empty ring says "not measured yet".
- Overlay (`overlay.odin`): drawn after the tools ran, in window coordinates through `Overlay` (points are window
  coordinates over `k.scale`), between `ui.layer_begin` and `ui.layer_end`, which move it under the panels into the
  layer `kit_frame` took over the viewport image. The pie (`draw_pie`) is drawn after it, over everything. It also
  draws the safe zone's inner edge (`edge_inner`, navigate.odin), the orbit pivot's dot while an orbit moves, and the
  brush ring lying on the surface (`draw_surface_ring`, from `app.cursor`, which `cursor_update` in `cursor.odin`
  fills each frame after the tools: a raycast and `sculpt.sculptor_area_normal`, timed as `cursor_ms`).
- Commands: a panel never mutates the scene; it sets `app.ui.scene_command` and the frame loop applies it at the start
  of the next frame. Mask commands go to `mask_command`; file actions to `file_dialog`/`file_post`, applied next frame
  (`file_take`), their outcome a `file_note` that the interface shows as a toast.
- Settings (`settings.odin`): `key values` lines; unknown keys are skipped, values clamped; the kit's add shape and
  size are `new_shape`/`new_vertices`. Saved on exit, when Settings closes and on `DID_ENTER_BACKGROUND`;
  `--settings-file=PATH` reads and writes PATH even in scripted runs (`--frames` otherwise never touches settings).

## Input routing (README "Touch and pen"; ZBrush for iPad is the model)
- SDL's touch-to-mouse is off (`HINT_TOUCH_MOUSE_EVENTS` "0", `platform_hints` in `android.odin`): it warps the pointer
  to where a finger lands, which counted as a drag and turned the camera. So are its pen-to-touch and mouse-to-touch
  (stand-in fingers that joined a real finger's touch); `touch_event` drops `PEN_TOUCHID` and `MOUSE_TOUCHID` anyway. `touch_event` drives the Device from the
  touch's first finger with `device_move(d, at, jump = true)` (no movement counted) and `pointer = .Finger`; mouse
  events with `which == PEN_MOUSEID` are `.Pen`. Only `DIRECT` touch devices count (touchpads report fingers too).
- One owner per touch (React Native's responder): `Touch.owner` is decided in `touch_route` once the kit said where
  the first finger landed (`ui.viewport_dragging`): Interface keeps it to the end and ignores other fingers; Viewport
  turns 2+ fingers into `touch_pan`/`touch_zoom`/`touch_roll` (`ui.fingers_change`, `src/ui/fingers.odin`), 3 into
  size/strength, quick taps into undo/redo. A second finger releases the pointer (never on Interface); lifting never
  hands the touch back. Palm: a lone finger while the pen is near (`Touch.palm`). `FINGER_CANCELED` and the pen
  going down set `d.cancel`: widgets let go without a click and a stroke is taken back (`stroke_cancel`).
- One owner per viewport drag (`Drag`, `pointer_route`, `drag_decide` in `navigate.odin`): decided at the press and
  kept to the release: Tool, Orbit, Pan, Zoom or Muted. Right orbits (Shift/Alt pan, Ctrl zoom), middle pans, Alt+left
  orbits; the left button, a pen or one finger on the model is the tool's, on empty space orbits (a raycast at the
  press; Ctrl keeps it for mask/hide shapes), and within `Nav_Prefs.edge_size` of an edge (`in_edge`, the safe zone)
  orbits whatever is under it. An orbit's pivot is decided at the press (`orbit_pivot`: the pointer's hit, the last
  stroke's middle `app.pivot`, the selected object's middle, else the target; never behind the eye) into
  `Drag.pivot` and `Viewport_Input.orbit_pivot`, and `camera.orbit_turn_about` keeps it on screen. Fingers and the
  pen move nothing until past `theme.slop` (10 pt); a finger's stroke waits `FINGER_HOLD` (90 ms) with its samples
  kept, so a second finger makes a gesture first.
- The gesture arena in the kit (Flutter's): `interact` (`ui.odin:628`) records `press_host`, the innermost
  `drag_scroll` container under a press; a finger or pen press there is tentative (`press_won` false), a mouse press
  wins at once. `scroll_update` (`ui.odin:711`) steals a tentative press that moves vertically past the slop (no click
  follows, the control keeps its value); `claim_drag(ctx, axis)` (`ui.odin:691`) wins it for a control dragged along
  `axis` past the slop (sliders and `drag_value` use 0), or at once with -1 (`area`). `scroll_take` (`ui.odin:736`)
  starts a scroll from a press no control took. Hit areas count only inside their clip, and a root's hit area is its
  rect joined with its widgets' (`Placed.hit`, `hit_extend`), so a target past a panel's drawn edge is still the panel's.

## The kit (`src/ui`)
- Immediate mode. Each frame `ui.frame_begin(ctx, input)`, containers (`begin_anchored`/`begin`/`end`, `Box` for
  direction, gap, padding, size, background, clip, scroll, inert), widgets that return what was done, `frame_end`.
  State kept between frames: the held widget, where each container ended up (`placed_prev`: anchored containers are
  placed by last frame's size; `prev_layout` reads it), the text field with the keys, tweens.
- Ids hash the label into the parent container's id; text after `##` is part of the id but not shown. Two widgets with
  one label in one container are one widget: give repeated rows `##index` suffixes.
- The pointer: only the topmost anchored container under it answers; a press outside every container is a
  `viewport_drag` until all buttons are up, so a stroke over a panel never presses it. `wants_pointer` decides whether
  the viewport gets the pointer.
- Sizes are points; the draw list is pixels (`pixel_density`). Every hit area is at least `Theme.target` (48) points
  (`hit_area`; sm-store); what is drawn can be smaller (`control` 36, `row` 40). Widgets name tokens from
  `src/ui/theme.odin` (`THEME_DARK`, "Graphite"), never literal colours or sizes.
- Widgets (`widgets.odin`): `label`, `paragraph`, `caption`, `icon_button`, `button` (variant, tone, width, glyph,
  enabled), `toggle_button`, `tabs` (segmented control; `chosen` -1 shows none), `switch_row`, `slider` (linear or
  logarithmic), `vslider`, `drag_value` (drag sideways, from the press value), `text_field` (a `[]u8` buffer),
  `select`, `list_row`, `menu_item`, `brush_tile`, `section`/`section_end`, `value_row`, `plot`, `area` (a space to draw
  into that reports the pointer: graphs, bars, thumbnails), `grey_image`, `divider`. Shapes (`ui.odin`): `fill_rect`,
  `stroke_rect`, `fill_circle`, `stroke_circle`, `line`, `polyline`, `fill_convex`, `text`, `icon`.
- Every pressable widget has default, hover, pressed, selected and disabled looks through `feedback`; selected tabs,
  tiles and segments use `indicator`, one sliding marker per container drawn under the content.
- Motion (`motion.odin`): `tween(ctx, salt(id, n), target, duration, ease)`; `presence` gives a 0–1 enter/exit share;
  animate by `transform_since`/`rotate_since` on the vertices drawn since a `vertex_mark`, never by changing the
  layout. The clock is the sum of clamped `Input.dt`. `ctx.reduced_motion` makes every duration 0. Nothing a stroke,
  the camera or a drag reads animates.
- Popovers (`popup.odin`): `popover_begin(ctx, name, open, anchor, side, box)` … `popover_end`; a press outside one
  closes it (swallowed if on the viewport); the first frame is measured invisibly. Selects draw their list in
  `frame_end`, over everything. `tip(ctx, id, rect, text, keys)` gives a tooltip; `toast(ctx, message, kind)` a note.
- Layers (`ui.odin:666`): `layer_mark` keeps a place in the draw order; what is drawn between `layer_begin` and
  `layer_end` goes there, under everything drawn after the mark. Draw in it with the whole window as the clip.
- Text fields: `typing(ctx)` is true while one has the keys; the app then calls `sdl.StartTextInput` (a tablet's
  on-screen keyboard) and turns its shortcuts off (`typing(app)`); `Input.text`, `backspace` and `text_end` (Enter or
  Escape) feed it. A field not drawn in a frame loses the keys.

## Recipes
| Want | Do |
|---|---|
| a control | a widget call in the right section of `kit_tool.odin`, `kit_object.odin`, `kit_scene.odin` or a feature's `kit_*_section`, editing `App` through a pointer |
| a new section | a `Kit_Section` value (`new_ui.odin:64`), open by default only if it belongs in `kit_init`'s list, then `if ui.section(ctx, "Title", &k.open[.X]) { …; ui.section_end(ctx) }` |
| a new widget | `src/ui/widgets.odin`, tokens only, hit area at least `target`, with a test in `ui_test.odin` if it has logic |
| a button that changes the scene | a new `Scene_Command.kind` and a `scene_apply` case (the sm-cad checklist); the panel only sets `scene_command` |
| a new statistic | a `Sample_Ring` in `Frame_Stats` (`src/app/stats.odin`), `ring_push` where it is measured, a `value_row` in `kit_stats.odin` and a key in the exit stats |
| an A/B toggle | `ui.switch_row(ctx, "…", &app.<field>)` in the Stats panel's Drawing section plus a `--no-<x>` field in `Options` and a sentence in README "App flags" |
| something drawn over the viewport | `overlay_*` calls in `overlay_viewport` (`overlay.odin`), in window coordinates |
| a shortcut | a `Command_Id` and its `COMMANDS` row (label, help, icon, run, enabled, checked) in `src/app/commands.odin` if the action is new, and a `DEFAULT_BINDINGS` row (exact modifiers, kept in the order keys are read); menus show it through `command_menu_item`, tooltips through `command_keys`; `commands_test.odin` refuses a chord bound twice; README "Controls" |
| a viewport input that tools must not see | clear it with `viewport_mute` before the tools read `Viewport_Input`; never filter inside a tool |
| a setting that survives a restart | a `key values` line in both `settings_save` and `settings_load`; a flag that sets it too overrides only when given |
| a user preference in Settings | a field in `Nav_Prefs`/`Kit_State` with its default in `NAV_DEFAULT` or `kit_init`, a row in its `settings_<tab>` proc with a one-line `paragraph`, a line in `settings_reset`, the two settings lines above, README "Settings" |
| a control that drags sideways inside a scrolling panel | act only `if held && claim_drag(ctx, 0)` (a tap may still act on `clicked`), so a vertical finger drag scrolls instead |
| a new scrolling panel | `scroll_update(ctx, id, prev_rect(ctx, name), &scroll, limit)` before the body, `begin` it with `clip`, `scroll` and `drag_scroll = true`, `scroll_take(ctx, id, scroll, limit, root)` after; follow the drag with tween duration 0 |
| a new floating panel | a `Kit_Window` value, a place in `KIT_WINDOW_ORDER`, its proc returning `raised` from `ui.window_begin` (default anchors as `begin_anchored`'s) with its body only while `body`, `ui.window_end`, a case in `kit_layout`'s loop and in the exit stats' `window_*` names; scroll its body as above, sized by `window_room` |
| a touch gesture | measure in `touch_route` (Viewport owner only, every finger still down: `f.count == f.most`), write a `Viewport_Input` field, apply it in `camera_apply_input` (it runs with no pointer down) or the tool; a switch in Settings > Touch; a scenario in `scripts/touch_check.py` |
| a curve to drag, a colour, a count | `kit_curve_editor`, `kit_color`, `kit_count` (`kit_widgets.odin`) |

## Traps
| You might expect | What happens |
|---|---|
| Shift+[ arrives as { | SDL3 leaves the modifiers out of key events' key codes: `e.key.key` is [ with Shift held too, and shortcuts compare against it with the modifiers apart |
| Ctrl+Z pressed and let go within one slow frame is lost | the Device counts the modifiers held when the frame's last key went down as held (`device_frame_end`) |
| a tap's press and release in one frame lose the press | `kit_viewport_input` counts a press this frame as held; the release among the samples ends the stroke |
| a finger's first press is a drag from where the last finger lifted | it was, with SDL's touch mouse; now `device_move(jump = true)` and drags measure from last frame's pointer (`Drag.last`), never SDL's motion sum |
| a finger press on a slider in the inspector moves it | it is tentative until it moves: sideways the slider wins, vertically the inspector scrolls, a tap lands as a tap |
| the camera ignores two fingers when no button is down | `camera_apply_input` applies `touch_*` before its hovered/dragging check: keep gesture fields ahead of it |
| gesture totals start at zero | they live in `Touch` and reset on the first finger down (`t.axis = -1`), not in `Drag`, which a gesture may never set |
| an orbit turns by the whole drag | the move that crosses the slop is not counted for fingers and the pen; scenario paths use `past_slop` |
| the overlay can be drawn where the viewport image is | the tools run after the layout; draw it after them, into the layer (`draw_viewport_overlay`) |
| an enumerated array literal can name some cases | `-vet` wants every case: set the rest in a loop (`kit_init` opens its sections that way) |
| `--ui-events` only press panels | they are pushed as SDL events (`kit_events_push`): a scripted press on the viewport sculpts or orbits; `fdown`/`pdown` are a touch screen's finger and the pen |
| a mouse press on a control scrolls the inspector | only a press on its gap does; a mouse wins any control at once (fingers and the pen scroll from anywhere) |
| a long row of text fits | `paragraph` wraps to the column's width; `label` and `value_row` do not |
| a tween follows a drag | a drag must follow the pointer exactly: give it duration 0 (the inspector's scroll does) |
| a shortcut fires while typing a layer name | `commands_handle_keys` returns while `typing(app)`; new key handling must check it too |
| a select's options can be built once | they must stay valid for the frame (temp memory is fine) |

## Verify
- `--ui-events="5:move:800,450;6:down;7:up;9:right;12:wheel:-3;14:fdown:0:300,300;16:fup:0"` drives the mouse,
  fingers and pen in window points (Menu at 36,36, Menu > Settings at 85,447; the inspector's title bar at y 103, its
  Minimise at 1504 and Close at 1554, and its tabs at about y 152 on a 1600 x 900 window), and
  `--dump-screen=build/x.png` writes the whole window, overlay included; open it and describe it. `ui_ms_*` and
  `ui_vertices` on exit are the kit's cost; `camera_*`, `undo_steps`, `brush_radius_px`, `inspector_scroll`,
  `settings_open` and `window_<name>=open,folded,left,top` show what the input did.
- `python scripts/touch_check.py` runs every touch, pen and mouse scenario (sm-touch-testing) after a debug build.
- `build.bat test` runs the kit's headless tests (`src/ui/ui_test.odin`); `build.bat smoke` after changing the frame loop.
