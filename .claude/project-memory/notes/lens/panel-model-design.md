# Lens P0-1: one Panel model and two columns

Spec: Lens report (https://claude.ai/artifact/LT1ZgSsMuUtFFtd7tm1RZw), "Customisation model" items 1, 2, 7, 8.

## What exists when done
- A **panel** is one of: the palette tray (`Kit_Window.Inspector`), Stats, History, the Objects card, the Colors card,
  the Thumbnail, or any tray section **pinned as a panel of its own** (Layers, Camera, Lights...).
- Each panel has one of three presentations: **docked** in the left or right column, **floating** (today's window or
  card, moved by its title bar or grip), or **popover** (a section opened from a bar button, as today's bar popover;
  its new Pin button turns it into a docked panel). Folding a panel (Minimise) keeps a one-line **summary** in its
  header ("3 layers", "Step 12 of 40").
- **Two columns**: the left one beside the brush bar under the object's readout, the right one beside the view bar
  under the top bar. A column stacks its docked panels top to bottom; the height is shared by water-filling
  (each panel gets what it wants, or an equal share of what is left), and a panel taller than its share scrolls.
- Moving: every panel header has **Panel options** (Dock on the left, Dock on the right, Float, Move up, Move down,
  Fold, Pin this section / Unpin, Close). Dragging a docked header past the slop **undocks** it (it floats under the
  finger and the drag goes on); dragging a floating panel over a column shows the **drop zone** and an insertion line,
  and letting go docks it there. Left-handed mirrors columns, not items.
- Default layout is today's: the tray docked in the right column, every other panel floating where it starts now.
  So nothing moves for an existing user; Workspaces (P0-2) will change built-in layouts.
- Settings, Help, Macros and Library stay side panels in the right column's place: while one is open the right
  column hides, as the tray hides today.
- Remembered: `column <left|right> <ref> ...` (written only when not the default) and `pinned <Section> <open>
  <moved> <x anchor> <y anchor> <x offset> <y offset> <minimised>`. A window ref is its `Kit_Window` name, a section
  `section:<Kit_Section>`. Reset panel positions also resets the columns and unpins.
- Commands: `Pin_Section` (one argument per tray section; toggles), `Panels_Reset`.

## Code
- `src/app/panels.odin`: `Panel_Ref :: union {Kit_Window, Kit_Section}`, `Column_Side`, columns as
  `[Column_Side][dynamic; COLUMN_MAX]Panel_Ref` in `Kit_State`, pins `[Kit_Section]Pinned`, `panel_begin`/`panel_end`
  returning `Panel_Frame{body, closed, raised, dock, docked, owner, room}`, `kit_columns`, `panel_water_fill`,
  `panel_summary`, `kit_panel_menu`, drop zones, settings lines.
- `src/ui/window.odin`: `window_begin`/`card_begin` take `options: ^bool = nil` (an extra icon button before Minimise;
  Minimise and Close keep their places); `window_grab(ctx, w, name, grab, card)` hands a held press to a window's
  title bar or grip so an undocked panel keeps following the pointer.
- Each panel proc swaps `ui.window_begin`/`card_begin` for `panel_begin`; its body height comes from `Panel_Frame.room`
  (equal to today's `window_room` arithmetic when floating), its scroll owner from `Panel_Frame.owner`.
- A docked panel is its own root container, anchored at the column's cursor (`k.panels.at[side]`), never nested in a
  column container: hit testing works per root and `prev_rect` finds roots by name, so nesting broke both.
  `k.panels.rect[side]` keeps the union of a column's panels for the drop zones and the exit stats.
- Exit stats: `window_*` read `panel_rect`; new `column_left=`, `column_right=`, `panel_pins=` (`pinned=` is the orbit pivot's).

## Not in this PR
Narrow-window popovers for columns (below 1180 pt), tab groups inside a column, resizable column width, docking
Settings/Help/Macros/Library.
