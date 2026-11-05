---
name: tech-stack
description: Bolt's chosen stack and engineering rules for the sculpting app (Odin, Dear ImGui, SDL3/SDL_GPU candidate, Win+Linux)
metadata:
  type: project
  modified: 2026-10-14T23:40:24.446Z
---

Stack set by Bolt on 2026-10-14:
- Language Odin; UI Dear ImGui (panels, menus, diagnostics, profiling) — ImGui must NOT own sculpt state or draw the viewport.
- Rendering: evaluate SDL3 + SDL_GPU first vs other native options; one graphics backend only unless a concrete need appears; keep it behind a thin boundary, no premature engine/abstraction.
- Targets: Windows and Linux. Odin native toolchain; reproducible build/test/profile commands on both.
- Sculpt representation: evaluate existing SDF/voxel code (if any) vs dynamic mesh vs hybrid on quality, memory, complexity, interactivity.
- Verify bindings' real API, maintenance, license and build behaviour; don't trust an example alone.
- Odin idioms, explicit ownership/allocation, no hot-path heap allocs, data-oriented where it helps, no ECS by default.
- First milestone is a vertical-slice prototype: window+GPU+ImGui, lit sphere in viewport, orbit/pan/zoom, basic brush, frame time + brush latency measured, clean shutdown, tests on both OSes.

Verified 2026-10-14 (decision doc: https://claude.ai/code/artifact/6e7fb48c-24bb-4f03-9c8d-926f3d857845): Odin dev-2026-10 + vendor:sdl3 (3.4.2 headers) + SDL 3.4.18 built from source + odin-imgui (gitlab.com/L-4/odin-imgui, ImGui 1.92.8-docking, backends sdl3+sdlgpu3). Linux needs libc++-18-dev/libc++abi-18-dev. Container has no GPU: use Xvfb + mesa llvmpipe Vulkan. Fresh repo (no existing code); Bolt tests Windows on their own machine, no Windows CI.
Repo: local git repo at /mnt/project-files/sculpt. GitHub: Bolt chose github.com/Cuzmix/Implicit_sculpt_modeler (holds their older Avalonia/C# project on master + feature branch); Odin code goes on new branch `odin-sculpt`, never touch existing branches. Pushed 2026-10-15 (App installed); push new work with `git push github main:odin-sculpt`, never force. Work in /home/claude/sculpt clone, run scripts/setup_deps.sh, build with ./build.sh [debug|release|test|smoke]; smoke needs DISPLAY (Xvfb :99). build.sh must not end a case branch with a failing `[ ] &&` test (set -e exit code bug fixed once already).

2026-10-31: SDL_GPU is retired (Bolt approved; thread "Digest pain points and cleanup needs"). Render draws only with its own Metal (Darwin) and Vulkan (elsewhere) backends; no --gpu flag, no Graphics menu, no Metal start guard. Where this file mentions an SDL_GPU fallback or choice, that is history. See [[pain-points-digest]].
