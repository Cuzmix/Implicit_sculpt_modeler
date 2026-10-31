package main

import "core:math"
import "core:os"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

@(private = "file")
CURVE_SIZE :: [2]f32{1000, 800}

// A selected sphere with no GPU buffers, the Curve tool on with its Curve kind.
@(private = "file")
curve_scene :: proc(app: ^App) {
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(4), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected, app.scene.next_id = 0, 1
	app.camera = camera.orbit_default()
	app.tool = .Curve
	app.curve = CURVE_DEFAULTS
	app.curve.kind = .Curve
	app.brush.radius_px = 40
}

@(private = "file")
curve_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		curve_part_free(obj)
		sculpt.levels_destroy(&obj.levels)
		delete(obj.name)
		delete(obj.group_materials)
		free(obj)
	}
	delete(app.scene.objects)
	curve_tool_destroy(&app.curve)
	history_destroy(&app.history)
	results_destroy(app)
}

@(private = "file")
curve_press :: proc(app: ^App, p: [2]f32, held, press: bool) {
	_ = curve_tool_frame(app, {size = CURVE_SIZE, mouse_pos = p, hovered = true, primary = held, press = press})
}

@(private = "file")
curve_tap :: proc(app: ^App, p: [2]f32) {
	curve_press(app, p, true, true)
	curve_press(app, p, false, false)
}

// A drag over the sphere becomes one curve object of a few points, selected, one undo
// step whose snapshot reads back as the same curve.
@(test)
curve_drawn_by_drag :: proc(t: ^testing.T) {
	app: App
	defer curve_scene_free(&app)
	curve_scene(&app)
	for i in 0 ..= 40 {
		x := 380 + f32(i) * 6
		y := 400 - 70 * math.sin(f32(i) / 40 * math.PI)
		curve_press(&app, {x, y}, true, i == 0)
	}
	curve_press(&app, {620, 400}, false, false)
	testing.expect_value(t, len(app.scene.objects), 2)
	obj := selected_object(&app)
	if !object_is_curve(obj) {
		testing.fail_now(t, "no curve selected")
	}
	n := len(obj.curve.points)
	testing.expectf(t, n >= 2 && n <= 12, "%d points", n)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, app.history.done[0].kind, History_Kind.Curve)
	testing.expect(t, !object_draws_triangles(obj), "a curve draws triangles")
	testing.expect(t, !object_editable(&app, obj, false), "a curve is sculptable")
	first := obj.curve.points[0]

	// What Undo and Redo trade the curve for: its snapshot reads back as the same curve.
	snap := history_snapshot(&app, obj, "test")
	defer history_snapshot_drop(snap)
	r := geom.byte_reader(snap.bytes[:])
	back, read, made := object_get(&app, &r)
	testing.expect(t, read && made, "the snapshot did not read")
	if back == nil do return
	testing.expect(t, object_is_curve(back) && len(back.curve.points) == n && back.curve.points[0] == first && back.id == obj.id, "the snapshot is not the same curve")
	curve_part_free(back)
	sculpt.levels_destroy(&back.levels)
	delete(back.name)
	delete(back.group_materials)
	free(back)
}

// Taps place points; a tap on the first of three closes the curve. Two taps and Enter make
// an open one; Escape's clear makes none.
@(test)
curve_placed_by_taps :: proc(t: ^testing.T) {
	app: App
	defer curve_scene_free(&app)
	curve_scene(&app)
	taps := [3][2]f32{{440, 360}, {560, 360}, {500, 460}}
	for p in taps do curve_tap(&app, p)
	testing.expect_value(t, len(app.curve.placing), 3)
	testing.expect_value(t, len(app.scene.objects), 1)
	curve_tap(&app, taps[0] + {3, 2})
	testing.expect_value(t, len(app.curve.placing), 0)
	testing.expect_value(t, len(app.scene.objects), 2)
	closed := app.scene.objects[1].curve
	testing.expect(t, closed != nil && closed.closed && len(closed.points) == 3, "not a closed curve of three points")

	// With the sphere selected again, a tap places rather than edits the curve's point.
	app.scene.selected = 0
	curve_tap(&app, taps[0])
	curve_tap(&app, taps[1])
	curve_place_finish(&app, false)
	testing.expect_value(t, len(app.scene.objects), 3)
	open := app.scene.objects[2].curve
	testing.expect(t, open != nil && !open.closed && len(open.points) == 2, "not an open curve of two points")
	testing.expect_value(t, app.curve.made, 2)
	testing.expect_value(t, len(app.history.done), 2)
}

