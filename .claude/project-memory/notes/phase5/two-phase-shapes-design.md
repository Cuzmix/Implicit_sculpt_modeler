# Phase 5 item 5: Two-phase shapes with ✓/✕ and auto-apply

Roadmap row: "Two-phase shapes with ✓/✕ and auto-apply setting", done when "Default off on touch" (P4, N004 Nomad's
green ✓ and Auto-validate; Z040 staged commit; C021 Enter). Shapes drawn with a finger are rough, and the view often
needs to change before the shape is applied; today every shape applies the moment the drag lets go.

## What exists
- `mask_shape.odin`: Ctrl (or rail Mask) + drag from empty space draws a mask rectangle or lasso; release calls
  `mask_shape_command(app, ndc_polygon, size, unmask)`.
- `clip.odin`: Ctrl+Shift + drag runs `app.gesture` (Hide rectangle, Hide lasso, Clip line, Slice line); release calls
  `hide_shape_command`, `clip_command(a, b, flip, size)` or `slice_request(a, b, size)`. A click shows all / isolates a
  group (unchanged by this item).
- Both are drawn by `draw_mask_shape` / `draw_clip` in overlay.odin, in viewport pixels.

## Design
- One pending shape, `App.pending: Pending_Shape` (new file `pending_shape.odin`): `kind` (None, Mask, Hide, Clip,
  Slice), `rectangle`, `flip` (unmask / hide inside / other side), `points` (viewport pixels: rectangle and line keep
  two, a lasso all), `size` (the viewport size it was drawn in), and an edit drag in progress (`grab`: none, move,
  point index).
- On release, the two gestures hand their shape to `shape_finish(app, kind, ...)`: it applies at once (today's path)
  when auto-apply holds for the pointer that drew it, else it becomes the pending shape (replacing any older one).
- Setting `shape_apply` (Settings > Touch): "With the mouse at once, with a finger or the pen after ✓" (default,
  Auto), "Always at once", "Always after ✓". Remembered as `shape_apply auto|now|confirm`; `--shape-apply=` for runs.
- While a shape is pending:
  - It is drawn as when dragged, with round handles (rectangle corners, line ends) and its fill.
  - A press on a handle drags that point; a press inside the shape (or within the slop of a line) moves it all.
    Any other press does what it always does (sculpt, turn the view, pinch), and the shape stays where it is on
    screen, so the view can be turned under it before applying, as in Nomad.
  - Buttons float under the shape's box (kept on screen, clear of the dock): ✓ Apply (accent), Flip (mask/unmask,
    keep/hide inside, the other side; not for Slice) and ✕. Enter applies, Escape (or Back) cancels.
  - Apply runs the same command the release ran, with the shape as it is now and the viewport size it is in now
    (points scaled if the window changed size). A new shape gesture replaces it; a tool change, a scene replace,
    an undo or a stroke do not (the stroke changes what Apply will cover, as a turn of the view does).
- The ✓ buttons are kit widgets placed with `ui.begin_at` at the shape's box (viewport pixels over `kit.scale` to
  points); input over them never reaches the viewport (kit hit testing as today).
- Exit stats: `shape_pending` (kind or none), `shape_points`.

## Tests
- app unit tests: `shape_apply_now` for each setting and pointer; moving and point-dragging a pending rectangle and
  line; scaling to a new viewport size.
- touch_check (desktop simulation): a finger mask rectangle stays pending (masked=0), ✓ masks (masked=1); ✕ leaves
  it; a mouse rectangle applies at once (unchanged); with `--shape-apply=confirm` a mouse lasso waits, Enter applies;
  pending rectangle moved by a drag inside it, then ✓ masks the moved place (mask_mean differs from unmoved);
  an orbit while pending keeps it; Flip unmasks; a Clip line pending, ✓ clips (export differs).
- README: Controls (masking and Ctrl+Shift gestures), Touch and pen, Settings > Touch, flags.

## After the sm-architect review (go with changes)
- A press on a pending shape's handle is decided in `drag_decide` as `Drag_Owner.Shape` (after the mouse-button owner
  and the palm check, before finger orbit and the safe zone), routed in `pointer_route` with `route_mute`; fingers and
  the pen move it past the slop; a gesture or cancel puts it back where it was at the press.
- Handles only (corners / line ends, plus a middle move handle), hit radius at least theme.target/2 points; a press
  inside the shape elsewhere sculpts or turns the view as always.
- Points in window coordinates (input.size is the window); a resize scales them uniformly by h'/h about the centre
  (the projection keeps fov_y).
- ✓, Flip, ✕, Enter and auto-apply set a request carried out in main.odin's Brush case; ✓ greyed with no selected
  object or a shape under gesture_min_px.
- Enter/Escape handled in kit_frame's key block (reserved chords): Enter only when nothing typed and nothing floats;
  Escape closes floats first, then the pending shape, then Settings/Help.
- Leaving the Brush tool cancels it. The pointer kind is taken at the press; rectangle-ness is snapshot at release.
- Setting `shape_apply` (Auto zero value) in Nav_Prefs, SETTINGS row, reset with Touch, `--shape-apply=`.
- State `App.shape_pending`; exit stats add `layout_shape_bar`.
