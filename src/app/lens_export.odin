package main

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"

import "../ui"

// The Export sheet (round 2's export2 screen, presets after round 3's mExport): every way
// out of the app in one place, starting from what the file is for, as a slicer's or a
// game store's export starts from where the file goes rather than from its format. Six
// presets stand across its top (3D print, Game engine, Blender, Turntable, Picture and
// Any format, which keeps every plain format to hand); under them the preset's options,
// its format among the few that fit it, and beside them a preview of what goes out: the
// picture, the file name, what it holds, its triangles and about how big, and a print's
// size in millimetres. Export runs the format's own command (the scene's save, the mesh
// export limited to the format, the screenshot, the turntable, the 3D print, the Blender
// link), so what each writes is unchanged; the sheet only gathers them. Menu > Export...,
// Ctrl+E and Search open it on what was exported last, which its head names.

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
	// The presets' own, after the others so that a settings file naming those still reads.
	Print_OBJ,
	Link,
	Print_3MF,
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
	.Print      = "3D print STL",
	.Print_OBJ  = "3D print OBJ",
	.Link       = "Blender link",
	.Print_3MF  = "3D print 3MF",
}

// What each format makes.
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
	.Print_OBJ  = ".obj, sized",
	.Link       = "the link's folder",
	.Print_3MF  = ".3mf, sized",
}

// Each format's name on its preset's format tabs, where the preset says the rest.
@(rodata)
EXPORT_FORMAT_TABS := [Export_Format]string {
	.Scene      = "Scene",
	.OBJ        = "OBJ",
	.PLY        = "PLY",
	.STL        = "STL",
	.GLTF       = "glTF",
	.USD        = "USD",
	.Screenshot = "Screenshot",
	.Turntable  = "Frames",
	.Print      = "STL",
	.Print_OBJ  = "OBJ",
	.Link       = "Live link",
	.Print_3MF  = "3MF",
}

// What a file is for, the sheet's first choice.
Export_Preset :: enum u8 {
	Print,
	Game,
	Blender,
	Turntable,
	Picture,
	Formats, // every plain format, as the sheet listed them before the presets
}

@(rodata)
EXPORT_PRESET_NAMES := [Export_Preset]string {
	.Print     = "3D print",
	.Game      = "Game engine",
	.Blender   = "Blender",
	.Turntable = "Turntable",
	.Picture   = "Picture",
	.Formats   = "Any format",
}

// What each preset makes, under its name on its card.
@(rodata)
EXPORT_PRESET_DETAIL := [Export_Preset]string {
	.Print     = "STL, OBJ or 3MF, sized in millimetres",
	.Game      = "glTF with its maps and shape keys",
	.Blender   = "The live link, or USD with layers and lights" when LINK_AVAILABLE else "USD with layers and lights",
	.Turntable = "Once round, as frames and a loop",
	.Picture   = "A screenshot of the view or of its render",
	.Formats   = "Scene, OBJ, PLY, STL, glTF, USD",
}

// Lucide's printer, gamepad-2, rotate-3d, video, camera and file-box, and download.
@(private = "file")
ICON_PRINTER :: rune(0xe145)
@(private = "file")
ICON_GAMEPAD :: rune(0xe0e2)
@(private = "file")
ICON_ROTATE_3D :: rune(0xe2ea)
@(private = "file")
ICON_VIDEO :: rune(0xe1a5)
@(private = "file")
ICON_CAMERA_SHOT :: rune(0xe068)
@(private = "file")
ICON_FILE_BOX :: rune(0xe313)
@(private = "file")
ICON_DOWNLOAD :: rune(0xe0b6)

@(rodata)
EXPORT_PRESET_ICONS := [Export_Preset]rune {
	.Print     = ICON_PRINTER,
	.Game      = ICON_GAMEPAD,
	.Blender   = ICON_ROTATE_3D,
	.Turntable = ICON_VIDEO,
	.Picture   = ICON_CAMERA_SHOT,
	.Formats   = ICON_FILE_BOX,
}

