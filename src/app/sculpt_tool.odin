package main

import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../geom"
import "../sculpt"
import "../ui"
import "../voxel"

// Brush settings as the user edits them. Radius is in screen pixels, converted to
// world units at each dab's hit point so the brush feels the same at any zoom.
Brush_Settings :: struct {
	kind:              sculpt.Brush_Kind,
	radius_px:         f32,
	strengths:         [sculpt.Brush_Kind]f32, // each brush's own (brush_strength)
	falloffs:          [sculpt.Brush_Kind]Falloff_Setting, // each brush's own, too
	// What pen pressure does, for every brush that uses the global setting (brush_pressure):
	pressure_strength: bool, // pen pressure scales the strength
	pressure_size:     bool, // pen pressure scales the radius
	pressure_curve:    geom.Curve, // what each pen pressure counts as for the strength (geom.curve_at)
	pressure_size_curve: geom.Curve, // and for the size
	pressure_size_floor: f32, // the smallest share of the radius pressure shrinks it to (Pressure.size_floor)
	// Each brush's own pressure, used in place of the global one where `own` is set (Use
	// global off), as ZBrush and Nomad let a brush keep its own curves.
	pressures:         [sculpt.Brush_Kind]Pressure_Own,
	tilt_strength:     f32, // 0 to 1: how far a leaning pen turns the brush (camera.orbit_tilt)
	// 0 to 1 each: how much a pen laid down toward the paper grows the brush (up to twice
	// its size) and lightens it (down to nothing), as a pencil's side shades wide and soft.
	tilt_size:         f32,
	tilt_soften:       f32,
	lazy_px:           f32,  // lazy mouse: the brush trails the cursor by this many pixels; 0 is off
	// The stabiliser (stroke_steady): the brush follows the mean of this many of the
	// pointer's newest positions, and of the pen's newest pressures; 1 (or less) is off.
	// Whole numbers up to STEADY_MAX.
	smoothing:          f32,
	pressure_smoothing: f32,
	// When the pen lifts, the stroke goes on to where it was lifted, past the lazy
	// string and the smoothing's lag, so the line ends under the pen.
	catch_up:           bool,
	front_only:        bool, // brushes and mask shapes leave what faces away from the viewer (sculpt.Brush.facing)
	lock_plane:        bool, // keep the plane the stroke's first dab found (sculpt.Brush.lock_plane)
	connected:         bool, // work only on what joins the dab's centre through the surface (sculpt.Brush.connected)
	grab_depth:        bool, // Grab reaches through the whole depth under the brush (sculpt.Brush.through)
	// Grab: which way the drag moves what it picked up (Shift mid-grab takes Along normal,
	// Alt Along surface), how much of a Free drag goes along the normal instead (Blender's
	// Normal weight), and Same side and Silhouette (sculpt.Brush).
	grab_mode:         Grab_Mode,
	grab_normal:       f32,
	grab_same_side:    bool,
	grab_silhouette:   bool,
	// Grab's falloff measured along the surface (sculpt.Brush.topological).
	grab_topological:  bool,
	// Grab and Elastic take hold from a press just past the model's outline too, at the
	// nearest surface within the ring (Nomad's Move); off, a press off the model turns the
	// view for them as for every brush, as ZBrush's Move does.
	grab_outline:      bool,
	// Elastic: how much of its volume the pulled solid keeps, 0 to 1 (sculpt.Brush.volume).
	elastic_volume:    f32,
	// Snake hook: Pinch (below 0 Magnify), Rake and the Elastic tip (sculpt.Brush.hook_*).
	hook_pinch:        f32,
	hook_rake:         f32,
	hook_elastic:      bool,
	smooth_only:       sculpt.Smooth_Only, // which vertices Smooth evens out: all, valleys or peaks
	smooth_stable:     bool, // Smooth's passes follow the mesh's density (sculpt.Brush.smooth_stable)
	smooth_mode:       sculpt.Smooth_Mode, // how Smooth evens out: Smooth, Relax or Polish
	// The Samples section (sculpt.Brush.stabilize, sample_radius, no_accumulate): how
	// much of the stroke's mean normal and plane a dab keeps, the share of the radius the
	// area is sampled over, and per brush whether a stroke over itself builds up (false:
	// Accumulate on, which Draw starts without).
	stabilize:         f32,
	sample_radius:     f32,
	no_accumulate:     [sculpt.Brush_Kind]bool,
	stroke:            Stroke_Mode,
	spray_spread:      f32, // Spray: how far from the path dabs scatter, in brush radii
	// Spray: how far each dab's paint colour strays from the brush's, 0 to 1 (Colour spray).
	color_spray:       f32,
	// Dots: brush radii between dabs on screen (the lazy step); 0 for DAB_SPACING.
	spacing:           f32,
	// Dots: each dab's strength scaled so a stroke builds the same height at any spacing
	// as at SPACING_REFERENCE (spacing_strength), as Blender's Adjust strength for spacing.
	even_strength:     bool,
	// Dots: the spacing is measured along the surface rather than on screen, so a stroke
	// over a part turned away keeps its dabs as far apart on the model (scene_spacing_px).
	scene_spacing:     bool,
	// Symmetry's images near a plane or the radial axis share the strength they overlap
	// by (sculpt.Brush.feather).
	feather:           bool,
	line:              bool, // every stroke a straight line from its press (Stroke.line)
	// Dots: No back and forth (ZBrush's), dabs only while the stroke goes the way it first
	// went, so a zigzag lays parallel hatching; Directional, dabs only while it moves away
	// from where it was pressed (stroke_way_allowed).
	one_way:           bool,
	directional:       bool,
	// Size fixed in the scene (ZBrush's Dynamic size, Nomad's Constant): each pixel of
	// radius_px stands for size_ref world units, taken from the view's middle when it was
	// turned on (0 until then), so zooming in makes the brush bigger on screen and the
	// stroke keeps the same size on the model (brush_size_scale).
	size_world:        bool,
	size_ref:          f32,
	// Clay strips' tip (sculpt.Brush.tip_roundness, tip_scale), Trim dynamic's angle in
	// degrees and whether it is sampled (sculpt.Brush.trim_angle, trim_fixed), and
	// Flatten's reach above and below its plane, 0 to 1 of the radius
	// (sculpt.Brush.plane_short).
	tip_roundness:     f32,
	tip_scale:         f32,
	trim_angle:        f32,
	trim_dynamic:      bool,
	plane_height:      f32,
	plane_depth:       f32,
	join:              bool, // a press near where the last stroke ended carries it on (Stroke_End)
	// Hold to edit: a stroke ended with the pen held still this many seconds becomes a curve to
	// edit before it is kept (stroke_edit.odin), as Nomad's editable strokes.
	hold_edit:         bool,
	hold_edit_s:       f32,
	// How far the fitted curve may stray from the dabs, in brush radii: more, fewer points.
	hold_edit_smoothness: f32,
	symmetry:          sculpt.Symmetry, // mirror strokes across these planes of the object
	// Local symmetry: the planes (and the radial axis) pass through the object's own middle
	// instead of its origin (symmetry_center).
	sym_local:         bool,
	// Radial symmetry: while on, every dab has radial_count copies evenly round radial_axis.
	radial_on:         bool,
	radial_count:      i32,
	radial_axis:       sculpt.Axis,
	// On objects with dynamic topology: edges under the brush longer than this many
	// pixels on screen split, and with collapse, ones much shorter merge. With
	// detail_by_radius the length is detail_radius of the brush's radius instead (Blender's
	// Brush detail), so a small brush adds fine triangles and a large one coarse ones
	// at any zoom.
	detail_px:         f32,
	detail_by_radius:  bool,
	detail_radius:     f32,
	collapse:          bool,
	// The detail eases off with the brush's falloff (sculpt.Brush.detail_falloff).
	detail_falloff:    bool,
	// Each brush's own dynamic topology: whether it changes triangles at all, and its own
	// detail where it keeps one (Use global off).
	dyns:              [sculpt.Brush_Kind]Dyn_Own,
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
	// The painting channel (Both or Color) the Paint toggle turns back on (paint_toggle.odin).
	paint_on:          sculpt.Channel,
	// While painting (the Paint brush, or a sculpting brush with the channel on Colour),
	// Smooth blurs the paint and Invert takes it off, instead of smoothing the surface and
	// digging it (painting): Paint's Blur and Erase in the dial, as Nomad and Procreate
	// have them.
	paint_dial:        bool,
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

// The stroke modes as their tabs show them: an icon over a short name, the full name in
// the tooltip (stroke_tabs).
STROKE_MODE_SHORT := [Stroke_Mode]string {
	.Dots      = "Dots",
	.Drag_Rect = "Rect",
	.Spray     = "Spray",
	.Roll      = "Roll",
	.Drag_Dot  = "Drag",
}
STROKE_MODE_ICONS := [Stroke_Mode]rune {
	.Dots      = rune(0xe0ba), // Lucide ellipsis
	.Drag_Rect = rune(0xe37a), // rectangle-horizontal
	.Spray     = rune(0xe49a), // spray-can
	.Roll      = rune(0xe5a3), // paint-roller
	.Drag_Dot  = rune(0xe495), // move-right
}

// A brush's falloff: the built-in smooth one, or a curve the user drew (read from the
// rim in: sculpt.falloff_set_shaped), reshaped by its hardness and focal shift, and
// measured round a ball or across the view (sculpt.Brush.projected).
Falloff_Setting :: struct {
	drawn:     bool,
	curve:     geom.Curve,
	focal:     f32, // sculpt.FOCAL_MIN to FOCAL_MAX; 0 leaves the shape as it is
	hardness:  f32, // 0 to sculpt.HARDNESS_MAX: the share of the radius at full strength
	projected: bool, // Falloff shape Projected rather than Sphere
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
	// How squarely the surface under the last dab faces the view (|cos|), which Scene
	// spacing divides by; 0 before the first dab.
	facing:   f32,
	// Even strength's scale for this stroke's dabs (spacing_strength), or Accumulate off's
	// (once_strength); 0 until worked out.
	even:     f32,
	// Size fixed in the scene: how many screen pixels a pixel of radius_px is at the last
	// dab (brush_size_scale); 0 before it.
	size_scale: f32,
	// No back and forth: the way the stroke first moved on screen, zero before it has.
	first_dir:  [2]f32,
	// Where the last dab was, in the object's space (last_set once there is one), which
	// the way the stroke goes is measured from (sculpt.Brush.stroke_dir).
	last_at:    Vec3,
	last_set:   bool,
	size:     [2]f32, // viewport size the positions above are in
	pending:  [dynamic]Input_Sample, // samples left for the next frame once one reaches MAX_DABS_PER_FRAME
	// The stabiliser's newest raw samples, newest first (`steady_count` of them), and
	// whether pending's first was taken in already (a frame ran out partway to it).
	steady:       [STEADY_MAX]Input_Sample,
	steady_count: int,
	steady_taken: bool,
	raw:          Input_Sample, // the pointer's newest sample as it came, where catching up goes
	grab:     bool, // a Grab stroke: drags what it picked up instead of laying dabs
	cloth:    bool, // a Cloth stroke: simulates the region it began on every frame (sculpt.Cloth)
	hook:     bool, // a Snake hook stroke: drags the surface along after the pointer
	rect:     bool, // a Drag rectangle or Drag dot stroke: redoes its one dab as the pointer moves
	start:    [2]f32, // Drag rectangle: where on screen the drag began
	at:       Vec3, // ...and where that is on the object, in its own space
	anchor:   Vec3, // Grab: where the stroke started; Snake hook: where it has pulled to (world space)
	// Snake hook: the way its last step went (world space, unit length; zero before the
	// first), which Rake turns what it drags by.
	hook_dir: Vec3,
	// Grab: the point under the press on the plane through the anchor facing the camera,
	// which the pointer's moves are measured from (the anchor itself, unless the press was
	// past the silhouette), and the area normal there (world space, unit length or zero).
	grab_from:   Vec3,
	grab_normal: Vec3,
	// Grab: the pen's roll as the stroke last saw it (degrees, from Viewport_Input.pen_roll)
	// and how far it has turned since the press, the short way round each time
	// (grab_twist_angle).
	grab_roll:   f32,
	grab_turned: f32,
	// Grab: how far what it picked up moves for each unit the pointer goes, from the
	// brush's Strength as the press found it (grab_gain).
	grab_gain:   f32,
	// The pen's pressure at the press: Grab's and Snake hook's strength keep it.
	press_pressure: f32,
	// The brush the stroke started with, Shift's Smooth and the rail's Mask included: kept
	// for the whole stroke, so Shift or a brush key pressed mid-stroke changes nothing.
	kind:     sculpt.Brush_Kind,
	held:     bool, // ...and whether that is the brush held, with its alpha and stroke mode
	mode:     Stroke_Mode, // the held brush's stroke mode as it began; Dots for any other
	invert:   bool, // whether it started inverted, for the History panel
	blur:     bool, // Smooth while painting: a Paint stroke that blurs the paint (painting)
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

	// Where its dabs landed, for Hold to edit to fit a curve to (stroke_edit.odin); freed when
	// the stroke ends.
	path:        [dynamic]Stroke_Path_Point,
	// Hold to edit's watch: where the pointer has stayed within HOLD_SLOP_PX of, and since when.
	still_pos:   [2]f32,
	still_since: f64,
}

// One dab of a stroke as Hold to edit fits a curve to it: where on the object it landed and
// the surface's normal there (the object's space), and its radius (the object's units) and
// strength before Even strength and any mode's scatter, with the pen's lean.
Stroke_Path_Point :: struct {
	at, normal: Vec3,
	radius:     f32,
	strength:   f32,
	tilt:       [2]f32,
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
	// How many strokes joined one before, how many straight lines were laid, and how many
	// strokes were held to edit, for the exit stats.
	joins, lines, edits: int,
}

// How near the last stroke's end a press joins it: about a fingertip, so a finger or
// pen lifted and put down again on the same spot finds it.
SNAP_PX :: 24

// Which way a Grab drags what it picked up: as the pointer goes, on the plane facing the
// camera (Free); along the surface's normal where it was pressed, toward where the normal
// points on screen pulling out (Normal: ZBrush's Shift, Nomad's Normal, 3D-Coat's Ctrl); or
// only across the surface, the normal part taken out (Surface: ZBrush's Alt, Blender's
// Nudge and Thumb).
Grab_Mode :: enum u8 {
	Free,
	Normal,
	Surface,
}

// Elastic's Volume as a fresh install has it: Poisson's ratio 0.4, as Blender's default.
ELASTIC_VOLUME_DEFAULT :: 0.8

// Along Normal with the normal facing the camera within this (the sine of its lean on
// screen), the drag's up on screen is its out, as there is no way on screen to follow.
GRAB_NORMAL_SCREEN_MIN :: 0.25

Sculpt_Frame_Result :: struct {
	dabs:       int,
	raycast_ms: f64,
	brush_ms:   f64,
}

DAB_SPACING :: 0.2 // brush radii between dabs, measured on screen
// The spacing every brush's strength was tuned at, the default until dabs came closer:
// with Even strength a stroke at any spacing builds the height one at this built.
SPACING_REFERENCE :: 0.25
// Scene spacing measures the gap along a surface turned away from the view by dividing by
// how far it is turned; past this share the dabs would come too close to be worth laying.
SCENE_SPACING_MIN_FACING :: 0.25
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
// The most pointer samples the stabiliser averages: at a pen's 240 Hz, a fifteenth of a
// second, past which the brush lags too far to steer.
STEADY_MAX :: 16
MIN_PRESSURE_SIZE :: 0.05 // smallest share of the radius pen pressure can shrink it to
// The lean from upright, in degrees, at which the tilt's size and softening are full: a
// pencil shades with its side at about this.
LEAN_FULL :: 60

// Turns this frame's pointer samples into brush dabs. A stroke sculpts the object it
// started on, which becomes the selected object. Dabs are laid along the path the
// pointer took on screen, DAB_SPACING radii apart, and each is raycast onto the
// surface, so a fast stroke follows the pointer and every dab lands on the surface.
sculpt_frame :: proc(app: ^App, input: Viewport_Input) -> (res: Sculpt_Frame_Result) {
	app.alpha_roll = input.pen_roll
	// How many samples a stroke's frames bring, for the exit stats (pen_samples.odin).
	defer if app.stroke.active do pen_samples_count(app, len(input.samples))
	if input.size.x <= 0 || input.size.y <= 0 {
		stroke_finish(app)
		return
	}
	// A stroke held to edit takes every frame, hovering and letting go included, until it is
	// kept or put back; a press away from its curve keeps it and starts the next stroke.
	if app.stroke_edit.open && stroke_edit_frame(app, input, &res) do return
	samples := input.samples
	cursor := [1]Input_Sample{{pos = input.mouse_pos, pressure = 1, tilt = input.pen_tilt}}
	if len(samples) == 0 do samples = cursor[:] // synthetic input has only the cursor position

	if !input.primary {
		// The button went up during the frame: the samples before that still count.
		if app.stroke.active {
			if rest := until_release(samples); len(rest) < len(samples) do stroke_follow(app, input, rest, &res)
		}
		stroke_catch_up(app, input, &res)
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
			stroke_catch_up(app, input, &res)
			line_complete(app, input, &res)
			stroke_finish(app)
		}
		samples = samples[press:]
	}
	// A release in the samples ends the stroke there, even where the button still reads
	// as held: a replayed or synthetic frame need not agree with its samples.
	rest := until_release(samples)
	stroke_follow(app, input, rest, &res)
	if len(rest) == len(samples) do stroke_hold_watch(app, input)
	if len(rest) < len(samples) {
		stroke_catch_up(app, input, &res)
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
		stroke_steady_start(st, samples[0])
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
		if !stroke_step(app, obj, input, inv, s, res) {
			rest := queue[i:]
			if len(rest) > MAX_PENDING_SAMPLES {
				rest = rest[len(rest) - MAX_PENDING_SAMPLES:]
				st.steady_taken = false
			}
			append(&st.pending, ..rest)
			return
		}
	}
}

