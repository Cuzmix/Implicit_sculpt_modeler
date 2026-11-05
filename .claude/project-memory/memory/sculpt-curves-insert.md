---
name: sculpt-curves-insert
description: Curve tool (tube/stitches/zipper) and Insert tool in the Odin sculpt app, PR #43 merged 2026-10-25; behaviour and limits
metadata:
  type: project
---

PR #43 merged into odin-sculpt 2026-10-25 (item 5 of Bolt's "All" list).

- Tool enum now has Curve (C key) and Insert (I key), in src/app/curve_tool.odin. Geometry is in geom/curve_mesh.odin.
- Curve: a drag over a surface makes a new object on release.
  - Tube is a capped sweep (Sides, Lift); Stitches are leaning bars; Zipper is alternating teeth.
  - Width is a share of the brush diameter.
- Insert: a click places a primitive or a "Copy of" a scene object on the surface normal. Size comes from the brush, or from a drag. Sink sets depth.
  - "Mark as" sets its boolean mode, which ties into Live boolean ([[sculpt-booleans]]).
- Each result is a new object and one undo step. Settings persist in settings.odin.
- Limits:
  - Tubes are low-poly (square quads from Sides) until remeshed.
  - Curves can't be edited after release.
  - Inserts are separate objects, not merged into the surface.
  - Not tried on Windows.
