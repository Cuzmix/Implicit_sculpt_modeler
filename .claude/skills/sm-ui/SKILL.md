---
name: sm-ui
description: The interface — the kit in src/ui (containers, widgets, hit testing, tokens, motion, popovers, layers, text fields) and its use in src/app (new_ui.odin's toolbars, dock, inspector and menus; kit_tool, kit_object, kit_scene, kit_stats; each feature's kit_*_section; the History panel in timeline.odin) — and the frame loop around it: the Device (keys, pointer, typed text from SDL), Viewport_Input (all the camera and tools read), pen samples, the viewport overlay under the panels (brush outline, gizmo, gesture shapes), the brush pie, shortcuts, Scene_Command, remembered settings. Load for ANY task that adds or changes something the user taps, reads or types, e.g. "add a section to the Object tab", "add a shortcut", "show X in the Stats panel", "the slider does not update", "the viewport ignores the pointer". Requires sm-odin and sm-build; what buttons do is sm-sculpt or sm-cad; viewport pixels are sm-render; touch targets and store rules are sm-store.
---

# Interface

## Model (README: the app row of "Layout", "Interface", "Controls")
- One interface, drawn by the kit (`src/ui`, no SDL or `render` imports) through the renderer's UI pass
  (`src/render/ui_pass.odin`). The viewport fills the window: `ui.image` draws it first, then the panels float over it.
- The frame (`src/app/main.odin`): events → `device_event` (`src/app/device.odin:51`), `touch_event`, pointer samples →
  `device_frame_end` (modifiers) → `viewport_target_resize` → `kit_frame` (`new_ui.odin:283`: `kit_begin` builds the
  kit's `ui.Input` from the Device and applies `--ui-events`, then the viewport image, `ui.layer_mark`, `kit_layout`,
  `kit_viewport_input`, `handle_shortcuts`, `layer_drag_end`, text input on/off, F11/Tab/Escape) → `touch_apply` → the
  camera and the active tool → `draw_viewport_overlay` (`overlay.odin:82`) → the 3D work → `kit_upload` (`ui.frame_end`)
  → `ui_pass_draw` into the swapchain.
- `Device` (`device.odin:12`): this frame's keys (`Key_Press`, unshifted key codes from the scancode), Shift/Ctrl/Alt,
  the pointer in window coordinates and how far it moved, buttons down/pressed/released, the wheel, typed text, the
  right button's tap (`right_tap`, for the pie) and `input_at` (latency). `key_pressed(d, sdl.K_X, repeat)`.
- `Viewport_Input` (`ui.odin:110`), filled by `kit_viewport_input` (`new_ui.odin:327`): size and pointer in window
  coordinates, `hovered` (pointer over no panel), `dragging` (a press that began on the viewport, `ui.viewport_dragging`),
  `orbit_drag`, `pan_drag`, `primary`, `press`, `smooth` (Shift), `invert` (Ctrl), `alt`, `samples`, `pen_tilt`, then
  `pie_update` and `adjust_update` may mute it (`viewport_mute`). Nothing else reaches the camera or the tools.
- `Ui_State` (`ui.odin:15`): `viewport_request`, `scene_command`, the pointer over the viewport for shortcuts that act
  there, the pie, the S/U adjust, curve handles, and each section's own settings and last results. `Kit_State`
  (`new_ui.odin:30`): the kit context, which tab, which sections are open (`Kit_Section`), menus, Stats and History
  panels, the inspector's scroll, add shape and size, the overlay's `layer`, text input on or off.
- Layout (`kit_layout`, `new_ui.odin:360`): top left menu, undo and redo (tooltips name the step) and the History
  button; top middle the tools (`Tool` order: W, B, C, I) and X/Y/Z symmetry; top right View menu and the inspector
  button; left the tall size and strength sliders; bottom the brush dock and the brush browser; bottom right the
  object's status; then `kit_inspector`, `kit_stats`, `kit_history_panel`, and last the popovers.
