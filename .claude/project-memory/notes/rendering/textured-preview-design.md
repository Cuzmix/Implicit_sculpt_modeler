# Stage 3.3: the textured viewport preview (design)

Roadmap Stage 3, part 3 (research-3-pbr.md section 2 item 7, section 7 "Textured preview of the low mesh", phase 5).
3.1 and 3.2 (PR #147) bake base colour, ORM, ID and normal maps from a sculpt onto a retopologized quad object and
write a textured `.glb`. Today the maps only exist as files: the low object still draws as clay. This part closes the
loop inside the app: the low object shows its maps in the viewport, the maps stay with it in the scene file, and maps
made elsewhere (Substance, Blender) can be loaded onto it.

Two PRs: **3.3a** the preview (render variant, the bake attaching its maps, views, scene v17, undo step) and **3.3b**
loading and removing maps, and a textured object's own glTF export.

## What exists
- A retopologized object is an ordinary sculpt object whose base level is the quads' triangles (two a quad);
  `Levels.faces` keeps the quads (base-level vertex numbers) and their `Uv_Layout` (per quad four corners, charts).
  They are dropped whenever the base's triangles change (deleting lower levels, dynamic topology).
- `geom.quad_mesh_normals`, `quad_mesh_tangents` (per (vertex, chart) slot, unit xyz square to N, w ±1) and
  `quad_mesh_split_uvs` (a vertex per slot, quads as 0,1,2 / 0,2,3) build exactly the mesh the `.glb` carries; the
  normal map was baked against that frame read MikkTSpace-style (vN, vT blended unnormalized, vB = w·cross(vN, vT)).
- The mesh pipeline: 16-byte vertices in two buffers, chunked indirect draws, `mesh.vert`/`mesh.frag` with one
  sampler (the MatCap) and two fragment uniform buffers (Material_Uniforms, Slot_Uniforms).

## 3.3a The preview

### Render (`src/render/textured.odin`, new)
```odin
Texture_Map :: enum u8 {Base_Color, Orm, Normal}
// One vertex of a textured mesh: 32 bytes, one interleaved buffer.
Textured_Vertex :: struct {
    position: [3]f32,
    normal:   Normal_Packed,  // octahedral with the mask folded in (pack_normal), as the sculpt vertex
    tangent:  [4]i16,         // xyz unit, w ±1, SHORT4_NORM
    uv:       [2]f32,         // v up, as Uv_Layout stores it; the shader samples (u, 1 - v)
}
Textured_Mesh :: struct {
    vertices, indices: ^sdl.GPUBuffer,
    vertex_capacity, index_capacity, index_count: u32,
    maps:  [Texture_Map]^sdl.GPUTexture, // nil: none (a 1x1 default is bound)
    sizes: [Texture_Map][2]u32,
    stamp: u64,                          // bumps when buffers or maps change (both frame keys)
}
textured_mesh_upload :: proc(r, tm, vertices: []Textured_Vertex, indices: []u32) -> bool // grows by powers of two; own command buffer + fence, like texture_upload
textured_mesh_set_map :: proc(r, tm, m: Texture_Map, pixels: []u8, w, h: int) -> bool    // nil pixels removes; full mip chain
textured_mesh_destroy :: proc(r, tm)
```
- Formats: base colour `R8G8B8A8_UNORM_SRGB` (filtered in linear light, as the MatCap), ORM and normal
  `R8G8B8A8_UNORM`; usage SAMPLER + COLOR_TARGET for `GenerateMipmapsForGPUTexture`. Defaults bound for a missing
  map: `no_matcap` (1x1 white) serves base colour and ORM, a new 1x1 (128, 128, 255) `no_normal_map`.
- `Renderer.texture_sampler`: linear min/mag/mip, repeat, anisotropy 8 where the device has it (not on Android,
  whose device is created without the feature: `when ODIN_PLATFORM_SUBTARGET == .Android` leaves it off).
- `Mesh_Pipelines` gains `textured` and `textured_see` (Solid and See_Through modes of the same builder:
  `create_mesh_pipeline` takes the shader pair and vertex layout from a small table), so MSAA, thumbnails and the nav
  head need nothing new. A device that refuses them logs a warning and textured items draw through the sculpt path.
- `Draw_Item` gains `textured: ^Textured_Mesh` and `texture_view: Texture_View` (`.Off, .Textured, .Normal_Map,
  .Uv_Checker`). With both set, `draw_items` binds the textured pipeline, the interleaved buffer, the four samplers
  (MatCap, base colour, ORM, normal) and draws the whole index buffer (no chunks, culling, LOD or hidden runs: the
  object is small). The item keeps `mesh`, so the wireframe pass (sculpt buffers, same positions), the studio
  render's shadow pass and the damage boxes work unchanged. `frame_key` and `static_key` add the textured pointer,
  its stamp and the view.
- `Material_Uniforms` gains `maps: [4]f32` (x, y, z: base colour, ORM, normal present; w: the view). The sculpt
  path pushes zero there and its shader ignores it.

### Shaders
- `textured.vert` (new): reads the 32-byte vertex, writes the sculpt path's outputs (normal, view position, mask;
  paint 0, group −1, slot 0, mesh position) plus `out_uv` (location 7) and `out_view_tangent` (location 8, view space
  xyz, w sign), turned by `mat3(view) * mat3(model)` like the normal (a similarity, so the frame stays consistent).
