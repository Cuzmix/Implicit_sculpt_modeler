package main

import "core:fmt"
import "core:math"
import "core:path/filepath"

import "../camera"
import "../geom"
import "../sculpt"
import "../ui"

// Stroke record and replay. The app keeps the last stroke as it was drawn: every frame's
// pointer samples and modifier keys, the camera and viewport size they were drawn in,
// and the brush settings. Record keeps every stroke from then until Stop as one take.
// Replaying feeds those frames back through sculpt_frame, the path a real stroke takes,
// so a replayed stroke is exactly a drawn one (lazy mouse, symmetry, Grab, Cloth and
// undo included) and works on any object it lands on.
//
// Replay puts the strokes back where they were drawn, with the camera they were drawn
// with, whatever the view is now. Replay at the pointer (R over the viewport) moves them
// on screen so the first stroke starts under the pointer, in the current view: a stroke
// recorded once becomes a stamp to lay anywhere, on any object. With Recorded brushes
// off, the path is replayed with the brush as it is set now instead.
Replay :: struct {
	last:      Take, // the last stroke drawn
	take:      Take, // what Record kept
	recording: bool,
	recorded_brush: bool, // replay with the brushes the strokes were drawn with
	instant:   bool, // replay every frame at once instead of one a frame, as drawn
	// The replay running: which take, how far it has got, and, at the pointer, how far
	// the samples move and the view they go into.
	playing:   ^Take,
	frame:     int,
	at_pointer: bool,
	offset:    [2]f32,
	camera:    camera.Orbit,
	was_active: bool, // a stroke was under way when this frame's sculpting began
}

// Strokes as drawn: frames in order, each naming its samples and brush.
Take :: struct {
	frames:  [dynamic]Take_Frame,
	samples: [dynamic]Input_Sample,
	brushes: [dynamic]Brush_Settings, // one per stroke, as it began
	seeds:   [dynamic]u64, // ...and each stroke's seed (Stroke.seed), so its random dabs replay
	scales:  [dynamic]f32, // ...and its strength scale (Stroke.scale), so a finger's replays as light
}

Take_Frame :: struct {
	first, count: u32, // its samples in Take.samples
	brush:     u32, // in Take.brushes
	camera:    camera.Orbit,
	size:      [2]f32,
	mouse_pos: [2]f32,
	pen_tilt:  [2]f32,
	pen_roll:  f32, // the pen's roll, which a Pen roll alpha turns by
	primary, smooth, invert: bool,
	mask:      bool, // the modifier rail's Mask: the stroke painted the mask
	alt:       bool, // Alt held mid-stroke: a Grab moved along the surface
}

replay_init :: proc(p: ^Replay) {
	p.recorded_brush = true
}

replay_destroy :: proc(p: ^Replay) {
	take_destroy(&p.last)
	take_destroy(&p.take)
	p^ = {}
}

take_destroy :: proc(t: ^Take) {
	delete(t.frames)
	delete(t.samples)
	delete(t.brushes)
	delete(t.seeds)
	delete(t.scales)
	t^ = {}
}

@(private = "file")
take_clear :: proc(t: ^Take) {
	clear(&t.frames)
	clear(&t.samples)
	clear(&t.brushes)
	clear(&t.seeds)
	clear(&t.scales)
}

take_strokes :: proc(t: ^Take) -> int {return len(t.brushes)}

// What a replay without a choice plays: the recording, or else the last stroke.
replay_source :: proc(app: ^App) -> ^Take {
	p := &app.replay
	if len(p.take.frames) > 0 do return &p.take
	return &p.last
}

// Notes, before sculpt_frame, whether a stroke is under way.
replay_frame_begin :: proc(app: ^App) {
	app.replay.was_active = app.stroke.active
}

// Keeps this frame for the last stroke, and for the take while recording, if it took
// part in a stroke: one was under way, began, or came and went within the frame.
replay_record :: proc(app: ^App, input: Viewport_Input, res: Sculpt_Frame_Result) {
	p := &app.replay
	// A stroke held to edit is laid from its curve, not from the pointer: its frames are not
	// samples a replay could lay again.
	if app.stroke_edit.open do return
	if !p.was_active && !app.stroke.active && res.dabs == 0 do return
	began := !p.was_active
	if began do take_clear(&p.last)
	take_append(&p.last, app, input, began)
	if p.recording do take_append(&p.take, app, input, began)
}

@(private = "file")
take_append :: proc(t: ^Take, app: ^App, input: Viewport_Input, began: bool) {
	// A stroke that began within a frame another ended in (a release and a press in one
	// frame's samples) gets its own entry too, found by its seed, so it replays with it.
	if began || len(t.brushes) == 0 || (app.stroke.active && app.stroke.seed != t.seeds[len(t.seeds) - 1]) {
		append(&t.brushes, app.brush)
		append(&t.seeds, app.stroke.seed)
		append(&t.scales, app.stroke.scale if app.stroke.scale > 0 else 1)
	}
	append(&t.frames, Take_Frame {
		first = u32(len(t.samples)), count = u32(len(input.samples)), brush = u32(len(t.brushes) - 1),
		camera = app.camera, size = input.size, mouse_pos = input.mouse_pos, pen_tilt = input.pen_tilt, pen_roll = input.pen_roll,
		primary = input.primary, smooth = input.smooth, invert = input.invert, mask = input.mask, alt = input.alt,
	})
	append(&t.samples, ..input.samples)
}

replay_record_start :: proc(app: ^App) {
	p := &app.replay
	replay_stop(app)
	take_clear(&p.take)
	// The recording's first stroke joins none drawn before it, as its replay will not.
	app.stroke_end.valid = false
	p.recording = true
}

replay_record_stop :: proc(app: ^App) {
	app.replay.recording = false
}

