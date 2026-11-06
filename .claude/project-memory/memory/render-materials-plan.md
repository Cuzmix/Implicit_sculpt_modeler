---
name: render-materials-plan
description: "2026-11-06 render plan approved: Series E (OpenPBR-style material record, SSS, coat, sheen, glow, transmission, thin film, glTF) then Series O (any-size render, shadow catcher, passes); self-merge allowed"
metadata:
  type: project
  modified: 2026-11-06T15:00:00.000Z
---

2026-11-06 Bolt approved the render plan, which takes over the Pelz plan's stage E (nothing had built it; branch claude/project-thread-072t81 holds only B1). Worktree ../sculpt-render, branch claude/render-materials; E1-E3 are PR #761.

Series E, one PR each: E1 material record (Material fields, materials out of render_trace's Item into a table in the items buffer since all 8 storage buffers are used; sm-architect reviews first; 0 px change) > E2 multiscatter GGX and IOR F0 (the one intended pixel change) > E3 full random-walk SSS behind RT_SSS with Skin, Wax, Jade, Marble and Milk presets > E4 viewport pre-integrated Burley LUT and Fast shadow-map translucency, replacing the classic wrap Skin and Red wax > E5 coat, sheen, glow > E6 transmission > E7 thin film (optional) > E8 glTF KHR_materials_* in and out. A mock of the Material card's Surface section comes before E3's sliders. Series O after: O1 render at any size, O2 transparent background and shadow catcher in Full, O3 passes as images.

Rule for every lobe: its own lazily made pipeline variant or specialization constant (#702, #703), so scenes without it stay 0 px different and 0 ms slower.

**Why:** Bolt asked to overhaul the render with SSS and make it feature complete, and said yes to Series O.
**How to apply:** build in ../sculpt-render, one PR per step, gate and self-merge ([[self-merge]]). Related: [[pelz-pathtracer-study]], [[local-machine-real-gpu]].
