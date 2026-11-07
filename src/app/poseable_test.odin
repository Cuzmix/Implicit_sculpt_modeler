package main

import "core:strings"
import "core:testing"

import "../geom"
import "../sculpt"

// Poseable symmetry pairs the selected sphere between strokes once a plane is on, says
// so, and does not pair it again until the plane changes; the brush carries it only with
// a plane on.
@(test)
poseable_pairs_the_selected_object :: proc(t: ^testing.T) {
	app: App
	defer {
		for obj in app.scene.objects {
			sculpt.levels_destroy(&obj.levels)
			free(obj)
		}
		delete(app.scene.objects)
		results_destroy(&app)
	}
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	s := object_sculptor(obj)

	poseable_toggle(&app)
	poseable_frame(&app)
	testing.expect(t, !sculpt.sculptor_mirror_ready(s), "paired with no plane on")
	testing.expect(t, !brush_symmetry(&app, obj).poseable, "the brush mirrors by topology with no plane on")

	app.brush.symmetry = {.X}
	poseable_frame(&app)
	testing.expect(t, sculpt.sculptor_mirror_ready(s) && s.mirror_axis == .X, "not paired across X")
	testing.expect_value(t, s.mirror_paired, len(s.mesh.positions))
	testing.expect(t, strings.contains(app.result.text, "paired all"), app.result.text)
	testing.expect(t, brush_symmetry(&app, obj).poseable)

	app.brush.symmetry = {.Z}
	poseable_frame(&app)
	testing.expect(t, sculpt.sculptor_mirror_ready(s) && s.mirror_axis == .Z, "not paired again across Z")
	poseable_toggle(&app)
	testing.expect(t, !brush_symmetry(&app, obj).poseable)
}
