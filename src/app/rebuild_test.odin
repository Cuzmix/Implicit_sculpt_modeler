package main

import "core:math"
import "core:testing"

import "../geom"
import "../sculpt"

@(private = "file")
rebuild_app :: proc(app: ^App) -> ^Object {
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	app.ui.rebuild_goal, app.ui.rebuild_even, app.ui.retopo_quads = .Even, 2000, 500
	return obj
}

@(private = "file")
rebuild_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	rebuild_preview_destroy(&app.rebuild)
}

// The checker shows while Density is held and a moment after, as the remesh's own
// lattice; never for Fewer, during a stroke, in a studio render or on a live boolean.
@(test)
rebuild_preview_shows_the_remesh_lattice :: proc(t: ^testing.T) {
	app: App
	defer rebuild_free(&app)
	obj := rebuild_app(&app)
	testing.expect_value(t, rebuild_preview_frame(&app), [4]f32{})
	rebuild_preview_hold(&app)
	checker := rebuild_preview_frame(&app)
	area, bounds := geom.mesh_area_bounds(object_mesh(obj)^)
	h, origin, _ := geom.remesh_lattice(area, bounds, 2000)
	testing.expect_value(t, checker, [4]f32{origin.x, origin.y, origin.z, h})
	testing.expect(t, app.rebuild.shown)
	// Quads: the mean quad's side.
	app.ui.rebuild_goal = .Quads
	testing.expect_value(t, rebuild_preview_frame(&app).w, f32(math.sqrt(area / 500)))
	app.ui.rebuild_goal = .Fewer
	testing.expect_value(t, rebuild_preview_frame(&app), [4]f32{})
	app.ui.rebuild_goal = .Even
	// The studio render shows it too.
	app.studio_on = true
	testing.expect(t, rebuild_preview_frame(&app) != {})
	app.studio_on = false
	app.ui.boolean.shown = true
	testing.expect_value(t, rebuild_preview_frame(&app), [4]f32{})
	app.ui.boolean.shown = false
	testing.expect(t, rebuild_preview_frame(&app) != {})
	// Let go: it stays REBUILD_PREVIEW_HOLD seconds.
	app.kit.ctx.time += REBUILD_PREVIEW_HOLD - 0.1
	testing.expect(t, rebuild_preview_frame(&app) != {})
	app.kit.ctx.time += 0.2
	testing.expect_value(t, rebuild_preview_frame(&app), [4]f32{})
	// A stroke ends it at once.
	rebuild_preview_hold(&app)
	app.stroke.active = true
	testing.expect_value(t, rebuild_preview_frame(&app), [4]f32{})
	testing.expect_value(t, app.rebuild.until, 0)
}

// The area is measured once per mesh version, again when the buffers change.
@(test)
rebuild_measures_once_per_mesh :: proc(t: ^testing.T) {
	app: App
	defer rebuild_free(&app)
	obj := rebuild_app(&app)
	app.rebuild.pinned = true
	_ = rebuild_preview_frame(&app)
	testing.expect(t, app.rebuild.measured)
	app.rebuild.area = -1 // a re-measure would put it back
	_ = rebuild_preview_frame(&app)
	testing.expect_value(t, app.rebuild.area, -1)
	obj.gpu[obj.levels.current].version += 1
	_ = rebuild_preview_frame(&app)
	testing.expect(t, app.rebuild.area > 0)
}

// Apply runs the goal's operation at its density.
@(test)
rebuild_runs_the_goal :: proc(t: ^testing.T) {
	app: App
	app.ui.rebuild_even, app.ui.rebuild_fewer, app.ui.retopo_quads, app.ui.retopo_engine = 300_000, 20_000, 900, .Own
	wants := [Rebuild_Goal]Scene_Command {
		.Even  = {kind = .Remesh, vertices = 300_000},
		.Fewer = {kind = .Decimate, vertices = 20_000},
		.Quads = {kind = .Retopo, vertices = 900, engine = .Own},
	}
	for goal in Rebuild_Goal {
		app.ui.rebuild_goal = goal
		rebuild_command(&app)
		testing.expect_value(t, app.ui.scene_command, wants[goal])
	}
	testing.expect_value(t, rebuild_count(10), REBUILD_MIN_VERTICES)
	testing.expect_value(t, rebuild_count(1 << 30), REBUILD_MAX_VERTICES)
}
