package main

import "core:testing"

import "../geom"
import "../sculpt"

// One small selected object, enough for the check to read its counts; the step's own
// count is what makes it heavy.
@(private = "file")
check_scene :: proc(app: ^App) -> ^Object {
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	return obj
}

@(private = "file")
check_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	app.history.swap_bytes = 0
	history_destroy(&app.history)
	results_destroy(app)
}

// A remesh to 2M needs about 470 MB. With 400 MB left and 200 MB in the history it fits
// once the history goes, so the popup asks, offering no smaller count (2M itself fits).
@(test)
a_remesh_that_fits_after_freeing_asks :: proc(t: ^testing.T) {
	app: App
	defer check_scene_free(&app)
	_ = check_scene(&app)
	app.memory_free_test = 400
	app.history.swap_bytes = 200 << 20
	testing.expect(t, memory_check_holds(&app, {kind = .Remesh, vertices = 2_000_000}))
	a := app.memory_ask
	testing.expect(t, a.on && a.fits)
	testing.expect_value(t, a.smaller, 0)
	testing.expect_value(t, a.asks, 1)
}

// With 100 MB left and no history it cannot fit: the popup offers the largest count
// that does, rounded to two figures.
@(test)
a_remesh_too_big_offers_a_smaller_count :: proc(t: ^testing.T) {
	app: App
	defer check_scene_free(&app)
	obj := check_scene(&app)
	app.memory_free_test = 100
	cmd := Scene_Command{kind = .Remesh, vertices = 2_000_000}
	testing.expect(t, memory_check_holds(&app, cmd))
	a := app.memory_ask
	testing.expect(t, a.on && !a.fits)
	_, fixed, per_vertex := memory_need(&app, obj, cmd)
	want := memory_round_down((int(MEMORY_MARGIN * f64(100 << 20)) - fixed) / per_vertex)
	testing.expect_value(t, a.smaller, want)
	testing.expect(t, a.smaller > MEMORY_SMALLEST && a.smaller < cmd.vertices)
	// The smaller count fits what is left.
	smaller, _, _ := memory_need(&app, obj, {kind = .Remesh, vertices = a.smaller})
	testing.expect(t, smaller <= int(MEMORY_MARGIN * f64(100 << 20)))
}

// A step that fits, one already answered and one Adjust last runs again go on at once.
@(test)
the_check_lets_steps_through :: proc(t: ^testing.T) {
	app: App
	defer check_scene_free(&app)
	_ = check_scene(&app)
	app.memory_free_test = 100
	testing.expect(t, !memory_check_holds(&app, {kind = .Remesh, vertices = 10_000}))
	testing.expect(t, !memory_check_holds(&app, {kind = .Remesh, vertices = 2_000_000, checked = true}))
	testing.expect(t, !memory_check_holds(&app, {kind = .Remesh, vertices = 2_000_000, adjust = true}))
	testing.expect(t, !memory_check_holds(&app, {kind = .Decimate, vertices = 2_000_000}))
	testing.expect(t, !app.memory_ask.on)
}

// Free older history remembered: a step that fits once the history goes frees it and
// runs without asking; one that would not fit even then still asks.
@(test)
a_remembered_free_history_runs_without_asking :: proc(t: ^testing.T) {
	app: App
	defer check_scene_free(&app)
	_ = check_scene(&app)
	app.memory_short = .Free_History
	app.memory_free_test = 400
	app.history.swap_bytes = 200 << 20
	testing.expect(t, !memory_check_holds(&app, {kind = .Remesh, vertices = 2_000_000}))
	testing.expect_value(t, app.memory_ask.freed, 1)
	testing.expect(t, !app.memory_ask.on)
	app.memory_free_test = 100
	app.history.swap_bytes = 0
	testing.expect(t, memory_check_holds(&app, {kind = .Remesh, vertices = 2_000_000}))
	testing.expect(t, app.memory_ask.on && !app.memory_ask.fits)
}

@(test)
memory_counts_read_as_the_presets :: proc(t: ^testing.T) {
	testing.expect_value(t, memory_round_down(12_345_678), 12_000_000)
	testing.expect_value(t, memory_round_down(987), 980)
	testing.expect_value(t, memory_count_label(12_000_000), "12M")
	testing.expect_value(t, memory_count_label(1_300_000), "1.3M")
	testing.expect_value(t, memory_count_label(440_000), "440k")
}

// A remesh short of memory that letting its object go first makes fit goes on without
// asking, where it runs on its own thread (an early release, long_job.odin), and still
// asks where it runs at once, which keeps the object until it is done.
@(test)
a_remesh_that_fits_once_its_object_goes_does_not_ask :: proc(t: ^testing.T) {
	app: App
	defer check_scene_free(&app)
	obj := check_scene(&app)
	sculpt.levels_destroy(&obj.levels)
	sculpt.levels_init(&obj.levels, geom.icosphere(7), nil, 64)
	cmd := Scene_Command{kind = .Remesh, vertices = 500_000}
	need, _, _ := memory_need(&app, obj, cmd)
	gain := memory_release_gain(obj)
	testing.expect(t, gain > 0)
	// Between what fits with the object and what fits without it.
	app.memory_free_test = (int(f64(need) / MEMORY_MARGIN) - gain / 2) >> 20
	testing.expect(t, memory_short_for(&app, obj, cmd))
	testing.expect(t, memory_check_holds(&app, cmd), "a remesh run at once did not ask")
	app.memory_ask = {}
	app.long_job.allowed, app.long_job.forced = true, true
	testing.expect(t, !memory_check_holds(&app, cmd), "a remesh that fits once its object goes asked")
	testing.expect(t, !app.memory_ask.on)
}
