# PR 5: Keep symmetry lands the count, all quads, thin parts kept

Plan: https://claude.ai/artifact/Wadm1f5C3DPypSREt6Ufg9 (section 4, PR 5).

## Why
- Mirrored, the count came out about 10-19 % short: the flat caps over the cut took more
  than their area's share of the quads, which were then dropped.
- Thin parts (a tail, a horn, a rod) got two or three quads round or none and came back
  folded or gone (a rod a thirtieth of a sphere's width vanished at 2,000 quads).
- A few triangles and pentagons came back on thin parts and along the seam, so the object
  got no UVs.

## What changed
- Caps take none of the count: `Params.cap` / `cap_snap` tell the shim which faces lie on a
  cap plane; they count for nothing in the cells wanted or measured. Up to three covers
  land it; a cover under a quarter or over four times the ask (folded) bounds no bracket.
- The cap rim goes in as feature edges from the cut's own record (`origins.triangle ==
  SLICE_NONE`), not flatness (slivers along the cut zigzagged the rim), and is left free
  where it faces its own other side within a quad (a spike cut lengthwise).
- Thin parts (`retopo/thin_parts.odin`): thickness by a ray inward, width by four rays
  across from halfway; round = pi (t + w) / 2; under six quad edges asks density for six
  quads round, graded (Dijkstra, size grows <= 0.25 x distance), raised against the mean
  normalisation, and `Params.refine` 0.5 (finer isotropic triangles) there. Measured on the
  whole and carried to the half by the cut's origins.
- `geom.ray_aabb`: 0 x infinity = NaN no longer misses axis-aligned boxes.
- Shim `unpinch`: splits vertices meshoptimizer pinched (two fans through one vertex),
  which made the isotropic remesher loop forever on a creature.
- `dissolve_doublets` (two-face vertices) and `quad_fill_odd` (odd faces joined in pairs or
  to the seam): all quads.
- A mirrored result open where the input is closed falls back to the whole remesh.
- `geom.format_f32` writes nan / inf instead of looping forever.
- Result line counts vertices on thin parts; Report has isotropic triangles and covers.

## Acceptance (as measured)
- Sphere mirrored on X at 1,000 / 2,000 / 4,000: 101.6 / 97.8 / 103.1 %; X and Y at 4,000:
  98.8 %; all quads, closed.
- Rod through a sphere at 2,000: whole, 49 vertices each side outside, reaches both ends,
  within 0.0022 of its surface, all quads, closed.
- Creature (body400k) at 2,500, whole: 2,213 quads (88.5 %), all quads, closed. Mirrored:
  the half's cover now lands its cells within 0.1 % (it folded to 91 then 3,820 cells for
  1,231 before the rim gap rule), but the extraction leaves holes on the half (the horns),
  so it falls back to the whole. The extraction drops about 8 % of the cells on the
  creature (signed and absolute cell areas differ by 2 %, so not folds).

## Left for the Odin port
The extraction's losses (holes on a capped half, 8 % of cells on a creature) and the
cover's sensitivity to the rim are in the C++ core; the port owns those stages.
