# Voxel sculpting: design for the first vertical slice

Date 2026-10-27. Research: `voxel-research.md` (same folder). Target branch: `odin-sculpt`.

## 1. Request
Add voxel (volume) sculpting as a first-class object type and sculpting mode next to the triangle-mesh
sculptor: create a voxel sculpt, add and subtract clay with brush strokes, smooth and flatten, see the
surface update incrementally, undo and redo per stroke, save and reopen it in `.sculpt`, and convert it to
a mesh object when detail work begins. It is not a replacement for the mesh sculptor, not a ray-marched
renderer, and not adaptive resolution.

## 2. Current state (verified against odin-sculpt be6c7ba)
- Mesh objects: `Object{levels: sculpt.Levels, gpu: [MAX_LEVELS]render.Mesh_Buffers, ...}` (`src/app/scene.odin:50-70`);
  everything reaches the mesh through `object_sculptor`/`object_mesh`/`object_level` (206 call sites in `src/app`).
- Strokes: `sculpt_frame` → `stroke_follow` → `stroke_start`/`stroke_walk` → `stroke_dab` (raycast then
  `sculpt.apply_dab`) (`src/app/sculpt_tool.odin:194-760`); `brush_stroke_finish` records a `History_Entry`
  when `sculptor_stroke_end` says the stroke changed something (`src/app/history.odin:200-224`).
- Undo across objects: `history_step` takes `can`/`step` procs over `^sculpt.Sculptor` through
  `entry_sculptor` (`history.odin:522-584`); whole-object changes are swap entries holding `object_put` bytes.
- Frame loop: per object and part, `sculptor_flush` → `level_upload` (ranges, index pages, regrow) → one
  `Draw_Item{chunks, chunk_groups, damage, lod, hidden}` (`src/app/main.odin:625-690`); `prepare_draws`
  culls `chunks` sorted by `first_index` into indirect draws (`src/render/renderer.odin:979-1052`), a nil
  `lod`/`hidden`/`chunk_groups` is fine.
- Render: `mesh_buffers_create(r, mesh, mask)` sizes buffers to the mesh's arrays; `mesh_buffers_upload_ranges`
  (vertices with the mask) and `mesh_buffers_upload_indices` (index ranges, asserted inside `index_count`);
  dyntopo already draws a slotted layout whose unused triangles are zero (`src/sculpt/dyntopo.odin:19-34`,
  `level_upload` recreates buffers when the arrays outgrow them, `scene.odin:489-510`).
- Files: `object_put_bytes` writes id, name, transforms, boolean, view bits, folder, then `levels_write`
  (`src/app/files.odin:779-795`); `SCENE_VERSION` is 10.
- Existing SDF code: the spike `src/sdf_trial` (dense f32 grid, 16³ chunks, surface nets); `geom.remesh`'s
  manifold marching-cubes table and ray-crossing voxelizer (`src/geom/remesh.odin`).
- Baseline numbers on this VM (4 threads): mesh bench 1M large-brush frame 0.32 ms (5M: 1.12 ms); dense spike
  256³: dab 0.40 ms + serial chunk remesh 4.6 ms p50 (39 chunks a dab), 64 MB; 512³: 3.1 + 22.9 ms, 512 MB.

## 3. Design

### 3.1 Package `src/voxel` (new; imports `core:`, `../geom`, `../jobs` only)
Representation: a narrow-band signed distance field in 8³ bricks of `i16`, fixed point `SCALE = 4096` units a
voxel, negative inside, clamped to ±`CLAMP = 4` voxels (band half-width `BAND = 3`, one voxel of slack for
interpolation), sparse: a brick exists only where the band passes; elsewhere a tile code says Empty (outside) or
Inside. Why: every production voxel sculptor with public internals uses this (Medium 8³ ±2, Dreams 8³ fp16,
OpenVDB 8³ leaves, band 3); memory follows surface area (about 2 B a band voxel); 16-bit keeps vertex placement
and shading smooth where 8-bit bands.

