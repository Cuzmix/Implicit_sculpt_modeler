package main

import "core:slice"
import "core:testing"

import "../geom"
import "../sculpt"

@(private = "file")
reshape_scene :: proc(app: ^App) {
	for id in 1 ..= 3 {
		obj := new(Object)
		obj.id, obj.transform = id, {position = {f32(3 * id), 0, 0}, scale = 1}
		sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
		append(&app.scene.objects, obj)
	}
	app.scene.selected = 0
	app.ui.reshape = reshape_panel_default()
}

@(private = "file")
reshape_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
}

// Drags Amount through `values` and lets go.
@(private = "file")
reshape_drag :: proc(app: ^App, obj: ^Object, values: ..f32) {
	for v in values {
		app.ui.reshape.amount = v
		reshape_drag_to(app, obj)
	}
	reshape_drag_end(app)
}

// A drag is one undo step that ends where its last value puts it, and the slider springs
// back; undo puts every vertex back.
@(test)
reshape_drag_is_one_step :: proc(t: ^testing.T) {
	app: App
	defer reshape_scene_free(&app)
	reshape_scene(&app)
	obj := app.scene.objects[0]
	before := slice.clone(object_mesh(obj).positions[:], context.temp_allocator)
	app.ui.reshape.choice = .Offset
	reshape_drag(&app, obj, 10, 40, 25)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, app.history.done[0].what, "Offset")
	testing.expect_value(t, app.ui.reshape.amount, 0)
	// 25 % of a sphere 2 across along Y.
	for p, v in object_mesh(obj).positions do testing.expect(t, abs(p.y - before[v].y - 0.5) < 1e-5 && p.x == before[v].x)
	history_undo(&app)
	testing.expect(t, slice.equal(object_mesh(obj).positions[:], before))
	free_all(context.temp_allocator)
}

// Polish runs once, when the slider is let go, with the steps it shows; Repeat on the
// others gives the two other objects the same, undone together in one step.
@(test)
reshape_polish_on_release_and_repeat :: proc(t: ^testing.T) {
	app: App
	defer reshape_scene_free(&app)
	reshape_scene(&app)
	obj := app.scene.objects[0]
	app.ui.reshape.choice = .Polish
	app.ui.reshape.amount = 4
	reshape_drag_to(&app, obj)
	testing.expect_value(t, len(app.history.done), 0)
	reshape_drag_end(&app)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect(t, app.ui.reshape.last.valid && app.ui.reshape.last.choice == .Polish)

	app.ui.reshape.choice = .Size
	reshape_drag(&app, obj, 50)
	others := [2][]geom.Vec3{slice.clone(object_mesh(app.scene.objects[1]).positions[:], context.temp_allocator), slice.clone(object_mesh(app.scene.objects[2]).positions[:], context.temp_allocator)}
	testing.expect_value(t, reshape_repeat(&app), 2)
	for k in 0 ..< 2 do testing.expect(t, !slice.equal(object_mesh(app.scene.objects[k + 1]).positions[:], others[k]))
	steps := history_step_count(app.history.done[:])
	history_undo(&app)
	testing.expect_value(t, history_step_count(app.history.done[:]), steps - 1)
	for k in 0 ..< 2 do testing.expect(t, slice.equal(object_mesh(app.scene.objects[k + 1]).positions[:], others[k]))
	free_all(context.temp_allocator)
}
