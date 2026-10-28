package main

import "core:testing"

import "../geom"

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

// Classic's six starts keep their numbers, so what names one by number still starts it;
// every start has a name of its own that reads back; Lens's Home shows each start once.
@(test)
new_scene_starts_keep_their_numbers_and_names :: proc(t: ^testing.T) {
	classic := [CLASSIC_NEW_SCENES]geom.Primitive{.Sphere, .Head, .Bust, .Figure, .Hand, .Creature}
	for shape, i in classic do testing.expect(t, NEW_SCENES[i].kind == .Mesh && NEW_SCENES[i].shape == shape)
	for _, i in NEW_SCENES {
		id, arg, ok := command_from_name(command_name(.New_Scene, i))
		testing.expectf(t, ok && id == .New_Scene && arg == i, "%d: %v %d %v", i, id, arg, ok)
	}
	testing.expect_value(t, command_name(.New_Scene, 7), "New_Scene:Plane")
	testing.expect_value(t, command_name(.New_Scene, 8), "New_Scene:Voxels")
	// A start-up script names them in lower case.
	s := script_parse("new_scene plane\nnew_scene empty", "test")
	defer script_destroy(&s)
	testing.expect(t, len(s.errors) == 0 && len(s.statements) == 2)
	testing.expect(t, s.statements[0].command == .New_Scene && s.statements[0].arg == 7)
	testing.expect_value(t, s.statements[1].arg, 9)
	shown: [len(NEW_SCENES)]int
	for i in LENS_HOME_STARTS do shown[i] += 1
	for i in LENS_HOME_MORE do shown[i] += 1
	for n, i in shown do testing.expectf(t, n == 1, "%s shows %d times", NEW_SCENES[i].name, n)
}

// A voxel block asks for a voxel object of the Add size's resolution, and an empty scene
// for no object.
@(test)
new_scene_voxel_block_and_empty :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	app.kit.add_size = 2
	new_scene_run(&app, 8)
	vertices := int(SPHERE_PRESETS[2].vertices)
	testing.expect(t, app.ui.scene_command.kind == .New && !app.ui.scene_command.on)
	testing.expect_value(t, app.ui.scene_command.voxels, voxel_resolution_for(vertices))
	new_scene_run(&app, 9)
	testing.expect(t, app.ui.scene_command.kind == .New && app.ui.scene_command.on && app.ui.scene_command.voxels == 0)
	new_scene_run(&app, 7)
	testing.expect(t, app.ui.scene_command.shape == .Plane && app.ui.scene_command.voxels == 0 && !app.ui.scene_command.on)
}
