# A clean GPU abstraction for Sculpt (replacing the SDL_GPU-shaped seam)

Written 2026-11-03 from `odin-sculpt` at `3fa95db`. Bolt asked for "a clean abstraction" after
seeing how much of render still copies SDL_GPU, and turned down bgfx (it offers only what every
backend shares, like SDL_GPU, and has no ray query, async queue, present timing or barycentrics).
This is a design: no code has changed.

## 1. What is wrong with today's seam

`src/render/hal.odin` has 112 `gpu_*` procs with SDL_GPU's names, arguments and types. Our own
Vulkan, Metal and WebGPU backends (9,673 lines) were written to copy SDL_GPU so their pictures
could be checked against it pixel for pixel (`vk_device.odin:12-17`). That check ended on
31 October (#436), and the copy now costs:

| SDL_GPU leftover | Evidence | Cost |
|---|---|---|
| SDL's types as our handles and infos | 1,291 `sdl.GPU*` names in src/render; `gpu.odin:9-12` | Readers think SDL draws; fields we never use ride along |
| SDL's error string as our error channel | 45 `sdl.SetError`, 118 `sdl.GetError` | render needs SDL for something that is not windows |
| Transfer buffers, map/unmap, copy passes and `cycle` flags at every call site | 36 transfer buffers made, 29 maps, 34 copy passes in render | Every upload is ~8 lines of plumbing; the cycle flag is a footgun (`sm-render` "When it looks wrong") |
| Destroy is unsafe while a frame is in flight, so callers wait for the whole GPU | 36 `gpu_wait_for_idle` calls in render | Stalls whenever something is replaced; an AGENTS.md hard rule exists only to cope |
| Fences as objects to acquire, wait and release | 28 `sdl.GPUFence`, `fence_finish` | We already run on timeline semaphores (`vk_cmd.odin:366`) |
| Textures rest in a default layout and go back after each pass; ALL_COMMANDS barriers | `vk_cmd.odin:10-14, 162-188` | Drains between passes |
| Descriptor sets allocated and written per bind | `vk_cmd.odin:545-760` | CPU per draw |
| One `vkAllocateMemory` per backing | `vk_device.odin:577-591` | 4,096-allocation cap on Windows, allocation stalls |
| Uniforms as 4 KiB pushed blocks; SDL's set numbering by stage in all 66 shaders | `VK_UNIFORM_RANGE`; shader headers | A copy per push; binding by stage, not by meaning |
| Metal shaders via SDL_shadercross mapping SDL's sets to SDL's Metal slots | `scripts/shaders_msl.py`, `build_shadercross.py` | A second compiler; slangc already writes our traced kernels' Metal |
| Twelve `gpu_*_offered` procs | `hal.odin` | Caps asked one by one; `Gpu_Caps` already exists (`caps.odin`) |

## 2. Goals and non-goals

Goals: an API named for what Sculpt does, small enough to read in one sitting; safe by default
(no use-after-free, no forgotten barrier, no cycle flag); every native feature we use today kept
(ray query, async compute, present timing, display link, timestamps, barycentrics, indirect count,
transient targets, texture arrays, shared buffers); the same pictures (0 px on the 19 parity scenes).

Not goals: a general engine, a render graph that reorders work, or a fourth backend. The renderer's
passes (`renderer.odin`, `studio.odin`, `path.odin`, ...) keep their logic; only how they speak to
the GPU changes.

Taken from the best of each: sokol_gfx's generational handles and descriptions with defaults;
NVRHI's automatic state tracking; WebGPU's tickets-not-fences and bind-by-group model; Metal's
"just set bytes" for small uniforms.

## 3. The API (package `gpu`, `src/gpu`)

A new package so the abstraction and its backends are separate from the renderer: `src/gpu` holds
`gpu.odin` (the API below), `vk_*.odin`, `mtl_*.odin`, `wgpu_*.odin` (moved from render) and
`shaders_gen.odin` (generated). Only `render` imports `gpu`; `boundary_check.py` enforces it, and
`gpu` imports SDL only for the window it presents to.

### Handles and errors

```odin
Buffer   :: distinct u32 // generational: low 20 bits a slot, high 12 a generation; 0 is none
Texture  :: distinct u32
Sampler  :: distinct u32
Pipeline :: distinct u32 // graphics or compute; the kind is in its slot
Accel    :: distinct u32
Surface  :: distinct u32 // a window's swapchain
Cmd      :: distinct u32 // a recording, valid until submitted
Ticket   :: struct { queue: Queue, value: u64 } // a timeline point; zero is "already done"

Queue :: enum u8 { Graphics, Compute }

Error :: enum u8 { None, Out_Of_Memory, Unsupported, Device_Lost, Invalid }
last_error :: proc() -> (Error, string) // the backend's words for the last failure
```

A stale or released handle fails a lookup (`Invalid`, logged once) instead of crashing. Every
proc that makes something returns `(handle, Error)` and is `@(require_results)`.

### Device, caps and lifetime

```odin
init     :: proc(window: rawptr, want: Want) -> (Caps, Error)  // Want: validation, frames_in_flight, ...
shutdown :: proc()
caps     :: proc() -> ^Caps  // today's Gpu_Caps plus everything the *_offered procs answer

frame_begin :: proc() // retires work the GPU finished; frees what was destroyed before it
destroy     :: proc(h: $T) // deferred: freed once every submission that could use it is done
wait        :: proc(t: Ticket) -> bool
done        :: proc(t: Ticket) -> bool
wait_all    :: proc() -> bool // shutdown and device-lost only
```

`destroy` is always safe, so the 36 waits for the whole GPU go, and the AGENTS.md rule
"`render.wait_idle` before freeing buffers" becomes "destroy any time".

### Resources

```odin
Buffer_Use :: bit_set[enum u8 { Vertex, Index, Indirect, Storage, Storage_Write, Uniform, Accel_Input, Address }; u16]
Memory     :: enum u8 { Device, Shared /* device-local and mapped */, Upload, Readback }

Buffer_Desc :: struct { size: u64, use: Buffer_Use, memory: Memory, name: string }
make_buffer :: proc(d: Buffer_Desc) -> (Buffer, Error)
mapped      :: proc(b: Buffer) -> []u8 // Shared, Upload and Readback buffers only

Texture_Desc :: struct {
	size: [3]u32, levels, layers: u32, format: Format, samples: u8,
	use: bit_set[enum u8 { Sampled, Storage, Color_Target, Depth_Target, Transient }; u8], name: string,
}
make_texture :: proc(d: Texture_Desc) -> (Texture, Error)
make_sampler :: proc(d: Sampler_Desc) -> (Sampler, Error)
```

`Format` is our own enum of the formats Sculpt uses (about 15), not SDL's 100.

### Moving data

```odin
upload        :: proc(c: Cmd, dst: Buffer, offset: u64, data: []u8)
upload_texture :: proc(c: Cmd, dst: Texture, level, layer: u32, region: Rect3, data: []u8)
copy          :: proc(c: Cmd, src: Buffer, src_offset: u64, dst: Buffer, dst_offset, size: u64)
copy_texture  :: proc(c: Cmd, src, dst: Texture_Region)
download      :: proc(c: Cmd, src: Buffer, offset, size: u64) -> Readback // ready after the cmd's ticket
download_texture :: proc(c: Cmd, src: Texture_Region) -> Readback
readback      :: proc(r: Readback) -> (data: []u8, ready: bool) // valid until the next frame_begin
mipmaps       :: proc(c: Cmd, t: Texture)
```

Uploads go through a per-frame staging ring the backend owns (grown on demand, then reused), so
transfer buffers, map/unmap, copy passes and `cycle` disappear from render. A write to a buffer the
GPU may still read is ordered by the tracker (below), not by cycling; where render wants
double-buffering (the brush's dirty ranges) it keeps two buffers itself, visibly.

### Shaders and bindings

Each `.slang` file is compiled by slangc for every target (SPIR-V, Metal, WGSL) with reflection;
`scripts/shaders_gen.py` writes `shaders_gen.odin`: one `Shader` value per entry point with its
blobs and its binding layout, and named slot constants:

```odin
// generated
Cull_Write :: struct { records, groups, totals, indirect: Slot } // from the .slang's parameter names
CULL_WRITE: Shader_Info
```

Bindings are set by name-checked slots, grouped by how often they change, which the shaders
declare with Slang's `ParameterBlock`s:

- group 0 `Frame`: camera, lights, environment; set once a frame (`set_frame`).
- group 1 `Pass`: what a pass shares (targets read, material maps).
- group 2 `Draw`: per draw or dispatch, pushed (Vulkan push descriptors, Metal `setBuffer`, WebGPU a
  cached bind group).
- push constants up to 128 bytes for small per-draw values (`push(c, &u)`); larger uniforms go in the
  frame's uniform ring (`uniform(c, data) -> Buffer_Range`).

```odin
Bind :: struct { slot: Slot, buffer: Buffer, offset, size: u64, texture: Texture, sampler: Sampler, accel: Accel, write: bool }
bind :: proc(c: Cmd, group: u8, binds: ..Bind)
```

The `write` flag (or the reflection's `RW` type) is what the tracker reads.

### Recording, passes and synchronisation

```odin
cmd_begin   :: proc(q: Queue = .Graphics) -> (Cmd, Error)
submit      :: proc(c: Cmd, after: ..Ticket) -> Ticket   // `after`: cross-queue waits
render_begin :: proc(c: Cmd, d: Render_Pass) // colours, depth, resolve, load/store, clear
render_end   :: proc(c: Cmd)
compute_begin :: proc(c: Cmd)
compute_end   :: proc(c: Cmd)
set_pipeline, set_vertex_buffers, set_index_buffer, set_scissor, set_viewport
draw, draw_indexed, draw_indirect, draw_indexed_indirect(_count), dispatch
scope :: proc(c: Cmd, name: string, tag := Timestamp_Tag.None) -> Scope_End // `defer`-able debug group + timestamps
```

The tracker keeps each resource's last access (stage, read or write, layout). Binding, drawing,
dispatching, copying and `render_begin` declare accesses; the backend emits the narrowest barrier
needed just before the command that needs it (Vulkan `CmdPipelineBarrier2` with exact stages,
layouts tracked per texture and level; Metal encoder boundaries and `memoryBarrier` within compute;
WebGPU does its own). Two dispatches writing and then reading the same buffer get a barrier between
them automatically; independent dispatches get none. `barrier(c)` stays as an escape hatch.

### Windows and presenting

```odin
surface_make    :: proc(window: rawptr) -> (Surface, Error)
surface_config  :: proc(s: Surface, mode: Present_Mode, frames_in_flight: u8) -> bool
surface_acquire :: proc(c: Cmd, s: Surface, wait: bool) -> (target: Texture, size: [2]u32, turns: u8, ok: bool)
present_timing, present_input, present_times, display_link_* // as today, on Surface
```

The submit of a command buffer that acquired a surface presents it.

### Ray tracing, timestamps, async

Kept as today's procs, typed: `build_blas(c, Blas_Desc) -> Accel`, `build_tlas`, `buffer_address`;
`timestamps_frame(out)`; the compute queue is `cmd_begin(.Compute)` plus `submit(c, after = t)`.

## 4. The cull example, before and after

Before (`gpu_cull.odin:128-157`, 30 lines): build a `GPUStorageBufferReadWriteBinding`, begin a compute
pass per kernel, bind storage buffers by pointer array and count, push a uniform block, end, then a
transfer buffer and a copy pass for the readback.

After:

```odin
compute_begin(cmd)
gpu.set_pipeline(cmd, g.count_pipeline)
gpu.bind(cmd, 2, {CULL_COUNT.records, c.records}, {CULL_COUNT.groups, c.groups}, {CULL_COUNT.totals, c.totals, write = true})
gpu.push(cmd, &u)
gpu.dispatch(cmd, groups, 1, 1)
gpu.set_pipeline(cmd, g.write_pipeline)
gpu.bind(cmd, 2, {CULL_WRITE.records, c.records}, {CULL_WRITE.groups, c.groups}, {CULL_WRITE.totals, c.totals}, {CULL_WRITE.indirect, mb.indirect, write = true})
gpu.dispatch(cmd, groups, 1, 1) // the tracker puts the totals barrier here
compute_end(cmd)
s.header = gpu.download(cmd, mb.indirect, 0, CULL_HEADER)
```

## 5. Migration (each step 0 px on the 19 parity scenes, smoke clean under validation)

| Step | What | Size | Risk |
|---|---|---|---|
| G0 | Measure: `encode_ms` exit stat (CPU recording time), count of whole-GPU waits, Vulkan allocation count; gpubench rows here and on Bolt's 3060 Ti | small | none |
| G1 | `src/gpu` package: handles, errors, caps, deferred destroy, our `Format`; implemented over today's backends moved from render; render switches its types (mechanical, by file group, two PRs) | large, mechanical | low |
| G2 | Uploads and readbacks through rings; transfer buffers, map/unmap, copy passes, `cycle` removed from render; the 36 waits removed | medium | medium: ordering; parity + validation catch it |
| G3 | Shader pipeline: slangc for all three targets with reflection, `shaders_gen.odin`, named slots, `ParameterBlock` groups; shadercross deleted | large (66 shaders) | medium: 0 px per shader is the test |
| G4 | Tickets replace fences; `submit(after)` replaces the compute wait plumbing | small | low |
| G5 | Vulkan internals: tracker barriers, suballocator (256 MB blocks desktop, 64 MB tablets), push descriptors, push constants | medium | perf: gpubench A/B, 3 alternating runs, on lavapipe and Bolt's PC; ships only if not slower |
| G6 | Metal internals to the same model (encoders from the tracker, `setBytes`, heap suballocation) | medium | unverified here: compile only; Bolt's iPad `try_it.py` decides |
| G7 | WebGPU internals; AGENTS.md section 5 rules, `sm-render`, README and `boundary_check.py` rewritten for `gpu` | small | low |

The app's side (`render.Cmd`, `render.Texture`, `render.Fence`, `wait_idle`) shrinks to `Cmd`,
`Texture`, `Ticket`; `src/app` changes in about a dozen lines.

## 6. Decisions to confirm (defaults in bold; work starts on the defaults)

- Package: **new `src/gpu`, imported only by `render`** (alternative: stay inside render).
- Handles: **generational ids** (safe, debuggable) rather than pointers.
- Synchronisation: **automatic tracking with a `barrier` escape hatch** rather than explicit barriers
  everywhere.
- Vulkan: **require `VK_KHR_push_descriptor`** with the 1.3 floor (offered by desktop drivers,
  Mali-G710, Adreno 6xx+); a device without it is refused like a device without 1.3.

## 7. What it does not promise

Speed: G1-G4 are about clarity and safety. G5's barrier, allocation and descriptor work should cut CPU
recording time and remove allocation stalls, but nothing here has measured how much; G0 does, and a G5
change that is not faster on Bolt's PC is dropped. The Metal side cannot be run here.

## G0 baseline (2026-11-03, release build, SwiftShader in the cloud container)

| Run | frame_ms p50 | encode_ms (total) | cmds | ms per cmd | idle waits | fence waits | allocations | MB |
|---|---|---|---|---|---|---|---|---|
| 500k, `--orbit --frames=120` | 480 | 1969 | 282 | 6.98 | 2 | 41 | 91 | 406 |
| 500k, `--bench-stroke=120` | 193 | 1998 | 250 | 7.99 | 2 | 10 | 56 | 226 |
| 2M, `--orbit --frames=120` | 2002 | 3782 | 310 | 12.20 | 2 | 69 | 119 | 634 |
| 2M, `--bench-stroke=120` | 217 | 3934 | 250 | 15.74 | 2 | 10 | 56 | 284 |

Reading: whole-GPU waits are rare while working (2 a run, at start-up and exit); the 36 call sites are
on resize, load and teardown paths, so G2's win is clarity, not frame time. Fence waits grow with
orbiting (readbacks and culling). Allocations are one per buffer or texture (56-119 a run). SwiftShader
records on the CPU, so recording time here is mostly the driver's; Bolt's 3060 Ti numbers decide G5.
