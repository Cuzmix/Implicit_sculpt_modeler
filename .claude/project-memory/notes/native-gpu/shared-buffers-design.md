# Shared buffers for loads: design (native GPU plan 2.6, B1)

Status: design for review. Plan reference: B1 in `notes/native-gpu/native-gpu-plan.md`.

## What exists now
- `mesh_buffers_create` (`src/render/renderer.odin:933`) makes three device buffers (positions, indices, packed normals) and fills them through one 16 MB transfer buffer (`TRANSFER_BUFFER_SIZE`).
  - Each 16 MB is copied into the transfer buffer, submitted as a copy pass, and followed by `gpu_wait_for_idle`. That is 25 round trips at 10M (400 MB).
  - It waits for the whole device, including frames still in flight.
- Measured here at 10M (lavapipe, own Vulkan backend): `uploaded in 1520 ms` (the `object_build_from` log line). That is about a sixth of the 7.5 s to get ready to sculpt.
- Every load, Remesh, level switch, HD window, dynamic topology toggle and boolean preview goes through it (`src/app/scene.odin`, `files.odin`, `boolean.odin`).

## What changes
Where the device can map device-local memory, the three buffers are made in that memory. The CPU writes the mesh into them directly: no transfer buffer, no copy pass, no wait.

### Capability
`Gpu_Caps.shared_buffers` is set as follows.
- **Own Vulkan backend: true** when both of these hold:
  - a memory type is `DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT`;
  - its heap is at least half the largest device-local heap.

  That covers UMA (Android Mali, Intel/AMD integrated, llvmpipe) and desktops with Resizable BAR. A desktop without ReBAR has a 256 MB host-visible window, which fails the heap test, so it keeps the copy path and that small heap is never filled.
- **Own Metal backend: true** when `hasUnifiedMemory` (every Apple silicon device), with `MTLResourceStorageModeShared`.
- **SDL_GPU: false.** SDL has no mapped device buffers.

### Seam
One new hal proc, beside `gpu_create_buffer`:

```odin
// A device buffer the CPU can write once, before its first use: `mapped` points at its
// `info.size` bytes, or is nil (and the buffer nil) where the backend cannot, and the
// caller makes a plain buffer and uploads instead.
gpu_create_buffer_mapped :: proc(device, info) -> (buffer: ^sdl.GPUBuffer, mapped: rawptr)
```

- **Vulkan.** `Vk_Buffer.host` gains `.Shared`. `vk_buffer_backing_make` allocates the memory type above and maps it. A failed allocation returns nil, with no fallback inside the backend; the caller falls back.
- **Metal.** A `StorageModeShared` buffer, and `contents` as `mapped`.
- **SDL.** Returns nil, nil.

### The hazard rule, made structural
- The mapped pointer exists only in the call that creates the buffer. It is not stored in `Mesh_Buffers` or anywhere else.
- So the CPU writes the buffer strictly before any command buffer references it. There is no fence or wait to get right, and no debug assert is needed beyond a `#force_inline` scope.
- Afterwards the buffer is an ordinary device buffer. Stroke uploads, `cycle`, the traced studio's storage reads and release all work as today. A Vulkan cycle on such a buffer makes its new backing with the same `.Shared` host kind, so the buffer keeps one memory kind.
- Strokes keep the transfer path, as the plan says: writing a range the previous frame is still drawing would race.

### mesh_buffers_create
When `r.caps.shared_buffers` holds:
- positions and indices are made mapped with `{.VERTEX/.INDEX, .COMPUTE_STORAGE_READ}`, and filled with `copy`;
- normals are made mapped and packed straight into it (`pack_normal`, as `upload_normals_blocking` does).

The copies and the packing are spread over the app's pool when there is one (`Renderer.pool`, from #390), in 4 MB ranges. Each range is disjoint, so this is deterministic.

Any mapped creation that returns nil falls back, for that buffer, to today's path.

The fallback path itself also stops waiting for the whole device: it gains a fence per batch, so a load waits only for its own copies. The plan does not require this, but it is the same function and costs about 10 lines. The fence goes through `render.Fence` (`gpu_submit_command_buffer_and_acquire_fence` / `gpu_wait_for_fences`), which SDL and both backends already provide.

### What 2.6 does not do
- **GPU Smooth all's round trip** (upload, then readback after the dispatch). This is B1's second half. Its readback needs a mapped *download* after a fence on the dispatch, which is a real hazard rule rather than a structural one.

  At 10M on desktop it is a fraction of the smooth itself. On the iPad, GPU Smooth all waits for Metal stage 2 (3.3) anyway, so it goes with 3.3 rather than here.
- Texture uploads (matcaps, environment images, render mode textures) stay on the transfer path. They are small, and images need layout changes.
- Level and LOD index buffers that are made and filled during a stroke (`lod_indices` growth) stay on the transfer path. They are written while drawing.

## Size and checks
- **Size.** About 150 lines:
  - hal and caps: 20;
  - vk: 40;
  - mtl: 20;
  - renderer, with the pool fill and the fence fallback: 70.
- **Checks here.** llvmpipe passes the Vulkan heap test.
  - The `uploaded in … ms` line at 10M before and after, three runs each.
  - `--gpu=sdl` A/B, which must equal today's numbers, since SDL takes the fallback.
  - `parity_check.py` at 0 px under the default Vulkan backend and under SDL.
  - `mesh_check` on a loaded 10M scene.
  - A test of the heap rule in `caps`: the same pure proc, fed memory properties.
- **Exit stats** gain `shared_buffers=` and `mesh_upload_ms` (the most recent).
- **Bolt.**
  - RTX: ReBAR is shown in Stats > Drawing as "Shared buffers: yes"/"no". A 20M load with the line before and after.
  - Android: the same line.
  - iPad: only under `--gpu=metal` (trial).

## Review (sm-architect, 2026-10-30): approve with changes
The hazard claim holds: every write into mesh buffers uses `cycle = false`, and every caller destroys (after `wait_idle`) before it creates. Changes taken into the build:
1. Caps pins the exact memory type index it chose and allocates from it, rather than going through `vk_memory_type`. That way a matching type on a small BAR heap listed first is never picked. Types flagged PROTECTED or DEVICE_UNCACHED_AMD are skipped.
2. The mapped path shares `vk_create_buffer`'s usage translation, including TRANSFER_SRC and TRANSFER_DST, since strokes and the path tracer copy into and out of these buffers.
3. A cycled `.Shared` buffer's new backing is allocated as `.None` (device-local, unmapped), so cycling never fills the small heap.
4. The backend unmaps (forgets) the pointer after the fill: `gpu_buffer_filled(device, buffer)` ends the mapped window, so no mapped pointer outlives creation.
5. The fence-per-batch fallback change is dropped. On one in-order queue it signals when `wait_for_idle` would.
6. The pool fill splits at 64-byte-aligned offsets and never reads mapped memory.
7. `mb.transfer` is still made, because strokes need it. Stats > Drawing shows "Shared buffers: yes/no", and the README says so.
