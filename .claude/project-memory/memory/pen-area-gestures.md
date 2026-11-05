---
name: pen-area-gestures
description: 2026-10-29 thread "Add pen roll twist and hover-aware gestures": plan for roll/double-tap/squeeze doing different things by screen area; Nomad twist
metadata:
  type: project
  modified: 2026-10-29T19:26:51.208Z
---

Bolt 2026-10-29 19:20: wants Nomad's "hover over the mesh and barrel-roll twists it about the point", plus per-area behaviours for roll, double-tap and squeeze (over mesh vs empty space; "on the taskbar a barrel does the swipe"), "explore and plan".

Plan doc (Claude Doc): https://claude.ai/artifact/3hN2875WbW9YgPsti6Pt7U — 5 PRs: 1 view twist on hover roll (model: about hit point; empty: about tip) + model/empty settings; 2 roll while Move/Grab/Snake hook/Elastic stroke twists the held part (what Nomad actually ships: roll during Move/Drag stroke); 3 interface areas for roll (shelf swipes pages, lists scroll, choices step, Undo/Redo scrubs History, nav head spins, colour wheel hue, timeline); 4 double-tap/squeeze per area; 5 pen side/second buttons per area (for Android, no roll there) + Help.

Defaults chosen: empty-space roll = twist too; pen twist ignores the turntable roll lock; empty-space squeeze = a new built-in view pie; empty double-tap = Frame; travel reset 40 pt before engage; "Pen roll" alpha brush wins over view twist.

Related: [[pencil-pro-plan]], [[best-of-all-worlds]], [[gate-per-pr]].

Progress: PR1 #311 merged 2026-10-29 ~20:00 (pen_roll.odin: Pen_Area, Roll_Action, Nav_Prefs.pen_roll, slots Pen_Double_Tap_Empty/Pen_Squeeze_Empty, Settings > Pen > Where the pen points; pencil gestures named in tooltips only on iOS via PENCIL_GESTURES). Branch claude/project-thread-67i3yo is reused per PR (restart from odin-sculpt after each merge).
PR2 #317 merged (sculpt.Grab_Twist in grab.odin: per-vertex dominant image+weight; app grab_twist_angle; pen_grab_twist). macro_records_and_replays fails in the container on odin-sculpt too (pre-existing).
PR3 #322 merged (ui.area_roll/roll_steps/roll_hint; shelf pages, Undo scrubs, nav head spins, Disc hue, choices step). PR4 #325 merged (pen_zone per place, Pen_As_Empty pseudo-command, double-tap/squeeze slots per place). Gotcha: pen_zone must use the stack top's `.root` (as ui interact does), and the shelf passes its own root id because it is laid out after its container ends; nav head records inside its begin/end.
PR5 #332 merged 2026-10-29 ~21:35 (Pen_Button_Empty, Pen_Button_2_<place>, pencil_slot_here resolves Pen_As_Empty; pen_input groups one input's slots for gesture_notes). Full gate green (631/631 touch). Series done; awaits Bolt's iPad/tablet try: /mnt/project-files/notes/pen-areas/try-it.md. Settings file keeps wireframe across runs: order Steps so the expected-off run comes first.

2026-11-03 thread "Support every Apple Pencil Pro feature": audit found everything built; only gap built = Pen lean alpha mode (azimuth) #517 merged. Audit table + iPad steps /mnt/project-files/notes/pen-areas/pencil-pro-audit.md. Remaining unused: UIKit estimated-force refinement (judged not worth it).