// Moves a stroke laying dabs on toward the pointer sample `s`: through the stabiliser,
// then on the lazy string. Returns false, as stroke_walk does, when the frame ran out
// partway; the same sample then comes again first next frame, and is not taken into the
// stabiliser twice.
@(private = "file")
stroke_step :: proc(app: ^App, obj: ^Object, input: Viewport_Input, inv: matrix[4, 4]f32, s: Input_Sample, res: ^Sculpt_Frame_Result, bounded := true) -> bool {
	st := &app.stroke
	steady := stroke_steady(app, s)
	target := steady.pos
	if lazy := app.brush.lazy_px; lazy > 0 {
		// The brush trails the cursor on a string `lazy` pixels long.
		d := target - st.pos
		l := linalg.length(d)
		if l <= lazy do return true
		target = st.pos + d * (1 - lazy / l)
	}
	if !stroke_walk(app, obj, input, inv, target, steady.pressure, steady.tilt, res, bounded) {
		st.steady_taken = true
		return false
	}
	return true
}

// Takes the raw sample `s` into the stabiliser, unless it was taken already, and gives
// where the brush goes for it: the mean of the newest Smoothing positions and leans and
// of the newest Pressure smoothing pressures (ZBrush's Mouse Avg and Nomad's pressure
// smoothing; with both off, `s` itself).
@(private = "file")
stroke_steady :: proc(app: ^App, s: Input_Sample) -> Input_Sample {
	st := &app.stroke
	if st.steady_taken {
		st.steady_taken = false
	} else {
		copy(st.steady[1:], st.steady[:STEADY_MAX - 1])
		st.steady[0] = s
		st.steady_count = min(st.steady_count + 1, STEADY_MAX)
		st.raw = s
	}
	n := min(steady_count(app.brush.smoothing), st.steady_count)
	m := min(steady_count(app.brush.pressure_smoothing), st.steady_count)
	out := s
	if n > 1 {
		pos, tilt: [2]f32
		for k in 0 ..< n {
			pos += st.steady[k].pos
			tilt += st.steady[k].tilt
		}
		out.pos, out.tilt = pos / f32(n), tilt / f32(n)
	}
	if m > 1 {
		pressure: f32
		for k in 0 ..< m do pressure += st.steady[k].pressure
		out.pressure = pressure / f32(m)
	}
	return out
}

