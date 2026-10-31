package main

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

// A sphere and, selected, a brush path curve of three points over its front, Draw in hand.
@(private = "file")
path_scene :: proc(app: ^App) -> (sphere: ^Object) {
	sphere = new(Object)
	sphere.id = 1
	sphere.transform = {scale = 1}
	sculpt.levels_init(&sphere.levels, geom.icosphere(5), nil, 64)
	append(&app.scene.objects, sphere)
	app.scene.selected, app.scene.next_id = 0, 1
	app.camera = camera.orbit_default()
	app.brush.kind, app.brush.radius_px = .Draw, 40
	app.brush.strengths[.Draw] = 0.5
	app.kit.fixed_dt = 1.0 / 60
	app.ui.viewport_size = {1000, 800}
	toward := camera.orbit_toward(app.camera, {})
	right := linalg.normalize(linalg.cross(Vec3{0, 1, 0}, toward))
	pts: [3]geom.Bezier_Point
	for &p, i in pts {
		p.p = linalg.normalize(-toward + right * (f32(i) - 1) * 0.4)
		p.h_in, p.h_out = -right * 0.1, right * 0.1
		p.radius, p.intensity = 0.08, 1
	}
	look := CURVE_LOOK_DEFAULTS
	look.use = .Brush_Path
	_ = curve_object_add(app, pts[:], false, look)
	app.tool = .Curve
	return
}

@(private = "file")
path_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		curve_part_free(obj)
		sculpt.levels_destroy(&obj.levels)
		delete(obj.name)
		free(obj)
	}
	delete(app.scene.objects)
	delete(app.stroke.pending)
	delete(app.stroke.path)
	stroke_edit_destroy(&app.stroke_edit)
	curve_tool_destroy(&app.curve)
	history_destroy(&app.history)
	results_destroy(app)
}

// Running the brush along the curve opens a stroke on the sphere under it, which the next
// frames lay; Validate keeps it as one undo step and the curve stays.
@(test)
brush_runs_along_a_curve :: proc(t: ^testing.T) {
	app: App
	defer path_scene_free(&app)
	sphere := path_scene(&app)
	before := slice.clone(object_mesh(sphere).positions[:])
	defer delete(before)
	steps := len(app.history.done)
	testing.expectf(t, curve_brush_refusal(&app) == "", "refused: %s", curve_brush_refusal(&app))
	testing.expect(t, command_run(&app, .Curve_Brush_Run), "Run brush did not run")
	testing.expect(t, app.stroke_edit.open, "the stroke is not open for editing")
	testing.expect_value(t, app.tool, Tool.Brush)
	testing.expect(t, selected_object(&app) == sphere, "the sphere is not selected")
	for _ in 0 ..< 10 do _ = sculpt_frame(&app, {size = {1000, 800}, mouse_pos = {10, 10}, hovered = true})
	stroke_edit_validate(&app)
	moved: f32
	for p, i in object_mesh(sphere).positions do moved += linalg.length(p - before[i])
	testing.expectf(t, moved > 0.01, "the surface moved %v", moved)
	testing.expect_value(t, len(app.history.done), steps + 1)
	testing.expect_value(t, len(app.scene.objects), 2)
	testing.expect_value(t, app.curve.brush_runs, 1)
}

// Brushes that hold what they move have no path to follow.
@(test)
grab_brush_refuses_a_path :: proc(t: ^testing.T) {
	app: App
	defer path_scene_free(&app)
	_ = path_scene(&app)
	app.brush.kind = .Grab
	testing.expect(t, curve_brush_refusal(&app) != "")
	testing.expect(t, !command_enabled(&app, .Curve_Brush_Run))
}
