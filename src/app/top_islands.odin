package main

import "core:fmt"
import "core:strings"

import "../ui"

// The top bar's three islands as wholes (Arrange's R3): the file island (the menu, the file
// and Undo and Redo), the work island (the spaces and the object chip) and the app island
// (Search, History and Settings) each stand in one of the bar's three places, its start
// corner, its middle on the window's centre line and its end corner. Arrange carries an
// island by its grip and snaps it to the place nearest the pointer, the island there
// taking the carried one's old place, so the three always fill the three places. Sections
// still come out of an island one by one to stand alone (chip_islands.odin). The order is a
// setting, as the sections' islands are: the bar holds the spaces' tabs, so it stays the
// same in every space and workspace. It counts from the start side, so the kit's mirror
// flips it for a left hand.

Top_Island :: enum u8 {
	File, // the menu, the file and Undo and Redo
	Work, // the space tabs and the object chip
	App, // Search, History and Settings
}

// Each island's name in the `top_order` line and the exit stats.
@(rodata)
TOP_ISLAND_NAMES := [Top_Island]string {
	.File = "file",
	.Work = "work",
	.App  = "app",
}

// Each island as its grip's tip names it.
@(rodata)
TOP_ISLAND_LABELS := [Top_Island]string {
	.File = "the file and Undo",
	.Work = "the spaces and the object",
	.App  = "Search and Settings",
}

// Each island's root in the bar's row, which its drawn width is read back from.
@(rodata)
TOP_ISLAND_ROOTS := [Top_Island]string {
	.File = "file island",
	.Work = "work island",
	.App  = "app island",
}

// The islands from the start corner to the end corner, as the bar comes.
TOP_ORDER_DEFAULT :: [3]Top_Island{.File, .Work, .App}

// The grip each island leads with while arranging, in points.
TOP_GRIP_W :: 24

// The islands in the bar's three places: the setting when it holds each island once (a
// fresh Kit_State's zeros do not), else the bar as it comes.
top_order :: proc(k: ^Kit_State) -> [3]Top_Island {
	return k.top_order if top_order_valid(k.top_order) else TOP_ORDER_DEFAULT
}

// Whether `o` holds each island exactly once.
top_order_valid :: proc(o: [3]Top_Island) -> bool {
	seen: bit_set[Top_Island]
	for i in o {
		if i in seen do return false
		seen += {i}
	}
	return card(seen) == 3
}

// The bar's place (0 the start corner, 1 the middle, 2 the end corner) a pointer at screen
// x `x` snaps an island to over the bar `bar`: its nearest third, counted from the start
// side, which a mirrored kit puts at the right.
top_island_slot :: proc(bar: ui.Rect, x: f32, mirror: bool) -> int {
	if bar.w <= 0 do return 1
	rel := (x - bar.x) / bar.w
	slot := 0 if rel < 1.0 / 3 else (2 if rel > 2.0 / 3 else 1)
	return 2 - slot if mirror else slot
}

// `o` with island `isl` put in place `slot`, the island that stood there taking isl's
// old place.
top_order_put :: proc(o: [3]Top_Island, isl: Top_Island, slot: int) -> [3]Top_Island {
	out := o
	for x, i in o do if x == isl {
		out[i], out[slot] = o[slot], isl
		break
	}
	return out
}

// The grip an island leads with while arranging: a drag past the slop carries the whole
// island, and let go it snaps to the bar's place nearest the pointer. A tap does nothing.
top_island_grip :: proc(app: ^App, isl: Top_Island) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	st := &k.arrange
	a := ui.area(ctx, fmt.tprintf("Move %s##grip %s", TOP_ISLAND_LABELS[isl], TOP_ISLAND_NAMES[isl]), {TOP_GRIP_W, t.target}, drag = true)
	carried, has := st.island_carry.?
	lit := a.hovered || (has && carried == isl)
	ui.icon(ctx, ui.ICON_GRIP, {a.rect.x + a.rect.w * 0.5, a.rect.y + a.rect.h * 0.5}, t.icon_small, t.accent if lit else t.text_tertiary)
	ui.tip(ctx, a.id, a.rect, fmt.tprintf("Drag to move %s to the bar's left, middle or right", TOP_ISLAND_LABELS[isl]))
	if a.pressed {
		st.carry, st.chip_carry = nil, nil
		st.island_carry, st.carry_from, st.carry_press, st.carrying = isl, k.top_island_at[isl], a.mouse, false
		return
	}
	if !has || carried != isl do return
	if a.held {
		d := a.mouse - st.carry_press
		if !st.carrying && d.x * d.x + d.y * d.y > t.slop * t.slop {
			st.carrying = true
			ui.long_cancel(ctx)
		}
		return
	}
	if st.carrying {
		slot := top_island_slot(ui.prev_root_rect(ctx, "top bar"), a.mouse.x, ctx.mirror)
		k.top_order = top_order_put(top_order(k), isl, slot)
		st.island_carries += 1
	}
	st.island_carry, st.carrying = nil, false
}

// While an island is carried: its outline under the pointer, and the island standing in
// the place it would snap to ringed, as the one that will trade places with it. Returns
// whether an island is carried, for the Library to step aside.
arrange_top_islands :: proc(app: ^App) -> (carrying: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	st := &k.arrange
	_, has := st.island_carry.?
	if !has || !st.carrying do return false
	m := ctx.input.mouse
	from := st.carry_from
	ui.stroke_rect(ctx, {from.x - 2 + m.x - st.carry_press.x, from.y - 2 + m.y - st.carry_press.y, from.w + 4, from.h + 4}, t.radius_large + 2, t.accent, 2)
	slot := top_island_slot(ui.prev_root_rect(ctx, "top bar"), m.x, ctx.mirror)
	there := top_order(k)[slot]
	if r := k.top_island_at[there]; r.w > 0 do ui.stroke_rect(ctx, {r.x - 2, r.y - 2, r.w + 4, r.h + 4}, t.radius_large + 2, ui.color_fade(t.accent, 0.6), 2)
	return true
}

// The settings file's `top_order <start> <middle> <end>` line, written only when the
// islands stand other than as the bar comes.
top_order_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	o := top_order(k)
	if o == TOP_ORDER_DEFAULT do return
	fmt.sbprintfln(out, "top_order %s %s %s", TOP_ISLAND_NAMES[o[0]], TOP_ISLAND_NAMES[o[1]], TOP_ISLAND_NAMES[o[2]])
}

// Reads a `top_order` line; one that does not name each island once leaves the bar as it
// comes.
top_order_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) != 4 do return
	o: [3]Top_Island
	for i in 0 ..< 3 {
		found := false
		for name, isl in TOP_ISLAND_NAMES do if name == f[i + 1] {
			o[i], found = isl, true
		}
		if !found do return
	}
	if top_order_valid(o) do k.top_order = o
}

// The order for the exit stats: `file,work,app` as the bar comes.
top_order_text :: proc(k: ^Kit_State) -> string {
	o := top_order(k)
	return fmt.tprintf("%s,%s,%s", TOP_ISLAND_NAMES[o[0]], TOP_ISLAND_NAMES[o[1]], TOP_ISLAND_NAMES[o[2]])
}
