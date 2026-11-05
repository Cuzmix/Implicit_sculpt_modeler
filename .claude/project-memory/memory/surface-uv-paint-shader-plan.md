---
name: surface-uv-paint-shader-plan
description: UV unwrap, texture paint and shader graph (Surface space): plan v2 doc 2026-11-03, 24 PRs, approved 12:43, building (UV1 merged #559 #561); MRGB cut
metadata:
  type: project
---

- **Plan v2 (2026-11-03, the one to build from)**: Claude Doc https://claude.ai/artifact/CiCECeBofwvGhBwRpGEH84 ; notes copy /mnt/project-files/notes/surface/plan-v2.md. 24 PRs in six series: UV1-6 (pure package `uv`: per-corner UVs + seams on any mesh, ABF++ then LSCM, SLIM-style relax, auto seams, Fast/Tight packers, UVs on levels, Peel), DK1-3 (docking frames/tabs/floats from the docking mock), UE1-2 (seam pen with live re-solve, UVs tab), PT1-6 (Paint_Layer stack; targets Vertices, Skin = colour per detail-skin sample (Ptex-like, own idea), Texels = sparse 128² tiles painted by 3D compute dabs, per-tile undo), MK1 (masks generated live from the sculpt), SH1-4 (graph compiled to bytecode run by one committed kernel; Stack view, Graph tab, Probe), OT1-2 (bake, UDIM, glTF/USD, content packs).
- Decisions recommended (Bolt to confirm): three paint targets; bytecode graph not per-node kernels nor compiled shaders (offline Slang, App Store); own flattener measured against Blender bpy in `bench --uv`; Surface as 4th space; Layers card gets a Paint tab; UV engine first (paint on vertices/skin can jump the queue).
- ArmorPaint: avoid its per-dab whole-mesh UV raster, device shader compile, full-size layers.
- Mock v2 (Paint, UV with Peel and seam pen, Shade with graph float, Probe, live nodes, Phone): https://claude.ai/artifact/BJtWJCmbusZgbx4zzDNwXm (source /mnt/project-files/notes/surface/surface-mock-v2.html); 2026-11-03 merged the best of the v1 mocks into it at Bolt's ask, keeping the app's chrome (docking frames instead of the v1 Overlay/Split/Full modes).
- MRGB: CUT as a named feature. Multi-channel strokes are modern and wanted (Wafer): a layer's channel dots pick what a stroke writes, the brush carries a value per channel (PT1). 'Across a topology change': paint projected across Remesh/dyntopo (PT2), no convert prompts in Surface.
- 2026-11-03 12:20 Bolt sent Wafer and CozyBlanket Pro (sparseal.com/wafer, /cozyblanket-pro) to study: done, table in the plan doc section "Wafer and CozyBlanket Pro" (notes copy has the list). Wafer paints multi-channel per stroke (layer channel sets), confirmed our tiles design; CBP: seams/islands edited in 3D, pack to region/distribute, editable bake cages, AI seams (skipped).
- 2026-11-03 12:43 Bolt: "ok proceed with the plan" = BUILD with default decisions. This thread (renamed "Build UV unwrap for the Surface space") does UV1-UV6; coordinator asked to start DK1-3 and PT1-2 threads.
- UV build progress (UV1-UV6, branch-only since 2026-11-05): see [[surface-uv-build]].

**Why:** Bolt wants best-of-all-worlds UVs, texturing and shaders on tablets with no runtime shader compile. **How to apply:** build from plan v2 once Bolt picks; designs before code for the `uv` package, LAYR/MATG sections, History kinds, GPU buffers and kernels. See [[sculpt-retopo-bake]], [[docks-cards-redesign]], [[detail-skin-plan]], [[best-of-all-worlds]].