```odin
BRICK :: 8                   // voxels along a brick's edge
NODE_BRICKS :: 2             // bricks along a node's edge: a node is 16³ voxels, the unit meshed and uploaded
CHUNK_BRICKS :: 16           // bricks along a chunk's edge: a chunk is 128³ voxels, the unit of the directory
MAX_CHUNKS :: 32             // chunks along the domain's edge: 4096 voxels, DynaMesh's top lattice
SCALE :: 4096                // fixed-point units a voxel
BAND :: 3                    // voxels either side of the surface that hold true distances
CLAMP :: (BAND + 1) * SCALE  // values are kept within ±CLAMP

Tile :: enum u8 {Empty, Inside, Brick}
Brick :: struct { d: [BRICK * BRICK * BRICK]i16 }           // x fastest, then y, then z

// The directory: a fixed table of chunks over the domain, each chunk a table of brick
// slots and node indices, made the first time anything in it is not Empty.
Chunk_Table :: struct {
	bricks: [CHUNK_BRICKS * CHUNK_BRICKS * CHUNK_BRICKS]u32, // TILE_EMPTY, TILE_INSIDE or a brick pool index
	nodes:  [(CHUNK_BRICKS / NODE_BRICKS) * ... ]u32,         // NODE_NONE or a node index (meshing side)
}
Volume :: struct {
	voxel:     f32,     // a voxel's size in the object's space
	origin:    Vec3,    // the object-space centre of voxel (0, 0, 0)
	chunks:    []u32,   // MAX_CHUNKS³: table index + 1, 0 for an all-Empty chunk never touched
	tables:    [dynamic]^Chunk_Table,
	bricks:    [dynamic]Brick,      // the pool; freed slots on `free`
	coords:    [dynamic][3]i32,     // per pool slot: its brick coordinate (BRICK_FREE when free)
	free:      [dynamic]u32,
	allocator: runtime.Allocator,
}
```
Procs: `volume_init(v, voxel, centre, allocator)`, `volume_destroy`, `volume_tile(v, bc) -> (Tile, ^Brick)`,
`volume_brick_make(v, bc, fill: i16) -> ^Brick` (fills from the tile it replaces), `volume_brick_collapse(v, bc, Tile)`,
`volume_sample(v, p) -> f32` (trilinear, voxel units), `volume_gradient(v, p) -> Vec3`, `volume_raycast(v, origin,
dir) -> (hit, normal, ok)` (steps brick by brick over Empty tiles, sphere-traces inside bricks, bisects the crossing),
`volume_bounds(v) -> geom.Aabb` (allocated bricks), `volume_fill_sphere(v, centre, radius)` (the first primitive).
Domain: 4096 voxels a side centred on `centre`; a dab reaching outside is clamped to the domain and a warning is
logged once per stroke (the Res- path shrinks later).

