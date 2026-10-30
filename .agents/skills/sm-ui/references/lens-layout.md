# The Lens layout in detail (sm-ui)

The chrome round the view, bar by bar, as `kit_layout` lays it out: what each container is called, what keeps clear
of what, Arrange, the docks, the palette groups and the dial. Read it before changing any chrome; SKILL.md keeps the
summary.

- Layout: one, Lens (the Sculpt Workspace Directions mock; spec `notes/lens/mock-layout-design.md`). The Classic
  layout (ZBrush-iPad bars, the dock, `--chrome`) is gone; never add a second chrome: `settings_load` passes over old
  `chrome`, `panes_under_panels`, `dock*` and `right_rail` lines. `kit_layout` (`new_ui.odin`) lays out in order: the
  chip bar `kit_top_bar` (`kit_top_lens.odin`, root "top bar", floating `TOP_BAR_INSET` in and `TOP_BAR_TOP` down;
  `TOP_BAR_H` stays the room it takes): Menu, file block (`file_status`, fixed width so Undo/Redo never move) | Undo,
  Redo | space tabs `top_space_tabs` | the object chip `top_object_chip` (`object_chip.odin`, shrunk by
  `object_chip_fit`; its tap opens `kit_object_menu`, `object_menu.odin`: rows from `OBJECT_VERBS[Object_Type][Space]`,
  each a registry command, another space's first enabled verb tagged with `menu_item(tag =, tag_color = t.tints[space])`
  and run after `Space_Switch`; a new verb is a table row, never a menu branch; on the view `view_menu_open` serves the right
  click (`pie_update`), the `Object_Menu` command and the finger's `hold_menu_check` in `pointer_route`; `space_fit` (`offers.odin`)
  rings it amber and `kit_offer_line` takes the action bar's place; a dimmed command passes `command_reason` as `reason`;
  `kit_colour_island` sits under both while painting, lifting them by `colour_island_lift`) | Search field | History, Settings, all laid inline with spacers (a `begin_at` inside the bar
  loses hits to it); its width budget counts the row's gaps (`things`, 14 with every section in). Each section is `chip_section_draw` (`Chip_Section`); one taken out stands as an island (`chip_islands.odin`, `k.islands`: a setting, not the layout's, since the bar holds the space tabs), and Arrange outlines every drawn section with an overlay `ui.area` in `arrange_chip_sections` whose drag carries it (dropped over `prev_root_rect("top bar")` it goes back; inside another root use `prev_root_rect`, as `prev_rect` hashes under the current id); `lens_focus(k)` (the View_Bar zone hidden) turns it into `kit_top_islands`, with no view chips and
  a compact shelf. Then `kit_view_chips` ("points", skipped while a pane is maximised: `view_chips=`), `kit_offhand` (the island, "brush bar": Size and Strength
  `ui.vslider`s, long press = Pen section, the pen's roll sets them via `island_roll`), `kit_nav_head`, `kit_view_rail`
  ("view bar", `Bar_Which.View_Rail`), the shelf `kit_shelf` (`lens_shelf.odin`, "dock", pages row "dock pages"),
  the action bar, the picker `kit_brush_sheet` (`k.browser` at `.Dock`; at `.Bar`, with the shelf hidden, the
  browser `kit_brush_browser`), Search, the menu `kit_menu_lens`. The containers keep the old bars' names so
  `kit_left`/`kit_right`/`kit_card_place`/`side_panel_below`/`dock_stack`/`lens_free_area` and Arrange's zone tags
  (`ui.prev_rect` of "brush bar", "dock", "view bar") keep working: renaming one moves them all. Measure the shelf with
  `dock_stack` (it sits `DOCK_LIFT` above the edge margin). `Zone` (`.Brush_Bar`, `.View_Bar`, `.Dock`, `.Wheel`,
  `.Action_Bar`) keeps its layout-text names; `ZONE_NAMES` are what people read.
  Lens view (`lens_view.odin`): `camera.Orbit.shift` (half-heights, applied in `orbit_proj`) draws the target in
  `lens_free_area`; `view_fit_free` from Frame/Focus/Reset; zeroed outside Single and in `second_orbit`. touch_check's
  `MIDDLE` is where the sphere's middle lands at 1600x900 (the gizmo's points follow it). Panels fade under a viewport
  stroke (`panel_fade` in `panel_begin`/`panel_end`). Clean view `k.clean` returns early from `kit_layout`; Tab is
  bound to it and B to the brush picker in `DEFAULT_BINDINGS`.
  Places (`bar_place.odin`): the island, the rail and the shelf stand where `Kit_State.places[Place_Bar]` says (`Bar_Place`:
  Default, Left/Right at `along` for the columns, Bottom at `along` for the shelf (`bar_place_edges`), Float at `at`, layout terms, a `bar_place` layout line). Default must draw as before
  (parity); anything that keeps clear of a side bar asks `kit_left`/`kit_right` (they measure the bars on each edge) and
  a popover's side `bar_side(app, which)`, never "the island is left, the rail right". Arrange's tags carry them
  (`arrange_carry_follow`, `bar_place_drop`, `bar_place_set` swaps two bars on one edge). Whatever keeps clear of the
  shelf at the bottom asks `shelf_bottom_size`/`shelf_bottom_span` (nothing while it floats), never "centred, last frame's size".
  User docks (`user_docks.odin`): `Kit_State.docks[i]` is `Bar_Which.Dock_1 + i`'s list, `Place_Bar.Dock_1 + i`'s place and
  `Arrange_Zone.Dock_1 + i`'s tag; they are layout-only (`bars_save` skips them in settings and while unused), home Float,
  never left at Default (`user_docks_settle`). Ask `user_dock_shown`, and from inside a container find a root with
  `ui.prev_root_rect` (plain `prev_rect` looks for a child of the current container).
  Bars (`bars.odin`): `Bar_Which` is Tools (the shelf's strip after All), View_Rail, the six `Shelf_*` pages (each space's from `shelf_pages_of`; no tool strip on Model's or Render's),
  Brush_Pie and Offhand (the island, last so zone names and `shelf_page_of` keep their meaning), each a `Bar_List` of `Bar_Slot` drawn by `bar_slot_button`, whose `bar_slot_run`/`bar_slot_more`/
  `bar_lit`/`bar_icon` keep each command's own tap, long press and lit state wherever it sits; `BAR_LAYOUT` (Tools,
  View_Rail) go in workspace layouts, the pages, the pie and the island only in settings. Brush values
  (`brush_values.odin`) are `Brush_Value` slots (one argument per value); their look is the bar's
  (`Bar_List.looks`, kept parallel by insert, remove and move; `bar_look` turns a Slider off the island into a
  Chip), and `value_item` draws every look, a Chip claiming the drag only across its bar (`claim_drag`). Customise bars (`k.bars_edit`) is
  Arrange (`lens_arrange.odin`): a tap on a ringed slot opens `kit_bar_slot_menu` with `bar_slot_actions`, Search
  chooses a command through `Palette_For`'s `Bar_Pick` (`bar_choose`, `bar_put`); the Library's Panels tab is
  `arrange_show_chips` + `arrange_panel_rows` (the stack Hidden/Left/Right/Float, other windows Hidden/Shown), and
  `kit_arrange_ghosts` outlines a hidden shelf, wheel or action bar. A bar button opens the one `Bar_Pop` (`bar_pop_toggle`): a tray section by
  `Kit_Section` (any palette's, `bar_section`), the symmetry axes, the polyframe parts, the Remesh quick menu, Shading,
  Camera or View layout. `corner = true` on `icon_button` draws the triangle that says a long press does more.
  An overlay on a panel's own area takes no hits from a `begin_at` root (the mini view's chip is part of the picture's
  press). Thumbnail = `kit_mini_view`; `lens_mini_reach` shortens the docked stack above it. The shelf's pages are
  drag_scroll, so `ui.swipe_update` on it turns pages (`shelf_turn`); `shelf_fit` decides how many tiles and tools
  show; ask a child's `prev_rect` inside its parent. `k.order` is `Float_Ref` (windows and floated
  `Panel_Kind`s): `float_raise` on a press; the dial (`kit_modifier_rail`) is laid out after the floats, before menus
  and popovers, so it is the top lasting root. `ui.row_room` right-aligns in a fixed-width row (spacer(0) does
  nothing). The tray is the stack (`lens_stack.odin`, `kit_inspector`, `panel_begin(bare)`): cards in `k.stack`,
  layout line `stack`; `tray_open` calls `stack_reveal` (`exact` for Show where), which brings a left-out section's
  palette in as `s.visit` (`stack_visit`; `stack_keep` keeps a section for good, Pin to the stack, `stack_kept` asks; the layout never writes the visit; markers ask
  `palette_on_screen`; `s.revealed` is the section opened last); the tray and its Palettes card are gone (PR 9c),
  and `stack_layout_upgrade` rewrites a saved layout that still names Palettes; `k.in_stack` lets a section drop what the Brush card shows above it. What a panel holds is a `Panel_Kind`
  (`panel_kind.odin`: one enum, the cards then a palette per tray section, `panel_of_section`/`panel_section` between
  it and `Kit_Section`; sections start in `STACK_HIDDEN_DEFAULT`, and stack lines write one only while shown, as
  `panel_word`'s `section:Mask`); its content is `panel_body`, which the stack and the pane strip's tab
  both call, and its title, icon, folded line and layout name (`card:Brush`, `section:Stroke`) come from
  the `panel_kind_*` procs. The brush pie is
  `Bar_Which.Brush_Pie` (`k.brush_pie`, eight slots); `pie_slot` reads it, `lens_pie_update` adds tap-to-pick and
  the rest that opens `pie_quick`. Stack sizes live in `lens_resize.odin` (`stack_width`, which `tray_width` returns,
  `heights`, `sizes`, layout line `stack_size`); its handles are `ui.begin_at` roots drawn after what they resize.
  Split views chrome is `lens_panes.odin`: `lens_pane_head` (chips, `k.pane_menu` lists), `grid_divider_lens`
  (grip, `handle_double_tap` evens, edge close via `grid_close_target`, the main pane never closes), `grid_choose`
  (the View grid command; `k.new_panes`), and the stack's tab strip while `stack_strip_shown` (panes beside the main view, or the layout's
  `k.stack.density == .Icons`; `kit_stack_tab` draws a card over the view through `stack_card_body`, and
  `stack_reveal` opens the strip's card at `s.strip_at`). Palette groups (`stack_groups.odin`) are runs in
  `s.order`: a host then the cards in `s.joined`; the host carries open, floated, hidden, window, height, size and
  scroll, `s.shown[host]` (read through `stack_shown`) the tab drawn. Iterate hosts only (skip `s.joined`), move runs
  (`stack_move_to_k`), and read `stack_group` lines after the whole layout (`kit_layout_put`). Carrying is
  `stack_carry.odin`: sources set `s.carry` (the grip; `ui.tabs(dragged = &i)`), `stack_carry_update` runs once after
  the floats (new_ui.odin) and targets only this frame's `s.seen` and `s.strip_seen` rects, cleared by `stack_frame_begin`; a strip icon
  joins after `stack_dwell` reaches 1 (twice `long_press`, drawn with `ui.hold_ring`). Columns: `s.beside` (the
  tab beginning column two), `stack_column`/`stack_column_head`, `stack_shown` per column head; the panel's width is
  `stack_width + stack_docked_extra` everywhere (`tray_width`, `panel_width`), never `stack_width` alone; `view_grid_room` is the whole window, panes always under the panels.
  The grid is a split tree (`Grid_Tree`, at most four leaves; pane 0 the main view, panes keep their numbers and the
  last fills a closed one's): change it only through the tree ops in grid.odin. Gestures (`lens_areas.odin`) queue a
  `Grid_Op` that `kit_grid` applies before layout; each op is a `Grid_Step` that `undo_run`/`redo_run` order against
  the History by `at` ticks. Pictures follow moved views in `grid_pictures_follow`.
  The menu is `kit_menu_lens` (`lens_menu.odin`; `LENS_MENU_PLACE` says where each command is, keep it in step with
  the rows, and touch_check's `MENU_ROWS`); search's rows, groups and Put on a bar are `lens_search.odin`
  (`palette_where`). The stack's Scene, Layers and Tools cards are `kit_lens_scene`, `kit_lens_layers` and
  `kit_lens_tools` (the full sections are cards of their own; a Tools tile is a registry command); the action
  bar's lists come from `action_list`; a lock (`Object.locked`) goes through `object_pickable`, never a raycast of its
  own. The look's cards (Lights, Material, Environment: `lens_studio.odin`) start in `stack.hidden`; every stack loop
  skips hidden cards. `built_in_layout(b)` gives each built-in workspace's layout.
  Settings rows live in `settings_block` (`settings_blocks.odin`), one case per heading; the sheet's sections
  (`lens_settings.odin`) and the narrow window's tabs (`kit_settings.odin`, under 840 points) are lists of
  `Settings_Entry`. A new setting goes in a block, its default in `settings_block_reset`, and its search words in
  `SETTINGS_BLOCK_WORDS`. Home is `lens_home_body` from `LENS_HOME_WIDE`, else kit_home's narrow page.
  The Export sheet (`lens_export.odin`) only gathers: a new way out is an `Export_Format` whose `export_command` is an
  existing command, and a mesh format a filter of `file_dialog_export`, never a writer of its own.
  New scene's argument indexes `NEW_SCENES` (Mesh, Voxels or Empty starts): append, never reorder, since keys, bars
  and scripts name a start by its number or `new_start_key`; the narrow Home page shows the first `NARROW_HOME_STARTS`.
  The dial's sectors are each space's, `Kit_State.dials[Space]` (`Dial_Sector`, a Modifier or a Bar_Slot; defaults
  `DIAL_DEFAULTS`): read the current one through `dial_of(k)`, pass it to `rail_hit`, never index a fixed table; only
  a Modifier sector claims a finger. A space switch drops latches the new dial lacks (`dial_latches_keep`); settings
  write Sculpt's as `dial_sector` and the others' as `dial_space` lines (v6; `dials_from_one` moves an older file).
  The History panel (`kit_history_panel`, `timeline.odin`) shows `Timeline.view`: List (`history_list.odin`, a
  setting `history_view`, anchored at the pen side under the chip bar, `KIT_HISTORY_LIST_W` wide) or Strip (the
  bar over the shelf, as before). The list's rows come from `history_rows`, newest first, a step being a non-chain
  entry with the chained ones after it; a group is consecutive same-brush strokes on one object on one side of
  `done`, none adjusted, opened by `Timeline.open_at` (its oldest stroke's `at`, so undoing its newest keeps it
  open). A row's position counts `done` then `undone` reversed (`history_entry_at`) and a tap seeks to `last + 1`
  through `timeline_seek_to`. Sizes are `History_Entry.bytes`, set when recorded (`sculptor_last_step_bytes`,
  `clay_last_step_bytes`, the swap snapshot, the texture step); never measure them while drawing. The root row reads
  `History.began` and `History.dropped`. Scenarios that tap the strip set `history_view strip` first.
