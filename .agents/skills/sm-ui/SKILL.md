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
  `samples`, `pen_tilt`, the fingers' `touch_pan`, `touch_zoom`, `touch_roll`, `touch_at`; `touch_route` and
  `pointer_route` fill the navigation and decide who gets the press, then `pie_update` and `adjust_update` may mute it
  (`viewport_mute`). Nothing else reaches the camera or the tools.
- `Ui_State` (`ui.odin:15`): `viewport_request`, `scene_command`, the pointer over the viewport for shortcuts that act
  there, the pie, the S/U adjust, curve handles, and each section's own settings and last results. `Kit_State`
  (`new_ui.odin:30`): the kit context, which tab, which sections are open (`Kit_Section`), menus, Stats (Simple or
  Advanced), Settings (open, tab, scroll) and History panels, the interface size (`ui_scale`), the tray's scroll,
  add shape and size, the overlay's `layer`, text input on or off.
- Layout (`kit_layout`, `new_ui.odin`; the bars in `kit_bars.odin`, after ZBrush for iPad): `kit_top_bar` (a full-width
  strip, `TOP_BAR_H`: Menu, Save, Import, Export | file name | History, Edit pies, Help, Settings), `kit_points` (the
  object's readout under it, at the top left), `kit_brush_bar` (left column, top from `brush_bar_top`, which keeps
  it above the wheel in the corner where there is room: Brushes, Stroke, Alpha, Material, Colour (`bar_swatches`, long
  press = `.Swap_Colors`), the paint channel (`.Paint_Channel` cycles) | Focal shift, Draw size, Strength, Add, Subtract
  (`.Brush_Add`/`.Brush_Subtract` on `rail.latched` Invert) | Undo, Redo; those three are `bar_value_button`s: tap = tall slider, finger or pen
  long press held = a `Bar_Scrub` that drags the value up and down with a readout (`kit_bar_scrub`), long press let go
  without dragging or a right click = the Falloff or Pen section, a cancel restores the value), `kit_nav_head` (`nav_head.odin`: the navigation head
  top right, `NAV_HEAD_W` x `NAV_HEAD_H`, a `ui.area` showing the renderer's picture; tap = `View_Axis` from that side,
  drag = orbit), `kit_view_bar` (right, from `nav_head_bottom()`: Search, Palettes (the tray), Objects (the card); then the shortcut column the user
  arranges, `k.shortcuts` (`bars.odin`: `Bar_List` of `Bar_Slot` commands drawn by `bar_slot_button`, whose `bar_slot_run`/
  `bar_slot_more`/`bar_lit`/`bar_icon` keep each command's own tap, long press and lit state wherever it sits; a fresh
  install's `SHORTCUTS_DEFAULT`: Shading and Camera (a tap opens `Bar_Pop_Kind.Shading`/`.Camera`,
  `kit_shading_menu`/`kit_camera_menu`, beside `k.bar_at[kind]`), Studio render, Floor grid, Symmetry, Local symmetry,
  Focus, Wireframe, Transparency, Ghost, Solo; it scrolls in a `kit_scroll` when too tall);
  touch_check's `UI` table has each button's place, so a button added here shifts the ones under it there); bottom `kit_bottom_bar` (a page of the dock's slots,
  `dock_page_slots`/`dock_per_page`, in the clipped `drag_scroll` row "dock slots" that `ui.swipe_update` turns by a
  sideways finger or pen drag (`dock_turn`, `k.dock_slide` easing the new page in, `dock_peek` drawing the next page
  inert behind the slide; the wheel over it turns too), with `ui.page_dots` under it; All brushes; then the tool strip
  `k.tools`, `TOOLS_DEFAULT` Gizmo, Remesh (long press: `Bar_Pop_Kind.Remesh_Quick`, `kit_remesh_quick` in rebuild.odin),
  Dynamic topology, Retopologize, Subdivide, Live boolean, the others' long press their Object section above it; the
  dock sits `DOCK_LIFT` above the edge margin, so measure it with `dock_stack`). A dock slot is a brush, a preset or a
  command (`Dock_Slot.command`), `dock_used` of up to `DOCK_SLOTS`. Customise bars (`k.bars_edit`, `.Customise_Bars`)
  rings every slot; a tap opens `kit_bar_slot_menu` (column, strip) or `kit_dock_menu`, both with `bar_slot_actions`,
  and Search chooses a command through `Palette_For`'s `Bar_Pick` (`bar_choose`, `bar_put`). That mode is Arrange
  (`src/app/arrange.odin`): `kit_arrange_head` (zone switches via `zone_toggle`, Panels, Reset bars, Revert, Save as
  new, Done), `kit_arrange_drawer` (each panel Hidden/Left/Right/Float), `kit_arrange_ghosts` (a hidden dock, wheel
  or action bar as an outline with Show), and `kit_column_drop` outlines both columns while it is on. Curve and Insert are tiles in
  the brush browser; then the four windows in `k.order` (back to front) and last the popovers. Panels under the top bar
  start at `kit_top()`, clear of the side bars at `kit_left(app)`/`kit_right(app)`; a card under the top bar uses
  `kit_card_place`; a right-side panel keeps clear of the dock with `side_panel_below`. A bar button opens the one
  `Bar_Pop` (`bar_pop_toggle`): a tray section by `Kit_Section` (any palette's, `bar_section`), the size or strength
  slider, the symmetry axes or the save actions. `corner = true` on `icon_button` draws the triangle that says a long
  press does more. The look is `Kit_State.look` (`Look`: Studio, the default, or Graphite), `LOOK_THEMES` set as
  `ctx.theme` each frame in `kit_begin`; both themes share every size, so a look never moves a control.
- Windows (`src/ui/window.odin`, `Kit_Window` in `new_ui.odin`): the tray, Stats, History and Settings are
  `ui.window_begin(ctx, name, title, &k.windows[which], x, y, offset, box, close_keys)` … `ui.window_end`: a title
  bar (drag it to move, Minimise folds to it, a tap on a folded title opens it, Close) over the caller's body, which
  is laid out only while `body` is true. A moved window keeps to its nearer edges (`ui.Window.x/y/offset`) and its
  title bar stays in the safe area. `raised` (a press anywhere on it) moves it to the end of `k.order` with
  `window_raise`; the draw order is the hit-test order from the next frame. `window_room` is the height it has where
  it is; `window_slide` the side it slides from. Positions and folds are `window` lines in the settings;
  `windows_reset` puts them back (Settings > Interface > Reset panel positions).
- Panels and columns (`src/app/panels.odin`): `Panel_Ref :: union {Kit_Window, Kit_Section}` names a panel, a
  window or a tray section pinned on its own (`k.panels.pins`, `panel_pin_toggle`, `panel_pinnable`). Each panel proc
  calls `panel_begin(app, ref, title, x, y, offset, box)` … `panel_end`, never `ui.window_begin` itself: floating it
  is the window or card as before; docked (`k.panels.columns[side]`, laid out by `kit_columns`) it is its own root
  container placed at `k.panels.at[side]`, with a header (title, summary when folded, options, Minimise, Close) and a
  body scrolled by `Kit_Scroll` in the height `panel_water_fill` allots. Size the body from `Panel_Frame.room`, scroll
  from `Panel_Frame.owner`, and set `p.want` to the height the body would like. Docked panels are separate roots so
  hit testing and `prev_rect` by root name keep working; never nest one panel proc in another's container. A header
  dragged past the slop calls `panel_undock`, which floats the window under the finger and hands it the press with
  `ui.window_grab`; `panel_drag_follow` docks a floating panel let go over `column_zone`. `kit_panel_menu` is the
  options popover. `column` and `pinned` lines in the settings (`panels_save`, `panels_load_line`); `windows_reset`
  calls `panels_default`. Exit stats `column_left= column_right= panel_pins= panel_moves= panel_menu=`.
- Workspaces (`src/app/workspaces.odin`): a layout is text, `kit_layout_text(k)` (`hidden`, `open`, `window`,
  `column`, `pinned` lines, places written right-handed) and `kit_layout_put(k, text)`; the modified dot is that text
  against the current workspace's `saved`, once a frame (`workspaces_frame`). Built-ins are `built_in_layout(b)`,
  canonical by construction. A hidden `Zone` skips its bar in `kit_layout` (the top bar takes Undo/Redo or
  Search/Palettes); read the wheel's side with `rail_shown(k)`, never `k.rail_side`, and the action bar with
  `action_bar_shown`. A new panel that a layout should open goes in `LAYOUT_PANELS`. Commands `Workspace` (slot arg),
  `Workspace_Save/_Save_As/_Revert/_Reset/_Rename/_Delete`. The layout holds the column and strip bars (a `bars`
  line, then `bars_save`), never the dock, which is the user's own set; a text with no `bars` line keeps the bars.
- Passes (`src/app/passes.odin`, `k.passes`): `kit_pass_chip` in the top bar before History (fixed width,
  `pass_chip_width`), its list `kit_pass_menu`, commands `View_Pass` (arg the pass, Alt+1..6) and
  `View_Pass_Last` (Alt+0); a peek is `chip_held` (from `ui.held_long`, true while a press stays past the long press, mouse
  too) or `key_held` (backquote by keycode, intercepted in main.odin's event loop as Space is, reserved in
  `chord_reserved`), ignored while a time-lapse or turntable records (`recording`).
  Read what shows with `viewport_pass(k)`; the layout writes `pass` only when not Shaded and never a peek.
- Cards (`ui.card_begin`): a window with no title bar, as ZBrush for iPad's quick-access cards, its dots on top
  dragging it like a title bar and a long press on them returning `dock`, then a large centred title. The Objects
  card (`kit_objects_card.odin`, `Kit_Window.Objects`, `Objects_Card` command) is one: Add / Duplicate / New folder /
  More, then `ui.thumb_row` rows (a picture cell of `KIT_THUMBS_IMAGE` from `thumb_for`, the name, a switch under it,
  toggles at the right, an accent outline when selected; `drags = true` makes a mouse drag or a long press then drag
  report `dragged`), fed to the shared `kit_row_drags`/`kit_tree_drags` with a `Tree_Scroll` of its own body. It
  shares the tray's place: the tray or a side panel opening closes it (`tray_was`), `objects_card_toggle` closes
  them. Its menus are popovers in `kit_objects_card_menus`; `menu_item(trailing = true)` puts the icon at the right
  as iPad menus do.
  Under the list's size bar a `ui.section` "Actions" unfolds a `kit_scroll` body (`card_actions`): the V1 to V8 tiles
  (`.Visibility_Slot`, a `View_Change`), then one `ui.section` per `Card_Action`. Sections reuse other panels' content
  procs (`kit_boolean_section`, `kit_project_section`, `kit_extract_section`) rather than copies. Tile grids use
  `command_button(..., icon_only = true)`: the icon alone, the label in its tooltip. Touch scenarios reach section
  bodies by header coordinates (`OBJECTS_CARD` in touch_check), which move by `CARD_ROW_H` with each row the list
  gains or loses.
  The Colors card (`kit_colors.odin`, `Kit_Window.Colors`, `Colors_Card` command, the brush bar's Colour) is the other:
  beside the brush bar, Procreate's tabs (`Colors_Tab`) as `brush_tile`s along its bottom over a `kit_scroll` body,
  its state in `Kit_State.colors` (`Colors_Card`: the HSV it edits, kept apart from the RGB so a grey keeps its hue,
  `colors_sync` re-reading it when the colour changed elsewhere; history; your palettes). A pick goes through
  `colors_set_hsv`/`colors_set_rgb` and joins the history when the pointer lets go; `colors_pick` for taps. The
  Eyedropper is `eyedropper_frame` beside `group_pick_frame` in the frame loop, its loupe `draw_eyedropper` in the
  overlay; `COLORS_CARD` in touch_check holds the card's coordinates.
- Palette tray (`kit_inspector` in `new_ui.odin`, the rest in `kit_tray.odin`; still the "inspector" window and
  layout name): palettes `Kit_Tab` Tool (`kit_tool_tab`, `kit_tool.odin`: the brush's `BRUSH_SECTIONS`; Curve and
  Insert settings; Move help), Object (`kit_object.odin`, `OBJECT_SECTIONS`) and Scene (`kit_scene.odin`: Objects,
  the rows with eye and ghost (`scene_tree.odin`), then `SCENE_SECTIONS`), each showing ONE section,
  `k.section[tab]` read through `tray_section` (which falls back when the brush no longer offers it). A wide safe
  area (`tray_wide`, at least `TRAY_NAV_MIN_W`) lists palettes and sections down the tray's left (`kit_tray_list`);
  a narrow one puts them in a select (`kit_tray_select`). Open a section with `tray_open(app, sec)`; Kit_Section
  keeps the tray's sections first (`TRAY_SECTIONS`, `section_palette`) and the Stats panel's after. A feature's
  section lives beside its code (`kit_layers_section` in `layers.odin`, …) and starts with nothing but its
  controls (the tray draws its title). The content is the clipped "inspector body", which scrolls (see Input
  routing); the list scrolls on its own. Search's Show where (`tray_show`, `COMMAND_HOMES`) marks a command's
  control: `command_hint` calls `tray_mark`, which `ui.mark_next`s the next control while the tray draws, and
  `tray_mark_draw` rings `ctx.marked.rect`; `show_where_finds_every_home` checks every home has its control. The
  Show_Section command (one argument per section) opens any section from search, keys and scripts. While Settings
  or Help is open the tray is hidden and inert.
- Settings panel (`kit_settings.odin`): tabs Interface, Camera, Touch, Performance (`Settings_Tab`), anchored right
  in the tray's place, its body scrolling as the tray does; each tab ends in "Reset <tab> settings"
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
- Commands: an action button, menu row or shortcut runs a registry command (`command_run(app, .Id, arg)`, `src/app/commands.odin`), whose `enabled` also decides the button's enabled state and whose shortcut and touch gesture its tooltip shows through `command_hint` (`command_keys` joined to `command_gesture`, which follows the Settings and the tool); never type a shortcut into a label or paragraph. A panel never mutates the scene; it sets `app.ui.scene_command` and the frame loop applies it at the start
  of the next frame. Mask commands go to `mask_command`; file actions to `file_dialog`/`file_post`, applied next frame
  (`file_take`), their outcome a `file_note` that the interface shows as a toast.
- Operation results (`src/app/results.odin`): an operation says what it did once, with
  `report(app, section, flags, format, args)` (past tense, with its time); `.Quiet` for what
  shows by itself, `.Undo` right after recording its undo step. The kit shows it as a toast
  (with Undo when offered), its inspector section with `kit_last_result`, and Stats under Last
  operation. Never add a per-operation `*_last` struct to `app.ui`. Undo is tied to the step by
  `Undo_Mark` (object id and time), never by a count of steps. Destructive scene commands are
  reported by `scene_run` around `scene_apply`.
- Settings (`settings.odin`): `key values` lines after `version N`; unknown keys are skipped, values clamped. A plain
  field of App (bool, f32, i32 or an enum) is one row of `SETTINGS` {key, offset, type, lo, hi}, read and written by
  that row (`settings_test.odin` checks each row's offset and type against App); only compound values (per-brush
  strength and falloff, curves, symmetry, windows, material) are hand-written lines in both procs. The kit's add shape and
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
  turns 2+ fingers into `touch_pan`/`touch_zoom`/`touch_roll` (`ui.fingers_change`, `src/ui/fingers.odin`; a twist
  rolls where `twist_rolls` says, a turntable's through `roll_level_detent`, about `touch_at`), 3 into
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
  kept, so a second finger makes a gesture first. A press the lights take (`lights_take_press`, `light_markers.odin`:
  a light's marker while Scene > Lights shows, the picked point/spot light's move arms and plane squares
  (`light_gizmo`, `light_gizmo_pick`: `gizmo.screen` at its world place, the middle left to the marker), or the model
  with Place highlight on) is the Tool's at once, never pending, and `lights_viewport_frame` runs before the tools,
  as `group_pick_frame` does. `draw_move_handles` (overlay.odin) draws the arms and squares for both the Move tool
  and the lights.
- The modifier wheel (`modifiers.odin`, still `Modifier_Rail`/`rail_*` in code; `ui.wheel` in `src/ui/wheel.odin`;
  README "Touch and pen"): sectors Smooth (top), brush pie (right), Invert (bottom), Mask (left) by
  `WHEEL_SECTORS`; Smooth and Mask together are Hide (`rail_toggle`, `rail_mode`, `rail_press_mods`). Its hit test is by
  angle (`ui.wheel_sector_at`, `Modifier_Rail.center/outer/hole/turn`); the grip drags `Kit_State.wheel_offset` from its
  place (`rail_reach`/`rail_reach_across` are zero once moved); `wheel_size` picks `WHEEL_OUTER`/`WHEEL_HOLE` (Small
  to XL3), `wheel_labels` what `Wheel_Sector.glyph`/`caption` show, `wheel_turn` (degrees, `wheel_turn_snapped`) turns
  drawing and hit test alike. Two rail fingers that spread or twist (`rail_finger_move`, against their start
  positions) set `Modifier_Rail.gesture`: `rail_holds` then drops every finger from the mods, and `rail_gesture_apply`
  (in `kit_modifier_rail`) sets the size and turn; `rail_claims_plain` claims a second finger on the pie sector or grip
  as `Rail_Finger.plain` for it. The brush ring's colour by mode is `brush_ring_color` (red, pink inverted, blue,
  yellow, white for Hide).
  A finger landing on a modifier sector (`rail_claims`: the wheel is the top root at that point by `ui.root_at`, and no menu,
  popover or list is open) is recorded in `Modifier_Rail.fingers` before `ui.fingers_down` and goes no further: never
  the pointer, never a gesture finger or a palm, untouched by the pen's cancel; its motion and lift stop there too.
  `rail_press` (in `kit_viewport_input`, inside `if input.dragging`, before `touch_route`/`pointer_route`) snapshots
  `rail_press_mods` at the left press (held beats latched, the last held wins; any keyboard modifier leaves the rail
  out) and resolves it into `smooth`/`invert`/`alt`/`mask`/`mask_shape` every frame to the release. `mask_shape` (not
  `invert`) starts a mask shape; `stroke_brush`/`held_brush` (`sculpt_tool.odin`) pick Mask for `mask`. `route_mute`
  and `viewport_mute` clear all of them. `drag_decide` keeps empty space for Mask/Hide (Brush tool only) and gives
  them the safe zone only when held (`Rail_Press.held`). A new `Viewport_Input` flag a stroke depends on is also a
  `Take_Frame` flag in `replay.odin` (bump `STROKES_VERSION`).
- Long press (`ui.odin`: `Long_Press`, `long_due`, `secondary`, `long_cancel`, `press_used`, `long_press_decide`): a
  finger or pen held `theme.long_press` within the slop on the held widget: Settings > Touch > Hold delay
  (`Nav_Prefs.hold_delay`, 0.25 s by default, 0.1 to 1.5), which `kit_begin` puts in the theme each frame with
  `long_ring` at half of it at most; the two- and three-finger hold keeps its own `HOLD_LONG` (touch.odin). A widget
  with a secondary action calls `ui.secondary(ctx)` right after it (it acts on `ctx.last_id`, which `place` clears and
  `interact` sets, so a disabled widget never passes on its neighbour's); it fires once (or on a right press and
  release on that widget), wins the arena (`press_won`) and the release is no click. Unclaimed, a widget with a
  tooltip shows it at frame end (`.Tip`, also no click); with neither, nothing fires and the release clicks. A widget
  that moves a value while held calls `long_cancel`; one that takes the press for a drag of its own (the brush bar's
  values) calls `press_used`: no long press, no click, the arena won. `vslider(reset = v)` resets on a long press.
  `list_row.menu` is `secondary`. `tree_row` lays out its trailing toggles and chevron before its body, so a press on
  them never selects the row or opens its menu.
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
- Left-handed layout: `ctx.mirror` (Settings > Interface > Screen layout, `left_handed`) swaps every default x anchor
  (`ui.mirrored`: Start and End, a Center offset negated) in `begin_anchored`, `window_begin` and `card_begin`, and
  popovers' `.Left`/`.Right`; a moved window keeps its own anchor and `kit_mirror` flips it once when the hand changes.
  So write offsets as "from the brush bar's side" (`kit_left`) or "from the view bar's side" (`kit_right`) and anchor
  with them; anything measured from a real rect's `x` must mirror itself (`kit_card_place`, the wheel's drag sign).
- Ids hash the label into the parent container's id; text after `##` is part of the id but not shown. Two widgets with
  one label in one container are one widget: give repeated rows `##index` suffixes.
- The pointer: only the topmost anchored container under it answers; a press outside every container is a
  `viewport_drag` until all buttons are up, so a stroke over a panel never presses it. `wants_pointer` decides whether
  the viewport gets the pointer.
- Sizes are points; the draw list is pixels (`pixel_density`). Every hit area is at least `Theme.target` (48) points
  (`hit_area`; sm-store); what is drawn can be smaller (`control` 36, `row` 40). Widgets name tokens from
  `src/ui/theme.odin` (`THEME_STUDIO`, "Studio", and `THEME_DARK`, "Graphite"), never literal colours or sizes.
- Widgets (`widgets.odin`): `label`, `paragraph`, `caption`, `icon_button`, `button` (variant, tone, width, glyph,
  enabled, keys: a tooltip hint), `toggle_button`, `tabs` (segmented control; `chosen` -1 shows none; `keys` a hint per option), `switch_row`, `slider` (linear or
  logarithmic), `vslider`, `drag_value` (drag sideways, from the press value), `text_field` (a `[]u8` buffer),
  `select`, `gradient_slider` (a track of colour stops, for channels), `swatch` (a colour cell a whole target, `long` its menu), `list_row`, `tree_row` (indent, chevron, trailing `Row_Toggle`s, `grip` that drags the row and claims the press, `held_toggle` for a column drag: at once for a mouse, after the tooltip's hold for a finger or pen), `menu_item`, `brush_tile`, `preview_tile` (a large tile: a `fill_ball` material ball with an icon over a name; `selected` rings it, several at once in a row, `menu` its long press), `picture_tile` (a grid tile of something to open: an atlas `Picture` cut to a 4:3 well, a title and a line, a `Tile_Ring`, a danger `banner` for an armed tap), `section`/`section_end`, `value_row`, `plot`, `area` (a space to draw
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
  `frame_end`, over everything; a list taller than the room above or below its field is cut to the window and
  scrolls (`select_list_draw`). Popovers themselves only clamp to the window: one whose content can grow puts it in
  a `kit_scroll_begin` body sized to the room left (the brush grid, `dock.odin`). `tip(ctx, id, rect, text, keys)` gives a tooltip; `toast(ctx, message, kind, action)` a note, with an optional action button (`toast_take_action`, `toast_drop_action`).
- Layers (`ui.odin:666`): `layer_mark` keeps a place in the draw order; what is drawn between `layer_begin` and
  `layer_end` goes there, under everything drawn after the mark. Draw in it with the whole window as the clip.
- Text fields: `typing(ctx)` is true while one has the keys; the app then calls `sdl.StartTextInput` (a tablet's
  on-screen keyboard) and turns its shortcuts off (`typing(app)`); `Input.text`, `backspace` and `text_end` (Enter or
  Escape) feed it. A field not drawn in a frame loses the keys.

## Recipes
| Want | Do |
|---|---|
| a control | a widget call in the right section of `kit_tool.odin`, `kit_object.odin`, `kit_scene.odin` or a feature's `kit_*_section`, editing `App` through a pointer |
| a new section | a `Kit_Section` value (`new_ui.odin`), open by default only if it belongs in `kit_init`'s list, and a row in the tab's table (`BRUSH_SECTIONS` in kit_tool.odin, `OBJECT_SECTIONS` in kit_object.odin, `SCENE_SECTIONS` in kit_scene.odin), which draws it inside `ui.section` |
| more than five controls in a section | the first five (the commonest) as they are, the rest inside `if kit_more(app, .X) { …; kit_more_end(app) }` (kit_widgets.odin): a More options fold, or everything with Settings > Interface > Show every option. `sections_show_at_most_five_controls` (kit_more_test.odin) counts `ctx.controls` for every section in its widest state and fails over five; keep "Last: ..." lines and controls other features read (Mask's Steps) out of the fold |
| something floating (a menu, popover, list) | add its flag to `kit_floating` (new_ui.odin): Escape closes it before Settings or Help, and the first-run tip (kit_coach.odin) hides under it |
| a gesture that should count for a first-run tip | set `app.coach_seen += {.Step}` where the gesture changes the view or the model, only once it moved (past the slop for touches); coach_update counts it when the gesture ends |
| a new widget | `src/ui/widgets.odin`, tokens only, hit area at least `target`, with a test in `ui_test.odin` if it has logic |
| a button, pair, switch or tab that runs a command | `command_button(app, id, ...)` or `kit_command_pair(app, a, b, ...)` (label, enabled state and the `command_hint` tooltip from the registry); a switch or tab passes `keys = command_hint(...)` (tabs a `hints` slice); a new touch gesture goes in `command_gesture`; `controls_that_run_commands_show_their_hints` scans the sources and fails a widget that runs a command without its hint |
| a button that changes the scene | a new `Scene_Command.kind` and a `scene_apply` case (the sm-cad checklist); the panel only sets `scene_command` |
| a new statistic | a `Sample_Ring` in `Frame_Stats` (`src/app/stats.odin`), `ring_push` where it is measured, a `value_row` in `kit_stats.odin` and a key in the exit stats |
| an A/B toggle | `ui.switch_row(ctx, "…", &app.<field>)` in the Stats panel's Drawing section plus a `--no-<x>` field in `Options` and a sentence in README "App flags" |
| something drawn over the viewport | `overlay_*` calls in `overlay_viewport` (`overlay.odin`), in window coordinates |
| a shortcut | a `Command_Id` and its `COMMANDS` row (label, help, icon, run, enabled, checked) in `src/app/commands.odin` if the action is new, and a `DEFAULT_BINDINGS` row (exact modifiers, kept in the order keys are read); menus show it through `command_menu_item`, tooltips through `command_hint`; `commands_test.odin` refuses a chord bound twice; README "Controls"; the command palette lists it by itself: add the names other apps give it to `SEARCH_WORDS` (`palette.odin`), a clearer `PALETTE_LABELS` row when its menu heading says what the label leaves out, and leave it out in `palette_lists` if it acts where the pointer is; Help > Keys lists it by itself, in its `command_group` |
| a viewport input that tools must not see | clear it with `viewport_mute` before the tools read `Viewport_Input`; never filter inside a tool |
| a setting that survives a restart | one row in `SETTINGS` (a plain field), or a hand-written line in both `settings_save` and `settings_load` (a compound value); a flag that sets it too overrides only when given |
| a user preference in Settings | a field in `Nav_Prefs`/`Kit_State` with its default in `NAV_DEFAULT` or `kit_init`, a row in its `settings_<tab>` proc with a one-line `paragraph`, a line in `settings_reset`, the two settings lines above, README "Settings" |
| a control that drags sideways inside a scrolling panel | act only `if held && claim_drag(ctx, 0)` (a tap may still act on `clicked`), so a vertical finger drag scrolls instead |
| a new scrolling panel | in the app, `kit_scroll_begin(ctx, name, &scroll, window_id, width, height, gap)` before the body and `kit_scroll_end(ctx, s)` after (`new_ui.odin`: wheel, drag, easing and the bar, as the inspector, Settings and Help scroll); in the kit itself, `scroll_update(ctx, id, prev_rect(ctx, name), &scroll, limit)` before, `begin` with `clip`, `scroll` and `drag_scroll = true`, `scroll_take(ctx, id, scroll, limit, root)` after, the drag followed with tween duration 0 |
| a new floating panel | a `Kit_Window` value, a place in `KIT_WINDOW_ORDER`, its proc returning `raised` from `ui.window_begin` (default anchors as `begin_anchored`'s) with its body only while `body`, `ui.window_end`, a case in `kit_layout`'s loop and in the exit stats' `window_*` names; scroll its body as above, sized by `window_room`; one that opens on the right in the inspector's place joins `side_panel_open`/`side_panel_close` (Settings and Help) |
| a follow-up action for something active on the object | a group or a row in `ACTION_GROUPS` (`kit_action_bar.odin`) and its state in `action_groups_now`; derived facts that cost a scan (like `object_has_mask`) are cached on `history.serial`, never computed every frame; anything at the bottom middle keeps clear of `dock_stack`, the dock plus the bar |
| a long press (secondary action) on a control | `if ui.secondary(ctx) do ...` right after the widget (a value slider: `vslider(reset = v)`); add a row to README "Touch and pen" and a `long_press(s, x, y)` scenario; a control without one shows its tooltip |
| a touch gesture | measure in `touch_route` (Viewport owner only, every finger still down: `f.count == f.most`; the one exception is `touch_lift_orbit`, the finger left of two, which runs first and keeps the touch once armed), write a `Viewport_Input` field, apply it in `camera_apply_input` (it runs with no pointer down) or the tool; a switch in Settings > Touch; a scenario in `scripts/touch_check.py`; a line in `TOUCH_HELP` (`kit_help.odin`) so Help > Gestures lists it (`help_touch_rows_hold_every_gesture` fails a `command_gesture` missing there) |
| a command in a user pie, or starred | nothing to add: any command `pie_lists` allows can go in a pie (`user_pies.odin`) from the palette's Put in a pie, and any palette row can be starred; one that acts where the pointer is belongs out of `pie_lists` too, since the pie sits over that spot |
| a popover opened by a command a click runs | close the others in its open proc (as `palette_open`, `bind_open`, `pie_editor_open`), add its flag to `kit_floating` and to kit_frame's Escape list; a pie or popover opened during the layout must not see the same click (`Pie.opened_frame`) |
| a command in Settings > Keys | nothing to add: the tab lists every command `palette_lists` keeps, in Help's `command_group` order, and finds it by `keys_match` (`kit_keys.odin`); what a mouse button does to the view is `mouse_button_owner` (`navigate.odin`), by `Nav_Prefs.mouse_scheme`, and its words for the tab and Help are `MOUSE_SCHEME_HOW` |
| something the pen does while hovering over a control | the pen arrives as the mouse with `ui.Input.pointer == .Pen`: test `ctx.hot == ctx.last_id` after the widget and `input.down == {}`; a bar value's label carries its value, so its id changes as it does (track it by kind and rect, as `bar_roll` does); hover tooltips follow `Nav_Prefs.pen_tips` through `ui.Input.no_hover_tips`; `tip_showing=` in the exit stats is the tooltip the last frame drew |
| a touch gesture that runs a command | a `Gesture_Slot` in `gesture_map.odin` (name, default, its place in `GESTURE_SLOT_ORDER`, `gesture_slot` for its fingers) and a `gesture_run` where it is recognised; tooltips, the palette and Help follow `gesture_text`; an overlap the user should know of is a line in `gesture_notes`, never silent. Any command `gesture_lists` allows can go on a slot: `GESTURE_CHOICES` is only the dropdown's short list, and its Any command... row opens the palette in choosing mode (`palette_open_for`, `Kit.palette_for`), where `palette_run` assigns instead of running |
| a per-pointer strength or scale on a stroke | set it once in `stroke_start` into `Stroke` (as `Stroke.scale`, Touch strength for a finger), read it in `brush_at`; record it per stroke in `Take` and the `.strokes` file (bump `STROKES_VERSION`, old files read the neutral value), and have `replay_frame` and `dab_wait_resolve` force it through `App.stroke_scale_from`, since the pointer then is not the one that drew |
| a curve to drag, a colour, a count | `kit_curve_editor`, `kit_color`, `kit_count` (`kit_widgets.odin`); `kit_color` shows sRGB with a hex field (`kit_hex_field`, which the Colors card's Value tab shares) (`linear = true` for a colour stored as linear light, as materials are) and counts as one control in the five-control test; its well (a stretched `ui.swatch`) opens `kit_color_popover`, which edits a copy and hands it back through `Colors_Card.pop_set` on the next frame, so no pointer into a panel is kept |

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
| a text field keeps the keys while its popover is open | a plain `text_field` lets them go on Enter, Escape or any press elsewhere; one that must keep them (the palette's) passes `hold = open`, and its owner sets `ctx.text_focus = 0` when it closes; shortcuts stay off while `k.palette` is set, since a popover's field is first drawn a frame or two after it opens |
| a mouse press on a control scrolls the inspector | only a press on its gap does; a mouse wins any control at once (fingers and the pen scroll from anywhere) |
| a long row of text fits | `paragraph` wraps to the column's width; `label` and `value_row` do not |
| a tween follows a drag | a drag must follow the pointer exactly: give it duration 0 (the inspector's scroll does) |
| a shortcut fires while typing a layer name | `commands_handle_keys` returns while `typing(app)`; new key handling must check it too |
| a select's options can be built once | they must stay valid for the frame (temp memory is fine) |
| a press while a pie is open reaches the panel under it | kit_begin hands the kit no press, hold or release while `app.ui.pie.open` or `.swallow`; a right tap then closes the pie from anywhere |
| Escape with a pie and Settings open closes both | the pie reads Escape in `pie_update`, before kit_frame's Escape list: kit_frame takes `kit_floating` before `kit_viewport_input`, so Settings stays |
| Escape in a side panel's text field closes the panel | kit_frame closes Settings or Help on Escape only when nothing floats and no field had the keys at the frame's start (`typed`) |
| the same widget twice in one container | ids come from labels: give each a `##` suffix (`"Clay##slot 3"`); the text after `##` is not shown |
| a shortcut's text or the keys a command has | `command_keys(app, …)` / `command_chords(app, …)` / `keymap(app)` (keymap.odin), never DEFAULT_BINDINGS: the user's `key` overrides change them (Ctrl+Alt+click → Assign key, kit_bind.odin) |
| a control that runs a command | through `command_run` during the layout: a Ctrl+Alt click there opens Assign key instead (`bind_click`, `ui.Context.clicked_rect`); an action that is no command (presets) is not bindable |
| a dock slot | `dock.odin`: `Kit_State.dock` slots (three pages of `DOCK_PAGE`; a brush or a preset from 1), `kit_brush_grid` for every brush and preset, `dock_preset_deleted` when presets shift; the slot menu is `k.dock_menu` |
| the brush browser | `kit_brushes.odin`: ZBrush's Brushes palette over `k.browser`; everything it lists is a `Brush_Item` (brush or preset slot, tool, mask shape, gesture) with a `brush_item_key` that Recent and Favorites keep; a new kind of item needs its name, icon, key, category, pick and settings there |

## Verify
- `--ui-events="5:move:800,450;6:down;7:up;9:right;12:wheel:-3;14:fdown:0:300,300;16:fup:0"` drives the mouse,
  fingers and pen in window points (Menu at 26,26, Menu > Settings at 75,688; the inspector's title bar at y 104, its
  Minimise at 1450 and Close at 1500, and its tabs at about y 154 on a 1600 x 900 window; the `UI` table at the top of
  `scripts/touch_check.py` names every bar button's position; `pnear`, `pmove`, `ppress:P` and `proll:DEG` are the
  pen hovering, moving, pressing and turned about its length, which `pen_roll_take` turns into `App.pen_roll`), and
  `--dump-screen=build/x.png` writes the whole window, overlay included; open it and describe it. `ui_ms_*` and
  `ui_vertices` on exit are the kit's cost; `camera_*`, `undo_steps`, `brush_radius_px`, `inspector_scroll`,
  `settings_open` and `window_<name>=open,folded,left,top` show what the input did.
- `python scripts/touch_check.py` runs every touch, pen and mouse scenario (sm-touch-testing) after a debug build.
- `build.bat test` runs the kit's headless tests (`src/ui/ui_test.odin`); `build.bat smoke` after changing the frame loop.
