# Research 2: advanced rendering, hybrid effects and path tracing (2026-10-27)

Scope: raster improvements (A) vs hybrid compute-traced effects (B) vs an optional progressive path tracer (C) for the
sculpting app, plus a native Vulkan hardware-RT side path. Source of truth for what exists: `notes/rendering/audit.md`.
Code read on branch `claude/project-thread-f462c2` (= `odin-sculpt`), SDL 3.4.18 source in `deps/sdl3-src`. Nothing was
measured on a real GPU in this research; every number below is an estimate with its working, or a quoted figure.

## 1. The existing renderer, assessed for this purpose (verified in code)

| Fact | Where | Consequence for A/B/C |
|---|---|---|
| Viewport is `R8G8B8A8_UNORM`, shaders gamma-encode themselves (`pow(c, 1/2.2)`), ACES fit inline, no exposure | `renderer.odin:19`, `mesh.frag:126-141` | Every option below needs an HDR intermediate first: IBL, traced lighting and denoising all work in linear radiance. This is the one prerequisite shared by A, B and C. |
| Partial redraw, idle cache, per-chunk indirect draws, LOD while moving | `renderer.odin:791-963`, `prepare_draws` 979-1040 | Any screen-space pass must either re-run on the damage rect (padded by its kernel radius) or run only when idle. The studio render already takes the "only when idle" route (`main.odin:765`: `changed := !drawn.partial \|\| drawn.redrawn_px > 0`). |
| Studio render: 1 shadow-map light sample per still frame into RGBA16F accum, R2 sequence, 2048² map over the scene sphere, composite multiplies the viewport | `studio.odin:73-170`, `studio_gather.frag`, `studio_composite.frag` | A ready progressive framework: restart-on-change, sample counter, UI (`kit_scene.odin:464-475`, cap `STUDIO_SAMPLES_MAX = 1024`). B can swap the shadow-map gather for a compute dispatch and keep everything else. Weakness: a scene-sphere shadow map of radius R has texels of 2R/2048 ≈ R/1000, so crevices finer than ~0.1% of the model are lost, which is exactly 10M-triangle detail; normals are depth-reconstructed (`studio_gather.frag:35-46`), so the AO cosine term is noisy at silhouettes. |
| Compute works: 5 read-only + 1 read-write storage buffers, 2D dispatch, bit-identical to CPU on llvmpipe | `smooth_compute.odin:64-75, 208-219`, `smooth_all.comp` | Proves the SDL_GPU compute path, the std430 flat-float trick (`float src[]`), per-step pass ordering and fence timing. B and C are compute shaders of the same shape plus more buffers. |
| GPU vertex data: positions (12 B) and oct normals (4 B) in separate VERTEX buffers, u32 indices; usage flags are `{.VERTEX}` / `{.INDEX}` only | `renderer.odin:477-479` | A traced path reads triangles from storage buffers. Adding `.COMPUTE_STORAGE_READ` to those usage flags lets the tracer reuse the mesh buffers already on the GPU (no second copy of 10M triangles). Must be verified on the RTX (flag combination is legal in the header; `SDL_gpu.h:978` warns storage reads expect std140-style layout, but `smooth_all.comp` already reads flat float arrays fine under Vulkan). |
| CPU BVH: binary, 36-B nodes, Morton build (`bvh_build_morton`, leaf = `NODE_TRIANGLES` 1024 for the sculptor), refit of dirty leaves only (`bvh_refit_leaves`), picking/bake BVHs built ad hoc with leaf 4 | `geom/bvh.odin:33-51, 197-231, 367-442`; `sculpt/brush.odin:24, 249, 881` | The sculptor's BVH is a *node* tree (1024 tris per leaf): perfect as a GPU top level (TLAS) that is refit per stroke, useless as a ray-tracing leaf (1024 ray-triangle tests per leaf hit). A GPU tracer needs a per-node bottom level (BLAS) built from `Node.tri_first/tri_count`. |
| GPU timing is "submit, wait on fence" (`main.odin:773-786`); SDL_GPU has no timestamp queries (no match for "timestamp" in `SDL_gpu.h`) | | Compute passes can be timed the same way (the compute trial does); per-pass GPU timings need a separate submit per pass. |
| Tests: `--dump-viewport` PPM, `scripts/ppm.py diff`, smoke under GPU validation, `gpubench` 500k-10M, all on llvmpipe in CI | `main.odin:46, 878`, `gpubench.odin` | Compute tracing is testable on llvmpipe at small sizes (correctness, determinism, leaks), never for speed. |

