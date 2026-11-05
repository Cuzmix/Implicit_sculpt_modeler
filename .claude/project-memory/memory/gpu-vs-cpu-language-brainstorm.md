---
name: gpu-vs-cpu-language-brainstorm
description: 2026-11-04 answer to Bolt: is GPU sculpting better on mobile, and should we rewrite in Go/Rust/C++; Go vs C vs Rust dab microbench numbers
metadata:
  type: project
  modified: 2026-11-04T15:43:57.326Z
---

Thread "Choose GPU vs CPU and language for sculpting" (2026-11-04), brainstorm only, Bolt said a rewrite is on the table.

- GPU vs CPU answer: GPU win on desktop comes from GDDR bandwidth (3060 Ti 25M: CPU/frame 4.1 -> 2.4-2.8 ms); on iPad M2 / Mali-G710 unified memory CPU and GPU share 60-100 GB/s and dabs are memory-bound, so the gap shrinks; GPU path adds a CPU mirror (memory, cf. [[dense-remesh-memory-plan]]) and shares the thermal budget. ZBrush/Blender/3D-Coat (and likely Nomad) sculpt on CPU. No tablet numbers yet: recommended `try_it.py gpu_sculpt_10m` on both tablets, then Automatic picks CPU/GPU per device by mesh size.
- Microbench (container, 4 cores, Draw-like dab over 10M SoA vertices, best of 10): C/clang -O3 (Odin proxy, both LLVM) 17.5 ms 1 thread / 6.6 ms 4 threads; Rust 18.9 / 7.1; Go 1.24 32.1 / 8.5. Go ~1.8x slower single-thread (no autovectorisation), Go wasm has no threads, cgo per GPU call.
- Recommendation given: not Go; if ever rewriting, Rust (C++ second); but keep Odin, a rewrite buys no speed. Real Odin cost: AI writes old-Odin from memory (hence pinning). Related: [[stack-rebuild-question]], [[gpu-sculpt-plan]].
