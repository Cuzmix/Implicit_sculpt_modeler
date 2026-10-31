package main

import "core:fmt"
import "core:path/filepath"
import "core:time"

import "../sculpt"
import "../ui"

// The History panel's list (History revamp H1, after Nomad's): every step as a row, newest
// at the top, with its number, a bar and icon in its kind's colour, what it was and on which
// object, how long ago, and what it holds. Undone steps stay at the top, faded, until a new
// step replaces them; the step the scene stands at is lit ("you are here"). Strokes of one
// brush on one object in a row read as one line with × N, which opens to show each; each
// still undoes on its own. The last row is where the History starts, with how many older
// steps the limits dropped. A tap on a row goes there through the timeline, which undoes
// and redoes as Ctrl+Z would.

// One row of the list: a step (with the entries chained to it), a group of repeated
// strokes, or one stroke of an opened group. Steps are entry indices, oldest first, as the
// timeline counts them: `head` is the row's newest step's first entry and `last` its last
// (chained) one; a group runs from `oldest` (its oldest step's first entry) to `last`.
History_Row :: struct {
	head, last, oldest: int,
	count:              int, // steps in a group; 1 otherwise
	sub:                bool, // a stroke under its opened group
	open:               bool, // a group that is open
}

// A row's height, a group's stroke's, and the gap under each, in points.
HISTORY_ROW_H :: 50
HISTORY_SUB_H :: 38
HISTORY_ROW_GAP :: 2
// The list's width.
KIT_HISTORY_LIST_W :: 400

// The entry at timeline position `i` (0 is the oldest done step, done and undone counted
// as the timeline counts them).
history_entry_at :: proc(app: ^App, i: int) -> History_Entry {
	done, total := len(app.history.done), history_total(app)
	return app.history.done[i] if i < done else app.history.undone[total - 1 - i]
}

// The list's rows, newest first: each step's first entry with the entries chained to it,
// repeated strokes grouped unless `group` is false (with an opened group's strokes after
// it), only the selected object's with `only` set to its id.
history_rows :: proc(app: ^App, only := -1, open_at := time.Tick{}, group := true) -> [dynamic]History_Row {
	rows := make([dynamic]History_Row, 0, 64, context.temp_allocator)
	done, total := len(app.history.done), history_total(app)
	// Each step as [head, last], newest first.
	steps := make([dynamic][2]int, 0, total, context.temp_allocator)
	last := total - 1
	for i := total - 1; i >= 0; i -= 1 {
		if history_entry_at(app, i).chain && i > 0 do continue
		append(&steps, [2]int{i, last})
		last = i - 1
	}
	for n := 0; n < len(steps); {
		first := steps[n]
		e := history_entry_at(app, first[0])
		// The run of strokes like it: one brush, one object, on the same side of where the
		// History stands, none adjusted (an adjusted stroke reads on its own).
		m := n + 1
		for group && m < len(steps) {
			o := history_entry_at(app, steps[m][0])
			if !history_same_stroke(e, o) || (steps[m][0] < done) != (first[0] < done) do break
			m += 1
		}
		if only >= 0 && e.id != only {
			n = m
			continue
		}
		if m - n == 1 {
			append(&rows, History_Row{head = first[0], last = first[1], oldest = first[0], count = 1})
			n = m
			continue
		}
		// A group is known by its oldest stroke, which stays its own while newer ones are
		// undone or added.
		open := open_at != {} && history_entry_at(app, steps[m - 1][0]).at == open_at
		append(&rows, History_Row{head = first[0], last = first[1], oldest = steps[m - 1][0], count = m - n, open = open})
		if open do for j in n ..< m do append(&rows, History_Row{head = steps[j][0], last = steps[j][1], oldest = steps[j][0], count = 1, sub = true})
		n = m
	}
	return rows
}

// Whether two steps are strokes the list groups: one brush on one object, neither adjusted
// nor bookmarked (each reads on its own, so its amount or name shows).
history_same_stroke :: proc(a, b: History_Entry) -> bool {
	return a.kind == .Stroke && b.kind == .Stroke && a.id == b.id && a.what == b.what && !a.adjusted && !b.adjusted && a.bookmark == "" && b.bookmark == ""
}

