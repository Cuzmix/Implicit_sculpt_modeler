# Review of `voxel-roadmap-design.md` (stages 3–8) — sm-architect, read-only

Date 2026-10-27. Reviewed against `odin-sculpt` at `51a8f07` (the design's baseline). The worktree also holds an
uncommitted start on stage 3 (`src/geom/lattice_rays.odin`, `src/voxel/voxelize.odin`, `voxelize_test.odin`, and
`remesh.odin` already calling them); where I cite those files I say "worktree". `remesh.odin` line numbers are from
`51a8f07`. Every other `path:line` was opened in this session; `UNVERIFIED` marks what was not. Nothing was built or
run: this is a review of a design, not of a diff.

Verdict: the geometry is right where it matters most. Stage 5's two rules do make every edge of the surface-nets
mesh belong to exactly two triangles and every vertex a single fan (the proof is in §3.5), and stage 3's seeds are
exactly the set `band_repair` keeps fixed. What needs fixing is around the edges: the saddle scan as written can
leave a saddle behind on a face it never visits; Res+ shrinks the domain and can lose clay in silence; Convert to
voxels writes a snapshot the reader refuses; Intersect on fields erases nothing outside the other object's box; the
live-boolean stamp cannot see a voxel edit; 8b's culling cone is built from the wrong normals and would cull visible
triangles. The MUST list in §3a is what makes the stages implementable as described; the SHOULDs are cheaper ways
to the same numbers.

## 1. Request
Six stages over the merged `voxel` package and voxel objects: a closed mesh becomes clay (exact lattice rays made
public from `remesh.odin`), Res+/Res− resample the clay, surface nets become closed and manifold (no saddle faces
in the field, one vertex per cell loop), the stroke's end and the conversion get fast (settled-brick early exit, an
exact parallel weld by cell identity), live booleans between voxel objects run on the fields, and masks, pictures,
culling cones and an RLE file section arrive. It is not a change to the mesh sculptor, not adaptive resolution,
not a new `SCENE_VERSION` (the SVOX section carries its own version), and not the Windows or tablet numbers.

## 2. Current state (the design's "What exists", checked)
| Claim | Verified | Notes |
|---|---|---|
| `Volume` sparse 8³ `i16`, `SCALE` 4096, `BAND` 3, `CLAMP` ±4 voxels, tiles, 32³ chunks of 16³ brick tables | yes | `volume.odin:24-76`; `volume_init` puts the origin at `centre − DOMAIN/2 · voxel` (`:82`), so the domain in object space scales with the voxel |
| `clay_dab` serial pre-pass, parallel bricks, serial post-pass with `surface_mark_box`, collapse, `band_mark`, `dilate_band` | yes | `clay.odin:116-196`; Smooth writes scratch then commits (`:150-166`) |
| `band_repair`: seeds beside a sign change keep their value capped at a voxel, the rest far, 8 sweeps, settled bricks skipped, collapse after | yes | `band.odin:63-96` (seed pass), `:105-116` (sweeps), `:117-121`; it is `@(private)` so package-visible (`:38`). It never changes a sign: seeds keep theirs (`:86`), far values take the sign (`:89`), a sweep writes `−q`/`q` by the old sign (`:181-183`) and `eikonal_update` returns > 0 (`:196-209`) |
| `mesh_node`: naive nets over a 20³ window, one vertex per crossed cell, `cell_vertex` `#force_no_inline`, chunks with `cone_cutoff = 1` | yes | `mesh.odin:57-60, 505-543, 553-602, 446-456` |
| `clay_to_mesh` welds by sorting every vertex by position bits, single thread | yes | `convert.odin:10-56` |
| Per-stroke COW `Saved_Brick` steps, self-inverse swap | yes | `undo.odin:79-100, 196-215` |
| SVOX v1: tables + raw bricks | yes | `file.odin:15-16, 28-65`; `clay_read` ends in `surface_mark_all` with no saddle pass (`:84`) |
| `remesh.odin`: exact fixed-point casts, `Rays{first, hits{w, wind}}`, all file-private; the rule-built MC table | yes | `remesh.odin:33-36, 223-240, 273-363, 662-742` |
| `Voxel_Part{clay, gpu, resolution}`, `voxel_part_attach` file-private, `voxel_upload` remakes the GPU copy on `regrow` | yes | `voxel_object.odin:21-25, 60-79, 118-134`; `voxel_upload` passes `nil` masks (`:65, 124, 129`) |
| `Voxel_To_Mesh` is a swap entry; `MESH_ONLY_COMMANDS` guards the selected object | yes | `scene.odin:741-751`; `:155, 695-698` (`.Boolean` and `.Extract` are in the set) |
| `Boolean_State` + `boolean_make`/`boolean_live_update`/`boolean_hides` on meshes | yes | `boolean.odin:35-45, 120-196`; `boolean_stamp` reads `object_sculptor(obj).history` and `object_vertex_count` (`:110-112`); `shape_in` reads `object_mesh(obj)` (`:63-64`), the EMPTY level of a voxel object |
| `object_thumbs.odin` draws `obj.gpu[obj.levels.current]` only | yes | `:47, 96`; `thumb_camera` takes bounds from `lv.sculptor.chunks` (`:121-122`) |
| The History routes any non-swap entry of a voxel object to `clay_undo`/`clay_redo` | yes | `history.odin:584-597`; `brush_stroke_finish` records `.Stroke` for a clay (`:228-231`); `history_swap` snapshots the live object, `object_get`s the saved one, waits for the GPU, frees the old (`:640-690`) |
| `object_put_bytes` writes the kind byte, then the clay in the levels' place; `object_get` refuses a voxel object with group materials | yes | `files.odin:903-911`, `:961` |
| The mask reaches the shader in the normal's low nibbles | yes | `render.VERTEX_BYTES = Vec3 + [2]i16` (`renderer.odin:193-198`), `pack_normal = geom.oct_encode_masked` (`visibility.odin:219-227`), `mesh.vert:4, 59` |
| The sculptor's culling cones are built from FACE normals | yes | `brush.odin:1385-1403` (`face_normal` per triangle → `geom.normal_cone`); `chunk_backfacing` (`visibility.odin:83-92`) is conservative only for such a cone |

