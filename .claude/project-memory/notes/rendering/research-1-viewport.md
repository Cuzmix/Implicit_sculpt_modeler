# Research 1: viewport shading, lighting and material presentation (2026-10-27)

Scope: the gaps in `notes/rendering/audit.md`, judged against ZBrush (MatCap/LightCap/BPR), Marmoset Toolbag and
Blender Workbench. Code read: `src/render/shaders/mesh.frag`, `mesh.vert`, `renderer.odin`, `studio.odin`,
`studio_gather.frag`, `studio_composite.frag`, `ui_pass.odin`, `src/app/material.odin`, `kit_scene.odin:407-476`,
`main.odin:708-752`, and the SDL 3.4.18 headers/`SDL_gpu.c` in `deps/sdl3-src` for the MSAA/cube/mipmap rules.
Research only; nothing was changed.

The one-line verdict: the physically based code is right, the *colour pipeline and the lighting rig around it* are
what make forms read badly. The ZBrush look sculptors want is MatCap + cavity, which this renderer can add with one
texture fetch and a few derivative instructions, with no new pass, so partial redraw and the idle cache are untouched.
MSAA is the only essential item that costs real GPU time, and it is affordable.

## 1. What exists: quality assessment of mesh.frag

Correct, keep:
- GGX `D = a²/(π d²)`, Hammon's height-correlated Smith fit `V = 0.5/lerp(2 NoL NoV, NoL+NoV, a)`, Schlick F,
  `(diffuse/π + DVF)·NoL`: all match Filament's recommended forms. `a = rough²`, rough clamped to 0.04 (fp32 safe;
  Filament uses 0.089 only for fp16).
- Karis's env BRDF fit coefficients are exact; `f0·A + B` is applied correctly to the blurred environment.
- Wrap-Lambert, rim, flat shading from `dFdx/dFdy`, mask darkening: fine for a clay viewport.

Wrong or weak, fix:
1. **Gamma 2.2 instead of the sRGB OETF** (`pow(c, 1/2.2)` at lines 68, 127, 141; `pow(., 2.2)` paint decode in
   mesh.vert:53). At linear 0.001 sRGB gives 3/255, 2.2 gives 11/255; at 0.01, 25 vs 31. Crevices and the dark
   floor of the studio environment come out grey instead of black, which flattens every sculpt. Zero-cost fix.
2. **The key light is counted twice** in the PBR path: `direct(..KEY_DIR..)·3.0` plus the `studio()` softbox lobe
   centred on the same `KEY_DIR` with energy 4.0. Metals show one over-bright blob rather than a highlight plus a
   soft reflection. Either drop the direct key for PBR (ZBrush-like: environment only) or move the softbox off-axis.
3. **The procedural environment is rotationally symmetric and grey.** It is a reasonable stand-in for *diffuse*
   light (the irradiance of a uniform grey sky is right) but chrome/steel read as a grey gradient ball because there
   is nothing asymmetric to reflect. Two or three coloured lobes (warm key, cool rim, darker floor) would fix most of
   it without an HDRI.
4. **No horizon occlusion** on the environment reflection: on bumpy sculpts the reflection vector dips below the
   surface and picks up sky. Filament's `h = min(1 + dot(r, n), 1); spec *= h*h` is two instructions.
5. **No specular anti-aliasing.** With sub-pixel triangles at 5-10M vertices, Chrome (rough 0.08) sparkles.
6. **Tone mapping applies to PBR only** and inside the material shader, so a Clay object and a Gold object in the
   same scene go through different transfer curves; no exposure control; Narkowicz ACES hue-shifts saturated reds
   and golds, which fights the colour the artist picked.
7. `diffuse · studio(n, 1) · 0.7`: the 0.7 is an ad hoc ambient occlusion. Fine, but it should become the
   cavity/AO term once one exists.

## 2. Candidate improvements

