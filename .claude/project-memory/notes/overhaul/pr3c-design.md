# PR 3c: bar placement and Arrange

Part of the round 3 overhaul (design.md "Docks": "A dock sits on an edge (snapped to its
middle, as Forger's toolbox does) or floats where it was let go"; "In Arrange: ... Edges light
as drop targets while a dock is dragged"). The pr3a review moved `Bar_Dock` placement here,
with Arrange, since placement has no use until Arrange can move a bar.

Split in two so each stays under the review threshold's spirit:

- **3c (this PR): placement.** The three chrome bars (off-hand island, view rail, shelf) get a
  place: their default, an edge at a point along it, or floating. Arrange drags them by their
  tag. Reset zone puts a bar's place back.
- **3d (next): user docks.** New dock (up to four more bars of any commands and values),
  each dock's density (Icons or Tiles), Delete dock. Written as its own design after 3c.

## What exists when it is done

- While arranging, each bar's name tag (Off-hand, Shelf, Rail) is also its **grip**: a drag on
  it (a finger, the pen or the mouse, past the slop) carries the bar's outline with the
  pointer. A tap still picks the zone for Reset zone.
- While a bar is carried, the **edges it may go to light** as strips along the window's
  inside edges (accent at 35%; the one the pointer is nearest within 72 points at full accent).
  - The island and the rail are columns: Left or Right.
  - The shelf is a row: Bottom or Top.
  - The orientation never changes (a shelf as a column would need its own tile layout,
    and an island of tall sliders as a row has no use), so those are the only edges each
    offers.
- **Let go** over a lit edge: the bar goes on that edge, centred on where the pointer was
  along it, snapped to the middle within 4% of it (Forger's toolbox). Let go elsewhere: the
  bar floats with its top-left where the outline's was. Either way the layout gets its dot.
- A bar's place is part of the workspace's layout (it is the screen's, not the hand's), so
  each space and workspace keeps its own, and Reset workspace and Reset zone put it back.
- **Default** is the place each bar has today, computed as today (`brush_bar_top`, the rail's
  top under the top bar, the shelf's centre shift on a tablet and under the main pane): a
  layout that never moved a bar draws exactly as before (parity_check).
- Left-handed mirrors Left and Right and a floating bar's x, as `ui.mirrored` does; places
  are written for the right-handed layout, as windows are.

## Data

```odin
Bar_Edge :: enum u8 { Default, Left, Right, Top, Bottom, Float }

// Where a chrome bar stands: its default place, an edge at `along` (0..1, the middle 0.5),
// or floating with its top-left at `at` (points in the safe area).
Bar_Place :: struct {
	edge:  Bar_Edge,
	along: f32,
	at:    [2]f32,
}
```

- `Kit_State.places: [Place_Bar]Bar_Place` with `Place_Bar :: enum u8 {Offhand, Rail, Shelf}`.
  Not `Arrange_Zone`, which also names the dial and the panels. 3d's user docks will add to
  this.
- `bar_place_edges(b) -> bit_set[Bar_Edge]`: {Left, Right} for the columns, {Bottom, Top} for
  the shelf, plus Default and Float.
- **Layout lines:** `bar_place <offhand|rail|shelf> <edge> <along> <x> <y>`, only for a place
  that is not Default, written in `kit_layout_text` before `bars`, and read in
  `kit_layout_put`. `kit_layout_put` resets them all to Default first. An older build
  passes over the line. A name, edge or number it does not know leaves Default.
- No settings or workspace file version bump: the lines are new, and nothing else changes.

## Layout

`bar_place_anchor(app, b, size) -> (x, y: ui.Anchor, offset: [2]f32)` gives each bar's
`begin_anchored` arguments. Default returns today's arguments unchanged. Otherwise:

- Left or Right: x = Start or End at LENS_EDGE. y = Start, with the top at
  `along * (room - size.y)`, the room running from under the top bar (`TOP_BAR_H + 6`) to the
  safe area's bottom less `t.edge`.
- Bottom or Top: y = End at `t.edge + dock_lift` (Bottom) or Start at `TOP_BAR_H + 6` (Top).
  x = Start, with the left at `along * (area.w - size.x)`.
- Float: Start and Start at `at`, clamped into the safe area.
- The size is last frame's (`ui.prev_layout` of the bar's root), as `brush_bar_top` does
  today.

Keep-clear rules that read a bar's place:

- `dock_stack` (toasts, the inspector, the action bar, the rail's lift) counts the shelf only
  while it is at the bottom: Default or Bottom. Top or Float gives 0, so the action bar keeps
  its place over where the shelf was.
- `rail_lift` keeps the dial clear of the shelf only while the shelf is Default (the place
  it measures against).
- `rail_inset` keeps the dial clear of the island only while the island is Default.
- `brush_bar_top` is the island's Default and is used for nothing else.
- `lens_nav_offset` already takes the rail's `prev_rect` where it is, so it follows the rail.
- `rail_reach` and `lens_palm` are unchanged. The bars' own placement ignores the palm zone,
  since a person put them there.
- The shelf's popovers (quick settings, the brush picker's anchor) hang from its rect and
  follow it. The picker opens above a Bottom shelf and below a Top one. Its side is set from
  the edge.

## Arrange

- `Arrange_State` gains `carry: Maybe(Place_Bar)`, `carry_from` (the outline's rect at the
  press) and `carry_at` (the pointer).
- `kit_arrange_lens`: the tag's `ui.area` takes `drag = true` for Off-hand, Shelf and Rail.
  Past the slop it starts a carry (`ui.claim_drag`, so a scroll or a page swipe never takes it).
  - While carrying, the outline is drawn at `carry_from` moved by the drag. The allowed edges
    are drawn as strips, and the nearest one is lit.
  - On release, `bar_place_drop` sets the place. `workspace_touch` gives the layout its dot.
- Reset zone for Off-hand, Shelf and Rail also puts its place back to Default. Off-hand's
  Reset zone now has something to put back, so `arrange_zone_resettable` is true for it, but
  only while its place is not Default.
- Exit stats: `bar_places=` as `offhand:left:0.50,rail:default,shelf:top:0.50`, and
  `bar_carries=` (carries let go).

## Tests and checks

- `lens_arrange_test.odin`:
  - `bar_place_drop`: snapping to the middle, the nearest allowed edge, Float elsewhere, and
    an edge a bar may not take.
  - `bar_place` lines round-trip through `kit_layout_text` and `kit_layout_put`, mirrored too.
  - An unknown edge reads as Default.
- Touch scenarios (1440x900, `--script=customise_bars`):
  - Dragging the Rail tag to the left edge puts the rail on the left: `bar_places`, and the
    rail's rect after Done (a stat `rail_x=`).
  - Dragging the Shelf tag to the top puts the shelf at the top, and the action bar and the
    toasts stay at the bottom.
  - Dragging the Off-hand tag into the middle floats it.
  - Reset zone after a move puts it back.
  - A tap on a tag still picks it: `lens_arrange_reset_zone` passes as it is.
- Run the existing `lens_arrange_*`, `shelf_*` and `offhand_*` scenarios: unchanged with every
  place Default.
- `parity_check.py`: every case matches, since every place starts Default.
- README (Arrange: moving bars) and sm-ui (`Bar_Place`, `bar_place_anchor`, the keep-clear
  rules).

About 320 lines.

## Review corrections (sm-architect, 29 Oct) and the new split

The review found the keep-clear rules far wider than this design assumed. Everything at
the bottom reads the shelf's rect directly, centred maths included: `kit_action_bar`,
`lens_free_area`, the shape bar, History, `side_panel_below`, `column_place`, `rail_lift`
and the hidden-dock ghost. `kit_left` and `kit_right` reserve the island's and the rail's
widths whatever their place, and the "dock pages" root is separate. Placement therefore
splits in two, columns first:

### 3c-1: the island and the rail (column bars)
- `Bar_Place {edge, along, at}`, with `Bar_Edge.Default = 0` so `new(Kit_State)` built-ins stay
  canonical. Places are kept in layout terms, relative to the start side, so `ui.mirrored`
  flips them. They are written unmirrored, and `kit_mirror` leaves them alone. A drop
  converts screen terms to layout terms under the mirror.
- Edges are Left or Right at `along`, or Float.
  - One column bar per edge: a drop on the edge the other bar holds swaps the two.
  - A drop at a bar's own default spot (its default edge, `along` within 4% of its default)
    stores Default.
  - The palm zone is respected: a place is clamped out of `lens_palm`'s band on the pen side.
- `kit_left` and `kit_right` measure each side from the bars actually standing there (last
  frame's rects), not from which bar it is. With both Default, today's maths is unchanged.
  The callers then follow on their own: the action bar's room, cards, columns, History and
  the mini view.
- Popovers open away from the edge a bar stands on: `bar_side`, `bar_menu_toggle`, the pass
  menu and the value items.
- The rail's scroll room and the island's slider folding are computed from the bar's own top
  and room. The view chips step aside when a column bar stands at the top of their side.
- `lens_nav_offset` takes either bar at the pen side's top. `lens_free_area` counts only
  edge bars as side columns, not floating ones.
- Hidden ghosts are drawn at the place.
- Lines and stats:
  - `bar_place offhand|rail <edge> <along> <x> <y>`, read with `window_number` (NaN, inf
    and a disallowed edge read as Default), written with `%g`. On a drop, `along` is
    quantised to 0.01 and `at` to whole points.
  - No `workspace_touch`: the dot follows from the layout text.
  - Stats: `bar_places=` and `bar_carries=`. `layout_brush_bar=` and `layout_view_bar=`
    already give the rects.
- Arrange:
  - The tag's `ui.area(drag=true)` is tested by hand for the slop against `press_mouse`.
  - `ui.press_used` runs when a carry starts, so a release is no tap.
  - The Library fades and takes no presses while carrying.
  - The top strip stays under the top bar.
  - Reset zone covers a moved island (`arrange_zone_resettable(k, z)`, and `resets` is
    counted).
- Why the bars' place is the layout's while the dial's is a setting: the dial is the hand's
  and moves with it in every layout, as design.md says; the bars are the screen's.
- Tests:
  - mirrored drops, bad lines, built-ins canonical, `workspace_layout_clean` keeps the line,
    a default-spot drop is Default, the swap;
  - touch: finger, pen and mouse drags, left-handed, portrait 800x1280, rail Left with its
    popovers to the right and the left column clear, a workspace switch and export/import
    keep it, a shrinking window clamps a floating island;
  - parity, and the `layout_*` stats across the window-size scenarios.

### 3c-2: the shelf
- Bottom at `along`, or Top, or Float. One helper, `shelf_bottom_reach(app)`, gives every
  bottom reader the shelf's reach, or 0 when it is not at the bottom. Today's centred maths is
  kept for Default.
- Off-centre and Top places use the rect's overlap.
- The centre comes from the place before `shelf_fit`, and "dock pages" follows the shelf.
- A Top shelf opens its tiles' popovers, quick settings and the picker below it. `kit_top()`
  readers (columns, cards, chips, the rail's top, the nav head) keep clear of it through a
  `shelf_top_reach`.
- Tests as 3c-1's, plus: the action bar, toasts, picker and quick settings under a Top shelf,
  and a Bottom shelf off-centre against the dial in portrait.

3d (user docks) follows, using the same `Bar_Place` (the name design.md's `Placement` is
taken here as `Bar_Place`, with `bar_place_*` procs).

### 3c-2 as built (29 Oct)
- The Top edge was dropped: the top band holds the top bar, the view chips, the navigation head
  and the panels' tops, so a Top shelf would push all of them. The shelf goes Bottom at `along`
  (between the dial and the other side, `shelf_across`), Default near the middle, or Float with
  its top no higher than 40% down (`SHELF_FLOAT_TOP`), so what it opens still opens above it
  (`bar_place_side` is Above_Center for the shelf whatever its place).
- Bottom readers go through `shelf_bottom_size` and `shelf_bottom_span` (layout terms; the
  centred maths at Default, last frame's mirrored rect otherwise, nothing while floating):
  `dock_stack`, `action_bar_room`, `kit_action_bar`, `side_panel_below`, `column_place`,
  `rail_lift`, `lens_free_area`, the shape bar and History.
- "dock pages" follows the shelf: under its middle, or under a floating shelf.
- The hidden-dock ghost is drawn at the place; the ghost's old double mirror was removed.