## 3. Design

### 3a. MUST (each with the smallest change)
1. **Stage 5, `resolve_saddles` scope and termination.** A flip of corner `v` (inside → +1) can CREATE a saddle on
   another face through `v`: with `v` out and its face neighbours `p`, `q` in and the opposite corner `r` out, `p`
   and `q` are now diagonal insides. That face may lie on the −x/−y/−z side of the job brick, inside a neighbour
   that is not a job brick, which the design's scan ("the dab's bricks and the +x/+y/+z faces into their
   neighbours") never visits. The pass terminates (the inside count falls by one a flip) but can stop with a saddle
   left. Fix: scan every face touching a job brick's voxels, i.e. the 10³ window `WINDOW` already gathered for Smooth
   (`clay.odin:47, 203-232`), and keep a worklist: a flip re-queues the faces through the flipped voxel until a scan
   finds none. Tie on |d|: the lower `voxel_index` (`volume.odin:117`), so the result is one whatever the scan
   order. A chosen corner that lies in an Inside tile (possible where an outside brick face meets a tile that
   `dilate_band` never made a brick of, `clay.odin:260` makes bricks only for inside face values) is made a brick
   first: `undo_record`, `volume_brick_make(v, nc, tile_value(tile))`, `band_mark`, as `dilate_band` does
   (`clay.odin:266-268`). Run the pass before the post-pass collapse (`clay.odin:185-188`), since a flip can empty a
   brick.
2. **Stage 5, `clay_read` too.** SVOX v1 files written before the rule hold saddles; `clay_read` ends in
   `surface_mark_all` (`file.odin:84`) and the design lists only `clay_fill_sphere`, `clay_from_mesh` and
   `clay_resample`. Add `resolve_saddles(c)` (no undo step: a load is not undoable) after `clay_read_chunks` and
   after `undo_swap`? No: a swapped step restores a state that was saddle-free when recorded, so only the read needs
   it. Without it the manifold invariant and `--check-mesh`'s `mesh_non_manifold_edges=0` fail on any old file.
3. **Stage 3 app, group materials.** `object_mesh_to_voxels` must clear `obj.group_materials` (with
   `autosave_settle`, exactly as `object_build_from` does at `scene.odin:1106-1109`). Otherwise `object_put_bytes`
   writes the groups and then the voxel kind (`files.odin:903-910`), and `object_get` refuses the bytes
   (`files.odin:961`): the swap snapshot taken by the NEXT change to the object, every autosave and every save of
   the scene are unreadable, and undo logs "could not rebuild object" (`history.odin:650-652`).
