package main

import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"
import "../ui"

// A selected sphere at the world's middle with no GPU buffers, the Draw brush held.
@(private = "file")
stroke_sphere :: proc(app: ^App, subdivisions := 4) -> ^Object {
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(subdivisions), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	app.camera = camera.orbit_default()
	app.tool = .Brush
	app.brush.kind, app.brush.radius_px = .Draw, 60
	app.brush.strengths[.Draw], app.brush.strengths[.Smooth] = 0.5, 0.5
	return obj
}

@(private = "file")
stroke_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	delete(app.stroke.pending)
	history_destroy(&app.history)
	results_destroy(app)
}

@(private = "file")
STROKE_SIZE :: [2]f32{1000, 800}

// A stroke along `path`, one sample a frame, with Shift (smooth) held from sample
// `shift_from` on, then the release.
@(private = "file")
stroke_along :: proc(app: ^App, path: [][2]f32, shift_from: int) {
	for p, i in path {
		samples := []Input_Sample{{pos = p, pressure = 1, kind = .Press if i == 0 else .Move}}
		_ = sculpt_frame(app, {size = STROKE_SIZE, mouse_pos = p, hovered = true, primary = true, press = i == 0, smooth = i >= shift_from, samples = samples})
	}
	_ = sculpt_frame(app, {size = STROKE_SIZE, mouse_pos = path[len(path) - 1], hovered = true})
}

// The brush a stroke uses is the one its press chose: Shift pressed mid-stroke leaves a
// Draw stroke drawing (the same mesh as without it), while Shift at the press smooths.
@(test)
stroke_keeps_the_brush_its_press_chose :: proc(t: ^testing.T) {
	path := [?][2]f32{{440, 380}, {470, 390}, {500, 400}, {530, 410}, {560, 420}}
	plain, late, early: App
	defer stroke_scene_free(&plain)
	defer stroke_scene_free(&late)
	defer stroke_scene_free(&early)
	a, b, c := stroke_sphere(&plain), stroke_sphere(&late), stroke_sphere(&early)
	stroke_along(&plain, path[:], len(path))
	stroke_along(&late, path[:], 2)
	stroke_along(&early, path[:], 0)
	pa, pb, pc := object_sculptor(a).mesh.positions[:], object_sculptor(b).mesh.positions[:], object_sculptor(c).mesh.positions[:]
	testing.expect_value(t, len(plain.history.done), 1)
	testing.expect(t, slice.equal(pa, pb))
	testing.expect_value(t, late.history.done[0].what, "Draw")
	testing.expect_value(t, early.history.done[0].what, "Smooth")
	testing.expect(t, !slice.equal(pa, pc))
}

// While painting (the channel on Colour), Shift blurs the paint and Invert takes it off,
// moving nothing; with the paint dial off, Shift smooths the surface as it always has.
@(test)
painting_blurs_with_smooth_and_erases_with_invert :: proc(t: ^testing.T) {
	path := [?][2]f32{{440, 380}, {470, 390}, {500, 400}, {530, 410}, {560, 420}}
	run :: proc(app: ^App, path: [][2]f32, smooth, invert, dial: bool) -> (moved, erased, blurred: bool) {
		obj := stroke_sphere(app)
		app.brush.channel, app.brush.paint_dial = .Color, dial
		s := object_sculptor(obj)
		_ = sculpt.sculptor_paint_command(s, .Gradient, {200, 30, 30}, {to = {30, 30, 200}, axis = {1, 0, 0}})
		before := slice.clone(s.mesh.positions[:], context.temp_allocator)
		colors := slice.clone(s.color, context.temp_allocator)
		for p, i in path {
			samples := []Input_Sample{{pos = p, pressure = 1, kind = .Press if i == 0 else .Move}}
			_ = sculpt_frame(app, {size = STROKE_SIZE, mouse_pos = p, hovered = true, primary = true, press = i == 0, smooth = smooth, invert = invert, samples = samples})
		}
		_ = sculpt_frame(app, {size = STROKE_SIZE, mouse_pos = path[len(path) - 1], hovered = true})
		moved = !slice.equal(before, s.mesh.positions[:])
		for c, v in s.color {
			if c.a < 255 do erased = true
			if c.rgb != colors[v].rgb do blurred = true
		}
		return
	}
	blur, erase, smooth: App
	defer stroke_scene_free(&blur)
	defer stroke_scene_free(&erase)
	defer stroke_scene_free(&smooth)
	moved, erased, blurred := run(&blur, path[:], true, false, true)
	testing.expect(t, !moved && !erased && blurred, "Shift while painting did not only blur")
	testing.expect_value(t, len(blur.history.done), 1)
	if len(blur.history.done) == 1 do testing.expect_value(t, blur.history.done[0].what, "Blur")
	moved, erased, blurred = run(&erase, path[:], false, true, true)
	testing.expect(t, !moved && erased && !blurred, "Invert while painting did not only erase")
	if len(erase.history.done) == 1 do testing.expect_value(t, erase.history.done[0].what, "Erase")
	moved, _, _ = run(&smooth, path[:], true, false, false)
	testing.expect(t, moved, "with the paint dial off, Shift did not smooth the surface")
	testing.expect_value(t, smooth.history.done[len(smooth.history.done) - 1].what, "Smooth")
}

// A stroke along `path` as stroke_along lays it, kept by the recorder as a drawn one is;
// returns the dabs each frame laid.
@(private = "file")
stroke_recorded :: proc(app: ^App, path: [][2]f32) -> []int {
	dabs := make([]int, len(path) + 1, context.temp_allocator)
	for i in 0 ..= len(path) {
		p := path[min(i, len(path) - 1)]
		input := Viewport_Input{size = STROKE_SIZE, mouse_pos = p, hovered = true}
		if i < len(path) {
			input.primary, input.press = true, i == 0
			input.samples = []Input_Sample{{pos = p, pressure = 1, kind = .Press if i == 0 else .Move}}
		}
		replay_frame_begin(app)
		res := sculpt_frame(app, input)
		replay_record(app, input, res)
		dabs[i] = res.dabs
	}
	return dabs
}

// Where a point in the sphere's space lands on screen.
@(private = "file")
on_screen :: proc(app: ^App, p: Vec3) -> [2]f32 {
	m := camera.orbit_proj(app.camera, STROKE_SIZE.x / STROKE_SIZE.y) * camera.orbit_view(app.camera)
	c := m * [4]f32{p.x, p.y, p.z, 1}
	return {(c.x / c.w * 0.5 + 0.5) * STROKE_SIZE.x, (0.5 - c.y / c.w * 0.5) * STROKE_SIZE.y}
}

// A Spray stroke moves only what lies within the spread and a radius of its path on
// screen, the same seed gives the same mesh and another seed another one.
@(test)
spray_scatters_within_its_spread_and_repeats_with_its_seed :: proc(t: ^testing.T) {
	path := [?][2]f32{{420, 400}, {460, 400}, {500, 400}, {540, 400}, {580, 400}}
	// On the heap: three Apps are more than a test's stack may hold.
	apps := new([3]App)
	defer free(apps)
	objs: [3]^Object
	before: []Vec3
	for &app, i in apps^ {
		objs[i] = stroke_sphere(&app)
		// The sculptor keeps vertices in its nodes' order, so the first is compared with
		// itself as it was.
		if i == 0 do before = slice.clone(object_sculptor(objs[0]).mesh.positions[:], context.temp_allocator)
		app.brush.radius_px, app.brush.stroke, app.brush.spray_spread = 20, .Spray, 1
		app.stroke_seed = 5 if i < 2 else 6
		_ = stroke_recorded(&app, path[:])
	}
	defer for &app in apps^ {
		replay_destroy(&app.replay)
		stroke_scene_free(&app)
	}
	pa := object_sculptor(objs[0]).mesh.positions[:]
	testing.expect(t, slice.equal(pa, object_sculptor(objs[1]).mesh.positions[:]))
	testing.expect(t, !slice.equal(pa, object_sculptor(objs[2]).mesh.positions[:]))
	testing.expect_value(t, apps[0].stroke_seed, 6)
	moved := 0
	for p, v in pa {
		if p == before[v] do continue
		moved += 1
		// The spread and the brush's radius past the path, in pixels, with a little for
		// the radius growing on the far side of the sphere.
		s := on_screen(&apps[0], before[v])
		gap := max(abs(s.y - 400), max(420 - s.x, s.x - 580, 0))
		testing.expectf(t, gap <= 2 * 20 + 4, "vertex %d moved %.1f px from the path", v, gap)
	}
	testing.expect(t, moved > 0)
}

