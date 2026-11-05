---
name: sculpt-retopo-bake
description: Retopology into quads, auto UVs and normal/displacement baking (PR #40, 2026-10-25): design, limits, timings
metadata:
  type: project
---
Retopology, UVs and baking were merged into odin-sculpt as PR #40 on 2026-10-25. They are item 3 of Bolt's production list.

Retopologize (Scene panel):
- Makes a new all-quad object next to the selected one.
- Steps: decimate to about 0.45 × the wanted quad count in triangles, pair triangles into near-square quads, cut every face into quads Catmull-Clark style, then relax and project back onto the sculpt.
- Not flow-aligned like ZRemesher; about 78% of vertices end up with valence 4.
- **Possible upgrade:** a flow-aligned (Instant Meshes style) field.
- Timing: 10M sphere in 11 s (mostly the decimation); 1M in under 1 s.

UVs and storage:
- UVs are planar charts within 55° of each chart's seed, shelf-packed.
- Quads and UVs live on the base level in `Levels.faces` and are saved in the scene.
- OBJ export writes quads with `vt`.
- They are dropped by Delete lower or by turning dyntopo on.

Bake maps...:
- Picks a folder and bakes the "Bake from" object's top level onto the quad UVs.
- Writes a tangent-space normal PNG (green up), a 16-bit displacement PNG (32768 is the surface), a txt file with the displacement range, and the quad OBJ.
- Timing: 3.7 s for a 2048 bake from 10M.

SCENE_VERSION is now 4 (covers layers and quads).

Not tried on Windows yet. Item 6 (project detail) can reuse `geom.bvh_raycast_with` and the ray-both-ways pattern from `bake.odin`.

2026-10-27 (PR #147): the bake also writes base colour, ORM (ray-traced occlusion) and polygroup ID maps, plus NAME.glb with UVs, tangents and the maps embedded (sculpt-rendering-roadmap.md).
