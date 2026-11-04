package main

import "../ui"

// Motion of the panels (Panels v2): a card slides out from behind the dock that opened it
// and back in when it closes, or aside as another takes its place; on a narrow window its
// sheet rises from the foot and follows a drag down to put it away; a dock slides off the
// edge it stands on as it hides and back as it shows, and fades across when the space
// changes. What leaves is drawn for its last moments from a copy of last frame's drawing
// (ui.copy_prev), so a panel keeps no state between frames and nothing it holds runs
// again. Each kind has its switch (Motion_Kind: Cards, Docks, Spaces), follows the
// Motion level, and costs nothing while nothing moves: the interface's vertices are moved
// on the CPU and the view is not drawn again.

CARD_SLIDE_TIME :: 0.22 // a card out from its dock
CARD_LEAVE_TIME :: 0.18 // a card back behind its dock
CARD_SWAP_TIME :: 0.2 // a card aside as another opens in its column
SHEET_RISE_TIME :: 0.26 // the narrow window's sheet up from the foot
SHEET_BACK_TIME :: 0.2 // a sheet let go short of a third of its height, back up
DOCK_SLIDE_TIME :: 0.24 // a dock off its edge or back
DOCK_STAGGER :: 0.03 // between one dock and the next, so the screen clears without a jolt
SPACE_OUT_TIME :: 0.12 // a dock fading out as the space changes
SPACE_IN_TIME :: 0.18 // and the new space's fading in
CARD_GLIDE_TIME :: 0.26 // a floating card put back, gliding into its column
CARD_LIFT_TIME :: 0.12 // a floating card lifting as it is picked up by its grip
FLOAT_CLOSE_TIME :: 0.16 // a floating card closed, fading where it was
CARD_LIFT :: 0.03 // how much larger a floating card is drawn while carried
DOCK_GLIDE_TIME :: 0.22 // a dock let go gliding from where it was dropped to where it snaps
SLOT_TIME :: 0.2 // an Edit button growing in, shrinking out, or gliding to its new place
// The Edit buttons followed at once, across the docks and bars being edited.
SLOTS_SEEN :: 96

// An Edit button seen: which bar and command it is, where it was drawn last and its
// drawing, and the glide or growth it is in (serial 0 for none).
Slot_Seen :: struct {
	key:    ui.Id,
	which:  Bar_Which,
	rect:   ui.Rect,
	drawn:  ui.Draw_Range,
	from:   ui.Rect,
	serial: u64,
	grow:   bool,
}
// How far a card set aside by another slides, as a share of its width, and how far a dock
// of the new space settles, in points.
CARD_SWAP_SHIFT :: 0.14
SPACE_SETTLE :: 6

// Where a card or a dock was drawn last and which way it goes out: `from` is the unit step
// toward where it hides (behind its dock, off its edge), `dist` how far, and `cut` (when it
// has a width) where it is cut off as it goes behind something.
Panel_Way :: struct {
	from: [2]f32,
	dist: f32,
	cut:  ui.Rect,
}

// One thing drawn for its last moments from a copy.
Panel_Leave :: struct {
	copy:   ui.Draw_Copy,
	way:    Panel_Way,
	serial: u64,
	swap:   bool, // set aside by another rather than closed
	fade:   bool, // fades where it is (a floating dock, a space change)
	time:   f32,
	delay:  f32,
	class:  Motion_Kind,
	active: bool,
}