// Roll lays its first dab a radius from the press and the rest a diameter apart, and
// turns the alpha's top along the stroke whatever the alpha's mode.
@(test)
roll_dabs_a_diameter_apart_along_the_stroke :: proc(t: ^testing.T) {
	path := make([dynamic][2]f32, context.temp_allocator)
	for x := f32(400); x <= 600; x += 10 do append(&path, [2]f32{x, 400})
	app: App
	defer stroke_scene_free(&app)
	defer replay_destroy(&app.replay)
	_ = stroke_sphere(&app)
	app.brush.radius_px, app.brush.stroke = 20, .Roll
	dabs := stroke_recorded(&app, path[:])
	// 200 px: dabs at 20, 60, 100, 140 and 180 px from the press.
	testing.expect_value(t, dabs[0], 0)
	testing.expect_value(t, dabs[1], 0)
	testing.expect_value(t, dabs[2], 1)
	total := 0
	for d in dabs do total += d
	testing.expect_value(t, total, 5)

	app.brush.alpha_mode, app.brush.alpha_angle = .Fixed, 0
	app.stroke.active, app.stroke.mode, app.stroke.dir = true, .Roll, {1, 0}
	testing.expect(t, abs(alpha_screen_angle(&app) + math.PI / 2) < 1e-5)
	app.stroke.mode = .Dots
	app.brush.stroke = .Dots
	testing.expect_value(t, alpha_screen_angle(&app), 0)
	app.stroke.active = false
}

