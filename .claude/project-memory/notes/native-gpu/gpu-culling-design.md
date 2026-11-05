# GPU culling: design (native GPU plan 2.3, for step 2.4)

Status: design for review. Step 2.4 builds it. Plan reference: B2 in `notes/native-gpu/native-gpu-plan.md`.

## What exists now
- `prepare_draws` (`src/render/renderer.odin`) runs on the CPU, before the render passes, once for each draw pass of a frame. A partial redraw calls it with a narrowed clip, and so do the full view, `screen_pass` and the view windows.
- For each `Draw_Item` that can be culled, it runs one of:
  - `geom.cull_chunks_grouped`: first the groups of `CHUNK_GROUP` = 64 chunks, then each chunk of a surviving group;
  - `geom.cull_chunks`, when there are no groups (dynamic topology, voxel surfaces);
  - `geom.cull_lod`, while simplified drawing is on.
- The visible chunks are merged into runs that sit next to each other in the index buffer. One `GPUIndexedIndirectDrawCommand` is written per run, through a transfer buffer and a copy pass, into `mb.indirect`.
- `draw_item_triangles` then issues one `draw_indexed_primitives_indirect` with `draw_count` = number of runs. The CPU sums `stats.triangles` from the runs.
- Cost (sculpt-big-meshes, 2026-10-25, grouped culling): about 0.1 ms for a close-up and 0.95 ms for a whole view at 50M, growing with the chunk count. Step 2.1's `cull_ms` table gives the RTX numbers.

## What changes
For the common case, a compute pass writes the commands in place of the CPU:
- an object with chunk groups,
- no hidden parts,
- simplified drawing not in use this pass.

The CPU no longer walks the chunks, and no commands are uploaded. Everything else keeps today's CPU path:
- `cull_lod`, so orbiting with Simplify on;
- dynamic topology (no groups);
- voxel surfaces;
- hidden parts;
- SDL_GPU.

### Capability
`Gpu_Caps.gpu_cull` is true under the own Vulkan backend when the device has `multiDrawIndirect` (`vk_state.multi_draw`), the timeline and compute already used.

Without multi-draw, the backend issues indirect draws one by one, and one command per chunk would mean 100k draw calls, so the cap stays false there.

It is false under SDL_GPU. SDL issue #14754 is a missing barrier between a compute write and an indirect draw in SDL's Vulkan driver; it stays false there until that is fixed.

It is false under the own Metal backend until its compute stage (plan 3.3) exists.

On Android it starts false until the OnePlus Pad's `gpubench` shows that 20k to 100k empty commands cost less than the CPU walk. Mali's command processor reads every command.

A Stats > Drawing switch, **Cull on the GPU** (default on where offered), and `--cpu-cull` give the A/B. The exit stats gain `gpu_cull=`.

### Data on the GPU (new buffer layout)
Per `Mesh_Buffers`, two storage buffers (`COMPUTE_STORAGE_READ`), created on first use and grown like `indirect_ensure`:

```
// cull.comp.slang and geom.Chunk agree on this, 48 bytes, std430:
struct Gpu_Chunk {
    float4 lo;    // xyz bounds.lo, w cone_cutoff
    float4 hi;    // xyz bounds.hi, w asfloat(first_index)
    float4 axis;  // xyz cone_axis, w asfloat(index_count)
};
```
- `chunk_records`: one `Gpu_Chunk` per chunk.
- `group_records`: one per group (`sculptor_chunk_groups`).

At 50M, with about 100k chunks, that is 4.8 MB plus 75 KB.

`mb.indirect` gains `COMPUTE_STORAGE_WRITE` usage. It holds one command per chunk, `chunk_count` × 20 bytes, which is 2 MB at 100k chunks.

