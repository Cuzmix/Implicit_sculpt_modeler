# PR 4: Quad Remesh follows guide curves

Plan: https://claude.ai/artifact/Wadm1f5C3DPypSREt6Ufg9 (section 4, PR 4).

## Why
ZRemesher's Curves (drawn with the ZRemesherGuide brush) and Curves Strength are how a
modeller tells the loops which way to run: round an eye, along a limb, across a cheek.

## What changes
- A curve object gets the use **Guide** (after Brush path in the curve card's tabs): a line
  on the surface, as Line is, making no mesh; its card says what it does. No file change:
  the use byte already takes any value the enum has.
- The app hands `retopo.Source.guides`: every shown Guide curve of the scene, sampled
  (geom.bezier_sample) and carried into the remeshed object's own space, as segment pairs.
  `Options.guide_strength` (0..1, 50 % by default, as ZRemesher's Curves Strength):
  setting `retopo_guide_strength`, kept by Adjust last and macros, slider "Guide strength"
  in Rebuild > Quads > More options, greyed "(no guides)" without a Guide curve.
- retopo keeps the segments whose ends lie within a quad's width (sqrt(area / quads)) of
  the surface, each end moved onto it (bvh_closest); under Keep symmetry each segment is
  cut at the planes and the parts on the - side are reflected to the + side, so a guide
  drawn on either side counts. `Result.guides` counts the segments kept; the result line
  says "guided by N curves".
- quadmesh: `Params.guides` (segment pairs) and `guide_strength`; the shim, after the
  isotropic remesh, gives each face whose centroid lies within 0.75 of a local quad edge
  of a segment the segment's direction (projected onto the face) and a weight
  w = s / (1 - s + 0.01) (s = 1 gives 100, s = 0.5 about 1, the curvature rows' largest).
- Patch: `Parameterizer::setFaceGuides(const std::vector<Vector3>*)` (direction times weight,
  zero for none) into `FrameField::create`, which adds an energy row per guided face pulling
  its frame to the guide with a fixed right-hand side (not re-aimed each iteration as the
  curvature rows are). A face locked by a sharp or feature edge stays locked.
- The built-in engine ignores guides (README says so).

## Acceptance
retopo test: a sphere with a guide drawn round it as a tilted circle (30 degrees): the mean
angle between the quad edges under the curve and its tangent (folded to 0..45) under 10
degrees at strength 100 %, well over that with no guide; a guide across the bumpy sphere
the same; counts within 5 %. Mirrored: a guide drawn on the - side guides the + side.
Corpus unchanged. The app: a guided sphere in a described PNG.

## Outcome (as built)
- The frame field rows alone were not enough: a circle guide round a sphere left the
  edges 13 degrees off it at full strength (15 at half; 27 unguided). The cover's curl
  correction turns each face by up to 0.3 rad to make the field integrable; a guided face
  now keeps its direction there with the guide's weight (`faceTurnWeight` into
  `QuadParameterizer::parameterize` / `applyCurlCorrection`), so the sizes take up the curl:
  5.7 degrees at full, 6.8 at half, 2.1 mirrored, 6.7 across the bumpy sphere (25.3 unguided).
  Skipping the singularity simplifier made no difference.
- Counts: 1,966 / 1,978 for 2,000 (full / half), bumpy 2,970 for 3,000; mirrored 1,400 for
  2,000 (the mirrored count's shortfall, PR 5).
- App: 1,554 quads for 1,500 on a 40k sphere with a sine guide across its front; the
  loops bend along it (PNG pr4-guide.png, unguided pr4-noguide.png).
