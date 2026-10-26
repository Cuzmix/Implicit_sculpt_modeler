package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../geom"
import "../sculpt"

// Brush settings as the user edits them. Radius is in screen pixels, converted to
// world units at each dab's hit point so the brush feels the same at any zoom.
Brush_Settings :: struct {
	kind:              sculpt.Brush_Kind,
	radius_px:         f32,
	strengths:         [sculpt.Brush_Kind]f32, // each brush's own (brush_strength)
	falloffs:          [sculpt.Brush_Kind]Falloff_Setting, // each brush's own, too
	pressure_strength: bool, // pen pressure scales the strength
	pressure_size:     bool, // pen pressure scales the radius
	pressure_curve:    geom.Curve, // what each pen pressure counts as (geom.curve_at)
	tilt_strength:     f32, // 0 to 1: how far a leaning pen turns the brush (camera.orbit_tilt)
	lazy_px:           f32,  // lazy mouse: the brush trails the cursor by this many pixels; 0 is off
	front_only:        bool, // brushes and mask shapes leave what faces away from the viewer (sculpt.Brush.facing)
	stroke:            Stroke_Mode,
	symmetry:          sculpt.Symmetry, // mirror strokes across these planes of the object
	// On objects with dynamic topology: edges under the brush longer than this many
	// pixels on screen split, and with collapse, ones much shorter merge.
	detail_px:         f32,
	collapse:          bool,
	alpha:             int, // index into App.alphas; -1 (or any other outside it) is the round brush
	alpha_mode:        Alpha_Mode,
	alpha_angle:       f32, // degrees counter-clockwise the image turns on top of what the mode gives
	color:             [3]f32, // what the Paint brush paints, sRGB 0 to 1
	cloth_mode:        sculpt.Cloth_Mode, // what the Cloth brush does
	// The preset the brush is on (presets.odin), from 1; 0 on a plain brush. While on
	// one, `plain` keeps the plain brush's values that leaving it puts back.
	preset:            int,
	plain:             Preset_Values,
}

// How a left drag lays the brush down.
Stroke_Mode :: enum u8 {
	Dots,      // dabs along the path, DAB_SPACING radii apart
	Drag_Rect, // one dab where the drag started, sized and turned by how far and which way it goes (ZBrush's DragRect)
}

// A brush's falloff: the built-in smooth one, or a curve the user drew (read from the
// rim in: sculpt.falloff_set_curve).
Falloff_Setting :: struct {
	drawn: bool,
	curve: geom.Curve,
}

// One pointer sample as SDL reported it. The app keeps every motion event of a frame,
// not just the last, so a fast stroke follows the path the pointer really took.
// Positions are in window coordinates in App.samples and viewport-local in
// Viewport_Input.samples.
Input_Sample :: struct {
	pos:      [2]f32,
	pressure: f32, // 0 to 1 from a pen; 1 from a mouse
	kind:     Sample_Kind,
	tilt:     [2]f32, // the pen's lean in degrees (x right, y down); zero from a mouse
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
	tilt:     [2]f32, // pen lean at pos
	dir:      [2]f32, // the way the stroke last moved on screen, unit length; zero before it has
	travel:   f32, // pixels moved since the last dab
	size:     [2]f32, // viewport size the positions above are in
	pending:  [dynamic]Input_Sample, // samples left for the next frame once one reaches MAX_DABS_PER_FRAME
	grab:     bool, // a Grab stroke: drags what it picked up instead of laying dabs
	cloth:    bool, // a Cloth stroke: simulates the region it began on every frame (sculpt.Cloth)
	hook:     bool, // a Snake hook stroke: drags the surface along after the pointer
	rect:     bool, // a Drag rectangle stroke: redoes its one dab at `start` as the pointer moves
	start:    [2]f32, // Drag rectangle: where on screen the drag began
	at:       Vec3, // ...and where that is on the object, in its own space
	anchor:   Vec3, // Grab: where the stroke started; Snake hook: where it has pulled to (world space)
	kind:     sculpt.Brush_Kind, // the brush the stroke started with, Shift's Smooth included, for the History panel
	invert:   bool, // ...and whether it was inverted
	// The sum and count of the points it dabbed, in its object's space: their mean is the
	// pivot orbits turn about once it ends (Stroke_Pivot).
	pivot_sum:   Vec3,
	pivot_count: int,
}

