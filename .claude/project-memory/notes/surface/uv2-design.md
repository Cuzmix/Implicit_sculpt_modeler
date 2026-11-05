# UV2 design: flatten islands (LSCM, ABF++), stretch, bench --uv

Goal: given an object's `uv.Uvs` whose seams cut the surface into islands with borders, lay
each island flat with low distortion, the way Blender's Unwrap (Angle Based / Conformal)
does, and measure it. No UI in UV2: the Unwrap command and auto seams are UV4, packers UV5.

## API (package `uv`, imports core:, geom and jobs)
- `Method :: enum u8 {Abf, Lscm}`; `Abf` is ABF++ angles then LSCM built from them
  (Blender's default), `Lscm` the conformal map straight from the 3D triangles.
- `flatten(u: ^Uvs, positions: []geom.Vec3, indices: []u32, faces: geom.Vertex_Faces,
  method: Method, pool: ^jobs.Pool, allocator) -> Flatten_Report`
  - Every island that has a border is flattened in place in `u.corner`; the islands are
    independent, run on the pool (`parallel_for` over islands, biggest first), each with
    its own heap memory, so serial and parallel are bit-identical.
  - A closed island (no border: a sphere with no seam) is left as it was and counted in
    `report.closed`; UV4's auto seams cut those.
  - Pins: an island with two or more pinned vertices keeps them where they are (LSCM's
    fixed points); otherwise the two border vertices farthest apart are fixed for the
    solve, and the result is then turned so that pair lies level.
  - After the solve each island is scaled so its UV area equals its 3D area (one texel
    density) and the whole set is fitted into the unit square by a plain shelf placement
    (largest first, rows); UV5 replaces this with the real packers. `filled` is updated.
- `Flatten_Report{islands, flattened, closed, failed int, ms f64}`; `failed` counts
  islands whose solve did not converge or folded, which keep their old coordinates.

## Island meshes
- Per island, its triangles in ascending order; its own vertex numbering made of
  "wedges": the corners round a mesh vertex grouped by crossing non-seam edges, so a
  vertex on a seam becomes two or more island vertices. Built from `across` and the
  seam bits only; numbered in order of first appearance, deterministic.
- Border edges of an island are its seam edges and the mesh's open edges.
- Degenerate triangles (area < 1e-12 of the island's mean) get angles of a third of pi
  each and a tiny weight, as Blender does, so one sliver cannot break a solve.

## LSCM (Lévy et al. 2002)
- The conformal energy per triangle in its own 2D frame, two unknowns per free wedge.
  Normal equations AᵀA x = Aᵀb solved by conjugate gradient in f64 with a Jacobi
  preconditioner, warm-started from the island's current coordinates when they are
  finite (repeat unwraps converge in a few steps). Tolerance 1e-10 relative, cap
  4·sqrt(n)+200 iterations; no external solver.
- Matrix kept in CSR built once per island; rows in wedge order (deterministic sums).

## ABF++ (Sheffer, Lévy, Mogilnitsky, Bogomyakov 2005)
- Unknowns: the angles of the island's triangles, target the 3D angles (clamped to
  [3°, 175°]), weights 1/target². Constraints: triangle sums = pi, interior wedge sums
  = 2pi, interior wedge sine (wheel) condition.
- Newton steps with ABF++'s reduction: the angle block is diagonal, so the system shrinks
  to the 2·interior-wedges Schur complement, solved by preconditioned CG (it is SPD).
  At most 10 Newton steps, stop when the gradient norm < 1e-6 (Blender uses 1e-3 on
  floats). If it fails to converge, fall back to LSCM for that island (counted).
- The angles then build the flat triangles (each triangle's shape from its angles, its
  size from the 3D one) and LSCM solves for the coordinates from those shapes.

## Stretch (`stretch(u, positions, indices, triangles?) -> Stretch`)
- Per triangle the Jacobian's singular values σ1 ≥ σ2 against the 3D triangle, with the
  island's area scale divided out. Reports area-weighted: Sander's L2 stretch,
  max σ1/σ2 (worst) and mean angle distortion in degrees, plus flipped triangles.
- Used by the tests, by `bench --uv` and later by UV3's relax and the UV editor's
  stretch view.

## bench --uv
- `build/bench --uv [sizes]`: fixtures with seams (a cylinder cut along a line, a cube
  grid cut into its six sides, a hemisphere (one border), a remeshed sphere cut along a
  meridian by a seam path, and an imported head when present under build/), each at the
  asked sizes; per fixture and method: ms (1 thread and all threads), L2 stretch, worst
  σ1/σ2, angle distortion, flips.
- Blender comparison: `scripts/uv_check.py` runs the same fixtures exported as OBJ
  through bpy (`bpy.ops.uv.unwrap(method='ANGLE_BASED'|'CONFORMAL', margin=0)`) when
  Blender or the `bpy` wheel is installed, and measures its UVs with the same stretch
  code (it reads the OBJ back through our importer), printing both tables side by side.
  Not available in the cloud container: the table there shows ours only.

## Tests (src/uv/flatten_test.odin)
- A flat grid (already planar) comes back the same shape up to a similarity (both
  methods), so stretch is 1 and no flips.
- A cylinder cut along a line unrolls to a rectangle of the right aspect (2πr by h).
- A hemisphere: no flips, L2 stretch under the bound we measure first and then pin.
- Pins stay where they were; serial and parallel results are bit-identical; a closed
  sphere is reported closed and untouched; a sliver triangle does not break the solve.

## Boundaries and rules
- `uv` gains `core:jobs`-free use of `../jobs` (pure CPU pool), so sm-lint's import list
  for uv becomes core:, geom and jobs; the boundary script's list too.
- Allocations inside the island jobs use runtime.heap_allocator() for make and delete.
- No file format change, no History kind, no GPU change in UV2.

## Split
- UV2a: island meshes (wedges, borders), LSCM, stretch, shelf placement, tests.
- UV2b: ABF++ with its fallback, bench --uv, scripts/uv_check.py, README bench section.

## After the architect review (2026-11-03): approved with changes
- Big islands: CG on the normal equations is O(n) conditioned (minutes at 1M). Use our
  own sparse Cholesky / LDLᵀ with a nested-dissection order from recursive bisection of
  the 3D positions (deterministic, ~O(n^1.5) on a planar mesh, about 1 s at 1M); reused
  by ABF++'s Schur system and UV3's relax. CG with Jacobi stays for small islands and as
  a cross-check in tests. Tolerance about 1e-7, enough for f32 output.
- ABF++: the same direct solver; a step check (angles above 0, the constraint norm
  falling, else halve the step); "interior" means a closed disc fan, so bowtie and
  non-manifold vertices count as border; a non-mutual `across` pair is a border, as
  `check` treats it.
- A fold is not a failure: keep it and count the flips. Failed means non-finite or no
  convergence on the direct path.
- Pins: a pinned vertex holds all its wedges in that island. With one pin: that pin plus
  the farthest border wedge along the box's longest axis. The far pair is the extremes
  along that axis, lowest wedge on a tie (O(b)). Pinned islands are neither scaled nor
  placed by the packing.
- The pool cannot nest: big islands one at a time with parallel kernels whose sums run
  in fixed chunks added in order; then parallel_for over the small islands. No temp
  allocator inside jobs (islands_find and boxes_filled only on the calling thread).
- Boundaries: sm-lint's uv line becomes core:, geom and jobs; bench may import uv.
- Blender: `bench --uv --measure=FILE.obj` measures any OBJ's UVs with our stretch, so
  `scripts/uv_check.py` exports fixtures, unwraps them in bpy and measures them by it.
- Split into four PRs: (1) wedges and borders, stretch, tests; (2) sparse Cholesky and
  LSCM; (3) packing and `bench --uv` with our numbers (speed is the main risk);
  (4) ABF++, uv_check.py, README.
- Tests added: wedge counts at seams and a bowtie, an annulus, a non-manifold edge, one
  pin, a pinned island not moved, check after flatten, stretch of a known affine map,
  bit-identical with pools of 1, 2 and N, packed boxes apart and inside the square, ABF
  angle sums, the fallback forced, NaN positions fail and leave the UVs, warm and cold
  starts agree. Bench rows: a 1M-triangle island, iterations and residual, peak memory
  with the factor's fill, a warm repeat, 1 against all threads, big and small phases.
