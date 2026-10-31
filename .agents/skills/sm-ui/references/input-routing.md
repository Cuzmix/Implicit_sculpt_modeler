# Input routing (sm-ui; README "Touch and pen"; ZBrush for iPad is the model)

Read from sm-ui before changing how a finger, the pen or the mouse reaches a panel, the viewport or the camera.

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
  that moves a value while held calls `long_cancel`; one that takes the press for a drag of its own (the island's
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