Sculpt_Frame_Result :: struct {
	dabs:       int,
	raycast_ms: f64,
	brush_ms:   f64,
}

DAB_SPACING :: 0.25 // brush radii between dabs, measured on screen
MIN_DAB_SPACING_PX :: 1
MAX_DABS_PER_FRAME :: 64 // the rest of the path waits for the next frame
// ...and once the frame's dabs have taken this long, as they can when dynamic topology
// has many triangles to make, so the frame rate holds and the stroke catches up later.
MAX_BRUSH_MS_PER_FRAME :: 10
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
	cursor := [1]Input_Sample{{pos = input.mouse_pos, pressure = 1, tilt = input.pen_tilt}}
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
	// A release in the samples ends the stroke there, even where the button still reads
	// as held: a replayed or synthetic frame need not agree with its samples.
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
		st.pos, st.pressure, st.tilt, st.travel, st.size = samples[0].pos, samples[0].pressure, samples[0].tilt, 0, input.size
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
	if st.active && st.grab {
		if len(queue) > 0 do grab_follow(app, input, inv, queue[len(queue) - 1].pos, res)
		return
	}
	if st.active && st.cloth {
		// The cloth moves on every frame of the stroke, held still or not.
		cloth_follow(app, input, inv, queue[len(queue) - 1].pos if len(queue) > 0 else st.pos, res)
		return
	}
	if st.active && st.hook {
		for s in queue do hook_follow(app, input, inv, s, res)
		return
	}
	if st.active && st.rect {
		if len(queue) > 0 do rect_follow(app, input, queue[len(queue) - 1], res)
		return
	}
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
		if !stroke_walk(app, obj, input, inv, target, s.pressure, s.tilt, res) {
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
	if .Paint in BRUSHES[stroke_brush(app, input)].flags && (object_in_hd(obj) || object_dynamic(obj)) {
		// Said once a press; the stroke never starts, so nothing records it.
		if s.kind == .Press do _ = paint_allowed(obj)
		return
	}
	st := &app.stroke
	st.active, st.object = true, obj.id
	st.pos, st.pressure, st.tilt, st.travel, st.size = s.pos, s.pressure, s.tilt, 0, input.size
	st.dir = {}
	clear(&st.pending)
	sculpt.sculptor_stroke_begin(object_sculptor(obj))
	local := to_local(obj.transform, hit)
	brush := brush_at(app, input, obj.transform, local, s.pressure, s.tilt)
	flags := BRUSHES[brush.kind].flags
	st.grab, st.hook, st.anchor, st.kind, st.invert = .Grab in flags, .Hook in flags, hit, brush.kind, brush.invert
	st.cloth = .Cloth in flags && !object_dynamic(obj)
	if .Cloth in flags && !st.cloth do log.warn("cloth: not with dynamic topology on")
	st.rect = app.brush.stroke == .Drag_Rect && !st.grab && !st.hook && .Cloth not_in flags && held_brush(input) && !object_dynamic(obj)
	st.start, st.at = s.pos, local
	st.pivot_sum, st.pivot_count = local, 1
	if st.hook || st.rect do return // they move nothing until the pointer does
	t1 := time.tick_now()
	if st.grab {
		sculpt.sculptor_grab_begin(object_sculptor(obj), brush, local)
	} else if st.cloth {
		mode := app.brush.cloth_mode
		if brush.invert && mode == .Pinch do mode = .Expand
		else if brush.invert && mode == .Expand do mode = .Pinch
		sculpt.sculptor_cloth_begin(object_sculptor(obj), brush, local, mode)
		return
	} else {
		sculpt.apply_dab(object_sculptor(obj), brush, local)
	}
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
	res.dabs += 1
}

