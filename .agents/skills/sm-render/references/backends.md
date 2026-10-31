# The GPU backends in detail (sm-render)

Read from sm-render's Rules when a change touches a backend itself (`vk_*.odin`, `mtl_*.odin`, `hal.odin`) or one
of the capabilities only they offer. SDL_GPU is retired: these two backends are the only ones, Metal on Darwin and
Vulkan everywhere else, chosen at compile time in `hal.odin` (`when METAL`).

- The Vulkan backend (`vk_device.odin`, `vk_resources.odin`, `vk_cmd.odin`, `vk_swapchain.odin`) was written to mirror
  SDL_GPU's own Vulkan backend (`deps/sdl3-src/src/gpu/vulkan/SDL_gpu_vulkan.c` is the reference): the same descriptor sets per
  stage, uniforms as dynamic uniform buffers of 4096 bytes from a per-command-buffer arena, default layouts per usage
  that passes leave and restore, cycling by backings, deferred destruction by refcount, a flipped viewport, dynamic
  rendering and a timeline semaphore whose serials are the fences. It needs Vulkan 1.3 with dynamicRendering,
  synchronization2, timelineSemaphore and independentBlend (the Android manifest asks for 1.3 too); without them
  `renderer_init` returns false with the reason in `render.backend_error`, and the app shows it in the system's
  message box (`graphics_failed_text`, `platform_alert`) and ends: there is no fallback. `backend_select` loads
  the Vulkan loader before the window is made, as SDL makes Vulkan windows with it.
  A `vk_*` proc takes its struct parameters `#by_ptr` exactly as the `gpu_*` wrapper does, or the values arrive as
  garbage. Under `--gpu-debug` it runs the validation layer with synchronization validation and every message fails
  the run (`render.validation_errors`); a render change that must not move a pixel passes
  `parity_check.py --compare <old build's run>` at 0 px.
- The Metal backend (`mtl_device.odin`, `mtl_resources.odin`, `mtl_cmd.odin`, `mtl_swapchain.odin`, `#+build darwin`)
  was written to mirror SDL_GPU's own Metal backend (`deps/sdl3-src/src/gpu/metal/SDL_gpu_metal.m`): vertex buffers at buffer 14+,
  uniforms at buffer(i) sent by `set*Bytes` at draw time (4096 bytes a slot), vertex storage buffers after the
  uniforms, fragment textures and samplers at their slot, no viewport flip, cycling by backings and serials as the
  fences. Metal tracks hazards, so there are no barriers. Count objects by hand: a `new*`/`alloc` result is ours to
  release, an autoreleased one (command buffer, encoder, drawable) is retained while kept, and every proc opens
  `NS.scoped_autoreleasepool()`. The pinned Odin asserts ("missing procedure 'objc_lookUpClass'") on any objc
  message unless the package implements an objc class, which `Mtl_Objc_Anchor` does; keep it. Compute mirrors SDL's
  slots too: uniforms at buffer 0+, then read-only and read-write storage buffers; sampled textures and samplers at 0+,
  then read-only and read-write storage textures (each a view of one level and layer, made when the pass begins and
  released when it ends); bindings reach the encoder at dispatch. It is the only backend on Apple's platforms and
  has drawn on an iPad and a Mac; `maccheck` and `iphonecheck` only compile it here. `backend_fail` keeps a
  backend's reason for `backend_error`.
- What a device and backend can do is `render.Gpu_Caps` (`caps.odin`), filled by `caps_fill` after the device is made
  and read by the app through `render.caps`; a switch is set only once the backend holds what it needs, so the app
  branches on caps, never on a backend's name. A new capability is a field there plus one `gpu_*` proc with an
  Vulkan and a Metal answer (`gpu_set_allowed_frames_in_flight`, set between frames by `frame_pace`).
