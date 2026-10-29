package main

import "core:strings"
import "core:testing"

// Voxel clay under a brush that needs a mesh is offered Convert to mesh, a voxel brush or
// the Move tool fits it; a mesh in Model with the Model tool is offered a cage; nothing
// selected always fits. The mesh-only commands are dimmed on clay with the reason why.
@(test)
offers_make_the_selection_fit :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	app.kit.spaces.current, app.tool, app.brush.kind = .Sculpt, .Brush, .Crease
	fits, _ := space_fit(&app)
	testing.expect(t, fits)
	vp: Voxel_Part
	objs[0].voxel = &vp
	defer objs[0].voxel = nil
	fits2, offer := space_fit(&app)
	testing.expect(t, !fits2)
	testing.expect_value(t, offer.fix, Command_Id.Convert_To_Mesh)
	testing.expect(t, strings.contains(offer.needs, "needs a mesh"))
	app.brush.kind = .Clay
	fits3, _ := space_fit(&app)
	testing.expect(t, fits3)
	app.brush.kind, app.tool = .Crease, .Move
	fits4, _ := space_fit(&app)
	testing.expect(t, fits4)
	testing.expect(t, !command_enabled(&app, .Remesh))
	testing.expect(t, strings.contains(command_reason(&app, .Remesh), "voxel clay"))
	testing.expect_value(t, command_reason(&app, .Frame_All), "")
	objs[0].voxel = nil
	testing.expect(t, command_enabled(&app, .Remesh))
	testing.expect_value(t, command_reason(&app, .Remesh), "")
	app.kit.spaces.current, app.tool = .Model, .Model
	fits5, model := space_fit(&app)
	testing.expect(t, !fits5)
	testing.expect(t, model.fix == .Retopologize || model.fix == .Edit_Cage)
	app.kit.spaces.current = .Render
	fits6, _ := space_fit(&app)
	testing.expect(t, fits6)
	app.scene.selected = -1
	app.kit.spaces.current = .Model
	fits7, _ := space_fit(&app)
	testing.expect(t, fits7)
	free_all(context.temp_allocator)
}