// How many samples a Smoothing or Pressure smoothing value `v` averages: 1 to STEADY_MAX.
steady_count :: proc(v: f32) -> int {
	return clamp(int(math.round(v)), 1, STEADY_MAX)
}

// Starts the stabiliser over at `s`, as at a press.
@(private = "file")
stroke_steady_start :: proc(st: ^Stroke, s: Input_Sample) {
	st.steady[0], st.steady_count, st.steady_taken, st.raw = s, 1, false, s
}

// Whether the brush of a stroke laying dabs can trail the pointer: on the lazy string or
// behind the smoothing's mean. The rope is drawn then, and catching up has a way to go.
stroke_trails :: proc(app: ^App) -> bool {
	return app.brush.lazy_px > 0 || steady_count(app.brush.smoothing) > 1
}

// The pen lifted (or the button came up): with Catch up on, a stroke laying dabs walks
// the samples still waiting and then on to where the pointer last was, so the line ends
// under the pen rather than a string's length or the smoothing's lag short of it (Krita's
// finish line, Toon Boom's catch up). Off, it ends where the brush had got to, as
// ZBrush's lazy mouse does.
@(private = "file")
stroke_catch_up :: proc(app: ^App, input: Viewport_Input, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	if !st.active || !app.brush.catch_up || !stroke_trails(app) do return
	if st.grab || st.hook || st.cloth || st.rect || st.line || input.size.x <= 0 || input.size.y <= 0 do return
	obj := object_by_id(app, st.object)
	if obj == nil do return
	inv := linalg.inverse(camera.orbit_proj(app.camera, input.size.x / input.size.y) * camera.orbit_view(app.camera))
	for s in st.pending do _ = stroke_step(app, obj, input, inv, s, res, bounded = false)
	clear(&st.pending)
	st.steady_taken = false
	_ = stroke_walk(app, obj, input, inv, st.raw.pos, st.raw.pressure, st.raw.tilt, res, bounded = false)
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
	// With Past the outline on, Grab takes hold from just past the silhouette too, as
	// Nomad's Move does: the nearest point of the surface within the brush ring.
	from := hit
	if !ok && app.brush.grab_outline && .Grab in BRUSHES[stroke_brush(app, input)].flags && s.kind == .Press {
		index, hit, ok = scene_grab_near(app, origin, dir, input.size)
		if ok {
			facing := camera.orbit_toward(app.camera, hit)
			if along := linalg.dot(dir, facing); abs(along) > 1e-6 do from = origin + dir * (linalg.dot(hit - origin, facing) / along)
		}
	}
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
	// The offer line already says why a press does nothing; the note says it otherwise.
	say := s.kind == .Press && !offer_standing(app)
	if obj.voxel != nil && !voxel_brush_allowed(app, stroke_brush(app, input), say) do return
	if !object_editable(app, obj, say) do return
	st := &app.stroke
	st.active, st.object = true, obj.id
	st.kind, st.held = stroke_brush(app, input), held_brush(input)
	st.blur = input.smooth && !input.mask && painting(app)
	st.seed, st.step, st.turn = app.stroke_seed, 0, 0
	app.stroke_seed += 1
	st.scale = app.stroke_scale_from if app.stroke_scale_from > 0 else (app.nav.touch_strength if app.device.pointer == .Finger else 1)
	st.pos, st.pressure, st.tilt, st.travel, st.size = s.pos, s.pressure, s.tilt, 0, input.size
	st.dir, st.facing, st.even, st.size_scale, st.first_dir = {}, 0, 0, 0, {}
	st.last_set = false
	st.line, st.line_leaving, st.joined, st.smooth_was = false, false, false, input.smooth
	clear(&st.pending)
	clear(&st.path)
	st.still_pos, st.still_since = s.pos, input_clock(app)
	stroke_steady_start(st, s)
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
	st.hook_dir = {}
	st.grab_from, st.grab_normal, st.press_pressure = from, {}, s.pressure
	st.grab_roll, st.grab_turned = input.pen_roll, 0
	st.grab_gain = grab_gain(app, st.kind)
	if st.grab && obj.voxel == nil {
		t := obj.transform
		if n, found := sculpt.sculptor_area_normal(object_sculptor(obj), local, 0.5 * brush.radius, to_local_dir(t, camera.orbit_toward(app.camera, hit))); found {
			st.grab_normal = linalg.normalize0(to_world_dir(t, n))
		}
	}
	st.cloth = .Cloth in flags
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
		st.travel = brush_radius_px(app, s.pressure, s.tilt)
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
	moved := grab_moved(app, input, origin + dir * t - st.grab_from, facing)
	offset := to_local_dir(obj.transform, moved) * (st.grab_gain / obj.transform.scale)
	st.pos = pos
	twist: sculpt.Grab_Twist
	if angle := grab_twist_angle(app, input.pen_roll); angle != 0 {
		// Clockwise seen from the pen's top turns what is held clockwise on screen: about
		// the way the view looks at it, which a viewer looking along sees clockwise.
		twist = {linalg.normalize0(to_local_dir(obj.transform, facing)), angle}
	}
	t1 := time.tick_now()
	sculpt.sculptor_grab_move(object_sculptor(obj), offset, twist)
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
	res.dabs += 1
}