// Drags what a Grab stroke picked up so its anchor follows the pointer at `pos`, on
// the plane through the anchor facing the camera. Only the frame's last sample counts:
// the grab goes straight to where the pointer is.
@(private = "file")
grab_follow :: proc(app: ^App, input: Viewport_Input, inv: matrix[4, 4]f32, pos: [2]f32, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	obj := object_by_id(app, st.object)
	if obj == nil {
		st.active = false
		return
	}
	origin, dir := ray_through(inv, pos, input.size)
	facing := camera.orbit_toward(app.camera, st.anchor)
	along := linalg.dot(dir, facing)
	if abs(along) < 1e-6 do return
	t := linalg.dot(st.anchor - origin, facing) / along
	offset := to_local_dir(obj.transform, origin + dir * t - st.anchor) / obj.transform.scale
	st.pos = pos
	t1 := time.tick_now()
	sculpt.sculptor_grab_move(object_sculptor(obj), offset)
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
	res.dabs += 1
}

// Steps a Cloth stroke's simulation once, with the pointer at `pos`: Drag pulls what
// was under the brush after the pointer on the plane through where it began facing the
// camera, as Grab does; Gravity pulls toward the bottom of the screen (the top when
// inverted).
@(private = "file")
cloth_follow :: proc(app: ^App, input: Viewport_Input, inv: matrix[4, 4]f32, pos: [2]f32, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	obj := object_by_id(app, st.object)
	if obj == nil {
		st.active = false
		return
	}
	t := obj.transform
	offset: Vec3
	origin, dir := ray_through(inv, pos, input.size)
	facing := camera.orbit_toward(app.camera, st.anchor)
	if along := linalg.dot(dir, facing); abs(along) > 1e-6 {
		hit := origin + dir * (linalg.dot(st.anchor - origin, facing) / along)
		offset = to_local_dir(t, hit - st.anchor) / t.scale
	}
	view := camera.orbit_view(app.camera)
	down := -to_local_dir(t, Vec3{view[1, 0], view[1, 1], view[1, 2]})
	if input.invert do down = -down
	st.pos = pos
	t1 := time.tick_now()
	sculpt.sculptor_cloth_step(object_sculptor(obj), offset, linalg.normalize0(down))
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
	res.dabs += 1
}

// Pulls a Snake hook stroke after the pointer sample `s`: the point where the stroke
// has got to follows the pointer on the plane through it facing the camera, and each
// step of the way, at most DAB_SPACING radii long, drags the surface around it along,
// as Blender's and ZBrush's snake hooks do. Nothing is raycast: the hook leaves the
// surface it started on.
@(private = "file")
hook_follow :: proc(app: ^App, input: Viewport_Input, inv: matrix[4, 4]f32, s: Input_Sample, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	obj := object_by_id(app, st.object)
	if obj == nil {
		st.active = false
		return
	}
	origin, dir := ray_through(inv, s.pos, input.size)
	facing := camera.orbit_toward(app.camera, st.anchor)
	along := linalg.dot(dir, facing)
	if abs(along) < 1e-6 do return
	t := obj.transform
	offset := origin + dir * (linalg.dot(st.anchor - origin, facing) / along) - st.anchor
	st.pos, st.pressure, st.tilt = s.pos, s.pressure, s.tilt
	brush := brush_at(app, input, t, to_local(t, st.anchor), s.pressure, s.tilt)
	step := max(brush.radius * t.scale * DAB_SPACING, 1e-6)
	steps := min(int(math.ceil(linalg.length(offset) / step)), MAX_DABS_PER_FRAME)
	t1 := time.tick_now()
	for _ in 0 ..< steps {
		part := offset / f32(steps)
		brush.drag = to_local_dir(t, part) / t.scale
		sculpt.apply_dab(object_sculptor(obj), brush, to_local(t, st.anchor))
		st.anchor += part
		res.dabs += 1
	}
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
}

