---
name: remesh-quad-research
description: Thread "Plan distinct Remesh and Quad Remesh tools" (2026-10-29): audit findings, AutoRemesher facts, container build workarounds
metadata:
  type: project
  modified: 2026-10-29T21:38:47.201Z
---

Bolt's brief (2026-10-29 21:23): research + plan only for two tools, Remesh (DynaMesh-like) and Quad Remesh (AutoRemesher as the leading candidate), diagnose why both "look like triangles", no rewrite.

Audit facts (verified in code, commit ccc31aa):
- Remesh = `geom.remesh_voxel` (own winding-number rays + marching cubes, triangles) via `object_remesh`; Quad Remesh = Retopologize = `geom.mesh_retopo` (decimate, pair triangles, Catmull-Clark cut, relax) via `object_retopo` (src/app/retopo.odin): a NEW object whose quads live in `Levels.faces.quads` (src/sculpt/levels_quads.odin), saved in the scene (v4), exported as quads (OBJ/USD), used for UVs, bake, Edit cage.
- Quads are real at the algorithm output (diag test: 100% quads, closed; valence-4 only 77-83%, 11-13% valence 3). The viewport wireframe (`wire_pass`, line-fill of the triangle draw) shows triangle diagonals; only Model-mode cages get polygon edge lines (`Draw_Item.cage_lines`, `mesh_buffers_set_edges`). So quads "look like triangles" in the viewport and the edge flow is poor, not lost.
- Our voxel package's surface nets already builds a quad per crossed edge and appends it as two triangles (src/voxel/mesh.odin:567-625).

AutoRemesher (github huxingyi/autoremesher, master 4a49f82 2026-10-07, v1.2.0): MIT; Geogram/libigl/CoMISo/OpenVDB are GONE (changelog 1.0.0 relicensed, 1.1.0 native parameterizer); core is src/AutoRemesher (~10.7k lines, quadextractor.cpp 4.5k) + thirdparty eigen (MPL2, but it uses SimplicialLDLT and COLAMDOrdering, Eigen's LGPL parts) + isotropicremesher (MIT) + meshoptimizer (MIT) + TBB (Apache 2: only parallel_for/blocked_range/parallel_sort). Qt only for the GUI/CLI main. ACKNOWLEDGEMENTS.html is stale (still lists CoMISo GPL etc.). API: AutoRemesher(vertices, triangles).setTargetTriangleCount(2*quads)/setScaling/setGradientAdaptivity/setSharpEdgeDegrees/setAnisotropy/setSmoothNormalDegrees/setProgressHandler; remesh(); remeshedVertices()/remeshedQuads() (polygons, may hold non-quads). Pipeline: islands -> decimate if dense -> isotropic remesh at voxelSize -> frame field + quad-cover parameterization (own MILS) -> quad extraction + many cleanup passes -> smooth and project.

Container notes (SDL build, GPU driver, offscreen runs): in [[remesh-quad-build]].

**Why:** the plan and its PRs must build on these facts, and the next thread should not redo the audit.
**How to apply:** read the report artifact (link in this thread) before implementing; related [[sculpt-remesh]], [[sculpt-retopo-bake]], [[sculpt-voxel]].

Report (2026-10-29 21:50): https://claude.ai/artifact/Y7oLGn8QV2MmegNP2uYWgV — decisions: keep geom.remesh_voxel as Remesh (add Smooth, Keep detail, Groups, optional dual/quads mesher; fix the open-sheet bug: the merged Female export remeshed to 3465 non-manifold edges), AutoRemesher behind a C ABI as Quad Remesh (src/quadmesh + scripts/build_autoremesher.py, EIGEN_MPL2_ONLY, TBB shim), polygon topology stays a side table (Quad_Faces/Polys), PR 1 = polygon edges in the wireframe. Measured: AutoRemesher 99.5-100% quads, 95-100% valence-4 vs ours 77-83%; 0.4 s for 2k quads; 20 s / 1.5 GB on the raw 3.8M-tri Female export (83% quads, dirty input). Target count is approximate (6-20% under at adaptivity 0, 3x under at 1).
Late result: AutoRemesher on the merged Female export after our Remesh at 500k (956k tris, non-manifold output) was killed after 30 min at 2.7 GB (exit 137): a validity check and an input cap must sit in front of the call; the first milestone's end-to-end proof waits on the Remesh open-sheet fix (PR 5a).
Build log per PR (#358-#372, PR 6): [[remesh-quad-build]].
