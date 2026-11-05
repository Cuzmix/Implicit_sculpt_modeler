---
name: bezier-curves-plan
description: Nomad-style Bézier curves + editable strokes/stamps, 13-PR series approved 2026-10-31; all 13 PRs merged (#453-#474) 2026-11-01, full gate green; awaits Bolt's tablet try
metadata:
  type: project
---

Bolt asked on 2026-10-31 18:58 for Nomad-style Bézier curves, with a plan and an HTML mock. Mock and plan: https://claude.ai/artifact/BnWpcs912G7Vtrcb6K122Y (source /mnt/project-files/notes/curves/curves-mock.html). Bolt approved it at 19:17 ("ok looks good proceed"). Self-merge each PR into odin-sculpt. The branch claude/project-thread-1lqqnm is restarted from odin-sculpt after each merge. Design notes are in /mnt/project-files/notes/curves/prN-design.md, each reviewed by the architect.

Round 2 (Bolt, 19:12) took all four defaults: live until Bake; a drag draws freehand and taps place points; a baked tube is its own object; Pipe/Lathe/Loft make a new cage. Bolt also asked for curves in Model mode and for Nomad 2.9's hold-to-edit strokes and editable stamps.

The 13 PRs:
1. geom bezier
2. hold-to-edit strokes
3. editable stamps
4. curve object + CURV chunk
5. pen editing
6. Tube
7. Lathe
8. Along
9. Brush path
10. Model Pipe/Lathe quad cages (creased corners)
11. Spine/Extrude/Knife follow a curve + Edge loop to curve
12. Loft
13. Help/README/full gate

Merged: #453, #456, #459, #460, #462, #464 (Tube), #466 (Lathe), #468 (Along), #469 (Brush path), #470 (Pipe/Lathe cages), #471 (Spine/Extrude/Knife follow a curve, Loop to curve), #473 (Loft cage), #474 (Help glossary, full gate: 1321 tests, 788 touch scenarios). Build details: [[bezier-curves-build]].

Reported to Bolt 2026-11-01; open items:
- Bake deletes the curve (Undo brings it back) instead of hiding it.
- Along's Object part is deferred.
- A lathe profile that crosses its axis is not handled.
- Nothing has been tested on a tablet.

Related: [[best-of-all-worlds]], [[gate-per-pr]].
