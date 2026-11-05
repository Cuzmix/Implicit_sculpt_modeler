# Native GPU plan: what Sculpt's own Metal and Vulkan backends should give users beyond SDL_GPU

Written 2026-10-30 from the repository at commit `3bbb31f` ("Offer Metal (trial) in Settings > Graphics"), the pinned SDL `release-3.4.18` source in `deps/sdl3-src`, the pinned Odin bindings in `deps/odin/vendor`, Apple's and Android's developer pages where they could be fetched, and SDL's GitHub issues and pull requests. Nothing in the repository was edited. Every claim marked UNVERIFIED is one I could not check from here; everything else cites the file or page it comes from.

## 0. Summary

- The two levers users feel first, Pencil latency and stroke frame rate on big meshes, do not need most of the headline features. They need frames in flight set to 1 (SDL_GPU has had `SDL_SetGPUAllowedFramesInFlight` since 3.2.0 and `hal.odin` does not expose it; both own backends hard-code 2), present timing on each platform (not in SDL, own backends), and on Android pre-rotation (SDL deliberately leaves the compositor to rotate; own Vulkan backend). Zero-copy brush uploads, named to Bolt as a Metal win, move about 0.6 MB a frame at 10M vertices (README bench, 39k vertices a dab x 16 bytes) and are not where the time goes; unified memory pays off for loads and GPU compute round trips, not strokes.
- GPU Smooth all on the iPad does not need our Metal backend's compute stage. SDL_GPU's Metal driver accepts precompiled `.metallib` shaders beside MSL source (`SDL_GPU_SHADERFORMAT_METALLIB`, `deps/sdl3-src/src/gpu/metal/SDL_gpu_metal.m:867-878`, formats `MSL | METALLIB` at `:4675`), and `./build.sh ios` already runs every `.msl` through `xcrun metal` (`build.sh:193-203`). Compiling `smooth_all.comp.msl` with fast maths off into a metallib gives precise maths on SDL_GPU and on our backend alike. SDL compiles MSL source with `options:nil` (`SDL_gpu_metal.m:864-866`), and Apple documents `fastMathEnabled`'s default as true, which is why bit-exact smoothing is off on Darwin today (README line 264).
- SDL has no newer release than the pin (its releases page lists 3.4.18 of 2 Oct as the newest; `WhatsNew.txt` on `main` has no header past 3.4.0). The features SDL is working on that matter here are a draft timestamp/occlusion query API (PR #15651, Vulkan proof of concept only) and an opt-in low-latency present (issue #15656, milestone moved from 3.6 toward 3.8). Nothing in SDL's tracker plans ray tracing, bindless resources, mesh shaders, async compute, memoryless targets, unified memory (#14354 closed "not planned") or Android pre-rotation. So the own backends remain the only route to those, and the plan below gives each one an SDL_GPU fallback.
- One design per feature, keyed by a `Gpu_Caps` struct render fills at device creation and the app reads; each capability has one Vulkan answer and one Metal answer behind `hal.odin`'s procs, and `false` means today's path. The seam, `boundary_check.py` and the package boundaries in AGENTS.md section 5 stay as they are.
- Phases: (1) latency and pacing, (2) stroke speed and uploads at 20M+, (3) compute on Apple (metallib precise maths, then Metal compute in our backend), (4) memory on tablets (transient MSAA, load/store actions), (5) large scenes (GPU culling, descriptor indexing for textured render mode, async compute), (6) ray tracing (Vulkan ray query, then Metal). Every Metal step waits for Metal (trial) to draw correctly on Bolt's iPad; every step says what Bolt checks and on which device.

## 1. Where the code stands (facts the plan builds on)

| Fact | Where |
|---|---|
| 67 `gpu_*` procs form the seam; each hands to `vk_*` under `.Vulkan`, to `mtl_*` under `.Metal` inside `when METAL`, else SDL | `src/render/hal.odin` (622 lines; `grep -c "^gpu_[a-z_]* :: proc"` = 67) |
| Vulkan backend 2,507 lines (`vk_cmd` 953, `vk_resources` 800, `vk_device` 460, `vk_swapchain` 294); needs 1.3 + dynamicRendering + synchronization2 + timelineSemaphore + independentBlend, else falls back | `src/render/vk_device.odin:119-126` |
| Only `KHR_swapchain` is enabled as a device extension; the only features asked beyond SDL's are none | `vk_device.odin:236-268` (features), `:261` (extensions) |
| Metal backend 1,523 lines (`mtl_cmd` 581, `mtl_resources` 562, `mtl_device` 234, `mtl_swapchain` 146); no compute pipelines (`mtl_create_compute_pipeline` returns nil) | `src/render/mtl_resources.odin:557-560` |
| Metal shaders compiled from MSL source with nil options, exactly as SDL does | `mtl_resources.odin:300`; SDL `SDL_gpu_metal.m:864` |
| Frames in flight: `VK_FRAMES :: 2`, `MTL_FRAMES :: 2`; SDL's default 2, cap 3 | `vk_device.odin:20`, `mtl_device.odin:23`, `deps/sdl3-src/src/gpu/SDL_gpu.c:3298-3300` |
| Metal swapchain: `CAMetalLayer`, `nextDrawable`, `presentDrawable` on the command buffer, `displaySyncEnabled` on the Mac only, no `maximumDrawableCount` set (default 3) | `mtl_swapchain.odin:41-46, 128-146`; `mtl_cmd.odin:141` |
| Vulkan swapchain: FIFO for vsync, `preTransform` identity where offered (no pre-rotation), as SDL does on Android | `vk_swapchain.odin:92-93`; SDL `SDL_gpu_vulkan.c:4782-4786` |
| Metal buffers private, transfer buffers shared (write-combined for uploads); textures private, never memoryless | `mtl_resources.odin:95, 103, 183` |
| Vulkan buffers DEVICE_LOCAL, uploads HOST_VISIBLE|COHERENT, images DEVICE_LOCAL; no TRANSIENT/LAZILY_ALLOCATED | `vk_resources.odin:191-193, 350` |
| The frame: `frame_pace` (vsync/limit) → fence → `cmd_begin` → `swapchain_acquire(wait = true)` → events → sculpt → uploads → `render_viewport` → submit `cmd` → interface pass on `present_cmd` → submit; `latency_ms` = newest input to the submit | `src/app/main.odin:878-887, 1308-1374` |
| Brush uploads: ranges packed into a 16 MB cycled transfer buffer, one copy pass; `upload_kb` = dirty vertices x 16 B | `src/render/renderer.odin:252, 1033-1089` |
| Culling on the CPU writes one indirect command per visible chunk run (`NODE_TRIANGLES 1024`, `CHUNK_GROUP 64`); one indirect draw per item | `renderer.odin:1507-1560`; `src/sculpt/brush.odin:24`; `src/geom/visibility.odin:119` |
| Traced studio and render mode: CPU-built chunk BVHs refit on the GPU, a compute walk per sample; `TRACE_BUFFER_MAX` 128 MB and `RENDER_SCENE_MAX` 256 MB on tablets | `src/render/trace.odin:1-60`, `src/render/path.odin:54-60` |
| GPU Smooth all: compute trial, upload / dispatch / readback each waited; bit-identical to the CPU on llvmpipe (`build/cb.md`: max diff 0); not offered on Darwin | `src/render/smooth_compute.odin`; README line 264 |
| `--time-gpu` measures GPU time by serialising frames | `main.odin:1308-1320` |
| Android asks the display for a rate with `ANativeWindow_setFrameRate`; no Choreographer, no present feedback | `android/app/jni/android_main.c:109-133`; `src/app/frame_rate.odin:157-169` |
| iPad: Pencil coalesced samples bridged from UIKit; the app loop runs inside `SDL_RunApp` on UIKit's main thread | `src/app/pen_samples.odin`, `src/app/ios.odin:60-74` |
| Minimum OS: iPadOS 17.4, macOS 14.4 | `build.sh:105, 127` |
| Odin bindings cover Metal acceleration structures (419 hits), counter sample buffers, memoryless, `presentsWithTransaction`, `setMaximumDrawableCount`, `supportsRaytracing`, `hasUnifiedMemory`; not `CAMetalDisplayLink` (0 hits). Vulkan: ray query, acceleration structures, `CmdWriteTimestamp2`, `GOOGLE_display_timing`, `KHR_present_wait`, descriptor indexing, mesh shaders, int64 atomics; not `VK_EXT_present_timing` | `deps/odin/vendor/darwin/{Metal,QuartzCore}`, `deps/odin/vendor/vulkan` |
| The Metal design doc's five stages: 1 mirror (merged), 2 compute/copies/mipmaps/readback/timing + menu, 3 parity on the iPad and Automatic = Metal, 4 exact maths and precompiled metallib, 5 ray tracing and argument buffers | the Claude Docs document "Metal backend for Sculpt: design" (read through the Docs connector) |

## 2. What SDL_GPU already has or plans

What I could check: the pinned `release-3.4.18` source and header in full; SDL's releases page, `WhatsNew.txt` and `SDL_gpu.h` on `main` (through raw.githubusercontent.com); individual issue and PR pages on github.com; GitHub's issue and PR search for `libsdl-org/SDL`; the SDL_GPU wiki FAQ; SDL_shadercross's header and recent commits on `main`. What I could not: `gh api` and the GitHub connector refuse every repository but this project's, so I could not list releases or read the Metal and Vulkan driver sources on `main` directly; `main`'s driver code may hold changes the header and WhatsNew do not show. The header on `main` carries no `\since` newer than 3.4.0 and WhatsNew no 3.6 section, so what follows treats `main` as 3.4.18 plus bug fixes unless a PR says otherwise.

| Benefit | SDL_GPU status | Links | Recommendation |
|---|---|---|---|
| Frames in flight 1 (one frame less latency) | In 3.2.0: `SDL_SetGPUAllowedFramesInFlight(device, 1..3)`; default 2; not exposed by `hal.odin`. Issue #14791 says SDL still shows one frame more than D3D11 on D3D12/Vulkan; open | `deps/sdl3-src/include/SDL3/SDL_gpu.h:4223`; https://github.com/libsdl-org/SDL/issues/14791 | Use SDL's on the fallback; add `gpu_set_allowed_frames_in_flight` to the seam, answered by `VK_FRAMES`/`MTL_FRAMES` becoming per-window values |
| Low-latency present (present-wait, presented-time feedback) | Open proposal #15656 (opened 2026-05-19, milestone 3.6, maintainer said it may slip to 3.8): D3D12 waitable object, Vulkan `VK_KHR_present_wait`/`GOOGLE_display_timing`, Metal `addPresentedHandler`. Not in any release | https://github.com/libsdl-org/SDL/issues/15656 | Own backends now (section 4.A); when SDL ships it, the fallback gains it through the same cap flag |
| ProMotion pacing (`CAMetalDisplayLink`) | Not in SDL, not proposed | wiki FAQ (no mention) | Own Metal backend |
| Android pre-rotation | SDL sets `preTransform = IDENTITY` on Android on purpose; #12950 (orientation swapchain loop) closed as a bug fix, not pre-rotation | `SDL_gpu_vulkan.c:4782-4786`; https://github.com/libsdl-org/SDL/issues/12950 | Own Vulkan backend |
| Android frame pacing (Choreographer) | Issue #15013 open, milestone 3.8.0, no implementation | https://github.com/libsdl-org/SDL/issues/15013 | Own: `VK_GOOGLE_display_timing` feedback in the Vulkan backend plus the existing `setFrameRate` |
| Precise-maths Metal shaders | SDL compiles MSL with `options:nil` (fast maths), but accepts `SDL_GPU_SHADERFORMAT_METALLIB` (3.2.0) beside MSL, so a metallib compiled by us with fast maths off runs under SDL_GPU. SDL_shadercross offers no maths option (only `SDL_SHADERCROSS_PROP_SPIRV_MSL_VERSION_STRING`, default 1.2.0) | `SDL_gpu_metal.m:864-878, 4675`; shadercross header on `main` | Use SDL's: ship `.metallib` for the shaders that must be exact (section 4.C). Our Metal backend loads the same metallib with `newLibraryWithData` |
| Compute on Metal | In SDL_GPU since 3.2.0 (our `smooth_compute.odin` runs on it on a Mac today, only the maths differ) | `SDL_gpu.h:2645` | Use SDL's for the fallback; our Metal backend's compute (design stage 2) is still needed for parity, not for the feature |
| Unified memory / zero-copy buffers | #14354 closed "not planned" 2025-10-29: SDL keeps every transfer on the GPU timeline | https://github.com/libsdl-org/SDL/issues/14354 | Own backends, where it pays (loads, compute round trips); not for strokes |
| Memoryless / transient targets, own load and store actions | Not in SDL; textures are `MTLStorageModePrivate`, Vulkan images DEVICE_LOCAL; no issue found | `SDL_gpu_metal.m:1457`; `SDL_gpu_vulkan.c` | Own backends (one design: Metal memoryless, Vulkan transient + lazily allocated) |
| GPU timestamp queries | PR #15651 "GPU: Query API" draft: timestamps and occlusion, Vulkan proof of concept, D3D12 and Metal to do, last activity 2026-07-04; issue #11452 (profilers) open | https://github.com/libsdl-org/SDL/pull/15651 ; https://github.com/libsdl-org/SDL/issues/11452 | Own backends now behind a cap flag; swap the fallback to SDL's API when it lands |
| Debug labels and groups (for Xcode capture, RenderDoc) | In 3.2.0: `SDL_InsertGPUDebugLabel`, `SDL_PushGPUDebugGroup`, `SDL_SetGPUTextureName`; `hal.odin` wraps none of them | `SDL_gpu.h:2956-3048` | Use SDL's; add three seam procs with Vulkan (`VK_EXT_debug_utils`) and Metal (`pushDebugGroup`, `label`) answers |
| Native handle access | Issue #10876 open since 2024, maintainers against beyond a narrow debugging subset | https://github.com/libsdl-org/SDL/issues/10876 | Not coming; the own backends are the answer |
| Hardware ray tracing | FAQ: no immediate plans for "bleeding-edge" features; no issue or PR | https://wiki.libsdl.org/SDL3/CategoryGPU | Own backends |
| Bindless / descriptor indexing | API has fixed slots per stage; `SDL_GPUVulkanOptions` (3.4.0) can enable `descriptorIndexing` on the device but the binding API cannot use arrays | `SDL_gpu.h:2415-2424`; PR #14204 | Own backends, only where a feature needs it (textured render mode) |
| Subgroup ops, 64-bit atomics, other SPIR-V capabilities | `SDL_GPUVulkanOptions` (3.4.0) lets the app raise the API version and enable features such as `shaderBufferInt64Atomics` (SDL checks them, `SDL_gpu_vulkan.c:11595-11625`); issue #15946 reports `feature_list` contents ignored (UNVERIFIED whether fixed in 3.4.18) | PR https://github.com/libsdl-org/SDL/pull/14204 | Use SDL's options for the fallback; our Vulkan backend enables the same features |
| Async compute queue | Single queue; nothing planned | - | Own backends |
| Mesh shaders | FAQ: no immediate plans | wiki FAQ | Not planned here either (section 4.E) |
| Sampling multisample textures | PR #15838 "Allow multisample textures to be read" merged 2026-09-14; the pin still asserts "Multisample textures cannot be bound as samplers!" (`SDL_gpu.c:2110`), so it is on `main` only | https://github.com/libsdl-org/SDL/pull/15838 | A future SDL would let the interface sample the MSAA viewport directly; not needed by this plan |
| Buffer <-> texture copies, pipeline caches, WebGPU backend, multiview | PRs #16249 (draft), #11629 (open), #16020 (open), #16350 (draft) | github.com/libsdl-org/SDL/pull/… | None needed; #16020 is the route to the README's "WGSL later" |

Upgrading SDL: nothing above needs it today, since no release is newer than the pin. The two to watch for a bump are #15656 (low-latency present) and #15651 (queries); each lands behind the same cap flag the own backends already set, so the fallback gains it with a pin change and no app code.

## 3. One design for both backends

### 3.1 `Gpu_Caps`

A plain struct in render, filled once at device creation by whichever backend started, read by the app through `render.caps()` (a proc, so `app` never touches a GPU name; `scripts/boundary_check.py` stays as it is):

```
Gpu_Caps :: struct {
    frames_in_flight:   u8,   // what the swapchain was made for (1..3)
    present_timing:     bool, // presented-time feedback: CAMetalDisplayLink / present_wait / display_timing
    pre_rotation:       bool, // the swapchain is made in the display's own orientation (Android Vulkan)
    timestamps:         bool, // per-pass GPU times without serialising frames
    transient_targets:  bool, // MSAA colour and depth can live in tile memory
    shared_buffers:     bool, // buffers the CPU writes in place (Apple silicon, Vulkan ReBAR/UMA)
    precise_shaders:    bool, // the exact-maths shader set is loaded (metallib or -fp-mode precise SPIR-V)
    draw_indirect_count: bool,
    descriptor_indexing: bool, // runtime-indexed texture arrays (Vulkan descriptorIndexing, Metal argument buffers tier 2)
    async_compute:      bool,
    ray_query:          bool, // Vulkan VK_KHR_ray_query; Metal supportsRaytracing
    ray_hardware:       bool, // Vulkan: ray query device; Metal: Apple9+ family
    subgroup_size:      u32,  // 0 when unknown
    int64_atomics:      bool,
}
```

Rules: a flag is set only after the backend created what it needs (a query pool, a second queue, a display link), never from a device property alone, so a flag that is true works; the SDL_GPU path sets `frames_in_flight`, `precise_shaders` (metallib) and `subgroup_size`/`int64_atomics` (through `SDL_GPUVulkanOptions`) and leaves the rest false. The exit stats print the struct (`caps=…`) and the Stats panel's Advanced view shows it, so a report from Bolt's tablet says which paths ran. Settings > Graphics gets one line per capability that changes behaviour ("Frames in flight: 1 · Present timing: on · Tile memory: on").

### 3.2 Seam rules that keep the boundaries

- A feature is one new `gpu_*` proc (or a field on an existing create-info) with three answers in `hal.odin`; the SDL answer is a no-op or SDL's own call. Never a backend-specific proc called from above the seam.
- Shader variants are chosen by `shaders.odin` from `Gpu_Caps` at pipeline creation: `name.stage.spv` (today), `name.stage.rq.spv` (ray query), `name.stage.metallib` (precise). Slang stays the one source; a variant is a `-D` or `-capability` flag in `build.sh`/`build.bat`, committed like the `.spv` and `.msl` are.
- `app` keeps holding only `render.Cmd`, `render.Texture`, `render.Fence`, `render.Sample_Count` (`src/render/gpu.odin`).
- Determinism (AGENTS.md section 5) is not relaxed: GPU paths that feed the mesh (smoothing, later normals) must equal the CPU bit for bit or stay off; GPU paths that feed pixels (culling, RT visibility) must give the same pixels as the CPU path (`parity_check.py` at 0 px) or be a different, named mode (render mode with hardware RT is allowed a tolerance, stated in README).
- Every step ends with: `python scripts/gate.py`; `parity_check.py` against the previous build; `smoke` under both backends; and the device run named in the step.

### 3.3 Verification ladder for this plan

| Where | What it can prove |
|---|---|
| This container (llvmpipe, no RT, no Metal) | compiles (`check`, `maccheck`, `iphonecheck`, `androidcheck`, `wincheck`), tests, `smoke` with Vulkan validation and sync validation, `parity_check.py` 0 px for render-only changes, `touch_check.py`, `--compute-bench` bit-exactness on llvmpipe, exit stats that the new flags appear |
| GitHub's macOS runner (`ipad.yml`, `mac.yml`) | Metal shaders and metallibs compile; the Mac app links; whether the runner's virtual GPU runs Metal at all is UNVERIFIED (the design doc says the same) |
| Bolt's Windows RTX 3060 Ti | Vulkan: frames in flight and `latency_ms`, timestamps vs `--time-gpu`, GPU culling at 20M+, descriptor indexing, ray query parity and speed; `gpubench` A/B rows |
| Bolt's Android tablet | pre-rotation (`frame_ms`, `gpu_ms` A/B and a rotated screenshot), display timing, transient MSAA memory, ray query if the GPU has it (Immortalis-G715/G720/G925, Xclipse 920 and newer; Adreno UNVERIFIED) |
| Bolt's iPad (sideloaded) | everything Metal: trial parity, frames in flight and Pencil latency, `CAMetalDisplayLink`, metallib precise maths (`--compute-bench` max diff), memoryless MSAA memory and frame time, Metal RT (hardware only on A17/M3/M4, Apple's Apple9 family page) |

