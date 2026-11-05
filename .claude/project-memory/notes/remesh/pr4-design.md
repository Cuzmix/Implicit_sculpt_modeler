# PR 4 design: Quad Remesh options (symmetry, Close first, adaptivity)

## Request
Quad Remesh (PR 3, #362) gains the options the plan lists for AutoRemesher: **Adaptivity** (0–1, smaller quads where the
surface bends), **Symmetry** (Off, X, Y, Z in the object's space: one half is remeshed and mirrored, so the seam is exact),
and **Close first** (an input that is not closed, or that the check would refuse, is voxel remeshed first, the
DynaMesh-then-ZRemesher habit). Not in this PR: the sharp-edge angle, anisotropy, guide curves, a Replace mode; the Remesh
tool's own gaps (PR 5); the plan's 4c (Catmull-Clark levels and Edit cage on a quad-remeshed object) is already true after
PR 3 and verified by a scripted run (`retopologize; edit_cage; apply_cage; subdivide`: closed, `levels_rule=Smooth`, 2 levels).

## Current state
- `src/app/retopo.odin`: `Quad_Engine`, `retopo_compute(view, quads, engine, pool, progress)`, `quad_remesh_compute`
  (decimate past `QUAD_REMESH_MAX_TRIANGLES`, `mesh_integrity` refusals, `quadmesh.remesh`, `polygon_mesh_triangulate`,
  flip when inverted, UVs when all quads), `Retopo_Result` (polys, counts, reason), `retopo_apply`.
- `Scene_Command.engine` (`scene.odin:183`), issued at `rebuild.odin:157`, `commands.odin:1411`, `adjust_last.odin:335`
  from `app.ui.retopo_engine`; `adjust_open` restores it; macros record `retopo_quads`, `retopo_engine`.
- `geom.mesh_slice(m, point, normal, close, pool) -> (front, back, ok)` (`slice.odin:26`): vertices within `extent·1e-5`
  of the plane snap onto it; the cut points are made in a fixed order. `geom.mesh_symmetrize` (`symmetrize.odin:13`) cuts
  and mirrors triangles (not reusable as is: the remesh must happen between the cut and the mirror).
- `geom.remesh_voxel_measured(m, area, bounds, target, pool, allocator, progress, share)` and `mesh_area_bounds`.
- The Rebuild section (`kit_rebuild`, section `.Remesh`) has no More options fold; `kit_more_test` counts controls only
  for the sections in its table (Remesh is not one).

## Design
### Types and settings
```odin
Quad_Symmetry :: enum u8 {Off, X, Y, Z}
QUAD_SYMMETRY_NAMES := [Quad_Symmetry]string{"Off", "X", "Y", "Z"}
// What a Quad Remesh runs with besides the count: carried in the scene command, so the job thread reads no interface state.
Quad_Options :: struct {
	engine:      Quad_Engine,
	adaptivity:  f32,           // 0..1, AutoRemesher only
	symmetry:    Quad_Symmetry, // AutoRemesher only: the half on the + side is remeshed and mirrored
	close_first: bool,          // voxel remesh an open or unsound input first
}
```
- `Scene_Command.quad: Quad_Options` replaces `Scene_Command.engine` (the three issue sites call `quad_options(app)`,
  which reads `app.ui.retopo_engine`, `retopo_adaptivity`, `retopo_symmetry`, `retopo_close_first`); `adjust_open`
  restores all four; macros' QUADS/RETOPO lists name all four settings; settings rows `retopo_adaptivity` (f32 0–1),
  `retopo_symmetry` (enum), `retopo_close_first` (bool).
- `retopo_compute(view, quads, options, pool, progress)`; `Retopo_Result` gains `closed_first: int` (vertices of the
  voxel remesh, 0 for none) and `mirrored: bool`.

### Compute (AutoRemesher path), in this order
1. **Cap**: decimate past `QUAD_REMESH_MAX_TRIANGLES` (as now).
2. **Check** (`mesh_integrity`): as now, but with `close_first` on, a mesh that is open (`boundary_edges > 0`) or that the
   check would refuse (non-manifold, flipped, degenerate, duplicate; not NaN, not too many pieces) is **voxel remeshed**
   instead of refused: `remesh_voxel_measured` at `clamp(20 × quads, 20k, QUAD_REMESH_MAX_TRIANGLES / 2)` vertices (a
   lattice a few cells per quad, so the flow has a surface to follow; overlapping parts merge, open sheets vanish or
   thicken as Remesh has them), then checked again; a result that still fails is refused with the reason. Progress
   share 0.05–0.2. Without `close_first`, an open mesh goes to AutoRemesher as today (it keeps boundaries).
3. **Symmetry**: with `symmetry != .Off`, `mesh_slice(input, 0, +axis, close = false)` keeps the + half (`front`); when
   the plane misses the mesh or leaves it all on one side (`ok` false, or an empty half) the remesh runs whole and the
   report says "not mirrored: the mesh does not cross the plane". AutoRemesher gets the half at `quads / 2`.
4. **Remesh** (`quadmesh.remesh`, share 0.2–0.85), then `polygon_mesh_triangulate` as now.
5. **Mirror** (`polygon_mesh_mirror(&out, axis, snap)`, pure, on the `quadmesh.Polygon_Mesh` before triangulation): a
   vertex within `snap` (the slice's `extent·1e-5`, widened to `1e-4` since AutoRemesher's boundary smoothing moves
   seam vertices along the loop) of the plane is put on it and is its own mirror image; every other vertex gets a
   mirrored copy; every polygon gets a mirrored copy with its corners reversed. The seam needs no hashing: a
   seam vertex maps to itself. Polygons whose corners all lie on the plane (a cap AutoRemesher may lay across the cut
   loop, since it fills holes under 65 edges) would double up; `mesh_slice` leaves the cut open and AutoRemesher's hole
   filling is a risk named below, caught by the closed/manifold check: such polygons are dropped before mirroring.
6. Flip when inverted, UVs when all quads, as now.

The own engine ignores adaptivity and symmetry (its decimation locks borders, so a cut half would keep a dense seam);
with symmetry asked and the own engine running (asked or fallen back to) the report says "not mirrored". Close first
applies to both engines (it runs before the engine).

### Interface
Rebuild's Quads, under the engine tabs (AutoRemesher built): Adaptivity slider (0–100 %, "Uniform" at 0; the readout
says fewer quads than asked at high values), Symmetry tabs Off/X/Y/Z, Close first switch. Five controls at most under
the goal (Density, engine, adaptivity, symmetry, close first), so no More options fold. The Quads paragraph explains
the three in one sentence each. Adjust last keeps its count slider.

