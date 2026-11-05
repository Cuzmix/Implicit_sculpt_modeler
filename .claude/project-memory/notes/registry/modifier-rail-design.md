# Modifier rail and coloured cursor: design (workstream 2, touch parity, step 1)

Base: odin-sculpt c82e921 (registry done, PRs #50-#54). Pattern P1 (09_Interaction_Patterns.md) and P15. Touch has no Shift, Ctrl or Alt, so on a tablet there is no Smooth, invert, mask shape or hide gesture without the keyboard. Nomad and 3DCoat give buttons that latch on a tap and act while held.

## What exists
- Keyboard modifiers reach the tool through `Viewport_Input` (`kit_viewport_input`, new_ui.odin ~520): `smooth` = Shift, `invert` = Ctrl, `alt` = Alt with a primary drag.
- What they mean today: Shift on the model smooths (sculpt_tool.odin:447); Ctrl on the model inverts; Ctrl dragged from empty space draws a mask shape (mask_shape.odin:32, Alt unmasks); Ctrl+Shift drag runs the picked gesture tool (clip.odin:45: hide rectangle/lasso, clip, slice; Alt flips), and a Ctrl+Shift click on a group isolates it (paint.odin).
- `drag_decide` (navigate.odin) keeps empty space and the safe zone for the tool when `d.ctrl`, so shapes can start there.
- Touch (touch.odin): one touch at a time, owned by where its first finger landed; a finger on a panel is the kit's pointer; the pen going down cancels a touch in progress (palm rejection). So a finger held on a normal kit button cannot stay held while the pen sculpts.

## Design

### State (new `src/app/modifiers.odin`)
```odin
Modifier :: enum u8 {Smooth, Invert, Mask, Hide}
Modifiers :: bit_set[Modifier; u8]
Modifier_Rail :: struct {
	latched: Modifiers,              // stays on until tapped again
	fingers: [4]struct {id: u64, which: Modifier, at: f64, used: bool}, // fingers held on rail buttons
	count:   int,
	rects:   [Modifier]ui.Rect,      // last frame's buttons, window coordinates, for touch_event
}
RAIL_TAP :: 0.25 // seconds: a shorter press that sculpted nothing is a tap (P1, tune on the tablet)
```
- Smooth, Mask and Hide are one mode at a time: latching one unlatches the other two. Invert is separate and combines with the mode.
- `rail_mods(app) -> Modifiers` = latched ∪ held (fingers). `rail_mode(app)` picks the mode with Hide > Mask > Smooth.

### Pressing a button
- **A finger on a rail button belongs to the rail, not to the touch.** In `touch_event` FINGER_DOWN, before `ui.fingers_down`, a finger landing in `rail.rects` (and the rail shown) is recorded in `rail.fingers` and goes no further. It does not become the pointer, does not count toward a gesture or a palm, and the pen landing does not cancel it. Its FINGER_UP or CANCEL releases it.
- **Release rule**, a pure function `rail_release(rail, finger, now) -> toggled: bool`:
  - Released within RAIL_TAP with no stroke made while it was held: a tap, which toggles the latch.
  - Otherwise (held longer, or a stroke ran while held): momentary, and the latch is unchanged. A cancel is never a tap.
- **The mouse and the pen** press rail buttons through the kit as ordinary buttons. A click toggles the latch. They cannot hold a button and stroke at once, so they only latch.
- **A stroke while a finger is held** marks that finger `used` (`stroke_start` sets it), so lifting it afterwards never latches.
- **The keyboard** lights the buttons but never latches them: Shift lights Smooth, Ctrl lights Invert, Ctrl+Shift lights Hide.

### What the rail does (resolved in `kit_viewport_input`, next to the keyboard's)
| Rail | On the model | From empty space |
|---|---|---|
| Smooth | smooth stroke (as Shift) | orbit, as today |
| Invert | inverted stroke (as Ctrl on the model) | orbit (no mask shape) |
| Mask | paints the mask: the stroke uses the Mask brush (new `input.mask`) | draws the mask shape picked in the Mask section |
| Mask + Invert | erases the mask | unmask shape (as Alt) |
| Hide | the picked gesture tool (as Ctrl+Shift), group isolate on a tap | the same |
| Hide + Invert | the gesture flipped (as Alt) | the same |

Code changes:
- `Viewport_Input` gains `mask: bool`.
- `mask_shape.odin` starts on `invert || mask` and unmasks on `alt`. Mask with Invert sets `alt`.
- `brush_at` uses `.Mask` when `input.mask`, as it uses `.Smooth` for `input.smooth`.
- Hide sets `smooth` and `invert`, and `alt` when Invert is also on.
- `drag_decide` treats an active Mask or Hide as it treats Ctrl: empty space and the safe zone stay with the tool. That check comes after `finger_model == .Orbit`, so fingers set to orbit still orbit.

### Layout
- A 2×2 grid at the bottom left (`begin_anchored .Start, .End`, edge E) on a panel background: Smooth, Invert, Mask, Hide.
- Each button is a 48 pt target with a Lucide icon and a caption: waves, diff (±), contrast, eye-off.
- New kit widget `ui.modifier_button(ctx, name, glyph, state: Modifier_Look, keys) -> clicked`.
  - `.Off`, `.Lit` (held or keyboard): accent outline and soft fill.
  - `.Latched`: solid accent fill.
- The tooltip names the keyboard modifier ("Shift", "Ctrl", "Ctrl+Shift").
- The grid sits under the size and strength sliders and does not move them, so the positions in touch_check stay the same.
- Settings > Interface gains "Modifier buttons" (on by default), one row in `SETTINGS`. With it off, nothing is drawn and no finger is claimed.

### Coloured cursor (P15)
The brush ring takes the effective mode's colour (keyboard or rail):
| Mode | Ring colour |
|---|---|
| Smooth | `t.accent` |
| Invert | `t.danger` |
| Mask | `t.warning` |
| Plain | as today |

Hide shows no ring change, because its gesture draws its own shape.

## Ownership, threading, failure
- Main thread only. The rail rects are copied each frame, with no references kept.
- A finger the rail claims that never comes up (focus lost) is cleared with the touch's fingers on `WINDOW_FOCUS_LOST`/`DID_ENTER_BACKGROUND`.

## Tests
- **app unit:** `rail_release` covers tap, long hold, used during a stroke, cancel, latch then tap to unlatch, and the radio between modes. `rail_resolve` (the mapping table above) is a pure function of mods, keyboard and on-model state, checked against the table.
- **touch_check scenarios** (finger held via `fdown` on a rail button, pen stroke via `pdown/pmove/pup`):
  - `rail_hold_smooth_with_pen`: the stroke is a Smooth step, and nothing is latched afterwards.
  - `rail_tap_latches_invert`: a quick fdown/fup latches, so a later stroke is inverted.
  - `rail_mask_paints_mask`: the step is a Mask step.
  - `rail_mask_shape_from_empty_space`
  - `rail_hide_gesture`: hidden triangles > 0.
  - `rail_finger_survives_pen_down`
  - `rail_mouse_click_latches`
- New stats printed: `stroke_kind`, `stroke_invert`, `rail_latched`.
- check, smoke, wincheck, androidcheck; a screenshot of the rail in each state.

Size: about 400 lines including tests. It touches touch.odin routing (the rail claim) and `Viewport_Input`; no History or Scene_Command change.

## Changes from the sm-architect review (as built)
- **Claim:** `rail_claims` takes a finger only where the rail is the topmost root (`ui.root_at`, over the last frame's placements) and no menu, popover or list is open. A finger id already held is dropped first (a lift that never came). A fifth finger on a full rail is dropped, not handed to the touch.
- **Motion and lift:** a rail finger's FINGER_MOTION and FINGER_UP/CANCEL stop in `touch_event` before the touch's own handling, so a cancel never sets `d.cancel`. Focus lost and background call `rail_forget` unconditionally. A tap also needs travel within the slop.
- **Press snapshot:** `rail_press` runs in `kit_viewport_input` inside `if input.dragging`, before `touch_route` and `pointer_route`. At the left press it takes `rail_press_mods` (held beats latched, last held wins, Invert from either), marks the fingers held as used, and resolves that snapshot every frame until the release. Any of Shift, Ctrl or Alt held at the press leaves the rail out.
- **Mask shapes:** a new `Viewport_Input.mask_shape` starts them (keyboard Ctrl without Shift, or the rail's Mask); the rail's Invert alone draws no shape. `route_mute` and `viewport_mute` clear `mask`, `mask_shape` and `alt`.
- **Strokes:** `stroke_brush` (Mask > Smooth > held brush) decides the Paint refusal and the brush; `held_brush` keeps the alpha, the alpha outline and Drag rectangle to the held brush only. `Stroke.invert` is new, for the stats.
- **drag_decide:** only for the Brush tool, a Mask or Hide press keeps empty space for its shape; the edge band still orbits unless the mode came from a finger held (`Rail_Press.held`).
- **Gestures:** clip and mask shapes start at the first sample of the press (where a finger landed before FINGER_HOLD) and count as a drag only past the slop for fingers and the pen (CLIP_MIN_PX for the mouse). A Hide tap off a group shows everything; Hide + Invert on a group masks it.
- **Replay:** `Take_Frame.mask`, flag bit 3; STROKES_VERSION 3; flags above 7 are refused in versions 1 and 2.
- **Layout:** `Rail_Side {Off, Left, Right}` replaces the bool (settings key `modifier_rail`). On the left the sliders' track shortens (100 to 260 points) so they never meet the rail; the rail lifts above the dock where they would meet. On the right it sits above the object's status and the inspector's room shrinks to clear it. Off clears every latch and finger.
- **Ring colours** are literals, not theme tokens: blue {0.45, 0.7, 1} smooth, red {1, 0.45, 0.4} invert, violet {0.72, 0.55, 1} mask; Hide leaves the ring as it is.
- **Stats:** `stroke_kind`, `stroke_invert`, `rail_latched`, `masked`, and `layout_<name>` rectangles for the window-size scenarios.
