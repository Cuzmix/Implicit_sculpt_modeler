# UV4 design: auto seams and Unwrap (2026-11-05)

Goal: one tap gives any object UVs, as UV Master's Unwrap, Blender's Smart UV Project and
3D-Coat's auto seams do, with seams where they are least seen: the seams first, then
UV2/UV3's flatten (ABF++), relax and packing. The approved mock v2 puts Unwrap on the
Surface space's UV page (UE1, not built yet), so UV4 ships the engine and a Mesh card
row that runs it; the Surface page reuses the same command when UE1 lands (one UI per
thing: the Surface page's button and the row are one command, one undo).

## Engine (package uv): `auto_seams` and `unwrap`
- `Seam_Weights :: struct {crease, group, hidden: f32}` (defaults 1, 4, 2) and
  `auto_seams(u: ^Uvs, positions, indices, faces, groups: []u16 = nil, hidden: []f32 =
  nil, options, pool)`: chooses u.seam and finds islands.
  - Edge cost of cutting: low where an edge is a crease (dihedral angle, cut is hidden
    in the fold), on a polygroup border (users group by part), and where the surface is
    hidden (`hidden` per vertex in 0..1: the app passes its cavity/occlusion when it has
    it; none in UV4, so it is optional and tested with a synthetic one).
  - Charts by region growing (xatlas's and Lévy's D-Charts approach): seeds placed by
    farthest point, charts grown by a priority queue on normal deviation from the
    chart's average plus edge cost, a fixed tie order (lowest triangle). Then merged
    while the merged chart's normal cone stays under 60° and is still a disc.
  - Every chart is made a disc: Euler characteristic 1 and one border loop; a closed
    chart (no border) gets a cut along the cheapest path between its two farthest
    vertices; a chart with several border loops gets cut along the cheapest path joining
    them; a chart with handles is split by reseeding. Checked with `check`.
  - After flattening, an island whose worst stretch passes a limit (σ1/σ2 > 4) or that
    flips is split in two by reseeding and solved again (at most 3 rounds).
- `unwrap(u, positions, indices, faces, options, pool) -> Unwrap_Report`: auto_seams
  (unless `keep_seams`), flatten (ABF++), relax (a few iterations), pack; symmetry when
  asked. Deterministic, bit-identical serial and parallel.

## App
- `Scene_Command .Unwrap` with options from settings (`unwrap_relax`, `unwrap_symmetry`;
  `unwrap_keep_seams`), run as the existing long job copies (no topology change): it
  only writes Levels.uvs, so the undo entry is a new History kind `.Uvs` holding the old
  and new `uv.Uvs` (bytes: 8 per corner + 1 per triangle; the History budget counts them).
  This needs its own design note before code (History kind, AGENTS.md rule) and the UI
  needs a mock (Bolt's rule): a row "Unwrap" in the Mesh card's Surface group, with a
  fold for Relax, Symmetry, Keep my seams, beside the existing UV-dependent rows.
- Script verb `unwrap [relax N] [symmetry x|y|z] [keep]`, exit stats (islands, ms,
  stretch), `--unwrap` flag for checks; README.

## Tests and bench
- auto_seams: a sphere becomes discs (each island Euler 1, one loop), a cube cuts on its
  edges (six or fewer islands, every seam on a crease), groups become islands, a torus
  gets its two loops cut, hidden weights draw the seams there, bit-identical pools.
- unwrap: no flips, stretch bounded, every corner inside the square.
- bench --uv gains Sphere (closed) and Cube rows through unwrap; uv_check compares with
  Blender's Smart UV Project.

## Order
- UV4a: auto_seams + unwrap in the engine, tests, bench (no app code).
- UV4b: History .Uvs, Scene_Command .Unwrap, Mesh card row (after Bolt picks a mock).

## UV4b design (2026-11-05, after Bolt picked mock C)
- One command for UVs: `Scene_Command .Layout_Uvs` becomes `.Unwrap` (New UVs, which only
  laid a quad object out again with geom.quad_uv_unwrap, is replaced: one UI per thing).
  It works on any mesh object (not voxels, not under dynamic topology: its base
  triangles change under a stroke).
- Quads kept whole: `auto_seams` takes `partner: []i32` (each triangle's other half of its
  quad, -1 for none): a triangle's partner joins its chart with it and a disc split keeps
  pairs on the lower one's side, so no seam cuts a quad's diagonal and uv.to_quads (bake,
  texture views, quad exports) reads the result as before.
- Undo: no new History kind. The existing `.Textures` step (Texture_Step.uvs/has_uvs,
  textures_replace with `uvs`) already swaps the object's UVs and its maps (which followed
  the old UVs and go, as New UVs did). Label "unwrap".
- Long job: objects of LONG_JOB_MIN_VERTICES or more run on the job's thread, reading the
  base level in place (the scene holds still, as Remesh borrows its level); smaller ones and
  scripts run at once. `unwrap` gains `progress: ^jobs.Progress` (seams 0-0.15, flatten
  to 0.8, relax to 1) and stops between stages when cancelled. The result `uv.Uvs` is made
  with the levels' allocator and taken by textures_replace on the frame thread.
- Options from settings: `unwrap_relax` (0-20, default 5), `unwrap_symmetry` (0 off, 1-3
  x/y/z), `unwrap_keep_seams` (only offered when the object has UVs).
- UI (mock C): a "UVs" section in the Mesh card's Surface group in place of the bake
  section's New UVs button: Unwrap (primary), help line, Relax slider, Symmetry tabs, Keep
  my seams switch, readout (islands, stretch, filled). Bake's and Textures' "has no UVs"
  paragraphs become one ask that opens the UVs section (Open_Section).
- Script verb `unwrap [relax N] [symmetry x|y|z] [keep]`; exit stats `unwrap_ms`,
  `unwrap_islands`; README.
