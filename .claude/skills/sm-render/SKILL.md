---
name: sm-render
description: Rendering in src/render with SDL_GPU — the device and pipelines, the offscreen viewport target the interface shows, 16-byte vertices (float3 position + octahedral snorm16 normal carrying the mask) in two buffers, the 16 MB cycled transfer buffer and range uploads, index-page uploads and buffer regrowth for dynamic topology, indirect draws per visible chunk run, simplified-copy (LOD) index buffers, partial redraw by damage rect, the idle-object cache, present modes, GLSL shaders compiled to committed .spv, the frame's two command buffers, GPU timing, viewport download, screenshots (--dump-viewport PNG or PPM, src/png_write) and scripts/ppm.py. Load for ANY task that draws, uploads, changes what is on screen or judges it, e.g. "it renders black", "add wireframe", "change the material", "upload is slow", "the partial redraw leaves garbage", "the mask does not show", "take a screenshot", "add a shader". Requires sm-odin and sm-build; culling math lives in sm-geom; the frame loop's input and panels are sm-ui.
---

# Rendering

## Model (README: the render row of "Layout", "Idle objects", "Simplified drawing while the view moves", "GPU benchmark and frame timing")
- `Renderer{device, window, depth_format, mesh_pipeline, clear_pipeline, last_version, cull, partial, present_mode,
  lod_px}` (`src/render/renderer.odin:21-35`); `BACKGROUND` linear `{0.16, 0.17, 0.19}` (`:38`); `PARTIAL_MAX_AREA 0.6`
  (`:42`); `Viewport_Target{color, depth, width, height, cache, frame_key}` (`:45-55`); `Static_Cache` (`:57-65`).
- `Mesh_Buffers` (`:67-96`): `positions` (FLOAT3) and `normals` (octahedral SHORT2_NORM) in two vertex buffers, 32-bit
  `indices`, one `transfer` of `TRANSFER_BUFFER_SIZE = 16 MB` (`:104-106`), `version`/`drawn_version`, the `indirect`
  command buffer sized for every chunk, `lod_indices` for the copies. `VERTEX_BYTES = 16`.
- The mask rides in the normals: `pack_normal :: geom.oct_encode_masked` (`:102`) keeps 12 bits of each octahedral half
  for the normal and 4 for a nibble of the mask, so `VERTEX_BYTES` stays 16. `mesh_buffers_create(r, mesh, mask)` and
  `mesh_buffers_upload_ranges(…, ranges, mask)` take the sculptor's `mask` (nil = unmasked). `mesh.vert` rebuilds both
  (`raw & ~15` is the normal; the nibbles give `out_mask` at location 2) and `mesh.frag` darkens masked clay
  (`albedo · (1 − 0.7 · mask)`, highlights `· (1 − 0.5 · mask)`).
- Paint (`Mesh_Buffers.paint`, nil until an object has polypaint or polygroups): a `GRAPHICS_STORAGE_READ` buffer of
  `Paint_Packed` (`[2]u32`: RGBA8 colour, group) per vertex that `mesh.vert` reads by `gl_VertexIndex` (set 0 binding 0) when
  `Frame_Uniforms.options` asks; `Renderer.no_paint` is bound otherwise. `mesh_buffers_upload_paint` (ranges or all; the app
  uploads all when `paint_stamp` differs). The group colour is a `flat` output, taken from the triangle's first index, which
  the sculptor's packed indices make a corner carrying the triangle's group. `Draw_Item.paint`/`groups` are in both keys.