- `mesh.frag` moves its body into `mesh_shading.glsl` (an include, never compiled alone); `mesh.frag` becomes
  `#version 450` + `#include`, and `textured.frag` the same with `#define TEXTURED` first
  (`GL_GOOGLE_include_directive`). Under `TEXTURED` only: inputs 7-8, samplers at bindings 1-3, no Slot_Uniforms, and
  these substitutions right after the wireframe's early return:
  - **Normal** (Textured and Normal map views, map present): `tn = texture(normal_map, uv').xyz * 2 - 1`,
    `n = normalize(tn.x * T + tn.y * w·cross(N, T) + tn.z * N)` with N and T the interpolated, unnormalized inputs
    (the convention the bake solved for), flipped on back faces. Flat shading does not apply in textured views.
  - **Albedo** (Textured): `base.rgb * texture(base_map).rgb` with `base.rgb` = white when the map is present, else
    the material's colour (the app passes it), as glTF multiplies factor and texture.
  - **ORM** (Textured, map present): roughness = G, metallic = B; the physically based path is taken even for a
    classic material (surf.y = max(G, 0.04)); occlusion R multiplies the ambient term (classic) or the studio's
    diffuse and specular environment (physically based), never the direct lights, as glTF specifies.
  - **UV checker**: albedo × a procedural checker over (u, v): 8 x 8 cells, alternate cells 0.72, thin lines from
    `fwidth`, fading to the mean under 3 px like the density checker; each cell tinted by its column and row
    (hue from u, lightness from v) so stretching, mirroring and seams read at a glance. No texture.
  - Paint, polygroup colours and group slots do not show in textured views (the base colour map already has them).
    The mask shows darker as on the sculpt path (it rides in the normal). MatCap materials work: the MatCap is looked
    up with the mapped normal and multiplied by the mapped albedo.
- The sculpt `mesh.frag.spv` must not change in behaviour: the move into the include is checked by dumping the
  default scene, a painted/grouped/slotted one and a MatCap one before and after (`ppm.py diff` → 0 pixels).
- `build.sh`/`build.bat` already compile every `*.vert|*.frag`; `.glsl` is not in their globs.

### App (`src/app/textures.odin`, new)
```odin
Object_Textures :: struct {
    image: [render.Texture_Map][]u8, // the encoded file (PNG from a bake; 3.3b also JPEG, BMP, QOI), owned; nil: none
    stamp: u32,                      // bumps on every change
}
Texture_Preview :: struct {          // GPU side, never saved
    mesh:         render.Textured_Mesh,
    shape:        u64,               // Mesh_Buffers.version of the base level the vertices were built from
    maps_stamp:   u32,               // Object_Textures.stamp the maps were decoded from
}
Texture_View :: render.Texture_View  // app.texture_view, a settings row, remembered
```
- `Object` gains `textures: Object_Textures` and `preview: Texture_Preview`.
- **When an object draws textured** (`object_textured(app, obj) -> bool`): `app.texture_view != .Off`, the object is
  on level 0 with quads and UVs, not dynamic, not voxel, not in HD, no hidden triangles, polygroup colours not shown,
  not the object of a stroke in progress, and the view has something to show: Textured needs any map, Normal map the
  normal map, UV checker only the UVs. Otherwise it draws as now. Hidden parts are left to the sculpt path because the
  preview has no per-triangle runs; a stroke on the object draws as clay so the stroke runs at sculpting speed (and
  a sculpted low mesh no longer matches maps baked from its old shape anyway); the textures come back when it ends.
