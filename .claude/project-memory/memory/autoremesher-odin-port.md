---
name: autoremesher-odin-port
description: Port of Quad Remesh's AutoRemesher C++ core to Odin: Bolt's requirements, the design doc link, the 10-PR plan and where it stands (2026-11-05: all 10 PRs merged, PR 10 #673 last)
metadata:
  type: project
---

2026-11-03: Bolt picked "Port to Odin after PR 5" (ZRemesher PR 5 merged #562). Goal: one engine on desktop, iPad, Android and web, no C++/Eigen toolchain.

Bolt's requirements: benchmark against the C++, as fast or faster; take speed/streamlining wins; treat as a day-one feature; AI-testable hooks (bench rows, CLI/test flags, scripts); improve quality and add better features from research.

Design doc (Claude Doc, 2026-11-03): https://claude.ai/artifact/CN8zVs2tkyZkYWZ2gP16pk
Key choices: keep quadmesh.remesh API; mixed pipeline while porting (retopo_core/--core, removed in 8b); src/sparse instead of Eigen; geom.mesh_decimate replaces meshoptimizer+unpinch; own isotropic remesher; QEx-style extractor from the paper (libQEx is GPL: never read its source); symmetry without caps (open half, cut on an integer grid line); quantization (QGP, min-cost flow) in phase 2. Stage checks (key=value), `--quadmesh-dump=FOLDER`, `scripts/quadmesh_view.py`.
PR order (reordered): 1 seams #629, 2 extraction #630, 3 thin+isotropic #636, 4 src/sparse #637, 5 field+singularities #639, 6 cover on supernodal Cholesky #640, 7 symmetry without caps #642, 8a guides #643, 8b C++ deleted + engine on every platform #644, 9 low counts #645 (all merged; quantization dropped, see results), 9b Keep borders #646 (FreezeBorder), 9c topology mends #648 (twins + bridges), 9d shapes at low counts #661, 10 corpus/polish #673 (all merged). Targets: every cell a quad, count within 2 %, half the C++ time overall by PR 8 (already met: 1M 2.5 s vs 15.9 s after PR 6).
2026-11-05 Bolt named the engines Flow (ours, default) and Fast (built-in; #679; retopo.Engine .Flow/.Fast, `set retopo_engine flow|fast`); I recommended dropping the Fast tab (keep it as fallback only: 2.4x faster but 80 vs 95 % four-valent, 4x UV charts, no options; exact at 100 quads where Flow gives 74), Bolt chose to keep both tabs while he tests. Pending Bolt: phase 2; iPad/OnePlus run.

Per-PR results, numbers and gotchas: [[autoremesher-odin-port-results]].

**Why:** the next thread must build the port to these terms without re-asking.
**How to apply:** the plan is done; next is Bolt's call (phase 2, or the open items in the results file: poles at low counts, ears at 300/400, mirrored horn at 2000). Bolt's iPad/OnePlus run is due now that the engine is on the tablets. Related: [[zremesher-plan]], [[remesh-quad-build]].