Panel_Motion :: struct {
	serial:      u64, // one per start, so each start runs its own tween
	cards:       [Card]struct {
		drawn:  ui.Draw_Range,
		way:    Panel_Way,
		side:   Column_Side,
		serial: u64,
		// Where it glides from as it is put back from floating, while it does.
		glide:  ui.Rect,
		gliding: bool,
		// Its drawing as a floating card, for when it closes.
		floated: ui.Draw_Range,
	},
	card_leave:  [Column_Side]Panel_Leave,
	float_leave: Panel_Leave,
	// A floating card just put back, and where it was, for it to glide from.
	glide_card:  Card,
	glide_from:  ui.Rect,
	glide_set:   bool,
	// The narrow window's sheet: how far a drag on its head has pulled it down, and the
	// spring back when it is let go short.
	pull:        f32,
	pulling:     bool,
	pull_card:   Card,
	back_from:   f32,
	back_serial: u64,
	docks:       [Dock_Id]struct {
		drawn:  ui.Draw_Range,
		way:    Panel_Way,
		fade:   bool,
		serial: u64,
		delay:  f32,
		space:  bool, // it came in as the space changed, so it fades in rather than slides
		// Where it was let go, carried, to glide from to where it snapped, while it does.
		glide:  ui.Rect,
		glide_serial: u64,
	},
	// The Edit buttons, the frame each bar last drew them in, and one removed shrinking.
	slots:       [SLOTS_SEEN]Slot_Seen,
	bar_edited:  [Bar_Which]u64,
	slot_leave:  Panel_Leave,
	slot_left:   ui.Rect,
	slot_moves:  int,
	dock_glides: int,
	dock_leave:  [Dock_Id]Panel_Leave,
	switches:    int, // the space switches seen, to tell a space change from a hide
	space_frame: u64, // the frame the space last changed in
	// Exit stats: cards and docks that slid out or in, and sheets put away by a drag.
	slides:      int,
	leaves:      int,
	pulled_away: int,
	glides:      int,
	lifts:       int,
}

panel_motion_destroy :: proc(m: ^Panel_Motion) {
	for &l in m.card_leave do ui.draw_copy_destroy(&l.copy)
	for &l in m.dock_leave do ui.draw_copy_destroy(&l.copy)
	ui.draw_copy_destroy(&m.float_leave.copy)
	ui.draw_copy_destroy(&m.slot_leave.copy)
}

// The share (0 to 1) a start numbered `serial` has run, `time` long, for kind `kind`: 1
// at once when that motion is off.
@(private = "file")
panel_progress :: proc(ctx: ^ui.Context, serial: u64, time: f32, kind: Motion_Kind, delay: f32 = 0) -> f32 {
	return ui.tween_from(ctx, ui.salt(ui.hash_under(0, "panel motion"), serial), 0, 1, time, .Linear, delay, motion_class(kind))
}

@(private = "file")
ease_out :: proc(t: f32) -> f32 {
	return ui.ease(.Out_Cubic, t)
}

@(private = "file")
ease_in :: proc(t: f32) -> f32 {
	return t * t * t
}

// Which way the cards of a column opened from button `at`, on its `side`, go back: behind
// the dock (cut at the button's edge), or down off the window as the narrow window's sheet.
card_way :: proc(app: ^App, at: ui.Rect, side: ui.Side, w, h: f32) -> Panel_Way {
	ctx := &app.kit.ctx
	BIG :: 100000
	if cards_as_sheet(&app.kit) do return {from = {0, 1}, dist = ctx.input.window.y}
	EDGE :: 4
	#partial switch side {
	case .Left:  return {from = {1, 0}, dist = w + CARD_GAP + 8, cut = {-BIG, -BIG, at.x - EDGE + BIG, 2 * BIG}}
	case .Right: return {from = {-1, 0}, dist = w + CARD_GAP + 8, cut = {at.x + at.w + EDGE, -BIG, 2 * BIG, 2 * BIG}}
	case .Below: return {from = {0, -1}, dist = h + CARD_GAP + 8, cut = {-BIG, at.y + at.h + EDGE, 2 * BIG, 2 * BIG}}
	}
	return {from = {0, 1}, dist = h + CARD_GAP + 8, cut = {-BIG, -BIG, 2 * BIG, at.y - EDGE + BIG}}
}

