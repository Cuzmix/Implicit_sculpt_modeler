package main

import "core:fmt"
import "core:slice"
import "core:strings"

import "../sculpt"
import "../ui"

// The Library's items and categories (the Library itself is the sheet over the shelf,
// kit_brush_sheet in lens_shelf.odin). Everything it lists is a Brush_Item: a brush, a
// preset (built-in, yours or a pack's), the Curve and Insert tools, a mask, hide or cut
// tool, or any other button a dock can hold (a card, a slider, a command). The categories,
// Recent and Favorites are the interface's: settings.txt remembers them (brush_category,
// brush_recent, brush_favorite).

BRUSH_RECENT :: 12
BRUSH_FAVORITES :: 48
BRUSH_KEY :: 80

// Lucide's heart.
ICON_HEART :: rune(0xe0f5)

// All comes first so a fresh install opens on it; the column lists them in
// BRUSH_CATEGORY_ORDER, ZBrush's, with Recent and Favorites above All, then the buttons
// that are not brushes: cards, sliders and every other command.
Brush_Category :: enum u8 {
	All,
	Recent,
	Favorites,
	Clay,
	Crease,
	Smooth,
	Move,
	Cloth,
	Mask,
	Paint,
	Clip_Hide,
	Curve_Insert,
	History,
	Presets, // yours
	Pack, // a content pack's presets: Brush_Palette.pack says which
	Cards, // Open card, of a card or a section's card
	Sliders, // the brush values a dock shows as sliders
	Commands, // every other button
}

@(rodata)
BRUSH_CATEGORY_ORDER := [?]Brush_Category{.Recent, .Favorites, .All, .Clay, .Crease, .Smooth, .Move, .Cloth, .Mask, .Paint, .Clip_Hide, .Curve_Insert, .History, .Presets, .Cards, .Sliders, .Commands}

@(rodata)
BRUSH_CATEGORY_NAMES := [Brush_Category]string {
	.Recent       = "Recent",
	.Favorites    = "Favorites",
	.All          = "All",
	.Clay         = "Clay",
	.Crease       = "Crease",
	.Smooth       = "Smooth",
	.Move         = "Move",
	.Cloth        = "Cloth",
	.Mask         = "Mask",
	.Paint        = "Paint",
	.Clip_Hide    = "Clip and hide",
	.Curve_Insert = "Curve and insert",
	.History      = "History",
	.Presets      = "My presets",
	.Pack         = "Pack",
	.Cards        = "Cards",
	.Sliders      = "Sliders",
	.Commands     = "Commands",
}

// The category a brush, and the library's presets made from it, are listed under: what
// the brush does to the surface, as ZBrush groups its own.
@(rodata)
BRUSH_CATEGORY_OF := [sculpt.Brush_Kind]Brush_Category {
	.Draw       = .Clay,
	.Smooth     = .Smooth,
	.Clay       = .Clay,
	.Flatten    = .Smooth,
	.Inflate    = .Clay,
	.Pinch      = .Crease,
	.Crease     = .Crease,
	.Grab       = .Move,
	.Mask       = .Mask,
	.Layer      = .Clay,
	.Snake_Hook = .Move,
	.Morph      = .History,
	.Paint      = .Paint,
	.Cloth      = .Cloth,
	.History    = .History,
	.Elastic    = .Move,
	.Clay_Strips  = .Clay,
	.Trim_Dynamic = .Smooth,
}

// The Library's own state, in Kit_State.
Brush_Palette :: struct {
	category:       Brush_Category,
	pack:           int, // into App.library.packs, or PACKS_MANAGE, while category is .Pack
	// The dock's slot it is choosing a button for (library_open_for): a tap puts the item
	// there instead of picking it.
	adding:         Maybe(Bar_Pick),
	puts:           int, // buttons put on a dock from it, for the exit stats
	side_reveal:    bool, // the column scrolls to the category shown, once laid out
	searching:      bool,
	search_focus:   bool, // the search field takes the keyboard on its first frame
	search:         [32]u8,
	side_scroll:    f32,
	recent:         [BRUSH_RECENT]Brush_Key, // most recent first
	recent_count:   int,
	favorites:      [BRUSH_FAVORITES]Brush_Key, // in the order they were added
	favorite_count: int,
	seen:           Dock_Slot, // the brush last frame, to notice a pick made anywhere
	seen_ok:        bool,
	picks:          int, // picks and settings opened from the browser, for the exit stats
}

