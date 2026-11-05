# Surface plan v2: UVs, texture paint, shaders (2026-11-03)

Full plan (the doc Bolt reviews): https://claude.ai/artifact/CiCECeBofwvGhBwRpGEH84
Earlier: plan.md (2026-11-01), split-view-plan.md (docking D1-D5), mocks in this folder.

## Recommendation (the six decisions, defaults)
1. Paint on three targets per layer: Vertices (polypaint's path, 20M), Skin (the detail skin's samples: Ptex-like, no UVs, seamless, resolution independent of the mesh; refuses above 16M samples), Texels (sparse 128x128 tiles over UVs; what exports).
2. Texel dab = a compute kernel over the tiles whose 3D bounds meet the dab; each texel tested in 3D through the tile's position+normal map (lazy), alpha, symmetry, mask, hiding; paint-mask tile per stroke against double dabs; per-tile undo; gutters dilated at stroke end. NOT ArmorPaint's UV-space raster of the whole mesh per dab (cost grows with the mesh, breaks with symmetry).
3. Shader graph compiled by the app to bytecode, run by one committed kernel (material.comp.slang, registers per texel), stage cuts at filters (blur, normal from height, dilate) that are fixed kernels; output = the standard maps; CPU interpreter is the test reference. No shader compile on device (offline Slang, App Store 2.5.2).
4. Own flattener in a pure package `uv`: ABF++ then LSCM, SLIM-style stretch relax, pins, symmetry (solve + side, reflect); packers Fast (skyline) and Tight (xatlas-style raster); measured against Blender bpy in `bench --uv` on the remesh_check fixtures.
5. Surface = 4th space, shelf pages UV / Paint / Shade; UVs, Texture, Graph are docking tabs (DK1-DK3 = docking mock's D1-D5); Layers card gets a Paint tab; Material card gets Stack + Looks.
6. Order: UV engine, docking and vertex paint start in parallel; then UV editing, texel paint, masks, graph, out.

## PR list (24)
UV1 data+seams+UVS section | UV2 islands+ABF+LSCM+bench | UV3 stretch relax, pins, symmetry | UV4 auto seams, Unwrap | UV5 packers, texel density, UDIM | UV6 UVs on levels, Straighten, Peel
DK1 frames+tabs | DK2 2D tab kinds + Texture tab | DK3 floats, Maximise, Overview, drag and drop
UE1 Surface space, seam pen, live re-solve, Stretch pass, Peel | UE2 UVs tab editing
PT1 Paint_Layer stack, Vertices target, Layers card Paint tab, LAYR section | PT2 Skin target | PT3 texel store + composite | PT4 texel dab kernel | PT5 tools (erase, blur, smudge, clone, fill, stencil, decal, gradient), 2D paint | PT6 fill layers, move between targets, blend modes
MK1 generators (cavity, occlusion, thickness, height, facing, groups, mask, level difference, skin height, colour) + Mask pass
SH1 material data, bytecode compiler, interpreter kernel, MATG | SH2 Stack view, Probe, Looks, node set A | SH3 Graph tab | SH4 node set B, generators as inputs
OT1 bake stack to files, UDIM, texture sets, glTF/USD, Blender link, Send | OT2 smart materials as content packs, README, full gate

## MRGB (decision 7, final 2026-11-03 11:58: cut)
No Paints chip, no Look/Colour/Material brush mode. Kept: every shading mode reads the same paint composite (MatCaps colour only, said in the readout); the lit swatch; layer channel dots paint roughness/metal/height when enabled (PT1). Reason: the surprise was lighting, ZBrush's M is a palette index nobody else copies, channel dots already cover the use.

## Budgets
Flatten 20k-face island < 15 ms; Pack Fast 1000 islands < 100 ms; texel dab over 64 tiles < 1 ms M2 / 2.5 ms Mali; composite 2048x4 layers < 2 ms; 100-op material at 2048 < 8 ms M2; generator < 10 ms; paint per object capped 512 MB; no new per-frame viewport cost.

## References read
ArmorPaint (armory3d/armortools: make_paint.c, render_path_paint.c, make_mesh.c, slot_layer.c, history.c, util_uv_unwrap.c, dilate_pass.shader); Blender (uv_parametrizer.cc, uv_pack.cc, uvedit_unwrap_ops.cc). Substance, ZBrush, Nomad, Mari, 3D-Coat from manuals.

## Across a topology change (2026-11-03 12:10)
Surface never asks to convert a sculpt mesh or cage. Prompts: Texels with no UVs offers Unwrap; voxel clay offers conversion; Remesh / Quad Remesh in place / dyntopo warn (UVs dropped). Paint layers survive: projected onto the new surface with bake rays (Vertices->vertices, Skin->samples, Texels->vertices until new UVs), one undo with the swap entry; rides PT2.

## Wafer and CozyBlanket Pro (Sparseal), read 2026-11-03 12:20 (full table in the plan doc)
Sources: product pages (markdown), CozyBlanket tool reference, App Store history+reviews, CG Channel, 80.lv, screenshots. No manual; YouTube walkthrough not watchable here.
Correction: Wafer paints Color/Roughness/Metal/Bump in one stroke via layer channel sets -> the need is current; our channel dots + per-channel brush values cover it (MRGB cut stands).
Folded in, no new PR: PT1 channel values beside the swatch, 16-bit height/roughness, dithered 8-bit composite; PT3 Affect chips (Front facing, Same island, Same polygroup, Facing angle), Smudge/wet mix, Clip to mask, Alpha lock, pixel-art switch; PT4 paint in the Texture tab; DK3 References tab with Sample; UE1 Island multitouch on the model + X gesture re-solves an island; UE2 Pack to region, Distribute; UV4 Pack Together; OT1 Packing list (domain->channel, PNG/EXR), cage distance painted with the mask brush, high->low links in Scene card, bake map previews, all texture sets in one pass. Avoided: AI seams/topology, GPU packer before measuring, whole-4K tiles, touch that paints.