// What the History holds in all, in bytes, and how near it is to dropping its oldest steps,
// 0 to 1: against History may use when it is set, else its fullest store against its own
// limit (the swap snapshots and texture steps, and each sculptor's strokes).
history_memory :: proc(app: ^App) -> (bytes: int, full: f32) {
	h := &app.history
	limit := h.swap_limit if h.swap_limit > 0 else SWAP_LIMIT_BYTES
	bytes = h.swap_bytes
	full = f32(h.swap_bytes) / f32(limit)
	for obj in app.scene.objects {
		if obj.voxel != nil {
			bytes += obj.voxel.clay.history.bytes
			continue
		}
		add :: proc(s: ^sculpt.Sculptor, bytes: ^int, full: ^f32) {
			bytes^ += s.history.bytes
			if s.history.limit > 0 do full^ = max(full^, f32(s.history.bytes) / f32(s.history.limit))
		}
		for lv in obj.levels.levels do add(&lv.sculptor, &bytes, &full)
		if object_in_hd(obj) do add(&obj.levels.hd.window.sculptor, &bytes, &full)
	}
	if app.history_limit_mb > 0 do full = f32(bytes) / f32(int(app.history_limit_mb) << 20)
	return bytes, clamp(full, 0, 1)
}

// The list view: the memory line, the rows in a scrolling body as tall as the window has
// room for, and the playback buttons under them.
kit_history_list :: proc(app: ^App, p: ^Panel_Frame, width: f32, can: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	tl := &app.timeline
	inner := width - 20
	// The memory line: steps and bytes (of History may use, when set), and a meter of how
	// near the History is to its limit.
	steps := history_step_count(app.history.done[:]) + history_step_count(app.history.undone[:])
	bytes, full := history_memory(app)
	link := "Limits in Settings"
	lw := ui.text_width(ctx, link, t.small_size) + 8
	ui.begin(ctx, "history memory", {direction = .Row, width = inner, center = true})
	r := ui.place(ctx, {inner - lw, 18})
	of := fmt.tprintf(" of %s", bytes_label(int(app.history_limit_mb) << 20)) if app.history_limit_mb > 0 else ""
	ui.text(ctx, fmt.tprintf("%d step%s · %s%s", steps, "" if steps == 1 else "s", bytes_label(bytes), of), r.x, r.y + r.h * 0.5, t.small_size, t.text_secondary)
	// It opens the Settings page, where the limits are.
	la := ui.area(ctx, "Limits in Settings##history", {lw, 18}, drag = false)
	ui.text(ctx, link, la.rect.x + la.rect.w, la.rect.y + la.rect.h * 0.5, t.small_size, t.accent if la.hovered else t.text_tertiary, .Regular, .Right)
	if la.clicked do tl.settings = true
	ui.end(ctx)
	meter := ui.place(ctx, {inner, 5})
	ui.fill_rect(ctx, meter, 2.5, t.track)
	if full > 0 do ui.fill_rect(ctx, {meter.x, meter.y, max(meter.w * full, 5), meter.h}, 2.5, overlay_color(KIND_COLORS[.Stroke]) if full < 0.8 else t.warning)

	only := -1
	if tl.only_selected {
		if obj := selected_object(app); obj != nil do only = obj.id
	}
	rows := history_rows(app, only, tl.open_at, !app.history_ungrouped)
	natural: f32 = HISTORY_ROW_H + HISTORY_ROW_GAP // the first row of all, where the History starts
	for row in rows do natural += (HISTORY_SUB_H if row.sub else HISTORY_ROW_H) + HISTORY_ROW_GAP
	// The rows take what the window has left under its head, the memory line and the
	// playback buttons.
	room := max(p.room - 4 * t.target - 40, 3 * HISTORY_ROW_H)
	height := min(natural, room)
	s := kit_scroll_begin(ctx, "history rows", &tl.list_scroll, p.owner, inner, height, 0, fixed = true)
	// Only the rows in sight are laid out; spacers stand for the rest, so a History of
	// hundreds of steps costs what a screenful does.
	top, bottom := s.shown, s.shown + height
	recall := recall_marker(app)
	y: f32 = 0
	skipped: f32 = 0
	for row in rows {
		h := f32(HISTORY_SUB_H if row.sub else HISTORY_ROW_H) + HISTORY_ROW_GAP
		if y + h < top || y > bottom {
			skipped += h
		} else {
			if skipped > 0 do ui.spacer(ctx, skipped)
			skipped = 0
			history_row(app, row, inner, can, recall)
		}
		y += h
	}
	if skipped > 0 do ui.spacer(ctx, skipped)
	history_root_row(app, inner, can)
	kit_scroll_end(ctx, s)
	history_transport(app, can)
}

