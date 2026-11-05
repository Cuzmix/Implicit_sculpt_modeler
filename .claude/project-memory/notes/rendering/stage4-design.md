# Stage 4: advanced rendering (design, 2026-10-27)

Bolt said "Proceed" on Stage 4 after Stages 1-3. Source research: `research-2-advanced.md` (sections 6-7). Stage 1.1
already moved every lit path to linear light with exposure, PBR Neutral and an exact sRGB encode inside the shader, so
the research's "Stage 0 HDR intermediate" is not needed for 4.1 or 4.2: both work on linear values inside
`mesh_shading.glsl` or multiply the finished viewport the way the studio render already does.

Four PRs, in order, each leaving the renderer working, each with nothing new running inside a stroke frame unless it
is cheap and opt-in:

| Part | What exists after it | New GPU objects |
|---|---|---|
| 4.1 | **Image environments (IBL)**: load a `.hdr` (or PNG/JPEG) panorama; physically based materials reflect it (prefiltered by roughness) and take its diffuse light (SH9); optionally shown as the background, blurred | one RGBA16F equirect source with mips, one prefiltered RGBA16F equirect with 6 mips, a prefilter pipeline; a second fragment sampler on the mesh and textured pipelines; the clear pipeline samples the source |
| 4.2 | **Live ambient occlusion (GTAO)** in the viewport while working, opt-in | R8 AO + RGBA8 shown textures at viewport size, three full-screen pipelines; a 1x depth redraw when MSAA is on |
| 4.3 | **Traced studio render**: the studio's shadow-map gather replaced by compute-traced AO and key-light shadow rays against a GPU BVH (two-level: the sculptor's node tree over per-node BVHs), falling back to today's gather | flattened TLAS/BLAS storage buffers, mesh buffers gain `COMPUTE_STORAGE_READ`, a trace compute pipeline |
| 4.4 | **Render mode** (optional, presentation): progressive path tracing from the raster primary hit, GGX/Lambert with VNDF sampling, NEE for key/fill + environment importance sampling, MIS, A-Trous denoise, PNG save | accumulators and denoise buffers; reuses 4.3's BVH |

4.3 and 4.4 each get their own design addendum and architect review before they are built (new GPU buffer layouts);
this document is final for 4.1 and 4.2 and an outline for 4.3-4.4.

## 4.1 Image environments

### Behaviour
- Scene palette gets an **Environment** section (after Lights): tabs **Studio** (today's procedural studio, the default,
  bit-identical pixels) and **Image**; **Load environment...** (a file picker for `.hdr` Radiance RGBE, also PNG/JPEG/
  BMP/TGA/QOI panoramas read as sRGB, equirectangular 2:1, any size up to 8192 x 4096); **Strength** (stops, -4..+4,
  default 0); a line naming the loaded file and its size. Under More: **Background** switch (show the environment
  behind the scene) and **Blur** (0..1, default 0.3: which prefiltered roughness the background shows).
  Five controls folded: tabs, Load, Strength, the status line is a paragraph, More.
- Physically based materials (roughness > 0) and textured objects take reflections from the prefiltered environment
  at their roughness and their diffuse light from its SH9 irradiance, in place of `studio()`. Key and fill lights stay
  (the Lights section sets them; a user who wants pure IBL sets them to 0). The classic materials, MatCaps, polygroup
  colours and the wireframe are unchanged: they have no environment term today and get none.
