# PR 2: Quad Remesh keeps groups and creases as edge loops

Plan: https://claude.ai/artifact/Wadm1f5C3DPypSREt6Ufg9 (section 4, PR 2).

## Why
ZRemesher's KeepGroups and KeepCreases make the quads' edges run along polygroup borders
and creased edges, which is how a modeller controls where the loops go. AutoRemesher only
knows "sharp" edges by angle (90 degrees by default), judged three times over: the
isotropic remesher (per-vertex "featured" pins, flips still allowed), the frame field
(locked faces) and the quad cover (corner constraints, which make the edge an integer
isoline, so the extraction puts quad edges on it). A group border on a smooth surface is
none of those.

## What changes
- Feature edges travel as vertex pairs: `retopo.Source{groups, creases}` from the app
  (the shown level's polygroups per triangle; the base level's creases when the base level
  is shown), through the cap decimation (its labels guide, as Decimate's Keep groups;
  creases do not survive a decimation past the cap), the mirror cut (triangle and vertex
  origins) and Close first (which rebuilds the surface, so both are dropped with a note),
  into `quadmesh.Params.features` and the shim's `Qm_Params.features`.
- Patches to the pinned AutoRemesher, kept in `src/quadmesh/patches/*.patch` and applied
  by `scripts/build_autoremesher.py` after the fetch (the stamp hashes them):
  - isotropic halfedge mesh: feature edges set from pairs at construction; a split edge's
    halves inherit its state and the midpoint is featured only when the edge is; a
    featured edge never flips; a featured edge collapses only along its line (the vertex
    that goes has exactly two featured edges and the kept one stays where it is), so a
    dense crease thins out to the quad size instead of pinning every input vertex; a
    featured vertex relaxes along its two featured neighbours and a junction stays put.
  - isotropic remesher: `setFeatureEdges`, featured vertices projected onto the input's
    feature polyline instead of the surface, `remeshedFeatureEdges()` out.
  - frame field, singularity simplifier and quad cover take per-corner feature flags
    beside the angle test.
- The shim orchestrates the parameterization itself (normals, scaling field, frame field
  with the flags, simplifier, cover with the flags), which PR 3 (density) and PR 4
  (guides) then feed without further patches.
- Options: Keep groups (on), Keep creases (on), Edge angle (90, as today; lower keeps
  softer edges) under Rebuild > Quads > More options, settings `retopo_keep_groups`,
  `retopo_keep_creases`, `retopo_edge_degrees`, kept by Adjust last and macros. The
  built-in engine ignores them (README says so). Freeze border is deferred: the border
  is already an integer isoline; keeping its vertices one for one needs an integer
  constraint per border vertex in the cover (noted in zremesher-plan memory).

## Acceptance
quadmesh test: a sphere whose triangles above z = 0.3 are one group and the rest another
comes back with a closed loop of quad edges on the border (every output edge whose ends
lie within 1e-3 of the border polyline; the loop's vertices have two such edges each), at
the count asked within 5 %; the same on 1 and 4 threads. Corpus unchanged. The app:
Keep groups on a grouped sphere in a described PNG (Wireframe), result line names the
feature edges kept.

## Outcome (as built)
- The shim kept the core's `Parameterizer` (patched with `setCornerFeatures` and a
  `setFaceScaling` hook for PR 3) rather than orchestrating the parameterization itself:
  its anisotropy helpers sit in an anonymous namespace.
- Extra measures found while testing: the input's feature polyline is smoothed (4 rounds,
  half weight) before the isotropic remesh projects onto it, since a painted group border
  zigzags along its triangles; the extractor's smoothing keeps quad vertices that lie on a
  feature on its segments; chains shorter than two quads are dropped; a triangle whose two
  feature edges cross at 15° to 75° does not lock the field; a free vertex may collapse onto
  a vertex of a caller feature (removes slivers beside it); merged edges keep the stronger
  feature state.
- Upstream bug fixed: `fixHoleWithQuads` left a hole at four after adding its last quad,
  and `fixHoles` ran the second pass on it, adding that quad again (a doubled quad, eight
  non-manifold edges). Only seen near features, but it is a general fix.
- Fallback: a result with non-manifold edges or open where the input was closed is
  remeshed once without features; `Result.unkept` says so in the result line.
- Numbers: two-group icosphere 1,452 quads for 1,500, closed, all quads, loop on the
  border; grouped 40k sphere 1,482 for 1,500 with a straight loop at the border (PNG
  described in the PR); 35 groups of `group normals` (2,630 feature edges) 1,370 polygons,
  1 triangle, 19 pentagons or more, closed (before the fixes: 22 triangles, 93 n-gons,
  open, 134 non-manifold edges).
