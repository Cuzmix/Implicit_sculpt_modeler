---
name: paint-layers-build
description: Surface plan PT1-PT2 paint layers build 2026-11-03: PT1a merged #569 (stack, Paint tab, SCENE_VERSION 39); next PT1b roughness/metal, PT2a Skin, PT2b rebuild carry
metadata:
  type: project
---

- Design: /mnt/project-files/notes/paint-layers/design.md (architect-reviewed; revisions at the end: separate `paint_material` u32 GPU buffer for roughness/metal with a dummy, Mix only until PT6, no Height on Vertices/Skin targets, Skin undo gets its own `skin_colors`, rebuilds flatten to one "Paint 1" until PT2b, dyntopo frees paint).
- PT1a #569 merged 2026-11-03: src/sculpt/paint_layers.odin (picked layer IS Sculptor.color; `paint.shown` composite nil while plain; front-to-back premultiplied over + position-hash Bayer dither in `paint_composite`; per-node dirty via mark_stale(.Paint)); Paint_Op undo, History kind .Paint; lens_paint_layers.odin (Layers card Sculpt/Paint tabs). SCENE_VERSION 39 (UV1b took 38 concurrently: check origin before bumping).
- Perf (release, 5M verts, VM): flush 0.03 ms 1 layer, 0.21 ms with 4 layers.
- Pre-existing failures on odin-sculpt 2026-11-03 (not ours): app kit_more "Options: 6 controls"/Retopo 13 controls, Skin_Squeeze homes; retopo tests abort in AutoRemesher C++ ("terminate called").
- 2026-11-03 13:57 PAUSED at Bolt's ask mid-PT1b: uncommitted work saved as /mnt/project-files/notes/paint-layers/pt1b-wip.patch (base odin-sculpt b30d0b3, apply with git apply). Done in it: sculpt side (Paint_Channel dots, Material_Paint per layer + Sculptor.material, brush roughness/metal, Fill/Clear/Blur/eyedropper sculptor_paint_at, undo/adjust/levels carry/file, SCENE_VERSION 40, test passing); render Mesh_Buffers.paint_material + upload + bindings (MESH_VERTEX_STORAGE 2, skin 5, tess 8). Not done: app call of mesh_buffers_upload_paint (new materials arg), shaders (binding + varying location 13 + mesh_shading surf blend), app UI (dots, sliders, settings, eyedropper), README.
- Remaining: PT1b channel dots + brush roughness/metal + paint_material buffer + shaders (.spv/.msl/.wgsl) + eyedropper; PT2a Skin target; PT2b carry layers across rebuilds via Surface_Map.

See [[surface-uv-paint-shader-plan]].
