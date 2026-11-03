# The Lens layout in detail (sm-ui)

The chrome round the view, bar by bar, as `kit_layout` lays it out: what each container is called, what keeps clear
of what, Arrange, the docks, the palette groups and the dial. Read it before changing any chrome; SKILL.md keeps the
summary.

- Layout: one, Lens (the Sculpt Workspace Directions mock; spec `notes/lens/mock-layout-design.md`). The Classic
  layout (ZBrush-iPad bars, the dock, `--chrome`) is gone; never add a second chrome: `settings_load` passes over old
  `chrome`, `panes_under_panels`, `dock*` and `right_rail` lines. `kit_layout` (`new_ui.odin`) lays out in order: the
  top bar `kit_top_bar` (`kit_top_lens.odin`, root "top bar", floating `TOP_BAR_INSET` in and `TOP_BAR_TOP` down;
  `TOP_BAR_H` stays the room it takes): three docks (`Top_Dock`, bars `.Top_File/.Top_Spaces/.Top_App`, roots "file dock",
  "spaces dock", "app dock"; `top_dock_draw` draws the chips and bar buttons by command id, anything else `bar_slot_button`;
  `top_widths` + the give-way loop): Main_Menu, File_Chip (`file_status`, fixed width so Undo/Redo never move) | Save, Undo,
  Redo | space tabs `top_space_tabs` | the object chip `top_object_chip` (`object_chip.odin`, shrunk by
  `object_chip_fit`; its tap opens `kit_object_menu`, `object_menu.odin`: rows from `OBJECT_VERBS[Object_Type][Space]`,
  each a registry command, another space's first enabled verb tagged with `menu_item(tag =, tag_color = t.tints[space])`
  and run after `Space_Switch`; a new verb is a table row, never a menu branch; on the view `view_menu_open` serves the right
  click (`pie_update`), the `Object_Menu` command and the finger's `hold_menu_check` in `pointer_route`; `space_fit` (`offers.odin`)
  rings it amber and `kit_offer_line` takes the action bar's place; a dimmed command passes `command_reason` as `reason`;
  `kit_colour_island` sits under both while painting, lifting them by `colour_island_lift`) | Search field | History, Settings, all laid inline with spacers (a `begin_at` inside the bar
  loses hits to it); its width budget counts the row's gaps (`things`, 14 with every section in). While editing, File and App draw every slot as `bar_slot_button` (carry, change, remove) plus `bar_add_button`, and Spaces holds `arrange_top_controls`; `lens_focus(k)` (the View_Bar zone hidden) gives the middle `top_focus_middle` and the end `top_focus_view`, with no readout and
  a compact shelf. Then `kit_readout` (readout.odin: "points" > "readout lines" > "readout", the camera and shading words over faded vertices, memory and GPU lines; skipped while a pane is maximised, in Focus or hidden: `readout=`), `kit_dock(app, .Offhand)` (the island, "brush bar": Size and Strength
  `ui.vslider`s via `dock_slider`, the pen's roll sets them via `island_roll`), `kit_nav_head`, `kit_dock(app, .Rail)`
  ("view bar", `Bar_Which.View_Rail`), `kit_user_docks`, the shelf `kit_shelf` (`lens_shelf.odin`, "dock", pages row "dock pages"),
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
  Docks (`docks.odin`): every bar round the view is a `Dock_Id` (Offhand, Rail, Shelf, Dock_1..4) with a `Dock` in
  `Kit_State.docks` (the layout's: `place`, `more_lines`, `names`, `more_off`, `used`; one `dock` layout line each) and its
  buttons in the bar list `dock_which` names. `kit_dock` draws all but the shelf the same way: lines of `bar_slot_button`s
  (names via `dock_named`, labels `rail_label`), tall sliders for values whose look is Slider (demoted to chips when short),
  a scroll body, the + while arranging and the ⋯ (`More##<root>`, `Bar_Pop_Kind.Dock_Menu`, `kit_dock_menu`). A new
  per-dock choice goes on `Dock` and its menu, never a Settings row.
  Places: each dock stands where `Kit_State.docks[d].place` says (`Dock_Place`:
  Default, Left/Right at `along` for the columns, Bottom at `along` for the shelf (`dock_edges`), Float at `at`, layout terms). Default must draw as before
  (parity); anything that keeps clear of a side bar asks `kit_left`/`kit_right` (they measure the bars on each edge) and
  a popover's side `bar_side(app, which)`, never "the island is left, the rail right". Edit docks' heads carry them
  (`arrange_carry_follow`, `dock_drop`, `dock_place_set` swaps two docks on one edge; a floating drop lines up by `dock_align`),
  and each dock's resize corner (`arrange_resize_corner`) sets `more_lines`; a dock's menu holds `dock_reset` and Delete dock. Whatever keeps clear of the
  shelf at the bottom asks `shelf_bottom_size`/`shelf_bottom_span` (nothing while it floats), never "centred, last frame's size".
  User docks: `Kit_State.dock_lists[i]` is `Bar_Which.Dock_1 + i`'s list, `Dock_Id.Dock_1 + i` (`user_dock_id`) its dock; they are layout-only (`bars_save` skips them in settings and while unused), home Float
  (a Default one floats in the middle, `dock_anchor`). Ask `user_dock_shown`, and from inside a container find a root with
  `ui.prev_root_rect` (plain `prev_rect` looks for a child of the current container).
  Bars (`bars.odin`): `Bar_Which` is View_Rail, the `Shelf_*` pages (each space's from `shelf_pages_of`),
  Brush_Pie and Offhand (the island, last so zone names and `shelf_page_of` keep their meaning), each a `Bar_List` of `Bar_Slot` drawn by `bar_slot_button`, whose `bar_slot_run`/`bar_slot_more`/
  `bar_lit`/`bar_icon` keep each command's own tap, long press and lit state wherever it sits; `BAR_LAYOUT` (Tools,
  View_Rail) go in workspace layouts, the pages, the pie and the island only in settings. Brush values
  (`brush_values.odin`) are `Brush_Value` slots (one argument per value); their look is the bar's
  (`Bar_List.looks`, kept parallel by insert, remove and move; `bar_look` turns a Slider off the island into a
  Chip), and `value_item` draws every look, a Chip claiming the drag only across its bar (`claim_drag`). Customise bars (`k.bars_edit`) is
  Arrange (`lens_arrange.odin`): a tap on a ringed slot opens `kit_bar_slot_menu` with `bar_slot_actions`, the
  Library (`bar_choose` -> `library_open_for`, `library_put` -> `bar_put`) chooses its button; Arrange's sheet's Panels tab is
  `arrange_show_chips` + `arrange_panel_rows` (the stack Hidden/Left/Right/Float, other windows Hidden/Shown), and
  `kit_arrange_ghosts` outlines a hidden shelf, wheel or action bar. A bar button opens the one `Bar_Pop` (`bar_pop_toggle`): the symmetry axes, the
  polyframe parts, the Remesh quick menu, Shading, Camera or View layout. A section or card button off the rail (and a
  long press's section, a value menu's or quick menu's settings) pops the stack's own card out as a floating window
  beside it (`card_pop.odin`: `card_pop_toggle`, `card_pop_section`, one at a time, placed again by its laid-out size,
  Keep open / Close in its head, `card_pop=` stat); a card the docked stack shows opens there instead. `corner = true` on `icon_button` draws the triangle that says a long press does more.
  An overlay on a panel's own area takes no hits from a `begin_at` root (the mini view's chip is part of the picture's
  press). Thumbnail = `kit_mini_view`; `lens_mini_reach` shortens the docked stack above it. The shelf's pages are
  drag_scroll, so `ui.swipe_update` on it turns pages (`shelf_turn`); `shelf_lines_layout`/`shelf_fit` decide how many tiles (in the dock's lines as rows)
  show; ask a child's `prev_rect` inside its parent. `k.order` is `Float_Ref` (windows and floated
  `Panel_Kind`s): `float_raise` on a press; the dial (`kit_modifier_rail`) is laid out after the floats, before menus
  and popovers, so it is the top lasting root. `ui.row_room` right-aligns in a fixed-width row (spacer(0) does
  nothing). The tray is the stack (`lens_stack.odin`, `kit_inspector`, `panel_begin(bare)`): cards in `k.stack`,
  layout line `stack`; `tray_open` calls `stack_reveal` (`exact` for Show where), which brings a left-out section's
  palette in as `s.visit` (`stack_visit`; `stack_keep` keeps a section for good, Pin to the stack, `stack_kept` asks; the layout never writes the visit; markers ask
  `palette_on_screen`; `s.revealed` is the section opened last); the tray and its Palettes card are gone (PR 9c),
  and `stack_layout_upgrade` rewrites a saved layout that still names Palettes; `k.in_stack` lets a section drop what the Brush card shows above it. What a panel holds is a `Panel_Kind`
  (`panel_kind.odin`: one enum, the cards of their own (`STACK_CARDS`) then a card per section, `panel_is_section`;
  sections start in `STACK_HIDDEN_DEFAULT`, and stack lines write one only while shown, as
  `panel_word`'s `section:Mask`); its content is `panel_body`, which the stack and the pane strip's tab
  both call, and its title, icon, folded line and layout name (`card:Brush`, `section:Stroke`) come from
  the `panel_kind_*` procs. The brush pie is
  `Bar_Which.Brush_Pie` (`k.brush_pie`, eight slots); `pie_slot` reads it, `lens_pie_update` adds tap-to-pick and
  the rest that opens `pie_quick`. Stack sizes live in `lens_resize.odin` (`stack_width`, which `tray_width` returns,
  `heights`, `sizes`, layout line `stack_size`); its handles are `ui.begin_at` roots drawn after what they resize.
  Split views chrome is `lens_panes.odin`: `lens_pane_head` (chips, `k.pane_menu` lists), `grid_divider_lens`
  (grip, `handle_double_tap` evens, edge close via `grid_close_target`, the main pane never closes), `grid_choose`
  (the View grid command; `k.new_panes`), and the stack's tab strip while `stack_strip_shown` (panes beside the main view;
  `kit_stack_tab` draws a card over the view through `stack_card_body`, and
  `stack_reveal` opens the strip's card at `s.strip_at`). Palette groups (`stack_groups.odin`) are runs in
  `s.order`: a host then the cards in `s.joined`; the host carries open, floated, hidden, window, height, size and
  scroll, `s.shown[host]` (read through `stack_shown`) the tab drawn. Iterate hosts only (skip `s.joined`), move runs
  (`stack_move_to_k`), and read `stack_group` lines after the whole layout (`kit_layout_put`). Carrying is
  `stack_carry.odin`: sources set `s.carry` (the grip; `ui.tabs(dragged = &i)`), `stack_carry_update` runs once after
  the floats (new_ui.odin) and targets only this frame's `s.seen` and `s.strip_seen` rects, cleared by `stack_frame_begin`; a strip icon
  joins after `stack_dwell` reaches 1 (twice `long_press`, drawn with `ui.hold_ring`). A group shows as tabs or, with its
  host in `s.sections` (`stack_as_sections`), as sections (`stack_sections_body`, folds in `s.folded`); the panel's width is
  `stack_width` everywhere (`tray_width`, `panel_width`); `view_grid_room` is the whole window, panes always under the panels.
  The grid is a split tree (`Grid_Tree`, at most four leaves; pane 0 the main view, panes keep their numbers and the
  last fills a closed one's): change it only through the tree ops in grid.odin. Gestures (`lens_areas.odin`) queue a
  `Grid_Op` that `kit_grid` applies before layout; each op is a `Grid_Step` that `undo_run`/`redo_run` order against
  the History by `at` ticks. Pictures follow moved views in `grid_pictures_follow`.
  The menu is `kit_menu_lens` (`lens_menu.odin`; `LENS_MENU_PLACE` says where each command is, keep it in step with
  the rows, and touch_check's `MENU_ROWS`); search's rows, groups and Put on a bar are `lens_search.odin`
  (`palette_where`). The stack's Scene, Layers and Tools cards are `kit_lens_scene`, `kit_lens_layers` and
  `kit_lens_tools` (the full sections are cards of their own; a Tools tile is a registry command); the action
  bar's lists come from `action_list`; a lock (`Object.locked`) goes through `object_pickable`, never a raycast of its
  own. The Scene card is the outliner: its chips (`Outliner.kind`, `object_scene_kind`) and Find narrow the rows and
  stop drags (a narrowed list is not the scene's order); its Add menu (`kit_scene_add_menu`, drawn after the layer
  menu) sends the same `Scene_Command`s and commands as the Scene card; a light's row changes the lights through
  `light_drag_changed`, so the change is one undo step like the Lights section's; a row's ⋯ opens the object menu at
  `row_toggle_rect`, the toggle's own rect, which must follow `ui.thumb_row`'s layout of the toggles.
  An object's spaces dots (`Object.spaces_off`, `ui.Thumb_Row.dots`) feed `object_flags`, so leaving an object out of
  the current space is exactly an eye turned off there; anything that asks whether an object shows goes through
  `object_shown`/`object_pickable`, never `obj.off` alone. The look's cards (Lights, Material, Environment: `lens_studio.odin`) start in `stack.hidden`; every stack loop
  skips hidden cards. `built_in_layout(b)` gives each built-in workspace's layout.
  Settings rows live in `settings_block` (`settings_blocks.odin`), one case per heading; each `Settings_Section`
  (`settings_sections.odin`) is a list of `Settings_Entry`, shown by the sheet and by the narrow window's
  drill-down panel (`kit_settings.odin`, under 840 points) alike. A new setting goes in a block, its default in `settings_block_reset`, and its search words in
  `SETTINGS_BLOCK_WORDS`. Home is one page, `home_body` (`home_page.odin`), Start new beside the Continue card from `HOME_WIDE` and under it below.
  The Export sheet (`lens_export.odin`) only gathers: a new way out is an `Export_Format` whose `export_command` is an
  existing command, and a mesh format a filter of `file_dialog_export`, never a writer of its own; it is offered by
  one or more `Export_Preset`s (`export_preset_formats`), and new formats go at the end of the enum, which settings
  files name.
  New scene's argument indexes `NEW_SCENES` (Mesh, Voxels or Empty starts): append, never reorder, since keys, bars
  and scripts name a start by its number or `new_start_key`; the narrow Home page shows the first `NARROW_HOME_STARTS`.
  The dial's sectors are each space's, `Kit_State.dials[Space]` (`Dial_Sector`, a Modifier or a Bar_Slot; defaults
  `DIAL_DEFAULTS`): read the current one through `dial_of(k)`, pass it to `rail_hit`, never index a fixed table; only
  a Modifier sector claims a finger. A space switch drops latches the new dial lacks (`dial_latches_keep`); settings
  write Sculpt's as `dial_sector` and the others' as `dial_space` lines.
  The History panel (`kit_history_panel`, `timeline.odin`) shows `Timeline.view`: List (`history_list.odin`, a
  setting `history_view`, anchored at the pen side under the top bar, `KIT_HISTORY_LIST_W` wide) or Strip (the
  bar over the shelf, as before). The list's rows come from `history_rows`, newest first, a step being a non-chain
  entry with the chained ones after it; a group is consecutive same-brush strokes on one object on one side of
  `done`, none adjusted, opened by `Timeline.open_at` (its oldest stroke's `at`, so undoing its newest keeps it
  open). A row's position counts `done` then `undone` reversed (`history_entry_at`) and a tap seeks to `last + 1`
  through `timeline_seek_to`. Sizes are `History_Entry.bytes`, set when recorded (`sculptor_last_step_bytes`,
  `clay_last_step_bytes`, the swap snapshot, the texture step); never measure them while drawing. The root row reads
  `History.began` and `History.dropped`. Scenarios that tap the strip set `history_view strip` first.
  The step menu (`history_menu.odin`, drawn after the pass menu) opens from `ui.secondary` on a row or a strip block
  and knows its step by its first entry's `at` (`history_step_of`), never a position, since positions move as the
  History does. `History_Entry.view` (the camera at record time, set at every append and in `history_push`) feeds View
  from this step (`camera_go`, wrapped in the camera ease); `History_Entry.bookmark` is owned, freed in `entry_free`,
  set only through `history_bookmark_set`, named through the rename popover (`Rename_Entry.step`), and keeps a
  stroke out of a group. Delete everything older is `history_delete_before`, which Delete older history calls with
  `len(done)`. The tint (`history_tint.odin`, drawn after the flashes in `overlay_viewport`) reads
  `History_Entry.area`, recorded at `history_record` from `sculptor_last_step_bounds` / `clay_last_step_bounds` (never
  measured while drawing), through `flash_screen_box`; rows and blocks call `history_tint_rest` each frame they are
  rested on and `history_tint_frame` forgets it at the panel's start.
  The panel's Settings page (`Timeline.settings`, `kit_history_settings`) draws the Settings blocks Undo_History,
  History_Steps and History_Back, which Settings > Files lists too: one setting, two places. The History settings
  are App fields named so that off is the default (`history_no_lights`, `history_ungrouped`), so a zero App is as
  before; `history_limits_apply` hands History may use to every store only when it is set or just changed back.
  The quick scrub (`quick_scrub.odin`, `Timeline.quick`): Undo and Redo call `quick_scrub_button` right after their
  `icon_button` (it calls `ui.held_long` before `ui.secondary`, so the long press scrubs and only the right button
  opens the panel at once; the mouse begins on a sideways drag past the slop, `ui.press_used`); `touch_hold_history`
  begins the fingers' scrub once its hold fired and the fingers slide. `quick_scrub_frame` (after the menus) follows
  the pointer, maps it to `history_places` (chains are one place) and seeks; nothing else moves the History.
  Step pictures (`history_pictures.odin`, `render.Step_Pictures`): `step_pictures_frame` runs after the view panes in
  the frame loop and draws the newest done step when it has no cell (`Step_Picture_Slots.seen`), from that frame's
  draws through `narrow * proj`; panels show a cell with `step_picture_draw` (`KIT_STEP_PICTURES_IMAGE`). Never key a
  picture by position: cells are found by the step's first entry's `at`.
  The Layers panel (`lens_layers.odin`, `Kit_State.layer_panel`): a row's picture and name sit in a drag-scrolled zone
  so `ui.swipe_update` opens Merge down and Delete; the strength slider stays outside the zone (a drag there is the
  slider's at once). Ask `prev_rect` of a row's children inside the row (`id_of` is the parent's). Layer pictures
  (`layer_pictures.odin`) are cells of a second `render.Step_Pictures`, kept like the object thumbnails (settle, one a
  frame); the tint is `draw_tint_glow`, shared with the History's.
  The Material card (`lens_materials.odin`, `Kit_State.material_card`): MatCap spheres are `ui.image_disc` over
  `KIT_MATCAP_IMAGE + Material.matcap`, which `kit_draws` maps to `material_matcap`; the Matcaps tab sets
  `Library.matcaps_wanted` so `pack_matcaps_settle` makes every pack's picture. The scrub sends `.Material` Scene_Commands
  with `preview` Show/Keep/Back (`material_command` keeps the objects' materials aside in `App.material_saved`);
  `material_to` (Apply to) rides every `.Material` command.
  Layer masks in the panel (`layer_masks.odin`, `app.ui.layer_mask`): the mask badge is drawn on the picture's corner and
  answers the picture's own area (its right half), so the row keeps room for the name; `layer_mask_paint` remembers the
  brush and runs `.Brush` Mask, `layer_mask_stop(restore)` puts it back, `layer_mask_frame` ends the pick when the work
  leaves it. `history_record` sets `History_Entry.layer_mask` for a `.Mask` step on a picked layer mask (label "(layer
  mask)"); menu edits on an unpicked mask pick it for the one step (`layer_mask_edit`).
