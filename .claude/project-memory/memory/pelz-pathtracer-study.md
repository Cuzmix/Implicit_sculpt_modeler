---
name: pelz-pathtracer-study
description: 2026-10-31 study of Josef Pelz's TouchDesigner Pathtracer 3.0.1 (MIT): what makes it fast, what we should adopt (ranked)
metadata:
  type: project
  modified: 2026-10-31T15:19:37.071Z
---

Thread "Research Josef Pelz's fast path tracer" (2026-10-31), research only, no code. Report https://claude.ai/artifact/2fqGs7JomNmBRiH8mLxQTq (copy in /mnt/project-files/notes/pathtracer-study/index.html).

Findings: its speed is mostly DLSS Ray Reconstruction (traces ~1/3 of pixels at 1 spp; neural/NVIDIA, out by Bolt's rule), hardware ray query via TouchDesigner's GLSL POP (software trace on Mac), and "Optimize" = kernels specialised to the scene's features with a flexible kernel standing in meanwhile. v3 dropped SVGF and OptiX from 2.1.

Ranked adoption proposed to Bolt (none approved yet): 1 automatic specialised render kernels (Vulkan spec constants / Metal function constants, compile on a worker, general kernel meanwhile); 2 render mode clean while moving (render plan stage 4: reduced size, reprojection, ReSTIR DI, per-signal denoiser); 3 rect/disk area lights with normalised strength across kinds; 4 clear coat, sheen, thin film, transmission (stage 6); 5 indirect-only firefly clamp, passes, "No light" message, stable-planes guides. Not for us: DLSS, haze, glass caustics (likely MNEE), points/lines as spheres/tubes.

Unread: the video (YouTube bot check), Patreon (Cloudflare), the shaders (patron download). Asked Bolt for the transcript or Pathtracer.zip to confirm inferences.

Related: [[sculpt-rendering-roadmap]], [[native-gpu-plan]], [[maxon-docs-access]].

2026-10-31 15:46 Bolt: "lets do all that will benefit our project... lets plan for this". Plan doc https://claude.ai/artifact/XbF8gpo5XncXTQRoYLfX8M (Render plan after the Pelz study): A specialised kernels (2 PRs) > B small fixes (2) > C rect/disk lights + one brightness rule (2) > D clean while moving = old One Render stages 4+5 with reduced size while moving, per-signal denoiser, A-SVGF gradients, mirror guides (6) > E clear coat/sheen, SSS, transmission, thin film (4); old stage 7 after. Awaiting Bolt's review of the plan before building; defaults listed in its Decisions.

2026-11-05 Bolt: "proceed with the plan" (build all stages A-E, self-merge). A1 #702 (spec constants RT_ITEMS/ENV_IMAGE/LENS/SPHERE_LIGHTS, scripts/kernel_stats.py on RADV null device), A2 #703 (Render_Features variants built on a thread via gpu.compute_build_*, switch between samples, scripted runs wait, --no-render-variants; disk pipeline cache dropped). Lavapipe shows no ms gain (CPU); real-GPU numbers owed by Bolt's try_it. Stage C note: rect/disk lights already exist in raster; render mode traces them as spheres, so C = exact area-light tracing. Next: B.
2026-11-05 20:43 Bolt: "dont merge to the main branch for now keep everything in your own branch": from B1 on, commits stay on claude/project-thread-072t81, no merges into odin-sculpt (A1/A2 were already merged).
