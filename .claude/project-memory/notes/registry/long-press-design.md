# Long press as the secondary action: design (workstream 2, touch parity, step 2)

Base: odin-sculpt 3ef12bc (modifier rail merged, PR #55). Pattern P3 (09_Interaction_Patterns.md), findings #15, #41, #48 and A-07.
Problem: on a tablet there is no right-click and no hover. Controls with options need a second gesture, and touch users never see the tooltips that name a control and its shortcut.

## Rule
- A finger or pen that presses a control and stays within the slop (10 pt) for LONG_PRESS fires the control's secondary action, once. LONG_PRESS is 0.45 s, a new theme value `long_press`, to tune on the tablet.
- Its release is then no click: a long press never also taps.
- From 0.15 s, a ring around the press point fills toward LONG_PRESS, so a tap shows nothing.
- Moving past the slop, a scroll stealing the press, a cancel, or a second button ends it with nothing fired.
- On the desktop, a right-click on a control (released over it) fires the same secondary action. A mouse holding the left button never long-presses.
- Controls without a secondary action show their tooltip (name and shortcut) on a long press, held until the finger lifts. That release is no click either. This is Nomad's help on long press.
- The viewport is not affected: a long press there is still a stroke or an orbit.
- There is no haptic: SDL has no phone vibration. It would need Android's Vibrator through JNI, which is a later step.

## Kit (`src/ui`)
- `Context` gains:
  - `press_at: f64`: ctx.time at the press, set in `interact`.
  - `last_id: Id`: the last widget's id, set in `interact`.
  - `long: Long_Press{id, fired: enum {None, Action, Tip}, claimed}`.
- `long_due(ctx, id) -> bool` is true when all of these hold:
  - `ctx.active == id`;
  - the pointer is a Finger or a Pen;
  - `ctx.time - press_at >= long_press`;
  - the pointer has travelled no further than the slop from `press_mouse`;
  - `.Left in down` and no cancel;
  - nothing has fired yet.
- `secondary(ctx) -> bool`, called right after a widget, applies to `ctx.last_id`:
  - it marks the widget as having a secondary action this frame (`long.claimed = id`);
  - it returns true once when `long_due`, and sets `fired = .Action`;
  - it also returns true when the right button is released on the widget while it is hot.
- The tooltip case is decided in `tooltip_draw`, at frame end, after every widget had its chance to claim the press:
  - if `long_due(active)` and the widget did not claim it, set `fired = .Tip` and show the active widget's tooltip at once, with no delay, for as long as it is held.
  - `tip()` records the text for the active widget even while the button is down.
- In `interact`, on release, `clicked` is false when `long.fired != .None` for this id. `long` is reset at the next press.
- `long_press_draw` runs in `frame_end`, after the tooltip, and draws the ring (accent arc of radius 22 around `press_mouse`) while counting toward due.
- `list_row`'s `menu` becomes `secondary`: right-release as before, or a long press.

## App: the directory for this step
| Control | Secondary (long press, right-click) |
|---|---|
| Undo, Redo | open the History panel |
| Dock tiles and brush browser tiles | pick that brush and open the inspector on its tool tab |
| Size and Strength sliders (left) | reset: size 60 px, strength the brush's default (`BRUSHES[kind].strength`) |
| Object status chip (bottom right) | the object menu (Focus, Duplicate, Delete) at the chip; a tap opens the inspector's Object tab |
| Scene list rows | the object menu (right-click today, now long press too) |
| Everything else with a tooltip | its tooltip |

Long press to "Assign key" (P10) waits for workstream 4. Slider value entry and favourites are out of scope.

## Tests
- `src/ui/ui_test.odin`:
  - a finger held still past LONG_PRESS fires `secondary` exactly once, and its release is no click;
  - held 0.3 s, it clicks and fires nothing;
  - moved past the slop, nothing fires;
  - a mouse left hold never fires;
  - a right release fires;
  - an unclaimed long press shows the tooltip and does not click;
  - a scroll steal ends it.
- `touch_check.py` scenarios (fingers held for real time, using a frame count that covers 0.45 s at the scripted frame rate, or a `--long-press=SECONDS` flag for tests):
  - long press Undo opens History;
  - long press on a dock tile opens the inspector on Brush and selects that brush;
  - long press on the size slider resets it;
  - long press on the status chip opens the object menu;
  - long press on a scene row opens the menu;
  - a long press on a plain button shows its tooltip and does not run it;
  - a tap still taps;
  - a long press then a drag on a slider still slides.
- New exit stats: `history_open`, `object_menu`, `tooltip_shown`. Existing ones cover the rest.
- check, test, smoke, touch_check, wincheck, androidcheck; a screenshot of the ring mid-press and of a long-press tooltip.

Size: about 350 lines with tests. It touches kit input (interact, tooltips) and app panels; there is no History, Scene_Command or GPU change.

## Changes from the sm-architect review (as built in step 2a, the kit)
- Split in two: 2a is the kit (long press, tooltips on long press, right-click twin, ring, `vslider(reset)`), `--ui-dt` and scene rows; 2b is the app directory (Undo/Redo, dock and browser tiles, sliders, status chip).
- `last_id` is cleared in `place` and set in `interact`, so `secondary()` after a disabled widget returns false.
- Nothing fires on a control with neither a claim nor a tooltip (`tip_len > 0` required); its slow tap still clicks. The ring shows only when the press would do something.
- `tip()` records the held widget's tooltip while down (finger or pen); `tooltip_draw` shows a `.Tip` at once, while held, above the control when there is room.
- `vslider(reset)` resets in the kit and rebases `press_value` and `press_mouse`; any value change while held calls `long_cancel` (slider, vslider, drag_value).
- `.Action` sets `press_won`, so a scroll cannot take the press; `.Tip` does not.
- Right-click needs press and release on the same widget (`right_on`); the pen's side button arrives as Right.
- `long.claimed` is reset in `frame_begin`; travel is tracked as the furthest from the press.
- `--ui-dt=SECONDS` fixes the kit clock; touch_check always passes 1/60, so a long press is 27 frames (LONG_PRESS_FRAMES 30). FINGER_HOLD and PIE_TAP stay on the real clock.
- Stats: `long_tip` (last long-press tooltip, underscores for spaces), `object_menu`; no `history_open` (window_history exists).
- Modifier rail: fingers never reach the kit, so a held finger stays the rail's hold; a pen long press on a rail button shows its tooltip and does not latch. The rail scenarios are unchanged and pass.
- Ring radius 34 pt, drawn round the press point.

## As built in step 2b (the app directory)
- Undo and Redo: a long press or right-click opens History. A disabled Undo (nothing to undo) takes no press, so it has no long press either.
- Dock and browser tiles: `brush_settings_open` picks the brush, closes Settings and opens the inspector on its Tool tab (the browser closes).
- The left sliders reset in the kit: size to `DEFAULT_RADIUS_PX` (60, now named in adjust.odin), strength to `BRUSHES[kind].strength`.
- The status line is a kit `chip` (new widget: a row of labels in one 48 pt target). A tap opens the inspector's Object tab; a long press opens the object menu above the chip (`object_menu_open(..., .Above)`).
- Stats `inspector_tab` and `brush_kind`; six touch_check scenarios (77 in all).
