# Implicit modelling reference

## Contents
- Sign convention and primitives
- CSG and smooth blends
- Transforms of a field
- Normals and curvature
- Meshing: surface nets, dual contouring, marching cubes
- Chunked and sparse grids
- From field to geom.Mesh
- The comparison table against bench
- Sources

## Sign convention and primitives
Negative inside, zero on the surface, positive outside; `|∇f| = 1` for a true distance (CSG and smooth blends break
this, which only matters for ray marching step sizes and the blend band estimate). With `p` the sample point:
- sphere: `length(p) − r`
- box with half-extents `b`: `q = abs(p) − b; length(max(q, 0)) + min(max(q.x, max(q.y, q.z)), 0)`
- rounded box: box with `b − rounding`, minus `rounding`
- capsule from `a` to `b`, radius `r`: `pa = p − a; ba = b − a; h = clamp(dot(pa, ba) / dot(ba, ba), 0, 1); length(pa − ba·h) − r`
- torus, radii `R` (ring) and `r` (tube), axis y: `q = {length(p.xz) − R, p.y}; length(q) − r`
- plane with unit normal `n` and offset `h`: `dot(p, n) + h`
- cylinder along y, radius `r`, half-height `h`: `d = {length(p.xz) − r, abs(p.y) − h}; min(max(d.x, d.y), 0) + length(max(d, 0))`
(Inigo Quilez's list has the rest, with exactness notes.)

## CSG and smooth blends
- Union `min(a, b)`, intersection `max(a, b)`, difference `max(a, −b)`. These are exact outside the blend region only
  as lower bounds; their gradient is discontinuous along the seam, which the mesher sees as a crease.
- Smooth minimum, polynomial (the voxel brushes' `smin`): `h = clamp(0.5 + 0.5 (b − a) / k, 0, 1); lerp(b, a, h) − k h (1 − h)`,
  with `k` the blend radius in world units; smooth intersection is `−smin(−a, −b, k)`, smooth difference
  `−smin(−a, b, k)`. Exponential and power variants trade cost for symmetry; keep one and name its `k`.
- A dab is a smooth union with a sphere: only cells within `radius + k` (plus a cell of margin) can change, which is what
  keeps the dirty region small.

## Transforms of a field
- Translate: `f(p − t)`; rotate: `f(Rᵀ p)`; uniform scale by `s`: `f(p / s) · s` (dividing keeps `|∇f| = 1`); mirror:
  `f({abs(p.x), p.y, p.z})` gives symmetry across x for free; repetition: `f(mod(p + c/2, c) − c/2)`.

## Normals and curvature
- Normal = normalised gradient; central differences with `h` of half a cell: `n = normalize({f(p+hx) − f(p−hx), …})`
  (six samples), or the tetrahedron trick (four samples). For meshing, sample the gradient at the crossing points on
  the grid edges (Hermite data); the mesh's vertex normals can then come from `mesh_recompute_normals` or from the field.

## Meshing: surface nets, dual contouring, marching cubes
- Marching cubes: vertices on cell edges, triangles from a 256-case table; produces many slivers, no sharp features,
  and needs the ambiguity-resolved table to stay manifold.
- Surface nets (`src/voxel/mesh.odin`): one vertex per crossed cell at the mean of its edge crossings, one quad per crossing edge
  connecting the four cells around it; smooth, cheap, simple to chunk; sharp features are rounded; ambiguous cells can
  yield non-manifold edges, which `mesh_check` reports.
- Dual contouring (Ju, Losasso, Schaefer, Warren, SIGGRAPH 2002): same connectivity as surface nets, but the vertex
  minimises a quadratic error function over the Hermite data, so edges and corners are reproduced; needs normals at
  crossings and an SVD or Gram–Schmidt solve per cell, plus clamping of the solution into the cell. Manifold dual
  contouring (Schaefer, Ju, Warren 2007; libfive's mesher) fixes the non-manifold cases.
- All three share the chunking scheme: a chunk owns its cells' vertices and the quads of the edges it owns; its
  vertex pass extends one cell into the previous chunk so border quads find all four vertices (the voxel mesher's −1 neighbour).

## Chunked and sparse grids
- Bricks of 16³ or 32³ with a dirty flag per brick; a brick table that allocates bricks only where the
  surface passes (a narrow band), which turns n³ memory into roughly surface area × band width; a boundary layer per
  brick (one or two voxels) copied from neighbours before remeshing, which lets bricks remesh in parallel without
  reading each other (`jobs.parallel_for` over dirty bricks, heap-allocated per-brick output).
- Keep the field in a fixed-point or f16 format only after measuring: f32 is the simplest and the first numbers were
  the baseline.

## From field to geom.Mesh
1. Triangulate quads `(q0, q1, q2), (q0, q2, q3)`; drop degenerate triangles (a quad whose four cells gave three distinct
   vertices).
2. `geom.Mesh{positions, normals, indices}`, `mesh_recompute_normals`, then `mesh_check`: closed, positive volume; flip
   all triangles if negative.
3. For the scene: `scene_add_mesh` (sm-cad). For per-brick GPU buffers while sculpting the field, each brick needs its
   own vertex and index ranges with a per-brick capacity, and the `Draw_Item` would list one chunk per brick; that is a
   render design to write up before building (AGENTS.md: a new GPU buffer layout stops for review).

## The comparison table against bench
| Representation | Vertices shown | MB (field or mesh) | Dab ms p50 | Remesh / normals ms p50 | Frame ms (4 dabs) | Upload MB/frame |
|---|---|---|---|---|---|---|
| mesh sculptor (`build.bat bench N --threads=T`) | | | | | | |
| Voxel clay (`bench --voxel`) | | | | | | |
Same thread count, release builds, both on the 77-dab r = 0.13 stroke.

## Sources
- Inigo Quilez, distance functions: https://iquilezles.org/articles/distfunctions/
- Inigo Quilez, smooth minimum: https://iquilezles.org/articles/smin/
- Ju, Losasso, Schaefer, Warren, "Dual Contouring of Hermite Data" (SIGGRAPH 2002)
- Schaefer, Ju, Warren, "Manifold Dual Contouring" (TVCG 2007); libfive: https://libfive.com/
- Manifold's level-set mesher (SDF → manifold mesh): https://github.com/elalish/manifold
- Mikola Lysenko, "Smooth Voxel Terrain" (surface nets vs marching cubes vs dual contouring, with code)