### 3.2 Brushes (`src/voxel/brush.odin`)
```odin
Brush_Kind :: enum u8 {Add, Subtract, Smooth, Flatten, Inflate}
Brush :: struct {
	kind:     Brush_Kind,
	radius:   f32,  // object space
	strength: f32,  // 0..1
	invert:   bool, // Add ↔ Subtract, Flatten clips ↔ fills, Inflate ↔ deflate
	normal:   Vec3, // the surface normal under the pointer (volume_gradient at the hit), unit
}
```
Operators, all on fixed-point values in voxel units, per voxel inside the brush's box:
- Add: smooth union with a stamp sphere whose cap protrudes `h = radius · strength · ADD_HEIGHT` above the surface and
  whose footprint is the brush radius: `R = (r² + h²) / 2h`, centre `hit − n (R − h)`; `d' = smin(d, d_stamp, k)` with
  `k = 0.25 r` (Quilez quadratic). The stamp's own values fill the new band exactly, so a dab may add more than a
  voxel of clay without corrupting the band (Medium's stamps).
- Subtract: the mirror image, `d' = −smin(−d, −d_stamp, k)` with the stamp centred `hit + n (R − h)`.
- Smooth: 3³ box mean of the field, blended by `strength · falloff(d² / r²)`: `d' = lerp(d, mean, w)`. Two passes
  (compute into per-brick scratch reading neighbours, barrier, commit) so no job reads a brick another writes.
- Flatten: `plane = (hit, n)`; clip: `d' = lerp(d, max(d, d_plane), w)`; inverted (fill): `d' = lerp(d, min(d,
  max(−d_plane, d_sphere(r))), w)`.
- Inflate: offset `d' = d − h · w` with `h = min(radius · strength · INFLATE_HEIGHT, 1 voxel)` a dab, so values stay
  within a voxel of true distances; inverted deflates.
After every operator values are clamped to ±CLAMP; a brick whose values all reach +CLAMP or −CLAMP collapses to a tile.

Band repair (`band.odin`): `volume_redistance(v, bricks, pool)` on the bricks a stroke touched plus one brick of halo
at `clay_stroke_end`: voxels next to a sign change keep the crossing (`d = sign · |d| / (|d| + |d_n|)` over crossing
neighbours, the smallest), the rest are swept with the Godunov upwind update in the 8 sweep directions, two rounds,
within the region; bricks that end uniform collapse. Off by a flag for the benchmark's A/B.

### 3.3 Dab pipeline (`clay.odin`)
```odin
Clay :: struct {
	volume:  Volume,
	surface: Surface,            // 3.4
	history: Undo_History,       // 3.5
	pool:    ^jobs.Pool,
	touched: [dynamic]u32,       // brick slots this stroke changed, for the band repair
	jobs:    [dynamic]Dab_Job,   // scratch: one per brick a dab writes
	scratch: [dynamic]Brick,     // Smooth's second buffer, one per job
	stroke_bricks, stroke_voxels: int, // counts for the stats
}
clay_init(c, voxel, centre, pool, allocator); clay_destroy(c)
clay_dab(c, brush, centre) -> (voxels: int)
clay_stroke_begin(c); clay_stroke_end(c) -> (changed: bool)
clay_flush(c) -> Flush   // 3.4: once a frame, before upload
clay_raycast(c, origin, dir) -> (hit, normal, ok)
```
`clay_dab`: 1) serial pre-pass over the brush's brick box: decide whether the operator can change the brick
(stamp distance to the brick's box within the band for Add/Subtract, inside the radius for the others), skip Empty
tiles the operator cannot fill and Inside tiles it cannot carve, make bricks from tiles where it can, record each
brick once per stroke (3.5), append a `Dab_Job{slot, coord}`. 2) `jobs.parallel_for` over the jobs: each writes only
its own brick (Smooth: its own scratch, then a second `parallel_for` commits). 3) serial post-pass: tile collapse, mark
the nodes whose meshing window covers the brick dirty (its node and the neighbours within one voxel... the window is
20³ around a 16³ node, so a brick dirties its node and the nodes up to one step away on each axis), grow the damage box.
Serial and parallel results are bit-identical: every voxel's value depends only on its own old value (and, for Smooth,
the old neighbourhood read from the untouched first buffer).