// A Brush_Item's name as Recent and Favorites keep it (brush_item_key), up to the first
// zero byte.
Brush_Key :: [BRUSH_KEY]u8

Brush_Item_Kind :: enum u8 {
	Slot, // a brush or a preset, or (slot.command) any other button
	Tool,
	Mask_Shape,
	Gesture,
}

Brush_Item :: struct {
	what:    Brush_Item_Kind,
	slot:    Dock_Slot,
	tool:    Tool,
	mask:    Mask_Shape_Kind,
	gesture: Gesture_Tool,
}

// An item as listed: with its name, and the name in lower case, which sorts and searches.
Listed_Brush :: struct {
	item:       Brush_Item,
	name, low:  string,
	key:        string,
}

brush_key_text :: proc(k: ^Brush_Key) -> string {
	n := 0
	for n < BRUSH_KEY && k[n] != 0 do n += 1
	return string(k[:n])
}

brush_key_set :: proc(k: ^Brush_Key, s: string) {
	k^ = {}
	copy(k[:BRUSH_KEY - 1], s)
}

brush_item_name :: proc(app: ^App, it: Brush_Item) -> string {
	switch it.what {
	case .Slot:       return dock_slot_label(app, it.slot)
	case .Tool:       return kit_tool_name(it.tool)
	case .Mask_Shape: return fmt.tprintf("Mask %s", MASK_SHAPE_NAMES[it.mask])
	case .Gesture:    return string(GESTURE_NAMES[it.gesture])
	}
	return ""
}

// What Recent and Favorites remember an item by: its kind and name, which outlive a
// preset deleted before it or a pack installed after it, as indices would not.
brush_item_key :: proc(app: ^App, it: Brush_Item) -> string {
	switch it.what {
	case .Slot:
		s := it.slot
		switch {
		case s.command.id != .None:
			// Slashes for the name's colon, so a control's name (the Library's card) has none.
			name, _ := strings.replace_all(command_name(s.command.id, s.command.arg), ":", "/", context.temp_allocator)
			return fmt.tprintf("button/%s", name)
		case s.preset == 0:
			return fmt.tprintf("brush/%s", BRUSHES[s.kind].name)
		case preset_of_pack(s.preset):
			p, _ := preset_at(app, s.preset)
			return fmt.tprintf("pack/%s/%s", app.library.presets[s.preset - PACK_PRESET].pack, preset_name(p))
		case preset_built_in(s.preset):
			return fmt.tprintf("library/%s", BUILT_IN_PRESETS[s.preset - BUILT_IN_PRESET].name)
		case:
			p, _ := preset_at(app, s.preset)
			return fmt.tprintf("preset/%s", preset_name(p))
		}
	case .Tool:       return fmt.tprintf("tool/%s", kit_tool_name(it.tool))
	case .Mask_Shape: return fmt.tprintf("mask/%s", MASK_SHAPE_NAMES[it.mask])
	case .Gesture:    return fmt.tprintf("gesture/%s", GESTURE_NAMES[it.gesture])
	}
	return ""
}

brush_item_icon :: proc(app: ^App, it: Brush_Item) -> rune {
	switch it.what {
	case .Slot:
		if it.slot.command.id != .None do return bar_icon(app, it.slot.command)
		return BRUSHES[it.slot.kind].icon
	case .Tool:       return TOOL_ICONS[it.tool]
	case .Mask_Shape: return SHAPE_TOOL_ICONS[it.mask]
	case .Gesture:    return GESTURE_ICONS[it.gesture]
	}
	return ui.ICON_BRUSH
}

// What an item is, under its name on the current brush's card.
brush_item_family :: proc(app: ^App, it: Brush_Item) -> string {
	switch it.what {
	case .Slot:
		s := it.slot
		base := BRUSHES[s.kind].name
		switch {
		case s.command.id != .None:        return BRUSH_CATEGORY_NAMES[brush_item_category(it)]
		case s.preset == 0:                return "Brush"
		case preset_of_pack(s.preset):     return fmt.tprintf("%s, from a pack", base)
		case preset_built_in(s.preset):    return fmt.tprintf("%s, from the library", base)
		case:                              return fmt.tprintf("Your %s preset", strings.to_lower(base, context.temp_allocator))
		}
	case .Tool:       return "Tool"
	case .Mask_Shape: return "Mask shape"
	case .Gesture:    return "Hide and cut"
	}
	return ""
}