// The formats each preset offers, its first the one it starts on. Blender's live link
// is the desktop's alone, as the link is.
@(private = "file", rodata)
EXPORT_PRINT_FORMATS := [?]Export_Format{.Print, .Print_OBJ, .Print_3MF}
@(private = "file", rodata)
EXPORT_GAME_FORMATS := [?]Export_Format{.GLTF, .OBJ}
@(private = "file", rodata)
EXPORT_BLENDER_FORMATS := [?]Export_Format{.Link, .USD}
@(private = "file", rodata)
EXPORT_TURNTABLE_FORMATS := [?]Export_Format{.Turntable}
@(private = "file", rodata)
EXPORT_PICTURE_FORMATS := [?]Export_Format{.Screenshot}
@(private = "file", rodata)
EXPORT_ANY_FORMATS := [?]Export_Format{.Scene, .OBJ, .PLY, .STL, .GLTF, .USD}

export_preset_formats :: proc(p: Export_Preset) -> []Export_Format {
	switch p {
	case .Print:     return EXPORT_PRINT_FORMATS[:]
	case .Game:      return EXPORT_GAME_FORMATS[:]
	case .Blender:   return EXPORT_BLENDER_FORMATS[:] when LINK_AVAILABLE else EXPORT_BLENDER_FORMATS[1:]
	case .Turntable: return EXPORT_TURNTABLE_FORMATS[:]
	case .Picture:   return EXPORT_PICTURE_FORMATS[:]
	case .Formats:   return EXPORT_ANY_FORMATS[:]
	}
	return nil
}

// Whether preset `p` offers format `f`.
export_preset_has :: proc(p: Export_Preset, f: Export_Format) -> bool {
	for g in export_preset_formats(p) do if g == f do return true
	return false
}

// What the Export sheet's For this file options do to the next export it starts (the
// request's `sheet`), set when Export runs: the copy written changes, never the scene.
Export_Once :: struct {
	decimate: int, // the triangles the file may hold; 0 keeps them all
}

// The For this file options for request `req`: the sheet's when it started it, else none.
export_once_of :: proc(app: ^App, req: File_Request) -> Export_Once {
	return app.export_once if req.sheet else {}
}

// The sheet's state in Kit_State: open, the preset and format chosen, each preset's
// format picked while the app runs, for the scene whether Export saves a copy rather
// than saving as, and the export that ran last, which the sheet opens on (the settings
// keep the preset, the format and the last export).
Export_Sheet :: struct {
	open:        bool,
	preset:      Export_Preset,
	format:      Export_Format,
	picks:       [Export_Preset]Export_Format, // a preset's format from before, when it offers it
	copy:        bool,
	print_all:   bool, // a print takes every object shown, not only the selected ones
	decimate:    bool, // Decimate for this file only, for a print or the game engine
	decimate_to: i32, // the triangles it decimates to; 0 for half of what goes out
	ran:         bool, // an export has run, in this run or one before
	last_preset: Export_Preset,
	last_format: Export_Format,
	runs:        int, // how many times Export ran, for the exit stats
}

// The sheet's widest, a preset card's height, the options' and preview's height (fixed,
// so the sheet keeps its size from preset to preset) and the preview's picture, in points.
EXPORT_SHEET_W :: 940
EXPORT_CARD_H :: 104
EXPORT_BODY_H :: 336
EXPORT_PICTURE :: 120

// Puts the format in a preset that offers it: a settings file from before the presets
// keeps only the format, and the live link is not offered on a tablet.
export_settle :: proc(s: ^Export_Sheet) {
	if export_preset_has(s.preset, s.format) do return
	for p in Export_Preset do if export_preset_has(p, s.format) {
		s.preset = p
		return
	}
	s.format = export_preset_formats(s.preset)[0]
}

// Picks preset `p` on the format it had before, or its first.
export_preset_pick :: proc(s: ^Export_Sheet, p: Export_Preset) {
	s.picks[s.preset] = s.format
	s.preset = p
	s.format = s.picks[p] if export_preset_has(p, s.picks[p]) else export_preset_formats(p)[0]
}

