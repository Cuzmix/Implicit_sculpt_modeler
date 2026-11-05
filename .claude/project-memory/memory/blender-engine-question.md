---
name: blender-engine-question
description: 2026-10-31 Bolt asked whether to build on Blender's code as the engine under our UI; answer was no (GPL/App Store, entanglement, no tablets, slower); port ideas + use permissive libs instead
metadata:
  type: project
  modified: 2026-10-31T19:27:27.588Z
---

Thread "Weigh building on Blender's engine" (2026-10-31, discussion only, no code).

Recommendation given: don't build on Blender's code. Reasons: GPL forces the app to be GPL, which conflicts with App Store terms; the sculpt code is tied into DNA/RNA, the depsgraph, bContext/operators, undo and GPU module; Blender has no iOS/Android build; it's slower than our engine (25M orbit 2.2 ms on 3060 Ti).
Middle path (already our practice): reimplement Blender *behaviour* from docs/papers in Odin without copying GPL code, and link permissive libs via C shims: Cycles (Apache-2.0), OpenSubdiv, OpenVDB, Embree, Manifold.

**How to apply:** don't re-propose embedding Blender code. If Bolt names a missing Blender tool, write a behaviour comparison and port plan. Related: [[stack-rebuild-question]], [[best-of-all-worlds]], [[pelz-pathtracer-study]].

2026-10-31 23:11 follow-up: recommended keeping our own GPU path tracer (Cycles: no Vulkan/Android/iPad, offline only); libs via real C shims (not rewrites): Manifold first (exact booleans vs our voxel-seam booleans), Embree maybe for bakes/iPad CPU rays, OpenSubdiv low value (we have Catmull-Clark+creases), OpenVDB skip. Offered to plan Manifold booleans; awaiting Bolt.
