---
name: sculpt-project-detail
description: Project detail (ZBrush ProjectAll-style) in the Odin sculpt app, PR #44 merged 2026-10-25; behaviour, spaces default, ray fixes
metadata:
  type: project
---

PR #44 merged into odin-sculpt 2026-10-25 (item 6 of Bolt's "All" list).

- Scene > Project detail lets you pick "Project from", then set Reach (share of target size, default 0.03), Strength, "Polypaint too" and "As placed".
- Code: app/project.odin, sculpt/project.odin (`sculptor_project`), geom `project_along_normals` in boolean.odin.
- Default reads each object in its own space, like bake. Duplicate and Retopologize put the copy beside the original, so world space would miss it. "As placed" uses scene transforms.
- Ray gotcha: bvh `ray_aabb` gets NaN (0×∞) when a direction part is exactly 0 and the point lies on a box face (mirror-plane vertices). project_along_normals nudges zero parts to 1e-9 and starts rays 1e-3·reach behind the point. Baking may have the same latent issue.
- Speed: 100k target from a 1M source takes 0.28 s on the VM. Not tried on Windows.

Related: [[sculpt-retopo-bake]], [[sculpt-booleans]].