// The head's note of the export that ran last: "Last time: glTF for the game engine".
export_last_label :: proc(p: Export_Preset, f: Export_Format) -> string {
	switch p {
	case .Print:     return fmt.tprintf("Last time: %s for 3D printing", EXPORT_FORMAT_TABS[f])
	case .Game:      return fmt.tprintf("Last time: %s for the game engine", EXPORT_FORMAT_TABS[f])
	case .Blender:   return "Last time: the live link to Blender" if f == .Link else fmt.tprintf("Last time: %s for Blender", EXPORT_FORMAT_TABS[f])
	case .Turntable: return "Last time: a turntable"
	case .Picture:   return "Last time: a picture"
	case .Formats:   return fmt.tprintf("Last time: %s", EXPORT_FORMAT_NAMES[f])
	}
	return ""
}

// The command Export runs for format `f`, whose enabled says whether it can.
export_command :: proc(f: Export_Format, copy := false) -> Command_Id {
	switch f {
	case .Scene:                           return .Save_Scene_Copy if copy else .Save_Scene_As
	case .OBJ, .PLY, .STL, .GLTF, .USD:    return .Export_Mesh
	case .Screenshot:                      return .Screenshot
	case .Turntable:                       return .Record_Turntable
	case .Print, .Print_OBJ, .Print_3MF:   return .Export_Print
	case .Link:                            return .Send_To_Blender
	}
	return .None
}

// The print file a format writes, when it is a print's.
export_print_file :: proc(f: Export_Format) -> (Print_File, bool) {
	#partial switch f {
	case .Print:     return .STL, true
	case .Print_OBJ: return .OBJ, true
	case .Print_3MF: return .Model_3MF, true
	}
	return {}, false
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
// positions, normals and indices), and the link what it sends of the selection; 0 where
// it cannot say (no object, a scene, a picture).
export_bytes :: proc(app: ^App, f: Export_Format) -> int {
	if _, is_print := export_print_file(f); is_print {
		// A print takes its objects (print_objects), each counted the same way.
		bytes := 0
		for obj in print_objects(app) do bytes += export_object_bytes(obj, f)
		return bytes
	}
	if f == .Link do return link_send_bytes(app)
	obj := selected_object(app)
	return 0 if obj == nil else export_object_bytes(obj, f)
}

// What format `f` writes for `obj` alone.
@(private = "file")
export_object_bytes :: proc(obj: ^Object, f: Export_Format) -> int {
	v, t := object_vertex_count(obj), object_triangle_count(obj)
	#partial switch f {
	case .OBJ, .Print_OBJ: return 30 * v + 20 * t
	case .PLY:             return 300 + 12 * v + 13 * t
	case .STL, .Print:     return 84 + 50 * t
	case .GLTF:            return 1024 + 24 * v + 12 * t
	case .USD:             return 40 * v + 30 * t
	case .Print_3MF:       return 1024 + 52 * v + 46 * t
	}
	return 0
}

// Whether the sheet decimates what it exports: asked, for a print or the game engine.
export_decimates :: proc(s: ^Export_Sheet) -> bool {
	return s.decimate && (s.preset == .Print || s.preset == .Game)
}

// The triangles format `f` takes out: a print's objects' or the selected object's.
export_triangles :: proc(app: ^App, f: Export_Format) -> int {
	if _, is_print := export_print_file(f); is_print {
		n := 0
		for obj in print_objects(app) do n += object_triangle_count(obj)
		return n
	}
	obj := selected_object(app)
	return 0 if obj == nil else object_triangle_count(obj)
}

// The triangles Decimate for this file only leaves: what the sheet set, or half of what
// goes out, never under a thousand.
export_decimate_budget :: proc(app: ^App, f: Export_Format) -> int {
	s := &app.kit.export
	if s.decimate_to > 0 do return int(s.decimate_to)
	return max(export_triangles(app, f) / 2, EXPORT_DECIMATE_MIN)
}

// The fewest triangles Decimate for this file only goes to.
EXPORT_DECIMATE_MIN :: 1000

