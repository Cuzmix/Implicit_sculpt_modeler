---
name: try-it-windows-2026-11-03
description: Bolt's try_it.py run on his Windows 3060 Ti PC 2026-11-03: 11/11 pass on own Vulkan, caps and frame numbers, open stroke-rib question
metadata:
  type: project
---

Bolt sent build/try_it.zip from his Windows 11 PC (RTX 3060 Ti) on 2026-11-03: 11 of 11 checks passed, all gpu_backend=vulkan.
- Caps logged: present_timing=Present_Wait, GPU timestamps, async_compute=Second_Queue, ray_query=true (check passed in render_mode), barycentrics=true, gpu_cull=true, subgroup 32, int64 atomics.
- GPU p50: sculpt_1m 0.40 ms, sculpt_10m 0.92 ms (CPU 2.17), orbit_5m 1.43 ms (cull_ms 0.068). Frames ~13 ms = vsync.
- Validation layer not installed on his PC (no Vulkan SDK), so that check ran without it.
- Not covered: async/RT on-off A/B, iPad Metal.
- Open: sculpt_1m.png/sculpt_10m.png strokes show ribs and dark cracks where the scripted Dots stroke folds back; unknown if artefact or dab stacking.

Related: [[native-gpu-plan]], [[pain-points-digest]].
