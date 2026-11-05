---
name: sculpt-perf-work
description: Status of the sculpt performance roadmap (culling, undo, partial redraw, gpubench, stroke feel, normals, dabs, subdivision levels, simplified drawing, HD detail, what is next), with PR numbers, measured results and container bench tips
metadata:
  type: project
  modified: 2026-10-17T17:25:56.637Z
---

Roadmap from thread "Faking 3D like ZBrush" (re-ranked 2026-10-17). Architecture background in [[sculpt-decisions]].
- Merged: culling + packed 16 B vertices (PR #2, flag --no-cull); per-stroke undo of hit nodes, 512 MB cap (PR #3); partial redraw, pixel-identical (PR #4, --no-partial); frame timing, VSync switch --no-vsync, `build.bat gpubench` -> build/gpubench.md (PR #4).
- PR #5 (merged into odin-sculpt 2026-10-17, 4 commits):
  - Stroke feel: every mouse/pen sample, dabs every 0.25 radius along the screen path, pen pressure (strength, optional size), lazy mouse, 64 dabs/frame cap with backlog. Bench viewport resizes in frames 0-2, so a stroke restarts at the pointer on resize.
  - Normals: dirty nodes .Shape (full) or .Edge (border verts only); cones wait until the stroke ends (CONE_BATCH 512/flush). 10M normals/frame 0.83 -> 0.58 ms.
  - Dabs: per-node undo allocations (one growing buffer realloc-stalled dabs), owned bounds computed in the move pass, falloff on squared distance. Slowest 10M stroke frame 4.8 -> 2.4 ms; 1M dab 0.118 -> 0.048 ms; 10M typical dab unchanged at 4 threads (0.66 -> 0.56 ms single-thread).
  - Subdivision levels (c31b16d): details in [[subdivision-levels]]. At 10M a base stroke frame is 0.10 ms vs 2.06 on top.
- Dead ends: hoisting dab constants / select instead of branch in the vertex loops gave nothing. At 10M the vertex passes look memory-latency bound in this VM (draw ~6 ns/vertex single-thread), so instruction tweaks don't show here.
- Container benching: VM is noisy (shared L3). Run old/new alternately, 3-5 rounds, medians; nothing else running; `--prefault=3000`. Bench "Dab ms" is a median, so it hides stalls: check "Frame ms max" too. Profile phases with a scratch patch (scratchpad tools/prof_patch.py), not in the repo.
- Container pacing: Xvfb does not pace FIFO; for vsync use headless weston on wayland-9 (XDG_RUNTIME_DIR set, SDL_VIDEO_DRIVER=wayland).
- PR #6 (self-merged 2026-10-18): simplified far chunks while the view moves, 17x fewer triangles orbiting 10M; details in [[simplified-drawing]]. gpubench now has "Orbit, no simplify" and a triangles table; `build.sh wincheck` (another thread) compiles for Windows from Linux.
- PR #7 (self-merged 2026-10-19, d75845d): HD detail, ZBrush-style windows up to 3 Loop steps above the top level; details in [[hd-detail]]. That finishes the coordinator's list for Bolt's absence; no next item chosen yet.
- Windows gpubench received 2026-10-24 (RTX 3060 Ti, Vulkan, 12 threads, mailbox, 1214x862): with all toggles on, every size 500k-10M is under 1 ms GPU (10M orbit 0.54, stroke 0.41) and CPU stroke p50 0.56 ms (500k) to 1.44 ms (10M), p99 2.4 ms; toggles off cost 2-3 ms GPU at 5M+. Pointer latency p50 3.9 ms. 10M simplified-copy build 1.18 s. Verdict: viewport perf is solved for 500k-10M; remaining cost is CPU per stroke frame at 10M. Still missing: a hands-on Windows try of levels and HD detail (PR #7).