// Decimate for this file only's switch and, while it is on, its triangles to drag.
@(private = "file")
export_decimate_rows :: proc(app: ^App, f: Export_Format) {
	ctx := &app.kit.ctx
	s := &app.kit.export
	total := export_triangles(app, f)
	_ = ui.switch_row(ctx, "Decimate for this file only", &s.decimate, enabled = total > EXPORT_DECIMATE_MIN || s.decimate)
	if !s.decimate do return
	budget := f32(min(export_decimate_budget(app, f), max(total, EXPORT_DECIMATE_MIN)))
	if ui.slider(ctx, "Triangles##export decimate", &budget, EXPORT_DECIMATE_MIN, f32(max(total, EXPORT_DECIMATE_MIN + 1)), .Logarithmic, fmt.tprintf("%s of %s", count_label(int(budget)), count_label(total))) {
		s.decimate_to = i32(budget + 0.5)
	}
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
	case .Print_OBJ:  suffix = ".obj"
	case .Print_3MF:  suffix = ".3mf"
	case .Turntable:  return "a folder of frames"
	case .Link:       return "Blender link folder"
	case .Scene, .OBJ, .PLY, .STL, .GLTF, .USD, .Screenshot:
	}
	stem := "Untitled"
	if app.scene_path != "" do stem = filepath.stem(app.scene_path)
	return strings.concatenate({stem, suffix}, context.temp_allocator)
}

// Opens the sheet on the export that ran last, closing what floats.
export_sheet_open :: proc(app: ^App) {
	k := &app.kit
	kit_floats_close(k)
	s := &k.export
	if s.ran do s.preset, s.format = s.last_preset, s.last_format
	export_settle(s)
	s.open = true
}

// Runs Export for the chosen format and closes the sheet; false when the format's command
// cannot run now.
export_run :: proc(app: ^App) -> bool {
	s := &app.kit.export
	f := s.format
	id := export_command(f, s.copy)
	if !command_enabled(app, id, 0) do return false
	// The dialog suggests the file beside the scene's, which needs a folder: an Android
	// content:// document has none, as for Save next.
	where_ := ""
	if save_next_allowed(app) do where_, _ = filepath.join({filepath.dir(app.scene_path), export_file_name(app, f)}, context.temp_allocator)
	app.export_once = {decimate = export_decimate_budget(app, f) if export_decimates(s) else 0}
	if filter, ok := export_filter(f); ok {
		file_dialog_export(app, filter, where_, sheet = true)
	} else if file, is_print := export_print_file(f); is_print {
		file_dialog_print(app, file, where_, sheet = true)
	} else do command_run(app, id)
	s.open = false
	s.runs += 1
	s.ran, s.last_preset, s.last_format = true, s.preset, f
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
	PAD :: 16
	if !ui.popover_begin(ctx, "export sheet", &s.open, at, .Pointer, {direction = .Column, gap = 12, padding = PAD, width = width}) do return
	defer ui.popover_end(ctx)
	export_settle(s)
	inner := width - 2 * PAD

	// The head: Export, what ran last, and Close.
	ui.begin(ctx, "export head", {direction = .Row, center = true, gap = 8, width = inner})
	mark := ui.place(ctx, {t.icon_size, t.target})
	ui.icon(ctx, ICON_DOWNLOAD, {mark.x + mark.w * 0.5, mark.y + mark.h * 0.5}, t.icon_size, t.text)
	title := ui.place(ctx, {inner - mark.w - t.target - 16, t.target})
	ui.text(ctx, "Export", title.x, title.y + title.h * 0.5, t.heading_size * 1.15, t.text, .Semibold)
	if s.ran {
		last := ui.text_fit(ctx, export_last_label(s.last_preset, s.last_format), t.small_size, title.w - 120)
		ui.text(ctx, last, title.x + title.w, title.y + title.h * 0.5, t.small_size, t.text_secondary, .Regular, .Right)
	}
	if ui.icon_button(ctx, "Close", ui.ICON_CLOSE, keys = "Esc") do s.open = false
	ui.end(ctx)

	// The presets, six across, or three a row on a narrow window.
	GAP :: 10
	across := len(Export_Preset) if inner >= 720 else 3
	card_w := (inner - GAP * f32(across - 1)) / f32(across)
	for first := 0; first < len(Export_Preset); first += across {
		ui.begin(ctx, fmt.tprintf("export presets %d", first), {direction = .Row, gap = GAP, width = inner})
		for i in first ..< min(first + across, len(Export_Preset)) {
			p := Export_Preset(i)
			if export_preset_card(ctx, p, card_w, p == s.preset) do export_preset_pick(s, p)
		}
		ui.end(ctx)
	}

	// The preset's options, and beside them what goes out.
	COLUMNS_GAP :: 22
	options_w := math.floor((inner - COLUMNS_GAP) * 0.54)
	ui.begin(ctx, "export body", {direction = .Row, gap = COLUMNS_GAP, width = inner, height = EXPORT_BODY_H})
	ui.begin(ctx, "export options", {direction = .Column, gap = 8, width = options_w})
	ui.caption(ctx, "OPTIONS")
	formats := export_preset_formats(s.preset)
	if len(formats) > 1 {
		names := make([]string, len(formats), context.temp_allocator)
		chosen := 0
		for f, i in formats {
			names[i] = EXPORT_FORMAT_TABS[f]
			if f == s.format do chosen = i
		}
		if picked := ui.tabs(ctx, fmt.tprintf("export formats %v", s.preset), names, chosen); picked >= 0 do s.format = formats[picked]
	}
	export_options(app, s.format)
	ui.end(ctx)
	export_preview(app, s.format, inner - options_w - COLUMNS_GAP)
	ui.end(ctx)

	// The foot: what Export does to the scene, then Cancel and Export.
	ui.divider(ctx, across = true)
	ui.begin(ctx, "export foot", {direction = .Row, center = true, gap = 8, width = inner})
	buttons: f32 = 2 * 100 + 8
	r := ui.place(ctx, {inner - buttons - 8, t.target})
	note := ui.text_fit(ctx, export_foot_note(s.format, s.copy), t.small_size, r.w, .Regular)
	ui.text(ctx, note, r.x, r.y + r.h * 0.5, t.small_size, t.text_tertiary, .Regular)
	if ui.button(ctx, "Cancel##export", .Bordered, width = 100) do s.open = false
	id := export_command(s.format, s.copy)
	if ui.button(ctx, "Export##export", .Solid, .Accent, width = 100, enabled = command_enabled(app, id, 0), keys = command_hint(app, id)) do _ = export_run(app)
	ui.end(ctx)
}

