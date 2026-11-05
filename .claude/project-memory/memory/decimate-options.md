---
name: decimate-options
description: Decimate (Rebuild > Fewer) got a Keep % slider and Keep paint/groups/borders/Use mask in #439 (2026-10-31); what it does, and what was left out
metadata:
  type: project
  modified: 2026-10-31T14:30:36.440Z
---

On 2026-10-31 Bolt asked for "the equivalent of remesh/quad remesh for decimate" (choose how much). Merged #439 into odin-sculpt the same day.
- Rebuild's Fewer goal: **Keep** 1–90 % of the object's vertices (default 20 %, settings `decimate_by`/`decimate_percent`), Count under More options. Also under More options: Keep paint, Keep groups, Keep borders (on by default), Use mask (off).
- Engine: `geom.Simplify_Guide` (weight, labels, slide_borders), strict decimation only. The LOD's simplify is unchanged. App side: `src/app/decimate.odin`.
- Adjust last offers 50/25/10/5/2 % after a run that kept a share.
- Touch: Fewer's Apply now sits at y 504 like Even and Quads (`REBUILD_APPLY`). New scenario `decimate_runs_as_a_long_job`.
- Left out, and possible follow-ups: keeping UVs (UVs here belong only to all-quad objects, see `Quad_Faces`), symmetric decimation (Blender's Symmetry), a live preview of the result while dragging.

**Why:** the next thread should not rebuild this or re-suggest it as missing.
**How to apply:** start any decimation change in `src/app/decimate.odin` and `geom.Simplify_Guide`. It still needs Bolt's device try. Related: [[remesh-quad-build]].
