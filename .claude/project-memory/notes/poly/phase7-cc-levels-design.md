# Phase 7 design: Catmull-Clark levels (sm-architect, 2026-10-28)

**1. Request**
Phase 7 connects Model mode to sculpting. Apply to sculpt turns a cage with Smooth N into levels 0..N: level 0 is the cage cut into triangles, and each level above is one Catmull-Clark step with creases. Those levels sync up and down the way Loop levels do. Two more pieces follow: a retopologized object can become a cage, and a sculpted object's cage can be edited later without losing the detail.
It is not Catmull-Clark HD, not UVs for n-gon cages, and not Model mode running on top of levels.

**2. Current state**
- **Levels are Loop only.**
  - `Level{parents [4]u32, detail, even_of, deps, dependents}` is at `src/sculpt/levels.odin:34`.
  - The `EVEN` tag is at `:65`.
  - `frame_at` is `#force_no_inline` and only knows the Loop rule (`:465-494`). `recode_level` (`:414`) and `push_down` (`:318`) read it through `Loop_Base` (`:449`).
  - `level_above` (`:539`) splits each triangle in four (`:651`), refuses an open mesh (`:609`) and calls `sculptor_init`, which renumbers (`:656`).
  - `link_levels` lists the nodes a level depends on through the Loop parents only (`:715`).
- **Other code reads `parents[2] == EVEN`:**
  - groups: `level_tri_parents`, `src/sculpt/groups.odin:360-391`, and the downward carry at `:419`
  - layer carry: `src/sculpt/layer_carry.odin:497-509`
  - file order: `level_canon`, `src/sculpt/levels_file.odin:471-528`
  - mask carry: `carried_mask`, `src/sculpt/mask.odin:622-627`
  - colour carry: `src/sculpt/paint.odin:291`
  - The mask and colour carries use only `p[0]` and `p[1]`.
- **HD builds its own Loop patches**, separate from the levels' base (`src/sculpt/hd.odin:64`, `:76`). Retopologized quads live in `Levels.faces` (`levels.odin:56`, `levels_quads.odin:10`).
- **Files.** Upper levels are rebuilt by `levels_subdivide` while reading (`levels_file.odin:391`), checked against `levels_subdivide_estimate` (`:388`, `levels.odin:191`). The node-layout block comes first (`levels_file.odin:123`, `:358`).
- **Catmull-Clark in the cage code.**
  - `poly.subdivide` numbers each step's points as vertex V, edge point V + e, face point V + E + f (`src/poly/subdivide.odin:10`).
  - It makes each face a ring of quads ordered (vertex, edge, face, edge) (`:120`).
  - Creases step down by 1 a step (`:129`, `:136`). The vertex rule is at `:178-221`.
- **Cage objects.**
  - `object_build_cage` cuts the smoothed cage with `poly.triangulate`, which picks a quad's shorter diagonal (`src/app/model.odin:101`, `src/poly/triangulate.odin:36-45`).
  - `object_apply_cage` only frees the cage (`model.odin:216`). It is a swap entry (`src/app/scene.odin:802`).
  - Retopologize builds a new object with quads and UVs (`src/app/retopo.odin:65-108`).
  - Project detail exists already (`src/app/project.odin:33`). It records its own undo step (`:99`).

**3. Design**
**Rule on the Levels, polygons on each Level.** In `src/sculpt/levels_cc.odin`:
- `Subdivision_Rule :: enum u8 {Loop, Smooth, Flat}` is stored as `Levels.rule`. Every level above the base follows it. Smooth and Flat need the base's polygons.
- `Polys{first, corners, tri_poly: []u32}` is stored on each level whose rule is not Loop. Polygons are counter-clockwise lists of corners; `tri_poly` gives each triangle's polygon. Level 0 holds the cage's n-gons, and every level above holds quads.
- `Sharp{edges: []u64 sorted (lo<<32|hi), edge: []f32, verts: []u32 sorted, vert: []f32}` holds each level's creases and corner sharpness.
- `levels_set_polys(l, polys, sharp, rule) -> bool` works on a single-level object, takes ownership, and frees and returns false on a size mismatch.
- `level_free` and `level_unlink` free both.