### 3.4 Surface (`mesh.odin`): the shown triangles, in slots
```odin
Node :: struct {
	coord:                  [3]i32,
	vert_first, vert_cap, vert_count: u32,
	idx_first, idx_cap, idx_count:    u32,
	bounds:                 geom.Aabb,
	dirty:                  bool,
}
Surface :: struct {
	mesh:      geom.Mesh,            // positions and normals in vertex slots, indices in index slots; unused
	                                 // index slots hold 0 (a degenerate triangle on vertex 0, as dyntopo's pages)
	nodes:     [dynamic]Node,
	chunks:    [dynamic]geom.Chunk,  // one per node with triangles, sorted by first_index, for the Draw_Item
	free_verts, free_indices: [dynamic]geom.Vertex_Range / Index_Range,  // holes, first-fit
	dirty:     [dynamic]u32,         // node indices to remesh at the next flush
	changed:   geom.Aabb,            // damage box since the last flush
	relaid:    bool,                 // slots moved or the arrays grew: the GPU copy must be made afresh
}
Flush :: struct {
	ranges:   []geom.Vertex_Range,  // vertex slots to upload (coalesced, sorted)
	indices:  []geom.Index_Range,   // index slots to upload
	regrow:   bool,                 // the arrays grew or were compacted: recreate the buffers
	damage:   geom.Aabb,
}
```
Meshing: naive surface nets per node (the 16³ cells it owns plus the −1 cell layer, so every quad's four cells are
found; a quad belongs to the node owning its edge's lower voxel), vertex at the mean of the cell's edge crossings,
normal = trilinear interpolation of central-difference gradients at the cell's corners (needs a 20³ window of
voxels, copied from the up to 64 bricks it spans into per-job scratch), two triangles a quad wound from the sign of the
edge. One `parallel_for` over the dirty nodes writes each node's slot directly when the output fits, else a heap
overflow buffer; a serial pass reallocates the overflowed nodes' slots (first-fit in the free lists, else at the end
of the arrays with 25 % slack, capacities rounded up to 64 vertices / 192 indices, 50 % headroom) and copies. When
the holes exceed half the arrays, every slot is laid out again (compaction) and `regrow` is set. `chunks` is rebuilt
from the nodes whenever a slot moved, else only the touched chunks' bounds change; `cone_cutoff = 1` (never
back-face culled) in this slice. Vertices on a node's border are duplicated with the neighbour (same position and
normal by construction, so no seam shows); `clay_to_mesh` welds them for export and conversion.

### 3.5 Undo (`undo.odin`)
One step a stroke: the first time a stroke touches a brick, its coordinate and 1 KiB of values (or the tile it
was) are copied into the step; undo swaps the saved contents with the live ones brick by brick (a brick created by
the stroke goes back to its tile and vice versa), marks the nodes around them dirty, and the step is its own inverse.
`UNDO_LIMIT_BYTES` as the mesh sculptor's (512 MB) drops the oldest steps. API mirrors the mesh one so the app's
`history_step` can call it: `clay_can_undo`, `clay_undo`, `clay_can_redo`, `clay_redo`, `clay_undo_bytes`.

### 3.6 Files (`file.odin`)
`clay_write(c, out)`: tag `"SVOX"`, version 1, voxel size, origin, chunk count; per occupied chunk its coordinate and
its 4096 tile codes as `u8`; then every brick's 512 `i16` values in chunk order then slot order (little-endian,
`geom.byte_put`). `clay_read(c, r, pool) -> bool` refuses damaged bytes (counts out of range, a short read), never
asserts. The mesh is not stored: it is remeshed on open (every node dirty) in parallel. No compression in this
slice (a 35 k-brick bust is ~35 MB); run-length coding of clamped values is the obvious follow-up.

### 3.7 Conversion (`convert.odin`)
`clay_to_mesh(c, pool, allocator) -> geom.Mesh`: every node meshed, border vertices welded by exact position,
degenerate triangles dropped, normals from the gradient; `geom.mesh_check` reports it (closed is expected except at
non-manifold vertices of ambiguous cells, which the check counts). The app turns it into a mesh object through the
existing `object_build_from` path. Mesh → voxels (import, DynaMesh-style re-voxelise) is a follow-up: our
`geom.remesh` ray-crossing voxelizer gives the sign, `geom.bvh_closest` the band distances.

