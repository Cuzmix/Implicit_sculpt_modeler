package main

import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "../geom"
import "../render"
import "../sculpt"

@(private = "file")
stack_scene :: proc(app: ^App) -> ^Object {
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	return obj
}

@(private = "file")
stack_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
}

// Each plane doubles the images; each image is a reflection across the planes it
// combines, so every one but the object's own turns space over an odd or even number of
// times, and the clip keeps the side the row says.
@(test)
stack_mirror_placings_and_clip :: proc(t: ^testing.T) {
	app: App
	defer stack_scene_free(&app)
	obj := stack_scene(&app)
	testing.expect_value(t, len(stack_placings(&app, obj)), 0)
	obj.stack.mirror = {added = true, shown = true, axes = {.X, .Z}}
	placings := stack_placings(&app, obj)
	testing.expect_value(t, len(placings), 3)
	reflected := 0
	for p in placings do reflected += int(render.model_reflected(p))
	testing.expect_value(t, reflected, 2)
	testing.expect_value(t, stack_clip(obj), [3]f32{1, 0, 1})
	obj.stack.mirror.minus = true
	testing.expect_value(t, stack_clip(obj), [3]f32{-1, 0, -1})
	// Hidden, or with no plane, it draws nothing extra and clips nothing.
	obj.stack.mirror.shown = false
	testing.expect_value(t, len(stack_placings(&app, obj)), 0)
	testing.expect_value(t, stack_clip(obj), [3]f32{})
	obj.stack.mirror = {added = true, shown = true}
	testing.expect_value(t, len(stack_placings(&app, obj)), 0)
}

// A shown mirror holds the brush's symmetry on across its planes, through the origin
// even with Local symmetry, and Keep symmetry's planes with it.
@(test)
stack_mirror_locks_symmetry :: proc(t: ^testing.T) {
	app: App
	defer stack_scene_free(&app)
	obj := stack_scene(&app)
	app.brush.sym_local = true
	obj.stack.mirror = {added = true, shown = true, axes = {.Y}}
	b := brush_symmetry(&app, obj)
	testing.expect_value(t, b.symmetry, sculpt.Symmetry{.Y})
	testing.expect_value(t, b.sym_center, Vec3{})
	testing.expect(t, symmetry_planes(&app, obj).axes[1])
	testing.expect(t, symmetry_on(&app))
	obj.stack.mirror.shown = false
	testing.expect_value(t, brush_symmetry(&app, obj).symmetry, sculpt.Symmetry{})
}

// The script verb sets the row as the card does, one undo step each, and undo and redo
// trade the stack back and forth.
@(test)
stack_script_and_undo :: proc(t: ^testing.T) {
	app: App
	defer stack_scene_free(&app)
	obj := stack_scene(&app)
	testing.expect_value(t, stack_script(&app, obj, "mirror -xz"), "")
	testing.expect_value(t, obj.stack.mirror, Stack_Mirror{added = true, shown = true, axes = {.X, .Z}, minus = true})
	testing.expect_value(t, stack_script(&app, obj, "hide mirror"), "")
	testing.expect(t, !obj.stack.mirror.shown)
	testing.expect(t, stack_script(&app, obj, "mirror w") != "")
	testing.expect(t, stack_script(&app, obj, "twist mirror") != "")
	testing.expect(t, stack_script(&app, obj, "array 1 2 0 0") != "")
	testing.expect(t, stack_script(&app, obj, "radial 6 w") != "")
	testing.expect_value(t, len(app.history.done), 2)
	history_undo(&app)
	testing.expect(t, obj.stack.mirror.shown)
	history_undo(&app)
	testing.expect(t, !obj.stack.mirror.added)
	history_redo(&app)
	testing.expect_value(t, obj.stack.mirror.axes, sculpt.Symmetry{.X, .Z})
	// The same stack again is no step.
	testing.expect_value(t, stack_script(&app, obj, "mirror -xz"), "")
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, stack_script(&app, obj, "array 4 0 1.5 0"), "")
	testing.expect_value(t, obj.stack.array.count, 4)
	testing.expect_value(t, obj.stack.array.offset, Vec3{0, 1.5, 0})
	testing.expect_value(t, stack_script(&app, obj, "radial 5 z"), "")
	testing.expect(t, obj.stack.radial.added && obj.stack.radial.count == 5 && obj.stack.radial.axis == .Z)
	testing.expect_value(t, stack_script(&app, obj, "hide radial"), "")
	testing.expect_value(t, stack_summary(obj), "Mirror X and Z, Array 4, Radial (hidden)")
	testing.expect_value(t, stack_script(&app, obj, "array off"), "")
	testing.expect(t, !obj.stack.array.added)
	testing.expect_value(t, len(app.history.done), 5)
}

