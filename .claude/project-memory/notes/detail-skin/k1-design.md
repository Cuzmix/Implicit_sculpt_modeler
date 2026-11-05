# Detail skin, stage K1: design

Status: draft for architect review, 2026-11-02. Nothing is built. Plan and mock: https://claude.ai/artifact/3nZFyTfjSBHtTc4HJGV1K4.
Bolt picked "cheaper sculpting": sculpt finer detail than the mesh holds, without paying for polygons, then Apply it as polygons.

## What exists after K1
- Object palette, Subdivision section: **Detail skin** (Off, 2, 4, 8 or 16 segments). The row shows what it looks like: "1.0M triangles → looks like 16.4M".
  The section also has **Apply** (turns the skin into subdivision levels) and **Remove**.
- With a skin on, Draw, Clay, Crease, Smooth, Flatten, Inflate and Layer, with or without an alpha, write heights into the skin instead of moving vertices.
  Grab, Snake hook, Pinch, Move, Pose, Cloth, Morph, History, Mask and Paint keep working on the mesh, and the skin rides along on it.
  The brush ring shows a small "skin" mark while a stroke goes to the skin.
- The viewport shades every pixel with the skin's normal. The silhouette stays the mesh's (K5 adds real edges near the camera).
- Undo, symmetry (mirror and radial), mask, hide, Front faces only, Connected and stroke replay all work as they do on vertices.
- Scene files keep the skin. Older apps open the file without it.

## Prototype numbers (scratch bench, one thread, same dab on both sides; noise about 15%)
| case | samples or vertices | memory MB | ms a dab | upload KB a dab |
|---|---|---|---|---|
| skin: ico 6 (82k tris), 4 segments | 1.23M samples | 11 | 0.89 | 51 |
| polygons: ico 8, same micro triangles | 0.66M vertices | 66 | 1.43 | 104 |
| skin: ico 6, 8 segments | 3.69M samples | 26 | 2.52 | 154 |
| polygons: ico 9 | 2.6M vertices | 262 | 8.34 | 407 |
| skin: ico 7 (328k tris), 8 segments | 14.7M samples | 105 | 13.6 | 590 |
| polygons: ico 10 | 10.5M vertices | 1049 | 36.5 | 1609 |
The prototype duplicated edge samples per triangle, which costs about 2× the samples. K1 stores them once (below), so the skin side should improve further.
The polygon side is naive single-thread code, not our engine. The ratio is the signal, not the milliseconds.

## Representation (src/sculpt/skin.odin, new)
- `Skin{segments: u8 (S = 2, 4, 8, 16), heights: []f16, normals: []u32 (oct, what the GPU reads), edge_of: [][3]u32 (per triangle: edge id << 1 | reversed), ...}` on `Sculptor.skin ^Skin` (nil none).
- Samples sit on a barycentric grid of S segments per triangle edge: point = flat point + height × normalize(Phong-interpolated vertex normal).
  A sample at a mesh vertex is stored once per vertex, a sample inside an edge once per edge (S − 1 of them), and a face-interior one once per triangle ((S − 1)(S − 2) / 2).
  Neighbouring triangles read the same edge and vertex samples, so the skin is watertight by construction, with no seam pass.
- Layout: vertex samples [0, V), edge samples [V, V + E·(S−1)), face samples after. The edges are numbered so that each node's owned edges are contiguous, and the node that owns an edge's lower-numbered vertex owns the edge.
  Each node owns its vertices' samples (the existing owner rule), its owned edges' samples and its triangles' face samples, so parallel jobs per node never write the same sample. This is the same discipline as vertices.
- Memory: 2 B height + 4 B normal a sample. 1M triangles at 8 segments ≈ 1M·(1 + 1.5·7 + 21) ≈ 32.5M samples ≈ 195 MB. The same look as polygons is about 3.2 GB.

## Brushes
- `dab_once` runs as today up to `job_area` (so Clay and Flatten get `d.normal`/`d.plane`, alphas get `alpha_frame`). With `Brush.skin` set and a skin kind, it calls `skin_dab(s, d, img)` instead of the kind's `job_*`.
- `skin_dab` runs per node over the leaves in reach: for each owned sample in reach, weight = `dab_weight` at the sample's point × shield interpolated from the triangle corners (HD fade, mask, hide). The height changes per kind:
  - Draw/Inflate: += radius·strength·DRAW_HEIGHT·w along the sample normal.
  - Clay: toward the plane `CLAY_HEIGHT` radii up, capped.
  - Flatten: toward the plane.
  - Crease: −, with the narrow falloff.
  - Layer: toward the stroke's height (per-sample stroke heights live in a lazily made `layer` array, as `Sculptor.layer` does).
  - Smooth: a Jacobi step on heights, with targets then apply as `job_smooth_targets`.
  The heights are signed distances along the surface normal, so Pinch-like sideways moves are not possible. That is why Pinch stays a mesh brush.
