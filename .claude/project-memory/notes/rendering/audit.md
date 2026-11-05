# Rendering, shading and PBR audit (2026-10-27)

Source of truth: github.com/Cuzmix/Implicit_sculpt_modeler branch `odin-sculpt` (commit at audit time: see thread).
Stack: Odin dev-2026-10, SDL 3.4.18 (built from source), SDL_GPU with SPIR-V only (`renderer_init` creates the
device with `{.SPIRV}`), GLSL compiled by glslangValidator to committed `.spv`, embedded with `#load`.
**No SDL_shadercross** in the build. No shader hot reload (shaders are compiled at build time and embedded).
Windows target is Vulkan (RTX 3060 Ti); D3D12/Metal would need shadercross or DXIL/MSL. Android is Vulkan too.

Classification key: WORKING = implemented, used, tested at least by smoke/dumps on llvmpipe; INCOMPLETE = exists but
limited; MISSING; UNKNOWN. "Verified" below means seen in code and, where noted, in a Linux software-GPU dump.
Nothing in this area has been tried on Bolt's real GPU except gpubench timings (see baseline).

## Pipeline and render targets
| Feature | State | Where | Notes |
|---|---|---|---|
| Offscreen viewport target | WORKING | `src/render/renderer.odin:19` `VIEWPORT_COLOR_FORMAT = R8G8B8A8_UNORM`, depth D32F (else D24) | The interface samples it NEAREST, 1:1 into the swapchain (`ui_pass.odin:80`). |
| HDR intermediate / linear buffer | MISSING | – | The mesh shader tone maps (PBR only) and gamma encodes with `pow(c, 1/2.2)` itself, writing display values into UNORM. No exposure control. Classic path does no tone mapping (clips). |
| sRGB handling | INCOMPLETE | `mesh.frag` end, `mesh.vert` paint decode `pow(.,2.2)` | Approximate 2.2 gamma, not the sRGB curve; no sRGB texture formats used; swapchain is SDR composition. Colour pickers' values are fed as linear. |
| Anti-aliasing | MISSING | pipelines have default sample count 1 | No MSAA, FXAA, SMAA or TAA. Silhouettes and wireframe lines alias; specular aliasing on dense meshes. SDL_GPU 3.4 supports MSAA 2/4/8 with resolve, and `SDL_GPUTextureSupportsSampleCount`. |
| Partial redraw (damage rect), idle-object cache, LOD while moving, per-chunk indirect draws, culling | WORKING | `renderer.odin` `render_viewport`, `render_rect`, `Static_Cache` | These are the reason 10M strokes are ~0.4 ms GPU on the RTX. ANY new pass must keep partial redraw and the idle cache valid (screen-space effects re-run on a rect, or are skipped mid-stroke). |
| Vertex format | WORKING | 16 bytes: float3 position + octahedral snorm16x2 normal with 4+4 mask bits; paint/groups in an optional storage buffer (8 B/vertex) | No UVs, tangents or per-vertex material IDs on the GPU. Adding attributes costs memory at 10-50M vertices. |
| Uniforms | WORKING | `Frame_Uniforms{view_proj, view, model, options}`, `Material_Uniforms{base_color, params, surface, checker}` pushed per draw | Room to add more vec4s cheaply. |
| Shader compile | WORKING | `build.sh` runs glslangValidator on every `.vert/.frag/.comp`; `build.bat` only if on PATH | No hot reload, no shadercross, no reflection. |

