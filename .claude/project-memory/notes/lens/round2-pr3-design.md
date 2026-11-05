# Round 2, PR 3: shelf with named pages, tile quick settings, brush picker sheet (Lens)

Screens `brushQuick` and `brushPick` in `/mnt/project-files/ui-direction/round2/screens.js`. Lens chrome only; Classic keeps its dock, mesh tools strip and brush browser as they are.

## What exists when done

- **Shelf** (replaces the dock and the mesh tools strip in Lens, same zone `Dock`, laid out as "dock"):
  - A floating strip of brush tiles at the bottom centre, All at its end after a divider.
  - Under it, the page names Sculpt, Paint, Move and Curve (the bottom-left mode menu Bolt asked about becomes these pages). A tap turns the page.
  - Each page is a bar of its own, `Bar_Which.Shelf_Sculpt` to `Shelf_Curve` (zones `shelf_sculpt` and so on), up to 12 tiles. Customise bars, the slot popover and Search-pick work on it unchanged.
  - Pages hold the person's brushes, so workspace layouts leave them out (as the dock); settings.txt keeps them.
  - On a tablet-shaped window it moves left of the middle (9% of the width, mirrored when left-handed) and shows 8 tiles, clear of the pen hand's palm.
  - The mesh tools (remesh, dynamic topology, retopologize, subdivide, live boolean) leave the bottom in Lens; Search and the tray reach them until PR 9's Tools palette.
- **Quick settings** (long press a brush tile, the app's hold delay): picks the brush and opens a popover above the tile with its stroke preview, name and favourite heart, Radius, Strength, Stroke kind, Alpha (Round plus the first five), Lazy mouse, Pin as panel (the Stroke section) and All settings. A command tile's long press does what it does on any bar.
- **Brush picker** (All, or B in Lens; command `Brush_Picker`): a sheet up to 1000 wide centred over the shelf, which stays visible.
  - The categories column (200 wide) in `BRUSH_CATEGORY_ORDER`, with counts and packs.
  - Head: search, the shelf's page names (narrow All by what each page is for, and turn the shelf), Import (content pack), Close.
  - A 4-column grid of cards, each a procedural stroke on clay (`lens_stroke_preview`), name, heart if favourite.
  - Tap picks and closes; long press opens settings; a drag past the slop carries the card (a ghost above the finger, the tile under it ringed); release over a tile replaces it on the shown page.
  - Footer hint.
- Classic B stays Tool_Sculpt; `keymap_default` maps it to Brush_Picker in Lens.

## Tests

- Unit (`lens_shelf_test.odin`): defaults, bar procs, settings round trip, layouts leave shelves out; `shelf_slot_of` and labels; B per chrome and the command toggling.
- Touch (LENS_1440): tap picks; long press opens quick; page name turns; All opens the picker, a card picks and closes, its Paint turns the shelf; a card dragged onto Layer replaces it.
- Screens at 1440x900 against `brushQuick` and `brushPick`, 1366x1024, left-handed, and Classic unchanged.