### Report and log
"Quad remeshed X: 1,180 quads (AutoRemesher, mirrored across X, closed first), UVs in 12 charts, 900 ms"; the log line
adds the half's counts and the voxel remesh's vertices.

### Tests (`src/app/retopo_test.odin`)
- Symmetry on an icosphere(4) across X: every face a quad, closed, `mesh_check` manifold, and for every vertex (x, y, z)
  a vertex (−x, y, z) exists within 1e-5 (the mirror is exact); seam vertices have x == 0 exactly.
- Close first on an open hemisphere (icosphere with the z < 0 triangles removed): without it AutoRemesher keeps the
  boundary (boundary_edges > 0); with it the result is closed and `closed_first > 0`.
- Adaptivity 1 gives fewer faces than adaptivity 0 on a bumpy sphere (counts only).
- Where `!quadmesh.AVAILABLE` each test expects the own engine and skips the AutoRemesher-only expectations.

## Boundary check
No new import edge: `app` already imports `geom`, `quadmesh`, `sculpt`.

## Alternatives rejected
- Symmetry by `geom.mesh_symmetrize` on the triangulated result: the quads would be cut by the plane, giving triangles
  and n-gons along the seam.
- Close first as a chained swap undo on the source object (the plan's wording): Quad Remesh makes a new object and
  leaves the source alone; closing inside the compute keeps that, and the source stays available for Project detail.
- Reusing `Scene_Command.axis`/`on` for symmetry and close first: `on` already means several things; a named struct
  reads better and carries into Adjust last whole.

## Risks
- AutoRemesher fills holes under 65 edges: the cut loop of a sphere half at 600 quads is ~50 edges, so it may cap the
  seam. Caught by the test (closed + manifold after mirroring; a cap would make the seam edges non-manifold). Mitigation
  in the design: polygons lying wholly on the plane are dropped before mirroring; if the cap is bigger than that (a
  few rings), the fallback is to remesh whole and report "not mirrored" when the mirrored result is not manifold.
- Seam vertices slightly off the plane: snapped within `1e-4·extent`; beyond that the two halves would not weld and
  the manifold check catches it (fallback as above).
- The voxel remesh of Close first takes seconds at 500k vertices on the job thread; it has progress and cancel.
- Undo, levels, HD: unchanged (a new object, as PR 3).

## Plan (one PR, ~450 lines)
1. Types, settings rows, `Scene_Command.quad`, `quad_options`, macros, adjust restore — check, `rebuild_test` updated.
2. Close first and symmetry in `quad_remesh_compute`, `polygon_mesh_mirror` — tests above.
3. Interface rows, README (Retopology section: the three options and their scripts), scripted runs with pictures
   (`set retopo_symmetry x; retopologize; wireframe on`), check, test, smoke.

## Open questions (defaults taken)
- Symmetry plane: the object's own space through its origin, as Mirror and weld (the sculpt's symmetry plane). Yes.
- Close first density: 20 quads' worth of vertices per quad, 20k floor. A later Remesh-density control if asked.