// Curves are saved in their own chunks, in order, and read back from them only; the scene
// chunk counts only the other objects, as an app from before curves expects, and keeps the
// selection among all of them.
@(test)
curve_scene_round_trip :: proc(t: ^testing.T) {
	app: App
	defer curve_scene_free(&app)
	app.camera = camera.orbit_default()
	app.scene.lights = app.start_lights
	a := []geom.Bezier_Point{{p = {0, 0, 0}, h_out = {0.1, 0, 0}, radius = 0.2, intensity = 1}, {p = {1, 0, 0}, h_in = {-0.1, 0, 0}, radius = 0.1, intensity = 0.5, twist = 0.3, corner = true}}
	b := []geom.Bezier_Point{{p = {0, 1, 0}, radius = 1, intensity = 1}, {p = {0, 2, 0}, radius = 1, intensity = 1}, {p = {1, 2, 0}, radius = 1, intensity = 1}}
	testing.expect(t, curve_object_add(&app, a, false))
	testing.expect(t, curve_object_add(&app, b, true))
	app.scene.selected = 0
	folder := "build/curve_test/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	testing.expect(t, os.make_directory_all(folder) == nil)
	path := "build/curve_test/round_trip.sculpt"
	testing.expect(t, scene_save(&app, path))

	// As an app from before curves reads it: the scene chunk says no objects, and every
	// chunk after it is a CURV one it steps over.
	data, err := os.read_entire_file_from_path(path, context.allocator)
	testing.expect(t, err == nil)
	defer delete(data)
	r := geom.byte_reader(data[len(SCENE_MAGIC):])
	_ = geom.byte_get(&r, u32)
	_ = preview_block_skip(&r)
	tag, chunk, ok := scene_chunk_next(&r)
	testing.expect(t, ok && tag == CHUNK_SCENE)
	f, fields_ok := scene_fields_get(&app, &chunk, SCENE_VERSION)
	scene_fields_destroy(&f)
	testing.expect(t, fields_ok && f.count == 0 && f.curves == 2 && f.selected_any == 0)
	// Not temporary: object_get frees the temporary allocator.
	got := make([dynamic]^Object)
	defer delete(got)
	for {
		next, body, more := scene_chunk_next(&r)
		if !more do break
		testing.expect_value(t, next, CHUNK_CURVE)
		// A curve in an object's chunk is damage; in its own it reads back.
		wrong := body
		_, wrong_read, _ := object_get(&app, &wrong, SCENE_VERSION, nil, .Object_Chunk)
		testing.expect(t, !wrong_read, "a curve read from an object chunk")
		obj, read, made := object_get(&app, &body, SCENE_VERSION, nil, .Curve_Chunk)
		testing.expect(t, read && made, "a curve chunk did not read")
		if obj != nil do append(&got, obj)
	}
	testing.expect_value(t, len(got), 2)
	defer for obj in got {
		curve_part_free(obj)
		sculpt.levels_destroy(&obj.levels)
		delete(obj.name)
		delete(obj.group_materials)
		free(obj)
	}
	if len(got) != 2 do return
	c0, c1 := got[0].curve, got[1].curve
	testing.expect(t, c0 != nil && !c0.closed && len(c0.points) == 2, "the first curve")
	testing.expect(t, c1 != nil && c1.closed && len(c1.points) == 3, "the second curve")
	if c0 != nil && len(c0.points) == 2 {
		// Points are kept about the object's middle, which its transform puts back.
		world := to_world(got[0].transform, c0.points[1].p)
		testing.expectf(t, abs(world.x - 1) < 1e-5 && c0.points[1].corner && c0.points[1].twist == 0.3, "%v", c0.points[1])
	}
}

