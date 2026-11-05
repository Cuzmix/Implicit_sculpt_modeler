# Touch step 3: double-tap pivot, two-down-lift-one orbit, hold to repeat undo: design

Base: odin-sculpt 9f59b17 (PR #58). Patterns P7, P8, P17 (09_Interaction_Patterns.md); findings #9, #42, A-24; Nomad N012, N003.
Problems:
- People get lost orbiting about the wrong point (P7).
- When the model fills the view, one finger cannot orbit except from the edge band (P8).
- Undoing many steps takes many two-finger taps (P17).

## 1. Double tap (fingers only)
- **What counts.** A finger tap is a press and release that stays within the slop, with the release less than FINGER_TAP (0.25 s) after the press.
  - It must be routed to Orbit (empty space, the edge band, or Finger_Model.Orbit), or be a Brush stroke still pending.
  - A double tap is a second such tap whose press comes within DOUBLE_TAP_GAP (0.30 s, as Android's) of the first one's release, and within DOUBLE_TAP_REACH (48 pt) of it.
  - The pen and the mouse never double-tap: the pen stipples, and the desktop has F and the Pointer pivot.
- **On the model: pin the pivot.**
  - The surface point under the second tap becomes the pivot every orbit turns about, whatever Settings > Camera > Turn about says.
  - It is kept in its object's own space, like the stroke pivot.
  - Nothing moves: the view does not jump. The pivot dot flashes there for 0.8 s.
  - The pin ends when the next stroke ends (in Stroke mode that stroke's middle takes over), on Focus selected, on Frame all, or on another double tap.
  - New Pivot_Source `.Tapped`; `Stroke_Pivot` gains `pin_object`, `pin_at` and `pinned`.
- **On empty space: frame.** Focus selected, or Frame all when nothing is selected, as Nomad's "double tap on background".
- **The dab problem.**
  - Today one finger tap on the model lays a dab, so two taps would lay two dabs before the double tap is seen.
  - With double tap on, a Brush finger press that has not passed the slop stays pending for FINGER_TAP (0.25 s) instead of FINGER_HOLD (90 ms).
  - A press that moves past the slop still starts at once, replaying every sample. So only a still press-and-hold starts 160 ms later.
  - A tap's samples (Press..Release) are kept as the *waiting dab*, together with that frame's stroke modifiers (smooth, invert, mask and alt, which the rail and keys may change before it plays). Then:
    - if no second tap comes within DOUBLE_TAP_GAP, the dab plays then, as a whole press and release in one frame (sculpt_frame already handles Press..Release within a frame);
    - if a second tap comes, both dabs are dropped and the double tap acts;
    - if the second press turns into a stroke, or a press lands elsewhere, the waiting dab is prepended to that press's samples (or played that frame), so no dab is lost.
  - A single tap's dab therefore lands about 0.3 s after the lift.
- **Setting.** Settings > Touch and pen > "Double tap sets the pivot" (`double_tap`, default on). Off restores today's behaviour exactly.

## 2. Two fingers down, lift one: orbit (P8)
- Two fingers on the viewport (most == 2, never three) and one lifts. The finger left down orbits once it moves past the slop from where it was when the other lifted.
- It orbits about orbit_pivot at that point (the pin, the stroke middle, and so on), with the pivot dot showing.
- It ends when that finger lifts. Pan, zoom and roll still need both fingers down, as today.
- New `Viewport_Input.touch_orbit` (a delta), applied in camera_apply_input with `orbit_pivot`.
- `orbit_pivot` loses its file-private mark so touch.odin can call it.
- Setting: Touch and pen > "Lift one of two fingers to turn" (`lift_one_orbit`, default on).
- A two-finger tap is unaffected. A tap moves under 24 pt within 0.25 s, so at most the last few points of a lift turn the view; that counts as no motion until the slop is passed.

## 3. Hold two or three fingers to repeat undo or redo (P17)
- Two (or three) fingers held still on the viewport (every finger down, travel under the slop) for `theme.long_press` (0.45 s) undo (or redo) once. They then repeat every 0.12 s until a finger moves past the slop or lifts.
- Once it repeats, the touch is a repeat for good: no pan, zoom, roll or three-finger size or strength.
- From `long_ring` (0.15 s), a ring around the fingers' middle fills toward the first undo, as the kit's long press does. While repeating, a label "Undo 3" (or "Redo 3") counts beside it.
- Never while the pen is near or down, or for a palm touch, since Nomad's palm bug was repeated undo.
- Under the existing "Two fingers tap to undo, three to redo" switch, which is renamed to add "hold to repeat".

## Clock and stats
- Every time above reads `input_clock(app)`, so scenarios count frames: gap 18 frames, tap 15, long 27, repeat 7.2 frames.
- Stats:
  - `pivot_source` gains `tapped`;
  - new `pinned=0/1`;
  - `touch_repeats=N` (undo or redo steps by holding);
  - `framed=N` (double taps on empty space).

## Tests
- `src/app` unit test: a double-tap classifier as a pure proc, taking two taps' times and positions and returning whether they make a double tap, at the gap and reach edges.
- touch_check scenarios:
  - double_tap_model_pins_pivot: dabs 0, undo 0, pinned 1; a following orbit's pivot_source is tapped.
  - single_finger_tap_still_dabs_late: one dab, undo 1.
  - tap_then_stroke_keeps_the_dab: undo 2.
  - double_tap_empty_frames: a pinch first, then the camera distance is back at 3.5.
  - double_tap_off_lays_two_dabs.
  - pin_cleared_by_next_stroke.
  - lift_one_finger_orbits: yaw changes, no dabs.
  - lift_one_off_does_nothing.
  - pinch_then_lift_without_moving_turns_nothing.
  - hold_two_fingers_repeats_undo: 4 strokes, held 45 frames, which is 3 undos.
  - hold_three_fingers_repeats_redo.
  - hold_with_pen_near_does_nothing.
  - moving_fingers_never_repeat: a slow pinch.
- Gate: python3 scripts/gate.py; screenshots of the ring mid-hold and of the pin flash.

## Size
About 400 lines with tests. Touches navigate.odin (taps, the waiting dab), touch.odin (lift-one, repeat), overlay (dot, ring), settings rows, kit_settings rows and README. No History, Scene_Command or GPU change.

## Changes from the sm-architect review (as built in step 3a)
- Split: 3a ships double tap only for taps that turn the view (empty space, or the model when Finger_Model is Orbit); a double tap on the model while one finger sculpts (the waiting dab) is step 3b, with its own design and review. The review's points for it are kept for 3b: play the dab in its own `sculpt_frame` with camera and brush swapped as replay does, resolve it at one point after events, never prepend it before a Press, exclude presses that go to mask shapes or clip.
- Fixed now: a finger tap's stroke began on the release frame, where the rail and keys read as up, so a tap with Invert, Smooth or Mask latched laid a plain dab. `Drag.mods` keeps the press's modifiers (scenario `finger_tap_with_invert_latched_dabs_inverted` failed before).
- No double tap in the edge band (checked at the press); the Move tool's first tap deselects, so the selection before the first tap is put back before framing.
- Pin: `Stroke_Pivot.pinned` and `flash` reuse `object` and `at`; checked first in `orbit_pivot`; cleared by `stroke_finish` (a stroke that touched), Focus, Frame all, Reset camera, opening a scene, and its object going.
- Lift one: arms only if the pair stayed under the slop (`fingers.travel`) and no hold fired, never with a palm or the pen near (and stops when the pen comes); the pivot is decided once and drawn from `Touch.lift`; once it turned the view a two-finger tap does not fire; a finger landing resets it; `touch_orbit` is applied before camera_apply_input's early return.
- Hold: timed from the last finger landing; off for the touch on travel past the slop, a spread change over 3% or a twist over 3 degrees; pen checked every frame; one step a frame; its own setting `hold_history`; fingers must land within 0.15 s of the first. Label counts steps taken.
- Stats: `pinned`, `framed`, `touch_repeats`. 18 new scenarios (95 in all).

## Step 3b as built (double tap on the model while sculpting)
- Dab_Wait (navigate.odin): an eligible finger brush press (double taps on; no Shift, Ctrl or Alt; no rail Mask or Hide; no replay) waits FINGER_TAP to begin. As a tap, its samples, modifiers, camera and brush are kept. dab_wait_event (each SDL event, before touch_event) marks play on a key, Space, the wheel, the mouse, the pen, focus loss, quit, or a finger landing elsewhere. A finger within reach and gap marks `second`.
- dab_wait_resolve runs after events and before kit_frame. It plays the dab in its own sculpt_frame, with the tap's camera and brush swapped in and replay_record inside, when the gap ran out, play was marked, or a `second` finger did not become a waiting brush press within a frame (a palm, a panel). The sm-reviewer blocker: it was stuck. The scenario tap_then_palm_nearby_still_dabs failed without the fix.
- A second press that becomes a stroke stays pending one frame so the dab plays first (pointer_route keeps a pending press past its lift).
- Scenarios: 7 new, 101 in all.

## Start-location taps (P2), as built after 3b
- With Mask on (rail Mask, or Ctrl off the model with the mouse/pen/finger), a press on the Brush tool is `Drag.mask_tap`: it waits as pending (any pointer) up to FINGER_TAP or the slop; as a tap it runs `mask_tap_act` instead of painting a dot: off the model Invert, on the selected object Blur where the mask under it (`sculpt.sculptor_mask_at`, the hit triangle's corner mean) is at least half, else Sharpen. `mask_command(..., toast = true)` reports with Undo.
- Ctrl on the model is not a mask tap (Ctrl inverts the brush there). Shift excludes it (clip). Mask shapes from empty space still start once past the slop.
- Clear on "drag off the model" (Nomad) is left out: our drag off the model draws a shape; Alt+M and the Mask section clear.
- Stats `mask_mean`, `last_op`, `toast_undo`; 6 scenarios.
