---
name: sm-render
description: Rendering in src/render with SDL_GPU — the device and pipelines, the offscreen viewport target the interface shows, 16-byte vertices (float3 position + octahedral snorm16 normal carrying the mask) in two buffers, the 16 MB cycled transfer buffer and range uploads, index-page uploads and buffer regrowth for dynamic topology, indirect draws per visible chunk run, simplified-copy (LOD) index buffers, partial redraw by damage rect, the idle-object cache, present modes, GLSL shaders compiled to committed .spv, the frame's two command buffers, GPU timing, viewport download, screenshots (--dump-viewport PNG or PPM, src/png_write) and scripts/ppm.py. Load for ANY task that draws, uploads, changes what is on screen or judges it, e.g. "it renders black", "add wireframe", "change the material", "upload is slow", "the partial redraw leaves garbage", "the mask does not show", "take a screenshot", "add a shader". Requires sm-odin and sm-build; culling math lives in sm-geom; the frame loop's input and panels are sm-ui.
---

# Rendering

## Model (README: the render row of "Layout", "Idle objects", "Simplified drawing while the view moves", "GPU benchmark and frame timing")
- `Renderer{device, window, depth_format, single, multi: Mesh_Pipelines{mesh, wire, clear}, samples, last_version,
  cull, partial, present_mode, lod_px}` (`src/render/renderer.odin`); `BACKGROUND`; `PARTIAL_MAX_AREA 0.6`;
  `Viewport_Target{color, depth, multi_color, samples, width, height, cache, frame_key}`; `Static_Cache`.
- MSAA (`renderer_set_msaa`, app side `src/app/msaa.odin`, setting `msaa`): a pipeline only draws into targets of its
  sample count, so every pass takes its `^Mesh_Pipelines` (`mesh_pipelines(r, vt.samples)`; thumbnails and the nav head
  pass `&r.single` and stay 1x, because the interface samples them and SDL refuses to sample an MSAA texture). With
  MSAA the viewport draws into `multi_color` + MSAA `depth` (kept with STORE so partial redraw can LOAD them) and every
  pass resolves into the 1x `color` (`target_pass`: RESOLVE_AND_STORE, `cycle_resolve_texture`); the cache is MSAA and
  copied MSAA->MSAA (fine on Vulkan, equal sample counts); `render_rect` draws meshes 1 px past the cleared rect
  (llvmpipe scissors per sample); the studio draws its own 1x camera depth (`studio_view_depth`) at `samples == 0`.
  MSAA depth cannot be resolved or sampled. `set msaa off` gives the old images bit for bit.
- `Mesh_Buffers` (`:67-96`): `positions` (FLOAT3) and `normals` (octahedral SHORT2_NORM) in two vertex buffers, 32-bit
  `indices`, one `transfer` of `TRANSFER_BUFFER_SIZE = 16 MB` (`:104-106`), `version`/`drawn_version`, the `indirect`
  command buffer sized for every chunk, `lod_indices` for the copies. `VERTEX_BYTES = 16`.
- The mask rides in the normals: `pack_normal :: geom.oct_encode_masked` (`:102`) keeps 12 bits of each octahedral half
  for the normal and 4 for a nibble of the mask, so `VERTEX_BYTES` stays 16. `mesh_buffers_create(r, mesh, mask)` and
  `mesh_buffers_upload_ranges(…, ranges, mask)` take the sculptor's `mask` (nil = unmasked). `mesh.vert.slang` rebuilds both
  (`raw & ~15` is the normal; the nibbles give `out_mask` at location 2) and `mesh.frag.slang` darkens masked clay
  (`albedo · (1 − 0.7 · mask)`, highlights `· (1 − 0.5 · mask)`).
- Paint (`Mesh_Buffers.paint`, nil until an object has polypaint or polygroups): a `GRAPHICS_STORAGE_READ` buffer of
  `Paint_Packed` (`[2]u32`: RGBA8 colour, group) per vertex that `mesh.vert.slang` reads by `gl_VertexIndex` (set 0 binding 0) when
  `Frame_Uniforms.options` asks; `Renderer.no_paint` is bound otherwise. `mesh_buffers_upload_paint` (ranges or all; the app
  uploads all when `paint_stamp` differs). The group colour is a `flat` output, taken from the triangle's first index, which
  the sculptor's packed indices make a corner carrying the triangle's group. `Draw_Item.paint`/`groups` are in both keys.
