# PR 3d: user docks (New dock, Icons or Tiles, Delete dock)

Round 3's "Docks" (design.md): "In Arrange: New dock ..."; "Its density is Icons, Tiles or
Panels"; "Every dock has a grip (drag to move; long press for its menu) and a + slot (pick
anything from Search)". 3a made any command or brush value sit on any bar, and 3c gave bars a
place. 3d adds docks of the person's own, built from those two pieces, without the one-type
rewrite design.md §2.3 sketched: the built-in bars keep their code, and Panels density waits
for PR 5 (palette groups), which is what it draws.

## What exists when it is done

- **New dock** in Arrange's top bar (after Library; also the command `New_Dock`, in Search as
  "New dock", which opens Arrange first when it is off). It makes Dock 1 (then 2, 3, 4: at
  most four) floating in the middle of the free area, picked, empty but for its +, and says so
  in a note. With four in use it is disabled, its tip saying why.
- A user dock is a **column** of the person's commands and values (any `Bar_Slot` that
  `bar_lists` allows, brush values included, as the island and the rail take). Its + (while
  arranging) picks one in Search; a tap on a slot opens the usual slot popover (move, remove,
  another command). It holds up to 12.
- **Density** per dock: Icons (the rail's 44 pt icon buttons, the default) or Tiles (icon over
  its name, the shelf's tile, 64 x 58). Values show as chips in both (Slider is the island's
  alone, as 3a decided).
- **Its tag** in Arrange ("Dock 1 · 3", the count) is its grip, as 3c's tags are: a drag
  carries it to the left or right edge or floats it, with 3c's rules (one bar per edge, a drop
  on a held edge swaps; floating anywhere under the top bar). A tap picks it.
  - Picked, Reset zone empties it (it keeps its place and density).
  - A long press on the tag, or a right-click, opens its menu: Icons, Tiles (a segment),
    Delete dock. The menu says the dock's name and count. The tag's tip names the long press.
  - Delete dock takes it away at once, its slot count in the note ("Deleted Dock 2 (3
    buttons)"). Revert workspace brings it back while the workspace is unsaved, as for any
    layout change; nothing else asks first, as Arrange's other changes do not.
- **Outside Arrange** an empty dock draws nothing. Focus mode hides user docks with the island
  and the rail. A hidden-zone ghost is not needed: a dock is deleted, not hidden.
- User docks are **the layout's** (the screen's, like the rail's buttons and every place), so
  each space and workspace has its own, the built-ins have none, export and import carry them,
  and Reset workspace removes them.
- Left-handed mirrors them like every place.

## Data

```odin
USER_DOCKS :: 4
Dock_Density :: enum u8 { Icons, Tiles }

// A dock of the person's own: whether it is in use and how its buttons show. Its buttons
// are Bar_Which.Dock_1 + i's list and its place Place_Bar.Dock_1 + i's.
User_Dock :: struct {
	used:    bool,
	density: Dock_Density,
}
```

- `Bar_Which` gains `Dock_1 .. Dock_4` after `Offhand` (zones `dock_1` .. `dock_4`;
  capacity 12; fresh = empty; `bar_title` "Dock 1"; `bar_side` from their place; `bar_column`
  true). `BAR_LAYOUT` gains the four, so `bars_save(layout = true)` writes their lines and
  `bar_lists_reset` empties them. A shelf-page or `Offhand` range is not iterated anywhere
  (checked: only `shelf_page_of` counts from `Shelf_Sculpt`).
- `Place_Bar` gains `Dock_1 .. Dock_4` (names `dock1` .. `dock4`, roots `"user dock 1"` ..,
  home edge Float with Default meaning "not placed yet", see Placement). `bar_place_shown` is
  `used && !focus` for them; `bar_place_edges` {Left, Right}.
- `Arrange_Zone` gains `Dock_1 .. Dock_4` (names "Dock 1" ..; the tag adds " · N").
  `arrange_zone_rect` is the dock's prev_rect while used, else {} (no outline).
- `Kit_State.docks: [USER_DOCKS]User_Dock`, in the layout.
- **Layout line** `user_dock <n> <density>` for each used dock, written before `bar_place`
  and `bars`; `kit_layout_put` clears all four first (used false, Icons) and a line marks one
  used. An older build passes over it, and over the `bar dock_N` and `bar_place dockN` lines
  (`bar_zone` and the place names miss), so the docks simply are not there. A line with a
  number out of 1..4 or an unknown density is dropped. No version bump: new lines only.