// Lucide's list, columns-3, layers and file: the List and Strip views, a layer's step and
// the first row.
ICON_HISTORY_LIST :: rune(0xe10c)
ICON_HISTORY_STRIP :: rune(0xe09d)
ICON_LAYERS :: rune(0xe104)
ICON_FILE :: rune(0xe0c4)

// A row's kind glyph.
@(rodata)
KIND_GLYPHS := [History_Kind]rune {
	.Stroke    = ui.ICON_BRUSH,
	.Mask      = ICON_CIRCLE_DASHED,
	.Hide      = ui.ICON_EYE_OFF,
	.Deform    = ui.ICON_WAND,
	.Rebuild   = ICON_REMESH,
	.Paint     = ui.ICON_PAINTBRUSH,
	.Layer     = ICON_LAYERS,
	.Transform = ui.ICON_MOVE,
	.Arrange   = ui.ICON_FOLDER,
	.Textures  = ui.ICON_IMAGE,
	.Lights    = ui.ICON_SUN,
	.Model     = ICON_CAGE,
	.Curve     = ui.ICON_SPLINE,
}

// One row: a tap goes to its step (a group's newest), a long press, a right click or the
// pen's side button opens its menu, and a group's chevron opens or closes it. The row
// holding `recall`, the step the History brush paints back to, shows the brush.
@(private = "file")
history_row :: proc(app: ^App, row: History_Row, width: f32, can: bool, recall: int) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	tl := &app.timeline
	done := len(app.history.done)
	e := history_entry_at(app, row.head)
	h: f32 = HISTORY_SUB_H if row.sub else HISTORY_ROW_H
	group := row.count > 1
	undone := row.head >= done
	current := row.last == done - 1
	ui.begin(ctx, fmt.tprintf("history row %d %v", row.head, row.sub), {direction = .Row, width = width})
	chevron: f32 = t.target if group else 0
	a := ui.area(ctx, fmt.tprintf("Step %d##history row %v", row.head + 1, row.sub), {width - chevron, h}, drag = false)
	if ui.secondary(ctx) && can do history_menu_open(app, row.head, {a.mouse.x, a.mouse.y, 1, 1}, .Pointer)
	// Resting on a row or pressing it shows what its step changed; a finger has no rest,
	// so only its press does.
	if (a.hovered && ctx.input.pointer != .Finger) || a.held do history_tint_rest(app, e.at)
	box := ui.Rect{a.rect.x, a.rect.y, width, h}
	if current {
		ui.fill_rect(ctx, box, t.radius_medium, ui.color_fade(t.accent, 0.16))
		ui.stroke_rect(ctx, box, t.radius_medium, ui.color_fade(t.accent, 0.45), 1)
	} else if a.held {
		ui.fill_rect(ctx, box, t.radius_medium, t.fill_pressed)
	} else if a.hovered {
		ui.fill_rect(ctx, box, t.radius_medium, t.fill_hover)
	}
	fade: f32 = 0.42 if undone else 1
	colour := ui.color_fade(overlay_color(KIND_COLORS[e.kind]), fade)
	x := box.x + (28 if row.sub else 0)
	mid := box.y + h * 0.5
	if !row.sub do ui.text(ctx, fmt.tprintf("%d", row.head + 1), x + 24, mid, t.caption_size, ui.color_fade(t.text_tertiary, fade), .Regular, .Right)
	bar_h: f32 = 18 if row.sub else 28
	ui.fill_rect(ctx, {x + 32, mid - bar_h * 0.5, 4, bar_h}, 2, colour)
	tx := x + 66
	// With Step pictures in the list, the step's picture stands where its icon would, a
	// little wider than a row is tall; a step with none (the lights) keeps its icon.
	pic: f32 = 30 if row.sub else 42
	if app.history_pictures && step_picture_draw(app, e.at, {x + 42, mid - pic * 0.5, pic, pic}, fade) {
		tx = x + 50 + pic
	} else {
		ui.icon(ctx, KIND_GLYPHS[e.kind], {x + 52, mid}, t.icon_small - (2 if row.sub else 0), colour)
	}
	right := box.x + box.w - chevron - 8
	size := bytes_label(history_row_bytes(app, row)) if history_row_bytes(app, row) > 0 else "—"
	sw := ui.text_width(ctx, size, t.caption_size)
	ui.text(ctx, size, right, mid, t.caption_size, ui.color_fade(t.text_secondary, fade), .Regular, .Right)
	if recall >= row.oldest && recall <= row.last {
		ui.icon(ctx, ui.ICON_BRUSH, {right - sw - 12, mid}, t.icon_small - 4, t.accent)
		sw += 18
	}
	title := entry_label(e)
	title_w := right - sw - 10 - tx
	name_y := mid if row.sub else mid - 8
	weight: ui.Font = .Semibold if current else .Regular
	shown := ui.text_fit(ctx, title, t.small_size, title_w - (40 if group else 0), weight)
	ui.text(ctx, shown, tx, name_y, t.small_size, ui.color_fade(t.text, fade), weight)
	if group {
		pill := fmt.tprintf("× %d", row.count)
		px := tx + ui.text_width(ctx, shown, t.small_size, weight) + 6
		pw := ui.text_width(ctx, pill, t.caption_size, .Semibold) + 10
		ui.fill_rect(ctx, {px, name_y - 8, pw, 16}, t.radius_small, t.track)
		ui.text(ctx, pill, px + 5, name_y, t.caption_size, ui.color_fade(t.text_secondary, fade), .Semibold)
	}
	if !row.sub {
		obj := object_by_id(app, e.id)
		on := object_label(obj) if obj != nil else ""
		ago := ago_label(e.at)
		note := "  · you are here" if current else "  · undone" if undone else ""
		line := fmt.tprintf("%s · %s%s", on, ago, note) if on != "" else fmt.tprintf("%s%s", ago, note)
		lx := tx
		// A bookmark leads the line with its flag and name, in the flags' amber.
		if e.bookmark != "" {
			amber := ui.color_fade(t.warning, fade)
			ui.icon(ctx, ICON_FLAG, {lx + 5, mid + 9}, t.icon_small - 6, amber)
			name := ui.text_fit(ctx, e.bookmark, t.caption_size, (right - sw - 10 - tx) * 0.6, .Semibold)
			ui.text(ctx, name, lx + 13, mid + 9, t.caption_size, amber, .Semibold)
			lx += 13 + ui.text_width(ctx, name, t.caption_size, .Semibold)
			line = fmt.tprintf(" · %s", line)
		}
		ui.text(ctx, ui.text_fit(ctx, line, t.caption_size, right - sw - 10 - lx), lx, mid + 9, t.caption_size, t.accent if current else ui.color_fade(t.text_tertiary, fade))
	}
	ui.tip(ctx, a.id, box, fmt.tprintf("Step %d: %s. Tap to go here; hold or right-click for its menu", row.head + 1, entry_label(e)))
	if a.clicked && can do timeline_seek_to(tl, row.last + 1)
	if group {
		c := ui.area(ctx, fmt.tprintf("Open step %d##history group", row.head + 1), {chevron, h}, drag = false)
		if c.hovered && !current do ui.fill_rect(ctx, c.rect, t.radius_medium, t.fill_hover)
		ui.icon(ctx, ui.ICON_CHEVRON_DOWN if row.open else ui.ICON_CHEVRON_RIGHT, {c.rect.x + c.rect.w * 0.5, mid}, t.icon_small, t.text_tertiary)
		ui.tip(ctx, c.id, c.rect, "Close the group" if row.open else fmt.tprintf("Show the %d strokes", row.count))
		if c.clicked do tl.open_at = {} if row.open else history_entry_at(app, row.oldest).at
	}
	ui.end(ctx)
	ui.spacer(ctx, HISTORY_ROW_GAP)
}

