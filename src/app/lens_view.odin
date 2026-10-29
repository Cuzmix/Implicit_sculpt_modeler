package main

import "../camera"
import "../ui"

// The Lens layout's view (round 2 of the mockups): the picture fills the window with every
// control floating over it, so the model is drawn in the middle of the room the controls
// leave rather than of the window, and Clean view hides the controls altogether.

// Lucide's fullscreen, for Clean view.
ICON_CLEAN_VIEW :: rune(0xe539)

// Seconds Clean view's hint shows before it fades, and how long the fade takes.
CLEAN_HINT_TIME :: 2.5
CLEAN_HINT_FADE :: 0.5

// Each frame before the layout: the shift goes wherever it has no room to mean anything,
// and the model is drawn in the free area once the controls have been laid out at the start.
lens_view_frame :: proc(app: ^App) {
	k := &app.kit
	if grid_panes(&k.grid) != 1 {
		app.camera.shift = {}
		return
	}
	// The third frame: by then every bar and panel has been laid out once, so their rects
	// are known.
	if !k.view_started && k.frame >= 3 {
		k.view_started = true
		if app.camera.shift == {} do view_fit_free(app, false)
	}
}

// The part of the window, in points, that the controls leave free: under the top bar,
// above the dock, and between whatever stands tall down either side (the bars, the
// columns, the tray and floating panels), as they were laid out last. The whole safe
// area when that leaves too little.
lens_free_area :: proc(app: ^App) -> ui.Rect {
	k := &app.kit
	ctx := &k.ctx
	area := ui.safe_area(ctx)
	// Above the shelf, not the action bar over it: that comes and goes with what is
	// active (an Adjust after a remesh), and the view is placed by this once, at the start.
	below: f32 = 0
	if dock := shelf_bottom_size(app); dock.y > 0 do below = dock.y + dock_lift(app)
	lo := [2]f32{area.x, area.y + TOP_BAR_H}
	hi := [2]f32{area.x + area.w, area.y + area.h - below}
	mid := area.x + area.w * 0.5
	side :: proc(r: ui.Rect, mid: f32, lo, hi: ^[2]f32) {
		if r.w <= 0 do return
		if r.x + r.w * 0.5 < mid do lo.x = max(lo.x, r.x + r.w + 8)
		else do hi.x = min(hi.x, r.x - 8)
	}
	// A floating bar stands over the view rather than down a side; the shelf is the
	// bottom's, above.
	for b in Place_Bar do if b != .Shelf && bar_place_edge(k, b) != .Float do side(ui.prev_rect(ctx, PLACE_BAR_ROOTS[b]), mid, &lo, &hi)
	for c in k.panels.rect do side(c, mid, &lo, &hi)
	// A panel shown last frame and tall enough to stand down a side.
	for s in k.panels.seen do if s.frame >= k.frame - 1 && s.rect.h > area.h * 0.3 do side(s.rect, mid, &lo, &hi)
	if hi.x - lo.x < area.w * 0.3 || hi.y - lo.y < area.h * 0.3 do return area
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

// With one view, draws the camera's target in the middle of the free area (the
// camera's shift), and with `fit` moves it back so what Frame framed fits the free area's
// shorter side rather than the window's. Anywhere else the shift goes.
view_fit_free :: proc(app: ^App, fit: bool) {
	k := &app.kit
	app.camera.shift = {}
	if grid_panes(&k.grid) != 1 do return
	win := k.ctx.input.window
	if win.x <= 0 || win.y <= 0 do return
	free := lens_free_area(app)
	d := [2]f32{free.x + free.w * 0.5, free.y + free.h * 0.5} - win * 0.5
	app.camera.shift = [2]f32{d.x, -d.y} / (win.y * 0.5)
	if fit {
		grow := clamp(win.y / max(min(free.w, free.h), 1), 1, 2)
		app.camera.distance = clamp(app.camera.distance * grow, camera.MIN_DISTANCE, camera.MAX_DISTANCE)
	}
}

// Turns Clean view on or off; on, whatever floats closes with the controls.
clean_view_set :: proc(app: ^App, on: bool) {
	k := &app.kit
	if on == k.clean do return
	k.clean, k.clean_at = on, k.ctx.time
	if !on do return
	if k.palette do palette_close(app)
	kit_floats_close(k)
}

// Clean view's layout: the dial when it stays, and for a moment a hint at the top that
// says how to bring the controls back, which a tap on it does too.
kit_clean_view :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	if k.clean_dial do kit_modifier_rail(app)
	age := ctx.time - k.clean_at
	if age > CLEAN_HINT_TIME + CLEAN_HINT_FADE do return
	shown := 1 - clamp(f32(age - CLEAN_HINT_TIME) / CLEAN_HINT_FADE, 0, 1)
	if ctx.reduced_motion do shown = 1
	hint := "Tab or four-finger tap to bring the interface back"
	mark := ui.vertex_mark(ctx)
	ui.begin_anchored(ctx, "clean hint", .Center, .Start, {0, 24}, {direction = .Row})
	w := ui.text_width(ctx, hint, t.small_size) + 20
	a := ui.area(ctx, "Bring the interface back", {w, 32})
	ui.fill_rect(ctx, a.rect, t.radius_medium, {t.frame.r, t.frame.g, t.frame.b, 200})
	ui.stroke_rect(ctx, a.rect, t.radius_medium, t.border, 1)
	ui.text(ctx, hint, a.rect.x + 10, a.rect.y + a.rect.h * 0.5, t.small_size, t.text)
	if a.clicked do clean_view_set(app, false)
	ui.end(ctx)
	ui.transform_since(ctx, mark, shown)
}
