# PR 3 design: the Quad Remesh command (AutoRemesher engine behind Retopologize)

## Request
Rebuild's Quads (command `.Retopologize`, scene command `.Retopo`) gets a second engine: AutoRemesher through
`src/quadmesh` (PR 2). The new object keeps the polygons it was built from (quads and the few triangles and n-gons
AutoRemesher leaves) as the base level's `Polys` with the Catmull-Clark rule, so Wireframe shows polygon edges (PR 1) and
Subdivide keeps quads. UVs are laid out as before when every polygon is a quad. The user-facing name becomes
"Quad Remesh"; the script verb `retopologize` and the section `.Retopo` stay. Not in this PR: symmetry, Close first,
adaptivity or a rule choice (PR 4); any change to the voxel Remesh (PR 5).

## Current state
- `src/app/retopo.odin`: `object_retopo(app, obj, quads)` (sync) = `object_shape` → `retopo_compute(view, quads, pool, progress)`
  (`bvh_build_morton`, `geom.mesh_retopo` share {0, 0.9}, `quad_uv_unwrap`, `quad_mesh_triangulate`) →
  `retopo_apply(app, obj, &r, start)` (`scene_add_mesh` with `old_to_new`, remaps `q.quads`, `levels_set_quads`,
  `levels_set_uvs`, `report(.Retopo, "Retopologized ...")`).
- `src/app/long_job.odin:242-246, 359-362`: the same halves on the job thread (`j.input` a copy with fresh normals,
  `j.pool`, `j.progress`); the thread never reads `app.ui`.
- `src/app/scene.odin:337-358`: `scene_add_mesh` / `object_from_mesh` take `old_to_new` but not `tri_from`;
  `object_build_from` (`:1320`) takes both and `sculpt.levels_init` fills them (vertices renumbered by node, triangles
  reordered).
- `src/sculpt/levels_cc.odin:94`: `levels_set_polys(l, polys, sharp, rule) -> bool` needs one level, `rule != .Loop`,
  `first[0] == 0`, `first[last] == len(corners)`, `len(tri_poly) == triangles`, each triangle's corners in its polygon;
  takes ownership (frees on failure). `levels_polygon_source` (PR 1) reads polys first, else the base quads.
- `src/quadmesh/quadmesh.odin:88`: `remesh(positions, indices, params, progress, share, allocator) -> (Polygon_Mesh,
  Report, Error, reason)`; `AVAILABLE` false on Android and the iPad.
- Sites that name the command: `rebuild.odin:35,156,171`, `commands.odin:1408-1412`, `adjust_last.odin:49,335,417`,
  `kit_help.odin:262`, `offers.odin:53`, `palette.odin:177`, `results.odin:113`, `long_job.odin:108`, `macros.odin:110-111`,
  `settings.odin:223-226`, README "Retopology, UVs and baking".

