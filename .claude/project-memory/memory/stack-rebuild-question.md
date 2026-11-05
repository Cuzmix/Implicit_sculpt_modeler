---
name: stack-rebuild-question
description: 2026-10-28 answer to Bolt's "what stack would you pick if rebuilding from scratch": C++20+SDL3+own Vulkan layer+Slang+own UI; don't switch now
metadata:
  type: project
---

Bolt asked (thread "Choose tech stack for a fresh rebuild", 2026-10-28) for an unbiased from-scratch pick. Doc: https://claude.ai/artifact/MFrws44oqwssHjn1XNAQE1

- From scratch: C++20 (restrained subset), SDL3 (windows/input/pen), own thin renderer on Vulkan 1.3 (+ Metal later for iPad), Slang shaders, own immediate-mode touch UI kit (ImGui debug only).
- Verdict: do NOT rewrite. SDL3 and own UI already match. Only the GPU layer is a real limit (SDL_GPU: no ray tracing, no bindless).
- Suggested steps: 1) move SDL_GPU calls out of src/app behind src/render (878 calls in 39 files, 23 in src/app, as of 2026-10-28); 2) shaders to Slang; 3) Odin Vulkan backend only when HW ray tracing or 50M+ bindless drawing is actually needed.
- Reopen the language question only if the first real Android build shows Odin's Android path is fragile.

Related: [[tech-stack]], [[cross-platform-flutter-plan]], [[sculpt-rendering-roadmap]].
- 2026-10-28 Bolt chose to start the Vulkan backend right after steps 1-2 (layout cache PR, GPU-boundary PR), wants a Settings > System > Graphics dropdown (Vulkan | SDL_GPU, on restart), Vulkan the default once it matches SDL_GPU's images here; merge after own full tests, no need to wait for Bolt's Windows try (SDL_GPU stays as fallback). Thread "Prepare renderer for Vulkan and Slang".
- Slang: slangc ships in the LunarG Vulkan SDK (sdk.lunarg.com reachable from the container; GitHub releases are not); Bolt approved running it 2026-10-28 (pinned by hash in setup_deps.sh).
- Progress 2026-10-28: #241 text cache, #243 GPU boundary merged. Slang port committed on branch claude/project-thread-swenqb: 0 px vs GLSL on 19 scenes only with `-matrix-layout-row-major -O0` (spirv-opt folds x/c to x*(1/c)) and folded literal constants. Vulkan design + architect review: /mnt/project-files/notes/vulkan/backend-design.md.
- Note: the app creates SDL_GPU with SPIR-V only, so it always runs SDL's Vulkan backend; Mac/iPad (Metal) needs the Slang Metal output first, there are no MSL shaders yet.
- 2026-10-28 Bolt reminded: targets are Windows, Linux, Android, Mac, iPad. Plan agreed: Vulkan default on Win/Linux/Android with automatic SDL_GPU fallback when features missing; Mac/iPad stay on SDL_GPU (Metal) until a Metal backend; Graphics dropdown lists only what the platform supports.
- 2026-10-28 later: #245 Slang merged (0 px, 19 scenes), #246 GPU seam (src/render/hal.odin, 67 gpu_* procs) merged. Vulkan backend (vk_device/vk_resources/vk_cmd/vk_swapchain.odin, mirrors SDL_GPU's own Vulkan backend: same set numbering, default layouts, cycling, flipped viewport) runs behind --gpu=vulkan: 0 px vs SDL_GPU on all 19 parity scenes, 0 validation messages in smoke. Gotcha: vk_* procs must take struct args #by_ptr like hal's, or Odin passes garbage. Force-push is blocked by the classifier; keep branch fast-forwardable.
- #249 Vulkan backend merged 2026-10-28 (SDL_GPU still default; smoke runs both backends, any Vulkan validation message fails the run). - #252 merged 2026-10-28: Settings > System > Graphics (Automatic|Vulkan|SDL_GPU, applies on restart, `graphics` setting peeked before the window), Automatic = own Vulkan on Win/Linux/Android, SDL_GPU on Mac/iPad; --gpu=auto|vulkan|sdl; fallback reason shown in the menu. Scripted runs (tests, touch, parity) now default to Vulkan. Untested on real Windows/Android drivers; older Android tablets without Vulkan 1.3 fall back.

2026-10-31: SDL_GPU is retired (Bolt approved; thread "Digest pain points and cleanup needs"). Render draws only with its own Metal (Darwin) and Vulkan (elsewhere) backends; no --gpu flag, no Graphics menu, no Metal start guard. Where this file mentions an SDL_GPU fallback or choice, that is history. See [[pain-points-digest]].
