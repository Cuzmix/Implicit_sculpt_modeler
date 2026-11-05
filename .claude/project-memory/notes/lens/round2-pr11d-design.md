# Round 2, PR 11d: Arrange and the dial (design)

This PR builds round 2's custom2 screen, in Lens only. Classic's Customise bars keeps its head card and everything else it has now.

## What exists

- **Arrange** (`arrange.odin`) is `bars_edit` with a head card under the top bar. The card has:
  - the title, "Arranging Sculpt (changed)", with Done;
  - Panels, which opens a drawer of every panel with Hidden, Left, Right or Float;
  - Reset bars, Revert and Save as new;
  - a row of Show chips, one per `Zone` (Brush bar, View bar, Dock, Wheel, Next steps).
- **Ringed buttons and the + tiles**: a tap opens the slot popover, or Search to choose a command (`bar_choose`, `Palette_For.Bar_Pick`).
- **The dial** is the modifier wheel (`modifiers.odin`). Its sectors are fixed in `WHEEL_SECTORS`: Smooth on top, the brush pie on the right, Invert at the bottom and Mask on the left.
  - A finger on a modifier sector belongs to the wheel (`rail_claims`). A finger on the pie's sector is the panels' to tap, unless another finger is already on the wheel (`rail_claims_plain`).
  - The grip drags the wheel, and two fingers pinch and twist it.

## What 11d adds

### 1. The top bar in Arrange (Lens)

While arranging, the workspace pill gives way to:

- "Arranging Sculpt" in the accent colour, with the amber dot when the layout has changed;
- **Reset zone**, which resets the picked zone (see 2) and is greyed out with no zone picked;
- **Reset workspace** (`.Workspace_Revert`, renamed in this spot only);
- **Save as new** (`.Workspace_Save_As`);
- **Done**.

Lens's head card goes. Its Panels drawer and its Show chips move into the Library (see 3).

### 2. Zone outlines and name tags

While arranging, each visible zone draws a dashed-looking outline (a hairline in the accent at 50%) round where it was drawn last frame, with a name tag at its top left:

| Tag | Zone |
|---|---|
| Off-hand | the size and strength sliders, kit_offhand |
| Dial | the wheel |
| Shelf · page 1 of 4 | the Lens shelf, with its page |
| Panels | the right column's stack |
| Rail · 8 | the view rail, with its button count |

- A tap on a tag picks that zone. The tag turns solid accent, and Reset zone resets that zone:
  - the Shelf's or the Rail's slots go back to the built-in ones (`bar_reset` of that `Bar_Which`);
  - the Dial's sectors, size and turn go back to their defaults;
  - the Off-hand's slider choice goes back to its default;
  - the Panels go back to the stack of the workspace's built-in layout.
- Each zone records its rect while it draws, in a new `Arrange_Zone` array on `Kit_State` (frame data only, never saved). The outlines are drawn after everything else, over the zones.
- New enum: `Arrange_Zone {Offhand, Dial, Shelf, Panels, Rail}`. It is separate from `Zone`, which is what a layout shows or hides.

### 3. The Library sheet

- While arranging, a floating sheet titled **Library** (about 480 by 400 points, movable, under the top bar on the left) has two tabs: **Panels** and **Dial**.
- **Panels** holds what the head card held:
  - every panel with Hidden, Left, Right or Float;
  - the Show chips for the zones;
  - the paragraph about pinning sections.
- **Dial** holds:
  - Top, Right, Bottom and Left, each a select;
  - Size (the existing `wheel_size`);
  - Show names under icons (`wheel_labels`, as a switch between Icons and Icons and names);
  - Keep the dial in clean view (`clean_dial`).
- **Left for a follow-up**: the mock's Commands, Brushes and Views tabs, and dragging items onto a zone. A tap on a ringed button already chooses any command, brush or view through Search, so nothing becomes unreachable.

### 4. Dial sectors

