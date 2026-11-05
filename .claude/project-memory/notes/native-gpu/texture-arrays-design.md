# Texture arrays for render mode: design (native GPU plan 5.2, E1)

Status: design for review, 2026-10-30.

## The problem
Render mode traces textured objects with their maps, but only three of them (`RENDER_TEXTURED_MAX`, `path.odin:172`). The kernel `render_trace.comp.slang` names nine samplers, `map0` to `map8`, and picks one with a `switch` (`map_at`, line 206). It does this because indexing an array of textures with a value that differs per pixel is a device feature, and SDL_GPU's fixed binding slots have no arrays. Every textured object after the third shows its material instead, and the Render section says so (`app/render_mode.odin:139`).

## What changes
Under the own Vulkan backend, where the device has descriptor indexing, the kernel reads every textured object's maps from one array: up to 64 objects (192 maps) instead of 3. Everywhere else, today's switch and limit of 3 stay as they are:
- **SDL_GPU:** has only fixed slots.
- **Metal:** SDL_shadercross cannot turn an unsized sampler array into MSL. Tried here, it fails with "Descriptor set index for compute texture-sampler must be 0". Metal needs argument buffers written by us, so its half waits for a later step.

### Device and caps
- `vk_device.odin` enables four `VkPhysicalDeviceVulkan12Features` where offered:
  - `runtimeDescriptorArray`
  - `descriptorBindingPartiallyBound`
  - `descriptorBindingVariableDescriptorCount`
  - `shaderSampledImageArrayNonUniformIndexing`
- lavapipe has all four (vulkaninfo here).
- `Gpu_Caps.texture_arrays: u32` is the most textures one array binding may hold. It is 0 where not offered: SDL_GPU, Metal, or a Vulkan device lacking a feature. Otherwise it is `min(256, maxPerStageDescriptorSamplers - 16, maxPerStageDescriptorSampledImages - 16, maxDescriptorSetSamplers - 16)`, leaving room for a stage's 16 named slots.
- The exit stat is `texture_arrays=`.

### Seam (`hal.odin`)
- `gpu_create_compute_pipeline_array(device, info, capacity) -> ^GPUComputePipeline`:
  - **Under the own Vulkan backend:** the pipeline layout gains a fourth descriptor set (set 3). It holds one binding: `COMBINED_IMAGE_SAMPLER`, `descriptorCount = capacity`, flags `PARTIALLY_BOUND | VARIABLE_DESCRIPTOR_COUNT`.
  - **Elsewhere:** nil with SDL's error set. Callers only ask when `texture_arrays > 0`.
  - The layout cache key gains the capacity.
- `gpu_bind_compute_texture_array(pass, bindings: []GPUTextureSamplerBinding)`:
  - It allocates set 3 from the command buffer's pools, with `VkDescriptorSetVariableDescriptorCountAllocateInfo` set to `len(bindings)`, and writes the textures.
  - It tracks them as the sampler binds do, and marks set 3 dirty so the next dispatch binds it.
  - `transient_check_use` runs on each texture, as for samplers.
  - The pools' `COMBINED_IMAGE_SAMPLER` count grows from 1024 to 4096, so a 192-map set and the usual sets fit one pool.
- Textures in the array are sampled the way the named samplers are: the backend keeps them in their read layout, as `vk_bind_samplers` does. So no new barrier is needed.

### Shader
- The kernel's body moves to the include `render_trace.slang`. Two entry files include it:
  - `render_trace.comp.slang`, with today's nine named samplers and switch (every backend).
  - `render_trace_maps.comp.slang`, which defines `MAP_ARRAY` and declares `[[vk::binding(0, 3)]] Sampler2D maps[]`. `map_at` reads `maps[NonUniformResourceIndex(slot * 3 + kind)]`.
- Its first line is `// vulkan only`. `scripts/shaders_msl.py` then makes no `.msl` for it, and `check` accepts that. Slang raises the SPIR-V profile with `SPV_EXT_descriptor_indexing` on its own; checked here.
- **`Item_Record.tex.w` widens its slot** from 4 bits to 8: slot bits 0–7, view 8–11, maps 12–14. The value for no slot becomes 255. Both variants share the layout from the include. This changes the `.spv` and `.msl` of the switch variant too, so it must pass parity at 0 px.