// After card `c` is drawn in column `s` from mark `m`, going back `way`: it slides out from its dock
// the first frames it shows (or rises, as the narrow window's sheet), follows a drag down
// on a sheet, and its drawing is noted for when it leaves.
card_motion_end :: proc(app: ^App, s: Column_Side, c: Card, m: ui.Motion_Mark, r: ui.Rect, way: Panel_Way, fade: f32) {
	k := &app.kit
	ctx := &k.ctx
	pm := &k.moving
	e := &pm.cards[c]
	if !ui.drawn_last(ctx, e.drawn) {
		pm.serial += 1
		e.serial = pm.serial
		e.gliding = pm.glide_set && pm.glide_card == c
		if e.gliding {
			e.glide, pm.glide_set = pm.glide_from, false
			pm.glides += 1
		} else {
			pm.slides += 1
		}
	}
	// A card put back from floating glides from where it floated into its place.
	if e.gliding {
		p := panel_progress(ctx, e.serial, CARD_GLIDE_TIME, .Cards)
		if p >= 1 do e.gliding = false
		else if ctx.motion == .Reduced do ui.slide_since(ctx, m, fade * p)
		else do ui.slide_since(ctx, m, fade, [2]f32{e.glide.x - r.x, e.glide.y - r.y} * (1 - ease_out(p)))
		e.drawn = ui.range_end(ctx, m)
		e.way, e.side = way, s
		return
	}
	sheet := cards_as_sheet(k)
	p := panel_progress(ctx, e.serial, SHEET_RISE_TIME if sheet else CARD_SLIDE_TIME, .Cards)
	shift := way.from * way.dist * (1 - ease_out(p))
	opacity := fade
	if ctx.motion == .Reduced do opacity *= p
	// The sheet held by its head follows the finger down; let go short, it springs back.
	follows := false
	if sheet && pm.pull_card == c {
		pull := pm.pull
		if !pm.pulling && pm.back_serial != 0 {
			b := panel_progress(ctx, pm.back_serial, SHEET_BACK_TIME, .Cards)
			pull = pm.back_from * (1 - ease_out(b))
			if b >= 1 do pm.back_serial = 0
		}
		if pull > 0 do shift.y += pull
		follows = pm.pulling
	}
	ui.slide_since(ctx, m, opacity, shift, way.cut if p < 1 else {}, follows)
	e.drawn = ui.range_end(ctx, m)
	e.way = way
	e.side = s
}

// The narrow window's sheet, card `c` `h` tall, dragged by its head (`held` past the slop):
// it follows the finger down, and let go past a third of its height it is put away,
// otherwise it springs back.
card_sheet_pull :: proc(app: ^App, c: Card, held: bool, h: f32) {
	k := &app.kit
	ctx := &k.ctx
	pm := &k.moving
	if held {
		if pm.pull_card != c do pm.pull = 0
		pm.pull_card, pm.pulling = c, true
		pm.pull = max(ctx.input.mouse.y - ctx.press_mouse.y, 0)
		return
	}
	if !pm.pulling || pm.pull_card != c do return
	pm.pulling = false
	if pm.pull > h / 3 {
		pm.pulled_away += 1
		card_close(app, c)
		return
	}
	pm.serial += 1
	pm.back_serial, pm.back_from, pm.pull = pm.serial, pm.pull, 0
}

// Before column `s` draws: a card it drew last frame and no longer draws (closed, or set
// aside by `fresh`, a card it shows for the first time) slides back behind its dock, or
// aside, from a copy of its last drawing; drawn under what the column shows now.
cards_leaving :: proc(app: ^App, s: Column_Side, now: bit_set[Card], fresh: bool) {
	k := &app.kit
	ctx := &k.ctx
	pm := &k.moving
	l := &pm.card_leave[s]
	for c in Card {
		e := &pm.cards[c]
		if e.side != s || !ui.drawn_last(ctx, e.drawn) || c in now || c in k.cards.floats do continue
		if motion_duration_of(ctx, .Cards) <= 0 || !ui.copy_prev(ctx, e.drawn, &l.copy) do continue
		pm.serial += 1
		pm.leaves += 1
		l.way, l.serial, l.swap, l.fade, l.active, l.delay = e.way, pm.serial, fresh && !cards_as_sheet(k), false, true, 0
		l.time = CARD_SWAP_TIME if l.swap else CARD_LEAVE_TIME
		l.class = .Cards
		// A sheet let go mid-drag was copied where the finger left it.
		if pm.pull_card == c do pm.pull = 0
	}
	panel_leave_draw(app, l)
}

