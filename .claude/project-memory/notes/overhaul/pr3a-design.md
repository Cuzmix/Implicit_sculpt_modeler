# PR 3a: brush values on any bar, and the off-hand island as a bar

Bolt (29 Oct, 14:20): brush Size, Strength and the other values need icons, and should be
placeable in the toolbars as Classic had them, with the user choosing. Mock: round 3 artifact,
tab 14 (vChips, vLooks, vIcons).

The design note's 3a was "Bar_Dock type and placement". Placement has no use until Arrange can
drag a dock (3c), and changing every chrome root's placement without a way to move it is a large
refactor no one can see. So this PR does the part people see first and the part placement needs:
the off-hand island becomes a bar whose items are values or commands, and every bar can hold a
value. `Bar_Dock` placement (edge, along, at, layout lines) moves into 3c with Arrange, where it
is used. 3b (per-space bottom sets, per-space dial) is unchanged.

## What exists when it is done

- Six brush values, each with its own glyph: Size, Strength, Focal shift, Spacing, Lazy,
  Pressure.
- Each value can sit on any bar: the off-hand island, the view rail, the shelf's tool strip, any
  shelf page and the brush pie.
- Each value item has a look, chosen per item:
  - **Slider**: today's tall slider (the off-hand island's look). Only on column bars; on a row
    bar it draws as Chip.
  - **Chip**: the glyph over the number, with a hairline showing how far it is set. A tap opens
    the value's popover; a drag across the bar scrubs it (sideways on a column bar, up and down on
    a row bar, so it never fights the shelf's page swipe or the rail's scroll).
  - **Icon**: the glyph alone. A tap opens the popover.
- The popover: the glyph, the name and the exact value, a wide slider, and step chips to tap
  (Size 12, 24, 48, 96, 192 px; Strength .25, .5, .75, 1; Focal shift -50, 0, 50; Spacing 5, 10,
  20, 50 %; Lazy off, 10, 30, 60 px). Pressure's popover is two switches, Size and Strength, since
  it is on or off for each.
- A long press (or right-click) on a value item opens its menu: Show as Slider, Chip or Icon (a
  tick on the current one; Slider absent on a row bar), Brush settings (the section today's long
  press opens), Move left and right (or up and down), Add another value (the values not yet on
  that bar), Remove from the bar.
- The off-hand island is a bar (`Bar_Which.Offhand`, zone `offhand`). It holds values and any
  command, so it can also be a Classic-style toolbar. A fresh install holds Size and Strength as
  Sliders, so it looks exactly as today. Customise bars rings its items and ends it with a +.
- Search lists each value once ("Size", "Strength" …). Running one (a key, the pie, Search) opens
  its popover at the pointer. Put on a bar from Search, it takes the bar's default look: Slider on
  the off-hand island, Chip elsewhere.

## Data

No new list type: a value item is a `Bar_Slot` (`Pie_Slot {id, arg}`), so every bar, the pie,
keys, gestures and the settings lines hold it already.

```odin
// src/app/brush_values.odin (new)
Brush_Value :: enum u8 { Size, Strength, Focal_Shift, Spacing, Lazy, Pressure }
Value_Look  :: enum u8 { Slider, Chip, Icon }

// A value item's command argument: the value, and its look in the higher places.
value_slot :: proc(v: Brush_Value, look: Value_Look) -> Bar_Slot  // {.Brush_Value, int(look)*len(Brush_Value)+int(v)}
value_of   :: proc(s: Bar_Slot) -> (v: Brush_Value, look: Value_Look, ok: bool)
```

- New command `Brush_Value`, `args = len(Brush_Value) * len(Value_Look)` (18). Its arg names are
  `Size`, `Size_Chip`, `Size_Icon`, … so `command_from_name`'s generic loop reads them and a
  saved bar line reads `bar offhand 2 Brush_Value:Focal_Shift_Chip`.
- `palette_entries` lists only the Slider arguments of `Brush_Value` (one line), so Search shows
  each value once.
- Reading and writing each value: `value_get(app, v) -> f32`, `value_set(app, v, f32)`,
  `value_range(v) -> (lo, hi, scale)`, `value_text(app, v) -> string`. Size is
  `brush.radius_px`, Strength `brush_strength(app)^`, Focal shift `focal_shift(app)^` (made
  non-private), Spacing `brush.spacing` (0 reads as `DAB_SPACING`), Lazy `brush.lazy_px`.
  Pressure is read as `pressure_size || pressure_strength` and set through its popover's two
  switches. These are the same fields the Pen and Stroke sections' sliders change, with the same
  ranges and roundings (focal in whole steps), so nothing new reaches the sculpt state.
- Glyphs: `value_glyph(ctx, v, center, size, color)` draws each one as strokes on Lucide's 24
  grid with `ui.polyline`, `ui.line` and `ui.stroke_circle` (the curves sampled), at the stroke
  width Lucide's font has at that size. Lucide has no glyph for these, and adding outlines to the
  font needs stroke-to-outline tooling the repo does not have. `src/ui` gains nothing.
- `Bar_Which.Offhand` (after `View_Rail`, zone `offhand`, `OFFHAND_MAX :: 8`), in
  `BAR_LAYOUT`, so a workspace's layout keeps it. `OFFHAND_DEFAULT` is Size and Strength as
  Sliders. The settings file needs no version bump: an older file has no `offhand` lines and
  gets the fresh island, which is today's.
- The popover is the bars' popover with a new `Bar_Pop_Kind.Value` and a `value` field, so it
  opens, toggles and closes as every bar popover does (`bar_pop_toggle`, `kit_floats_close`).