- The environment turns with the light rig (`Draw_Item.lights`): with lights fixed to the camera (default) the panorama
  stays put on screen as the studio does now (Blender's studio-light behaviour); **Fixed to the scene** makes it a world
  environment that the camera orbits inside. Turn rotates it about the vertical, Height tilts it, as for the studio.
- The background, when on and an image is loaded, replaces the flat/gradient background in every pass (full, cache,
  partial rect, studio render, screenshots); thumbnails and the nav head stay transparent as now.
- Remembered like the MatCap image: settings `environment studio|image`, `environment_image PATH` (a missing file
  leaves a note and Studio), `environment_strength`, `environment_background`, `environment_blur`; script verb
  `environment FILE` loads one (and picks Image); `set environment studio` goes back. Not in the scene file (a view
  setting, as materials' MatCap images are). README section under Materials.
- Loading decodes on a thread (as texture maps do): the old environment (or Studio) shows until the new one is ready;
  a refused file (not an image, wrong aspect, too big, damaged RLE) is a toast and changes nothing.

### Files and data
- `src/app/environment.odin`: settings fields on `App` (`environment: Environment_Kind {Studio, Image}`,
  `environment_path`, `environment_strength`, `environment_background`, `environment_blur`), `environment_load(app,
  path) -> string` (refusal reason), the decode thread (heap allocator, one at a time), `environment_frame` (takes a
  finished decode: downsamples, computes SH9, calls `render.environment_create`), `kit_environment_section`,
  `hdr_decode(data) -> (pixels []f32 RGB, w, h, why)`: Radiance RGBE with both flat and new-style RLE scanlines, `-Y +X`
  orientation only (the common one; others refused), `FORMAT=32-bit_rle_rgbe` (xyz refused), header capped at 4 KB,
  every run length checked against the row (a damaged file is refused, never read past the end). LDR images go
  through `core:image` and the sRGB EOTF.
- CPU work after decode (thread): box-downsample to the source size (2048 x 1024 desktop, 1024 x 512 Android, power of
  two 2:1), convert to f16 RGBA; SH9 irradiance (Ramamoorthi-Hanrahan) from a 128 x 64 downsample weighted by solid
  angle `sin(theta)`, returned as 9 RGB coefficients already convolved with the cosine lobe (A0 = pi, A1 = 2pi/3,
  A2 = pi/4) and divided by pi, so the shader evaluates irradiance/pi directly. Deterministic (fixed loop order, no
  parallel reduction).
- `src/render/environment.odin`: `Environment{source, prefiltered: ^GPUTexture, size, mips, sh: [9][4]f32, stamp}`;
  `environment_create(r, pixels_f16, w, h, sh) -> (Environment, bool)` on its own command buffer behind a fence (as
  `texture_create`): upload level 0 of `source` (RGBA16F, usage SAMPLER + COLOR_TARGET, full mips via
  `GenerateMipmapsForGPUTexture`), then render each of `ENV_MIPS = 6` levels of `prefiltered` (w/2 x h/2 at level 0)
  with `env_prefilter.frag` (full-screen `clear.vert` triangle, colour target = that mip level): level k is roughness
  k/5; level 0 a plain copy-sample of the source; levels 1-5 GGX importance sampling, 64 Hammersley samples, each read
  from the source at the lod of its solid angle (Colbert-Krivanek filtered importance sampling), N = V = R. Release:
  `environment_destroy` waits for the GPU idle. `Renderer.environment: ^Environment` (nil = Studio) and
  `Renderer.environment_look: {strength, background on, blur}` set by the app each frame.
- Uniforms: `Material_Uniforms` gains `env: vec4` (x 1 when an image environment is bound, y its linear strength
  `2^stops`, z the prefiltered mip count - 1, w unused) and `env_sh: vec4[9]` appended last (std140, 144 + 16 + 144 =
  304 bytes, `#assert`); zero on Studio, so the old branch runs and old pixels stay bit-identical.
- Samplers: the mesh pipeline's fragment stage gains sampler binding 1 (`environment`, the prefiltered equirect),
  always bound (a 1x1 black RGBA16F default `r.no_environment`); the textured pipeline's maps move from bindings 1-3 to
  2-4. One `env_sampler`: linear, linear mips, repeat in u, clamp in v. Sampled with explicit `textureLod` (no
  derivative seam at the u wrap); direction to uv: `u = atan(d.x, -d.z) / 2pi + 0.5`, `v = acos(clamp(d.y)) / pi`.
- `mesh_shading.glsl`: `vec3 environment(vec3 dir, float rough)` = `env.x > 0 ? textureLod(...) * env.y : studio(dir,
  rough)`; `irradiance(n)` = SH9 eval * env.y, else `studio(n, 1.0)`. The PBR branch calls these two in place of the
  two `studio()` calls. Nothing else changes.
- Background: `Clear_Uniforms` gains `inv_view_rot: mat4` (the camera's inverse rotation times the rig's, so the
  background turns with the same matrix as reflections) and `env: vec4` (x on, y strength, z lod = blur * 5, w the
  vertical field of view tangent and aspect packed with `extent`); `clear.frag` samples
  the **prefiltered** texture at `blur * 5` (roughness-matched blur, so the background looks like what a rough object
  reflects), through the same exposure and PBR Neutral `display()` copied into clear.frag. Dithering stays. The clear
  pipeline gains one fragment sampler. `draw_background` runs in every pass when the environment background is on
  (like a gradient). Partial redraws stay exact: the pixel depends only on its own ray.
- Keys: `frame_key` and `static_key` hash `environment.stamp`, the look, and (for the background) the view rotation is
  already in both. `viewport_invalidate` is not needed.
- Memory: desktop source 2048 x 1024 RGBA16F + mips = 21.3 MB, prefiltered 1024 x 512 x 6 mips = 5.3 MB; Android half
  each (6.7 MB). Reported in the Stats panel's GPU memory line if one exists, else in the section's status line.
- Time: prefilter is 6 small passes (~512k texels x 64 samples at level 1, quartering each level): a few ms on the RTX;
  on llvmpipe at 2048 x 1024 roughly 1-2 s, which is why the app tests use 64 x 32 maps.

### Tests and checks
- `hdr_decode`: a hand-built RLE file and a flat file decode to known values; truncated runs, a run past the row, a
  wrong `-Y` line, an oversize header and a 0 x 0 image are refused (each must not read past the buffer).
- SH9: a constant environment of 1 gives irradiance/pi = 1 in every direction within 1e-4; a single bright pixel at the
  zenith gives more light up than down.
- Studio pixels unchanged: dumps of the four baseline scenes (classic, PBR, MatCap, textured) with Studio are 0-px
  different from the build before (`ppm.py diff`).
- Image environment: a white furnace check in an app test with a 64 x 32 constant-1.0 environment, a white diffuse
  (metallic 0, roughness 1) sphere, key and fill 0, exposure 0: the pre-tone-map value is ~1.0; read through
  `viewport_download` it must equal `display(1.0)` within 2/255.
- Partial vs full redraw with the background on: 0-px diff (`--no-partial`). gpu-debug smoke with an environment.
- Visual: a described PNG of a metal and a rough sphere under a loaded HDR (made by the test helper as a gradient sky
  with a bright sun disc, written as `.hdr` by a small writer in the test, since no HDR is shipped).
- `sm-store`: user-picked files only, no new permission, nothing shipped (no HDRI asset licences to track).

## 4.2 Live ambient occlusion

### Behaviour
- Scene > Studio render section gains **Occlusion while working** (switch, default off, setting `live_ao`); it uses
  the section's existing **Occlusion** strength (`studio_ao`) and, under a new More, **Reach** (`live_ao_reach`,
  fraction of the scene's radius, default 0.04, 0.005..0.2). When the studio render is on it wins (it already shows
  converged occlusion); live AO shows otherwise. Command `Live_Occlusion` (palette, keymap-assignable), script
  `set live_ao on`.
- It darkens the finished viewport as the studio composite does (`color * mix(1, ao, strength)`), so it acts on every
  material including MatCaps, like Blender Workbench's cavity/AO; the background (far depth) is untouched.

### Passes (`src/render/live_ao.odin`, shaders `gtao.frag`, `ao_blur.frag` (blur + composite in one))
- After `render_viewport` and before the studio: needs a 1x depth. Without MSAA the viewport's own depth (needs
  `depth_sampled`, as the studio); with MSAA the studio's `studio_view_depth` approach (drawn again at one sample,
  shared code moved into a helper both call). If `!depth_sampled`, the switch is shown disabled with the reason.
