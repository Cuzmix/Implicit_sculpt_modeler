# Voxel roadmap, stages 3–8: design

Written 2026-10-27 after PR #127 (the `voxel` package) and PR #132 (voxel objects in the app) merged into
`odin-sculpt`. Bolt asked for "the full roadmap" of the report (https://claude.ai/artifact/3Ak33tfrBu1VrzSZUvFj2e,
section 8). Stage 9 (Windows and tablet numbers) is Bolt's own run; the rest is built here, one PR a stage, in order.
Conventions from AGENTS.md hold: `voxel` imports `core:`, `../geom` and `../jobs` only; serial equals parallel bit
for bit; every whole-clay replacement in the app is a swap entry (`history_snapshot` / `history_record_swap`).

## What exists (verified against odin-sculpt 51a8f07)
- `src/voxel/volume.odin`: `Volume` (sparse 8³ `Brick` of i16, `SCALE` 4096, `BAND` 3, `CLAMP` ±4 voxels, tiles
  `TILE_EMPTY`/`TILE_INSIDE`, 32³ chunk directory of 16³ brick tables), `volume_brick_make/collapse`, `volume_value/
  sample/gradient/raycast`, `volume_fill_sphere`.
- `clay.odin`: `Clay{volume, surface, history, pool, scratch...}`, `clay_dab` (serial pre-pass, parallel brick jobs,
  serial post-pass with `surface_mark_box`, `band_mark`, `dilate_band`), `gather_window`.
- `band.odin`: `band_repair` at stroke end: seeds = voxels beside a sign change (value kept, capped at a voxel), the rest
  far, 8 Godunov sweeps (GS in brick, Jacobi across, settled bricks skipped), collapse to tiles after.
- `mesh.odin`: `Surface` of per-node slots in one `geom.Mesh`, `clay_flush`, `mesh_node` = naive surface nets over a
  20³ window with ONE vertex per crossed cell (`cell_vertex`, `#force_no_inline` so node copies agree bit for bit),
  chunks with `cone_cutoff = 1` (no back-face culling).
- `convert.odin`: `clay_to_mesh` welds node copies by sorting every vertex by position bits (single thread).
- `undo.odin`: per-stroke COW `Saved_Brick` steps, self-inverse swap. `file.odin`: SVOX v1 (tables + raw bricks).
- `src/geom/remesh.odin`: the DynaMesh lattice: exact fixed-point ray crossings along x, y, z (`cast_rays`,
  `triangle_hits`, `Rays{first, hits{w, wind}}`), all `@(private = "file")`; marching cubes with the rule-built table
  (`mc_build_table`: on each face the surface keeps diagonal inside corners apart) that is closed and manifold.
- App: `Voxel_Part{clay, gpu, resolution}`, `object_build_voxel`, `voxel_part_attach` (file-private), `voxel_upload`,
  `object_dab`, `object_voxel_to_mesh`, `kit_voxels`, `Scene_Command_Kind.Voxel_To_Mesh`, `MESH_ONLY_COMMANDS`,
  `Boolean_State` + `boolean_make`/`boolean_live_update`/`boolean_hides` for meshes (`geom.remesh_run` with
  `Remesh_Op`), `object_thumbs.odin` draws `obj.gpu[obj.levels.current]` only.

## Stage 3: Mesh to voxels

### geom: the lattice rays become public (refactor, behaviour unchanged)
`src/geom/lattice_rays.odin` (moved out of remesh.odin):
```
Lattice_Hit  :: struct { w: f32, wind: i32 }            // position along the ray in lattice steps; winding just past it
Lattice_Rays :: struct { nu, nv: int, first: []u32, hits: []Lattice_Hit }   // ray u + nu*v, hits sorted, wind summed
lattice_rays_cast    :: proc(m: Mesh, origin: Vec3, h: f32, n: [3]int, axis: int, split: int, weight: i32, q: [][3]i32, pool: ^jobs.Pool, allocator := context.allocator) -> Lattice_Rays
lattice_rays_destroy :: proc(r: ^Lattice_Rays, allocator := context.allocator)
lattice_ray_hits     :: proc(r: Lattice_Rays, u, v: int) -> []Lattice_Hit
lattice_quantize     :: proc(m: Mesh, origin: Vec3, h: f32, pool: ^jobs.Pool, allocator := context.allocator) -> [][3]i32   // the FIX-point vertex positions both callers need
```
`remesh_run` keeps its `Remesher` but holds `[3]Lattice_Rays`; `inside(op, wind)`, `find_flips`, `crossing_on` stay in
remesh.odin and take the rays by value. `FIX` and `EDGE_MARGIN` move with the rays (`LATTICE_FIX`). The remesh tests
(`remesh_test.odin`) prove nothing changed (same vertex counts and `mesh_check` lines).