- Uniforms: `Frame_Uniforms{view_proj, view, model, options}` (std140, column-major, `renderer.odin:108-113`) pushed per draw; `Material_Uniforms
  {base_color, params (ambient, specular strength, power, wrap), surface (metallic, roughness, flat), checker (lattice origin xyz, cell size w; 0 off), look (exposure in stops, cavity, ridge: `Draw_Item.look`, in both frame keys; zero is plain), lights (`Draw_Item.lights: render.Lights`, 560 bytes at offset 80, `maps` at 640, the block 880 (asserted), `style` last: light_x/y/z the studio's turn into view space as columns with the ambient in light_x.w, then for LIGHT_COUNT (8) lights `light_pos` (toward a sun, unit length, or a point/spot's view-space position; kind LIGHT_SUN/POINT/SPOT in .w), `light_color` (linear rgb, strength in .w, 0 off and skipped), `light_spot` (a spot's axis, cos of half its cone in .w) and `light_shape` (x the distance it equals a sun of its strength, y reach with Karis's window, 0 none, z the inner cosine, kept above the outer, w the light's size: the sine of a sun's angular radius from `Light.angle`, a point/spot's radius from `Light.radius`, 0 none); `light_at` in mesh_shading.slang gives the direction, falloff and `spread` (the size's sine as seen from the pixel) for both lit paths; a light with `spread > 0` takes its specular from Karis's representative point (`nearest_in_light`) normalized by `widened` (both the GGX `direct_sized` and the classic Blinn-Phong, whose power maps to a GGX width), while `spread == 0` runs the old code path, so size 0 is bit-identical (checked with `ppm.py diff` on Classic and Steel); the app builds it on the CPU (`viewport_lights`, `src/app/lights.odin`: camera lights through the Turn/Height rig, scene lights through the view), so the shader turns only its studio lookups; zero means `lights_default()`, the key and fill suns fixed to the camera; `studio_frame` takes it and `lights_key(lights, centre)` picks the brightest light on for the shadow, from the scene's centre toward a point or spot, none on meaning no shadow samples)}`; every lit path ends in `display()`: exposure, Khronos PBR Neutral tone map, exact sRGB encode (never `pow(1/2.2)`), and cavity/ridge come from `curvature()` (normal turn per pixel from `dFdx`/`dFdy`), so they stay per-pixel and rect-safe; `mesh.vert.slang` passes the mesh-space position at location 5 for the checker (Rebuild's density preview: alternate cells darker, edge lines from 16 px cells, fading to the mean under ~3 px; `Draw_Item.checker` is in both frame keys); `params.y < 0` makes `mesh.frag.slang` write the flat colour (the wireframe); `surface.y > 0` takes the physically based path (GGX from each light that is on, at 3x its strength, with specular anti-aliasing, a procedural studio of sky, floor and three light lobes blurred by roughness, Karis's environment BRDF fit), 0 the classic wrap-Lambert and Blinn-Phong one; `surface.z` shades with the face normal from `dFdx`/`dFdy` of the view position (no vertex data); `surface.w > 0` takes the MatCap path before both: the fragment stage has one sampler (set 2, binding 0), always bound to `Draw_Item.matcap` or the 1x1 white `r.no_matcap`, with `r.matcap_sampler` (linear, mipmapped, clamped), looked up with Blender's perspective-correct basis and multiplied by albedo, relief and exposure (no tone map: the picture is the final look) (`renderer.odin:154-158`). Matcap textures (`render/matcap.odin`) are RGBA8 sRGB with a GPU-built mip chain (usage SAMPLER + COLOR_TARGET, which `GenerateMipmapsForGPUTexture` needs), uploaded on their own command buffer behind a fence so they can be made outside a frame; `Draw_Item.matcap` is in both frame keys by address, so whoever replaces one calls `viewport_invalidate`. Shaders are `.spv` (`.msl` on Darwin, `shaders.odin`) embedded with `#load`
  (`renderer.odin`), compiled from the Slang sources `src/render/shaders/*.vert.slang|*.frag.slang|*.comp.slang` (rules below; sm-build).
- Group materials (`Draw_Item.slots: ^Material_Slots`, nil for none; app side `src/app/group_materials.odin`): slot 0 is the
  draw's own material, slots 1-15 polygroups'. The groups ride in `Frame_Uniforms.slot_group` (`uvec4[4]`, `SLOT_NONE` unused;
  `options.z` turns the lookup on) and `mesh.vert.slang` finds the triangle's slot into a `flat` output (location 6); the slots'
  colour, params and surface are fragment uniform buffer 1 (`Slot_Uniforms`, set 3 binding 1, so mesh pipelines' fragment
  shaders declare 2 uniform buffers and every mesh draw pushes both). `mesh.frag.slang` swaps base/params/surface after the
  wireframe's early return and sets `surf.w = 0` (no MatCap in a slot). Needs the paint buffer (the group word); both frame
  keys hash the slots' contents, never the pointer, since the app makes them in temp memory each frame.
