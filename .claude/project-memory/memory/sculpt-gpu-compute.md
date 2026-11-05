---
name: sculpt-gpu-compute
description: GPU compute trial (PR #33, 2026-10-25): Smooth all as SDL_GPU compute shader vs CPU, computebench, results and next steps
metadata:
  type: project
  modified: 2026-10-25T07:15:02.081Z
---

Bolt asked (2026-10-25) whether sculpting is CPU or GPU and which is better long term (vs Sculptron, 3DCoat, ZBrush, Nomad). Answer given: CPU core (like ZBrush/Nomad), move heavy whole-mesh ops to GPU compute when limits hit. Bolt said "Sure" to a trial.

- PR #33 merged into odin-sculpt: Tools > Deformation > Smooth all (whole-mesh smooth, mask-aware, one undo step, not with dyntopo) + "On the GPU" checkbox (off by default; `--gpu-smooth`, `--smooth-all=N`). Shader src/render/shaders/smooth_all.comp, host src/render/smooth_compute.odin; sculpt side src/sculpt/smooth_all.odin via `Smooth_Gpu` callback (sculpt never imports render).
- `build.bat computebench` writes build/computebench.md: CPU vs GPU at 500k-10M, 1 and 10 steps, GPU split upload/compute/readback, cold (topology uploaded) vs warm (resident), max diff vs CPU.
- On the VM's llvmpipe the GPU result is bit-identical to the CPU (precise + same op order). VM CPU (4 threads): 10M 10 steps 560 ms. GPU timings on VM are meaningless.
- Waiting on Bolt's Windows RTX 3060 Ti computebench run. Expected (estimate, unmeasured): GPU wins clearly at many steps; at 1 step upload+readback (~150 MB warm at 10M) eats the gain. Next step if it wins: keep the mesh resident on the GPU (render vertex buffer with compute usage) so only readback remains.
