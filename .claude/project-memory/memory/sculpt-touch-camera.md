---
name: sculpt-touch-camera
description: PR #49 (merged 2026-10-25): ZBrush-style touch/pen/mouse routing, 360° orbit, Settings panel, plain-words stats, touch_check.py, skills sm-touch-testing and sm-figma-ui
metadata:
  type: project
  modified: 2026-10-25T19:02:21.567Z
---

PR #49 merged into odin-sculpt 2026-10-25 (thread "Fix tablet touch and camera controls"). Report doc: https://claude.ai/artifact/3Ry1w1n4S5aQAcRJVRE6YD ; screenshots /mnt/project-files/notes/touch/.

- Bolt first said copy Nomad's touch controls, then "no instead copy zbrush orbit and touch controls": ZBrush for iPad is the model (one finger/pen on model sculpts, on empty space orbits; 2 fingers pan/pinch toward fingers/twist roll; 3 fingers size+strength; 2/3-finger tap undo/redo; mouse right drag orbit, Alt/Shift+right pan, Ctrl+right zoom, Shift snaps).
- Root causes fixed: SDL touch-to-mouse warp counted as a drag (hint off now, also pen/mouse-to-touch); hit areas outside panel rects; inspector scroll only from presses no control took.
- Code: src/app/touch.odin (one owner per touch), src/app/navigate.odin (drag owner, Nav_Prefs), src/ui gesture arena (claim_drag, scroll_update, scroll_take), src/ui/fingers.odin, camera Free/Turntable basis orbit with roll; scene v7, strokes v2.
- Settings panel (Menu > Settings): Interface, Camera, Touch, Performance; saved on close/background/exit; `--settings-file`, `--orbit-style`, `--finger-orbits` (Finger sculpts menu item removed).
- Tests: `python scripts/touch_check.py` 36 scenarios (desktop simulation, scripted SDL events). Nothing run on a real tablet/pen; tuning values (10 pt slop, 90 ms hold, 10° twist) are guesses.
- Figma connector works (samflux, starter plan, View seat); Settings/Stats panels not yet in the "Sculpt UI" file.

- 2026-10-27 (PR #153 merged): Bolt asked for "regular orbiting" by default, trackball only as a Settings option: default orbit is now Turntable (Settings > Camera lists Turntable, Trackball, X axis, Z axis; Trackball is enum/script value `free`). Settings file v2 moves a v1 file's `orbit_style Free` to Turntable once. Twist-to-roll works only with Trackball.

- 2026-10-27 PR #175 merged: long press on controls 0.45 → 0.3 s, Settings > Touch > Hold delay (0.15-1.5 s, `hold_delay`); two/three-finger hold-undo keeps its own 0.45 s (HOLD_LONG). PR #178 merged: Settings > Camera > Turn about list (Last stroke default, Pointer, Selected objects, Whole scene, View centre), air pivot (Pointer only), Show the pivot dot, Wheel zooms toward the pointer (off). Bolt said one thread for both was fine ("do whats best").
- 2026-10-27 PR #204 merged: Hold delay 0.1-1.5 s, 0.25 s default (Bolt wanted lower); Draw size/Strength/Focal shift on the brush bar drag at once (no hold). PR #208 merged: Bolt said Turntable felt "z axis locked" and wanted Nomad's turntable for touch. Nomad's manual says its turntable is 2-DOF and twist only rolls in Trackball, so read it as the roll: Settings > Camera > "Twist two fingers to roll the turntable" (`turntable_roll`, off by default); a rolled turntable reads drags along the rolled screen; roll holds level within 4 degrees; twist rolls about the fingers. If Bolt meant something else (e.g. a tilted turntable axis), revisit.
- 2026-10-29 PR #316 merged: Bolt asked for a finger tap to switch mesh, with a setting. A quick finger tap on a non-selected object selects it with no dab (tap on the selected one still dabs; strokes unchanged; works in finger-orbit mode too). Settings > Touch > Tap another object to switch to it (`tap_switches`, default on). Scenario tap_another_object_switches_to_it. Untested on a tablet.
- 2026-10-31 PR #457 merged: Bolt said pinch zoom should pivot between the fingers. It already zoomed toward the midpoint but on the target's plane (behind the surface), so the surface drifted. Now the target is rebased (camera.orbit_rebase) to the depth of the surface hit under the midpoint before pinch zoom/twist roll and wheel-toward zoom; no hit keeps the plane. Untested on a tablet. Six scenarios (colour_well_opens_the_picker, slider_drag_sideways, preset_*, focus_moves_undo_and_search_to_the_top_bar) failed on odin-sculpt already that day.
**Why:** Bolt reported unintended orbit and first-touch scroll failures on the OnePlus tablet.
**How to apply:** for input work load sm-touch-testing and run touch_check.py; ask Bolt for the device checklist results (skill section 6) before tuning further.
