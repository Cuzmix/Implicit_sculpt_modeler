---
name: pen-keeps-to-active-object
description: 2026-11-05 thread "Stop pen from switching active mesh": pen/mouse strokes keep to the selected object by default; Settings > Pen "The pen picks the object it strokes" (stroke_picks, off); Alt click switches
metadata:
  type: project
  modified: 2026-11-05T15:00:07.461Z
---

Bolt 2026-11-05: with two meshes overlapping, the pen picked the front one instead of sculpting the active one underneath. Wants the pen to act like a pen (sculpt the active object), switching only by finger tap or Alt+click; pen picking left as an opt-in setting.

Built and merged as #694 (2026-11-05):
- Nav_Prefs.stroke_switches (default on) renamed to `stroke_picks`, default OFF (settings key `stroke_picks`; old line passed over, no migration). Label "The pen picks the object it strokes" in Settings > Pen > Other objects. Covers pen, mouse and finger strokes (`stroke_only` in sculpt_tool.odin).
- With it off: pen/mouse press on another object with the selected not behind it counts as empty space (orbits) in drag_decide; brush ring raycasts the selected only (cursor_update); Ctrl mask taps keep to the selected for pen/mouse.
- Alt click / pen Alt tap (Orbit owner, travel <= slop, no Ctrl/Shift, left button) switches objects: Drag.alt_click, `switch_target`, exit stat `alt_switches`. Ctrl+Alt drag mask (#677) untouched.
- Finger tap switching (tap_switches) unchanged.

Related: [[gizmo-pivot-input-plan]], [[pen-area-gestures]].
