# Phase 7 item 3: glTF and USD export (layers as morph targets)

Roadmap row: "glTF and USD export (layers as morph targets) · N005 · M · Done when opens in Blender". Today Export mesh writes the selected object's shown level as OBJ or PLY (`object_export`, `src/app/files.odin`), with polypaint as vertex colours and a retopologized base level as quads with UVs (OBJ only). Sculpt layers, polygroups and the scene's layout are lost on the way out.

## What exists when this is done

- Export mesh (and `--export`) also takes `.glb` (binary glTF 2.0, one file) and `.usda` (USD, text). The file dialog lists them.
- What goes in, for the selected object's shown level, as today: positions in the file's units (`obj.file` scale and position, as OBJ and PLY), smooth normals, triangles, polypaint as vertex colours (the same blend over white as OBJ/PLY), and each **sculpt layer as a morph target / blend shape**: its displacement at strength 1 on the vertices it moved, named as the layer, with the layer's strength as the default weight (0 when hidden). The base positions are the surface without the layers, so in Blender the shape keys rebuild exactly what the app shows, and each layer's slider is the shape key's value.
  - glTF: one mesh with POSITION, NORMAL, COLOR_0 (unsigned byte, normalized) and `_POLYGROUP` (an application attribute, unsigned short, per vertex as the renderer already carries it; importers that do not know it ignore it); morph targets as **sparse** accessors (only the moved vertices, so a layer over a small patch costs little); `mesh.weights` the strengths and `mesh.extras.targetNames` the names (what Blender's importer reads for shape key names). A retopologized base level exported at level 1 goes as its quads triangulated, with TEXCOORD_0 from its UVs, vertices split along UV seams.
  - USD: a `Mesh` prim with points, faceVertexCounts/Indices (quads for a retopologized base level, with `primvars:st` faceVarying), `primvars:normals`, `primvars:displayColor` (vertex), and layers as `BlendShape` prims (offsets + pointIndices, sparse) bound with `SkelBindingAPI` to a `Skeleton` and a `SkelAnimation` whose `blendShapeWeights` are the strengths: the form Blender's USD importer turns into shape keys. `metersPerUnit` 1, Y up as the app.
- Dynamic topology on: exported as its compact mesh, as today, without layers (dynamic topology bakes them).
- Big meshes: 10M vertices write in a few seconds (glTF is mostly a straight copy of float arrays; USD text is the slow one, written on the worker pool in chunks as the OBJ writer does). The note says the size and time.

## How

- `src/geom/gltf_write.odin`: `mesh_write_glb(out, Mesh_Export)`, where `Mesh_Export` carries positions, normals, indices, optional colours, groups, UV corners and `[]Morph {name, weight, vertices: []u32, deltas: [][3]f32}`. Pure: no sculpt, no render (package rule). The JSON is written by hand (small, fixed shape); the binary chunk holds the buffers, 4-byte aligned; accessors carry min/max for POSITION as the spec requires.
- `src/geom/usd_write.odin`: `mesh_write_usda(out, Mesh_Export, pool)`, numbers with `%g`-style shortest round-trip floats.
- `src/sculpt`: `sculptor_layer_sparse(s, index) -> (vertices: []u32, deltas: [][3]f32)` (the node-owned ranges flattened; temp allocator); smooth normals come from the sculptor's.
- `src/app/files.odin`: `object_export` gathers a `Mesh_Export` and picks the writer by extension; the file dialog's filters gain the two.
- No change to the scene file, the History, the renderer or a shader.

## Verification

- geom tests: a tiny mesh's .glb parses back (a test-side minimal reader: header, JSON chunk, BIN chunk, accessor counts and bounds); a sparse morph target's indices and values round-trip; USD text of a two-triangle mesh matches a golden string.
- `scripts/export_check.py` (new, used by touch_check's export scenario and by hand): runs the Khronos glTF validator when `npx gltf-validator` is available, `usdchecker` from usd-core when installed, and Blender itself through `bpy` (pip wheel, Python 3.13) when installed: imports the file and prints vertices, faces, shape key names and values, and colour attribute presence; compares against the app's exit stats. Each tool missing is reported as skipped, never as passed.
- touch_check scenario: a sphere with two layers (one hidden) and paint exported as .glb and .usda; the check script reads both.

## Split

- **7.3a** glTF: `gltf_write.odin`, `sculptor_layer_sparse`, export by extension, tests, `export_check.py` with the validator and Blender import, README.
- **7.3b** USD: `usd_write.odin` with blend shapes, usdchecker and Blender import, README.
- **7.3c** (if wanted) whole-scene export: every shown object as a node with its transform, folders as parent nodes.

## Not in this item

Textures (bake writes PNGs already; linking them as a material is a later step), animation, importing glTF/USD.

## Prototype findings (2026-10-26, before review)

Hand-made files checked with the real tools in the scratchpad (bpy 5.2.3 LTS from pip, usd-core 26.11, Khronos gltf-validator 2.0.0-dev.3.10 from npm):
- glTF: a mesh with POSITION, NORMAL, COLOR_0 (normalized ubyte VEC4), u32 indices and one **sparse** POSITION morph target, `weights` and `extras.targetNames`: validator 0 errors 0 warnings; Blender imports it with shape keys "Basis" and "Layer 1" at 0.7 and the colour attribute (it turns Y up into Z up).
- USD: SkelRoot > Mesh (SkelBindingAPI, skel:blendShapes, blendShapeTargets, skel:skeleton) with a BlendShape child (offsets + pointIndices), and a Skeleton with no joints whose SkelAnimation names the shape: the 30 UsdValidation validators report nothing; Blender imports the shape key but **ignores a default `blendShapeWeights`**: only a time sample sets it (it makes an action keyed at frame 1, value 0.7). So the writer gives the weights both as the default and as one time sample at frame 1.

## Architect review (2026-10-26), adopted

Must (all adopted):
1. Polypaint is sRGB: converted to linear after the blend over white. glTF `COLOR_0` VEC4 unsigned short normalized (export_check confirms Blender reads it; else VEC4 ubyte); USD displayColor linear.
2. Layer deltas are multiplied by `obj.file.scale` only, never offset.
3. Every glTF vertex attribute 4-byte aligned (`COLOR_0` VEC4); UNSIGNED_INT only for indices.
4. A layer that moved nothing is an all-zero accessor (no bufferView, no sparse). Every morph POSITION accessor has min/max including 0 when the layer misses a vertex, written with `format_f32`.
5. Layer names repaired to valid UTF-8 and JSON-escaped (glTF); USD identifiers sanitised and de-duplicated.
6. Import and export dialogs get separate filters; the suffix by filter index learns the new cases.
7. A `.glb` over 4 GB is refused with a note.
8. USD `uniform token subdivisionScheme = "none"`.
9. Strengths outside 0–1: **verified in Blender 5.2.3**: a glTF weight of 1.5 or −0.5 imports as the shape key's value with `slider_max`/`slider_min` widened, and the evaluated mesh is right (v2 at 1.5 → (1, −0.75, 1); at −0.5 → (1, 0.25, 1)). No pre-scaling is needed.

Should (adopted): `_POLYGROUP` and quads/UVs cut from glTF (USD only, 7.3b: polygroups as `int[] primvars:polygroup` uniform); `sculptor_layer_sparse` takes an allocator, skips exact zeros and gathers one layer at a time; export first ends the stroke and inspector drags and refreshes normals; "rebuild exactly" means to f32 rounding, compared with a tolerance; README says USD weights become an action in Blender; export uses the save's "show first" note pattern for big meshes; export_check stays out of the gate's pass/fail (skips reported).

Could (later): true strength and visibility in extras, node named after the object, transform on the node, morph normals, dense targets for layers covering most vertices.
