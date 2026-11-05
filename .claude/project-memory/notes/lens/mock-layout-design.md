# Lens mock layout: design (the nine PRs)

Spec: notes/lens/mock-layout-gaps.md (gap list and PR order) and ui-direction/template.html (positions, sizes and
copy). Bolt, 2026-10-28: the app should look and behave like the Sculpt Workspace Directions mockups, option C.

## One switch: the chrome
- `Chrome :: enum u8 {Lens, Classic}` on `Kit_State.chrome`. **Lens** (the default) is the mock's layout; **Classic**
  is today's ZBrush-iPad layout, kept whole so nothing is lost (Settings > Interface > Layout: Lens / Classic;
  settings row `chrome lens|classic`; command `Chrome_Classic` in Search, "classic layout zbrush"; flag
  `--chrome=lens|classic`). Every PR below branches its zone on it and leaves Classic as it is.
- Workspaces stay as they are and apply under either chrome (their zones map onto the Lens zones: Brush_Bar = the
  off-hand rail, View_Bar = the view rail, Dock = the shelf, Wheel = nothing in Lens).
- Tests: `scripts/touch_check.py` runs every scenario with `--chrome=classic` unless the scenario names a chrome, so
  the 461 scenarios keep their coordinates; Lens scenarios pass `--chrome=lens`. Unit tests that lay out the kit say
  which chrome they test.

## PR 1: the top bar (Lens)
Left: Menu, the file block (the file name, bold, over "Saved N min ago" / "Unsaved changes" / "Not saved", from
`app.saved_at`: the time of the last save, or the file's own time when opened), a divider, Undo and Redo (greyed when
there is nothing; their tooltips name the step). Middle: the workspace switcher as a pill of segments (every
workspace, the current one raised, the amber dot on it while modified, then "+" which opens the switcher's menu; a
tap on the current one opens the menu too); a window too narrow for the pill shows the chip. Right: the Search field
(300 pt, "Search commands, brushes, panels" and its key, Ctrl K), History, Settings. Home, Save, Import, Export,
Edit pies and Help leave the bar: Home and Help head the menu (which keeps Save, Import, Export), Edit pies is in
Search. The pass chip leaves it for the pane header (PR 5; meanwhile Search, the passes' keys and the view rail).

After building: the file block keeps a fixed width (its widest status line) so Undo and Redo never move when a stroke
makes the scene unsaved; the pill is laid out inline in the bar with spacers (a `begin_at` container inside the bar
lost its hits to the bar); "+" sits inside the pill's well. Narrow windows: the Search field shrinks to its icon
first, then the pill becomes the chip (checked at 1100 and 760 points). Six Lens touch scenarios (`lens_*`).

## PR 2..9
As the gap list orders them; each gets its own short section here when it starts.
