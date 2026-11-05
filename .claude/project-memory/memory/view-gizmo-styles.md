---
name: view-gizmo-styles
description: 2026-11-04 view gizmo (was navigation head) got 3 styles Axes/Cube/Model+own model, PR #616 merged; where the code is and the touch gotchas
metadata:
  type: project
  modified: 2026-11-04T10:40:20.282Z
---

Bolt 2026-11-04 asked for Blender XYZ + Nomad cube + ZBrush own-model gizmo ("best of all worlds"). Mock https://claude.ai/artifact/51R39wBi27SSnTNUNnj77L (source /mnt/project-files/notes/view-gizmo/mock.html); Bolt said "looks good". Merged as PR #616 into odin-sculpt.

- Code: src/app/view_gizmo.odin (styles, picks, view_gizmo_controls shared by Settings > Camera > VIEW GIZMO and the Bar_Pop_Kind.View_Gizmo popover on hold/right-click, own model take/save/load `view_model.bin` beside settings), src/app/nav_head.odin (head mesh + Model render), camera.orbit_look_from, ui.map_since (affine text onto cube faces).
- Settings: view_gizmo axes|cube|model (default axes), view_gizmo_model head|own, view_gizmo_axes. Exit stat view_gizmo=.
- Axes/Cube: interface-drawn, no GPU pass; Model: cached picture redrawn only on view turns (Bolt asked about compute; answered).
- Touch gotchas: UI["nav_head"] fallback coords are not the real centre; use "@navigation head/navigation head~DX,DY". Head scenarios now pass `--script=set view_gizmo model`. --ui-events before frame ~10 can miss the popover.
- Pre-existing app test failures on base (not ours): sections_show_at_most_five_controls, show_every_option_unfolds_the_sections, textured_export_carries_the_maps.
- Not tried on a tablet. Related: [[rail-groups-lights-plan]], [[panels-v2-plan]].