- `gtao.frag` into R8 `ao`: GTAO (Jimenez 2016) with 2 slice directions x 6 steps per side, horizon-based integral with
  the cosine weight, normal reconstructed from depth (least-difference of the 4 neighbours, as `studio_gather.frag`),
  direction rotation and step jitter from interleaved gradient noise of the pixel coordinate (deterministic, no time
  term); the screen radius is the world reach projected at the pixel's depth, clamped to `LIVE_AO_MAX_PX = 48`.
- `ao_blur.frag` into RGBA8 `shown`: a 4 x 4 depth-aware box blur of `ao` and the multiply with the viewport colour.
- The viewport panel shows `shown` while live AO is on (as `studio_texture`), downloads and screenshots read it.
- Partial redraw: when `render_viewport` redrew a rectangle, the three passes are scissored to that rectangle padded
  by `LIVE_AO_MAX_PX + 2` (clamped to the target), and `shown` outside it keeps last frame's pixels; a full redraw
  runs them full-screen; nothing redrawn, nothing run. Partial and full give the same pixels because every AO pixel
  reads depth only within 48 px and the blur 2 px more. (The 1x depth redraw under MSAA is scissored the same way.)
- Cost target: <= 1 ms at 1080p on the RTX (unmeasurable here; llvmpipe gives correctness only). Off by default, so
  every existing image and the gpubench numbers are unchanged.

### Tests and checks
- AO off: baseline dumps 0-px different. AO on: `--no-partial` vs partial over a bench stroke: 0-px different; gpu-debug
  smoke with AO and MSAA x4; described PNG of a sculpted sphere with AO (crevices darker, flat areas within 2/255 of
  AO off); touch_check unaffected except the Studio section, whose new rows are below its existing ones.

## 4.3 Traced studio (outline; design addendum before building)
Two-level BVH: TLAS = the sculptor's node BVH (refit already done per stroke), flattened to 32-byte nodes; BLAS per
`Node` (leaf 8 triangles, 64-byte nodes with both child boxes) built on the job pool, rebuilt for nodes a stroke
changed when it ends; mesh `positions`/`indices` buffers created with `COMPUTE_STORAGE_READ` so triangles are not
copied; `studio_trace.comp` (one AO or key-shadow ray per pixel per sample, cosine-weighted hemisphere, R2 sequence)
writes into the existing `accum`; falls back to the shadow-map gather when the device refuses. Acceptance per
research section 7 stage 2 (10M build <= 1 s on 8 threads, <= 12 B/tri, AO vs CPU `bvh_raycast` reference within 2%
at 64 x 64 on llvmpipe, deterministic). Multi-object scenes: one TLAS entry per item with its model matrix. Open
questions for its addendum: 128 MB storage-buffer ranges on tablets (split buffers), dynamic topology (rebuild whole
object at stroke end), HD windows (trace the HD part's own buffers).

## 4.4 Render mode (outline; design addendum before building)
Scene palette **Render** section: progressive path tracing (primary hit from the raster G-buffer: depth, normal,
material id), GGX + Lambert with VNDF sampling, NEE for key and fill as small area lights plus environment importance
sampling (alias table over the 4.1 source), power-heuristic MIS, Russian roulette after 3 bounces, max 6; RGBA32F
accumulation; A-Trous denoise (5 iterations, depth/normal/albedo guides) with radius decaying by sample count; exposure
and PBR Neutral as everywhere; Save PNG. Desktop full resolution, tablets quarter resolution behind a setting.
Acceptance per research section 7 stage 3 (white furnace within 1% at 1024 spp, deterministic 64 x 64 x 8 spp on
llvmpipe).

## Out of scope (Stage 4)
Hardware ray tracing (SDL_GPU exposes none; research section 3), OIDN, CWBVH, TAA/FXAA, EXR loading (no decoder in
core; `.hdr` covers Poly Haven and most free HDRIs), shipping HDRI files.

## Architect review applied (2026-10-27)

The sm-architect review found six MUSTs; this section overrides anything above it.
- 4.1 samplers: every draw binds the environment sampler, `r.no_environment` when none (SDL asserts on a missing
  fragment sampler in debug): `draw_background` in every pass, the mesh pipeline's two bind sites, the textured
  pipeline's map array (4 to 5); `num_samplers` 2 on the mesh pipeline, 5 on the textured one, 1 on the clear one.
- 4.1 furnace: the image path's diffuse is `irradiance(n) * ao` without the studio's 0.7, so a constant-1 environment
  on a white rough dielectric gives `1 + f0 * A + B` (about 1.016) before the tone map; the test expects that.
- 4.1 background: `Clear_Uniforms` gains `exposure` and an inverse (projection x view rotation) matrix with the rig,
  and `clear.frag` unprojects its pixel as `floor.frag` does (an orthographic camera shows one direction, the view
  axis, at every pixel, which reads as a flat colour: documented). `Renderer.environment_look` carries the rig and
  exposure independent of items and is hashed into both keys. `draw_background`'s flat early return is skipped when
  the environment background is on. `display()` moves into `display.glsl`, included by `mesh_shading.glsl` and
  `clear.frag`.
- 4.1 decoder: refusal reasons are cloned into the caller's allocator; every pixel is clamped to 65504 (f16's
  largest) before the box sum; panoramas under 64 x 32 are refused; LDR images convert straight from core:image's
  pixels (no second full-size copy) and are capped at 4096 wide on Android; the file is read on the decode thread;
  a flat row whose first pixel happens to be (1,1,1,e) is no longer taken for the old run form (the old form is
  refused only when the whole file would not fit flat).
- 4.1 lifecycle: `environment_frame` runs at the start of the frame before any command buffer; the old environment is
  released after the swap; one decode at a time, the newest request wins; startup and the `environment` script verb
  wait for the decode so dumps are deterministic. `thumb_key` includes the environment stamp (a counter).