// The stack's bytes read back as written; anything else is refused.
@(test)
stack_bytes_round_trip :: proc(t: ^testing.T) {
	s := Stack {
		mirror = {added = true, shown = false, axes = {.Y, .Z}, minus = true},
		array  = {added = true, shown = true, count = 5, offset = {1, 2, 3}, turn = {0, 15, 0}, grow = 0.9},
		radial = {added = true, shown = false, count = 8, axis = .Z, pivot = {0, -1, 0}},
		along  = {added = true, shown = true, count = 7, axis = .Y, curve = 12},
	}
	out: [dynamic]u8
	defer delete(out)
	stack_put(&out, s)
	testing.expect_value(t, len(out), STACK_BYTES)
	r := geom.byte_reader(out[:])
	back, ok := stack_get(&r)
	testing.expect(t, ok && r.at == STACK_BYTES)
	testing.expect_value(t, back, s)
	// A bit past the mirror's, an array of one, a size step of nothing or too few bytes is
	// damage.
	for b in ([?][2]u8{{0, 8}, {3, 1}}) {
		bad := slice.clone(out[:], context.temp_allocator)
		bad[b[0]] = b[1]
		rb := geom.byte_reader(bad)
		_, bad_ok := stack_get(&rb)
		testing.expect(t, !bad_ok)
	}
	grown := s
	grown.array.grow = 0
	out2: [dynamic]u8
	defer delete(out2)
	stack_put(&out2, grown)
	r2 := geom.byte_reader(out2[:])
	_, grown_ok := stack_get(&r2)
	testing.expect(t, !grown_ok)
	r3 := geom.byte_reader(out[:10])
	_, short_ok := stack_get(&r3)
	testing.expect(t, !short_ok)
	free_all(context.temp_allocator)
}

// Array and Radial multiply: three steps turned six times are seventeen copies; with a
// mirror plane each of the eighteen has its image, thirty-five copies, half reflected.
// The frames a stroke can sculpt through are the steps', never a reflection.
@(test)
stack_array_and_radial_placings :: proc(t: ^testing.T) {
	app: App
	defer stack_scene_free(&app)
	obj := stack_scene(&app)
	obj.stack.array = STACK_ARRAY_DEFAULT
	testing.expect_value(t, len(stack_placings(&app, obj)), 2)
	p := stack_placings(&app, obj)
	testing.expect(t, abs(p[1][0, 3] - 2 * STACK_ARRAY_DEFAULT.offset.x) < 1e-5, "the second copy is two steps along")
	obj.stack.radial = STACK_RADIAL_DEFAULT
	testing.expect_value(t, len(stack_placings(&app, obj)), 17)
	testing.expect_value(t, len(stack_frames(&app, obj)), 17)
	obj.stack.mirror = {added = true, shown = true, axes = {.X}}
	placings := stack_placings(&app, obj)
	testing.expect_value(t, len(placings), 35)
	reflected := 0
	for m in placings do reflected += int(render.model_reflected(m))
	testing.expect_value(t, reflected, 18)
	testing.expect_value(t, len(stack_frames(&app, obj)), 17)
	for f in stack_frames(&app, obj) do testing.expect(t, f.scale > 0)
	// A radial turn about Y through the pivot keeps the pivot where it is.
	obj.stack = {radial = STACK_RADIAL_DEFAULT}
	for m in stack_placings(&app, obj) {
		q := m * [4]f32{STACK_RADIAL_DEFAULT.pivot.x, STACK_RADIAL_DEFAULT.pivot.y, STACK_RADIAL_DEFAULT.pivot.z, 1}
		testing.expect(t, linalg.length(q.xyz - STACK_RADIAL_DEFAULT.pivot) < 1e-4)
	}
	// The counts at their most stop at STACK_COPIES_MAX draws.
	obj.stack.array = STACK_ARRAY_DEFAULT
	obj.stack.array.count, obj.stack.radial.count = STACK_COUNT_MAX, STACK_COUNT_MAX
	obj.stack.mirror = {added = true, shown = true, axes = {.X, .Y}}
	testing.expect(t, len(stack_placings(&app, obj)) < STACK_COPIES_MAX)
	free_all(context.temp_allocator)
}

