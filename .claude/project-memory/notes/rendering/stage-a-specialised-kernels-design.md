# Stage A: specialised render kernels (design)

Plan: "Render plan after the Pelz study" (https://claude.ai/artifact/XbF8gpo5XncXTQRoYLfX8M), stage A. Bolt approved the plan on 2026-11-05.

## Evidence first

All four render-mode kernels (`render_trace`, `_rq`, `_maps`, `_maps_rq`) include `render_trace.slang`, which carries every feature as a runtime branch. Compiled for an AMD RX 6700 XT class GPU (Mesa RADV's null device, `RADV_FORCE_FAMILY=navi22`, statistics from `VK_KHR_pipeline_executable_properties`):

| render_trace.comp | VGPRs | Waves per SIMD | Instructions | Inverse throughput |
|---|---|---|---|---|
| today | 128 | 8 | 7090 | 31734 |
| plain sculpt scene (no image environment, no lens, no paint, groups, slots, textures or skin, suns only) | 96 | 10 | 4327 | 18278 |
| only textures and skin off | 96 | 10 | 4877 | 18236 |
| paint, groups and slots on; textures and skin off | 96 | 10 | 5213 | 20641 |
| render_trace_rq today / plain | 144 / 128 | 7 / 8 | 5840 / 3136 | 39937 / 27205 |

Textured and skinned items are what push the kernel to 128 registers; the environment, lens and sphere lights cost instructions but not occupancy. Specialization constants folded by the driver give exactly the statically-compiled numbers, so one SPIR-V file serves every variant. slangc emits them as Metal function constants with the same defaults (`is_function_constant_defined ? value : default`), so one `.msl` serves every variant too. Render mode does not exist on the web (its kernels have no WGSL), so WebGPU is untouched.

## What changes

### A1: feature constants, the general kernel, the stats tool

- `render_trace.slang` declares four constants, all `uint` so Metal sets them with one type:
  - `[vk::constant_id(0)] const uint RT_ITEMS = 0xffffffff`: the item flags any item may carry; each item's flags are ANDed with it, so a bit no item has folds its branches away.
  - `(1) RT_ENV_IMAGE = 1`: an image environment may be bound.
  - `(2) RT_LENS = 1`: depth of field may be on.
  - `(3) RT_SPHERE_LIGHTS = 1`: a point, spot or area light may be on (each is traced as a sphere); 0 means suns only.
- With no constants given every default is "everything", so the kernel is today's: `parity_check.py` at 0 px.
- `gpu.Compute_Pipeline_Desc` gains `constants: []u32`, constant i taking id i. Vulkan passes a `VkSpecializationInfo`; Metal creates the function with `MTLFunctionConstantValues` (type `UInt`, index i); WebGPU refuses a non-empty list (`.Unsupported`).
- `scripts/kernel_stats.py` (Linux): builds a small C program against the system's Vulkan loader into `build/`, creates each named kernel on Mesa's RADV null device with optional constants, and prints a table of registers, waves per SIMD, instructions and scratch. It needs `mesa-vulkan-drivers` and `libvulkan-dev`, which it names when missing. This is how stage A and every later kernel change shows its cost without the hardware.

### A2: variants chosen per run, built off the frame

- At the first sample of a still view, `path_prepare` computes a `Render_Features` key from the scene it just merged: the OR of every item's flags, an image environment bound, the lens radius above 0, any non-sun light on.
- `Path_Render` keeps a small table of variant pipelines by key (the key includes walk or ray query; named or array maps follow the device). A sample uses the variant for its run's key when it is ready, otherwise the general kernel; the switch happens only between samples, so the first render of a scene benefits too. Scripted runs build synchronously, so their images never depend on the compile's timing (built: the folded branches give the same pixels on lavapipe).
- A key not in the table starts a build on its own thread (`core:thread`, not the jobs pool, which sculpting uses; `gpu.compute_build_start`, `_ready`, `_finish`): the backend's driver call only (`vkCreateComputePipelines`; Metal's `newFunctionWithName:constantValues:` and pipeline state). Layouts, modules and the slot table are made on the main thread first, and the finished pipeline enters the handle pool on the main thread when the next frame polls it. So no shared state of ours is touched off the main thread; the drivers allow these calls from any thread.
- A scripted run (`--frames`) builds synchronously, so dumps and parity runs are the same on every machine.
- The table is capped (8 variants a kind); the oldest unused variant is released past it. Variants are released with the path renderer.
- No pipeline cache file of our own: NVIDIA, AMD and Mesa drivers and Metal already keep a shader cache on disk, so a variant compiled once is cheap on the next launch (dropped from the plan when built).

### Stats

Exit stats gain `render_variant=` (the key in use for the last run, hex, or `general`) and `render_variants_built=`.

## Measured by

- `kernel_stats.py` tables in each PR (RADV null device, RDNA2).
- ms per sample from the GPU timestamps, general against specialised, A B A B, on lavapipe here. Bolt's RTX 3060 Ti and iPad numbers are owed by his `try_it.py` run.
- `parity_check.py` at 0 px with the general kernel; a specialised run against the general one on lavapipe, expected 0 px (the folded branches were not taken).

## What it does not do

- No button. The app knows which features the scene uses.
- The studio's trace kernel (`studio_trace.comp`) is left as it is; it is short and measured later with the same tool.
