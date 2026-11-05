# Phase 6 item 7: layers at any level, reproject layers after Rebuild

Roadmap row: "Layers at any level; reproject layers after Rebuild" (Z089 ZBrush 3D Layers, N017 Nomad Layers; findings:
ZBrush makes layers at the top level only and adding levels moves them one way; Nomad's layers survive topology change).

## Today
- `src/sculpt/sculpt_layers.odin`: layers belong to one sculptor (one level). Positions always hold base + Σ w·delta;
  delta per node, nil where unused. Add/remove/bake/set are undo steps; a recording stroke saves the old delta.
- Any level can already have its own layers (unlike ZBrush), saved per level in `.sculpt` (LEVELS_LAYERS).
- Gaps:
  1. **Rebuilds lose layers.** Remesh, Decimate, Mirror and weld, Slice, Make boolean go through
     `object_release_mesh` + `object_build_from`: the new mesh is built from the shown positions, so the layers'
     work stays in the shape but the layers (names, sliders, REC) are gone. Dynamic topology on bakes them.
  2. **Subdivide leaves the layers behind.** The new top level is built from the old top's positions (layers
     included) but has no layers; the sliders stay on the level below, where dialling them moves that level and the
     sync carries it up as plain movement. ZBrush moves the layers up.
  3. **Delete higher drops the deleted levels' layers** (their work survives in the current level through the sync,
     as plain sculpting).

## What the user gets
1. **Layers survive Rebuild** (Nomad): after Remesh, Decimate, Mirror and weld, Slice (each part) and Make boolean
   (the base object), the object keeps its layers of the level it was rebuilt from: names, strength, visibility,
   recording. Each new vertex's displacement in a layer is the old displacement at the nearest point of the old
   surface (barycentric over the old triangle's corners). The shape is unchanged by it (positions are the rebuilt
   shown surface, which already holds the layers' work); dialling a layer afterwards moves the new mesh as it moved
   the old one. A new vertex farther than `REPROJECT_REACH` (4 old mean edge lengths) from the old surface (a
   boolean's other operand) gets none. Mirror and weld: a vertex on the mirrored side takes the mirrored kept-side
   displacement (query at its reflection, reflect the delta), so the result is symmetric like the shape.
   The rebuild's note says "kept 2 layers". Turning dynamic topology on still bakes them (its strokes renumber).
2. **Subdivide moves the top level's layers up** (ZBrush): the new top level gets each layer of the old top with
   its displacement carried up as the mask is (a vertex continuing one below takes its delta, an edge vertex the mean
   of the edge's ends), recording kept; the old top keeps its shape with the layers gone from its list (baked, which
   moves nothing). Subdivide becomes an undo step (a swap entry, `history_snapshot` before it) when the top level
   has layers, so undo brings the layers back where they were; without layers it stays as now (not an undo step).
3. **Delete higher carries the top level's layers down** to the new top (the current level): a vertex takes the delta
   of the vertex it became (`even_of`), as the mask goes down; appended after the current level's own layers, up to
   MAX_SCULPT_LAYERS (the rest are baked, with a note). It is already a swap entry.
4. README: Layers section ("each level has its own layers" stays; plus moving up/down and surviving rebuilds), the
   rebuild notes.

## Data and code
- geom: `bvh_closest(b, m, p, max_dist) -> (tri, bary, dist, ok)`: branch-and-bound nearest point on the triangles,
  stack per call (thread-safe, no allocation inside jobs beyond a fixed stack array).
- sculpt (`src/sculpt/layer_carry.odin`, new):
  - `Layers_Kept :: struct {positions, indices (copies), bvh, layers: []Kept_Layer{name, strength, visible,
    delta: []Vec3 per vertex (nil when unused)}, recording}` taken by `sculptor_layers_keep(s, allocator)` (flattens
    per-node deltas into per-vertex arrays; compacts dyntopo away: refused with dyn on, since enabling bakes them).
  - `sculptor_layers_reproject(s, kept, mirror: Maybe(Axis) = nil) -> int`: parallel over new nodes: closest query
    per vertex, interpolate each layer's delta into a per-node delta (nil when all zero), append layers (no undo step:
    called on a fresh sculptor right after the build, whose history is empty), set recording. Deterministic: per
    vertex, no order dependence.
  - `levels_subdivide` gets `carry_layers` (move up as described); `levels_delete_higher` carries down.
- app: each rebuild proc takes `kept := sculpt.sculptor_layers_keep(...)` before `object_release_mesh` and
  reprojects after `object_build_from`; Slice reprojects both parts; boolean the base. Subdivide records a swap when
  the top has layers. The rebuild notes mention kept layers.
- Undo: rebuilds are swap entries whose snapshot (object_put) already holds the old object with its layers; redo
  swaps the new object (with its reprojected layers) back. Adjust last operation re-runs the rebuild from before and
  reprojects again, deterministically.
- Files: no change (layers are per level already).

## Cost
- Reproject: one BVH over the old mesh (built anyway? no: the old sculptor's BVH is freed with it; keep a copy or
  build a fresh one, ~0.2 s at 10M), a closest query per new vertex (parallel), L·12 bytes a vertex. Target: under
  10% of the rebuild's own time at 1M; measured with `--remesh` and `--layer`.
- Subdivide carry: one pass over the new level per layer (parallel), same as the mask carry.

## Tests
- sculpt: keep → reproject onto the same mesh gives the same deltas (bit-identical where vertices coincide);
  onto a remeshed sphere, dialling a layer to 0 gives (within tolerance) the remesh of the surface without the layer;
  mirror keeps symmetry; far vertices get none; serial = parallel.
- levels: subdivide with a layer: dialling it on the new top to 0 matches subdividing the base without it (within
  tolerance); undo of the subdivide swap restores; delete higher carries down.
- app: Remesh keeps layers (count, names, strength), note says so; undo brings the old object with its layers.
- Scenario: `--layer` + stroke + Remesh by palette, then the layer slider to 0 moves the mesh (mesh_sum changes).

## Split
- 7a: reproject after rebuilds (geom closest query, sculpt keep/reproject, app rebuild paths, tests).
- 7b: subdivide moves layers up (swap entry when layered), delete higher carries down.

## Open questions (defaults taken)
- Copy layers up on Subdivide instead of moving them (no undo change, but two sets of sliders that drift apart)?
  Default: move, with a swap entry.
- Reach for far vertices: 4 mean edge lengths of the old mesh. Default as stated.

## Architect review (2026-10-26), adopted
- R1 Subdivide carries each layer up with Loop's own weights (`loop_origin(below, par)`, same weights as levels.odin
  ~456/460), not the mask's rule, so "subdivide then layer to 0" = "layer to 0 then subdivide". `frame_at` untouched.
