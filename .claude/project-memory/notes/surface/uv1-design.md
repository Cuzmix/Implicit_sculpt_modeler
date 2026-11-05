# UV1 design (architect review, 2026-11-03)

- Package `uv` (imports core: and geom): `Uvs{corner [][3][2]f32 per base triangle (v up), seam []bit_set[0..<3;u8] symmetric, island []u32, islands, pins []u32 sorted vertices, filled}`.
- Kept on `sculpt.Levels.uvs` beside `faces` (Quad_Faces keeps only quads); follows the base level's current triangle order; corner order inside a triangle survives sculptor_init's renumbering (brush.odin copies whole triangles), so imports index through tri_from.
- Quad readers (bake, tangents, split UVs, textured preview, OBJ/glb/USD export) read a derived `geom.Uv_Layout` view: `uv.to_quads` (first half holding a quad corner wins; chart = island of half 0). Skin map and Groups by UVs read the store directly. Fold: `uv.from_quads` keeps chart ids as islands so the view is bit-equal (tested).
- File: LEVELS_UVS flag section after quads: u8 has, u32 triangles, corners, seams, islands, u32 islands, f32 filled, u32 pins + pins; read through tri_from/file_order; damage -> false; SCENE_VERSION +1, old bytes not read.
- Triangle imports keep their UVs (`uv.from_corners`); quad_uvs_from_corners deleted. Triangle-only objects with UVs: Groups by UVs works; bake, textures, skin map refuse politely ("needs quads with UVs"); triangle OBJ/glb export without UVs until UV5.
- `.Textures` Texture_Step holds `uv.Uvs`.
- Split: UV1a = package + tests + lists (PR); UV1b = objects on the store.
- Defaults taken: export of triangle UVs waits for UV5; pins as a vertex list; no size cap on imported UVs.
