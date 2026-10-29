package main

import "core:fmt"
import "core:strings"

import "../ui"

// The Input diagnostics screen (diagnostics.odin): the tests down one side, the test shown in
// the middle with its steps, verdicts and notes, and on the other side the controls the tests
// use, each a kit widget as the panels have, with what the input pipeline says live under
// them. It covers the window as Home does, so nothing reaches the scene behind it.

// Points the test list, the probe column and the gap between columns take; under
// DIAG_WIDE points across, the list becomes a select in the heading.
DIAG_LIST_W :: 250
DIAG_PROBE_W :: 380
DIAG_GAP :: 16
DIAG_WIDE :: 1000

kit_diag :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	d := &app.diag
	t := ctx.theme
	win := ctx.input.window
	area := ui.safe_area(ctx)
	PAD :: 20
	ui.begin_at(ctx, "diag", {0, 0}, {direction = .Row, width = win.x, height = win.y})
	owner := ui.id_of(ctx, "diag")
	ui.fill_rect(ctx, {0, 0, win.x, win.y}, 0, t.frame)
	ui.spacer(ctx, area.x + PAD)
	width := area.w - 2 * PAD
	ui.begin(ctx, "diag page", {direction = .Column, gap = 10, width = width, height = area.y + area.h})
	ui.spacer(ctx, area.y + 8)
	wide := width >= DIAG_WIDE

	// The heading: the title and session, the test picker on a narrow window, Export and Close.
	ui.begin(ctx, "diag head", {direction = .Row, center = true, gap = 10, width = width, height = t.target})
	actions: f32 = 160 + t.target + 2 * 10
	picker: f32 = 0 if wide else min(260, width * 0.4)
	title := ui.place(ctx, {width - actions - picker - (10 if picker > 0 else 0), t.target})
	ui.text(ctx, "Input diagnostics", title.x, title.y + title.h * 0.3, t.heading_size, t.text, .Semibold)
	ui.text(ctx, fmt.tprintf("Session %s · %d runs · %d KB logged", diag_text(d.session[:]), len(d.runs), len(d.log) >> 10), title.x, title.y + title.h * 0.78, t.caption_size, t.text_tertiary)
	if !wide {
		names := make([]string, len(Diag_Test_Id), context.temp_allocator)
		for test, id in DIAG_TESTS do names[int(id)] = test.title
		if picked := ui.select(ctx, "Test", names, int(d.test), picker); picked >= 0 do diag_show(app, Diag_Test_Id(picked))
	}
	if ui.button(ctx, "Export report", .Bordered, width = 160) do file_dialog(app, .Diagnostic_Report)
	if ui.icon_button(ctx, "Close diagnostics", ui.ICON_CLOSE, keys = "Esc") do diag_close(app)
	ui.end(ctx)

	room := area.y + area.h - (ctx.last_rect.y + ctx.last_rect.h) - 10 - PAD
	ui.begin(ctx, "diag body", {direction = .Row, gap = DIAG_GAP, width = width, height = room})
	probe_w: f32 = DIAG_PROBE_W if width >= 760 else width * 0.48
	card_w := width - probe_w - DIAG_GAP - ((DIAG_LIST_W + DIAG_GAP) if wide else 0) - 10
	if wide {
		list := kit_scroll_begin(ctx, "diag tests", &d.list_scroll, owner, DIAG_LIST_W - 10, room, 2)
		category := ""
		for test, id in DIAG_TESTS {
			if test.category != category {
				category = test.category
				ui.label(ctx, diag_category_name(category), t.caption_size, t.text_tertiary, .Semibold)
			}
			row := ui.list_row(ctx, fmt.tprintf("%s##%s", test.title, test.key), diag_status(d, id), selected = d.test == id)
			if row.clicked do diag_show(app, id)
		}
		kit_scroll_end(ctx, list)
		ui.spacer(ctx, 0)
	}
	card := kit_scroll_begin(ctx, "diag card", &d.card_scroll, owner, card_w, room, 10)
	kit_diag_card(app, card_w)
	kit_scroll_end(ctx, card)
	ui.spacer(ctx, 0)
	kit_diag_probes(app, owner, probe_w, room)
	ui.end(ctx)

	ui.end(ctx)
	ui.end(ctx)
}