### 3.8 App integration (`src/app`)
- `Object.voxel: ^Voxel_Part` (nil for mesh objects): `Voxel_Part{clay: voxel.Clay, gpu: render.Mesh_Buffers}`.
  `object_is_voxel(obj)`. `object_level`/`object_sculptor`/`object_mesh` assert `obj.voxel == nil` so a mesh-only
  path reached with a voxel object fails loudly in debug runs; the paths below branch first.
- Create: Scene palette Add object gets a switch "As voxels" (`Kit.add_voxel`, remembered); `Scene_Command.voxel`;
  `scene_add_voxel_sphere(app, resolution, t)`; `--voxel=RES` flag starts with a voxel sphere RES voxels across
  (0 = off). Size presets map to a resolution whose sphere has about that many surface vertices
  (`voxel_resolution_for(vertices)`; 1M → about 560 voxels across).
- Strokes: `stroke_start`/`stroke_dab`/`spray_dab` call `voxel_dab(app, obj, …)` when the object is voxel: raycast
  through `clay_raycast`, brush mapped Draw/Clay/Crease → Add, Inflate → Inflate, Smooth → Smooth, Flatten → Flatten,
  others refused at the press with one `log.warn` ("the Grab brush has no voxel form yet"); strength and radius from
  `brush_at`'s numbers; symmetry mirrors the centre and normal through `sculpt.mirrors`. Pivot and stroke-end
  bookkeeping unchanged. Grab, Cloth, Hook, Drag rectangle, Line, Mask shapes, Clip: refused on voxel objects.
- Undo: `history_step` branches on `object_is_voxel` to `voxel.clay_can_undo/undo/redo`; `brush_stroke_finish`
  records a `.Stroke` entry when `clay_stroke_end` says the stroke changed something. Swap entries (add, delete,
  duplicate) work unchanged once `object_put`/`object_get` know voxel objects.
- Frame: a voxel object flushes `clay_flush`, uploads `ranges` and `indices` through the existing render procs (nil
  mask), recreates its `Mesh_Buffers` on `regrow` (as `level_upload` does), and draws one `Draw_Item{chunks =
  surface.chunks, damage, live = selected}`. `scene_raycast`, `cursor_update` (ring normal from the gradient),
  `object_vertex_count`/`object_triangle_count` (sum over nodes), `object_has_mask` (false), `boolean_live_update`
  (voxel objects left out), export (through `clay_to_mesh`) branch.
- Files: `SCENE_VERSION` 11 adds a `u8` kind after the folder (0 mesh, 1 voxel) followed by `levels_write` or
  `clay_write`; version ≤ 10 reads as mesh. Autosave writes through `object_put_bytes` unchanged (serial path).
- Object palette: for a voxel object the tray shows Transform and a new "Voxels" section (resolution, bricks,
  memory, vertices, "Convert to mesh" command `Voxel_To_Mesh`, "Repair band" toggle); the mesh-only sections are
  skipped. Stats: dab time goes to `brush_ms`, flush time to `normals_ms`, upload to `upload_kb`; exit stats add
  `voxel_bricks= voxel_nodes= voxel_mb= voxel_vertices=`.
- README: a "Voxel sculpting" section, the flag, the switch, the controls, the limits (no mask, levels, layers,
  dyntopo on voxel objects).

### 3.9 Threading, memory, determinism
All loops through `jobs.parallel_for` with per-job scratch from `runtime.heap_allocator()` or pre-sized pools
owned by `Clay` (grown serially before the dispatch); jobs write disjoint bricks or disjoint node slots; the
directory is mutated only in serial passes. Tests compare a 1-thread and a 3-thread run bit for bit. No allocation
on the hot path once pools are warm. Peak memory at 1024³ effective (a bust): ~35–50 MB of bricks + ~50 MB of mesh
slots; the 4096-voxel domain's chunk table is 128 KB; each occupied 128³ chunk costs 18 KB of tables.