// Starts replaying `t`: where it was drawn, or with its first stroke starting at `pointer`
// in the current view.
replay_start :: proc(app: ^App, t: ^Take, at_pointer := false, pointer: [2]f32 = {}) {
	p := &app.replay
	if len(t.frames) == 0 || p.playing != nil do return
	stroke_finish(app)
	// A replay's first stroke never joins one drawn before it, nor a drawn one the last
	// it replayed, so it lands the same wherever it is played.
	app.stroke_end.valid = false
	p.recording = false
	p.playing, p.frame, p.at_pointer = t, 0, at_pointer
	if at_pointer {
		p.offset, p.camera = pointer - take_start(t), app.camera
	}
}

replay_stop :: proc(app: ^App) {
	p := &app.replay
	if p.playing == nil do return
	p.playing = nil
	stroke_finish(app)
	app.stroke_end.valid = false
}

replay_busy :: proc(app: ^App) -> bool {return app.replay.playing != nil}

// Where the take's first stroke begins on screen: its first press, or its first sample.
take_start :: proc(t: ^Take) -> [2]f32 {
	for s in t.samples do if s.kind == .Press do return s.pos
	if len(t.samples) > 0 do return t.samples[0].pos
	return t.frames[0].mouse_pos
}

// Replays the next recorded frame (every one left, when instant) through sculpt_frame in
// place of the pointer, which does nothing to the objects meanwhile. The camera and brush
// are the recorded ones only for those calls: the view stays the user's. At the pointer,
// the samples go into the viewport as it is now (`now`), and wait while it has no size.
replay_frame :: proc(app: ^App, now: Viewport_Input) -> (res: Sculpt_Frame_Result) {
	p := &app.replay
	t := p.playing
	if t == nil || (p.at_pointer && (now.size.x < 1 || now.size.y < 1)) do return
	// The seed too: the user's next stroke takes the one it would have without the replay.
	saved_camera, saved_brush, saved_seed, saved_scale := app.camera, app.brush, app.stroke_seed, app.stroke_scale_from
	defer app.camera, app.brush, app.stroke_seed, app.stroke_scale_from = saved_camera, saved_brush, saved_seed, saved_scale
	for p.frame < len(t.frames) {
		f := t.frames[p.frame]
		p.frame += 1
		samples := make([]Input_Sample, f.count, context.temp_allocator)
		copy(samples, t.samples[f.first:][:f.count])
		input := Viewport_Input {
			size = f.size, mouse_pos = f.mouse_pos, pen_tilt = f.pen_tilt, pen_roll = f.pen_roll, hovered = true,
			primary = f.primary, smooth = f.smooth, invert = f.invert, mask = f.mask, alt = f.alt, samples = samples,
		}
		app.camera = f.camera
		if p.at_pointer {
			for &s in samples do s.pos += p.offset
			input.mouse_pos += p.offset
			input.size, app.camera = now.size, p.camera
		}
		app.brush = t.brushes[f.brush] if p.recorded_brush else saved_brush
		app.stroke_seed = t.seeds[f.brush]
		app.stroke_scale_from = t.scales[f.brush]
		r := sculpt_frame(app, input)
		res.dabs += r.dabs
		res.raycast_ms += r.raycast_ms
		res.brush_ms += r.brush_ms
		if !p.instant do break
		if obj := selected_object(app); obj != nil do sculpt.sculptor_refresh_normals(object_sculptor(obj))
	}
	if p.frame >= len(t.frames) {
		// A take whose recording stopped mid-stroke ends that stroke here.
		stroke_finish(app)
		p.playing = nil
		app.stroke_end.valid = false
	}
	return
}

// R over the viewport: replay at the pointer.
replay_shortcut :: proc(app: ^App) {
	if app.replay.recording || replay_busy(app) || !app.ui.viewport_hovered do return
	replay_start(app, replay_source(app), true, app.ui.viewport_mouse)
}

// The .strokes file: "SCSTROKE", its form, then a tagged record (geom/record.odin) of a
// field a brush and a field a frame, every number little-endian. A brush keeps what makes
// a stroke what it is (kind, size, strength, falloff, pressure, lazy mouse and the
// stabiliser, front faces, stroke mode, symmetry, colour and paint channel, cloth mode and
// settings, the Physics switch, Spray's spread, the stroke's seed and strength scale, Line
// and Join strokes, All depth and Smooth only); the rest (alpha, tilt, dynamic topology
// detail), and any value a file lacks, comes from the brush as set when the file is
// loaded, since an alpha names an image that may not be there.
STROKES_MAGIC :: "SCSTROKE"
// The file's form: changes only when the file is laid out another way, never for a field
// a build adds or drops (SCENE_FORMAT says the same of the scene file).
STROKES_FORMAT :: u32(1)

// The fields of a .strokes file's record. Tags are never reused or retyped.
Strokes_Tag :: enum u16 {
	Brush = 1, // Stroke_Brush_Tag record, one a stroke
	Frame = 2, // Stroke_Frame_Tag record, in order
}