// What Export does to the scene, for the foot: nothing but for Save as.
export_foot_note :: proc(f: Export_Format, copy: bool) -> string {
	#partial switch f {
	case .Scene: return "Saves a copy; the scene still saves to its own file." if copy else "Saves the scene; the new file becomes the scene's own."
	case .Link:  return "Sends a copy to Blender; the scene is not changed."
	}
	return "Exports a copy; the scene is not changed."
}

// A preset's card, `w` points wide: its icon, name and what it makes, ringed in the
// accent when it is the one chosen. True when tapped.
@(private = "file")
export_preset_card :: proc(ctx: ^ui.Context, p: Export_Preset, w: f32, lit: bool) -> bool {
	t := ctx.theme
	a := ui.area(ctx, fmt.tprintf("%s##export preset", EXPORT_PRESET_NAMES[p]), {w, EXPORT_CARD_H}, drag = false)
	r := a.rect
	fill := t.accent_soft if lit else t.fill_hover if a.hovered else t.fill
	ui.fill_rect(ctx, r, t.radius_medium, fill)
	if lit do ui.stroke_rect(ctx, r, t.radius_medium, t.accent, 1.5)
	INSET :: 12
	x := r.x + INSET
	y := r.y + INSET + t.icon_size * 0.5
	ui.icon(ctx, EXPORT_PRESET_ICONS[p], {x + t.icon_size * 0.5, y}, t.icon_size, t.accent if lit else t.text_secondary)
	y += t.icon_size * 0.5 + 8 + t.text_size * 0.6
	room := r.w - 2 * INSET
	ui.text(ctx, ui.text_fit(ctx, EXPORT_PRESET_NAMES[p], t.text_size, room, .Semibold), x, y, t.text_size, t.text, .Semibold)
	line_h := math.ceil(t.small_size * 1.4)
	y += t.text_size * 0.6 + 4 + line_h * 0.5
	first, second := export_two_lines(ctx, EXPORT_PRESET_DETAIL[p], t.small_size, room)
	ui.text(ctx, first, x, y, t.small_size, t.text_secondary)
	if second != "" do ui.text(ctx, second, x, y + line_h, t.small_size, t.text_secondary)
	return a.clicked
}