- The value menu is `k.bar_slot` (the Customise bars popover) opened outside the edit mode for a
  value slot, with the look rows and Brush settings added above its Move, Add and Remove rows.

## Layout

- `kit_offhand` keeps its root name `brush bar` and its anchor. It walks `bar_used(.Offhand)`:
  a value slot draws by its look (`value_item`), any other slot is `bar_slot_button`. Pen roll
  over a Size or Strength item still sets it (`island_roll`), in the Slider and Chip looks.
- `value_item(app, which, slot, v, look, column)` is shared by every bar: the view rail and the
  off-hand island pass `column = true`; the tool strip and shelf pages `false`; a Slider on a row
  bar draws as Chip. A Chip is 52 × 56 on a column bar and a tile's size on the shelf.
- `bar_slot_run` for a value slot opens the popover beside the slot (`bar_side(which)`); from the
  pie, a key or Search, at the pointer.

## Tests and checks

- `brush_values_test.odin`: each value round-trips through `value_set`/`value_get` within its
  range and rounding; `value_slot`/`value_of` round-trip every value and look;
  `command_name`/`command_from_name` round-trip all 18 arguments; Search lists six; an off-hand
  bar line from settings reads back; a fresh `Offhand` is Size and Strength Sliders, and a
  settings file from before (no `offhand` lines) gives the same.
- `parity_check.py` against the base build: the 19 scenes pixel-identical (the fresh island is
  today's).
- Touch scenarios: a Chip's tap opens the popover and a step chip sets Size; a drag across a Chip
  scrubs Size; a long press picks Icon and the stats show it; a value on the shelf's tool strip
  scrubs up and down while a sideways swipe still turns the page; Pressure's popover switch.
- Exit stats: `values=<items on bars> value_pops=<opened> value_scrubs=<drags>` and
  `offhand=<names>` (as `bar_names` gives).
- README (the off-hand island, Customise bars, Search), sm-ui (values on bars, the looks).

## Not in this PR

- Docks' placement on other edges and floating (3c, with Arrange).
- A dot on an Icon for "not the brush's own" from the mock: the brush has no per-value default to
  compare with, so it would mean nothing reliable. Left out.
- Typing an exact number in the popover: the kit has no number field today; the steps and the
  slider cover it. A later PR can add one for every slider at once.

About 600 lines, most of them in `brush_values.odin`.

## Architect review (29 Oct): corrections. This section wins over the sections above.

- **Glyphs are Lucide's.** A slot's icon is a `rune` in the pie, the dial, Search, Settings >
  Keys, shelf tiles, the pie editor and `icon_button`, so drawn glyphs would need a hook in
  `src/ui`. The font has close glyphs: Size `diameter` (e52b), Strength `gauge` (e1bf), Focal
  shift `focus` (e29e), Spacing `ellipsis` (e0ba), Lazy `spline` (e38f), Pressure `signature`
  (e5f7). `value_glyph` is dropped.
- **The look lives on the bar, not in the argument.** `Brush_Value` has six arguments (one per
  value). `Bar_List` gains `looks: [BAR_SLOTS_MAX]Value_Look`, written as its own line
  `bar_look <zone> <slot> <look>` after the slot's `bar` line, only where it is not the bar's
  default look. An older build passes over the unknown line and keeps the slot. This removes the
  18-label, script-choice, macro, chord-match and duplicate problems. The pie, the dial and
  gestures hold the plain value (a tap opens the popover).
- **Scripts and macros:** `script_allows(.Brush_Value)` is false and macros skip it.
- **Slider only on the island.** The rail scrolls vertically, so a tall slider loses to it there;
  elsewhere Slider is not offered and a value put from Search takes Chip (`bar_put` sets the look
  by `bar_default_look(which)`). Pressure is tap-only (no scrub).
- **Long press on a value opens the value menu**, as the mock has it, with Brush settings (the
  section today's long press opens) as its first row. Six touch scenarios at
  `touch_check.py:273-329` expect `bar_pop=pen` from the long press and move to the menu's row.
- **Offhand goes last in `Bar_Which`**, after `Brush_Pie`, and is the person's like the pie and
  the shelf pages (not in `BAR_LAYOUT`): a workspace switch keeps it. `bars_save` decides layout
  membership from `BAR_LAYOUT` instead of its hard-coded test. `bar_list_k` and `bar_fresh` become
  full switches. The zone is named `offhand_island` to keep it apart from `Zone.Brush_Bar`.
- **Plumbing:** `bar_side(.Offhand)` is `.Right` (mirrored); `bar_slot_actions` moves the island's
  items up and down; `bar_pop_toggle` compares `value` too; `bar_lit` lights a value whose popover
  shows; `focal_shift` is already public (adjust.odin) and `island_roll` stays private in
  lens_chrome.odin, which keeps the island's drawing; Spacing is shown disabled unless the stroke
  is Dots.
- **Gestures:** a Chip scrub claims the drag along its own axis only (`claim_drag(ctx, 1)` on the
  shelf, so a sideways swipe still turns the page), and a scrub that won the drag never also
  clicks.
- **Island limits:** at most 8 items, scrolling as the rail does when it is taller than the room;
  an empty island still draws in Customise bars for its +; sliders take no drags in Customise.
- **Stale help:** kit_help.odin:149 and settings_blocks.odin:358 are updated.
- **Parity:** the fresh island keeps the slider names and key hints, so the 19 scenes match.
