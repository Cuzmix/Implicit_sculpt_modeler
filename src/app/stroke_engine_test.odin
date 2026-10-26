package main

import "core:math"
import "core:os"
import "core:slice"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

// A selected sphere at the world's middle with no GPU buffers, the Draw brush held.
@(private = "file")
stroke_sphere :: proc(app: ^App) -> ^Object {
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(4), nil, 64)
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
	apps: [3]App
	objs: [3]^Object
	before: []Vec3
	for &app, i in apps {
		objs[i] = stroke_sphere(&app)
		// The sculptor keeps vertices in its nodes' order, so the first is compared with
		// itself as it was.
		if i == 0 do before = slice.clone(object_sculptor(objs[0]).mesh.positions[:], context.temp_allocator)
		app.brush.radius_px, app.brush.stroke, app.brush.spray_spread = 20, .Spray, 1
		app.stroke_seed = 5 if i < 2 else 6
		_ = stroke_recorded(&app, path[:])
	}
	defer for &app in apps {
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

// A Spray stroke saved to a .strokes file and replayed on another sphere lays the same
// dabs as drawn, and leaves the replaying app's own seed as it was; a version 3 file,
// from before the spread and seed, still reads.
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
	a.stroke_seed = 41
	strip := [?][2]f32{{430, 380}, {470, 390}, {510, 400}, {550, 410}}
	_ = stroke_recorded(&a, strip[:])
	testing.expect(t, strokes_save(&a, path))
	replay_init(&b.replay)
	testing.expect(t, strokes_load(&b, path))
	b.stroke_seed = 7
	testing.expect_value(t, b.replay.take.brushes[0].spray_spread, 0.8)
	testing.expect_value(t, b.replay.take.seeds[0], 41)
	replay_start(&b, &b.replay.take)
	for replay_busy(&b) do _ = replay_frame(&b, {})
	testing.expect(t, slice.equal(object_sculptor(oa).mesh.positions[:], object_sculptor(ob).mesh.positions[:]))
	testing.expect_value(t, b.stroke_seed, 7)

	// Version 3 had neither the spread nor the seed after a brush's cloth mode: the one
	// brush ends 64 bytes after the header's 16.
	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil)
	defer delete(data)
	old := make([dynamic]u8, context.temp_allocator)
	append(&old, ..data[:16 + 64])
	append(&old, ..data[16 + 64 + 12:])
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
	replay_start(&b, take)
	for replay_busy(&b) do _ = replay_frame(&b, {})
	testing.expect(t, slice.equal(object_sculptor(oa).mesh.positions[:], object_sculptor(ob).mesh.positions[:]))
}