### voxel: `src/voxel/voxelize.odin`
```
// Builds `c` (uninitialised) as the clay of the closed mesh `m` (object space): the field is the signed distance to the
// surface within the band, the sign the winding number along x (as geom.remesh_voxel decides inside), the lattice a
// voxel grid of `voxel` centred on the mesh's box. False (c left empty) when the mesh has no volume or needs more than
// VOXELIZE_MAX voxels along an axis.
clay_from_mesh :: proc(c: ^Clay, m: geom.Mesh, voxel: f32, pool: ^jobs.Pool, allocator := context.allocator) -> bool
// `voxel` for `across` voxels along the mesh's longest extent (the app's resolution).
voxel_size_for :: proc(bounds: geom.Aabb, across: int) -> f32
```
Steps (all per-axis loops through `jobs.parallel_ranges`, heap scratch, deterministic):
1. `bounds := geom.mesh_area_bounds(m)`; `clay_init(c, voxel, centre)`; lattice point (i, j, k) is voxel
   `g0 + (i, j, k)` with `g0` chosen so the box plus `MARGIN = BAND + 3` voxels lies inside the domain (reject if
   `extent / voxel + 2 MARGIN > DOMAIN` — never with across ≤ 1024). Lattice origin `o = voxel_centre(g0)`, `h = voxel`.
2. `rays[a] = geom.lattice_rays_cast(m, o, h, n, a, len/3, 1, q, pool)` for a in x, y, z.
3. Candidate bricks: every brick whose voxel box lies within `REACH = 7` voxels (√3·(BAND + 1) rounded up) along any axis
   of a crossing: walked per x ray in parallel into per-job brick lists, merged and sorted (serial), de-duplicated.
