---
name: sculpt-layers
description: Sculpt layers (PR #38, 2026-10-25): REC recording, strength sliders, undo and file design, limits, bench
metadata:
  type: project
---
Sculpt layers were merged into odin-sculpt as PR #38 on 2026-10-25. They are item 2 of Bolt's production list.

How they work:
- They live in Tools > Layers.
- **New layer** starts the layer recording (REC is lit). While a layer records, strokes, Smooth all and Clip also go into it.
- Each layer has a strength slider from -1 to 2 and an eye to hide it. There are also Delete (takes the work off) and Bake (keeps the work, drops the layer).
- The shown surface is the base plus the sum of each layer's strength times its displacement. Displacement is stored per node, only for nodes the layer moved.
- Every change is an undo step, and a slider drag is a single step.
- Layers belong to one subdivision level and are saved per level in .sculpt files.
- They are refused in HD and under dyntopo. Turning dyntopo on, or rebuilding the mesh, bakes them.
- **Recording is a mode, not history:** undoing a delete brings the layer back with REC off.

Performance at 10M:
- A Draw frame while recording is about the same as without (1.27 vs 1.30 ms).
- The stroke end costs 2.5 ms.
- A slider change is about 8 ms including normals.

Also in this PR, a fix to undo byte accounting (step_move re-counts the bytes).

Watch out: PR #36's merge left conflict markers in the README flags line. They are fixed now. Check `git diff --name-only --diff-filter=U` after every merge, not `tail`.

Not tried on Windows yet. Related: [[sculpt-paint-groups]].
