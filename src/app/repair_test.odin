package main

import "core:testing"

import "../geom"
import "../sculpt"

// A hole's cap takes its border's colour and a polygroup after the highest; the kept
// triangles keep their own groups, and without groups the rest of the object is group 0.
@(test)
repair_surface_gives_caps_a_group_and_their_border_colour :: proc(t: ^testing.T) {
	m := geom.icosphere(3)
	// One triangle gone: a hole of three corners, capped by one triangle.
	holed: geom.Mesh
	append(&holed.positions, ..m.positions[:])
	resize(&holed.normals, len(holed.positions))
	append(&holed.indices, ..m.indices[3:])
	geom.mesh_destroy(&m)
	s: sculpt.Sculptor
	sculpt.sculptor_init(&s, &holed, nil, 64)
	defer {
		sculpt.sculptor_destroy(&s)
		geom.mesh_destroy(&holed)
	}
	testing.expect(t, sculpt.sculptor_paint_command(&s, .Fill, {200, 10, 10}))
	out, from, report, ok := geom.mesh_close_holes(holed, false, nil)
	defer {
		geom.mesh_destroy(&out)
		geom.repair_map_destroy(&from)
	}
	testing.expect(t, ok && report.closed == 1)
	surface := repair_surface(&s, from)
	defer {
		delete(surface.color)
		delete(surface.groups)
	}
	testing.expect_value(t, len(surface.color), len(out.positions))
	for c in surface.color do testing.expect_value(t, c, s.color[0])
	testing.expect_value(t, len(surface.groups), len(out.indices) / 3)
	last := len(surface.groups) - 1
	for g, i in surface.groups do testing.expect_value(t, g, 1 if i == last else 0)

	// With groups, the cap's is after the highest.
	testing.expect(t, sculpt.sculptor_group_command(&s, .Creases, 1))
	grouped := repair_surface(&s, from)
	defer {
		delete(grouped.color)
		delete(grouped.groups)
	}
	highest: u16
	for g in sculpt.sculptor_groups(&s) do highest = max(highest, g)
	testing.expect_value(t, grouped.groups[last], highest + 1)
	free_all(context.temp_allocator)
}

// Each repair is a command whose home is Modify topology, and Delete hidden asks for a
// hidden part.
@(test)
repair_commands_live_in_modify_topology :: proc(t: ^testing.T) {
	for id in ([?]Command_Id{.Close_Holes, .Delete_Hidden, .Weld_Points, .Check_Mesh, .Fix_Mesh, .Delete_Half}) {
		home, homed := COMMAND_HOMES[id].?
		testing.expectf(t, homed && home == .Mirror, "%v lives in %v", id, COMMAND_HOMES[id])
	}
	app: App
	obj := new(Object)
	defer free(obj)
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	defer sculpt.levels_destroy(&obj.levels)
	append(&app.scene.objects, obj)
	defer delete(app.scene.objects)
	app.scene.selected = 0
	testing.expect(t, command_enabled(&app, .Close_Holes, 0))
	testing.expect(t, !command_enabled(&app, .Delete_Hidden, 0))
	app.ui.weld_distance = 0.002
	_ = command_run(&app, .Weld_Points, 0)
	cmd := app.ui.scene_command
	testing.expect(t, cmd.kind == .Repair && cmd.repair == .Weld_Points && cmd.distance == 0.002)
	app.ui.mirror_axis, app.ui.mirror_negative = 2, true
	_ = command_run(&app, .Delete_Half, 0)
	cmd = app.ui.scene_command
	testing.expect(t, cmd.repair == .Delete_Half && cmd.axis == 2 && !cmd.on)
}
