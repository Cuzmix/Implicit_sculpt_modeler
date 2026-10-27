package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../geom"
import "../sculpt"
import "../voxel"

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
	lock_plane:        bool, // keep the plane the stroke's first dab found (sculpt.Brush.lock_plane)
	connected:         bool, // work only on what joins the dab's centre through the surface (sculpt.Brush.connected)
	grab_depth:        bool, // Grab reaches through the whole depth under the brush (sculpt.Brush.through)
	smooth_only:       sculpt.Smooth_Only, // which vertices Smooth evens out: all, valleys or peaks
	stroke:            Stroke_Mode,
	spray_spread:      f32, // Spray: how far from the path dabs scatter, in brush radii
	// Spray: how far each dab's paint colour strays from the brush's, 0 to 1 (Colour spray).
	color_spray:       f32,
	// Dots: brush radii between dabs on screen (the lazy step); 0 for DAB_SPACING.
	spacing:           f32,
	line:              bool, // every stroke a straight line from its press (Stroke.line)
	join:              bool, // a press near where the last stroke ended carries it on (Stroke_End)
	symmetry:          sculpt.Symmetry, // mirror strokes across these planes of the object
	// Local symmetry: the planes (and the radial axis) pass through the object's own middle
	// instead of its origin (symmetry_center).
	sym_local:         bool,
	// Radial symmetry: while on, every dab has radial_count copies evenly round radial_axis.
	radial_on:         bool,
	radial_count:      i32,
	radial_axis:       sculpt.Axis,
	// On objects with dynamic topology: edges under the brush longer than this many
	// pixels on screen split, and with collapse, ones much shorter merge.
	detail_px:         f32,
	collapse:          bool,
	alpha:             int, // index into App.alphas; -1 (or any other outside it) is the round brush
	alpha_mode:        Alpha_Mode,
	alpha_angle:       f32, // degrees counter-clockwise the image turns on top of what the mode gives
	color:             [3]f32, // what the Paint brush paints, sRGB 0 to 1
	// The secondary colour, which Swap colours trades with `color` (V, or a long press on
	// the brush bar's Colour).
	color2:            [3]f32,
	// What every sculpting brush changes: the surface, it and the polypaint, or only the
	// polypaint (sculpt.Channel; the brush bar's channel button cycles them).
	channel:           sculpt.Channel,
	cloth_mode:        sculpt.Cloth_Mode, // what the Cloth brush does
	// The preset the brush is on (presets.odin), from 1; 0 on a plain brush. While on
	// one, `plain` keeps the plain brush's values that leaving it puts back.
	preset:            int,
	plain:             Preset_Values,
}

// How a left drag lays the brush down.
// The values are kept in .strokes files and settings by name, so new modes go last.
Stroke_Mode :: enum u8 {
	Dots,      // dabs along the path, DAB_SPACING radii apart
	Drag_Rect, // one dab where the drag started, sized and turned by how far and which way it goes (ZBrush's DragRect)
	Spray,     // dabs scattered about the path, each its own size, strength and turn (ZBrush's Spray)
	Roll,      // dabs a diameter apart, the alpha's top along the stroke, so an alpha tiles like a rolled tape (ZBrush's Roll)
	Drag_Dot,  // one dab at the brush's size that slides with the pointer until let go (ZBrush's DragDot)
}

STROKE_MODE_NAMES := [Stroke_Mode]string {
	.Dots      = "Dots",
	.Drag_Rect = "Rectangle",
	.Spray     = "Spray",
	.Roll      = "Roll",
	.Drag_Dot  = "Drag dot",
}