### Render mode (`path.odin`)
- **Pipeline:** when `caps.texture_arrays >= 3 * 4`, `path_ensure` makes the maps variant with capacity `3 * RENDER_TEXTURED_ARRAY` (64 objects, or fewer if the cap is lower). If that fails, it falls back to the switch variant.
- **Tracking:** `pr.textured_max` holds whichever limit is in force. `tex_meshes` and `tex_stamps` grow to `[RENDER_TEXTURED_ARRAY]`.
- **Binding:** the five named samplers stay. The maps go as one array binding of `3 * textured_count` entries (at least 3, so the set is never empty), instead of the nine slots.
- **App:** `render.render_textured_max(r)` replaces the constant in the Render section's message.

## Size
About 330 lines:

| Part | Lines |
|---|---|
| Vulkan device, layout and binding | ~140 |
| Seam and caps | ~30 |
| Shader split and variant | ~40 (plus moved lines) |
| `path.odin` | ~60 |
| `shaders_msl.py` skip | ~10 |
| README and sm-render | ~30 |
| One test | ~20 |

## Checks (all here; Linux checks are enough per the plan)
- **Parity:** `parity_check.py` at 0 px against the build before, under Vulkan and SDL_GPU. The switch variant's bit layout changed, and the maps variant must draw the same three objects the same.
- **New scene check:** five textured objects in render mode, from the glTF fixtures the import tests use, under `--gpu=vulkan`. The first three must be pixel-identical to the switch path with the same three (`ppm.py diff` of a render-mode dump), and the other two must show their maps (a described PNG).
- **Fallback:** `--gpu=sdl-gpu` keeps 3 and the Render section's message.
- **The usual:** `smoke` under validation, `maccheck`, `iphonecheck`, `androidcheck`.
- **On Bolt's devices (not needed to merge):** RTX speed with many textured objects. On the OnePlus Pad, Mali has descriptor indexing, which the cap will show.

## Not in this step
- Metal argument buffers (tier 2) for the same array. They need our own MSL for the variant, or SPIRV-Cross's argument-buffer mode, which shadercross does not expose.
- Arrays anywhere else, such as the viewport's textured draws. Each viewport draw binds one object's three maps, so there is no limit there to lift.

## Review (sm-architect, 2026-10-30): approve with changes, all taken
- **Split into two steps.**
  - **5.2a:** device features, `texture_arrays` cap, set-3 layout, array binding and seam.
  - **5.2b:** shader variant, `path.odin`, app, README and sm-render.
- **The switch variant keeps its `tex.w` layout.** The wide slot goes in bits 16–23 and is read only under `MAP_ARRAY`. Splitting today's kernel into include plus entry was compiled to a byte-identical `.spv`, so the switch's `.spv` and `.msl` do not change. "None" is CPU-side only, and `path.odin`'s comparisons use `pr.textured_max`.
- **Binding numbers in the maps variant.** The storage buffers' set-0 bindings follow the five named samplers there, so the include takes a base-binding macro, and the pipeline uses `num_samplers = 5`.
- **Darwin.** Load the variant's code only `when ODIN_OS != .Darwin`, since it has no `.msl`.
- **Vulkan binding path.**
  - Write the array as one `VkWriteDescriptorSet` from an image-info array held in `Vk_Cmd`; `Vk_Set_Writer` holds only 32 writes.
  - Bind 4 sets when the layout has set 3, and set `set_dirty[3]` from that.
  - Clear `cmd.sets[3]` when a pass begins, and refuse a dispatch whose array was never bound.
  - Allocate set 3 inside `vk_bind_sets`, like the others.
- **Layouts.** `Vk_Set_Key` gains the array capacity. `vk_set_layout` chains `DescriptorSetLayoutBindingFlagsCreateInfo` for that binding. `Vk_Compute_Layout_Key` gains a seventh field, and the fourth set is filled in.
- **Pools stay at 1024 samplers**, since a 192-map set fits. The allocation loop fails when a fresh pool refuses a set instead of spinning, and the capacity is capped at 1024.
- **The cap** also respects `maxPerStageResources` and `maxDescriptorSetSampledImages`, and reads the features from the Vulkan 1.2 query the device already makes.
- **`PARTIALLY_BOUND` is dropped**, since every element up to the count is written (defaults for missing maps). That is one feature fewer to need.
- **`shaders_msl.py`** skips Vulkan-only shaders in both `--check` and remake, reading a marker from the `.slang` beside the `.spv` on any of its first few lines, so it does not collide with the `fp-mode` line.
- **`spirv-val`** runs on the variant, and its capability flag keeps the build quiet.
- **A one-size `Texture2DArray`** was weighed. It would resample every map and roughly double map memory (about 1 GB for 64 objects of 1024² maps), and it blurs 4K maps in the mode meant for the final image. It may still be the cheaper later answer for Metal and SDL_GPU, as three arrays with few layers.
