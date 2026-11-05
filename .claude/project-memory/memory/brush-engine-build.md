---
name: brush-engine-build
description: Build thread for the 20-PR brush engine plan (started 2026-10-29): which PRs are done, PR numbers, gate approach, decisions taken while building
metadata:
  type: project
  modified: 2026-10-29T17:10:00.000Z
---

Thread "Build brush engine" (2026-10-29) builds [[brush-engine-plan]] in phase order 1a..6b, self-merging into odin-sculpt after `scripts/gate.py` (about 33 min; touch step ~29 min, run in background with a 2 h timeout).

Status (2026-10-29 17:10):
- All 20 steps merged into odin-sculpt: phase 1 #277, 2a #279, 2b #282, 2c #283, 2d #285, 2e #287, 3a #288, 3b #289, 4a #290, 4b #291, 4c #292, 5a #293, 5b #294, 5c #295, 5d #296, 6a #297, 6b #298 (6b merged 18:43 after the quick gate; the full gate passed on its previous merge of odin-sculpt).
- Gate approach used: full gate on the stack tip, `gate.py --fast` on each commit before merging; touch scenarios bisected per commit when the tip failed.
- 4a side effect: Smooth at pen pressure 0 now moves nothing (strength scales passes), so touch scenarios that smooth by pen press 0.8.

Decisions taken while building (Bolt can overrule):
- 1c: SPACING_REFERENCE 0.25 is what Even strength normalises to; settings v4 moves a saved 0.25 to 0.2 once.
- 1d: Android uses one-frame extrapolation, not AndroidX MotionEventPredictor.
- 2c Elastic: Volume (Poisson ν) 0..0.5, Kelvinlet ε = radius. 2e: Grab/Elastic refine under dyntopo at release.
- 3b: response presets Default/Clay/Steady/Light. 2026-10-29 Bolt's iPad report "Clay does nothing" overruled Clay starting on the Clay response (pencil at ~0.5 gave ~0.1% of Draw): Clay now starts on the global pressure (settings v7 migrates the old default once) and CLAY_HEIGHT is 0.25 (Blender's), Clay strips keeps 0.08 (CLAY_STRIPS_HEIGHT). Thread "Fix Clay brush and brush menu scrolling".
- 4b: Alt while smoothing = Polish (HC Laplacian). 4c: Smooth under dyntopo only collapses.
- 5a: Draw starts with Accumulate off; Dots dabs are scaled by the row's overlap so one pass is as high as with it on.
- 5b: Hardness per brush (0-95%); Falloff shape Projected is the default for Clay, Flatten and Trim dynamic.
- 5c: "Size fixed in the scene" (ZBrush Dynamic size) fixes the size at the first stroke's zoom; "No back and forth", "Directional"; built-in preset Hatch (Crease, one-way).
- 5d: new kinds Clay_Strips and Trim_Dynamic (the old Flatten preset "Trim" keeps its name); Flatten gets Plane height/depth; built-in presets Fill and Scrape.
- 6a: Detail Screen (px) or Radius (share, default 10%); per-brush "changes triangles" and "Use global detail"; "Detail follows the falloff"; partial masks weight splits.
- 6b: Snake hook and Cloth repair stretch at stroke end; Cloth now works under dyntopo; command Remove stretching splits edges > 2x the median.
- 2026-10-29 Bolt overruled 2a's press past the outline (#309): every brush, Grab and Elastic included, starts only with the pointer itself on the model (ZBrush); Nomad's ring reach is the opt-in `grab_outline` switch "Past the outline" (Grab/Elastic More, off by default; .strokes v29).
- Presets carry new values as named `key=value` tail words.
- Gate trick: a second worktree /home/user/gate-wt (deps copied, never symlinked, [[sculpt-worktrees]]) runs the gate on a commit while work goes on in the main tree.

**How to apply:** a later thread picking this up reads this, the plan /mnt/project-files/notes/brush-engine/plan.md and design notes beside it; pen parts of 1a, 1b, 1d, 3a plus 2a's pressure latch and 3b's feel await Bolt's Windows/tablet try ([[sculpt-tablet]]).
