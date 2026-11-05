# Stage 3.1 + 3.2: the bake set and a textured glTF (design)

Roadmap Stage 3 (viewport-look-roadmap.html; research-3-pbr.md sections 2, 3, 9 phases 3-4). This note covers the
first two parts: more maps from the existing ray bake, and a `.glb` with UVs, tangents and embedded textures written
with them. The textured viewport preview (3.3: a new vertex layout and pipeline) gets its own design afterwards.

## What exists
`geom.bake_maps(low: Quad_Mesh, uvs: Uv_Layout, source: Mesh, bvh, size, reach, pool)` rasterizes each quad's two
triangles into the UV square (texel centre → owner triangle + barycentrics), casts one ray out and one in along the
low mesh's interpolated normal, and writes a tangent-space normal (RGBA8) and a displacement (f32). The tangent frame:
per (vertex, chart) sums of the triangles' UV tangents/bitangents, blended unnormalized, then Gram-Schmidt per texel.
Dilation grows charts 8 texels by neighbour averages. `app.bake_to_folder` writes `NAME_normal.png`,
`NAME_displacement.png` (16-bit), `.txt`, `NAME.obj`. Panel: Object palette > Build > UVs and baking (source select,
Bake maps... / New UVs, More: size tabs, Reach). Flags `--bake=DIR`, `--bake-size`.

## 3.1 The bake set
New maps, each optional (Normal and Displacement stay always on: they are why the bake exists and cost one ray pair):

| Map | File | Content | Colour space |
|---|---|---|---|
| Base colour | `NAME_base_color.png` | the source's polypaint over the material of the hit triangle (its group's, else the object's), composed exactly as the export composes it (`paint_over` in sRGB bytes); no paint: the material's colour | sRGB RGBA8 |
| ORM | `NAME_orm.png` | R ambient occlusion, G roughness, B metallic of the hit triangle's material (glTF's `metallicRoughnessTexture` + `occlusionTexture` layout) | linear RGBA8 |
| Polygroup ID | `NAME_id.png` | the hit triangle's group in the viewport's group colour (`group_color` ported to Odin, one definition shared with a test that it matches the shader's constants) | sRGB RGBA8 |

### geom API
```odin
Bake_Kind :: enum u8 {Base_Color, Orm, Id}
Bake_Surface :: struct {base: [3]f32 /* linear */, metallic, roughness: f32}   // one a material slot
Bake_Source :: struct {
    mesh: Mesh, bvh: ^Bvh,
    paint: [][4]u8,         // per source vertex, sRGB + coverage; nil for none
    groups: []u16,          // per source triangle; nil for none
    slots: []u8,            // per source triangle: index into surfaces; nil = all 0
    surfaces: []Bake_Surface, // [0] the object's material
    occlusion_rays: int,    // per texel, 0 = no occlusion (R = 255)
    occlusion_reach: f32,   // farther hits do not occlude
}
bake_maps :: proc(low: Quad_Mesh, uvs: Uv_Layout, src: Bake_Source, size: int, reach: f32, kinds: bit_set[Bake_Kind], pool, allocator) -> Bake_Maps
```
`Bake_Maps` gains `base_color, orm, id: []u8` (RGBA, nil when not asked). Callers pass `Bake_Source{mesh, bvh}` for
today's behaviour (one existing test call changes).

- **Hit attributes.** After the nearer hit, barycentrics of the hit point in the source triangle (as `source_normal`
  already computes) interpolate paint per channel in sRGB bytes (as the viewport interpolates the decoded bytes, close
  enough: the shader interpolates *before* decoding too, so bytes are the right space), then compose over the slot's
  base encoded to sRGB bytes with the same rounding as `app.paint_over` (moved to geom as `paint_over_srgb` so app and
  bake share it). A miss leaves the texel unfilled for every map (dilation fills it).
- **Occlusion.** `occlusion_rays` cosine-weighted directions around the *source* normal at the hit point, from the hit
  point lifted by 1e-4 × reach along it, `bvh_raycast_with` up to `occlusion_reach`. Directions: a fixed
  Hammersley set of N points mapped to the cosine hemisphere, rotated about the normal by an angle hashed from the
  texel index (`u32` hash, deterministic, independent of threads and ranges). R = 255 × (1 − hits/N). Default 16
  rays, reach = 0.2 × the source's bounds diagonal; both in the panel's More and script-settable.
- **Dilation.** `dilate` generalized: colour maps (base colour, ORM) average filled neighbours per channel like the
  normal; ID takes the most common neighbour colour (ties: first in a fixed neighbour order), so no new colours appear
  at chart edges. Same 8 rings.
- **Determinism.** Per-row ranges write disjoint texels; occlusion's directions depend only on the texel index. A test
  bakes on the pool and serially and compares every map byte for byte.

### App
- `bake_to_folder` builds the `Bake_Source` from the source object's top level: `paint` = that level's
  `sculptor.color` (nil when dynamic: the packed copy has no colours, said in the note), `groups` = `groups.tris` (nil
  when dynamic), `slots`/`surfaces` from `export_material` of the object's material and its group materials (the table
  `export_group_materials` builds, factored so both use it). Paint present → base colour composed as the viewport.
