---
name: sculpt-tablet
description: Pen tilt, pressure curve editor and the brush pie (radial menu) in the sculpt app, PR #12 merged 2026-10-24: controls, defaults, what is untested
metadata:
  type: project
  modified: 2026-10-24T17:03:48.969Z
---

Part of the "lets do all of it" brainstorm list (after [[sculpt-files]]). PR #12 self-merged into odin-sculpt (98bc957) 2026-10-24.
- Tools > Pen section: pressure-to-strength/size checkboxes, a Bézier pressure curve editor (drag handles; presets Linear, Soft, Firm, S), Tilt slider (default 0 = off), live pen readout.
- Tilt turns Draw/Clay/Flatten/Pinch/Crease's push direction toward the pen top (max 81 deg), mirrored for symmetry. Flags `--tilt-strength`, `--bench-tilt`. No measurable brush cost (2M stroke 1.27-1.33 ms p50 either way).
- Brush pie: hold Space over viewport and release toward a brush; tap Space or right-click without dragging (pen side button) leaves it open for a click; Escape closes. Space over the viewport is kept from ImGui (its keyboard nav would press focused widgets).
- Untested on a real tablet and on Windows (VM has no pen). SDL reports tilt on Windows pointer messages, X11 and Wayland. Ask Bolt to try pen pressure/tilt and the pie.
- Next on the list: AI ideas, then extras (brush alphas, mask blur/grow).
