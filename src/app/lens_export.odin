package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "../ui"

// The Export sheet (round 2 of the mockups, screen export2): every way out of the app in
// one place, the formats down its side and the chosen one's options beside them, with the
// file it makes and about how big before Export, as a desktop modeller's export dialog
// keeps every format behind one command. Export runs the format's own command (the scene's
// save, the mesh export limited to the format, the screenshot, the turntable, the 3D
// print), so what each writes is unchanged; the sheet only gathers them. Menu > Export...,
// Ctrl+E and Search open it, on the format used last.

Export_Format :: enum u8 {
	Scene,
	OBJ,
	PLY,
	STL,
	GLTF,
	USD,
	Screenshot,
	Turntable,
	Print,
}

@(rodata)
EXPORT_FORMAT_NAMES := [Export_Format]string {
	.Scene      = "Sculpt scene",
	.OBJ        = "OBJ",
	.PLY        = "PLY",
	.STL        = "STL",
	.GLTF       = "glTF",
	.USD        = "USD",
	.Screenshot = "Screenshot",
	.Turntable  = "Turntable",
	.Print      = "3D print",
}

// What each format makes, on its row.
@(rodata)
EXPORT_FORMAT_DETAIL := [Export_Format]string {
	.Scene      = ".sculpt",
	.OBJ        = ".obj",
	.PLY        = ".ply",
	.STL        = ".stl",
	.GLTF       = ".glb",
	.USD        = ".usda",
	.Screenshot = ".png",
	.Turntable  = "frames",
	.Print      = ".stl, sized",
}

// Lucide's box, triangle, camera, rotate-3d and printer.
@(private = "file")
ICON_BOX :: rune(0xe065)
@(private = "file")
ICON_TRIANGLE :: rune(0xe192)
@(private = "file")
ICON_CAMERA_SHOT :: rune(0xe068)
@(private = "file")
ICON_ROTATE_3D :: rune(0xe2ea)
@(private = "file")
ICON_PRINTER :: rune(0xe145)

@(rodata)
EXPORT_FORMAT_ICONS := [Export_Format]rune {
	.Scene      = ICON_BOX,
	.OBJ        = ICON_TRIANGLE,
	.PLY        = ICON_TRIANGLE,
	.STL        = ICON_TRIANGLE,
	.GLTF       = ICON_TRIANGLE,
	.USD        = ICON_TRIANGLE,
	.Screenshot = ICON_CAMERA_SHOT,
	.Turntable  = ICON_ROTATE_3D,
	.Print      = ICON_PRINTER,
}

// The sheet's state in Kit_State: open, the format chosen (which the settings keep), and
// for the scene whether Export saves a copy rather than saving as.
Export_Sheet :: struct {
	open:   bool,
	format: Export_Format,
	copy:   bool,
	runs:   int, // how many times Export ran, for the exit stats
}

// The sheet's size and its side's width, in points.
EXPORT_SHEET_W :: 680
EXPORT_SHEET_H :: 420
EXPORT_SHEET_SIDE :: 200

// The command Export runs for format `f`, whose enabled says whether it can.
export_command :: proc(f: Export_Format, copy := false) -> Command_Id {
	switch f {
	case .Scene:                           return .Save_Scene_Copy if copy else .Save_Scene_As
	case .OBJ, .PLY, .STL, .GLTF, .USD:    return .Export_Mesh
	case .Screenshot:                      return .Screenshot
	case .Turntable:                       return .Record_Turntable
	case .Print:                           return .Export_Print
	}
	return .None
}

// The mesh filter a format limits the export dialog to, when it is a mesh format.
export_filter :: proc(f: Export_Format) -> (Export_Filter, bool) {
	#partial switch f {
	case .OBJ:  return .OBJ, true
	case .PLY:  return .PLY, true
	case .STL:  return .STL, true
	case .GLTF: return .GLTF, true
	case .USD:  return .USD, true
	}
	return {}, false
}

