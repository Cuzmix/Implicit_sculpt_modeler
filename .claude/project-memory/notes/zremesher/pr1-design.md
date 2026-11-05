# PR 1: Quad Remesh drives AutoRemesher's stages itself, and lands its count

Plan: https://claude.ai/artifact/Wadm1f5C3DPypSREt6Ufg9 (section 4, PR 1).

## Why
`AutoRemesher::remesh()` passes neither a frame field nor a scaling field to its
parameterizer, both of which the later PRs need (guides, group and crease alignment,
density), and it sizes the quads from the isotropic mesh's mean edge with a scaling of 1,
so the count lands wherever the isotropic remesher's mean edge lands relative to its
target: 71 % of the request at 500 quads, 79 % at 2k and 20k, 107 % at 8k on the sphere.

## What changes
- `src/quadmesh/quadmesh_shim.cpp` runs the stages: `MeshSeparator::splitToIslands`,
  the core's decimation past 8x (meshoptimizer, copied from `decimateIfTooDense`), the
  curvature target-length field of Adaptivity (copied from `resample`), `IsotropicRemesher`,
  `Parameterizer`, `QuadExtractor`, and merges the islands. Islands run on their own
  threads up to the thread count (the TBB stand-in runs a short range on the caller, so
  the core's island loop was serial anyway); one island runs on the caller, as before, so
  a cancel unwinds at once.
- Count: the quad edge wanted is `h = sqrt(area / quads)` over the whole input; each
  island's parameterizer gets `scaling = h / averageEdgeLength(isotropic island)`, which
  is the number the cover multiplies by that same mean edge. Measured: the cover still
  lands short where the field has curl it cannot flatten (a sphere 89 %, the bench's bumpy
  sphere 67 %), and the extraction keeps the cover's cells exactly, so the shim measures
  the cover's area in cells and, when it is more than 3 % off, runs one more cover with
  the scaling corrected by sqrt(cells / wanted): sphere 1532 for 1500, bench 19,864 for
  20,000, at the cost of one more parameterization (about a third of the time; PR 6 can
  reuse the frame field). `Params.scaling > 0` still overrides it all (a multiplier of
  the mean edge, as before).
- `Report` gains `decimate_ms`, `isotropic_ms`, `parameterize_ms`, `extract_ms` (summed
  over islands) through `qm_times`; `bench --quadremesh` prints them.
- Rebuild's Quads: Half, Same, Double by the Density count, from the selected object's
  faces (its polygons where the base level keeps them, else its quads, else its triangles).
- README's Quad Remesh paragraph: the count lands within about 5 %; `remesh_check.py`'s
  acceptance tightens from -25 % / +10 % to ±5 % on the closed fixtures.

## Acceptance
Corpus: every closed fixture's Quad Remesh within 5 % of 2,000; quads share and four-valent
share no worse than today's report; `bench --quadremesh 500000` within 5 % of 20,000.
Tests: quadmesh's sphere test expects 1,425 to 1,575 for 1,500 asked; a two-island
fixture (two spheres) gives the same output on 1 and 4 threads.
