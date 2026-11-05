package main

import "core:testing"

// Automatic follows the device: about 12M on an 8 GB iPad, Rebuild's largest on 16 GB and
// when the device does not say.
@(test)
automatic_mesh_size_follows_the_device :: proc(t: ^testing.T) {
	testing.expect_value(t, mesh_remesh_automatic(8 * GB), 12_000_000)
	testing.expect_value(t, mesh_remesh_automatic(16 * GB), REBUILD_MAX_VERTICES)
	testing.expect_value(t, mesh_remesh_automatic(0), REBUILD_MAX_VERTICES)
	testing.expect_value(t, history_swap_automatic(8 * GB), 1 * GB)
	testing.expect_value(t, history_swap_automatic(32 * GB), 3 * GB)
	testing.expect_value(t, history_level_automatic(8 * GB), 256 << 20)
	testing.expect_value(t, history_level_automatic(16 * GB), 512 << 20)
}

// A remesh past Largest remesh is made at it, by count or at a cell size widened to it.
@(test)
a_remesh_past_the_limit_is_held_to_it :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	_ = tree_scene(&app)
	app.remesh_most = 1_000_000
	cmd := Scene_Command{kind = .Remesh, vertices = 2_000_000}
	mesh_remesh_limit(&app, &cmd)
	testing.expect_value(t, cmd.vertices, 1_000_000)
	small := Scene_Command{kind = .Remesh, vertices = 500_000}
	mesh_remesh_limit(&app, &small)
	testing.expect_value(t, small.vertices, 500_000)
	cell := Scene_Command{kind = .Remesh}
	cell.remesh.cell = 0.001
	mesh_remesh_limit(&app, &cell)
	made := memory_remesh_count(&app, selected_object(&app), cell)
	testing.expect(t, made <= 1_000_000 && made > 900_000)
	testing.expect_value(t, app.mesh_limited, 2)
}

@(test)
largest_subdivision_level_counts_vertices :: proc(t: ^testing.T) {
	app: App
	app.subdivide_most = 1_000_000
	testing.expect(t, mesh_subdivide_fits(&app, 900_000, 1 << 40))
	testing.expect(t, !mesh_subdivide_fits(&app, 2_000_000, 0))
	app.subdivide_most = 0
	testing.expect(t, mesh_subdivide_fits(&app, 2_000_000, 1 << 20))
	testing.expect(t, !mesh_subdivide_fits(&app, 2_000_000, mesh_bytes_most() + 1))
}

// The system's low-memory warning drops the older rebuild copies at the next frame, and
// keeps the newest step for the next Undo.
@(test)
a_low_memory_warning_drops_old_rebuild_copies :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	for i in 0 ..< 3 do history_record_swap(&app, objs[i].id, history_snapshot(&app, objs[i], "remesh"))
	testing.expect_value(t, history_step_count(app.history.done[:]), 3)
	app.memory_low = true
	history_cap(&app)
	testing.expect(t, !app.memory_low)
	testing.expect_value(t, app.memory_low_warnings, 1)
	testing.expect_value(t, history_step_count(app.history.done[:]), 1)
	testing.expect_value(t, app.history.done[0].id, objs[2].id)
}