// A category's name as the list heads it.
@(private = "file")
diag_category_name :: proc(category: string) -> string {
	switch category {
	case "finger":   return "FINGER"
	case "pencil":   return "APPLE PENCIL"
	case "pressure": return "PRESSURE"
	case "hover":    return "HOVER AND SLIDERS"
	case "text":     return "TEXT AND KEYBOARD"
	case "system":   return "SYSTEM GESTURES"
	case "roll":     return "BARREL ROLL"
	}
	return category
}

// Shows `test` on the card, ending the run of another.
diag_show :: proc(app: ^App, test: Diag_Test_Id) {
	d := &app.diag
	if test == d.test do return
	if r := diag_run(d); r != nil do diag_run_end(app, .Next)
	d.test = test
	d.card_scroll = 0
}

// What the list says of a test: its last run's verdict, the person's over the app's.
@(private = "file")
diag_status :: proc(d: ^Diag, test: Diag_Test_Id) -> string {
	r := diag_last_run(d, test)
	if r == nil do return ""
	if d.run_open && r == diag_run(d) do return "running"
	if r.manual != .None do return DIAG_MANUAL_NAMES[r.manual]
	return DIAG_VERDICT_NAMES[r.auto] if r.auto != .None else "done"
}

// The test card: what to do and expect, the buttons that run it, and what it concluded.
@(private = "file")
kit_diag_card :: proc(app: ^App, width: f32) {
	ctx := &app.kit.ctx
	d := &app.diag
	t := ctx.theme
	test := DIAG_TESTS[d.test]
	ui.label(ctx, test.title, t.title_size, t.text, .Semibold)
	needs, _ := strings.replace_all(test.needs, ",", ", ", context.temp_allocator)
	needs, _ = strings.replace_all(needs, "pencil_pro", "Apple Pencil Pro", context.temp_allocator)
	needs, _ = strings.replace_all(needs, "pencil", "Apple Pencil", context.temp_allocator)
	needs, _ = strings.replace_all(needs, "ipad", "iPad", context.temp_allocator)
	ui.paragraph(ctx, fmt.tprintf("Device: %s · Needs: %s · Uses the %s", test.device, needs, DIAG_PROBE_TITLES[test.probe]), width)
	ui.label(ctx, "Steps", t.caption_size, t.text_tertiary, .Semibold)
	for step, i in strings.split_lines(test.steps, context.temp_allocator) do ui.paragraph(ctx, fmt.tprintf("%d. %s", i + 1, step), width, t.text_secondary)
	ui.label(ctx, "Expected", t.caption_size, t.text_tertiary, .Semibold)
	ui.paragraph(ctx, test.expected, width, t.text_secondary)

	ran := diag_last_run(d, d.test) != nil
	ui.begin(ctx, "diag run buttons", {direction = .Row, gap = 8})
	if ui.button(ctx, "Repeat" if ran else "Start", .Solid, .Accent, width = 120) do diag_run_start(app, d.test)
	if ui.button(ctx, "Skip", .Bordered, width = 90) {
		if !d.run_open do diag_run_start(app, d.test)
		diag_run_end(app, .Skip)
		diag_next(app)
	}
	if ui.button(ctx, "Next", .Bordered, width = 90) {
		if d.run_open do diag_run_end(app, .Next)
		diag_next(app)
	}
	ui.end(ctx)

	// Only now: a button may have added a run, which can move the runs, or shown another test.
	r := diag_last_run(d, d.test)
	running := d.run_open && r == diag_run(d)

	if r == nil {
		ui.paragraph(ctx, "Not run yet. Press Start, then follow the steps.", width)
		return
	}
	verdict, reason := r.auto, diag_text(r.reason[:])
	if running {
		// The verdict so far, judged afresh each frame from the run's counts.
		verdict, reason = diag_judge(r)
		ui.label(ctx, fmt.tprintf("Run %d, %.1f s", r.run, diag_now(app) - r.start), t.text_size, t.text)
	} else {
		ui.label(ctx, fmt.tprintf("Run %d, ended after %.1f s", r.run, r.end - r.start), t.text_size, t.text)
	}
	colors := [Diag_Verdict]ui.Color{.None = t.text_tertiary, .Pass = t.success, .Fail = t.danger, .Inconclusive = t.warning, .Unavailable = t.warning}
	label := "Only you can judge this one" if verdict == .None else fmt.tprintf("Automatic: %s", DIAG_VERDICT_NAMES[verdict])
	ui.label(ctx, label, t.text_size, colors[verdict], .Semibold)
	if reason != "" do ui.paragraph(ctx, reason, width)
	for count, code in r.anomalies do if count > 0 {
		ui.paragraph(ctx, fmt.tprintf("Noticed: %s (%s, %d)", DIAG_ANOMALY_NAMES[code], DIAG_ANOMALY_SEVERITY[code], count), width, t.warning)
	}
	if running {
		ui.label(ctx, "Your verdict", t.caption_size, t.text_tertiary, .Semibold)
		options := [4]string{"Pass", "Fail", "Inconclusive", "Skip"}
		if picked := ui.tabs(ctx, "Your verdict", options[:], int(r.manual) - 1); picked >= 0 do r.manual = Diag_Manual(picked + 1)
		ui.label(ctx, "Notes", t.caption_size, t.text_tertiary, .Semibold)
		_ = ui.text_field(ctx, "Notes", r.notes[:], width, hint = "What you saw (goes in the report)")
	} else {
		ui.paragraph(ctx, fmt.tprintf("Your verdict: %s%s", DIAG_MANUAL_NAMES[r.manual] if r.manual != .None else "none", fmt.tprintf(". Notes: %s", diag_text(r.notes[:])) if r.notes[0] != 0 else ""), width)
	}
	ui.spacer(ctx, 4)
	_ = ui.switch_row(ctx, "Keep recording after closing", &d.keep)
	ui.paragraph(ctx, "On, the log goes on while you use the app's own panels, so a problem with the real sliders or Search is in the report too. Reopen this screen to export.", width)
}