## 4. Boundary check
`voxel` → `geom` (Vec3, Aabb, Mesh, Chunk, ranges, Byte_Reader) and `jobs`: same edges `sculpt` has. `app` → `voxel`.
`render` unchanged (reuses `Mesh_Buffers`). `bench` → `voxel` (new `--voxel` table). `ui` untouched.

## 5. Alternatives rejected
- Dense grid (the spike): 512 MB at 512³, 4 GB at 1024³; the stroke cost was fine, memory is not.
- Hierarchical VDB-style tree or adaptive octree: no shipping brush sculptor uses adaptive resolution; the two-level
  table is a VDB without the 32³ level and without mutation complexity.
- Ray-marched display without a mesh: throws away the <1 ms mesh path and every tool that reads a mesh; Medium chose
  triangles for the same reason.
- Marching cubes for display: twice the triangles of surface nets; kept as the manifold fallback for export.

## 6. Risks
| Risk | Invariant threatened | Catches it |
|---|---|---|
| Band corruption after many Smooth/Inflate dabs (|∇d| drifts) | surface placement stays within a voxel | test: 200 dabs then redistance, RMS change ≤ 0.1 voxel; `--check-mesh` volume vs analytic sphere |
| Seams or cracks between nodes | every quad emitted once, vertices duplicated exactly | test: `clay_to_mesh` welds to a closed mesh (`mesh_check` boundary_edges 0 for a sphere) |
| Slot overflow / compaction hitch | upload within `vertex_capacity`/`index_count` | assert in upload procs; bench "Frame ms max"; `regrow` counted in stats |
| Undo swaps a brick whose node slot moved | undo dirties the nodes around the brick, never slots | test: dab, undo, compare every voxel bit for bit |
| Parallel nondeterminism | serial == parallel | tests with `jobs.pool_init(&pool, 3)` |
| Domain overrun (clay beyond 4096 voxels) | directory bounds | clamp + `log.warn` once a stroke; test |
| Mesh-only app paths reached with a voxel object | nil levels | asserts in `object_level`; touch scenario `voxel_sphere_sculpts` runs the common panels |
| 10M-scale: a 2048³ bust is ~4.4 M vertices, 35 k nodes | frame time | bench rows at 256/512/1024 resolution, 1 and 4 threads |

## 7. Plan (each step ends with check + its tests)
1. `src/voxel`: volume, directory, sphere fill, sample, gradient, raycast; tests (sphere radius error, raycast hit vs
   analytic). ~350 lines.
2. Brushes Add/Subtract/Inflate/Flatten/Smooth + dab pipeline + tile collapse; tests (volume change sign, serial vs
   parallel, domain clamp). ~400 lines.
3. Surface nets meshing into slots, flush, chunks, `clay_to_mesh`; tests (sphere closed after weld, Euler, seam
   count, dirty-only remesh equals full remesh). ~450 lines.
4. Undo + band repair + files; tests (undo bit-exact, redo, write/read round trip, damaged bytes refused). ~350 lines.
5. `bench --voxel` table at 256/512/1024, 1 and 4 threads: dab ms, flush ms, frame ms, max, upload KB, undo MB,
   memory. Compare with the dense spike and the mesh bench. ~150 lines.
6. App: object kind, Add switch/flag, frame loop, raycast, strokes, undo, files v11, palette section, README,
   touch scenario; smoke + viewport dump described. ~700 lines (own PR).
7. Follow-ups (own PRs): mesh → voxels, Res+/Res−, RLE in the file, normal cones per node, GPU trial for whole-volume
   smooth.

## 8. Open questions (defaults taken)
- Smooth volume loss: default no compensation; expose later if it shows.
- Brush height constants: `ADD_HEIGHT 0.1` radii per dab (as the mesh Draw brush), `INFLATE_HEIGHT 0.05`, capped a voxel.
- Voxel objects and symmetry: X/Y/Z mirror by the object's local axes, as meshes do.
- Default resolution for "Add voxel sphere" at the 1M preset: 560 voxels across (about 1M surface vertices).
