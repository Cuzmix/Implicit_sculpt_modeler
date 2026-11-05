package main

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
	testing.expect_value(t, len(stack_placings(obj)), 0)
	obj.stack.mirror = {added = true, shown = true, axes = {.X, .Z}}
	placings := stack_placings(obj)
	testing.expect_value(t, len(placings), 3)
	reflected := 0
	for p in placings do reflected += int(render.model_reflected(p))
	testing.expect_value(t, reflected, 2)
	testing.expect_value(t, stack_clip(obj), [3]f32{1, 0, 1})
	obj.stack.mirror.minus = true
	testing.expect_value(t, stack_clip(obj), [3]f32{-1, 0, -1})
	// Hidden, or with no plane, it draws nothing extra and clips nothing.
	obj.stack.mirror.shown = false
	testing.expect_value(t, len(stack_placings(obj)), 0)
	testing.expect_value(t, stack_clip(obj), [3]f32{})
	obj.stack.mirror = {added = true, shown = true}
	testing.expect_value(t, len(stack_placings(obj)), 0)
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
}

// The stack's bytes read back as written; anything else is refused.
@(test)
stack_bytes_round_trip :: proc(t: ^testing.T) {
	s := Stack{mirror = {added = true, shown = false, axes = {.Y, .Z}, minus = true}}
	out: [dynamic]u8
	defer delete(out)
	stack_put(&out, s)
	testing.expect_value(t, len(out), STACK_BYTES)
	back, ok := stack_get(out[:])
	testing.expect(t, ok)
	testing.expect_value(t, back, s)
	_, bad := stack_get([]u8{8, 0})
	testing.expect(t, !bad)
	_, bad = stack_get([]u8{1, 9})
	testing.expect(t, !bad)
}
