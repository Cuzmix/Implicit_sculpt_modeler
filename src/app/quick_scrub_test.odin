package main

import "core:testing"

import "../geom"
import "../sculpt"

// The quick scrub stands only where the History can: a chain is passed over as one step.
// Sliding a step's width a time moves the History through timeline_seek_to, lifting keeps
// where it went, and a hold let go unslid opens the History panel instead.
@(test)
quick_scrub_moves_by_steps :: proc(t: ^testing.T) {
	app: App
	defer {
		for obj in app.scene.objects {
			sculpt.levels_destroy(&obj.levels)
			free(obj)
		}
		delete(app.scene.objects)
		history_destroy(&app.history)
		results_destroy(&app)
	}
	app.ui.smooth_steps, app.ui.smooth_strength = 1, 0.5
	app.camera = {distance = 3, fov_y = 0.8, near = 0.01, far = 100}
	app.kit.ctx.input.window = {1600, 900}
	app.kit.ctx.theme.slop = 10
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(5), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	for _ in 0 ..< 5 do smooth_command(&app, 1)
	testing.expect_value(t, len(app.history.done), 5)
	app.history.done[3].chain = true
	places := history_places(&app)
	testing.expect_value(t, len(places), 5)
	testing.expect_value(t, places[3], 4)
	testing.expect_value(t, history_place_of(places[:], 5), 4)
	testing.expect_value(t, history_place_of(places[:], 3), 2)

	in_ := &app.kit.ctx.input
	settle :: proc(app: ^App) {
		quick_scrub_frame(app)
		for app.timeline.seeking do timeline_frame(app)
	}
	// Two steps' width left: back over the last step and the chain, as one.
	quick_scrub_begin(&app, .Undo, 500)
	testing.expect_value(t, app.timeline.quick.base, 4)
	in_.down = {.Left}
	in_.mouse.x = 500 - 2 * QUICK_SCRUB_STEP
	settle(&app)
	testing.expect(t, app.timeline.quick.moved)
	testing.expect_value(t, len(app.history.done), 2)
	// Back a step's width right redoes the chain whole.
	in_.mouse.x = 500 - QUICK_SCRUB_STEP
	settle(&app)
	testing.expect_value(t, len(app.history.done), 4)
	// Lifting keeps it there and opens no panel.
	in_.down = {}
	settle(&app)
	testing.expect_value(t, app.timeline.quick.by, Quick_Scrub_By.Off)
	testing.expect_value(t, app.timeline.quick.scrubs, 1)
	testing.expect_value(t, app.timeline.quick.last, -1)
	testing.expect_value(t, len(app.history.done), 4)
	testing.expect(t, !app.kit.history)

	// Held at the window's side, it keeps stepping past what the slide reaches.
	quick_scrub_begin(&app, .Redo, 100)
	in_.down = {.Left}
	in_.mouse.x = 10
	for i in 0 ..< 6 {
		app.kit.ctx.time = f64(i) * HOLD_REPEAT
		settle(&app)
	}
	testing.expect_value(t, len(app.history.done), 0)
	in_.down = {}
	settle(&app)

	// A hold let go without sliding opens the History panel and moves nothing.
	quick_scrub_begin(&app, .Undo, 300)
	in_.down = {.Left}
	in_.mouse.x = 302
	settle(&app)
	in_.down = {}
	settle(&app)
	testing.expect(t, app.kit.history)
	testing.expect_value(t, len(app.history.done), 0)
	testing.expect_value(t, app.timeline.quick.scrubs, 2)
}