// With meshes around a curve, the scene chunk counts the meshes alone, and a selected curve
// gives the mesh before it as the selection an older app reads.
@(test)
curve_selection_without_curves :: proc(t: ^testing.T) {
	app: App
	defer curve_scene_free(&app)
	curve_scene(&app)
	pts := []geom.Bezier_Point{{p = {0, 0, 2}}, {p = {1, 0, 2}}}
	testing.expect(t, curve_object_add(&app, pts, false))
	mesh := new(Object)
	mesh.id = 10
	sculpt.levels_init(&mesh.levels, geom.icosphere(1), nil, 64)
	append(&app.scene.objects, mesh)
	app.scene.selected = 1
	testing.expect_value(t, scene_selected_without_curves(&app), 0)
	app.scene.selected = 2
	testing.expect_value(t, scene_selected_without_curves(&app), 1)
	app.scene.objects[0], app.scene.objects[1] = app.scene.objects[1], app.scene.objects[0]
	app.scene.selected = 0
	testing.expect_value(t, scene_selected_without_curves(&app), 0)
}

// Damaged curve bytes are refused before anything is made: too few points, more points
// than bytes, a corner or use no version wrote, a value that is not a number.
@(test)
curve_damage_is_refused :: proc(t: ^testing.T) {
	good := Curve_Part{tube = geom.TUBE_DEFAULTS}
	defer delete(good.points)
	append(&good.points, geom.Bezier_Point{p = {0, 0, 0}, radius = 1}, geom.Bezier_Point{p = {1, 0, 0}, radius = 1})
	bytes: [dynamic]u8
	defer delete(bytes)
	curve_part_put(&bytes, &good)
	check :: proc(t: ^testing.T, data: []u8, want: bool, what: string) {
		obj: Object
		r := geom.byte_reader(data)
		app: App
		got, _ := curve_part_get(&app, &r, &obj)
		testing.expectf(t, got == want, "%s: read %v", what, got)
		curve_part_free(&obj)
		sculpt.levels_destroy(&obj.levels)
	}
	check(t, bytes[:], true, "whole")
	check(t, bytes[:len(bytes) - 1], false, "tube options cut short")
	check(t, bytes[:6 + CURVE_POINT_BYTES], false, "points cut short")
	one := make([]u8, len(bytes), context.temp_allocator)
	copy(one, bytes[:])
	one[0] = 1
	check(t, one, false, "one point")
	many := make([]u8, len(bytes), context.temp_allocator)
	copy(many, bytes[:])
	many[0] = 200
	check(t, many, false, "more points than bytes")
	use := make([]u8, len(bytes), context.temp_allocator)
	copy(use, bytes[:])
	use[5] = 9
	check(t, use, false, "a use past the last")
	corner := make([]u8, len(bytes), context.temp_allocator)
	copy(corner, bytes[:])
	corner[6 + CURVE_POINT_BYTES - 1] = 2
	check(t, corner, false, "a corner of 2")
	nan := make([]u8, len(bytes), context.temp_allocator)
	copy(nan, bytes[:])
	bits := transmute([4]u8)math.nan_f32()
	copy(nan[6:][:4], bits[:])
	check(t, nan, false, "not a number")
}

