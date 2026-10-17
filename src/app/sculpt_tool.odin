package main

import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../sculpt"

// Brush settings as the user edits them. Radius is in screen pixels, converted to
// world units at each dab's hit point so the brush feels the same at any zoom.
Brush_Settings :: struct {
	kind:              sculpt.Brush_Kind,
	radius_px:         f32,
	strength:          f32,
	pressure_strength: bool, // pen pressure scales the strength
	pressure_size:     bool, // pen pressure scales the radius
	lazy_px:           f32,  // lazy mouse: the brush trails the cursor by this many pixels; 0 is off
}

// One pointer sample as SDL reported it. The app keeps every motion event of a frame,
// not just the last, so a fast stroke follows the path the pointer really took.
// Positions are in window coordinates in App.samples and viewport-local in
// Viewport_Input.samples.
Input_Sample :: struct {
	pos:      [2]f32,
	pressure: f32, // 0 to 1 from a pen; 1 from a mouse
	kind:     Sample_Kind,
}

Sample_Kind :: enum u8 {
	Move,
	Press, // left button (or pen tip) down
	Release, // left button (or pen tip) up
}

Stroke :: struct {
	active:   bool,
	object:   int, // id of the object being sculpted
	pos:      [2]f32, // viewport position the stroke has reached; trails the cursor with lazy mouse
	pressure: f32, // pen pressure at pos
	travel:   f32, // pixels moved since the last dab
	size:     [2]f32, // viewport size the positions above are in
	pending:  [dynamic]Input_Sample, // samples left for the next frame once one reaches MAX_DABS_PER_FRAME
}

Sculpt_Frame_Result :: struct {
	dabs:       int,
	raycast_ms: f64,
	brush_ms:   f64,
}

DAB_SPACING :: 0.25 // brush radii between dabs, measured on screen
MIN_DAB_SPACING_PX :: 1
MAX_DABS_PER_FRAME :: 64 // the rest of the path waits for the next frame
MAX_PENDING_SAMPLES :: 4096 // beyond this a lagging stroke drops its oldest samples
MIN_PRESSURE_SIZE :: 0.05 // smallest share of the radius pen pressure can shrink it to

// Turns this frame's pointer samples into brush dabs. A stroke sculpts the object it
// started on, which becomes the selected object. Dabs are laid along the path the
// pointer took on screen, DAB_SPACING radii apart, and each is raycast onto the
// surface, so a fast stroke follows the pointer and every dab lands on the surface.
sculpt_frame :: proc(app: ^App, input: Viewport_Input) -> (res: Sculpt_Frame_Result) {
	if input.size.x <= 0 || input.size.y <= 0 {
		stroke_finish(app)
		return
	}
	samples := input.samples
	cursor := [1]Input_Sample{{pos = input.mouse_pos, pressure = 1}}
	if len(samples) == 0 do samples = cursor[:] // synthetic input has only the cursor position

	if !input.primary {
		// The button went up during the frame: the samples before that still count.
		if app.stroke.active {
			if rest := until_release(samples); len(rest) < len(samples) do stroke_follow(app, input, rest, &res)
		}
		stroke_finish(app)
		return
	}

	// A press this frame starts the stroke there; samples before it were hovering.
	press := -1
	for s, i in samples do if s.kind == .Press do press = i
	if press >= 0 {
		if app.stroke.active {
			// Released and pressed again within one frame: end the previous stroke first.
			stroke_follow(app, input, until_release(samples[:press]), &res)
			stroke_finish(app)
		}
		samples = samples[press:]
	}
	// The panel can report a release a frame late, so a release in the samples ends
	// the stroke there.
	rest := until_release(samples)
	stroke_follow(app, input, rest, &res)
	if len(rest) < len(samples) do stroke_finish(app)
	return
}

// The samples before the first release.
@(private = "file")
until_release :: proc(samples: []Input_Sample) -> []Input_Sample {
	for s, i in samples do if s.kind == .Release do return samples[:i]
	return samples
}

