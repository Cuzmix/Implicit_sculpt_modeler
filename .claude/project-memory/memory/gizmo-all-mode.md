---
name: gizmo-all-mode
description: 2026-10-29 combined Move+Turn+Scale gizmo ("All" mode, gizmo.Mode.All) PR #310: layout, picking rules, touch points
metadata:
  type: project
  modified: 2026-10-29T19:38:08.121Z
---

Bolt 2026-10-29 19:25 asked for a gizmo mode combining move, rotate and scale (as ZBrush, Nomad, Blender). Built in thread "Add combined move-rotate-scale gizmo" as PR #310, merged into odin-sculpt 2026-10-29 ~20:20 after a full gate (605 touch scenarios).

- `gizmo.Mode.All` (4th, appended so stored `gizmo_mode` names stay valid; W cycles Move, Turn, Scale, All). Layout in arm units: plane squares 0.28-0.48, white scale knobs at KNOB_AT 0.62, axis rings ALL_RING 0.85, view ring x1.25, arms to ALL_ARM 1.35 with arrowheads. Knobs scale uniformly (similarity rule; non-uniform scale still out).
- Picking: nearest wins, later-considered wins ties: rings, squares, arms, knobs. So arms beat rings at crossings, knobs beat their arm; knob grows by the finger's grow like the centre square.
- touch_check: GIZMO_CHIPS now has 6 chips (move 670, turn 736, scale 799, all 856, snap 911, pivot 973, y 766); GIZMO_ALL_* points; scenario gizmo_all_moves_turns_and_scales.
- Screenshot: /mnt/project-files/notes/phase6/screens/gizmo-all.png. Not tried on Windows/tablet. Related: [[sculpt-depth-phase6]].