// The share of `kind`'s motion that runs, as a duration: 0 while it is off.
motion_duration_of :: proc(ctx: ^ui.Context, kind: Motion_Kind) -> f32 {
	return ui.motion_duration(ctx, motion_class(kind), 1)
}

// Draws leaving `l` for this frame, and lets it go once it is out.
@(private = "file")
panel_leave_draw :: proc(app: ^App, l: ^Panel_Leave) {
	if !l.active do return
	ctx := &app.kit.ctx
	t := panel_progress(ctx, l.serial, l.time, l.class, l.delay)
	if t >= 1 {
		l.active = false
		return
	}
	m := ui.draw_copy(ctx, &l.copy)
	switch {
	case l.fade:
		ui.slide_since(ctx, m, 1 - t, l.way.from * l.way.dist * ease_out(t))
	case l.swap:
		ui.slide_since(ctx, m, 1 - t, -l.way.from * l.way.dist * CARD_SWAP_SHIFT * ease_out(t))
	case:
		q := ease_in(t)
		opacity: f32 = 1 - t if ctx.motion == .Reduced else 1
		ui.slide_since(ctx, m, opacity, l.way.from * l.way.dist * q, l.way.cut)
	}
}

// Which way dock `id`, drawn at `r`, goes off: toward the window edge it stands by, or
// nowhere for a floating one, which fades.
dock_way :: proc(app: ^App, id: Dock_Id, r: ui.Rect) -> (way: Panel_Way, fade: bool) {
	k := &app.kit
	win := k.ctx.input.window
	edge := dock_edge(k, id)
	if edge == .Float do return {}, true
	if edge == .Top do return {from = {0, -1}, dist = r.y + r.h + 8}, false
	if edge == .Bottom do return {from = {0, 1}, dist = win.y - r.y + 8}, false
	// The left-handed layout mirrors the sides, so the side is read from where it stands.
	if r.x + r.w * 0.5 < win.x * 0.5 do return {from = {-1, 0}, dist = r.x + r.w + 8}, false
	return {from = {1, 0}, dist = win.x - r.x + 8}, false
}

// After dock `id` is drawn from mark `m`: the first frames it shows it slides in from its
// edge (or fades in and settles, as the space changes), and its drawing is noted for when
// it hides.
dock_motion_end :: proc(app: ^App, id: Dock_Id, m: ui.Motion_Mark) {
	k := &app.kit
	ctx := &k.ctx
	pm := &k.moving
	e := &pm.docks[id]
	r := ui.root_rect(ctx, DOCK_ROOTS[id])
	if r.w <= 0 do r = ui.prev_root_rect(ctx, DOCK_ROOTS[id])
	if !ui.drawn_last(ctx, e.drawn) {
		pm.serial += 1
		e.serial = pm.serial
		e.delay = DOCK_STAGGER * f32(id)
		e.space = space_changing(k)
		pm.slides += 1
	}
	// A dock let go where it was carried glides from there into the place it snapped to.
	if e.glide_serial != 0 {
		p := panel_progress(ctx, e.glide_serial, DOCK_GLIDE_TIME, .Docks)
		if p >= 1 do e.glide_serial = 0
		else if ctx.motion != .Reduced && r.w > 0 do ui.slide_since(ctx, m, 1, [2]f32{e.glide.x - r.x, e.glide.y - r.y} * (1 - ease_out(p)))
	} else if e.serial != 0 {
		if e.space {
			p := panel_progress(ctx, e.serial, SPACE_IN_TIME, .Spaces, SPACE_OUT_TIME)
			ui.slide_since(ctx, m, p, {0, SPACE_SETTLE * (1 - ease_out(p))})
		} else {
			p := panel_progress(ctx, e.serial, DOCK_SLIDE_TIME, .Docks, e.delay)
			way, fade := dock_way(app, id, r)
			if fade do ui.slide_since(ctx, m, p)
			else if p < 1 do ui.slide_since(ctx, m, 1 if ctx.motion != .Reduced else p, way.from * way.dist * (1 - ease_out(p)))
		}
	}
	e.drawn = ui.range_end(ctx, m)
	e.way, e.fade = dock_way(app, id, r)
}