- Uniforms: `Frame_Uniforms{view_proj, view, model, options}` (std140, column-major, `renderer.odin:108-113`) pushed per draw; `Material_Uniforms
  {base_color, params (ambient, specular strength, power, wrap), surface (metallic, roughness, flat)}`; `params.y < 0` makes `mesh.frag` write the flat colour (the wireframe); `surface.y > 0` takes the physically based path (GGX key and fill lights, a procedural studio blurred by roughness, Karis's environment BRDF fit, ACES curve), 0 the classic Blinn-Phong one, which stays pixel-identical; `surface.z` shades with the face normal from `dFdx`/`dFdy` of the view position (no vertex data) (`renderer.odin:154-158`). Shaders are `.spv` embedded with `#load`
  (`renderer.odin:160-163`), compiled from `src/render/shaders/*.vert|*.frag` only when `glslangValidator` is on PATH (sm-build).
- `Draw_Item{mesh, model, color, material, surface, flat, wireframe, live, chunks, damage, lod, hidden}` (`renderer.odin:115-137`): `surface` is metallic and roughness (roughness 0 = classic), `flat` faceted shading; both are in the frame and cache keys; `material` is
  ambient, specular, power and wrap (zero = `DEFAULT_MATERIAL`, the app's presets in `src/app/material.odin`); `wireframe` draws
  the same chunks again through `wire_pipeline` (`.LINE` fill, depth bias, no depth write, `WIRE_COLOR`), which is optional:
  if a backend refuses line fill it logs a warning and stays off; `model` is a similarity (rotation, translation,
  uniform scale) only, because culling takes the eye into mesh space with its inverse; `damage` is the mesh-space box of what
  changed, before and after; a version bump without a damage box forces a full redraw; `hidden` is per chunk then per group.
- Pipelines: mesh culls `.BACK` with `.COUNTER_CLOCKWISE` front faces (`renderer.odin:284`), colour `R8G8B8A8_UNORM`, depth
  `D32_FLOAT` else `D24_UNORM` (`renderer.odin:178-181`); the clear pipeline draws a full-screen triangle at the far plane to clear a
  scissored rectangle (`renderer.odin:320`, `clear.vert`). `renderer_init` creates the device with `{.SPIRV}` and the debug flag from
  `--gpu-debug` (`renderer.odin:165-186`); failures are `log.errorf(…, sdl.GetError())` and `return false`.
- The frame (`src/app/main.odin:298-504`): apply the scene command (`:300`) → change vsync before acquiring (`:311`;
  `renderer_set_vsync` recreates the swapchain, `src/render/renderer.odin:197-204`) → wait the previous fence when timing
  → acquire `present_cmd` and the swapchain texture (`src/app/main.odin:324-330`) → events → `viewport_target_resize`
  before the interface references the texture → the interface (`kit_frame`), the tools and the viewport overlay → a second command buffer `cmd` for the 3D
  work (`:413`) → per object and part (current level, plus the HD window, `:423`): `sculptor_flush` → `level_upload`
  (`src/app/scene.odin:217`: vertex ranges with the mask, dynamic topology's index pages, new buffers when the mesh
  outgrew them), then once per frame and never during a stroke `sculptor_lod_update` → `mesh_buffers_upload_lod`
  (`src/app/main.odin:440-451`) → a `Draw_Item` per part, the material's colours (the Scene tab's Material; selected and idle) and `wireframe` on the selected one (`:452`) →
  `render_viewport` (`:469`) → submit, with a fence when `time_gpu` (`:472`) → `kit_upload` and the interface's
  pass (`ui_pass_draw`) into the swapchain on `present_cmd`.
- `render_viewport` (`renderer.odin:628-650`): with `partial` on and an unchanged `frame_key` (camera, size, item
  identity, model, colour, `lod_px`), `damage_rect` projects every damage box, pads by 2 px and redraws only that
  rectangle through `render_rect` (`:665-712`); otherwise `render_full` copies the idle objects from the `Static_Cache`
  (rebuilt when its key changes) and draws the live ones. `viewport_invalidate` zeroes both keys for changes the keys
  cannot see, such as which chunks are hidden (`:652-657`).
- `prepare_draws` writes one `GPUIndexedIndirectDrawCommand` per visible run of chunks, LOD runs after the fine ones,
  inside a copy pass before the render pass; `mesh_buffers_create` uploads a whole mesh in chunks, waiting for the GPU
  after each, for loading only (`:395`); `mesh_buffers_upload_ranges` packs up to 256 ranges a batch into the
  cycled transfer buffer and bumps `version` (`:488`); `mesh_buffers_upload_indices` uploads index ranges (dynamic
  topology's whole changed pages, `sculptor_index_ranges`) and asserts they fit `index_count` (`:575`); `mesh_buffers_upload_lod` drops the LOD buffer on failure so the mesh
  draws at full detail; `viewport_download` returns RGBA8 rows top to bottom after waiting for the GPU (tests and dumps).
- Studio render (`src/render/studio.odin`, app `studio_on`/Shift+R): `studio_frame` after `render_viewport` on the same
  `cmd`; a frame whose stats show any redraw (`!partial || redrawn_px > 0`) copies `vt.color` into `Studio.shown` and resets,
  a still one adds one sample: `shadow.vert`/`.frag` depth pass from an R2-sequence direction (every 4th around the view-space
  key light) into a 2048² map, `studio_gather.frag` (full-screen `clear.vert`, additive blend into RGBA16F `accum`; normals
  from neighbouring viewport depths), `studio_composite.frag` into `shown`. Needs `Renderer.depth_sampled` (viewport depth
  has `.SAMPLER`). The viewport panel and `viewport_download(…, texture)` use `studio_texture` while on.
- Compute (the GPU compute trial, `src/render/smooth_compute.odin`): `Smooth_Compute` holds the `smooth_all.comp` pipeline,
  six storage buffers (indices, CSR offsets and tris, weights, two position buffers) and an upload and a download transfer
  buffer, all grown on demand and kept; `smooth_compute_run` uploads (topology only when its key changed or is 0),
  dispatches one compute pass a step (SDL_GPU orders passes, not dispatches inside one) in rows of at most 65535
  groups, downloads, and waits on a fence after each part to time it (`Smooth_Timing`). SDL's SPIR-V compute layout:
  set 0 read-only storage, set 1 read-write storage, set 2 uniforms. `build.sh` compiles `*.comp` with the other shaders.

- The interface's pass (`src/render/ui_pass.odin`, `ui.vert`/`ui.frag`): `ui_pass_upload` copies the kit's 20-byte
  vertices and indices into buffers grown by powers of two and the changed rows of its R8 glyph atlas (recreated when
  fontstash grows it) in one copy pass; `ui_pass_draw` draws in the swapchain pass, one draw per `Ui_Draw` with its
  scissor, the atlas or the viewport texture bound. Atlas texture coordinates arrive in atlas pixels and the vertex
  shader divides by the size in its uniforms, so glyphs placed before a mid-frame atlas growth stay right. NDC y is
  flipped in the shader. `ui_pass_capture` redraws the same lists into an offscreen RGBA8 target for `--dump-screen`.

## Verify what you draw
    build\sculpt.exe --vertices=500000 --frames=60 --dump-viewport=build\a.ppm
    python scripts\ppm.py to-png build\a.ppm build\a.png        # open it with Read; describe what is where and how it is lit
- A render-only change moves no pixel: the same flags twice must give `ppm.py diff a.ppm b.ppm` → 0 differing pixels
  (the render is deterministic), and `--no-partial` must match a partial run. `ppm.py crop … --scale 4` for edges,
  `ppm.py pixel` for exact values, `ppm.py uniform` to catch a blank frame.
- `build.bat smoke` after any SDL_GPU change: validation layers on, `SDL_ASSERT=abort`, leaks fail.

## When it looks wrong
| Symptom | First suspects |
|---|---|
| black or background only | nothing uploaded (`mesh_buffers_create` returned false), `Draw_Item.chunks` empty with `cull` on, the camera inside the mesh, a stale `frame_key` (call `viewport_invalidate`) |
| holes or flicker at chunk borders | ranges not merged or sorted; a cone culling a chunk that is visible (`CONE_SLACK`; cones stay open during a stroke by design) |
| garbage inside a rectangle | the damage box missed a moved vertex: `changed_bounds` must cover before and after (`src/sculpt/brush.odin:149-151, 457, 492`); `PAD` |
| lighting wrong after a stroke | normals not re-uploaded: only dirty nodes' ranges are uploaded, so a node that moved must be marked stale |
| an idle object does not update | its cache key did not change: bump `version` or `viewport_invalidate` |
| validation errors in `smoke` | a buffer released while in flight (`WaitForGPUIdle` before every destroy: `src/app/scene.odin:94, 168, 238, 319, 325, 412`), an upload outside a copy pass, a transfer buffer mapped without `cycle` |
| swapchain errors after toggling VSync | `renderer_set_vsync` called after the swapchain texture was acquired |

## Rules
- Only `render` (and `app`, for the present pass) import `vendor:sdl3`; `render` never reads UI state (`:1-3`).
- Every `sdl.*GPU*` result is consumed (sm-odin); wait for the GPU before destroying anything drawn this frame;
  `renderer_destroy` waits and releases in reverse order.
- Edit the GLSL and commit the regenerated `.spv` with it, saying which validator produced it; never hand-edit `.spv`.
- GPU timing (`--time-gpu`) serialises frames; leave it off except when measuring (sm-perf).