// A brush's falloff: the built-in smooth one, or a curve the user drew (read from the
// rim in: sculpt.falloff_set_shaped), reshaped by its focal shift.
Falloff_Setting :: struct {
	drawn: bool,
	curve: geom.Curve,
	focal: f32, // sculpt.FOCAL_MIN to FOCAL_MAX; 0 leaves the shape as it is
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
	rect:     bool, // a Drag rectangle or Drag dot stroke: redoes its one dab as the pointer moves
	start:    [2]f32, // Drag rectangle: where on screen the drag began
	at:       Vec3, // ...and where that is on the object, in its own space
	anchor:   Vec3, // Grab: where the stroke started; Snake hook: where it has pulled to (world space)
	// The brush the stroke started with, Shift's Smooth and the rail's Mask included: kept
	// for the whole stroke, so Shift or a brush key pressed mid-stroke changes nothing.
	kind:     sculpt.Brush_Kind,
	held:     bool, // ...and whether that is the brush held, with its alpha and stroke mode
	mode:     Stroke_Mode, // the held brush's stroke mode as it began; Dots for any other
	invert:   bool, // whether it started inverted, for the History panel
	// What its brush's strength is multiplied by: Touch strength for a finger, 1 for the
	// pen and mouse, or what a replay recorded (App.stroke_scale_from).
	scale:    f32,
	// The stroke's random numbers (Spray's scatter, a Random alpha's turn) come from its
	// seed (App.stroke_seed, kept by the recorder) and the step, one a dab, so a replayed
	// stroke lands the same dabs; turn is a Spray dab's turn of the alpha, for
	// alpha_screen_angle.
	seed:     u64,
	step:     u32,
	turn:     f32,
	// A straight line (Shift or the rail's Smooth pressed mid-stroke, or the Line switch):
	// while it is held, what the stroke did is put back and laid again from line_from to
	// the pointer whenever the pointer moves, so it stays one undo step. line_to is where
	// the line being laid goes, line_done whether it got there (a long line can take more
	// than a frame's dabs), aim where the pointer is now, with its pressure and lean.
	line:          bool,
	line_from:     [2]f32,
	line_to:       [2]f32,
	line_done:     bool,
	line_aim:      Input_Sample,
	// Shift was let go: the line is laid to the last place it was held at, then the
	// samples since (kept in pending) are walked freehand from its end.
	line_leaving:  bool,
	smooth_was:    bool, // input.smooth in the frame before, to see Shift go down
	// A stroke that joined the last one (Stroke_End): the way it was going and how far
	// it had gone since its last dab, and its locked plane, for a straight line laid
	// again from the join.
	joined:        bool,
	join_dir:      [2]f32,
	join_travel:   f32,
	join_locked:   sculpt.Locked_Plane,

	// The sum and count of the points it dabbed, in its object's space: their mean is the
	// pivot orbits turn about once it ends (Stroke_Pivot).
	pivot_sum:   Vec3,
	pivot_count: int,
}

// Where the last stroke laying dabs ended, for Join strokes: a press within SNAP_PX of
// it on the same object, in the same view, carries that stroke on from there, its
// spacing and direction included, so a line drawn in pieces has no blob or gap at the
// joins. Replays start and stop without one.
Stroke_End :: struct {
	valid:  bool,
	object: int,
	pos:    [2]f32,
	dir:    [2]f32,
	travel: f32,
	size:   [2]f32,
	camera: camera.Orbit,
	locked: sculpt.Locked_Plane, // its Lock plane, which a stroke joining it keeps
	// How many strokes joined one before, and how many straight lines were laid, for
	// the exit stats.
	joins, lines: int,
}

// How near the last stroke's end a press joins it: about a fingertip, so a finger or
// pen lifted and put down again on the same spot finds it.
SNAP_PX :: 24

Sculpt_Frame_Result :: struct {
	dabs:       int,
	raycast_ms: f64,
	brush_ms:   f64,
}

