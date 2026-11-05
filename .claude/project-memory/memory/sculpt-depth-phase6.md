---
name: sculpt-depth-phase6
description: UX roadmap Phase 6 ("Depth where artists feel it") progress: gizmo #84-#85, scene tree #86 onward, and the remaining items
metadata:
  type: project
---

Phase 6 of /mnt/project-files/notes/ux-research/12_Product_Roadmap.md, worked autonomously in thread "Build command registry and touch controls" while Bolt is away (after Phase 5, [[sculpt-never-lose-work]]). Order: full gizmo, scene tree, selection model, posing, stroke engine, history brush, layers at any level.

- Gizmo part 1 merged 2026-10-26 as PR #84 into odin-sculpt:
  - Move/Turn/Scale modes, cycled by pressing W again. Move has plane squares. Turn has axis rings plus a view ring. Scale uses a disc plus a circle.
  - Snapping works through a latch or by holding Ctrl.
  - A readout shows the change while dragging.
  - Finger-sized picking.
  - Esc or a second finger cancels a drag.
  - History_Kind.Transform makes each gizmo drag, inspector drag, or Reset transform one undo step.
  - Code: src/gizmo/turn.odin, src/app/move_tool.odin.
  - Design and reviews: /mnt/project-files/notes/phase6/gizmo-design.md.
- Gizmo part 2 merged 2026-10-26 as PR #85:
  - Set pivot latch (action bar Pivot chip): a tap on a surface places the pivot, stored local to the object with its id, not saved; Reset pivot.
  - Typed values: a tap on an arm, ring or scale disc that moves nothing opens a popover (number sets, +N adds, *N scales; ring = degrees).
  - Item 1 (full gizmo) is done. Long-press for the pivot was skipped (the latch covers it). Next: scene tree.
- touch_check: GIZMO_* points assume the starting sphere and camera; `gizmo_where` checks `gizmo_at`. The Move tab keeps Focus/Frame first (y=328) so gizmo settings below never move them.
- Scene tree split into 1a/1b/2/3 after the architect review (design + review: /mnt/project-files/notes/phase6/scene-tree-design.md). Names: "Folders" (Group means polygroups), object flag `off` (hidden means hidden triangles).
- Scene tree 1a merged 2026-10-26 as PR #86: eye/ghost/solo per object (ui.tree_row with toggles), H / Alt+H / Shift+S, selection always pickable, scene file v8, view changes not undoable (app.view_edits). Ghost is an opaque darkened tint (no blending in the mesh pipeline). 
- Scene tree 1b merged 2026-10-26 as PR #87: folders (one level, contiguous via scene_folders_normalize), Ctrl+G, F2 rename, folder menu, History_Kind.Arrange with Scene_Layout before/after, Delete folder = Arrange + chained swaps, file v9. Next: part 2 (drag to reorder with a grip, column drag of eyes), then part 3 (multi-select transform).
- touch_check: THREE (3 spheres), SCENE_ROWS_Y, SCENE_EYE_X, SPHERES3 for scene-tree scenarios. Palette words must not steal existing searches ("wire" finds Wireframe first in 5 scenarios).
- Scene tree 2 merged 2026-10-26 as PR #88: grip drag to reorder (tree_row grip; pure tree_drop; Arrange Reorder/Reorder_Folder with Scene_Command.before; autoscroll), column drag of eyes/ghosts (mouse at once, finger after tooltip hold; queued View commands sent by tree_column_send each frame). Next: part 3 multi-select transform + 50-object check.
- Scene tree 3 merged 2026-10-26 as PR #89: multi-select (Scene.also + also_for; Shift/Ctrl click rows, Shift+click viewport, Select several switch, folder Select its objects); gizmo/Transform/typed values move all via transform_follow + chained .Transform; shared scale clamp; Duplicate/Delete all; 50 rows ui_ms_p50 0.86 ms. Item 2 (scene tree) DONE. Trap: snapshots free temp memory, so loops over ids must heap-copy. Next: item 3 Selection model.
- Items 3 onward (selection model, posing, stroke engine, history brush): [[sculpt-depth-phase6-later]].
- touch_check trap: helper names must be unique; a later `def same_file` silently shadowed an earlier one (fixed: file_difference).
- Not tried on Windows or a tablet.
