#+build js
package main

import "core:math"
import "core:math/linalg"
import "core:sys/wasm/js"
import "core:time"

import "../camera"
import "../sculpt"

// The browser's events the page listens to: pointers (mouse, pen and fingers alike) and
// the wheel on the canvas, keys on the window. web/index.html captures a pressed pointer
// to the canvas, so a drag that leaves it keeps coming here.
listen :: proc() {
	js.add_event_listener(CANVAS_ID, .Pointer_Down, nil, on_pointer_down)
	js.add_event_listener(CANVAS_ID, .Pointer_Move, nil, on_pointer_move)
	js.add_event_listener(CANVAS_ID, .Pointer_Up, nil, on_pointer_up)
	js.add_event_listener(CANVAS_ID, .Pointer_Cancel, nil, on_pointer_up)
	js.add_event_listener(CANVAS_ID, .Pointer_Leave, nil, on_pointer_leave)
	js.add_event_listener(CANVAS_ID, .Wheel, nil, on_wheel)
	js.add_window_event_listener(.Key_Down, nil, on_key_down)
}

// What a page button or menu asks (web/index.html's sculpt.command).
Command :: enum i32 {
	None,
	Brush,      // value: the brush's place in BRUSHES
	Radius,     // value: pixels
	Strength,   // value: 0 to 1, for the brush held
	Symmetry,   // value: 0 or 1
	Undo,
	Redo,
	New_Sphere, // value: vertices
	Reset_View,
}

@(export)
command :: proc "c" (code: i32, value: f64) {
	context = state.ctx
	switch Command(code) {
	case .None:
	case .Brush:
		if i := int(value); i >= 0 && i < len(BRUSHES) do state.kind = BRUSHES[i]
	case .Radius:
		state.radius_px = clamp(f32(value), MIN_RADIUS_PX, MAX_RADIUS_PX)
	case .Strength:
		state.strengths[state.kind] = clamp(f32(value), 0, 1)
	case .Symmetry:
		state.symmetry_x = value != 0
	case .Undo:
		undo(false)
	case .Redo:
		undo(true)
	case .New_Sphere:
		state.new_vertices = clamp(int(value), 1000, MAX_VERTICES)
	case .Reset_View:
		state.cam = camera.orbit_default()
	}
}

undo :: proc(redo: bool) {
	if state.sculptor == nil || state.drag == .Stroke do return
	if redo {
		_ = sculpt.sculptor_redo(state.sculptor)
	} else {
		_ = sculpt.sculptor_undo(state.sculptor)
	}
}

pointer_at :: proc(e: js.Event) -> Vec2 {
	return {f32(e.mouse.offset.x), f32(e.mouse.offset.y)}
}

// The pressure a dab gets: the pen's own, and full for a mouse or a finger, which report
// none worth reading.
pressure_of :: proc(e: js.Event) -> f32 {
	if e.mouse.pointer.pointer_type == .Pen do return clamp(f32(e.mouse.pointer.pressure), 0.05, 1)
	return 1
}

find_pointer :: proc(id: int) -> ^Pointer {
	for &p in state.pointers do if p.used && p.id == id do return &p
	return nil
}

touches_down :: proc() -> (count: int, a, b: Vec2) {
	for p in state.pointers {
		if !p.used || p.kind != .Touch do continue
		if count == 0 do a = p.at
		if count == 1 do b = p.at
		count += 1
	}
	return
}