// Whether the space changed this frame: what comes and goes then fades across rather than
// sliding off an edge.
@(private = "file")
space_changing :: proc(k: ^Kit_State) -> bool {
	return k.spaces.switches != k.moving.switches || k.moving.space_frame == k.ctx.frame
}

// After every dock: one drawn last frame and not this one slides off its edge from a copy
// of its last drawing, or fades as the space changes.
docks_leaving :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	pm := &k.moving
	space := space_changing(k)
	if k.spaces.switches != pm.switches {
		pm.switches = k.spaces.switches
		pm.space_frame = ctx.frame
	}
	n := 0
	for id in Dock_Id {
		e := &pm.docks[id]
		l := &pm.dock_leave[id]
		if ui.drawn_last(ctx, e.drawn) {
			kind := Motion_Kind.Spaces if space else .Docks
			if motion_duration_of(ctx, kind) > 0 && ui.copy_prev(ctx, e.drawn, &l.copy) {
				pm.serial += 1
				pm.leaves += 1
				l.serial, l.active, l.swap, l.class = pm.serial, true, false, kind
				l.way, l.fade = e.way, e.fade || space
				if space do l.way = {from = {0, -1}, dist = SPACE_SETTLE}
				l.time = SPACE_OUT_TIME if space else DOCK_SLIDE_TIME
				l.delay = 0 if space else DOCK_STAGGER * f32(n)
				n += 1
			}
			e.drawn = {}
		}
		panel_leave_draw(app, l)
	}
}

// Floating card `c` put back in a column from `from`, where it floated: it glides from
// there into its place there (card_motion_end).
card_glide_from :: proc(app: ^App, c: Card, from: ui.Rect) {
	pm := &app.kit.moving
	if from.w <= 0 do return
	pm.glide_card, pm.glide_from, pm.glide_set = c, from, true
}

// After floating card `c` is drawn from mark `m` at `r`, `carried` by its grip: it lifts a
// little while carried, settling as it is let go, and its drawing is noted for when it
// closes.
card_float_motion_end :: proc(app: ^App, c: Card, m: ui.Motion_Mark, r: ui.Rect, carried: bool) {
	k := &app.kit
	ctx := &k.ctx
	pm := &k.moving
	id := ui.salt(ui.hash_under(0, "card lift"), u64(c))
	lift := ui.tween(ctx, id, 1 if carried else 0, CARD_LIFT_TIME, .Out_Quad, class = motion_class(.Cards))
	if lift > 0.001 do ui.transform_since(ctx, m.vertex, 1, 1 + CARD_LIFT * lift, {r.x + r.w * 0.5, r.y + r.h * 0.5}, {0, -2 * lift})
	pm.cards[c].floated = ui.range_end(ctx, m)
}

// After the floating cards: one drawn last frame that no longer floats, and is not in a
// column now (closed rather than put back), fades where it was from a copy.
floats_leaving :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	pm := &k.moving
	l := &pm.float_leave
	for c in Card {
		e := &pm.cards[c]
		if !ui.drawn_last(ctx, e.floated) || c in k.cards.floats do continue
		if _, _, in_column := card_find(k, c); in_column do continue
		if motion_duration_of(ctx, .Cards) <= 0 || !ui.copy_prev(ctx, e.floated, &l.copy) do continue
		pm.serial += 1
		pm.leaves += 1
		l^ = {copy = l.copy, serial = pm.serial, fade = true, time = FLOAT_CLOSE_TIME, class = .Cards, active = true}
	}
	panel_leave_draw(app, l)
}

// Dock `id` let go where it was carried, its outline at `box`: it glides from there to
// where it snaps (dock_motion_end), unless that is where it already stands.
dock_glide_from :: proc(app: ^App, id: Dock_Id, box: ui.Rect) {
	pm := &app.kit.moving
	if motion_duration_of(&app.kit.ctx, .Docks) <= 0 do return
	pm.serial += 1
	pm.docks[id].glide, pm.docks[id].glide_serial = box, pm.serial
	pm.dock_glides += 1
}

