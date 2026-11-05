# Round 2, PR 5: resizable panels (Lens)

Screen `resize2`. Lens only; Classic's tray keeps its fixed width.

## What exists when done

- **Stack width:**
  - The stack's inner edge (the left one, the right one when left-handed) drags the stack from 260 to 440 pt wide.
  - The handle is a strip 28 pt out over the view and 4 pt in. At rest a short bar shows where it is.
  - While dragging, a teal line, a knob, a width pill and a dashed line at the start show.
  - A double tap goes back to 312 pt. The mock says 300; 312 is the tray's width, which every section is laid out for.
- **Card height:**
  - An open docked card has a 14 pt grip under its content. Dragging it sets the content's height (at least 48 pt); taller content scrolls inside.
  - Dragging up past the header folds the card and keeps the height it had before.
  - A double tap fits the card to its content.
- **Floating card size:**
  - Eight handles sit at the corners and edge middles. Each is a 36 pt target that reaches only 8 pt into the card, so the header's buttons keep their presses.
  - A drag moves the held edges and keeps the others. Sizes are clamped to 240×120 to 640×860.
  - A drag across leaves the height fitting the content; one up or down sets a height.
  - The size shows in a pill under the card. A double tap gives back the default size.
- **Grid:** every size snaps to 8 pt.
- **Saving:**
  - The layout line `stack_size <width|default> <Card>=<height> ...` is written only when something differs from a fresh layout, so workspaces keep their own sizes.
  - Floating sizes last for the session, since floating cards dock again when a layout is put in place.
- **Scale:** Settings › Interface › Size already scales all the chrome, so it is documented, not rebuilt.

## Tests

- **Unit:** `stack_sizes_round_trip_in_a_layout`, which covers the line, the limits, the grid, `default`, and `kit_layout_text` and `kit_layout_put`.
- **Touch:**
  - `lens_stack_edge_sets_the_width` (drag, then double tap);
  - `lens_stack_grip_sets_a_card_height` (set, then fold);
  - `lens_stack_floating_card_resizes_from_a_corner`.
- **Screens:** `pr5-width.png`, `pr5-height.png`, `pr5-float.png`, `pr5-lefty.png`.
