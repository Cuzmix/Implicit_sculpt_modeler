# P1 Layers panel (built)

- lens_layers.odin rewritten: head (New layer solid, level text, Wide ±5 chip), rows 56 pt: picture zone
  (drag-scrolled: swipe left -> Merge down + Delete), record dot, name + strength caption as one area (tap picks,
  rest/press tints, long press/right click -> layer menu), inline strength bar (-1..2 or ±5, catches 0 and 1, picks the
  layer), eye; Base sculpt row; foot Duplicate / Merge down / Bake all / menu.
- Layer menu popover: Rename (Rename_Entry.layer mode), Record/Stop, Hide/Show, Duplicate, Invert, Merge down,
  Move up/down, Bake into the base, Delete.
- layer_pictures.odin: second render.Step_Pictures atlas, ortho from main view direction fitted to
  sculptor_layer_bounds, settle like object thumbs. Tint uses shared draw_tint_glow (accent colour).
- Removed the More options block of the card (menu replaces it); Object palette Layers section unchanged.
