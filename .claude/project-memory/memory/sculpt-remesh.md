---
name: sculpt-remesh
description: DynaMesh-style voxel remesh in the sculpt app (PR #9, 2026-10-24): how it works, keys, bench numbers, limits
metadata:
  type: project
  modified: 2026-10-24T14:43:06.348Z
---

Part of the "lets do all of it" brainstorm list in thread "Add sculpting brushes, masking and symmetry" (after [[sculpt-brushes]]). PR #9 self-merged into odin-sculpt (32b96fb) 2026-10-24.
- Remesh selected (Scene panel) / Ctrl+R (own vertex count) / app flag `--remesh=N` now voxel-remeshes the current level via geom.remesh_voxel (src/geom/remesh.odin); levels, HD, mask, undo history are dropped.
- Algorithm: lattice spacing h = sqrt(1.5*area/target), cap 4096 points per axis (DynaMesh max); exact fixed-point x/y/z ray crossings + winding number; marching cubes with a table built from a face rule (closed manifold guaranteed); 3 tangential relax rounds fused with normals. Memory follows surface area.
- Bench `build/bench --remesh --prefault=3000` (VM, 4 threads): 1M 0.3 s, 5M 1.5 s, 10M 4.3 s remesh + 1.3 s sculpt-ready; edge p99/median 3.4 -> 1.6. Peak RSS 2.3 GB at 10M. On the VM much of the time is first-touch page faults (vertex_faces_build, output arrays), so desktop should be faster.
- Not done: keeping sculpted detail by projecting onto a higher-res remesh, polygroups, thin-part preservation. Windows not tried yet.
- /mnt/project-files/sculpt is a stale copy (stops at PR #5 era); GitHub odin-sculpt is the source of truth.
