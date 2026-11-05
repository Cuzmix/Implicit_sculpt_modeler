---
name: native-gpu-plan
description: 2026-10-30 plan (Fable research) to use what own Metal/Vulkan backends allow beyond SDL_GPU: 6 phases ~28 PRs; all done 2026-10-31 (last #430 Metal ray tracing)
metadata:
  type: project
  modified: 2026-10-31T09:50:10.064Z
---

Bolt 2026-10-30 (thread "Plan native Metal and Vulkan features"): approved the order 11:48. Doc https://claude.ai/artifact/SxLRNE3chkX2QR8UUvDXfX; research and design notes in /mnt/project-files/notes/native-gpu/ (native-gpu-plan.md step table, plus per-step designs).

Merged:
- Phase 1: #381 caps + Low latency, #383 debug labels, #384 Vulkan present_wait, #386 Android pre-rotation, #396 1.7a Metal presented handlers, #426 1.7b CAMetalDisplayLink (opt-in "Pace with the display (trial)", off).
- Phase 2: #387 20M gpubench, #389 timestamps, #390 parallel CPU culling, #392 shared buffers, #421 GPU culling + drawIndirectCount (on by default, --cpu-cull, --dump-cull). 2.7 8-byte vertices was decided NOT to build (smaller-vertices-design.md): CPU memory is the 50M limit.
- Phase 3: #394 Metal compute, #395 GPU Smooth all default on, #424 3.4 Metal = Automatic on iPad/Mac (SDL_GPU fallback; a failed start moves the setting to SDL_GPU).
- Phase 4: #393 transient depth, #422 4.3 viewport MSAA in tile memory when partial redraw off (--tile-msaa forces it).
- Phase 5: #391 subgroup caps, #399 texture arrays, #400 async compute, #425 async compute on by default (settings v10).
- Phase 6: #404/#407/#409 Vulkan ray query (studio + render mode); #430 6.4 Metal ray tracing (Bolt chose "build it now, off by default" 2026-10-31): mtl_accel.odin, slangc .metal kernels with a slots line, off on Darwin (RAY_QUERY_DEFAULT, settings v11), check runs once before first Metal trace.

Still owed by Bolt (none run on device by Claude): RTX 20M cull_ms and async/RT A/B; iPad week of Metal-as-Automatic; display link Pen to screen A/B; tablet gpubench partial vs tile rows. Metal RT on/off samples-per-second A/B on the iPad (M2 traces in software) + parity_check --tolerance 0.2 on Apple. Plan finished; the cleanup thread (retire SDL_GPU) owns the GPU files next.

Bolt's devices: iPad Air M2, OnePlus Pad (Mali-G710), Windows RTX 3060 Ti. Related: [[apple-target]], [[stack-rebuild-question]].

2026-10-31: SDL_GPU is retired (Bolt approved; thread "Digest pain points and cleanup needs"). Render draws only with its own Metal (Darwin) and Vulkan (elsewhere) backends; no --gpu flag, no Graphics menu, no Metal start guard. Where this file mentions an SDL_GPU fallback or choice, that is history. See [[pain-points-digest]].