4. **Stage 4, the domain shrinks at Res+.** `volume_init` places the domain at `centre − DOMAIN/2 · voxel`
   (`volume.odin:82`), so at `voxel/2` it covers half the object space it did; clay added more than
   `DOMAIN/4 · voxel` from the centre (a sphere of radius 1 at 256 across has a domain of ±8, after one Res+ ±4,
   after two ±2) falls outside and is lost without a word (`brick_in_domain`, `volume.odin:131-133`, makes it
   Empty). `clay_resample` checks `clay_bounds(c)` grown by `BAND + 1` voxels against the new domain and returns
   false (`log.warn` + true in the app). Test: a sphere plus an Add dab at the domain's edge refuses, the sphere
   alone does not.
5. **Stage 6, owner-local cell codes and the per-vertex arrays.** A node's copy of a border vertex sits in its own
   cell array at index −1 on an axis (`MESH_CELLS = NODE + 1`, `mesh.odin:60, 555`); the owner holds the same cell
   at index `NODE − 1`. The code the design stores ("local cell index in 17³") differs between copy and owner, so
   the binary search in the owner's list finds nothing. Store the OWNER-local code (16³ = 12 bits, loop in 4 bits)
   on every vertex, copies included (the node knows which axes are at −1), or translate before the search. The
   owner can be missing (a node at coordinate 0 has −1 cells no node owns; `surface_mark_node` drops negative
   coordinates, `mesh.odin:149`; the window there reads `CLAMP`, `volume.odin:262`): keep such a copy as its own
   vertex, never assert. And every new per-vertex array (`cell_codes`, 8a's `mask`) must follow positions through
   `surface_alloc_verts` (`mesh.odin:382-385`), the flush copy pass (`:263-264`) and `surface_compact_if_needed`
   (`:478-495`), or they go stale after the first compaction.
6. **Stage 7, Intersect's region is the whole base.** Outside `other`'s box the sample is `+CLAMP` (outside), so
   Intersect = `max(a, +CLAMP)` = Empty everywhere the other does not reach; the design's region ("the bricks of the
   base's lattice that other's bounds cover plus BAND + 1") leaves the base intact outside the box and the result is
   the base, not the intersection. For `.Intersect` the region is every base brick, and every Inside tile outside
   the box becomes Empty. (Union and Subtract are right as written: `min(a, CLAMP) = a`, `max(a, −CLAMP) = a`.)
7. **Stage 7, the live stamp cannot see a clay edit.** `boolean_stamp` mixes the sculptor's `history.done/undone`
   lengths, the level and the vertex count (`boolean.odin:110-112`); a voxel object's sculptor is the empty level's,
   so a stroke, undo or Res± on the clay leaves the stamp unchanged and the preview stale. The design's `clay_hash`
   "cached per object per stroke end" misses undo, redo (`history.odin:584-597`), Res± and a swap, and hashing is a
   pass over the field (`file.odin:129-139`; 146 MB at 1024). Smallest change: `Voxel_Part.edits: u64`, bumped
   wherever the clay changes (`brush_stroke_finish` `history.odin:230`, the voxel branch of `history_step`,
   `clay_resample`, `clay_combine`, `voxel_part_get` starting from a per-run counter so a swapped-in part differs),
   mixed into the stamp beside `obj.id`. No hashing at all.
8. **Stage 7, the command guard and `shape_in`.** `.Boolean` is in `MESH_ONLY_COMMANDS` (`scene.odin:155`) and the
   guard looks only at the selected object (`:695-698`): with a mesh selected and a voxel base, `boolean_make` runs
   today's mesh path; with a voxel selected it refuses even when the base is a mesh. Take `.Boolean` out of the set
   and decide in `boolean_make`/`boolean_live_update` from the base's and the marks' kinds. And "a mesh base with
   voxel marks keeps the mesh path (voxel marks converted with `clay_to_mesh`)" must happen inside `shape_in`
   (`boolean.odin:63-81`), which today returns the voxel object's EMPTY level: a voxel mark is silently a no-op.
9. **Stage 8b, cones from face normals.** The design builds the node's cone from the vertex normals ("mean of
   vertex normals, cutoff = min dot") and tests vertex normals against it. `chunk_backfacing`
   (`visibility.odin:83-92`) is conservative only for a cone over the TRIANGLES' normals, which is what the sculptor
   feeds `geom.normal_cone` (`brush.odin:1385-1403`); a surface-nets triangle's face normal can lie well outside
   its three vertices' (blended gradient) normals, so a front-facing triangle would be culled. In `mesh_node`
   collect `cross(p1 − p0, p2 − p0)` per emitted triangle into a heap scratch and call `geom.normal_cone` (it
   normalises in place and returns cutoff 1 for a cone wider than a hemisphere, `visibility.odin:35-52`). The test:
   every triangle's unit face normal has `dot(axis) ≥ sqrt(1 − cutoff²) − CONE_SLACK`, as the sculptor's does.
10. **Stage 8a, the mask's two readers.** `object_has_mask` (`history.odin:768-785`) reads only the sculptor's
    mask, and the mask-dependent enablers read it (`commands.odin:237, 713, 1129`; `kit_action_bar.odin:77`): add a
    clay branch (`voxel.clay_has_mask`, cached under the same `history.serial` rule). On the GPU side there is no
    mask attribute to find "when built": the mask rides in the low four bits of each half of the packed normal
    (`pack_normal` = `oct_encode_masked`, `renderer.odin:195-198`, `visibility.odin:219-227`; `mesh.vert:59`), and
    the voxel path passes `nil` (`voxel_object.odin:65, 124, 129`). Keep a `Surface.mask: [dynamic]u8` per vertex
    slot (filled by the flush copy pass from the trilinear sample, following positions as in MUST 5) and pass
    `mask[:]` to `mesh_buffers_create` and `mesh_buffers_upload_ranges`. `VERTEX_BYTES` and the shader do not
    change; say so in the design. A mask stroke on a clay records `.Mask`, not `.Stroke`, at `history.odin:230`, so
    `object_has_mask`'s serial-keyed cache and the action bar follow it.

### 3b. SHOULD
- **Stage 3, `REACH`.** `VOXELIZE_REACH = 7` ("√3 · (BAND + 1)") goes the wrong way: the Chebyshev distance is at
  most the Euclidean one, so a brick whose box is more than `BAND + 1 = 4` voxels from every crossing along some
  axis holds no value under `CLAMP`. `REACH = 4` makes about half the candidate bricks (worktree
  `voxelize.odin:20, 156-185`); they collapse to tiles afterwards anyway (`:109-113`), so this is time and peak
  memory at 1024 across, not correctness.
- **Stage 3, failure reporting.** `clay_from_mesh` returns false for an open mesh only by accident (the design's
  test "an open mesh (a triangle) returns false" is UNVERIFIED: a lone triangle casts hits, the x rays give odd
  windings, bricks are made). Decide inside from winding exactly as the remesh does and add a `mesh_edges_closed`
  pre-check in the APP (`log.warn` "needs a closed mesh"), not in the package.
- **Stage 4, Res+ cost.** "measured synchronously first" is right; put the bench row in before deciding on frames.
- **Stage 6 (a).** The early exit is safe: a brick skipped as `quiet` (`band.odin:139-149`) is at a fixed point;
  when `settled_next` is all true the next sweep changes nothing. Count the sweeps taken into the exit stats.
- **Stage 7, preview cost.** The mesh path bounds the preview by `live_vertices`; the field path has no knob and a
  1024³ base previews in seconds (`clay_combine` + `clay_to_mesh`, both over the whole band). Preview on the base
  resampled to at most 256 across (stage 4's `clay_resample` into a scratch clay) and make at full resolution.
- **Stage 8c.** `clay_write_estimate` (`file.odin:120-124`) stays the raw size, an upper bound: `reserve` only.

### 3c. Signatures and ownership (as the design has them, with the changes above)
```
// geom (worktree lattice_rays.odin:37, 73, 110, 117 — matches the design but for the explicit `q` and the allocator kept in the struct)
lattice_quantize   :: proc(m: Mesh, origin: Vec3, h: f32, pool: ^jobs.Pool, allocator := context.allocator) -> [][3]i32
lattice_rays_cast  :: proc(m: Mesh, q: [][3]i32, origin: Vec3, h: f32, n: [3]int, axis: int, split: int, weight: i32, pool: ^jobs.Pool, allocator := context.allocator) -> Lattice_Rays
lattice_rays_destroy :: proc(r: ^Lattice_Rays)
lattice_ray_hits   :: proc(r: Lattice_Rays, u, v: int) -> []Lattice_Hit
// voxel
clay_from_mesh  :: proc(c: ^Clay, m: geom.Mesh, voxel: f32, pool: ^jobs.Pool, allocator := context.allocator) -> bool
clay_resample   :: proc(c: ^Clay, factor: f32) -> bool            // false: out of VOXELS range or the clay would leave the domain (MUST 4)
clay_combine    :: proc(c: ^Clay, base, other: ^Clay, place: matrix[4, 4]f32, scale: f32, op: Clay_Op) -> bool
resolve_saddles :: proc(c: ^Clay, bricks: []u32, record: bool)     // @(private); record = inside a stroke (undo_record)
clay_has_mask   :: proc(c: ^Clay) -> bool
```
Ownership: `clay_from_mesh` and `clay_combine` build an uninitialised `Clay` (the caller destroys the old one after
`WaitForGPUIdle`, as `object_voxel_to_mesh` does, `voxel_object.odin:188-195`); `clay_resample` replaces in place and
leaves `surface.regrow = true` (`surface_init`, `mesh.odin:104`) so the next `voxel_upload` remakes the GPU copy
(`voxel_object.odin:121-128`) — no GPU call inside `voxel`. `Lattice_Rays` own `first`/`hits` through their allocator
(worktree `lattice_rays.odin:32, 110-114`); `remesh_run` gives them the heap and frees them in a `defer` (worktree
diff of `remesh.odin`).

Threading: every parallel pass writes disjoint bricks or nodes and reads the rays, the old volume or a snapshot;
`resolve_saddles` is serial in the post-pass (it edits the directory through `volume_brick_make`); the candidate and
region lists are sorted before use (`band_repair` sorts its region, `band.odin:55`). Failure modes: `clay_from_mesh`
false (no triangles, no volume, too big) → `log.warn` + true in `scene_apply` as `.Remesh` does (`scene.odin:357-360`);
GPU failure after the old part is gone → `history_snapshot_drop` + delete the object + false, as `.Voxel_To_Mesh`
(`scene.odin:744-748`); a damaged SVOX v2/v3 → `clay_read` false, never an assert (`file.odin:11-13`).

### 3.5 Why stage 5's two rules suffice (the design's claim, checked)
Call a cell face "clean" when it has 0 or 2 crossed edges. Rule 1 makes every face clean (the only face with 4
crossings is the diagonal-insides saddle; parity forbids 1 or 3). In a clean cell each crossed edge lies on two
faces and each face pairs it with exactly one other crossed edge, so the crossed edges split into disjoint cycles:
rule 2's loops are well defined, and a face's pair is always within one loop. Now the quads. For a crossed lattice
edge `e`, `mesh_node` emits one quad over the four cells around `e`, split on the diagonal `q0–q2`
(`mesh.odin:529-539`); with rule 2 each corner is that cell's vertex for the loop holding `e`.
- A quad SIDE joins two face-adjacent cells A, B across the face F containing `e`. The only quads that can contain
  both A's and B's vertices for these loops are the quads of F's crossed edges, and F has exactly two, `e` and
  `e'`, which are paired, hence in the same loop in A and in B: the side `(A_L, B_L')` appears in exactly those two
  quads, once each, so in exactly two triangles.
- A quad DIAGONAL joins two cells that share only `e` (they differ on both other axes); no other edge touches both,
  so the diagonal appears only in its own quad's two triangles.
So every mesh edge is in exactly two triangles (closed, and `mesh_check`'s inconsistent count will confirm the
winding, which `d0 >= 0` already orients, `mesh.odin:538`). For a vertex `V = (A, L)`: the quads around it are the
quads of L's edges, and consecutive edges of L share a face of A, so consecutive quads share a side at V: the quads
form one cycle. Each link vertex `D` of V has degree = the number of triangles on edge `V–D` = 2 (just shown), so
V's link is a connected 2-regular graph: one cycle, and V is manifold. The −1 cell layer makes every quad's four
cells available to the owning node (`MESH_CELLS`, `mesh.odin:60, 509, 532-535`), and the loop grouping is a pure
function of the eight corner signs, so copies agree bit for bit as today.

Rule 1's own claims: the flip only turns inside voxels outside, so it terminates (but see MUST 1 for where it stops
scanning); `band_repair` never changes a sign (§2), so repair makes no saddles; `+1` rather than `0` keeps the voxel
outside for both `d < 0` (`mesh.odin:528`, `band.odin:79`) and `volume_raycast`'s `s <= 0` (`volume.odin:360`),
which treat zero differently — a good choice, say why in the comment. The surface motion: a planar field has no
saddle on any face (with corner values d0, d0+n1, d0+n2, d0+n1+n2 the diagonal pattern needs n1, n2 ≥ −d0 > 0 and
n1 + n2 < −d0, impossible), so saddles come only from curvature inside one voxel: necks and sheets thinner than a
voxel, and pinch points. A one-voxel-thick diagonal sheet (x + y = c) is a saddle on every xy face and half its
voxels flip: it dissolves into dots. That is within "features thinner than a voxel go", but the design should say
so beside "a voxel at thin diagonal necks only", and the 0.1 % volume test on a sphere does not exercise it; add a
test that a thin diagonal sheet drops its triangles without a non-manifold edge.

### 3.6 Stage 3 seeds (exactness and determinism)
The seed set is voxels with a 6-neighbour of the other sign, exactly `band_repair`'s fixed set (`band.odin:79-87`;
worktree `voxelize.odin:222-233` tests the same six neighbours), and every seed is under one voxel
(`d = 1/√Σ 1/ax² ≤ min(ax) < 1`, with `CROSSING_MARGIN` 0.02 keeping it above zero, worktree `:28, 153`), so the
cap `max(d, −SCALE)`/`min(d, SCALE)` at `band.odin:86` is a no-op and the surface does not move in the repair.
Exactness: for a plane with unit normal n at distance D, `ax_i = D/|n_i|` and `Σ 1/ax² = 1/D²`, so `d = D` up to the
f64→f32 rounding of `at` (`lattice_rays.odin:170-171`); "exact for a plane" should read "to f32". Signs come from
one place, the x rays, as the remesh decides inside (`find_flips`, `remesh.odin:368-397`: a point is inside when
the winding after the hits with `w < p` is positive; worktree `voxelize.odin:124-130, 207-213` does the same with a
binary search). The y/z crossing falls back to the middle when that ray disagrees with the x rays, as `crossing_on`
does (`remesh.odin:461-470`; worktree `:139-154`). Determinism: hits are appended in thread order and insertion-sorted
by `w` (`remesh.odin:293-308`); two hits at the same `w` can land in either order, but every consumer (`find_flips`,
`crossing_on`, the seeds) reads only `w` and the cumulative winding after the group, which are order-independent.
Candidates are marked in parallel per slab into a flag array and made in serial box order (worktree `:84-102`), so the
pool slots are deterministic and `clay_hash` (pool-order-free anyway, `file.odin:126-139`) agrees serial/parallel.
Risk worth a test: a mesh with a vertex exactly on a voxel centre row (a cube primitive) — the top-left rule covers
it (`lattice_rays.odin:153-155`), and the remesh tests prove it for the lattice at `bounds.lo − 1.5h`; the voxel
lattice sits elsewhere, so run the cube through `clay_from_mesh` → `mesh_check` too.

