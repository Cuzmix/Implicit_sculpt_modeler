---
name: open-decisions-2026-11-06
description: "What waits on Bolt as of 2026-11-06 (device runs, blocked items, unanswered picks, promised work), from a full read of the exported project chat and 91 threads"
metadata:
  type: project
  modified: 2026-11-06T18:00:00.000Z
---

On 2026-11-06 Bolt exported the cloud project's chat and all 91 threads, and a local session read them in full. What they leave open:

**Device runs (run 2026-11-06).** About 15 merged series had never run on the iPad, the OnePlus Pad, Windows or real Wi-Fi; on 2026-11-06 Bolt ran the backlog on his iPad Air M2, OnePlus Pad and RTX 3060 Ti PC and said everything looks good, with no per-feature numbers given. What it covered (all run): Send to computer/tablet, Pencil Pro and pen lean, Hover preview and its heat pause, Live stack handles and copies' GPU cost, texture paint, physics, UV, curves, motion, the Android edge strips, Photos import, voxel stage 9, Metal ray tracing and Metal culling, GPU culling numbers on Mali, the detail skin on tablets, the web build on a real browser GPU. Numbers for any one of them still need a new ask. See [[app-gaps-2026-11-06]].

**Blocked on Bolt.** Dense remesh: build #735 for the iPad, remesh to 15M twice, send `sculpt-log.txt`; the per-vertex memory estimates are corrected from that log ([[dense-remesh-memory-plan]]).

**Unanswered picks.** Which of the 20 whole-app gaps to build next (Android save to a picked file was done as #757); G6 Metal internals (recommended skip); Manifold for exact mesh booleans (offered 2026-10-31); compact 32 pt mouse rows as a setting; a faintly visible resize corner on tablets; raising the panel-shadow slider's top end; Flow vs Fast in Quad Remesh (Bolt testing both); fitting the matcaps 1:1 to his iPad ZBrush screenshots (needs the shots); whether to revert Pelz A1/A2 (#702, #703; now used by the render materials plan, so likely keep); C7 one name for mini view / second view / view windows; the app icon pick for the store builds.

**Promised or designed, not built.** Matcap A/B two-picture cavity and Transition slider (a short design was promised); shader graph; docking DK3a (patch parked) and DK3b; physics GPU kernels; Remesh sharp edges (patch parked) and the remesh_check fixtures; skin over branching curves; drag and drop from other apps on tablets; Live strokes (design only) and Onion skin (not picked); the non-brush toolbar icons and Trim dynamic's icon; the UI review target of 8 (at 6.91); GPU sculpting's kernel-compile hitch, cones kernel and the brushes still on the CPU.

**Leftovers that break today's rules.** Early PRs (#42, #121, #153, #275, #435) added reading of older files and settings; #504 removed most of it. Any that remains (for example ignored `chrome classic` settings lines from #275) goes when found.

**How to apply:** when Bolt asks "what's next" or "what needs my attention", start from this list and check each item against the code and git log first (the code wins). Related: [[render-materials-plan]], [[self-merge]].
