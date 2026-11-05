# Lens P1-9: popover and panel pinning

Spec: Lens report P1 item 9 ("Popover and panel pinning: the same content as popover, docked panel or floating
card"), the Customisation model's item 1 ("A panel can be docked in a column, float as a card, or open as a popover
from a button ... Pin a popover to dock it; collapse a panel to keep a one-line summary") and "Adapts to the screen"
("Below 1180 pt (the tray's existing breakpoint) columns become popovers from the rails").

P0 (#210) already gave sections Pin as a panel (bar popover, Panel options, Search), docking, floating, folding with
a summary. What is missing is the third presentation for a whole column, and summaries for most sections.

## What exists when done
- **Columns become popovers on a narrow window.** Below 1180 pt wide (`TRAY_NAV_MIN_W`), a column's docked panels no
  longer stand over a third of the view all the time. A column shows only while it is **popped**:
  - its edge **tab** (a small chip at the column's top beside its rail, Lucide panel-left / panel-right, with the
    number of panels when more than one) pops it;
  - opening any panel docked in it (Palettes, Stats, a pinned section's command, Show section...) pops it;
  - Palettes (the right bar's button and its key) pops or closes the column holding the tray rather than hiding it;
  - a press on the viewport closes it and is swallowed, as a popover's dismissing press is, so it never sculpts; a
    press on another panel or bar leaves it open; Escape closes it when nothing else takes Escape.
  - While arranging (Arrange interface) or while a floating panel is dragged, every column shows, so its drop zone
    and outline are there.
  The popped column is drawn exactly as a docked one (same panels, same water-filling), with the Lens panel shadow,
  so nothing about its content differs between presentations.
- **Setting**: Settings > Interface > PANELS "Columns pop over a narrow window" (on; settings row
  `column_popovers`). Off keeps today's behaviour.
- **Summaries** for the sections that had none: Levels ("Level 2 of 4"), Topology ("Dynamic on"/"off"), Mask
  ("Mask shown"/"No mask"?) only where the state is cheap to read, Remesh (its density), Mirror (axis), Floor
  ("Grid on"), Background, Studio ("Render on"), Print ("25 mm a unit"), Turntable (frames), Look (the look's name),
  Material (the selected object's material name), Environment (on/off).
- Never saved: which column is popped. Exit stats: `columns_narrow=` (1 while the rule applies), `column_popped=`
  (`left`, `right`, `left,right` or `none`), `column_pops=` (how many times a column popped).

## Code
- `panels.odin`: `Panels.popped: [Column_Side]bool`, `Panels.pops`, `Panels.open_last: [Column_Side]u64` (a bit per
  ref, `panel_bit(ref)`: window index, then `len(Kit_Window) + section`; a `#assert` keeps it under 64);
  `columns_narrow(app)`; `column_visible(app, side)` = !narrow || popped || arranging || a panel drag;
  `column_shown` returns nothing for a hidden column; `kit_columns` first closes a popped column on a viewport press
  (`ctx.input.pressed != {}` with `ctx.pointer_root == 0`, then `ctx.swallow = true`), pops a column when a panel in
  it went from closed to open, and draws `kit_column_tab` for a hidden column with open panels.
- `commands.odin` `.Inspector`: when narrow and the tray is docked, toggles that column's `popped` (and opens the tray
  if it was closed); `checked` reads the popped state there.
- `kit_settings.odin` row, `settings.odin` `column_popovers`, README (Panels), sm-ui note.
- Tests: `panel_bit` distinct for every ref; a narrow layout hides a column until popped; touch at 1024 x 768: the
  tray's column hidden at start with its tab, a tab tap pops it, a press on the viewport closes it without a dab,
  Palettes pops it, a wide window shows the column as before.
