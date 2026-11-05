# Round 2, PR 4a: panel stack and Brush panel groups (Lens)

Screens `sculpt2` and `brushPanel`. The brush pie (screen `brushPie`) follows as PR 4b. Lens only; Classic keeps the tray as it is.

## What exists when done

- **The stack is the tray in Lens.** The tray's panel (`Kit_Window.Inspector`, Palettes on the rail, Tab's old key) draws as a stack of cards in Lens. It docks, floats and opens wherever the tray does, so workspaces, columns, `tray_open` and Show where keep working unchanged, and the built-in layouts stay the same text.
- **Cards, in a fresh layout's order:**
  - Brush: open. The current tool's name and settings when the tool is not the brush.
  - Symmetry, Layers and Scene: folded.
  - Palettes: folded. It holds the whole tray (the palette select, then the section), so every section stays reachable until rounds 9 and 10 give them panels of their own.
- **Each card's header:**
  - The grip. Drag it up or down to reorder, or well clear of the stack to float the card there.
  - The chevron and the title: a tap folds or unfolds the card. Folded, the header carries a summary (for example "Clay · 48 px", "3 layers", or "5 objects · Sphere 1").
  - The X, Y and Z toggles (Symmetry only).
  - Float, or Dock when the card floats.
  - More, which opens: Move up, Move down, Float/Dock, Fold the others, and Where the stack goes (the tray's panel options).
- **Floating cards** are cards of their own. Their dots drag them, and holding the dots docks them back.
- **The Brush card:**
  - At the top, the brush's card: its stroke preview, its name, its family with "· edited" when the preset has changed, and Favorite.
  - Then Radius and Strength, always shown.
  - Then the Brush palette's sections as groups that fold, each with a summary in its header:
    - Preset: folded.
    - Stroke: open; summary "Dots · lazy 30 px".
    - Colour: folded.
    - History brush: shown only on History.
    - Falloff: open.
    - Alpha: open.
    - Pen: folded; summary "pressure → size, strength".
    - Options: folded; summary "front faces · …".
    - Stroke recorder: folded.
- **Saving:**
  - The order and the open cards go in a workspace's layout as `stack Brush+ Symmetry Layers Scene Palettes`. The line is written only when it differs from a fresh layout.
  - The groups' folds last for the session.
  - Floating cards dock again when a layout is put in place.
- **Opening a section:** `tray_open` on a section opens the card that holds it:
  - a brush section opens Brush and unfolds its group;
  - Layers opens Layers;
  - Objects opens Scene;
  - anything else opens Palettes on that section.
- **Width:** the stack is the tray's content width (312), without the tray's list beside it.

## Not yet

- Per-card heights and the stack's width come in PR 5, with resizing.
- The tab strip with two or more panes comes in PR 6.
- Show where's ring does not scroll the stack to the control.

## Tests

- **Unit:**
  - `stack_layout_save` and `stack_layout_read` round trip.
  - A fresh layout writes no line.
  - `stack_move_to` keeps floating cards in place.
  - `stack_reveal` picks the right card.
- **Touch (LENS_1440):**
  - A tap on a folded header unfolds it.
  - A tap on a Brush group header folds it.
  - Dragging a grip below the next card reorders them.
  - Float floats a card.
  - The object chip opens Scene.
- **Screens:**
  - 1440×900 against `sculpt2` and `brushPanel`.
  - Left-handed.
  - Classic unchanged.

# Round 2, PR 4b: the brush pie (Lens)

Screen `brushPie`. Lens only; Classic's pie keeps every brush in key order.

- **Eight brushes by direction**, a bar of its own (`Bar_Which.Brush_Pie`, settings only, never in a layout): Clay up, then clockwise Draw, Inflate, Crease, Grab (down), Flatten, Pinch (left), Smooth.
- **Opening:** Space or a right click at the pointer, the pen's side button, the dial's Pie sector in the viewport's middle.
- **Picking:** with Space held, let go toward a slice (flick). Opened by a tap, tap a slice. A lifted finger points at nothing.
- **Resting** half a second on a slice with Space, a press or the pen held picks it and opens its quick settings beside the slice (PR 3's popover).
- **Look:** icon and name per slice; the slice pointed at pops out 10 pt, tinted and outlined in the accent; dotted line from the middle toward the pointer; the middle names it with "lift to pick" or "tap to pick".
- **Editing:** the pie editor's first row in Lens. Tap without a command to put opens Search for that slot; with one, puts it; long press or right click empties; Reset pies resets it too.

Tests: unit `brush_pie_is_a_bar_kept_in_settings`; touch `lens_brush_pie_dial_then_tap_picks`, `lens_brush_pie_space_flick_picks`, `lens_brush_pie_rest_shows_quick_settings`, `lens_pie_editor_brush_slot_chooses_in_search`. Screens `pr4b-*.png`.