Verdict on fitness: the renderer is a sound base. It is fast because it draws as little as possible; nothing in A-C may
run inside a stroke frame unless it costs under ~0.1 ms, which rules out per-frame tracing during strokes on the RTX and
all screen-space passes during strokes on tablets. The studio render's idle-only progressive design is the right
integration point for everything heavier.

## 2. Comparison

| | A: targeted raster | B: hybrid compute-traced AO/shadows (studio render v2) | C: progressive path-traced mode |
|---|---|---|---|
| Visual value for sculptors | High and immediate: HDR + exposure, IBL with a real HDRI, interactive GTAO, fitted shadows, gradient/env background. Covers the "turntable in a studio" look. | Medium-high at review time: exact crevice occlusion at 10M-50M tris (no shadow-map resolution floor), correct contact shadows, soft area shadows, bent-normal AO. Invisible while sculpting (idle only). | High for presentation and material inspection only: GI, colour bleeding between objects, inter-reflections, soft area lights, physically consistent metals. Little value until per-object materials and IBL exist (audit: both MISSING); with one global material and a procedural studio it shows nothing the raster path cannot. |
| GPU cost (RTX 3060 Ti, 1080p) | GTAO ~0.5-1 ms full-res (published GTAO figures are ~0.5 ms at 1080p on 2016 consoles); IBL adds ~2 texture fetches per pixel: negligible. Shadow map re-render of 10M tris: ~0.5 ms per sample (same as an orbit frame, measured 0.54 ms). | 1 AO or shadow ray per pixel = 2.1M rays/sample. Software BVH traversal estimate 0.3-1 Gray/s for incoherent rays on this GPU (tinybvh quotes 5 Gray/s *coherent* on an RTX 5080 laptop; incoherent rays on a 10M-tri mesh are 5-15x slower and the 3060 Ti is roughly half the GPU) => 2-7 ms per sample, i.e. one sample per frame at 60 Hz while idle. | 1 camera ray (or the raster G-buffer) + 4 bounces with next-event estimation = ~8-9 rays/pixel/sample = 17-19M rays => 20-60 ms per sample => 15-50 spp/s. 64 spp (enough with a spatial denoiser) in 1.5-4 s; 1024 spp clean in 20-70 s. |
| Mobile (Adreno 7xx/Mali G7xx tablets) | GTAO at half-res, idle only; IBL fine. | ~10-30x fewer rays/s than the RTX (estimate from compute throughput ratios, unmeasured) => 20-100 ms per 1080p sample; run at half-res, one sample every few frames. Viable but slow. | 0.5-2 s per sample at 1080p: only at quarter-res with denoising, or as an export-only render. |
| Memory (see 5) | +17 MB HDR target, +~10 MB IBL maps, +4-8 MB GTAO | +~100 MB at 10M tris, +~500 MB at 50M, + accum buffers ~35 MB | B's BVH + ~130 MB render/denoise buffers at 1080p |
| Risk | Low: all passes are fragment shaders over existing targets; partial redraw rules known. | Medium: new GPU buffer layout (design review required by AGENTS.md), BLAS maintenance after strokes, compute perf on tablets unknown, SDL storage-buffer size limits on mobile (Vulkan guarantees only 128 MB per storage buffer range). | High: large shader surface (BSDF sampling, MIS, env sampling, denoiser), tuning without a real GPU in CI, divergence between llvmpipe and RTX floats, materials model not yet designed. |
| Effort (one engineer) | 2-4 weeks | 3-4 weeks after A's HDR stage | 6-10 weeks after B, plus ongoing |
| Platform coverage | All (Vulkan on all three; llvmpipe runs it) | All; needs `.COMPUTE_STORAGE_*` on mesh buffers; tested on llvmpipe at small sizes | All in principle; tablets only at reduced resolution |
| Preserves current speed | Yes if idle-only or damage-rect aware | Yes by design (nothing runs during strokes) | Yes (separate mode) |

## 3. SDL_GPU 3.4.18 feasibility (`deps/sdl3-src/include/SDL3/SDL_gpu.h`)

