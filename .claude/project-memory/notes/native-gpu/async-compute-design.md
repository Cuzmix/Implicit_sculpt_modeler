# Async compute for render mode: design (native GPU plan 5.3, E2)

Status: design for review, 2026-10-30. It changes when render mode's buffers and images are read and written, so it waits for review before it is built.

## The problem
Render mode traces a band of rows each frame, recorded into the frame's own command buffer (`render_frame`, `path.odin`; called from `app/render_mode.odin:65` and `app/thumbnail.odin:427`). The GPU runs the band, then the viewport and the interface, one after the other. So while render mode converges, every frame waits for its band. The band shrinks when frames are slow (`RENDER_FRAME_SLOW`) and grows when they are fast, which keeps orbiting usable but trades away samples. A second queue lets the band run beside the frame instead of before it.

## What exists
- **The own Vulkan backend has one queue**: one family that draws, computes and presents (`vk_unfit`, `vk_device.odin:145`). Every submission signals one timeline semaphore with the next serial (`vk_submit`, `vk_cmd.odin:271`).
- **Lifetimes ride that serial.** A command buffer holds a reference on each image, buffer and sampler it uses (`vk_cmd_track_*`), dropped when `vk_collect` sees `serial <= completed`. Fences are serials. `vk_wait_for_idle` waits for the last serial.
- **New textures** get their first layout in a setup command buffer that rides the next submission (`vk_setup_cmd`).
- **Render mode's images are already ping-pong.** Each band reads `accum[current]` and writes `accum[1 - current]` and, at the first sample (every sample with a lens), `guides[1 - guide_at]`. Once a sample's last band is in, `path_display` swaps them and runs the denoiser and display (graphics) reading `accum[current]` and `guides[guide_at]`.
- **lavapipe here has one family with one queue** (`vulkaninfo`). Bolt's RTX 3060 Ti has 16 queues in its graphics family plus a compute-only family; Mali-G710 is UNVERIFIED (expected 2 queues in its one family); AMD desktops have 1 graphics queue plus a compute family.

## What changes

### 1. A second queue (Vulkan)
- **Which queue.** At device creation, if the graphics family offers two queues or more, the device asks for two and keeps the second as `vk_state.compute_queue`. Queues of one family share every resource with no ownership transfer, which keeps this step small.
  - A compute-only family (AMD) needs ownership transfers or concurrent sharing for each resource both queues touch. That is left for a later step; such a device runs the split on one queue (below).
- **Its own timeline.** `vk_state.compute_timeline`, `compute_submitted` and `compute_completed`. Two queues cannot signal one timeline, because their work finishes out of order and a timeline's values must only rise.
- **A command buffer knows its queue.** `Vk_Cmd.queue: enum {Graphics, Compute}`. `vk_collect` reads both timelines and recycles a command buffer once its own queue's counter has passed its serial. References, so lifetimes, need no other change. A fence carries the queue too. `vk_wait_for_idle` waits for both.
- **The setup buffer never rides the compute queue.** A compute submission with setup work pending first submits the setup alone on the graphics queue (one empty-ish submission), and waits for it.
- **One queue, split anyway.** When no second queue exists, the compute timeline still exists and compute submissions go to the graphics queue, signalling their own timeline. Nothing overlaps, but every line of the bookkeeping runs. That is how this is checked here under validation, including synchronization validation.
- **Timestamps.** Compute-queue command buffers are not timed in this step: the Render mode span leaves Stats while async compute is on, and the PR says so.

### 2. The seam (`hal.odin`)
- `gpu_acquire_compute_command_buffer(device) -> ^GPUCommandBuffer`: a command buffer for the compute queue (own Vulkan with async compute on); nil elsewhere.
- `gpu_submit_compute(cmd, after: ^GPUFence) -> ^GPUFence`: submits it, waiting first for the graphics work `after` names (nil for none), and returns its fence.
- `gpu_wait_on(cmd, fence)`: makes a graphics command buffer wait, at the compute stage and above, for a compute fence before it runs. The app only adds this once the fence has signalled (it checks with `gpu_query_fence`), so it never stalls the queue; it is there for memory visibility, which a semaphore wait gives and a host check does not.
- `Gpu_Caps.async_compute`: `.Off`, `.Same_Queue` (the split on one queue) or `.Second_Queue`. Exit stat `async_compute=`.

### 3. Render mode (`path.odin`)
- **When on**, `render_frame` records each band into its own compute command buffer and submits it with `gpu_submit_compute`. At most one band is in flight (`pr.band_fence`). A frame whose band has not finished records no band.
- **What a band waits for.** Graphics work that touches what the band writes:
  - the scene build and the tracer's refits (scene buffers, written at the first band of a still view);
  - the last `path_display` and denoiser passes, which read the `accum` and `guides` the band will write (a write-after-read across queues).
  - `pr.graphics_fence` is the fence of the frame that last did either. The band waits on it; it is mostly long finished.