### 3.7 Stage 3 refactor (remesh output unchanged)
The worktree refactor moves `FIX` → `LATTICE_FIX`, `Hit` → `Lattice_Hit`, `Rays` → `Lattice_Rays` (minus `op` and
`cursor`), `cast_rays` + `triangle_hits` → `lattice_rays_cast` with the same two-pass atomic count/fill, the same
insertion sort and prefix sum, the same `(positions − origin)/h` f32 for `aw/bw/cw` and the same `round(l · FIX)`
quantisation (`lattice_rays.odin:44-52, 79-106, 141-171` against `remesh.odin:190-195, 273-363`), with `BOOL_WEIGHT`
passed as `weight` and `op` passed explicitly to `crossing_on` (worktree `remesh.odin:337`). `EDGE_MARGIN`,
`inside`, `find_flips`, `crossing_on` stay. Behaviour is unchanged as long as the quantise expression stays
character for character (it does) and `q` keeps its allocator lifetime (temp in `remesh_run`, heap in
`clay_from_mesh`). Evidence rung: `remesh_test.odin` and `boolean_test.odin` green, and `build/bench --remesh`
rows within noise of the baseline. One MUST-adjacent note: `lattice_rays_cast` clones `first` into
`context.temp_allocator` (`lattice_rays.odin:85`) — fine from the frame loop and the setup paths, and `clay_from_mesh`
is called there; it must not be called from a job.

