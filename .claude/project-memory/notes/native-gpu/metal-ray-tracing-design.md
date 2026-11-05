# 6.4 Metal ray tracing: findings and design

Status 2026-10-31: **built and merged (#430), off by default on Apple; unverified on a device.** It is the last open step of the native
GPU plan. Everything it needs was checked from the container. It can only be judged on an Apple
device, and Bolt's iPad Air M2 has no ray tracing hardware.

## Where things stand
- Under the own Metal backend, the studio render and render mode already trace by walking the app's own
  trees (`studio_trace.comp`, `render_trace.comp`, through their committed `.msl`). Their pictures
  match SDL_GPU's.
- Ray queries (6.1a–c, #404/#407/#409) exist only under the own Vulkan backend.
  - `gpu_build_blas`, `gpu_build_tlas`, `gpu_create_compute_pipeline_traced`, `gpu_bind_compute_accel`,
    `gpu_buffer_address` and `gpu_accel_*` answer nil or 0 elsewhere.
  - `Gpu_Caps.ray_query` is false there, so the app keeps the walk.

## Findings
1. **The usual MSL path cannot carry ray queries.** The `.spv` → `.msl` step (SDL_shadercross,
   `scripts/shaders_msl.py`) refuses `studio_trace_rq.comp.spv`: "Acceleration Structure Type is
   supported in MSL 2.3 and above". shadercross pins MSL 2.1 for SDL_GPU, and SDL_GPU cannot bind an
   acceleration structure anyway.
2. **Slang's own Metal target can.** `slangc studio_trace_rq.comp.slang -target metal -entry main
   -stage compute` produces MSL with `raytracing::intersection_query<triangle_data, instancing>` and a
   `acceleration_structure<instancing>` argument. The same works for `render_trace_rq.comp`. So the
   kernels need no rewrite.
3. **Slang numbers the Metal slots its own way.** For example:
   - studio: `instances` buffer(0), `run_first` buffer(1), the structure buffer(2), uniforms buffer(3);
   - render: the structure buffer(0), `positions` buffer(1), `indices` buffer(2), …, uniforms buffer(9).

   The own Metal backend binds as SDL_GPU's Metal does (uniforms first, then read-only, then
   read-write storage). So the two RQ kernels need a slot table of their own. That means a small
   reflection step at build time (slangc `-reflection-json`), committed beside the `.metal`, which
   `mtl_create_compute_pipeline_traced` reads. Explicit `register` bindings in the Slang source do not
   reach the Metal target reliably.
4. **The Metal side of the seam** (`MTL.AccelerationStructure*` is in the Odin bindings):
   - `mtl_build_blas`: an `MTLPrimitiveAccelerationStructureDescriptor` with one triangle geometry per
     `Blas_Geometry`, over the mesh's own position and index buffers, with offsets. It is built or
     refit with an `MTLAccelerationStructureCommandEncoder` (`refitAccelerationStructure` for strokes,
     as Vulkan refits).
   - `mtl_build_tlas`: an `MTLInstanceAccelerationStructureDescriptor` over a buffer of
     `MTLAccelerationStructureUserIDInstanceDescriptor`s, whose `userID` carries `Tlas_Instance.custom`
     (the kernels' CommittedInstanceID), plus the list of bottom levels.
   - At dispatch: `setAccelerationStructure:atBufferIndex:`, and `useResource:` for every bottom level the
     top level names. Metal does not track resources reached only through the top level.
   - `gpu_buffer_address`: `MTLBuffer.gpuAddress` (Metal 3, so Apple7+/M1+).
   - Scratch buffers kept as Vulkan keeps them. Hazards are tracked by Metal, so no barriers.
   - Size: about 450 lines in a new `mtl_accel.odin`, about 80 in the build (slangc Metal target, slot
     table, `shaders_msl.py --check` for the two files), about 50 at the seam and in caps.
5. **What it buys on Bolt's devices.** Apple GPUs from M1/A14 answer `supportsRaytracing`, but the M2
   traces in software (shader code Apple supplies). Hardware ray tracing came with M3 and A17 Pro.
   - On the M2 it would replace the app's tree walk with Apple's software walk. That might be a little
     faster or slower; it is UNVERIFIED either way.
   - It would also save the CPU time of building the app's trees (about 0.4 s for three 100k spheres
     here). The driver's structures cost more GPU memory, which an iPad has less of.
6. **Risk.** None of it can run here: no Metal. A slot-table or descriptor mistake compiles and fails
   only on the device.
   - Built now, it would ship behind the existing Ray tracing hardware switch, offered under Metal only
     with `supportsRaytracing`.
   - It would need its own crash guard, or would start off, until an Apple run of `parity_check.py
     --tolerance 0.2` passes on the studio and render cases.

## Recommendation
Wait for an Apple device with hardware ray tracing (an M3/M4 Mac or iPad, or an A17 Pro iPad mini).
There, building this pays off clearly, and it can be checked the same day. On the M2 the walk already
works, and the gain is unknown.

If Bolt wants it now, build it as above, off by default. On the M2, compare samples per second with
it off and on in Stats before turning it on anywhere.
