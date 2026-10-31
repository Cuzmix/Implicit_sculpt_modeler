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
	app.ui.remesh_smooth, app.ui.remesh_keep_detail = 5, true
	app.ui.decimate_by, app.ui.decimate_percent, app.ui.decimate_keep_groups, app.ui.decimate_use_mask = .Percent, 10, true, true
	wants := [Rebuild_Goal]Scene_Command {
		.Even  = {kind = .Remesh, vertices = 300_000, remesh = {smooth = 5, keep_detail = true}},
		.Fewer = {kind = .Decimate, vertices = 20_000, decimate = {percent = 10, keep_groups = true, use_mask = true}},
		.Quads = {kind = .Retopo, vertices = 900, quad = {engine = .Own}},
	}
	for goal in Rebuild_Goal {
		app.ui.rebuild_goal = goal
		rebuild_command(&app)
		testing.expect_value(t, app.ui.scene_command, wants[goal])
	}
	testing.expect_value(t, rebuild_count(10), REBUILD_MIN_VERTICES)
	testing.expect_value(t, rebuild_count(1 << 30), REBUILD_MAX_VERTICES)
}

// A share of the object becomes a count of it as it is; a count stays.
@(test)
decimate_aims_for_a_share_or_a_count :: proc(t: ^testing.T) {
	testing.expect_value(t, decimate_target(100_000, 5_000, {percent = 20}), 20_000)
	testing.expect_value(t, decimate_target(100_000, 5_000, {}), 5_000)
	testing.expect_value(t, decimate_target(10, 5_000, {percent = 1}), 4)
	app: App
	app.ui.decimate_by, app.ui.decimate_percent = .Count, 30
	testing.expect_value(t, decimate_setup(&app).percent, 0)
	decimate_setup_set(&app, {percent = 25, keep_borders = true})
	testing.expect(t, app.ui.decimate_by == .Percent && app.ui.decimate_percent == 25 && app.ui.decimate_keep_borders && !app.ui.decimate_keep_paint)
}

// Polypaint follows the vertices that stay and polygroups the triangles, the line
// between the groups staying where it was.
@(test)
decimate_keeps_paint_and_groups :: proc(t: ^testing.T) {
	src: Decimate_Source
	src.mesh = geom.icosphere(5)
	defer decimate_source_free(&src)
	n := len(src.mesh.positions)
	src.color = make([]sculpt.Color, n)
	for &c, v in src.color do c = {255, 0, 0, 255} if src.mesh.positions[v].z > 0 else {0, 0, 255, 255}
	src.groups = make([]u16, len(src.mesh.indices) / 3)
	for &g, i in src.groups do g = 7 if src.mesh.positions[src.mesh.indices[3 * i]].x > 0 else 3
	src.mask = make([]u8, n)
	for &m, v in src.mask do m = 255 if src.mesh.positions[v].y > 0.5 else 0
	mesh, _, surface, built, _ := decimate_compute(src, 500, {keep_paint = true, keep_groups = true, keep_borders = true, use_mask = true}, nil)
	defer geom.mesh_destroy(&mesh)
	defer surface_free(&surface)
	if !testing.expect(t, built) do return
	testing.expect_value(t, len(surface.color), len(mesh.positions))
	testing.expect_value(t, len(surface.groups), len(mesh.indices) / 3)
	testing.expectf(t, abs(len(mesh.positions) - 500) < 60, "%d vertices", len(mesh.positions))
	for c, v in surface.color {
		want := sculpt.Color{255, 0, 0, 255} if mesh.positions[v].z > 0 else sculpt.Color{0, 0, 255, 255}
		if c != want {
			testing.expectf(t, false, "vertex %d at %v took %v", v, mesh.positions[v], c)
			break
		}
	}
	// Each triangle's group is the side of x = 0 it is on, give or take the zigzag of
	// the line, which runs through the old line's own vertices.
	wrong := 0
	for g, i in surface.groups {
		for k in 0 ..< 3 {
			x := mesh.positions[mesh.indices[3 * i + k]].x
			if abs(x) > 0.1 && (x > 0) != (g == 7) do wrong += 1
		}
	}
	testing.expectf(t, wrong == 0, "%d corners on the wrong side of their group", wrong)
	r := geom.mesh_check(mesh)
	testing.expectf(t, r.closed && r.degenerate_triangles == 0, "%v", r)
	// The masked cap keeps more of its vertices than the same cap below.
	top, bottom := 0, 0
	for p in mesh.positions {
		if p.y > 0.5 do top += 1
		if p.y < -0.5 do bottom += 1
	}
	testing.expectf(t, top > 2 * bottom, "masked %d, unmasked %d", top, bottom)
}

