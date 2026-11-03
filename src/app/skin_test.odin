package main

import "core:testing"

import "../geom"
import "../sculpt"

// A selected sphere with no GPU buffers: adding a skin and routing strokes need none.
@(private = "file")
skin_object :: proc(app: ^App) -> ^Object {
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	return obj
}

@(private = "file")
skin_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	results_destroy(app)
}

// The Detail skin command adds, changes and takes off the skin as undo steps; while there
// is one, the skin brushes go into it as Detail goes to says, the rest move the mesh, and
// the commands that would change the triangles under it are refused.
@(test)
detail_skin_routes_strokes_and_refuses_subdividing :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	obj := skin_object(app)
	defer skin_scene_free(app)
	testing.expect(t, !stroke_to_skin(app, obj, .Draw), "a stroke went to a skin before there was one")
	testing.expect(t, command_enabled(app, .Subdivide))
	testing.expect(t, !command_enabled(app, .Detail_Skin, 0), "Off is offered with no skin")
	testing.expect(t, !command_enabled(app, .Skin_Apply), "Apply is offered with no skin")
	testing.expect(t, command_run(app, .Detail_Skin, 3))
	sk := object_skin(obj)
	testing.expect(t, sk != nil && sk.segments == SKIN_SEGMENTS[3])
	testing.expect(t, command_checked(app, .Detail_Skin, 3))
	// Apply is offered once there is a skin on the top level.
	testing.expect(t, command_enabled(app, .Skin_Apply))
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect(t, !command_enabled(app, .Subdivide), "Subdivide is offered under a skin")
	testing.expect(t, !command_enabled(app, .Dyntopo_Toggle), "dynamic topology is offered under a skin")
	testing.expect(t, command_reason(app, .Subdivide) != "")
	testing.expect(t, stroke_to_skin(app, obj, .Draw))
	testing.expect(t, !stroke_to_skin(app, obj, .Grab), "Grab went to the skin")
	app.brush.detail_to[.Draw] = .Mesh
	testing.expect(t, !stroke_to_skin(app, obj, .Draw), "Mesh went to the skin")
	testing.expect(t, stroke_to_skin(app, obj, .Clay), "Draw's setting reached Clay")
	// Skin refuses while a layer records, which takes vertex moves only; Auto moves the mesh.
	app.brush.detail_to[.Draw] = .Skin
	testing.expect(t, skin_stroke_allowed(app, obj, .Draw, false))
	_ = sculpt.sculptor_layer_add(object_sculptor(obj))
	testing.expect(t, !skin_stroke_allowed(app, obj, .Draw, false), "Skin went ahead while a layer records")
	testing.expect(t, !stroke_to_skin(app, obj, .Clay), "Auto went to the skin while a layer records")
	testing.expect(t, command_run(app, .Detail_Skin, 0))
	testing.expect(t, object_skin(obj) == nil)
	testing.expect(t, !skin_stroke_allowed(app, obj, .Draw, false), "Skin went ahead with no skin")
	testing.expect(t, command_enabled(app, .Subdivide))
}

// A fine dab on a skinless object adds a skin, sized to the dab, as an undo step of its
// own; a coarse one, a brush that moves the mesh, the switch off or a skin taken off by
// hand add none.
@(test)
detail_skin_adds_itself_for_fine_dabs :: proc(t: ^testing.T) {
	testing.expect_value(t, skin_auto_segments(1000, 1, 2), 0)
	testing.expect_value(t, skin_auto_segments(1000, 1, 0.9), 4)
	testing.expect_value(t, skin_auto_segments(1000, 1, 0.3), 8)
	testing.expect_value(t, skin_auto_segments(1000, 1, 0.01), 16)
	// Ten million triangles: 16 segments would take far past the limit, so fewer.
	testing.expect(t, skin_auto_segments(10_000_000, 1, 0.01) < 16, "a skin past the memory limit")

	app := new(App)
	defer free(app)
	obj := skin_object(app)
	defer skin_scene_free(app)
	app.skin_auto = true
	testing.expect(t, !skin_auto_add(app, obj, .Draw, 10), "a dab wider than the mesh added a skin")
	testing.expect(t, !skin_auto_add(app, obj, .Grab, 0.01), "Grab added a skin")
	app.brush.detail_to[.Draw] = .Mesh
	testing.expect(t, !skin_auto_add(app, obj, .Draw, 0.01), "Detail goes to Mesh added a skin")
	app.brush.detail_to[.Draw] = .Auto
	testing.expect(t, skin_auto_add(app, obj, .Draw, 0.01), "a fine dab added no skin")
	testing.expect(t, object_skin(obj) != nil)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect(t, !skin_auto_add(app, obj, .Draw, 0.01), "a second skin was added")
	// Off by hand: none comes back by itself.
	testing.expect(t, command_run(app, .Detail_Skin, 0))
	testing.expect(t, !skin_auto_add(app, obj, .Draw, 0.01), "a skin taken off by hand came back")
	obj.skin_declined = false
	app.skin_auto = false
	testing.expect(t, !skin_auto_add(app, obj, .Draw, 0.01), "the switch off added a skin")
}

// A rebuilt mesh's skin holds at least the old surface's samples, fewer segments only past
// the memory limit; Squeeze is offered on dense sculpts only.
@(test)
skin_carry_segments_keep_the_samples :: proc(t: ^testing.T) {
	// 198k vertices onto 48k triangles: 2.9 wanted, so 4 (2 would hold fewer).
	testing.expect_value(t, skin_carry_segments(48_000, 198_000), 4)
	testing.expect_value(t, skin_carry_segments(10_000, 10_000), 2)
	testing.expect_value(t, skin_carry_segments(1_000, 100_000), 16)
	testing.expect_value(t, skin_carry_segments(0, 100), 0)
	// Twenty million triangles: even 2 segments' skin passes the limit.
	testing.expect_value(t, skin_carry_segments(80_000_000, 100_000_000), 0)

	app := new(App)
	defer free(app)
	obj := skin_object(app)
	defer skin_scene_free(app)
	testing.expect(t, skin_squeeze_refusal(obj) != "", "a 162-vertex sphere could be squeezed")
	testing.expect(t, !command_enabled(app, .Skin_Squeeze, 1))
}