## Shading and lighting
| Feature | State | Where | Notes |
|---|---|---|---|
| Classic clay shading | WORKING | `mesh.frag` bottom: wrap-Lambert key + fill fixed to the camera, Blinn-Phong spec, rim `pow(1-n.v,3)*0.25` | Presets Clay, Red wax, White, Grey, Skin (`src/app/material.odin`). Lights are camera-fixed (good for sculpting, like ZBrush default). |
| PBR (metal/rough) | INCOMPLETE | `mesh.frag` `direct()`, `studio()`, `env_brdf()` | GGX + height-correlated Smith (fast fit) + Schlick, 2 camera-fixed lights, a *procedural* analytic studio environment blurred by roughness (no real HDRI, no prefiltered maps, no irradiance SH), Karis env BRDF fit, Narkowicz ACES, gamma 2.2. Presets Gold, Copper, Chrome, Steel, Plastic, Ceramic, Rubber, PBR clay + one Custom (colour, metallic, roughness). Tuned only on llvmpipe. No specular AA, no multiscatter compensation, no clearcoat/sheen/SSS/transmission. |
| MatCap | MISSING | – | ZBrush's main sculpting look. No texture sampling exists in the mesh pipeline at all (no samplers bound). |
| HDRI environment lighting | MISSING | – | No image-based lighting, no .hdr/.exr loader (`core:image` has png/jpeg/bmp/tga/qoi only), no cubemaps, no environment rotation. |
| Lights | INCOMPLETE | constants `KEY_DIR`, `FILL_DIR` in `mesh.frag` | Not editable; no LightCap-like editor; lights rotate with the camera (no world-locked option). |
| Per-object material | MISSING | `app.material` is ONE global index; `main.odin:715` selected object gets `material.selected`, others `material.idle` grey | A gold armour piece next to a skin body is impossible; material is not saved in the .sculpt scene (only in settings.txt as a preference). |
| Cavity / curvature shading | MISSING (as shading) | Mask by cavity exists (`src/sculpt/mask.odin:454` `mask_cavity`) | No screen-space or vertex curvature/cavity tint in the viewport. |
| Ambient occlusion (interactive) | MISSING | – | Only in Studio render (below). |
| Studio render (Shift+R) | WORKING | `src/render/studio.odin`, `studio_gather.frag`, `studio_composite.frag` | Progressive: one shadow-map light sample per still frame into RGBA16F accum; AO from directions all round + soft key shadow; composites by *darkening* the viewport image (multiplicative), so no GI, no reflections of other objects, no PBR-consistent lighting. Restarts on any change. 256 samples default, max 1024. Normals reconstructed from depth. |
| Shadows (interactive) | MISSING | shadow map only in Studio render | |
| Reflections between objects | MISSING | – | |
| Flat shading (Shift+G) | WORKING | `dFdx/dFdy` face normal | |
| Wireframe (Shift+F) | WORKING | `.LINE` fill second pass, depth bias | Aliased, one fixed colour, selected object only. |
| Mask display, polypaint, polygroups (Shift+W), density checker | WORKING | `mesh.vert`/`mesh.frag` | |
| Background | INCOMPLETE | flat `BACKGROUND {0.17,0.17,0.17}` (`renderer.odin:45`) | No gradient, no env background, no ground plane/grid/shadow catcher. |
| Diagnostics views (normals, UV, curvature, overdraw) | MISSING | – | Stats panel has frame/CPU/GPU timings. |
| Ghost objects | WORKING | colour darkened by `GHOST_SHADE` (not transparent) | |

## Materials, textures, baking
| Feature | State | Where | Notes |
|---|---|---|---|
| Material data model | INCOMPLETE | `Material{label, selected, idle, shading[4], metallic, roughness}` in `src/app/material.odin` | Viewport-only, global, no textures, no names per object, not exported. |
| Vertex colour (polypaint) | WORKING | `src/sculpt/paint.odin`, storage buffer, saved per level, exported to PLY/OBJ/glTF COLOR_0/USD displayColor | sRGB bytes + coverage. No roughness/metal paint channels. |
| Polygroups | WORKING | per-triangle group via flat attribute | Could drive material assignment. |
| Image loading | WORKING (for alphas) | `src/app/alphas.odin` via `core:image` png/jpeg/bmp/tga/qoi → greyscale CPU alpha | No GPU texture upload path for colour images; no mip generation used; no texture cache/asset manager. `SDL_GenerateMipmapsForGPUTexture` exists in SDL. |
| UVs | INCOMPLETE | `src/geom/uv_unwrap.odin` planar charts for retopo quads only; OBJ import UVs? (dropped) | Only the retopo quad object has UVs, CPU side only, never on the GPU. |
| Baking | INCOMPLETE | `src/geom/bake.odin` + `src/app/retopo.odin` | High→low (sculpt top level → retopo quads) tangent-space normal PNG (OpenGL, Mikk-like not exact), 16-bit displacement PNG; 3.7 s for 2048 from 10M (CPU, BVH ray both ways). No AO, curvature, thickness, position, ID, colour (polypaint) bakes; no cage; no preview of the baked maps on the low mesh. |
| Texture painting | MISSING | – | |
| Export materials | INCOMPLETE | glTF `.glb` (`src/geom/gltf_write.odin`) and USD `.usda` write mesh, normals, COLOR_0/displayColor, shape keys | No `materials` / pbrMetallicRoughness / textures in glTF; no UsdPreviewSurface. |
| MaterialX / OpenPBR | MISSING | – | |

