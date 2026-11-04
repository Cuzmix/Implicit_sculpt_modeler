package main

import "core:fmt"
import "core:strings"

import "../ui"

// The floating panels: Stats, History, the Colors card and the thumbnail float as windows
// and cards; Settings, Help and Macros are side panels. Folded, a floating panel keeps its
// header. The cards that hold the controls open in columns beside the docks (column.odin).

// A panel: one of the windows Panel options and Arrange place (a union, as the pinned
// sections once shared it).
Panel_Ref :: union {
	Kit_Window,
}

// The windows that are panels; Settings, Help, Macros and Library stay side panels.
PANEL_WINDOWS :: bit_set[Kit_Window]{.Stats, .History, .Colors, .Thumbnail}

// What a panel was last laid out as: where, and in which frame.
Panel_Seen :: struct {
	ref:    Panel_Ref,
	frame:  int, // the frame it was laid out in; earlier means not shown since
	rect:   ui.Rect,
	faded:  bool, // a stroke passed under it (Lens): it shows faint until the stroke ends
}

// The panels' state in Kit_State.
Panels :: struct {
	seen:    [dynamic; len(Kit_Window)]Panel_Seen,
	// The panel menu (Panel options): open, for which panel, beside what.
	menu:    bool,
	menu_of: Panel_Ref,
	menu_at: ui.Rect,
}

// What panel_begin opened, for the caller's content and panel_end.
Panel_Frame :: struct {
	ref:    Panel_Ref,
	body:   bool, // lay out the content (false while folded)
	closed: bool, // Close was tapped
	raised: bool, // a press landed on it: bring it to the front (floating only)
	dock:   bool, // a card's grip was long pressed (floating cards only)
	// The root container a press on the panel lands in: what a scrolling body inside it
	// is dragged for (kit_scroll_begin's owner).
	owner:  ui.Id,
	// How tall the content may be under the header: the room a floating window has down
	// to the safe area's bottom.
	room:   f32,
	padding, gap: f32, // its box's
	// Where its drawing starts and how opaque it ends up: faint while a stroke passes
	// under it (panel_fade).
	mark:   int,
	fade:   f32,
}

// The panels as a new user finds them: nothing remembered of where they were drawn, and
// the windows in their starting order.
panels_default :: proc(k: ^Kit_State) {
	p := &k.panels
	clear(&p.seen)
	p.menu = false
	k.order = {}
	for w in KIT_WINDOW_ORDER do append(&k.order, Float_Ref(w))
}

// The panel's container name at the root, as its window or card is named when it floats.
panel_name :: proc(ref: Panel_Ref) -> string {
	switch r in ref {
	case Kit_Window:
		names := [Kit_Window]string{.Stats = "stats", .History = "history panel", .Settings = "settings", .Help = "help", .Macros = "macros", .Colors = "colors card", .Thumbnail = "thumbnail"}
		return names[r]
	}
	return ""
}

// A stable id for the panel's own animations (its presence).
panel_id :: proc(ref: Panel_Ref) -> ui.Id {
	return ui.hash_under(0, fmt.tprintf("panel %s", panel_name(ref)))
}

// The window that holds where the panel floats and whether it is folded.
panel_window :: proc(k: ^Kit_State, ref: Panel_Ref) -> ^ui.Window {
	switch r in ref {
	case Kit_Window:  return &k.windows[r]
	}
	return nil
}

// Whether the panel is shown (open), wherever it is.
panel_open :: proc(app: ^App, ref: Panel_Ref) -> bool {
	k := &app.kit
	switch r in ref {
	case Kit_Window:
		#partial switch r {
		case .Stats:     return k.stats
		case .History:   return k.history
		case .Colors:    return k.colors_card
		case .Thumbnail: return k.thumbnail
		}
	}
	return false
}

// Opens or closes the panel.
panel_set_open :: proc(app: ^App, ref: Panel_Ref, open: bool) {
	k := &app.kit
	switch r in ref {
	case Kit_Window:
		#partial switch r {
		case .Stats:     k.stats = open
		case .History:   k.history = open
		case .Colors:    k.colors_card = open
		case .Thumbnail: k.thumbnail = open
		}
	}
}

// Where the panel was laid out this frame (or the last, during the layout); empty when
// it was not.
panel_rect :: proc(app: ^App, ref: Panel_Ref) -> ui.Rect {
	k := &app.kit
	for s in k.panels.seen do if s.ref == ref && s.frame >= k.frame - 1 do return s.rect
	return {}
}

@(private = "file")
panel_seen :: proc(k: ^Kit_State, ref: Panel_Ref) -> ^Panel_Seen {
	for &s in k.panels.seen do if s.ref == ref do return &s
	if len(k.panels.seen) == cap(k.panels.seen) do clear(&k.panels.seen)
	append(&k.panels.seen, Panel_Seen{ref = ref})
	return &k.panels.seen[len(k.panels.seen) - 1]
}

