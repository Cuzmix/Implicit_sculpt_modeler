package main

import "core:slice"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

// A selected sphere at the world's middle with no GPU buffers, the Draw brush held.
@(private = "file")
stroke_sphere :: proc(app: ^App) -> ^Object {
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(4), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	app.camera = camera.orbit_default()
	app.tool = .Brush
	app.brush.kind, app.brush.radius_px = .Draw, 60
	app.brush.strengths[.Draw], app.brush.strengths[.Smooth] = 0.5, 0.5
	return obj
}

@(private = "file")
stroke_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	delete(app.stroke.pending)
	history_destroy(&app.history)
	results_destroy(app)
}

@(private = "file")
STROKE_SIZE :: [2]f32{1000, 800}

// A stroke along `path`, one sample a frame, with Shift (smooth) held from sample
// `shift_from` on, then the release.
@(private = "file")
stroke_along :: proc(app: ^App, path: [][2]f32, shift_from: int) {
	for p, i in path {
		samples := []Input_Sample{{pos = p, pressure = 1, kind = .Press if i == 0 else .Move}}
		_ = sculpt_frame(app, {size = STROKE_SIZE, mouse_pos = p, hovered = true, primary = true, press = i == 0, smooth = i >= shift_from, samples = samples})
	}
	_ = sculpt_frame(app, {size = STROKE_SIZE, mouse_pos = path[len(path) - 1], hovered = true})
}

// The brush a stroke uses is the one its press chose: Shift pressed mid-stroke leaves a
// Draw stroke drawing (the same mesh as without it), while Shift at the press smooths.
@(test)
stroke_keeps_the_brush_its_press_chose :: proc(t: ^testing.T) {
	path := [?][2]f32{{440, 380}, {470, 390}, {500, 400}, {530, 410}, {560, 420}}
	plain, late, early: App
	defer stroke_scene_free(&plain)
	defer stroke_scene_free(&late)
	defer stroke_scene_free(&early)
	a, b, c := stroke_sphere(&plain), stroke_sphere(&late), stroke_sphere(&early)
	stroke_along(&plain, path[:], len(path))
	stroke_along(&late, path[:], 2)
	stroke_along(&early, path[:], 0)
	pa, pb, pc := object_sculptor(a).mesh.positions[:], object_sculptor(b).mesh.positions[:], object_sculptor(c).mesh.positions[:]
	testing.expect_value(t, len(plain.history.done), 1)
	testing.expect(t, slice.equal(pa, pb))
	testing.expect_value(t, late.history.done[0].what, "Draw")
	testing.expect_value(t, early.history.done[0].what, "Smooth")
	testing.expect(t, !slice.equal(pa, pc))
}
