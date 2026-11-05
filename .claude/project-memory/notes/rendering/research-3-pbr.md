# Research 3: PBR materials, texturing and baking (2026-10-27)

Scope: materials, colour space, polypaint, UVs, baking, texture preview and material export for the
Odin/SDL_GPU sculpt app. Verified against branch `odin-sculpt` at de6bb70 and `notes/rendering/audit.md`.
Classification: **improvement** (fixes existing), **extension** (grows an existing system), **new**
(new capability), **experiment** (optional). Code paths are under `src/`.

## 1. Audit of what exists (verified in code)

| Area | State | Where | What is actually there |
|---|---|---|---|
| Material model | INCOMPLETE | `app/material.odin`, `render/renderer.odin:142-199` | `Material{label, selected, idle, shading[4], metallic, roughness}`; 13 presets + `app.custom`; ONE global index `app.material`; the selected object gets `selected`, others `idle` grey (`app/main.odin:714-723`); per draw `Material_Uniforms{base_color, params, surface, checker}` (4 vec4, room to grow). Saved only in settings.txt (`material`, `custom_material`), never in the scene. The classic fields (`shading` = ambient, spec, power, wrap) are a viewport *look*, not a material property. |
| Shading | INCOMPLETE | `shaders/mesh.frag` | GGX + height-correlated Smith (fast fit) + Schlick, F0 = mix(0.04, albedo, metallic), two camera-fixed lights, analytic `studio()` env blurred by roughness, Karis env-BRDF, Narkowicz ACES, `pow(1/2.2)`. No specular/AO/emissive/clearcoat inputs, no texture bound (no samplers in the mesh pipeline; samplers exist in `studio.odin`, `thumbs.odin`, `ui_pass.odin`). |
| Colour space | INCOMPLETE and INCONSISTENT | `app/kit_widgets.odin:72`, `app/paint.odin:14`, `mesh.vert:53`, `geom/gltf_write.odin:279` | One widget `kit_color` (three linear 0-1 sliders, swatch drawn as a UI colour) feeds both the material colour (used **as linear** in the shader) and the brush colour (quantised to **sRGB bytes** by `brush_color_bytes`). The same slider value therefore shows two brightnesses. Polypaint bytes are sRGB, decoded in the vertex shader with `pow(2.2)` (interpolated linear: correct); exports use the exact piecewise curve (`srgb_to_linear`); the display encode is `pow(1/2.2)`. Three different transfer functions in one path. |
| Polypaint | WORKING | `sculpt/paint.odin`, `render/renderer.odin:622` | RGBA8 sRGB + coverage per vertex per level, 4 B/vertex CPU; GPU `Paint_Packed [2]u32` (8 B/vertex: colour, group in low 16 bits; **high 16 bits of `.y` unused**). Undo per stroke, carried across levels. Exported as paint composited over *white* by coverage (PLY/OBJ sRGB bytes; glTF `COLOR_0` VEC4 u16 normalized linear; USD `displayColor` linear). |
| Polygroups | WORKING | `sculpt/groups.odin` | u16 per triangle + per-vertex carrier for the flat GPU output; saved; USD `primvars:polygroup` (quads only). Ready to drive material slots and ID bakes. |
| UVs | INCOMPLETE | `geom/uv_unwrap.odin`, `sculpt/levels_quads.odin`, `sculpt/levels_file.odin:182` | Per quad corner `[4][2]f32` + chart id, planar charts (55 deg), row packing, 8/4096 padding; only for the retopo object's base level; saved (scene v4); exported in OBJ `vt` and USD `primvars:st` (faceVarying), not glTF. OBJ import drops `vt` (`geom/mesh_file.odin:51`) and `mesh_clean` welds seam vertices, so imported UVs cannot survive today. Never on the GPU. |
| Baking | INCOMPLETE | `geom/bake.odin`, `app/retopo.odin:122` | CPU, texel-centre rasterisation of the UV charts, one ray out and one in along the smooth low normal (`reach` in average edge lengths; starts 1e-3 behind), nearest hit wins; tangent-space normal (OpenGL +Y) from per-vertex-per-chart tangent sums (triangle-area weighted, **not** MikkTSpace's angle weighting or vertex grouping), 16-bit displacement normalised to `max_displacement` (scale in a .txt), 8-texel averaging dilation, no supersampling, no cage. Test `retopo_test.odin:98`. |
| Images | WORKING (alphas) | `app/alphas.odin` | `core:image` png/jpeg/bmp/tga/qoi, 8/16-bit, to greyscale only. `png_write` writes RGBA8 and 16-bit grey. No HDR/EXR, no GPU colour texture upload path, no mip generation. |
| Export | INCOMPLETE | `geom/gltf_write.odin`, `geom/usd_write.odin`, `app/files.odin:400-470` | glTF: one mesh, POSITION/NORMAL/COLOR_0, sparse morph targets, no `materials`, no TEXCOORD. USD: quads, st, displayColor, polygroups, blend shapes, no `Material`. Checked by `scripts/export_check.py` (gltf-validator, UsdValidation, Blender bpy import). |
| MaterialX / OpenPBR | MISSING | - | - |

### Corrections to audit.md (report only; the file is unchanged)
1. "Colour pickers' values are fed as linear": only the **material** colour is; the **brush** colour is fed as sRGB (`brush_color_bytes`). The real defect is that one widget means two things.
2. "Vertex colour ... saved per level": colours exist per level in memory, but `levels_write` saves only the **current** level's colours and groups (scene v3 comment, README "for the current level"); other levels are rebuilt by `levels_carry_color` on load/level change.
3. "No GPU texture upload path": there are textures and samplers (studio accumulation, thumbnail atlas, UI atlas) and a 16 MB cycled transfer buffer; what is missing is a *mesh-pipeline* texture binding and mip generation, not GPU texture code as such.
4. Baking row: add that the displacement scale is per bake (not a fixed mid/alpha depth as ZBrush's), that there is no supersampling, and that dilation averages normals (wrong for ID maps).
5. Polygroups row: group ids are u16 (65535 groups), per triangle, with a per-vertex carrier; the USD export writes them only for quad bases.
6. Export row: `COLOR_0` is written as 16-bit normalized linear with alpha 65535, composited over white, from the *current* level only.

## 2. Missing or incomplete capabilities, ranked by value for the sculpt workflow

1. **Consistent colour space** (improvement, high, small): one definition of what a colour value means in state, UI, shader, file and export. Blocks every PBR feature: polypaint-to-texture bakes would otherwise not match the viewport.
2. **Per-object material, saved in the scene** (extension of `Material`, `Draw_Item`, `files.odin`): gold armour next to skin; prerequisite for any material export. Default stays the global look, so nothing changes for existing scenes.
3. **Material export** (extension of `gltf_write`/`usd_write`): glTF `materials[]` with `pbrMetallicRoughness`, UsdPreviewSurface. Even without textures, Blender/Marmoset/engines then show the object as the viewport did.
4. **More bake maps from the existing ray bake** (extension of `bake.odin`): base colour from polypaint, ID from polygroups, AO, curvature, thickness, position/object normals; supersampling; a correct MikkTSpace frame. This is the ZBrush Multi Map Exporter / Marmoset map list, and the product's natural texturing path (paint on the sculpt, bake to the low mesh).
5. **glTF with UVs and textures** (extension): TEXCOORD_0 for the retopo base (split at UV seams), textures embedded in the GLB (PNG via `png_write`), `metallicRoughnessTexture` as ORM-packed, `normalTexture`, `occlusionTexture`. The one-click "to Blender/engine" export.
6. **Per-polygroup material slots** (extension of groups + uniforms): a slot table per object indexed by the group already in the paint buffer; exports as glTF primitives / USD GeomSubsets. Mecha and hard-surface need it; cheap given polygroups.
7. **Textured preview of baked maps on the low mesh** (new, mid): a small textured pipeline for retopo objects only, with mipmaps and anisotropic filtering, UV checker view. Closes the bake loop without leaving the app.
8. **Polypaint roughness/metallic channels** (extension, zero extra GPU memory: the free 16 bits of `Paint_Packed.y`): ZBrush has none; 3D-Coat and Substance paint them. Bakes to ORM. Mid value for stylised/mecha work.
9. **Triplanar material previews** (new, mid-low): tiled detail textures by `in_mesh_pos` + normal, no UVs. Concept-art lookdev on the sculpt.
10. **Specular/clearcoat/emissive parameters** (extension, low-mid): needed for car paint, lacquer, glowing parts; each maps 1:1 to glTF KHR extensions and OpenPBR.
11. **Texture import onto the low mesh** (new, low-mid): load Substance/Painter output for lookdev. Reuses the preview pipeline.
12. **MaterialX/OpenPBR file export, UDIM/texture sets, displacement preview, texture painting, polypaint layers** (experiment / out of scope; see sections 6-7).

## 3. Recommended next texturing milestone: "Bake set and materials out"

Deliver, in this order: colour-space fix -> per-object material saved (scene v12) -> glTF/USD materials -> bake set
(base colour, ID, AO, curvature, thickness, position, normal with exact MikkTSpace, 4x supersampling) -> GLB with
TEXCOORD_0 and embedded textures (base colour sRGB, ORM, normal). Each step ships on its own and reuses existing
code (`bake_maps`, `Uv_Layout`, `png_write`, `Mesh_Export`, `export_check.py`). This is the milestone with the best
value/risk: no new GPU buffer layout, no shader beyond a few uniform fields, and the result is checkable in Blender.
The textured preview (section 2 item 7) is the milestone after it.

## 4. Material parameter set that survives a path tracer, glTF and OpenPBR

Keep the data model glTF-shaped and OpenPBR-named; **do not adopt MaterialX/OpenPBR as the internal model** (slabs,
transmission, subsurface, fuzz, thin film are far beyond a sculpt viewport and would force every system to carry
them). Map on export; every field below maps without loss.

```
Surface :: struct {          // linear, physically meaningful, per object (later per slot)
    base_color: [3]f32,      // glTF baseColorFactor, OpenPBR base_color, Usd diffuseColor
    metallic:   f32,         // metallicFactor, base_metalness, metallic
    roughness:  f32,         // roughnessFactor (GGX alpha = r*r), specular_roughness, roughness
    specular:   f32 = 1,     // KHR_materials_specular specularFactor, OpenPBR specular_weight (F0 = 0.04*specular for dielectrics)
    emissive:   [3]f32,      // emissiveFactor; OpenPBR emission_color (with emission_luminance), Usd emissiveColor
    emissive_strength: f32 = 1, // KHR_materials_emissive_strength
    coat:       f32,         // KHR_materials_clearcoat clearcoatFactor, coat_weight, Usd clearcoat
    coat_roughness: f32 = 0.03, // clearcoatRoughnessFactor, coat_roughness, clearcoatRoughness
    occlusion_strength: f32 = 1, // occlusionTexture.strength
    normal_scale: f32 = 1,   // normalTexture.scale
    textures:   [Texture_Slot]Texture_Ref, // base_color (sRGB), orm (linear), normal (linear), emissive (sRGB)
}
Look :: struct { ambient, specular, power, wrap: f32 }  // the classic clay viewport look; never exported
```

Rules that keep the viewport, a future path tracer and exporters consistent:
- All f32 colours in app state are **linear**; 8-bit storage (polypaint, PNG base colour) is **sRGB**; the piecewise
  sRGB curve everywhere, never 2.2 (shader: a 5-instruction function; or render into `R8G8B8A8_UNORM_SRGB`).
- Dielectric F0 = 0.04 x specular; metals take F0 from base colour (as now). Roughness is perceptual, alpha = r^2 (as now).
- Energy terms a path tracer can match: Lambert diffuse x (1 - metallic) x (1 - F) is close enough; add
  multiscatter compensation (Fdez-Aguera) later, it changes nothing in the data.
- Texture colour spaces exactly as glTF: base colour and emissive sRGB; ORM (R occlusion, G roughness, B metallic),
  normal (+Y up, OpenGL) and displacement linear.
- The classic presets become `Look` presets (Clay, Red wax, ...), the PBR presets become `Surface` presets; one
  object has one `Surface` and the scene one `Look` (lights and tone map are also scene-level, not material-level).

## 5. Colour-space plan (improvement)

- `kit_color` edits and shows **display (sRGB) values** with a hex field, as Blender's and Substance's pickers do;
  it converts to linear for `Surface.base_color` and quantises directly to bytes for the brush. Settings:
  `paint_color` stays sRGB 0-1 (unchanged meaning); `custom_material` is written as a new `surface` line in linear
  with the old line still read (settings are keyed lines, no version needed).
- `mesh.vert`: decode polypaint with the piecewise curve (vertex rate, negligible). `mesh.frag`: encode with the
  piecewise curve. The classic path stays pixel-stable except a <= 2/255 shift on mid greys: refresh the reference
  PPM dumps once.
- Export already uses the exact curve; polypaint-to-texture bakes (section 6) use the same `srgb_to_linear` table.
- Acceptance: `odin test` in `geom`/`app` for round trips (sRGB byte -> linear -> byte identity for all 256 values);
  a `--dump-viewport` of a 0.5 sRGB painted sphere next to a 0.5 sRGB material sphere differs by <= 1/255 in the
  flat-lit centre pixel (`scripts/ppm.py pixel`).

## 6. Baking: what to add next (extension of `geom/bake.odin`)

All of these reuse the texel-owner rasterisation, the two rays, the BVH and the dilation; each adds a `Bake_Kind` and a
per-texel sample from the hit triangle `tri` at `p + d*n`.
- **Base colour from polypaint**: barycentric blend of the source level's `color` (sRGB -> linear -> blend -> sRGB
  byte; coverage composited over the object's `base_color`, coverage itself to alpha). The bake source is the top
  level; colours are carried there by `levels_carry_color` (already the case for the current level). PNG RGBA8.
- **ID from polygroups**: `groups.tris[tri]` -> palette colour (`group_color` from `mesh.vert` ported to CPU, so the
  map matches the viewport); dilation must copy the majority neighbour, not average (a per-kind dilation rule).
- **AO**: N cosine-weighted rays from the hit point over the source hemisphere, max distance = reach x k; 2048^2 x 32
  rays = 134M rays; the Morton BVH does ~10-20M rays/s/core, so ~2-4 s on 4 threads: acceptable for a one-off,
  with a progress note. Grey PNG, linear. Also gives **bent normals** for free (optional).
- **Thickness**: the same rays sent inward from the back face (distance-weighted); **curvature**: the per-vertex
  cavity measure of `mask_cavity` (`sculpt/mask.odin:454`) computed on the source once, blended at the hit (fast,
  resolution-independent); **position** and **object-space normal**: already known (`p + d*n`, `sn`), normalised by
  the source bounds; **height** stays as is but offer a fixed mid-value scale option like ZBrush's.
- **Cage / ray distance**: keep `reach` in edges; add a per-vertex cage offset (a scalar painted with the Mask brush
  on the low mesh, reusing the mask) later: this is Marmoset's "offset painting" with zero new UI.
- **Supersampling**: 4 rays per texel at (±0.25) offsets, averaged per kind (normals renormalised, IDs by majority).
  Fixes aliasing and makes dilation seams stable. 4x cost: 2048 from 10M goes ~3.7 s -> ~12 s; default 1x for the
  preview, 4x on "final".
- **MikkTSpace exactness**: port the reference `mikktspace.c` (Morten Mikkelsen, zlib/public domain, ~1,900 lines;
  the Blender C++ rewrite is a cleaner source) for the low mesh: angle-weighted tangents, grouping by
  position+normal+UV, per-vertex bitangent sign, computed on the **triangulated** low mesh in the same triangle order
  the exporter writes. glTF says clients compute tangents with "default MikkTSpace algorithms" when TANGENT is absent;
  exporting TANGENT as well removes any reader difference. Test: a known-vector unit test (a tilted quad whose
  tangent the reference computes), and the Blender check below.
- **Bake preview**: section 7.
Acceptance: `odin test geom bake_*`: polypaint sphere painted one colour bakes to that colour within 1/255 on every
covered texel; ID map has exactly as many colours as groups; AO of a sphere is 1.0 +- 0.02 everywhere; a grown-by-1%
copy still gives the displacement test. `export_check.py --material`: Blender imports the GLB, finds a Principled
BSDF with Base Color/Normal/ORM image nodes, and (new) renders a 64x64 Workbench/EEVEE shot of the low mesh with the
normal map vs. a shot of the high mesh exported alongside; mean normal angle difference <= 2 deg via a bpy script
that reads the normal map through Blender's tangents.

## 7. Vertex colours vs textures at 10M+, painting scope, previews

- 10M vertices = 10M colour samples, placed where the sculpt is dense: equivalent to a ~3.2k map in count, better in
  distribution. Painting costs 1.0 ms/frame at 10M (README). ZBrush's approach (paint on the sculpt, bake to texture)
  fits the architecture; Substance/3D-Coat per-pixel painting (UV-space render targets, projection painting, seam
  padding, layers with masks) is a second product. **Scope: no texture painting in the sculpt.** Textures come from
  bakes and from external tools (import for lookdev).
- **Extra polypaint channels** (extension): roughness and metallic as two bytes in the free high half of
  `Paint_Packed.y`, CPU `[2]u8` per vertex (20 MB at 10M, allocated on first use like `color`), painted by the Paint
  brush's channel switch, carried across levels with `levels_carry_color`, saved (scene version bump), baked to ORM.
  The shader reads them where `surface.y > 0`. Polypaint *layers*: experiment only (40 MB per layer at 10M; ZBrush's
  layers hold polypaint, but the win is small for a sculpt tool).
- **Triplanar previews** (new): sample a tiled texture by `in_mesh_pos` with normal-weighted blending; needs the
  texture binding of the preview pipeline, costs 3 samples per fragment, no vertex data. Good for concept-art
  materials (skin pores, cast metal, fabric) on the sculpt. Keep partial redraw valid: textures are static inputs.
- **Textured preview of the low mesh** (new): a separate small `Mesh_Buffers` variant for retopo objects (a few
  thousand to 100k quads): vertices split at UV seams with position, normal, UV, tangent (the MikkTSpace frame), a
  second pipeline binding up to 4 textures with trilinear + 8x anisotropic samplers and mips from
  `SDL_GenerateMipmapsForGPUTexture`. No change to the 16-byte sculpt vertex, chunks, LOD or culling (the object is
  small; draw it as one `live` item). Views: Textured, Normal map only, UV checker, Flat colour. This is also the
  path for importing Substance output.

## 8. Performance and interoperability

Memory at 10M vertices (per level): positions 120 MB CPU + 160 MB GPU vertices (existing); polypaint 40 MB CPU +
80 MB GPU (existing, only when painted); roughness/metal channels +20 MB CPU, +0 GPU. Textures: 2048^2 RGBA8 = 16 MB
(+5.3 MB mips), 4096^2 = 64 MB (+21 MB); a 2k bake set (base colour, ORM, normal) is 48 MB + mips, a 4k set 256 MB:
fine on an RTX 3060 Ti, keep the preview at 2k on Android. 16-bit displacement 2048^2 = 8 MB (`R16_UNORM`). Block
compression (BC7) would quarter this but SDL_GPU has no encoder: experiment, not plan. CPU bake time scales with
texels x rays; AO/thickness are the only multi-ray maps; run every bake on the pool with the progress note, never in
the frame loop. Upload through the existing 16 MB cycled transfer buffer in slices.

File versioning: `SCENE_VERSION` 11 -> 12 adds per object a `Surface` record (fixed-size floats + flags, no strings
beyond a preset label) and the material slots per polygroup (count + u8 per group, 0 for none); 12 -> 13 (or the
same bump) adds the optional roughness/metal arrays after `color` in `levels_write` with a presence byte, as colours
are written. Older files read with the global material and no channels. Textures are **referenced by path relative
to the .sculpt** (bake output folder), never embedded: a missing file shows the flat material and a note, and the
bake can be redone. Settings keep `material` as the default for new objects.

Interoperability facts to build to: glTF `metallicRoughnessTexture` = G roughness, B metallic (R free for
occlusion: the ORM pack); `occlusionTexture` reads R; `normalTexture` linear, +Y up, `scale` on XY; base colour and
emissive textures sRGB, all else linear; `COLOR_0` linear; images PNG/JPEG (GLB `bufferView` + `mimeType`).
UsdPreviewSurface: `useSpecularWorkflow 0`, `UsdUVTexture` with `sourceColorSpace raw` and `scale (2,2,2,1) bias
(-1,-1,-1,0)` for 8-bit normals, `UsdPrimvarReader_float2 varname st`, `material:binding`, `UsdGeomSubset` per slot.
OpenPBR/MaterialX: optional `.mtlx` with `open_pbr_surface` (base_color, base_metalness, specular_roughness,
specular_weight, coat_weight, coat_roughness, emission_color) referenced from the USD for Houdini/Arnold users;
Blender does not read MaterialX, so it stays an experiment.

## 9. Phased plan (each phase extends existing systems and ships on its own)

**Phase 1: colour space and the material record** (improvement + extension). Tasks: `Surface`/`Look` split in
`material.odin`; `kit_color` in sRGB with hex; piecewise curve in `mesh.vert`/`mesh.frag`; `Material_Uniforms`
gets `specular, emissive, coat, coat_roughness` (two more vec4). Reuses `MATERIALS`, `kit_material`, settings lines.
Accept: `odin test app` colour round trips; smoke green; `scripts/ppm.py diff` of before/after dumps for the Clay
preset shows only mid-grey shifts <= 2/255; the 0.5-grey paint vs material pixel test (section 5).

**Phase 2: per-object materials, saved; material export** (extension). `Object.surface`; `Draw_Item.color/surface`
from the object (the idle grey becomes a *Look* option "mute unselected", default on, so today's picture is kept);
scene v12; `Scene_Command.Set_Material` + script `set material steel` applies to the selection; glTF `materials[]`
+ `pbrMetallicRoughness` + `KHR_materials_specular/clearcoat/emissive_strength` when non-default; USD
`UsdPreviewSurface`. Reuses `Mesh_Export`, `glb_json`, `usd_write`. Accept: `odin test geom gltf_*|usd_*` (JSON
has the material, values round-trip); `export_check.py --material "gold"`: Blender's Principled BSDF Base
Color/Metallic/Roughness equal the exported values within 1e-3; gltf-validator 0 errors; a v11 scene opens with
the global material; a saved v12 scene reopens with each object's material (`save_test.odin` pattern).

**Phase 3: the bake set** (extension of `bake.odin`/`retopo.odin`). `Bake_Kind` set; polypaint, ID, AO, curvature,
thickness, position, object normal; majority dilation; 4x supersampling; MikkTSpace port with TANGENT; bake panel
checkboxes and `--bake-maps=...` flag. Accept: tests in section 6; 2048 from 10M with all single-ray maps <= 6 s
and AO at 32 rays <= 12 s on the 4-thread VM (release); PNG set opens in Blender via `export_check.py`.

**Phase 4: GLB with UVs and textures; per-polygroup slots** (extension). UV-seam split in `gltf_write` for the
retopo base (`TEXCOORD_0`, `TANGENT`), embedded PNGs, `ORM` pack from the bake set, `textures/images/samplers`;
material slots per polygroup (u8 table, `glTF primitives`, `UsdGeomSubset`); scene bump if not done in phase 2.
Accept: `export_check.py --textures 3 --uv`: Blender finds the UV map and three image nodes, mesh triangle count
unchanged, vertex count = split count the writer reports; validator 0 errors; a polygroup-slotted object imports
as N material slots.

**Phase 5: textured preview and texture import** (new). Preview `Mesh_Buffers` variant + pipeline, mips,
anisotropic sampler, UV checker, Textured/Normal/Checker views as registry commands; load PNG/JPEG textures into
slots. Accept: smoke under GPU validation with a textured object; `--dump-viewport` of the UV checker shows a
regular grid (describe PNG); a baked normal map on the low mesh vs. the high mesh dump: mean pixel difference
over the silhouette-interior <= 4/255 (`ppm.py diff`); cost < 0.2 ms GPU for a 20k-quad object (`--time-gpu`).

**Phase 6 (optional experiments)**: polypaint roughness/metal channels and ORM bake; triplanar previews; `.mtlx`
export; BC7 via an offline encoder; displacement preview on a subdivided copy; multiscatter GGX compensation.

## 10. Documentation, standards and papers worth keeping at hand

glTF 2.0 spec and the KHR_materials_* READMEs; UsdPreviewSurface spec; OpenPBR and MaterialX PBR specs (naming,
export); Mikkelsen 2008 and `mikktspace.c`; Marmoset baking docs (cage, offset painting, map types, handedness);
ZBrush Multi Map Exporter / Texture From Polypaint / UV Master; Substance PBR Guide 1-2 (value ranges, sRGB vs
linear maps); 3D-Coat texturing manual; Karis 2013 (UE4 shading); Fdez-Aguera 2019 (multiscatter IBL); Burley 2012
(Disney BRDF); Lagarde 2014 (Frostbite); Khronos glTF Sample Viewer (reference shader for KHR extensions).

## Sources
- https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html (materials, COLOR_0, tangents, image types)
- https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos (KHR_materials_specular, _clearcoat, _emissive_strength, ...)
- https://openusd.org/release/spec_usdpreviewsurface.html
- https://github.com/AcademySoftwareFoundation/OpenPBR
- https://academysoftwarefoundation.github.io/OpenPBR/
- https://materialx.org/ and https://github.com/AcademySoftwareFoundation/MaterialX/blob/main/documents/Specification/MaterialX.PBRSpec.md
- https://github.com/mmikk/MikkTSpace (reference mikktspace.c); https://github.com/KhronosGroup/glTF-Sample-Viewer
- https://docs.marmoset.co/docs/setting-up-a-bake-project/ ; https://docs.marmoset.co/docs/map-types/ ; https://docs.marmoset.co/docs/cage-mesh/
- https://help.maxon.net/zbr/en-us (Multi Map Exporter, Texture From Polypaint, UV Master)
- https://www.adobe.com/learn/substance-3d-designer/web/the-pbr-guide-part-1 ; https://www.adobe.com/learn/substance-3d-designer/web/the-pbr-guide-part-2
- https://www.adobe.com/learn/substance-3d-painter ; https://experienceleague.adobe.com/en/docs/substance-3d-painter/using/home
- https://3dcoat.com/documentation/manual/texturing/ ; https://pilgway.com/product/3dcoattextura
- https://wiki.libsdl.org/SDL3/SDL_GenerateMipmapsForGPUTexture ; https://wiki.libsdl.org/SDL3/SDL_GPUSamplerCreateInfo ; https://wiki.libsdl.org/SDL3/SDL_GPUTextureFormat
- https://jcgt.org/published/0008/01/03/ (Fdez-Aguera multiscatter) ; https://blog.selfshadow.com/publications/s2013-shading-course/ (Karis)
