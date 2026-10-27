package main

import "core:fmt"
import "core:slice"
import "core:strings"

import "../sculpt"
import "../ui"

// The brush browser, laid out as ZBrush for iPad's Brushes palette: a header (the
// categories' toggle, the title or the search field, Search and Close), then down the left
// the current brush's card, with its heart, and the categories, each with its count; in
// the middle the category's brushes as large tiles three to a row, alphabetical; and down
// the right an A to Z index that a tap or a drag scrolls to a letter. A tap on a tile
// picks it and closes the browser, a long press (or a right-click) shows its settings.
// Everything it lists is a Brush_Item: a brush, a preset (built-in, yours or a pack's),
// the Curve and Insert tools, or a mask, hide or cut tool. The categories, Recent and
// Favorites are the interface's: settings.txt remembers them (brush_category,
// brush_sidebar, brush_recent, brush_favorite).

BRUSH_RECENT :: 12
BRUSH_FAVORITES :: 48
BRUSH_KEY :: 80
BRUSH_COLUMNS :: 3
BRUSH_SIDEBAR_W :: 200
BRUSH_INDEX_W :: 22

// Lucide's heart and panel-left.
ICON_HEART :: rune(0xe0f5)
ICON_PANEL_LEFT :: rune(0xe12e)

// All comes first so a fresh install opens on it; the sidebar lists them in
// BRUSH_CATEGORY_ORDER, ZBrush's, with Recent and Favorites above All.
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
}

@(rodata)
BRUSH_CATEGORY_ORDER := [?]Brush_Category{.Recent, .Favorites, .All, .Clay, .Crease, .Smooth, .Move, .Cloth, .Mask, .Paint, .Clip_Hide, .Curve_Insert, .History, .Presets}

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
}

