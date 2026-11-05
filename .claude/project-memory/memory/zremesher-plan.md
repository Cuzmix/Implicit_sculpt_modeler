---
name: zremesher-plan
description: Quad Remesh to ZRemesher level (2026-11-03 thread): decision to drive AutoRemesher's stages from our own shim, the 7-PR series, baseline numbers, and build facts
metadata:
  type: project
  modified: 2026-11-03T01:14:38.755Z
---

Bolt picked "Quad Remesh at ZRemesher quality" (2026-11-03, Fable thread). Plan artifact: https://claude.ai/artifact/Wadm1f5C3DPypSREt6Ufg9. Design notes per PR in /mnt/project-files/notes/zremesher/.

Baseline before PR 1: counts landed 71-107 % of asked; 20k quads from 328k tris 9.4 s on one core; rod fixture has 48 flipped caps (PR 7).

Decision: keep AutoRemesher (MIT); `quadmesh_shim.cpp` drives MeshSeparator / meshopt decimation / IsotropicRemesher / Parameterizer / QuadExtractor itself; our patches to the pinned source live in src/quadmesh/patches/ (applied by build_autoremesher.py).

Rejected: QuadriFlow, Instant Meshes, QuadWild, MIQ/CoMISo, libQEx.

PR 1 merged #525: count lands via a second cover pass when the cover's cell area is >3 % off (bench 19,864/20,000, 13.9 s vs 10.4 s; PR 6 should reuse the frame field); Half/Same/Double; corpus acceptance ±5 %. Gotchas: README python edits must search after the start anchor; harness blocks rebase+force push, merge odin-sculpt instead.

PR 2 merged #529 (2026-11-03): Keep groups / Keep creases / Edge angle (AutoRemesher only, Rebuild Quads card). Patches to AutoRemesher in src/quadmesh/patches (applied by build_autoremesher.py; regenerate from a scratch git copy, thirdparty files CRLF; fetch runs with core.autocrlf=false, .gitattributes -text). Found+fixed upstream extractor bug: fixHoleWithQuads added a hole's last quad twice (doubled quad = 8 non-manifold edges). Debug recipe: count duplicate faces after each extractor pass. Results: 2-group sphere 1482/1500 straight loop on border; 35 groups 1 tri + 19 n-gons, closed. Fallback: non-manifold/open result -> remesh without features (Result.unkept). Freeze border deferred (needs per-vertex integer constraint in cover). Base branch note: build.sh check fails on web step in process_memory_other.odin (Docks 6a), not ours.

PR 3 merged #534 (2026-11-03): Use paint / Use mask (red 4x, blue 1/4, mask 2x; settings retopo_use_paint/use_mask off) + Adaptivity relabelled Adaptive size (keeps count). Key finding: per-face cover scaling alone gives only 1.4x; needs conformal frame field (transport turn += -(cot a+cot b)*dlog s) AND singularity simplifier off while density varies (it cancels the pole pairs). Painted half 3.4x, mirrored 3.1x (cap takes half's lowest density; mean gave 1.8x). Found: mirrored count ~19 % short even without density (flat cap takes extra quads) -> fix in PR 5. Fixed app crash on quit with 2+ mesh objects (sculpt_gpu_level read freed levels).

PR 4 merged #536 (2026-11-03): curve use Guide + Guide strength (retopo_guide_strength 0.5). Frame-field fixed-target rows alone gave 13 deg; key was keeping guided faces' direction in the cover's curl correction (faceTurnWeight) -> 5.7 deg. PR 5 finding: mirrored count short ~10 % at 500-2000 because cap faces (flat cut) were counted; excluding cap from count works at 8000 but isotropic mesh bevels the rim at low counts.

PR 5 merged #562 (2026-11-03): caps count none of the cells (Params.cap), third cover, folded covers bound no bracket; cap rim features from origins.triangle==SLICE_NONE minus rim within 1 quad of its own other side (creature's midline cut runs lengthwise through a head spike half a quad thick: cover folded 91 -> 3,820 cells for 1,231); thin parts (thin_parts.odin: thickness+width rays on ~32 hashed samples a quad, graded Dijkstra, refine 0.5 isotropic; 0.44 s of 5.2 s release on 500k creature); shim unpinch (meshopt pinched vertices hung isotropic remesher); dissolve_doublets + quad_fill_odd = all quads; open mirrored result falls back to whole; ray_aabb NaN fix; format_f32 NaN hang fix. Sphere mirrored 98-103 %. Creature body400k (scratchpad fixture, asymmetric tail) whole 2,500 -> 2,213 (88.5 %): extraction drops ~8 % of cells (not folds); mirrored half's extraction leaves holes at the horns -> falls back to whole. These belong to the Odin port (own extractor).

PR series: 1 own driver + exact count + Half/Same/Double + phase times in Report (done); 2 feature edges (Keep groups, Keep creases, Detect edges, Freeze border); 3 density (Adaptive size at kept count, Use paint red 4x/blue 1/4, Use mask); 4 guides (curve objects use Guide, Guide strength, frame field in our driver); 5 thin parts + symmetry seam pentagons; 6 speed inside one island (dropped: Bolt picked an Odin port of AutoRemesher after PR 5, design doc first, benchmarked against the C++, AI-testable hooks); 7 corpus fixtures + README.

Build facts: container needs `scripts/setup_deps.sh` (~8 min) first; phase-report CLI in /mnt/project-files/notes/remesh/ar_cli.cpp.

**Why:** the next thread must not redo the comparison or re-measure the baseline.
**How to apply:** continue the series in order; UI only in Rebuild's Quads card (docks refactor running). Related: [[remesh-quad-build]], [[keep-symmetry]], [[gate-on-bolts-pc]].
