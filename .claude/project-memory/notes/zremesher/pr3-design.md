# PR 3: Quad Remesh density from paint and mask, Adaptive size keeps the count

Plan: https://claude.ai/artifact/Wadm1f5C3DPypSREt6Ufg9 (section 4, PR 3).

## Why
ZRemesher's Use PolyPaint (red denser, blue sparser) and Adaptive Size are how a modeller
puts more loops on a face and fewer on a back. Since PR 1 the count already lands with
Adaptivity on (2,936 for 3,000 on the bumpy sphere), so the README's "a third as many" is
stale and the control is renamed Adaptive size, as ZBrush calls it.

## What changes
- Density per input vertex, d = relative quads per area (1 neutral), built in `retopo`:
  paint: 4^(coverage x (redness - blueness)), redness = r - max(g, b), blueness = b - max(r, g)
  (white, grey and green are neutral; pure red 4x, pure blue a quarter); mask: x 2^mask.
  Clamped to 1/16..16 (edge length 0.25x..4x). Options `use_paint`, `use_mask` (off by
  default, as ZBrush's Use PolyPaint); `Source.paint`, `Source.mask` copied by the app.
- It follows the input: the cap decimation's `from` map, Close first by closest point on
  the mesh before it (the DynaMesh-then-ZRemesher habit keeps its paint), the mirror cut's
  vertex origins (cap vertices take the mean).
- `quadmesh.Params.density` (per vertex) -> shim: normalised so its area-weighted mean is 1
  over the whole input (the count stays what was asked), split per island, carried through
  the shim's decimation, multiplied into the isotropic target lengths (edge x 1/sqrt(d)), and
  carried through the isotropic remesh as a vertex payload (patch: split averages it like
  the target length, a collapse keeps the kept vertex's) into the cover's per-face scaling
  (`Parameterizer::setFaceScaling`, PR 2's hook). The landing pass measures cells against
  the density-weighted area.
- Rebuild > Quads > More options: Use paint, Use mask switches (greyed "(none)" without
  paint or mask), Adaptivity relabelled Adaptive size. Settings `retopo_use_paint`,
  `retopo_use_mask`; Adjust last and macros keep them. Built-in engine ignores them.

## Acceptance
A sphere painted red on its upper half gets 3 to 4 times the quads per area there, count
within 5 %. Adaptive size: count within 5 % and the quad areas spread wider than Even.
Corpus and bench unchanged with the switches off.

## Outcome (as built, merged #534)
- A per-face scaling of the cover alone reached only 1.4x on the painted half: the cover
  cannot place the poles a change of size needs along a field solved without it. The
  density now goes in as a per-vertex log scale (`Parameterizer::setVertexScaling`, which
  replaced PR 2's `setFaceScaling` hook): the frame field is solved in the scaled metric
  (`FrameField::conformalTurn`, the transport across each edge turned by
  -(cot a + cot b) x the log scale's change), the cover's scaling field is multiplied by it,
  and the singularity simplifier is skipped while the density varies (it cancels exactly
  the pole pairs that bring the extra loops, at any pair distance). The log scale is
  blurred 4 rounds (half toward the ring mean) first.
- The payload rides the isotropic remesh (split averages it; the patch files were renamed
  by stage: core-isotropic-remesher, core-parameterize-extract, isotropic-remesher).
- The mirror cut's cap takes the half's lowest density, not the mean: with the mean the
  upper part got 1.8x, with the lowest 2.9x (3.1x through compute).
- Numbers: icosphere 5 painted red above, 2,000 asked: 1,992 quads, 3.36x above; mask
  2.38x; mirrored 1,982, 3.06x; plain 1,944, 0.85x. quadmesh test: upper 4 / 0.25 give
  3.32x / 0.27x. Adaptive size at 100 % on the bumpy sphere: 2,936 for 3,000, area spread
  0.34 against 0.22 at Even.
- Found on the way: the mirrored count runs about 19 % short with or without density (the
  flat cap takes more than its share), left for PR 5; the app crashed on quit with two mesh
  objects (the GPU sculpt lookup read a freed object's levels), guarded in this PR.
