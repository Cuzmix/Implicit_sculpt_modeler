---
name: sculpt-brushes
description: Brushes, masking and symmetry added to the sculpt app (PR #8, 2026-10-24): design, keys, bench numbers, gotchas, what is left
metadata:
  type: project
  modified: 2026-10-24T14:19:47.058Z
---

Thread "Add sculpting brushes, masking and symmetry" (started as a brainstorm 2026-10-24; Bolt picked direction 1 and said "lets do all of it" for the brainstorm list). PR #8 self-merged into odin-sculpt (33f92e4). Perf background: [[sculpt-perf-work]], architecture: [[sculpt-decisions]].
- Brushes (keys 1-9): Draw, Smooth, Clay, Flatten, Inflate, Pinch, Crease, Grab, Mask. One loop per kind via `displace(d, i, $K)` in src/sculpt/brush.odin; Grab in grab.odin (picks up at stroke start, moves by pointer offset on the camera-facing plane); mask in mask.odin.
- Mask: per-vertex u8 on Sculptor (nil until used), Stale.Paint = upload only. Undo saves masks per node. Carried across subdivision levels in levels_set_current/levels_subdivide. HD windows start unmasked, mask dropped on leave. GPU: low 4 bits of each i16 of the packed oct normal (geom.oct_encode_masked), no extra memory.
- Symmetry: Brush.symmetry bit_set, mirrors() gives up to 8 sign vectors.
- Bench (`build/bench --brushes`, VM, 4 threads): 10M frame Draw 1.67 ms, other brushes 1.8-1.9, Smooth 2.6, Grab move 0.44, Mask 0.55, X symmetry 3.2. Draw did not regress vs before.
- Gotcha: in Odin `for k in 0 ..< len(arr)` re-reads len each iteration; appending inside the loop ran it past the intended count (mirrors() bug, caught by a test).
- Mask Blur/Sharpen/Grow/Shrink with a Steps slider: PR #14 merged 2026-10-24. Perf trick worth reusing: a vertex whose triangle corners all equal it is a fixed point, so steps run only on uneven nodes + owners and recheck only nodes next to moved ones (10M: ~10 ms a press vs 85-107 ms a step full-pass). `build/bench --masks`.
- Brush alphas: PR #13 ([[sculpt-alphas]]).
- Not done yet: falloff curve editor, Grab with pen pressure, dab spacing control. Rest of the brainstorm list ("all of it"): DynaMesh-style voxel remesh (done, [[sculpt-remesh]]), dynamic topology, file import/export (OBJ/PLY, native save), tablet/UX (pen tilt, pressure curves, radial menu), AI ideas.
- Bolt's Windows gpubench (2026-10-24, RTX 3060 Ti) already showed viewport perf solved at 500k-10M.
