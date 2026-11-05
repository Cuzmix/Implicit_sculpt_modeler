---
name: gpu-own-model-testing
description: How each GPU abstraction step (G1-G7) is verified on Linux: smoke, validation script, GPU sculpt, parity, A/B, gotchas
metadata:
  type: project
---
Used for every PR of [[gpu-own-model]].
A/B on SwiftShader 2M is noisy (+-4%, ui_ms moves too): compare untouched stats.
GPU sculpting is tested here with --gpu-sculpt (scripted runs default to CPU). G4 #599 (done before G2c): gpu.submit -> (Ticket{value,queue}, ok), gpu.done/wait(..)/wait_on; Fence gone; WebGPU own timeline (answers per submission); render.Ticket/cmd_submit_ticket/ticket_wait; stat gpu_ticket_waits.
Script commands for validation runs: --script="remesh; undo; redo; subdivide; detail_skin 4; ..." (ids = commands.odin names lowercased; undo after level_down fails). Gotcha: render/path.odin uses sdl only on MOBILE (@(require) import); run maccheck/iphonecheck since unused-import errors differ per platform; debug-only code (transient.odin when ODIN_DEBUG) needs the debug build to type-check.
Parity: scripts/parity_check.py --compare <baseline dir> expects 19 ok; screen diffs only at y 114-141 are the readout's live text.
