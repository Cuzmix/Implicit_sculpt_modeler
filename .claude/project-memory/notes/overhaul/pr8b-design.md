# PR 8b: the Paint toggle and the colour island (as built)

8a (Blur and Erase, strokes v14, paint_dial) shipped earlier as #278; 8b is the UI of design §2.7.

- `src/app/paint_toggle.odin`: `paint_toggle` (Sculpt <-> Brush_Settings.paint_on, Both at first, settings line
  `paint_channel_on`), command `Paint_Toggle`, `shelf_paint_toggle`, `kit_colour_island`, `colour_island_lift`.
- The toggle is its own tile beside the dock on the pen side (as the active brush tile stands on the off-hand side),
  inside SHELF_SIDE_ROOM, so the dock neither moves nor loses tiles: putting it inside the dock row shifted the
  centred dock and broke five shelf scenarios' coordinates. Only in Sculpt, not focused, shelf at its default place.
- The colour island: while channel != Sculpt or the Paint brush is held, in Sculpt with the Brush tool, the dock shown,
  History closed, not focused. Main colour well (the colour popover, as kit_color's well), second colour (tap swaps),
  up to five history swatches as room allows, Eyedropper, and for channel brushes the Sculpt + paint / Paint only tabs.
  The action bar and the offer line rise by colour_island_lift; dock_stack counts it.
- `shade` in kit_colors.odin lost its file privacy.
- Parity: only the new Paint tile's box (1300..1392 x 796..881) differs on the 19 screen dumps; every viewport matches.
- Touch: paint_toggle_turns_painting_on_and_off, paint_toggle_off_hides_the_island, paint_toggle_lays_colour_as_it_sculpts.
  Unit: paint_toggle_remembers_its_channel.