// The panel's name in its header and menus.
panel_title :: proc(app: ^App, ref: Panel_Ref) -> string {
	switch r in ref {
	case Kit_Window:
		#partial switch r {
		case .Stats:     return "Statistics"
		case .History:   return "History"
		case .Colors:    return "Colors"
		case .Thumbnail: return "Thumbnail"
		}
	}
	return ""
}

// Opens panel `ref` as a floating window (or, with `card`, a card titled `title`, "" for
// none) where it floats, with `x`, `y` and `offset` its default anchors as window_begin
// takes them. `box` is its look. End it with panel_end, whatever body says.
panel_begin :: proc(app: ^App, ref: Panel_Ref, title: string, x, y: ui.Anchor, offset: [2]f32, box: ui.Box, close_keys := "", card := false) -> (p: Panel_Frame) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	p.ref, p.padding, p.gap = ref, box.padding, box.gap
	p.mark, p.fade = ui.vertex_mark(ctx), panel_fade(app, panel_seen(k, ref))
	w := panel_window(k, ref)
	name := panel_name(ref)
	p.owner = ui.hash_under(0, name)
	options := false
	head: f32
	if card {
		p.raised, p.dock = ui.card_begin(ctx, name, title, w, x, y, offset, box, &options)
		p.body = true
		head = 18 + box.gap + (40 + box.gap if title != "" else 0)
	} else {
		p.body, p.closed, p.raised = ui.window_begin(ctx, name, title, w, x, y, offset, box, close_keys, &options)
		head = t.target + box.gap
	}
	p.room = window_room(app, w^, offset.y) - head - 2 * box.padding
	if options do panel_menu_open(app, ref)
	return
}

// A panel the pointer passes over during a stroke that began on the viewport
// fades to PANEL_FADED until the stroke ends, so the work under it shows; the stroke
// stays the viewport's all the while. Returns how opaque the panel is now.
panel_fade :: proc(app: ^App, seen: ^Panel_Seen) -> f32 {
	k := &app.kit
	ctx := &k.ctx
	if !ui.viewport_dragging(ctx) || !app.ui.viewport_stroke {
		seen.faded = false
	} else if !seen.faded && seen.frame >= k.frame - 1 && ui.rect_contains(seen.rect, ctx.input.mouse) {
		seen.faded = true
		k.panels_faded += 1
	}
	return ui.tween(ctx, ui.salt(ui.hash_under(0, panel_name(seen.ref)), 0x6a6465), PANEL_FADED if seen.faded else 1, ctx.theme.hover_time)
}

// How opaque a panel a stroke passes under is (the mockups' quarter).
PANEL_FADED :: 0.25

// Ends what panel_begin opened, and remembers where it went.
panel_end :: proc(app: ^App, p: ^Panel_Frame) {
	k := &app.kit
	ctx := &k.ctx
	seen := panel_seen(k, p.ref)
	seen.frame = k.frame
	defer if p.fade < 1 do ui.transform_since(ctx, p.mark, p.fade)
	ui.window_end(ctx)
	seen.rect = ui.last_ended(ctx)
}

// Opens Panel options for `ref`, beside `at` (its header when empty).
panel_menu_open :: proc(app: ^App, ref: Panel_Ref, at := ui.Rect{}) {
	k := &app.kit
	kit_floats_close(k)
	at := at
	if at.w <= 0 {
		r := panel_rect(app, ref)
		t := k.ctx.theme
		at = {r.x + r.w - 3 * t.target - 12, r.y + 12, t.target, t.target}
	}
	k.panels.menu, k.panels.menu_of, k.panels.menu_at = true, ref, at
}

// Panel options: folding a floating panel, and closing it.
kit_panel_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	m := &k.panels
	if !ui.popover_begin(ctx, "panel menu", &m.menu, m.menu_at, .Below, {direction = .Column, padding = 6, width = 248}) do return
	defer ui.popover_end(ctx)
	ref := m.menu_of
	w := panel_window(k, ref)
	picked := false
	ui.caption(ctx, fmt.tprintf("  %s", strings.to_upper(panel_title(app, ref), context.temp_allocator)))
	if ui.menu_item(ctx, "Unfold" if w.minimized else "Fold to its header", glyph = ui.ICON_RESTORE if w.minimized else ui.ICON_MINIMISE) {
		w.minimized = !w.minimized
		picked = true
	}
	ui.divider(ctx, across = true)
	if ui.menu_item(ctx, "Close", glyph = ui.ICON_CLOSE) {
		panel_set_open(app, ref, false)
		picked = true
	}
	if picked do m.menu = false
}