// Whether an item is chosen: the brush or preset held, the tool picked, the mask shape
// Ctrl draws or the gesture Ctrl + Shift runs.
brush_item_on :: proc(app: ^App, it: Brush_Item) -> bool {
	switch it.what {
	case .Slot:       return dock_slot_on(app, it.slot)
	case .Tool:       return app.tool == it.tool
	case .Mask_Shape: return app.ui.mask_shape_kind == it.mask
	case .Gesture:    return app.gesture == it.gesture
	}
	return false
}

brush_item_hint :: proc(app: ^App, it: Brush_Item) -> string {
	switch it.what {
	case .Slot:
		if c := it.slot.command; c.id != .None do return command_hint(app, c.id, c.arg)
		if it.slot.preset == 0 do return command_hint(app, .Brush, int(it.slot.kind))
		if arg, ok := preset_slot_of(it.slot.preset); ok do return command_hint(app, .Brush_Preset, arg)
		return ""
	case .Tool:       return command_hint(app, TOOL_COMMANDS[it.tool])
	case .Mask_Shape: return "Ctrl + drag on empty space, or Mask on the wheel"
	case .Gesture:    return "Ctrl + Shift + drag, or Hide on the wheel"
	}
	return ""
}

// The category an item is listed under besides All. A pack's presets are under the pack.
brush_item_category :: proc(it: Brush_Item) -> Brush_Category {
	switch it.what {
	case .Slot:
		s := it.slot
		#partial switch s.command.id {
		case .None:
		case .Open_Card, .Open_Section: return .Cards
		case .Brush_Value:               return .Sliders
		case:                            return .Commands
		}
		if s.preset > 0 && preset_of_pack(s.preset) do return .Pack
		if s.preset > 0 && !preset_built_in(s.preset) do return .Presets
		return BRUSH_CATEGORY_OF[s.kind]
	case .Tool:       return .Curve_Insert
	case .Mask_Shape: return .Mask
	case .Gesture:    return .Clip_Hide
	}
	return .All
}

// Picks an item, as a tap on its tile does.
brush_item_pick :: proc(app: ^App, it: Brush_Item) {
	switch it.what {
	case .Slot:       dock_slot_pick(app, it.slot)
	case .Tool:       command_run(app, TOOL_COMMANDS[it.tool])
	case .Mask_Shape: shape_tool_pick(app, it.mask)
	case .Gesture:    shape_tool_pick(app, it.gesture)
	}
	if it.what != .Slot do brush_recent_push(&app.kit.brushes, brush_item_key(app, it))
}

// Picks an item and shows its settings, as a long press on its tile does; a mask shape or
// a gesture has none of its own, so it is only picked.
brush_item_settings :: proc(app: ^App, it: Brush_Item) {
	switch it.what {
	case .Slot:       dock_slot_settings(app, it.slot)
	case .Tool:       tool_settings_open(app, it.tool)
	case .Mask_Shape, .Gesture: brush_item_pick(app, it)
	}
}

// Every item the Library lists, in its order: the brushes, the built-in presets, yours,
// each pack's, then the tools, the mask shapes and the gestures, and with `buttons` every
// other button a dock can hold, in the registry's order.
brush_items_all :: proc(app: ^App, buttons := false) -> [dynamic]Listed_Brush {
	items := make([dynamic]Brush_Item, context.temp_allocator)
	for kind in sculpt.Brush_Kind do append(&items, Brush_Item{what = .Slot, slot = {kind = kind}})
	for r, j in BUILT_IN_PRESETS do append(&items, Brush_Item{what = .Slot, slot = {kind = r.kind, preset = BUILT_IN_PRESET + j}})
	for p, i in app.presets[:app.preset_count] do append(&items, Brush_Item{what = .Slot, slot = {kind = p.values.kind, preset = i + 1}})
	for p, j in app.library.presets do if !p.gone do append(&items, Brush_Item{what = .Slot, slot = {kind = p.preset.values.kind, preset = PACK_PRESET + j}})
	for tool in ([?]Tool{.Curve, .Insert, .Model}) do append(&items, Brush_Item{what = .Tool, tool = tool})
	for m in Mask_Shape_Kind do append(&items, Brush_Item{what = .Mask_Shape, mask = m})
	for g in Gesture_Tool do append(&items, Brush_Item{what = .Gesture, gesture = g})
	if buttons do for e in palette_entries() {
		if e.kind != .Command || !bar_lists(e.id) || library_lists_already(e.id) do continue
		append(&items, Brush_Item{what = .Slot, slot = {command = {e.id, e.arg}}})
	}
	if buttons do append(&items, Brush_Item{what = .Slot, slot = {command = {.Command_Palette, 0}}})
	out := make([dynamic]Listed_Brush, 0, len(items), context.temp_allocator)
	for it in items {
		name := brush_item_name(app, it)
		append(&out, Listed_Brush{item = it, name = name, low = strings.to_lower(name, context.temp_allocator), key = brush_item_key(app, it)})
	}
	return out
}

