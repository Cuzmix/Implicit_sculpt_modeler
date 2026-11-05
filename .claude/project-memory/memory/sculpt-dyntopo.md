---
name: sculpt-dyntopo
description: Dynamic topology (Sculptris Pro / Blender dyntopo) in the sculpt app, PR #10 merged 2026-10-24: design, keys, bench numbers, limits
metadata:
  type: project
  modified: 2026-10-24T15:39:42.455Z
---

Part of the "lets do all of it" brainstorm list (after [[sculpt-brushes]] and [[sculpt-remesh]]). PR #10 self-merged into odin-sculpt (ce5e511) 2026-10-24.
- Ctrl+T / Tools panel "Dynamic topology" checkbox; Detail slider in screen px (default 10), "Collapse short edges" (default on); app flags `--dyntopo`, `--detail=PX`. Needs a single level and no HD; toggling clears undo; Remesh turns it off.
- Design (src/sculpt/dyntopo.odin): node id = page (1280 vertex / 2048 triangle slots, unused triangles zero), per-vertex face lists (16), Rivara longest-edge bisection (the first version made slivers/folds; a long-stroke test caught it), guarded collapses, 2048 edits per dab cap, app stops dabs after 10 ms brush time per frame (MAX_BRUSH_MS_PER_FRAME), whole-node undo, BVH over pages with nil tri_order.
- Bench `build/bench --dyntopo` (VM, 4 threads): turn on 47 ms at 1M / 2 s at 10M; plain strokes = fixed layout (+20% at 10M); stress refine frame 12-31 ms; peak 2.5 GB at 10M. Static sculpting no slower (old vs new bench A/B).
- Collapse with default detail on a dense mesh coarsens what the brush touches (Blender behaves the same); documented in README.
- Other thread added AGENTS.md/CLAUDE.md, sm-* skills, `./build.sh check`, `--check-mesh`, scripts/ppm.py on odin-sculpt (0bb1f34); follow AGENTS.md "Done means" and run scripts/agents_sync.py after skill edits.
- Not tried on Windows yet.
