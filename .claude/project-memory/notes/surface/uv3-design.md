# UV3 design: stretch relax, pins, symmetry (2026-11-05)

Goal: after an island is flattened (ABF++ or LSCM), make it closer to the surface's
lengths without folding it, as Blender's Minimize Stretch and SLIM do, and lay out a
symmetric model's islands symmetrically, as ZBrush UV Master's Symmetry and RizomUV's
symmetry do. Still no UI: the Unwrap command and its options are UV4, the editor UE1-2.
Everything stays in package `uv` (core:, geom, jobs, sparse) on the calling thread and the
pool, with serial and parallel results bit-identical.

## Relax: SLIM (Rabinovich, Poranne, Panozzo, Sorkine-Hornung 2017)
- Energy: symmetric Dirichlet, area-weighted, per triangle ||J||² + ||J⁻¹||² with J the
  map from the triangle's surface frame to its UVs. It is infinite for a flipped or
  degenerate triangle, so a flip-free start stays flip-free (locally injective).
- `relax(u, positions, indices, faces, iterations = 10, pool) -> Relax_Report{islands,
  relaxed, skipped, before, after, ms}`. Islands that are flattened already (a border, no
  flips, finite) are relaxed; an island with flips is skipped and counted (a folded
  start has infinite energy; LSCM's rare folds stay until UE1 lets you re-cut).
- Local step per triangle: J's SVD U Σ Vᵀ, the closest rotation R = U Vᵀ, the weight
  W = U diag(w) Uᵀ with w_i = sqrt((σ_i - σ_i⁻³) / (σ_i - 1)), 2 at σ_i = 1.
- Global step: minimize Σ A_t ||W_t (J_t(x) - R_t)||²: a symmetric system with two
  unknowns a wedge whose 2x2 blocks couple u and v, on the pair system (pairs.odin). The
  pattern never changes, so it is analysed once and refilled each iteration.
- Line search: the largest step with no triangle reaching zero area (Smith and Schaefer
  2015: a quadratic in t per triangle), times 0.8, then halve until the energy falls.
- Pins: pinned wedges are held (the island keeps its place and scale). Unpinned: the
  lowest wedge is held where it is, which removes the translation; the scale goes to the
  surface's (σ near 1), and the islands are packed again after (shelf_pack).
- Stops after `iterations` or when the energy falls by less than 1e-3 of itself.
- Big islands one at a time with the pool in the factor, small ones side by side, as
  flatten does.

## Symmetry
- `Symmetry :: struct {axis: u8 (0 x, 1 y, 2 z), tolerance: f32}`, passed to flatten and
  relax (`symmetry: ^Symmetry = nil`). The mirror of each vertex is found by its reflected
  position within the tolerance (quantised grid lookup, lowest index on a tie); a vertex
  with no mirror means the model is not symmetric there, and the islands touching it are
  laid out on their own.
- An island and its mirror island (same triangles reflected, which needs the seams to be
  symmetric too): the one with the lower first triangle is flattened and relaxed, and the
  other takes its coordinates through the triangle and corner correspondence, reflected
  across u (so it reads the same way in a texture, like UV Master).
- An island that is its own mirror (it straddles the plane): flattened whole, then made
  exactly symmetric: the line of best fit through the midpoints of its mirror pairs is
  the UV mirror line, and each wedge becomes the mean of itself and its mirror's
  reflection. Relax runs on it the same way after each iteration's step.
- Pinned islands keep their pins; a pinned island's mirror is laid out from it.

## Tests (src/uv/relax_test.odin, symmetry_test.odin)
- Relax lowers the energy of an LSCM dome and of a stretched strip, never flips, keeps
  pins, leaves a flat grid as it was (energy 4 already, the minimum), and gives the same
  bits on pools of 0, 1 and 3.
- A flipped start is skipped and left as it was.
- A symmetric tube cut on both sides: the two halves' UVs are each other's reflection
  exactly; a dome straddling the plane comes out symmetric to rounding; an asymmetric
  vertex leaves its island alone.

## Bench
- `bench --uv` gains a relax column per fixture (ms, energy before/after, L2 after) and a
  symmetric fixture (a tube cut along two opposite lines, two islands).

## Not in UV3
- Pin editing, live drag re-solve (UE1: holds the factor while a pin is dragged, so a
  move is only the triangular solves), Straighten and Peel (UV6), packers (UV5).

## After the architect review (2026-11-05): approved with changes
- Weights as sqrt((σ+1)(σ²+1)/σ³); signed SVD so R is a rotation. Frames measured at the
  island's own UV scale (pinned islands keep size; packed ones are not pulled back first).
  Slivers get lscm's equilateral stand-in at weight 0.1. Line search handles a linear
  determinant. One pin holds that pin; repack only islands with fewer than two pins.
- Symmetry (UV3b): mirror map must be an involution (m(m(v)) == v), tolerance relative to
  the box; corners matched by vertex (t' = m(a), m(c), m(b)); check the wedge map is a
  bijection; self-mirrored islands tie unknowns (u' = -u, v' = v, u = 0 on the plane)
  rather than averaging (averaging can fold); packing turns the leader and mirrors the
  angle onto the follower; followers copied serially after the solves.
- Optional: Tutte start for folded islands with one border loop (not taken yet).
- UV3a built: src/uv/relax.odin. Measured: dome L2 1.025 -> 1.007 (100k 0.9 s, 1M 17 s).