- **What the display waits for.** Once the last band of a sample has signalled, the frame swaps and runs `path_display` as today, after `gpu_wait_on(cmd, pr.band_fence)`.
- **Changes start over safely.** `path_render_reset` keeps the band fence. The next scene build first waits for it (a host wait, only at a change, at most one band), because the build rewrites buffers a band may still read. `path_render_destroy` already waits for idle.
- **Band size.** With overlap, the frame time no longer says how heavy a band is. The band's own time does: from submission to the frame that sees its fence signalled. Under 1.5 frame intervals the rows double; over 3 they halve; the same bounds as today.
- **Determinism.** A pixel's samples depend only on the pixel and the sample, as today; parity stays at 0 px with async compute on.
- **The thumbnail's render** (`thumbnail.odin:427`) keeps the frame's command buffer: it renders off screen, and an interface waiting on it is not the problem.

### 4. App and settings
- **Settings > System > Graphics: Async compute** (Off by default until Bolt's numbers). `--async-compute` / `--no-async-compute` for one run. Shown only where `Gpu_Caps.async_compute != .Off`; the help line says what the second queue does and that SDL_GPU and Metal (for now) do not offer it.
- README and sm-render updated.

### 5. Metal (later, not in this step)
A second `MTLCommandQueue`, an `MTLSharedEvent` per queue as the timeline, and `encodeWaitForEvent`/`encodeSignalEvent`. Metal's automatic hazard tracking does not cross queues, so the same waits are needed. It waits for this step's numbers on the RTX and the Metal trial's progress.

## Size
About 350 lines:

| Part | Lines |
|---|---|
| Vulkan queue, timeline, collect, fences, setup rule | ~150 |
| Seam and caps | ~40 |
| `path.odin` | ~90 |
| App setting, flag, exit stat | ~30 |
| README and sm-render | ~40 |

## Checks
- **Here (one queue, `.Same_Queue`):**
  - `parity_check.py` at 0 px with `--async-compute`, under `--gpu=vulkan --gpu-debug`, with synchronization validation on for the render cases.
  - A render-mode run that orbits, stops and changes the scene mid-sample (a script), under validation: no messages, no leaks, and the samples finish.
  - `check`, `test`, `smoke`, the cross-compiles.
- **Bolt, RTX 3060 Ti, before it is on by default:** render mode on a 1M scene with Half resolution off, orbiting for 10 s, then still for 10 s, with Async compute Off and On. Read `frame_ms` p99 from Stats while orbiting, and the samples reached after 10 s still. Acceptance: p99 lower with On, and samples no fewer.
- **OnePlus Pad:** whether it offers a second queue (exit stat `async_compute=`), and the same A/B if it does.

## Not in this step
- Compute-only families (AMD), with ownership transfers.
- The traced studio (`trace.odin`) and Smooth all on the compute queue. The studio adds its samples inside the frame, so it would need the same split; Smooth all is a one-off wait.
- Metal (section 5).

## Questions for the review
1. Is a second queue of the graphics family worth it, or does NVIDIA only overlap work from its compute-only family? UNVERIFIED either way; the RTX run answers it, and the compute family would then become the first follow-up.
2. Is a host wait at a change (at most one band) acceptable, or should the build go to fresh buffers instead?

## Review (sm-architect, 2026-10-30): approve with changes, all taken
- **No frame fence exists.** `cmd_submit` returns none and the build shares the frame's command buffer. So `gpu_submit_compute` drops `after` and waits on the latest graphics serial already submitted; the frame that builds the scene records no band; a band never waits on a serial not yet submitted (on one queue that would never end).
- **Generations.** Each band carries `pr.generation`; a reset or resize bumps it, and a band of an older one is dropped when its fence signals. Rows advance at submit; the swap, guide flip, `samples += 1` and `path_display` happen in the frame that sees the last band's fence signalled.
- **`gpu_wait_on` waits at ALL_COMMANDS**, since the denoiser and display read in fragment shaders.
- **Every serial names its timeline:** `vk_query_fence`, `vk_wait_for_fences` (one `WaitSemaphores` over both for mixed fences), `vk_wait_serial(timeline, value)`, the setup buffer (graphics), teardown (waits for both, destroys the compute timeline). `frame_serial` and timing slots stay graphics-only, and a band is recorded with no span (`span_open` is global).
- **Setup before a band:** a semaphore wait on the setup's graphics serial, never a host wait.
- **The single-queue split tests lifetimes, collect, fences and host ordering, not cross-queue synchronization:** one queue's barriers cover everything before. So Bolt's RTX run starts with `--gpu-debug` and synchronization validation on the second queue. Optional, taken: a debug tracker in the split recording the last queue and serial to touch each image and buffer, failing a submission that lacks a covering wait.
- **Acceptance measures the right thing:** orbiting restarts render mode and records no band. Measure frame time p99 while a still view converges and the panels are used, the first orbit frame after a still view, and samples per second; plus an Nsight Systems trace to see overlap directly (question 1).
- **Settings:** the switch shows only for `.Second_Queue`; the split is `--async-compute` only.
- **The second caller** (`picture_render`, view panes and the thumbnail window) stays synchronous by choice: `render_frame` gains an explicit `async` parameter.
- **Invariant:** the graphics queue never touches `accum[1-current]` or `guides[1-guide_at]` while a band is in flight; those guides are bound for writing (and change layout) at every band.
- **Question 2:** no host wait and no fresh buffers. The build is skipped (`return true`) until the old band's fence has signalled.
- **Tracer refits** need no wait: the band binds only `pr.buffers`.
- **Build in two steps:** 5.3a backend queue, timelines and fences in the single-queue split, no path changes; 5.3b `path.odin`, the setting and README. Optional, taken: the compute queue at priority 0.5.