- R2 Delete higher carries down with the push-down weights (half own change + half neighbours' mean, level by level),
  from each deleted level that has layers (the in-between ones too), before `level_free`.
- R3 Subdivide on a layered top: snapshot after the refusals, `levels_subdivide`, then `history_record_swap` +
  `object_forget_history` (sculptor steps hold layer indices); `history_snapshot_drop` on failure; `.Subdivide` in
  SCENE_REPORTS; note + README say earlier strokes of the object can no longer be undone.
- R4 `stroke_finish` ends an open layer-slider drag; keep/carry procs end an open sculptor stroke first.
- R5 Reach = 4·max(old, new mean edge), weight fading 1→0 over its last half.
- R6 Fresh `geom.bvh_build_morton(mesh, BVH_LEAF_SIZE, pool)` for queries; fixed `[64]u32` stack (Morton depth ≤ ~55);
  `closest_on_triangle` promoted from simplify_test into geom.
- R7 Layer arrays allocated on the calling thread (history allocator): jobs flag used (layer, node), then allocate, then fill.
- R8 Keep `named`; no layers → return before any BVH; Mirror and weld zeroes the axis component on the plane; nothing kept in temp.
- Suggestions taken: project before `object_release_mesh` while the old sculptor lives (no flatten/copy), mapping
  through `old_to_new`; a reusable surface map (old tri, bary, weight) per new vertex; `layers_kept` note counter and
  "N layers on other levels went"; count layers in `object_put_estimate`; `object_forget_history` clears the recall
  target; Layers panel text updated.
- Plan: 7a1 geom closest query; 7a2 sculpt surface map + projection; 7a3 app wiring of the five rebuilds; 7b1 delete
  higher carry-down; 7b2 subdivide carry-up + swap + forget + slider-drag fix (re-review).