// The browser's own state, in Kit_State.
Brush_Palette :: struct {
	category:       Brush_Category,
	pack:           int, // into App.library.packs, while category is .Pack
	sidebar_hidden: bool,
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
	Slot, // a brush or a preset
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

brush_item_icon :: proc(it: Brush_Item) -> rune {
	switch it.what {
	case .Slot:       return BRUSHES[it.slot.kind].icon
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

// The ball an item's tile shows: clay, the paint colour for the Paint brush, a dark grey
// for the masks, as the viewport shows a mask.
brush_item_ball :: proc(app: ^App, it: Brush_Item) -> ui.Color {
	CLAY :: ui.Color{196, 176, 164, 255}
	MASK :: ui.Color{96, 100, 112, 255}
	switch it.what {
	case .Slot:
		if it.slot.kind == .Paint {
			b := color_bytes(app.brush.color)
			return {b.r, b.g, b.b, 255}
		}
		if it.slot.kind == .Mask do return MASK
	case .Mask_Shape: return MASK
	case .Tool, .Gesture:
	}
	return CLAY
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
	case .Slot:       return command_hint(app, .Brush, int(it.slot.kind)) if it.slot.preset == 0 else ""
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

// Every item the browser lists, in the library's order: the brushes, the built-in
// presets, yours, each pack's, then the tools, the mask shapes and the gestures.
brush_items_all :: proc(app: ^App) -> [dynamic]Listed_Brush {
	items := make([dynamic]Brush_Item, context.temp_allocator)
	for kind in sculpt.Brush_Kind do append(&items, Brush_Item{what = .Slot, slot = {kind = kind}})
	for r, j in BUILT_IN_PRESETS do append(&items, Brush_Item{what = .Slot, slot = {kind = r.kind, preset = BUILT_IN_PRESET + j}})
	for p, i in app.presets[:app.preset_count] do append(&items, Brush_Item{what = .Slot, slot = {kind = p.values.kind, preset = i + 1}})
	for p, j in app.library.presets do if !p.gone do append(&items, Brush_Item{what = .Slot, slot = {kind = p.preset.values.kind, preset = PACK_PRESET + j}})
	for tool in ([?]Tool{.Curve, .Insert}) do append(&items, Brush_Item{what = .Tool, tool = tool})
	for m in Mask_Shape_Kind do append(&items, Brush_Item{what = .Mask_Shape, mask = m})
	for g in Gesture_Tool do append(&items, Brush_Item{what = .Gesture, gesture = g})
	out := make([dynamic]Listed_Brush, 0, len(items), context.temp_allocator)
	for it in items {
		name := brush_item_name(app, it)
		append(&out, Listed_Brush{item = it, name = name, low = strings.to_lower(name, context.temp_allocator), key = brush_item_key(app, it)})
	}
	return out
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
		append(&out, ..all)
	case p.category == .Pack:
		for l in all do if brush_item_of_pack(app, l.item, p.pack) do append(&out, l)
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
	if app.tool == .Curve || app.tool == .Insert do return {what = .Tool, tool = app.tool}
	return {what = .Slot, slot = {kind = app.brush.kind, preset = app.brush.preset}}
}

// The brush browser, over its button on the dock or beside the brush bar.
kit_brush_browser :: proc(app: ^App, anchor: ui.Rect, side: ui.Side) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.brushes
	brush_recent_track(app)
	if p.category == .Pack && p.pack >= len(app.library.packs) do p.category = .All
	size, _ := ui.prev_layout(ctx, "brush browser")
	owner := ui.id_of(ctx, "brush browser")
	if !ui.popover_begin(ctx, "brush browser", &k.browser, anchor, side, {direction = .Column, gap = 8, padding = 12}) do return
	defer ui.popover_end(ctx)
	room := brush_palette_room(ctx, size.y, anchor, side)
	grid_w := ui.PREVIEW_TILE.x * BRUSH_COLUMNS
	width := grid_w + 8 + BRUSH_INDEX_W + (0 if p.sidebar_hidden else BRUSH_SIDEBAR_W + 16)
	all := brush_items_all(app)
	brush_palette_head(app, width)
	list := brush_palette_list(app, all[:])
	pick, settings: Maybe(Brush_Item)
	ui.begin(ctx, "brush palette body", {direction = .Row, gap = 8})
	if !p.sidebar_hidden {
		if it, ok := brush_palette_side(app, owner, all[:], room).?; ok do settings = it
		ui.spacer(ctx, 8)
	}
	tap, press := brush_palette_grid(app, owner, list, room)
	if it, ok := tap.?; ok do pick = it
	if it, ok := press.?; ok do settings = it
	brush_palette_index(app, list, room)
	ui.end(ctx)
	if it, ok := pick.?; ok {
		brush_item_pick(app, it)
		p.picks += 1
		k.browser = false
	}
	if it, ok := settings.?; ok {
		brush_item_settings(app, it)
		p.picks += 1
		k.browser = false
	}
}

// The grid's height: the room under the top bar beside the brush bar, or above the dock
// when the dock's button opened it, less what the browser holds besides the grid.
@(private = "file")
brush_palette_room :: proc(ctx: ^ui.Context, popover_h: f32, anchor: ui.Rect, side: ui.Side) -> f32 {
	body, _ := ui.prev_layout(ctx, "brush palette grid well")
	besides := popover_h - body.y if popover_h > 0 && body.y > 0 else 90
	free := anchor.y - 16 if side == .Above_Center else ui.safe_area(ctx).h - kit_top() - 16
	return clamp(free - besides, ui.PREVIEW_TILE.y * 2, ui.PREVIEW_TILE.y * 6)
}

// The header: the categories' toggle, the title (or the search field while searching),
// Search and Close.
@(private = "file")
brush_palette_head :: proc(app: ^App, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.brushes
	t := ctx.theme
	ui.begin(ctx, "brush palette head", {direction = .Row, center = true, width = width})
	if ui.icon_button(ctx, "Categories", ICON_PANEL_LEFT, selected = !p.sidebar_hidden) do p.sidebar_hidden = !p.sidebar_hidden
	middle := width - 3 * t.target
	if p.searching {
		_ = ui.text_field(ctx, "Search brushes", p.search[:], middle, hold = p.search_focus, hint = "Search brushes")
		p.search_focus = false
	} else {
		r := ui.place(ctx, {middle, t.target})
		ui.text(ctx, "Brushes", r.x + r.w * 0.5, r.y + r.h * 0.5, t.title_size, t.text, .Semibold, .Center)
	}
	if ui.icon_button(ctx, "Search", ui.ICON_SEARCH, selected = p.searching) {
		p.searching = !p.searching
		p.search_focus = p.searching
		p.search = {}
		k.grid_scroll = 0
	}
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do k.browser = false
	ui.end(ctx)
}

// The column at the left: the current brush's card, then the categories, each with how
// many it holds. Returns the item whose settings the card's tile asked for.
@(private = "file")
brush_palette_side :: proc(app: ^App, owner: ui.Id, all: []Listed_Brush, height: f32) -> (settings: Maybe(Brush_Item)) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.brushes
	t := ctx.theme
	ui.begin(ctx, "brush palette side", {direction = .Column, gap = 6, width = BRUSH_SIDEBAR_W, height = height})
	// The current brush, as ZBrush's card at the palette's top left: a tap on its tile
	// shows its settings, the heart keeps it in Favorites.
	cur := brush_item_current(app)
	key := brush_item_key(app, cur)
	ui.begin(ctx, "brush current", {direction = .Row, gap = 4})
	res := ui.preview_tile(ctx, "##current brush", brush_item_icon(cur), brush_item_ball(app, cur), false, "Its settings")
	if res.clicked || res.menu do settings = cur
	ui.begin(ctx, "brush current text", {direction = .Column, gap = 0, width = BRUSH_SIDEBAR_W - ui.PREVIEW_TILE.x - 4})
	ui.spacer(ctx, 10)
	ui.label(ctx, ui.text_fit(ctx, brush_item_name(app, cur), t.text_size, BRUSH_SIDEBAR_W - ui.PREVIEW_TILE.x - 8, .Semibold), font = .Semibold)
	ui.label(ctx, ui.text_fit(ctx, brush_item_family(app, cur), t.small_size, BRUSH_SIDEBAR_W - ui.PREVIEW_TILE.x - 8), size = t.small_size, color = t.text_tertiary)
	_, favorite := brush_favorite(p, key)
	if ui.icon_button(ctx, "Favorite" if !favorite else "Favorite (on)", ICON_HEART, selected = favorite) do brush_favorite_toggle(p, key)
	ui.end(ctx)
	ui.end(ctx)
	counts: [Brush_Category]int
	packs := make([]int, len(app.library.packs), context.temp_allocator)
	for l in all {
		counts[brush_item_category(l.item)] += 1
		for _, i in app.library.packs do if brush_item_of_pack(app, l.item, i) do packs[i] += 1
	}
	counts[.All] = len(all)
	counts[.Recent] = len(brush_palette_count(app, all, p.recent[:p.recent_count]))
	counts[.Favorites] = len(brush_palette_count(app, all, p.favorites[:p.favorite_count]))
	card, _ := ui.prev_layout(ctx, "brush current")
	rows := kit_scroll_begin(ctx, "brush categories", &p.side_scroll, owner, BRUSH_SIDEBAR_W, max(height - (card.y if card.y > 0 else ui.PREVIEW_TILE.y) - 6, t.target * 2), 0)
	for c in BRUSH_CATEGORY_ORDER {
		on := !p.searching && p.category == c
		if ui.list_row(ctx, fmt.tprintf("%s##brush category", BRUSH_CATEGORY_NAMES[c]), fmt.tprint(counts[c]), on).clicked {
			p.category, p.searching, p.search, k.grid_scroll = c, false, {}, 0
		}
	}
	for pack, i in app.library.packs {
		if packs[i] == 0 do continue
		on := !p.searching && p.category == .Pack && p.pack == i
		name := ui.text_fit(ctx, pack.name, t.text_size, BRUSH_SIDEBAR_W - 56)
		if ui.list_row(ctx, fmt.tprintf("%s##brush pack %d", name, i), fmt.tprint(packs[i]), on).clicked {
			p.category, p.pack, p.searching, p.search, k.grid_scroll = .Pack, i, false, {}, 0
		}
	}
	kit_scroll_end(ctx, rows)
	ui.end(ctx)
	return
}

// The keys of `keys` that name an item there is.
@(private = "file")
brush_palette_count :: proc(app: ^App, all: []Listed_Brush, keys: []Brush_Key) -> []Listed_Brush {
	out := make([dynamic]Listed_Brush, context.temp_allocator)
	for &k in keys do if l, ok := brush_find(all, brush_key_text(&k)); ok do append(&out, l)
	return out[:]
}

// The tiles, BRUSH_COLUMNS to a row, in a body that scrolls. Returns the item tapped and
// the one long-pressed (or right-clicked).
@(private = "file")
brush_palette_grid :: proc(app: ^App, owner: ui.Id, list: []Listed_Brush, height: f32) -> (tap, press: Maybe(Brush_Item)) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.brushes
	width := ui.PREVIEW_TILE.x * BRUSH_COLUMNS
	ui.begin(ctx, "brush palette grid well", {direction = .Column, width = width, height = height})
	scroll := kit_scroll_begin(ctx, "brush palette grid", &k.grid_scroll, owner, width, height, 0)
	for l, i in list {
		if i % BRUSH_COLUMNS == 0 do ui.begin(ctx, fmt.tprintf("brush palette row %d", i / BRUSH_COLUMNS), {direction = .Row, gap = 0})
		on := brush_item_on(app, l.item)
		res := ui.preview_tile(ctx, fmt.tprintf("%s##%s", l.name, l.key), brush_item_icon(l.item), brush_item_ball(app, l.item), on, brush_item_hint(app, l.item))
		if res.clicked do tap = l.item
		if res.menu do press = l.item
		// Opening, the grid scrolls to the brush held, once the body's height is known.
		if on && l.item.what == .Slot && k.grid_reveal && scroll.natural > 0 {
			k.grid_scroll = clamp(f32(i / BRUSH_COLUMNS) * ui.PREVIEW_TILE.y - (height - ui.PREVIEW_TILE.y) * 0.5, 0, scroll.limit)
		}
		if i % BRUSH_COLUMNS == BRUSH_COLUMNS - 1 || i == len(list) - 1 do ui.end(ctx)
	}
	if len(list) == 0 {
		empty: string
		switch {
		case p.searching:              empty = "No brush has that in its name."
		case p.category == .Recent:    empty = "The brushes you pick show here, the last one first."
		case p.category == .Favorites: empty = "Tap the heart beside the current brush to keep it here."
		case p.category == .Presets:   empty = "Save a brush as a preset (Brush palette, Preset) to find it here."
		case:                          empty = "Nothing here yet."
		}
		ui.paragraph(ctx, empty, width)
	}
	kit_scroll_end(ctx, scroll)
	ui.end(ctx)
	if scroll.natural > 0 do k.grid_reveal = false
	return
}

// The A to Z index down the grid's right, as ZBrush's and iOS's: a tap or a drag on a
// letter scrolls the grid to the first item starting with it, or with the next letter
// that has one. Letters that start no item are faint.
@(private = "file")
brush_palette_index :: proc(app: ^App, list: []Listed_Brush, height: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	first: [26]int
	for &f in first do f = -1
	for l, i in list {
		if len(l.low) == 0 do continue
		c := int(l.low[0]) - 'a'
		if c >= 0 && c < 26 && first[c] < 0 do first[c] = i
	}
	a := ui.area(ctx, "brush index", {BRUSH_INDEX_W, height})
	step := a.rect.h / 26
	held := -1
	if a.held do held = clamp(int((a.mouse.y - a.rect.y) / step), 0, 25)
	for c in 0 ..< 26 {
		y := a.rect.y + step * (f32(c) + 0.5)
		x := a.rect.x + a.rect.w * 0.5
		if c == held do ui.fill_circle(ctx, {x, y}, 10, t.accent)
		color := t.on_accent if c == held else (t.text_secondary if first[c] >= 0 else ui.color_fade(t.text_tertiary, 0.5))
		ui.text(ctx, fmt.tprintf("%c", rune('A' + c)), x, y, t.caption_size, color, .Semibold, .Center)
	}
	if held < 0 do return
	to := -1
	for c in held ..< 26 do if first[c] >= 0 {
		to = first[c]
		break
	}
	if to < 0 do for c := held; c >= 0; c -= 1 do if first[c] >= 0 {
		to = first[c]
		break
	}
	if to < 0 do return
	rows := (len(list) + BRUSH_COLUMNS - 1) / BRUSH_COLUMNS
	k.grid_scroll = clamp(f32(to / BRUSH_COLUMNS) * ui.PREVIEW_TILE.y, 0, max(f32(rows) * ui.PREVIEW_TILE.y - height, 0))
}
