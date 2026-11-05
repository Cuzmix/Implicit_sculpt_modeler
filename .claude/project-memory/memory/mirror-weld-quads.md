---
name: mirror-weld-quads
description: 2026-10-31 #438 Mirror and weld keeps quads (seam weld like ZBrush, polygon cut fallback); pictures in notes/mirror-weld
metadata:
  type: project
  modified: 2026-10-31T14:14:29.617Z
---

Bolt reported Mirror and weld turned quad meshes into triangles. Fixed in #438 (merged into odin-sculpt 2026-10-31): `geom.mesh_symmetrize` takes the level's polygons + creases, first welds along a seam of the mesh's own edges moved onto the plane (polygons kept whole; 3-seam-corner quads re-cut on the other diagonal), falls back to an exact polygon-by-polygon clip. App side `src/app/symmetrize.odin`. A Quad Remesh sphere mirrored on X/Y/Z stays 100% quads. Pictures: /mnt/project-files/notes/mirror-weld/.

**Why:** the seam weld moves the seam loop up to half a polygon onto the plane (shape changes slightly near the seam), the trade ZBrush makes for topology.
**How to apply:** if Bolt reports seam distortion, an option "exact cut" (the fallback path) could be exposed; not built. Not tried on device yet.
