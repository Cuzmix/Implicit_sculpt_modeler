# Algorithms and references for CAD-style mesh tools

## Contents
- Booleans: the Manifold semantics, and the voxel fallback
- Decimation, subdivision and remeshing already in the repo
- Plane trim and slice
- Extrude, inset, bevel
- Mirror and symmetry
- Checks with numbers (what the good CAD skills do)
- Sources

## Booleans: the Manifold semantics, and the voxel fallback
- Manifold (github.com/elalish/manifold) is the reference for mesh booleans: union, intersection and difference that
  take manifold inputs and guarantee manifold output, with triangle-level robustness (symbolic perturbation) instead of
  tolerances. Even when reimplemented here, copy its contract: refuse non-manifold input with a precise report (which
  edges), never emit a non-manifold result, and keep the output's winding consistent with the inputs.
- Nomad Sculpt adopted Manifold for its polygon booleans (1.79) and kept voxel remeshing as the fallback: a single
  non-manifold edge makes a polygonal boolean fail, while a voxel pass always produces a closed surface at the cost of
  resolution and sharp edges. The same split fits here: polygonal when `mesh_check` says both inputs are closed and
  consistently wound, otherwise `geom.remesh_voxel` over both meshes' triangles together (it already merges overlaps and
  self-intersections by winding number, `src/geom/remesh.odin:11-29`) and `object_build_from`.
- A boolean's result starts as a new mesh: new sculptor, levels dropped, GPU buffers recreated (the topology path in
  SKILL.md). Print `volume_before`, `volume_after` and the `mesh_check` counts; a union's volume is at most the sum and
  at least the larger input, an intersection's at most the smaller.

## Decimation, subdivision and remeshing already in the repo
- `geom.simplify` is quadric edge collapse (Garland–Heckbert) in passes of independent collapses, as meshoptimizer
  does; it locks border and non-manifold vertices and refuses flips. Use it for decimation tools; it keeps a patch's
  border exactly, which is what makes LOD cuts crack-free.
- Loop subdivision lives in `level_above` (`src/sculpt/levels.odin`): even vertices `(1 − nβ)p + β·ring`, odd vertices
  `3/8(a + b) + 1/8(c + d)`, closed meshes only. Open meshes need Biermann, Levin and Zorin's boundary rules (cubic
  B-spline stencils along the boundary); the levels code refuses them instead, which a tool that opens a mesh must respect.
- `geom.remesh_voxel` (DynaMesh) is the even remesh: winding-number inside test, marching cubes, tangential relaxation;
  its tests (`remesh_test.odin`) check closed manifold, Euler characteristic 2, the count within ±30% and the distance to
  the sphere within 0.6 of the spacing, and `build/bench --remesh` reports edge-length spread before and after. Fine
  detail below the spacing is lost by design; a detail-keeping variant would project the result back onto the source
  with closest-point queries and report the distance.

## Plane trim and slice
- Classify vertices by signed distance to the plane; triangles with mixed signs are split at the zero crossings (one
  triangle becomes one or two on each side); the cut produces closed loops of boundary edges that are capped with a 2D
  triangulation in the plane (ear clipping is enough for simple loops; nested loops need holes). The cap's winding
  faces the kept side. Verify: `mesh_check` closed, bounds stop at the plane, volume shrank by the cut-off part.
- Slice is a trim kept on both sides as two objects.

## Extrude, inset, bevel
- Extrude a face set: duplicate its vertices, move the copies along the normal, connect the boundary loop with a quad
  strip (two triangles each), flip or remove the original faces as the tool wants; the result's Euler characteristic
  tells you whether a loop was missed. Inset moves the duplicated loop inward in the face plane instead. Bevel replaces
  an edge by a strip and its vertices by fans; it is the one most likely to create degenerate triangles at short edges,
  so clamp the width to the shortest adjacent edge and check `degenerate_triangles == 0`.

## Mirror and symmetry
- Mirror across a local-space plane is positions-only when the mesh is already symmetric in topology (reflect the
  positions of one half onto their mirror vertices, found by nearest-point search), and a topology change otherwise
  (cut at the plane, mirror one half, weld the seam). Symmetric sculpting already exists as a brush
  feature (`Brush.symmetry`, `mirrors` in `src/sculpt/brush.odin`: every dab runs at each mirror image in the same
  stroke, planes through the mesh's local origin); a symmetrise tool is the positions-only path when the topology is
  already mirrored.

## Checks with numbers (what the good CAD skills do)
- pthompson8594/openscad-skill checks its work "with numbers instead of pictures": bounding box and volume against
  the intended dimensions, open and non-manifold flags on every part, clash and clearance between every pair, and a
  self-test that builds a tiny model with planted faults and proves each check catches them. The equivalents here are
  `mesh_check`, the signed volume, the bounds and `check_test.odin`'s planted faults.
- ibmua/claude-3d-skills (3d-modelling) keeps "every version one sound object": floating parts are a fault unless
  declared, open edges are sorted by kind and must be explained, closed parts with negative volume are flipped, and each
  version comes with a hand-back line (body count, last check line, what was removed and how each gap was closed). Write
  the same hand-back for a tool's result: counts, `mesh_check` line, volume before and after.

## Sources
- Manifold: https://github.com/elalish/manifold (README: guaranteed-manifold booleans; inputs must be manifold)
- Nomad Sculpt 1.79 boolean notes: https://80.lv/articles/nomad-sculpt-1-79-s-boolean-demonstrated
- Garland and Heckbert, "Surface Simplification Using Quadric Error Metrics" (SIGGRAPH 1997)
- Loop, "Smooth Subdivision Surfaces Based on Triangles" (1987); Biermann, Levin, Zorin, "Piecewise Smooth Subdivision
  Surfaces with Normal Control" (SIGGRAPH 2000): https://mrl.cs.nyu.edu/publications/piecewise-smooth/
- pthompson8594/openscad-skill: https://github.com/pthompson8594/openscad-skill
- ibmua/claude-3d-skills: https://github.com/ibmua/claude-3d-skills
