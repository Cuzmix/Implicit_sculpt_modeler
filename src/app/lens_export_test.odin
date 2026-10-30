package main

import "core:math"
import "core:os"
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

// Decimate for this file only writes a copy with about the triangles asked, whose paint
// stayed on the vertices it was on, and leaves the object as it was; a print of several
// objects shares the triangles among them; a shape key keeps the vertices still there,
// by their new numbers.
@(test)
export_decimates_a_copy :: proc(t: ^testing.T) {
	FOLDER :: "build/export_decimate_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	path := strings.clone(FOLDER + "fewer.obj")
	defer delete(path)

	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	obj := objs[0]
	lv := sculpt.levels_current(&obj.levels)
	before := len(lv.mesh.indices) / 3
	// Red paint above the middle, blue below.
	lv.sculptor.color = make([]sculpt.Color, len(lv.mesh.positions))
	for p, v in lv.mesh.positions do lv.sculptor.color[v] = {255, 0, 0, 255} if p.y > 0 else {0, 0, 255, 255}
	if !testing.expect(t, object_export(&app, obj, path, once = {decimate = 100})) do return
	testing.expect_value(t, len(lv.mesh.indices) / 3, before)
	testing.expect(t, app.export_decimated > 0 && app.export_decimated <= 105, "not decimated to about 100")

	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if !testing.expect(t, err == nil) do return
	colors: [dynamic]geom.Vertex_Color
	defer delete(colors)
	m, read_err, _ := geom.mesh_read_obj(data, nil, colors = &colors)
	defer geom.mesh_destroy(&m)
	if !testing.expect_value(t, read_err, geom.Mesh_File_Error.None) do return
	testing.expect_value(t, len(m.indices) / 3, app.export_decimated)
	if !testing.expect_value(t, len(colors), len(m.positions)) do return
	wrong := 0
	for p, v in m.positions {
		red := colors[v].r > 128
		if p.y > 1e-4 && !red || p.y < -1e-4 && red do wrong += 1
	}
	testing.expect_value(t, wrong, 0)

	// A print of all three shares the triangles asked among them, the painted one too.
	three := strings.clone(FOLDER + "three.3mf")
	defer delete(three)
	app.export_decimated = 0
	if !testing.expect(t, print_export_many(&app, objs[:], three, {decimate = 300})) do return
	testing.expect(t, app.export_decimated > 0 && app.export_decimated <= 315, "the print was not decimated to about 300")
	testing.expect_value(t, len(lv.mesh.indices) / 3, before)

	vertices := []u32{0, 1, 2, 3}
	deltas := []Vec3{{1, 0, 0}, {2, 0, 0}, {3, 0, 0}, {4, 0, 0}}
	kept := []u32{max(u32), 0, max(u32), 1}
	v, d := sparse_keep(vertices, deltas, kept)
	testing.expect(t, len(v) == 2 && v[0] == 0 && v[1] == 1 && d[0].x == 2 && d[1].x == 4, "the shape key's vertices did not follow")
	free_all(context.temp_allocator)
}

// Hollow for this file only writes a print with an inside wall as thick as asked: the
// file is one closed solid of a shell's volume, the object keeps its triangles, a wall
// too thin for the object's size is refused, and several objects in a 3MF each get one.
@(test)
export_hollows_a_print :: proc(t: ^testing.T) {
	FOLDER :: "build/export_hollow_test/"
	_ = os.remove_all(FOLDER)
	defer os.remove_all(FOLDER)
	testing.expect(t, os.make_directory_all(FOLDER) == nil)
	path := strings.clone(FOLDER + "hollow.obj")
	defer delete(path)

	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	obj := objs[0]
	lv := sculpt.levels_current(&obj.levels)
	before := len(lv.mesh.indices) / 3
	if !testing.expect(t, object_export(&app, obj, path, print = true, once = {hollow = 2})) do return
	testing.expect_value(t, len(lv.mesh.indices) / 3, before)
	testing.expect(t, app.export_hollowed > 0, "no inside wall")

	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if !testing.expect(t, err == nil) do return
	m, read_err, _ := geom.mesh_read_obj(data, nil)
	defer geom.mesh_destroy(&m)
	if !testing.expect_value(t, read_err, geom.Mesh_File_Error.None) do return
	report := geom.mesh_check(m)
	// The sphere prints about 50 mm across (an icosphere of 320 faces, a little smaller
	// in volume than the sphere); the shell is its volume less a sphere 2 mm smaller.
	solid := geom.mesh_check(lv.mesh).volume * 25 * 25 * 25
	r := math.cbrt(solid * 3 / (4 * math.PI))
	shell := solid - 4 * math.PI / 3 * (r - 2) * (r - 2) * (r - 2)
	testing.expectf(t, report.closed && !report.inverted && abs(report.volume - shell) < 0.15 * shell, "the hollow print: %v, a shell's volume is %.0f", report, shell)

	testing.expect(t, !object_export(&app, obj, path, print = true, once = {hollow = 0.01}), "a wall too thin for the object was hollowed")

	three := strings.clone(FOLDER + "three.3mf")
	defer delete(three)
	app.export_hollowed = 0
	testing.expect(t, print_export_many(&app, objs[:], three, {hollow = 2}), "the 3MF was not written")
	testing.expect(t, app.export_hollowed > 0, "the 3MF's objects got no inside wall")
	free_all(context.temp_allocator)
}