Format per item: what / state / artist value / visual gain / GPU cost and cache interaction / sketch / effort /
risks / acceptance. "Rect-safe" means the effect is a pure per-pixel function of the mesh shader inputs, so partial
redraw (`render_rect`) and the idle cache (`Static_Cache`) stay valid with no change, provided any new global
setting is folded into `frame_key`/`static_key` (see 2.12).

### 2.1 Colour pipeline: exact sRGB, one tone mapper, exposure — MISSING/INCOMPLETE
- Value: high for everyone; forms read by their darks. Gain: deeper crevices, consistent brightness across materials,
  highlights roll off instead of clipping on Clay/White.
- Cost: ~15 ALU per pixel, zero passes. Rect-safe.
- Sketch (`mesh.frag`): replace the three `pow(1/2.2)` with the piecewise OETF
  (`c <= 0.0031308 ? 12.92c : 1.055 c^(1/2.4) - 0.055`); replace the paint decode in `mesh.vert` with the EOTF.
  Add `vec4 look` to `Material_Uniforms` (or a new `Frame`-level uniform): x exposure in stops (`c *= exp2(ev)`), y
  tone mapper id. Apply the same `tonemap()` to both the classic and PBR paths. Default mapper: **Khronos PBR
  Neutral** (identity below peak 0.76, compresses above, mild desaturation; designed to keep base colours), option
  **AgX** (Wrensch's minimal fit, ~20 lines) for presentation screenshots. Drop the ACES fit. Blender has made AgX
  the successor to Filmic and ships PBR Neutral for colour-accurate product work; Marmoset offers AgX/ACES/Reinhard.
- Effort S. Risk: every dump changes (new baselines), the classic presets' `ambient/spec` may need a retune (small:
  Neutral is identity in the range they live in). Not an sRGB *target format*: the UI pass samples the viewport
  NEAREST into a UNORM swapchain, so an `_SRGB` viewport texture would be decoded to linear and shown too bright
  unless the whole UI moved to `SDR_LINEAR` composition. Do it in the shader.
- Acceptance: `--dump-viewport` + `scripts/ppm.py pixel` on a shadowed crevice: value falls (e.g. 11 → 3); a 0.18
  linear flat-lit grey reads ≈118/255; gpubench unchanged within noise.

### 2.2 Specular/geometric AA, horizon occlusion, key double-count — MISSING
- Value: high at the mesh sizes this product targets. Gain: no sparkle on Chrome/Steel/Gold while orbiting dense
  meshes; fewer fireflies at silhouettes.
- Cost: `dFdx/dFdy` of the normal plus ~10 ALU. Rect-safe.
- Sketch (`mesh.frag`, PBR branch, skip when `surface.z` flat):
  `vec3 dx = dFdx(n), dy = dFdy(n); float var = 0.25*(dot(dx,dx)+dot(dy,dy)); float k = min(2.0*var, 0.18);
  a2 = clamp(a*a + k, 0.0, 1.0);` (Tokuyoshi–Kaplanyan 2021 as implemented in Filament/Unity: pixel kernel
  σ = 0.5 so variance 0.25, clamp 0.18-0.2). Horizon: `float h = min(1.0 + dot(r, n), 1.0); env_spec *= h*h`.
  Then either remove the `direct(KEY)` term from the PBR path or shift the softbox 25-30° from `KEY_DIR`.
- Effort S. Risk: at 10M vertices zoomed out, dense normal variation legitimately roughens chrome (that is the
  point; it is what MSAA cannot fix because shading is one sample per pixel).
- Acceptance: two dumps of Chrome at 10M with the camera nudged 1 px: `ppm.py diff` changed-pixel count drops by
  an order of magnitude; one dump unchanged in flat regions.

### 2.3 Cavity / curvature shading from normal derivatives — MISSING
- Value: very high. ZBrush's own docs say matcaps "respond mainly to cavity information"; Blender's Workbench
  Cavity (Screen type) is what sculptors turn on first. Gain: pores, wrinkles and stroke edges pop; the single
  most visible change for sculpting.