- New `Dial_Sector :: struct {kind: Dial_Kind, modifier: Modifier, command: Bar_Slot}`, with `Dial_Kind :: enum u8 {Modifier, Pie, Command}`.
- `Kit_State.dial: [4]Dial_Sector` replaces `WHEEL_SECTORS`. The default is today's: Smooth, Pie, Invert, Mask.
- Dial sectors are settings, `dial_sector N <name>`, written as "Smooth", "Invert", "Mask", "Hide", "Pie", or `command_name` for a command. They are not part of a workspace layout, because they belong to the hand rather than the screen.
- **The select for a sector** lists Smooth, Invert, Mask, Hide, Brush pie, then "A command...". The last opens Search with a new `Palette_For.Dial_Pick` (the sector), and a pick puts that command on the sector. A sector already holding a command shows its label as the select's current item.
- **The finger rules change in one place**:
  - `rail_hit` returns a modifier only for a Modifier sector. A Pie or Command sector is plain, as the pie's sector is today: a lone finger there is the panels' and runs it on a tap, and with another finger on the wheel it joins the pinch.
  - `rail_finger_move`, `rail_finger_up` and `touch_event` do not change.
- **Drawing**: a Command sector shows the command's icon and short label, lit while the command is checked (Symmetry X, for one).
- Two sectors may hold the same modifier. Latching either latches the modifier, and both light up.
- **A dial with no modifier left**: nothing breaks. The keyboard and the Hold gestures still give Smooth, Mask and Invert, and Settings says so under the selects.

### 5. The dial in Arrange

The wheel already moves by its grip and resizes and turns by pinch. In Arrange, a one-finger drag anywhere on the dial moves it, so the sectors cannot latch while you are arranging. A tap on the dial picks the Dial zone.

## Tests

- **Dial sectors**:
  - The default is today's.
  - The setting names read back.
  - A Command sector is never claimed by `rail_claims` and runs on a tap.
  - Two Mask sectors latch together.
  - Reset zone on the Dial restores the default.
- **Arrange**:
  - Every visible Arrange_Zone records a rect.
  - Reset zone on the Rail restores the built-in rail and leaves the shelf alone.
- **Touch scenarios**:
  - `lens_arrange_dial_sector_runs_a_command`: set the top sector to Frame all through the Library and a pick in Search, leave Arrange, tap the top sector, and check `frame_all` ran and no modifier latched.
  - `lens_arrange_reset_zone`: add a button to the rail, tap the Rail tag, press Reset zone, and check the rail count.

## Size

About 450 lines of app code, plus tests. No new GPU buffers, shaders, `Scene_Command` kinds or History changes, and no change to the scene file. The settings file gains `dial_sector` lines, which older builds ignore.

## After review (sm-architect)

These points replace the matching parts of the design above.

- **A sector is a `union {Modifier, Bar_Slot}`.** There is no `Dial_Kind`. The pie is the command `.Brush_Pie`, so the default dial is Smooth, `{.Brush_Pie, 0}`, Invert and Mask.
- **`rail_hit` takes the sectors as an argument**, so the tests that build a bare `Modifier_Rail` keep working. A lone finger on a command sector stays unclaimed, as on the pie's sector today, so during the dab wait it plays the dab.
- **Hide lights when Smooth and Mask are latched together.** `lit_of` checks both ways.
- **Settings lines use the dock's tagged form**: `dial_sector N modifier Smooth` or `dial_sector N command <name>`. They are written only when the dial differs from the default, and a command is checked with `bar_lists` when it is read.
- **Zone outlines use `ui.prev_rect` of the named containers.** There is no rect array.
- **The one-finger drag in Arrange is dropped.** The grip and the two-finger pinch already move and resize the dial, so the `ui` wheel and `rail_claims` do not change.
- **Dial tab**: Show names under icons stays the three-way choice it is in Settings (Icons, Icons and names, Names).
- **Removing the modifiers**: Smooth, Mask and Hide have no gesture command, so a dial without them leaves only the keyboard. The Dial tab says so under the selects when a sector change leaves no Smooth or no Mask on the dial. The selects still allow it, because a pen with a keyboard beside it may not need them.
