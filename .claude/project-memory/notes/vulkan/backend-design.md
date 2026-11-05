# Vulkan backend: design (2026-10-28)

Thread "Prepare renderer for Vulkan and Slang". Bolt chose: build it right after the text cache (#241) and the GPU
boundary PR; a Settings > System > Graphics dropdown (Vulkan | SDL_GPU, applied on restart); Vulkan the default on
Windows, Linux and Android once it matches SDL_GPU's images here; SDL_GPU stays as the fallback and as the only
backend on Mac and iPad (Metal) until a Metal backend exists. Merge after the full gate, no Windows wait.

## Why
SDL_GPU caps every stage at 8 storage buffers and 16 samplers (render mode uses 8/8 and 14/16), has no bindless
resources and no ray tracing. The real-time Render plan (rendering thread, stage 3) needs all three.

## Options compared
| Option | RT | Bindless | Effort | Risk |
|---|---|---|---|---|
| A. HAL inside `render` mirroring SDL_GPU's model, two implementations (SDL_GPU passthrough, Vulkan), chosen at device creation | yes (Vulkan) | yes | high | parity bugs, caught by image diffs |
| B. Rewrite `render` directly on Vulkan, drop SDL_GPU | yes | yes | highest | no fallback, no Mac/iPad |
| C. SDL_GPU plus Vulkan interop for RT only | partial | no | medium | SDL 3.4 exposes no native handles to share; two devices |
| D. wgpu-native / Dawn | experimental | experimental | high | WebGPU limits, extra validation, C++/Rust toolchain |

Pick A: the render code ports mechanically (each `sdl.X` becomes `gpu_x`), both backends draw the same frames from the
same SPIR-V, and image diffs prove parity pass by pass.

## Shape
- All of it stays in `src/render` (the boundary check keeps the GPU API there). New files:
  - `hal.odin`: backend-neutral handles (`Gpu_Buffer`, `Gpu_Texture`, `Gpu_Sampler`, `Gpu_Shader`, `Gpu_Graphics_Pipeline`,
    `Gpu_Compute_Pipeline`, `Gpu_Transfer_Buffer`, `Cmd`, `Fence`, pass handles) as small structs holding either
    backend's object, and procs named after SDL_GPU's (`gpu_create_texture`, `gpu_begin_render_pass`, ...) that switch on
    `Renderer.backend`. Info structs reuse SDL's (`sdl.GPUTextureCreateInfo` etc.) so the port changes call names, not
    arguments, and the SDL path costs one switch per call.
  - `vk_device.odin` (instance, device, queues, features, debug messenger), `vk_memory.odin` (dedicated allocations
    first; a block sub-allocator only if the allocation count shows up), `vk_resources.odin` (buffers, textures,
    samplers, transfer buffers with cycling), `vk_cmd.odin` (command buffers, passes, barriers, uniforms, descriptors),
    `vk_pipeline.odin`, `vk_swapchain.odin` (per window, present modes, resize, out of date).
- Bindings: SDL's SPIR-V conventions kept so today's .spv files work unchanged: graphics vertex set 0 (sampled textures,
  storage textures, storage buffers) and set 1 (uniforms), fragment sets 2 and 3; compute set 0 read-only, 1
  read-write, 2 uniforms. Set layouts come from the counts each shader is created with. Descriptors: push descriptors
  (VK_KHR_push_descriptor) where offered, else a per-frame descriptor pool reset when that frame's fence signals.
  Pushed uniforms go to a per-frame ring buffer bound with dynamic offsets, as SDL does.
- Synchronisation: one graphics+compute queue; passes are ordered as SDL orders them, with a conservative barrier
  between passes and per-texture layout tracking (sync2). Correct first; narrower barriers only if a GPU capture shows
  them mattering.
- Lifetimes: SDL_GPU lets the app release anything at any time; Vulkan destroys it once the last submission that used
  it has finished (a timeline semaphore value per submission, a deferred-destroy list). Transfer buffers mapped with
  `cycle` rotate to a backing buffer the GPU is not reading, as SDL's do; textures and buffers written by the GPU only are
  ordered by barriers instead of cycled.
- Required: Vulkan 1.3 core (dynamic rendering, synchronization2, timeline semaphores) plus the features the shaders use.
  A device without them is not picked and the app uses SDL_GPU, saying why (log, Stats, the dropdown's note).
- SDL3 still makes windows and gives the instance extensions and the surface (`SDL_Vulkan_*`).

## Settings
`graphics` setting (Auto | Vulkan | SDL_GPU, applied on restart), Settings > System > Graphics dropdown listing only what
the platform has, `--gpu=auto|vulkan|sdl`. Auto = Vulkan on Windows, Linux, Android when the device qualifies, else
SDL_GPU; Mac/iPad only SDL_GPU. Exit stat `gpu_backend=` and the reason when it fell back.

## PRs
1. HAL with the SDL_GPU implementation only; every `sdl.*GPU*` call in render goes through it. Pixel-identical.
2. Vulkan core: device, swapchain, command buffers, copy passes, buffers, textures, samplers, render passes, graphics
   pipelines, push uniforms, scissor, indirect draws: the interface and the mesh viewport draw under `--gpu=vulkan`.
3. Vulkan rest: compute, MSAA resolve, mipmaps, texture-to-texture copies, downloads and readbacks, view windows, every
   remaining pass; the parity battery passes.
4. Dropdown, Auto, fallback, Vulkan default on Windows/Linux/Android; README and skills.
5. Afterwards, Vulkan-only capabilities the Render plan needs (more bindings per stage, bindless maps, ray query), each
   with an SDL_GPU fallback path.

## Verification
- A parity battery script: the same scene and flags under both backends, `ppm.py diff` (dump-viewport and dump-screen)
  for default, MSAA x4, studio, render mode, live AO, environment, textured, wireframe, see-through, nav head,
  thumbnails, second view. Target 0 px; any non-zero diff is explained (driver rounding) or fixed.
- `smoke` under Vulkan with the Khronos validation layer (apt `vulkan-validationlayers`): zero validation messages.
- The gate (check, tests, build, smoke, touch, wincheck, androidcheck) for both backends where it applies.
- lavapipe (Mesa 25.2) offers Vulkan 1.4, push descriptors, ray query and acceleration structures, so all of it runs here.

## Architect review (2026-10-28): changes taken
- SDL_GPU here is already SDL's Vulkan backend (SPIR-V only), so parity on the same driver should be 0 px; there are
  no MSL shaders, so the Mac/iPad path needs the Slang port's Metal output before it exists at all.
- Compute set 0 is samplers, then read-only storage textures, then read-only storage buffers (render mode binds samplers).
- Uniforms belong to the command buffer, not the pass (pushed before a loop of passes): uniform ring and descriptor
  pools per command buffer (4 slots per stage, 32 KB each, as SDL).
- Command buffers are recorded out of submission order (present_cmd open while matcap/env cmds are submitted), so use
  SDL's default-usage layouts (every pass returns each resource to its default layout), not CPU-side layout tracking.
- Cycling covers GPU-written textures (render, depth, resolve targets) and the indirect buffer too: implement real
  cycling (rotate backing resources) like SDL; cycle=false sites (thumbnail atlas, uploads read by the previous frame)
  need write-after-read barriers.
- Swapchain: waiting and non-waiting acquire (nil texture when none free, then the cmd is cancelled), per-window present
  mode and SDR, UI pipeline from the swapchain format; Android: IDENTITY pre-transform, ignore SUBOPTIMAL, recreate on
  SURFACE_LOST at acquire and present.
- Windows need SDL_WINDOW_VULKAN: the backend is chosen before any window, via a render proc supplying the flag.
- Optional features: Android lacks clip distance, anisotropy, indirect first-instance; loop draws when multiDrawIndirect
  is missing; wireframe needs fillModeNonSolid; format/sample-count queries with D32 -> D24 fallback.
- Per-subresource layouts for mip rendering and GenerateMipmaps; depth sampled in compute; MSAA depth image copy;
  clear-only and depth-only passes; non-waiting fence query; barriers between compute passes too.
- Unbound-sampler check in the HAL (debug) for both backends; a test reading every embedded .spv's decorations
  against the counts it is created with.
- PR 1 also carries the parity battery (SDL vs itself, two runs, 0 px) and HAL handles in gpu.odin. PR 2 also takes
  fences, mipmaps, downloads and the window flag (needed by renderer_init and every image diff). PR 3 splits compute
  (render mode, trace, smooth) from the remaining passes.
- Tests the parity battery cannot see: swapchain (dump-screen draws offscreen) needs a manual desktop session and an
  androidrun session; Android Vulkan 1.3 is required, else fallback with a logged reason (check gpu_backend= on the tablet).
- Defaults: 2 frames in flight; Mac out of scope until Metal shaders exist.
