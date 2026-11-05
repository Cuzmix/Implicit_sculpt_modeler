---
name: detail-skin-k3-k6-build
description: Detail skin K3-K6 build log (Bolt 2026-11-03 "Do all of the milestones"): what merged, conventions chosen, what is unverified
metadata:
  type: project
  modified: 2026-11-03T07:43:05.275Z
---

Bolt 2026-11-03 00:34: "Do all of the milestones" = build K3, K4, K5, K6 of [[detail-skin-plan]] without stopping to ask.

K3 done 2026-11-03 (all merged to odin-sculpt):
- #518 vector page Skin.side [][2]f16 in owner-triangle frame (skin_frame/skin_lift), undo, Settle, Apply, file (mesh-space f16 in file because owner numbering changes on reload).
- #520 Pinch, Crease's pinch, Snake hook in the skin; Smooth relaxes side.
- #521 VDM stamps = Alpha.vectors (radii; x right, y up, z out), Draw lays them (vdm_move), six built-ins under "VDM STAMPS".
- #523 EXR VDM import: hdri.exr_decode_picture (signed, any size) + exr_encode; Vdm_Axes {Blender x2, ZBrush (x,-B,G) x4, Mudbox (x,-B,G) x2}, setting vdm_axes; library keeps non-Blender maps re-encoded in Blender layout. Presets are UNVERIFIED against real ZBrush/Mudbox/Blender files: if Bolt reports a sideways/sunken stamp, fix the mapping in sculpt/vdm.odin vdm_from_file.
- #527 Capture VDM from object (upward faces of a slab, median level, 256², reads skin exactly, vertices as heights) + Export VDM; script verbs capture_vdm NAME, export_vdm PATH.

Testing gotchas: --ui-events X,Y are window pixels of the 1600x900 dump here, not halved; `set new_vertices 40962; new_scene plane; detail_skin 16; detail_to skin; view_axis top` makes a quick capture slab (default plane is huge: 522 MB scene, 4 min to reopen).

K4 #535: Squeeze, heat view, skin carried through rebuilds. Key insight: skin heights must be measured from the curved (Phong) base `skin_curve`, not the flat triangles, or squeezed skins show scale-like specks.
K5 P1 #537: bake from a skin (self-bake via rest mesh + bvh_closest), VDM `_vdm.exr`, object space, MAPS FOR targets.
K5 P2 #540: Load map into skin (Height PNG/EXR, tangent/object VDM EXR) via UVs; round trip bake->load exact except UV seams. App tests need geom.mesh_recompute_normals on the sculptor mesh (no frame ran).
Screenshot of a card: `--width=1280 --height=720` (dump is 1280x720), open via `--ui-events="8:move:@Search commands;9:down;10:up;12:text:HD detail;14:key:return"`.
K5 P3 #542: .bary export (geom/bary.odin, R11 bird curve, one group, mesh props); NVIDIA's reference validator accepted it. Running compiled external code was later blocked by the auto-mode classifier: decode with own scripts instead.
K6 P1 #543: near chunks drawn by skin_tess.vert (render/skin.odin skin_tess_split, 0.5 px, 4M budget); outline within 1 px vs bary export. SwiftShader lacks Float16/Int16: decode halves by hand. Exact-frame A/B of a skin vs an imported mesh: imports normalise to radius 1 (max distance), so patch the .sculpt Transform scale (pos Vec3 + f32 after the object) to 1/maxdist, then `select N; move 0 0 0` both and hide one; script `select` counts from 1.
K6 P2/P3 #546: render mode shades skinned hits by skin normals (skin data appended to trace attributes, Item_Record.skin, shared skin_grid.slang); Studio needed no code (viewport shading + grid depth). ALL K3-K6 DONE 2026-11-03.
Crease flat patches fixed #550: Settle lifts capped by bend (SKIN_SETTLE_BEND 0.03 of mean edge vs neighbours mean); facets came from Settle kinks surfacing when skin normals recompute (reload). Bench gotcha: --save right after --bench-stroke saves before the post-Settle flush.