// Keep symmetry: a lopsided, painted, grouped sphere decimated across X through a centre
// off the origin comes out its own mirror image, closed, near the count asked, with its
// paint and groups carried on both sides and the result line saying so.
@(test)
decimate_keeps_symmetry :: proc(t: ^testing.T) {
	src: Decimate_Source
	src.mesh = geom.icosphere(5)
	defer decimate_source_free(&src)
	for &p in src.mesh.positions {
		if p.x > 0.4 do p.x *= 1.3
		p.x += 0.25
	}
	n := len(src.mesh.positions)
	src.color = make([]sculpt.Color, n)
	for &c, v in src.color do c = {255, 0, 0, 255} if src.mesh.positions[v].z > 0 else {0, 0, 255, 255}
	src.groups = make([]u16, len(src.mesh.indices) / 3)
	for &g, i in src.groups do g = 7 if src.mesh.positions[src.mesh.indices[3 * i]].y > 0 else 3
	setup := Decimate_Setup{keep_paint = true, keep_groups = true, keep_borders = true, mirror = {axes = {true, false, false}, center = {0.25, 0, 0}}}
	mesh, _, surface, built, unmirrored := decimate_compute(src, 1000, setup, nil)
	defer geom.mesh_destroy(&mesh)
	defer surface_free(&surface)
	if !testing.expect(t, built) do return
	testing.expect_value(t, unmirrored, "")
	testing.expectf(t, abs(len(mesh.positions) - 1000) < 120, "%d vertices", len(mesh.positions))
	testing.expect_value(t, len(surface.color), len(mesh.positions))
	testing.expect_value(t, len(surface.groups), len(mesh.indices) / 3)
	r := geom.mesh_check(mesh)
	testing.expectf(t, r.closed && r.non_manifold_edges == 0 && !r.inverted && r.degenerate_triangles == 0, "%v", r)
	unmatched, on := 0, 0
	for p in mesh.positions {
		if p.x == 0.25 do on += 1
		found := false
		for q in mesh.positions do if abs(q.x - (0.5 - p.x)) <= 1e-5 && q.y == p.y && q.z == p.z {
			found = true
			break
		}
		if !found do unmatched += 1
	}
	testing.expect_value(t, unmatched, 0)
	testing.expectf(t, on >= 8, "%d vertices on the plane", on)
	for c, v in surface.color {
		want := sculpt.Color{255, 0, 0, 255} if mesh.positions[v].z > 0 else sculpt.Color{0, 0, 255, 255}
		if abs(mesh.positions[v].z) > 0.05 && c != want {
			testing.expectf(t, false, "vertex %d at %v took %v", v, mesh.positions[v], c)
			break
		}
	}
	testing.expect_value(t, decimate_note(setup, unmirrored), ", mirrored across X")
	// An object the plane misses is decimated whole, and the line says why.
	setup.mirror.center.x = 5
	whole, _, whole_surface, whole_built, why := decimate_compute(src, 1000, setup, nil)
	defer geom.mesh_destroy(&whole)
	defer surface_free(&whole_surface)
	testing.expect(t, whole_built, "not decimated whole")
	testing.expect_value(t, why, "the object does not cross the plane")
}