**Parents keep `[4]u32`.**
- A vertex point is `{v, neighbour, EVEN, 0}`.
- An edge point is `{a, b, f1, f2}`.
- A face point is `{c0, c2, FACE, f}`, with `FACE :: max(u32) - 1`.

Because `p[0]` and `p[1]` keep the same meaning, `carried_mask`, the colour carry and selection-set restore need no change.

**Frames.**
- `Loop_Base` gains `polys`, `sharp` and `rule`. HD leaves them nil, so HD stays Loop.
- `frame_at` begins with `if below.polys != nil do return frame_cc(below, par)`. `frame_cc` is also `#force_no_inline` and uses `poly`'s exact arithmetic.
- At a vertex point it visits the polygons of `vertex_faces(v)` in ascending order, keeping each the first time it appears. That order is deterministic.
- Each polygon adds its face point and its two edge midpoints. On a closed mesh each edge is counted twice, so no edge ids are needed.
- Sharpness is a binary search, skipped when `Sharp` is empty.
- Normals: the triangle ring at a vertex point, `cross(b-a, fp1-fp2)` at an edge point, Newell's normal at a face point.

**Building a level.** `level_above` dispatches to `level_above_cc` when `l.rule != .Loop`.
- It numbers points as `poly` does and emits quads in parent-polygon order, so polygon ids do not depend on renumbering.
- Each quad is split on the fixed vertex-to-face-point diagonal, so triangles depend on topology only. Files rebuild the same triangles.
- It decrements, splits, renumbers and sorts `Sharp`.
- It runs the same closed check and calls `link_levels`, which gets a Catmull-Clark branch that lists every polygon corner read. That includes the far corner of a quad, which is in no triangle at the vertex.

**Branches elsewhere.**
- `levels_subdivide_estimate` counts exactly V + E + F.
- `level_tri_parents`: going up, a triangle takes its face-point corner's polygon and that polygon's first triangle. Going down, each triangle takes the group of its polygon's lowest-numbered child.
- `layer_carry`: the rule is linear, so `frame_cc`'s origin is run over a flat temporary array of displacements.
- `level_canon`: vertices first, then polygon edges by their lower placed end, then face points in polygon order.
- `levels_dyn_enable` drops the base's polygons and sets the rule to Loop. `levels_delete_lower` keeps the new base's quads.

**What follows.**
- Subdivide adds a Catmull-Clark level whenever the rule is not Loop.
- HD stays Loop steps above the top level.
- Quads and UVs: Apply on an all-quad cage sets `Levels.faces` from the cage's quads.

**Files.**
- `LEVELS_CC = 64`: right after the layout come the rule byte, the base's polygons, `tri_poly` and `Sharp`, in the base's own order.
- `levels_read` needs `tri_from` from `levels_init` to remap `tri_poly`.
- `SCENE_VERSION` goes to 29.
- A damaged block makes the read return false.

**App, Apply** (`model.odin`). This is still one swap entry.
- `poly.triangulate(&cp.mesh)` runs over the cage itself, with groups taken from `tri_face`.
- Then `object_build_from`, `levels_set_polys` (through `vert_of`/`tri_from`), N × `levels_subdivide`, and `object_show_level`, as the starter path does (`scene.odin:300-312`).
- Model mode draws the subdivided steps with the same fixed diagonal (a parameter on `poly.triangulate`), so stepping levels shows what Smooth showed, to within float rounding.
- An open cage, Smooth 0, or a refusal falls back to today's single level, with a note.

**Retopology result as a cage: the Edit cage command (`Scene_Command.Edit_Cage`).**
- It applies to an object whose base has `Polys` or `Levels.faces` quads.
- It builds `poly.mesh_from_polygons` from the base positions and polygons, then adds groups and creases from `Sharp`.
- `Cage_Part.uv` keeps the retopology UVs until an edit changes topology; moves, creases and look changes keep them. They are saved with the cage (version 30).

**Editing the cage under levels**, as ZBrush's Freeze Subdivision Levels does. This is a later step.
- When levels are above the base, Edit cage first makes an eye-off duplicate as the source and stores its id in `Cage_Part.source`. It records an added entry plus a swap, chained (`history.odin:173`).
- On Apply, if the polygons are unchanged: set level 0 from the cage, refresh `Sharp`, sync up. The detail rides along exactly.
- Otherwise: build the levels, run project detail without its own record from the source's top level onto the new top, run `levels_sync`, and delete the source, all chained.