## Review and as built (2026-10-30)
The architect's corrections were taken: the mirrored result that leaves non-manifold edges along the seam is dropped
and the whole mesh remeshed with "not mirrored since the seam did not close" in the result line, as is a plane the mesh
does not cross or the own engine running with symmetry asked; the seam snap is a share of the largest extent; Close
first runs before the integrity check (which then judges the remesh's output), and README says the bowl is filled where
the winding is positive, which the test bounds by volume (a half ball). What the build changed from the note: the half
goes to AutoRemesher **closed by a flat cap** (`mesh_slice(..., close = true)`) rather than open, since AutoRemesher fills
a cut loop under 65 edges itself and smooths a larger one's rim off the plane; the count asked is raised by the cap's
share of the area and the rim is kept as a sharp edge (60°) so the quads line up with the seam; the cap's polygons are
recognised polygon by polygon, by the nearest point of the capped half to the polygon's middle lying on a cap triangle
(`quad_seam_classify`), not by their corners' distance to the plane, because AutoRemesher's smoothing leaves cap vertices
up to 1 % of the size off it and its quads straddle the rim; the seam vertices are then those a kept and a dropped polygon
share, and a chord (an edge between two kept polygons with both ends on the seam, which the mirror would give four faces)
is removed by dropping the more seam-heavy of its two polygons and redrawing the seam, a round or two; and the
triangulation never cuts a quad or fan along a seam-to-seam diagonal (`polygon_mesh_triangulate(m, seam)`), since the
mirror image would cut there too and the edge would carry four triangles (the 7 non-manifold edges the first run
showed). Tests: symmetry (closed, manifold, every vertex has its image, seam exact), Close first on a hemisphere
(open without it at 2,000 quads; closed with it, half-ball volume), adaptivity (fewer faces), plus the PR 3 four.
Stress run before the PR (27 cases: a 40k geodesic sphere, an icosphere and a bumpy sphere at 400, 1,500 and 6,000 quads,
mirrored about X, Y and Z): 26 mirrored closed and manifold, one (the bumpy sphere at 400 quads about X) fell back
cleanly to a whole remesh with its reason in the result line.
