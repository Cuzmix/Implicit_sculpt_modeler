# Sculpt on the GPU, P4: masks, HD windows, alphas and drawn falloffs

Status: design for review (2026-11-03). Series: [[gpu-sculpt-plan]] P1 #526, P2 #533, P3 #539 #544 #547 #563. Bolt picked "skip the cones kernel, start P4".

## Why
On Bolt's RTX 3060 Ti a 25M stroke that the GPU takes costs 2.4 ms CPU a frame (CPU path 4.1). But most real strokes never reach the GPU:
- `dab_gpu_takes` refuses any sculptor with `s.mask != nil`. The mask is allocated on the first mask stroke and never freed (only dyntopo and layer masks delete it), so after one mask stroke **every later stroke on that level stays on the CPU**, even with the mask cleared.
- Alphas (`brush.alpha`) and drawn falloffs (`brush.falloff_shape`) are refused.
- HD windows are refused by the app (`lv != levels_current` gives `.Normals`) and by `s.fade != nil`.

What stays refused after P4: Lock plane, Stabilize, Connected, Polish and Stable Smooth, brush kinds beyond the seven, layer recording, dynamic topology, detail skin, hidden triangles, Drag rect, Drag dot and straight-line strokes. Of these, only Stabilize might be worth a later step.

## What changes

