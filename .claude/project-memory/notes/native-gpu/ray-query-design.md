# Ray query for the traced studio and render mode: design (native GPU plan 6.1, G1)

Status: design for review, 2026-10-30. It adds GPU objects (acceleration structures), new buffer usages and two shader variants, so it waits for review.

## What changes for the user
Under the own Vulkan backend, on a GPU with hardware ray tracing (Bolt's RTX 3060 Ti; some recent Android GPUs), the traced studio's shadows and occlusion and render mode's paths trace against the driver's acceleration structures instead of our compute BVH walk. Render mode then converges in fewer seconds, and the studio reaches its samples sooner. Everywhere else the walk runs as today, pixel for pixel. A switch in Settings > System > Graphics ("Ray tracing hardware", on where offered) lets Bolt A/B it, and `--no-ray-query` turns it off for one run.

## Finding that changes the plan
The plan assumed nothing of this runs in the container. It does: Mesa 25.2's lavapipe here offers `VK_KHR_acceleration_structure` and `VK_KHR_ray_query` (`rayQuery = true`, vulkaninfo). So every step is built and checked here, under validation, against the walk; only the speed needs the RTX.

## What exists
- **Geometry on the GPU.** Each mesh's `Mesh_Buffers.positions` (3 floats a vertex) and `indices` (u32), readable by compute where `storage` is true. Hidden triangles are uploaded as degenerate (a repeated corner), and both kernels skip triangles with a repeated corner.
- **Trees.** `Trace_Mesh` (`trace.odin:64`) keeps a CPU-built tree per chunk run, keyed by `geom.chunk_bvh_key`, rebuilt when `index_version` moves and refit on the GPU when only `version` moves, plus a tree over the shown chunks (`tlas_key`).
- **The studio** (`trace_sample`, `trace.odin:161`) dispatches `studio_trace.comp` once per item, in that item's mesh space; each dispatch writes 0 where its triangles block the ray.
- **Render mode** (`path.odin`) copies every traced item's positions and indices into merged scene buffers and builds one tree over every item's chunks in world space; `trace()` in `render_trace.slang` returns the nearest hit: `t` along the world ray, the triangle in the merged index buffer, the item and the barycentrics of the second and third corners.

## Design

### 1. Device and caps (Vulkan)
- Enable, where all are offered: `VK_KHR_acceleration_structure`, `VK_KHR_ray_query`, `VK_KHR_deferred_host_operations` (required by the first), and the Vulkan 1.2 feature `bufferDeviceAddress`.
- `Gpu_Caps.ray_query: bool`. Exit stat `ray_query=`.
- With it on, buffers made with the vertex, index or storage usage also get `SHADER_DEVICE_ADDRESS` and `ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY`, and their memory `VkMemoryAllocateFlagsInfo{DEVICE_ADDRESS}`. Nothing else about buffers changes.

### 2. Seam (`hal.odin`) and backend (`vk_accel.odin`, new)
- `Gpu_Accel` (opaque): an acceleration structure with its buffer.
- `gpu_build_blas(cmd, positions, indices: ^GPUBuffer, ranges: []Blas_Range, update: ^Gpu_Accel) -> ^Gpu_Accel`: one geometry per range (`first_triangle`, `triangle_count`, `vertex_count`), triangles from the index buffer at an offset, vertices from `positions` (`R32G32B32_SFLOAT`, stride 12). `PREFER_FAST_TRACE | ALLOW_UPDATE`. With `update`, refits it in place (`MODE_UPDATE`) and returns it; a range list that differs from the one built is a rebuild.
  - A geometry is `OPAQUE` unless the mesh has hidden triangles (`hidden_stamp != 0`); then it is not, and the kernel rejects candidates with a repeated corner. Vulkan does not promise that a zero-area triangle never reports a hit, so the walk's rule is kept exactly.
- `gpu_build_tlas(cmd, instances: []Tlas_Instance, update: ^Gpu_Accel) -> ^Gpu_Accel`: an instance is a BLAS, a 3x4 transform (the item's model; a similarity, per AGENTS.md) and a 24-bit custom index (the item). Instances go up through a small upload buffer of the command buffer's own.
- Builds are recorded outside passes, in the frame's command buffer, with a barrier from `ACCELERATION_STRUCTURE_BUILD` writes to compute shader reads. Scratch comes from one growing scratch buffer the backend keeps, released by the usual references.
- `gpu_bind_compute_accel(pass, accel)`: binds it at set 3, binding 1 (binding 0 stays the texture array of 5.2). The set-3 layout key gains "has an acceleration structure".
- `gpu_release_accel`, deferred by the command buffers' references like any buffer.
- Lifetimes ride `Vk_Cmd` references, as images and buffers do. Under async compute (5.3) a compute-queue band reading a TLAS built in the graphics frame is already ordered: the band waits for every graphics submission.

### 3. Where the structures live
- **One BLAS per mesh**, in its `Trace_Mesh`, built from the mesh's own `Mesh_Buffers` with one geometry per run the chunk trees use (the same `ranges`), so studio and render mode share it. Keys:
  - `index_version` moved, or the ranges changed: rebuild;
  - only `version` moved: refit (`MODE_UPDATE`), as the chunk trees are refit;
  - neither: kept.
  - Built only where the tracer already brings trees up to date (`trace_prepare`), so only at the first sample of a still view, never while sculpting.
- **The studio's TLAS**: one instance per traced item, with its model transform. The studio then dispatches `studio_trace` once for all items, in world space, instead of once per item: the result ("0 where anything blocks") is the same.
- **Render mode's TLAS**: the same instances, built at the scene build. A hit gives the instance's custom index (the item) and the primitive index within its geometry; the kernel adds the geometry's first triangle (`Item.offs.z`, new, the item's first triangle in the merged index buffer, plus the run's first triangle, read from a small per-item run table) so `Hit.tri` is the same merged-buffer triangle as the walk's.
- **Budget**: BLAS memory counts toward `Tracer.bytes` and the exit stat; on `MOBILE` the same `TRACE_BUFFER_MAX` rule applies to a mesh's BLAS.

### 4. Shaders
- `studio_trace.comp.slang` and `render_trace.slang` keep their walks. A `RAY_QUERY` define replaces `occluded()` and `trace()` with `RayQuery` versions:
  - studio: `RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH`, any hit ends it;
  - render mode: closest hit, `any` mapped to the same flag; `t` is the world ray's parameter (the instance transform keeps the unnormalised direction, as the walk's mesh-space ray does); barycentrics are the second and third corners', as Möller-Trumbore's.
  - Non-opaque candidates (hidden triangles) are confirmed only when their three indices differ.
- New entry files: `studio_trace_rq.comp.slang`, `render_trace_rq.comp.slang` and `render_trace_maps_rq.comp.slang` (with 5.2's array), each `// vulkan only` (no `.msl`; the build quiets the profile warning, as 5.2's does).

### 5. Results and tolerance
- Two ray-query runs give the same pixels: visibility is a yes or no, and the closest hit's ties are resolved the same way by one driver.
- Ray query against the walk is not bit-identical: the driver's intersection test is watertight and Möller-Trumbore is not, so rays through edges and the farthest bounces differ. README states a tolerance for the hardware mode, and `parity_check.py` gains `--tolerance` for the RT cases (the plan's "traced vs gather within ~12/255" style), compared here on lavapipe and on the RTX.
- The walk with ray query off stays 0 px against the build before.