DAB_SPACING :: 0.25 // brush radii between dabs, measured on screen
SPRAY_SPACING :: 0.5 // ...for Spray, whose scattered dabs need fewer to cover the path
ROLL_SPACING :: 2 // ...for Roll: one diameter, so the alpha's images meet edge to edge
SPRAY_MAX_SPREAD :: 1.5
SPRAY_DEFAULT_SPREAD :: 0.6
// Spray's dabs are this share of the brush at the smallest and full size at the largest,
// and this share of its strength at the weakest.
SPRAY_SIZE_LOW :: 0.75
SPRAY_STRENGTH_LOW :: 0.5
MIN_DAB_SPACING_PX :: 1
MAX_DABS_PER_FRAME :: 64 // the rest of the path waits for the next frame
// ...and once the frame's dabs have taken this long, as they can when dynamic topology
// has many triangles to make, so the frame rate holds and the stroke catches up later.
// A run on the interface's fixed clock (--ui-dt) has no such limit: where the stroke
// stops would depend on how busy the machine is, and the dabs after it on that.
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
		line_complete(app, input, &res)
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
			line_complete(app, input, &res)
			stroke_finish(app)
		}
		samples = samples[press:]
	}
	// A release in the samples ends the stroke there, even where the button still reads
	// as held: a replayed or synthetic frame need not agree with its samples.
	rest := until_release(samples)
	stroke_follow(app, input, rest, &res)
	if len(rest) < len(samples) {
		line_complete(app, input, &res)
		stroke_finish(app)
	}
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
		// A straight line under way stays as it was laid, since where it began is lost.
		clear(&st.pending)
		st.line = false
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
		if len(queue) == 0 do return
		if st.mode == .Drag_Dot do dot_follow(app, input, inv, queue[len(queue) - 1], res)
		else do rect_follow(app, input, queue[len(queue) - 1], res)
		return
	}
	// Shift (or the rail's Smooth) going down mid-stroke turns it into a straight line;
	// held from the press it smooths instead (stroke_brush). The frame the button comes up
	// in reads as no Shift (input.smooth needs the button), so it keeps the frame before's.
	shift := input.smooth if input.primary else st.smooth_was
	if st.active {
		if shift && !st.smooth_was && !st.line && line_allowed(app) do line_begin(app)
		st.smooth_was = shift
		if st.line {
			line_follow(app, input, inv, queue, shift, res)
			return
		}
	}
	for s, i in queue {
		if !st.active {
			stroke_start(app, input, inv, s, res)
			// With the Line switch on, the rest of the press's frame goes to the line.
			if st.line {
				line_follow(app, input, inv, queue[i + 1:], shift, res)
				return
			}
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
	// A deformer's Amount held by another finger owns the object's undo until let go.
	if app.ui.deform.drag.active do return
	index, hit, ok := scene_raycast(app, origin, dir)
	res.raycast_ms += time.duration_milliseconds(time.tick_since(t0))
	if !ok do return
	app.scene.selected = index
	obj := selected_object(app)
	// The Paint brush, or a sculpting brush held with the channel on Colour, only paints.
	color_only := held_brush(input) && app.brush.channel == .Color && channel_brush(stroke_brush(app, input))
	if (color_only || .Paint in BRUSHES[stroke_brush(app, input)].flags) && (object_in_hd(obj) || object_dynamic(obj)) {
		// Said once a press; the stroke never starts, so nothing records it.
		if s.kind == .Press do _ = paint_allowed(obj)
		return
	}
	if color_only && obj.voxel != nil {
		if s.kind == .Press do report(app, Kit_Section.Paint_Color, {.Warning}, "Voxel clay has no polypaint: set the brush's channel to Sculpt, or convert the object to a mesh")
		return
	}
	if stroke_brush(app, input) == .History && !recall_ready(app, obj, s.kind == .Press) do return
	if obj.voxel != nil && !voxel_brush_allowed(app, stroke_brush(app, input), s.kind == .Press) do return
	st := &app.stroke
	st.active, st.object = true, obj.id
	st.kind, st.held = stroke_brush(app, input), held_brush(input)
	st.seed, st.step, st.turn = app.stroke_seed, 0, 0
	app.stroke_seed += 1
	st.scale = app.stroke_scale_from if app.stroke_scale_from > 0 else (app.nav.touch_strength if app.device.pointer == .Finger else 1)
	st.pos, st.pressure, st.tilt, st.travel, st.size = s.pos, s.pressure, s.tilt, 0, input.size
	st.dir = {}
	st.line, st.line_leaving, st.joined, st.smooth_was = false, false, false, input.smooth
	clear(&st.pending)
	sculpt.sculptor_stroke_begin(object_sculptor(obj))
	if vp := obj.voxel; vp != nil do voxel.clay_stroke_begin(&vp.clay)
	// The mode before the first dab's brush, whose alpha turn reads it.
	flags := BRUSHES[st.kind].flags
	st.mode = app.brush.stroke if st.held && flags & {.Grab, .Hook, .Cloth} == {} else .Dots
	if (st.mode == .Drag_Rect || st.mode == .Drag_Dot) && object_dynamic(obj) do st.mode = .Dots
	// A voxel dab has no alpha to lay along a tape and no stroke to put back and redo.
	if obj.voxel != nil && (st.mode == .Drag_Rect || st.mode == .Roll || st.mode == .Drag_Dot) do st.mode = .Dots
	st.rect = st.mode == .Drag_Rect || st.mode == .Drag_Dot
	local := to_local(obj.transform, hit)
	brush := brush_at(app, input, obj.transform, local, s.pressure, s.tilt)
	st.grab, st.hook, st.anchor, st.invert = .Grab in flags, .Hook in flags, hit, brush.invert
	st.cloth = .Cloth in flags && !object_dynamic(obj)
	if .Cloth in flags && !st.cloth do log.warn("cloth: not with dynamic topology on")
	st.start, st.at = s.pos, local
	st.pivot_sum, st.pivot_count = local, 1
	// A drag dot lays its dab at the press, then slides it.
	if st.mode == .Drag_Dot {
		stroke_dab(app, obj, input, inv, s.pos, s.pressure, s.tilt, res)
		return
	}
	if st.hook || st.rect do return // they move nothing until the pointer does
	if app.brush.line && line_allowed(app) {
		line_begin(app)
		st.line_to = st.pos // laid again once the pointer moves
	}
	if !st.grab && !st.cloth {
		if end, joins := stroke_joins(app, obj, s.pos, input.size); joins {
			// It carries on from where the last stroke ended, as if the pointer had never
			// let go, and walks to the press.
			st.pos, st.dir, st.travel, st.start = end.pos, end.dir, end.travel, end.pos
			st.line_from, st.line_to = end.pos, end.pos
			st.joined, st.join_dir, st.join_travel, st.join_locked = true, end.dir, end.travel, end.locked
			sculpt.sculptor_lock_plane(object_sculptor(obj), end.locked)
			app.stroke_end.joins += 1
			_ = stroke_walk(app, obj, input, inv, s.pos, s.pressure, s.tilt, res)
			return
		}
	}
	switch st.mode {
	case .Roll:
		// The first image waits until the pointer has gone a radius, so the stroke has a
		// direction for its top and the tape starts where the press was.
		st.travel = brush_radius_px(app, s.pressure)
		return
	case .Spray:
		spray_dab(app, obj, input, inv, s.pos, s.pressure, s.tilt, res)
		return
	case .Dots, .Drag_Rect, .Drag_Dot:
	}
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
		object_dab(app, obj, brush, local, object_normal_local(obj, local))
	}
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
	res.dabs += 1
}