Each step below names its device check as "Bolt: …".

## 4. The benefits, one by one

Format: what changes for the user · who gets it · SDL_GPU fallback · size · risks · verification · comparison where a choice exists.

### 4.A Latency and frame pacing (Pencil first)

**A1. Frames in flight = 1 while a stroke is live.**
- User: one display period less between the pen and the pixel (8.3 ms at 120 Hz, 16.7 ms at 60 Hz) during strokes; throughput unchanged for the frames that matter, since the app already waits for the display before reading input (`main.odin:878-887`).
- Who: all three backends, every device.
- Fallback: `SDL_SetGPUAllowedFramesInFlight(device, 1)` (3.2.0). Issue #14791 reports SDL's D3D12/Vulkan still keep an extra frame in some cases; Bolt's numbers decide.
- Design: `gpu_set_allowed_frames_in_flight(device, n)` in the seam; `Vk_Window.frame_serial` and `Mtl_Window.frame_serial` sized for 3 and used up to `n`; on Metal also `setMaximumDrawableCount(2)` (binding exists, `QuartzCore.odin:67`). The app sets 1 while `stroke` is live or the pointer is down, 2 otherwise (so orbiting with a heavy frame keeps overlap), changed only between frames before the acquire, next to `frame_pace`.
- Size: ~120 lines (seam 10, vk 30, mtl 30, app 30, README). No design review needed (no buffer layout, no shader).
- Risks: a backend that stalls on acquire with 1 frame (SDL #14791 suggests D3D12; we do not use it). On Android, FIFO with one frame may show a lower rate during heavy frames; the Limit setting is the escape.
- Verify: here, `--bench-stroke` exit stats show `latency_ms` unchanged or lower and no `wait_ms` growth on llvmpipe (meaningful only as a smoke). Bolt: RTX, `--bench-stroke=240 --no-vsync` is not the test (no display wait); use vsync on, Stats panel `latency_ms` p50 with frames 1 vs 2, three runs each; iPad and Android: the same from the Stats panel while drawing by hand, and a feel report (sm-touch-testing). Expect about one period less.

**A2. Present timing and presented-time feedback.**
- User: the Stats panel shows true pen-to-display latency (today `latency_ms` stops at the submit); the pacer can start the frame as late as the display allows instead of right after the previous acquire, which is what cuts latency at 120 Hz without dropping frames.
- Who: Metal (iPad and Mac) through `CAMetalDisplayLink` (iOS 17.0 / macOS 14.0 per Apple; our minimums 17.4 / 14.4), which calls the app when a frame is due with a target presentation timestamp and `preferredFrameLatency`; Vulkan on Android through `VK_GOOGLE_display_timing` (binding present), on desktop through `VK_KHR_present_wait` + `present_id` where offered (SDL's maintainer measured about 40% coverage on Windows and much higher on Linux; the RTX 3060 Ti's driver offers it, UNVERIFIED from here); `VK_EXT_present_timing` is still a proposal and not in the Odin binding, so it waits.
- Fallback: none in SDL today; #15656 would bring the feedback half later.
- Design: a `render.Present_Timing{ presented_ns, target_ns, refresh_ns }` the app reads after acquire (`gpu_present_timing(window)`), and a `gpu_set_present_target(window, target_ns)` the pacer may call. On Metal the loop structure changes: SDL's UIKit path already runs the app on the main thread inside `SDL_RunApp` (`ios.odin:60-74`); `CAMetalDisplayLink` needs a delegate callback, so the Metal backend creates the link on the layer, and `mtl_acquire_swapchain(wait = true)` blocks on a semaphore the callback signals, taking the drawable the callback delivered. That keeps the frame loop as it is and swaps "wait for the oldest drawable" for "wait for the display's call". Since the Odin binding has no `CAMetalDisplayLink`, the delegate is an Objective-C class of our own, as `Mtl_Objc_Anchor` already is (`mtl_device.odin:48-51`), or 40 lines in `ios/sculpt_ios.m`. Also set `presentsWithTransaction` false (the default; Apple's page says true only when Core Animation content must land in the same frame, which costs a `waitUntilScheduled`; we draw everything ourselves).
- Companion, not GPU: UIKit's predicted touches for the brush ring only (the dab path must stay sample-driven for replays, sm-sculpt's `stroke_random` rule); 30 lines in `ios/sculpt_ios.m` next to the coalesced-samples bridge. Named here because it is the other half of what Procreate-class apps do for Pencil latency; UNVERIFIED how much it adds in Sculpt.
- Size: Metal ~250 lines (link, delegate, semaphore, timing struct), Vulkan ~200 (display timing on Android, present_wait on desktop), app ~80 (Stats rows `display_ms`, pacer target). Design review: yes for the Metal loop change (it touches when the frame starts).
- Risks: `CAMetalDisplayLink` and SDL's own UIKit event pump fighting over the run loop; a late callback skipping a frame; Mac windows on non-ProMotion displays (plain 60 Hz, nothing lost). Android drivers where `GOOGLE_display_timing` reports garbage (common; use it for stats only until measured).
- Verify: here nothing beyond compile and `smoke` (llvmpipe offers no present_wait). Bolt: iPad Stats panel `display_ms` (pen to presented) with and without the link, at 120 Hz; a dropped-frame count over a 10 s stroke; Mac the same; Android `display_ms` only.
- Comparison: Apple's own guidance ("CAMetalDisplayLink … when you need more control over the timing window") is the stated path for Metal apps; Nomad Sculpt's and ZBrush for iPad's internals are not public (searched; UNVERIFIED), ZBrush for iPad documents Pencil hover and barrel roll, not pacing. The Android Frame Pacing library (Swappy) does the Vulkan half for games; it is a C++ library under Apache 2.0, and what we need from it (presentation timestamps, one frame queued, a chosen interval) is about 200 lines against `GOOGLE_display_timing` plus the `setFrameRate` call we already make, so no new dependency.