// `s` wrapped at a space onto at most two lines of `w` points, the second cut short with
// an ellipsis when it still does not fit.
@(private = "file")
export_two_lines :: proc(ctx: ^ui.Context, s: string, size, w: f32) -> (first, second: string) {
	if ui.text_width(ctx, s, size) <= w do return s, ""
	cut := 0
	for i in 0 ..< len(s) {
		if s[i] != ' ' do continue
		if ui.text_width(ctx, s[:i], size) > w do break
		cut = i
	}
	if cut == 0 do return ui.text_fit(ctx, s, size, w), ""
	return s[:cut], ui.text_fit(ctx, s[cut + 1:], size, w)
}

// What goes out, `w` points wide: the picture (the object's thumbnail, or the view for
// the scene and the pictures), the file name, and lines on what it holds; for a print,
// the checks before it prints under them (print_checks.odin).
@(private = "file")
export_preview :: proc(app: ^App, f: Export_Format, w: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	obj := selected_object(app)
	ui.begin(ctx, "export preview", {direction = .Column, gap = 10, width = w})
	ui.begin(ctx, "export preview head", {direction = .Row, gap = 12, width = w})
	pic := ui.place(ctx, {EXPORT_PICTURE, EXPORT_PICTURE})
	ui.fill_rect(ctx, pic, t.radius_medium, t.fill)
	drawn := false
	if f == .Scene || f == .Screenshot || f == .Turntable {
		// The view's middle square, as the view stands.
		v := k.grid.main
		if v.w > 0 && v.h > 0 {
			half := [2]f32{0.5 * min(v.h / v.w, 1), 0.5 * min(v.w / v.h, 1)}
			ui.image_part(ctx, pic, KIT_VIEWPORT_IMAGE, 0.5 - half, 0.5 + half)
			drawn = true
		}
	} else if obj != nil {
		if lo, hi, ok := thumb_for(app, obj); ok {
			ui.image_part(ctx, pic, KIT_THUMBS_IMAGE, lo, hi)
			drawn = true
		}
	}
	if !drawn do ui.icon(ctx, EXPORT_PRESET_ICONS[app.kit.export.preset], {pic.x + pic.w * 0.5, pic.y + pic.h * 0.5}, t.icon_size * 2, t.text_tertiary)
	lines_w := w - EXPORT_PICTURE - 12
	ui.begin(ctx, "export preview lines", {direction = .Column, gap = 2, width = lines_w})
	ui.label(ctx, ui.text_fit(ctx, export_file_name(app, f), t.text_size, lines_w, .Semibold), t.text_size, t.text, .Semibold)
	for line in export_preview_lines(app, f) do ui.label(ctx, ui.text_fit(ctx, line, t.small_size, lines_w), t.small_size, t.text_secondary)
	ui.end(ctx)
	ui.end(ctx)
	if _, is_print := export_print_file(f); is_print && obj != nil do print_checks_rows(app, obj, w)
	ui.end(ctx)
}