// What a row's steps held when they were made: each step's entries, a group's every step.
history_row_bytes :: proc(app: ^App, row: History_Row) -> int {
	n := 0
	for i in row.oldest ..= row.last do n += history_entry_at(app, i).bytes
	return n
}

// The first row of all, at the list's foot: where the History starts (the file, or a new
// scene), how long ago, and how many older steps the limits dropped. A tap undoes
// everything.
@(private = "file")
history_root_row :: proc(app: ^App, width: f32, can: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	h := &app.history
	current := len(h.done) == 0
	a := ui.area(ctx, "Start##history root", {width, HISTORY_ROW_H}, drag = false)
	box := a.rect
	if current do ui.fill_rect(ctx, box, t.radius_medium, ui.color_fade(t.accent, 0.16))
	else if a.hovered do ui.fill_rect(ctx, box, t.radius_medium, t.fill_hover)
	ui.stroke_rect(ctx, box, t.radius_medium, t.border_strong if !current else ui.color_fade(t.accent, 0.45), 1)
	mid := box.y + box.h * 0.5
	ui.text(ctx, "0", box.x + 24, mid, t.caption_size, t.text_tertiary, .Regular, .Right)
	ui.icon(ctx, ICON_FILE, {box.x + 52, mid}, t.icon_small, t.text_secondary)
	start := fmt.tprintf("Opened %s", filepath.base(app.scene_path)) if app.scene_path != "" else "New scene"
	if h.began != {} do start = fmt.tprintf("%s · %s", start, ago_label(h.began))
	dropped := fmt.tprintf("%d older dropped", h.dropped) if h.dropped > 0 else ""
	dw := ui.text_width(ctx, dropped, t.caption_size)
	ui.text(ctx, ui.text_fit(ctx, start, t.small_size, box.w - 76 - dw - 16), box.x + 66, mid, t.small_size, t.text_secondary)
	if dropped != "" do ui.text(ctx, dropped, box.x + box.w - 8, mid, t.caption_size, t.text_tertiary, .Regular, .Right)
	ui.tip(ctx, a.id, box, "Where the History starts. Tap to undo everything")
	if a.clicked && can do timeline_seek_to(&app.timeline, 0)
	ui.spacer(ctx, HISTORY_ROW_GAP)
}