## Design
### Types (src/app/retopo.odin)
```odin
Quad_Engine :: enum u8 {Auto, Own}      // AutoRemesher (src/quadmesh), or the own edge-pairing retopology
QUAD_ENGINE_NAMES := [Quad_Engine]string{.Auto = "AutoRemesher", .Own = "Built-in"}
QUAD_REMESH_MAX_TRIANGLES :: 1_000_000  // more is decimated first (AutoRemesher takes seconds and hundreds of MB per million)
QUAD_REMESH_MAX_PIECES :: 256           // more parts than this is refused (each is an island it parameterizes alone)

Retopo_Result :: struct {
	q:         geom.Quad_Mesh,    // every polygon a quad: the quads over `mesh`'s positions (nil otherwise)
	how:       geom.Retopo_Report,
	uv:        geom.Uv_Layout,    // with `q`
	mesh:      geom.Mesh,
	polys:     sculpt.Polys,      // Auto: the polygons as the base level keeps them (first, corners, tri_poly over `mesh`)
	engine:    Quad_Engine,       // which engine made it (Auto may fall back to Own)
	faces, quads, triangles, ngons: int, // Auto's polygon counts
	capped:    int,               // Auto: triangles the input was decimated to first, 0 for none
	reason:    string,            // owned: why AutoRemesher was not used, "" when it was
	built:     bool,
	retopo_ms, uv_ms: f64,
}
```
- `Scene_Command.engine: Quad_Engine` (Retopo), set where the command is issued from `app.ui.retopo_engine`
  (rebuild_command, the `.Retopologize` command, adjust_last's rerun), as `vertices` is; the thread reads `j.cmd.engine`.
- `Ui_State.retopo_engine: Quad_Engine` (default Auto; settings row `{"retopo_engine", ..., Quad_Engine, 0, 0}`,
  script `set retopo_engine own`, macros' QUADS/RETOPO lists gain it).

### Procs
- `object_retopo(app, obj, quads, engine) -> (made, ok)` and `retopo_compute(view, quads, engine, pool, progress) -> Retopo_Result`.
- `retopo_compute` with `.Own`: unchanged. With `.Auto`, `quad_remesh_compute` (private):
  1. `geom.mesh_integrity(view, pool)` (progress 0–0.05). Refuse (reason kept) when `nan_count > 0`,
     `non_manifold_edges > 0`, `inconsistent_edges > 0`, `pieces > QUAD_REMESH_MAX_PIECES` or `triangles < 4`.
  2. Over `QUAD_REMESH_MAX_TRIANGLES`: `geom.mesh_decimate(view, MAX, pool, progress, share {0.05, 0.2})` into a mesh of
     its own (`capped`), else the view itself.
  3. `quadmesh.remesh(positions, indices, {quads, 0, 90, 0, 0, clamp(pool_size(pool), 1, MAX_THREADS)}, progress, {0.2, 0.85})`.
     `.Cancelled` → built false, nothing kept. `.Refused | .Failed | .Unavailable` → reason cloned, fall back below.
  4. Polygons to triangles (`polygon_mesh_triangulate`, private, pure): a triangle as is, a quad along its shorter
     diagonal (`geom.quad_split`), an n-gon as a fan from its first corner; `tri_poly` per triangle; vertices no polygon
     uses are dropped (AutoRemesher's output is expected whole; the compaction is a guard, remapping corners). Zero
     normals; `levels_init` computes them.
  5. `geom.mesh_check` on the triangles for the log (closed, non_manifold, inverted). An inverted closed result is
     flipped (reverse each polygon's corners and each triangle) before anything else uses it, since AutoRemesher's
     winding follows its input's but the sculpt expects outward.
  6. When `quads == faces`: `q = {positions copy, quads}`, `uv = quad_uv_unwrap(q, UV_PADDING)` (0.85–1); `mesh` is
     then `quad_mesh_triangulate(q)` (two triangles a quad, k → 2k, 2k+1) so `tri_poly[t] = t / 2`, and `polys` follows.
     Otherwise `q`, `uv` stay nil (no UVs: the report says so) and `mesh` comes from step 4.
  Fallback: the own path with share {0.2, 0.9}, `engine = .Own`, `reason` kept so the report says why.
- `retopo_apply`: `tri_from := make([]u32, triangles)` beside `old_to_new`; `scene_add_mesh(..., old_to_new, tri_from = tri_from, material)`
  (new `tri_from: []u32 = nil` parameter on `scene_add_mesh` and `object_from_mesh`, handed to `object_build_from`).
  Then `retopo_polys_renumber(&polys, old_to_new, tri_from)` (pure: `corners[i] = old_to_new[corners[i]]`, `tri_poly_new[t] =
  tri_poly_old[tri_from[t]]`), `sculpt.levels_set_polys(&twin.levels, polys, {}, .Smooth)` (a false is logged as an
  error and the polys dropped; the object stays a plain triangle object with its quads, as today), then as today
  `levels_set_quads` / `levels_set_uvs` when `q` exists. Report: "Quad remeshed %s: N quads (AutoRemesher), UVs in N charts,
  N ms" / "...: N quads, N triangles and N n-gons, so no UVs; ..." / "...(built-in: AutoRemesher REASON)".
- Memory: `Retopo_Result` owns everything until `retopo_apply` takes it or `retopo_result_destroy` frees it (`polys`,
  `reason` added to both). Scratch inside `quad_remesh_compute` is heap, freed before return (the job thread's temp
  arena is only freed by the thread itself, as today's `free_all` after `mesh_retopo`).
- Threading: `mesh_integrity`, `mesh_decimate`, `quadmesh.remesh` (its own threads, `pool_size` of them) and the own path
  take `pool`; the result is deterministic per build (quadmesh is bit-identical across thread counts; not across platforms,
  so no parity comparison uses it).
- Failure modes: refused/failed AutoRemesher → fallback + reason in the report (no error); cancel → as today (nothing
  made, "cancelled" note); `levels_set_polys` false → `log.errorf`, polys dropped, object kept; GPU failure → false as today.

### Interface and words
- Rebuild's Quads: under Density, `ui.tabs(ctx, "quad engine", {"AutoRemesher", "Built-in"})` when `quadmesh.AVAILABLE`
  (else no tabs: only the built-in exists), and the paragraph says which engine does what.
- Labels: command label "Quad Remesh" (help updated), `REBUILD_VERBS.Quads = "Quad Remesh (new object)"`, kit_help row,
  `ADJUST_OP_NAMES.Retopo = "Quad Remesh"`, `SCENE_REPORTS.Retopo = "Quad remeshed %s"`, `JOB_VERB.Retopo = "Quad remeshing"`,
  offers' button "Quad Remesh", palette aliases gain "retopologize autoremesher". Command id, script verb and section ids unchanged.
- README: the "Retopologize" paragraph becomes "Quad Remesh" (both engines, polygons kept, tabs, script setting, fallback).

## Boundary check
`app` already imports `quadmesh` (nothing new); `quadmesh` imports `geom` and `jobs` only; no new edge.

## Alternatives rejected
- A new `Scene_Command` kind `.Quad_Remesh`: doubles every site (adjust last, long job tables, macros, offers) for the same object outcome.
- Reading `app.ui.retopo_engine` on the job thread: the thread must not read interface state; the command carries it.
- Polys for the own engine too: `levels_polygon_source` already reads its quads; adding polys changes its subdivision rule, which is PR 4's choice.

## Risks
- `levels_set_polys` rejects a triangle outside its polygon: cannot happen with triangles derived from the polygons, and `tri_from` is applied before; the apply test checks the renumbering.
- Undo: Retopo records `history_record_added` as today; polys and quads live in the new object and go with it.
- 10M input: decimated to 1M first (seconds), then AutoRemesher (~1 min, hundreds of MB) on the job thread with cancel; the report says `capped`.
- An inverted or open result: `mesh_check` after; flipped when inverted; open when the input is open (as the own path).
- Loop subdivision assumption anywhere? `Levels.rule = .Smooth` is what the Model cage already sets; the sculpt operates on each level's triangles.

## Plan (one PR, ~400 lines)
1. `Quad_Engine`, settings row, Scene_Command field, `tri_from` passthrough — `check`.
2. `quad_remesh_compute`, `polygon_mesh_triangulate`, `retopo_polys_renumber`, fallback, `retopo_apply` — `check`, `src/app/retopo_test.odin`
   (Auto on an icosphere gives all quads, polys, UVs; a non-manifold fin falls back to Own with a reason; renumbering keeps each triangle in its polygon).
3. Labels, tabs, README — `check`, `test`, `smoke`, scripted run `set retopo_quads 1500; retopologize; wireframe on` with `poly_edges` = 2 × quads, `subdivide` keeps polygon edges; a described PNG.

## Open questions (defaults taken)
- Default engine: Auto (falls back to Own where it is not built).
- Refuse non-manifold input rather than try: yes (AutoRemesher can run forever on some); the fallback handles it.

## Review and as built (2026-10-30)
The architect review agreed with the shape and asked for four corrections, all taken: `retopo_apply` and
`retopo_result_destroy` free `polys` and `reason` on every path, and the reason is cloned to the heap (it comes back in
temp memory); Adjust last restores `retopo_engine` from the command it reruns, as it does `retopo_quads`; the rebuild
test sets the engine explicitly, so the compared command does not pass by the zero value; the decimation past the cap
runs before `mesh_integrity`, which has no cancel and a serial pass, and the check also refuses degenerate and
duplicate triangles. Its boundary note was right: `app` did not import `quadmesh` before this PR; the edge is new and
allowed (quadmesh is imported only by app). Verified: check, every package's tests (the palette test now expects
"Quad Remesh" for "zremesher"), smoke, and scripted runs: `set retopo_quads 1500; retopologize; wireframe on` gives
1,202 quads, `poly_edges=2404`, `levels_rule=Smooth`, closed and outward; with `subdivide` after it, 4,808 quads on
the Catmull-Clark level (`poly_edges=9616`); `set retopo_engine own` gives 1,504 quads with `levels_rule=Loop`.
Pictures: pr3_quad_wire.png (the quad flow with its few singularities) and pr3_quad_subdivided.png.
