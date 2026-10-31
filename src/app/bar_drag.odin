package main

import "core:fmt"

import "../ui"

// Drag and drop on the bars, as a home screen's icons move: a button held still for a long
// press and then moved is lifted (ui.lift; in Customise bars any drag lifts it), carried
// under the pointer, and let go between two buttons of the same bar or another it goes
// there, the bar it would join lit at the place, or ringed in the warning colour when it
// is full or does not take it. Let go clear of every bar, it comes off its bar, with Undo
// on the note. A row of Search lifts the same way and lets go onto a bar as Put on a bar
// does, only where it is let go. Each bar's buttons say where they are as they are drawn
// (bar_spot), and the carry is followed once every bar and Search are drawn.

// What is carried: the command and how a value item shows, and the bar and slot it came
// from (nil for one from Search).
Bar_Carry :: struct {
	slot:      Bar_Slot,
	look:      Value_Look,
	from:      Maybe(Bar_Which),
	from_slot: int,
}

// Where a bar's button stood this frame: slot `slot` of bar `which` (`end` for the bar's
// Add button, which puts a carried button last).
Bar_Spot :: struct {
	which: Bar_Which,
	slot:  int,
	rect:  ui.Rect,
	end:   bool,
}

BAR_SPOTS_MAX :: 256

// Where a carried button would go: bar `which` before slot `at`, the rect of the button it
// lands next to, and whether the bar takes it there (`why` says why not).
Bar_Target :: struct {
	which: Bar_Which,
	at:    int,
	rect:  ui.Rect,
	after: bool,
	ok:    bool,
	why:   string,
}

// The button the last drop took off its bar, for its note's Undo.
Bar_Removed :: struct {
	carry:  Bar_Carry,
	serial: ui.Id,
}

// Notes where slot `slot` of bar `which` stands this frame, as a place to let a carried
// button go.
bar_spot :: proc(app: ^App, which: Bar_Which, slot: int, r: ui.Rect, end := false) {
	k := &app.kit
	if k.bar_spot_count >= BAR_SPOTS_MAX || r.w <= 0 do return
	k.bar_spots[k.bar_spot_count] = {which, slot, r, end}
	k.bar_spot_count += 1
}

// After the button just drawn for slot `slot` of bar `which` (holding `s`, shown in
// `look`): lifts it when its press says so, and notes where it stands.
bar_slot_lift :: proc(app: ^App, which: Bar_Which, slot: int, s: Bar_Slot, look := Value_Look.Chip) {
	k := &app.kit
	ctx := &k.ctx
	r := ctx.last_rect
	bar_spot(app, which, slot, r)
	if k.bar_carry == nil && ctx.last_id != 0 && ui.lift(ctx, k.bars_edit) do bar_lift(app, {slot = s, look = look, from = which, from_slot = slot})
}

// Starts carrying `c`: whatever its long press opened closes, as the finger has moved on;
// Search, which a row is carried out of, stays until it lands.
bar_lift :: proc(app: ^App, c: Bar_Carry) {
	k := &app.kit
	if c.from != nil do kit_floats_close(k)
	k.shelf.quick = false
	k.bar_carry = c
	k.bar_lifts += 1
	haptic(app, .Alignment)
}

// Whether bar `which` takes command `s`: a brush only on the shelf's pages and the person's
// docks, which show brushes; a brush value anywhere a value item shows (not the brush pie,
// which holds brushes); any other command a bar lists anywhere but the brush pie.
bar_takes :: proc(which: Bar_Which, s: Bar_Slot) -> (ok: bool, why: string) {
	if which == .Brush_Pie do return false, "the brush pie is set in its editor"
	if !bar_lists(s.id) do return false, "it is not a button"
	_, page := shelf_page_of(which)
	_, dock := user_dock_of(which)
	if s.id == .Brush && !page && !dock do return false, "brushes go on the shelf or a dock"
	return true, ""
}

// Where carried `c` would go with the pointer at `p`, among this frame's `spots`: before
// the button under it or after it, whichever half the pointer is in along the bar.
bar_target :: proc(app: ^App, c: Bar_Carry, spots: []Bar_Spot, p: [2]f32) -> (t: Bar_Target, found: bool) {
	for sp in spots {
		if !ui.rect_contains(sp.rect, p) do continue
		t = {which = sp.which, at = sp.slot, rect = sp.rect}
		if !sp.end {
			column := bar_column(sp.which)
			mid := sp.rect.y + sp.rect.h * 0.5 if column else sp.rect.x + sp.rect.w * 0.5
			along := p.y if column else p.x
			if along > mid do t.at, t.after = sp.slot + 1, true
		}
		t.ok, t.why = bar_takes(sp.which, c.slot)
		same := c.from != nil && c.from.? == sp.which
		if t.ok && !same {
			if bar_count(app, sp.which)^ >= bar_capacity(sp.which) {
				t.ok, t.why = false, "it is full"
			} else {
				for u in bar_used(app, sp.which) do if u == c.slot {
					t.ok, t.why = false, fmt.tprintf("it has %s already", bar_label(c.slot))
					break
				}
			}
		}
		return t, true
	}
	return {}, false
}