- Exit stats: `user_docks=` (as `1:icons:3,2:tiles:0`, or `none`), `docks_made=`,
  `docks_deleted=`.

## Placement

- A new dock's place is Float at the free area's middle less half a 52 x 120 outline, quantised
  to whole points. It never stays Default: Default for a user dock reads as Float at the
  safe area's middle (`bar_place_anchor` handles it, so a hand-written layout line with no
  place still shows).
- Edges and swaps are 3c's: `bar_place_set` swaps with the column bar on that edge (island,
  rail or another dock). A swap that would put the island or rail on Float puts it at the
  dock's old float, as 3c does.
- `kit_edge_width`, `lens_free_area`, `lens_nav_offset` (pen side's top) and the Arrange
  outlines already loop `Place_Bar` or are made to: each reads a user dock's root by
  `PLACE_BAR_ROOTS`. Floating docks keep nothing clear (the person put them there).
- The column's room is `bar_place_anchor`'s; past it the dock scrolls (`kit_scroll_begin`), as
  the rail does.

## Drawing (`src/app/user_docks.odin`, new)

- `kit_user_docks(app)` after the rail in Lens's chrome order: for each used dock with a
  slot or while arranging, `begin_anchored("user dock N", ...)` from `bar_place_anchor`, column,
  padding 3, panel background; each slot `bar_slot_button(app, which, i, s, tile = density ==
  .Tiles)`; then `bar_add_button` while arranging.
- `bar_slot_button` gains `tile := false`: a command shows through `ui.brush_tile`, which gains
  `enabled := true` and `corner := false` (defaults leave the shelf drawing as it does, so
  parity holds); a value keeps `value_item` as a chip.
- `kit_dock_menu(app)`: the popover from the tag's long press: title, the density segment,
  `Delete dock` (destructive tone). One `Dock_Menu {open, dock, at}` in `Arrange_State`.

## Tests and checks

- Unit (`user_docks_test.odin`):
  - New dock fills the first free slot, at most four, floats in the free area, picked.
  - Delete frees it, empties its list and place; New dock then reuses it fresh.
  - Layout text round-trips (`user_dock`, `bar dock_N`, `bar_place dockN`), mirrored too; bad
    lines drop; a built-in workspace has no docks; Reset workspace removes them.
  - Swap: a dock dropped on the rail's edge sends the rail to the dock's float.
- Touch (1440x900, `--script=customise_bars`):
  - Tap New dock, the dock's +, pick "Frame all" in Search, Done, tap the dock's button:
    framed; `user_docks=1:icons:1`.
  - Mouse-drag the dock's tag to the left edge: the island swaps; `bar_places` says so.
  - Long press the tag (finger), pick Tiles, Done: the dock's width is a tile's.
  - Long press, Delete dock: `user_docks=none`, `docks_deleted=1`.
  - Pen, left-handed: New dock and drag it to the screen's right edge.
  - A dock in Sculpt is not in Model (space switch) and comes back on switching back.
- Related scenarios: arrange, rail, island, shelf, workspace export/import, focus.
- `parity_check.py` against the 3c-2 merge: every case matches (no docks by default).
- README (Arrange: user docks) and sm-ui (`User_Dock`, the Bar_Which/Place_Bar/Arrange_Zone
  entries, `bar_slot_button(tile)`).

About 380 lines.

## As built, after the sm-architect review (29 Oct)
- New dock, density and Delete live in a third Library tab, Docks (after Dial, so the Dial
  tab keeps its place), not in the top bar (no room at 1024 pt) and not on a long press of the
  tag (a grip that also opens a menu needed carry cancelling and float bookkeeping for little
  gain). Search's "New dock" turns Arrange on and makes one.
- Docks' home is Float and a used dock is never left at Default (`user_docks_settle` at
  layout put); `bar_places_text`, `bar_places_save` and `bars_save` skip unused docks, and the
  settings file never holds them. `kit_layout_put` clears `k.docks` first.
- `bar_column`, `bar_side`, `bar_slot_actions` and the value menu's column read docks;
  `lens_free_area`, `kit_edge_width` (shown bars only) and `lens_nav_offset` count them.
- A new dock floats in the middle, or beside the Library (away from the off-hand) where
  the Library would cover it.
- `ui.prev_root_rect`: finding a root by name from inside a container. That also fixed
  3c-1's floating island's popover side, which always opened right.
- Focus mode and Inspect hide docks (`user_dock_shown`); Settings > Reset > Bars removes them.