### 3.8 Undo, History and GPU lifetimes (stages 3, 4, 7)
`.Voxel_To_Mesh` is the template (`scene.odin:741-751`): snapshot, convert (`stroke_finish`, `clay_to_mesh`,
`WaitForGPUIdle`, `object_release_mesh`, `object_build_from`), record the swap or drop the snapshot and the object
on a GPU failure. Mesh→voxels mirrors it with `object_hd_leave` (as `object_remesh`, `scene.odin:338-339`),
`object_release_mesh` (which already calls `voxel_part_free` and `history_forget_strokes`, `scene.odin:1184-1192`)
and `voxel_part_attach` (`voxel_object.odin:61-79`, file-private, so the new proc lives in that file). Layers are
lost: count them in `app.layers_lost` as `object_take_layered` does (`scene.odin:1162-1165`), or the command's note
under-reports. MUST 3 above. Res±: `history_record_swap` already drops the object's stroke entries
(`history.odin:160-162`); the clay's own steps need `clay_clear_history` (asserts no stroke is recording,
`undo.odin:255-257`, so `stroke_finish` first). The GPU copy is remade by the next `voxel_upload` on `regrow`
(§3c), so the only waits are the ones already in `voxel_upload` (`voxel_object.odin:122`). `boolean_make` on a voxel
base: snapshot, build the result clay, `WaitForGPUIdle`, destroy the part's `gpu` and clay, attach the new clay,
record the swap, delete the marks chained (`boolean.odin:178-190`); the preview buffers follow today's path
(`:133-146`). History swaps of voxel objects already work: `object_get` → `voxel_part_get` builds a fresh part
(`files.odin:962-967`), `object_free` releases the old one after the wait (`history.odin:659, 668`). Snapshot cost:
a voxel snapshot is the SVOX bytes (146 MB at 1024³, `volume_bytes` in README "Voxel sculpting"), under
`SWAP_LIMIT_BYTES` 1.5 GB (`history.odin:117`) and dropped oldest-first (`:172-188`), as the design says.