## Advanced rendering and compute
| Feature | State | Where | Notes |
|---|---|---|---|
| Compute shaders | WORKING (trial) | `src/render/smooth_compute.odin`, `smooth_all.comp` | Proves SDL_GPU compute + storage buffers work here; bit-identical on llvmpipe; RTX timing pending. |
| CPU BVH | WORKING | `src/geom/bvh.odin` (Morton BVH, raycast), used by picking, bake, project | Per-object, rebuilt/refit by the sculptor's nodes. Could be flattened to a GPU buffer. |
| Hardware ray tracing | MISSING / not exposed | SDL_GPU 3.4 has no acceleration structures or ray queries | A hardware RT path would need a native Vulkan side path. |
| Path tracing | MISSING | – | |

## Camera, UI, tests, profiling
- Camera: orbit (ZBrush-like), perspective fov 40°, near 0.01, far 100 fixed; ortho (P). `src/camera/camera.odin`.
- UI: own kit (`src/ui`, `src/app/kit_*.odin`). Material and Studio render sections live in the Scene palette
  (`kit_scene.odin:411-475`: material select, colour, Metallic, Roughness sliders; Studio Occlusion/Shadow/Samples).
  View toggles are registry commands (`commands.odin:985-1010`: Wireframe, Flat shading, Studio render).
  Every new control must be a command in the registry, with a script verb (`set material steel`, `studio_render on`).
- Tests: `odin test` packages (render has none), `smoke` 300 frames under GPU validation, `--dump-viewport` PPM →
  `scripts/ppm.py` diff/crop/pixel (renders are deterministic: same flags → 0 pixel diff), `scripts/gate.py` whole gate.
- Profiling: `--time-gpu`, Stats panel, `gpubench` (orbit + stroke cases at 500k-10M, writes build/gpubench.md).
- Undo/geometry updates: rendering only consumes dirty vertex ranges and damage boxes; never owns geometry.

## Baseline
See section "Baseline measurements" appended below (Linux container, llvmpipe software Vulkan: GPU timings are
meaningless; CPU timings are VM numbers). Bolt's RTX 3060 Ti gpubench (2026-10-24): 10M orbit 0.54 ms GPU, stroke
0.41 ms GPU, stroke CPU 1.4 ms; < 1 ms GPU at every size with all toggles on.

## Baseline measurements (2026-10-27, commit de6bb70)
Machine: cloud VM, 4 vCPU Intel Xeon 2.1 GHz, Xvfb + Mesa llvmpipe (software Vulkan). GPU numbers and frame times
here are dominated by the software rasteriser and are NOT meaningful for real GPUs; only the CPU brush/normal/upload
columns are. Release build, 1600x900 viewport, --no-vsync, 120-frame synthetic stroke (--bench-stroke=120).

| Mesh | frame p50/p99 ms (llvmpipe) | brush ms p50 | normals ms p50 | upload KB/frame p50 |
|---|---|---|---|---|
| sphere 1M | 33.8 / 156 | 0.13 | 0.09 | 190 |
| sphere 5M | 64.9 / 776 | 0.28 | 0.26 | 577 |

Real GPU reference (Bolt, RTX 3060 Ti, Vulkan, 2026-10-24 gpubench): 10M orbit 0.54 ms GPU, stroke 0.41 ms GPU,
CPU 1.4 ms p50.

Visual baseline (notes/rendering/baseline/): organic = `new_scene head` at 1M; hard surface = cube 600k with a
subtracted cylinder and a torus. Findings from the dumps:
- grid.png (Gold, Chrome, PBR clay, Skin, Studio render on Clay, sphere-with-insert): Chrome shows the procedural
  environment as a hard sky/floor split, so the lower half of a chrome head reads as flat black; PBR clay is low
  contrast and washed out compared with classic Clay; Studio render adds convincing contact AO/shadow under the ears.
- hard_grid.png (Clay vs Steel on the hard-surface scene): with camera-locked lights a flat face has one uniform
  value; Steel's front face is near-black (it reflects the dark floor) and the top a flat grey, so metal hard
  surface reads poorly; no contact shading where the torus meets the cube.
- edge_crop.png (6x crop of the head's silhouette): hard 1-pixel stair-stepping; there is no anti-aliasing.