on_pointer_down :: proc(e: js.Event) {
	at := pointer_at(e)
	id := e.mouse.pointer.pointer_id
	if find_pointer(id) == nil {
		for &p in state.pointers {
			if p.used do continue
			p = {id = id, at = at, kind = e.mouse.pointer.pointer_type, used = true}
			break
		}
	}
	state.hover, state.hovering = at, e.mouse.pointer.pointer_type != .Touch

	// A second finger turns whatever the first began into a pinch: two fingers pan and
	// zoom, as on every tablet app.
	if count, a, b := touches_down(); count >= 2 {
		end_stroke()
		state.drag = .Pinch
		state.pinch_span = max(linalg.length(b - a), 1)
		state.pinch_mid = (a + b) / 2
		return
	}
	if state.drag != .None do return
	state.drag_from = at
	switch {
	case e.mouse.button == 2:
		state.drag = .Orbit
	case e.mouse.button == 1:
		state.drag = .Pan
	case e.mouse.button == 0:
		// On the surface a press sculpts; off it, it turns the view (ZBrush's way), or
		// moves it with Alt.
		if hit, ok := pick(at); ok {
			begin_stroke(e, at, hit)
		} else {
			state.drag = .Pan if e.mouse.alt else .Orbit
		}
	}
}

on_pointer_move :: proc(e: js.Event) {
	at := pointer_at(e)
	if p := find_pointer(e.mouse.pointer.pointer_id); p != nil {
		before := p.at
		p.at = at
		switch state.drag {
		case .Pinch:
			if count, a, b := touches_down(); count >= 2 {
				span := max(linalg.length(b - a), 1)
				mid := (a + b) / 2
				camera.orbit_pan(&state.cam, mid - state.pinch_mid, state.size.y)
				camera.orbit_zoom_toward(&state.cam, span / state.pinch_span, mid - state.size / 2, state.size.y)
				state.pinch_span, state.pinch_mid = span, mid
			}
		case .Orbit:
			camera.orbit_rotate(&state.cam, at - before)
		case .Pan:
			camera.orbit_pan(&state.cam, at - before, state.size.y)
		case .Stroke:
			if p.id == state.stroke.pointer do stroke_to(at, pressure_of(e), e.mouse.alt, e.mouse.shift)
		case .None:
		}
	}
	if state.drag != .Stroke && e.mouse.pointer.pointer_type != .Touch {
		state.hover, state.hovering = at, true
		state.cursor, state.cursor_ok = pick(at)
	}
}

on_pointer_up :: proc(e: js.Event) {
	if p := find_pointer(e.mouse.pointer.pointer_id); p != nil do p.used = false
	switch state.drag {
	case .Stroke:
		if e.mouse.pointer.pointer_id == state.stroke.pointer {
			end_stroke()
		}
	case .Pinch:
		if count, _, _ := touches_down(); count == 0 do state.drag = .None
	case .Orbit, .Pan:
		any_down := false
		for p in state.pointers do any_down ||= p.used
		if !any_down do state.drag = .None
	case .None:
	}
	if e.mouse.pointer.pointer_type == .Touch do state.hovering = false
}

on_pointer_leave :: proc(e: js.Event) {
	if state.drag == .None do state.hovering = false
}

on_wheel :: proc(e: js.Event) {
	js.event_prevent_default()
	// Pixels, lines or pages: a notch is about 100 pixels or 3 lines in every browser.
	steps := -f32(e.wheel.delta.y)
	switch e.wheel.delta_mode {
	case .Pixel: steps /= 100
	case .Line:  steps /= 3
	case .Page:
	}
	factor := math.pow(f32(1 / 0.88), steps)
	camera.orbit_zoom_toward(&state.cam, factor, pointer_at(e) - state.size / 2, state.size.y)
}

on_key_down :: proc(e: js.Event) {
	k := e.key.key
	command_key := e.key.ctrl || e.key.meta
	switch {
	case command_key && (k == "z" || k == "Z"):
		js.event_prevent_default()
		undo(e.key.shift)
	case command_key && (k == "y" || k == "Y"):
		js.event_prevent_default()
		undo(true)
	case command_key:
	case len(k) == 1 && k[0] >= '1' && k[0] <= '9':
		state.kind = BRUSHES[int(k[0] - '1')]
	case k == "0":
		state.kind = BRUSHES[9]
	case k == "[":
		state.radius_px = clamp(state.radius_px * 6.0 / 7, MIN_RADIUS_PX, MAX_RADIUS_PX)
	case k == "]":
		state.radius_px = clamp(state.radius_px * 7.0 / 6, MIN_RADIUS_PX, MAX_RADIUS_PX)
	case k == "x" || k == "X":
		state.symmetry_x = !state.symmetry_x
	case k == "f" || k == "F":
		state.cam = camera.orbit_default()
	}
}