// Moves the stroke through `samples` in order, after any left over from the previous
// frame. Starts the stroke at the first sample over an object if it has not started.
@(private = "file")
stroke_follow :: proc(app: ^App, input: Viewport_Input, samples: []Input_Sample, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	if !st.active {
		clear(&st.pending) // left by a stroke that ended before it caught up
	} else if st.size != input.size {
		// The viewport changed size, so earlier positions no longer match the view: the
		// stroke picks up where the pointer is now.
		clear(&st.pending)
		if len(samples) == 0 do return
		st.pos, st.pressure, st.travel, st.size = samples[0].pos, samples[0].pressure, 0, input.size
	}
	queue := samples
	if len(st.pending) > 0 {
		q := make([]Input_Sample, len(st.pending) + len(samples), context.temp_allocator)
		copy(q, st.pending[:])
		copy(q[len(st.pending):], samples)
		clear(&st.pending)
		queue = q
	}
	inv := linalg.inverse(camera.orbit_proj(app.camera, input.size.x / input.size.y) * camera.orbit_view(app.camera))
	for s, i in queue {
		if !st.active {
			stroke_start(app, input, inv, s, res)
			continue
		}
		obj := object_by_id(app, st.object)
		if obj == nil {
			st.active = false
			return
		}
		target := s.pos
		if lazy := app.brush.lazy_px; lazy > 0 {
			// The brush trails the cursor on a string `lazy` pixels long.
			d := s.pos - st.pos
			l := linalg.length(d)
			if l <= lazy do continue
			target = st.pos + d * (1 - lazy / l)
		}
		if !stroke_walk(app, obj, input, inv, target, s.pressure, res) {
			rest := queue[i:]
			if len(rest) > MAX_PENDING_SAMPLES do rest = rest[len(rest) - MAX_PENDING_SAMPLES:]
			append(&st.pending, ..rest)
			return
		}
	}
}

// Starts a stroke at `s` if it is over an object: that object becomes the selected
// one and gets the first dab.
@(private = "file")
stroke_start :: proc(app: ^App, input: Viewport_Input, inv: matrix[4, 4]f32, s: Input_Sample, res: ^Sculpt_Frame_Result) {
	origin, dir := ray_through(inv, s.pos, input.size)
	t0 := time.tick_now()
	index, hit, ok := scene_raycast(app, origin, dir)
	res.raycast_ms += time.duration_milliseconds(time.tick_since(t0))
	if !ok do return
	app.scene.selected = index
	obj := selected_object(app)
	st := &app.stroke
	st.active, st.object = true, obj.id
	st.pos, st.pressure, st.travel, st.size = s.pos, s.pressure, 0, input.size
	clear(&st.pending)
	sculpt.sculptor_stroke_begin(object_sculptor(obj))
	local := to_local(obj.transform, hit)
	t1 := time.tick_now()
	sculpt.apply_dab(object_sculptor(obj), brush_at(app, input, obj.transform, local, s.pressure), local)
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
	res.dabs += 1
}

// Moves the stroke in a straight line on screen to `target`, where the pressure is
// `pressure`, with a dab every spacing pixels. Returns false, with the stroke stopped
// partway, once the frame has used MAX_DABS_PER_FRAME dabs.
@(private = "file")
stroke_walk :: proc(app: ^App, obj: ^Object, input: Viewport_Input, inv: matrix[4, 4]f32, target: [2]f32, pressure: f32, res: ^Sculpt_Frame_Result) -> bool {
	st := &app.stroke
	for {
		d := target - st.pos
		l := linalg.length(d)
		// Pressure can shrink the spacing below what has been travelled already; the
		// dab then goes where the stroke is.
		need := max(DAB_SPACING * brush_radius_px(app, st.pressure), MIN_DAB_SPACING_PX) - st.travel
		if l < need {
			st.travel += l
			st.pos, st.pressure = target, pressure
			return true
		}
		if res.dabs >= MAX_DABS_PER_FRAME do return false
		if need > 0 {
			f := need / l
			st.pos += d * f
			st.pressure += (pressure - st.pressure) * f
		}
		st.travel = 0
		stroke_dab(app, obj, input, inv, st.pos, st.pressure, res)
	}
}

// Raycasts one point of the stroke's path and dabs where it meets the stroke's object.
// A point off the object is skipped; the stroke carries on and resumes where the path
// meets the surface again.
@(private = "file")
stroke_dab :: proc(app: ^App, obj: ^Object, input: Viewport_Input, inv: matrix[4, 4]f32, pos: [2]f32, pressure: f32, res: ^Sculpt_Frame_Result) {
	origin, dir := ray_through(inv, pos, input.size)
	t := obj.transform
	t0 := time.tick_now()
	hit, ok := sculpt.sculptor_raycast(object_sculptor(obj), to_local(t, origin), dir)
	res.raycast_ms += time.duration_milliseconds(time.tick_since(t0))
	if !ok do return
	t1 := time.tick_now()
	sculpt.apply_dab(object_sculptor(obj), brush_at(app, input, t, hit, pressure), hit)
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
	res.dabs += 1
}

