---
name: ortho-shading-eye
description: 2026-11-05 #650: ortho view shading turned inside out up close (eye past the surface); fix = env.w ortho flag, v=(0,0,1); how to reproduce offscreen
metadata:
  type: project
  modified: 2026-11-05T08:19:08.321Z
---

Bolt's report: in Ortho, the Normals pass looked inverted/faceted, with odd colours at the outline, on a 1M sculpt. Root cause: mesh_shading.slang used v = normalize(-view_pos) in ortho too. In ortho the eye sits at camera.distance and zooming moves it past the surface, because ortho depth reaches behind the eye. Flat shading flips its normal toward v, so it came out inside out (orange/green from the front), and Solid's rim, specular and MatCap were skewed. It was not culling or GPU sculpt.

Fix #650 (merged into odin-sculpt): draw_items sets Material_Uniforms.env.w = 1 when proj[3,3] == 1, and the shader then takes v = (0,0,1). gtao already did the same.

Repro: `--vertices=20000 --frames=40 --script="ortho_toggle; flat_shading on; view_pass normals" --ui-events="1:move:800,450;2:wheel:1;...;16:wheel:1"` (zooms to camera distance 0.51), then `--dump-viewport`.

**How to apply:** any new shading code that needs the view direction must use the ortho flag and never take it from -view_pos alone. Related: [[perf-critical-care]].