// The radians a Grab turns what it holds for the pen's roll `roll` (degrees, as the frame
// reports it), as Nomad's Move turns with the Pencil Pro: the turn since the press, less
// the first ui.ROLL_ENGAGE degrees, which a hand turns the pen by while it drags; none
// with Settings > Pen's Roll while grabbing off. A pen that reports no roll stays at 0.
grab_twist_angle :: proc(app: ^App, roll: f32) -> f32 {
	st := &app.stroke
	d := roll - st.grab_roll
	d -= 360 * math.floor((d + 180) / 360)
	if abs(d) <= ROLL_JUMP do st.grab_turned += d
	st.grab_roll = roll
	if !app.nav.grab_twist || abs(st.grab_turned) <= ui.ROLL_ENGAGE do return 0
	return math.to_radians(st.grab_turned - math.sign(st.grab_turned) * ui.ROLL_ENGAGE)
}

// The Strength at which Grab and Elastic move what they picked up exactly as far as the
// pointer goes: their default, so the feel they had before Strength counted is the one
// a fresh brush has.
GRAB_STRENGTH_EXACT :: 0.5

// How far Grab or Elastic (`kind`) moves what it picked up for each unit the pointer goes,
// from the brush's Strength, as ZBrush's Move takes its Z Intensity and Blender's Grab its
// strength: GRAB_STRENGTH_EXACT follows the pointer, less lags behind it (a fine nudge at
// 0.05 moves a tenth as far), more runs ahead of it, twice as far at full strength. Pen
// pressure is left out: the press's own pressure, light as a press starts, would make
// the whole drag weak.
grab_gain :: proc(app: ^App, kind: sculpt.Brush_Kind) -> f32 {
	return app.brush.strengths[kind] / GRAB_STRENGTH_EXACT
}

// How a Grab moves what it picked up for the pointer having gone `drag` (world space, on
// the plane facing the camera along `facing`), by the stroke's mode (Grab_Mode): Shift
// held takes Along normal and Alt Along surface, else the brush's mode, Free blending
// toward along the normal by the Normal weight.
grab_moved :: proc(app: ^App, input: Viewport_Input, drag, facing: Vec3) -> Vec3 {
	n := app.stroke.grab_normal
	mode := app.brush.grab_mode
	if input.alt do mode = .Surface
	else if input.smooth do mode = .Normal
	if n == {} do return drag
	switch mode {
	case .Free:
		w := clamp(app.brush.grab_normal, 0, 1)
		if w == 0 do return drag
		return drag + (grab_along_normal(app, drag, n, facing) - drag) * w
	case .Normal:
		return grab_along_normal(app, drag, n, facing)
	case .Surface:
		return drag - linalg.dot(drag, n) * n
	}
	return drag
}