- Symmetry: each `Sym_Image` is its own pass, as today. Random numbers come from the stroke seed only, as today.
- Normals: `skin_dab` marks touched triangles. The flush recomputes the normals of samples in touched triangles and their neighbours' rims in parallel per node, then returns sample ranges to upload. Any node whose vertices moved (apply_dab, nodes_moved, undo, levels sync) marks its triangles' samples stale, because the base moved under them.
- App: `Brush.skin = object has a skin && kind in SKIN_KINDS`, set in `brush_at`. In K1, Grab under Shift's smoothing stays on the mesh. K2's split by size replaces this rule.

## Drawing
- New storage buffer per mesh: sample normals (u32 a sample), plus `edge_of` per triangle (3 × u32). Uploaded by sample range like vertex ranges.
- The mesh pipeline gets a `skinned` variant (like `textured`). The fragment shader needs the triangle id and barycentrics:
  - triangle id = draw's first triangle (passed through `firstInstance` → `gl_InstanceIndex` → flat varying) + `gl_PrimitiveID`.
  - Barycentrics come from the three corner positions fetched by triangle id (positions bound as storage) and the interpolated view-space position. That works on every backend, and the fragment-barycentric extension can be an optimisation later.
  - Find the micro triangle from bary·S, fetch its three sample normals (vertex, edge or face sample by the index rule above, edge direction from `edge_of`), interpolate, and shade with that normal in object space turned to view space.
- Simplified copies (LOD) are off for skinned objects in K1. The mesh under a skin is meant to be light.
- Rendered (path traced) and Studio show the mesh's own normals in K1. The README says so, and K5 adds the skin there.
- Questions for review: does every draw path (indirect chunks, hidden-index pages, idle cache) keep triangle ids equal to mesh triangle order with a known first triangle per draw? Is a 9th storage buffer in the fragment stage within limits on Mali-G710 and Metal?

## Undo
- `Saved_Node.skin []f16`: the node's owned samples, saved on first touch by `record_hit` when the stroke is a skin stroke (2 B a sample). Undo and redo swap them in `step_move`, mark normals stale and re-upload.
- Turning the skin on or off, changing segments, Remove and Apply are each one step. On, off, segments and Remove are a sculptor step with `skin_op` holding the old skin, like `layer_op`. Apply is a swap undo entry (`history_snapshot` / `history_record_swap`), since it adds levels.

## Files
- A new field at the end of the `OBJ ` chunk, read only where the chunk has bytes left (the scene rule), never inside the levels payload. Inside the payload, an older reader would misread the fields after it.
  Contents: segments, then heights as f16 in canonical order: vertex samples by canon vertex, edge samples by canon edge (lower canon vertex first), face samples by canon triangle starting at its lowest canon corner, keeping winding.
- Damaged or mismatched counts drop the skin with a note and never assert. Autosave reads it through `levels_write`'s guard, so the writer checks `w.abort` per node.

## What happens to other features while a skin exists (K1)
| Feature | K1 rule |
|---|---|
| Dynamic topology, HD | Refused with a note. HD and the skin do the same job, so if the skin measures well, HD is the candidate to retire. |
| Subdivide, Delete higher/lower | Refused with "Apply or remove the skin first". The skin belongs to the top level. Sculpting a lower level is allowed, and the skin rides on the top. |
| Remesh, Decimate, Quad Remesh, Rebuild, booleans, Convert to voxels, Mirror and weld | The skin is dropped with a note (rebuilds already drop levels, mask and strokes). K2's Squeeze adds carrying it by ray. |
| Sculpt layers | Skin strokes don't go into layers in K1. While a layer records, skin kinds are refused with a note. |
| Polypaint, mask | Stay per vertex. Skin samples read the mask interpolated from the corners. |
| Export (OBJ, PLY, STL, 3MF, glTF) | Writes the mesh, with a note to Apply first. K3 exports maps. |
| Stroke replay, History brush | Replay is exact (CPU, seeded). The History brush moves the mesh only. |