### Keeping the records current without walking them
- **Group stamps.** The sculptor gains `group_stamps: []u64`, one per group, and a counter `chunk_stamp`.
  - `chunk_touched`, which already runs on every chunk write, sets `group_stamps[id / CHUNK_GROUP] = chunk_stamp`, after one increment per dab (in `apply_dab`'s end and the other callers of `chunk_touched`).
  - A rebuild of the chunk set (level change, rebuild, undo swap) replaces the sculptor's chunks, and a new `chunk_layout` id marks that.
- **Draw_Item fields.** `Draw_Item` gains `group_stamps: []u64` and `chunk_layout: u64`.
- **What each Mesh_Buffers remembers.** Each `Mesh_Buffers` remembers the `chunk_layout` and the largest stamp it has uploaded.
- **What prepare_draws uploads:**
  - If the layout differs, it uploads every record.
  - Otherwise it scans the group stamps (1.5k entries at 100k chunks) and uploads the 64 chunk records and the group record of each group stamped after its own. During a stroke that is a few groups.
- **Many views.** Each `Mesh_Buffers` keeps its own stamp, so several views of one object (view windows, thumbnails of the same level) stay right without a shared dirty list.

### The kernel (`cull.comp.slang`, one new shader)
- **Dispatch.** One workgroup of 64 threads per group, one thread per chunk. `numthreads(64,1,1)` equals `CHUNK_GROUP` on purpose.
- **Uniforms** (per item and pass, pushed as compute uniform data):
  - the six frustum planes from `geom.frustum_planes(narrow * proj * view * model)`, computed on the CPU exactly as now;
  - the eye in mesh space;
  - the chunk count.
- **Per thread:**
  - Thread 0 tests the group record (`aabb_outside`, `chunk_backfacing`, the same expressions as `geom`) and shares the verdict.
  - Every thread tests its own chunk unless the group failed.
  - It writes `{index_count if visible else 0, 1, first_index, 0, 0}` to `commands[chunk]`.
- **No compaction:** `draw_count` is the chunk count, and invisible chunks are zero-count commands. Step 2.5 adds `drawIndirectCount` with a compacted list where the device offers it.
- **Stats.** The kernel adds visible triangles, frustum-culled and back-culled counts to a 16-byte stats buffer with atomics. A ring of four small download buffers reads it back when that frame is done, the same pattern as timestamps.
  - `Viewport_Stats.triangles` and the culled counts are therefore a few frames late under GPU culling.
  - Stats > Drawing says "a few frames late" on that row. The gpubench Triangles table takes the late values, which are the same in a still or steady case.

### Ordering
A frame may cull one item several times (partial redraw's narrowed pass, then the full pass) into the same `mb.indirect`.

The own Vulkan backend puts a conservative all-commands memory barrier between passes (`vk_memory_barrier` in `vk_cmd.odin`). That orders:
- the compute write before the indirect read (`DRAW_INDIRECT` and `INDIRECT_COMMAND_READ` are covered by `ALL_COMMANDS` and `MEMORY_READ`);
- the next dispatch's write after the previous draw's read.

No new barrier code is needed. The compute pass must sit outside any render pass, which `prepare_draws` already requires of its copy pass.

### The exact-pixel rule
- **Frustum.** The planes are computed on the CPU and the tests are the same expressions. A difference can only come from float rounding on a chunk whose box touches a plane to within rounding. Either way that chunk has no pixel inside, since the rasterizer clips the same triangles.
- **Back faces.** The back-face test is conservative (`CONE_SLACK`). A chunk the two disagree on has every triangle facing away within the slack, and the mesh pipelines cull back faces (`cull_mode = .BACK`), so no pixel changes either.
- **Checks.** `parity_check.py` must stay at 0 px with GPU culling against the CPU build.
- **`--dump-cull`.** This debug flag reads the commands back once at exit, expands the CPU's runs to chunks, and prints:
  - `cull_chunks=` and `cull_mismatch=` (chunks the two disagree on), expected 0 on llvmpipe;
  - the planes' margin for any mismatch.

### What 2.4 does not do
- GPU LOD selection (`cull_lod`).
- Hidden parts (a hidden bit in the record later, if wanted).
- Dynamic topology and voxel surfaces.
- Metal.
- Compaction (2.5).
- Occlusion culling.

### Size and tests
- **Size.** About 450 lines:
  - `src/render/gpu_cull.odin`: buffers, upload by stamps, dispatch, stats ring, `--dump-cull`.
  - `cull.comp.slang` with its `.spv` and `.msl`.
  - The sculptor's stamps.
  - The app's switch, flag and exit stats.
- **Tests:**
  - `sculpt`: `group_stamps` move only for touched groups; serial and parallel dabs stamp the same groups.
  - `geom`: a `Gpu_Chunk` packing round trip.
  - Here on llvmpipe: `cull_ms` at 10M before and after, `cull_mismatch=0` on the parity scenes and a 10M orbit, and `parity_check.py` at 0 px.
- **Bolt:** RTX at 20M and 50M, `cull_ms` and `frame_ms` with and without `--cpu-cull`, and `gpu_viewport_ms` from step 2.2 to see what the empty commands cost.

## Review (sm-architect, 2026-10-30): rework

The review found that the barriers, the exact-pixel argument (every pass that reads `mb.indirect` culls back faces) and the seam all hold. It also found three problems.

1. **Stamps.**
   - Chunk records are written in `sculptor_flush`, not in `apply_dab`. Undo and redo, posing, after-stroke cones and level syncs change them with no dab, so stamps counted per dab would miss them.
   - Fix: stamp serially in `sculptor_chunk_groups`, once per call that remakes any group, and return groups, stamps and layout from that one call.
   - Fix: `chunk_layout` comes from one counter for the whole package, because level buffers move between levels.
2. **The default orbit is not covered.** Simplify is on by default and `lod_px > 0` while the view moves. So full redraws during an orbit take `cull_lod`, which this design leaves on the CPU, and the 0.95 ms whole-view cost is that case.
3. **Stats mix passes.** `prepare_draws` runs for the partial pass, the camera-depth pass and view windows, so one atomic stats buffer would sum them all. The "none, view unchanged" row reads `triangles == 0`.

Smaller points:
- Record uploads must use `cycle = false`.
- With one writable-buffer binding per item, it is one compute pass per item; the alternative is a shared indirect buffer.
- `geom.Chunk` is already 48 bytes, so no repacking is needed (`#assert`).
- Empty commands may cost the GPU more than the CPU walk saves, so compaction (2.5) should come with 2.4, or an RTX gate should stand before shipping.

**Simpler first step the review proposes:**
- Run `cull_chunks_grouped` and `cull_lod` in parallel over chunk groups with `jobs.parallel_ranges`: one run list per range, then one serial join that merges adjacent runs.
- It is deterministic and about 60 lines, with no shader, no new buffers and no late stats.
- It covers Simplify-on orbits, SDL_GPU, Metal and Android.
- Build it first as the baseline, and build GPU culling only if the RTX shows the walk still costs enough to matter.