// Whether command `id`'s buttons are listed already as the Library's own items (the
// brushes, presets, tools and shapes).
@(private = "file")
library_lists_already :: proc(id: Command_Id) -> bool {
	if shelf_holds_brushes(id) do return true
	return id == TOOL_COMMANDS[.Curve] || id == TOOL_COMMANDS[.Insert] || id == TOOL_COMMANDS[.Model]
}

// Whether an item is one of the buttons that are not brushes, tools or shapes.
brush_item_is_button :: proc(it: Brush_Item) -> bool {
	return it.what == .Slot && it.slot.command.id != .None
}

// Whether a listed item belongs to pack `pack` (into App.library.packs).
brush_item_of_pack :: proc(app: ^App, it: Brush_Item, pack: int) -> bool {
	if it.what != .Slot || !preset_of_pack(it.slot.preset) || pack < 0 || pack >= len(app.library.packs) do return false
	return app.library.presets[it.slot.preset - PACK_PRESET].pack == app.library.packs[pack].id
}

// What the grid shows: the search's matches while there is a search, else the category's
// items. Recent is in the order picked and Favorites in the order added; the rest are
// alphabetical, as the index needs.
brush_palette_list :: proc(app: ^App, all: []Listed_Brush) -> []Listed_Brush {
	p := &app.kit.brushes
	out := make([dynamic]Listed_Brush, context.temp_allocator)
	query := strings.to_lower(strings.trim_space(string(cstring(raw_data(p.search[:])))), context.temp_allocator)
	switch {
	case p.searching && query != "":
		for l in all do if strings.contains(l.low, query) do append(&out, l)
	case p.category == .Recent:
		for &k in p.recent[:p.recent_count] do if l, ok := brush_find(all, brush_key_text(&k)); ok do append(&out, l)
		return out[:]
	case p.category == .Favorites:
		for &k in p.favorites[:p.favorite_count] do if l, ok := brush_find(all, brush_key_text(&k)); ok do append(&out, l)
		return out[:]
	case p.category == .All:
		for l in all do if !brush_item_is_button(l.item) do append(&out, l)
	case p.category == .Pack:
		// Manage packs (PACKS_MANAGE) lists no items: the sheet shows the packs there.
		if p.pack >= 0 do for l in all do if brush_item_of_pack(app, l.item, p.pack) do append(&out, l)
	case:
		for l in all do if brush_item_category(l.item) == p.category do append(&out, l)
	}
	slice.stable_sort_by(out[:], proc(a, b: Listed_Brush) -> bool {return a.low < b.low})
	return out[:]
}

brush_find :: proc(all: []Listed_Brush, key: string) -> (Listed_Brush, bool) {
	for l in all do if l.key == key do return l, true
	return {}, false
}

// Puts `key` first in Recent, moving it there if it is already in it.
brush_recent_push :: proc(p: ^Brush_Palette, key: string) {
	if key == "" do return
	at := p.recent_count
	for &k, i in p.recent[:p.recent_count] do if brush_key_text(&k) == key {
		at = i
		break
	}
	if at == p.recent_count {
		at = min(p.recent_count, BRUSH_RECENT - 1)
		p.recent_count = min(p.recent_count + 1, BRUSH_RECENT)
	}
	copy(p.recent[1:at + 1], p.recent[:at])
	brush_key_set(&p.recent[0], key)
}

// Whether `key` is a favorite, and where.
brush_favorite :: proc(p: ^Brush_Palette, key: string) -> (int, bool) {
	for &k, i in p.favorites[:p.favorite_count] do if brush_key_text(&k) == key do return i, true
	return -1, false
}

// Adds `key` to the favorites, or takes it out.
brush_favorite_toggle :: proc(p: ^Brush_Palette, key: string) {
	if i, ok := brush_favorite(p, key); ok {
		copy(p.favorites[i:], p.favorites[i + 1:p.favorite_count])
		p.favorite_count -= 1
		return
	}
	if key == "" || p.favorite_count == BRUSH_FAVORITES do return
	brush_key_set(&p.favorites[p.favorite_count], key)
	p.favorite_count += 1
}