## Apply
- With S = 2^k: `levels_subdivide` k times (refused past MAX_LEVELS, as today), then set the new top level's positions to the sample points through `sculptor_nodes_moved`, then drop the skin. Every Loop child vertex maps to one sample: base vertices to vertex samples, and edge midpoints at each step to edge or face samples by their barycentric place.
- Question for review: is the `parents`/`even_of` numbering enough to find each child vertex's barycentric place without a search?

## Tests
- `skin_parallel_matches_serial` (every skin kind, bit for bit), `skin_is_watertight` (each shared sample's point is identical computed from either triangle), `skin_undo_restores`, `skin_file_round_trip` (and an older reader stepping over it), `skin_apply_matches_samples` (mesh_check and positions), `flat_skin_shades_like_the_mesh` (zero heights give the Phong normals within one oct step), `skin_symmetric_dabs_mirror`.
- `bench --skin` rows (4 threads): ms a dab and a frame, memory and upload, against the same detail as levels. `gpubench` frame times on the 3060 Ti, the iPad and the OnePlus Pad before K2 starts.

## Out of K1
Split by size (K2), Squeeze and carrying the skin through rebuilds (K2), game maps (K3), tiles and maps in (K4), real edges near the camera and in renders (K5), colour in the skin (shared texel store with the Surface plan), sideways offsets (vector skin).

## Architect review (2026-11-02) and what changed
The review is read-only and cites the code. Its MUSTs are taken in full:
1. **Triangle id by vertex pulling.** The skinned variant draws non-indexed with triangle = gl_VertexIndex / 3. It reads indices and positions from storage buffers, and the existing 20-byte commands are read as {count, 1, first, 0} with a 20-byte stride.
   This needs no firstInstance (optional and untracked today), no PrimitiveID (needs geometryShader, never enabled) and no position reconstruction, and the barycentrics come out exact.
   It means 4 storage buffers in the vertex stage and 2 in the fragment stage. Positions and indices get GRAPHICS_STORAGE_READ, and both backends get new hal procs with committed .spv and .msl.
   The shader works in GPU corner order (polygroups rotate the corners, groups.odin:331-343), and an edge's direction comes from comparing vertex ids.
2. **Edges belong to the node of their lower triangle**, as HD numbers them (hd.odin:769-786). Triangles are contiguous per node, so each node's edges are too. The vertex-owner rule was wrong: that node's leaf may not cover the edge, so a dab would miss samples.
3. **Apply builds each new level from the samples** (nested subsets at S/2, S/4, …), encodes detail bottom-up, never pushes down and clears `edited`. The old levels must stay bit-identical, which a test checks. `tri_from` is passed to `sculptor_init` while Apply builds, so each child triangle's grid place is O(1).
4. **Skin dabs put their nodes in dirty_nodes**, so damage boxes cover them. A test checks that partial redraw equals --no-partial to the pixel.
5. **The file field is guarded** by `version >= SCENE_CHUNKED && bytes left`. It is written in object_put_bytes after levels_write (so Duplicate, Paste, swap undo and autosave carry it), the writer lives in sculpt (canon orders), it checks abort, and it is counted in object_put_estimate.
6. Normal staleness after a vertex move comes from the nodes whose normals the flush recomputed, not only the moved nodes.

SHOULDs taken:
- Undo and skin_op keep heights only and recompute normals.
- A skin is refused on open or non-manifold meshes, because Apply can't subdivide them.
- Apply is pre-checked against MAX_SUBDIVIDE_BYTES (S = 16 on 1M triangles is 256M).
- Skin normals refresh at the end of Grab and Pose strokes, not every frame.
- Gpu_Caps records firstInstance.
- While a lower level is current, Brush.skin is false and the skin isn't drawn.

PR series (each passes gate --changed; the last runs the full gate):
- P1 skin.odin: layout, edges, points, normals (watertight and flat-normal tests).
- P2 dabs and undo.
- P3 render: hal procs, skinned pipeline, uploads.
- P4 app: palette, commands, refusals, README.
- P5 file field.
- P6 Apply.
- P7 bench --skin and gpubench rows.

## After Bolt's hybrid and VDM ask (2026-11-02)
The full plan (stages K1 to K6: hybrid routing, vector pages and VDM, Squeeze, maps, real edges) is the doc https://claude.ai/artifact/8HFKdC1pNjc5Ynh6pGHagf.
One K1 change: a sample's normal is the interpolated normal plus the area-weighted mean, over the small triangles at the sample, of the raised small triangle's unit normal minus the flat one's. It equals the gradient form to first order, gives the mesh normal exactly for flat skins and for an evenly raised skin, stays bounded on steep slopes, and works unchanged for sideways offsets (K3's vector pages).