## 4. Boundary check
`voxel` imports `geom` and `jobs` only (sm-lint §2); the new edges `geom.lattice_rays_*`, `geom.Aabb`,
`geom.mesh_area_bounds`, `geom.normal_cone`, `geom.Chunk.cone_*` are all into `geom`: fine. `geom` gains no import
(`lattice_rays.odin:3-8` uses `core:` and `../jobs`, both already in `remesh.odin:3-9`). `render` is untouched by
every stage (8a reuses the `mask` parameters, 8b fills `Chunk` fields it already reads). `app` touches only files
it owns. `bench` imports `voxel` already (`bench/voxel.odin:10`). No new package.

## 5. Alternatives rejected
- Manifold dual contouring (libfive-style QEF per cell) instead of rules 1 + 2: sharper features, but Hermite data,
  a QEF solve per cell and a face-adjacency pass; the two rules get closed-and-manifold for 3·8³ sign reads a brick.
- Keeping the position-sort weld but parallelising the sort: still O(n log n) over 5.6M float keys and still a
  single merge; identity by (owner cell, loop) is O(n) with per-node sorts of ≤ 4096·4 keys.
- Voxel booleans by meshing both objects into `mesh_boolean` (`geom/boolean.odin:19-23`): already works for a mesh
  base, but loses the field (no sculpting after without a conversion) and costs a remesh at the result size.

