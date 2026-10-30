package main

import "core:math"
import "core:testing"

import "../geom"
import "../jobs"

// A solid ball's thinnest wall is its width across; a hollow one's, the shell between
// its two surfaces, whichever way its faces turn.
@(test)
print_wall_measures_the_shell :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 2)
	defer jobs.pool_destroy(&pool)

	ball := geom.icosphere(3)
	defer geom.mesh_destroy(&ball)
	solid := print_check_compute(ball, nil, &pool).wall
	testing.expectf(t, math.abs(solid - 2) < 0.02, "a ball of radius 1 has a wall of %v", solid)

	// The same ball with a smaller one inside, turned inward: a shell 0.1 thick.
	shell := geom.icosphere(3)
	defer geom.mesh_destroy(&shell)
	inner := geom.icosphere(3, 0.9)
	defer geom.mesh_destroy(&inner)
	base := u32(len(shell.positions))
	append(&shell.positions, ..inner.positions[:])
	append(&shell.normals, ..inner.normals[:])
	for k := 0; k < len(inner.indices); k += 3 {
		append(&shell.indices, base + inner.indices[k], base + inner.indices[k + 2], base + inner.indices[k + 1])
	}
	wall := print_check_compute(shell, nil, &pool).wall
	testing.expectf(t, math.abs(wall - 0.1) < 0.01, "a shell 0.1 thick has a wall of %v", wall)

	// Turned inside out, the rays go the other way and find the same shell.
	for k := 0; k < len(shell.indices); k += 3 do shell.indices[k + 1], shell.indices[k + 2] = shell.indices[k + 2], shell.indices[k + 1]
	turned := print_check_compute(shell, nil, &pool).wall
	testing.expectf(t, math.abs(turned - 0.1) < 0.01, "the shell inside out has a wall of %v", turned)
	free_all(context.temp_allocator)
}

// A print fits the bed as it stands or turned a quarter round, never taller than it.
@(test)
print_fits_the_bed_turned :: proc(t: ^testing.T) {
	bed := [3]f32{220, 200, 250}
	testing.expect(t, print_fits_bed({210, 240, 190}, bed))
	testing.expect(t, print_fits_bed({190, 240, 210}, bed), "turned a quarter round, it fits")
	testing.expect(t, !print_fits_bed({210, 260, 190}, bed), "too tall")
	testing.expect(t, !print_fits_bed({230, 100, 230}, bed), "too wide both ways")
}

// The checks run once for each state of the object's surface, and again after it changes.
@(test)
print_checks_run_once_a_change :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	jobs.pool_init(&app.pool, 2)
	defer jobs.pool_destroy(&app.pool)
	objs := tree_scene(&app)
	obj := objs[0]
	c := print_checks_update(&app, obj)
	if !testing.expect(t, c != nil, "a small sphere was not checked at once") do return
	testing.expect_value(t, app.print_checks.runs, 1)
	testing.expect_value(t, c.holes, 0)
	testing.expect_value(t, c.open_edges, 0)
	testing.expect(t, c.wall > 0, "a closed sphere has a wall")
	_ = print_checks_update(&app, obj)
	testing.expect_value(t, app.print_checks.runs, 1)
	obj.gpu[obj.levels.current].version += 1
	_ = print_checks_update(&app, obj)
	testing.expect_value(t, app.print_checks.runs, 2)
	free_all(context.temp_allocator)
}
