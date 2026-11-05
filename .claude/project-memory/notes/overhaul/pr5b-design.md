# PR 5b: dragging palettes into groups (drop targets, hold ring, Ungroup, left and right)

Round 3 design.md §2.4 "Drag and drop" and §7's addition (Bolt, 29 Oct 11:30: targets tab,
above, below, left and right on docked and floating groups alike; left or right widens the
group into two columns with a divider, growing away from its edge; no room falls back to
below and the hint says so). Built on 5a's groups as they exist (stack_groups.odin: a group
is a run in `s.order`, the host carries the card state, `s.joined`, `s.shown`), not the
`Palette_Group` struct §2.4 sketched; PR 9 (tray and stack removal) is where the stack's
types are replaced. Split in two PRs, each about 400 lines:

- **5b-1** drop targets (tab, above, below, float), a tab dragged out of its row, the strip's
  hold ring, Ungroup.
- **5b-2** left and right: two-column groups, the divider, the no-room fallback.

## 5b-1: what exists when it is done

- **What a drag carries** (`Stack_Carry` in Lens_Stack, replacing `carry: Maybe(Stack_Card)`):
  `{card, tab: bool, from: [2]f32}`, a whole group (its host's) or one tab. It starts:
  - from a docked card's grip past the slop (today), carrying the group;
  - from a tab in a group's tab row dragged past the slop, carrying that tab alone (the tab row
    becomes the app's own row of `ui.area`s, drawn like `ui.tabs`, so a press can be a tap or
    a drag; a tap shows the tab as now);
  - from a strip icon (Icons density, or panes) held for `theme.long_press` then moved, carrying
    the group; a tap still opens it, and the ring shows while held.
  - Floating groups: a tab dragged out of a floating group's row carries it the same way; the
    floating card's dots keep moving the window, so no new source there.