// The playback buttons: back to the start, a step back, play or pause, a step on and on to
// the newest, with where the History stands.
history_transport :: proc(app: ^App, can: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	tl := &app.timeline
	done, total := len(app.history.done), history_total(app)
	ui.begin(ctx, "transport", {direction = .Row, center = true})
	if ui.icon_button(ctx, "Back to the start", ui.ICON_SKIP_BACK, enabled = can) do timeline_seek_to(tl, 0)
	if ui.icon_button(ctx, "Step back", ui.ICON_STEP_BACK, enabled = can && done > 0) do timeline_seek_to(tl, done - 1)
	if ui.icon_button(ctx, "Pause" if tl.playing else "Play", ui.ICON_PAUSE if tl.playing else ui.ICON_PLAY, selected = tl.playing, enabled = can && total > 0) {
		if tl.playing {
			tl.playing = false
		} else {
			// From the end, playback starts over from the beginning.
			if done >= total do timeline_seek_to(tl, 0)
			tl.playing, tl.owed, tl.last = true, 0, time.tick_now()
		}
	}
	if ui.icon_button(ctx, "Step forward", ui.ICON_STEP_FORWARD, enabled = can && done < total) do timeline_seek_to(tl, done + 1)
	if ui.icon_button(ctx, "Forward to the newest step", ui.ICON_SKIP_FORWARD, enabled = can) do timeline_seek_to(tl, total)
	ui.spacer(ctx, 10)
	ui.label(ctx, fmt.tprintf("Step %d of %d", done, total), t.text_size, t.text, .Semibold)
	ui.end(ctx)
}
