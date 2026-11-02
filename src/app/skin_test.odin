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
	testing.expect(t, command_run(app, .Detail_Skin, 3))
	sk := object_skin(obj)
	testing.expect(t, sk != nil && sk.segments == SKIN_SEGMENTS[3])
	testing.expect(t, command_checked(app, .Detail_Skin, 3))
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