// About how many bytes format `f` writes for the selected object: from its shown level's
// vertices and triangles and what each takes in that format (binary STL's 50 bytes a
// triangle, binary PLY's 12 a vertex and 13 a face, OBJ's and USD's lines of text, glTF's
// positions, normals and indices); 0 where it cannot say (no object, a scene, a picture).
export_bytes :: proc(app: ^App, f: Export_Format) -> int {
	obj := selected_object(app)
	if obj == nil do return 0
	v, t := object_vertex_count(obj), object_triangle_count(obj)
	#partial switch f {
	case .OBJ:         return 30 * v + 20 * t
	case .PLY:         return 300 + 12 * v + 13 * t
	case .STL, .Print: return 84 + 50 * t
	case .GLTF:        return 1024 + 24 * v + 12 * t
	case .USD:         return 40 * v + 30 * t
	}
	return 0
}

// An estimate's size to the nearest kilobyte or megabyte, with a tenth below ten
// megabytes, so that 4.8 MB does not read as 4 MB.
export_size_label :: proc(n: int) -> string {
	MB :: f64(1 << 20)
	switch {
	case n < 1 << 20:  return fmt.tprintf("%d KB", max((n + 512) >> 10, 1))
	case n < 10 << 20: return fmt.tprintf("%.1f MB", f64(n) / MB)
	case n < 1 << 30:  return fmt.tprintf("%d MB", int(f64(n) / MB + 0.5))
	}
	return fmt.tprintf("%.1f GB", f64(n) / (MB * 1024))
}

// The file name the save dialog suggests for format `f`: the scene file's name with the
// format's suffix, beside it, or "Untitled" before the scene is saved.
export_file_name :: proc(app: ^App, f: Export_Format) -> string {
	suffix := EXPORT_FORMAT_DETAIL[f]
	switch f {
	case .Print:      suffix = ".stl"
	case .Turntable:  return "a folder of frames"
	case .Scene, .OBJ, .PLY, .STL, .GLTF, .USD, .Screenshot:
	}
	stem := "Untitled"
	if app.scene_path != "" do stem = filepath.stem(app.scene_path)
	return strings.concatenate({stem, suffix}, context.temp_allocator)
}

// Opens the sheet on the format used last, closing what floats.
export_sheet_open :: proc(app: ^App) {
	k := &app.kit
	kit_floats_close(k)
	k.export.open = true
}

// Runs Export for the chosen format and closes the sheet; false when the format's command
// cannot run now.
export_run :: proc(app: ^App) -> bool {
	k := &app.kit
	f := k.export.format
	id := export_command(f, k.export.copy)
	if !command_enabled(app, id, 0) do return false
	if filter, ok := export_filter(f); ok {
		// The dialog suggests the file beside the scene's, which needs a folder: an Android
		// content:// document has none, as for Save next.
		where_ := ""
		if save_next_allowed(app) do where_, _ = filepath.join({filepath.dir(app.scene_path), export_file_name(app, f)}, context.temp_allocator)
		file_dialog_export(app, filter, where_)
	} else do command_run(app, id)
	k.export.open = false
	k.export.runs += 1
	return true
}

kit_export_sheet :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.export
	area := ui.safe_area(ctx)
	width := min(f32(EXPORT_SHEET_W), area.w - 32)
	at := ui.Rect{area.x + (area.w - width) * 0.5, kit_top() + 24, 0, 0}
	PAD :: 8
	if !ui.popover_begin(ctx, "export sheet", &s.open, at, .Pointer, {direction = .Row, gap = 12, padding = PAD, width = width}) do return
	defer ui.popover_end(ctx)
	side := f32(EXPORT_SHEET_SIDE)
	body_w := width - 2 * PAD - side - 12

	ui.begin(ctx, "export formats", {direction = .Column, gap = 0, width = side})
	for f in Export_Format {
		if ui.list_row(ctx, fmt.tprintf("%s##export format", EXPORT_FORMAT_NAMES[f]), EXPORT_FORMAT_DETAIL[f], f == s.format, EXPORT_FORMAT_ICONS[f]).clicked do s.format = f
	}
	ui.end(ctx)

	ui.begin(ctx, "export options", {direction = .Column, gap = 8, width = body_w, height = EXPORT_SHEET_H})
	ui.begin(ctx, "export head", {direction = .Row, center = true, width = body_w})
	title := ui.place(ctx, {body_w - t.target, t.target})
	ui.text(ctx, fmt.tprintf("Export %s", EXPORT_FORMAT_NAMES[s.format]), title.x, title.y + title.h * 0.5, t.heading_size * 1.15, t.text, .Semibold)
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do s.open = false
	ui.end(ctx)
	export_options(app, s.format)
	// The foot: the file it makes and about how big, then Cancel and Export, at the bottom.
	used := ctx.last_rect.y + ctx.last_rect.h
	top := title.y
	ui.spacer(ctx, max(top + EXPORT_SHEET_H - used - t.target - 16, 0))
	ui.divider(ctx, across = true)
	ui.begin(ctx, "export foot", {direction = .Row, center = true, gap = 8, width = body_w})
	line := export_file_name(app, s.format)
	if bytes := export_bytes(app, s.format); bytes > 0 do line = fmt.tprintf("%s · about %s", line, export_size_label(bytes))
	buttons: f32 = 2 * 100 + 8
	r := ui.place(ctx, {body_w - buttons - 8, t.target})
	ui.text(ctx, ui.text_fit(ctx, line, t.small_size, r.w, .Regular), r.x, r.y + r.h * 0.5, t.small_size, t.text_secondary, .Regular)
	if ui.button(ctx, "Cancel##export", .Bordered, width = 100) do s.open = false
	id := export_command(s.format, s.copy)
	if ui.button(ctx, "Export##export", .Solid, .Accent, width = 100, enabled = command_enabled(app, id, 0), keys = command_hint(app, id)) do _ = export_run(app)
	ui.end(ctx)
	ui.end(ctx)
}

