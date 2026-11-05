---
name: symmetry-line-grab-strength
description: 2026-10-29 thread "Show symmetry line and mirror point": #312 symmetry line + mirrored brush rings, #315 Grab/Elastic Strength scales the drag; both await a Windows/tablet try
metadata:
  type: project
  modified: 2026-10-29T19:56:01.937Z
---

Bolt's feedback 2026-10-29 (one message, four items; this thread had item 1, then Bolt added the Grab one here).
- #312 merged: with symmetry on, a thin line in each plane's axis colour where the plane cuts the selected object (Nomad style, Bolt sent a Nomad screenshot as the model), Radial draws its axis; brush ring shows dimmer copies + dot at each mirrored image (ZBrush). Switch "Show the symmetry line" (Symmetry popover + Settings > Interface > Symmetry, key `symmetry_line`). Cut is `sculpt.sculptor_plane_section`, cached per stroke; ~1.2 ms/plane at 5M tris. Voxel objects: rings only, no line.
- #315 merged: Grab and Elastic Strength = how far they move per pointer travel; 0.5 (default) exact, full 2x, pressure ignored; `.strokes` v30, older replay unchanged.
- Fresh container gotcha: setup_deps.sh needs the apt packages listed at its top (libxcursor-dev etc.) plus xvfb; install them first.

Related: [[sculpt-brushes]], [[brush-engine-build]], [[gate-per-pr]].
