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
	primary, smooth, invert: bool,
	mask:      bool, // the modifier rail's Mask: the stroke painted the mask
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
		camera = app.camera, size = input.size, mouse_pos = input.mouse_pos, pen_tilt = input.pen_tilt,
		primary = input.primary, smooth = input.smooth, invert = input.invert, mask = input.mask,
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
			size = f.size, mouse_pos = f.mouse_pos, pen_tilt = f.pen_tilt, hovered = true,
			primary = f.primary, smooth = f.smooth, invert = f.invert, mask = f.mask, samples = samples,
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

// The .strokes file: "SCSTROKE", a version, then the brushes and the frames, every
// number little-endian. A brush keeps what makes a stroke what it is (kind, size,
// strength, falloff, pressure, lazy mouse, front faces, stroke mode, symmetry, colour and
// paint channel, cloth mode, Spray's spread, the stroke's seed and strength scale, Line and Join strokes, All depth and Smooth
// only); the rest
// (alpha, tilt, dynamic topology detail) comes from the brush as set when the file is
// loaded, since an alpha names an image that may not be there.
STROKES_MAGIC :: "SCSTROKE"
// 2: each frame's camera roll; 3: the rail's Mask in a frame's flags; 4: each brush's
// spread and seed after its cloth mode; 5: its Line and Join switches after those; 6: its
// Lock plane and Connected switches after those; 7: its focal shift after those; 8: the
// stroke's strength scale (Touch strength) after that; 9: local symmetry, radial symmetry
// on, its copies and its axis after that; 10: the paint channel after those; 11: Grab's
// All depth and Smooth's Smooth only after that.
STROKES_VERSION :: u32(11)

