# Import: several meshes a file, glTF, FBX and USD

Bolt, 2026-10-29: "when importing a mesh object that has vertex color, the color doesn't show" (fixed by #308 for OBJ and
PLY) and "we should also allow the importing of GLTF files, USD files, and FBX also". Defaults announced in the thread:
a file of several meshes becomes several objects in a folder; ufbx for FBX after a comparison; an own USD reader in Odin;
texture / material colour into polypaint as the last PR.

## What exists (cited at odin-sculpt dae4be9)
- `scene_import` (src/app/files.odin) → `mesh_import_read` → `mesh_file_parse(data, kind, pool, colors)` → one
  `geom.Mesh` (+ vertex colours since #308) → `mesh_clean` → `mesh_normalize` (centre + radius 1, `Object.file` keeps
  `{center, radius}` for export) → `mesh_edges` and flip when closed and inward → `scene_add_mesh(..., surface)` →
  `history_record_added`. Pack meshes (`pack_mesh.odin`) share `mesh_import_read`.
- `geom.mesh_split(m, part, count)` (src/geom/split.odin) splits a mesh by a part number per triangle, with
  `vertex_from`/`tri_from`, serial and deterministic.
- Folders: `folder_new` and `history_record_arrange(before = layout_take(app))` (scene_tree.odin); chained adds as
  Duplicate does (`history_record_swap(..., chain = k > 0)`, scene.odin:913).
- Writers to mirror: `gltf_write.odin` (Y up, colours linear u16), `usd_write.odin` (displayColor linear, upAxis Y).
- `src/zip` reads ZIP entries (stored and deflated); `core:encoding/json` parses JSON.

## How the other apps do it (best of all worlds)
| | multi-mesh | transforms | colours | groups |
|---|---|---|---|---|
| ZBrush (OBJ, FBX ExportImport, GoZ) | OBJ: one subtool; FBX: one subtool each | baked | OBJ `#MRGB`, FBX vertex colour | OBJ `g` → polygroups, FBX materials → polygroups |
| Nomad | one object each, hierarchy kept | kept as object transforms | vertex colours, textures baked to paint optional | materials |
| Blender | one object each, hierarchy kept | kept | colour attributes | material slots |
| 3DCoat / Mudbox | one layer/mesh each | baked | vertex colours, texture to paint on import | |

