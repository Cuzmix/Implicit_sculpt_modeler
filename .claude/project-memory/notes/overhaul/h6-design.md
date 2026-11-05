# H6 step pictures (built)

- render.Step_Pictures: 1152 px atlas (64 cells of 144 px = 72 pt at 2x), drawn via Thumbnail_View at supersample 1,
  copied into a cell. No new HAL call, no shader.
- Picture = scene redrawn through main view proj narrowed (crop matrix) to a square round the step's changed area
  (history_tint_box -> flash_screen_box), side = 1.3 x box, min 96 px.
- Drawn when the newest done step changes and has no cell (also after undo to a step whose cell was reused), in that
  frame, one per frame, never while seeking/playing/lapse/grid work. Keyed by the step's first entry `at`.
- Shown: strip hover card (picture, name, object, age, size; tooltip kept for steps with none), step menu head,
  list rows with "Step pictures in the list" (history_pictures, off).
- Cost: one whole-scene draw at 144 px per finished step; not measured on a real GPU yet.