4. Per candidate brick (parallel, disjoint writes): for each of its 512 voxels the sign from its x ray (`wind > 0` just
   before the voxel's w); for each axis a the neighbour at +a (its sign from ITS x ray); where the signs differ, the
   crossing on the a ray through the pair (`lattice_ray_hits`, the last crossing in `[w, w + 1)` that changes
   insideness, else the midpoint, as `crossing_on` does) gives axis distances `t` and `1 − t`. Each voxel keeps its
   smallest axis distance per axis `ax[3]` (∞ when none). Seed value `d = sign · 1 / sqrt(Σ 1/ax[i]²)`, exact for a plane,
   at most `min(ax)`; a voxel with no crossing within one voxel on any axis gets ±CLAMP. All seeds are < 1 voxel so
   `band_repair`'s seed pass keeps them; every candidate brick is `band_mark`ed; bricks that come out all one clamp
   collapse to tiles; bricks never candidates but inside (their x ray says so) become `TILE_INSIDE` (a serial walk over
   the x rays' inside intervals, per brick row).
5. `band_repair(c)` (made `@(private)` → package-visible already) solves the band; `surface_mark_all(c)`.
Memory: rays as in remesh (hits ~ 1.5 area / h²); bricks only in the band. Cost: dominated by the ray casts (the
remesh at the same lattice takes 0.3 s at 1M on the VM) and one repair of the whole band.

Tests (`voxelize_test.odin`): a geodesic sphere of radius 1 → `clay_from_mesh` at 64 and 128 across → `clay_to_mesh` →
`mesh_check` closed, every vertex within one voxel of radius 1 (the Hausdorff half) and `volume_sample` at 200 random
points within one voxel of the analytic distance; `geom.primitive` torus keeps its hole (the remeshed count of
components is 1 and Euler characteristic 0: V − E + F = 0); serial equals parallel; an open mesh (a triangle) returns
false; a mesh too big for the domain returns false. Bench: `run_voxel` gains a "from mesh" column (ms) at each size.

### app
- `Scene_Command_Kind.Mesh_To_Voxels`; `Command_Id.Convert_To_Voxels` ("Convert to voxels", enabled for a selected mesh
  object; home `.Voxels`); `Kit_State.voxel_across: int` (remembered setting `voxel_across`, default 0 = the size the
  object's vertex count maps to through `voxel_resolution_for`); `kit_voxels` for a mesh object: a "Voxels across"
  slider (32..1024, whole nodes) with the vertices it would mesh to, the Convert to voxels button.
- `object_mesh_to_voxels(app, obj, across) -> bool`: `stroke_finish`, `object_hd_leave`, source = the current level's
  mesh compacted when dynamic (as `object_remesh`), `voxel.clay_from_mesh` with `voxel_size_for(bounds, across)`;
  `log.warn` + true when it fails; else `WaitForGPUIdle`, `object_release_mesh` (levels, layers, mask, strokes go),
  `voxel_part_attach`. `scene_apply` records the swap exactly like `.Voxel_To_Mesh`.
- `Voxel_Part.resolution` keeps its meaning "voxels across the object's longest extent at creation" (a sphere is 2 across
  → 2 / resolution a voxel; a converted mesh its extent / resolution).
- Objects card Actions menu: "Convert to voxels" beside the existing items; README "Voxel sculpting" paragraph; touch
  scenario `voxel_mesh_converts_to_voxels_and_back` (Convert to voxels via the palette, a stroke, Ctrl+Z twice).

## Stage 4: Res+ and Res−
```
// Rebuilds the clay at `factor` times the voxels along each axis (2 or 0.5): the new band is sampled from the old field
// (trilinear, distances rescaled) and solved again by band_repair. The surface moves by under a quarter voxel (RMS)
// at 2 and by what the coarser lattice can hold at 0.5.
clay_resample :: proc(c: ^Clay, factor: f32) -> bool
```
Steps: new `Volume` with `voxel' = voxel / factor`, same `origin`-centre (the domain stays centred: new origin =
centre − DOMAIN/2 · voxel'). Candidate new bricks: at 2, the 8 children of every old brick; at 0.5, the parent of every
old brick (sorted, unique, serial). Parallel per candidate brick: each new voxel's value = `volume_sample(old, centre) ·
voxel / voxel'` quantized, from the OLD volume (read only); bricks all one clamp collapse to tiles; tiles of the old
volume map onto whole new bricks (children of an Inside brick are Inside). Then `band_repair` over every new brick
(all `band_mark`ed), `surface_mark_all`. The old volume, surface and undo history are destroyed: the app records the
whole thing as a swap entry, so the clay's own steps go (`clay_clear_history` first; the History's `object_forget_history`
semantics). Resolution bounds: `VOXELS_MIN ≤ resolution · factor ≤ VOXELS_MAX` checked in the app.
App: `Scene_Command_Kind.Voxel_Resample` with `cmd.voxels` = the new resolution; `Command_Id.Voxel_Res_Up`/`Voxel_Res_Down`
("Res+", "Res−", 3D-Coat's names); `kit_voxels` shows the multiplier row "×2 → 512 across (~1.4M vertices), ÷2 → 128";
`Voxel_Part.resolution` doubles or halves; Objects card row shows "voxels · R" for voxel objects (its vertex count
column already shows the surface). Not over frames: measured synchronously first (the bench row "Res+ ms"); the roadmap's
"over frames with a preview" is dropped unless 512 → 1024 is over the frame budget by a lot on the RTX.
Tests: sphere at 128 → ×2 → every surface vertex within 0.25 voxel RMS of radius 1 and `mesh_check` closed; ×2 then ÷2
returns a field within one coarse voxel; serial = parallel.

## Stage 5: Manifold surface
Why naive nets fail: a lattice face whose corners are (+, −; −, +) (a saddle: diagonal inside corners) has four crossings
and two face segments; when the same cell loop uses both (the inside is connected through the other faces) the two
cells sharing the face share two dual edges and the surface edge is in four quads. One vertex per cell also pinches at
cells with two separate loops.
Design (two rules, both local to the field and the cell, so node copies still agree bit for bit):
1. **No saddle faces in the field.** After every dab (the serial post-pass, over the dab's bricks and the +x/+y/+z faces
   into their neighbours) and after `clay_fill_sphere`, `clay_from_mesh` and `clay_resample`, `resolve_saddles` finds
   every 2×2 voxel face with diagonal signs and flips the inside corner with the smaller |d| to +1 (a thousandth of a
   voxel outside), which only ever turns inside voxels outside, so it terminates; the flipped voxel's brick is
   `undo_record`ed (a neighbour brick that is not a job brick too), `surface_mark_box`ed and `band_mark`ed. The band
   repair never changes signs, so it makes no saddles. A face then has 0 or 2 crossings: one segment.
2. **One vertex per loop.** `mesh_node` groups a cell's crossing edges into loops (edges sharing a face are joined; with
   rule 1 a face has at most one pair) and makes a vertex per loop at the mean of its crossings, normal from the
   gradient at that point. A quad for crossed edge e takes, in each of the four cells around e, the vertex of the loop
   holding e. Every dual edge is one face segment, hence in exactly two quads, and every vertex's fan is one cycle:
   closed and manifold. `cells` becomes `[]Cell_Verts{first: u32, loop_of_edge: [12]i8}`; `cell_vertex` stays
   `#force_no_inline`.
Acceptance: `--voxels=256 --bench-stroke=60 --check-mesh` reports `mesh_non_manifold_edges=0`; a test strokes a sphere
with every brush kind and asserts `mesh_check` closed and manifold on `clay_to_mesh`; a test plants a saddle in a brick
and checks `resolve_saddles` removes it with one flip. Cost: the saddle scan is 3 · 8³ face reads per job brick in the
post-pass (the window is already gathered for Smooth; the others gather the +1 faces only).

## Stage 6: Faster stroke end and conversion
Measure first (`build/bench --voxel 1024`): the stroke end (869 ms at 1024³) is `band_repair`: region size × 8 sweeps ×
(10³ gather + 512 updates). Changes, each measured before the next: (a) stop sweeping once every brick is settled
(a flag reduced after each sweep); (b) the region only takes bricks whose `Dab_Effect.repair` was set AND whose values
within the band changed sign or came from a blend (Add/Subtract bricks that only took stamp distances are distances
already) — tracked as `Dab_Effect.repair` already, so the gain is in (a) and in (c): sweeps gather the window from the
snapshot a brick at a time; gathering only the 6 face layers that changed is a later step if (a) is not enough.
Conversion (`clay_to_mesh`, 6.8 s at 1024³): the weld becomes exact and parallel. A vertex's identity is (its cell's
global coordinate, its loop); a cell belongs to the node containing it, so every border copy has one owner. The Surface
keeps, per vertex slot, a `u16` cell code (local cell index in 17³, 4913 < 65536, loop in the high bits) in
`Surface.cell_codes` (written by the flush copy pass). `clay_to_mesh`: pass 1 (parallel over nodes) each node sorts its
OWNED vertices by code into a per-node `[]Owned{code, index}` (heap); prefix sums give each node's base; pass 2
(parallel over nodes) maps each vertex: owned → base + rank, else binary search in the owner node's list (the owner is
found through the chunk table); pass 3 (parallel over nodes) writes triangles into per-node ranges counted in pass 2
(degenerate ones dropped before counting). No position sort. Targets: stroke end < 200 ms and To mesh < 1 s at 1024³ on
4 threads of the VM.

## Stage 7: Live booleans between voxel objects
The app's `Boolean_Mode` on objects stays the interface; when the base (`boolean_base`) is a voxel object, the boolean
runs on fields:
```
// `c` (uninitialised) becomes `base` combined with `other` placed by `place` (other's object space → base's), as op:
// Union = min(a, b), Subtract = max(a, −b), Intersect = max(a, b), per voxel of the base's lattice; `other` is sampled
// trilinearly at the base's voxel centres (distances scaled by `place`'s uniform scale), within its bounds only.
clay_combine :: proc(c: ^Clay, base: ^Clay, other: ^Clay, place: matrix[4,4]f32, scale: f32, op: Clay_Op) -> bool
```
Steps: `c` starts as a copy of `base` (bricks and tables copied in parallel, no history). The region is the bricks of
the base's lattice that `other`'s bounds (transformed) cover plus `BAND + 1`; new bricks are made from tiles where the
op can change them (Union into Empty, Subtract and Intersect into Inside); parallel per region brick: the op per voxel;
collapse, `resolve_saddles` (stage 5), `band_repair` over the region, `surface_mark_all`. A marked MESH object is first
voxelised on the base's lattice (`clay_from_mesh` with the base's voxel size and the mesh moved into the base's space,
`shape_in`) and freed after. Live preview: `boolean_live_update` for a voxel base builds the result clay when the stamp
changes (as for meshes: not during a stroke or a drag), meshes it (`clay_to_mesh`) into `Boolean_State.preview`; the
stamp hashes each clay (`clay_hash`, cached per object per stroke end) and the transforms. `boolean_make` replaces the
base's part with the result (swap entry) and deletes the marked objects, as the mesh path does. Marked objects may be
meshes or voxels; a mesh base with voxel marks keeps the mesh path (voxel marks converted with `clay_to_mesh`).
Tests: two overlapping spheres → union closed with volume between the larger and the sum; subtract leaves a watertight cut
(closed, volume less than the base's); intersect of disjoint spheres is empty (false, nothing made); serial = parallel.
Bench row: two 256 spheres, union ms.

## Stage 8: Masks, pictures, file size, culling (three PRs)
8a **Masks on clay**: `Volume.masks: [dynamic]u32` per brick slot → index into `mask_bricks: [dynamic]Mask_Brick`
(`[512]u8`, 255 = fully masked) or `MASK_NONE`. `Brush_Kind.Mask` paints the mask with the falloff (invert erases); every
other dab scales its effect per voxel by `1 − m` (Add/Subtract: `lerp(v, r, 1 − m)`; the rest scale `w`). Undo saves
mask bricks in the step as `Saved_Mask` beside `Saved_Brick`. Mask shows as the mesh brushes' mask does: the surface
vertex's mask = trilinear sample of the mask field, written into the vertex attribute the renderer already reads for
masks (checked against `render.VERTEX_BYTES` and the mask packing when built; if the voxel surface mesh has no mask
channel the `Mesh_Buffers` path for masks is reused). App: the Mask brush allowed on voxels (`voxel_brush_of`), Alt+M
clear and Ctrl+I invert (`sculptor_mask_command` paths branch to `clay_mask_command`), masks drop at Convert to mesh.
SVOX v2 writes a mask flag + bytes per brick (v1 still read).
8b **Picture and culling**: `thumb_key`/`thumbs_frame`/`thumb_camera` branch on `obj.voxel` (the part's `gpu` and the
surface's chunk bounds). `mesh_node` computes the node's normal cone (mean of vertex normals, cutoff = min dot) into
`Node.cone_axis/cone_cutoff`, and `surface_chunks_rebuild` passes it to `geom.Chunk` so the renderer back-face culls
voxel nodes as it does mesh chunks; a test checks every vertex normal of a node lies inside its cone.
8c **RLE in the file**: SVOX v3 writes each brick's 512 values run-length encoded (runs of equal i16 as `count: u8,
value: i16`, raw fallback when longer): a sphere file halves (most band bricks are mostly ±CLAMP). Read keeps v1, v2.

## Boundary check
`voxel` → `geom`, `jobs`, `core:` only (new: `geom.lattice_rays_*`, `geom.Aabb`, `geom.mesh_area_bounds`). `geom` gains
no imports. App files touched: scene.odin, commands.odin, voxel_object.odin, boolean.odin, object_thumbs.odin,
history.odin (mask commands), files.odin (no scene version change: the clay's own SVOX version moves), kit_*.odin,
palette.odin, settings.odin, results.odin, README, skills sm-sdf and sm-cad.

## Risks
- Undo: every whole-clay replacement (Convert either way, Res±, Make boolean) is a swap entry serialising the clay
  (`object_put`), 146 MB at 1024³, as the mesh remesh already serialises 10M-vertex levels; `history_record_swap` drops
  old steps past the limit. Caught by the touch scenarios' undo/redo checks.
- Determinism: all parallel passes write disjoint bricks or nodes and read either the old volume or a snapshot; the
  serial-equals-parallel tests extend to voxelize, resample, combine.
- Dirty ranges and damage: `surface_mark_all` after a rebuild; the app's `voxel_upload` already remakes the GPU copy on
  `regrow`.
- The saddle rule moves the surface by a voxel at thin diagonal necks only; a test measures the volume change of a
  sphere under random strokes stays under 0.1%.
- Cost at 1024³: voxelize and resample are one band repair plus casts, bench rows say; To mesh and stroke end have targets.
