# Transient render targets: design (native GPU plan 4.2, D1a)

Status: design for a short review. The load/store audit (4.1, `load-store-audit.md`) found every pass already correct. What is left is memory: one-shot passes still allocate depth textures they never store.

## What changes
A texture can be made **transient**: its contents live only inside one render pass. The CPU never copies it, no shader samples it, and no pass loads or stores it. A tile GPU then keeps it in tile memory and never backs it with real memory.
- **Metal:** `MTLStorageModeMemoryless` (every Apple GPU family).
- **Vulkan:** `VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT` bound to `LAZILY_ALLOCATED` memory where a type has it (Mali, Adreno, PowerVR). Elsewhere it falls back to device-local memory. Desktops and llvmpipe have no lazily allocated type, so there it is an ordinary allocation with a narrower usage.

### Seam and caps
- `gpu_create_texture_transient(device, info) -> ^sdl.GPUTexture`, beside `gpu_create_texture`. `info.usage` must be COLOR_TARGET and/or DEPTH_STENCIL_TARGET only.
  - **Vulkan:** the usage is the attachment bits plus TRANSIENT, with no TRANSFER_SRC/DST and no SAMPLED (`vk_create_texture` adds those to every texture today). The memory type is LAZILY_ALLOCATED if offered, otherwise DEVICE_LOCAL.
  - **Metal:** `StorageModeMemoryless`.
  - **SDL_GPU:** plain `gpu_create_texture`.
- `Gpu_Caps.transient_targets`: true where the memory is actually saved. That means Vulkan with a lazily allocated type, or Metal on an Apple GPU family. It is false here.
- **Debug guard.** In debug builds both backends' `begin_render_pass` assert that a transient attachment is not loaded or stored. The guard catches only a STORE, a resolve-and-store, a LOAD, or a sample, on any backend; the transient textures themselves are only made on the own ones. Under the own Vulkan backend on llvmpipe, smoke and parity run the narrowed usage under validation.

### Which textures become transient
These are only the depth textures of single-pass one-shot targets, each opened by `begin_mesh_pass(load = false, keep_depth = false)` and never read:

| Target | Size | Where |
|---|---|---|
| Render mode's depth-of-field backdrop depth | the viewport (22 MB at 2800x2000 on the OnePlus Pad) | `path.odin:545` |
| Navigation head depth | small | `nav_head.odin:58` |
| Thumbnail strip scratch depth | 256² | `thumbs.odin:40` |
| Step picture scratch depth | small | `step_pictures.odin` via `thumbnail_view_draw` |
| Scene preview depth, when not `heavy` (`keep_depth = false`) | up to 1024² supersampled | `thumbnail.odin:360` |

- `viewport_target_resize` gains `transient_depth := false`. A change of that value remakes the target, as a size change does.
- `thumbnail_view_draw` passes `!keep_depth`.
- `begin_mesh_pass` already stores depth only with `keep_depth`.

### Not in 4.2
- **The main viewport's multisampled colour and depth, and the capture target.** These are drawn by up to two passes a frame (`render_full`'s pass, then the live items over the idle cache with `load = true`, `renderer.odin:1542/1572`). Partial redraw also loads them the next frame, so they cannot be memoryless as things are. That is 4.3's measured A/B.
- **Colour targets of one-shot passes.** Each is resolved or sampled after its pass, so none can be transient.

## Size and checks
- **Size.** About 120 lines: hal and caps 25, vk 40, mtl 15, render callers 25, debug guards 15.
- **Here:**
  - `parity_check.py` at 0 px against the build before;
  - smoke under GPU validation, which exercises the narrowed Vulkan usage on llvmpipe;
  - `maccheck`, `iphonecheck` and `androidcheck`;
  - exit stat `transient_targets=`.
- **Bolt.** On the OnePlus Pad, a render mode with depth of field. A memory figure needs a tool: Android Studio's GPU memory counter, or the Stats panel's texture byte count if 4.3 adds one. On the iPad the change only applies under Metal (trial).

## Review (sm-architect, 2026-10-30): approve with changes, all taken
- The debug guard is moved into the seam (`transient.odin`, called from hal), so it sees samples, copies, downloads, uploads and mipmaps, and it runs under SDL_GPU too.
- Vulkan: transient textures carry only attachment usage plus TRANSIENT, with no TRANSFER or SAMPLED. Memory prefers LAZILY_ALLOCATED. `Vk_Texture.transient` keeps cycled backings the same.
- Metal: `Mtl_Texture.transient` makes every backing Memoryless.
- `viewport_target_resize` drops SAMPLER for a transient depth, and its early return compares the flag.
- The scene preview's `heavy` invariant is stated in `thumbnail.odin`.
- The plan table no longer lists captures under 4.2.