// The surface normal at `at` (the object's space) for a voxel object's first dab, whose
// press found the object but not the way its surface faces; zero for a mesh, whose dabs
// work it out themselves.
@(private = "file")
object_normal_local :: proc(obj: ^Object, at: Vec3) -> Vec3 {
	if vp := obj.voxel; vp != nil do return voxel.volume_gradient(&vp.clay.volume, at)
	return {}
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

// Slides a Drag dot stroke's dab to the pointer sample `s`: where the pointer meets the
// object, what the stroke did so far is put back and its one dab laid there. Off the
// object, the dab stays where it was.
@(private = "file")
dot_follow :: proc(app: ^App, input: Viewport_Input, inv: matrix[4, 4]f32, s: Input_Sample, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	obj := object_by_id(app, st.object)
	if obj == nil {
		st.active = false
		return
	}
	if s.pos == st.pos do return
	origin, dir := ray_through(inv, s.pos, input.size)
	t := obj.transform
	t0 := time.tick_now()
	_, _, ok := object_raycast_local(obj, to_local(t, origin), to_local_dir(t, dir))
	res.raycast_ms += time.duration_milliseconds(time.tick_since(t0))
	if !ok do return
	st.pos, st.pressure, st.tilt = s.pos, s.pressure, s.tilt
	// The dab is laid on the surface as it was before the stroke, found again after the
	// put back, so the dot never stacks on itself.
	_ = sculpt.sculptor_stroke_restore(object_sculptor(obj))
	st.pivot_sum, st.pivot_count = {}, 0
	stroke_dab(app, obj, input, inv, s.pos, s.pressure, s.tilt, res)
}

// Moves the stroke in a straight line on screen to `target`, where the pressure is
// `pressure` and the pen leans `tilt`, with a dab every spacing pixels. Returns false,
// with the stroke stopped partway, once the frame has used MAX_DABS_PER_FRAME dabs or
// MAX_BRUSH_MS_PER_FRAME (only on the real clock).
@(private = "file")
stroke_walk :: proc(app: ^App, obj: ^Object, input: Viewport_Input, inv: matrix[4, 4]f32, target: [2]f32, pressure: f32, tilt: [2]f32, res: ^Sculpt_Frame_Result, bounded := true) -> bool {
	st := &app.stroke
	for {
		d := target - st.pos
		l := linalg.length(d)
		// Pressure can shrink the spacing below what has been travelled already; the
		// dab then goes where the stroke is.
		need := max(stroke_spacing(app, st.mode) * brush_radius_px(app, st.pressure), MIN_DAB_SPACING_PX) - st.travel
		if l > 0 do st.dir = d / l
		if l < need {
			st.travel += l
			st.pos, st.pressure, st.tilt = target, pressure, tilt
			return true
		}
		slow := app.kit.fixed_dt == 0 && res.brush_ms + res.raycast_ms >= MAX_BRUSH_MS_PER_FRAME
		if bounded && (res.dabs >= MAX_DABS_PER_FRAME || slow) do return false
		if need > 0 {
			f := need / l
			st.pos += d * f
			st.pressure += (pressure - st.pressure) * f
			st.tilt += (tilt - st.tilt) * f
		}
		st.travel = 0
		if st.mode == .Spray do spray_dab(app, obj, input, inv, st.pos, st.pressure, st.tilt, res)
		else do stroke_dab(app, obj, input, inv, st.pos, st.pressure, st.tilt, res)
	}
}

// Whether the stroke under way can become a straight line: one laying dabs along its
// path, on an object whose stroke can be put back (not with dynamic topology, whose
// strokes change the triangles).
@(private = "file")
line_allowed :: proc(app: ^App) -> bool {
	st := &app.stroke
	if st.grab || st.hook || st.cloth || st.rect do return false
	obj := object_by_id(app, st.object)
	return obj != nil && !object_dynamic(obj)
}

// Turns the stroke under way into a straight line from where it began.
@(private = "file")
line_begin :: proc(app: ^App) {
	st := &app.stroke
	st.line, st.line_from, st.line_to, st.line_done, st.line_leaving = true, st.start, {max(f32), max(f32)}, true, false
	st.line_aim = {pos = st.pos, pressure = st.pressure, tilt = st.tilt}
	clear(&st.pending)
	app.stroke_end.lines += 1
}

// A frame of a straight line. While Shift is held (`shift`, or the Line switch), the line
// is laid again to the pointer once the last time it was laid has got there: a long line
// can take more than a frame's dabs. Once Shift is let go, the line is laid to where the
// pointer last was with it held, then the stroke carries on freehand from there through
// the samples since. So where a line ends depends only on the samples, never on how fast
// the frames were, and a replay lays it the same.
@(private = "file")
line_follow :: proc(app: ^App, input: Viewport_Input, inv: matrix[4, 4]f32, queue: []Input_Sample, shift: bool, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	held := shift || app.brush.line
	if held {
		st.line_leaving = false
		if len(queue) > 0 do st.line_aim = queue[len(queue) - 1]
	} else {
		st.line_leaving = true
		append(&st.pending, ..queue)
	}
	_ = line_lay(app, input, inv, res, bounded = true)
}

// Lays the line to its aim: the redo under way first, then again from its start if the
// aim has moved since. Once it is there and Shift was let go, the stroke goes back to
// freehand, the samples waiting in pending first. Returns true when nothing is left.
@(private = "file")
line_lay :: proc(app: ^App, input: Viewport_Input, inv: matrix[4, 4]f32, res: ^Sculpt_Frame_Result, bounded: bool) -> bool {
	st := &app.stroke
	obj := object_by_id(app, st.object)
	if obj == nil {
		st.active = false
		return true
	}
	aim := st.line_aim
	if !st.line_done {
		if !stroke_walk(app, obj, input, inv, st.line_to, aim.pressure, aim.tilt, res, bounded) do return false
		st.line_done = true
	}
	if aim.pos != st.line_to {
		if !sculpt.sculptor_stroke_restore(object_sculptor(obj)) {
			st.line = false
			return true
		}
		st.line_to = aim.pos
		stroke_restart(app, obj, input, inv, st.line_from, aim.pressure, aim.tilt, res)
		st.line_done = stroke_walk(app, obj, input, inv, st.line_to, aim.pressure, aim.tilt, res, bounded)
		if !st.line_done do return false
	}
	if st.line_leaving {
		st.line, st.line_leaving = false, false
		st.pressure, st.tilt = aim.pressure, aim.tilt
	}
	return true
}

// Finishes a straight line not yet laid to its aim, whatever it costs in one frame, and
// the freehand samples after a let-go Shift, before the stroke ends there.
@(private = "file")
line_complete :: proc(app: ^App, input: Viewport_Input, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	if !st.active || !st.line || input.size.x <= 0 || input.size.y <= 0 do return
	obj := object_by_id(app, st.object)
	if obj == nil do return
	inv := linalg.inverse(camera.orbit_proj(app.camera, input.size.x / input.size.y) * camera.orbit_view(app.camera))
	_ = line_lay(app, input, inv, res, bounded = false)
	if st.line do return
	for s in st.pending do _ = stroke_walk(app, obj, input, inv, s.pos, s.pressure, s.tilt, res, bounded = false)
	clear(&st.pending)
}

// Starts the stroke under way again at `pos`, with nothing laid yet, as stroke_start
// starts one laying dabs: the first dab there (scattered for Spray; Roll's after a
// radius).
@(private = "file")
stroke_restart :: proc(app: ^App, obj: ^Object, input: Viewport_Input, inv: matrix[4, 4]f32, pos: [2]f32, pressure: f32, tilt: [2]f32, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	st.pos, st.pressure, st.tilt, st.travel, st.dir = pos, pressure, tilt, 0, {}
	st.step, st.turn, st.pivot_sum, st.pivot_count = 0, 0, {}, 0
	if st.joined {
		// A joined stroke goes on from the last one's end as it did at its press, with no
		// first dab of its own, and on its plane.
		st.dir, st.travel = st.join_dir, st.join_travel
		sculpt.sculptor_lock_plane(object_sculptor(obj), st.join_locked)
		return
	}
	switch st.mode {
	case .Roll:  st.travel = brush_radius_px(app, pressure)
	case .Spray: spray_dab(app, obj, input, inv, pos, pressure, tilt, res)
	case .Dots, .Drag_Rect, .Drag_Dot: stroke_dab(app, obj, input, inv, pos, pressure, tilt, res)
	}
}

// The end of the last stroke a press at `pos` on `obj` joins, with Join strokes on:
// within SNAP_PX of it, on the same object, in the same view.
@(private = "file")
stroke_joins :: proc(app: ^App, obj: ^Object, pos, size: [2]f32) -> (Stroke_End, bool) {
	e := app.stroke_end
	if !app.brush.join || !e.valid || e.object != obj.id || e.size != size || e.camera != app.camera do return {}, false
	return e, linalg.length(pos - e.pos) <= SNAP_PX
}

// Brush radii between a stroke's dabs on screen, for its mode: Dots' as set (the lazy
// step).
@(private = "file")
stroke_spacing :: proc(app: ^App, mode: Stroke_Mode) -> f32 {
	#partial switch mode {
	case .Spray: return SPRAY_SPACING
	case .Roll:  return ROLL_SPACING
	}
	return dot_spacing(app)
}

