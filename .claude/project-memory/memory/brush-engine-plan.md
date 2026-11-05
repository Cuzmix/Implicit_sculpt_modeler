---
name: brush-engine-plan
description: Brush engine + Grab research and 6-phase/20-PR plan (2026-10-29, thread "Plan a ZBrush-feel brush engine"): findings, defaults, where the plan lives, approval status
metadata:
  type: project
  modified: 2026-10-29T11:48:24.281Z
---

Bolt asked 2026-10-29 to plan improving the brush engine and Grab to feel like ZBrush, taking the best of ZBrush, Nomad, Blender and 3D-Coat ([[best-of-all-worlds]]). Research done with five parallel researchers (four apps + a second Blender source read, its own artifact section); artifact https://claude.ai/artifact/FWUTVoVJ4chsRmnuNUDMAz; plan file /mnt/project-files/notes/brush-engine/plan.md. Status: Bolt approved 2026-10-29 12:26 ("go all looks good", defaults as written); build thread requested from the coordinator.

Key findings (not derivable from the repo):
- SDL 3.4 drops coalesced pen/touch samples on Windows (no GetPointerPenInfoHistory), Android (no getHistorical*) and iOS (no coalescedTouches); our every-sample stroke path gets one sample a frame on tablets. Fix is app-side (Windows message hook, our SDLActivity subclass, an iOS gesture recogniser).
- ZBrush spaces dabs by pointer speed (blotchy fast strokes); Nomad/SculptGL 0.15 screen radius; Blender 10% of diameter (0.2 r) + strength/overlap compensation; ours 0.25 r uncompensated.
- Blender Elastic Deform (Kelvinlets) touches every node; ZBrush Move Elastic auto-offs above ~3M polys: plan bounds Kelvinlets to 3 radii.
- No app supports Move under dynamic topology (3D-Coat re-voxelises): plan 2e adds a stroke-end stretch split pass.
- Bolt asked 2026-10-29 12:00 "is SDL really the limiting factor?": answer in the artifact ("Is SDL really the limit?"): verified SDL reads one sample per OS message and the OS delivers one per frame; chord error under a px at 1500 px/s on a 100 px curve, up to 10 px on a flick; pressure/tilt ramps are the real loss; no latency effect. Don't oversell 1a again.
- SculptGL (Nomad's ancestor) sources are the only algorithmic view of Nomad: falloff 3d⁴−4d³+1, Move = proxy restore + closest point on the new ray to the stored centre.

Phases: 1 input+stabiliser (1a samples, 1b stabiliser 2.0, 1c spacing 0.2 r, 1d predicted cursor), 2 Move family (2a silhouette/normal/same-side, 2b geodesic topological falloff, 2c Elastic kind, 2d hook pinch/rake, 2e Grab under dyntopo), 3 pressure (two curves per brush), 4 smooth (iterations, Relax, Polish=HC Laplacian on Alt), 5 samples/accumulate/hardness/world size + 5d Clay strips (ZB ClayBuildup, Blender cube tip) and Trim (Multiplane scrape), 6 dyntopo polish. Defaults: spacing 0.2 r compensated; topological off by default; Elastic its own kind; Alt+Smooth = Polish.

**How to apply:** a build thread takes the plan file and the artifact; design notes required for 2b, 2c, 2e, 4b, 5a; pen parts need Bolt's Windows/tablet try ([[sculpt-tablet]], [[sculpt-brushes]]).