## Steps
- **6.2a** Device features, caps, buffer usages, `vk_accel.odin`, the seam (no caller): ~350 lines.
- **6.2b** Studio: BLAS keys in `Trace_Mesh`, the TLAS, the RQ variant, one dispatch: ~300 lines.
- **6.3** Render mode: the TLAS at the scene build, `Item.offs.z` and the run table, the two RQ variants, the setting and flag, README and sm-render: ~300 lines.

## Checks
- **Here (lavapipe has ray query):**
  - `parity_check.py` at 0 px with `--no-ray-query` and under `--gpu=sdl`.
  - The studio and render cases with ray query on: within the tolerance of the walk, and 0 px between two runs; under `--gpu-debug` with no validation messages, async compute on and off.
  - A sculpt-then-still script: the BLAS is refit (exit stat `blas_refits=`), and a topology change (Remesh) rebuilds it (`blas_builds=`).
  - Hidden triangles (the hide tool): render and studio agree with the walk about the hidden part.
  - `check`, `test`, `smoke`, the cross-compiles.
- **Bolt, RTX:** render mode and studio samples a second with Ray tracing hardware on and off on a 1M and a 10M scene, plus one look that the pictures agree.
- **OnePlus Pad:** whether `ray_query=` is true (Mali-G710 is not expected to have it).