// Lets carried `c` go at target `t`: moved within its bar, or put on the target's bar and
// taken off its own. Returns whether it went.
bar_drop :: proc(app: ^App, c: Bar_Carry, t: Bar_Target) -> bool {
	if !t.ok {
		report(app, nil, {.Warning}, "%s does not take %s: %s", bar_title(app, t.which), bar_label(c.slot), t.why)
		return false
	}
	at := t.at
	if from, ok := c.from.?; ok && from == t.which {
		// Within its own bar: out of its place, then in before the button it was let go by,
		// which is one earlier when it came from before it.
		if at > c.from_slot do at -= 1
		if at == c.from_slot do return true
		bar_remove(app, from, c.from_slot)
		if !bar_insert(app, from, at) do return false
		bar_set(app, from, at, c)
		return true
	}
	if !bar_insert(app, t.which, at) do return false
	bar_set(app, t.which, clamp(at, 0, bar_count(app, t.which)^ - 1), c)
	if from, ok := c.from.?; ok do bar_remove(app, from, c.from_slot)
	report(app, nil, {}, "%s now has %s", bar_title(app, t.which), bar_label(c.slot))
	return true
}

// Fills slot `at` of bar `which` with carried `c`, a value keeping how it showed where
// that bar can show it so.
@(private = "file")
bar_set :: proc(app: ^App, which: Bar_Which, at: int, c: Bar_Carry) {
	l := bar_list(app, which)
	l.slots[at] = c.slot
	l.looks[at] = c.look if c.look != .Slider || bar_offers_slider(which) else bar_default_look(which)
	if c.from == nil do l.looks[at] = bar_default_look(which)
}

// Takes carried `c` off its bar, let go clear of every bar, with Undo on the note.
bar_drop_off :: proc(app: ^App, c: Bar_Carry) {
	from, ok := c.from.?
	if !ok do return
	k := &app.kit
	bar_remove(app, from, c.from_slot)
	k.bar_removed = {carry = c, serial = ui.toast(&k.ctx, fmt.tprintf("%s came off %s", bar_label(c.slot), bar_title(app, from)), .Info, "Undo")}
	k.bar_drops_off += 1
}

// Puts back the button the last drop took off its bar, where it was.
bar_removed_undo :: proc(app: ^App) {
	k := &app.kit
	c := k.bar_removed.carry
	k.bar_removed = {}
	from, ok := c.from.?
	if !ok || !bar_insert(app, from, c.from_slot) do return
	bar_set(app, from, clamp(c.from_slot, 0, bar_count(app, from)^ - 1), c)
	l := bar_list(app, from)
	l.looks[clamp(c.from_slot, 0, bar_count(app, from)^ - 1)] = c.look
}

// Follows the carried button once every bar and Search are drawn: it shows under the
// pointer, with the place it would go lit; let go, it goes there, or off its bar.
bar_carry_update :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	c, carrying := k.bar_carry.?
	if !carrying do return
	in_ := ctx.input
	if in_.cancel {
		k.bar_carry = nil
		return
	}
	spots := k.bar_spots[:k.bar_spot_count]
	target, over := bar_target(app, c, spots, in_.mouse)
	if .Left in in_.down {
		// The place it would go: a bar between two buttons, across the bar; or the button's
		// ring in the warning colour where it would be refused.
		if over {
			r := target.rect
			if !target.ok {
				ui.stroke_rect(ctx, r, t.radius_medium, t.warning, 2)
			} else if bar_column(target.which) {
				y := r.y + r.h if target.after else r.y
				ui.fill_rect(ctx, {r.x + 4, y - 1.5, r.w - 8, 3}, 1.5, t.accent)
			} else {
				x := r.x + r.w if target.after else r.x
				ui.fill_rect(ctx, {x - 1.5, r.y + 4, 3, r.h - 8}, 1.5, t.accent)
			}
		}
		label := bar_label(c.slot)
		off := !over && c.from != nil
		if off do label = fmt.tprintf("Remove %s", label)
		w := ui.text_width(ctx, label, t.small_size, .Semibold) + 44
		// Above the finger, which would cover it, and kept in the window by the rail's edge.
		area := ui.safe_area(ctx)
		r := ui.Rect{clamp(in_.mouse.x - w * 0.5, area.x + 4, max(area.x + area.w - w - 4, area.x + 4)), max(in_.mouse.y - 64, area.y + 4), w, 36}
		ui.begin_at(ctx, "bar carry", {r.x, r.y}, {width = r.w, height = r.h, inert = true})
		ui.fill_rect(ctx, r, t.radius_medium, t.frame)
		ui.stroke_rect(ctx, r, t.radius_medium, t.warning if off || (over && !target.ok) else t.accent, 1.5)
		ui.icon(ctx, ui.ICON_TRASH if off else bar_icon(c.slot), {r.x + 18, r.y + r.h * 0.5}, t.icon_small, t.text)
		ui.text(ctx, label, r.x + 32, r.y + r.h * 0.5, t.small_size, t.text, .Semibold)
		ui.end(ctx)
		return
	}
	k.bar_carry = nil
	switch {
	case over:
		if bar_drop(app, c, target) {
			k.bar_drops += 1
			if c.from == nil && k.palette do palette_close(app)
		} else {
			k.bar_refusals += 1
		}
	case c.from != nil:
		bar_drop_off(app, c)
	}
}
