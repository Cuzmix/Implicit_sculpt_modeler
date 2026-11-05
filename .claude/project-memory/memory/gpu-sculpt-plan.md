---
name: gpu-sculpt-plan
description: GPU-resident sculpt pipeline (2026-11-03) for 20M+ meshes: design B, PR series behind --gpu-sculpt (P1 #526, P2 #533, P3 #539 #544 #547 #563, P4a #577 merged), doc URL, decisions, baseline numbers
metadata:
  type: project
---

Plan doc: https://claude.ai/artifact/WgXMUpaNXKbQHNbyMwB75j (Claude Doc, 2026-11-03). Bolt picked option 1 (full GPU sculpt pipeline) from the coordinator's list after the 25M study ([[perf-25m-study]]).

**Design B chosen** over A (GPU normals only), C (full residency), D (mesh shaders), E (more CPU tuning): the GPU runs dabs (area, displace, Smooth), normals, bounds, cones and the cull records; the CPU keeps raycast, hit nodes and undo on a positions mirror lagging 1–2 frames (readback ring of dirty ranges), stroke end waits so the mirror is exact between strokes. Per-stroke choice CPU/GPU in `apply_dab`; dyntopo, skin, cloth, Grab/Elastic/Hook, paint, curve strokes stay CPU. `Stroke_Gpu` callbacks in `sculpt`; kernels in `render/sculpt_gpu.odin` behind hal. Adjacency CSR on the GPU 28 B/vertex (700 MB at 25M), compact 14 B form in P7. Switch `--gpu-sculpt` / Stats > Drawing "Sculpt on the GPU", off by default until P7; `--gpu-sculpt-sync` for exact A/B.

**PR series:** P1 = harness + flag + GPU normals + CSR, #526. P2 = dab kernels + readback of positions/heights + replay fallback, #533. P3 groundwork #539 (exact tree, split readback, per-kind margin: 25M CPU 60 -> 23 ms a frame); #544 positions-only readback mid-stroke (23.7 -> 16.5 ms); #547 node bounds kernel node_bounds.comp.slang (16.5 -> 10.6 ms, landing 2.9 -> 0.25); #563 lookup slice-a-frame (Bolt PC 25M brush p99 122->1.2 ms); cones skipped by Bolt; P4 split after review (notes/gpu-sculpt/p4-design.md): P4a masks+drawn falloffs #577, P4b HD windows (fade) #579 (Vulkan RO compute bindings 8->16, dab kernels 9 RO + 5 RW), P4c alphas #580 (alpha in tables buffer, uploaded once a stroke; areas 5 float4s, record 9) -- P4 complete 2026-11-03; P5 Metal offered #582 (fixed MSL slot bug: shadercross numbers RW after RO the kernel reads; dab.slang keep_bindings; shaders_msl --check catches gaps), untested on Apple device; P6/P7 #583 merged 2026-11-03: workgroup>=256 gate, lookup budget (1/4 card memory, 1/8 unified; past it the mesh stays CPU), on by default (Bolt chose everywhere offered, #588), --cpu-sculpt, try_it gpu_sculpt_10m. Skipped: UMA zero-copy readback (GPU frames ahead, bounds would not match positions); compact 14 B lookup deferred (16-bit node-local ids overflow at node borders). Series complete; awaits Bolt device runs. Branch `claude/project-thread-df8tpw`, self-merge to odin-sculpt. Facts and gotchas: [[gpu-sculpt-facts]].

**Baseline (container, 4 threads, bcbb3f9):** 25M Draw r=0.13 dab 0.52 ms, normals 1.02 ms/frame, frame 3.07 (p99 4.9), upload 2.74 MB/frame. RTX 25M stroke: GPU 1.24, CPU 3.47 (brush 0.89, normals 0.55, ui 0.68).

**Why:** the CPU is the stroke wall 3:1 at 25M. **How to apply:** CPU path stays the test oracle; never touch Low latency pacing; verify on a real GPU (Bolt's PC) before P7 default-on.
