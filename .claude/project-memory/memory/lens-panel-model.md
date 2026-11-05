---
name: lens-panel-model
description: Lens P0 build thread, all merged: #210 panel model, #211 workspaces, #212 Arrange, #213 passes, #214 second view; code map and gotchas
metadata:
  type: project
---

Lens P0 build thread (2026-10-27), branch claude/project-thread-msth1a, PRs into odin-sculpt one at a time. See [[ui-direction-lens]].
- PR 1 (panel model + two columns) code: src/app/panels.odin. Panel_Ref :: union {Kit_Window, Kit_Section}; columns k.panels.columns[Left/Right]; any tray section but Objects can be pinned as its own panel (Pin_Section command, "Pin as a panel" button on a bar popover). Default = tray alone in the right column, others floating, so nothing moves for old users. Design note /mnt/project-files/notes/lens/panel-model-design.md.
- Gotchas: a docked panel must be its OWN root container (ui.begin_anchored at k.panels.at[side]); nesting panel procs inside a column container broke pointer_root hit testing and prev_rect/prev_layout lookups by root name. Exit stat `pinned=` already belongs to the orbit pivot, so pinned sections print as `panel_pins=`. ui.window_grab hands a held press to a window's title bar (undock and keep dragging).
- PR 2 #211 workspaces (src/app/workspaces.odin): layout = text from kit_layout_text (hidden/open/window/column/pinned lines, right-handed); dot = text != saved; built-ins Sculpt/Focus/Inspect/Studio via built_in_layout; Zone hides bars (top bar takes Undo/Redo, Search/Palettes); read wheel side via rail_shown(k). Workspace list is heap ([]Workspace) because App near the 3*App test stack limit. Scripts: `workspace focus`.
- PR 3 #212 Arrange merged (src/app/arrange.odin: head with zone Show switches, Panels drawer Hidden/Left/Right/Float, column outlines, ghosts for hidden dock/wheel/action bar). Layout text now has a `bars` line + bar_count/bar lines (column + tool strip); dock stays global. Test App/Kit_State needs bars_reset before comparing to built-ins.
- PR 4 #213 passes merged (src/app/passes.odin; render.View_Pass; Material_Uniforms.pass at 880; chip in top bar; ui.held_long; Alt+1..6, Alt+0 last, backquote peek). Gotcha: App is at the [3]App test stack limit; those two tests now heap-allocate (new([3]App)).
- PR 5 #214 second view merged 2026-10-27 (src/app/thumbnail.odin: Second_View k.second, Second_Camera Follow/6 axes ortho/Free in App.second_orbit, Second_Pass Silhouette/Shaded/Normals/Depth/Curvature; settings rows second_camera/second_pass, old thumbnail_shaded 1 -> Shaded; Maximise floating only, never saved). Design notes/lens/second-pane-design.md. Lens P0 complete; P1 next = view grid (panes tiled, panes in layouts), strokes in any pane, per-pane heavy passes. All untested on Windows/tablet.
- Not yet: narrow-window (<1180 pt) column popovers, resizable column width, docking Settings/Help/Macros/Library, tab groups.

**Why:** later Lens PRs (workspaces snapshot columns; Arrange mode; second pane) build on this model. **How to apply:** new panels go through panel_begin/panel_end and Panel_Frame.room/owner, never ui.window_begin directly.
