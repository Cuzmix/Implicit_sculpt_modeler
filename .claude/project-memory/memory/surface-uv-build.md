---
name: surface-uv-build
description: UV engine series UV1-UV6 build log: merged PRs, 2026-11-05 branch-only rule (claude/project-thread-ubkdnn), what is built, Bolt's Unwrap mock pick C
metadata:
  type: project
---

UV build: UV1a #559 (package `uv`: Uvs store per triangle corner, seams, islands, check, from_quads/to_quads) and UV1b #561 (Levels.uvs replaces Quad_Faces.uv; quad readers use levels_quad_uvs view; imports keep UVs on any mesh via uv.from_corners; SCENE_VERSION 38) merged 2026-11-03. UV2 in 5 PRs (notes uv2-design.md): #564 island meshes+stretch, #566 LSCM over own LDLT (nested dissection) merged; #572 multifrontal parallel factor (1M tris 22 s on 4 threads). Paused 2026-11-03; resumed 2026-11-05 ("ok continue"): LSCM moved onto src/sparse supernodal (own solve.odin/front.odin deleted; hierarchy patch in notes/surface/parked superseded). 2026-11-05 19:09 Bolt: do NOT merge to odin-sculpt for now, keep all UV work on branch claude/project-thread-ubkdnn (lifted at 20:51, see below). Branch has: LSCM on sparse, shelf pack, bench --uv/--measure, ABF++ default, scripts/uv_check.py (bpy absent here). 20k island ~100 ms LSCM vs plan budget 15 ms: live drag should reuse the factor (UE1). 2026-11-05 20:21 Bolt OK'd Unwrap mock C (https://claude.ai/artifact/NctPzXiK1NXc994g5T615t): UVs section in Mesh card Surface group + "needs UVs" asks in Textures/Bake that open it. Then packing+bench --uv, ABF++.

2026-11-05 evening on the branch (unmerged): UV3a SLIM relax (relax.odin), UV3b symmetry (symmetry.odin), UV4a auto_seams + unwrap (seams.odin), UV5 skyline packer with UDIM tiles (skyline.odin, keeps the fuller of skyline/shelf in one square). Designs: notes/surface/uv3-design.md, uv4-design.md. Next: UV4b app (History .Uvs design first, UVs section in Mesh card Surface group, asks in Textures/Bake), UV5 texel density, UV6.

**Why:** next thread continues the series without re-asking. **How to apply:** keep everything on the branch until Bolt says merge. Related: [[surface-uv-paint-shader-plan]].

2026-11-05: UV4b (Unwrap in app, Mesh card UVs section, mock C) built; PR #704 (UV1-UV5a + UV4b) merged into odin-sculpt 2026-11-05. Bolt 20:51: "ok now you merge as you go along": branch-only rule lifted; open and self-merge a PR per step into odin-sculpt. Pre-existing failing app tests on branch: five-controls Options 6, Mask 21 vs 20, textured_export "unpick first". Follow-up: texture views/bakes/exports on triangle UVs (UV4c).
2026-11-05: UV4c #705 merged (maps/Checker/Load map/textured glb on any sculpt with UVs via uv.split + textured_split; bake + skin-from-map still quad-only). Next: UV5b texel density, UV6.