- `Draw_Item{mesh, model, color, material, surface, flat, wireframe, live, chunks, damage, lod, hidden}` (`renderer.odin:115-137`): `surface` is metallic and roughness (roughness 0 = classic), `flat` faceted shading; both are in the frame and cache keys; `material` is
  ambient, specular, power and wrap (zero = `DEFAULT_MATERIAL`, the app's presets in `src/app/material.odin`); `wireframe` draws
  the same chunks again through `wire_pipeline` (`.LINE` fill, depth bias, no depth write, `WIRE_COLOR`), which is optional:
  if a backend refuses line fill it logs a warning and stays off; `model` is a similarity (rotation, translation,
  uniform scale) only, because culling takes the eye into mesh space with its inverse; `damage` is the mesh-space box of what
  changed, before and after; a version bump without a damage box forces a full redraw; `hidden` is per chunk then per group.
- Pipelines: mesh culls `.BACK` with `.COUNTER_CLOCKWISE` front faces (`renderer.odin:284`), colour `R8G8B8A8_UNORM`, depth
  `D32_FLOAT` else `D24_UNORM` (`renderer.odin:178-181`); the clear pipeline draws a full-screen triangle at the far plane
  (`clear.vert.slang`) painting `Renderer.background` (`Background{top, bottom}`, display values, set by the app each frame from
  `src/app/background.odin`; equal edges mean flat): `draw_background` runs after the clear op in the full pass and the
  cache pass only for a gradient (a flat one is the clear colour, so the default 0.17 grey stays bit-identical), and always
  in `render_rect`; `clear.frag.slang` dithers a gradient with a 4x4 Bayer pattern keyed on `gl_FragCoord`, so partial and full
  redraws match bit for bit. The background is in `frame_key` and `static_key` (the cache holds it); thumbnails and the
  nav head pass a transparent `background` to `begin_mesh_pass` and never draw it. `renderer_init` creates the device with `SHADER_FORMAT` (`shaders.odin`: `{.MSL}` on Darwin, `{.SPIRV}` elsewhere) and the debug flag from
  `--gpu-debug` (`renderer.odin:165-186`); failures are `log.errorf(…, sdl.GetError())` and `return false`.
- Blending passes (`Mesh_Pipelines.see`, `.floor`, both optional: nil logs a warning and the feature degrades): see-through
  items are those with `Draw_Item.look.w > 0` (the app's Transparency; `mesh.frag.slang` writes it as alpha via `opacity()`), drawn
  with `BLEND_OVER` (colour by source alpha, target alpha kept at 1, since the interface blends the viewport by its alpha)
  and no depth write. `draw_scene` orders every viewport pass: opaque items, then `draw_floor` (the `Renderer.floor`
  `Floor_Grid`, one full-screen `floor.vert.slang` triangle a plane; `floor.frag.slang` unprojects the pixel, meets the plane, writes
  `gl_FragDepth`, takes `fwidth` before any `discard`), then see-through items; in `render_rect` those blended layers stay
  inside the cleared rect, not the 1 px MSAA ring. `Renderer.floor` is in `frame_key` only; the grid is never drawn into
  the idle cache (the live items would cover it), any see-through item skips the cache, and with MSAA it skips partial
  redraw too. `studio_view_depth` leaves see-through items out; nav head and thumbnails never draw the grid or blend.
- The frame (`src/app/main.odin:298-504`): apply the scene command (`:300`) → change vsync before acquiring (`:311`;
  `renderer_set_vsync` recreates the swapchain, `src/render/renderer.odin:197-204`) → wait the previous fence when timing
  → acquire `present_cmd` and the swapchain texture (`src/app/main.odin:324-330`) → events → `viewport_target_resize`
  before the interface references the texture → the interface (`kit_frame`), the tools and the viewport overlay → a second command buffer `cmd` for the 3D
  work (`:413`) → per object and part (current level, plus the HD window, `:423`): `sculptor_flush` → `level_upload`
  (`src/app/scene.odin:217`: vertex ranges with the mask, dynamic topology's index pages, new buffers when the mesh
  outgrew them), then once per frame and never during a stroke `sculptor_lod_update` → `mesh_buffers_upload_lod`
  (`src/app/main.odin:440-451`) → a `Draw_Item` per part, each object's own material (`object_material`; `Object.material`, set through the `.Material` Scene_Command, saved from scene version 14; its groups' in `Object.group_materials`, `.Group_Material`, version 15, drawn through `object_material_slots`; selected colour, idle when `dim_others`) and `wireframe` on the selected one (`:452`) →
  `render_viewport` (`:469`) → submit, with a fence when `time_gpu` (`:472`) → `kit_upload` and the interface's
  pass (`ui_pass_draw`) into the swapchain on `present_cmd`. View windows (`src/app/view_window.odin`) are other
  swapchains on the same device (`render.window_claim`/`window_release`, mailbox where offered): each has its own
  `Ui_Pass` and its own command buffer submitted after `present_cmd`, acquired with the non-waiting
  `AcquireGPUSwapchainTexture` and only when what it shows changed (even that acquire blocks in
  `vkAcquireNextImageKHR`, so a window presented every frame would pace the main one to its monitor).
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
  draws at full detail; `viewport_download` returns RGBA8 rows top to bottom after waiting for the GPU (tests and dumps);
  `Readback` (`readback_start`/`readback_poll`/`readback_cancel`) reads a texture back without waiting, on its own
  command buffer submitted after the frame's and collected once its fence signals (the scene preview, at rest).
- Textured preview (`src/render/textured.odin`, app `src/app/textures.odin`; design notes/rendering/textured-preview-design.md):
  `Textured_Mesh` (one interleaved 32-byte `Textured_Vertex`: FLOAT3 position, SHORT2_NORM masked octahedral normal,
  SHORT4_NORM tangent with w ±1, FLOAT2 UV v-up; buffers grown by powers of two and uploaded in a copy pass on the
  frame's `cmd` with a cycled transfer buffer; `maps` per `Texture_Map{Base_Color (sRGB), Orm, Normal}` made by
  `texture_create` with GPU mips, also behind `matcap_create`; `stamp` for vertices, `maps_stamp` for maps). A
  `Draw_Item` with `textured` and `texture_view != .Off` draws it whole with `Mesh_Pipelines.textured`/`textured_see`
  (`create_mesh_pipeline(…, textured = true)`: no storage buffer, 5 fragment samplers: MatCap, environment, then the maps, defaults
  `no_matcap`/`no_normal_map`, `texture_sampler` repeat + 8x anisotropy where `Renderer.anisotropy`; 1 fragment
  uniform buffer) and keeps `mesh` for its wireframe (`wire_pass` after rebinding the sculpt buffers), the studio's
  shadows and the damage boxes; `draws_textured` and `blended` pick per item; `textured_key` folds mesh, maps stamp
  and view into both frame keys (vertices too into the idle cache's). Shaders: `mesh.frag.slang` and `textured.frag.slang` are
  `#version 450` + `GL_GOOGLE_include_directive` + `#include "mesh_shading.slang"` (never compiled alone), `textured.frag.slang`
  defining `TEXTURED` first; under it the normal map is read MikkTSpace's way (interpolated N and T unnormalized,
  B = w·cross(N, T)), flat shading and group slots are off, ORM drives the physically based path and occlusion dims
  only ambient and studio terms; `Material_Uniforms.maps` (x, y, z present, w the view) is zero on the sculpt path, whose
  pictures the move left identical to the pixel. `textured.vert.slang` writes every `mesh.vert.slang` output (4 and 6 flat) plus
  UV (7) and tangent (8), turning by `mat3(view) * mat3(model)` divided by its scale.
- Image environments (`render/environment.odin`, app `src/app/environment.odin` + `environment_file.odin`): every
  pipeline whose shader declares a sampler must have it bound on every draw (debug SDL aborts "Missing fragment sampler
  binding"): the mesh pipeline has 2 (MatCap, `environment_map`), the textured one 5 (MatCap, environment, 3 maps), the
  clear one 1; `environment_binding(r)` gives the prefiltered map or the 1x1 black `r.no_environment`, through
  `r.env_sampler` (repeat u, clamp v, explicit `textureLod`, so no derivative seam at the wrap). `Material_Uniforms`
  (352 B) ends with `env` (x on, y strength, z levels-1), `env_axes` (the panorama's axes in view space,
  `Environment_Look.rotation`: Turn and fixed-to-scene only, never Height) and `env_sh[9]` (cosine-convolved SH9 over
  pi, in the panorama's axes); all zero keeps the studio branch, bit-identical. The source is RGBA16F with full mips;
  `prefiltered` is half size with up to `ENV_LEVELS` = 6 levels (fewer when the height runs out), level k roughness
  k/(levels-1), made once by `env_prefilter.frag.slang` into `mip_level` targets (64 Hammersley GGX samples, Colbert-Krivanek
  lod) on its own command buffer behind a fence. Equirect mapping lives in `panorama.slang` (`u = atan(x, -z)/2pi + 0.5`,
  `v = acos(y)/pi`, row 0 up), the display curve in `display.slang` (`display_color(c, stops)`), both included by
  `mesh_shading.slang` and `clear.frag.slang`. `clear.frag.slang` shows the background from `Clear_Uniforms.env` and `clip_to_env`
  (rotation transpose times inverse projection, unprojected like `floor.frag.slang`); `draw_background` skips its flat early
  return when it shows. `Environment_Keyed{stamp, look}` (zero without one) is in both frame keys; the stamp is a run
  counter. The image path's diffuse is `irradiance(n) * ao` without the studio's 0.7, so the white furnace reads
  `1 + f0 A + B` (240/255 after the tone map).
- Live occlusion (`render/live_ao.odin`, app `src/app/live_ao.odin`): GTAO (`gtao.frag.slang`, 2 slices x 6 steps, a 4x4
  pattern of turns and offsets, never time) into an R16F `ao` (half size on Android via `LIVE_AO_SCALE`), then
  `ao_blur.frag.slang` (4x4 depth-weighted, clamps to 1 after averaging: a pixel's own value may pass 1) multiplies the
  viewport colour into `shown`. It runs after `render_viewport` and uses `Viewport_Stats.redrawn` (the partial rect):
  GTAO reruns that rect padded by `LIVE_AO_MAX_PX + 3` (in ao texels, rounded out), the blur 3 texels more, with LOAD
  and `cycle = false`; anything in `live_ao_key` (proj, size, samples, scale, reach, strength) or a frame it did not run
  (`live_ao_reset`) forces a full pass. Under MSAA it draws its own 1x depth through `view_depth_draw` (shared with the
  studio in `screen_pass.odin`, with `create_fullscreen_pipeline`, `create_shadow_pipeline`, the far-plane
  `create_depth_clear_pipeline` and `rect_narrow`), partial too. Partial must equal `--no-partial` to the bit (check
  with a bench stroke, MSAA off and x4). `viewport_shown(app)` picks studio, live AO or the plain colour for the panel,
  screenshots and the time-lapse; add any new post pass there.
  App side: maps come from a bake, `texture_load` (Textures section, `Load_Texture` command, `texture` script verb) or a
  scene file and leave by `texture_remove`, all `textures_replace` (one `.Textures` undo step); a `.glb` export of an
  object with maps goes through `quad_object_glb` (the bake's writer: layers, and paint when no base colour map, carried
  onto the split vertices; maps other than PNG or JPEG re-encoded as PNG; `geom.image_mime` names each).
- Studio render, the Render section's Fast quality (once named Preview; `setting_parse` still reads `preview` as Fast) (`src/render/studio.odin`, app `studio_on`/Shift+R; one switch with render mode via `render_set`, never both on from the UI): `studio_frame` after `render_viewport` on the same
  `cmd`; a frame whose stats show any redraw (`!partial || redrawn_px > 0`) copies `vt.color` into `Studio.shown` and resets,
  a still one adds one sample: `shadow.vert.slang`/`.frag` depth pass from an R2-sequence direction (every 4th around one light,
  `studio_light`: picked by brightness through an R3 sequence over the light samples) into a 2048² map, `studio_gather.frag.slang` (full-screen `clear.vert.slang`, additive blend into RGBA16F `accum`; normals
  from neighbouring viewport depths), `studio_composite.frag.slang` into `shown`. Needs `Renderer.depth_sampled` (viewport depth
  has `.SAMPLER`). The viewport panel and `viewport_download(…, texture)` use `studio_texture` while on, once it has
  `STUDIO_SHOW_MIN` samples when live AO is on (live AO runs under the studio and shows until then). `softness` (the
  key disc's radius) restarts it on change; `ao`/`shadow` changes after convergence recomposite (`Studio.strengths`).
  `studio_on` is a remembered setting: a device failure lives only in `Studio.failed` (`studio_running`), never saved.
  Light samples add (vis·w + amb, w + amb) (`studio_weight.slang`: w the picked light's n·l·falloff over Σ chance·reach +
  ambient, amb `STUDIO_AMBIENT_SHARE`·ambient / total brightness), so b/a is the unshadowed share of all light; mean
  weight 1 keeps half floats safe. Sphere lights trace to a disc of radius r·d/√(d²−r²) with tmax 1; suns tmax +inf.
  `light_window.slang` is shared with render_trace.comp.slang.
- Style (`Draw_Item.style`, `Material_Uniforms.style`, in both frame keys): w > 0.5 turns on the underside falloff of
  the ambient (`underside()`, rig up = `rig[1]`) and the narrow upper rim, classic and PBR studio ambient; w = 0 must
  run the old lines verbatim (check 0 px against the base). Thumbnails and the nav head pass zero.
- Passes (`Draw_Item.pass`, `Material_Uniforms.pass` at offset 880, block 896, in both frame keys; `render.View_Pass`):
  x the pass, y/z Depth's near/far as eye distances. `mesh_shading.slang` branches once after the normal and `bend`,
  writing unlit display values with `opacity()`; 0 must stay the shaded path. The app sets it on every viewport draw
  (`pass_items`, `src/app/passes.odin`) and clears it before the thumbnail, nav head and object pictures draw; the
  ground (`pass_ground`) and the floor are swapped in `main.odin`; `live_ao_wanted`, `studio_running`, `render_running`
  gate on `pass_shaded`. App structs near the test stack limit: `[3]App` tests allocate with `new`.
- Look presets (`src/app/look.odin`, Scene > Look, `Viewport_Look`): Sculpt studio / Classic write existing fields
  (material default, lights through Light_Set's fields, background, cavity, style, live AO, studio strengths). Code
  defaults stay Classic; `look_first_run` applies Sculpt studio once for the everyday settings file only
  (`look_chosen`), never under --no-settings, --frames or --settings-file, so scripted images do not move.
- Render mode (`src/render/path.odin`, `render_trace.comp.slang`, `render_display.frag.slang`, app `render_mode.odin`): its own
  `Tracer` for `trace_prepare`, then GPU copies of every traced item's positions, indices, normals, paint, chunk nodes
  and order into 7 merged read-only buffers (Scene_Buffer order = shader bindings), CPU-built chunk records (item in
  the top 12 bits of w) and a world TLAS appended to Nodes at `extra.x`. Ping-pong RGBA32F `accum`, a band of rows a
  frame (adaptive on frame time, never on content: a pixel's RNG depends only on pixel and sample), `shown` composited
  over `vt.color` by coverage. `studio_env.slang` holds `studio()` for both mesh_shading and the kernel: change it and
  recheck 0 px. While render mode runs the studio gets max_samples 0 (paused); off, `render_mode_frame` releases it.
  Sample 0 is unjittered and writes the denoiser guides (set 1 bindings 1-2, RGBA16F: albedo+hit, normal+t);
  `render_atrous.frag.slang` passes ping-pong `filtered` (pass 0 reads the sum and demodulates), display remodulates.
  Environment sampling (`env_sample.odin`): an RGBA32F alias table per environment (`Environment.table`, at most 512
  wide; the studio's built in `path_ensure` from `studio_luminance`, a CPU copy of `studio()`: keep them in step or
  only noise suffers). Texels are weighed by their 3 x 3 neighbourhood's brightest luminance, because the shader's
  bilinear lookup bleeds a sun's edge half a texel out: without it a sky-weight texel returns sun radiance, a
  speckle. Render mode binds `Environment.source` (full size) not `prefiltered`, so the table matches what it reads.
  `env.z` = `env_share` (0 for the studio while any light is on: measured noisier, see its comment).
  Half resolution (`render_half`, default on Android): `render_size` sizes accum, guides and filtered; `shown` stays
  at the viewport's size (`view_width`); the kernel derives rays from `textureSize(prev)`. render_display.frag.slang blends
  the four traced texels premultiplied by coverage when `params.w` is 1; at 0 it keeps the exact full-size path
  (0 px against the old display: keep it so).
  Textured items (ITEM_TEXTURED): `Textured_Mesh.corners` (geom.quad_mesh_triangle_corners, 3 slots a base-level
  triangle in its own corner order, uploaded with the preview) and its vertices are gpu-copied into Scene_Buffer
  `.Textured` (the 8th storage buffer: the per-stage limit is 8, none left). `Item_Record.tex` = first tri, corner
  base, vertex base, slot|view<<4|maps<<8; maps bound as 9 named samplers `map0..map8` (RENDER_TEXTURED_MAX 3, 12 of
  16 samplers) through a switch, never an array (non-uniform indexing is a device feature). A map's maps_stamp change
  restarts the view (`pr.tex_stamps`). The normal-map bend (reflect below ng) applies to textured hits only.
  Depth of field (`render.Lens`, app `lens.odin`): uniforms `lens_eye..lens_fwd` (radius 0 = pinhole, exactly the
  old path: the lens draws its two `rnd()` only when on, after the jitter). Guides are two ping-pong pairs
  (`guides[guide_at]` is read as samplers 3-4); with a lens every sample writes running means over hits and atrous
  (params.w) renormalizes the mean normals. The display composites over `pr.backdrop` (background + floor, drawn
  at sample 0) instead of `vt.color`, so the sharp clay never shows through blurred edges. 14 of 16 samplers used.
- Finishing stack (`src/render/finish.odin`, `finish.frag.slang`, app `finish.odin`, Scene > Finish): one full-screen
  pass after `live_ao_view_frame` over `viewport_unfinished`'s texture (or `vt.color`) into `Finish.shown`;
  `viewport_shown` returns it, so every reader is finished. Runs only while the Render switch is on, the pass is
  shaded and `render.finish_active` (any control off its none value): off stays 0 px. Input is display values:
  `neutral_inverse` (display.slang; shoulder from the max channel, the desaturation, then the toe) gives linear light
  back, capped at code 254.5 (`NEUTRAL_TOP`); the `residual` (shown minus tone_map of the inverse) is added after the
  curve so non-Neutral colours (MatCaps, wires, flat backgrounds) and 8-bit losses survive and identity settings
  stay within one code. Full feeds exact light: `render_display_linear.frag.slang` (render_display.frag.slang with LINEAR_OUT)
  into `pr.linear` RGBA16F when `render_frame(linear = true)`. AgX is our own build of the method (inset 0.2 to the
  mean, log2 -12.47..4.03, power-hyperbola sigmoid, outset 0.4), AgX and ACES exposure-matched to Neutral at mid grey
  (`AGX_EXPOSURE`, `ACES_EXPOSURE`; the tests check them). The key (`finish_version`) is the redraw count, studio
  and path samples and how they were shown, live AO runs: add whatever else changes the source without a redraw.
  Transparent captures finish their second drawing too (`Capture.finished`); each `Picture` has its own `finished`
  while it shows Studio or Render (read it through `picture_shown`, never `pic.shown`). Bloom is a chain before the
  pass (`bloom_down` 13-tap with Karis on level 0, `bloom_up` tent + HDRP scatter, R11G11B10 or RGBA16F, a linear
  sampler); sharpen (CAS) is a pass after it into `shown` from an RGBA16F `mid`, and then owns grain and dither
  (`finish_grain.slang`, `effects.z`); aberration taps the source bilinearly, so read exact pixels with Load.
- Studio carry (`studio_carry`, `studio_reproject.frag.slang`): a `changed` frame whose `studio_scene_key` (meshes,
  versions, models, hidden, softness, `vt.epoch`) holds carries `accum` (ping-pong `accums`) to the new view by
  `prev_depth` (R32F, the depth buffer's own values) and `view_proj`, 2x2 taps with a plane test, capped at
  `STUDIO_CARRY_AMBIENT`/`STUDIO_CARRY_KEY`; shadows only when `studio_lights_key` (world lights) holds. `samples` is
  since the last restart or carry (stopping), `sequence` the R2 index; `first` (no carry, no samples) clears. A still
  view must stay 0 px against the old build: unmoved carries need `STUDIO_CARRY_AMBIENT` samples first.
- Traced studio (`src/render/trace.odin`, `studio_trace.comp.slang`, `blas_refit.comp.slang`, `studio_trace_add.frag.slang`): at
  `samples == 0` `trace_prepare` decides the run (`Studio.traced`); false falls back to the gather, never half done.
  Needs `Draw_Item.source` (the CPU mesh as uploaded) and `Mesh_Buffers.storage` (positions and indices with
  `.COMPUTE_STORAGE_READ`, retried without). `Mesh_Buffers.trace` holds per-run `geom.Chunk_Bvh` trees keyed by
  `chunk_bvh_key` (rechecked only when `index_version` moved: creation and `upload_indices`, not packed/hidden uploads),
  refit when `version` moved, a TLAS (leaf = run id) from the item's chunk bounds minus `hidden`. Node layout and the
  u16-pairs order are shared with geom (`Gpu_Bvh_Node`, children after parent); keep `chunk_bvh_any_hit` and the shader
  walk in step, and the shader's STACK at 2 x `CHUNK_BVH_STACK`. A sample: clear `visible` (R32F, render pass), one
  compute pass with a dispatch per item that only stores 0, then an additive pass into `accum` in the gather's encoding.
  Check: `--no-trace` equals the base to the bit; traced vs gather within ~12/255 off silhouettes; two runs 0 px.
- Compute (the GPU compute trial, `src/render/smooth_compute.odin`): `Smooth_Compute` holds the `smooth_all.comp.slang` pipeline,
  six storage buffers (indices, CSR offsets and tris, weights, two position buffers) and an upload and a download transfer
  buffer, all grown on demand and kept; `smooth_compute_run` uploads (topology only when its key changed or is 0),
  dispatches one compute pass a step (SDL_GPU orders passes, not dispatches inside one) in rows of at most 65535
  groups, downloads, and waits on a fence after each part to time it (`Smooth_Timing`). SDL's SPIR-V compute layout:
  set 0 read-only storage, set 1 read-write storage, set 2 uniforms. `build.sh` compiles `*.comp.slang` with the other shaders.

- The interface's pass (`src/render/ui_pass.odin`, `ui.vert.slang`/`ui.frag.slang`): `ui_pass_upload` copies the kit's 20-byte
  vertices and indices into buffers grown by powers of two and the changed rows of its R8 glyph atlas (recreated when
  fontstash grows it) in one copy pass; `ui_pass_draw` draws in the swapchain pass, one draw per `Ui_Draw` with its
  scissor, the atlas or the viewport texture bound. Atlas texture coordinates arrive in atlas pixels and the vertex
  shader divides by the size in its uniforms, so glyphs placed before a mid-frame atlas growth stay right. NDC y is
  flipped in the shader. `ui_pass_capture` redraws the same lists into an offscreen RGBA8 target for `--dump-screen`.
- The navigation head (`src/render/nav_head.odin`, built and laid out by `src/app/nav_head.odin`): a small head mesh
  drawn with the mesh pipeline into its own target, `NAV_HEAD_SUPERSAMPLE` (2) times the size shown, cleared to
  transparent (`begin_mesh_pass`'s `background`), and only when its key (the camera's turn, size, colour) changes. The
  kit shows it as image id `KIT_NAV_HEAD_IMAGE`; its `Ui_Draw.smooth` binds a linear sampler (a 2x2 box filter at
  that ratio) and `ui.frag.slang` divides the colour by alpha (params.w), so its edge neither aliases nor darkens. Any other
  small 3D picture over the interface should reuse this rather than draw into the viewport target.
- Object pictures (`src/render/thumbs.odin`, kept by `src/app/object_thumbs.odin`): an atlas of `THUMB_CELLS`²
  cells of `THUMB_PX`, each drawn into a scratch target and copied into its cell (`CopyGPUTextureToTexture`,
  `cycle = false`, or other cells are lost). A picture's `Draw_Item` has `chunks` nil, so it draws the whole index
  buffer and never touches the per-frame indirect commands the viewport recorded. The app draws at most one a frame
  after `nav_head_frame`, never mid-stroke or while the view moves, and only once its object's `thumb_key` has held
  for `THUMB_SETTLE`; the kit shows cells as `KIT_THUMBS_IMAGE` with `ui.image_part` and the smooth sampler.
- Step pictures (`step_pictures.odin`, kept by `src/app/history_pictures.odin`): the same atlas-and-copy scheme for
  History steps (`STEP_PICTURE_PX` 144, 64 cells), drawn through a `Thumbnail_View` at supersample 1 with the main
  view's projection narrowed to the step's square (a pre-multiplied crop matrix), in the step's own frame.
- `Thumbnail_View` (`thumbnail_view.odin`): the frame's draw items again into a small target of its own at a
  supersample (`THUMBNAIL_SUPERSAMPLE`, 1 maximised), whole (chunks, groups, hidden and LOD cleared, as thumbnails
  are), with the view, projection, items and ground the app gives. The app's second view (thumbnail.odin) picks its
  camera (`second_orbit`: Follow, axis presets ortho, Free in `App.second_orbit`), builds the lights for that camera,
  and marks the items with `pass_items` (Silhouette is the shader's pass, with `pass_ground`'s paper); it draws only
  at rest, or every frame while its own camera is dragged.
- Transparent screenshots (app `capture.odin`): `render_viewport` again, after the frame's viewport and live AO, into a
  second `Viewport_Target` of the same size and samples with `background = {}`, `floor = {}`, `lod_px = 0` and the
  environment picture off (restored after); the clear's alpha 0 and the meshes' alpha 1 resolve to coverage. Written
  after submit: `viewport_shown` where coverage is 255, the second drawing unpremultiplied at edges. `BLEND_OVER`
  keeps the target's alpha, so see-through items add none.
- The turntable (app `turntable.odin`) reads each frame back through the same `Capture` (`capture.turntable`, with
  `transparent` from the setting; without it only `viewport_shown` is read), so a frame's camera is set at the frame's
  start and its pixels arrive in `capture_finish` the same frame. `png_write.apng_*` streams the animated PNG.
- `Pictures` (`pictures.odin`): an atlas of pictures the CPU decoded (Home's scene previews), 6 x 6 cells of
  `PICTURE_PX`, filled by `pictures_upload` on the frame's own command buffer at most `PICTURES_PER_FRAME` a frame
  through one transfer buffer mapped with `cycle = true`; a picture sits at its cell's top left (`picture_uv`). The
  kit shows it as `KIT_PICTURES_IMAGE`; Home frees it on close (`pictures_destroy` waits for the GPU).
- Kept pictures: `viewport_copy` copies a viewport-format texture into a `Viewport_Target` on its own command buffer,
  submitted before the frame draws over the source. The still a worked view pane leaves (`grid_work_gpu`) and the
  cross-fade (app `cross_fade.odin`: last frame's shown texture, copied after the interface, drawn over the main pane
  as `KIT_FADE_STILL_IMAGE` with its alpha set at upload, `cross_fade_tint`) use it; `ui.image`'s tint fades it.

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
| validation errors in `smoke` | a buffer released while in flight (`render.wait_idle` before every destroy, as `src/app/scene.odin` does), an upload outside a copy pass, a transfer buffer mapped without `cycle` |
| swapchain errors after toggling VSync | `renderer_set_vsync` called after the swapchain texture was acquired |

## Rules
- Only `render` names the GPU API; `app` imports `vendor:sdl3` for windows, events and the pen only, and reaches
  the GPU through `src/render/gpu.odin`: the handles `Cmd`, `Texture`, `Fence`, `Sample_Count`, and `wait_idle`,
  `cmd_begin`/`cmd_submit`/`cmd_submit_fenced`/`cmd_cancel`, `fence_finish`, `swapchain_acquire`, `ui_present`
  (each window's present pass), `renderer_ready`. `scripts/boundary_check.py` (run by `check`) fails on any
  `sdl.*GPU*` name or native GPU import outside `src/render`; a new GPU need is a render proc, never an app call.
  Inside render, SDL_GPU's procs are called only from the seam `hal.odin` (`gpu_create_texture` for
  `sdl.CreateGPUTexture`, same arguments), and every `gpu_*` there first hands the call to
  the Vulkan backend when `gpu_backend == .Vulkan` (`--gpu=vulkan`), or on Darwin to the Metal backend when `gpu_backend == .Metal` (`--gpu=metal`, inside `when METAL`); the check fails on a direct `sdl.*GPU*(` call anywhere else in render. SDL's types and info structs stay, as opaque
  handles render never dereferences.
  `render` never reads UI state.
- Every `sdl.*GPU*` result is consumed (sm-odin); wait for the GPU before destroying anything drawn this frame;
  `renderer_destroy` waits and releases in reverse order.
- Shaders are Slang (one source for SPIR-V, Metal through it, WGSL later). `name.stage.slang` (vert, frag, comp) is an
  entry file whose `main` builds `name.stage.spv`, and `scripts/shaders_msl.py` turns that into `name.stage.msl` with
  SDL_shadercross (`main` becomes `main0`; SDL's sets map to SDL_GPU's Metal slots); render `#load`s
  `"shaders/name.stage" + SHADER_EXT` with `SHADER_ENTRY` and `SHADER_FORMAT` (`shaders.odin`), so Darwin embeds only
  `.msl` and everything else only `.spv`; other `.slang` files are includes
  (`#include`, `#define TEXTURED` before `mesh_shading.slang`). Bindings are SDL's sets, written
  `[[vk::binding(binding, set)]]`; varyings carry `[[vk::location(n)]]`; vertex index is `SV_VulkanVertexID` (with
  base vertex, as GLSL's); globals that are not resources are `static`. slangc runs with `-matrix-layout-row-major
  -O0` (build.sh): a matrix is the transpose of its maths, so GLSL's `M * v` is `mul(v, M)`, `A * B` is `mul(B, A)`,
  `float3x3(a, b, c)` takes columns and `M[i]` is column i, exactly as GLSL; `-O0` because spirv-opt turns `x / c`
  into `x * (1 / c)`, which moved pixels. Write constants Slang would compute per pixel (`normalize` of a literal) as
  their folded values (`studio_env.slang`). A first line `// slangc: -fp-mode precise` keeps every multiply and add
  unfused (`smooth_all.comp.slang`, which must equal the CPU). Commit the regenerated `.spv` and `.msl` with the source; never
  hand-edit either (`check` fails on a `.msl` whose first line does not name its `.spv`'s hash). Metal compiles them with
  fast math, so nothing bit-exact (Smooth all on the GPU) is offered on Darwin. A shader change that should not move a pixel passes `scripts/parity_check.py` (19 scenes, viewport
  and window, against a baseline drawn by the old build; `--app` picks the binary) at 0 px.
- The Vulkan backend (`vk_device.odin`, `vk_resources.odin`, `vk_cmd.odin`, `vk_swapchain.odin`) mirrors SDL_GPU's
  own Vulkan backend (`deps/sdl3-src/src/gpu/vulkan/SDL_gpu_vulkan.c` is the reference): the same descriptor sets per
  stage, uniforms as dynamic uniform buffers of 4096 bytes from a per-command-buffer arena, default layouts per usage
  that passes leave and restore, cycling by backings, deferred destruction by refcount, a flipped viewport, dynamic
  rendering and a timeline semaphore whose serials are the fences. It needs Vulkan 1.3 with dynamicRendering,
  synchronization2, timelineSemaphore and independentBlend, and `renderer_init` falls back to SDL_GPU otherwise,
  keeping the reason for `render.backend_fallback`. The app picks the backend before it makes the window
  (`src/app/graphics.odin`: Settings > System > Graphics, Automatic = Vulkan except on Darwin, `--gpu` for one run).
  A `vk_*` proc takes its struct parameters `#by_ptr` exactly as the `gpu_*` wrapper does, or the values arrive as
  garbage. Under `--gpu-debug` it runs the validation layer with synchronization validation and every message fails
  the run (`render.validation_errors`); smoke runs both backends, and a render change passes
  `parity_check.py --compare <sdl run> -- --gpu=vulkan` at 0 px.
- The Metal backend (`mtl_device.odin`, `mtl_resources.odin`, `mtl_cmd.odin`, `mtl_swapchain.odin`, `#+build darwin`)
  mirrors SDL_GPU's own Metal backend (`deps/sdl3-src/src/gpu/metal/SDL_gpu_metal.m`): vertex buffers at buffer 14+,
  uniforms at buffer(i) sent by `set*Bytes` at draw time (4096 bytes a slot), vertex storage buffers after the
  uniforms, fragment textures and samplers at their slot, no viewport flip, cycling by backings and serials as the
  fences. Metal tracks hazards, so there are no barriers. Count objects by hand: a `new*`/`alloc` result is ours to
  release, an autoreleased one (command buffer, encoder, drawable) is retained while kept, and every proc opens
  `NS.scoped_autoreleasepool()`. The pinned Odin asserts ("missing procedure 'objc_lookUpClass'") on any objc
  message unless the package implements an objc class, which `Mtl_Objc_Anchor` does; keep it. It makes no compute
  pipelines yet (`gpu_*` compute procs return under Metal), the Graphics menu offers it only as Metal (trial), guarded by a start marker
  (`graphics_trial_begin`, `src/app/graphics.odin`), and it has never run on Apple hardware: `maccheck` and `iphonecheck` only compile it. `backend_fail` keeps a backend's reason for
  `backend_fallback` whichever one failed.
- What a device and backend can do is `render.Gpu_Caps` (`caps.odin`), filled by `caps_fill` after the device is made
  and read by the app through `render.caps`; a switch is set only once the backend holds what it needs, so the app
  branches on caps, never on a backend's name. A new capability is a field there plus one `gpu_*` proc with an
  SDL_GPU, Vulkan and Metal answer (`gpu_set_allowed_frames_in_flight`, set between frames by `frame_pace`).
- Present timing (`Gpu_Caps.present_timing`, `vk_present_learn` in `vk_swapchain.odin`): the own Vulkan backend's
  waiting acquire under vsync waits for the present `frames_in_flight` back to be on screen (`VK_KHR_present_wait`),
  or reads `VK_GOOGLE_display_timing` on Android; the app tags a present with `render.present_input` before the submit
  and takes `render.present_times` after the acquire. Only the main window paces (view windows acquire without
  waiting). lavapipe offers neither extension, so in the container only the `.None` path runs.
- Pre-rotation (Android, own Vulkan, `vk_pick_transform`): a swapchain image may be turned from the window
  (`swapchain_turns`); `Vk_Window.width/height` stay the window's. Anything new that draws into a swapchain must turn
  with `ui_pass_draw`'s `turns` (the vertex uniform's zw and the scissor remap); draw into an offscreen target instead.
- A new top-level pass function starts with `debug_group(cmd, "Name")` (`gpu.odin`, popped as the scope ends, so
  call it outside any pass), and a long-lived texture or buffer gets `gpu_set_texture_name`/`gpu_set_buffer_name`
  with a literal (the backends keep the pointer for later backings), so captures in Xcode and RenderDoc read.
- GPU timing (`--time-gpu`) serialises frames; leave it off except when measuring (sm-perf). Timestamps
  (`Gpu_Caps.timestamps`, `timing.odin`, `vk_timing.odin`) do not: a pass that should show in Stats passes a
  `Gpu_Span` to its `debug_group`; spans never nest (an inner one is left untimed), so their sum is the frame.
- A target drawn by one pass and never read after makes its depth with `gpu_create_texture_transient`
  (`viewport_target_resize(..., transient_depth = true)`): CLEAR/DONT_CARE only, never sampled or copied; debug checks it.
- Mapped device buffers (`gpu_create_buffer_mapped`, `Gpu_Caps.shared_buffers`) are filled once before first use
  and closed with `gpu_buffer_filled`; never keep the pointer or write them later (strokes use the transfer buffer).
- A compute kernel that wants subgroup operations or 64-bit atomics checks `Gpu_Caps.subgroup_size` (0 = unknown,
  keep a plain path) and `int64_atomics`; never sum floats with atomics (order breaks determinism).