- Settings (remembered, settings-table rows, script `set`): `bake_base_color` (on), `bake_orm` (on), `bake_id` (off),
  `bake_occlusion_rays` (0-64, 16), `bake_occlusion_reach` (share of the source's size, 0.2). Panel: under More
  options, three switches and the two sliders; folded count unchanged (≤ 5). `--bake` honours them.
- Note line lists the files written and the occlusion time separately.

## 3.2 A textured glTF from the bake
`bake_to_folder` also writes `NAME.glb`: the quad object's base level, triangulated the way the bake rasterizes
(0,1,2 / 0,2,3), with `TEXCOORD_0`, `NORMAL`, `TANGENT` and one material whose textures are the PNGs just written,
embedded. It opens in Blender, three.js, Unity, Godot ready to look at.

- **Seam split** (geom, `quad_mesh_split_uvs(low, uvs) -> (positions, normals, uvs, tangents, indices, from)`): one
  output vertex per distinct (vertex, chart, uv) corner, in first-corner order (deterministic; lookups in a map, never
  iterated). Normals are the low mesh's smooth `quad_mesh_normals` (shared across seams, so shading stays smooth).
- **One tangent frame for bake and file.** Factor the tangent build out of `bake_maps` into
  `quad_mesh_tangents(low, uvs) -> []([4]f32 per (vertex, chart) slot)`: the summed UV tangent made orthogonal to the
  vertex normal and normalized, w = handedness from the summed bitangent. The bake then reconstructs exactly what a
  MikkTSpace-convention pixel shader does with those vertex tangents: interpolate vN and vT unnormalized, vB =
  w × cross(vN, vT), and store the sculpt normal solved in that basis (`inverse([vT vB vN]) × n`, normalized), so a
  renderer that reads our TANGENT reproduces the sculpt normal to 8-bit rounding. Blender's importer ignores TANGENT
  and recomputes MikkTSpace; our frame is the same construction minus mikk's angle weighting and degenerate handling,
  so it stays "close, not to the bit" there (README says so; an exact mikk port is a later item).
- **glTF writer.** `Mesh_Export` gains `texcoords: [][2]f32` and `tangents: [][4]f32` (per vertex, nil none), and
  `Export_Material` gains `textures: [Export_Texture_Kind]int` (index into `Mesh_Export.images`, -1 none; kinds
  Base_Color, Orm, Normal) ; `Mesh_Export.images: []Export_Image{name: string, png: []u8}`. `glb_json` writes
  `images` (bufferView + `image/png`), one `sampler` (linear, mipmapped, repeat), `textures`, and the material's
  `baseColorTexture`, `metallicRoughnessTexture` + `occlusionTexture` (same ORM image), `normalTexture`;
  `baseColorFactor` 1 when a base colour texture is given. PNG bytes go in bufferViews after the vertex data,
  4-aligned. Without images the file is byte-identical to today's (tests keep their expectations).
- **Files**: `NAME.glb` beside `NAME.obj`; written only when the low object has UVs (always true here).
- **USD with textures**: not in this part (a `UsdUVTexture` per map referencing the PNGs beside it is a small follow-up;
  noted in README as not yet).

## Verification
- geom tests: maps on a known case (a quad sphere baked from a painted icosphere: base colour equals the paint where
  painted, the material elsewhere; ID has exactly the groups' colours and no others after dilation; occlusion is 255 on
  a lone convex sphere and < 255 inside a concave cup; pool vs serial byte-identical); tangent basis round trip
  (bake a sphere from itself: every normal-map texel within 2/255 of (0.5, 0.5, 1)); split counts (a cube's 6 charts →
  24 vertices).
- glTF tests: images/textures/sampler JSON, PNG bytes round-trip from the bufferView, no-images output unchanged.
- `export_check.py NAME.glb --textures 3 --uv`: validator 0 errors/warnings; Blender finds the UV map, three image
  nodes wired into the Principled BSDF (base colour, metallic/roughness via separate channels, normal map), triangle
  count = 2 × quads. Extend the Blender script to report image nodes and UV layers.
- App: `--bake` scripted run on a painted, grouped, group-materialled sculpt; describe the PNGs; time 2048 from 1M and
  10M (release) with and without occlusion; README numbers.
- Gate.

## Out of scope here
Supersampling (4x), curvature/thickness/position maps, exact MikkTSpace port, USD textures, textured viewport
preview (3.3), texture import.

## Cost
~250 lines geom bake, ~200 glTF writer + split, ~150 app/panel/settings, ~250 tests. No scene-file change, no undo,
no GPU change.

## Architect review (2026-10-27): approved with changes, all taken
1. Paint is decoded per corner to linear, blended with coverage, laid over the linear base and encoded once (the viewport decodes in mesh.vert before interpolation); the export's byte compose stays in app.
2. A hit mask: the set's maps dilate from texels that hit; anything still empty gets slot 0's surface, occlusion 255, alpha 255 (ID: group 0).
3. Occlusion hemisphere around the hit triangle's face normal (no self-hits on convex parts).
4. TEXCOORD_0 written as (u, 1 − v); tangent w kept from v-up space so B = w·cross(N,T) points to the image top.
5. `quad_mesh_tangents`: unit xyz ⟂ N, w = ±1, fallback perpendicular for UV-degenerate slots; the bake uses those per-vertex tangents blended unnormalized with the reciprocal basis (MikkTSpace pixel-shader convention).
6. Read-back test on a bumpy sphere through the split mesh's NORMAL/TANGENT/TEXCOORD_0 (all texels within 2°).
7. Factors 1 under textures; one material; occlusionTexture only when rays > 0 (`Export_Texture.Occlusion`).
8. Views 4-aligned with zero padding, images without target, mimeType image/png; no-image files byte-identical.
9. `sculpt.levels_paint_to_top` carries current-level paint/groups to the top without clearing the edited flags.
10. Retopo section full count 10.
11. The .glb uses `low.file.scale/position`.
Optional taken: slots keyed on (vertex, chart) so a split vertex is a tangent slot; `bvh_any_hit` for occlusion (16 rays at 2048 from 1M: 10.2 s → 8.3 s).
