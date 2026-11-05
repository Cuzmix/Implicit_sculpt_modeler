# 2c Elastic: design note (2026-10-29)

Goal: an Elastic brush (Blender's Elastic Deform, ZBrush's nearest is Move Elastic): a grab whose falloff is the
displacement of an elastic solid pulled at a point (regularized Kelvinlets, de Goes and James 2017), so the pulled
part keeps its volume and shape, the surround stretches smoothly with no edge to the falloff, and Volume (Poisson's
ratio) decides how much the sides bulge or thin. Its own brush kind (Bolt's default Q3), in the Move category.

## Maths
For a pull Δ at the brush centre c, the displacement of a point p, with r = p - c, ε the scale and r_ε = sqrt(|r|² + ε²):
    u(p) = [ A(r) I + B(r) r rᵀ ] Δ
    A = (a - b) / r_ε + a ε² / (2 r_ε³),   B = b / r_ε³,   a = 1 / (4π μ),  b = a / (4 (1 - ν))
Tri-scale (the paper's §5, Blender's `BKE_kelvinlet_grab_triscale`): scales ε = r, 2r, 4r, combined with weights
1, -(ε₃² - ε₁²)/(ε₃² - ε₂²) = -1.25, (ε₂² - ε₁²)/(ε₃² - ε₂²) = 0.25, which cancels the far field (decay ~|r|⁻⁵).
Normalised by the centre's value (B's term is zero there), so the point under the press follows the pointer
exactly ("force calibrated to the tip"): μ drops out, only ν matters. Volume = ν in 0..0.9, default 0.4
(Blender's range and default).
- Bounded cost: evaluated only within 3 r of each image's centre, multiplied by a smoothstep to 0 between 2.5 r
  and 3 r (the tri-scale field there is under 1% of the tip's, so the cut is invisible).

## Fit with Grab
The displacement is linear in Δ, so it is exactly Grab's `follow` matrix per vertex: for each symmetry image k,
    follow += K(p - c_k) · turn_k        (K the 3x3 Kelvinlet tensor above, turn_k the image's turn)
times the mask/hide shield. So `sculptor_grab_begin` with `kind == .Elastic` queries leaves within 3 r, fills
`follow` from the Kelvinlet instead of the scalar falloff, and `sculptor_grab_move`, undo, symmetry, Shift/Alt modes
(2a), the press past the outline and replays work unchanged. Same side, Silhouette, Topological, Connected and All
depth do not apply (it is a volume deformation, not a surface falloff) and grey out; the drawn falloff curve and
focal shift do not apply either (the falloff section says so).
- Cost: the reach is 3 r, about 9x Grab's vertices on a surface: a move at 10M with the bench's radius should stay
  near 1 ms on the 4-thread VM. Bench row "Elastic" next to "Grab".
- `sculpt.Brush.volume: f32` (ν). Brush_Kind gains `Elastic` at the end of the enum (kinds are stored by number).

## App
- BRUSHES row Elastic (flags {.Grab}, so the stroke engine treats it as a grab; checks for `kind == .Grab` that
  mean "a grab" are moved to `.Grab in flags`, the ones that mean Grab's own options stay).
- Options: Volume slider (0..90%, default 40%) and the Grab modes tabs; README brush table row, glossary entry,
  shelf/browser card (Move category), setting `elastic_volume`, presets and `.strokes` (version 18: Volume).
- Brush icon: Lucide stretch-horizontal (each brush has its own); its card shows the hook stroke as Grab's.

## Tests
- sculpt: the centre vertex moves exactly Δ; displacement falls smoothly to 0 by 3 r (no vertex beyond moves);
  a higher Volume moves the sides at 90° to the pull less... (measure the bulge sign change between ν = 0 and 0.9 on
  a plane: with ν high the material beside the pull contracts toward the axis more); serial == parallel; X symmetry
  mirrored.
- app: strokes/preset round trip, a touch scenario with a screenshot of an Elastic pull beside a Grab pull.

## Left out
Kelvinlet Scale, Twist and Bi-scale modes (Blender's other Elastic modes): later if wanted.

## Changed while building
- Volume is 0..100% mapped to ν = 0..0.5 (default 80% = ν 0.4): above ν = 5/6 the tri-scale tip value changes sign
  (1.5a - b < 0) and the pull turns against itself, and above 0.5 it is not physical, so Blender's 0..0.9 range is
  not copied.
- The smallest scale is the brush radius (as Blender's), not half of it: half made a needle-thin pull. The fade runs
  from 2 r to 3 r (the field there is a tenth of the pull or less, most of it ahead of the pull).
