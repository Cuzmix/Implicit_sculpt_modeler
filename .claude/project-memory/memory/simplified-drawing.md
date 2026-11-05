---
name: simplified-drawing
description: Design, bench numbers and gotchas of LOD while the view moves (border-locked chunk-group copies, cull_lod, LOD index buffer) in src/sculpt/lod.odin, src/geom/lod.odin, src/geom/simplify.odin
metadata:
  type: project
  modified: 2026-10-18T23:22:53.272Z
---

Built 2026-10-18 (roadmap item 3, thread "Faking 3D like ZBrush"), PR #6, self-merged into odin-sculpt (59de18f) under Bolt's "self-merge and work autonomously" instruction. Roadmap: [[sculpt-perf-work]]; architecture: [[sculpt-decisions]].
- Design: chunks (BVH leaves) grouped bottom-up along the BVH, 4-6 per group, up to one root. Each group's copy = its children's triangles/copies simplified to 1/4 by quadric edge collapse into existing vertices; vertices on edges without exactly 2 triangles are locked, so any cut is crack-free (a tree, not Nanite's DAG: borders stay full-res, still fine). Error = 1.5 x collapse error + max child error. Edits stale the groups above (closed upward); rebuild lowest first, parallel batches, ~4 ms per frame, one object per frame, never during a stroke. Copies in slots (1.25x) of one index array; compaction when half is wasted. Renderer: second index buffer per mesh, indirect commands after the fine ones, lod_px in frame/static keys. Used only while camera/size/transforms changed within 0.25 s; partial redraws always full detail (sub-pixel shading detail would be lost otherwise).
- Bench (`build/bench --lod`, 4 threads): 10M sphere whole view 8.63M -> 496k triangles (17x), close 791k -> 109k; full build 3.5 s in 790 frames; large stroke rebuild 219 ms; copies 100 MB (~1/4 of the index buffer). llvmpipe orbit GPU 49.6 -> 16.2 ms at 500k, 85 -> 18 ms at 1M. Only meshes >= 262,144 triangles get copies.
- Gotchas: Odin `resize` on [dynamic] grows to the exact length (no doubling): reserve geometrically before it. Hashing a struct with padding hashes garbage: frame_key header uses u32 fields. Quadric error is an estimate (true distance up to ~1.5x on tiny patches), tests allow 1.1x.
- Not done: simplifier ~300 ns/input triangle could be faster. HD windows hide the chunks and groups they cover: [[hd-detail]].