## Not in this step
- Metal (6.4): needs Slang's Metal target for the RQ kernels and `MTLAccelerationStructure`; it waits for this step and for an iPad with hardware RT (an M-series or A17 iPad; Bolt's iPad Air M2 would run Metal RT in software only, UNVERIFIED speed).
- Live AO and anything during strokes: acceleration structures are built only for still views.
- Compaction of BLAS memory (`COPY_MODE_COMPACT`): a follow-up if the RTX's memory says so.

## Questions for the review
1. One BLAS per mesh with a geometry per chunk run, or per chunk run (more structures, finer refits)?
2. The studio as one world-space dispatch over a TLAS: any reason to keep one dispatch per item?
3. Non-opaque geometry only for meshes with hidden triangles: enough, or should hidden triangles be dropped from the BLAS's ranges instead (a rebuild whenever hiding changes)?

## Review (sm-architect, 2026-10-30): approve with changes, all taken
- **BLAS key:** `index_version`, `hidden_stamp`, the shown runs, and each geometry's opacity. Any change rebuilds; only `version` alone refits (`MODE_UPDATE` forbids changed index values or flags; hidden uploads move `version` only, renderer.odin:1303).
- **Shown runs only:** geometries from `trace_shown`'s runs (HD windows and fully hidden units leave chunks out), merged when contiguous with the same opacity; the shown set is already in the key.
- **Opacity per geometry** from a degenerate-triangle scan in `trace_keys` (dyntopo's unused slots are degenerate too), not from `hidden_stamp` alone.
- **Studio one dispatch:** needs each instance's indices for non-opaque candidates: a per-instance device-address table read with `vk::RawBufferLoad`. Until then, items with a non-opaque geometry keep their own dispatch. The walk keeps per-item dispatches.
- **Set 3:** a variable-count binding must be the highest, so the acceleration structure is binding 0 and the texture array binding 1 in the RQ kernels; `Vk_Set_Key`/`Vk_Compute_Layout_Key` gain it, the pools gain `ACCELERATION_STRUCTURE_KHR`, and `vk_bind_sets` accepts a set 3 with no array.
- **Async compute:** the studio's `trace_prepare` must not refit or release a structure a render band may still read: wait on the band fence first. Binding a TLAS adds every BLAS it instances to the command buffer's references.
- **Memory:** sized from `vkGetAccelerationStructureBuildSizesKHR` (structure + build and update scratch), an explicit MOBILE budget, scratch shrunk after a still-view build; with ray query on, the CPU chunk trees and render mode's Nodes/Order copies are skipped. Any failure sends the whole view to the walk.
- **Device-address usage** only on Mesh_Buffers positions and indices and the structure, instance and scratch buffers; the allocate flag at every allocation site for those.
- **Steps:** 6.1a backend (features, caps, `vk_accel.odin`, seam with not-offered answers elsewhere, a `--gpu-debug` self-test building a BLAS and TLAS of a fixture); 6.1b studio with the setting, `--no-ray-query`, README, `ray_query=` and the store check; 6.1c render mode.
- **Determinism:** two runs are 0 px only over identical structures; a refit and a fresh build may settle ties differently, so README promises a tolerance, and both paths are tested against it.
- **Answers:** one BLAS per mesh, a geometry per merged shown run; the studio as one world-space dispatch once instance indices are reachable; hidden triangles stay in place as degenerates.
- **Optional, taken:** `offs.z` points at a per-item list of shown chunk ids, so `Hit.tri = chunks[id].z + PrimitiveIndex()` with the existing Chunks buffer; rebuild after N refits; a full barrier after each build; the instance buffer with build-input and device-address usages, 16-byte aligned, transforms row-major.
