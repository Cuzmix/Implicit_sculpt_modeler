---
name: sculpt-hide-slice
description: Hide tools and Slice tool (PR #34, merged into odin-sculpt 2026-10-25): keys, defaults, limits, timings
metadata:
  type: project
---

PR #34 merged into odin-sculpt 2026-10-25 (thread "We need a slice tool and hide", asked by Bolt).

- Ctrl+Shift + left drag now runs the Tools panel "Hide, clip and slice" choice: Hide rectangle (default), Hide lasso, Clip, Slice. Remembered as `gesture` in settings. Note: Clip used to be the only Ctrl+Shift action; now it must be picked in the panel.
- Hide: keeps inside shown (Alt hides inside). Ctrl+Shift click or Ctrl+H shows all, Ctrl+Shift+H inverts. Undoable, per level, not saved in .sculpt, refused in HD and with dyntopo. Half of 10M in 0.28 s.
- Slice: cuts the selected object along the drawn plane into two capped closed objects (right of drag becomes new object); one Ctrl+Z undoes. Drops levels/mask/hiding, ignores symmetry. 10M verts: ~6 s + 2.4 s setup on the VM (possible future speedup).
- Flags --slice=x|y|z, --hide=[-]x|y|z. Not tried on Windows yet.
Related: [[sculpt-polish-oct25]]
