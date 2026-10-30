package main

import "core:strings"
import "core:testing"

import "../geom"
import "../sculpt"

// Each format runs its own command, so the sheet changes nothing a file holds: the mesh
// formats are the mesh export limited to one filter, the others their own commands.
@(test)
export_formats_run_their_own_commands :: proc(t: ^testing.T) {
	testing.expect_value(t, export_command(.Scene), Command_Id.Save_Scene_As)
	testing.expect_value(t, export_command(.Scene, copy = true), Command_Id.Save_Scene_Copy)
	testing.expect_value(t, export_command(.Screenshot), Command_Id.Screenshot)
	testing.expect_value(t, export_command(.Turntable), Command_Id.Record_Turntable)
	testing.expect_value(t, export_command(.Print), Command_Id.Export_Print)
	testing.expect_value(t, export_command(.Print_OBJ), Command_Id.Export_Print)
	testing.expect_value(t, export_command(.Link), Command_Id.Send_To_Blender)
	testing.expect_value(t, export_command(.Print_3MF), Command_Id.Export_Print)
	for f in Export_Format {
		file, print := export_print_file(f)
		testing.expectf(t, print == (export_command(f) == .Export_Print), "%v", f)
		if print do testing.expect_value(t, export_file_name(&App{}, f), strings.concatenate({"Untitled", PRINT_FILE_SUFFIX[file]}, context.temp_allocator))
	}
	for f in Export_Format {
		filter, mesh := export_filter(f)
		testing.expectf(t, mesh == (export_command(f) == .Export_Mesh), "%v", f)
		// The filter's suffix is the one the format's row shows.
		if mesh do testing.expect_value(t, export_suffix(filter), EXPORT_FORMAT_DETAIL[f])
	}
}

// The foot's file name follows the scene's and the format's suffix, and its size estimate
// grows with the object and reads to a tenth below ten megabytes.
@(test)
export_names_and_sizes :: proc(t: ^testing.T) {
	a: App
	testing.expect_value(t, export_file_name(&a, .STL), "Untitled.stl")
	testing.expect_value(t, export_file_name(&a, .Print), "Untitled.stl")
	testing.expect_value(t, export_file_name(&a, .Print_OBJ), "Untitled.obj")
	a.scene_path = "/scenes/my head.sculpt"
	testing.expect_value(t, export_file_name(&a, .GLTF), "my head.glb")
	testing.expect_value(t, export_file_name(&a, .Scene), "my head.sculpt")
	testing.expect_value(t, export_bytes(&a, .STL), 0)

	obj := new(Object)
	defer free(obj)
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	defer sculpt.levels_destroy(&obj.levels)
	append(&a.scene.objects, obj)
	defer delete(a.scene.objects)
	a.scene.selected = 0
	tris := object_triangle_count(obj)
	testing.expect_value(t, export_bytes(&a, .STL), 84 + 50 * tris)
	testing.expect_value(t, export_bytes(&a, .Print), export_bytes(&a, .STL))
	testing.expect_value(t, export_bytes(&a, .Scene), 0)
	testing.expect_value(t, export_bytes(&a, .Screenshot), 0)

	testing.expect_value(t, export_size_label(100), "1 KB")
	testing.expect_value(t, export_size_label(5_000_084), "4.8 MB")
	testing.expect_value(t, export_size_label(50 << 20), "50 MB")
}

// Lens's menu keeps one Export... row: the formats' own commands are found in it, and
// Send to Blender and Export workspace moved to the menus they belong with.
@(test)
export_commands_live_in_the_sheet :: proc(t: ^testing.T) {
	testing.expect_value(t, LENS_MENU_PLACE[.Export_Sheet], Lens_Submenu.Main)
	for id in ([]Command_Id{.Export_Mesh, .Screenshot, .Record_Turntable, .Export_Print}) {
		testing.expectf(t, LENS_MENU_PLACE[id] == .Export, "%v", id)
	}
	testing.expect_value(t, LENS_MENU_PLACE[.Send_To_Blender], Lens_Submenu.More)
	testing.expect_value(t, LENS_MENU_PLACE[.Workspace_Export], Lens_Submenu.Workspaces)
}

// Every preset offers formats that belong to it, and every format but the pictures'
// own is in exactly the presets that name it; a format from a settings file before the
// presets settles into the first preset that offers it.
@(test)
export_presets_hold_their_formats :: proc(t: ^testing.T) {
	for p in Export_Preset {
		testing.expectf(t, len(export_preset_formats(p)) > 0, "%v offers nothing", p)
	}
	for f in Export_Format {
		held := false
		for p in Export_Preset do held ||= export_preset_has(p, f)
		testing.expectf(t, held || (f == .Link && !LINK_AVAILABLE), "no preset offers %v", f)
	}
	s := Export_Sheet{preset = .Print, format = .STL}
	export_settle(&s)
	testing.expect_value(t, s.preset, Export_Preset.Formats)
	s = {preset = .Print, format = .USD}
	export_settle(&s)
	testing.expect_value(t, s.preset, Export_Preset.Blender)
	s = {preset = .Print, format = .Print}
	export_settle(&s)
	testing.expect_value(t, s.preset, Export_Preset.Print)
}

// A preset comes back on the format it had, and on its first before it had one; the
// head names what ran last.
@(test)
export_presets_remember_their_format :: proc(t: ^testing.T) {
	s := Export_Sheet{preset = .Print, format = .Print}
	s.format = .Print_OBJ
	export_preset_pick(&s, .Game)
	testing.expect_value(t, s.format, Export_Format.GLTF)
	export_preset_pick(&s, .Picture)
	testing.expect_value(t, s.format, Export_Format.Screenshot)
	export_preset_pick(&s, .Print)
	testing.expect_value(t, s.format, Export_Format.Print_OBJ)
	testing.expect_value(t, export_last_label(.Game, .GLTF), "Last time: glTF for the game engine")
	testing.expect_value(t, export_last_label(.Print, .Print), "Last time: STL for 3D printing")
	testing.expect_value(t, export_last_label(.Formats, .Scene), "Last time: Sculpt scene")
	free_all(context.temp_allocator)
}