// What the card calls each control.
@(rodata)
DIAG_PROBE_TITLES := [Diag_Probe]string{.None = "whole screen", .Pad = "pad", .Slider = "slider", .Vslider = "size slider", .Button = "diagnostic button", .Menu = "diagnostic menu", .Field = "diagnostic field"}

// Moves the card to the test after the one shown.
@(private = "file")
diag_next :: proc(app: ^App) {
	d := &app.diag
	if int(d.test) + 1 < len(Diag_Test_Id) do diag_show(app, Diag_Test_Id(int(d.test) + 1))
}

// The controls the tests use, each reporting to diag_probe, and the live values. The pad and
// the size slider stand outside any scrolling, as the off-hand island's sliders do; the
// rest sit in a body that scrolls, so a finger's press on them is tentative, as in the
// panels (the gesture arena).
@(private = "file")
kit_diag_probes :: proc(app: ^App, owner: ui.Id, width, height: f32) {
	ctx := &app.kit.ctx
	d := &app.diag
	t := ctx.theme
	ring := DIAG_TESTS[d.test].probe
	ui.begin(ctx, "diag probes", {direction = .Column, gap = 8, width = width, height = height})
	ui.begin(ctx, "diag pad row", {direction = .Row, gap = 12})
	pad_h := DIAG_VTRACK + 80
	pad := ui.area(ctx, "diag pad", {width - t.target - 12, pad_h})
	diag_probe(app, .Pad, pad.hovered, pad.held, pad.clicked, 0, 0)
	d.rects[.Pad] = pad.rect
	diag_pad_draw(app, pad.rect, ring == .Pad)
	before := d.vslider
	_ = ui.vslider(ctx, "Size##diag", &d.vslider, 0, DIAG_RANGE, .Linear, fmt.tprintf("%.1f", d.vslider), track = DIAG_VTRACK)
	diag_probe(app, .Vslider, ctx.hot == ctx.last_id, ctx.active == ctx.last_id, false, before, d.vslider)
	d.rects[.Vslider] = ctx.last_rect
	if ring == .Vslider do ui.stroke_rect(ctx, ctx.last_rect, t.radius_medium, t.accent, 2)
	ui.end(ctx)

	scroll := kit_scroll_begin(ctx, "diag controls", &d.controls_scroll, owner, width - 10, height - pad_h - 8, 6)
	before = d.slider
	_ = ui.slider(ctx, "Slider##diag", &d.slider, 0, DIAG_RANGE, .Linear, fmt.tprintf("%.2f", d.slider))
	diag_probe(app, .Slider, ctx.hot == ctx.last_id, ctx.active == ctx.last_id, false, before, d.slider)
	d.rects[.Slider] = ctx.last_rect
	if ring == .Slider do ui.stroke_rect(ctx, ctx.last_rect, t.radius_medium, t.accent, 2)
	ui.begin(ctx, "diag button row", {direction = .Row, gap = 8})
	half := (width - 10 - 8) / 2
	clicked := ui.button(ctx, "Diagnostic button", .Flat, width = half)
	diag_probe(app, .Button, ctx.hot == ctx.last_id, ctx.active == ctx.last_id, clicked, 0, 0)
	d.rects[.Button] = ctx.last_rect
	if ring == .Button do ui.stroke_rect(ctx, ctx.last_rect, t.radius_medium, t.accent, 2)
	options := [5]string{"Clay", "Smooth", "Inflate", "Pinch", "Flatten"}
	picked := ui.select(ctx, "Diagnostic menu", options[:], d.menu, half)
	d.menu_id = ui.id_of(ctx, "Diagnostic menu")
	if picked >= 0 do d.menu = picked
	diag_probe(app, .Menu, ctx.hot == ctx.last_id, ctx.active == ctx.last_id, false, 0, 0)
	diag_menu(app, ctx.select_open == d.menu_id, picked)
	d.rects[.Menu] = ctx.last_rect
	if ring == .Menu do ui.stroke_rect(ctx, ctx.last_rect, t.radius_medium, t.accent, 2)
	ui.end(ctx)
	changed := ui.text_field(ctx, "Diagnostic field", d.field[:], width - 10, hint = "Type or write here")
	d.field_id = ctx.last_id
	diag_probe(app, .Field, ctx.hot == ctx.last_id, ctx.active == ctx.last_id, false, 0, 0)
	diag_field(app, ctx.text_focus == d.field_id && d.field_id != 0, changed)
	d.rects[.Field] = ctx.last_rect
	if ring == .Field do ui.stroke_rect(ctx, ctx.last_rect, t.radius_medium, t.accent, 2)
	kit_diag_live(app)
	kit_scroll_end(ctx, scroll)
	ui.end(ctx)
}