- Inspector (`kit_inspector`, `new_ui.odin:486`): tabs Tool (`kit_tool_tab`, `kit_tool.odin`: the brush's Stroke,
  Colour, Falloff, Alpha, Pen, Options and Stroke recorder; Curve and Insert settings; Move help), Object
  (`kit_object.odin`: Transform, levels, HD, dynamic topology, mask, hide/clip/slice, paint and groups, morph, layers,
  deformation, remesh, mirror, retopo, project, booleans, extract) and Scene (`kit_scene.odin`: objects, Add, Material,
  Studio render, Camera). A feature's section lives beside its code (`kit_layers_section` in `layers.odin`,
  `kit_boolean_section` in `boolean.odin`, `kit_alpha_section` in `alphas.odin`, …). The inspector clips and scrolls:
  the wheel, or a drag that starts where no control took the press (`k.scroll_drag`); it stops above the status chip
  and, on narrow windows, the dock.
- Overlay (`overlay.odin`): drawn after the tools ran, in window coordinates through `Overlay` (points are window
  coordinates over `k.scale`), between `ui.layer_begin` and `ui.layer_end`, which move it under the panels into the
  layer `kit_frame` took over the viewport image. The pie (`draw_pie`) is drawn after it, over everything.
- Commands: a panel never mutates the scene; it sets `app.ui.scene_command` and the frame loop applies it at the start
  of the next frame. Mask commands go to `mask_command`; file actions to `file_dialog`/`file_post`, applied next frame
  (`file_take`), their outcome a `file_note` that the interface shows as a toast.
- Settings (`settings.odin`): `key values` lines; unknown keys are skipped, values clamped; the kit's add shape and
  size are `new_shape`/`new_vertices`.

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
| a shortcut | a line in `handle_shortcuts` (`src/app/shortcuts.odin`) with `key_pressed(d, sdl.K_…)`, and README "Controls" |
| a viewport input that tools must not see | clear it with `viewport_mute` before the tools read `Viewport_Input`; never filter inside a tool |
| a setting that survives a restart | a `key values` line in both `settings_save` and `settings_load`; a flag that sets it too overrides only when given |
| a curve to drag, a colour, a count | `kit_curve_editor`, `kit_color`, `kit_count` (`kit_widgets.odin`) |

## Traps
| You might expect | What happens |
|---|---|
| Shift+[ arrives as { | SDL3 leaves the modifiers out of key events' key codes: `e.key.key` is [ with Shift held too, and shortcuts compare against it with the modifiers apart |
| Ctrl+Z pressed and let go within one slow frame is lost | the Device counts the modifiers held when the frame's last key went down as held (`device_frame_end`) |
| a tap's press and release in one frame lose the press | `kit_viewport_input` counts a press this frame as held; the release among the samples ends the stroke |
| the overlay can be drawn where the viewport image is | the tools run after the layout; draw it after them, into the layer (`draw_viewport_overlay`) |
| an enumerated array literal can name some cases | `-vet` wants every case: set the rest in a loop (`kit_init` opens its sections that way) |
| `--ui-events` only press panels | they go through the Device as SDL events do: a scripted press on the viewport sculpts or orbits |
| a press on the inspector's gap does nothing | it starts a scroll drag; a press on a control never does |
| a long row of text fits | `paragraph` wraps to the column's width; `label` and `value_row` do not |
| a tween follows a drag | a drag must follow the pointer exactly: give it duration 0 (the inspector's scroll does) |
| a shortcut fires while typing a layer name | `handle_shortcuts` returns while `typing(app)`; new key handling must check it too |
| a select's options can be built once | they must stay valid for the frame (temp memory is fine) |

## Verify
- `--ui-events="5:move:800,450;6:down;7:up;9:right;12:wheel:-3"` drives the pointer in window points (Menu at 36,36;
  the inspector's tabs at about y 98 on a 1600 x 900 window), and `--dump-screen=build/x.png` writes the whole window,
  overlay included; open it and describe it. `ui_ms_*` and `ui_vertices` on exit are the kit's cost.
- `build.bat test` runs the kit's headless tests (`src/ui/ui_test.odin`); `build.bat smoke` after changing the frame loop.