- Cost: ~6 ALU, no pass, no vertex data. Rect-safe (pure per-pixel). The idle cache is view-dependent anyway.
- Sketch (`mesh.frag`): screen-space curvature `float curv = dFdx(n.x) + dFdy(n.y);` (divergence of the
  view-space normal: positive on ridges, negative in valleys), made scale-free by multiplying by the view depth and
  dividing by the pixel footprint (`-in_view_pos.z / proj[1][1] / height` is one more uniform), then
  `albedo *= 1 - valley*smoothstep(0, 1, -curv)`, `albedo += ridge*smoothstep(0, 1, curv)`. Two strengths in the
  `look` uniform, two sliders in the Material section ("Cavity", "Ridge"), script `set cavity 0.6`. Clamp with
  `smoothstep` so sub-pixel triangles do not turn to noise (same caveat as 2.2).
- Effort S. Risk: pixel-scale only (large concavities are the AO's job); on sub-pixel triangles the result is a
  texture-like grain rather than clean lines, acceptable and what ZBrush shows too.
- Acceptance: dump of a sphere with a sculpted groove: pixel probe inside the groove darker than the flank by the
  slider amount; gpubench ≤ +2%.
- What NOT to do first: per-vertex curvature (needs a 1 B/vertex buffer and CPU work in every stroke) or a
  depth-based post pass (needs a second colour texture and the composite plumbing). Both can come later; the
  post-pass variant is the "World" cavity of Blender and belongs with the AO work in 2.9.

### 2.4 MatCap shading — MISSING (no sampler in the mesh pipeline)
- Value: very high; it is *the* ZBrush sculpting look (RedWax, SkinShade, Clay), and Blender Workbench's MatCap mode.
  Gain: baked, painterly lighting with built-in cavity response; reads form better than any analytic rig; and it is
  *cheaper* than the current PBR path.
- Cost: 1-2 texture fetches per pixel from a 512² texture that stays in cache; well under 0.02 ms. Rect-safe:
  the lookup depends only on the view-space normal and view ray.
- Sketch:
  - Textures: embed 4-6 matcaps as PNG (`#load`, decoded with `core:image/png` like the alphas), upload once via a
    transfer buffer + `UploadToGPUTexture` in a copy pass (the pattern in `ui_pass_upload`). Format
    `R8G8B8A8_UNORM_SRGB` if `GPUTextureSupportsFormat` says so (sampling returns linear), else UNORM + EOTF in
    the shader. Create with `num_levels = 10`, usage `{.SAMPLER, .COLOR_TARGET}` and call
    `sdl.GenerateMipmapsForGPUTexture(cmd, tex)` outside any pass, so minification at dense normals is filtered.
    Support ZBrush's two-sphere layout (left diffuse, right specular): `diffuse_sphere * albedo + specular_sphere`
    so polypaint and the mask still show under a matcap (Blender does the same). Single-sphere matcaps use
    `matcap * albedo / 0.5`-style modulation or replace the colour (a per-matcap flag).
  - Pipeline: `num_samplers = 1` on the fragment shader in `create_mesh_pipeline`; GLSL
    `layout(set = 2, binding = 0) uniform sampler2D matcap;`; a LINEAR/mipmapped sampler; bind per item in
    `draw_items` with `BindGPUFragmentSamplers(pass, 0, &b, 1)` (a dummy 1×1 texture when the material is not a
    matcap, as `no_paint` does for the storage buffer).
  - Lookup with the perspective fix (Blender `matcap_uv_compute`): build a basis from the per-pixel view vector `I`
    (`a = 1/(1+I.z); b = -I.x I.y a; b1 = (1 - I.x² a, b, -I.x); b2 = (b, 1 - I.y² a, -I.y); uv = (dot(b1,n),
    dot(b2,n)) * 0.496 + 0.5`, flip x on request). Plain `n.xy*0.5+0.5` slides at the frame edges with a 40° FOV.
  - Material model: `Material` gains `matcap: i8` (index, -1 none) and `matcap_flip: bool`; `Material_Uniforms.
    surface.w` carries the mode. Presets: "Red wax (matcap)", "Clay (matcap)", "Skin (matcap)", "Grey (matcap)".
    Commands: `set material "red wax matcap"`, `set matcap_flip on`.
- Effort M (texture upload path + sampler binding + 4 presets + UI). Risk: per-pixel normal quantisation
  (octahedral snorm16 with 12 bits of normal) shows as faint banding on glossy matcaps; acceptable, it is the same
  data the PBR path uses. The mesh shader's register/sampler count rises slightly: irrelevant on the RTX, check on
  Android.
- Acceptance: dump of the sphere with each matcap preset is deterministic and non-uniform (`ppm.py uniform`); a
  known matcap pixel colour appears at the normal that faces the camera (`ppm.py pixel` at the sphere centre
  equals the matcap centre texel); gpubench orbit/stroke at 10M within +0.05 ms.

### 2.5 Editable and world-locked lights (LightCap-lite) — INCOMPLETE (constants)
- Value: medium-high. Camera-fixed is right as the default (ZBrush, Blender Studio lights), but artists need to
  move the key to check a form, and world-locked light is how you judge a turntable.
- Cost: none. Rect-safe if the light vector is hashed in the frame keys (2.12).
- Sketch: `KEY_DIR/FILL_DIR` become `vec4 lights[4]` (view-space dir, intensity) + `vec4 light_colors[4]` in a
  new `Lights_Uniforms` (fragment set 3, binding 1; `num_uniform_buffers = 2`). World lock: the app multiplies
  world directions by `mat3(view)` before pushing, so the shader never changes. `studio.odin` reads
  `STUDIO_KEY_DIR` today; take it from the same struct so the shadow follows the key. UI: in the Studio section,
  two sliders (azimuth, elevation) per light plus colour and strength, or later a draggable dot on a sphere as
  ZBrush's LightCap Designer does (aperture/falloff/opacity per light, diffuse vs specular channel). Commands
  `set light_key 35 50`, `set lights_world on`.
- Later (optional): **bake the lights to a matcap** in a 512² offscreen pass whenever edited: that is exactly
  ZBrush's LightCap → MatCap workflow, and makes editable lights cost one fetch in the mesh shader.
- Effort S (uniforms + 4 sliders), M with the sphere widget. Risk: none technical.
- Acceptance: `set light_key` changes the dump; `set lights_world on` + orbit: the lit side stays fixed in world
  across two dumps with the camera turned.

### 2.6 Anti-aliasing — MISSING
Options weighed for a partial-redraw viewport:
- **TAA: no.** Needs jitter and history; breaks deterministic dumps, ghosts on strokes, fights `render_rect`.
- **FXAA: no.** Blurs exactly the fine stroke detail a sculptor is looking at; ZBrush's viewport has no AA while
  sculpting and nobody asks for FXAA there. SMAA is better but is 3 passes + lookup textures for an edge-only gain.
- **SSAA 2×: possible but 4× fill and memory**; MSAA gives better edges for less.
- **MSAA 4× (fallback 2×, then off): yes.** Silhouettes and the wireframe lines (which gain most) are what alias;
  shading aliasing is handled by 2.2.
- SDL rules verified in `SDL_gpu.c`: an MSAA texture may not have `SAMPLER` usage, `num_levels` must be 1, the
  resolve texture must be 1-sample, same format, `COLOR_TARGET`; **depth cannot be resolved**;
  `GPUTextureSupportsSampleCount(device, format, ._4)` must be checked for colour *and* depth formats.
- Sketch (`renderer.odin`): `Viewport_Target` gains `msaa_color`, `msaa_depth` (`sample_count = ._4`, usage
  `{.COLOR_TARGET}` / `{.DEPTH_STENCIL_TARGET}`); `vt.color` stays the 1-sample, sampled texture and becomes the
  resolve target (`store_op = .RESOLVE`, `resolve_texture = vt.color`); `vt.depth` MSAA. `multisample_state =
  {sample_count = ._4}` on the mesh, wire and clear pipelines. Partial redraw: `LOAD` the MSAA colour and depth,
  draw the rect, `RESOLVE` (the resolve is always full-frame; there is no partial resolve). Idle cache: cache
  textures become MSAA and `CopyGPUTextureToTexture` copies MSAA→MSAA (Vulkan `vkCmdCopyImage` allows equal
  sample counts; verify under validation in `smoke`; if refused, the cache redraws into the MSAA target instead of
  copying). Studio render: it samples `vt.depth`, which is now MSAA; give it a 1-sample depth by running the
  existing `shadow_pipeline` (depth-only, `Shadow_Uniforms{view_proj, model}`) with the camera matrices into a
  viewport-sized 1-sample depth texture when a studio accumulation (re)starts; it only restarts when idle, so the
  stroke path never pays. `viewport_download` reads the resolved `vt.color` unchanged.
- Cost at 1920×1080 4×: MSAA colour LOAD+RESOLVE ≈ 75 MB, depth LOAD+STORE ≈ 66 MB per frame ≈ 0.25-0.35 ms on
  a 3060 Ti; the 10M stroke would go from 0.41 to roughly 0.7 ms. Memory +130 MB with the cache. At 4K choose 2×.
  Tiled Android GPUs pay for the LOAD; default 2× or off there.
- Effort M/L; the riskiest essential item. Risks: SDL asserts on usage combinations (run `smoke` under
  validation), the MSAA cache copy, `--dump-viewport` baselines all change.
- Acceptance: silhouette pixels in a dump take intermediate values (probe a sphere edge); gpubench stroke 10M
  ≤ 0.75 ms and orbit ≤ 0.9 ms at 1080p; `gate.py smoke` clean; toggling `set msaa off` restores the old dumps
  bit-exactly.

### 2.7 Per-object materials — MISSING
- Value: high for scenes (gold armour on a skin body), medium for pure sculpting. Gain: presentable multi-object
  scenes; the Objects card can show a material swatch.
- Cost: none; `Draw_Item` already carries `color/material/surface` per item and both key hashes include them.
- Sketch (app-side only): `Object` gains `material: Material` (or preset index + custom), saved in the `.sculpt`
  scene with a version bump and defaulting to the global one on old files; `main.odin:712-724` reads
  `obj.material` instead of `current_material(&app)`; the Material section edits the selection and gets "Apply to
  all"; `set material` applies to the selection. Keep the selection cue but reconsider the grey `idle` override:
  ZBrush shows every subtool in its own material and marks the active one by its frame; a thin accent rim on the
  selected object (one `pow(1-n·v, k)` term tinted by a uniform) does the same without hiding the others' materials.
- Effort S/M. Risk: scene format compatibility (versioned already), ghost shading interplay.
- Acceptance: two objects with Gold and Skin render both materials in one dump; save/load round trip keeps them.

### 2.8 HDRI / image-based lighting — MISSING
- Value: medium for sculpting, high for presentation and metals. ZBrush itself does not use HDRIs interactively
  (LightCap can *analyse* a background image into lights); Marmoset is HDRI-first (sky, rotation, brightness,
  child lights picked from the sky image, blurred-sky backdrop).
- Cost per frame: one `textureLod` on a cube + 9-coefficient SH ≈ what the analytic `studio()` costs now.
  Rect-safe (reflection vector → world via a `mat3` uniform; camera is fixed during a stroke).
- Sketch: a Radiance `.hdr` (RGBE, RLE) reader (~120 lines of Odin; `core:image` has none); equirect → cube
  (`type = .CUBE, layer_count_or_depth = 6, num_levels = 6-8, usage {.SAMPLER, .COLOR_TARGET}`, render each face
  with `layer_or_depth_plane = face`, `mip_level = m`); GGX prefilter per mip in a fragment shader (32-64
  importance samples with mip-filtered lookups to kill fireflies), `lod = perceptual_roughness * (levels-1)`
  as Filament does; SH9 irradiance computed on the CPU from a 64×32 downsample and pushed as 7 vec4; keep Karis's
  fit for the DFG term. Background: sample the blurred mip along the view ray in `clear.frag`. Env rotation slider.
- Effort L. Risks: file dialogs and asset management for user HDRIs; EXR is out of scope (do not write an EXR
  reader). Do this only after 2.4 ships; a coloured 3-lobe procedural environment (see 1.3) gets 70% of the look
  at zero effort and should be tried first.
- Acceptance: a chrome sphere dump shows the environment's colours mirrored; rotating the env rotates them; gpubench
  within +0.05 ms.

### 2.9 Interactive ambient occlusion (GTAO/HBAO) — MISSING; Studio render exists
- Value: medium; the progressive Studio AO already gives the BPR-like result when idle, which is also how ZBrush
  works (BPR is a separate render; Preview has no AO).
- Cost: GTAO at full 1080p ≈ 0.5-1 ms (more than the whole frame today); half-res ≈ 0.3 ms plus a composite into
  a second colour texture (the `shown` scheme of `studio.odin`); needs the 1-sample depth of 2.6. With partial
  redraw: AO and composite over the damage rect expanded by the sample radius; no temporal filter (determinism).
- Recommendation: not now. Cheaper first: make the Studio restart *incrementally* (zero `accum` only in the
  expanded damage rect) and show the first samples sooner. Effort L. Risks: noise, halos, stroke-time cost.

### 2.10 Background, floor grid, ground shadow — INCOMPLETE
- Value: medium (orientation cues; a less "void" presentation). ZBrush: gradient document plus Draw > Floor grid.
- Sketch: `clear.frag` already covers rect clears; make it draw a vertical gradient from two colours in the uniform
  using `gl_FragCoord/size`, and use the same pipeline for the full clear so rect and full agree (rect-safe by
  construction). Floor grid: an analytic plane in a full-screen triangle drawn after the meshes with depth test
  and `gl_FragDepth` from the ray-plane hit, `fwidth` anti-aliased lines; toggle `set floor on`. A contact shadow
  needs the Studio's shadow map; leave it to the Studio render (shadow catcher later with 2.8).
- Effort S (gradient), S/M (grid). Risk: the grid must be excluded from the depth the Studio reads or it will
  receive AO (acceptable, Blender does the same).

### 2.11 Diagnostic views — MISSING
- Low artist value, useful for development: a `look.z` mode in `mesh.frag` showing view-space normals, curvature
  (2.3), depth or mask. Effort S. Rect-safe.

### 2.12 One hash for every global look setting (prerequisite for all of the above)
`frame_key` and `static_key` hash the camera, size and each item's colour/material/surface/flags. Lights, tone
mapper, exposure, cavity strengths, matcap index, background and MSAA mode are new global inputs: add a `look: u64`
(hash of a `Look` struct kept in the app) to `render_viewport` and to both `Header` structs. One line keeps partial
redraw and the idle cache correct for everything in this document.

## 3. Prioritised plan

Essential, in order (each independently shippable, each verifiable by dumps and gpubench):
1. **Colour pipeline** (2.1): exact sRGB both ways, PBR Neutral default + AgX option on *both* shading paths,
   exposure, and 2.12's `look` hash. S. Zero GPU cost. New dump baselines.
2. **Shading correctness in mesh.frag** (2.2 + 1.2-1.4): specular AA, horizon occlusion, no double key, a coloured
   asymmetric 3-lobe environment. S. Zero cost.
3. **Cavity from normal derivatives** (2.3) with Cavity/Ridge sliders. S. The biggest visible gain per line.
4. **MatCap** (2.4): texture upload path, sampler in the mesh pipeline, two-sphere matcaps that keep polypaint,
   perspective-correct lookup, 4-6 embedded presets. M. This is the ZBrush look.
5. **MSAA 4×/2×** (2.6) with the studio depth pre-pass. M/L. Budget: 10M stroke ≤ 0.75 ms at 1080p.

Optional, after:
6. Editable + world-locked lights (2.5), S; then the LightCap-style sphere widget and "bake lights to matcap", M.
7. Per-object materials saved in the scene (2.7), S/M.
8. Background gradient and floor grid (2.10), S.
9. HDRI IBL with `.hdr` reader, cube prefilter, SH9 (2.8), L.
10. HDR intermediate target (`B10G11R11_UFLOAT`, same bytes as RGBA8) + a final display pass: only when a post
    pass (AO composite, bloom) needs linear input; the Studio composite multiplies display-encoded colour today,
    which is wrong but tolerable.
11. Half-res GTAO when idle, incremental Studio restarts (2.9), L.
12. Diagnostic views (2.11), S.

Do NOT do: TAA or FXAA; a G-buffer/deferred rewrite; per-frame shadow maps at 10M (a second geometry pass doubles
the stroke cost; the Studio has shadows); per-vertex curvature or tangents in the vertex format (memory at 50M);
an `_SRGB` viewport texture or `SDR_LINEAR` swapchain (every UI colour would need converting); EXR or MaterialX;
screen-space reflections; HDR display output. Do not tune any of this on llvmpipe alone: items 2-5 must be judged on
Bolt's RTX with `--gpubench` at 500k, 2M, 10M and with `--dump-viewport` pairs diffed by `scripts/ppm.py`.

## 4. Verification recipe
- `--run look.txt --frames 60 --dump-viewport build/x.ppm` (script verbs such as `set material chrome`, `set cavity
  0.6`, `set msaa 4`), then `scripts/ppm.py diff|pixel|uniform`; same flags must still give a 0-pixel diff.
- `--gpubench` Orbit and Stroke rows at 500k/2M/10M before and after each step, against the budgets above.
- `scripts/gate.py smoke` (300 frames under GPU validation) after every SDL_GPU object change.

## 5. Sources
Reached:
- ZBrush LightCap: https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/lights/lightcap/lightcap.html
- ZBrush rendering modes: https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/rendering/rendering.html
- ZBrush BPR and SPix (via search): https://help.maxon.net/zbr/en-us/Content/html/user-guide/materials-lights-rendering/rendering/bpr/bpr.html , https://help.maxon.net/zbr/en-us/Content/html/reference-guide/render/bpr-renderpass/bpr-renderpass.html
- Marmoset Toolbag rendering: https://marmoset.co/toolbag/rendering/ ; lighting: https://docs.marmoset.co/docs/lighting/
- Filament PBR (BRDF, IBL, SH, specular occlusion, horizon): https://google.github.io/filament/main/filament.html
- Blender colour management (4.2 manual; the "latest" URL 404'd): https://docs.blender.org/manual/en/4.2/render/color_management.html
- Blender Workbench viewport shading (Studio/MatCap, World Space Lighting, Cavity, Shadow): https://docs.blender.org/manual/en/latest/editors/3dview/display/shading.html
- Khronos ToneMapping repo (PBR Neutral; the README fetch 404'd, algorithm quoted from the reference GLSL): https://github.com/KhronosGroup/ToneMapping
- Tokuyoshi & Kaplanyan 2021 (page text unavailable; constants from the Unity HDRP/Filament implementations found by search): https://www.jcgt.org/published/0010/02/02/ , https://developer.download.nvidia.com/gameworks/events/GDC2016/akaplanyan_specular_aa.pdf
- GTAO (Jimenez et al. 2016; PDF timed out, abstract via https://research.activision.com/publications/archives/practical-real-time-strategies-for-accurate-indirect-occlusion ; implementation https://github.com/GameTechDev/XeGTAO )
- AgX lineage (Sobotka; Wrensch minimal fit): https://enkisoftware.itch.io/avoyd/devlog/732953/avoyd-022-beta-agx-tonemapping
- SDL 3.4.18 `SDL_gpu.h` and `src/gpu/SDL_gpu.c` in `deps/sdl3-src` (MSAA, resolve, cube, mipmap rules).
Not readable (binary PDF through the fetch tool; summarised from prior knowledge, verify before quoting):
- Disney BRDF notes: https://disneyanimation.com/publications/physically-based-shading-at-disney/
- Karis, Real Shading in UE4: https://cdn2.unrealengine.com/Resources/files/2013SiggraphPresentationsNotes-26915738.pdf