What is there:
- Compute pipelines and passes: `SDL_CreateGPUComputePipeline` (line 2601 doc, resource sets at 2606-2612: set 0 sampled
  textures then read-only storage textures then read-only storage buffers, set 1 read-write, set 2 uniforms),
  `SDL_BeginGPUComputePass` (3703), `SDL_BindGPUComputeStorageBuffers`/`Textures` (110-111),
  `SDL_DispatchGPUCompute` (115) and `SDL_DispatchGPUComputeIndirect` with `SDL_GPUIndirectDispatchCommand` (1589-1594).
- Storage usage flags for buffers `COMPUTE_STORAGE_READ/WRITE` (992-993) and textures (910-912, including
  `COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE` 912, "only supported by a limited number of texture formats" 897-898).
  `SAMPLER` + `GRAPHICS_STORAGE_READ` on one texture is invalid (888), so a traced result is written as a storage texture
  or buffer and *sampled* in the composite, or read as a graphics storage buffer in the fragment shader.
- Universally supported storage texture formats include `R32_FLOAT`, `R32G32_FLOAT`, `R32G32B32A32_FLOAT`,
  `R16G16B16A16_FLOAT` (731-742); the same floats are colour-target formats (696-699), so an HDR intermediate is safe.
- Limits in `src/gpu/SDL_sysgpu.h`: 8 storage buffers, 8 storage textures and 4 uniform buffers per stage (30-32).
  A path tracer needs about 6 buffers (nodes, triangle order, indices, positions, normals, env alias table) + accumulators:
  it fits, but barely; pack where possible. Buffer size is `Uint32` (1806): 4 GB per buffer, far above 50M tris x 12 B.
- Cube textures (926) and `SDL_GenerateMipmapsForGPUTexture` (469) exist for IBL.
- The FAQ (179-186) says ray tracing and mesh shaders are "definitely not near future items".

What is not there (verified by grep of the header, the Odin binding `deps/odin/vendor/sdl3/sdl3_gpu.odin:814-817` and
`src/gpu/vulkan/SDL_gpu_vulkan.c`):
- No acceleration structures, ray queries, ray-tracing pipelines, timestamp queries, 64-bit atomics guarantees, or
  subgroup controls. Shader features such as `shaderInt64` are *optional Vulkan 1.0 features* the app may request
  (`SDL_gpu_vulkan.c:11549-11550`) through `SDL_GPUVulkanOptions` (header 2416-2426: API version, feature chain, device
  and instance extension lists), but SDL only enables them; it exposes nothing back.
- `SDL_GetGPUDeviceProperties` (2590) publishes only four strings: device name, driver name, version, info
  (2592-2595). There is no `VkInstance`, `VkPhysicalDevice`, `VkDevice`, `VkQueue`, nor the `VkBuffer` behind an
  `SDL_GPUBuffer`. The handles live in private structs (`VulkanRenderer`, `VulkanBuffer` in `SDL_gpu_vulkan.c`).

Native Vulkan hardware-RT side path, therefore: not feasible without patching SDL. Since SDL is built from source here,
a local patch (~100-200 lines) could add properties exposing the device handles and set
`VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT` on buffers; a GLSL compute shader with `GL_EXT_ray_query` could then
take the acceleration structure by 64-bit address in a uniform (`accelerationStructureEXT(uvec2)`), which sidesteps
SDL's lack of an AS descriptor type. But the app would then own: acceleration-structure build command buffers and their
synchronisation against SDL's internally tracked barriers, queue sharing, AS memory, and a fork of a pinned dependency.
Coverage: RTX-class desktops only; tablets with Vulkan RT are rare; llvmpipe has none, so no CI. Recommendation:
do not build it; a software BVH in compute (B/C) covers every target, and hardware RT is re-evaluated only if SDL adds it.

## 4. Papers and implementations

- Wald, Boulos, Shirley 2007, *Ray Tracing Deformable Scenes Using Dynamic BVHs* (ACM TOG): refit per frame, rebuild
  when quality degrades; the model for per-stroke BLAS refit + rebuild at stroke end.
- Lauterbach et al. 2009 *Fast BVH Construction on GPUs* (LBVH) and Karras 2012 *Maximizing Parallelism in the
  Construction of BVHs, Octrees, and k-d Trees* (HPG): linear-time Morton builds; `bvh_build_morton` is the CPU form.