Stroke_Brush_Tag :: enum u16 {
	Kind                = 1,  // u8 sculpt.Brush_Kind
	Radius              = 2,  // f32 pixels
	Strength            = 3,  // f32
	Falloff_Drawn       = 4,  // u8
	Falloff             = 5,  // [2][2]f32 curve
	Pressure_Strength   = 6,  // u8
	Pressure_Size       = 7,  // u8
	Pressure_Curve      = 8,  // [2][2]f32
	Lazy                = 9,  // f32 pixels
	Front_Only          = 10, // u8
	Stroke              = 11, // u8 Stroke_Mode
	Symmetry            = 12, // u8 sculpt.Symmetry
	Color               = 13, // [3]f32
	Cloth_Mode          = 14, // u8
	Spray_Spread        = 15, // f32
	Seed                = 16, // u64
	Line                = 17, // u8
	Join                = 18, // u8
	Lock_Plane          = 19, // u8
	Connected           = 20, // u8
	Focal               = 21, // f32
	Scale               = 22, // f32: the stroke's strength scale
	Sym_Local           = 23, // u8
	Radial_On           = 24, // u8
	Radial_Count        = 25, // u8
	Radial_Axis         = 26, // u8
	Channel             = 27, // u8
	Grab_Depth          = 28, // u8
	Smooth_Only         = 29, // u8
	Spacing             = 30, // f32
	Color_Spray         = 31, // f32
	Paint_Dial          = 32, // u8
	Smoothing           = 33, // f32 samples
	Pressure_Smoothing  = 34, // f32 samples
	Catch_Up            = 35, // u8
	Even_Strength       = 36, // u8
	Scene_Spacing       = 37, // u8
	Feather             = 38, // u8
	Grab_Mode           = 39, // u8
	Grab_Same_Side      = 40, // u8
	Grab_Silhouette     = 41, // u8
	Grab_Normal         = 42, // f32
	Grab_Topological    = 43, // u8
	Elastic_Volume      = 44, // f32
	Hook_Pinch          = 45, // f32
	Hook_Rake           = 46, // f32
	Hook_Elastic        = 47, // u8
	Pressure_Size_Curve = 48, // [2][2]f32
	Size_Floor          = 49, // f32
	Smooth_Stable       = 50, // u8
	Smooth_Mode         = 51, // u8
	Stabilize           = 52, // f32
	Sample_Radius       = 53, // f32
	One_Pass            = 54, // u8
	Hardness            = 55, // f32
	Projected           = 56, // u8
	One_Way             = 57, // u8
	Directional         = 58, // u8
	Size_World          = 59, // u8
	Size_Ref            = 60, // f32
	Tip_Roundness       = 61, // f32
	Tip_Scale           = 62, // f32
	Trim_Angle          = 63, // f32
	Plane_Height        = 64, // f32
	Plane_Depth         = 65, // f32
	Trim_Dynamic        = 66, // u8
	Grab_Outline        = 67, // u8
	Cloth_Region        = 68, // u8
	Cloth_Keep_Area     = 69, // u8
	Cloth_Allow_Shrink  = 70, // u8
	Cloth_Allow_Expand  = 71, // u8
	Cloth_Stiffness     = 72, // f32
	Cloth_Firmness      = 73, // f32
	Cloth_Damping       = 74, // f32
	Cloth_Gravity       = 75, // f32
	Physics             = 76, // u8
	Physics_Strength    = 77, // f32
}

Stroke_Frame_Tag :: enum u16 {
	Target    = 1,  // Vec3: the camera's
	Distance  = 2,  // f32
	Yaw       = 3,  // f32
	Pitch     = 4,  // f32
	Fov_Y     = 5,  // f32
	Near      = 6,  // f32
	Far       = 7,  // f32
	Roll      = 8,  // f32
	Ortho     = 9,  // u8
	Size      = 10, // [2]f32 the view's
	Mouse     = 11, // [2]f32
	Pen_Tilt  = 12, // [2]f32
	Pen_Roll  = 13, // f32
	Brush     = 14, // u32: its brush, required
	Primary   = 15, // u8
	Smooth    = 16, // u8
	Invert    = 17, // u8
	Mask      = 18, // u8
	Alt       = 19, // u8
	Positions = 20, // [2]f32 per sample
	Pressures = 21, // f32 per sample
	Kinds     = 22, // u8 Sample_Kind per sample
	Tilts     = 23, // [2]f32 per sample
}