// Brush radii between Dots' dabs: the Spacing setting, or DAB_SPACING when unset.
dot_spacing :: proc(app: ^App) -> f32 {
	return dot_spacing_of(app.brush)
}

// The same for the brush settings `b`.
dot_spacing_of :: proc(b: Brush_Settings) -> f32 {
	return clamp(b.spacing, MIN_SPACING, MAX_SPACING) if b.spacing > 0 else DAB_SPACING
}

MIN_SPACING :: 0.05
MAX_SPACING :: 2

// One Spray dab for the stroke at `pos`: scattered up to the spread from it on screen,
// with its own size, strength and, with an alpha, turn, all drawn from the stroke's seed
// and step.
@(private = "file")
spray_dab :: proc(app: ^App, obj: ^Object, input: Viewport_Input, inv: matrix[4, 4]f32, pos: [2]f32, pressure: f32, tilt: [2]f32, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	step := st.step
	st.step += 1
	// Uniform over the disc: the square root keeps the middle from crowding.
	r := app.brush.spray_spread * brush_radius_px(app, pressure) * math.sqrt(stroke_random(st.seed, step, 0))
	a := 2 * math.PI * stroke_random(st.seed, step, 1)
	scatter := Dab_Scatter {
		size     = 1 - (1 - SPRAY_SIZE_LOW) * stroke_random(st.seed, step, 2),
		strength = 1 - (1 - SPRAY_STRENGTH_LOW) * stroke_random(st.seed, step, 3),
	}
	st.turn = 2 * math.PI * stroke_random(st.seed, step, 4)
	// Colour spray: each of the paint's channels its own share brighter or darker.
	if v := app.brush.color_spray; v > 0 {
		for k in 0 ..< 3 do scatter.tint[k] = 1 + v * (2 * stroke_random(st.seed, step, 5 + u32(k)) - 1)
	}
	stroke_dab(app, obj, input, inv, pos + r * [2]f32{math.cos(a), math.sin(a)}, pressure, tilt, res, scatter)
}