## 6. Risks (invariant → what catches it)
- Undo: a converted object's snapshot refused on read (MUST 3) → a touch scenario Convert to voxels, stroke,
  Ctrl+Z ×2, then Save and Open; `--check-autosave` after a conversion.
- Levels and HD: `object_hd_leave` before every conversion (`scene.odin:339`); a voxel object has one empty level,
  so `MESH_ONLY_COMMANDS` must keep every level command (`scene.odin:155`) — only `.Boolean` leaves the set.
- Dirty ranges and damage: `surface_mark_all` after every rebuild (`mesh.odin:197-199`) and `regrow` for the GPU
  copy; the per-vertex arrays of MUST 5 → a test that compacts (`COMPACT_MIN_VERTS`, `mesh.odin:72`) and then
  welds, comparing `clay_to_mesh` with the position-sort weld kept as a test oracle.
- GPU buffer lifetimes: every destroy after `WaitForGPUIdle` (`voxel_object.odin:122`, `history.odin:659`,
  `boolean.odin:133`); `build.bat smoke` under validation after each app stage.
- Culling (MUST 9): `--no-cull` A/B dumps of a voxel object from several views must be pixel-identical
  (`scripts/ppm.py diff`).
- 10M-vertex cost: the saddle scan is serial in the post-pass over the dab's bricks (tens of bricks a dab) — fine;
  the weld's per-node sorts are parallel; Res+ at 512 → 1024 is one repair over the whole band (the bench row says).
  Res+ domain loss (MUST 4) → the refusal test.