// The drag turned along the normal `n`: as far as the pointer went toward where the
// normal points on screen, out along it (back for the other way), so a drag of so many
// pixels moves the surface as far as a Free one would. With the normal facing the camera
// it has no way on screen, and up on the screen is out.
@(private = "file")
grab_along_normal :: proc(app: ^App, drag, n, facing: Vec3) -> Vec3 {
	on_screen := n - linalg.dot(n, facing) * facing
	if linalg.length(on_screen) < GRAB_NORMAL_SCREEN_MIN {
		view := camera.orbit_view(app.camera)
		on_screen = Vec3{view[1, 0], view[1, 1], view[1, 2]}
	}
	return linalg.dot(drag, linalg.normalize(on_screen)) * n
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
// step of the way, at most SPACING_REFERENCE radii long (the hook keeps the steps it was
// tuned at, which Dots' closer spacing leaves be), drags the surface around it along,
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
	// The pressure of the press holds for the whole hook, as Grab's does: a pen easing
	// off as it lifts would otherwise thin the tip it is drawing out.
	brush := brush_at(app, input, t, to_local(t, st.anchor), st.press_pressure, s.tilt)
	step := max(brush.radius * t.scale * SPACING_REFERENCE, 1e-6)
	steps := min(int(math.ceil(linalg.length(offset) / step)), MAX_DABS_PER_FRAME)
	t1 := time.tick_now()
	for _ in 0 ..< steps {
		part := offset / f32(steps)
		brush.drag = to_local_dir(t, part) / t.scale
		// Rake: how far the hook turned since the last step, about the axis it turned on.
		way := linalg.normalize0(part)
		brush.rake_axis, brush.rake_angle = {}, 0
		if st.hook_dir != {} && way != {} {
			if axis := linalg.cross(st.hook_dir, way); linalg.length(axis) > 1e-6 {
				brush.rake_axis = linalg.normalize(to_local_dir(t, axis))
				brush.rake_angle = math.atan2(linalg.length(axis), linalg.dot(st.hook_dir, way))
			}
		}
		if way != {} do st.hook_dir = way
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
		need := max(stroke_spacing(app, st.mode) * brush_radius_px(app, st.pressure, st.tilt), MIN_DAB_SPACING_PX) - st.travel
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
		if !stroke_way_allowed(app) do continue
		if st.mode == .Spray do spray_dab(app, obj, input, inv, st.pos, st.pressure, st.tilt, res)
		else do stroke_dab(app, obj, input, inv, st.pos, st.pressure, st.tilt, res)
	}
}

// Whether a dab goes where the stroke has got to, as it moves along st.dir: No back and
// forth lays none while it goes against the way it first went, and Directional none
// while it comes back toward its press. The spacing walks on either way, so the dabs
// start again in step when the stroke turns back.
@(private = "file")
stroke_way_allowed :: proc(app: ^App) -> bool {
	st := &app.stroke
	if st.dir == {} do return true
	if app.brush.one_way {
		if st.first_dir == {} do st.first_dir = st.dir
		if linalg.dot(st.dir, st.first_dir) <= 0 do return false
	}
	if app.brush.directional && linalg.dot(st.dir, st.pos - st.start) <= 0 do return false
	return true
}

// How many screen pixels a pixel of the brush's radius_px is at a point `per_px` world
// units a pixel away (camera.orbit_world_per_px), in a viewport `height` pixels high: 1
// with the size on screen, and with the size fixed in the scene the world size it stands
// for seen there. Taking size_ref when it is first wanted means turning the switch on
// changes nothing on screen until the view zooms.
brush_size_scale :: proc(app: ^App, per_px, height: f32) -> f32 {
	b := &app.brush
	if !b.size_world do return 1
	if b.size_ref <= 0 do b.size_ref = camera.orbit_world_per_px(app.camera, app.camera.target, height)
	return b.size_ref / max(per_px, 1e-20)
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
	st.steady_taken = false
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
		// Freehand again from the line's end: the stabiliser forgets the path before it.
		stroke_steady_start(st, aim)
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
	st.steady_taken = false
}