begin_stroke :: proc(e: js.Event, at: Vec2, hit: Vec3) {
	s := state.sculptor
	state.drag = .Stroke
	state.stroke = {
		kind     = .Smooth if e.mouse.shift else state.kind,
		invert   = e.mouse.alt,
		pointer  = e.mouse.pointer.pointer_id,
		last_px  = at,
		pressure = pressure_of(e),
	}
	sculpt.sculptor_stroke_begin(s)
	state.cursor, state.cursor_ok = hit, true
	if state.stroke.kind == .Grab {
		_ = sculpt.sculptor_grab_begin(s, brush_at(hit, state.stroke.pressure), hit)
		state.stroke.anchor, state.stroke.grabbing = hit, true
		return
	}
	dab(hit, state.stroke.pressure)
}

// Lays dabs from the last one to `at`, a fifth of the brush's width apart, as the
// desktop's default spacing.
stroke_to :: proc(at: Vec2, pressure: f32, alt, shift: bool) {
	st := &state.stroke
	if st.grabbing {
		// Grab follows the pointer on the plane through where it picked up, facing the view.
		origin, dir := screen_ray(at)
		_, _, back := camera.orbit_basis(state.cam)
		denom := linalg.dot(dir, back)
		if abs(denom) < 1e-6 do return
		t := linalg.dot(st.anchor - origin, back) / denom
		point := origin + dir * t
		t0 := time.tick_now()
		_ = sculpt.sculptor_grab_move(state.sculptor, point - st.anchor)
		state.dab_ms += time.duration_milliseconds(time.tick_since(t0))
		state.dabs += 1
		state.cursor, state.cursor_ok = point, true
		return
	}
	spacing := max(state.radius_px * 0.2, 1)
	d := at - st.last_px
	dist := linalg.length(d)
	if dist < spacing do return
	n := int(dist / spacing)
	for i in 1 ..= n {
		q := st.last_px + d * (f32(i) * spacing / dist)
		if hit, ok := pick(q); ok {
			p := st.pressure + (pressure - st.pressure) * f32(i) / f32(n)
			dab(hit, p)
			state.cursor, state.cursor_ok = hit, true
		}
	}
	st.last_px += d * (f32(n) * spacing / dist)
	st.pressure = pressure
}

brush_at :: proc(hit: Vec3, pressure: f32) -> sculpt.Brush {
	st := &state.stroke
	stroke_dir: Vec3
	if st.last_set do stroke_dir = hit - st.last_hit
	st.last_hit, st.last_set = hit, true
	world_per_px := camera.orbit_world_per_px(state.cam, hit, state.size.y)
	return sculpt.Brush {
		kind          = st.kind,
		radius        = state.radius_px * world_per_px,
		strength      = state.strengths[st.kind] * pressure,
		invert        = st.invert,
		symmetry      = {.X} if state.symmetry_x else {},
		feather       = state.symmetry_x,
		facing        = -camera.orbit_toward(state.cam, hit),
		stroke_dir    = stroke_dir,
		tip_roundness = sculpt.CLAY_TIP_ROUNDNESS,
		tip_scale     = 1,
		volume        = 0.8,
		color         = {200, 60, 30},
	}
}

dab :: proc(hit: Vec3, pressure: f32) {
	t0 := time.tick_now()
	_ = sculpt.apply_dab(state.sculptor, brush_at(hit, pressure), hit)
	state.dab_ms += time.duration_milliseconds(time.tick_since(t0))
	state.dabs += 1
}

end_stroke :: proc() {
	if state.drag != .Stroke || state.sculptor == nil do return
	if state.stroke.grabbing do sculpt.sculptor_grab_end(state.sculptor)
	_ = sculpt.sculptor_stroke_end(state.sculptor)
	state.stroke = {}
	state.drag = .None
}