// A ray onto an array's copy hits it, through the copy's own transform, which a stroke
// started there sculpts by: the copy's point is the object's own point in its space.
@(test)
stack_ray_finds_the_copy :: proc(t: ^testing.T) {
	app: App
	defer stack_scene_free(&app)
	obj := stack_scene(&app)
	obj.stack.array = {added = true, shown = true, count = 2, offset = {3, 0, 0}, grow = 1}
	index, hit, frame, framed, ok := scene_raycast_framed(&app, {3, 0, 5}, {0, 0, -1})
	testing.expect(t, ok && framed && index == 0)
	testing.expect(t, linalg.length(hit - Vec3{3, 0, 1}) < 0.05)
	testing.expect(t, linalg.length(to_local(frame, hit) - Vec3{0, 0, 1}) < 0.05)
	_, _, _, on_object, _ := scene_raycast_framed(&app, {0, 0, 5}, {0, 0, -1})
	testing.expect(t, !on_object)
	free_all(context.temp_allocator)
}

// Along lays the object on a straight curve from end to end, its own X running along the
// curve, under the object's own size; the object stays where it was. Without its curve
// the row makes nothing.
@(test)
stack_along_lays_copies_on_the_curve :: proc(t: ^testing.T) {
	app: App
	defer stack_scene_free(&app)
	obj := stack_scene(&app)
	obj.transform = {position = {0, 3, 0}, scale = 0.5}
	curve := new(Object)
	curve.id = 2
	curve.transform = {scale = 1}
	curve.curve = new(Curve_Part)
	append(&curve.curve.points, geom.Bezier_Point{p = {0, 0, 0}, h_out = {0, 0, 1}}, geom.Bezier_Point{p = {0, 0, 6}, h_in = {0, 0, -1}})
	defer curve_part_free(curve)
	append(&app.scene.objects, curve)
	testing.expect_value(t, stack_script(&app, obj, "along 4 x"), "")
	testing.expect_value(t, obj.stack.along.curve, 2)
	placings := stack_placings(&app, obj)
	testing.expect_value(t, len(placings), 4)
	world := transform_matrix(obj.transform)
	for m, k in placings {
		w := world * m
		testing.expectf(t, linalg.length(Vec3{w[0, 3], w[1, 3], w[2, 3]} - Vec3{0, 0, 2 * f32(k)}) < 1e-3, "copy %d is at %v", k, Vec3{w[0, 3], w[1, 3], w[2, 3]})
		// The object's X runs along the curve (+Z), at the object's size.
		testing.expect(t, linalg.length(Vec3{w[0, 0], w[1, 0], w[2, 0]} - Vec3{0, 0, 0.5}) < 1e-3)
		testing.expect(t, !render.model_reflected(w))
	}
	testing.expect_value(t, len(stack_frames(&app, obj)), 4)
	// The object itself is not moved, and its copies go with the curve.
	testing.expect_value(t, obj.transform.position, Vec3{0, 3, 0})
	curve.transform.position = {1, 0, 0}
	w := world * stack_placings(&app, obj)[0]
	testing.expect(t, abs(w[0, 3] - 1) < 1e-3)
	obj.stack.along.curve = 9
	testing.expect_value(t, len(stack_placings(&app, obj)), 0)
	free_all(context.temp_allocator)
}