// A finger's Spray stroke at half Touch strength, with Lock plane and Connected on and a
// focal shift, saved to a .strokes file and replayed with the mouse on another sphere lays
// the same dabs as drawn, and leaves the replaying app's own seed as it was; a version 3
// file, from before the spread and seed, a version 5 file, from before Lock plane and
// Connected, a version 6 file, from before the focal shift, a version 7 file, from before
// the strength scale, a version 8 file, from before local and radial symmetry, and a version
// 9 file, from before the paint channel, and a version 10 file, from before All depth and
// Smooth only, still read.
@(test)
spray_replays_from_a_strokes_file :: proc(t: ^testing.T) {
	path := "build/spray_test.strokes"
	defer os.remove(path)
	a, b: App
	defer stroke_scene_free(&a)
	defer stroke_scene_free(&b)
	defer replay_destroy(&a.replay)
	defer replay_destroy(&b.replay)
	oa, ob := stroke_sphere(&a), stroke_sphere(&b)
	a.brush.radius_px, a.brush.stroke, a.brush.spray_spread = 20, .Spray, 0.8
	a.brush.lock_plane, a.brush.connected = true, true
	a.brush.falloffs[a.brush.kind].focal = 30
	a.brush.radial_on, a.brush.radial_count, a.brush.radial_axis = true, 3, .Z
	a.brush.channel = .Both
	// Neither changes a Draw stroke, but both are kept with it.
	a.brush.grab_depth, a.brush.smooth_only = true, .Peaks
	a.brush.spacing, a.brush.color_spray = 0.6, 0.4
	a.brush.smoothing, a.brush.pressure_smoothing, a.brush.catch_up = 3, 5, true
	// Nor these a Spray stroke.
	a.brush.even_strength, a.brush.scene_spacing, a.brush.feather = true, true, true
	a.brush.paint_dial = true
	// Nor Grab's modes.
	a.brush.grab_mode, a.brush.grab_normal = .Surface, 0.75
	a.brush.grab_same_side, a.brush.grab_silhouette, a.brush.grab_topological = true, true, true
	a.brush.elastic_volume = 0.3
	a.brush.hook_pinch, a.brush.hook_rake, a.brush.hook_elastic = -0.5, 0.25, true
	// The brush's own pressure, which the file keeps as the one it worked with.
	brush_pressure_own(&a.brush, a.brush.kind, true)
	a.brush.pressures[a.brush.kind].size, a.brush.pressures[a.brush.kind].size_curve = true, PRESSURE_PRESETS[2].curve
	a.stroke_seed = 41
	a.device.pointer, a.nav.touch_strength = .Finger, 0.5
	b.nav.touch_strength = 1
	strip := [?][2]f32{{430, 380}, {470, 390}, {510, 400}, {550, 410}}
	_ = stroke_recorded(&a, strip[:])
	testing.expect(t, strokes_save(&a, path))
	replay_init(&b.replay)
	testing.expect(t, strokes_load(&b, path))
	b.stroke_seed = 7
	testing.expect_value(t, b.replay.take.brushes[0].spray_spread, 0.8)
	testing.expect_value(t, b.replay.take.seeds[0], 41)
	testing.expect(t, b.replay.take.brushes[0].lock_plane && b.replay.take.brushes[0].connected)
	testing.expect_value(t, b.replay.take.brushes[0].falloffs[a.brush.kind].focal, 30)
	testing.expect_value(t, b.replay.take.scales[0], 0.5)
	testing.expect(t, b.replay.take.brushes[0].radial_on && !b.replay.take.brushes[0].sym_local)
	testing.expect_value(t, b.replay.take.brushes[0].radial_count, 3)
	testing.expect_value(t, b.replay.take.brushes[0].radial_axis, sculpt.Axis.Z)
	testing.expect_value(t, b.replay.take.brushes[0].channel, sculpt.Channel.Both)
	testing.expect(t, b.replay.take.brushes[0].grab_depth)
	testing.expect_value(t, b.replay.take.brushes[0].smooth_only, sculpt.Smooth_Only.Peaks)
	testing.expect_value(t, b.replay.take.brushes[0].spacing, 0.6)
	testing.expect_value(t, b.replay.take.brushes[0].color_spray, 0.4)
	testing.expect_value(t, b.replay.take.brushes[0].smoothing, 3)
	testing.expect_value(t, b.replay.take.brushes[0].pressure_smoothing, 5)
	testing.expect(t, b.replay.take.brushes[0].catch_up)
	testing.expect(t, b.replay.take.brushes[0].even_strength && b.replay.take.brushes[0].scene_spacing && b.replay.take.brushes[0].feather)
	testing.expect(t, b.replay.take.brushes[0].paint_dial)
	testing.expect_value(t, b.replay.take.brushes[0].grab_mode, Grab_Mode.Surface)
	testing.expect_value(t, b.replay.take.brushes[0].grab_normal, 0.75)
	testing.expect(t, b.replay.take.brushes[0].grab_same_side && b.replay.take.brushes[0].grab_silhouette && b.replay.take.brushes[0].grab_topological)
	testing.expect_value(t, b.replay.take.brushes[0].elastic_volume, 0.3)
	testing.expect_value(t, b.replay.take.brushes[0].hook_pinch, -0.5)
	testing.expect_value(t, b.replay.take.brushes[0].hook_rake, 0.25)
	testing.expect(t, b.replay.take.brushes[0].hook_elastic)
	{
		rb := b.replay.take.brushes[0]
		testing.expect(t, !rb.pressures[rb.kind].own && rb.pressure_size && rb.pressure_size_curve == PRESSURE_PRESETS[2].curve && rb.pressure_curve == a.brush.pressures[rb.kind].strength_curve)
	}
	replay_start(&b, &b.replay.take)
	for replay_busy(&b) do _ = replay_frame(&b, {})
	testing.expect(t, slice.equal(object_sculptor(oa).mesh.positions[:], object_sculptor(ob).mesh.positions[:]))
	testing.expect(t, slice.equal(object_sculptor(oa).color[:], object_sculptor(ob).color[:]))
	testing.expect_value(t, b.stroke_seed, 7)
	testing.expect_value(t, b.stroke_scale_from, 0)

	// Version 11 had no spacing and colour spray after Smooth only: the one brush ends
	// 64 + 31 bytes after the header's 16, where version 12's has 8 more.
	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil)
	defer delete(data)
	BRUSH :: 64 + 89
	// The files from before version 13 kept no pen roll in a frame.
	frames_before_roll :: proc(frames: []u8) -> []u8 {
		out := make([dynamic]u8, context.temp_allocator)
		r := geom.byte_reader(frames)
		n := geom.byte_get(&r, u32)
		append(&out, ..frames[:4])
		// A frame's camera, size, pointer and tilt, its roll, then its brush, flags, count
		// and samples.
		HEAD :: 12 + 28 + 1 + 8 + 8 + 8
		for _ in 0 ..< n {
			at := r.at
			append(&out, ..frames[at:][:HEAD])
			r.at = at + HEAD + 4 + 4 + 1
			count := geom.byte_get(&r, u32)
			append(&out, ..frames[at + HEAD + 4:][:4 + 1 + 4 + 21 * int(count)])
			r.at += 21 * int(count)
		}
		return out[:]
	}
	// Version 20 had no size pressure curve after the Elastic tip: the one brush ends
	// 64 + 73 bytes after the header's 16, and its size takes the strength's curve.
	twenty := make([dynamic]u8, context.temp_allocator)
	append(&twenty, ..data[:16 + 64 + 73])
	append(&twenty, ..data[16 + BRUSH:])
	twenty[len(STROKES_MAGIC)] = 20
	testing.expect(t, os.write_entire_file(path, twenty[:]) == nil)
	pc: App
	defer replay_destroy(&pc.replay)
	defer results_destroy(&pc)
	testing.expect(t, strokes_load(&pc, path))
	if len(pc.replay.take.brushes) == 1 {
		pb := pc.replay.take.brushes[0]
		testing.expect(t, pb.pressure_size && pb.pressure_size_curve == pb.pressure_curve && pb.hook_elastic)
	}

	// Version 19 had no Snake hook Pinch, Rake or Elastic tip after Elastic's Volume: the
	// one brush ends 64 + 64 bytes after the header's 16, and has none of them.
	nineteen := make([dynamic]u8, context.temp_allocator)
	append(&nineteen, ..data[:16 + 64 + 64])
	append(&nineteen, ..data[16 + BRUSH:])
	nineteen[len(STROKES_MAGIC)] = 19
	testing.expect(t, os.write_entire_file(path, nineteen[:]) == nil)
	hk: App
	defer replay_destroy(&hk.replay)
	defer results_destroy(&hk)
	testing.expect(t, strokes_load(&hk, path))
	if len(hk.replay.take.brushes) == 1 {
		hb := hk.replay.take.brushes[0]
		testing.expect(t, hb.hook_pinch == 0 && hb.hook_rake == 0 && !hb.hook_elastic)
		testing.expect_value(t, hb.elastic_volume, 0.3)
	}

	// Version 18 had no Elastic Volume after Topological: the one brush ends 64 + 60 bytes
	// after the header's 16, and takes the default.
	eighteen := make([dynamic]u8, context.temp_allocator)
	append(&eighteen, ..data[:16 + 64 + 60])
	append(&eighteen, ..data[16 + BRUSH:])
	eighteen[len(STROKES_MAGIC)] = 18
	testing.expect(t, os.write_entire_file(path, eighteen[:]) == nil)
	ev: App
	defer replay_destroy(&ev.replay)
	defer results_destroy(&ev)
	testing.expect(t, strokes_load(&ev, path))
	if len(ev.replay.take.brushes) == 1 {
		testing.expect_value(t, ev.replay.take.brushes[0].elastic_volume, ELASTIC_VOLUME_DEFAULT)
		testing.expect(t, ev.replay.take.brushes[0].grab_topological)
	}

	// Version 17 had no Topological after Grab's Normal weight: the one brush ends 64 + 59
	// bytes after the header's 16, and grabs by straight distance.
	seventeen := make([dynamic]u8, context.temp_allocator)
	append(&seventeen, ..data[:16 + 64 + 59])
	append(&seventeen, ..data[16 + BRUSH:])
	seventeen[len(STROKES_MAGIC)] = 17
	testing.expect(t, os.write_entire_file(path, seventeen[:]) == nil)
	k: App
	defer replay_destroy(&k.replay)
	defer results_destroy(&k)
	testing.expect(t, strokes_load(&k, path))
	if len(k.replay.take.brushes) == 1 {
		testing.expect(t, !k.replay.take.brushes[0].grab_topological && k.replay.take.brushes[0].grab_silhouette)
	}

	// Version 16 had no Grab modes after Even strength, Scene spacing and Feather: the one
	// brush ends 64 + 52 bytes after the header's 16, and grabs freely on both sides.
	sixteen := make([dynamic]u8, context.temp_allocator)
	append(&sixteen, ..data[:16 + 64 + 52])
	append(&sixteen, ..data[16 + BRUSH:])
	sixteen[len(STROKES_MAGIC)] = 16
	testing.expect(t, os.write_entire_file(path, sixteen[:]) == nil)
	p: App
	defer replay_destroy(&p.replay)
	defer results_destroy(&p)
	testing.expect(t, strokes_load(&p, path))
	if len(p.replay.take.brushes) == 1 {
		pb := p.replay.take.brushes[0]
		testing.expect_value(t, pb.grab_mode, Grab_Mode.Free)
		testing.expect(t, !pb.grab_same_side && !pb.grab_silhouette)
		testing.expect(t, pb.even_strength && pb.feather)
	}

	// Version 15 had no Even strength, Scene spacing or Feather after the stabiliser: the
	// one brush ends 64 + 49 bytes after the header's 16, and lays every dab at the
	// brush's strength, spaced on screen.
	fifteen := make([dynamic]u8, context.temp_allocator)
	append(&fifteen, ..data[:16 + 64 + 49])
	append(&fifteen, ..data[16 + BRUSH:])
	fifteen[len(STROKES_MAGIC)] = 15
	testing.expect(t, os.write_entire_file(path, fifteen[:]) == nil)
	q: App
	defer replay_destroy(&q.replay)
	defer results_destroy(&q)
	testing.expect(t, strokes_load(&q, path))
	if len(q.replay.take.brushes) == 1 {
		qb := q.replay.take.brushes[0]
		testing.expect(t, !qb.even_strength && !qb.scene_spacing && !qb.feather)
		testing.expect_value(t, qb.smoothing, 3)
		testing.expect(t, qb.paint_dial)
	}

	// Version 14 had no stabiliser after the paint dial: the one brush ends 64 + 40 bytes
	// after the header's 16, and follows the pointer as it came.
	fourteen := make([dynamic]u8, context.temp_allocator)
	append(&fourteen, ..data[:16 + 64 + 40])
	append(&fourteen, ..data[16 + BRUSH:])
	fourteen[len(STROKES_MAGIC)] = 14
	testing.expect(t, os.write_entire_file(path, fourteen[:]) == nil)
	m: App
	defer replay_destroy(&m.replay)
	defer results_destroy(&m)
	testing.expect(t, strokes_load(&m, path))
	if len(m.replay.take.brushes) == 1 {
		testing.expect_value(t, m.replay.take.brushes[0].smoothing, 1)
		testing.expect_value(t, m.replay.take.brushes[0].pressure_smoothing, 1)
		testing.expect(t, !m.replay.take.brushes[0].catch_up)
		testing.expect_value(t, m.replay.take.brushes[0].spacing, 0.6)
		testing.expect(t, m.replay.take.brushes[0].paint_dial)
	}

	// Version 13 had no paint dial after the colour spray: the one brush ends 64 + 39 bytes
	// after the header's 16, and Smooth and Invert sculpted whatever the brush painted.
	thirteen := make([dynamic]u8, context.temp_allocator)
	append(&thirteen, ..data[:16 + 64 + 39])
	append(&thirteen, ..data[16 + BRUSH:])
	thirteen[len(STROKES_MAGIC)] = 13
	testing.expect(t, os.write_entire_file(path, thirteen[:]) == nil)
	q13: App
	defer replay_destroy(&q13.replay)
	defer results_destroy(&q13)
	testing.expect(t, strokes_load(&q13, path))
	testing.expect_value(t, len(q13.replay.take.brushes), 1)
	if len(q13.replay.take.brushes) == 1 {
		testing.expect(t, !q13.replay.take.brushes[0].paint_dial)
		testing.expect_value(t, q13.replay.take.brushes[0].color_spray, 0.4)
		testing.expect_value(t, q13.replay.take.brushes[0].smoothing, 1)
	}

	eleven := make([dynamic]u8, context.temp_allocator)
	append(&eleven, ..data[:16 + 64 + 31])
	append(&eleven, ..frames_before_roll(data[16 + BRUSH:]))
	eleven[len(STROKES_MAGIC)] = 11
	testing.expect(t, os.write_entire_file(path, eleven[:]) == nil)
	l: App
	defer replay_destroy(&l.replay)
	defer results_destroy(&l)
	testing.expect(t, strokes_load(&l, path))
	if len(l.replay.take.brushes) == 1 {
		testing.expect_value(t, l.replay.take.brushes[0].spacing, SPACING_REFERENCE)
		testing.expect_value(t, l.replay.take.brushes[0].color_spray, 0)
		testing.expect_value(t, l.replay.take.brushes[0].smooth_only, sculpt.Smooth_Only.Peaks)
	}

	// Version 10 had no All depth and Smooth only after the paint channel: the one brush
	// ends 64 + 29 bytes after the header's 16, where version 11's has 2 more.
	ten := make([dynamic]u8, context.temp_allocator)
	append(&ten, ..data[:16 + 64 + 29])
	append(&ten, ..frames_before_roll(data[16 + BRUSH:]))
	ten[len(STROKES_MAGIC)] = 10
	testing.expect(t, os.write_entire_file(path, ten[:]) == nil)
	o: App
	defer replay_destroy(&o.replay)
	defer results_destroy(&o)
	testing.expect(t, strokes_load(&o, path))
	if len(o.replay.take.brushes) == 1 {
		testing.expect(t, !o.replay.take.brushes[0].grab_depth)
		testing.expect_value(t, o.replay.take.brushes[0].smooth_only, sculpt.Smooth_Only.All)
		testing.expect_value(t, o.replay.take.brushes[0].channel, sculpt.Channel.Both)
	}

	// Version 9 had no paint channel after the symmetry bytes: the one brush ends 64 + 28
	// bytes after the header's 16, and only sculpts.
	nine := make([dynamic]u8, context.temp_allocator)
	append(&nine, ..data[:16 + 64 + 28])
	append(&nine, ..frames_before_roll(data[16 + BRUSH:]))
	nine[len(STROKES_MAGIC)] = 9
	testing.expect(t, os.write_entire_file(path, nine[:]) == nil)
	n: App
	defer replay_destroy(&n.replay)
	defer results_destroy(&n)
	testing.expect(t, strokes_load(&n, path))
	if len(n.replay.take.brushes) == 1 {
		testing.expect_value(t, n.replay.take.brushes[0].channel, sculpt.Channel.Sculpt)
		testing.expect(t, n.replay.take.brushes[0].radial_on)
	}

	// Version 8 had no symmetry bytes after the strength scale: the one brush ends 64 + 24
	// bytes after the header's 16, and reads with radial off.
	eight := make([dynamic]u8, context.temp_allocator)
	append(&eight, ..data[:16 + 64 + 24])
	append(&eight, ..frames_before_roll(data[16 + BRUSH:]))
	eight[len(STROKES_MAGIC)] = 8
	testing.expect(t, os.write_entire_file(path, eight[:]) == nil)
	h: App
	defer replay_destroy(&h.replay)
	defer results_destroy(&h)
	testing.expect(t, strokes_load(&h, path))
	if len(h.replay.take.brushes) == 1 {
		testing.expect(t, !h.replay.take.brushes[0].radial_on)
		testing.expect_value(t, h.replay.take.brushes[0].radial_count, RADIAL_DEFAULT)
		testing.expect_value(t, h.replay.take.scales[0], 0.5)
	}

	// Version 7 had no strength scale after the focal shift: the one brush ends 64 + 20
	// bytes after the header's 16, and replays at full strength.
	seven := make([dynamic]u8, context.temp_allocator)
	append(&seven, ..data[:16 + 64 + 20])
	append(&seven, ..frames_before_roll(data[16 + BRUSH:]))
	seven[len(STROKES_MAGIC)] = 7
	testing.expect(t, os.write_entire_file(path, seven[:]) == nil)
	g: App
	defer replay_destroy(&g.replay)
	defer results_destroy(&g)
	testing.expect(t, strokes_load(&g, path))
	if len(g.replay.take.brushes) == 1 {
		testing.expect_value(t, g.replay.take.brushes[0].falloffs[a.brush.kind].focal, 30)
		testing.expect_value(t, g.replay.take.scales[0], 1)
	}

	// Version 6 had no focal shift after the brush's Lock plane and Connected: the one
	// brush ends 64 + 16 bytes after the header's 16.
	six := make([dynamic]u8, context.temp_allocator)
	append(&six, ..data[:16 + 64 + 16])
	append(&six, ..frames_before_roll(data[16 + BRUSH:]))
	six[len(STROKES_MAGIC)] = 6
	testing.expect(t, os.write_entire_file(path, six[:]) == nil)
	e: App
	defer replay_destroy(&e.replay)
	defer results_destroy(&e)
	testing.expect(t, strokes_load(&e, path))
	if len(e.replay.take.brushes) == 1 {
		testing.expect(t, e.replay.take.brushes[0].lock_plane && e.replay.take.brushes[0].connected)
		testing.expect_value(t, e.replay.take.brushes[0].falloffs[a.brush.kind].focal, 0)
		testing.expect_value(t, e.replay.take.seeds[0], 41)
	}

	// Version 5 had no Lock plane and Connected bytes after the brush's Line and Join:
	// the one brush ends 64 + 14 bytes after the header's 16.
	five := make([dynamic]u8, context.temp_allocator)
	append(&five, ..data[:16 + 64 + 14])
	append(&five, ..frames_before_roll(data[16 + BRUSH:]))
	five[len(STROKES_MAGIC)] = 5
	testing.expect(t, os.write_entire_file(path, five[:]) == nil)
	d: App
	defer replay_destroy(&d.replay)
	defer results_destroy(&d)
	testing.expect(t, strokes_load(&d, path))
	if len(d.replay.take.brushes) == 1 {
		testing.expect(t, !d.replay.take.brushes[0].lock_plane && !d.replay.take.brushes[0].connected)
		testing.expect_value(t, d.replay.take.brushes[0].spray_spread, 0.8)
		testing.expect_value(t, d.replay.take.seeds[0], 41)
	}

	// Version 3 had neither the spread and seed nor the Line and Join switches after a
	// brush's cloth mode: the one brush ends 64 bytes after the header's 16.
	old := make([dynamic]u8, context.temp_allocator)
	append(&old, ..data[:16 + 64])
	append(&old, ..frames_before_roll(data[16 + BRUSH:]))
	old[len(STROKES_MAGIC)] = 3
	testing.expect(t, os.write_entire_file(path, old[:]) == nil)
	c: App
	defer replay_destroy(&c.replay)
	defer results_destroy(&c)
	c.brush.spray_spread = 0.3
	testing.expect(t, strokes_load(&c, path))
	if len(c.replay.take.brushes) == 1 {
		testing.expect_value(t, c.replay.take.brushes[0].spray_spread, 0.3)
		testing.expect_value(t, c.replay.take.seeds[0], 0)
		testing.expect_value(t, c.replay.take.brushes[0].stroke, Stroke_Mode.Spray)
	}
}