// The pad: the trail of where the pointer went (filled while touching, rings while
// hovering), and where it is now.
@(private = "file")
diag_pad_draw :: proc(app: ^App, r: ui.Rect, ringed: bool) {
	ctx := &app.kit.ctx
	d := &app.diag
	t := ctx.theme
	ui.fill_rect(ctx, r, t.radius_large, t.surface)
	ui.stroke_rect(ctx, r, t.radius_large, t.accent if ringed else t.border, 2 if ringed else 1)
	ui.text(ctx, "Pad", r.x + 12, r.y + 16, t.caption_size, t.text_tertiary, .Semibold)
	inside :: proc(r: ui.Rect, at: [2]f32) -> bool {
		return at.x >= r.x + 4 && at.y >= r.y + 4 && at.x < r.x + r.w - 4 && at.y < r.y + r.h - 4
	}
	for i in 0 ..< d.trail_n {
		p := d.trail[(d.trail_at - d.trail_n + i + DIAG_TRAIL) % DIAG_TRAIL]
		if !inside(r, p.at) do continue
		fade := f32(i + 1) / f32(d.trail_n)
		color := t.accent if p.kind != .Finger else t.success
		if p.contact do ui.fill_circle(ctx, p.at, 3, ui.color_fade(color, fade))
		else do ui.stroke_circle(ctx, p.at, 4, ui.color_fade(t.text_tertiary, fade), 1)
	}
	in_ := ctx.input
	if in_.mouse_valid && inside(r, in_.mouse) {
		if in_.down != {} do ui.fill_circle(ctx, in_.mouse, 9, ui.color_fade(t.accent, 0.8))
		else do ui.stroke_circle(ctx, in_.mouse, 12, t.text_secondary, 1.5)
	}
}