- Async compute (`Gpu_Caps.async_compute`, design notes/native-gpu/async-compute-design.md): a second queue of the
  graphics family (`vk_state.compute_queue`, else the same queue as `.Same_Queue`) with its own timeline
  (`compute_timeline`); `Vk_Cmd.queue` and `Vk_Fence.queue` say which timeline a serial counts on (`vk_serial_done`,
  `vk_wait_serial(serial, queue)`, `vk_wait_for_fences` waits on both). A compute submission waits for every graphics
  serial so far and never carries the setup buffer (submitted first on graphics); graphics reads a band's output only
  after `gpu_wait_on` (ALL_COMMANDS). Under --gpu-debug `vk_check_compute_writes` fails a graphics submission using
  what compute wrote without such a wait, which one queue's barriers hide from the layer. Compute-queue command
  buffers are untimed and hold compute passes only. Render mode (`render_frame`'s `async`): one band in flight
  (`band_fence`), `generation` drops a stale band, no band in a frame that builds the scene, sample counting at
  collection; pictures stay synchronous.
- Ray query (`Gpu_Caps.ray_query`, design notes/native-gpu/ray-query-design.md): the own Vulkan backend enables
  `VK_KHR_acceleration_structure`, `VK_KHR_ray_query` and buffer device addresses where all are offered. Build inputs
  are buffers made with `accel_input` (`gpu_create_buffer`/`_mapped`), which alone get the device-address usages.
  `gpu_build_blas` (a geometry per triangle run, opaque or not; a refit only with the same geometries and vertex
  count, else a new structure the caller swaps in) and `gpu_build_tlas` (always a fresh build, its memory reused
  when the instance count matches) record on the graphics queue outside passes, barriers both sides, one shared
  scratch buffer (`vk_accel.odin`). `Vk_Accel` counts command buffers and the top levels holding it.
  `gpu_create_compute_pipeline_traced` puts the structure at set 3 binding 0 and a texture array, if any, at
  binding 1 (a variable-count binding must be last). `--gpu-debug` runs `ray_query_check` (`ray_query.odin`)
  at device creation; a wrong answer is a validation error.
  The traced studio uses it when `Renderer.ray_query` (Settings > Graphics > Ray tracing hardware): `trace_prepare_rq`
  keeps a `Trace_Mesh.blas` over the shown runs merged by opacity (not opaque if the CPU indices repeat a corner or
  `hidden_stamp != 0`), keyed by geometries, index_version, hidden_stamp and vertex count (else refit, rebuilt after
  `BLAS_REFITS_MAX`), and a top level per view, instance number = table row. `studio_trace_rq.comp.slang` traces once
  in world space and confirms non-opaque candidates by reading indices through `gpu_buffer_address` (Slang pointers,
  so `shaderInt64` is required); the tables are rewritten every sample since an upload's cycle moves the address.
  Any refusal returns the view to the walk, whose CPU trees are not built for the studio while it runs.
  The caller makes its kernel first (`trace_rq_kernel`, `path_rq_kernel`) and passes `ray_query`; `tr.rq` says if
  it took. Render mode (`render_trace_rq` / `render_trace_maps_rq`, `RAY_QUERY` in `render_trace.slang`) shares the
  meshes' BLASes, its own TLAS numbers instances like `placed` (same filter, same order), and `order` holds each
  item's geometries' merged first triangles from `offs.z`, so `tri = order[offs.z + geometry] + primitive` and
  non-opaque candidates are confirmed from the merged `indices`. Its pixels differ from the walk's by rounding
  (~0.06% at 4 samples): compare with `parity_check.py --tolerance`. A graphics submission that rewrites a structure
  in place (`Vk_Cmd.accel_writes`) waits for the last compute submission that traced it (`Vk_Accel.compute_read`).
- Metal ray tracing (6.4, notes/native-gpu/metal-ray-tracing-design.md, `mtl_accel.odin`): offered where
  `supportsFamily(.Metal3) && supportsRaytracing`; `app.ray_query` defaults off on Darwin (settings v11 turns an old
  file's on off once). A `// ray query` first line makes `shaders_msl.py` write `name.comp.metal` with slangc's Metal
  target (not shadercross, which pins MSL 2.1); its second line `// slots s=T:S rt= wt= rb= wb= u= a=` maps SDL_GPU's
  order to slangc's slots, from both targets' `-reflection-json`; `Mtl_Compute_Pipeline.slots` carries it (every
  other pipeline gets SDL's own table), and the entry is `main_0` (`RQ_EXT`, `RQ_ENTRY` in `shaders.odin`).
  `render_trace_maps_rq` stays Vulkan only (texture arrays). Builds use a `MTLAccelerationStructureCommandEncoder`
  per build outside passes, a fresh scratch each, refit in place (nil destination); instances are UserID descriptors
  (68 bytes). At dispatch each instanced BLAS and each buffer read through `gpu_buffer_address` (`Mtl_Cmd.addressed`)
  is `useResource`d, since Metal does not track what is reached only through the TLAS or an address; `Mtl_Cmd.kept`
  retains structures, scratch and instance buffers until the command buffer finishes. `ray_query_trusted` runs the
  ray query check once before Metal's first traced kernel and keeps the walk if it fails (logged, not a validation
  error). Nothing of it has run on a device from the container: verify with `parity_check.py --tolerance 0.2`.
- GPU culling (`gpu_cull.odin`, `Gpu_Caps.gpu_cull`: own Vulkan with multiDrawIndirect + drawIndirectCount, not on
  lazily-allocated-memory tile GPUs): `prepare_draws` hands an item with chunk groups, no `hidden`, no simplify to
  `cull_count`/`cull_write` (`cull.slang`, the CPU's tests); commands after a 20-byte header (count, triangles,
  frustum, back) in `mb.indirect`, drawn with `gpu_draw_indexed_primitives_indirect_count`. The GPU copy of the
  chunks (`Mesh_Cull`) re-uploads only groups whose `sculptor_chunk_stamps` stamp is newer, all on a new layout.
  Stats come back `CULL_SLOTS` frames late, per pass number in the frame (`gpu_cull_frame` each frame).
- Present timing (`Gpu_Caps.present_timing`, `vk_present_learn` in `vk_swapchain.odin`): the own Vulkan backend's
  waiting acquire under vsync waits for the present `frames_in_flight` back to be on screen (`VK_KHR_present_wait`),
  or reads `VK_GOOGLE_display_timing` on Android; the app tags a present with `render.present_input` before the submit
  and takes `render.present_times` after the acquire. Only the main window paces (view windows acquire without
  waiting). lavapipe offers neither extension, so in the container only the `.None` path runs. The own Metal backend
  answers `.Presented_Handler`: `mtl_present_log_add` registers each drawable before `presentDrawable`, and Metal's
  handler (on its own thread, `context` set, under the log's mutex) records the time or a dropped frame. Logs live in
  `mtl_state.present_logs` and outlive windows, since a handler can come after its window is released; never free one
  while the device lives. One frame in flight also means `maximumDrawableCount` 2 (`mtl_layer_drawables`).
  Pace with the display (`mtl_link.odin`, opt-in `mtl_state.link_wanted`) is a `CAMetalDisplayLink` on its own thread,
  reached through `objc_send` with every selector checked; the delegate keeps one drawable only while `keep`, else
  `nextDrawable` would wait on it. Untested on Apple hardware: change it only with an iPad's Pen to screen numbers.
- Pre-rotation (Android, own Vulkan, `vk_pick_transform`): a swapchain image may be turned from the window
  (`swapchain_turns`); `Vk_Window.width/height` stay the window's. Anything new that draws into a swapchain must turn
  with `ui_pass_draw`'s `turns` (the vertex uniform's zw and the scissor remap); draw into an offscreen target instead.