// A number from 0 up to 1 for draw `k` of step `step` of the stroke seeded `seed`:
// SplitMix64's finaliser over the three, so every stroke, step and draw has its own and
// the same ones always give the same number.
stroke_random :: proc(seed: u64, step, k: u32) -> f32 {
	z := seed * 0x9e3779b97f4a7c15 + (u64(step) << 3 | u64(k)) * 0xd1b54a32d192ed03
	z = (z ~ z >> 30) * 0xbf58476d1ce4e5b9
	z = (z ~ z >> 27) * 0x94d049bb133111eb
	z ~= z >> 31
	return f32(z >> 40) / f32(1 << 24)
}

// How a stroke mode changes one dab from the brush as set: its size and strength as
// shares of the brush's.
Dab_Scatter :: struct {
	size, strength: f32,
	tint:           [3]f32, // what each channel of its paint colour is multiplied by; zero for as set
}

// Raycasts one point of the stroke's path and dabs where it meets the stroke's object.
// A point off the object is skipped; the stroke carries on and resumes where the path
// meets the surface again.
@(private = "file")
stroke_dab :: proc(app: ^App, obj: ^Object, input: Viewport_Input, inv: matrix[4, 4]f32, pos: [2]f32, pressure: f32, tilt: [2]f32, res: ^Sculpt_Frame_Result, scatter := Dab_Scatter{size = 1, strength = 1}) {
	origin, dir := ray_through(inv, pos, input.size)
	t := obj.transform
	t0 := time.tick_now()
	hit, normal, ok := object_raycast_local(obj, to_local(t, origin), to_local_dir(t, dir))
	res.raycast_ms += time.duration_milliseconds(time.tick_since(t0))
	if !ok do return
	app.stroke.pivot_sum += hit
	app.stroke.pivot_count += 1
	t1 := time.tick_now()
	brush := brush_at(app, input, t, hit, pressure, tilt)
	// Dynamic topology's edge length is a share of the radius: kept as set.
	brush.radius *= scatter.size
	brush.detail /= scatter.size
	brush.strength *= scatter.strength
	if scatter.tint != {} {
		for k in 0 ..< 3 do brush.color[k] = u8(clamp(f32(brush.color[k]) * scatter.tint[k], 0, 255) + 0.5)
	}
	object_dab(app, obj, brush, hit, normal)
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

// The brush for a dab of the stroke under way at `hit` (in the object's local space),
// the kind its press chose (Stroke.kind): the radius in pixels,
// scaled by pen pressure if set, becomes world units at the hit's distance, and a
// leaning pen turns it as far as the tilt strength says. The pen's turn and the alpha's
// up are worked out in world space and turned into the object's.
@(private = "file")
brush_at :: proc(app: ^App, input: Viewport_Input, t: Transform, hit: Vec3, pressure: f32, tilt: [2]f32) -> sculpt.Brush {
	world_per_px := camera.orbit_world_per_px(app.camera, to_world(t, hit), input.size.y)
	kind := app.stroke.kind
	// Shift smooths at the Smooth brush's strength, not the strength of the brush held, and
	// the rail's Mask masks at the Mask brush's.
	strength := app.brush.strengths[kind]
	if app.brush.pressure_strength do strength *= pressure_curved(app, pressure)
	strength *= app.stroke.scale
	turn: matrix[3, 3]f32
	if app.brush.tilt_strength > 0 && tilt != {} {
		r := transform_rotation(t)
		turn = linalg.transpose(r) * camera.orbit_tilt(app.camera, tilt, app.brush.tilt_strength) * r
	}
	alpha := brush_alpha(app) if app.stroke.held else nil
	up: Vec3
	if alpha != nil do up = to_local_dir(t, alpha_world_up(app))
	facing: Vec3
	if app.brush.front_only do facing = to_local_dir(t, -camera.orbit_toward(app.camera, to_world(t, hit)))
	through: Vec3
	if kind == .Grab && app.brush.grab_depth do through = to_local_dir(t, camera.orbit_toward(app.camera, to_world(t, hit)))
	sym := brush_symmetry(app, selected_object(app))
	return sculpt.Brush {
		kind     = kind,
		radius   = brush_radius_px(app, pressure) * world_per_px / t.scale,
		strength = strength,
		invert   = input.invert,
		symmetry = sym.symmetry,
		radial   = sym.radial,
		radial_axis = sym.radial_axis,
		sym_center = sym.sym_center,
		detail   = app.brush.detail_px / brush_radius_px(app, pressure),
		collapse = app.brush.collapse,
		tilt     = turn,
		alpha    = alpha,
		alpha_up = up,
		falloff_shape = brush_falloff(app, kind),
		facing   = facing,
		color    = brush_color_bytes(app),
		channel  = brush_channel(app, selected_object(app)) if app.stroke.held else .Sculpt,
		lock_plane = app.brush.lock_plane,
		connected  = app.brush.connected,
		through    = through,
		smooth_only = app.brush.smooth_only if kind == .Smooth else .All,
	}
}

// The falloff of the brush `kind` as a table, made from its curve and focal shift, or nil
// for the built-in one unshifted, which the dabs work out themselves.
brush_falloff :: proc(app: ^App, kind: sculpt.Brush_Kind) -> ^sculpt.Falloff {
	f := app.brush.falloffs[kind]
	if !f.drawn && f.focal == 0 do return nil
	// Only what shapes the table counts: an undrawn curve is not read.
	if !f.drawn do f.curve = {}
	table := &app.falloff_tables[kind]
	if table.shape != f || !table.built {
		sculpt.falloff_set_shaped(&table.falloff, f.curve if f.drawn else nil, f.focal)
		table.shape, table.built = f, true
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
