package main

import "core:testing"

import "../geom"
import "../sculpt"

// Adds a straight open (or a closed triangle) line curve about x = `x`; its use is set
// after, since a tube is built on the GPU, which tests have not.
@(private = "file")
loft_add :: proc(app: ^App, x: f32, closed := false, use := Curve_Use.None) {
	pts := [3]geom.Bezier_Point{{p = {x, 0, 0}, radius = 0.1, intensity = 1}, {p = {x, 1, 0}, radius = 0.1, intensity = 1}, {p = {x, 0, 1}, radius = 0.1, intensity = 1}}
	_ = curve_object_add(app, pts[:] if closed else pts[:2], closed)
	app.scene.objects[len(app.scene.objects) - 1].curve.use = use
}

@(private = "file")
loft_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		curve_part_free(obj)
		sculpt.levels_destroy(&obj.levels)
		delete(obj.name)
		free(obj)
	}
	delete(app.scene.objects)
	delete(app.scene.also)
	curve_tool_destroy(&app.curve)
	history_destroy(&app.history)
	results_destroy(app)
}

// A loft runs from the selected curve to the nearest next, leaving out tubes, and refuses
// a lone curve or a mix of open and closed ones.
@(test)
loft_sections_run_nearest_first :: proc(t: ^testing.T) {
	app: App
	defer loft_free(&app)
	defer free_all(context.temp_allocator)
	loft_add(&app, 0)
	_, why := curve_loft_sections(&app)
	testing.expect(t, why != "", "a lone curve lofts")
	loft_add(&app, 5)
	loft_add(&app, 2)
	loft_add(&app, 1, use = .Tube)
	select_object(&app, app.scene.objects[0])
	curves, why2 := curve_loft_sections(&app)
	testing.expectf(t, why2 == "", "refused: %s", why2)
	testing.expect_value(t, len(curves), 3)
	if len(curves) == 3 {
		testing.expect(t, curves[0] == app.scene.objects[0] && curves[1] == app.scene.objects[2] && curves[2] == app.scene.objects[1], "not nearest first")
	}
	// Two selected curves loft alone, whatever else is shown.
	selection_set(&app, {app.scene.objects[1].id, app.scene.objects[0].id})
	curves, _ = curve_loft_sections(&app)
	testing.expect_value(t, len(curves), 2)
	loft_add(&app, 3, closed = true)
	selection_set(&app, {app.scene.objects[0].id, app.scene.objects[4].id})
	_, why = curve_loft_sections(&app)
	testing.expect(t, why != "", "open and closed curves loft together")
}
