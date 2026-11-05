---
name: ui-zbrush-gaplist
description: ZBrush-for-iPad gap list 15-PR build order and what each merged PR added (coords, versions, names)
metadata:
  type: project
  modified: 2026-10-27T18:14:15.241Z
---

Bolt asked for 1:1 subtools panel + gestures + "all the missing panels and features". Gap list + order: https://claude.ai/artifact/GMspYkj46rpUZzLjb1sf61. Order: 1 Objects card, 2 card actions, 3 gestures+focal, 4 wheel+pen, 5 right bar, 6 left bar, 7 masking, 8 visibility+groups, 9 layers, 10 brush pack, 11 lights, 12 home+top bar, 13 files, 14 geometry/deform + surface noise, 15 parked designs (Spotlight first).
- 1-11 merged #121-#160 (Objects card v11, V1-V8 v12, focal/One_Tap/wheel/pen, floor grid, symmetry, brush channel, masking/hide/layers/brush packs, light palette). touch_check UI y: brushes 143, colour 335, channel 383, focal 432, size 480, strength 528, add 576, subtract 624, undo 673, redo 721.
- 12: #164 Save next/left-handed/History marker+cap; real 3D lights #167-#189 (scene v19-v21, see [[sculpt-lights-3d]]); #191 previews (v22), #194 Home screen (Home at top-bar far left; not in Menu), #196 thumbnail window.
- 13 Files: #197 STL, #199 transparent screenshots, #201 turntable (own Scene section), #202 3D print (Scene > 3D print, print_mm scene v23).
- Limits enforced by tests: a section shows at most 5 controls folded (rest under kit_more); Object pages at most 6 sections.
- 14a #203 deformation sliders (app/reshape.odin, sculpt Pose_Kind.Reshape, Polish/Relax Smooth_Mode, Repeat on others; no Adjust last yet).
- #205 14b mesh repair (2026-10-27): Object > Shape > "Modify topology" (Kit_Section.Mirror): Close holes, Delete hidden, Weld points, Check mesh, Fix mesh, Delete half; geom/repair.odin, Scene_Command.Repair. Check mesh runs at once (scripts fail on a statement that leaves the scene unchanged). Touch coords: Close holes (1377,393), Delete hidden (1377,447). Design notes/geometry/mesh-repair.md.
- NEXT: 14b follow-up ClayPolish/Unify/Position-Size/smart resymmetrize, 14c crease/dyn subdiv/edge+panel loops, 14d surface noise, then 15.
- Rebase lesson: after `git add -A` in a conflicted rebase, git grep for '<<<<<<<' first.
**Why:** Bolt asked for every missing panel and feature. **How to apply:** build in order, one PR merged before the next; see [[ui-zbrush-build]].