// Redoes a Drag rectangle stroke's dab for the pointer sample `s`: what the stroke did
// so far is put back, then one dab at the point where the drag began, its radius the
// drag's length on screen and, with an alpha, the image's top toward the pointer.
@(private = "file")
rect_follow :: proc(app: ^App, input: Viewport_Input, s: Input_Sample, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	obj := object_by_id(app, st.object)
	if obj == nil {
		st.active = false
		return
	}
	d := s.pos - st.start
	length := linalg.length(d)
	if length < 2 || s.pos == st.pos do return
	st.pos, st.pressure, st.tilt = s.pos, s.pressure, s.tilt
	t := obj.transform
	t1 := time.tick_now()
	sculptor := object_sculptor(obj)
	_ = sculpt.sculptor_stroke_restore(sculptor)
	brush := brush_at(app, input, t, st.at, s.pressure, s.tilt)
	brush.radius = length * camera.orbit_world_per_px(app.camera, to_world(t, st.at), input.size.y) / t.scale
	if brush.alpha != nil {
		view := camera.orbit_view(app.camera)
		right := Vec3{view[0, 0], view[0, 1], view[0, 2]}
		up := Vec3{view[1, 0], view[1, 1], view[1, 2]}
		brush.alpha_up = to_local_dir(t, linalg.normalize(right * d.x - up * d.y))
	}
	sculpt.apply_dab(sculptor, brush, st.at)
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
	res.dabs += 1
}

// Moves the stroke in a straight line on screen to `target`, where the pressure is
// `pressure` and the pen leans `tilt`, with a dab every spacing pixels. Returns false,
// with the stroke stopped partway, once the frame has used MAX_DABS_PER_FRAME dabs or
// MAX_BRUSH_MS_PER_FRAME.
@(private = "file")
stroke_walk :: proc(app: ^App, obj: ^Object, input: Viewport_Input, inv: matrix[4, 4]f32, target: [2]f32, pressure: f32, tilt: [2]f32, res: ^Sculpt_Frame_Result) -> bool {
	st := &app.stroke
	for {
		d := target - st.pos
		l := linalg.length(d)
		// Pressure can shrink the spacing below what has been travelled already; the
		// dab then goes where the stroke is.
		need := max(DAB_SPACING * brush_radius_px(app, st.pressure), MIN_DAB_SPACING_PX) - st.travel
		if l > 0 do st.dir = d / l
		if l < need {
			st.travel += l
			st.pos, st.pressure, st.tilt = target, pressure, tilt
			return true
		}
		if res.dabs >= MAX_DABS_PER_FRAME || res.brush_ms + res.raycast_ms >= MAX_BRUSH_MS_PER_FRAME do return false
		if need > 0 {
			f := need / l
			st.pos += d * f
			st.pressure += (pressure - st.pressure) * f
			st.tilt += (tilt - st.tilt) * f
		}
		st.travel = 0
		stroke_dab(app, obj, input, inv, st.pos, st.pressure, st.tilt, res)
	}
}

// Raycasts one point of the stroke's path and dabs where it meets the stroke's object.
// A point off the object is skipped; the stroke carries on and resumes where the path
// meets the surface again.
@(private = "file")
stroke_dab :: proc(app: ^App, obj: ^Object, input: Viewport_Input, inv: matrix[4, 4]f32, pos: [2]f32, pressure: f32, tilt: [2]f32, res: ^Sculpt_Frame_Result) {
	origin, dir := ray_through(inv, pos, input.size)
	t := obj.transform
	t0 := time.tick_now()
	hit, ok := sculpt.sculptor_raycast(object_sculptor(obj), to_local(t, origin), to_local_dir(t, dir))
	res.raycast_ms += time.duration_milliseconds(time.tick_since(t0))
	if !ok do return
	app.stroke.pivot_sum += hit
	app.stroke.pivot_count += 1
	t1 := time.tick_now()
	sculpt.apply_dab(object_sculptor(obj), brush_at(app, input, t, hit, pressure, tilt), hit)
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
	res.dabs += 1
}

// The brush a stroke pressed with `input` uses: Smooth for Shift (or the rail's Smooth),
// Mask for the rail's Mask, or else the brush held.
stroke_brush :: proc(app: ^App, input: Viewport_Input) -> sculpt.Brush_Kind {
	if input.mask do return .Mask
	if input.smooth do return .Smooth
	return app.brush.kind
}