- Aila & Laine 2009 *Understanding the Efficiency of Ray Traversal on GPUs* (HPG): persistent-threads traversal, the
  baseline kernel shape (while-while, speculative traversal) for a compute tracer.
- Ylitie, Karras, Laine 2017 *Efficient Incoherent Ray Traversal on GPUs Through Compressed Wide BVHs* (HPG): 8-wide
  quantised nodes (80 B in tinybvh's implementation), 35-60% of the memory of an uncompressed BVH, 1.9-2.1x faster
  incoherent traversal. Build requires a collapsed SAH tree: slow to rebuild and awkward to refit; a stage-2 optimisation.
- tinybvh (J. Bikker, MIT): BVH layouts 32 B (binary), 64 B (`BVH_GPU`, both child boxes per node), 80 B CWBVH; refit
  supported when triangle counts do not change; OpenCL/compute kernels for each layout; 5 Gray/s claimed on an RTX
  5080 laptop in Sponza (binary layout). A direct reference for layouts and kernels, not a dependency (C++).
- GTAO: Jimenez et al. 2016 *Practical Realtime Strategies for Accurate Indirect Occlusion* (SIGGRAPH courses).
- Heitz 2018 *Sampling the GGX Distribution of Visible Normals* (JCGT) for the specular sampler; Karis 2013 split-sum
  for the IBL prefilter (the fit is already in `mesh.frag:43-49`).
- Veach & Guibas 1995 MIS; PBR Book 4th ed. chapters 12-14 (light sampling, alias tables for environment maps).
- Dammertz et al. 2010 *Edge-Avoiding À-Trous Wavelet Transform* and Schied et al. 2017 SVGF: a spatial À-Trous with
  depth/normal guides is enough for a progressive still (no temporal history needed); SVGF's variance-guided weights
  are worth adopting; ReSTIR GI (Ouyang et al. 2021) is for real-time animated path tracing and does not pay off here.
- Intel Open Image Denoise: CPU (x86 and ARM NEON), C API, optional final-frame denoise on desktop; a shipped
  dependency (sm-store review) and 20+ MB, so optional and late.
- Implementations: GLSL-PathTracer (MIT; two-level BVH flattened to GPU, Disney BSDF, MIS, tiles, OIDN) is the
  closest open design to C; Blender Cycles (Apache-2) for adaptive sampling, light tree and denoiser integration,
  EEVEE for raster GI/shadows (A); Marmoset Toolbag 4 ships compute ray tracing on any modern GPU with RTX
  acceleration where present, i.e. exactly the B/C split; ZBrush BPR is a 2.5-D depth-buffer render (AO, shadows,
  SSS from the pixol buffer), not a path tracer, which is why the studio render already competes with it.
- SDL: `SDL_gpu_examples` (TheSpydog) has the compute storage-texture and indirect examples; SDL_shadercross is
  not needed while the app stays SPIR-V-only.

## 5. Memory and time estimates (working shown)

Mesh on the GPU today: 16 B/vertex + 12 B/triangle; closed meshes have V ≈ T/2.
- 10M tris: 5M x 16 = 80 MB + 120 MB indices = 200 MB. 50M tris: 400 + 600 = 1.0 GB.

BVH for B/C, two-level, reusing the mesh buffers for triangle data:
- TLAS: the sculptor's node tree. 10M/1024 = 9,766 leaves -> ~19.5k nodes x 32 B = 0.6 MB. Refit is already done on the
  CPU per stroke (`bvh_refit_leaves`); upload is a copy of the flattened node array (0.6 MB).
- BLAS per node: 1024 tris at 8 tris/leaf = 128 leaves, 127 internal nodes; at 64 B per internal node (both child boxes,
  tinybvh `BVH_GPU` style) = 8.1 KB, plus a local triangle order of 1024 x u16 = 2 KB. Per triangle: ~10 B.
  10M tris: ~100 MB. 50M tris: ~500 MB. With 4 tris/leaf: ~18 B/tri (180 MB at 10M), traversal faster, memory worse.
- CWBVH later: Ylitie's 35-60% -> ~40-60 MB at 10M.
- Build time, CPU: `bvh_build_morton` builds "20M triangles in well under a second" per its comment (unmeasured here);
  per-node BLAS builds are independent, so the pool parallelises them. Budget to set as acceptance: whole 10M mesh
  <= 1 s on 8 threads; after a stroke that dirtied N nodes, rebuild only those: 500 nodes = 512k tris, estimate
  20-50 ms. Because B/C run only when idle, this latency hides behind the first accumulated frames.
- Upload after a stroke: 500 nodes x 10 KB = 5 MB through the existing 16 MB transfer buffer: one copy pass.
- Vulkan minimum `maxStorageBufferRange` is 128 MB; some mobile drivers report exactly that. The 10M node buffer
  (100 MB) fits; 50M does not: split into <= 128 MB buffers (8 storage slots available) or restrict tablets to <= 10M.

Screen buffers at 1920x1080 (2.07 Mpx):
- HDR intermediate RGBA16F: 16.6 MB. Studio accum RGBA16F: 16.6 MB (exists). PT accumulator RGBA32F: 33 MB.
- Denoiser: normal+depth guide (RGBA16F 16.6 MB) + two ping-pong colour RGBA32F (66 MB) + moments (R32G32F 16.6 MB)
  = ~100 MB. Total C at 10M on the RTX: 200 + 100 + 33 + 100 ≈ 430 MB plus the existing viewport and cache (4 x 8 MB).

Ray budgets (estimates, to be replaced by measurements):
- B: 2.1M rays/sample at 0.3-1 Gray/s = 2-7 ms. 256 samples (current default) in 4-14 s at 60 Hz idle; compare the
  shadow-map studio at ~1 ms/sample (10M-triangle shadow pass 0.5 ms + gather).
- C: 17-19M rays/sample = 20-60 ms; 64 spp 1.5-4 s; 1024 spp 20-70 s.
- Tablets: assume 10-30x slower until measured: B at half-res, one sample every 2-4 frames; C export-only.

## 6. Recommendation: not now, and what "later" should look like

The raster path meets the immediate needs. ZBrush-level interactivity is the product goal and it is met (0.41 ms GPU for
a 10M stroke); the studio render already gives a BPR-class review image. The missing visual value today is *material and
lighting*, not light transport: HDR pipeline with exposure, IBL from a real HDRI, MatCap and per-object materials (the
other research threads), interactive GTAO and a better-fitted studio shadow. All of these are approach A and all are
prerequisites of B and C anyway (a path tracer without IBL and per-object materials renders a grey ball in a procedural
box). Postpone B and C; do A first.

Do not build a native Vulkan hardware-RT path: SDL_GPU exposes no handles (section 3), it would fork a pinned
dependency, cover one platform and be untestable in CI.

When A is done, B is the right next step, not C: it slots into the existing studio framework, removes the shadow-map
resolution floor that hides 10M-triangle detail, costs ~10 B/tri, and its BVH is the foundation C would need. C stays
an optional "render" mode for presentation, built only once per-object materials exist and B's BVH is in production.

## 7. Staged plan (each stage leaves the renderer working; nothing runs during strokes)

Common acceptance for every stage: `python scripts/gate.py` green; `--dump-viewport` PPMs of the smoke scenes with the
new feature *off* are 0-pixel identical to the previous build (`scripts/ppm.py diff`); `gpubench` at 500k-10M: Orbit and
Stroke GPU p50 within 5% and Stroke CPU p50 within 5% of `build/gpubench.md` baseline on the RTX; smoke (300 frames,
GPU validation) with the feature on; the Stats panel shows the added GPU memory; every control is a registry command
with a script verb.

Stage 0 (A, prerequisite, ~1 week): HDR intermediate `R16G16B16A16_FLOAT` colour target + tonemap/exposure pass into the
existing UNORM viewport; shaders stop gamma-encoding; `--dump-viewport` reads the tonemapped UNORM as today.
Acceptance: classic materials PPM diff <= 1/255 per channel vs today (rounding only); +16.6 MB at 1080p; orbit GPU
+<= 0.1 ms at 10M (one full-screen pass).

Stage 1 (A, 2-3 weeks): IBL (.hdr RGBE loader, equirect -> cubemap, GGX prefilter in compute, SH9 irradiance on CPU),
environment/gradient background, GTAO as an idle-only pass (or re-run on the damage rect padded by its radius when
measured < 0.2 ms), studio shadow map fitted to the visible part of the scene with 4096 texels (64 MB D32 budget) and
cosine-weighted hemisphere directions. Acceptance: furnace-style check, a white diffuse sphere under a constant 1.0
environment renders 1.0 ± 2% before tone mapping (read back via `texture_download`); GTAO at 1080p <= 1 ms on the RTX
(`--time-gpu`); studio converged image of the 10M sphere differs from stage 0 only in crevices (visual check by the
verifier agent, PPM crop).

Stage 2 (B, 3-4 weeks, design review first: new GPU buffer layout): `render/trace.odin` with a flattened two-level BVH
(TLAS from `Sculptor.bvh` flattened, BLAS per `Node` built on the pool with `bvh_build_morton`-style code at leaf 8,
rebuilt for nodes the stroke changed when the stroke ends); mesh buffers created with `.COMPUTE_STORAGE_READ` added;
`studio_trace.comp` replaces the shadow-map gather when the device accepts it (fallback: the current gather). Also
`--trace-bench`: rays/s for AO rays at 500k-10M. Acceptance: BVH build 10M <= 1 s on 8 threads, post-stroke update of
500 nodes <= 50 ms off the stroke path (stroke CPU unchanged in gpubench); GPU memory <= 12 B/tri extra, reported;
AO sample <= 8 ms at 1080p/10M on the RTX; converged AO vs a CPU `bvh_raycast` reference at 64x64 on llvmpipe within
2% mean; studio PPM determinism on llvmpipe (same flags -> 0 diff) at small sizes; validation-clean smoke.

Stage 3 (C, optional, 6-10 weeks): "Render" mode in the Scene palette: progressive PT from the raster G-buffer primary
hit, GGX/Lambert with VNDF sampling, NEE for the key/fill as area lights + environment importance sampling (alias table),
power-heuristic MIS, Russian roulette, 4-6 bounces, RGBA32F accumulation, À-Trous denoise with sample-count-decaying
radius, exposure/tonemap through stage 0, PNG save. Acceptance: white furnace at 1024 spp within 1%; 64x64 x 8 spp
PPM deterministic on llvmpipe; spp/s at 1080p recorded by `--trace-bench`; memory <= 450 MB total at 10M on the RTX;
tablets: quarter-res only, enabled behind a setting.

Stage 4 (later): CWBVH conversion for idle meshes, OIDN final-frame denoise on desktop (dependency review), hardware RT
only if a future SDL exposes it.

## Sources
- SDL_gpu.h (3.4.18, local copy): deps/sdl3-src/include/SDL3/SDL_gpu.h; https://github.com/libsdl-org/SDL/blob/main/include/SDL3/SDL_gpu.h ; https://wiki.libsdl.org/SDL3/CategoryGPU
- https://github.com/TheSpydog/SDL_gpu_examples ; https://github.com/libsdl-org/SDL_shadercross
- https://github.com/jbikker/tinybvh (layouts, refit, 5 Gray/s figure)
- https://research.nvidia.com/publication/2017-07_efficient-incoherent-ray-traversal-gpus-through-compressed-wide-bvhs (Ylitie et al.)
- https://research.nvidia.com/publication/2009-08_understanding-efficiency-ray-traversal-gpus (Aila & Laine)
- https://research.nvidia.com/publication/2012-06_maximizing-parallelism-construction-bvhs-octrees-and-k-d-trees (Karras)
- https://dl.acm.org/doi/10.1145/1189762.1206075 (Wald et al., dynamic BVH refit)
- https://www.activision.com/cdn/research/Practical_Real_Time_Strategies_for_Accurate_Indirect_Occlusion_NEW%20VERSION_COLOR.pdf (GTAO)
- https://jcgt.org/published/0007/04/01/ (Heitz, GGX VNDF sampling)
- https://research.nvidia.com/labs/rtr/publication/schied2017spatiotemporal/ (SVGF) ; https://jo.dreggn.org/home/2010_atrous.pdf (À-Trous)
- https://research.nvidia.com/publication/2021-06_restir-gi-path-resampling-real-time-path-tracing
- https://pbr-book.org/ ; https://raytracing.github.io/ ; https://developer.nvidia.com/ray-tracing-gems-ii
- https://github.com/knightcrawler25/GLSL-PathTracer/ ; https://github.com/blender/cycles ; https://marmoset.co/toolbag/rendering/
- https://www.openimagedenoise.org/