strokes_save :: proc(app: ^App, path: string) -> bool {
	t := replay_source(app)
	if len(t.frames) == 0 {
		file_note(app, true, "There are no strokes to save: draw or record some first")
		return false
	}
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, STROKES_MAGIC)
	geom.byte_put(&out, STROKES_VERSION)
	geom.byte_put(&out, u32(len(t.brushes)))
	for b, i in t.brushes {
		geom.byte_put(&out, u8(b.kind))
		geom.byte_put(&out, b.radius_px)
		geom.byte_put(&out, b.strengths[b.kind])
		f := b.falloffs[b.kind]
		geom.byte_put(&out, u8(f.drawn))
		geom.byte_put(&out, f.curve)
		geom.byte_put(&out, u8(b.pressure_strength))
		geom.byte_put(&out, u8(b.pressure_size))
		geom.byte_put(&out, b.pressure_curve)
		geom.byte_put(&out, b.lazy_px)
		geom.byte_put(&out, u8(b.front_only))
		geom.byte_put(&out, u8(b.stroke))
		geom.byte_put(&out, transmute(u8)b.symmetry)
		geom.byte_put(&out, b.color)
		geom.byte_put(&out, u8(b.cloth_mode))
		geom.byte_put(&out, b.spray_spread)
		geom.byte_put(&out, t.seeds[i])
		geom.byte_put(&out, u8(b.line))
		geom.byte_put(&out, u8(b.join))
		geom.byte_put(&out, u8(b.lock_plane))
		geom.byte_put(&out, u8(b.connected))
		geom.byte_put(&out, f.focal)
		geom.byte_put(&out, t.scales[i])
		geom.byte_put(&out, [4]u8{u8(b.sym_local), u8(b.radial_on), u8(clamp(b.radial_count, RADIAL_MIN, sculpt.RADIAL_MAX)), u8(b.radial_axis)})
		geom.byte_put(&out, u8(b.channel))
		geom.byte_put(&out, [2]u8{u8(b.grab_depth), u8(b.smooth_only)})
	}
	geom.byte_put(&out, u32(len(t.frames)))
	for f in t.frames {
		c := f.camera
		geom.byte_put(&out, c.target)
		geom.byte_put(&out, [7]f32{c.distance, c.yaw, c.pitch, c.fov_y, c.near, c.far, c.roll})
		geom.byte_put(&out, u8(c.ortho))
		geom.byte_put(&out, f.size)
		geom.byte_put(&out, f.mouse_pos)
		geom.byte_put(&out, f.pen_tilt)
		geom.byte_put(&out, f.brush)
		geom.byte_put(&out, u8(f.primary) | u8(f.smooth) << 1 | u8(f.invert) << 2 | u8(f.mask) << 3)
		geom.byte_put(&out, f.count)
		for s in t.samples[f.first:][:f.count] {
			geom.byte_put(&out, s.pos)
			geom.byte_put(&out, s.pressure)
			geom.byte_put(&out, u8(s.kind))
			geom.byte_put(&out, s.tilt)
		}
	}
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
	r := geom.byte_reader(data)
	if len(data) < len(STROKES_MAGIC) || string(data[:len(STROKES_MAGIC)]) != STROKES_MAGIC do return false
	r.at = len(STROKES_MAGIC)
	// Older files are read too: version 1 has no roll.
	version := geom.byte_get(&r, u32)
	if version < 1 || version > STROKES_VERSION do return false
	brushes := int(geom.byte_get(&r, u32))
	if !r.ok || brushes < 1 || brushes > len(data) do return false
	finite :: proc(xs: ..f32) -> bool {
		for x in xs do if math.is_nan(x) || math.is_inf(x) do return false
		return true
	}
	curve_ok :: proc(c: geom.Curve) -> bool {
		return finite(c.c1.x, c.c1.y, c.c2.x, c.c2.y) && c.c1.x >= 0 && c.c1.x <= 1 && c.c2.x >= 0 && c.c2.x <= 1
	}
	for _ in 0 ..< brushes {
		b := app.brush
		// A recorded brush is plain: what it was recorded with is all it needs.
		b.preset = 0
		kind := geom.byte_get(&r, u8)
		radius := geom.byte_get(&r, f32)
		strength := geom.byte_get(&r, f32)
		drawn := geom.byte_get(&r, u8)
		falloff := geom.byte_get(&r, geom.Curve)
		pressure_strength := geom.byte_get(&r, u8)
		pressure_size := geom.byte_get(&r, u8)
		pressure_curve := geom.byte_get(&r, geom.Curve)
		lazy := geom.byte_get(&r, f32)
		front := geom.byte_get(&r, u8)
		stroke := geom.byte_get(&r, u8)
		symmetry := geom.byte_get(&r, u8)
		color := geom.byte_get(&r, [3]f32)
		cloth := geom.byte_get(&r, u8)
		// Before version 4 a stroke has the spread as set now and seed 0: those files were
		// drawn before Spray, so neither changes how they replay.
		spread, seed := b.spray_spread, u64(0)
		if version >= 4 {
			spread = geom.byte_get(&r, f32)
			seed = geom.byte_get(&r, u64)
		}
		// Before version 5 neither switch existed, so both were off.
		line, join: u8
		if version >= 5 {
			line = geom.byte_get(&r, u8)
			join = geom.byte_get(&r, u8)
		}
		// Nor, before version 6, these two.
		lock_plane, connected: u8
		if version >= 6 {
			lock_plane = geom.byte_get(&r, u8)
			connected = geom.byte_get(&r, u8)
		}
		// Nor, before version 7, a focal shift.
		focal: f32
		if version >= 7 do focal = geom.byte_get(&r, f32)
		// Nor, before version 8, a strength scale: every stroke was at full strength.
		scale := f32(1)
		if version >= 8 do scale = geom.byte_get(&r, f32)
		// Nor, before version 9, local or radial symmetry.
		radial := [4]u8{0, 0, RADIAL_DEFAULT, u8(sculpt.Axis.Y)}
		if version >= 9 do radial = geom.byte_get(&r, [4]u8)
		// Nor, before version 10, a paint channel: the brushes only sculpted.
		channel: u8
		if version >= 10 do channel = geom.byte_get(&r, u8)
		// Nor, before version 11, All depth or Smooth only: Grab's reach was round and
		// Smooth worked on everything.
		reach: [2]u8
		if version >= 11 do reach = geom.byte_get(&r, [2]u8)
		if !r.ok || int(kind) >= len(sculpt.Brush_Kind) || int(stroke) >= len(Stroke_Mode) || int(cloth) >= len(sculpt.Cloth_Mode) do return false
		all_axes := transmute(u8)sculpt.Symmetry{.X, .Y, .Z}
		if int(channel) >= len(sculpt.Channel) || reach[0] > 1 || int(reach[1]) >= len(sculpt.Smooth_Only) do return false
		if radial[0] > 1 || radial[1] > 1 || radial[2] < RADIAL_MIN || radial[2] > sculpt.RADIAL_MAX || int(radial[3]) >= len(sculpt.Axis) do return false
		if symmetry & ~all_axes != 0 || drawn > 1 || pressure_strength > 1 || pressure_size > 1 || front > 1 || line > 1 || join > 1 || lock_plane > 1 || connected > 1 do return false
		if !finite(radius, strength, lazy, spread, color.r, color.g, color.b, focal, scale) || !curve_ok(falloff) || !curve_ok(pressure_curve) do return false
		if focal < sculpt.FOCAL_MIN || focal > sculpt.FOCAL_MAX || scale < TOUCH_STRENGTH_MIN || scale > 1 do return false
		b.kind = sculpt.Brush_Kind(kind)
		b.radius_px = clamp(radius, MIN_RADIUS_PX, MAX_RADIUS_PX)
		b.strengths[b.kind] = clamp(strength, MIN_STRENGTH, 1)
		b.falloffs[b.kind] = {drawn = drawn == 1, curve = falloff, focal = focal}
		b.pressure_strength, b.pressure_size, b.pressure_curve = pressure_strength == 1, pressure_size == 1, pressure_curve
		b.lazy_px = clamp(lazy, 0, MAX_RADIUS_PX)
		b.front_only, b.stroke, b.symmetry = front == 1, Stroke_Mode(stroke), transmute(sculpt.Symmetry)symmetry
		b.color = {clamp(color.r, 0, 1), clamp(color.g, 0, 1), clamp(color.b, 0, 1)}
		b.cloth_mode = sculpt.Cloth_Mode(cloth)
		b.spray_spread = clamp(spread, 0, SPRAY_MAX_SPREAD)
		b.line, b.join = line == 1, join == 1
		b.lock_plane, b.connected = lock_plane == 1, connected == 1
		b.sym_local, b.radial_on, b.radial_count, b.radial_axis = radial[0] == 1, radial[1] == 1, i32(radial[2]), sculpt.Axis(radial[3])
		b.channel = sculpt.Channel(channel)
		b.grab_depth, b.smooth_only = reach[0] == 1, sculpt.Smooth_Only(reach[1])
		// Grab left Connected alone before version 11, so a Grab stroke recorded with it
		// on replays as it was drawn.
		if version < 11 && b.kind == .Grab do b.connected = false
		append(&t.brushes, b)
		append(&t.seeds, seed)
		append(&t.scales, scale)
	}
	frames := int(geom.byte_get(&r, u32))
	if !r.ok || frames < 1 || frames > len(data) do return false
	for _ in 0 ..< frames {
		f: Take_Frame
		c := &f.camera
		c.target = geom.byte_get(&r, Vec3)
		k: [7]f32
		if version >= 2 {
			k = geom.byte_get(&r, [7]f32)
		} else {
			old := geom.byte_get(&r, [6]f32)
			copy(k[:], old[:])
		}
		c.distance, c.yaw, c.pitch, c.fov_y, c.near, c.far, c.roll = k[0], k[1], k[2], k[3], k[4], k[5], k[6]
		ortho := geom.byte_get(&r, u8)
		f.size = geom.byte_get(&r, [2]f32)
		f.mouse_pos = geom.byte_get(&r, [2]f32)
		f.pen_tilt = geom.byte_get(&r, [2]f32)
		f.brush = geom.byte_get(&r, u32)
		flags := geom.byte_get(&r, u8)
		count := geom.byte_get(&r, u32)
		if !r.ok || ortho > 1 || flags > (15 if version >= 3 else 7) || int(f.brush) >= brushes || int(count) > (len(data) - r.at) / 21 do return false
		if !finite(c.target.x, c.target.y, c.target.z, c.distance, c.yaw, c.pitch, c.fov_y, c.near, c.far, c.roll) do return false
		if !finite(f.size.x, f.size.y, f.mouse_pos.x, f.mouse_pos.y, f.pen_tilt.x, f.pen_tilt.y) do return false
		if c.distance <= 0 || c.fov_y <= 0 || c.fov_y >= math.PI || c.near <= 0 || c.far <= c.near || f.size.x < 1 || f.size.y < 1 do return false
		c.ortho = ortho == 1
		c.yaw, c.pitch, c.roll = camera.wrap_angle(c.yaw), camera.wrap_angle(c.pitch), camera.wrap_angle(c.roll)
		f.primary, f.smooth, f.invert = flags & 1 != 0, flags & 2 != 0, flags & 4 != 0
		f.mask = flags & 8 != 0
		f.first, f.count = u32(len(t.samples)), count
		for _ in 0 ..< count {
			s: Input_Sample
			s.pos = geom.byte_get(&r, [2]f32)
			s.pressure = geom.byte_get(&r, f32)
			kind := geom.byte_get(&r, u8)
			s.tilt = geom.byte_get(&r, [2]f32)
			if !r.ok || int(kind) >= len(Sample_Kind) || !finite(s.pos.x, s.pos.y, s.pressure, s.tilt.x, s.tilt.y) do return false
			s.kind, s.pressure = Sample_Kind(kind), clamp(s.pressure, 0, 1)
			append(&t.samples, s)
		}
		append(&t.frames, f)
	}
	return r.ok && r.at == len(data)
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