- 4.1 rotation: Height does not tilt the panorama (Turn spins it about the vertical, as Blender's world rotation).
- 4.1 naming: the Environment tabs are **Built-in** and **Image**, so "Studio" means only the studio render.
- 4.2 (applied when 4.2 is built): an `ao_key` (reach px, strength, size, projection, ran last frame) forces a full
  pass when it changes; `ao`, `shown` and the 1x depth LOAD with `cycle = false`; `render_viewport` returns the
  redrawn rect; the MSAA depth redraw culls with the padded rect; one helper picks the shown texture (studio, live AO,
  colour) for files.odin, new_ui.odin and the timelapse; `create_fullscreen_pipeline` and the 1x depth helper move to
  shared code with sampler count, scissor and load parameters; GTAO runs at half resolution on Android; the third
  pipeline is the 1x depth redraw; `live_ao_reach` is not remembered unless `studio_ao` is.

## 4.2 as built: best of each tool (2026-10-27)

Bolt's rule is to take the best idea from each tool. For live occlusion that gives:
- **Blender (Workbench and EEVEE):** viewport occlusion is a plain switch that works on every shading mode,
  MatCaps included, and it sits beside a separate Cavity setting. Both hold here. Live AO darkens the finished image,
  and the existing `cavity` and `ridge` stay as they are. EEVEE's GTAO is the algorithm.
- **XeGTAO (Intel) and the GTAO paper:** the integral, the falloff, the low horizons tied to the normal's hemisphere,
  and the sample spacing (squared, with a 1.3 px minimum) all come from here. Denoising is spatial only: a 4 x 4
  pattern of slice rotations and step offsets, then a 4 x 4 depth-aware blur that sees all 16 rotations. That makes
  32 directions a pixel, with no temporal term. It is deterministic, which partial redraw needs.
- **Marmoset Toolbag and ZBrush BPR:** live AO and the converged studio render read the same **Occlusion** slider
  through the same curve (`ao^2 (3 - 2 ao)`), so the working view looks like the still render and does not jump
  when it settles. The studio render still wins while it is on.
- **Nomad:** reach is relative to the scene's size, not a world distance, so it needs no tuning per model. Tablets
  run it at half resolution. The blur doubles as a depth-aware upsample.
- **ZBrush:** it has no live AO, which is exactly the gap this fills.

Reach is 0.1 of the scene's radius by default (0.01 to 0.4), not the 0.04 planned above: at 0.04 the seam of two
touching spheres darkened over only about 10 px. The AO target is R16F, not R8, because one pixel's two slices may
exceed 1 (exact only averaged over turns), and clamping before the blur darkened sphere rims by up to 6/255.

Partial redraw: the passes rerun only the redrawn rectangle, padded by `LIVE_AO_MAX_PX + 3` for GTAO (in AO texels,
rounded out) and then 3 AO texels for the blur. Under MSAA the 1x depth reruns only the redrawn rectangle: a
far-plane clear triangle, then the items culled to that rectangle. The scene radius is snapped to 1/16 octave, so
growth during a stroke changes the reach, and forces a full pass, only rarely.

## 4.3 Traced studio: design addendum (2026-10-27, for architect review)

### What exists after it
The studio render (Shift+R) gets its occlusion and key-light shadow from rays cast against the real triangles, not from
2048² shadow maps. It keeps everything else: it runs only while the view is still, adds one sample a frame up to
Samples, uses the same accumulation encoding, and the same composite, sliders and partial-redraw behaviour. When the
device refuses any part of it, it falls back to today's shadow-map gather, so every image path that exists today
still exists. Fine detail at 10M triangles (pores, thin cuts) is the goal: the shadow map's texel floor, 2 x radius /
2048 (about 1/1000 of the scene), hides anything smaller.

### Best of each tool
- **Marmoset Toolbag:** ray-traced AO and shadows in the viewport, progressive while still. We do it in compute,
  since SDL_GPU exposes no RT (research section 3).
- **ZBrush BPR:** on demand, and it never costs anything while sculpting. The studio already works this way.
- **Blender (Cycles AO / EEVEE):** AO Distance. A new **Reach** for the studio (More options) bounds occlusion rays:
  0 means unbounded (today's look, sky visibility), else a share of the scene radius, which gives local, crevice-only
  occlusion like Blender's and ZBrush's AO. Also the sun's **Angle**: the key shadow's softness becomes a slider
  (today's fixed 0.06 rad is the default).
- **3DCoat / Nomad:** baked occlusion is out of scope here. The bake set's ray occlusion (geom/bake.odin) already
  covers it, and it could later reuse this BVH.
- **The live occlusion of 4.2** covers the moving view, so nothing here runs during strokes.

### GPU data (new layouts)
Each `Mesh_Buffers` gets, on first studio use:
- `positions` and `indices`, created with `.COMPUTE_STORAGE_READ` added to their usage, so triangles are never copied.
  This applies to every mesh buffer, so none needs recreating when the studio turns on. The cost is to be checked
  in gpubench on the RTX (acceptance: within 5%).
- `blas_nodes`: per chunk (sculptor node, about 1024 triangles), a BVH with leaves of at most 8 triangles, flattened
  depth-first. A node is 32 B (`lo xyz, child_or_first u32, hi xyz, count u32`): leaves hold `first` into
  `blas_order` and `count`; internal nodes hold the left child (the right is next to it, so the layout is
  left-then-right siblings, children after their parent). That is about 2 nodes for every 8 triangles, 8 B/tri.
- `blas_order`: per chunk, the triangles in leaf order, as u16 offsets from the chunk's first triangle (2 B/tri).
  This needs at most 65,536 triangles a chunk. Dynamic topology's pages and the layout's NODE_TRIANGLES (1024)
  keep far under that; it is asserted at build.
- `blas_chunks`: per chunk, the offset of its nodes and of its order (8 B a chunk).
- Total 10 B/tri plus 8 B a chunk: 100 MB at 10M, 500 MB at 50M, within the research's 12 B/tri.

Per item, per studio restart: `tlas`, a BVH over the item's shown (not `hidden`) chunks in mesh space, built on the
CPU from `Draw_Item.chunks` bounds with `geom.bvh_build_over` and flattened in the same 32 B node format. Its leaves
hold chunk ids. That is about 10k chunks, 0.6 MB, at 10M.

### Building and keeping it current
- **Topology (CPU):** `geom.chunk_blas_build(positions, indices, chunk ranges, pool)` runs per chunk on the job pool
  (binned SAH as `bvh_build`, leaf 8). Its output is plain arrays, so geom stays render-free. The app calls it when an
  item's index buffer changed since the last build: a new `Mesh_Buffers.index_stamp`, bumped by every index upload
  (remesh, dynamic-topology stroke end, levels, HD enter and leave, hide). It runs at the first studio sample after
  that, so a stroke never waits for it. The app uploads the result through `render.trace_upload`. Budget: 10M in
  1 s or less on 8 threads, measured with a new `--trace-bench`. If it measures above 100 ms for 10M on the RTX
  machine, a follow-up moves it onto a thread with the gather in the meantime. It is not done now (no premature
  threading).
- **Boxes (GPU):** sculpting moves vertices and never changes the topology, so instead of a rebuild, `blas_refit.comp`
  recomputes every chunk's boxes from `positions` at each studio restart: one invocation per chunk, walking its nodes
  last to first (children before parents), then leaves from their triangles. That reads every index and position
  once, an estimated 1 to 3 ms at 10M on the RTX, once per still view. The quality of a refitted hierarchy falls after
  large deformations, so the next topology build (any remesh) restores it. Measured: rays/s on a sphere after a 60%
  inflate, against a fresh build, recorded in the PR.
- **TLAS:** rebuilt on the CPU per restart, from the chunk bounds the sculptor already keeps current. It is uploaded
  with the per-item inverse model.

### Tracing (`studio_trace.comp`, 8x8 workgroups over the viewport)
Per pixel, per sample, as the gather does today:
1. Reconstruct the position and normal from the 1x depth (the same code, moved into a shared include).
2. Pick a ray: cosine-weighted hemisphere for occlusion (R2 sequence k, Cranley-Patterson rotated by a hash of the
   pixel, deterministic), or toward the key light jittered over the Angle disc on one sample in `STUDIO_KEY_EVERY`.
3. Offset the origin along the normal by `1e-4 x scene radius + 2 x the pixel's depth footprint`, with `t_min` of
   the same size.

There is one dispatch per item that has triangles: each binds that item's tlas, blas_nodes, blas_order, blas_chunks,
positions and indices (6 read-only storage buffers, within SDL's 8), transforms the ray into mesh space and does an
any-hit traversal up to Reach. A hit stores 0 into an R32_FLOAT storage texture `visible` (cleared to 1 per sample;
only stores, no read-modify-write, so the order of the dispatches does not matter). The ray of a pixel and sample is the same in every item's dispatch because it is a pure function of
(pixel, k). A full-screen fragment pass then samples `visible` and adds `(visible, 1)` to `accum`'s red and green for an
occlusion sample, or to its blue and alpha for a key sample, through the additive blend the gather already uses
(`visible` is SAMPLER + COMPUTE_STORAGE_WRITE, which SDL allows; `accum` stays a colour target). The occlusion estimator is now `mean(visible)` under cosine sampling. It replaces `sum(vis x cos) /
sum(cos)` under uniform directions, and `studio_composite.frag` reads both the same way. Many small items mean many
dispatches; that is fine, since each traverses only its own tree. See-through items (Transparency) cast nothing, as
today.

### Fallback and limits
- The gather stays, untouched, used when: compute or a storage buffer is refused, an item's indices exceed 128 MB on
  Android (Vulkan's guaranteed `maxStorageBufferRange`, about 10.6M triangles; SDL exposes no limit query, so the cap
  is a constant), or Settings > Performance turns **Traced studio** off (default on, a remembered setting, so a slow
  tablet can opt out).
- Memory shows in Stats and the exit stats (`trace_mb`, `trace_build_ms`, `trace_rays_per_s`).

### Tests and checks
- geom: `chunk_blas_build` against `bvh_raycast` on random rays over an icosphere and a remeshed bake fixture (same
  first hit, any-hit agrees), the layout invariants (children after parents, every triangle once), u16 range, and a
  determinism test (serial vs pool bit-identical).
- App, llvmpipe: converged traced AO at 64 x 64 against a CPU reference computed with `bvh_any_hit` on the same rays.
  The test calls the same ray function from Odin (`trace_ray(pixel, k)` mirrored in GLSL), so the mean differs by
  under 2%. Same flags, same image: a 0-px diff. With Traced studio off, a 0-px diff against today. GPU validation
  smoke with it on, MSAA x4.
- RTX (Bolt): `--trace-bench` at 500k, 1M, 5M, 10M (build ms, refit ms, ms per sample at 1080p); target 8 ms a sample
  or less at 10M.

### Open questions for the review
1. Is it acceptable to give every mesh buffer COMPUTE_STORAGE_READ (versus recreating on first trace)?
2. Is the AND-across-items `visible` texture better than one merged TLAS with per-leaf item buffers? SDL cannot bind
   a variable number of buffers, so merging would mean copying all items into one buffer (rejected: memory).
3. As written, the topology build runs synchronously before the first traced sample after a topology change, which
   is one hitch of up to about 1 s at 10M. Is that acceptable for v1? The alternative is a threaded build on a copy of
   the indices, with the gather shown until it lands.

### 4.3 architect review applied (2026-10-27; overrides the addendum above)
- **Layouts.** `positions` are read as `float[]`, 12-byte stride, as `smooth_all.comp` does. `blas_order` is packed
  u16 pairs in u32 words, each chunk's run padded to an even count (no 16-bit storage in SDL). `blas_chunks` is
  16 B: `{node_off, order_off, first_tri, node_count}`.
- **Hidden and degenerate triangles.** Hidden triangles stay as (0,0,0) inside chunk ranges. The refit skips
  degenerate triangles, and the intersection rejects det == 0. Hide and unhide therefore only refit. Packed-index
  uploads (hiding, group corners) do not change the topology key.
- **Items without chunks** (the boolean preview) are split into fixed ranges of 1024 triangles, so they still cast.
- **Compute bindings.** `blas_nodes` (refit) and `visible` are bound read-write with `cycle = false`. `visible` is
  cleared in a render pass of its own (usage COLOR_TARGET + SAMPLER + COMPUTE_STORAGE_WRITE, checked with
  `GPUTextureSupportsFormat`), since a compute pass has no internal synchronisation. Key samples that face away keep
  1, as the gather does.
- **Jobs.** The per-chunk build uses heap scratch per worker, never the temp allocator.
- **Topology key: incremental per chunk.** Each chunk is keyed by (first_index, index_count, a hash of its indices)
  and only chunks whose key changed are rebuilt. The hash costs about 20 ms at 10M with no thread. This keeps dynamic
  topology and voxel objects from rebuilding everything after every stroke. The BLAS and its keys live inside
  `Mesh_Buffers`, released and remade with them.
- **Memory.** The geom test counts nodes per triangle. The leaf limit rises to 12-16 if 8 gives over 12 B/tri.
- **128 MB cap.** On Android it applies to every bound buffer (`blas_nodes` and dynamic topology's padded index
  pages included).
- **Ray origin.** No `t_min` equal to the offset. The origin is offset along the normal and toward the eye, with the
  pixel-footprint term clamped at silhouettes. Reach and the epsilons are scaled into mesh space by the model's scale.
- **BVH depth.** Median split past depth 24, and a test asserts the traversal stack bound.
- **Refit** runs only for meshes whose `version` changed since the last refit.
- **CPU reference test.** It compares interior pixels only (no depth step in 3x3), with a per-pixel bound as well as
  the 2% mean.
- **v1 scope cuts.** No Reach or Angle sliders: unbounded rays and 0.06 rad as constants, both noted as later work in
  the README. No setting, only a `--no-trace` flag for the 0-px check; the automatic fallback covers refusal.
  `trace_rays_per_s` is printed only by `--trace-bench`. The TLAS is rebuilt only when the hash of the chunk bounds
  changes.
- **Open questions answered.** (1) COMPUTE_STORAGE_READ goes on positions and indices only, with a retry without it
  (that mesh is then untraceable). (2) Keep the AND-across-items `visible` texture. (3) The sync build is fine for
  remesh, levels, HD and loading, and is incremental per chunk for everything else (above).

## 4.3 as built (2026-10-27, PR #174)
- As the review: per-chunk trees (leaf 12, ~11.5 B/tri), refit on GPU, TLAS over shown chunk bounds (leaf = run id),
  one dispatch per item into R32F `visible`, additive into the gather's accum encoding. Fallback = gather, `--no-trace`.
- Measured (llvmpipe, 4 threads, release): 3.8M-tri head scan builds in 183 ms / 44 MB; 500k retop in 26 ms; traced
  faster than the gather on llvmpipe (9 s vs 17 s / 150 frames). Traced vs gather within 12/255 off silhouettes.
- Also fixed: studio never sampled with only chunkless items (live boolean preview): scene_sphere uses Draw_Item.source.
- Later: Reach (bounded AO rays) and Angle sliders; RTX ms/sample and 10M refit timings from Bolt.

## 4.4 Render mode: design addendum (2026-10-27, for architect review)

### What exists after it
- **Render mode** (Scene palette > Render section, also a command, "render" / "path trace" / "cycles" in the palette). It is progressive path tracing of the shown scene, built up while the view stays still. Any change starts it over, as the studio render does.
- **What it traces:**
  - Real materials: Lambert diffuse plus GGX specular, metals included.
  - Light bouncing between objects, up to 6 bounces.
  - Soft shadows from every light that is on.
  - The environment: the built-in studio or the 4.1 image.
- **Controls:**
  - Samples: 1024 at first, from 16 to 4096.
  - Bounces.
  - Denoise, on at first.
  - Resolution: full on the desktop, half on tablets.
- **Saving:** the screenshot path saves it as a PNG. It reads `viewport_shown`, which shows the render first.
- **While it builds:** the viewport shows the studio render, live occlusion or the plain view, whichever would show otherwise. The render shows from its first sample when the view is still: progressive noise, as Blender's Cycles viewport.

### Best of each tool
- **Blender Cycles viewport:** starts at once when still, restarts on change, a sample count, and a denoiser.
- **Marmoset Toolbag:** the same lights and materials as the viewport, so turning it on changes realism, not the look's setup.
- **KeyShot and ZBrush BPR:** one switch, nothing to set up.
- **Nomad:** works on a tablet, at a lower resolution.

### Approach: one merged scene, one kernel
- **Why not per-item dispatches.** 4.3 dispatches once per item and only needs any-hit. A path needs the closest hit across all items, then shading with that item's data, then the next bounce.
  - Per-item dispatches (wavefront) would need a per-pixel state buffer of about 60 B a pixel (86 MB at 1600x900), plus three passes per item per bounce.
  - SDL_GPU binds at most 8 storage buffers a stage and has no bindless arrays.
- **What render mode does instead:** while it is on, it copies every traced item's GPU data into scene-wide buffers, using GPU-to-GPU buffer copies with offsets. One compute kernel then runs the whole path for each pixel.
- **The buffers** (7 read-only storage buffers):
  1. **Positions:** float3 in mesh space, each item's at an offset.
  2. **Indices:** rebased by the item's vertex offset, by a small compute pass, since a plain copy cannot add an offset.
  3. **Vertex attributes:** the octahedral normal (`Normal_Packed`) and `Paint_Packed`, 12 B a vertex. The normal buffer gains `.COMPUTE_STORAGE_READ` with the 4.3 retry pattern. Paint is zero where an item has none.
  4. **Nodes:** every chunk's BLAS from `Trace_Mesh`, then the scene TLAS.
  5. **Order.**
  6. **Chunks:** node_off, order_off, first_tri and node_count, plus the item index.
  7. **Items:** the inverse model and the model (similarities), the material, the slot materials, flags (paint on, groups on), and the vertex and triangle offsets. 16 at most. See-through items are left out, as in 4.3.
- **The scene TLAS** is built on the CPU over every item's shown chunks, using their world-space boxes (each mesh-space chunk box transformed by its similarity). When the walk enters a chunk, the ray is transformed into that item's mesh space; t is preserved because the scale is uniform and the direction is rescaled.
- **The copies happen at sample 0 of a still view, only for items whose `version` or `index_version` moved.** The scene buffers are kept between runs and grown by doubling. Cost is about one extra copy of the traced meshes: 10M vertices is about 120 MB of positions, 240 MB of indices and 120 MB of attributes.
- **On tablets** the 128 MB storage cap applies per buffer, so render mode refuses a scene whose merged buffers exceed it, and the section says so.

### The kernel (`render_trace.comp`, 8x8)
- **Primary rays** come from the camera, jittered within the pixel (an R2 point rotated by a pixel hash, as 4.3), so the result is anti-aliased with no raster G-buffer.
- **Closest hit:** a two-level walk with ordered children (near first) and t-max pruning. It shares the node layout and the IN_CHUNK stack trick with `studio_trace.comp`. Möller-Trumbore gives barycentrics.
- **The shading normal** is interpolated from the three vertices' octahedral normals and flipped to face the ray.
- **Materials map to one model:**
  - Base colour: the material's colour, or the paint where it covers, or the slot material where the triangle's group has one.
  - Classic presets: metallic 0, roughness `sqrt(2/(power+2))`.
  - MatCap materials: their tint at roughness 0.5.
  - Textured items: their material colour in this stage; maps are later work.
- **The BSDF:** Lambert plus GGX with VNDF sampling (Heitz 2018) and a Schlick Fresnel. The lobe is picked by Fresnel-weighted luminance.
- **Next-event estimation:**
  - One light picked per bounce, in proportion to its strength.
  - A sun is a cone of `light_shape.w` radius, falling back to studio_softness when that is 0. Point and spot lights are spheres of that radius, with spot falloff as `light_at` gives it.
  - Plus the environment: the built-in studio is sampled by cosine; an image uses an alias table over its luminance times sin(theta), built on the CPU when it loads.
  - The power heuristic (MIS) combines it with BSDF sampling for the environment and the area lights.
- **Russian roulette** from bounce 3; at most `bounces` bounces (6).
- **Misses:**
  - A primary miss shows the viewport's background: gradient, flat, or the environment when Environment > Background is on.
  - Later misses take the environment light.
- **Lighting matches the viewport.** The built-in studio is the GLSL `studio()` function, moved to a shared `studio.glsl` included by both. The ambient strength scales it as in the viewport. Lights are in view space as render.Lights carries them, so the kernel works in view space: each item's matrix is view times model.
- **Accumulation:** an RGBA32F `accum` texture, a running sum.
- **The first hit's guides:** albedo, normal and depth go to an RGBA16F and an R32F texture at sample 0 for the denoiser. They are re-averaged over the first 8 samples, so edges are anti-aliased.
- **RNG:** PCG per pixel, seeded by pixel and sample. The same device gives the same image, every run.

### Display and denoise (`render_display.frag`, `render_atrous.frag`)
- **A-Trous** (Dammertz 2010): 5 iterations, steps 1, 2, 4, 8 and 16, edge-stopping on normal, depth and albedo, with the filter's reach shrinking by 1/sqrt(samples) after 64 samples. It runs on the mean image (accum/samples) only on frames that add a sample, into a ping-pong RGBA16F pair, then demodulates and remodulates albedo.
- **Display:** exposure, PBR Neutral and the sRGB encode via `display.glsl`, into `shown` (RGBA8), at viewport size. It upsamples bilinearly when the render resolution is half.
- `viewport_shown` gives render mode's `shown` first when it is on and has at least one sample. Its sample count joins `idle.odin`'s busy test.

### Cost and limits
- **Per sample:** one dispatch, plus the denoise and display. On llvmpipe, expect seconds a sample at full size, which is fine for a check at 64x64. On a desktop GPU, tens of ms at 1600x900 for a 1M-triangle scene.
- **Memory:** about 1.5x the traced meshes while on. It is freed when render mode turns off.
- **Fallback:** a device refusal (pipelines, storage read) disables render mode with a line in its section. Nothing else changes.
- **Off:** not one pixel changes from 4.3. Checked by a 0-px diff.

### Tests and checks
- **Unit tests (render package, CPU):**
  - The scene TLAS from transformed chunk boxes.
  - The alias table: its sums, and that a constant image gives a uniform pdf.
  - Material mapping: power to roughness.
  - Merged-buffer offsets and index rebasing (a CPU mirror of the compute pass).
- **GPU checks:**
  - White furnace: a white diffuse sphere in a constant environment of 1 gives 1 within 1% at 1024 spp at 64x64.
  - Determinism: two runs at 64x64 and 8 spp give 0 px.
  - Off is 0 px against the base.
  - `--gpu-debug` clean with MSAA off and x4.
  - Images of the head and of two spheres (gold and grey) with an image environment, described.
- **Script:** `render_mode on`, `set render_samples 64`, `set render_bounces 4`, `set render_denoise off`.
- **Exit stats:** `render_samples`, `render_ms`, `render_mb`.

### Split
- **4.4a:** merged scene, kernel, accumulation, display, Render section, script and stats.
- **4.4b:** the A-Trous denoiser and its guides, the image environment's importance sampling (4.4a samples the image by cosine), and half resolution on tablets.

### Open questions for the review
1. Is it acceptable to copy into merged buffers (memory 1.5x while on)? The alternative is per-item wavefront passes with a per-pixel state buffer.
2. Should the kernel work in view space (to reuse render.Lights unchanged) or world space (needs the inverse view for lights)?
3. Should render mode share the studio's `changed` signal and restart path, or keep its own copy of that logic?

### 4.4 architect review applied (2026-10-27; overrides the addendum above)
- **World space throughout.**
  - The kernel and the scene TLAS (from world chunk boxes) are in world space.
  - A ray enters an item's mesh space as `inv_model * o` and `mat3(inv_model) * d`, never normalised, so t stays in world units across items.
  - Normals turn by `mat3(model)/s`; offsets are scale-free (Ray Tracing Gems ch. 6) and the side is picked by the geometric normal.
  - `lights_to_world(lights, view)` in render turns pos, spot and rig back, with a round-trip test. An orbit only restarts with new uniforms.
- **Accumulation:** two RGBA32F textures, ping-ponged. The previous one is read through a sampler (texelFetch, set 0) and the next is written write-only (set 1). Both usages are checked with GPUTextureSupportsFormat.
- **Guides:** albedo RGBA8, normal RG16F octahedral and depth R32F, from one unjittered primary pass at sample 0 (4.4b).
- **MIS:**
  - BSDF rays test every light (suns as cones, point and spot lights as spheres, 8 at most) and add their emission with the power-heuristic weight.
  - Camera rays never see lights.
  - In 4.4a the environment is reached only by BSDF rays (weight 1). 4.4b adds it to the light pick, with the pick probability in the pdf.
  - The BSDF pdf in the weights is the mixture `w_s pdf_ggx + w_d pdf_lambert`, with the lobe picked by F(n.v).
- **Light radiance matches the viewport's `3 s k`.**
  - A sun is a cone of half-angle θ = studio_softness (light_shape.w when the lights thread fills it), radiance `3 s c/(π sin²θ)`.
  - A point or spot light has radius R = softness × its distance to the scene's centre (or its own size later), radiance `3 s ref² c/(π R²)`, times the window and spot factors of `light_at`.
  - The built-in studio's diffuse keeps the viewport's `0.7 ambient`.
- **Memory is about 2x the traced data** (about 35 B a triangle: positions, indices, normals, paint and the BLAS). It is reported in `render_mb`. On tablets the sum is refused above 128 MB a buffer and above 256 MB in total.
- **Tiles:** a sample dispatches in row tiles under a per-frame budget (8 ms on Android, 16 on the desktop, measured on the CPU by fence on llvmpipe only through the frame cap). It counts once every tile is done. This stays deterministic.
- **Studio:** while render mode runs, `studio_frame` gets max_samples 0, so it only resets.
- **Buffers:**
  - Plain GPU copies only. Indices are copied as they are, and the item record holds vertex_off and tri_off.
  - Chunks are written on the CPU with node_off, order_off and first_tri rebased and the item packed into node_count's high 12 bits.
  - Attributes are one buffer with a normals section and a paint section. There are no new usage flags on today's buffers (SDL's Vulkan backend gives every buffer TRANSFER_SRC|DST).
  - Paint is skipped by an item flag where absent; the mask nibble is stripped; the group comes from the triangle's first index.
- **No item cap:** items are a storage buffer.
- **Classic power to roughness:** `(2/(power+2))^(1/4)` (α = roughness²).
- **Primary misses** composite the render over `vt.color` by hit coverage (accum.a). Background, dither, grid and environment background then come free.
- **The alias table** is an RG32F texture built on the decode thread over a mip of at most 1024x512, with pdf luminance × sin θ and Jacobian `W H/(2π² sin θ)`. The built-in studio is baked once into a small panorama and sampled the same way (4.4b).
- **Furnace test:** reads the linear accumulation. Pure Lambert gives 1, and the full BSDF stays at or below 1.
- **Show threshold:** render mode shows from 4 samples (later, from the first denoised image).
- **Tablets:** half each way, a quarter of the pixels.
- **Refactor:** `trace_mesh_update` and the refit leave file scope so render mode can bring trees up to date without the studio.
- **App:**
  - `changed` is computed once and passed to both.
  - `Path_Render` keeps its own samples and reset (changed, bounces, scale, environment stamp); denoise only redisplays.
  - `viewport_shown` checks render mode first, and idle counts its samples.
  - Resolution and denoise are remembered; render mode itself is not.
- **Follow-up (not v1):** a no-copy path for a single item.

## Studio shadows from every light (after #187 light sizes)

Today the studio's key samples (1 in 4) trace or shadow-map only the brightest light (lights_key), as a direction from the scene centre, over a disc of `softness`; the composite darkens the viewport by mix(1, b/a, shadow) where key samples add (vis, 1) to b, a.

Change:
- Each key sample m = k / 4 picks one light j for every pixel, by brightness (strength x max rgb) through a golden-ratio sequence u = fract(0.5 + m * 0.618034) against the cumulative chances (render.lights_to_world's size.z/w, already used by render mode).
- Disc: a sun keeps a cone of half-angle asin(shape.w) when shape.w > 0 (tangent-plane radius tan of it), else `softness` exactly as now. A point or spot light is a sphere of radius shape.w (or distance-to-centre x tan(softness) when 0) at its world position; the traced kernel aims each pixel's ray at a point on the disc of that sphere facing the pixel and limits the any-hit test to t < 1 along the unnormalised ray (mesh space through the similarity keeps it). The shadow-map fallback keeps one direction from the scene centre (as lights_key does now) with the sphere's angular radius.
- Weight: a pixel adds (vis * w, w) with w = max(n.l, 0) x the light's falloff (light_at's (ref/d)^2, reach window, spot cone), shared by studio_trace_add.frag and studio_gather.frag through a new include studio_weight.glsl. Since a light's chance is its brightness / total, w / p_j is the light's share up to the constant total, so b / a converges to the brightness-weighted visibility of the light the pixel actually receives. A pixel no light faces adds nothing and stays unshadowed (it did before too: facing away added (1, 1)).
- When exactly one light is lit, w = 1 everywhere and the old code paths run: a single sun of size 0 is bit-identical to today (check 0 px). With the default lights (key + fill 0.3) the image changes by design: the fill now shadows too, and the key gets ~77% of the shadow samples.
- Uniforms: Trace_Uniforms gains the point light's world position, radius and kind; the add pass and Gather_Uniforms gain the weight's light (pos or dir + kind, ref/reach/inner cos, spot axis + outer cos) and the inverse view projection (gather has it). No new buffers or textures.