// Two Spray strokes whose release and press fall in one frame's samples are recorded
// with a seed each and replay as drawn.
@(test)
spray_strokes_ending_and_starting_in_one_frame_replay :: proc(t: ^testing.T) {
	a, b: App
	defer stroke_scene_free(&a)
	defer stroke_scene_free(&b)
	defer replay_destroy(&a.replay)
	defer replay_destroy(&b.replay)
	oa, ob := stroke_sphere(&a), stroke_sphere(&b)
	replay_init(&a.replay)
	replay_init(&b.replay)
	a.brush.radius_px, a.brush.stroke, a.brush.spray_spread = 20, .Spray, 1
	a.stroke_seed = 3
	replay_record_start(&a)
	frames := [?][]Input_Sample {
		{{pos = {430, 380}, pressure = 1, kind = .Press}},
		{{pos = {470, 390}, pressure = 1}},
		{{pos = {500, 395}, pressure = 1}, {pos = {500, 395}, pressure = 1, kind = .Release}, {pos = {520, 430}, pressure = 1, kind = .Press}},
		{{pos = {560, 440}, pressure = 1}},
		{{pos = {590, 450}, pressure = 1}},
	}
	for samples, i in frames {
		input := Viewport_Input{size = STROKE_SIZE, mouse_pos = samples[len(samples) - 1].pos, hovered = true, primary = true, press = i == 0, samples = samples}
		replay_frame_begin(&a)
		res := sculpt_frame(&a, input)
		replay_record(&a, input, res)
	}
	end := Viewport_Input{size = STROKE_SIZE, mouse_pos = {590, 450}, hovered = true}
	replay_frame_begin(&a)
	replay_record(&a, end, sculpt_frame(&a, end))
	replay_record_stop(&a)
	testing.expect_value(t, a.stroke_seed, 5)
	testing.expect_value(t, len(a.replay.take.seeds), 2)
	testing.expect_value(t, len(a.replay.take.seeds), len(a.replay.take.brushes))

	// The take, copied into b as a loaded file would be, replayed on b's sphere.
	take := &b.replay.take
	append(&take.frames, ..a.replay.take.frames[:])
	append(&take.samples, ..a.replay.take.samples[:])
	append(&take.brushes, ..a.replay.take.brushes[:])
	append(&take.seeds, ..a.replay.take.seeds[:])
	append(&take.scales, ..a.replay.take.scales[:])
	replay_start(&b, take)
	for replay_busy(&b) do _ = replay_frame(&b, {})
	testing.expect(t, slice.equal(object_sculptor(oa).mesh.positions[:], object_sculptor(ob).mesh.positions[:]))
}