strokes_save :: proc(app: ^App, path: string) -> bool {
	t := replay_source(app)
	if len(t.frames) == 0 {
		file_note(app, true, "There are no strokes to save: draw or record some first")
		return false
	}
	B :: Stroke_Brush_Tag
	F :: Stroke_Frame_Tag
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, STROKES_MAGIC)
	geom.byte_put(&out, STROKES_FORMAT)
	rec := geom.record_begin(&out)
	for b, i in t.brushes {
		at := geom.rec_begin(&out, Strokes_Tag.Brush)
		o := &out
		geom.rec_put(o, B.Kind, u8(b.kind))
		geom.rec_put(o, B.Radius, b.radius_px)
		geom.rec_put(o, B.Strength, b.strengths[b.kind])
		f := b.falloffs[b.kind]
		geom.rec_put(o, B.Falloff_Drawn, u8(f.drawn))
		geom.rec_put(o, B.Falloff, transmute([2][2]f32)f.curve)
		// The pressure the brush worked with, its own or the global one, which reading puts
		// back as the global one.
		b := b
		pressure := brush_pressure(&b, b.kind)
		geom.rec_put(o, B.Pressure_Strength, u8(pressure.strength))
		geom.rec_put(o, B.Pressure_Size, u8(pressure.size))
		geom.rec_put(o, B.Pressure_Curve, transmute([2][2]f32)pressure.strength_curve)
		geom.rec_put(o, B.Lazy, b.lazy_px)
		geom.rec_put(o, B.Front_Only, u8(b.front_only))
		geom.rec_put(o, B.Stroke, u8(b.stroke))
		geom.rec_put(o, B.Symmetry, transmute(u8)b.symmetry)
		geom.rec_put(o, B.Color, b.color)
		geom.rec_put(o, B.Cloth_Mode, u8(b.cloth_mode))
		geom.rec_put(o, B.Spray_Spread, b.spray_spread)
		geom.rec_put(o, B.Seed, t.seeds[i])
		geom.rec_put(o, B.Line, u8(b.line))
		geom.rec_put(o, B.Join, u8(b.join))
		geom.rec_put(o, B.Lock_Plane, u8(b.lock_plane))
		geom.rec_put(o, B.Connected, u8(b.connected))
		geom.rec_put(o, B.Focal, f.focal)
		geom.rec_put(o, B.Scale, t.scales[i])
		geom.rec_put(o, B.Sym_Local, u8(b.sym_local))
		geom.rec_put(o, B.Radial_On, u8(b.radial_on))
		geom.rec_put(o, B.Radial_Count, u8(clamp(b.radial_count, RADIAL_MIN, sculpt.RADIAL_MAX)))
		geom.rec_put(o, B.Radial_Axis, u8(b.radial_axis))
		geom.rec_put(o, B.Channel, u8(b.channel))
		geom.rec_put(o, B.Grab_Depth, u8(b.grab_depth))
		geom.rec_put(o, B.Smooth_Only, u8(b.smooth_only))
		geom.rec_put(o, B.Spacing, dot_spacing_of(b))
		geom.rec_put(o, B.Color_Spray, b.color_spray)
		geom.rec_put(o, B.Paint_Dial, u8(b.paint_dial))
		geom.rec_put(o, B.Smoothing, f32(steady_count(b.smoothing)))
		geom.rec_put(o, B.Pressure_Smoothing, f32(steady_count(b.pressure_smoothing)))
		geom.rec_put(o, B.Catch_Up, u8(b.catch_up))
		geom.rec_put(o, B.Even_Strength, u8(b.even_strength))
		geom.rec_put(o, B.Scene_Spacing, u8(b.scene_spacing))
		geom.rec_put(o, B.Feather, u8(b.feather))
		geom.rec_put(o, B.Grab_Mode, u8(b.grab_mode))
		geom.rec_put(o, B.Grab_Same_Side, u8(b.grab_same_side))
		geom.rec_put(o, B.Grab_Silhouette, u8(b.grab_silhouette))
		geom.rec_put(o, B.Grab_Normal, b.grab_normal)
		geom.rec_put(o, B.Grab_Topological, u8(b.grab_topological))
		geom.rec_put(o, B.Elastic_Volume, b.elastic_volume)
		geom.rec_put(o, B.Hook_Pinch, b.hook_pinch)
		geom.rec_put(o, B.Hook_Rake, b.hook_rake)
		geom.rec_put(o, B.Hook_Elastic, u8(b.hook_elastic))
		geom.rec_put(o, B.Pressure_Size_Curve, transmute([2][2]f32)pressure.size_curve)
		geom.rec_put(o, B.Size_Floor, pressure.size_floor)
		geom.rec_put(o, B.Smooth_Stable, u8(b.smooth_stable))
		geom.rec_put(o, B.Smooth_Mode, u8(b.smooth_mode))
		geom.rec_put(o, B.Stabilize, b.stabilize)
		geom.rec_put(o, B.Sample_Radius, b.sample_radius)
		geom.rec_put(o, B.One_Pass, u8(b.no_accumulate[b.kind]))
		geom.rec_put(o, B.Hardness, f.hardness)
		geom.rec_put(o, B.Projected, u8(f.projected))
		geom.rec_put(o, B.One_Way, u8(b.one_way))
		geom.rec_put(o, B.Directional, u8(b.directional))
		geom.rec_put(o, B.Size_World, u8(b.size_world))
		geom.rec_put(o, B.Size_Ref, b.size_ref)
		geom.rec_put(o, B.Tip_Roundness, b.tip_roundness)
		geom.rec_put(o, B.Tip_Scale, b.tip_scale)
		geom.rec_put(o, B.Trim_Angle, b.trim_angle)
		geom.rec_put(o, B.Plane_Height, b.plane_height)
		geom.rec_put(o, B.Plane_Depth, b.plane_depth)
		geom.rec_put(o, B.Trim_Dynamic, u8(b.trim_dynamic))
		geom.rec_put(o, B.Grab_Outline, u8(b.grab_outline))
		geom.rec_put(o, B.Cloth_Region, u8(b.cloth.region))
		geom.rec_put(o, B.Cloth_Keep_Area, u8(b.cloth.keep_area))
		geom.rec_put(o, B.Cloth_Allow_Shrink, u8(b.cloth.allow_shrink))
		geom.rec_put(o, B.Cloth_Allow_Expand, u8(b.cloth.allow_expand))
		geom.rec_put(o, B.Cloth_Stiffness, b.cloth.stiffness)
		geom.rec_put(o, B.Cloth_Firmness, b.cloth.firmness)
		geom.rec_put(o, B.Cloth_Damping, b.cloth.damping)
		geom.rec_put(o, B.Cloth_Gravity, b.cloth.gravity)
		geom.rec_put(o, B.Physics, u8(b.physics))
		geom.rec_put(o, B.Physics_Strength, b.physics_strength)
		geom.rec_end(&out, at)
	}
	n := 0
	for f in t.frames do n = max(n, int(f.count))
	pos, tilt := make([][2]f32, n, context.temp_allocator), make([][2]f32, n, context.temp_allocator)
	pressure, kind := make([]f32, n, context.temp_allocator), make([]u8, n, context.temp_allocator)
	for f in t.frames {
		at := geom.rec_begin(&out, Strokes_Tag.Frame)
		o := &out
		c := f.camera
		geom.rec_put(o, F.Target, c.target)
		geom.rec_put(o, F.Distance, c.distance)
		geom.rec_put(o, F.Yaw, c.yaw)
		geom.rec_put(o, F.Pitch, c.pitch)
		geom.rec_put(o, F.Fov_Y, c.fov_y)
		geom.rec_put(o, F.Near, c.near)
		geom.rec_put(o, F.Far, c.far)
		geom.rec_put(o, F.Roll, c.roll)
		geom.rec_put(o, F.Ortho, u8(c.ortho))
		geom.rec_put(o, F.Size, f.size)
		geom.rec_put(o, F.Mouse, f.mouse_pos)
		geom.rec_put(o, F.Pen_Tilt, f.pen_tilt)
		geom.rec_put(o, F.Pen_Roll, f.pen_roll)
		geom.rec_put(o, F.Brush, f.brush)
		geom.rec_put(o, F.Primary, u8(f.primary))
		geom.rec_put(o, F.Smooth, u8(f.smooth))
		geom.rec_put(o, F.Invert, u8(f.invert))
		geom.rec_put(o, F.Mask, u8(f.mask))
		geom.rec_put(o, F.Alt, u8(f.alt))
		for s, k in t.samples[f.first:][:f.count] do pos[k], pressure[k], kind[k], tilt[k] = s.pos, s.pressure, u8(s.kind), s.tilt
		geom.rec_put_slice(o, F.Positions, pos[:f.count])
		geom.rec_put_slice(o, F.Pressures, pressure[:f.count])
		geom.rec_put_slice(o, F.Kinds, kind[:f.count])
		geom.rec_put_slice(o, F.Tilts, tilt[:f.count])
		geom.rec_end(&out, at)
	}
	geom.record_end(&out, rec)
	if !write_file_safely(app, path, out[:], "save strokes to") do return false
	file_note(app, false, "Saved %d strokes to %s", take_strokes(t), filepath.base(path))
	return true
}

