# PR 5a: palette groups (static) and the Palettes dock's density

Round 3's "Palette groups" and "Docks: density Icons, Tiles or Panels" (design.md §2.4, §6
revised order 5a), built on what exists rather than the one-type rewrite §2.4 sketched:
the stack (lens_stack.odin) is already the pen side's dock of palettes in Panels density,
and the pane strip (lens_panes.odin `kit_stack_strip`, `kit_stack_tab`) is already its
Icons density, shown today only while panes stand beside the main view. PR 4's
`Panel_Kind`/`panel_body` draws any card's content. 5b adds drag and drop (hold ring,
targets, left and right). Pinned sections and the second column stay as they are until PR
9 (tray and stack removal), which is where the tray's own list goes; folding pins in now
would move ~40 touch scenarios twice.

## What exists when it is done

- **Groups.** A card can join the card above it as a tab: the two (or more) are one group,
  one card in the stack with a row of tabs under its header, each tab the card's icon and
  title; a tap on a tab shows that card's content. The group folds, floats, moves, is left
  out and resizes as one card does today (the first card, the host, carries those). A group
  of one draws exactly as a card does today (parity).
  - Panel options of a card gain **Join the card above** (enabled when a card stands above it
    in the stack) and, on a tab, **Take out of the group** (it becomes its own card right
    after its group). The menu's Move up/Move down move the whole group.
  - Search and Show where find a card's controls in its group: `stack_reveal` opens the
    group and makes that card its shown tab.
- **The Palettes dock's density** (per layout): **Panels**, as today, or **Icons**: the stack
  is the strip of icons beside the rail whatever the panes, one icon per group (a count badge
  on a group of two or more), and a tap opens that group over the view beside the strip
  (today's `kit_stack_tab`, now with the group's tabs), another tap or Escape closes it.
  - Set from the stack's Panel options (**Show as icons** / **Show as panels**), the Library's
    Panels tab (a "Palettes" Panels/Icons row), and the command `Stack_Density` (Search
    "palettes as icons", a checked command that bars and keys can hold).
  - With panes beside the main view the strip shows whatever the density, as today.
- Layout lines (no version bump; an older build passes over them):
  - `stack_join <card> ...`: the cards that are tabs of the card before them;
  - `stack_tab <host>=<card> ...`: the tab each group shows, only where it is not the host;
  - `stack_density icons`, only when Icons.
- Exit stats: `stack=` writes a joined card with `&` before its name (`Brush+,&Symmetry,...`;
  unchanged while nothing is joined), and new `stack_density= stack_joins=`.
- Defaults are unchanged: every built-in layout has groups of one and Panels density.

## Data

```odin
Lens_Stack :: struct {
	...
	joined:  bit_set[Stack_Card], // a tab of the nearest card before it in `order` that is not joined
	shown:   [Stack_Card]Stack_Card, // a host's shown tab (itself when unset)
	density: Stack_Density, // .Panels or .Icons; layout
	joins:   int, // for the exit stats
}
Stack_Density :: enum u8 { Panels, Icons }
```

- `stack_host(s, c) -> Stack_Card`: c, or the nearest earlier non-joined card in `order`.
  The first card in `order` can never be joined (`stack_layout_read` and Join refuse it).
- `stack_group(s, host, out) -> []Stack_Card`: the host then its joined cards, in order,
  skipping hidden ones.
- Every per-card state that belongs to the card in the stack (open, floated, hidden, window,
  height, size, scroll, rect, body) is read and written on the host. `stack_card`,
  `stack_float_card`, `stack_head`, the strip and the tab panel iterate hosts only.
- `panel_body(app, s.shown[host], inner)` draws the shown tab; scrolls and heights stay the
  host's (one scroll per group).
- Moving (`stack_move_to`, the carry, Move up/down) moves the group's run as a block, so a
  group never splits by a move. Leaving a host out leaves the group out. Floating a host
  floats the group; a joined card cannot float on its own (its Float floats its group).
- `stack_default` clears joined, shown and density.

## Header

- A group of one: today's header.
- Two or more: today's header for the group (the host's grip, chevron, the shown tab's icon
  and title, summary, Float, options), then, while open, a row of tabs (`ui.tabs` with
  icons, or `ui.toggle_button`s sized to fit, scrolling sideways when they do not), each a
  touch target tall. A folded group's summary is the shown tab's.
- Symmetry's axis chips stay on its header while Symmetry is the shown tab.

## Tests and checks

- Unit (`lens_stack_test.odin` or a new `stack_groups_test.odin`):
  - join and take out: host and group membership, the first card refused, a joined card's
    Move moves the group, leaving out and floating a host carries its tabs;
  - layout lines round-trip (`stack_join`, `stack_tab`, `stack_density`) and bad words are
    passed over; a fresh layout writes none; `stack_reveal` on a joined card opens its group
    on that tab;
  - `stack_text` unchanged with no joins.
- Touch (1440x900):
  - Panel options > Join the card above on Symmetry: Brush's group shows two tabs; a tap on
    the Symmetry tab shows the axes; `stack=Brush+,&Symmetry,...`.
  - Take out of the group puts it back after Brush.
  - Show as icons: the strip shows (no panes), a tap on the Brush icon opens the group beside
    it; Escape closes it; `stack_density=icons`; a workspace switch keeps each layout's own.
  - Left-handed with icons; a finger and the pen.
  - The existing `lens_stack_*`, `lens_pane*`, show-where, Search and columns scenarios
    unchanged.
- `parity_check.py` against the PR 4 merge: every case matches.
- README (Panels: groups and density) and sm-ui.

About 350 lines.

## As built: 5a-1 (Palettes as icons)

- `Lens_Stack.density` (`Stack_Density {Panels, Icons}`) and `strip_at`; `stack_strip_shown` is true with panes or
  Icons. `stack_density_set` closes the open tab; `stack_reveal` opens the strip's card at `strip_at` (Show where).
- Set from the stack's More (Show as icons / Show as panels), Arrange's Library Panels tab ("Palettes show" row) and
  the command `Stack_Density` (Skip in macro_kind, with `New_Dock`, which 3d had missed).
- Layout line `stack_density icons`; stat `stack_density=`. Tests `stack_density_reads_back`,
  `stack_icons_open_the_card_asked_for`; scenarios `stack_as_icons_opens_a_palette`,
  `stack_icons_show_where_opens_the_card`. Groups (5a-2) next.

## As built: 5a-2 (groups)

- `stack_groups.odin`: `stack_host`, `stack_group`, `stack_shown`, `stack_join_target`, `stack_join`,
  `stack_take_out` (the host out hands open/float/window/sizes to the next tab), `stack_show_tab`, `stack_tab_row`
  (`ui.tabs` with glyphs, icons only when the titles do not fit), the `stack_group` line (panel kind names, `*` on the
  shown tab), read after the whole layout. Stats `stack_joins= stack_shown=`, `&` in `stack=`.
- Menu items Join the card above (ICON_MERGE) and Take out of the group (ICON_SPLIT, the shown tab); Leave out hides
  the whole group; strip icons carry a count badge. Groups hold cards only; sections come with PR 9.
- Tests in `stack_groups_test.odin`; scenarios `stack_join_makes_a_group_of_tabs`, `stack_take_out_of_a_group`,
  `stack_group_as_icons_opens_on_its_tab`, `stack_join_left_handed_by_pen`. sm-ui is at 479 of 500 lines: split it
  before it grows much more.