// Starts the stroke under way again at `pos`, with nothing laid yet, as stroke_start
// starts one laying dabs: the first dab there (scattered for Spray; Roll's after a
// radius).
@(private = "file")
stroke_restart :: proc(app: ^App, obj: ^Object, input: Viewport_Input, inv: matrix[4, 4]f32, pos: [2]f32, pressure: f32, tilt: [2]f32, res: ^Sculpt_Frame_Result) {
	st := &app.stroke
	st.pos, st.pressure, st.tilt, st.travel, st.dir = pos, pressure, tilt, 0, {}
	st.step, st.turn, st.pivot_sum, st.pivot_count = 0, 0, {}, 0
	clear(&st.path)
	if st.joined {
		// A joined stroke goes on from the last one's end as it did at its press, with no
		// first dab of its own, and on its plane.
		st.dir, st.travel = st.join_dir, st.join_travel
		sculpt.sculptor_lock_plane(object_sculptor(obj), st.join_locked)
		return
	}
	switch st.mode {
	case .Roll:  st.travel = brush_radius_px(app, pressure, tilt)
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
	s := dot_spacing(app)
	// On screen a gap across a surface turned away is longer on the model by 1 / cos.
	if app.brush.scene_spacing && app.stroke.facing > 0 do s *= max(app.stroke.facing, SCENE_SPACING_MIN_FACING)
	return s
}

// How much Even strength scales a Dots dab of the brush `kind`: the overlap of a row of
// dabs at SPACING_REFERENCE over that at the brush's spacing (sculpt.dab_overlap), so 1 at
// the reference itself, less where dabs come closer and more where they are further apart.
spacing_strength :: proc(app: ^App, kind: sculpt.Brush_Kind) -> f32 {
	s := dot_spacing(app)
	if s == SPACING_REFERENCE do return 1
	shape := brush_falloff(app, kind)
	return sculpt.dab_overlap(shape, SPACING_REFERENCE) / sculpt.dab_overlap(shape, s)
}

// The scale Accumulate off gives a Dots stroke's dabs: the most its row piles up along
// the middle, at the reference spacing under Even strength (which evens every spacing to
// it) and at the stroke's own otherwise.
once_strength :: proc(app: ^App, kind: sculpt.Brush_Kind) -> f32 {
	return sculpt.dab_overlap(brush_falloff(app, kind), SPACING_REFERENCE if app.brush.even_strength else dot_spacing(app))
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
	r := app.brush.spray_spread * brush_radius_px(app, pressure, tilt) * math.sqrt(stroke_random(st.seed, step, 0))
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
	local_dir := to_local_dir(t, dir)
	hit, normal, ok := object_raycast_local(obj, to_local(t, origin), local_dir)
	res.raycast_ms += time.duration_milliseconds(time.tick_since(t0))
	if !ok do return
	st := &app.stroke
	if l := linalg.length(normal) * linalg.length(local_dir); l > 0 do st.facing = abs(linalg.dot(normal, local_dir)) / l
	stroke_dab_at(app, obj, input, hit, normal, pressure, tilt, res, scatter)
}

// The radius and strength a dab of an edited stroke is laid with, in place of those the
// pressure gives (stroke_edit_lay).
Dab_Fixed :: struct {
	radius, strength: f32,
}

// Dabs the stroke's object at `hit` (its own space), where the surface faces `normal`: the
// brush under `pressure` and `tilt`, or with `fixed` its radius and strength, then Even
// strength and the mode's scatter.
@(private = "file")
stroke_dab_at :: proc(app: ^App, obj: ^Object, input: Viewport_Input, hit, normal: Vec3, pressure: f32, tilt: [2]f32, res: ^Sculpt_Frame_Result, scatter := Dab_Scatter{size = 1, strength = 1}, fixed: Maybe(Dab_Fixed) = nil) {
	st := &app.stroke
	t := obj.transform
	st.pivot_sum += hit
	st.pivot_count += 1
	t1 := time.tick_now()
	brush := brush_at(app, input, t, hit, pressure, tilt)
	if f, is := fixed.?; is {
		brush.radius, brush.strength = f.radius, f.strength
	} else if !app.stroke_edit.open && app.brush.hold_edit {
		append(&st.path, Stroke_Path_Point{hit, normal, brush.radius, brush.strength, tilt})
	}
	// Even strength, for a row of dabs only: a single stamp or a scattered one has no
	// neighbours to overlap. A stroke never gets stronger than full strength by it.
	// Not on voxel clay, whose Add and Subtract meet their neighbours as a union and never
	// pile up.
	if st.mode == .Dots && brush.no_accumulate && obj.voxel == nil {
		// Accumulate off caps each vertex at the height one dab gives it, so each dab is
		// raised to what the whole row piles up along its middle: a pass stands as high as
		// one with Accumulate on, and passing again adds nothing.
		if st.even == 0 do st.even = once_strength(app, st.kind)
		brush.strength *= st.even
	} else if st.mode == .Dots && app.brush.even_strength && obj.voxel == nil {
		if st.even == 0 do st.even = spacing_strength(app, st.kind)
		brush.strength = min(brush.strength * st.even, max(brush.strength, 1))
	}
	// Dynamic topology's edge length is a share of the radius: kept as set on screen, or
	// scaled with the dab when it is measured by the radius.
	brush.radius *= scatter.size
	if !detail_edit(&app.brush, st.kind).by_radius^ do brush.detail /= scatter.size
	brush.strength *= scatter.strength
	if scatter.tint != {} {
		for k in 0 ..< 3 do brush.color[k] = u8(clamp(f32(brush.color[k]) * scatter.tint[k], 0, 255) + 0.5)
	}
	object_dab(app, obj, brush, hit, normal)
	res.brush_ms += time.duration_milliseconds(time.tick_since(t1))
	res.dabs += 1
}

// The brush a stroke pressed with `input` uses: Smooth for Shift (or the rail's Smooth),
// Mask for the rail's Mask, or else the brush held. While painting, Smooth and Invert are
// Paint strokes: one that blurs the paint, and one that takes it off.
stroke_brush :: proc(app: ^App, input: Viewport_Input) -> sculpt.Brush_Kind {
	if input.mask do return .Mask
	if input.smooth do return .Paint if painting(app) else .Smooth
	if input.invert && painting(app) do return .Paint
	return app.brush.kind
}

// What the History calls a stroke: its brush, or Blur and Erase for Paint's Smooth and
// Invert (painting).
stroke_name :: proc(st: ^Stroke) -> string {
	if st.kind == .Paint && st.blur do return "Blur"
	if st.kind == .Paint && st.invert do return "Erase"
	return BRUSHES[st.kind].name
}

// Whether the brush held paints rather than sculpts, so that Smooth blurs the paint and
// Invert erases it (Brush_Settings.paint_dial): the Paint brush, or a sculpting brush with
// the channel on Colour. Both sculpts as well as paints, so it keeps Smooth and Invert,
// and so does voxel clay, which has no paint to blur.
painting :: proc(app: ^App) -> bool {
	b := &app.brush
	if !b.paint_dial do return false
	if obj := selected_object(app); obj != nil && obj.voxel != nil do return false
	return .Paint in BRUSHES[b.kind].flags || (b.channel == .Color && channel_brush(b.kind))
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
	app.stroke.size_scale = brush_size_scale(app, world_per_px, input.size.y)
	// The way from the last dab, for the brushes that turn along the stroke.
	stroke_dir: Vec3
	if app.stroke.last_set do stroke_dir = hit - app.stroke.last_at
	app.stroke.last_at, app.stroke.last_set = hit, true
	kind := app.stroke.kind
	// Shift smooths at the Smooth brush's strength, not the strength of the brush held, and
	// the rail's Mask masks at the Mask brush's; while painting, Shift's blur is at Smooth's
	// strength too, and Invert erases at the strength and falloff of the brush held.
	own := kind
	if app.stroke.blur {
		own = .Smooth
	} else if kind == .Paint && app.stroke.held {
		own = app.brush.kind
	}
	strength := app.brush.strengths[own]
	if brush_pressure(&app.brush, app.brush.kind).strength do strength *= pressure_curved(app, pressure)
	strength *= 1 - app.brush.tilt_soften * lean_of(tilt)
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
	projected: Vec3
	if app.brush.falloffs[own].projected do projected = to_local_dir(t, camera.orbit_toward(app.camera, to_world(t, hit)))
	through: Vec3
	if kind == .Grab && app.brush.grab_depth do through = to_local_dir(t, camera.orbit_toward(app.camera, to_world(t, hit)))
	sym := brush_symmetry(app, selected_object(app))
	return sculpt.Brush {
		kind     = kind,
		radius   = brush_radius_px(app, pressure, tilt) * world_per_px / t.scale,
		strength = strength,
		invert   = input.invert,
		symmetry = sym.symmetry,
		radial   = sym.radial,
		radial_axis = sym.radial_axis,
		sym_center = sym.sym_center,
		detail   = brush_detail(&app.brush, kind, brush_radius_px(app, pressure, tilt)),
		detail_falloff = app.brush.detail_falloff,
		collapse = app.brush.collapse,
		tilt     = turn,
		alpha    = alpha,
		alpha_up = up,
		falloff_shape = brush_falloff(app, own),
		projected = projected,
		facing   = facing,
		color    = brush_color_bytes(app),
		blur     = app.stroke.blur,
		channel  = brush_channel(app, selected_object(app)) if app.stroke.held else .Sculpt,
		lock_plane = app.brush.lock_plane,
		connected  = app.brush.connected,
		through    = through,
		smooth_only = app.brush.smooth_only if kind == .Smooth else .All,
		smooth_stable = kind == .Smooth && app.brush.smooth_stable,
		// Alt while smoothing polishes, as ZBrush's alternate smooth, for keys to hand.
		smooth_mode = (.Polish if input.alt else app.brush.smooth_mode) if kind == .Smooth else .Smooth,
		stabilize = app.brush.stabilize,
		sample_radius = app.brush.sample_radius,
		no_accumulate = app.brush.no_accumulate[kind] && accumulate_applies(kind),
		feather    = app.brush.feather,
		same_side  = kind == .Grab && app.brush.grab_same_side,
		silhouette = kind == .Grab && app.brush.grab_silhouette,
		topological = kind == .Grab && app.brush.grab_topological,
		volume     = app.brush.elastic_volume,
		hook_pinch = app.brush.hook_pinch if kind == .Snake_Hook else 0,
		hook_rake  = app.brush.hook_rake if kind == .Snake_Hook else 0,
		hook_elastic = kind == .Snake_Hook && app.brush.hook_elastic,
		stroke_dir = stroke_dir,
		tip_roundness = app.brush.tip_roundness,
		tip_scale = app.brush.tip_scale,
		trim_angle = math.to_radians(app.brush.trim_angle),
		trim_fixed = !app.brush.trim_dynamic,
		plane_short = {1 - app.brush.plane_height, 1 - app.brush.plane_depth},
	}
}

// The falloff of the brush `kind` as a table, made from its curve and focal shift, or nil
// for the built-in one unshifted, which the dabs work out themselves.
brush_falloff :: proc(app: ^App, kind: sculpt.Brush_Kind) -> ^sculpt.Falloff {
	f := app.brush.falloffs[kind]
	if !f.drawn && f.focal == 0 && f.hardness == 0 do return nil
	// Only what shapes the table counts: an undrawn curve is not read, and the shape is
	// the dab's to apply.
	if !f.drawn do f.curve = {}
	f.projected = false
	table := &app.falloff_tables[kind]
	if table.shape != f || !table.built {
		sculpt.falloff_set_shaped(&table.falloff, f.curve if f.drawn else nil, f.focal, f.hardness)
		table.shape, table.built = f, true
	}
	return &table.falloff
}

// The brush's radius on screen in pixels under `pressure` and `tilt`, at the stroke's last
// dab when the size is fixed in the scene.
brush_radius_px :: proc(app: ^App, pressure: f32, tilt: [2]f32) -> f32 {
	r := app.brush.radius_px * (1 + app.brush.tilt_size * lean_of(tilt))
	if app.brush.size_world && app.stroke.size_scale > 0 do r *= app.stroke.size_scale
	if !brush_pressure(&app.brush, app.brush.kind).size do return r
	return r * max(pressure_sized(app, pressure), brush_pressure(&app.brush, app.brush.kind).size_floor, MIN_PRESSURE_SIZE)
}

// The brush as the app starts with it, before the settings file.
brush_defaults :: proc() -> Brush_Settings {
	b := Brush_Settings{kind = .Draw, radius_px = DEFAULT_RADIUS_PX, pressure_strength = true, pressure_curve = geom.CURVE_LINEAR, pressure_size_curve = geom.CURVE_LINEAR, detail_px = 10, collapse = true, alpha = -1, color = {0.75, 0.2, 0.15}, color2 = {0.95, 0.92, 0.85}, spray_spread = SPRAY_DEFAULT_SPREAD, spacing = DAB_SPACING, even_strength = true, feather = true, smoothing = 1, pressure_smoothing = 1, catch_up = true, radial_count = RADIAL_DEFAULT, radial_axis = .Y, paint_dial = true, paint_on = .Both, elastic_volume = ELASTIC_VOLUME_DEFAULT}
	// Draw does not build up over itself within a stroke, as ZBrush's and Nomad's.
	b.sample_radius, b.no_accumulate[.Draw] = 1, true
	for kind in sculpt.Brush_Kind do b.falloffs[kind].projected = projected_default(kind)
	b.tip_roundness, b.tip_scale = sculpt.CLAY_TIP_ROUNDNESS, 1
	b.trim_angle, b.trim_dynamic = TRIM_ANGLE_DEFAULT_DEGREES, true
	b.plane_height, b.plane_depth = 1, 1
	b.hold_edit, b.hold_edit_s, b.hold_edit_smoothness = true, HOLD_EDIT_DEFAULT_S, HOLD_EDIT_SMOOTHNESS_DEFAULT
	b.detail_radius = DETAIL_RADIUS_DEFAULT
	for &d in b.dyns do d.px, d.radius = b.detail_px, b.detail_radius
	// Clay strips starts on Blender's: its size follows the pen as p^1.5, never under 0.3.
	b.pressures[.Clay_Strips] = {own = true, pressure = {strength = true, size = true, strength_curve = geom.CURVE_LINEAR, size_curve = CURVE_POWER_1_5, size_floor = 0.3}}
	return b
}

// Dynamic topology's Detail by radius as a fresh brush has it, and its range: a share of
// the brush's radius.
DETAIL_RADIUS_DEFAULT :: 0.1
DETAIL_RADIUS_MIN :: 0.02
DETAIL_RADIUS_MAX :: 0.5

// One brush's dynamic topology (Brush_Settings.dyns): `off` keeps its triangles as they
// are; with `own` set it uses its own detail below in place of the global one.
Dyn_Own :: struct {
	off:       bool,
	own:       bool,
	by_radius: bool,
	px:        f32,
	radius:    f32,
}

// Dynamic topology's detail for brush `kind` as a share of its radius (sculpt.Brush.detail),
// radius_px across on screen: 0 where the brush keeps its triangles.
brush_detail :: proc(b: ^Brush_Settings, kind: sculpt.Brush_Kind, radius_px: f32) -> f32 {
	if b.dyns[kind].off do return 0
	d := detail_edit(b, kind)
	if d.by_radius^ do return d.radius^
	return d.px^ / max(radius_px, 1)
}

// Where brush `kind`'s detail is edited: its own or the global one.
Detail_Edit :: struct {
	by_radius: ^bool,
	px:        ^f32,
	radius:    ^f32,
}

detail_edit :: proc(b: ^Brush_Settings, kind: sculpt.Brush_Kind) -> Detail_Edit {
	if d := &b.dyns[kind]; d.own do return {&d.by_radius, &d.px, &d.radius}
	return {&b.detail_by_radius, &b.detail_px, &b.detail_radius}
}

// Gives brush `kind` its own detail (a copy of the global one, which it then starts from)
// or puts it back on the global one.
brush_detail_own :: proc(b: ^Brush_Settings, kind: sculpt.Brush_Kind, own: bool) {
	d := &b.dyns[kind]
	if own && !d.own do d.by_radius, d.px, d.radius = b.detail_by_radius, b.detail_px, b.detail_radius
	d.own = own
}

// Whether brush `kind` starts with its falloff Projected (Falloff_Setting.projected):
// Clay and Flatten, whose footprint is then the ring on screen however the surface curves
// away, as a flat stamp should be.
projected_default :: proc(kind: sculpt.Brush_Kind) -> bool {
	return kind == .Clay || kind == .Flatten || kind == .Trim_Dynamic
}

// Trim dynamic's fixed angle as a fresh brush has it, in degrees (sculpt.TRIM_ANGLE_DEFAULT).
TRIM_ANGLE_DEFAULT_DEGREES :: 60

// p^1.5 as a pressure curve (a cubic through (0, 0) and (1, 1)), Blender's Clay strips
// size: within 0.002 of it across the range (fitted on a grid of control points).
CURVE_POWER_1_5 :: geom.Curve{{0.1, 0}, {0.45, 0.175}}

// Whether Accumulate does anything for brush `kind`: the kinds that push along the normal
// (sculpt.Brush.no_accumulate). Layer never builds up past its height and the plane kinds
// stop at their plane.
accumulate_applies :: proc(kind: sculpt.Brush_Kind) -> bool {
	return kind == .Draw || kind == .Inflate
}

// Whether Stabilize orientation and Sample radius do anything for brush `kind`: the kinds
// that work along the area under the brush (sculpt.brush_locks_plane, alpha aside).
samples_apply :: proc(kind: sculpt.Brush_Kind) -> bool {
	return sculpt.brush_locks_plane(kind, false)
}

// How far a pen leaning `tilt` (degrees across and down, as SDL reports it) is laid
// toward the paper: 0 upright, 1 from LEAN_FULL degrees off upright on.
lean_of :: proc(tilt: [2]f32) -> f32 {
	if tilt == {} do return 0
	// The pen's top, from its tip: across and down by the tangents of the two tilts, and one
	// up; its angle from upright.
	t := [2]f32{math.tan(math.to_radians(clamp(tilt.x, -89, 89))), math.tan(math.to_radians(clamp(tilt.y, -89, 89)))}
	off := math.to_degrees(math.atan(linalg.length(t)))
	return clamp(off / LEAN_FULL, 0, 1)
}

// What pen pressure does to a brush: whether it scales the strength and the size, and
// the curve each goes through (geom.curve_at), kept apart so a brush can, say, grow with
// pressure gently while its strength comes in hard.
Pressure :: struct {
	strength:       bool,
	size:           bool,
	strength_curve: geom.Curve,
	size_curve:     geom.Curve,
	// The smallest share of the radius pressure can shrink the brush to, as Blender's
	// Clay keeps a fifth of it (never below MIN_PRESSURE_SIZE).
	size_floor:     f32,
}

// Where a Pressure is kept, the brush's own or the global fields, for editing.
Pressure_Ref :: struct {
	strength, size:             ^bool,
	strength_curve, size_curve: ^geom.Curve,
	size_floor:                 ^f32,
}

// Response presets: what pen pressure does as a whole, set in one tap (the Pen section's
// Response page).
PRESSURE_RESPONSES := [?]struct {
	label:    cstring,
	pressure: Pressure,
} {
	// The app's own start: strength follows the pen, the size stays.
	{"Default", {strength = true, strength_curve = geom.CURVE_LINEAR, size_curve = geom.CURVE_LINEAR}},
	// Blender's Clay: the size follows the cube of the pressure, never under a fifth of the
	// radius, so a light touch lays a narrow smear and a press a wide one; the strength
	// takes a press (the Firm curve).
	{"Clay", {strength = true, size = true, strength_curve = {{0.6, 0.05}, {0.95, 0.4}}, size_curve = {{1.0 / 3, 0}, {2.0 / 3, 0}}, size_floor = 0.2}},
	// Steady strokes, ZBrush's lazy pressure feel: over nine tenths of the strength from
	// half pressure on, so a stroke keeps an even height whatever the hand does, and the
	// size stays.
	{"Steady", {strength = true, strength_curve = {{0.15, 0.75}, {0.35, 1}}, size_curve = geom.CURVE_LINEAR}},
	// Light touch, Nomad's light-pressure default: a light touch goes far, for size and
	// strength alike (the Soft curve).
	{"Light", {strength = true, size = true, strength_curve = {{0.1, 0.6}, {0.4, 0.95}}, size_curve = {{0.1, 0.6}, {0.4, 0.95}}, size_floor = 0.1}},
}

// Whether `p` is the Clay response Clay started on before settings version 7, as a
// settings file wrote it back (to six places, so within a hair of the curves).
pressure_is_old_clay :: proc(p: Pressure_Own) -> bool {
	near :: proc(a, b: geom.Curve) -> bool {
		return abs(a.c1.x - b.c1.x) + abs(a.c1.y - b.c1.y) + abs(a.c2.x - b.c2.x) + abs(a.c2.y - b.c2.y) < 1e-4
	}
	c := PRESSURE_RESPONSES[1].pressure
	return p.own && p.strength == c.strength && p.size == c.size && abs(p.size_floor - c.size_floor) < 1e-4 && near(p.strength_curve, c.strength_curve) && near(p.size_curve, c.size_curve)
}

// A brush's own pressure, and whether it uses it rather than the global one.
Pressure_Own :: struct {
	own:            bool,
	using pressure: Pressure,
}

// The pressure brush `kind` works with: its own when it keeps one, else the global one.
brush_pressure :: proc(b: ^Brush_Settings, kind: sculpt.Brush_Kind) -> Pressure {
	if b.pressures[kind].own do return b.pressures[kind].pressure
	return {b.pressure_strength, b.pressure_size, b.pressure_curve, b.pressure_size_curve, b.pressure_size_floor}
}

// Gives brush `kind` its own pressure (own) starting from the global one, or puts it back
// on the global one, leaving its own as it was for the next time.
brush_pressure_own :: proc(b: ^Brush_Settings, kind: sculpt.Brush_Kind, own: bool) {
	p := &b.pressures[kind]
	if own && !p.own do p.pressure = brush_pressure(b, kind)
	p.own = own
}

// Where the pressure the held brush works with is edited: its own or the global one.
pressure_edit :: proc(b: ^Brush_Settings) -> Pressure_Ref {
	if p := &b.pressures[b.kind]; p.own do return {&p.strength, &p.size, &p.strength_curve, &p.size_curve, &p.size_floor}
	return {&b.pressure_strength, &b.pressure_size, &b.pressure_curve, &b.pressure_size_curve, &b.pressure_size_floor}
}

// Sets the pressure kept at `to`.
pressure_put :: proc(to: Pressure_Ref, p: Pressure) {
	to.strength^, to.size^, to.strength_curve^, to.size_curve^, to.size_floor^ = p.strength, p.size, p.strength_curve, p.size_curve, p.size_floor
}

// Which response preset the pressure at `at` is, or -1 for none.
pressure_response :: proc(at: Pressure_Ref) -> int {
	now := Pressure{at.strength^, at.size^, at.strength_curve^, at.size_curve^, at.size_floor^}
	for r, i in PRESSURE_RESPONSES {
		// What a switched-off curve is set to does nothing, so it does not count.
		p := r.pressure
		if !now.size do p.size_curve, p.size_floor = now.size_curve, now.size_floor
		if !now.strength do p.strength_curve = now.strength_curve
		if p == now do return i
	}
	return -1
}

// What a pen pressure counts as for the held brush's strength, through its curve. A
// mouse's 1 stays 1.
pressure_curved :: proc(app: ^App, pressure: f32) -> f32 {
	return geom.curve_at(brush_pressure(&app.brush, app.brush.kind).strength_curve, pressure)
}

// ...and for its size.
pressure_sized :: proc(app: ^App, pressure: f32) -> f32 {
	return geom.curve_at(brush_pressure(&app.brush, app.brush.kind).size_curve, pressure)
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

// Lays the stroke held to edit again along its curve (stroke_edit.odin) when the curve has
// changed since it was last laid: the stroke put back, then a dab each time the walk along
// the curve has gone the brush's spacing at the radius there, with that point's radius and
// intensity, on the surface under the curve. A lay under way is finished before a newer
// curve is laid, as line_lay does, so a drag that keeps changing the curve still sees it
// laid whole. Bounded like any stroke's frame; returns true once the curve as it stands is
// laid.
stroke_edit_lay :: proc(app: ^App, input: Viewport_Input, res: ^Sculpt_Frame_Result, bounded: bool) -> bool {
	e := &app.stroke_edit
	st := &app.stroke
	obj := object_by_id(app, st.object)
	if obj == nil || len(e.points) < 2 do return true
	if !e.laying {
		if e.version == e.laid_version do return true
		if !sculpt.sculptor_stroke_restore(object_sculptor(obj)) {
			e.laid_version = e.version
			return true
		}
		stroke_edit_sample(app)
		e.laying, e.lay_at, e.travel, e.laid_version = true, 0, max(f32), e.version
		st.last_set, st.step, st.turn, st.pivot_sum, st.pivot_count, st.even = false, 0, 0, {}, 0, 0
	}
	// The stroke's own modifiers, not those held now: a Ctrl let go must not flip it.
	lay := input
	lay.invert, lay.alt, lay.smooth, lay.mask = st.invert, false, false, false
	if lay.size.x <= 0 || lay.size.y <= 0 do lay.size = e.size
	for e.lay_at < len(e.samples) {
		slow := app.kit.fixed_dt == 0 && res.brush_ms + res.raycast_ms >= MAX_BRUSH_MS_PER_FRAME
		if bounded && (res.dabs >= MAX_DABS_PER_FRAME || slow) do return false
		s := e.samples[e.lay_at]
		if e.lay_at > 0 do e.travel += linalg.length(s.p - e.samples[e.lay_at - 1].p)
		e.lay_at += 1
		last := e.lay_at == len(e.samples)
		if e.travel < dot_spacing(app) * s.radius && !(last && e.travel > 0.5 * dot_spacing(app) * s.radius) do continue
		e.travel = 0
		at, normal := stroke_edit_surface(app, obj, s)
		stroke_dab_at(app, obj, lay, at, normal, 1, e.tilt, res, fixed = Dab_Fixed{s.radius, s.intensity})
	}
	e.laying = false
	return e.version == e.laid_version
}