### P4a: mask and fade bytes on the GPU (with HD windows)
- **Buffers.** `Mesh_Sculpt` gains `mask` and `fade` storage buffers. Each holds one byte per vertex, packed four to a `uint` (25 MB at 25M for the mask; fade only on an HD window's buffers, the window's size).
  - A buffer is made when its sculptor first has the array. The selected object's buffers are filled by the frame's slice-a-frame upload (the same path as the lookup in #563: the two arrays become a fourth and fifth part).
- **Keeping them current.** The mask changes only on the CPU: mask strokes, mask commands, undo and redo, layer masks. Every one of those marks nodes `.Paint` or `.Shape` stale, so their vertices are in the flush's ranges.
  - `level_upload` already uploads those ranges' packed normals with the mask nibbles. When the buffers hold a mask, it also copies the ranges' mask bytes, rounded out to multiples of four vertices (the neighbours' bytes are copied as they are).
  - Fade is set once, when the window is made (`hd.odin`). Under dyntopo it changes, but dyntopo stays on the CPU. A window with fade uploads it once, then never again.
  - A mask the sculptor frees (dyntopo, layer masks) releases the buffer.
- **Kernels.** `dab_move` and `dab_smooth_apply` multiply by `shield(v)`, which is `sculpt.shield` in the same order: `w = fade/255`, then `w *= (255 - mask)/255`. The record's flags gain `FLAG_FADE` and `FLAG_MASK`. With a flag off, the kernel does not read that buffer, and a 4-byte placeholder is bound for it. The area kernels do not use the shield, as on the CPU.
- **Bindings.** The dab kernels go from 6 to 8 read-only buffers (14 with the read-write ones). Check `maxPerStageDescriptorStorageBuffers` on the Mali-G710 (the Vulkan spec minimum is 4; the current 11 already exceed 8). If the device offers fewer, `caps.gpu_sculpt` is off for it.
- **Lifting the refusals.**
  - Sculpt side: `s.mask != nil` and `s.fade != nil` leave `dab_gpu_takes`.
  - App side: an HD window's strokes take `.Dabs` (the fade was the reason for `.Normals`).
  - `sculpt_gpu_prepare_level` runs for the window's buffers too: both parts of the selected object (the base level and the window) are prepared already.
- **Fake GPU oracle** (`stroke_gpu_test.odin`): `fake_lay` applies the shield. New scenarios:
  - a half-masked mesh;
  - a mask cleared after a stroke (bytes uploaded again);
  - a fade border.
  Each is compared with the CPU path within the existing tolerance.

### P4b: alphas and drawn falloffs
- **Upload per stroke.** At a stroke's begin, the app hands render the brush's alpha (`size²` f32, at most `ALPHA_SIZE²`) and the drawn falloff table (`FALLOFF_STEPS + 1` f32). They go into one `brush_images` storage buffer in `Sculpt_Gpu`, uploaded with the stroke's first dispatch: the alpha at offset 0, the table after it. A stroke changes neither.
- **The record.** It grows from 8 to 10 float4s (160 B), keeping 16-byte rows:
  - `alpha0`: `alpha_up.xyz`, `.w` = alpha size as float bits.
  - `alpha1`: `.x` = the falloff table's offset in floats; `.y`, `.z` and `.w` reserved.
  - Flags gain `FLAG_ALPHA`, `FLAG_MIRROR` and `FLAG_DRAWN`.
- **The alpha frame.** It needs the dab's final area normal (after the tilt), so `dab_reduce` works it out once per dab and writes `au`, `av` and `an` after the area: `areas` grows from 2 to 5 float4s per dab.
  - The arithmetic is `sculpt.alpha_frame`'s, in its order, including the helper axis when `alpha_up` runs along the normal.
  - `inv_r` is `1 / radius`, computed in the kernel. The CPU computes it as `1 / d.brush.radius`, and the record carries the same `radius`.
- **The weight.** `dab_weight` gains both branches, exactly as `sculpt.dab_weight` has them.
  - With an alpha: `alpha_sample(dot(delta, au), dot(delta, av)) * falloff(h*h)`, where `h = dot(delta, an)`.
  - With a drawn falloff: `falloff_drawn(x2)`, which reads the table.
  - `alpha_sample` is a bilinear read of the f32 buffer, with integer indices as on the CPU (`min(int(x), size - 2)`). There is no texture sampler, so it is IEEE-exact.
- **Query margin.** `gpu_margin_once` and `gpu_margin_dab` bound the move by `strength * radius * rate` with a weight of at most 1. Alpha values are 0 to 1: check `alpha_load` clamps imported images, and clamp in it if not.
- **Fake GPU.** It lays alphas through `sculpt.alpha_sample` itself. New scenarios: Draw with the Noise alpha, Clay with a rotated alpha_up, mirror, and a drawn falloff.

## Measuring
- **A/B against the CPU path** (`--gpu-sculpt-sync --ui-dt=0.016667 --export`, with plycmp at 500k). Start-up scripts set the cases:
  - `mask_rect 0 0 0.5 1` before a Draw stroke;
  - `alpha Noise`;
  - `falloff` with a drawn shape;
  - an HD window.
  The expected result is the same tolerance as P2 (Draw at most about 2e-3 over a 98-dab stroke, from the 12-bit packed normals). A masked vertex must not move at all: mask 255 gives a weight of exactly 0.
- **25M on Bolt's PC.** Run the half-masked and alpha cases on both paths: `cpu_ms`, `gpu_sculpt_ms`, `brush_ms`.
- **Costs.**
  - The mask bytes add 25 MB of VRAM at 25M (on top of the 700 MB lookup).
  - A mask stroke's frames copy that stroke's ranges' bytes as well, about 1/12 of what a positions upload copies.

## Not in P4
- Metal (P5) and tablets (P6).
- Compact lookup and on by default (P7).
- Stabilize (it needs the stroke's earlier dabs: a later step if measured worth it).
- Connected (its flood is per dab on the CPU).
- Lock plane (it needs the stroke's first plane: cheap to carry, but rare).

## Risks
- Mali storage-buffer limits (above).
- The mask byte upload racing a GPU stroke. It cannot: a mask change is a CPU stroke or command, and a GPU stroke's own frames upload no mask. The flush guard already syncs owed normals before a CPU change to a node.
- Undo of a mask inside a GPU-taken stroke cannot happen: one stroke at a time.

## After the architect's review (2026-11-03): go with changes
- Three PRs: **P4a** mask + drawn falloff (per-vertex weights; table in a small `tables` buffer); **P4b** HD windows (fade, plus `sculptor_gpu_sync` of the window before `object_hd_leave` destroys its buffers, which would drop unlanded readbacks; `dab_gpu_takes` refuses `s.hide.count > 0` since a base level's fade is the hidden map); **P4c** alphas (Area+Reduce run for every kind when FLAG_ALPHA, Inflate and Smooth included; VDM alphas (`alpha.vectors != nil`) stay refused; frame in dab_reduce with the n == 0 fallback; own A/B tolerance, alpha_up along the normal left out).
- The mask buffer does not ride the lookup's slices: `level_upload` checks `s.mask != nil` every frame for a mesh whose lookup exists, makes the buffer and uploads it whole on that transition (measure it), copies the flush ranges after, releases it when the mask goes nil. FLAG_MASK is set from `s.mask != nil` at record time.
- Shield in the CPU's order: `(dab_weight * shield) * facing`; Smooth `clamp(rate * dab_weight) * (shield * facing)`; keep the `w > 0` skip so Accumulate off writes no height for a masked vertex.
- Check maxPerStageDescriptorStorageBuffers in sculpt_gpu_offered; margin bound by the drawn table's maximum.
- Tests to add: masked Smooth, masked Draw with Accumulate off, layer-mask pick between strokes, mask appearing by undo after the lookup is ready, leaving HD with readbacks in flight, Inflate/Smooth with an alpha, VDM refused.
