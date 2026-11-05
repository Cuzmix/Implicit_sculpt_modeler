---
name: sculpt-booleans
description: Live booleans (union/subtract/intersect) and Extract in the Odin sculpt app, PR #41 merged 2026-10-25; how they work and known limits
metadata:
  type: project
  modified: 2026-10-25T09:30:50.266Z
---

PR #41 merged into odin-sculpt 2026-10-25 (item 4 of Bolt's "All" list, thread "Bolt's 7-item list").

- Scene > Booleans: an object is marked Union/Subtract/Intersect (Object.boolean, saved; SCENE_VERSION 5). Marked ones apply in scene order to the base (first unmarked object).
- Live boolean draws the preview at ~200k vertices in place of the base and marked objects. It rebuilds when its stamp changes and no mouse or stroke is active.
- Make boolean mesh: ~1M vertices; replaces the base and deletes the marked objects in one chained undo step.
- Extract masked: a shell from mask >= 128, thickness as a share of object size, added as a new object.
- Geom: remesh_run with the B triangles' crossings weighted by BOOL_WEIGHT (4096); mesh_boolean projects the result back within one voxel.
- Speed: Make boolean of two 1M spheres takes ~0.2-0.4 s on the VM. The 10M stroke frame is unchanged at 1.45 ms.
- Limits:
  - Subtract and Intersect objects aren't drawn (no ghost look), so pick them in the Scene list.
  - The seam where the two meshes meet stays at voxel resolution.
  - Not tried on Windows.

Related: [[sculpt-remesh]], [[sculpt-retopo-bake]].