// What the pipeline says now, and what the run under way has counted.
@(private = "file")
kit_diag_live :: proc(app: ^App) {
	ctx := &app.kit.ctx
	d := &app.diag
	t := ctx.theme
	tc := &app.touch
	dv := &app.device
	ui.label(ctx, "LIVE", t.caption_size, t.text_tertiary, .Semibold)
	ui.value_row(ctx, "Last event", diag_text(d.live.event[:]))
	ui.value_row(ctx, "Where", fmt.tprintf("%.0f, %.0f", d.live.at.x, d.live.at.y))
	touching := "touching" if dv.down != {} else ("hovering" if dv.pointer == .Pen else "up")
	ui.value_row(ctx, "Pointer", fmt.tprintf("%s, %s", DIAG_POINTER_NAMES[dv.pointer], touching))
	ui.value_row(ctx, "Pressure", fmt.tprintf("%.2f", d.live.pressure) if d.live.pressure_seen else "not reported")
	ui.value_row(ctx, "Hover height", fmt.tprintf("%.2f", app.pen_distance) if app.pen_seen else "not reported")
	ui.value_row(ctx, "Tilt", fmt.tprintf("%.0f, %.0f", d.live.tilt.x, d.live.tilt.y) if app.pen_seen else "not reported")
	ui.value_row(ctx, "Roll reported", fmt.tprintf("%.1f°", d.live.raw_roll) if d.live.raw_seen else "not reported")
	ui.value_row(ctx, "Roll this frame", fmt.tprintf("%.2f°", app.pen_roll))
	ui.value_row(ctx, "Pen near / down", fmt.tprintf("%v / %v", tc.pen_near, tc.pen_down))
	ui.value_row(ctx, "Fingers / palm", fmt.tprintf("%d / %v", tc.fingers.count, tc.palm && tc.fingers.count > 0))
	ui.value_row(ctx, "Touch owner", DIAG_OWNER_NAMES[tc.owner])
	ui.value_row(ctx, "Under the pointer", DIAG_PROBE_NAMES[d.state.hot])
	ui.value_row(ctx, "Slider / size", fmt.tprintf("%.2f / %.1f", d.slider, d.vslider))
	yes := [2]string{"no", "yes"}
	keyboard := "none on screen" if d.state.keyboard < 0 else yes[d.state.keyboard]
	ui.value_row(ctx, "Field has keys / text input", fmt.tprintf("%s / %s", yes[int(ctx.text_focus == d.field_id && d.field_id != 0)], yes[int(app.kit.text_input)]))
	ui.value_row(ctx, "Keyboard shown", keyboard)
	if r := diag_run(d); r != nil {
		ui.value_row(ctx, "Received", fmt.tprintf("finger %d, pen %d, mouse %d downs", r.received[.Finger_Down], r.received[.Pen_Down], r.received[.Mouse_Down]))
		ui.value_row(ctx, "Its control answered", fmt.tprintf("%d presses, %d clicks, %d changes", r.responded[.Press], r.responded[.Click], r.responded[.Value]))
		ui.value_row(ctx, "Palms", fmt.tprintf("%d", r.palms))
	}
}
