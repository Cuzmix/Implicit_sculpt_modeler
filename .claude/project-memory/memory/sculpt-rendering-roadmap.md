---
name: sculpt-rendering-roadmap
description: Rendering thread state: Stage 1-4 PRs merged, Sculpt studio look, render mode 4.4a, what is next (textures in render mode)
metadata:
  type: project
  modified: 2026-10-27T13:29:18.836Z
---

Thread "Improve viewport shading, rendering and PBR" (branch claude/project-thread-f462c2, self-merges into odin-sculpt). Plan https://claude.ai/artifact/YDpGZoj6b964KHvhp9VYrk; designs in /mnt/project-files/notes/rendering/ (stage4-design.md: 4.4 addendum + "architect review applied" overrides). Bolt: nothing neural, nothing proprietary (no DLSS); take best of all apps.

- Stages 1-3 merged #125-#156 (sRGB/tonemap, matcaps, MSAA, lights, materials, per-group materials, bake set, textures, textured glTF).
- Stage 4 + extras merged #163-#200: image environments, live GTAO, traced studio, Sculpt studio look (#183/#185), render mode Full (#188, path.odin), shadows from every light (#190), denoise (#192), env importance sampling (#193), half resolution (#195), textures (#198), depth of field (#200). Designs in notes/rendering/.
- 2026-10-28 Bolt chose one Render section: #234 merged. Scene > Render = Render switch (Studio_Render id, Shift+R) + remembered Quality Preview (studio render) | Full (render mode, Render_Mode = "Full render"); render_set keeps one on; Studio section removed, Occlusion while working moved to Look. Bolt asked about Marmoset-style features: I suggested post stack (bloom/vignette/grain/AgX), SSS+clearcoat+sheen, shadow catcher/turntable/passes, temporal reuse while orbiting; hardware RT only after measuring Full's ms/sample on his RTX 3060 Ti (SDL_GPU has no RT). 2026-10-28 Bolt asked for ONE always-on modern Render (EEVEE Next / Toolbag 5 class); plan doc https://claude.ai/artifact/PPSMxjSsYTUZfkVnufnTdL (Fast/Balanced/Path traced; stages: 1 finishing stack, 2 Fast with temporal reuse, 3 gate = Vulkan backend from thread "Prepare renderer for Vulkan and Slang", 4 Balanced ReSTIR DI + per-signal denoiser, 5 path traced as rest state, 6 SSS/clearcoat/sheen, 7 shadow catcher/turntable/passes). Coordinate render file changes with that thread: its order is text cache → GPU boundary (render.Cmd/render.Texture handles, boundary_check.py bans sdl.*GPU outside src/render) → Slang (all shaders .slang) → Vulkan default. My stage 1-2 PRs go after its GPU boundary PR, in GLSL (it ports them), adding passes/targets but not restructuring renderer.odin pipeline creation or the viewport target layout; tell it when I merge.
- 2026-10-28 Bolt: "do all of the phase" (stages 1-2). Merged #250 1a finish (tone curves Neutral/AgX/ACES, grade), #256 1b bloom/sharpen(CAS)/aberration, #258 2a Fast keeps samples while orbiting (studio_reproject, carried accum; camera-fixed shadows hidden while moving), #262 2b Preview renamed Fast (`preview` still parses). Stage 3 waits on the Vulkan backend thread (now default since #252; compare with --gpu=sdl, 0 px both backends so far). Images notes/rendering/look/finish-1b.png, fast-carry-2a.png, fast-rename-2b.png. Unverified: Windows, tablet, real-GPU cost.
- Lights are owned by the ZBrush-UI thread ([[sculpt-lights-3d]]); I own mesh_shading.glsl changes for looks/studio.

**Why:** Bolt's brief: better shading, materials, PBR, texturing, baking, rendering. **How to apply:** one PR per step, 0 px against base with features off, gate incl. touch for panel changes.
