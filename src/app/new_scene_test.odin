package main

import "core:testing"

// A starter comes with as many levels as keep its base at the starter minimum, at most
// STARTER_LEVELS: none at the smallest size, three at 1M and above.
@(test)
starter_levels_keep_the_base_big_enough :: proc(t: ^testing.T) {
	testing.expect_value(t, starter_levels(40_962), 0)
	testing.expect_value(t, starter_levels(100_000), 1)
	testing.expect_value(t, starter_levels(500_000), 2)
	testing.expect_value(t, starter_levels(1_000_000), 3)
	testing.expect_value(t, starter_levels(25_000_000), 3)
}

// New scene starts over at once on a scene with nothing to lose; with work to lose the
// first run only arms that shape, a second run of it soon after goes ahead, and another
// shape or a late second run arms afresh.
@(test)
new_scene_asks_before_discarding_work :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	defer delete(app.history.done)
	app.kit.add_size = 2
	new_scene_run(&app, 1)
	testing.expect(t, app.ui.scene_command.kind == .New && app.ui.scene_command.shape == .Head)
	testing.expect_value(t, app.ui.scene_command.vertices, int(SPHERE_PRESETS[2].vertices))

	app.ui.scene_command = {}
	append(&app.history.done, History_Entry{})
	app.kit.ctx.time = 10
	new_scene_run(&app, 1)
	testing.expect(t, app.ui.scene_command.kind == .None && new_scene_armed(&app, 1))
	testing.expect(t, .Warning in app.result.flags)
	// Another shape arms that one instead.
	app.kit.ctx.time = 11
	new_scene_run(&app, 2)
	testing.expect(t, app.ui.scene_command.kind == .None && new_scene_armed(&app, 2) && !new_scene_armed(&app, 1))
	app.kit.ctx.time = 12
	new_scene_run(&app, 2)
	testing.expect(t, app.ui.scene_command.kind == .New && app.ui.scene_command.shape == .Bust && !new_scene_armed(&app, 2))

	// Too late: the second run arms again.
	app.ui.scene_command = {}
	new_scene_run(&app, 0)
	app.kit.ctx.time += NEW_SCENE_ARM_TIME + 1
	new_scene_run(&app, 0)
	testing.expect(t, app.ui.scene_command.kind == .None && new_scene_armed(&app, 0))
}