// The brush for a dab at `hit` (in the object's local space): the radius in pixels,
// scaled by pen pressure if set, becomes world units at the hit's distance.
@(private = "file")
brush_at :: proc(app: ^App, input: Viewport_Input, t: Transform, hit: Vec3, pressure: f32) -> sculpt.Brush {
	dist := linalg.length(to_world(t, hit) - camera.orbit_eye(app.camera))
	world_per_px := 2 * dist * math.tan(app.camera.fov_y / 2) / input.size.y
	strength := app.brush.strength
	if app.brush.pressure_strength do strength *= pressure
	return sculpt.Brush {
		kind     = .Smooth if input.smooth else app.brush.kind,
		radius   = brush_radius_px(app, pressure) * world_per_px / t.scale,
		strength = strength,
		invert   = input.invert,
	}
}

brush_radius_px :: proc(app: ^App, pressure: f32) -> f32 {
	if !app.brush.pressure_size do return app.brush.radius_px
	return app.brush.radius_px * max(pressure, MIN_PRESSURE_SIZE)
}

// World-space ray through a viewport point (origin at the top-left).
mouse_ray :: proc(c: camera.Orbit, pos, size: [2]f32) -> (origin, dir: sculpt.Vec3) {
	return ray_through(linalg.inverse(camera.orbit_proj(c, size.x / size.y) * camera.orbit_view(c)), pos, size)
}

// mouse_ray with the inverse of the camera's projection times view already worked out.
ray_through :: proc(inv: matrix[4, 4]f32, pos, size: [2]f32) -> (origin, dir: sculpt.Vec3) {
	ndc := [2]f32{2 * pos.x / size.x - 1, 1 - 2 * pos.y / size.y}
	near := inv * [4]f32{ndc.x, ndc.y, 0, 1}
	far := inv * [4]f32{ndc.x, ndc.y, 1, 1}
	origin = near.xyz / near.w
	dir = linalg.normalize(far.xyz / far.w - origin)
	return
}

// Synthetic input for --bench-stroke: a wavy left-to-right drag across the first
// object as it appears on screen, or with `loops`, that many circles around its
// middle. With `samples_per_frame` above 1, each frame also carries that many pointer
// samples along the path since the previous frame, like a high-rate mouse.
bench_input :: proc(app: ^App, frame, total, samples_per_frame, loops: int, size: [2]f32) -> Viewport_Input {
	center, radius := first_object_on_screen(app, size)
	steps := f32(max(total - 1, 1))
	path :: proc(center: [2]f32, radius, t: f32, loops: int) -> [2]f32 {
		if loops > 0 {
			a := 2 * math.PI * f32(loops) * t
			return center + 0.5 * radius * [2]f32{math.cos(a), math.sin(a)}
		}
		return center + radius * [2]f32{-0.6 + 1.2 * t, 0.3 * math.sin(t * 4 * math.PI)}
	}
	input := bench_drag(size, path(center, radius, f32(frame) / steps, loops))
	if samples_per_frame > 1 && frame > 0 {
		samples := make([]Input_Sample, samples_per_frame, context.temp_allocator)
		for &s, j in samples {
			t := (f32(frame - 1) + f32(j + 1) / f32(samples_per_frame)) / steps
			s = {pos = path(center, radius, t, loops), pressure = 1}
		}
		input.samples = samples
	}
	return input
}

// A left-button drag at `pos`, as the viewport panel would report it.
bench_drag :: proc(size, pos: [2]f32) -> Viewport_Input {
	return {size = size, mouse_pos = pos, hovered = true, dragging = true, primary = true}
}

// Centre and radius in pixels of the first object's bounding sphere (a unit sphere in
// its local space), or a circle in the middle of the viewport when there is none.
first_object_on_screen :: proc(app: ^App, size: [2]f32) -> (center: [2]f32, radius: f32) {
	center, radius = size * 0.5, size.y * 0.3
	if len(app.scene.objects) == 0 do return
	obj := app.scene.objects[0]
	view_proj := camera.orbit_proj(app.camera, size.x / size.y) * camera.orbit_view(app.camera)
	to_px :: proc(m: matrix[4, 4]f32, p: Vec3, size: [2]f32) -> [2]f32 {
		c := m * [4]f32{p.x, p.y, p.z, 1}
		return {(c.x / c.w * 0.5 + 0.5) * size.x, (0.5 - c.y / c.w * 0.5) * size.y}
	}
	center = to_px(view_proj, obj.transform.position, size)
	up := Vec3{0, obj.transform.scale, 0}
	radius = linalg.length(to_px(view_proj, obj.transform.position + up, size) - center)
	return
}