// Reads a .strokes file into the recording. Every number is checked (finite, in range)
// before it can reach a brush, so a damaged file is refused rather than sculpting NaNs.
strokes_load :: proc(app: ^App, path: string) -> bool {
	data, err := file_read_any(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot open %s: %v", filepath.base(path), err)
		return false
	}
	defer delete(data)
	t: Take
	ok := strokes_read(app, data, &t)
	if !ok {
		take_destroy(&t)
		file_note(app, true, "Cannot load %s: it is not a strokes file, or it is damaged", filepath.base(path))
		return false
	}
	replay_stop(app)
	app.replay.recording = false
	take_destroy(&app.replay.take)
	app.replay.take = t
	file_note(app, false, "Loaded %d strokes from %s: Replay or R plays them", take_strokes(&t), filepath.base(path))
	return true
}

@(private = "file")
strokes_read :: proc(app: ^App, data: []u8, t: ^Take) -> bool {
	B :: Stroke_Brush_Tag
	F :: Stroke_Frame_Tag
	r := geom.byte_reader(data)
	if len(data) < len(STROKES_MAGIC) || string(data[:len(STROKES_MAGIC)]) != STROKES_MAGIC do return false
	r.at = len(STROKES_MAGIC)
	if geom.byte_get(&r, u32) != STROKES_FORMAT do return false
	rec := geom.record_take(&r)
	if !rec.ok || r.at != len(data) do return false
	if known, _ := geom.record_known(&rec, Strokes_Tag); !known do return false
	brushes := geom.rec_count(&rec, Strokes_Tag.Brush)
	if brushes < 1 do return false
	finite :: proc(xs: ..f32) -> bool {
		for x in xs do if math.is_nan(x) || math.is_inf(x) do return false
		return true
	}
	curve_ok :: proc(c: geom.Curve) -> bool {
		return finite(c.c1.x, c.c1.y, c.c2.x, c.c2.y) && c.c1.x >= 0 && c.c1.x <= 1 && c.c2.x >= 0 && c.c2.x <= 1
	}
	curve_get :: proc(rec: ^geom.Record, tag: Stroke_Brush_Tag, default: geom.Curve) -> geom.Curve {
		return transmute(geom.Curve)geom.rec_get(rec, tag, [2][2]f32, transmute([2][2]f32)default)
	}
	brush_at := 0
	for _ in 0 ..< brushes {
		payload, _ := geom.rec_next(&rec, Strokes_Tag.Brush, &brush_at)
		br := geom.record_of(payload)
		if known, _ := geom.record_known(&br, Stroke_Brush_Tag); !known do return false
		b := app.brush
		// A recorded brush is plain: what it was recorded with is all it needs.
		b.preset = 0
		now := b
		was_pressure := brush_pressure(&now, now.kind)
		kind := geom.rec_get(&br, B.Kind, u8, u8(b.kind))
		k := sculpt.Brush_Kind(kind) if int(kind) < len(sculpt.Brush_Kind) else b.kind
		g8 :: proc(rec: ^geom.Record, tag: Stroke_Brush_Tag, now: bool) -> u8 {return geom.rec_get(rec, tag, u8, u8(now))}
		radius := geom.rec_get(&br, B.Radius, f32, b.radius_px)
		strength := geom.rec_get(&br, B.Strength, f32, b.strengths[k])
		fall := b.falloffs[k]
		drawn := g8(&br, B.Falloff_Drawn, fall.drawn)
		falloff := curve_get(&br, B.Falloff, fall.curve)
		pressure_strength := g8(&br, B.Pressure_Strength, was_pressure.strength)
		pressure_size := g8(&br, B.Pressure_Size, was_pressure.size)
		pressure_curve := curve_get(&br, B.Pressure_Curve, was_pressure.strength_curve)
		lazy := geom.rec_get(&br, B.Lazy, f32, b.lazy_px)
		front := g8(&br, B.Front_Only, b.front_only)
		stroke := geom.rec_get(&br, B.Stroke, u8, u8(b.stroke))
		symmetry := geom.rec_get(&br, B.Symmetry, u8, transmute(u8)b.symmetry)
		color := geom.rec_get(&br, B.Color, [3]f32, b.color)
		cloth := geom.rec_get(&br, B.Cloth_Mode, u8, u8(b.cloth_mode))
		spread := geom.rec_get(&br, B.Spray_Spread, f32, b.spray_spread)
		seed := geom.rec_get(&br, B.Seed, u64, 0)
		line := g8(&br, B.Line, b.line)
		join := g8(&br, B.Join, b.join)
		lock_plane := g8(&br, B.Lock_Plane, b.lock_plane)
		connected := g8(&br, B.Connected, b.connected)
		focal := geom.rec_get(&br, B.Focal, f32, fall.focal)
		scale := geom.rec_get(&br, B.Scale, f32, 1)
		radial := [4]u8 {
			g8(&br, B.Sym_Local, b.sym_local),
			g8(&br, B.Radial_On, b.radial_on),
			geom.rec_get(&br, B.Radial_Count, u8, u8(clamp(b.radial_count, RADIAL_MIN, sculpt.RADIAL_MAX))),
			geom.rec_get(&br, B.Radial_Axis, u8, u8(b.radial_axis)),
		}
		channel := geom.rec_get(&br, B.Channel, u8, u8(b.channel))
		reach := [2]u8{g8(&br, B.Grab_Depth, b.grab_depth), geom.rec_get(&br, B.Smooth_Only, u8, u8(b.smooth_only))}
		spaced := [2]f32{geom.rec_get(&br, B.Spacing, f32, dot_spacing_of(b)), geom.rec_get(&br, B.Color_Spray, f32, b.color_spray)}
		dial := g8(&br, B.Paint_Dial, b.paint_dial)
		steady := [2]f32{geom.rec_get(&br, B.Smoothing, f32, f32(steady_count(b.smoothing))), geom.rec_get(&br, B.Pressure_Smoothing, f32, f32(steady_count(b.pressure_smoothing)))}
		catch_up := g8(&br, B.Catch_Up, b.catch_up)
		evened := [3]u8{g8(&br, B.Even_Strength, b.even_strength), g8(&br, B.Scene_Spacing, b.scene_spacing), g8(&br, B.Feather, b.feather)}
		grabbing := [3]u8{geom.rec_get(&br, B.Grab_Mode, u8, u8(b.grab_mode)), g8(&br, B.Grab_Same_Side, b.grab_same_side), g8(&br, B.Grab_Silhouette, b.grab_silhouette)}
		normal_weight := geom.rec_get(&br, B.Grab_Normal, f32, b.grab_normal)
		topological := g8(&br, B.Grab_Topological, b.grab_topological)
		volume := geom.rec_get(&br, B.Elastic_Volume, f32, b.elastic_volume)
		hooked := [2]f32{geom.rec_get(&br, B.Hook_Pinch, f32, b.hook_pinch), geom.rec_get(&br, B.Hook_Rake, f32, b.hook_rake)}
		hook_elastic := g8(&br, B.Hook_Elastic, b.hook_elastic)
		pressure_size_curve := curve_get(&br, B.Pressure_Size_Curve, was_pressure.size_curve)
		size_floor := geom.rec_get(&br, B.Size_Floor, f32, was_pressure.size_floor)
		stable := g8(&br, B.Smooth_Stable, b.smooth_stable)
		smooth_mode := geom.rec_get(&br, B.Smooth_Mode, u8, u8(b.smooth_mode))
		sampled := [2]f32{geom.rec_get(&br, B.Stabilize, f32, b.stabilize), geom.rec_get(&br, B.Sample_Radius, f32, b.sample_radius)}
		one_pass := g8(&br, B.One_Pass, b.no_accumulate[k])
		hardness := geom.rec_get(&br, B.Hardness, f32, fall.hardness)
		projected := g8(&br, B.Projected, fall.projected)
		ways := [3]u8{g8(&br, B.One_Way, b.one_way), g8(&br, B.Directional, b.directional), g8(&br, B.Size_World, b.size_world)}
		size_ref := geom.rec_get(&br, B.Size_Ref, f32, b.size_ref)
		// A tip scale of 0 is a whole one, as sculpt.Brush reads it.
		shaped := [5]f32 {
			geom.rec_get(&br, B.Tip_Roundness, f32, b.tip_roundness),
			geom.rec_get(&br, B.Tip_Scale, f32, b.tip_scale),
			geom.rec_get(&br, B.Trim_Angle, f32, b.trim_angle),
			geom.rec_get(&br, B.Plane_Height, f32, b.plane_height),
			geom.rec_get(&br, B.Plane_Depth, f32, b.plane_depth),
		}
		trim_dynamic := g8(&br, B.Trim_Dynamic, b.trim_dynamic)
		outline := g8(&br, B.Grab_Outline, b.grab_outline)
		cloth_ways := [4]u8{geom.rec_get(&br, B.Cloth_Region, u8, u8(b.cloth.region)), g8(&br, B.Cloth_Keep_Area, b.cloth.keep_area), g8(&br, B.Cloth_Allow_Shrink, b.cloth.allow_shrink), g8(&br, B.Cloth_Allow_Expand, b.cloth.allow_expand)}
		cloth_amounts := [4]f32 {
			geom.rec_get(&br, B.Cloth_Stiffness, f32, b.cloth.stiffness),
			geom.rec_get(&br, B.Cloth_Firmness, f32, b.cloth.firmness),
			geom.rec_get(&br, B.Cloth_Damping, f32, b.cloth.damping),
			geom.rec_get(&br, B.Cloth_Gravity, f32, b.cloth.gravity),
		}
		physics := g8(&br, B.Physics, b.physics)
		physics_strength := geom.rec_get(&br, B.Physics_Strength, f32, b.physics_strength)
		if !br.ok || int(kind) >= len(sculpt.Brush_Kind) || int(stroke) >= len(Stroke_Mode) || int(cloth) >= len(sculpt.Cloth_Mode) do return false
		all_axes := transmute(u8)sculpt.Symmetry{.X, .Y, .Z}
		if int(channel) >= len(sculpt.Channel) || dial > 1 || reach[0] > 1 || int(reach[1]) >= len(sculpt.Smooth_Only) do return false
		if radial[0] > 1 || radial[1] > 1 || radial[2] < RADIAL_MIN || radial[2] > sculpt.RADIAL_MAX || int(radial[3]) >= len(sculpt.Axis) do return false
		if symmetry & ~all_axes != 0 || drawn > 1 || pressure_strength > 1 || pressure_size > 1 || front > 1 || line > 1 || join > 1 || lock_plane > 1 || connected > 1 || catch_up > 1 || evened[0] > 1 || evened[1] > 1 || evened[2] > 1 do return false
		if int(grabbing[0]) >= len(Grab_Mode) || grabbing[1] > 1 || grabbing[2] > 1 || topological > 1 || !finite(normal_weight, volume) || volume < 0 || volume > 1 || !finite(hooked[0], hooked[1]) || abs(hooked[0]) > 1 || hooked[1] < 0 || hooked[1] > 1 || hook_elastic > 1 || normal_weight < 0 || normal_weight > 1 do return false
		if !finite(radius, strength, lazy, spread, color.r, color.g, color.b, focal, scale, spaced[0], spaced[1], steady[0], steady[1]) || !curve_ok(falloff) || !curve_ok(pressure_curve) || !curve_ok(pressure_size_curve) || !finite(size_floor) || size_floor < 0 || size_floor > 1 || stable > 1 || int(smooth_mode) >= len(sculpt.Smooth_Mode) do return false
		if !finite(sampled[0], sampled[1]) || sampled[0] < 0 || sampled[0] > sculpt.STABILIZE_MAX || sampled[1] < 0 || sampled[1] > 1 || one_pass > 1 || !finite(hardness) || hardness < 0 || hardness > sculpt.HARDNESS_MAX || projected > 1 || ways[0] > 1 || ways[1] > 1 || ways[2] > 1 || !finite(size_ref) || size_ref < 0 do return false
		if !finite(shaped[0], shaped[1], shaped[2], shaped[3], shaped[4]) || shaped[0] < 0 || shaped[0] > 1 || (shaped[1] != 0 && shaped[1] < sculpt.CLAY_TIP_SCALE_MIN) || shaped[1] > 1 || shaped[2] < 0 || shaped[2] > 160 || shaped[3] < 0 || shaped[3] > 1 || shaped[4] < 0 || shaped[4] > 1 || trim_dynamic > 1 || outline > 1 do return false
		if focal < sculpt.FOCAL_MIN || focal > sculpt.FOCAL_MAX || scale < TOUCH_STRENGTH_MIN || scale > 1 do return false
		if int(cloth_ways[0]) >= len(sculpt.Cloth_Region) || cloth_ways[1] > 1 || cloth_ways[2] > 1 || cloth_ways[3] > 1 do return false
		for x in cloth_amounts do if !finite(x) || x < 0 || x > 1 do return false
		if physics > 1 || !finite(physics_strength) || physics_strength < 0 || physics_strength > 1 do return false
		b.kind = sculpt.Brush_Kind(kind)
		b.radius_px = clamp(radius, MIN_RADIUS_PX, MAX_RADIUS_PX)
		b.strengths[b.kind] = clamp(strength, MIN_STRENGTH, 1)
		b.falloffs[b.kind] = {drawn = drawn == 1, curve = falloff, focal = focal, hardness = hardness, projected = projected == 1}
		b.pressure_strength, b.pressure_size, b.pressure_curve, b.pressure_size_curve = pressure_strength == 1, pressure_size == 1, pressure_curve, pressure_size_curve
		b.pressure_size_floor = size_floor
		b.smooth_stable, b.smooth_mode = stable == 1, sculpt.Smooth_Mode(smooth_mode)
		b.stabilize, b.sample_radius = sampled[0], sampled[1]
		b.no_accumulate[b.kind] = one_pass == 1
		b.one_way, b.directional, b.size_world, b.size_ref = ways[0] == 1, ways[1] == 1, ways[2] == 1, size_ref
		b.tip_roundness, b.tip_scale, b.trim_angle, b.plane_height, b.plane_depth = shaped[0], shaped[1], shaped[2], shaped[3], shaped[4]
		b.trim_dynamic = trim_dynamic == 1
		b.grab_outline = outline == 1
		b.pressures[b.kind].own = false
		b.lazy_px = clamp(lazy, 0, MAX_RADIUS_PX)
		b.front_only, b.stroke, b.symmetry = front == 1, Stroke_Mode(stroke), transmute(sculpt.Symmetry)symmetry
		b.color = {clamp(color.r, 0, 1), clamp(color.g, 0, 1), clamp(color.b, 0, 1)}
		b.cloth_mode = sculpt.Cloth_Mode(cloth)
		b.physics, b.physics_strength = physics == 1, max(physics_strength, 0.05)
		b.cloth = {
			region = sculpt.Cloth_Region(cloth_ways[0]), keep_area = cloth_ways[1] == 1, allow_shrink = cloth_ways[2] == 1, allow_expand = cloth_ways[3] == 1,
			stiffness = cloth_amounts[0], firmness = cloth_amounts[1], damping = cloth_amounts[2], gravity = cloth_amounts[3],
		}
		b.spray_spread = clamp(spread, 0, SPRAY_MAX_SPREAD)
		b.line, b.join = line == 1, join == 1
		b.lock_plane, b.connected = lock_plane == 1, connected == 1
		b.sym_local, b.radial_on, b.radial_count, b.radial_axis = radial[0] == 1, radial[1] == 1, i32(radial[2]), sculpt.Axis(radial[3])
		b.channel = sculpt.Channel(channel)
		b.paint_dial = dial == 1
		b.grab_depth, b.smooth_only = reach[0] == 1, sculpt.Smooth_Only(reach[1])
		b.spacing, b.color_spray = clamp(spaced[0], MIN_SPACING, MAX_SPACING), clamp(spaced[1], 0, 1)
		b.smoothing, b.pressure_smoothing, b.catch_up = f32(steady_count(steady[0])), f32(steady_count(steady[1])), catch_up == 1
		b.even_strength, b.scene_spacing, b.feather = evened[0] == 1, evened[1] == 1, evened[2] == 1
		b.grab_mode, b.grab_same_side, b.grab_silhouette, b.grab_normal = Grab_Mode(grabbing[0]), grabbing[1] == 1, grabbing[2] == 1, normal_weight
		b.grab_topological = topological == 1
		b.elastic_volume = volume
		b.hook_pinch, b.hook_rake, b.hook_elastic = hooked[0], hooked[1], hook_elastic == 1
		append(&t.brushes, b)
		append(&t.seeds, seed)
		append(&t.scales, scale)
	}
	frames := geom.rec_count(&rec, Strokes_Tag.Frame)
	if frames < 1 do return false
	frame_at := 0
	for _ in 0 ..< frames {
		payload, _ := geom.rec_next(&rec, Strokes_Tag.Frame, &frame_at)
		fr := geom.record_of(payload)
		if known, _ := geom.record_known(&fr, Stroke_Frame_Tag); !known do return false
		f: Take_Frame
		c := &f.camera
		c.target = geom.rec_get(&fr, F.Target, Vec3, Vec3{})
		c.distance = geom.rec_get(&fr, F.Distance, f32, 0)
		c.yaw = geom.rec_get(&fr, F.Yaw, f32, 0)
		c.pitch = geom.rec_get(&fr, F.Pitch, f32, 0)
		c.fov_y = geom.rec_get(&fr, F.Fov_Y, f32, 0)
		c.near = geom.rec_get(&fr, F.Near, f32, 0)
		c.far = geom.rec_get(&fr, F.Far, f32, 0)
		c.roll = geom.rec_get(&fr, F.Roll, f32, 0)
		ortho := geom.rec_get(&fr, F.Ortho, u8, 0)
		f.size = geom.rec_get(&fr, F.Size, [2]f32, [2]f32{})
		f.mouse_pos = geom.rec_get(&fr, F.Mouse, [2]f32, [2]f32{})
		f.pen_tilt = geom.rec_get(&fr, F.Pen_Tilt, [2]f32, [2]f32{})
		f.pen_roll = geom.rec_get(&fr, F.Pen_Roll, f32, 0)
		f.brush = geom.rec_need(&fr, F.Brush, u32)
		flags := [5]u8{geom.rec_get(&fr, F.Primary, u8, 0), geom.rec_get(&fr, F.Smooth, u8, 0), geom.rec_get(&fr, F.Invert, u8, 0), geom.rec_get(&fr, F.Mask, u8, 0), geom.rec_get(&fr, F.Alt, u8, 0)}
		ta := context.temp_allocator
		pos := geom.rec_get_slice(&fr, F.Positions, [2]f32, ta)
		pressure := geom.rec_get_slice(&fr, F.Pressures, f32, ta)
		kinds := geom.rec_get_slice(&fr, F.Kinds, u8, ta)
		tilts := geom.rec_get_slice(&fr, F.Tilts, [2]f32, ta)
		count := len(pos)
		if !fr.ok || ortho > 1 || int(f.brush) >= brushes || len(pressure) != count || len(kinds) != count || len(tilts) != count do return false
		for x in flags do if x > 1 do return false
		if !finite(c.target.x, c.target.y, c.target.z, c.distance, c.yaw, c.pitch, c.fov_y, c.near, c.far, c.roll) do return false
		if !finite(f.size.x, f.size.y, f.mouse_pos.x, f.mouse_pos.y, f.pen_tilt.x, f.pen_tilt.y, f.pen_roll) || abs(f.pen_roll) > 180 do return false
		if c.distance <= 0 || c.fov_y <= 0 || c.fov_y >= math.PI || c.near <= 0 || c.far <= c.near || f.size.x < 1 || f.size.y < 1 do return false
		c.ortho = ortho == 1
		c.yaw, c.pitch, c.roll = camera.wrap_angle(c.yaw), camera.wrap_angle(c.pitch), camera.wrap_angle(c.roll)
		f.primary, f.smooth, f.invert, f.mask, f.alt = flags[0] == 1, flags[1] == 1, flags[2] == 1, flags[3] == 1, flags[4] == 1
		f.first, f.count = u32(len(t.samples)), u32(count)
		for i in 0 ..< count {
			s := Input_Sample{pos = pos[i], pressure = pressure[i], tilt = tilts[i]}
			if int(kinds[i]) >= len(Sample_Kind) || !finite(s.pos.x, s.pos.y, s.pressure, s.tilt.x, s.tilt.y) do return false
			s.kind, s.pressure = Sample_Kind(kinds[i]), clamp(s.pressure, 0, 1)
			append(&t.samples, s)
		}
		append(&t.frames, f)
	}
	return true
}

