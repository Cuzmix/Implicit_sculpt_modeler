---
name: bezier-curves-build
description: Code facts learned building the Bézier curves series (curve objects, uses, tests that can't run headless)
metadata:
  type: project
---

Facts from building [[bezier-curves-plan]], 2026-10-31. These are not obvious from the code.

**Curve objects**
- `Object.curve: ^Curve_Part` (curve_object.odin). `Curve_Part` embeds `using look: Curve_Look{use, tube, lathe, along}`.
- In the file, the option blocks follow the points in a fixed order (tube, lathe, along). Each is read only where bytes remain; a block that is only partly there is damage.
- `curve_part_mesh` picks the geometry by use. `curve_rebuild` runs after each edit.
- The `Curve_Look` scene command carries the whole look, plus `look_drag` for sliders. `Bake_Curve` records the mesh added and the curve deleted as one chained step.
- `undo_steps=` counts history entries, so a Bake counts as 2.

**Tests**
- Headless tests segfault on GPU paths: tube, lathe and along builds, swap undo, and `scene_open` of meshes. Use snapshots in unit tests and touch scenarios for the rest.
- Sculpting itself works headless; `curve_brush_test` lays a stroke.
- Text typed into the palette in a touch scenario must not contain ':', which breaks `--ui-events`.

**Brush path (PR9)**
- `curve_brush_run` hands the curve to the hold-to-edit `Stroke_Edit` through a pointerless `stroke_path_start`.

**Along (PR8)**
- Along's Object part was deferred. It needs:
  - rebuild marks when the source object changes;
  - curve builds after `scene_replace`, so ids don't resolve against the old scene;
  - a scene serial for pastes across scenes.

**Model mode (PR11 #471, PR12 #473)**
- Follow: `model_follow_pick` (curve under pen) → `model_follow_path(cage, curve, middle, normal)`; Spine/Extrude grow via `model_spine_grow` (Extrude keeps `d.original` and restores it, `stale` rebuild). Knife tap on curve = `model_knife_curve`, skipped while a multi-cut tap is pending. `Model_Action.Loop_Curve` is last in the enum.
- Loft: `poly.loft_cage` (curve_loft.odin); `.Curve_Cage` Scene_Command carries `Curve_Cage_Kind` in `axis`; `curve_loft_sections` = selected curves (2+) else selected + shown Line curves of the same closedness, nearest first.
- Touch scenarios: `move` sets absolute position; script-made curves (`draw_curve`) count no undo step.