- Determinism: serial = parallel tests for voxelize, resample, combine (as `voxel_test.odin:91-125` does for
  strokes, comparing `clay_hash` and the welded mesh bit for bit).

## 7. Plan (one PR a stage; each ≤ ~300 lines or split)
1. **3a `geom`**: `lattice_rays.odin` as in the worktree; `remesh.odin` calls it. Rung: `check`, `test geom`
   (remesh and boolean tests), `bench --remesh` within noise.
2. **3b `voxel`**: `voxelize.odin` with `REACH = 4`; tests: sphere 64/128 (closed, Hausdorff < 1 voxel, 200
   `volume_sample` points), torus (components 1, V − E + F = 0), cube (the on-centre case), serial = parallel, too
   big → false. Rung: `test voxel`, bench "from mesh" column.
3. **3c app**: `Mesh_To_Voxels` command + Voxels across slider + MUST 3; README; touch scenario. Rung: `smoke`,
   `touch_check 'voxel_*'`, a described PNG of a converted cube.
4. **4**: `clay_resample` + MUST 4 + `Voxel_Resample` command. Rung: tests (0.25 voxel RMS, ×2 then ÷2), bench
   "Res+ ms", `smoke`.
5. **5a**: `resolve_saddles` per MUST 1–2 with the planted-saddle, thin-sheet and every-brush tests. **5b**: loops in
   `mesh_node` (`Cell_Verts`), the seam test still bit-exact. Rung: `--voxels=256 --bench-stroke=60 --check-mesh`
   prints `mesh_non_manifold_edges=0`, `smoke`.
6. **6a**: settled early exit, measured before and after (`bench --voxel 1024` stroke end). **6b**: owner-local codes
   (MUST 5) and the three-pass weld, with the old weld kept under test as the oracle. Rung: "To mesh ms" row, the
   weld-equivalence test, `--check-mesh`.
7. **7**: `clay_combine` with MUST 6; app MUST 7–8; tests (union/subtract/intersect volumes, disjoint → false,
   serial = parallel); bench row. Rung: `smoke`, a described PNG of the live preview.
8. **8a** masks (MUST 10, SVOX v2), **8b** pictures and cones (MUST 9), **8c** RLE (SVOX v3, v1/v2 read): three
   PRs. Rung: `--no-cull` pixel A/B for 8b; file size before/after for 8c; `touch_check` for the mask keys.

## 8. Open questions (with the default I would take)
- Should `resolve_saddles` flip the smaller-|d| corner or the one whose flip creates no new saddle when one exists?
  Default: smaller |d| with the index tie-break (MUST 1); it is the local minimum of surface motion and the worklist
  handles the cascade.
- Does Res− need a saddle pass? Yes: coarse sampling creates saddles freely. Default: every builder ends in
  `resolve_saddles` then `band_repair`, in that order (the repair keeps signs).
- Voxel marks on a mesh base: convert at the base's lattice, or `clay_to_mesh` into the mesh boolean? Default:
  `clay_to_mesh` inside `shape_in` (MUST 8), the smallest change; the field path only when the base is a voxel.
- The live preview's resolution for voxel bases: default a 256-across resample of the base (§3b), full on Make.
- `Voxel_Part.resolution` after Convert to voxels: "voxels across the longest extent" (the design) — keep, and show
  the voxel size beside it in `kit_voxels` as today (`voxel_object.odin:207`).
