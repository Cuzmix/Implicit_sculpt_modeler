# PR 14: Sweep (chip sections as islands, touch, README and skills)

Part of the round 3 overhaul (design.md "Chip bar": "In Arrange, any section can be dragged
out of the bar into an island of its own (a dock holding that section). An island can be
dropped back on the bar." and "Chip bar. It stays its own zone, not a dock item.").

## What exists when it is done

- The chip bar's six sections are `Chip_Section` (Menu and file, Undo and Redo, Spaces,
  Object, Search, History and Settings). Each is in the bar (as today) or an island: a small
  floating bar in the docks' style holding only that section, at a point the person chose.
- In Arrange every section that is drawn (in the bar, or an island) shows a thin outline,
  and a drag anywhere on it carries it (its buttons do not act while arranging, as on iOS's
  home screen). Let go over the chip bar: it goes back in the bar. Let go elsewhere: it
  floats there as an island (clamped into the safe area, under the bar's band).
- Arrange's middle replaces Spaces and the object chip, so Library > Docks gets a row
  "CHIP BAR" of six toggles: a tap takes a section out to an island under where it stood
  (or puts it back). "All in the bar" puts every section back.
- With a section out, the bar closes up: the dividers stand only between sections that are
  there, and the middle's fit (the object chip giving up badges, then Search shrinking) uses
  what is left. With every section out and not arranging, the bar is not drawn.
- An island of Search shows the field; one of the object chip shows it whole; one of the
  spaces shows the tabs. The menu and the command palette open under their island.
- Focused layouts (their own three islands) do not draw chip islands.

## Data

- `Kit_State.islands: [Chip_Section]Maybe([2]f32)`: nil in the bar, else the island's
  top-left in layout terms (the kit mirrors it for a left hand, as floating docks).
- Layout line `chip_island <section> <x> <y>` (names menu, undo, spaces, object, search,
  end), written in `kit_layout_text` and read in `kit_layout_put` (which puts every section
  back first). An older build passes over the line. No version bump.
- `Arrange_State.chip_carry: Maybe(Chip_Section)` shares carry_from, carry_press, carrying.
- Exit stats: `chip_islands=none|undo:600,300,...` and `chip_carries=`.

## Tests

- `chip_islands_test.odin`: the line round trip, mirrored; unknown names passed over;
  the drop over the bar or elsewhere.
- Touch (1440x900, customise_bars): a finger drags Undo out of the bar (island, after Done
  the bar has no Undo and the island stands there); the mouse drags the island back; the
  Library toggle takes Spaces out.

## Sweep rest

- The touch scenarios already cover docks, groups, spaces, the object menu and offers
  (checked); chip islands are the new gesture.
- README's Interface section: the chip bar and islands.
- sm-ui (500 lines) trimmed to make room; sm-touch-testing gets the chip island scenarios.

## As built (30 Oct)

- Islands are a setting (settings file `chip_island <section> <x> <y>`), not layout lines: the
  first build kept them per layout, and a tap on a Spaces island's Model tab switched to Model's
  layout, which put the tabs back in the bar under the finger. The chip bar holds the spaces, so
  it is the same in every space and workspace. Reset workspace leaves islands alone; Library >
  Docks > All in the bar puts them back.
- A new island from the Library goes to the first clear spot under the bar nearest where the
  section stood (clear of the view chips, rail, navigation head, off-hand island, panels and other
  islands); the Library itself may cover it until it is put away.
- In Arrange the whole section is the grip (an overlay `ui.area` over it), not a tag: the bar has
  no room above it for tags.
- sm-ui split: the Lens layout bullet (105 lines) moved to `.claude/skills/sm-ui/references/lens-layout.md`.
- PR #349.
