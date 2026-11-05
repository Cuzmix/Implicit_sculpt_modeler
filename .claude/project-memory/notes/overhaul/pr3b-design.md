# PR 3b: each space's own shelf set and dial

Part of the round 3 overhaul (design.md sections 1 "Dial and palm zone" and 2.3; section 6's
revised order: "3b. Per-space bottom sets (Model, Render; the Paint page migrates) and the
per-space dial (Model Select, Render Light, Exposure and Focus commands)").

## What exists when it is done

- **The shelf follows the space** (it already does for Model):
  - Sculpt: the Sculpt, Paint, Move and Curve pages, then the tool strip, as today.
  - Model: the Model page, without the tool strip, as today.
  - Render: a new **Render** page, also without the tool strip:
    - Render (Fast) and Full render;
    - the two looks, Sculpt studio and Classic;
    - Material, Lights and Environment, each opening its section beside its tile;
    - Exposure as a chip;
    - Pick focus;
    - Screenshot, Record turntable and Render preview pane.
  - Each page is a bar Customise bars changes, as the others are (`shelf_render` in settings).
- **The dial follows the space.** Each space keeps its own four sectors:
  - Sculpt: Smooth, Pie, Invert, Mask, as today. Paint already relabels Smooth and Invert as
    Blur and Erase.
  - Model: Snap, Pie, Alt, Select.
    - Snap and Alt are today's Smooth and Invert modifiers, which the Model tool already reads
      that way: Shift snaps and Ctrl is Alt (model_tool.odin:630).
    - The modifiers are named Snap and Alt in Model (`modifier_name`).
    - Select is the Model action Select (`Bar_Slot{.Model_Action, Select}`).
  - Render: Light, Pie, Exposure, Focus.
    - Light is a new command `Place_Light`, which toggles Place highlight. It is lit while on,
      so a press on the model moves the picked light's highlight there.
    - Exposure is a new value, `Brush_Value.Exposure` (the view's exposure, ±EXPOSURE_RANGE
      stops, in its section's steps). It is a value item like the brush's, so it also goes on
      any bar, and its popover has steps of -1, 0 and +1 stops.
    - Focus is `Pick_Focus`.
- **Library > Dial edits the current space's sectors**, and says which space it is editing.
  Reset puts all three back.

## Data

- `Kit_State.dial: [4]Dial_Sector` becomes `dials: [Space][4]Dial_Sector`, and
  `dial_of(k) -> ^[4]Dial_Sector` returns the current space's. Every reader moves to it:
  `kit_modifier_rail`, `rail_hit`, `rail_claims`, `dial_has`, the exit stats, Library > Dial and
  the palette's `Dial_Pick`.
- `DIAL_DEFAULT` becomes `DIAL_DEFAULTS: [Space][4]Dial_Sector`. `dial_is_default` checks one
  space.
- **Settings.**
  - Today's `dial_sector <i> <kind> <name>` line keeps its meaning and is written for Sculpt's
    dial, so an older build keeps the person's Sculpt dial.
  - A new `dial_space <space> <i> <kind> <name>` line is written for each changed sector of
    Model's and Render's dials. An older build passes over it.
  - Reading a `dial_sector` line from a file with no `dial_space` lines (any file written
    before this PR) sets that sector in all three spaces. That keeps design.md's rule: "a user
    who changed a sector keeps it in every space".
  - Reading `dial_space` sets only that space's sector. No settings version bump is needed:
    the only line whose reading changes is one that old files wrote for the single dial they
    had.
- `Shelf_Page.Render` and `Bar_Which.Shelf_Render` go after Model. Bars are saved by zone
  name, so the ordinals that move (Brush_Pie, Offhand) are never stored.
  - `shelf_pages_of(.Render)` returns Render alone.
  - `tools_here` leaves the strip out on the Render page as on Model.
  - `SHELF_RENDER` is the fresh set.
- Render's tiles take no new drawing: each is a `Bar_Slot` that `bar_slot_run` already knows,
  plus the Exposure value item. A Show_Section tile opens its section beside it.

## The Paint page

The revised order says "the Paint page migrates", meaning it folds into the Paint toggle. The
toggle is PR 8b, so the page stays in Sculpt until 8b, which migrates it. Nothing changes here.

## Tests and checks

- `spaces_test.odin`: each space's dial starts as its defaults.
  - Switching space switches the sectors that `rail_hit` sees.
  - An old `dial_sector` line sets all three spaces; a `dial_space` line sets one.
  - Save and load round-trip all three.
- `bars_test.odin`: the Render page's fresh set; `shelf_render` lines round-trip.
- `brush_values_test.odin`: Exposure sets and reads within its range.
- Touch scenarios:
  - In Render, the shelf shows the Render page and the Exposure chip scrubs the exposure.
  - The Render dial's Light sector lights Place highlight.
  - The Model dial's Select sector picks the Select action.
  - Library > Dial in Model changes Model's sector and not Sculpt's.
- Exit stats: `dial=` already prints the sectors; it prints the current space's. A new
  `dial_spaces=` gives the three spaces' changed counts.
- README (shelf pages per space, the dial per space, Library > Dial) and sm-ui.
- `parity_check.py`: Sculpt is unchanged.

About 350 lines.

## Review corrections (sm-architect, 29 Oct)

- Place highlight works only while the Lights section shows, so `Place_Light` opens the Lights
  section when it turns on (run again with the switch on but the section closed, it opens the
  section). The gate is not loosened, so a Sculpt press never moves a light it did not before.
- Settings version 6. `dial_sector` lines are Sculpt's; `dial_space <space> <i> <kind> <name>`
  lines hold Model's and Render's, each written whole when not default. A file before 6 that
  changed a sector copies only the sectors that differ from Sculpt's defaults into Model, and
  into Render only the command sectors (a modifier does nothing there).
- The stat is `dial_sectors=` (the current space's); `dial_spaces=` is new.
- The Render page's first tile is `Studio_Render` ("Render", at the section's quality).
- `modifier_name` checks the Model tool before painting.
- A space switch drops latches the new dial does not hold.
- Library > Dial names the modifiers as the space does, names the space in its caption (no new
  row, so the arrange coordinates hold), and warns about Smooth and Mask only in Sculpt.
- The picker opened from Render lists every brush; Arrange's page count is the space's.
- kit_help's Place highlight entry, COMMAND_HOMES and search words cover `Place_Light`.