// A curve's tube options come back as written; a curve from before them (no block after
// its points) takes the defaults, and options no version wrote are damage.
@(test)
curve_tube_options_read_back :: proc(t: ^testing.T) {
	cp := Curve_Part{closed = true}
	defer delete(cp.points)
	append(&cp.points, geom.Bezier_Point{p = {0, 0, 0}, radius = 1}, geom.Bezier_Point{p = {1, 0, 0}, radius = 1}, geom.Bezier_Point{p = {0, 1, 0}, radius = 1})
	cp.tube = {profile = .Star, radius = .One, one = 0.3, sides = 7, density = 2.5, caps = .Open, flatness = 0.4}
	bytes: [dynamic]u8
	defer delete(bytes)
	curve_part_put(&bytes, &cp)
	testing.expect_value(t, len(bytes), 6 + 3 * CURVE_POINT_BYTES + CURVE_TUBE_BYTES)
	read :: proc(data: []u8) -> (o: geom.Tube_Options, ok: bool) {
		obj: Object
		app: App
		r := geom.byte_reader(data)
		ok, _ = curve_part_get(&app, &r, &obj)
		if ok do o = obj.curve.tube
		curve_part_free(&obj)
		sculpt.levels_destroy(&obj.levels)
		return
	}
	got, ok := read(bytes[:])
	testing.expect(t, ok && got == cp.tube, "options did not come back")
	got, ok = read(bytes[:6 + 3 * CURVE_POINT_BYTES])
	testing.expect(t, ok && got == geom.TUBE_DEFAULTS, "a curve without options did not take the defaults")
	sides := make([]u8, len(bytes), context.temp_allocator)
	copy(sides, bytes[:])
	sides[6 + 3 * CURVE_POINT_BYTES + 6] = 2
	_, ok = read(sides)
	testing.expect(t, !ok, "two sides were read")
	profile := make([]u8, len(bytes), context.temp_allocator)
	copy(profile, bytes[:])
	profile[6 + 3 * CURVE_POINT_BYTES] = 9
	_, ok = read(profile)
	testing.expect(t, !ok, "a profile past the last was read")
}

// Cleaning keeps a tube buildable: sides in range, density and flatness positive.
@(test)
curve_tube_clean_bounds :: proc(t: ^testing.T) {
	o := curve_tube_clean({sides = 1, density = 0, flatness = -1, one = -2})
	testing.expect_value(t, o.sides, 3)
	testing.expect(t, o.density > 0 && o.flatness > 0 && o.one == 0)
	o = curve_tube_clean({sides = 999, density = 100, flatness = 0.5, one = 0.2})
	testing.expect_value(t, o.sides, geom.TUBE_SIDES_MAX)
	testing.expect(t, o.density <= 16 && o.flatness == 0.5 && o.one == 0.2)
}

// A curve is its own type: the chip says Curve and its conversion is Bake, which needs a tube.
@(test)
curve_is_its_own_type :: proc(t: ^testing.T) {
	app: App
	defer curve_scene_free(&app)
	curve_scene(&app)
	pts := []geom.Bezier_Point{{p = {0, 0, 2}, radius = 0.1}, {p = {1, 0, 2}, radius = 0.1}}
	testing.expect(t, curve_object_add(&app, pts, false))
	obj := selected_object(&app)
	testing.expect_value(t, object_type(obj), Object_Type.Curve)
	testing.expect_value(t, OBJECT_CONVERSIONS[.Curve].id, Command_Id.Curve_Bake)
	testing.expect(t, !command_enabled(&app, .Curve_Bake), "Bake runs on a curve with no tube")
	testing.expect(t, !object_draws_triangles(obj), "a line has triangles")
	chip := object_chip_of(&app)
	testing.expect_value(t, chip.tag, "Curve")
}

// Commands that need a surface refuse a selected curve.
@(test)
curve_refuses_surface_commands :: proc(t: ^testing.T) {
	app: App
	defer curve_scene_free(&app)
	curve_scene(&app)
	pts := []geom.Bezier_Point{{p = {0, 0, 2}}, {p = {1, 0, 2}}}
	testing.expect(t, curve_object_add(&app, pts, false))
	testing.expect(t, !command_enabled(&app, .Remesh), "Remesh is offered for a curve")
	testing.expect(t, !command_enabled(&app, .Subdivide), "Subdivide is offered for a curve")
	testing.expect(t, command_reason(&app, .Remesh) != "", "no reason given")
	testing.expect(t, .Remesh in CURVE_REFUSED_SCENE && .Delete not_in CURVE_REFUSED_SCENE && .Duplicate not_in CURVE_REFUSED_SCENE)
}
