---
name: sm-render
description: Rendering in src/render with SDL_GPU — the device and pipelines, the offscreen viewport target ImGui shows, 16-byte vertices (float3 position + octahedral snorm16 normal) in two buffers, the 16 MB cycled transfer buffer and range uploads, indirect draws per visible chunk run, simplified-copy (LOD) index buffers, partial redraw by damage rect, the idle-object cache, present modes, GLSL shaders compiled to committed .spv, the frame's two command buffers, GPU timing, viewport download, --dump-viewport PPM and scripts/ppm.py. Load for ANY task that draws, uploads, changes what is on screen or judges it, e.g. "it renders black", "add wireframe", "change the material", "upload is slow", "the partial redraw leaves garbage", "take a screenshot", "add a shader". Requires sm-odin and sm-build; culling math lives in sm-geom; the frame loop's input and panels are sm-ui.
---

# Rendering

## Model (README: the render row of "Layout", "Idle objects", "Simplified drawing while the view moves", "GPU benchmark and frame timing")
- `Renderer{device, window, depth_format, mesh_pipeline, clear_pipeline, last_version, cull, partial, present_mode,
  lod_px}` (`src/render/renderer.odin:21-35`); `BACKGROUND` linear `{0.16, 0.17, 0.19}` (`:38`); `PARTIAL_MAX_AREA 0.6`
  (`:42`); `Viewport_Target{color, depth, width, height, cache, frame_key}` (`:45-55`); `Static_Cache` (`:57-65`).
- `Mesh_Buffers` (`:67-96`): `positions` (FLOAT3) and `normals` (octahedral SHORT2_NORM) in two vertex buffers, 32-bit
  `indices`, one `transfer` of `TRANSFER_BUFFER_SIZE = 16 MB` (`:101-103`), `version`/`drawn_version`, the `indirect`
  command buffer sized for every chunk, `lod_indices` for the copies. `VERTEX_BYTES = 16`.
- Uniforms: `Frame_Uniforms{view_proj, view, model}` (std140, column-major, `:105-110`) pushed per draw; `Material_Uniforms
  {base_color, params (ambient, specular strength, power)}` (`:151-155`). Shaders are `.spv` embedded with `#load`
  (`:157-160`), compiled from `src/render/shaders/*.vert|*.frag` only when `glslangValidator` is on PATH (sm-build).
- `Draw_Item{mesh, model, color, live, chunks, damage, lod, hidden}` (`:112-134`): `model` is translation plus uniform
  scale only, because culling takes the eye into mesh space with its inverse; `damage` is the mesh-space box of what
  changed, before and after; a version bump without a damage box forces a full redraw; `hidden` is per chunk then per group.
- Pipelines: mesh culls `.BACK` with `.COUNTER_CLOCKWISE` front faces (`:281`), colour `R8G8B8A8_UNORM`, depth
  `D32_FLOAT` else `D24_UNORM` (`:175-178`); the clear pipeline draws a full-screen triangle at the far plane to clear a
  scissored rectangle (`:317`, `clear.vert`). `renderer_init` creates the device with `{.SPIRV}` and the debug flag from
  `--gpu-debug` (`:162-183`); failures are `log.errorf(…, sdl.GetError())` and `return false`.
- The frame (`src/app/main.odin:218-397`): apply the scene command → change vsync before acquiring (`:224-228`;
  `renderer_set_vsync` recreates the swapchain, `renderer.odin:194-201`) → wait the previous fence when timing → acquire
  `present_cmd` and the swapchain texture → events → `viewport_target_resize` before ImGui references the texture
  (`:280-283`) → UI and tools → `imgui.Render` → a second command buffer `cmd` for the 3D work (`:309-316`) → per object
  and part (current level, plus the HD window): `sculptor_flush` → `mesh_buffers_upload_ranges`, then once per frame and
  never during a stroke `sculptor_lod_update` → `mesh_buffers_upload_lod` (`:320-340`) → a `Draw_Item` per part, clay for
  the selected object and grey otherwise (`:341-354`) → `render_viewport` (`:362`) → submit, with a fence when `time_gpu`
  (`:364-383`) → ImGui pass into the swapchain on `present_cmd` (`:385-397`).
- `render_viewport` (`renderer.odin:597-619`): with `partial` on and an unchanged `frame_key` (camera, size, item
  identity, model, colour, `lod_px`), `damage_rect` projects every damage box, pads by 2 px and redraws only that
  rectangle through `render_rect` (`:634-681`); otherwise `render_full` copies the idle objects from the `Static_Cache`
  (rebuilt when its key changes) and draws the live ones. `viewport_invalidate` zeroes both keys for changes the keys
  cannot see, such as which chunks are hidden (`:621-626`).
- `prepare_draws` writes one `GPUIndexedIndirectDrawCommand` per visible run of chunks, LOD runs after the fine ones,
  inside a copy pass before the render pass; `mesh_buffers_create` uploads a whole mesh in chunks, waiting for the GPU
  after each, for loading only (`:389-414`); `mesh_buffers_upload_ranges` packs up to 256 ranges a batch into the
  cycled transfer buffer and bumps `version`; `mesh_buffers_upload_lod` drops the LOD buffer on failure so the mesh
  draws at full detail; `viewport_download` returns RGBA8 rows top to bottom after waiting for the GPU (tests and dumps).

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
| garbage inside a rectangle | the damage box missed a moved vertex: `changed_bounds` must cover before and after (`src/sculpt/brush.odin:107-109, 405, 425`); `PAD` |
| lighting wrong after a stroke | normals not re-uploaded: only dirty nodes' ranges are uploaded, so a node that moved must be marked stale |
| an idle object does not update | its cache key did not change: bump `version` or `viewport_invalidate` |
| validation errors in `smoke` | a buffer released while in flight (`WaitForGPUIdle` before every destroy: `src/app/scene.odin:77, 108, 116, 186, 192, 279`), an upload outside a copy pass, a transfer buffer mapped without `cycle` |
| swapchain errors after toggling VSync | `renderer_set_vsync` called after the swapchain texture was acquired |

## Rules
- Only `render` (and `app`, for the present pass) import `vendor:sdl3`; `render` never reads UI state (`:1-3`).
- Every `sdl.*GPU*` result is consumed (sm-odin); wait for the GPU before destroying anything drawn this frame;
  `renderer_destroy` waits and releases in reverse order.
- Edit the GLSL and commit the regenerated `.spv` with it, saying which validator produced it; never hand-edit `.spv`.
- GPU timing (`--time-gpu`) serialises frames; leave it off except when measuring (sm-perf).