// The preview's lines under the file name: what goes in, its triangles and about how
// big, and for a print its size.
export_preview_lines :: proc(app: ^App, f: Export_Format) -> []string {
	lines := make([dynamic]string, 0, 4, context.temp_allocator)
	obj := selected_object(app)
	switch f {
	case .Scene:
		n := len(app.scene.objects)
		append(&lines, fmt.tprintf("%d %s, with every level, layer and mask", n, "object" if n == 1 else "objects"))
		append(&lines, "The lights, materials and camera")
	case .Screenshot:
		append(&lines, "The view as it stands" if !app.screenshot_transparent else "The view without its background")
		if render_switch_on(app) do append(&lines, "With the render" if app.render_quality == .Fast else "With the path-traced render")
	case .Turntable:
		append(&lines, fmt.tprintf("%d frames, %.1f s at %d a second", app.turntable_frames, f32(app.turntable_frames) / TURNTABLE_FPS, TURNTABLE_FPS))
		append(&lines, "Numbered PNG pictures and one looping PNG")
	case .Link:
		n := len(selection_ids(app))
		if n == 0 {
			append(&lines, "Nothing selected")
			break
		}
		append(&lines, object_label(obj) if n == 1 else fmt.tprintf("%d objects", n))
		if bytes := export_bytes(app, f); bytes > 0 do append(&lines, fmt.tprintf("About %s", export_size_label(bytes)))
	case .Print, .Print_OBJ, .Print_3MF:
		objs := print_objects(app)
		if len(objs) == 0 {
			append(&lines, "Nothing selected")
			break
		}
		triangles := 0
		for o in objs do triangles += object_triangle_count(o)
		append(&lines, object_label(objs[0]) if len(objs) == 1 else fmt.tprintf("%d objects, each its own part" if f == .Print_3MF else "%d objects as one mesh", len(objs)))
		append(&lines, export_triangles_line(app, f, triangles))
		// The file stands Z up, so the scene's height (Y) is the print's.
		size := print_size_of(app, objs) / PRINT_UNIT_MM[app.print_unit]
		unit := PRINT_UNIT_NAMES[app.print_unit]
		append(&lines, fmt.tprintf("%s wide, %s deep, %s tall (%s)", print_number(size.x), print_number(size.z), print_number(size.y), unit))
	case .OBJ, .PLY, .STL, .GLTF, .USD:
		if obj == nil {
			append(&lines, "Nothing selected")
			break
		}
		append(&lines, object_label(obj))
		append(&lines, export_triangles_line(app, f, object_triangle_count(obj)))
	}
	return lines[:]
}

// The preview's line of triangles and about how big: after Decimate for this file only
// when it is on, the size scaled with them.
@(private = "file")
export_triangles_line :: proc(app: ^App, f: Export_Format, triangles: int) -> string {
	bytes := export_bytes(app, f)
	if !export_decimates(&app.kit.export) || triangles <= 0 do return fmt.tprintf("%s triangles · about %s", count_label(triangles), export_size_label(bytes))
	kept := min(export_decimate_budget(app, f), triangles)
	return fmt.tprintf("%s of %s triangles · about %s", count_label(kept), count_label(triangles), export_size_label(int(i64(bytes) * i64(kept) / i64(triangles))))
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
		ui.value_row(ctx, "Selected", object_label(obj))
		if k.export.preset == .Game {
			export_decimate_rows(app, f)
		} else {
			ui.value_row(ctx, "Vertices", count_label(object_vertex_count(obj)))
		}
		#partial switch f {
		case .STL:  ui.paragraph(ctx, "Triangles alone, as slicers read them. For a print at its real size, 3D print sets it in millimetres.")
		case .GLTF: ui.paragraph(ctx, "Binary glTF, as Unity, Unreal and Godot read it: the object's layers as shape keys, its materials and its maps.")
		case .USD:  ui.paragraph(ctx, "USD text, with the object's layers as blend shapes and the scene's lights.")
		case .OBJ:  ui.paragraph(ctx, "The object's shown level, placed as it is in the scene, with its polypaint as vertex colours; a retopologized base level goes as its quads and UVs.")
		case:       ui.paragraph(ctx, "The object's shown level, placed as it is in the scene, with its polypaint as vertex colours.")
		}
	case .Link:
		if !LINK_AVAILABLE {
			ui.paragraph(ctx, "The Blender link is on the desktop apps only.")
			return
		}
		if app.link.folder == "" {
			ui.paragraph(ctx, "Set the link's folder first, in Settings > System > Blender link, where the add-on for Blender is too.")
			return
		}
		ui.value_row(ctx, "Folder", filepath.base(app.link.folder))
		ui.paragraph(ctx, "Writes the selected objects to the link's folder; Get from Sculpt in Blender's Sculpt tab brings them in, with their layers, lights and materials, and Send to Sculpt brings Blender's changes back.")
	case .Screenshot:
		on := render_switch_on(app)
		if ui.switch_row(ctx, "Render it", &on, keys = command_hint(app, .Studio_Render)) do render_set(app, on, app.render_quality)
		if render_switch_on(app) {
			qualities := [2]string{"Fast", "Full"}
			if picked := ui.tabs(ctx, "export render quality", qualities[:], int(app.render_quality)); picked >= 0 do render_set(app, true, Render_Quality(picked))
		}
		transparent := app.screenshot_transparent
		if ui.switch_row(ctx, "Without background", &transparent, keys = command_hint(app, .Screenshot_Transparent)) do command_run(app, .Screenshot_Transparent)
		ui.paragraph(ctx, "The view as a PNG. Render it lays soft shadows and occlusion over it (Fast) or path traces it with the scene's lights (Full) first; without the background, the model stands on a transparent ground for a page or a slide.")
	case .Turntable:
		frames := f32(app.turntable_frames)
		seconds := fmt.tprintf("%d · %.1f s", app.turntable_frames, frames / TURNTABLE_FPS)
		if ui.slider(ctx, "Frames##export", &frames, TURNTABLE_FRAMES_MIN, TURNTABLE_FRAMES_MAX, .Logarithmic, seconds, enabled = !turntable_recording(app)) do app.turntable_frames = i32(frames + 0.5)
		on := app.screenshot_transparent
		if ui.switch_row(ctx, "Without background##turntable", &on, keys = command_hint(app, .Screenshot_Transparent)) do command_run(app, .Screenshot_Transparent)
		ui.paragraph(ctx, "The camera goes once round the scene, saving every frame into a folder you pick as numbered PNG pictures and one animated PNG that loops.")
	case .Print, .Print_OBJ, .Print_3MF:
		export_print_options(app)
	}
}