// Whether a stroke pressed with `input` uses the brush held, and with it the brush's own
// alpha and stroke mode, rather than Smooth or Mask standing in for it.
held_brush :: proc(input: Viewport_Input) -> bool {
	return !input.smooth && !input.mask
}

// The brush for a dab at `hit` (in the object's local space): the radius in pixels,
// scaled by pen pressure if set, becomes world units at the hit's distance, and a
// leaning pen turns it as far as the tilt strength says. The pen's turn and the alpha's
// up are worked out in world space and turned into the object's.
@(private = "file")
brush_at :: proc(app: ^App, input: Viewport_Input, t: Transform, hit: Vec3, pressure: f32, tilt: [2]f32) -> sculpt.Brush {
	world_per_px := camera.orbit_world_per_px(app.camera, to_world(t, hit), input.size.y)
	kind := stroke_brush(app, input)
	// Shift smooths at the Smooth brush's strength, not the strength of the brush held, and
	// the rail's Mask masks at the Mask brush's.
	strength := app.brush.strengths[kind]
	if app.brush.pressure_strength do strength *= pressure_curved(app, pressure)
	turn: matrix[3, 3]f32
	if app.brush.tilt_strength > 0 && tilt != {} {
		r := transform_rotation(t)
		turn = linalg.transpose(r) * camera.orbit_tilt(app.camera, tilt, app.brush.tilt_strength) * r
	}
	alpha := brush_alpha(app) if held_brush(input) else nil
	up: Vec3
	if alpha != nil do up = to_local_dir(t, alpha_world_up(app))
	facing: Vec3
	if app.brush.front_only do facing = to_local_dir(t, -camera.orbit_toward(app.camera, to_world(t, hit)))
	return sculpt.Brush {
		kind     = kind,
		radius   = brush_radius_px(app, pressure) * world_per_px / t.scale,
		strength = strength,
		invert   = input.invert,
		symmetry = app.brush.symmetry,
		detail   = app.brush.detail_px / brush_radius_px(app, pressure),
		collapse = app.brush.collapse,
		tilt     = turn,
		alpha    = alpha,
		alpha_up = up,
		falloff_shape = brush_falloff(app, kind),
		facing   = facing,
		color    = brush_color_bytes(app),
	}
}

// The drawn falloff of the brush `kind`, made from its curve, or nil for the built-in.
brush_falloff :: proc(app: ^App, kind: sculpt.Brush_Kind) -> ^sculpt.Falloff {
	f := app.brush.falloffs[kind]
	if !f.drawn do return nil
	table := &app.falloff_tables[kind]
	if table.curve != f.curve || !table.built {
		sculpt.falloff_set_curve(&table.falloff, f.curve)
		table.curve, table.built = f.curve, true
	}
	return &table.falloff
}

brush_radius_px :: proc(app: ^App, pressure: f32) -> f32 {
	if !app.brush.pressure_size do return app.brush.radius_px
	return app.brush.radius_px * max(pressure_curved(app, pressure), MIN_PRESSURE_SIZE)
}

// What a pen pressure counts as, through the pressure curve. A mouse's 1 stays 1.
pressure_curved :: proc(app: ^App, pressure: f32) -> f32 {
	return geom.curve_at(app.brush.pressure_curve, pressure)
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
// samples along the path since the previous frame, like a high-rate mouse. The pen
// leans `tilt` throughout.
bench_input :: proc(app: ^App, frame, total, samples_per_frame, loops: int, tilt: [2]f32, size: [2]f32) -> Viewport_Input {
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
	input.pen_tilt = tilt
	if samples_per_frame > 1 && frame > 0 {
		samples := make([]Input_Sample, samples_per_frame, context.temp_allocator)
		for &s, j in samples {
			t := (f32(frame - 1) + f32(j + 1) / f32(samples_per_frame)) / steps
			s = {pos = path(center, radius, t, loops), pressure = 1, tilt = tilt}
		}
		input.samples = samples
	}
	return input
}

// A left-button drag at `pos`, as the viewport would report it.
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