Taken: one object a mesh, all in a folder named after the file (Nomad/Blender, fits ZBrush-iPad's Subtools list);
transforms baked into the vertices (ZBrush: our objects are similarities only, and files carry non-uniform scale, shear
and mirrors); material / `g` / primitive splits become polygroups (ZBrush), so they survive as selectable parts;
vertex colours as polypaint everywhere; texture → polypaint as an optional last step (3DCoat, ZBrush's
"Polypaint from texture"). Avoided: ZBrush's merge-everything OBJ import (eyes and teeth stuck to the head), Blender's
one-unit-per-file scale surprise (we size the whole file to radius 1 as today, keeping relative sizes).

## Design
### geom: a file of parts
```odin
// One mesh of a file: triangles in the file's units with its node transforms applied, Y up, normals zero.
Mesh_Part :: struct {
	name:   string,                  // owned; "" for none
	mesh:   Mesh,
	colors: [dynamic]Vertex_Color,   // one a vertex, or empty
	groups: [dynamic]u16,            // one a triangle, or empty: OBJ g, a glTF primitive, an FBX/USD material
}
mesh_parts_destroy :: proc(parts: ^[dynamic]Mesh_Part)
```
- `mesh_clean(m, pool, colors, groups)` grows `groups: ^[dynamic]u16`: the kept triangles keep theirs (in place, in
  order, like the indices).
- OBJ: `job_obj_chunk` also notes `o` and `g` lines as (triangle index, name) events per chunk; the join numbers
  objects and groups in file order (names deduplicated by a sorted pass, no map order). One object and no groups: the
  path is today's. Several objects: `mesh_split` by object, colours and groups follow `vertex_from`/`tri_from`.
- glTF (`geom/gltf_read.odin`): `mesh_read_gltf(data, resolve, pool) -> (parts, err, why)`, `.glb` or `.gltf` JSON with
  `data:` URIs, or external buffers through `resolve(uri) -> ([]u8, ok)` (the app reads files beside it; geom stays
  without IO). Default scene's node tree (all root nodes when no scene), matrix or TRS, a part per mesh instance;
  triangles (mode 4, 5 and 6 fanned/stripped; points and lines skipped), POSITION (float, or normalized/plain ints of
  KHR_mesh_quantization), indices (u8/u16/u32), COLOR_0 (float, u8, u16 normalized, VEC3/VEC4; linear → sRGB), sparse
  accessors. A primitive per material → its group. `KHR_draco_mesh_compression` / `EXT_meshopt_compression` primitives
  are skipped and counted (named in the note); a negative-determinant node reverses winding.
- Units and axes: glTF is already the app's Y up. Everything is sized to radius 1 as now, so units only reach
  `Object.file`, which keeps each part's place in the file for export.

### fbx: ufbx behind a small C shim (new package `src/fbx`)
Compared (details in the thread's report):
| | licence | size | formats | maintained | mobile | verdict |
|---|---|---|---|---|---|---|
| ufbx 0.23.1 | MIT or public domain | 1 C file (33k lines) | binary 6100–7700, ASCII, 3.0 | yes, Blender 4.5's importer | C99, no deps | **chosen** |
| OpenFBX | MIT | C++ (~4k lines) + miniz | binary 7.x only, no ASCII | yes (Lumix) | C++ | weaker on pivots, versions |
| Assimp | BSD-3 | huge C++ | many | yes | heavy | too big for a tablet build |
| Autodesk FBX SDK | proprietary EULA | closed binaries | all | yes | no Android arm64 build we can ship | licence blocks store |
| own Odin reader | ours | ~1k lines | binary + ASCII | us | yes | pivots, geometric transforms, versions are where readers fail; ufbx has 10 years of test files |
- `src/fbx/fbx_shim.c` (ours, C99): `sculpt_fbx_load(data, size, error, error_size) -> scene*` with
  `target_axes = right_handed_y_up`, `target_unit_meters`, `geometry_transform_handling = modify_geometry`;
  `sculpt_fbx_parts(scene) -> u32`, `sculpt_fbx_part_size(scene, i, &vertices, &triangles, &has_color)`,
  `sculpt_fbx_part_fill(scene, i, positions, indices, colors, groups)` (world positions via
  `node->geometry_to_world`, `ufbx_triangulate_face`, a corner colour averaged per vertex, material index → group,
  winding reversed for a mirrored node), `sculpt_fbx_free`. Only the shim includes ufbx.h; Odin binds five procs.
- Build: `scripts/build_ufbx.py` (setup_deps runs it, like build_luau.py) clones `UFBX_TAG=v0.23.1` into
  `deps/ufbx-src` and builds `deps/ufbx/libufbx.a` / `ufbx.lib` from ufbx.c + the shim; Android's CMakeLists adds both
  .c files as a static library (as stb); `./build.sh ios` compiles both; `fbx.AVAILABLE` is true everywhere.
- Licence: assets/licenses/ufbx-LICENSE.txt and the About > Licences row (sm-store).

### usd: own reader (new package `src/usd`)
- `.usda` text: a tokenizer and a tolerant parser of prims (`def`/`over`; `class` skipped), properties with values
  (arrays of numbers and tuples, tokens, matrices), `.timeSamples` (first sample when no default), metadata blocks
  skipped by bracket balance; variant sets, references and payloads not followed (counted for the note).
- `.usdc` crate: header and TOC, TOKENS (TfFastCompression = LZ4 blocks), STRINGS, FIELDS, FIELDSETS, PATHS, SPECS with
  USD's integer coding, ValueReps (inline, array, compressed int/float arrays). Only the types the mesh needs are
  decoded: token, token[], int[], float/double vec3 arrays, color3f[], matrix4d, double3/float3, quatf, string; other
  values are skipped by their rep. LZ4 block decoding in Odin (~60 lines).
- `.usdz`: `src/zip`, the first `.usda`/`.usdc` entry is the root layer.
- Meshes: `Mesh` prims' `points`, `faceVertexCounts`, `faceVertexIndices` (fans), `orientation` (leftHanded reverses),
  `primvars:displayColor` (constant, uniform, vertex/varying, faceVarying → averaged per vertex; linear → sRGB),
  `GeomSubset`s of familyName `materialBind` → groups; `xformOpOrder` with translate, scale, rotate{X,Y,Z,XYZ…},
  orient, transform, `!invert!`, `!resetXformStack!`; stage `upAxis = "Z"` turns Z up into Y up; `metersPerUnit` only
  into `Object.file`.

### app: one import path for every format
- `Mesh_Kind` grows `GLTF`, `FBX`, `USD` (extension, or the bytes for content://: `glTF`, `{` with `"asset"`,
  `Kaydara FBX Binary`, `; FBX`, `PXR-USDC`, `#usda`, `PK` with a `.usd?` entry). Dialog filters add them.
- `mesh_import_read` returns `Mesh_Import{parts: []Import_Part{mesh, colors, groups, name, file: Transform}, ...}`.
  Each part is cleaned; the whole file is sized to radius 1 around its combined centre (the existing origin rule),
  then each part is recentred on its own bounds centre so it turns about itself; `Import_Part.file` keeps
  `{center + radius * c_k, radius}`, so an export of any part lines up with the file.
- `scene_import`: one part → today's object. Several → objects in file order at `next_free_position` + their offsets,
  in a new folder named after the file; one undo step: the adds chained (`history_record_swap(chain = k > 0)`), the
  folder an Arrange step chained after them. Polygroups come through `Surface.groups`. A pack mesh takes the same path.
- The note: "Imported robot.glb: 6 objects in a folder, 1.2M vertices…; 2 Draco-compressed meshes skipped".
- Limits: an empty or point-only file says so; a part over 32-bit indices refuses the file (as now).

### Tests and checks
- geom: OBJ `o`/`g` splitting serial = parallel; glTF reader on hand-made glb/gltf (TRS, matrix, sparse, quantized,
  colours u8/u16/float, strip/fan, mirrored node, Draco skip); `mesh_clean` keeps groups.
- glTF round trip: `mesh_write_glb` → `mesh_read_gltf` gives the same positions, colours (within sRGB↔linear
  rounding) and triangles.
- usd: usda and usdc of the same mesh (usdc written by usd-core in `build/export-tools`, committed as test data under
  `src/usd/testdata/`), round trip through `mesh_write_usda`; LZ4 and integer coding against known vectors.
- fbx: a binary and an ASCII file from Blender (export_check's Blender) committed under `src/fbx/testdata/`.
- App: `--import=file.glb --frames=30 --dump-viewport` described; `--check-mesh` per object; scene tree objects=N.

### PR order
1. #308 vertex colours (merged).
2. Parts: `Mesh_Part`, groups through `mesh_clean`, OBJ `o`/`g`, multi-object import into a folder, one undo step.
3. glTF import.
4. FBX import (ufbx, build plumbing on four platforms, licence).
5. USD import (usda, usdc, usdz).
6. Base colour texture / material colour → polypaint (glTF, FBX, USD, OBJ+MTL), UVs read as parts' corner UVs.

### Risks
- ufbx on Android/iOS is untested here (no NDK/Mac): CMake and build.sh ios lines follow stb's; androidcheck and
  iphonecheck compile only the Odin side.
- USD composition (references, payloads, variants, instancing) is not followed: such files import what the root layer
  defines and the note says what was skipped.
- Importing many parts makes many objects: a file of 500 meshes → 500 objects (folder keeps it tidy; no cap).