// Format `f`'s options, from the settings the app has for it.
@(private = "file")
export_options :: proc(app: ^App, f: Export_Format) {
	k := &app.kit
	ctx := &k.ctx
	obj := selected_object(app)
	switch f {
	case .Scene:
		ways := [2]string{"Save as", "Save a copy"}
		if picked := ui.tabs(ctx, "Scene export", ways[:], int(k.export.copy)); picked >= 0 do k.export.copy = picked == 1
		ui.paragraph(ctx, "Save a copy writes the scene to another file and keeps working in this one; Save as makes the new file the scene's own. Either keeps everything: objects, levels, layers, masks, materials, lights and the camera.")
	case .OBJ, .PLY, .STL, .GLTF, .USD:
		if obj == nil {
			ui.paragraph(ctx, "Select an object to export.")
			return
		}
		ui.caption(ctx, "OBJECT")
		ui.value_row(ctx, "Selected", object_label(obj))
		ui.value_row(ctx, "Triangles", count_label(object_triangle_count(obj)))
		ui.value_row(ctx, "Vertices", count_label(object_vertex_count(obj)))
		#partial switch f {
		case .STL:  ui.paragraph(ctx, "Triangles alone, as slicers read them. For a print at its real size, 3D print sets it in millimetres.")
		case .GLTF: ui.paragraph(ctx, "Binary glTF, with the object's layers as shape keys and its materials and maps.")
		case .USD:  ui.paragraph(ctx, "USD text, with the object's layers as blend shapes.")
		case:       ui.paragraph(ctx, "The object's shown level, placed as it is in the scene.")
		}
	case .Screenshot:
		on := app.screenshot_transparent
		if ui.switch_row(ctx, "Without background", &on, keys = command_hint(app, .Screenshot_Transparent)) do command_run(app, .Screenshot_Transparent)
		ui.paragraph(ctx, "The window's picture as a PNG; without the background, the model on a transparent ground for a page or a slide.")
	case .Turntable:
		frames := f32(app.turntable_frames)
		seconds := fmt.tprintf("%d · %.1f s", app.turntable_frames, frames / TURNTABLE_FPS)
		if ui.slider(ctx, "Frames##export", &frames, TURNTABLE_FRAMES_MIN, TURNTABLE_FRAMES_MAX, .Logarithmic, seconds, enabled = !turntable_recording(app)) do app.turntable_frames = i32(frames + 0.5)
		on := app.screenshot_transparent
		if ui.switch_row(ctx, "Without background##turntable", &on, keys = command_hint(app, .Screenshot_Transparent)) do command_run(app, .Screenshot_Transparent)
		ui.paragraph(ctx, "The camera goes once round the scene, saving every frame into a folder you pick as numbered PNG pictures and one animated PNG that loops.")
	case .Print:
		print_controls(app, false)
	}
}