// Notices a brush or preset picked anywhere (the dock, a key, a pie, the browser) and
// puts it first in Recent. The brush the app starts on is not a pick.
brush_recent_track :: proc(app: ^App) {
	p := &app.kit.brushes
	now, ok := brush_as_slot(app)
	if !ok do return
	if p.seen_ok && !dock_slot_same(now, p.seen) do brush_recent_push(p, brush_item_key(app, {what = .Slot, slot = now}))
	p.seen, p.seen_ok = now, true
}

// The item the current brush's card shows: the Curve or Insert tool while one is picked,
// else the brush or preset held.
brush_item_current :: proc(app: ^App) -> Brush_Item {
	if app.tool == .Curve || app.tool == .Insert || app.tool == .Model do return {what = .Tool, tool = app.tool}
	return {what = .Slot, slot = {kind = app.brush.kind, preset = app.brush.preset}}
}

// The Lens brush picker's column (lens_shelf.odin): the categories alone, `width` wide,
// with a rule down its right. Returns its width.
brush_palette_categories :: proc(app: ^App, owner: ui.Id, all: []Listed_Brush, height: f32) -> f32 {
	ctx := &app.kit.ctx
	t := ctx.theme
	W :: 200
	ui.begin(ctx, "brush sheet categories", {direction = .Column, gap = 0, padding = ui.SPACE_M, width = W, height = height})
	brush_category_rows(app, owner, all, W - 16, height - 16)
	ui.end(ctx)
	if r := ui.prev_rect(ctx, "brush sheet categories"); r.w > 0 do ui.fill_rect(ctx, {r.x + r.w - 1, r.y, 1, r.h}, 0, t.border)
	return W
}

// The categories in the app's order, then Manage packs and each installed pack, each row
// with how many it holds, in a body that scrolls; a tap shows that category's brushes.
@(private = "file")
brush_category_rows :: proc(app: ^App, owner: ui.Id, all: []Listed_Brush, width, height: f32) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.brushes
	t := ctx.theme
	counts: [Brush_Category]int
	packs := make([]int, len(app.library.packs), context.temp_allocator)
	for l in all {
		counts[brush_item_category(l.item)] += 1
		for _, i in app.library.packs do if brush_item_of_pack(app, l.item, i) do packs[i] += 1
	}
	for l in all do if !brush_item_is_button(l.item) do counts[.All] += 1
	counts[.Recent] = len(brush_palette_count(app, all, p.recent[:p.recent_count]))
	counts[.Favorites] = len(brush_palette_count(app, all, p.favorites[:p.favorite_count]))
	rows := kit_scroll_begin(ctx, "brush categories", &p.side_scroll, owner, width, height, 0)
	for c, i in BRUSH_CATEGORY_ORDER {
		if c == .Cards do ui.caption(ctx, "  BUTTONS")
		// The sheet always shows its search field; a category is lit while nothing is typed.
		on := brush_query(p) == "" && p.category == c
		if ui.list_row(ctx, fmt.tprintf("%s##brush category", BRUSH_CATEGORY_NAMES[c]), fmt.tprint(counts[c]), on).clicked {
			p.category, p.searching, p.search, k.grid_scroll = c, false, {}, 0
		}
		// Opened on a category below the fold (the Library for a dock), it scrolls into sight.
		if on && p.side_reveal && rows.limit > 0 {
			p.side_scroll = clamp(f32(i + 1) / f32(len(BRUSH_CATEGORY_ORDER) + 1) * rows.natural - height * 0.4, 0, rows.limit)
			p.side_reveal = false
		}
	}
	// The content packs: Manage packs (install, make, remove), then
	// each pack installed, with how many presets it brings.
	ui.caption(ctx, "  PACKS")
	manage := brush_query(p) == "" && p.category == .Pack && p.pack == PACKS_MANAGE
	if ui.list_row(ctx, "Manage packs##brush packs manage", fmt.tprint(len(app.library.packs)), manage).clicked {
		library_packs_open(app)
	}
	// Opened on the packs (Menu > More > Library, a pack waiting on Replace), the list
	// scrolls down to them.
	if p.category == .Pack && p.side_reveal && rows.limit > 0 {
		p.side_scroll = rows.limit
		p.side_reveal = false
	}
	for pack, i in app.library.packs {
		on := brush_query(p) == "" && p.category == .Pack && p.pack == i
		name := ui.text_fit(ctx, pack.name, t.text_size, width - 56)
		if ui.list_row(ctx, fmt.tprintf("%s##brush pack %d", name, i), fmt.tprint(packs[i]), on).clicked {
			p.category, p.pack, p.searching, p.search, k.grid_scroll, k.pack_armed = .Pack, i, false, {}, 0, 0
		}
	}
	kit_scroll_end(ctx, rows)
}