**Threading.** Every new loop goes through `parallel_ranges`/`parallel_for` over vertices, triangles or nodes, with heap lists in `link_levels` as now. The outputs are ordered by index, so they are deterministic.

**4. Boundary check**
- `sculpt` imports `poly` only in tests, which sm-lint allows ("`sculpt` may import `poly`").
- `app` already imports both.
- No new package.

**5. Alternatives rejected**
- **Precomputed Catmull-Clark weights per vertex:** about 50 B/vertex more at 10M, and canon and carry would still need the topology.
- **A `poly.Mesh` per level with `subdivide_positions`:** about 90 B/vertex, serial over the whole mesh, and no node-local sync.
- **Model mode running on levels:** rewrites the drawing and picking maps (`model.odin:48-68`). Not the smallest step.

**6. Risks**
- **Stale upper levels** if `deps` misses a polygon corner. Caught by a new test that moves a quad's far corner and expects the level above to update, plus a Catmull-Clark version of `synced_levels_stay_consistent` (`levels_test.odin:259`).
- **Determinism:** a Catmull-Clark version of `parallel_levels_match_serial` (`:295`) with a pool of 3.
- **`push_down` and canon assume a closed mesh** (`levels.odin:364`). Open cages fall back to one level.
- **HD with no detail is a Loop surface over Catmull-Clark quads.** The change is sub-pixel; README says so.
- **Memory:** about +28 B/vertex for each level's polygons, roughly 20% at a 10M top level. Measured with `levels_bytes` and a bench row.
- **Sync time** is about 1.5× Loop. A Catmull-Clark row against Loop in `build.bat bench` at 1M and 10M.
- **Model mode's drawn triangles change.** The `parity_check` cage scenes will differ on purpose.
- **Undo:** Apply and Edit cage are swap entries, and the projection is inside them.
- **Files:** `levels_file_refuses_damage` gets a Catmull-Clark case.

**7. Plan** (each step at most about 300 lines)
1. **Types and frames** (~250 lines). `levels_cc.odin` types, `frame_cc`, dispatch in `frame_at`, `levels_set_polys`, freeing. Test: frames on a cube match `poly.subdivide_positions` within 1e-6. Evidence: check, test.
2. **`level_above_cc` and link branch** (~300 lines). Builder, `Sharp` stepping, the `link_levels` branch, the estimate. Tests: cube, a prism with n-gons and triangles, creases of 2 and infinite, a corner, three levels within 1e-5 of `poly`; serial equals parallel; the far-corner sync test; `mesh_check` closed.
3. **Carries** (~250 lines). Groups, layers, dynamic topology, delete lower. Tests: mask, colour, groups, sets and layers carried on Catmull-Clark levels.
4. **Files** (~200 lines). `LEVELS_CC`, the `level_canon` branch, the read path, `SCENE_VERSION` 29. Tests: round trip keeps every level bit for bit; damage refused.
5. **App Apply** (~200 lines). Apply builds levels, the fixed diagonal in Model mode, quads for an all-quad cage, README, a `levels_rule` exit stat. Evidence: smoke; dump Smooth 2 against the applied level 2 and run `ppm.py diff` (expect about zero); `touch_check 'model_*'`.
6. **Bench** (~120 lines). Catmull-Clark against Loop for subdivide and sync, release build, at 1M and 10M.
7. **Edit cage from retopology** (~250 lines). Edit cage from quads, `Cage_Part.uv`, version 30. Tests in `app` for the round trip from retopology to cage to Apply, keeping quads and UVs; a touch scenario.
8. **Edit cage under levels** (~300 lines). The source copy, chained entries, ride-or-project on Apply. Tests: a points-only edit keeps the detail exactly; an extrude projects with more than 95% hits; one undo puts it all back.

**8. Open questions** (each with the default I would take)
- **Apply on an open cage:** one level, as today. Default: yes.
- **N-gon cages:** no quads or UVs. Default: yes.
- **Subdivide on a retopologized object:** stays Loop. Default: yes.
- **Flat look:** levels with the Flat rule. Default: yes.
- **Projection in step 8:** top level only, then sync down, with reach 0.1 of the size. Default: yes; projecting each level from the lowest up is the alternative.