// The bake is what the view shows: a mirror welds a closed whole whose every vertex comes
// from the kept side, and Array's copies join it, each vertex's source carried over.
@(test)
stack_bake_welds_the_mirror_and_joins_the_copies :: proc(t: ^testing.T) {
	app: App
	defer stack_scene_free(&app)
	obj := stack_scene(&app)
	src := object_mesh(obj)^
	_, none := stack_bake(&app, obj, src.positions[:], src.indices[:])
	testing.expect(t, !none, "baked a stack with no rows")

	obj.stack.mirror = {added = true, shown = true, axes = {.X}}
	from: [dynamic]u32
	defer delete(from)
	half, ok := stack_bake(&app, obj, src.positions[:], src.indices[:], &from)
	defer geom.mesh_destroy(&half)
	if !testing.expect(t, ok) do return
	r := geom.mesh_check(half)
	testing.expect(t, r.closed, "the welded mirror is not closed")
	testing.expect_value(t, len(from), len(half.positions))
	wrong := 0
	for v in from do if int(v) >= len(src.positions) || src.positions[v].x < -0.3 do wrong += 1
	testing.expect_value(t, wrong, 0)

	obj.stack.array = STACK_ARRAY_DEFAULT
	obj.stack.array.added, obj.stack.array.shown = true, true
	three, joined := stack_bake(&app, obj, src.positions[:], src.indices[:], &from)
	defer geom.mesh_destroy(&three)
	if !testing.expect(t, joined) do return
	testing.expect_value(t, len(three.positions), 3 * len(half.positions))
	testing.expect_value(t, len(three.indices), 3 * len(half.indices))
	testing.expect_value(t, len(from), len(three.positions))
	testing.expect_value(t, geom.mesh_check(three).boundary_edges, 0)
	// The third copy sits two steps along X.
	b := geom.mesh_check(three).bounds
	testing.expect(t, b.hi.x > 2 * STACK_ARRAY_DEFAULT.offset.x + 0.9, "the last copy is not two steps along")
	testing.expect_value(t, app.stack_bakes, 2)
	free_all(context.temp_allocator)
}

// An export takes the stack baked unless the sheet keeps it out, and leaves the object
// as it was.
@(test)
stack_export_bakes_unless_kept :: proc(t: ^testing.T) {
	FOLDER :: "build/stack_export_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	app: App
	defer stack_scene_free(&app)
	obj := stack_scene(&app)
	obj.stack.radial = STACK_RADIAL_DEFAULT
	obj.stack.radial.added, obj.stack.radial.shown = true, true
	n := len(object_mesh(obj).positions)
	for keep in ([2]bool{false, true}) {
		path := strings.concatenate({FOLDER, "kept.ply" if keep else "baked.ply"})
		defer delete(path)
		if !testing.expect(t, object_export(&app, obj, path, once = {keep_stack = keep})) do return
		data, err := os.read_entire_file(path, context.allocator)
		defer delete(data)
		if !testing.expect(t, err == nil) do return
		m, failed, _ := geom.mesh_read_ply(data, &app.pool)
		defer geom.mesh_destroy(&m)
		if !testing.expect_value(t, failed, geom.Mesh_File_Error.None) do return
		testing.expect_value(t, len(m.positions), n if keep else STACK_RADIAL_DEFAULT.count * n)
	}
	testing.expect_value(t, len(object_mesh(obj).positions), n)
	free_all(context.temp_allocator)
}

// The card's rows: what a sculpt can take (no cage rows), what each says folded, Add as
// one undo step with its starting values, and a hidden row saying so.
@(test)
stack_card_rows_add_and_say :: proc(t: ^testing.T) {
	app: App
	defer stack_scene_free(&app)
	obj := stack_scene(&app)
	for r in Stack_Row do testing.expect(t, !stack_row_in(&app, obj, r))
	stack_row_add(&app, obj, .Array)
	stack_row_add(&app, obj, .Radial)
	stack_row_add(&app, obj, .Mirror)
	testing.expect_value(t, len(app.history.done), 3)
	testing.expect(t, stack_row_in(&app, obj, .Array) && stack_row_in(&app, obj, .Radial) && stack_row_in(&app, obj, .Mirror))
	testing.expect(t, !stack_row_in(&app, obj, .Smooth) && !stack_row_in(&app, obj, .Cage_Mirror))
	testing.expect_value(t, stack_row_detail(&app, obj, .Array), "3, 2.20 apart")
	testing.expect_value(t, stack_row_detail(&app, obj, .Radial), "6 round Y")
	testing.expect_value(t, stack_row_detail(&app, obj, .Mirror), "X, keeps +")
	stack_row_add(&app, obj, .Along)
	testing.expect_value(t, stack_row_detail(&app, obj, .Along), "No curve picked")
	s := obj.stack
	s.radial.shown = false
	stack_set(&app, obj, s, "Hide radial")
	testing.expect_value(t, stack_row_detail(&app, obj, .Radial), "Hidden")
	// Reset is Add again: the starting values, one more step.
	s = obj.stack
	s.array.count = 9
	stack_set(&app, obj, s, "Array count")
	stack_row_add(&app, obj, .Array)
	testing.expect_value(t, obj.stack.array, STACK_ARRAY_DEFAULT)
	history_undo(&app)
	testing.expect_value(t, obj.stack.array.count, 9)
}