**A3. Android pre-rotation (own Vulkan backend).**
- User: on a tablet held in any orientation but the panel's native one, no compositor pass for rotation: Android's guide measured 1–3 ms of GPU preemption and a 40% higher GPU clock from the compositor on a Pixel 4 XL when apps leave rotation to the system; for us that is battery and frame time, not pixels.
- Who: Android Vulkan only (desktop surfaces report identity).
- Fallback: SDL stays identity (its choice, `SDL_gpu_vulkan.c:4783`).
- Design: `vk_swapchain_make` uses `caps.currentTransform` and swaps the extent for 90/270; the 3D viewport is drawn offscreen into `vt.color` and only `ui_present` touches the swapchain, so the rotation is one 2x2 matrix in `Ui_Uniforms` applied in `ui.vert.slang` (which already flips NDC y) and a remap of every scissor rect in `ui_pass_draw`; `ui.frag.slang` uses no derivatives (grep), so the `dFdx` caveat in Android's guide does not apply. `vkQueuePresentKHR` returning `SUBOPTIMAL_KHR` (already accepted at `vk_swapchain.odin:264`) remakes the swapchain. `--dump-screen` must come out upright, so `ui_pass_capture` draws without the rotation.
- Size: ~150 lines. No design review (no buffer layout; the shader change is one uniform, but it is a shader: small enough to review in the PR).
- Verify: here, `parity_check.py` 0 px (desktop identity path unchanged) and `touch_check.py`. Bolt: Android, rotate the tablet through all four orientations and screenshot; `frame_ms`/`gpu_ms` from the Stats panel in landscape-held-portrait, pre-rotation on vs `--no-pre-rotate`, three runs each.

