---
name: docking-dk-build
description: Docking DK1-DK3 (tabs, 2D tab kinds, floating panes) for the Surface space: design note, what is merged, gotchas
metadata:
  type: project
  modified: 2026-11-03T13:39:29.048Z
---

Thread "Build docking for 2D editors" (2026-11-03), from plan v2 ([[surface-uv-paint-shader-plan]]) and the docking mock.
Design: /mnt/project-files/notes/surface/docking-dk-design.md (mock's "frame" = our pane; main pane holds only the main
view; one Picture per pane, only the active tab draws; tree stays binary; 8 tabs, 4 docked, 2 floating).
- DK1 merged #568: grid_tabs.odin, `View_Grid.tabs`, `grid_view(g, pane)` accessor, segmented tab pill on the pane head,
  commands Pane_Tab_New/Close/Next(Ctrl+Tab)/Previous, layout `pane N ...` per tab + `pane_tab N A`.
- Gotcha: App must stay under 256 KB (401 tests put `app: App` on the stack; Odin errors at 262144). Grid undo steps
  moved to the heap (`grid_undo_destroy`); tests that push layout steps need `defer grid_undo_destroy(&app.kit.grid)`.
- Pre-existing app test failures on odin-sculpt (not ours): show_where_finds_every_home (Skin_Squeeze),
  show_every_option_unfolds_the_sections (Retopo 13 vs 10).
- DK2 Texture tab merged #571. 2026-11-03 Bolt paused all threads mid DK3a (floating panes + tab drag/drop):
  uncompiled WIP saved as /mnt/project-files/notes/surface/dk3a-floats-wip.patch (float_pane.odin + grid edits,
  apply on odin-sculpt). Left to wire: Grid_Op kinds Tab_Join/Split/Float, Float_Dock/Close; View_Grid cells,
  counters; Grid_Areas tab_drag/float_hold/float_before; app.float_pictures; kit_floats call; layout float lines;
  pane_menu_open; strings.Builder fix. Then DK3b (Overview, layout chip, Full screen, References tab).