// A stroke along `path`, one sample a frame, with Shift held where `shift` says, then
// the release.
@(private = "file")
stroke_shifted :: proc(app: ^App, path: [][2]f32, shift: []bool) {
	for p, i in path {
		samples := []Input_Sample{{pos = p, pressure = 1, kind = .Press if i == 0 else .Move}}
		_ = sculpt_frame(app, {size = STROKE_SIZE, mouse_pos = p, hovered = true, primary = true, press = i == 0, smooth = shift[i], samples = samples})
	}
	_ = sculpt_frame(app, {size = STROKE_SIZE, mouse_pos = path[len(path) - 1], hovered = true})
}

// Whether two meshes' positions agree to within float noise: a press's first dab lands
// where the scene's raycast meets the object, a line's where the object's own does.
@(private = "file")
meshes_near :: proc(a, b: ^Object) -> bool {
	pa, pb := object_sculptor(a).mesh.positions, object_sculptor(b).mesh.positions
	if len(pa) != len(pb) do return false
	for p, v in pa do if linalg.length(p - pb[v]) > 1e-5 do return false
	return true
}

// Shift pressed mid-stroke lays the stroke again as a straight line from its press to
// the pointer, redone as the pointer moves: what is left is a stroke drawn straight
// there, as one undo step.
@(test)
shift_mid_stroke_lays_a_straight_line :: proc(t: ^testing.T) {
	wiggle := [?][2]f32{{440, 380}, {470, 420}, {500, 370}, {520, 430}, {560, 360}, {580, 400}}
	shift := [?]bool{false, false, true, true, true, true}
	straight := [?][2]f32{{440, 380}, {580, 400}}
	a, b: App
	defer stroke_scene_free(&a)
	defer stroke_scene_free(&b)
	oa, ob := stroke_sphere(&a), stroke_sphere(&b)
	a.brush.radius_px, b.brush.radius_px = 20, 20
	stroke_shifted(&a, wiggle[:], shift[:])
	stroke_along(&b, straight[:], len(straight))
	testing.expect(t, meshes_near(oa, ob))
	testing.expect_value(t, len(a.history.done), 1)
	testing.expect_value(t, a.history.done[0].what, "Draw")
	testing.expect_value(t, a.stroke_end.lines, 1)

	// The Line switch makes every stroke one, from the press.
	c: App
	defer stroke_scene_free(&c)
	oc := stroke_sphere(&c)
	c.brush.radius_px, c.brush.line = 20, true
	stroke_along(&c, wiggle[:], len(wiggle))
	testing.expect(t, meshes_near(oc, ob))
}

// Letting Shift go carries on freehand from the line's end; with dynamic topology on,
// whose strokes cannot be put back, Shift mid-stroke does nothing.
@(test)
line_lets_go_and_is_refused_with_dynamic_topology :: proc(t: ^testing.T) {
	path := [?][2]f32{{440, 380}, {470, 420}, {500, 370}, {540, 400}, {560, 440}, {590, 420}}
	shift := [?]bool{false, false, true, true, false, false}
	after := [?][2]f32{{440, 380}, {540, 400}, {560, 440}, {590, 420}}
	a, b: App
	defer stroke_scene_free(&a)
	defer stroke_scene_free(&b)
	oa, ob := stroke_sphere(&a), stroke_sphere(&b)
	a.brush.radius_px, b.brush.radius_px = 20, 20
	stroke_shifted(&a, path[:], shift[:])
	stroke_along(&b, after[:], len(after))
	testing.expect(t, meshes_near(oa, ob))
	testing.expect_value(t, len(a.history.done), 1)

	c: App
	defer stroke_scene_free(&c)
	oc := stroke_sphere(&c)
	testing.expect(t, sculpt.levels_dyn_enable(&oc.levels))
	c.brush.radius_px, c.brush.line = 20, true
	stroke_shifted(&c, path[:], shift[:])
	testing.expect_value(t, c.stroke_end.lines, 0)
	testing.expect_value(t, len(c.history.done), 1)
}

// With Join strokes on, a press near where the last stroke ended carries it on: the two
// strokes lay what one drawn through both lays. Further away, or after the view turned,
// a press starts a stroke of its own.
@(test)
join_strokes_carry_on_from_the_last_end :: proc(t: ^testing.T) {
	first := [?][2]f32{{430, 380}, {455, 390}, {480, 393}}
	second := [?][2]f32{{490, 398}, {520, 405}, {550, 420}}
	whole := [?][2]f32{{430, 380}, {455, 390}, {480, 393}, {490, 398}, {520, 405}, {550, 420}}
	a, b: App
	defer stroke_scene_free(&a)
	defer stroke_scene_free(&b)
	oa, ob := stroke_sphere(&a), stroke_sphere(&b)
	a.brush.radius_px, b.brush.radius_px, a.brush.join = 20, 20, true
	stroke_along(&a, first[:], len(first))
	stroke_along(&a, second[:], len(second))
	stroke_along(&b, whole[:], len(whole))
	testing.expect_value(t, a.stroke_end.joins, 1)
	testing.expect_value(t, len(a.history.done), 2)
	testing.expect(t, meshes_near(oa, ob))

	far := [?][2]f32{{530, 450}, {560, 460}}
	stroke_along(&a, far[:], len(far))
	testing.expect_value(t, a.stroke_end.joins, 1)
	a.camera.yaw += 0.01
	near := [?][2]f32{{565, 462}, {590, 470}}
	stroke_along(&a, near[:], len(near))
	testing.expect_value(t, a.stroke_end.joins, 1)
}

// A line longer than a frame's dabs is laid over the frames after, and one let go of
// before it is laid is finished at the release: either way the stroke is the straight
// one.
@(test)
long_lines_finish_across_frames_and_at_the_release :: proc(t: ^testing.T) {
	held := make([dynamic][2]f32, context.temp_allocator)
	append(&held, [2]f32{320, 400}, [2]f32{330, 400})
	for _ in 0 ..< 12 do append(&held, [2]f32{680, 400})
	shift := make([]bool, len(held), context.temp_allocator)
	for &s, i in shift do s = i >= 2
	a, b, c: App
	defer stroke_scene_free(&a)
	defer stroke_scene_free(&b)
	defer stroke_scene_free(&c)
	oa, ob, oc := stroke_sphere(&a), stroke_sphere(&b), stroke_sphere(&c)
	a.brush.radius_px, b.brush.radius_px, c.brush.radius_px = 3, 3, 3
	stroke_shifted(&a, held[:], shift[:])
	straight := make([dynamic][2]f32, context.temp_allocator)
	append(&straight, [2]f32{320, 400})
	for _ in 0 ..< 12 do append(&straight, [2]f32{680, 400})
	stroke_along(&b, straight[:], len(straight))
	stroke_shifted(&c, held[:3], shift[:3])
	testing.expect(t, meshes_near(oa, ob))
	testing.expect(t, meshes_near(oc, ob))
}