### 4.B Stroke speed on big meshes (20M+)

What the numbers say first: at 10M vertices the GPU side is under 1 ms on the RTX (task brief) and the per-frame upload is about 0.6 MB (README bench: 39k vertices a dab at r = 0.13); the frame's cost is the brush (`brush_ms`), normals and culling on the CPU, and `cull_ms` grows with chunk count (10M = ~20k chunks; 50M = ~100k). So the GPU-side levers for 20M+ are: not stalling (A1), culling that does not scale with chunk count on the CPU, and smaller vertex data. Zero-copy uploads are last.

**B1. Shared (unified) buffers where a copy is the cost.**
- User: faster scene loads and GPU Smooth all round trips on Apple silicon (and on desktop GPUs that expose host-visible device memory): `mesh_buffers_create` today uploads a 10M mesh in 16 MB batches waiting for the GPU after each (`renderer.odin:924-935`, 400 MB at 10M); the compute trial's cold upload is 12.6 ms and readback 2 ms at 502k (`build/cb.md`), scaling to hundreds of ms at 10M.
- Not for strokes: writing live vertex ranges into a buffer the previous frame's draw is still reading races the GPU; keeping it deterministic means waiting for that frame, which costs more than the 0.6 MB copy. Keep the transfer path for strokes.
- Who: Metal (`MTLStorageModeShared` buffers for the vertex/index/storage buffers created by a loading path, `hasUnifiedMemory` true on every Apple silicon device), Vulkan where a HOST_VISIBLE|DEVICE_LOCAL heap exists (ReBAR on desktops, UMA on Android; `vk_memory_type` already prefers by flags, `vk_device.odin:413`).
- Fallback: SDL's transfer path (unchanged).
- Design: a `shared` bit in `gpu_create_buffer`'s props (SDL ignores it) and `gpu_map_buffer`/`gpu_unmap_buffer` seam procs that return nil when `caps.shared_buffers` is false; `mesh_buffers_create` and `smooth_compute_run` take the mapped path when offered. Hazard rule: a shared buffer is written only before its first use or after `wait_idle`/a fence on its last use, enforced by an assert in debug builds.
- Size: ~200 lines across seam, vk, mtl, renderer, smooth_compute. Design review: yes (a buffer memory layout decision, even if the bytes are the same).
- Verify: here, llvmpipe exposes host-visible device-local memory, so the Vulkan path runs: `mesh: … uploaded in … ms` log line and `--compute-bench` upload/readback columns before and after; `parity_check.py` 0 px. Bolt: iPad and Mac the same log lines and compute bench; RTX with ReBAR.

**B2. GPU culling: indirect commands written by a compute pass.**
- User: `cull_ms` stops growing with chunk count; a 50M-vertex scene culls in a fixed fraction of a millisecond on the GPU, and the CPU gets that time back for the brush.
- Who: all three (compute writes `GPUIndexedIndirectDrawCommand`s from a storage buffer of chunk bounds and cones; a culled run gets `num_indices = 0`). `draw_indirect_count` (Vulkan 1.2 feature `drawIndirectCount`; Metal indirect command buffers) skips the zeros where available; without it the draw count stays the chunk count, which GPUs handle well since empty commands cost almost nothing.
- Fallback: SDL_GPU has compute and indirect draws, but issue #14754 (open) reports a missing Vulkan barrier between a compute write and `vkCmdDrawIndexedIndirect` in SDL's driver; so under SDL the cap stays false until that is fixed upstream and the CPU path runs. Our backends insert the barrier themselves (`vk_cmd` already orders passes).
- Design: `geom.cull_chunks` math moves into a Slang compute kernel one to one (`cull.comp.slang`), with the LOD choice (`cull_lod`) in a second pass or left on the CPU at first; stats (`culled_view`, `culled_back`) come back through a small readback once a second, not per frame. The exact-pixel rule holds: the GPU cull must pick the same chunks as the CPU for the same view (`parity_check.py` 0 px with cull on both ways; a chunk counted visible by one and not the other shows as a pixel difference or as nothing, so the test also compares the command buffers in a debug flag `--dump-cull`).
- Size: ~450 lines + a shader: design review required (new GPU buffer layout: the chunk record; a shader).
- Verify: here, llvmpipe runs it: `cull_ms` before/after at `--vertices=10000000` and the parity run. Bolt: RTX at 20M+ (`build.bat gpubench --vertices=20000000`, which needs the 20M fixture the "next frontier" work adds), `cull_ms`, `frame_ms` A/B.