// A print's options: which objects it takes, its unit and its height, which sets the
// scene's one print scale (Scene > 3D print sets any side).
@(private = "file")
export_print_options :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	s := &k.export
	shown, chosen := len(print_objects_of(app, true)), len(print_objects_of(app, false))
	only := !s.print_all
	if ui.switch_row(ctx, fmt.tprintf("Only the selected objects (%d)", chosen), &only, enabled = shown > 1 || !only) do s.print_all = !only
	objs := print_objects(app)
	if len(objs) == 0 {
		ui.paragraph(ctx, "Select an object to print, or turn Only the selected objects off to print every object shown.")
		return
	}
	// The height to drag and its unit beside it, on one row.
	t := ctx.theme
	UNITS_W :: 132
	row_w := ui.fill_width(ctx)
	ui.begin(ctx, "export print height", {direction = .Row, center = true, gap = 8, width = row_w})
	ui.begin(ctx, "export print height value", {direction = .Column, width = row_w - UNITS_W - 8})
	unit := PRINT_UNIT_MM[app.print_unit]
	b := print_bounds_of(objs)
	height := (b.hi.y - b.lo.y) * print_scale(app) / unit
	step := max(height / 500, 0.001)
	if ui.drag_value(ctx, "Height##export print", &height, step, 0, PRINT_MM_MAX * 1000, fmt.tprintf("%s %s", print_number(height), PRINT_UNIT_NAMES[app.print_unit]), enabled = b.hi.y > b.lo.y) {
		_ = print_set_height(app, b, height * unit)
	}
	ui.end(ctx)
	names: [len(Print_Unit)]string
	for u in Print_Unit do names[u] = PRINT_UNIT_NAMES[u]
	if picked := ui.tabs(ctx, "export print unit", names[:], int(app.print_unit), item_width = (UNITS_W - 4) / 3); picked >= 0 do app.print_unit = Print_Unit(picked)
	ui.end(ctx)
	export_decimate_rows(app, k.export.format)
	ui.paragraph(ctx, "Width and depth follow, every object at the scene's one print scale, so parts printed apart fit together.", color = t.text_tertiary)
}