// Where a line ends depends only on the samples: with the pointer moving on while a long
// line is still being laid, the line ends where the pointer last was with Shift held,
// whether the button comes up then or Shift is let go and the stroke goes on freehand.
@(test)
lines_end_where_the_pointer_last_was_with_shift :: proc(t: ^testing.T) {
	moving := [?][2]f32{{320, 400}, {330, 400}, {500, 400}, {560, 410}, {620, 400}, {680, 405}}
	shift := [?]bool{false, false, true, true, true, true}
	a, b: App
	defer stroke_scene_free(&a)
	defer stroke_scene_free(&b)
	oa, ob := stroke_sphere(&a), stroke_sphere(&b)
	a.brush.radius_px, b.brush.radius_px = 3, 3
	stroke_shifted(&a, moving[:], shift[:])
	straight := make([dynamic][2]f32, context.temp_allocator)
	append(&straight, [2]f32{320, 400})
	for _ in 0 ..< 12 do append(&straight, [2]f32{680, 405})
	stroke_along(&b, straight[:], len(straight))
	testing.expect(t, meshes_near(oa, ob))

	// Shift let go after (620, 400): the line goes there, then on freehand.
	leaving := make([dynamic][2]f32, context.temp_allocator)
	append(&leaving, ..moving[:])
	append(&leaving, [2]f32{700, 440})
	for _ in 0 ..< 12 do append(&leaving, [2]f32{700, 440})
	held := make([]bool, len(leaving), context.temp_allocator)
	for &h, i in held do h = i >= 2 && i <= 4
	after := make([dynamic][2]f32, context.temp_allocator)
	append(&after, [2]f32{320, 400}, [2]f32{620, 400}, [2]f32{680, 405})
	for _ in 0 ..< 13 do append(&after, [2]f32{700, 440})
	c, d: App
	defer stroke_scene_free(&c)
	defer stroke_scene_free(&d)
	oc, od := stroke_sphere(&c), stroke_sphere(&d)
	c.brush.radius_px, d.brush.radius_px = 3, 3
	stroke_shifted(&c, leaving[:], held)
	stroke_along(&d, after[:], len(after))
	testing.expect(t, meshes_near(oc, od))
}

// With Line and Join strokes both on, a stroke pressed near the last one's end is a
// straight line from that end, going on as the last stroke went: what a stroke joined
// and drawn straight on lays.
@(test)
line_from_a_join_keeps_the_join :: proc(t: ^testing.T) {
	first := [?][2]f32{{430, 380}, {455, 390}, {480, 393}}
	bent := [?][2]f32{{485, 394}, {520, 430}, {560, 393}}
	on := [?][2]f32{{488, 393}, {560, 393}}
	a, b: App
	defer stroke_scene_free(&a)
	defer stroke_scene_free(&b)
	oa, ob := stroke_sphere(&a), stroke_sphere(&b)
	a.brush.radius_px, b.brush.radius_px = 20, 20
	a.brush.join, b.brush.join = true, true
	stroke_along(&a, first[:], len(first))
	stroke_along(&b, first[:], len(first))
	a.brush.line = true
	stroke_along(&a, bent[:], len(bent))
	stroke_along(&b, on[:], len(on))
	testing.expect_value(t, a.stroke_end.joins, 1)
	testing.expect_value(t, b.stroke_end.joins, 1)
	testing.expect(t, meshes_near(oa, ob))
}

// Front faces only, Lock plane and Connected are commands that flip their switches, and
// reach the sculpt brush: a stroke with Lock plane on locks the plane its first dab
// found, one with it off leaves none, and a stroke joining a locked one keeps its plane.
@(test)
filter_commands_reach_the_brush :: proc(t: ^testing.T) {
	path := [?][2]f32{{440, 380}, {470, 390}, {500, 400}}
	app: App
	defer stroke_scene_free(&app)
	obj := stroke_sphere(&app)
	for id in ([?]Command_Id{.Front_Only, .Lock_Plane, .Connected}) {
		testing.expect(t, !command_checked(&app, id))
		testing.expect(t, command_run(&app, id))
		testing.expect(t, command_checked(&app, id))
	}
	testing.expect(t, app.brush.front_only && app.brush.lock_plane && app.brush.connected)
	stroke_along(&app, path[:], len(path))
	testing.expect(t, object_sculptor(obj).locked.set)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect(t, command_run(&app, .Lock_Plane))
	stroke_along(&app, path[:], len(path))
	testing.expect(t, !object_sculptor(obj).locked.set)
	// A stroke joining one keeps its plane, so a stroke laid in pieces stays on one.
	testing.expect(t, command_run(&app, .Lock_Plane))
	app.brush.join = true
	stroke_along(&app, path[:], len(path))
	first := object_sculptor(obj).locked
	more := [?][2]f32{{504, 398}, {540, 380}, {580, 360}}
	stroke_along(&app, more[:], len(more))
	testing.expect_value(t, app.stroke_end.joins, 1)
	testing.expect(t, first.set && object_sculptor(obj).locked == first)
}

// After a stroke, Adjust last stroke sets how much of it stays, in place on its one
// History entry, whose label says the share; it stays adjustable through its own changes,
// and stops being once an undo comes; a new stroke is the one to adjust from then on.
@(test)
adjust_last_stroke_sets_its_amount :: proc(t: ^testing.T) {
	path := [?][2]f32{{440, 380}, {470, 390}, {500, 400}, {530, 410}}
	app: App
	defer stroke_scene_free(&app)
	obj := stroke_sphere(&app)
	m := object_sculptor(obj).mesh
	before := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, !adjust_stroke(&app, 0.5))
	stroke_along(&app, path[:], len(path))
	drawn := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, adjust_live(&app) && app.adjustable.op == .Stroke)
	// No action bar group: it would come after every stroke.
	testing.expect(t, .Adjust not_in action_groups_now(&app))
	testing.expect(t, adjust_stroke(&app, 0))
	testing.expect(t, slice.equal(m.positions[:], before))
	testing.expect(t, adjust_stroke(&app, 1.2))
	testing.expect(t, adjust_live(&app))
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, entry_label(app.history.done[0]), "Draw stroke (120%)")
	testing.expect(t, adjust_stroke(&app, 1))
	testing.expect(t, slice.equal(m.positions[:], drawn))
	history_undo(&app)
	testing.expect(t, slice.equal(m.positions[:], before))
	testing.expect(t, !adjust_live(&app))
	testing.expect(t, !adjust_stroke(&app, 0.5))
	history_redo(&app)
	testing.expect(t, slice.equal(m.positions[:], drawn))
	// A new stroke is the one to adjust from then on.
	stroke_along(&app, path[:], len(path))
	testing.expect(t, adjust_live(&app))
	testing.expect(t, adjust_stroke(&app, 0))
	testing.expect(t, slice.equal(m.positions[:], drawn))
}

// The History brush paints back to the oldest step by default, building its target at
// the first press; Earlier and Later move the point and say which step it is, an undo of
// that step falls back to the oldest, and its own strokes are steps like any other.
@(test)
history_brush_paints_back_to_a_step :: proc(t: ^testing.T) {
	path := [?][2]f32{{440, 380}, {470, 390}, {500, 400}, {530, 410}}
	app: App
	defer stroke_scene_free(&app)
	obj := stroke_sphere(&app)
	m := object_sculptor(obj).mesh
	start := slice.clone(m.positions[:], context.temp_allocator)
	app.brush.kind = .History
	stroke_along(&app, path[:], len(path))
	testing.expect_value(t, len(app.history.done), 0)
	app.brush.kind = .Draw
	stroke_along(&app, path[:], len(path))
	app.brush.kind, app.brush.strengths[.Clay] = .Clay, 0.5
	stroke_along(&app, path[:], len(path))
	drawn := slice.clone(m.positions[:], context.temp_allocator)
	back, reach, shown := recall_now(&app)
	testing.expect(t, back == 0 && reach == 2 && shown == 2)
	testing.expect(t, command_enabled(&app, .Recall_Later) && !command_enabled(&app, .Recall_Earlier))
	app.brush.kind = .History
	app.brush.strengths[.History] = 1
	stroke_along(&app, path[:], len(path))
	testing.expect_value(t, len(app.history.done), 3)
	testing.expect_value(t, app.history.done[2].what, "History")
	closer := 0
	for p, v in m.positions {
		testing.expect(t, linalg.length(p - start[v]) <= linalg.length(drawn[v] - start[v]) + 1e-6)
		if linalg.length(p - start[v]) < linalg.length(drawn[v] - start[v]) do closer += 1
	}
	testing.expect(t, closer > 20)
	back, reach, _ = recall_now(&app)
	testing.expect(t, back == 3 && reach == 3)
	e, ok := recall_entry(&app, obj, back)
	testing.expect(t, ok && entry_label(e) == "Draw stroke")
	// Later: before the Clay stroke, chosen.
	testing.expect(t, command_run(&app, .Recall_Later))
	back, _, _ = recall_now(&app)
	testing.expect_value(t, back, 2)
	testing.expect(t, sculpt.sculptor_recall_pinned(object_sculptor(obj)))
	testing.expect(t, command_enabled(&app, .Recall_Oldest))
	// Undoing the History stroke and the Clay stroke takes the chosen step away: the next
	// History stroke paints back to the oldest, and says so.
	history_undo(&app)
	history_undo(&app)
	stroke_along(&app, path[:], len(path))
	back, _, _ = recall_now(&app)
	testing.expect_value(t, back, 2)
	testing.expect(t, !sculpt.sculptor_recall_pinned(object_sculptor(obj)))
	testing.expect(t, strings.contains(app.result.text, "out of reach now"))
}