**B3. Smaller vertices (8 bytes: snorm16 positions relative to chunk bounds) – optional, measured first.**
- Named because 50M x 16 B = 800 MB of positions and normals plus 1.2 GB of 32-bit indices decides whether a 50M scene fits an iPad at all (README: 888 MB of CPU mesh at 10M). It is not a backend feature; it works on SDL too and needs a design (vertex layout, `mesh.vert.slang`, upload packing, the traced studio's storage read of positions). Listed so that "bindless for 50M" is not mistaken for the memory fix. Do it only after B2 and after a 20M run shows memory, not draw count, as the limit.

### 4.C Compute parity on Apple: GPU Smooth all on the iPad

**C1. Precise-maths metallib under SDL_GPU and under our Metal backend.**
- User: "Smooth all · On the GPU" appears on the iPad and Mac, 2–2.6x the CPU at 500k in the llvmpipe bench (`build/cb.md`), far more on a real GPU, with results equal to the CPU's so Undo, levels and the Blender link see the same mesh.
- Who: SDL_GPU on Darwin and our Metal backend once it has compute (stage 2).
- How: `build.sh ios|mac` already compiles each `.msl` with `xcrun metal` for checking (`metal_check`, `build.sh:193-203`). For the shaders listed in a `PRECISE_SHADERS` set (today `smooth_all.comp`), it also links a `.metallib` compiled with fast maths off and contraction off (`-fno-fast-math`, and `-ffp-contract=off`; UNVERIFIED that current `xcrun metal` accepts both and that SPIRV-Cross's MSL preserves the operation order the SPIR-V's `NoContraction` asked for; Apple's `mathMode` page says `fastMathEnabled = false` maps to safe maths and precise functions, so the flags exist in some spelling). The metallib is embedded as `#load("shaders/smooth_all.comp.metallib")` under Darwin, `gpu_create_compute_pipeline` gets `format = {.METALLIB}` for that shader (SDL accepts mixed formats on one device: `shader_formats = MSL | METALLIB`, `SDL_gpu_metal.m:4675`), and our Metal backend loads it with `newLibraryWithData`. Odin's `#load` of a file built on the Mac means the metallib is committed like the `.msl` (the iPad CI builds it; `shaders_msl.py --check` grows a `--metallib` check), or built in `build.sh` on the Mac only and embedded there (then `iphonecheck` on Linux needs a stub; prefer committing, as for `.spv`).
- Fallback: none needed; if the device refuses the metallib the switch is hidden, as the CPU fallback already works (`smooth_compute_init` returning false).
- Size: build script ~60 lines, `shaders.odin`/`smooth_compute.odin` ~40, README. No new layout; the shader is unchanged. Review: a short one, since it changes what ships in the IPA.
- Verify: here, nothing (no Metal). GitHub Mac runner: the metallib builds. Bolt: iPad and Mac `build/sculpt --compute-bench` (`src/app/computebench.odin`) must print max diff 0 at every size; if it prints a nonzero diff, the feature stays off on Apple and the plan's C2 (our own compile options, `MTLCompileOptions.mathMode = safe` at runtime, iOS 18+/macOS 15+, or `fastMathEnabled = false` on 17.x) is the next try; if both fail, bit-exactness is not reachable on Apple and README says so.
- This step is gated on Bolt's iPad only for the verdict, not for the code: the Metal trial need not draw correctly first, because it runs under SDL_GPU.

**C2. Metal backend stage 2: compute pipelines, copies, mipmaps, readback, timing (the design doc's stage 2).**
- Already designed; ~400 lines in `mtl_resources.odin`/`mtl_cmd.odin` (compute pipeline state, compute encoder, storage buffer slots as SDL's Metal driver binds them, `dispatchThreadgroups`). With C1 in place, its only new user-visible effect is parity: the traced studio, render mode and GPU Smooth all run under Metal (trial) as under SDL_GPU.
- Verify: Bolt's iPad and Mac: `parity_check.py --compare <sdl run> -- --gpu=metal` on the 19 scenes at 0 px, and `--compute-bench` max diff 0 under `--gpu=metal`.
- Gate: Metal (trial) draws the 19 scenes correctly on Bolt's iPad (stage 3's verdict) before this merges as more than compile-checked code.

### 4.D Memory and bandwidth on tablets

**D1. Transient MSAA targets: memoryless on Metal, transient + lazily allocated on Vulkan.**
- User: on the iPad (2x MSAA on tablets, README line 104) the multisample colour and depth of a 2732x2048 viewport are about 45 MB each; memoryless removes their memory and, more important on a tile GPU, the store of every sample to memory each frame. On Android tile GPUs (Mali, Adreno) `VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT` with `LAZILY_ALLOCATED` memory does the same where the driver offers it (desktops do not).
- Constraint from our own renderer: partial redraw keeps the MSAA targets with STORE and LOADs them next frame (sm-render), and the idle cache is an MSAA copy. Apple's page: memoryless contents cannot be loaded or stored. So memoryless applies to passes that clear and resolve in one go: thumbnails, nav head, step pictures, captures, and the main viewport only when partial redraw is off. That makes the real question a measurement: on a TBDR GPU, is a full redraw with memoryless MSAA cheaper than a partial redraw with stored MSAA? Likely yes for frame time and bandwidth, no for GPU work on big meshes; `gpubench` on the iPad decides the iPad default.
- Who: Metal (every Apple GPU family per Apple's page), Vulkan on tile GPUs; desktop Vulkan never (no lazily allocated heap).
- Fallback: SDL allocates private/device-local (unchanged).
- Design: a `transient` bit on `gpu_create_texture` props (ignored by SDL); `Viewport_Target` makes `multi_color` and MSAA `depth` transient when `caps.transient_targets && !r.partial`; `target_pass` already sets RESOLVE for the colour; the depth store becomes DONT_CARE in that mode. The idle cache under MSAA is skipped in that mode (it already skips for see-through items).
- Size: ~150 lines. Design review: short (it changes which passes store).
- Verify: here, `parity_check.py` 0 px (desktop path untouched). Bolt: iPad Stats panel memory (`SDL_GetGPU…` has no memory query; the Xcode Metal capture or the app's own texture byte count, which the step adds to the Stats panel) and `gpubench` rows partial-on-stored vs partial-off-memoryless for the stroke cases; Android the same with `frame_ms`.

**D2. Explicit load and store actions everywhere.** Each pass in `renderer.odin`, `live_ao.odin`, `studio.odin`, `finish.odin` states its actions today through SDL's enum; the audit is to make sure none LOADs what it clears or STOREs what nothing reads (on Vulkan and Metal alike a needless store is a full-screen write; on a tile GPU it is the whole cost). This is a review pass with `parity_check.py` at 0 px, ~50 lines of changes; no backend feature needed; part of D1's PR.

### 4.E Large scenes

**E1. Descriptor indexing / argument buffers, where a feature needs arrays.**
- The honest case: draw count is per object, not per chunk (one multi-draw indirect per item, `renderer.odin:1552-1560`), so "fewer draws for 50M" is not a bindless problem. The concrete need is render mode's textured items: `RENDER_TEXTURED_MAX 3` maps through a `switch` over 9 named samplers because non-uniform indexing is a device feature (`path.odin`, sm-render), using 12 of 16 sampler slots. With `descriptorIndexing` (Vulkan 1.2 feature; core on every 1.3 device our backend already requires, with `shaderSampledImageArrayNonUniformIndexing` to check) and Metal argument buffers (tier 2 on every Apple silicon GPU; Apple's `argumentBuffersSupport` page gives the tiers without per-device lists, UNVERIFIED which iPads are tier 1), the kernel binds one array of all maps and any number of textured items trace at once.
- Fallback: today's switch and limit of 3.
- Design: a new binding kind at the seam, `gpu_bind_compute_texture_array(pass, slot, textures[])`, with a Vulkan descriptor set using `VARIABLE_DESCRIPTOR_COUNT` + `PARTIALLY_BOUND`, and a Metal argument buffer encoded per frame; the Slang kernel declares `Texture2D maps[]` under `-D MAP_ARRAY` (a shader variant). Size ~400 lines + the variant. Design review required.
- Verify: here with llvmpipe (it supports descriptor indexing): render mode with 4+ textured items against the switch path with 3 (same pixels for the first three items; `ppm.py diff` 0 within the untextured region). Bolt: RTX (speed), iPad once Metal compute exists.
- Comparison: Metal argument buffers tier 1 (A11 and earlier) cap resources per buffer at 8 buffers/31 textures-ish and need explicit `useResource`; tier 2 (A12+/Apple silicon) allows up to 500k textures and nested buffers, which is why the step requires tier 2 and falls back otherwise. Vulkan's `VK_EXT_descriptor_buffer` is the newer, Metal-like model but with thinner coverage on Android; descriptor indexing is the right choice for a 1.3 baseline.

**E2. Async compute queue for render mode and the traced studio.**
- User: while render mode converges (bands of rows per frame, adaptive on frame time, `path.odin:63-70`), the interface and orbit keep their frame rate because the kernel runs on a second queue instead of inside the frame's command buffer.
- Who: Vulkan with a compute-only family (every desktop GPU; most Android), Metal with a second `MTLCommandQueue` (Apple GPUs overlap compute and render across queues; UNVERIFIED how much on a given iPad).
- Fallback: SDL's one queue (today's banding).
- Design: `gpu_acquire_command_buffer(device, queue = .Graphics | .Compute)`; the Vulkan backend's timeline semaphore already serialises submissions (`vk_device.odin:41-45`), so a compute submission signals the same timeline and the graphics frame waits on the value for the scene buffers it reads; Metal uses an `MTLSharedEvent` between queues. Render mode's accumulators are already ping-pong, so the display reads the finished one. Size ~350 lines + app changes to submit the trace from a separate cadence. Design review required (it touches when buffers are read).
- Verify: here, llvmpipe has one queue family, so only the fallback runs; `smoke` with sync validation. Bolt: RTX and iPad: `frame_ms` p99 while render mode runs, before/after.

**E3. 64-bit atomics and subgroup operations.** Core facts: subgroup ops are Vulkan 1.1 core (our backend requires 1.3) and MSL has SIMD-group functions on every Apple GPU; 64-bit atomics are the optional `shaderBufferInt64Atomics` (SDL's options list shows it, `SDL_gpu_vulkan.c:11605`) and on Metal exist only for min/max on Apple9 (A17/M3/M4; UNVERIFIED beyond Apple's Metal 3.1 notes). What they are for here: a GPU dyntopo or GPU BVH refit with fixed-point reductions. What they are not for: GPU normals by atomic float adds, which would break the bit-identical rule (addition order); GPU normals, when they come, gather over the vertex-faces CSR the smooth kernel already uploads (`smooth_compute.odin`'s `offsets`/`tris`), which is deterministic and needs no atomics. So: expose `subgroup_size` and `int64_atomics` in `Gpu_Caps` (20 lines, both backends; SDL through `SDL_GPUVulkanOptions`), and plan no feature on 64-bit atomics until a design asks for one.

**E4. Mesh shaders: not planned.** Metal 3 mesh shaders (Apple7+/M1+) and `VK_EXT_mesh_shader` replace the index buffer with GPU-generated meshlets; the gain is per-cluster culling on the GPU, which B2 gets with indirect commands and existing index buffers, and vertex fetch savings that matter only when fetch is the bottleneck. At <1 ms GPU for 10M on the RTX, it is not. Revisit with a 50M fixture if B2 and B3 leave the GPU above the frame budget on the iPad. SDL has no plans either, so the fallback would be a second draw path forever.

### 4.F Timing and capture

**F1. Per-pass GPU timestamps without serialising frames.**
- User: the Stats panel's `gpu_ms` becomes per pass (viewport, live AO, studio/render, interface) in every frame, with frames overlapping as in normal use; `gpubench` reports true overlapped GPU time; a slow pass on a tablet is visible in Bolt's report.
- Who: Vulkan (`vkCmdWriteTimestamp2`, `timestampComputeAndGraphics`, `timestampPeriod`, a query pool per in-flight frame, results read two frames later); Metal (`MTLCommandBuffer.GPUStartTime/GPUEndTime` for whole command buffers on every device, and `MTLCounterSampleBuffer` timestamps at stage boundaries where `supportsCounterSampling(.atStageBoundary)`; Apple's page gives the API from iOS 14 / macOS 10.15).
- Fallback: SDL's draft PR #15651 later; until then `--time-gpu` as today.
- Design: `gpu_timestamp(cmd, slot)` + `gpu_timestamps_read(device, frame_serial) -> []f64`; the app places eight named marks per frame; `Viewport_Stats` gains them. Size ~250 lines. No design review (no layout; no shader), but it is a new GPU buffer (query pool), so a short note in the PR.
- Verify: here, llvmpipe supports timestamps: `gpu_ms` by timestamps vs `--time-gpu` within 10% at 1M. Bolt: RTX and iPad the same comparison; iPad counter sampling support printed in `caps`.

**F2. Debug labels and groups; Xcode GPU capture and RenderDoc.** Capture tools attach to the process and need no backend work; what makes captures readable is names. SDL has `SDL_PushGPUDebugGroup`/`SDL_InsertGPUDebugLabel`/`SDL_SetGPUTextureName` since 3.2.0; our seam wraps none. Add `gpu_push_debug_group`, `gpu_pop_debug_group`, `gpu_set_name` (Vulkan `VK_EXT_debug_utils`, Metal `pushDebugGroup:`/`label`), and name every pass and buffer in render (~120 lines, mechanical). Bolt: one Xcode capture of the iPad under Metal (trial) and one RenderDoc capture on the RTX under Vulkan, read for pass names. Store note: `MTL_DEBUG_LAYER` and labels are debug-only; store builds set neither (sm-store "Store builds are release builds").

### 4.G Ray tracing (last)

**G1. Vulkan ray query in the existing compute kernels.**
- User: the traced studio's shadows and occlusion, and render mode's paths, trace against hardware acceleration structures: on the RTX 3060 Ti that is an order of magnitude more rays a second than the compute BVH walk (vendor figures; the actual ratio for our kernels is UNVERIFIED until Bolt runs it), so render mode converges in seconds, not tens of seconds, and the studio reaches its sample count faster. Live AO stays screen-space (it runs during strokes; acceleration structures need a refit per frame, which the plan does not do while sculpting).
- Who: Vulkan devices with `VK_KHR_ray_query` + `VK_KHR_acceleration_structure` + `VK_KHR_deferred_host_operations` (the ray query extension depends on them, Vulkan Guide): the RTX; on Android, Arm Immortalis-G715/G720/G925 and Samsung Xclipse 920/940 expose ray query (Arm's developer overview and learning path; Qualcomm Adreno 7xx UNVERIFIED from here, GPUinfo pages load no data without JavaScript). Bolt's tablet's GPU is unknown; `caps` tells.
- Fallback: the compute walk, unchanged (SDL and non-RT devices).
- Why ray query, not RT pipelines: our tracing already lives in compute kernels (`studio_trace.comp.slang`, `render_trace.comp.slang`) that own their sampling, environment table and denoiser guides; ray query keeps one kernel per feature on every API (Metal's `intersector<>` is query-style too, so the Metal port is the same kernel), while an RT pipeline would split them into ray-gen/hit shaders and add a shader-binding table that Metal has no equivalent of. The Vulkan Guide notes ray query "restricts the range of optimizations" (no hardware shader scheduling of divergent hits); Arm recommends ray query on mobile for the same reason it suits us: simple shading per hit. Blender's Cycles took the pipeline route on NVIDIA through OptiX and the query-style route on Metal (Metal RT, on by default only for M3 and newer, Blender PR #120299); Marmoset Toolbag 5 lists hardware acceleration for NVIDIA RTX and AMD RX and runs its tracer on Apple silicon without saying whether M3 hardware is used (its system requirements page); neither claim changes the choice.
- Design (needs review: a shader variant and new GPU buffers): BLAS per `Trace_Mesh` run group from the storage positions/indices already on the GPU (`Mesh_Buffers.storage`), built at `samples == 0` with a time budget and refit (UPDATE) when `version` moved and triangles did not, rebuilt when `index_version` moved (same keys the chunk trees use, `trace.odin:70-77`); TLAS over shown chunk runs minus `hidden`; the kernels get `-D RAY_QUERY` variants (`*.rq.spv`) where `chunk_bvh_any_hit`'s walk becomes `rayQuery` with `gl_RayFlagsTerminateOnFirstHit` for visibility and closest-hit for render mode, keeping every other line. Determinism: visibility is boolean, so the studio stays two-runs-0-px; render mode's closest hit can tie differently in hardware, so README states a tolerance for the RT mode and `parity_check.py` compares RT against the walk with the existing "traced vs gather within ~12/255" style threshold.
- Size: ~700 lines in `vk_resources`/`vk_cmd` (AS build, scratch, barriers, device address), ~150 in `trace.odin`/`path.odin`, two shader variants. Two PRs: AS build + studio visibility; then render mode.
- Verify: here, none of it runs (llvmpipe has no ray tracing); compile, `smoke` with the cap false, the walk path unchanged at 0 px. Bolt: RTX, `--studio` and render mode scenes from `parity_check.py` compared RT vs walk within tolerance, `samples`/s from the exit stats, and two RT runs compared; Android if `caps.ray_query`.

**G2. Metal ray tracing.**
- Who: `MTLDevice.supportsRaytracing` (API from iOS 14 / macOS 11; Apple's page), hardware on the Apple9 family (A17, M3, M4 per Apple's family page), software-emulated on earlier Apple silicon (UNVERIFIED speed; Blender keeps Metal RT off below M3, which says enough).
- The shader problem: our MSL comes from SPIRV-Cross, which has no MSL output for ray query SPIR-V (UNVERIFIED for the pinned `SPIRV_CROSS_COMMIT`; treat as absent). The design doc's stage 5 already names the way: Slang's direct Metal target (`slangc -target metal`) emits `intersector`/acceleration-structure intrinsics. That makes a second shader pipeline for exactly the RT kernels (two files), committed as `.metal` source or metallib, chosen by `shaders.odin` under `caps.ray_query` on Darwin.
- Design: `MTLPrimitiveAccelerationStructure` per run group from the same storage buffers, `MTLInstanceAccelerationStructure` as the TLAS, refit with `refitAccelerationStructure`, built on the compute queue; the same keys and budgets as G1. Size ~500 lines Metal + the Slang Metal path in the build (~80 lines of script). Design review required.
- Gate: after G1 has run on the RTX and after Metal stage 2 (compute) is verified on Bolt's iPad; only worth hardware if Bolt's iPad is an M-series or A17 model (ask).
- Verify: Bolt's iPad/Mac: RT vs walk within tolerance, samples per second, and `caps.ray_hardware` printed.

## 5. Phases and PR-sized steps

Order: what the user feels first. "Merge on Linux" means the checks here suffice to merge with the capability off by default or on a path llvmpipe runs; "Bolt before merge" means the PR waits for a device report. Lines are estimates of Odin plus script changes, excluding generated shader binaries.

### Phase 1 — Pencil latency and pacing (all devices)
| Step | What | Lines | Review | Merge gate | Bolt checks |
|---|---|---|---|---|---|
| 1.1 | `Gpu_Caps` struct, `render.caps()`, exit stats and Stats panel line; SDL path fills `frames_in_flight` | ~120 | no | Linux | none (RTX: `caps=` line appears) |
| 1.2 | `gpu_set_allowed_frames_in_flight`; SDL call; vk/mtl per-window frames 1–3; Metal `setMaximumDrawableCount(2)`; app sets 1 during strokes (A1) | ~150 | no | Linux (smoke both backends) | RTX `latency_ms` 1 vs 2 frames; iPad and Android the same by hand (iPad under SDL_GPU, so this ships before the Metal trial verdict) |
| 1.3 | Debug groups and names at the seam (F2) | ~120 | no | Linux | one Xcode capture, one RenderDoc capture |
| 1.4 | Vulkan presented-time feedback: `GOOGLE_display_timing` on Android, `present_wait` on desktop; `display_ms` in Stats (A2, Vulkan half) | ~220 | short | Linux (fallback path) | RTX, Android `display_ms` |
| 1.5 | Android pre-rotation in the Vulkan backend (A3) | ~150 | no | Linux (parity 0 px, touch_check) | Android four orientations + `frame_ms`/`gpu_ms` A/B |
| 1.6 | iOS predicted touch for the brush ring (companion, not GPU) | ~60 | no | Linux (`iphonecheck`) | iPad feel |
| 1.7 | Metal `CAMetalDisplayLink` pacing with `preferredFrameLatency 1` (A2, Metal half) | ~280 | yes | Bolt before merge (iPad) | iPad `display_ms` and dropped frames at 120 Hz; Mac |

Phase 1 ships 1.1–1.6 with no Metal dependency; 1.7 waits for the Metal (trial) verdict (section 6).

### Phase 2 — Stroke speed on big meshes
| Step | What | Lines | Review | Merge gate | Bolt checks |
|---|---|---|---|---|---|
| 2.1 | A 20M (and 50M, if memory allows) `gpubench` size and fixture; `cull_ms` and `upload_kb` rows in `gpubench.md` | ~80 | no | Linux | RTX rows |
| 2.2 | GPU timestamps per pass (F1), so 2.3+ are measured without serialising | ~250 | short | Linux (timestamps vs `--time-gpu` within 10%) | RTX, iPad later |
| 2.3 | GPU culling design: chunk record layout, `cull.comp.slang`, `--dump-cull` | design | yes | design review | - |
| 2.4 | GPU culling, CPU-equal, indirect commands with zero counts; cap false under SDL until #14754 is fixed (B2) | ~450 | (2.3) | Linux (parity 0 px, `cull_ms`) | RTX 20M `cull_ms`, `frame_ms` |
| 2.5 | `draw_indirect_count` where offered (Vulkan feature; Metal ICB later) | ~120 | no | Linux | RTX draws count |
| 2.6 | Shared buffers for loads and compute round trips (B1) | ~200 | yes | Linux (llvmpipe has host-visible device memory) | iPad/Mac load times and compute bench |
| 2.7 | 8-byte vertices (B3): design only, decided on 2.1's numbers | design | yes | - | - |

### Phase 3 — Compute parity on Apple
| Step | What | Lines | Review | Merge gate | Bolt checks |
|---|---|---|---|---|---|
| 3.1 | Precise metallib for `smooth_all.comp` in `build.sh ios|mac`, committed, `--check`; `format = METALLIB` for it; the GPU switch offered on Darwin when `caps.precise_shaders` (C1) | ~130 | short | GitHub Mac runner builds it; Linux `iphonecheck` | iPad and Mac `--compute-bench` max diff 0 at every size; if not 0, the switch stays hidden and 3.2 is tried |
| 3.2 | Our Metal backend compiles MSL with `MTLCompileOptions` maths safe (17.x: `fastMathEnabled = false`; 18+: `mathMode = safe`) as a second route to C1 | ~40 | no | Linux compile | iPad compute bench under `--gpu=metal` (needs 3.3) |
| 3.3 | Metal stage 2: compute pipelines, dispatch, storage slots, mipmaps/readback/timing gaps (C2) | ~400 | (designed) | Bolt before merge | iPad/Mac parity 19 scenes at 0 px under `--gpu=metal`, compute bench |
| 3.4 | Metal stage 3: Automatic = Metal on Apple with SDL fallback, trial label removed | ~60 | no | Bolt before merge | iPad and Mac week of use |

### Phase 4 — Memory on tablets
| Step | What | Lines | Review | Merge gate | Bolt checks |
|---|---|---|---|---|---|
| 4.1 | Load/store audit of every pass (D2) | ~50 | no | Linux (parity 0 px) | - |
| 4.2 | `transient` textures: Vulkan transient + lazily allocated (Android), Metal memoryless; used by one-shot passes' depth (thumbnails, nav head, step pictures, scene previews, render mode's backdrop; captures go with 4.3) (D1a) | ~150 | short | Linux (parity 0 px) | Android, iPad memory count in Stats |
| 4.3 | Viewport MSAA transient when partial redraw is off; `gpubench` partial-stored vs full-memoryless decides the tablet default (D1b) | ~100 | short | Linux | iPad and Android `gpubench` rows |

### Phase 5 — Large scenes
| Step | What | Lines | Review | Merge gate | Bolt checks |
|---|---|---|---|---|---|
| 5.1 | `subgroup_size`, `int64_atomics` in caps; SDL path through `SDL_GPUVulkanOptions` (E3) | ~60 | no | Linux | RTX, Android `caps` |
| 5.2 | Texture arrays at the seam: Vulkan descriptor indexing, Metal argument buffers tier 2; render mode's `MAP_ARRAY` variant lifts `RENDER_TEXTURED_MAX` (E1) | ~400 | yes | Linux (llvmpipe supports it) | RTX speed; iPad after 3.3 |
| 5.3 | Async compute queue for render mode and the traced studio (E2) | ~350 | yes | Linux (fallback only) + Bolt before default-on | RTX and iPad `frame_ms` p99 in render mode |

### Phase 6 — Ray tracing
| Step | What | Lines | Review | Merge gate | Bolt checks |
|---|---|---|---|---|---|
| 6.1 | Design: acceleration structure lifetime against `Trace_Mesh` keys, budgets, the RT tolerance in README, the shader variant scheme | design | yes | design review | - |
| 6.2 | Vulkan AS build/refit + ray query in `studio_trace` (visibility) (G1a) | ~600 | (6.1) | Bolt before merge (RTX) | RTX RT vs walk within tolerance, two RT runs 0 px, samples/s; Android if offered |
| 6.3 | Ray query in `render_trace` (closest hit) (G1b) | ~250 | (6.1) | Bolt before merge | RTX convergence time, tolerance |
| 6.4 | Slang → Metal path in the build for the two RT kernels; Metal AS build and intersector (G2) | ~580 | yes | Bolt before merge (iPad/Mac, hardware RT device) | iPad/Mac RT vs walk, samples/s, `caps.ray_hardware` |

## 6. Prerequisites and gates

- **Metal gate.** No Metal-only step (1.7, 3.2, 3.3, 3.4, 4.2's Metal half, 5.2's Metal half, 6.4) merges as more than compile-checked code until Metal (trial) has drawn the 19 `parity_check.py` scenes correctly on Bolt's iPad (and ideally the Mac). What "correctly" means: `parity_check.py --compare <sdl run> -- --gpu=metal` at 0 px, or a described difference accepted in the PR. Until then those steps can be written and pass `maccheck`/`iphonecheck`; their PRs stay open or merge with the capability unreachable (the trial guard in `graphics_trial_begin` already protects users).
- **Not Metal-gated:** 1.1–1.6, 2.x, 3.1 (runs under SDL_GPU), 4.1, 4.3's Vulkan half, 5.1, 5.3's Vulkan half, 6.1–6.3.
- **Merge on Linux checks alone:** steps whose new path llvmpipe runs with `parity_check.py` at 0 px and whose device-only effects are behind a cap flag that is false here: 1.1–1.5, 2.1–2.6, 3.1 (with the switch hidden until Bolt's bench), 4.1–4.3, 5.1–5.2, and the walk-path side of 6.x.
- **Bolt's hardware before merge:** 1.7, 3.3, 3.4, 5.3 default-on, 6.2–6.4, and any step whose first measurement contradicts its premise (1.2 if `latency_ms` does not fall, 4.3 if memoryless is slower).
- **Fixtures Bolt needs:** his iPad's model (decides Metal RT hardware and argument buffer tier), the Android tablet's GPU name (the `GPU: … (vulkan, driver …)` log line decides ray query and transient support), and whether his RTX driver offers `VK_KHR_present_wait` (`caps` prints it after 1.4).
- **Order inside a phase is strict** where a step measures another (2.2 before 2.4; 1.1 before everything).

## 7. Comparisons where a choice was made

| Choice | Candidates | Pick and why |
|---|---|---|
| Ray tracing API | ray query in compute · RT pipeline (Vulkan) · Metal intersection functions | Ray query: one kernel per feature on both APIs, no shader-binding table, Arm's mobile guidance, our kernels already own sampling and denoising; RT pipelines give better hardware scheduling of divergent hit shading, which our shading does not have (Vulkan Guide: ray query "restricts the range of optimizations"). Blender uses OptiX pipelines on NVIDIA and Metal RT (query-style) on Apple, M3+ default (Blender PR #120299). |
| Bindless model | Vulkan descriptor indexing · `VK_EXT_descriptor_buffer` · Metal argument buffers tier 1 / tier 2 | Descriptor indexing (core 1.2, present on every 1.3 device we already require) and argument buffers tier 2 (Apple silicon); descriptor_buffer is Metal-like but thin on Android; tier 1 needs per-resource `useResource` and small limits, so it falls back. |
| Precise maths on Apple | precompiled metallib with fast maths off (works under SDL_GPU) · own `MTLCompileOptions` (own backend only) · keep CPU | Metallib first: ships on the SDL_GPU path today, the iPad gets GPU Smooth all before our backend has compute; own options as the second route; CPU stays the fallback. |
| Low-latency pacing on Apple | `CAMetalDisplayLink` · `CADisplayLink` + `nextDrawable` · `presentsWithTransaction` | `CAMetalDisplayLink` (iOS 17 / macOS 14, inside our minimums; Apple's page: for Metal apps that "need more control over the timing window"); `presentsWithTransaction` is for syncing with UIKit content and adds a `waitUntilScheduled`, which we do not need. |
| Android pacing | Swappy (AGDK, C++, Apache 2.0) · own `GOOGLE_display_timing` + `setFrameRate` · SDL's future Choreographer (#15013, 3.8) | Own: the needed part is ~200 lines and the app already asks the display for a rate; no new native dependency in the APK; adopt SDL's Choreographer when it ships. |
| GPU culling | CPU (today) · compute-written indirect commands · mesh shaders | Compute-written commands: CPU-equal pixels, runs on all three backends (SDL once #14754 is fixed), keeps index buffers; mesh shaders only if a 50M fixture shows vertex fetch as the limit. |
| Zero-copy for strokes | shared vertex buffers written in place · transfer copy (today) | Keep the copy: 0.6 MB a frame at 10M; in-place writes race the frame in flight or cost a wait. Shared memory is for loads and compute round trips. |
| GPU normals (future) | atomic float accumulation (needs 64-bit or CAS) · gather over the vertex-faces CSR | Gather: deterministic, no atomics, the CSR already exists on the GPU for Smooth all. |
| How other apps do it | ZBrush for iPad: Metal, 92M polygons per subtool on an M4 1 TB iPad (CGWORLD), Pencil hover and barrel roll (Maxon docs); Nomad Sculpt: internals not public, cross-platform (iOS, Android, Windows, macOS, web); Blender: Metal only on macOS since 4.0, Vulkan planned as default on Windows/Linux after 5.0 (devtalk status reports), Cycles Metal RT on M3+; Marmoset Toolbag 5: own tracer, hardware acceleration named for NVIDIA RTX and AMD RX; 3D-Coat: CUDA for some GPU work, no Vulkan renderer found | Nothing found contradicts the order above; none of them documents Pencil pacing internals, so A2 is measured here, not copied. |

## 8. Store rules (sm-store) for what ships

- **No new permissions, no network, no downloaded code:** every step is in-process GPU work; shader variants and metallibs are data files built and signed with the app (Apple 2.5.2 holds; metallibs are compiled Metal libraries shipped in the bundle, which is the normal case for Metal apps).
- **Privacy manifest (`ios/PrivacyInfo.xcprivacy`):** none of `CAMetalDisplayLink`, counter sample buffers, acceleration structures or `MTLCompileOptions` is a "required reason" API; timestamps come from Metal's GPU clock, not `mach_absolute_time` or boot time (SDL's timer entry 35F9.1 already covers what the app calls). Recheck when 1.7 lands, since the display link's timestamps are `CFTimeInterval`s read from the link, not from a listed API (UNVERIFIED against Apple's current list; the step's report must say).
- **Crashes and hangs:** every capability is probed at device creation and false on failure; acceleration structure builds run with a time budget and never on the main thread for longer than a frame's share (render mode's band scheme already does this); a driver that refuses an extension falls back the way `backend_fail` does today.
- **Debug surfaces:** timestamps and `caps` live in the Stats panel, which sm-store already marks as developer-only in store builds; `MTL_DEBUG_LAYER`, Vulkan validation and debug labels are debug-build only (labels can stay in release; they are harmless, but the store build keeps `--gpu-debug` off).
- **Android packaging:** no new native library (Swappy declined), so the 16 KB page alignment, arm64 and target API 36 rules are unchanged; pre-rotation changes nothing the manifest declares.
- **Licences:** no new third-party code; Slang's Metal output and Apple's compilers produce our own files. If Swappy were ever adopted, it is Apache 2.0 and would go in About > Licences.
- **Memory on tablets:** steps 4.x reduce memory; 6.x adds acceleration structures (roughly 1–2x the index data: UNVERIFIED per driver), so `TRACE_BUFFER_MAX`/`RENDER_SCENE_MAX` style budgets apply to them, and a scene over budget keeps the compute walk, never a crash.
- **Settings > Graphics text and README:** each shipped capability gets a sentence under Graphics and its README paragraph (AGENTS.md section 5: README updated with any flag, control or panel change).

## 9. What remains unverified

- Any Metal behaviour at all (the backend has never run on Apple hardware); the GitHub Mac runner's GPU; the exact `xcrun metal` flags for safe maths and no contraction; whether SPIRV-Cross's MSL keeps the operation order of `NoContraction` SPIR-V; whether Apple GPUs reach bit-exact division with safe maths.
- Driver support on Bolt's devices: `VK_KHR_present_wait` on the RTX, ray query and transient attachments on the Android tablet, the iPad's GPU family (hardware RT, argument buffer tier).
- SDL `main`'s driver sources beyond the header and WhatsNew (repository file access to `libsdl-org` was refused for `gh` and the GitHub connector; issue and PR pages and raw files were readable through plain fetches); whether SDL #15946 (`feature_list` ignored) is fixed in 3.4.18; whether PR #15838 (sampling MSAA textures) is on a release branch.
- Khronos registry pages refused plain fetches; the ray tracing and present timing facts come from the Vulkan Guide and the `Vulkan-Docs` proposal text on GitHub.
- All speed-ups are ranges to be measured on Bolt's devices with the commands named; nothing here is a measured number except the repository's own bench tables and `build/cb.md`.
