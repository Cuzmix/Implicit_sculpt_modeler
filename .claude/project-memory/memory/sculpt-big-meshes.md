---
name: sculpt-big-meshes
description: 20-50M mesh scaling findings and the grouped-culling change (PR #46, 2026-10-25); bench numbers and what was tried and dropped
metadata:
  type: project
---

PR #46 merged into odin-sculpt 2026-10-25 (item 7 of Bolt's "All" list, CPU side).

- The sculpt core already scales with what a stroke touches (`build/bench`, VM):

| Mesh | Large-brush frame | Small-brush frame | Setup | Peak RSS |
| --- | --- | --- | --- | --- |
| 20M | 2.37 ms | 0.45 ms | 3 s | 2.7 GB |
| 50M | 6.2 ms (194k verts a dab) | 0.99 ms | 9 s | 6.75 GB |

- Culling was the only per-frame cost that grew with the mesh: about 1 ms at 50M for any view.
  - Fix: `geom.CHUNK_GROUP` = 64 chunk groups, with bounds and a union cone (`sculptor_chunk_groups`, `chunk_touched` at every s.chunks write).
  - At 50M a close-up drops from 1.39 to 0.12 ms and a whole view from 2.07 to 0.95 ms.
  - No groups under dyntopo.
- Tried and dropped: a BVH-walk frustum cull. It was slower, because the frustum keeps the far side of the mesh, so few subtrees prune without cones.
- Save and open in the app at 30M: a 1 GB file saves in about 8 s and opens in about 4.5 s, bound by the VM's disk and first touch of memory.
- Possible next steps:
  - Bolt's real-GPU run via `build.bat gpubench --vertices=20000000` or `50000000`.
  - GPU compute ([[sculpt-gpu-compute]]) once Bolt's computebench numbers arrive.