// Choosing a step on the History panel's bar makes the History brush paint back to
// before it, chosen and marked, counted among its own object's steps only; the mark and
// the point follow undo. A step that is no sculpting step, of another level, or past the
// end is not taken.
@(test)
history_brush_point_from_the_timeline :: proc(t: ^testing.T) {
	path := [?][2]f32{{440, 380}, {470, 390}, {500, 400}, {530, 410}}
	app: App
	defer stroke_scene_free(&app)
	obj := stroke_sphere(&app)
	other := new(Object)
	other.id, other.transform = 2, {position = {5, 0, 0}, scale = 1}
	sculpt.levels_init(&other.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, other)
	other_stroke :: proc(app: ^App, other: ^Object) {
		s := object_sculptor(other)
		sculpt.sculptor_stroke_begin(s)
		_ = sculpt.apply_dab(s, {kind = .Draw, radius = 0.5, strength = 0.8}, {0, 0, 1})
		_ = sculpt.sculptor_stroke_end(s)
		history_record(app, other, .Stroke, "Draw")
	}
	app.brush.strengths[.Clay] = 0.5
	// The bar: 0 Draw, 1 other's, 2 Clay, 3 other's, 4 Draw.
	for kind, i in ([?]sculpt.Brush_Kind{.Draw, .Clay, .Draw}) {
		app.brush.kind = kind
		stroke_along(&app, path[:], len(path))
		if i < 2 do other_stroke(&app, other)
	}
	testing.expect_value(t, len(app.history.done), 5)
	testing.expect_value(t, recall_marker(&app), 0)
	testing.expect(t, recall_to_entry(&app, 2))
	back, _, _ := recall_now(&app)
	testing.expect_value(t, back, 2)
	testing.expect(t, sculpt.sculptor_recall_pinned(object_sculptor(obj)))
	testing.expect_value(t, recall_marker(&app), 2)
	// Undoing the newest stroke leaves the point where it is, one step nearer.
	history_undo(&app)
	back, _, _ = recall_now(&app)
	testing.expect_value(t, back, 1)
	testing.expect_value(t, recall_marker(&app), 2)
	// The other object's step sets the other object's point and leaves this one's mark.
	testing.expect(t, recall_to_entry(&app, 1))
	other_back, _ := sculpt.sculptor_recall_back(object_sculptor(other))
	testing.expect_value(t, other_back, 2)
	testing.expect_value(t, recall_marker(&app), 2)
	// A placing of the object is no step of its sculptor; past the end is nothing.
	before := obj.transform
	obj.transform.position.x += 1
	history_record_transform(&app, obj, before, "move")
	testing.expect(t, !recall_to_entry(&app, 4))
	testing.expect(t, !recall_to_entry(&app, 5))
	testing.expect_value(t, recall_marker(&app), 2)
}

// Touch strength scales a finger's strokes only: a finger at full Touch strength sculpts as
// the mouse does, at half it moves the surface less, and the mouse ignores the setting.
@(test)
touch_strength_lightens_a_fingers_strokes :: proc(t: ^testing.T) {
	moved :: proc(pointer: ui.Pointer_Kind, touch: f32) -> (total: f32, positions: [dynamic]Vec3) {
		app: App
		defer stroke_scene_free(&app)
		defer replay_destroy(&app.replay)
		obj := stroke_sphere(&app)
		app.device.pointer, app.nav.touch_strength = pointer, touch
		before := slice.clone(object_sculptor(obj).mesh.positions[:], context.temp_allocator)
		path := [?][2]f32{{480, 380}, {520, 400}}
		_ = stroke_recorded(&app, path[:])
		after := object_sculptor(obj).mesh.positions[:]
		for p, i in after do total += linalg.length(p - before[i])
		positions = make([dynamic]Vec3, context.temp_allocator)
		append(&positions, ..after)
		return
	}
	mouse, mouse_at := moved(.Mouse, 0.5)
	full, full_at := moved(.Finger, 1)
	half, _ := moved(.Finger, 0.5)
	testing.expect(t, mouse > 0)
	testing.expect(t, slice.equal(mouse_at[:], full_at[:]))
	testing.expect(t, half < 0.75 * full && half > 0.25 * full)
}

// A Drag dot stroke's one dab slides with the pointer: dragged across the sphere, what is
// left is a single press laid where it was let go, as one undo step.
@(test)
drag_dot_leaves_one_dab_where_it_is_let_go :: proc(t: ^testing.T) {
	path := [?][2]f32{{440, 380}, {470, 390}, {500, 400}, {530, 410}, {560, 420}}
	dragged, pressed: App
	defer stroke_scene_free(&dragged)
	defer stroke_scene_free(&pressed)
	a, b := stroke_sphere(&dragged), stroke_sphere(&pressed)
	dragged.brush.stroke = .Drag_Dot
	stroke_along(&dragged, path[:], len(path))
	stroke_along(&pressed, path[len(path) - 1:], 1)
	testing.expect_value(t, len(dragged.history.done), 1)
	testing.expect(t, meshes_near(a, b))
}

// Spacing sets how far apart a Dots stroke's dabs are: four times the spacing lays about
// a quarter as many along the same path.
@(test)
spacing_sets_how_far_apart_dabs_are :: proc(t: ^testing.T) {
	path := make([dynamic][2]f32, context.temp_allocator)
	for x := f32(400); x <= 600; x += 10 do append(&path, [2]f32{x, 400})
	totals: [2]int
	for spacing, i in ([2]f32{0.25, 1}) {
		app: App
		defer stroke_scene_free(&app)
		defer replay_destroy(&app.replay)
		_ = stroke_sphere(&app)
		app.brush.radius_px, app.brush.spacing = 20, spacing
		for d in stroke_recorded(&app, path[:]) do totals[i] += d
	}
	// 200 px at 5 px and at 20 px a dab, and the press's.
	testing.expectf(t, totals[0] >= 40 && totals[1] <= 12 && totals[1] >= 10, "dabs %v", totals)
}

// Colour spray gives each Spray dab's paint its own shade, the same for the same seed.
@(test)
color_spray_varies_the_paint_and_repeats_with_its_seed :: proc(t: ^testing.T) {
	path := [?][2]f32{{420, 400}, {460, 400}, {500, 400}, {540, 400}, {580, 400}}
	// On the heap: three Apps are more than a test's stack may hold.
	apps := new([3]App)
	defer free(apps)
	objs: [3]^Object
	for &app, i in apps^ {
		objs[i] = stroke_sphere(&app)
		app.brush.kind, app.brush.radius_px, app.brush.stroke, app.brush.spray_spread = .Paint, 20, .Spray, 1
		app.brush.strengths[.Paint], app.brush.color = 1, {0.5, 0.4, 0.3}
		app.brush.color_spray = 0 if i == 0 else 0.5
		app.stroke_seed = 5
		_ = stroke_recorded(&app, path[:])
	}
	defer for &app in apps^ {
		replay_destroy(&app.replay)
		stroke_scene_free(&app)
	}
	plain, sprayed := object_sculptor(objs[0]).color[:], object_sculptor(objs[1]).color[:]
	testing.expect(t, len(plain) > 0 && len(plain) == len(sprayed))
	testing.expect(t, !slice.equal(plain, sprayed))
	testing.expect(t, slice.equal(sprayed, object_sculptor(objs[2]).color[:]))
}

// A stroke along `path`, one sample a frame with the pressures `pressures`, left held
// (no release) when `held`.
@(private = "file")
stroke_pressed :: proc(app: ^App, path: [][2]f32, pressures: []f32, held := false) {
	for p, i in path {
		samples := []Input_Sample{{pos = p, pressure = pressures[i], kind = .Press if i == 0 else .Move}}
		_ = sculpt_frame(app, {size = STROKE_SIZE, mouse_pos = p, hovered = true, primary = true, press = i == 0, samples = samples})
	}
	if !held do _ = sculpt_frame(app, {size = STROKE_SIZE, mouse_pos = path[len(path) - 1], hovered = true})
}

