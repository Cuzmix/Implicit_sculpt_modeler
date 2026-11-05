# PR 5b design: Quads for Remesh (the dual of the marching cubes)

Part of the Remesh / Quad Remesh roadmap (report https://claude.ai/artifact/Y7oLGn8QV2MmegNP2uYWgV, section 8, PR 5b),
approved by Bolt 2026-10-30 07:09. PR 6 (corpus script + bench) follows.

## What exists when it is done
Remesh gains a **Quads** switch (under More options with Smooth, Keep detail and Groups; setting `remesh_quads`; in the
`Scene_Command`'s `Remesh_Setup`). With it on, the remesh's output is a closed manifold mesh of quads only, kept as the
object's polygons (`Polys`, rule Smooth, so Divide gives Catmull-Clark quads and the wireframe draws quad edges) and as
`Quad_Faces` (so OBJ/USD export and UV layout see quads), as DynaMesh's quad-dominant output and Blender's voxel remesh
give. Vertex count stays about the Density asked. `bench --remesh` gets the quads path's time beside the triangles', and
README's table both.

## Why this construction is manifold and all quads
Marching cubes (`remesh_run`) builds, per cell, loops of crossing edges (`mc_build_table`), each fanned into triangles: one
loop is one surface patch through the cell, a disk. Its dual: **one vertex per loop** (at the mean of the loop's crossing
points, as surface nets place it) and **one quad per crossed lattice edge** (one per marching cubes vertex), whose four
corners are the loops that use that crossing in the four cells around the edge. Each crossing belongs to exactly one loop
in each of its four cells, so every face has four corners; a dual edge is a marching cubes face edge (two crossings on a
lattice face joined by the table's rule), shared by exactly the two cells on that face, so every quad edge has exactly two
quads; a loop's crossings run around it in a cycle, so every vertex's quads form a cycle. The ambiguous faces that make
plain surface nets non-manifold (four crossings on a face, four quads on one cell-pair edge) are resolved because the two
patches through such a cell are two loops, hence two vertices. No new table: `mc_build_table` also records each case's
loops (`mc_loops`, `mc_loop_edges`).

## Design (geom, `src/geom/remesh.odin`)
- `Remesh_Options.quads: bool`; `Remesh_Report.quads: [][4]u32` (in the output's vertex numbers, the caller's allocator;
  output triangle `2q` and `2q + 1` are quad `q`'s two halves, `quad_split`'s shorter diagonal).
- `remesh_run(..., smooth, quads: ^[][4]u32 = nil)`: with `quads`, after `place_vertices` (the crossings' positions are
  still needed for the loop means) `dual_cells` runs instead of `march_cells`: per slab in parallel, the same column walk
  as `march_column`, but per cell and loop it appends a dual vertex (loop mean) to the slab's list and, per crossing of the
  loop, an entry `(crossing, slot, local vertex)`; `slot` is the cell's place around the crossing's lattice edge (its side
  in the edge's two other axes), a fixed table per cell edge. Slabs are prefix-summed and a second parallel pass writes
  `corner[4 * crossing + slot] = base + local` (four distinct words per quad, written from up to four slabs, no race). Each
  quad's corners are then ordered around its edge's axis and turned so the quad faces outward, from which end of the edge
  is inside (`mc_case`'s corner bit of the edge's low corner), which the cell knows. Every slot must be filled (the mesh is
  closed) or the dual is refused and the run returns not ok.
- Positions: the dual vertices replace the crossings as `out.positions`; `relax_quads` (the same tangential step as
  `relax`, neighbours from the quads' edges, normals from the quads' diagonals, double-buffered rounds, a last pass for
  the normals) replaces `relax`; `out.indices` is `quad_split` of each quad, two triangles a quad, in quad order.
- Counts: quads = crossings ≈ 1.5 A / h² ≈ the Density asked; vertices = quads + 2 on a sphere, so the slider means the
  same. Memory: the slab lists hold 4 entries a crossing (12 bytes) and a Vec3 a loop, freed before the triangles are made.
- Closed first, turned outward, Keep detail (per vertex, after the quads are built), Groups (`remesh_groups` offsets each
  piece's quads by the pieces before it and concatenates them) all compose with it unchanged.
- Determinism: every slab's lists are in cell order, prefix sums are serial, corners land in fixed words, `relax_quads`
  reads one buffer and writes the other with per-vertex neighbour lists built in quad order; the bit-identity test gains
  the quads cases.
- Tests: a sphere's quads are all 4 distinct corners, every quad edge in exactly two quads one way each, V = Q + 2, each
  triangle's corners within its quad, deviation under 0.6 h, normals outward, count within 30 % of the target, volume
  near the ball's; a bowl (capped first) and two groups with quads; valence histogram logged (the share of 4-valent
  vertices reported, no pole reduction in this PR); smooth 0 and 8; serial = parallel bit for bit.

## Design (app)
- `Remesh_Setup.quads`, `app.ui.remesh_quads`, setting and macro `remesh_quads`, a "Quads" switch row in the More fold, the
  result line "; quads"; README's Voxel remesh section and the scripts line.
- `remesh_apply` passes `old_to_new` and `tri_from` through `object_rebuild` to `object_build_from` when the report has
  quads, then `remesh_polys` builds `sculpt.Polys{first = 4q, corners = quads through old_to_new, tri_poly[t] =
  tri_from[t] / 2}` for `levels_set_polys(.Smooth)` and the renumbered quads for `levels_set_quads`; the long job does
  the same on its thread after `levels_init` with the maps (sculpt only, as `levels_take_surface` already is).
- `bench --remesh` adds two columns: the quads path's remesh time and its vertex count at each size; README's table is
  re-run on this VM. The report's bar: ships only if the quads path stays within 1.5× the triangle path's time and
  `mesh_check` is clean on the fixtures (the corpus script is PR 6, which will run both paths).

## Out of scope
Pole reduction (valence-3 and -5 vertices are inherent to a lattice dual; Blender's voxel remesh has a "fix poles" pass,
left for later with a note), quads for the booleans' remesh (they keep triangles), partial remesh.

## Review and as built (2026-10-30)
The architect's review (Revise) found the hole in the manifoldness argument: the plain face rule keeps a face's two
inside corners apart and so joins its two outside corners across the face, and in 36 of the 256 cases one loop then
crosses a face twice; where the cell across the face has such a loop too (a crevice thinner than a cell slipping
diagonally between lattice points), the two patches' dual edge would carry four quads. Building the fixture (two spheres
an oblique fraction of a cell apart) showed the same configuration already broke the **triangle** path: the two cells'
fans shared a diagonal four triangles at a time, a non-manifold remesh that has been there since the first version and
that nearly touching parts hit. Rather than refuse the dual there, the rule now turns on exactly those faces
(`cell_flips`: both cells' static cases say their loops thread the face twice, so both agree): each cell then keeps two
pockets apart instead of a pinched tube, the crevice closes as any gap narrower than a cell does, and both the triangles
and the quads are manifold at every gap tried (0.01 to 0.08 of a unit sphere at h 0.097; the test
`remesh_closes_a_gap_thinner_than_a_cell`). `mc_case_loops(case, flips)` is the one source of a cell's loops and
triangles: the table holds the 256 plain cases and a turned cell traces its own (rare). A fan's apex is a crossing off the
loop's doubled faces, so even an unturned doubled pair never shares a diagonal. The dual keeps a refusal for what the
turn cannot reach (several faces of one cell turning at once): `Remesh_Report.quads_thin`, the triangles made instead.
The double-face flags ride in the corner word's top two bits (no extra memory; 17 bytes a crossing in all for the dual's
scratch). The y-axis orientation flip the review asked to state: slots run counter-clockwise about +x and +z and clockwise
about +y, hence `forward := (axis != 1) == low_in`. The app side as designed: `remesh_take_quads` builds the `Polys` and
quad faces with the levels' allocator (the context's, on either thread) and `long_job_prepare` asks for the maps whenever
the report has quads. Scripted runs: Quads on a 20k sphere at 8,000 gives 7,998 quads, OBJ export writes 4-sided faces
only, `mesh_check` clean, wireframe `pr5b_quads.png`; through the long job's thread with Keep detail the same; Divide on
it gives Catmull-Clark quads (31,994 vertices = V + E + F). Bench: the quads path takes 0.9× to 1.1× the triangle path's
time at 500k to 10M (README's table), within the 1.5× bar. About half the vertices are four-valent (the rest three, five
and six): pole reduction stays out of scope, noted in README.
