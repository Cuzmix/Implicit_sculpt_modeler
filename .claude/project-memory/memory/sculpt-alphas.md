---
name: sculpt-alphas
description: Brush alphas (image stamps shaping each dab) in the sculpt app, PR #13 merged 2026-10-24: features, cost, what is next
metadata:
  type: project
  modified: 2026-10-24T17:31:59.501Z
---

First of the "extras" after Bolt chose to skip the AI ideas (2026-10-24; follows [[sculpt-tablet]]). PR #13 self-merged into odin-sculpt (6d3377d) 2026-10-24.
- Tools > Alpha section: thumbnails of Round + 6 built-ins (Square, Noise, Rings, Stripes, Dots, Star), "Load image..." (PNG/JPEG/BMP/TGA/QOI via core:image; brightness x opacity), modes Follow stroke / Fixed / Random plus Angle slider. Outline turns into the rotated square.
- Image lies on the plane across the area normal; symmetry mirrors it. Grab and Shift-smooth ignore it.
- Cost: dab searches only out to the measured reach (max sqrt 2 radii). Noise alpha vs Draw at 10M: +19% per dab, +8% per frame. Always-sqrt-2 reach had been 2.2x.
- Flags `--alpha`, `--alpha-mode`, `--alpha-angle`. Screenshots in /mnt/project-files/screenshots/brush-alpha*.png.
- Not done (possible follow-ups if Bolt asks): dab spacing control / DragRect single stamps, alpha textures as GPU images for hundreds of alphas.
- Followed by mask Blur/Sharpen/Grow/Shrink (PR #14, see [[sculpt-brushes]]), which finished the brainstorm list.