- **Targets**, hit-tested against last frame's rects (`s.rects`, the new `s.head_at[c]` for each
  host's header plus tab row, `s.tab_rects` for tabs, `s.strip_at`), first match wins:
  1. **Tab**: over another group's header or tab row, docked or floating: the carried card(s)
     join that group as tabs at the slot under the pointer (between tabs by x; after the last
     over the header). A ghost slot (accent outline, the carried card's icon) shows in the row.
  2. **Strip icon**: over another icon the icon scales to 1.08 and a ring (`ui.hold_ring`, the
     long press ring's drawing made public with a centre, radius and fraction) fills round it
     over `theme.long_press`; let go after it fills: join that group as its last tab; before:
     reorder the strip (the stack's order) at that slot, with the line between icons.
  3. **Above or below**: over a docked card's body or the gap between cards: the insertion line
     (today) and the carried card moves there: a tab becomes a card of its own at that place.
  4. **Clear of everything**: floats at the pointer (today); a tab becomes a floating card of its
     own.
  - A hint pill beside the pointer says what letting go does: "Join Brush", "Move here",
    "Float here", "Hold to join Brush". Escape (the input's cancel) drops nothing.
  - Dropping a group or tab on its own place does nothing (no move counted).
- **Ungroup** in a group's Panel options: every tab becomes a card of its own, in the group's
  order, right where the group was; the host keeps its fold and float, the others are folded.
- Procs (stack_groups.odin): `stack_join_at(k, carried, tab, host, slot)` (general join: a tab
  is taken out first without opening; a group's whole run joins; refuses joining into itself),
  `stack_ungroup(k, host)`, `stack_carry_target(app, p) -> Stack_Target {kind, host, slot,
  at}`, `stack_carry_update` grows the cases above, `stack_tab_row` returns the tab pressed for
  a drag.
- Left-handed: nothing is mirrored by hand: the hit tests use laid-out rects, the hint pill
  sits on the pointer's view side (`ui.mirrored`).
- Exit stats: `stack_drops=` (drops that changed the stack), `stack_carry=none|<card>[:tab]`,
  `stack_target=none|tab|icon|line|float` (while a drag is held, for scenarios that stop
  mid-drag).

### Tests and checks (5b-1)

- Unit: `stack_join_at` (a tab into another group at a slot, a group into a group, into
  itself refused, a floating target); `stack_ungroup`; the target picker against made-up rects
  (tab slot by x, line, float, icon) with `s.order` and rects set by hand.
- Touch (1440x900): Symmetry's grip dragged onto Brush's header joins it (`stack=Brush+,&
  Symmetry,...`); a tab dragged out of the row to below Layers becomes a card there; a tab
  dragged clear floats; the strip (icons): Layers' icon held then moved over Brush's, held till
  the ring fills, let go joins, and let go early reorders; Ungroup; a pen run left-handed;
  existing `lens_stack_*` carries unchanged.
- parity: every case matches.

## 5b-2: left and right

- **Columns**: `beside: bit_set[Stack_Card]` in Lens_Stack, a tab that begins its group's
  second column (at most two: GROUP_COLUMNS 2). Column one is the host up to the beside card,
  column two the beside card and the tabs after it. Each column has its own tab row and shown
  tab (`s.shown[host]`, `s.shown[beside card]`) and scroll; the group folds, moves, floats and
  is left out as one.
- **Targets**: the left and right thirds of a group's header or body (docked or floating),
  at least 48 points each, are "beside": the carried card(s) become column two (or join column
  two's tabs when there is one already: then it is a Tab target on that column).
  - The preview fills the part the new column would take, beside the group, on the side away
    from the edge it is docked on (a right-docked stack grows left; floating, toward the
    pointer's side).
  - **No room**: when the column would not fit inside the safe area with 360 points of view
    left, the target is Below instead and the hint says "No room beside: goes below".
- **Drawing**: a docked two-column group draws column one in the stack as a card and column two
  as its own root (`ui.begin_at`) against column one's view side, the same top, as tall as its
  content (or its own height grip); a floating group is one window two columns wide.
  - The divider between the columns (docked: column two's inner edge; floating: between them)
    drags column two's width (`s.beside_w[host]`, 260 to 440, snapped to 8, double tap resets),
    like the stack's edge.
- **Layout**: the `stack_group` line gains `|` before the card beginning column two:
  `stack_group card:Brush card:Symmetry | *card:Layers` (5a-2's reader passes over `|`, so an
  older build reads a group of three); `stack_size` gains `beside=<host>:<w>`. Exit stats:
  `stack=` writes `|` before a beside card.
- A whole user dock dropped beside another is Arrange's (3c places them along an edge); out of
  scope here.

### Tests and checks (5b-2)

- Unit: beside join and take out (taking out column two's last card ends the column), the
  line round trip with `|`, the no-room test against a narrow safe area, widths read back.
- Touch: Symmetry dropped on Brush's left third makes two columns (`stack=Brush+,|Symmetry`);
  the divider drag sets the width; a narrow window (800 wide) falls back to below with the hint;
  left-handed (the column grows right); a floating group's right third.
- parity.

## Architect review (29 Oct, 21:00) and the decisions taken

Split confirmed; 5b-1 splits again: **5b-1a** Stack_Carry, `stack_join_at`, the target picker,
tab drags, Ungroup; **5b-1b** the strip as a source, the dwell ring, `ui.hold_ring`; then 5b-2.
Required changes, all taken:
1. Escape is a key (`key_pressed(d, sdl.K_ESCAPE)`), not `input.cancel`; a carry eats it.
2. `stack_carry_update` runs once a frame after the floats and menus (new_ui.odin), drawn as
   its own root, so it resolves in strip mode and draws over floating groups.
3. `rects`, `head_at`, `tab_rects` are cleared each frame before the stack draws; docked rects
   are clipped to the panel's visible area.
4. Targets are tested in z order: floating groups front to back (`k.order`), docked, strip.
5. A header is a band map: top and bottom quarters (at least 10 points) give the line, the
   middle joins (5b-2 adds left and right thirds to the same map).
6. Join slots clamp to at least 1, so a join never changes a host; reordering tabs inside
   their own group is not in 5b (a drop on its own group is nothing).
7. Tabs as drag sources through a generic `drags` option on `ui.tabs`, by the `thumb_row`
   rule (mouse at once; finger and pen hold first; a tap only within the slop), so the column
   still scrolls by finger and the pen's roll stays.
8. The ghost slot is an overlay, never space in the row.
9. 5b-2 draws a two-column group as a Row of two Columns in its card and widens the panel to
   `stack_width + beside_w` (no separate root).
10. 5b-2 keeps column two's height (`beside_h[host]`) and makes `stack_shown`/`stack_show_tab`
    column-aware.
Also taken: close the strip's card when a carry starts; dwell twice `long_press` and restart past
the slop; `stack_take_out(open := true)`; a `stack_valid` invariant test after every operation.

## As built: 5b-1a

- `stack_carry.odin`: Stack_Carry/Stack_Target, `stack_frame_begin` (clears `seen`, `drop_at`, `head_at`, `row_at`,
  `tabs_at`; `rects` stays for the grips), `stack_carry_update` after the floats, the target picker (floats front to
  back, band map, own place is None), the drop, the marks and pill; `carry_off` holds an Escaped carry down until the
  press ends (the held grip would restart it).
- `stack_join_at` (slot clamped to 1, tab taken out first), `stack_ungroup`, `stack_take_out(open)`; `ui.tabs(dragged)`
  and `ui.clipped`. Stats `stack_drops= stack_carry= stack_target=`.
- Tests: `stack_carry_test.odin` (with `stack_valid`), ui `tabs_drag_by_the_thumb_row_rule`; scenarios
  `stack_grip_drag_joins_a_header` (finger, mouse), `stack_tab_carried_onto_a_card_joins_it`,
  `stack_tab_carried_clear_floats`, `stack_carry_escape_drops_nothing`, `stack_tab_row_swipe_carries_nothing`,
  `stack_ungroup_gives_the_tabs_back`, `stack_tab_carried_left_handed_by_pen`, `stack_carry_shows_where_it_goes`.

## As built: 5b-1b

- Strip icons are sources (`ui.held_long` each frame; mouse at once; a carrying press is no tap), `s.strip_seen`
  cleared each frame; `stack_strip_target` before the docked targets: near the strip the line between icons
  (`target.strip`), resting on another icon `stack_dwell >= 1` (twice `long_press`, restarted past the slop) joins.
- `ui.hold_ring(ctx, center, radius, fraction)` (the long press ring's drawing, now shared); the target icon outlined
  at 1.08 with the ring, pill "Hold to join X".
- Tests `stack_strip_targets_reorder_then_join`; scenarios `stack_icon_rested_on_another_joins_it` (finger, mouse),
  `stack_icon_let_go_early_reorders`, `stack_icon_carried_with_panes`, `stack_icon_carried_clear_floats`,
  `stack_icon_resting_fills_the_ring`. Next 5b-2.

## As built: 5b-2

- Departure from the design: the beside target is the 96-point band just beyond a group's side over the view (a
  docked group's view side only), not the card's outer thirds, because a grip drag that reorders runs down the card's
  own left third and would have become a column drop.
- `s.beside`, `s.beside_w`, `s.beside_left`; `stack_column`, `stack_column_head`, `stack_shown` per column head,
  `stack_beside_join`, `stack_columns_tabs`/`stack_columns_bodies` (one scroll for both columns, shared height, the
  divider `Stack_Drag_Kind.Beside`); `stack_docked_extra` widens the panel (`panel_width`, `tray_width`, the stack's
  own `stack_edge` keeps `before = stack_width`); other cards right-aligned with a spacer by `stack_docked_right`
  (layout side xor mirror). No room: 440 points of view left, else below (docked) or a tab (floating).
- Lines: `|` in `stack_group`, `*` per column, `stack_beside Brush=280`. Stats `stack_columns= tray_width=`.
- Tests: `stack_beside_makes_a_second_column`, `stack_columns_read_back`, `stack_beside_target_needs_room`
  (stack_valid checks one column two per group); scenarios `stack_grip_dropped_beside_makes_two_columns`,
  `stack_column_divider_sets_the_width`, `stack_beside_without_room_goes_below` (1100x900),
  `stack_beside_left_handed_grows_right`.