// The interface's Stroke recorder section.
kit_replay_section :: proc(app: ^App) {
	ctx := &app.kit.ctx
	p := &app.replay
	busy := replay_busy(app)
	if p.recording {
		if ui.button(ctx, "Stop recording", .Solid, .Danger, glyph = ui.ICON_STOP) do replay_record_stop(app)
		ui.paragraph(ctx, fmt.tprintf("Recording: %d strokes.", take_strokes(&p.take)))
	} else {
		source := replay_source(app)
		record, replay := kit_button_pair(ctx, "Record", "Replay", !busy, !busy && len(source.frames) > 0, .Danger)
		if record do replay_record_start(app)
		if replay do replay_start(app, source)
		switch {
		case busy:
			if ui.button(ctx, "Stop replay", .Flat, glyph = ui.ICON_STOP) do replay_stop(app)
		case len(p.take.frames) > 0:
			ui.paragraph(ctx, fmt.tprintf("Recorded: %d strokes.", take_strokes(&p.take)))
		case len(p.last.frames) > 0:
			ui.paragraph(ctx, "Replay plays the last stroke.")
		case:
			ui.paragraph(ctx, "Nothing recorded yet.")
		}
	}
	ui.paragraph(ctx, "R over the viewport replays the recording (or else the last stroke) from the pointer, in this view; Replay puts it back where it was drawn.")
	if kit_more(app, .Recorder) {
		_ = ui.switch_row(ctx, "Recorded brushes", &p.recorded_brush)
		_ = ui.switch_row(ctx, "Instant", &p.instant)
		idle := !p.recording && !busy
		save, load := kit_button_pair(ctx, "Save strokes...", "Load strokes...", idle, idle)
		if save do file_dialog(app, .Save_Strokes)
		if load do file_dialog(app, .Load_Strokes)
		if ui.button(ctx, "Clear the recording", .Light, .Danger, enabled = idle && len(p.take.frames) > 0) do take_clear(&p.take)
		ui.paragraph(ctx, "With Recorded brushes off a replay uses the brush set now; Instant plays it all at once rather than at the pace it was drawn.")
		kit_more_end(app)
	}
}
