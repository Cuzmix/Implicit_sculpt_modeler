# Phase 5 item 4: Camera history

Roadmap row: "Camera history (back/forward views)" (P22, Z110: ZBrush keeps a separate 14-step camera undo with no
default keys; Nomad restores the view with each undo). Recover a view without undoing work.

## Design
- `App.views: Camera_History` (camera_history.odin): up to 32 views (target, distance, yaw, pitch, roll; not the
  projection or field of view, which are modes) and which one is shown, like a browser's back and forward.
- A view counts once the camera has rested 0.4 s on the interface clock (`ctx.time`, so `--ui-dt` runs are exact)
  with no drag owning the viewport, no timeline playback and no stroke replay. Every way the camera moves (orbit, pan,
  zoom, pinch, wheel, Focus, Frame all, axis views, Reset, double tap) is covered without hooking each; a jump rests at
  once, so it is a view of its own.
- Previous view (Alt+Left) first keeps the current view if it is not the shown entry (so Next comes back to it), then
  shows the one before. Next view (Alt+Right) shows the one after, only while the camera is still on the shown
  entry. A new view after going back drops the ones ahead. Showing an entry sets the camera at once (the app has no
  camera animation) and does not count as a move.
- Cleared when a scene is opened or a new one made; not saved in the scene file (ZBrush does not either).
- Commands `.View_Back` "Previous view" / `.View_Forward` "Next view" in the View group: View menu > CAMERA, palette
  (words: camera undo, back), Help keys, and the gesture map's choices (no gesture by default: the free four-finger
  slots overlap system gestures on some tablets).
- Exit stats: `camera_views` (kept), `camera_view` (shown, from 1), `camera_steps` (back/forward taken).

## Tests
- app unit tests: rest then record; no record mid-drag or before the rest; back/forward walk; a new view drops the
  forward ones; back from an unrecorded view keeps it; the ring drops the oldest at 32; clear.
- touch_check: two orbits with rests then Alt+Left twice is back at the start (camera_still); Alt+Left then
  Alt+Right returns to the second orbit's view; View menu row.