// With the lazy string on, a stroke ends a string's length short of where the pen lifted;
// Catch up on lift carries it on to there.
@(test)
catch_up_ends_the_stroke_under_the_pen :: proc(t: ^testing.T) {
	path := [?][2]f32{{420, 400}, {450, 400}, {480, 400}, {510, 400}, {540, 400}, {570, 400}}
	full := [?]f32{1, 1, 1, 1, 1, 1}
	short, caught: App
	defer stroke_scene_free(&short)
	defer stroke_scene_free(&caught)
	_, _ = stroke_sphere(&short), stroke_sphere(&caught)
	for app in ([]^App{&short, &caught}) {
		app.brush.lazy_px, app.brush.join = 40, true
		app.brush.catch_up = app == &caught
		stroke_pressed(app, path[:], full[:])
	}
	testing.expect(t, short.stroke_end.valid && caught.stroke_end.valid)
	testing.expectf(t, abs(short.stroke_end.pos.x - 530) < 0.5, "short: %v", short.stroke_end.pos)
	testing.expectf(t, linalg.length(caught.stroke_end.pos - path[len(path) - 1]) < 1, "caught: %v", caught.stroke_end.pos)
	testing.expect_value(t, len(caught.history.done), 1)
}

// Smoothing follows the mean of the pointer's last few positions, and Pressure smoothing
// the mean of the pen's last few pressures: a jump to the side and a sudden lift both
// arrive a share at a time.
@(test)
smoothing_follows_the_mean_of_the_last_samples :: proc(t: ^testing.T) {
	path := [?][2]f32{{420, 400}, {450, 400}, {480, 400}, {510, 400}, {540, 440}}
	pressures := [?]f32{1, 1, 1, 1, 0.2}
	app: App
	defer stroke_scene_free(&app)
	_ = stroke_sphere(&app)
	app.brush.smoothing, app.brush.pressure_smoothing = 4, 2
	stroke_pressed(&app, path[:], pressures[:], held = true)
	// The mean of the last four positions and of the last two pressures.
	testing.expectf(t, linalg.length(app.stroke.pos - [2]f32{495, 410}) < 1e-3, "pos %v", app.stroke.pos)
	testing.expectf(t, abs(app.stroke.pressure - 0.6) < 1e-5, "pressure %v", app.stroke.pressure)
	// Off, the brush is where the pointer is.
	app.brush.smoothing, app.brush.pressure_smoothing = 1, 1
	stroke_pressed(&app, path[:], pressures[:], held = true)
	testing.expect_value(t, app.stroke.pos, path[len(path) - 1])
	testing.expect_value(t, app.stroke.pressure, 0.2)
}

// With Even strength a straight Draw stroke rises as high at any spacing from a tenth to
// half the radius as at the old default's quarter (within 2%), where without it the
// height follows how closely the dabs pile up. Y symmetry's feathering leaves the stroke,
// which runs well above the plane, as high as without symmetry.
@(test)
even_strength_keeps_a_strokes_height_across_spacings :: proc(t: ^testing.T) {
	path := make([dynamic][2]f32, context.temp_allocator)
	for x := f32(430); x <= 570; x += 4 do append(&path, [2]f32{x, 400})
	rise :: proc(path: [][2]f32, spacing: f32, even: bool, symmetry := sculpt.Symmetry{.Y}) -> f32 {
		app := new(App)
		defer free(app)
		defer stroke_scene_free(app)
		obj := stroke_sphere(app, 6)
		app.brush.radius_px, app.brush.spacing, app.brush.even_strength = 40, spacing, even
		app.brush.strengths[.Draw] = 0.05
		app.brush.feather, app.brush.symmetry = true, symmetry
		before := slice.clone(object_mesh(obj).positions[:], context.temp_allocator)
		stroke_pressed(app, path, slice.repeat([]f32{1}, len(path), context.temp_allocator))
		top: f32
		for p, i in object_mesh(obj).positions do top = max(top, linalg.length(p) - linalg.length(before[i]))
		return top
	}
	reference := rise(path[:], SPACING_REFERENCE, true)
	alone := rise(path[:], SPACING_REFERENCE, true, {})
	testing.expectf(t, reference > 0 && reference == alone, "with symmetry %v, without %v", reference, alone)
	for spacing in ([?]f32{0.1, 0.15, 0.2, 0.3, 0.4, 0.5}) {
		h := rise(path[:], spacing, true)
		testing.expectf(t, abs(h / reference - 1) < 0.02, "spacing %v: height %v, at the reference %v", spacing, h, reference)
	}
	// Unevened, dabs a tenth of the radius apart pile up about two and a half times as high.
	testing.expect(t, rise(path[:], 0.1, false) > 2 * reference)
}

// A Grab pressed just past the sphere's edge takes hold of the nearest surface within the
// brush ring, and holding still moves nothing (the drag counts from the press, not from
// the surface point it took); dragging outward then pulls the edge out.
@(test)
grab_takes_hold_past_the_silhouette :: proc(t: ^testing.T) {
	app: App
	defer stroke_scene_free(&app)
	obj := stroke_sphere(&app)
	app.brush.kind, app.brush.radius_px = .Grab, 40
	app.brush.strengths[.Grab] = 1
	// The sphere's right edge along the middle row, then a little past it.
	edge := [2]f32{500, 400}
	for {
		origin, dir := mouse_ray(app.camera, edge + {1, 0}, STROKE_SIZE)
		if _, _, ok := scene_raycast(&app, origin, dir); !ok do break
		edge.x += 1
	}
	press := edge + {15, 0}
	before := slice.clone(object_mesh(obj).positions[:], context.temp_allocator)
	stroke_pressed(&app, {press, press}, {1, 1}, held = true)
	testing.expect(t, app.stroke.active && app.stroke.grab)
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], before))
	out := press + {30, 0}
	_ = sculpt_frame(&app, {size = STROKE_SIZE, mouse_pos = out, hovered = true, primary = true, samples = {{pos = out, pressure = 1, kind = .Move}}})
	_ = sculpt_frame(&app, {size = STROKE_SIZE, mouse_pos = out, hovered = true})
	far: f32
	for p in object_mesh(obj).positions do far = max(far, linalg.length(p))
	testing.expectf(t, far > 1.05, "the edge reached %v", far)
	testing.expect_value(t, len(app.history.done), 1)
}

// Along normal moves a sideways drag along the pressed normal by how far the pointer went
// toward where the normal points on screen; Along surface takes the normal part out; Free
// keeps the drag, and its Normal weight blends toward along the normal. Shift and Alt
// mid-grab pick the first two whatever the brush says.
@(test)
grab_modes_turn_the_drag :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	facing := camera.orbit_toward(app.camera, {})
	// A normal half across the screen, half toward the camera.
	view := camera.orbit_view(app.camera)
	right := Vec3{view[0, 0], view[0, 1], view[0, 2]}
	n := linalg.normalize(right + facing)
	app.stroke.grab_normal = n
	drag := right * 0.2
	near :: proc(a, b: Vec3) -> bool {return linalg.length(a - b) < 1e-5}
	testing.expect(t, near(grab_moved(&app, {}, drag, facing), drag))
	app.brush.grab_mode = .Normal
	testing.expect(t, near(grab_moved(&app, {}, drag, facing), n * 0.2))
	app.brush.grab_mode = .Surface
	surface := grab_moved(&app, {}, drag, facing)
	testing.expect(t, abs(linalg.dot(surface, n)) < 1e-5)
	app.brush.grab_mode, app.brush.grab_normal = .Free, 0.5
	testing.expect(t, near(grab_moved(&app, {}, drag, facing), (drag + n * 0.2) * 0.5))
	app.brush.grab_normal = 0
	testing.expect(t, near(grab_moved(&app, {smooth = true}, drag, facing), n * 0.2))
	testing.expect(t, abs(linalg.dot(grab_moved(&app, {alt = true}, drag, facing), n)) < 1e-5)
	// With the normal toward the camera, up on the screen is out.
	app.stroke.grab_normal = facing
	up := Vec3{view[1, 0], view[1, 1], view[1, 2]}
	testing.expect(t, near(grab_moved(&app, {smooth = true}, up * 0.1, facing), facing * 0.1))
}
