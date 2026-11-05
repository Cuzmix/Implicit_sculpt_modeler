# Lens P0-3: Arrange mode

Spec: Lens report, "Customisation model" ("Arrange mode is how users customise…") and items 2, 3 and 5. It builds on #209 (Customise bars: `bars_edit`, `Bar_Slot`, the slot popover, + tiles, and zone-named `bar` lines) and on P0-1 and P0-2 (panels, workspaces).

## What exists when done
- **Customise bars becomes Arrange.** The command keeps its id (`Customise_Bars`), so keys and pies still find it. Its label is "Arrange the interface", and Search still finds it by "customise". Everything #209 does stays: rings, the slot popover, + tiles, and a long press on a dock slot.
- **The Arrange head** sits under the top bar, in the switcher's place, and holds:
  - the workspace name, with the amber dot when changed;
  - **Bars**: a toggle for each zone (Brush bar, View bar, Dock, Wheel, Next steps). Off hides that zone in this workspace, which is the same `k.hidden` P0-2 added;
  - **Panels**: a drawer listing every panel (the tray, Stats, Objects, Colors, Thumbnail, and each pinnable section). Each row has Dock left, Dock right, Float and Hide, and shows where the panel is now;
  - **Reset bars**, as in #209;
  - **Reset workspace**: the saved layout back (Revert), or for a built-in after a second tap, as shipped;
  - **Save as new** and **Done**. Done saves nothing; the dot says whether there is anything to save.
- **Columns show their drop zones** for the whole time Arrange is on, not only while dragging. An empty column shows a dashed outline with "Drop a panel here".
- **Hidden zones show as dashed outlines** where they would be ("Brush bar, hidden: tap to show"), so nothing is lost while arranging.
- **Workspaces now include the right bar's shortcut column and the bottom bar's tool strip.** These are #209's `bar_count`/`bar` lines, written into the layout text. The dock is left out: it holds brushes and presets, which are the user's own set rather than a layout, and it stays global. Built-in workspaces keep the default bars.
- **Search's "Put on a bar"** is #209's existing slot choose (`bar_choose`). Nothing new is needed.

## Code
- `kit_layout_text`/`kit_layout_put` take `^App` (for `bar_list`). `built_in_layout` uses a scratch `App` from the temp allocator.
- The bar lines' parsing moves out of `settings_load` into `bar_load_line(app, f)`, shared with the layout reader. The writing moves into `bars_save(app, out)`, shared too.
- `kit_bars_edit_head` grows into `kit_arrange_head` (bars.odin). The zone toggles write `k.hidden`. The panels drawer is a popover from a "Panels" button.
- `kit_column_drop` draws while `k.bars_edit` is on, as well as while dragging. Hidden zones get `arrange_ghost(app, zone)`, which draws a dashed rect at the zone's default place; a tap on it shows the zone.
- Exit stats: `arrange=` (the same as `bars_edit`), `panels_drawer=`.

## Not in this PR
Dragging commands from a Library drawer onto bars (the + tile and Search cover this), Reset zone for a single zone, and workspace files (P1).