// The keys of `keys` that name an item there is.
@(private = "file")
brush_palette_count :: proc(app: ^App, all: []Listed_Brush, keys: []Brush_Key) -> []Listed_Brush {
	out := make([dynamic]Listed_Brush, context.temp_allocator)
	for &k in keys do if l, ok := brush_find(all, brush_key_text(&k)); ok do append(&out, l)
	return out[:]
}

// Opens the Library to choose the button for `pick`: on the category that dock holds most
// (the rail's cards, the brush bar's sliders, a shelf page's brushes, the other docks'
// commands, the brush pie's brushes). While it is open a tap puts the item there instead of picking it.
library_open_for :: proc(app: ^App, pick: Bar_Pick) {
	k := &app.kit
	p := &k.brushes
	kit_floats_close(k)
	p.adding = pick
	p.category, p.searching, p.search = library_category_for(pick.which), false, {}
	k.browser, k.grid_scroll, k.grid_reveal = true, 0, false
	p.side_scroll, p.side_reveal = 0, true
	// The search field takes the keys at once, so typing a name and Enter chooses.
	p.search_focus = true
}

// The category the Library opens on for bar `which`.
library_category_for :: proc(which: Bar_Which) -> Brush_Category {
	#partial switch which {
	case .View_Rail: return .Cards
	case .Offhand:   return .Sliders
	case .Brush_Pie: return .All
	}
	if _, ok := shelf_page_of(which); ok do return .All
	return .Commands
}

// The button `it` is on a dock, as the Library puts it there.
library_slot_of :: proc(it: Brush_Item) -> (Bar_Slot, bool) {
	return shelf_slot_of(it)
}

// Whether item `it` stands on the bar the Library is adding to.
library_on_bar :: proc(app: ^App, it: Brush_Item) -> bool {
	pick, ok := app.kit.brushes.adding.?
	if !ok do return false
	s, has := library_slot_of(it)
	if !has do return false
	for u in bar_used(app, pick.which) do if u == s do return true
	return false
}

// A tap on item `it` while the Library adds to a dock: it goes on that dock after the last
// one put there, or comes off it when it is there already; choosing for one slot, it
// takes that slot and the Library closes.
library_put :: proc(app: ^App, it: Brush_Item) {
	k := &app.kit
	p := &k.brushes
	pick, ok := p.adding.?
	if !ok do return
	s, has := library_slot_of(it)
	if !has do return
	// The brush pie's editor chooses its slots here too, whatever bar_takes says of a carry.
	if takes, why := bar_takes(pick.which, s); !takes && pick.which != .Brush_Pie {
		report(app, nil, {.Warning}, "%s", why)
		return
	}
	if !pick.add {
		bar_put(app, pick, s)
		p.puts += 1
		k.browser = false
		return
	}
	for u, i in bar_used(app, pick.which) do if u == s {
		bar_remove(app, pick.which, i)
		if i < pick.slot do p.adding = Bar_Pick{which = pick.which, slot = pick.slot - 1, add = true}
		report(app, nil, {}, "%s is off %s", bar_label(app, s), strings.to_lower(bar_title(app, pick.which), context.temp_allocator))
		return
	}
	if len(bar_used(app, pick.which)) >= bar_capacity(pick.which) {
		report(app, nil, {.Warning}, "%s is full: take a button off first", bar_title(app, pick.which))
		return
	}
	bar_put(app, pick, s)
	p.puts += 1
	p.adding = Bar_Pick{which = pick.which, slot = min(pick.slot + 1, len(bar_used(app, pick.which))), add = true}
	// The search keeps the keys, to type the next one's name.
	p.search_focus = true
}

// The bar the Library is adding to, by its settings name, or none: for the exit stats.
library_for_text :: proc(app: ^App) -> string {
	pick, ok := app.kit.brushes.adding.?
	if !ok || !app.kit.browser do return "none"
	return BAR_ZONES[pick.which]
}
