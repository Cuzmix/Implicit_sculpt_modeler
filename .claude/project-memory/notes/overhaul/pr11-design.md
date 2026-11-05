# Round 3, PR 11: Motion II (design, 30 Oct)

Motion I (#337) gave the kit motion classes, the levels Full/Reduced/Off and Settings >
Interface > Motion. Motion II adds the moves round 2 listed, each with its own Motion_Kind
row so it can be turned off by itself. Split in three PRs so each stays reviewable.

Rule kept from the overhaul: nothing a stroke, the camera under a finger or a drag follows
ever animates. Reduced turns moves into fades (or drops them when there is nothing to fade);
Off makes every duration 0.

## 11a. Camera ease (Motion_Kind.Camera)
- `camera_ease.odin`: `Camera_Ease {from, to: camera.Orbit, start: f64, on: bool, eases, cuts}`
  in App. `camera_ease_from(app, before)` is called after a jump: when the view changed and
  easing is allowed, the camera goes back to `before` and eases to where the jump put it over
  CAMERA_EASE_TIME (0.32 s, Out_Cubic) on the interface clock (ui_dt aware).
- Eased: Frame all, Focus selected, Reset camera, the axis views (View_Axis: nav head taps,
  numpad, Camera section), Previous/Next view, a double tap's frame. Not eased: Shift's square
  snap mid-drag (the hand drives it), the mini view swap, scene loads, start-up framing,
  replays, the time-lapse and the turntable.
- Interpolation: target and shift linear, distance geometric (so zooming far reads even),
  yaw, pitch and roll each along the shorter way round; fov, near, far, ortho take the
  destination's at once. The last frame sets the destination exactly (bit for bit).
- Cut short: navigation input on the view (touch pan/zoom/roll/orbit, a drag, the wheel)
  stops it where it is, so the hand takes over from what it sees; a press that sculpts jumps
  to the destination first, so the stroke lands on the view asked for. Counted (`cuts`).
- Allowed only when motion moves (Full and the Camera kind on), no script or macro runs, no
  replay records or plays, the time-lapse and turntable are idle, and the run is interactive;
  `--camera-ease` allows it in a scripted run, to test it.
- Camera history keeps no view while easing; the ease ends on the view shown, so Previous
  and Next keep their place.
- Stats: `camera_easing= camera_eases= camera_ease_cuts=`.

## 11b. Unfolding chrome (Pie, Hand_Switch, Home, Panes, Arrange)
- The brush pie and the dial's quick pies unfold: slices scale from the centre with a 15 ms
  stagger clockwise (Reduced: fade only).
- Left-handed switch: the bars and the stack slide across to their new sides over 0.28 s
  (a transform from the old rects; Reduced: cross-fade).
- Home grows into the scene: the picked scene's card scales to the window as Home fades.
- Pane slide: a view grid preset change slides each pane from its old rect to its new one.
- Arrange outline: the outlines fade in, with a dash that marches slowly while Arrange is on
  (Off: still dashes).

## 11c. Feedback flashes (Undo_Flash, Mask_Wipe, Selection, Save_Tick)
- Undo flash: the screen box of what an undo or redo changed (the dirty range's bounds)
  glows once, 0.35 s, in the accent at 25%.
- Mask wipe: a mask command (Invert, Clear, Grow, Shrink, Sharpen, Blur) sweeps a soft edge
  across the object's screen box over 0.3 s instead of the mask popping.
- Selection outline: a newly selected object's outline draws in from 0 to full width.
- Save tick: after a save, the file block's status shows a tick that draws on, then fades.

## Verification (each PR)
- Unit: ease maths (shorter-way angles, exact end, geometric distance, cut keeps place);
  motion_off names round-trip with the new kinds.
- Touch: one scenario per motion with its flag, reading the new stats mid-motion and after.
- Parity 19/19 (every motion is off in scripted runs unless its flag asks).