- **Refill** (`texture_preview_update`, once a frame before the draw list, outside strokes): when the base level's
  `Mesh_Buffers.version` differs from `preview.shape`, build `quad_mesh_normals` → `quad_mesh_tangents` →
  `quad_mesh_split_uvs` (the `.glb`'s exact mesh, so the normal map reads back as baked), pack `Textured_Vertex`
  with the mask of `frame.vertex[slot]`, upload. When `textures.stamp` differs from `preview.maps_stamp`, decode each
  image (`core:image`, to RGBA8: grey and RGB expanded, 16-bit taken to 8) and `textured_mesh_set_map`. A map that
  does not decode is dropped from `textures` with a toast naming it (the scene still opens). Temp memory only, freed
  by the frame loop.
- **The bake attaches its maps**: `bake_to_folder` hands the PNG bytes it just wrote (base colour when on, ORM when
  on, normal always) to the low object as one `.Textures` history step, and switches `texture_view` to Textured the
  first time an object gets textures in a session, so the result shows at once (the toast says View > Textures
  turns it off). The ID map is not attached (it is a mask source, not a look).
- **Undo**: a new `History_Kind.Textures` entry owning `^Texture_Step{before, after: Object_Textures}` (as
  `Group_Table_Step` does for group materials): undo and redo swap the object's textures and bump the stamp; it
  never forgets the object's strokes, unlike a swap entry. Object swaps (`object_put`) carry the textures, so
  deleting and undeleting a textured object keeps them.
- **What drops them**: anything that rebuilds the object drops its quads and UVs and so its textures (the rebuild
  makes a new object state; the textures are not carried). New UVs (`object_layout_uvs`) records a `.Textures` step
  that clears them in the same undo step, since they followed the old layout; its note says so.
- **Views** (registry commands, View menu SHADING): `.Texture_View` with args 4 — "Sculpt", "Textures",
  "Normal map", "UV checker" — `checked` on the current one; the settings row `texture_view` (tabs, remembered,
  script `set texture_view uv_checker`). Default Off, so nothing changes for anyone who never bakes. Palette search
  words: "textures uv checker normal map bake preview".
- **Scene file v17** (`SCENE_VERSION` 17, reading every older one): after `group_materials_put`, `textures_put`: a
  `u8` bit set of the maps present, then per present map (in enum order) a `u32` byte count and the bytes. Read:
  version < 17 → none; bits beyond the enum, a count past the end, or textures on a voxel object refuse the file
  (damage), as the other fields do. Decoding is lazy (first preview), so opening a scene never waits on PNGs it
  does not show. The autosave thread reads `image` slices only while the scene rests; texture changes only happen
  from commands and the bake, which stop it first, as any scene change does.
- `object_put_estimate` adds the image bytes.

### Tests and verification (3.3a)
- app: `textured_vertices_follow_the_split` (counts equal `quad_mesh_split_uvs`, tangents round-trip through
  SHORT4_NORM within 1e-4, the mask of `frame.vertex`); `scene_keeps_textures` (v17 round trip byte-identical, a v16
  file reads with none, a truncated count refuses); `textures_undo_and_redo` (bake attach, New UVs clearing, undo
  both); `object_textured_only_when_it_can` (level, dynamic, hidden, stroke, view, maps); the settings and verb
  tests take the new row; `show_every_option` counts.
- Pixels: before/after dumps of sculpt-path scenes identical (above); `--dump-viewport` of a retopologized sphere in
  UV checker view (describe: a regular grid of cells across the surface, seams visible); a painted sculpt baked and
  shown Textured beside its source with the same camera and material: mean pixel difference over the
  silhouette's interior ≤ 4/255 (`ppm.py diff --mask`, research acceptance); Normal map view of a bumpy sphere's low
  mesh against the high mesh.
- `--gpu-debug` run of a scripted retopo + bake + Textured view (validation clean, no leaks), MSAA on and off, a
  see-through textured object, wireframe over it, the studio render.
- Gate. GPU time for a 20k-quad textured object is not meaningful on llvmpipe: reported as not measured.

## 3.3b Loading maps, removing them, and a textured export
- Commands `.Load_Texture` (args 3: base colour, ORM, normal: "Load base colour...", …) open a file picker (a
  `file_take` request like Load MatCap) for PNG, JPEG, BMP or QOI on the selected object with UVs; the bytes are
  checked by decoding once (refused with a toast if they do not decode or exceed 8192 px a side) and stored as
  loaded; one `.Textures` step. `.Remove_Textures` clears all of them (one step, undoable).
- Panel: Object palette > Build gets a **Textures** section under "UVs and baking", shown for objects with UVs:
  the view tabs, one row a map (its name and size, or "none") with its Load button; More: Remove textures. Five
  controls folded or fewer (tabs 1, three Load buttons 3).
- Export: glTF of a textured object at level 0 writes the `.glb` the bake writes (`bake_glb` generalized to take
  `Object_Textures`), so loaded or baked maps go out with TEXCOORD_0 and TANGENT; OBJ and USD unchanged (USD
  textures stay a later item).
- Tests: load decodes and refuses (a bad file, an oversize header), remove undo; `export_check.py X.glb --uv
  --textures 3` after a load; a JPEG base colour shown.

## Out of scope
Texture painting, UDIMs, displacement preview, per-group texture sets, BC compression, an exact MikkTSpace port,
textures on objects without quads (triplanar is a later item).

## Cost
3.3a: render ~220 lines, shaders ~90 (plus the include move), app ~300, tests ~200. 3.3b: app ~200, tests ~100.
New: one vertex layout, two pipelines per sample count, one history kind, scene v17. No change to the sculpt vertex,
chunks, LOD, culling or partial redraw logic.

## Architect review (2026-10-27): approved with changes, all taken
1. Quad diagonals: the base level splits each quad on its shorter diagonal when made (`quad_split`), the bake and
   split mesh always 0-2. `Quad_Mesh.across` (per quad, split 1-3; nil = all 0-2) read from the base level's real
   triangles (`geom.quad_mesh_diagonals` over the sculptor's vertex faces, filled by `sculpt.levels_quad_mesh`), and
   `quad_halves` used by the bake's raster, the tangents, the split mesh and the `.glb`.
2. textured.vert divides the view-model turn by its scale (`length(turn[0])`) so N, T and cross(N, T) keep their
   relative lengths under a scaled object.
3. `.Textures` history entries handled like `.Transform`: their own branch in `history_step`, no sculptor redo
   clearing in `history_drop_redo`, kept by `history_forget_strokes` and `history_forget_level`, a timeline colour.
4. New UVs becomes a `Scene_Command` (`.Layout_Uvs`) recording a `.Textures` step that owns the UV layout and the
   textures before and after, so undo puts both back together.
5. Textures never outlive UVs: `textures_settle` beside `materials_settle` drops them (no history: the change that
   dropped the UVs is the undoable one, and its snapshot or step has them); a file whose object has textures but no
   UVs after `levels_read` is refused; the failure path frees them.
6. The per-frame preview never changes `obj.textures`: a map that does not decode is marked failed in
   `Texture_Preview` with a toast. Image headers are checked (size ≤ 8192, decodable kind) on reading a file and on
   loading a map.
7. Refill right after part 0's `level_upload`, as a copy pass on the frame's `cmd` (cycled transfer), so the preview
   matches this frame's shape with no fence.
8. Decoding runs on `jobs` (heap allocator, `matcap_pixels`-style pure decode); the object draws as clay until its
   maps are ready; textures upload when ready.
9. Texture steps count their image bytes toward `SWAP_LIMIT_BYTES` (images shared by reference between the object
   and steps where unchanged would be nicer, but counting is simpler and bounded).
10. Render: per-item pipeline choice in `draw_items` (rebinding the sculpt buffers before a textured item's wire
    pass); `blended` checks `textured_see`; `mesh_pipelines_destroy` covers the new ones; frame-key asserts updated;
    `maps` appended last in `Material_Uniforms` (#assert 144); textured.vert writes locations 0-6 (flat 4 and 6);
    TEXTURED drops `Slot_Uniforms`; T flips with N on back faces. textured.frag starts `#version 450`, the include
    extension, then `#define TEXTURED`, then the include.
11. The object's tint survives: the base map is multiplied by tint ÷ material colour per channel (white → tint).
Optional taken: textured items carry no `lod`; `Renderer.anisotropy` set where the device property is chosen;
`texture_view` stays a remembered settings row like the other view toggles (it only changes objects that have maps or
UVs, so a later run starting in it costs nothing elsewhere), and the first bake of a run turns it on; preview maps are downscaled by halves to at most 4096 (2048 on Android) and a
failed `CreateGPUTexture` falls back to clay; thumbnails stay clay (README says so).
