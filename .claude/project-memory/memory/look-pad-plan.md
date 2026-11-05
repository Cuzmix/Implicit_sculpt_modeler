---
name: look-pad-plan
description: 2026-11-04 Look pad plan (Uniform Surface View chart done better) replacing the Shading mode list; mock + 4 PRs, awaiting Bolt's 3 picks
metadata:
  type: project
  modified: 2026-11-04T10:34:31.847Z
---

Bolt 2026-11-04 10:29 asked to plan how we beat Uniform's Surface Views chart (x = shape->colour->unlit, y = light energy; Static views with 4 lights + env). Planning only.
Plan + live mock: https://claude.ai/artifact/7B85zKHpkeQE7BSxaQEgB1 (source /mnt/project-files/notes/surface-views/look-pad.html).

Design: pad x: c=min(1,2x) colour, shape s=mix(min(1,2(1-x)),1,y); y blends view-locked "View light" (bottom, never black; can be a MatCap) to scene lights (top). Corners = today's modes (BL Solid MatCap Single, TL Solid Studio, TR Material Preview + Render switch, BR Solid Flat Material). 9 named snap spots, follows tool (spot per tool kind), quick pad (hold 1 / hold chip, relative drag), up to 4 saved-look pins (replaces Static views), per-view spot.
Removes Shading_Mode list, Solid_Lighting, Single colour, Wireframe mode (twin of overlay); Flat shading renamed Facets. Cost: 16 B uniforms, uniform branch so edges/corners = today, interior both light paths (~10-20% frag, gpubench before merge).
PRs: 1 shader blend + View_Shading, 2 ui.pad + Shading chip opens Look card's Shading section, 3 quick pad + follow tool, 4 pins + view light editor.
Decisions asked (my recs yes/on/yes): replace mode list; follows tool on by default; pins max 4.

**How to apply:** build only after Bolt answers; touches a shader so PR 1 checks corners 0 px vs base. Related [[uniform-study]] (Look pad idea), [[surface-uv-paint-shader-plan]].