// The Edit button for `s` on bar `which`, keyed by both, so one moved to another slot is
// still the same button.
@(private = "file")
slot_seen :: proc(pm: ^Panel_Motion, which: Bar_Which, s: Bar_Slot) -> ^Slot_Seen {
	key := ui.salt(ui.salt(ui.hash_under(0, "edit slot"), u64(which) << 32 | u64(s.id)), u64(s.arg))
	for &e in pm.slots do if e.key == key do return &e
	// Otherwise the one drawn longest ago makes room.
	oldest := &pm.slots[0]
	for &e in pm.slots do if e.drawn.frame < oldest.drawn.frame do oldest = &e
	oldest^ = {key = key, which = which}
	return oldest
}

// After Edit button `s` on bar `which` is drawn from mark `m` at `at`: one added grows into
// the gap it opened, and one whose place changed (a neighbour added, removed or moved)
// glides there from where it stood.
slot_motion_end :: proc(app: ^App, which: Bar_Which, s: Bar_Slot, m: ui.Motion_Mark, at: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	pm := &k.moving
	edited := pm.bar_edited[which] != 0 && pm.bar_edited[which] + 1 >= ctx.frame
	pm.bar_edited[which] = ctx.frame
	// Places are kept relative to the dock, so the dock itself moving (dropped, sliding,
	// growing a line) moves its buttons with it rather than gliding each.
	root := ui.open_root_rect(ctx)
	r := ui.Rect{at.x - root.x, at.y - root.y, at.w, at.h}
	e := slot_seen(pm, which, s)
	if ui.drawn_last(ctx, e.drawn) {
		if abs(e.rect.x - r.x) > 0.5 || abs(e.rect.y - r.y) > 0.5 {
			pm.serial += 1
			e.from, e.serial, e.grow = e.rect, pm.serial, false
			pm.slot_moves += 1
		}
	} else if edited && e.drawn.frame != ctx.frame {
		pm.serial += 1
		e.serial, e.grow = pm.serial, true
		pm.slot_moves += 1
	}
	if e.serial != 0 {
		p := panel_progress(ctx, e.serial, SLOT_TIME, .Docks)
		q := ease_out(p)
		switch {
		case p >= 1: e.serial = 0
		case e.grow: ui.transform_since(ctx, m.vertex, q, 0.5 + 0.5 * q, {root.x + r.x + r.w * 0.5, root.y + r.y + r.h * 0.5})
		case:        ui.transform_since(ctx, m.vertex, 1, 1, {}, [2]f32{e.from.x - r.x, e.from.y - r.y} * (1 - q))
		}
	}
	e.rect = r
	e.drawn = ui.range_end(ctx, m)
}

// After bar `which`'s Edit buttons: one it drew last frame and no longer draws (removed)
// shrinks where it stood from a copy, as its neighbours close up.
bar_slots_leaving :: proc(app: ^App, which: Bar_Which) {
	k := &app.kit
	ctx := &k.ctx
	pm := &k.moving
	l := &pm.slot_leave
	if pm.bar_edited[which] == ctx.frame {
		for &e in pm.slots {
			if e.which != which || e.key == 0 || !ui.drawn_last(ctx, e.drawn) do continue
			if motion_duration_of(ctx, .Docks) <= 0 || !ui.copy_prev(ctx, e.drawn, &l.copy) do continue
			pm.serial += 1
			pm.slot_moves += 1
			l^ = {copy = l.copy, serial = pm.serial, time = SLOT_TIME, class = .Docks, active = true}
			// It shrinks about where it stood in the dock as the dock stands now.
			root := ui.open_root_rect(ctx)
			pm.slot_left = {root.x + e.rect.x, root.y + e.rect.y, e.rect.w, e.rect.h}
			e.drawn = {}
		}
	}
	if !l.active do return
	t := panel_progress(ctx, l.serial, l.time, l.class)
	if t >= 1 {
		l.active = false
		return
	}
	r := pm.slot_left
	m := ui.draw_copy(ctx, &l.copy)
	ui.transform_since(ctx, m.vertex, 1 - t, 1 - 0.5 * ease_out(t), {r.x + r.w * 0.5, r.y + r.h * 0.5})
}
