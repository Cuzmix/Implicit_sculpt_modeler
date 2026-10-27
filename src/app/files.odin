package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../png_write"
import "../render"
import "../sculpt"

// Files: meshes in and out as OBJ or PLY, and whole scenes saved and opened in the
// native format. A request comes from a File menu dialog, a shortcut or a flag and runs
// at the start of a frame (file_take), as a Scene_Command does.

File_Kind :: enum u8 {
	None,
	Import, // a mesh file becomes a new object
	Export, // the selected object's shown level goes to a mesh file
	Save,   // the scene goes to a .sculpt file
	Save_Copy, // the scene goes to a .sculpt file, and stays the file it was (versions.odin)
	Open,   // a .sculpt file replaces the scene
	Alpha,  // an image becomes a brush alpha (alphas.odin)
	Screenshot, // the viewport image goes to a PNG file
	Timelapse,  // the History is recorded as PNG frames into a folder (timeline.odin)
	Bake,       // maps baked onto the selected quad object go into a folder (retopo.odin)
	Save_Strokes, // the recorded strokes go to a .strokes file (replay.odin)
	Load_Strokes, // a .strokes file becomes the recording
	Recover,      // an earlier session's newest autosave replaces the scene (autosave.odin); the path names the session, "" for the newest of any
	Discard_Autosave, // an earlier session's autosaves are deleted; the path names the session
	Open_Version, // an earlier save of the scene's file replaces the scene, which still saves to its file (versions.odin)
	Run_Script,   // a command script file runs as the person's own work (macros.odin)
}

File_Request :: struct {
	kind: File_Kind,
	path: string, // from runtime.heap_allocator(): a dialog's thread may make it
}

// The last file action's outcome, which the interface shows as a note: the log alone may
// be in a console nobody watches. `at` tells a new note from the one already shown.
// The native scene file starts with these bytes, then its version.
SCENE_MAGIC :: "SCULPTSC"
SCENE_VERSION :: u32(10) // 2: each object's rotation; 3: the current level's polypaint and polygroups; 4: sculpt layers, and a retopologized object's quads and UVs (sculpt.levels_write); 5: each object's boolean mode; 6: the base level's node layout (sculpt.levels_write); 7: the camera's roll; 8: each object's eye and ghost, and Solo; 9: folders, and each object's folder; 10: selection sets (sculpt.levels_write)

// The request waiting for the next frame, and whether a dialog is showing. Kept here
// rather than in App because SDL may call a dialog back on another thread, even after
// the App is gone.
@(private = "file")
pending: struct {
	lock:   sync.Mutex,
	dialog: bool,
	req:    File_Request,
	error:  string, // a dialog's failure, for the main thread to log (heap)
}

// What the dialogs offer. SDL reads them until the dialog calls back, so they live for
// the whole run.
@(private = "file")
MESH_FILTERS := [?]sdl.DialogFileFilter{{"Meshes (OBJ, PLY)", "obj;ply"}, {"OBJ", "obj"}, {"PLY", "ply"}}
// Export writes two formats Import does not read, so it offers its own list; a name
// typed without an extension takes the one of the filter chosen (EXPORT_SUFFIX).
@(private = "file")
EXPORT_FILTERS := [?]sdl.DialogFileFilter{{"Meshes (OBJ, PLY, glTF, USD)", "obj;ply;glb;usda"}, {"OBJ", "obj"}, {"PLY", "ply"}, {"glTF binary (layers as shape keys)", "glb"}, {"USD text (layers as blend shapes)", "usda"}}
@(private = "file")
EXPORT_SUFFIX := [len(EXPORT_FILTERS)]string{".obj", ".obj", ".ply", ".glb", ".usda"}
@(private = "file")
SCENE_FILTERS := [?]sdl.DialogFileFilter{{"Sculpt scene", "sculpt"}}
@(private = "file")
PNG_FILTERS := [?]sdl.DialogFileFilter{{"PNG image", "png"}}
@(private = "file")
IMAGE_FILTERS := [?]sdl.DialogFileFilter{{"Images (PNG, JPEG, BMP, TGA, QOI)", "png;jpg;jpeg;bmp;tga;qoi"}}
@(private = "file")
STROKES_FILTERS := [?]sdl.DialogFileFilter{{"Recorded strokes", "strokes"}}
@(private = "file")
SCRIPT_FILTERS := [?]sdl.DialogFileFilter{{"Command scripts", "cmd;txt"}}

// Shows the dialog that picks the file for `kind`; its answer becomes a request. Does
// nothing while another dialog is showing.
file_dialog :: proc(app: ^App, kind: File_Kind) {
	if kind == .None do return
	sync.lock(&pending.lock)
	busy := pending.dialog
	pending.dialog = true
	sync.unlock(&pending.lock)
	if busy do return
	userdata := rawptr(uintptr(kind))
	#partial switch kind {
	case .Import:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(MESH_FILTERS[:]), len(MESH_FILTERS), nil, false)
	case .Export:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(EXPORT_FILTERS[:]), len(EXPORT_FILTERS), nil)
	case .Save, .Save_Copy:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(SCENE_FILTERS[:]), len(SCENE_FILTERS), nil)
	case .Open:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(SCENE_FILTERS[:]), len(SCENE_FILTERS), nil, false)
	case .Alpha:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(IMAGE_FILTERS[:]), len(IMAGE_FILTERS), nil, false)
	case .Screenshot:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(PNG_FILTERS[:]), len(PNG_FILTERS), nil)
	case .Save_Strokes:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(STROKES_FILTERS[:]), len(STROKES_FILTERS), nil)
	case .Load_Strokes:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(STROKES_FILTERS[:]), len(STROKES_FILTERS), nil, false)
	case .Run_Script:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(SCRIPT_FILTERS[:]), len(SCRIPT_FILTERS), nil, false)
	case .Timelapse, .Bake:
		sdl.ShowOpenFolderDialog(file_dialog_done, userdata, app.window, nil, false)
	}
}

// SDL's answer to a dialog, on whichever thread SDL likes: a nil list is a failure, an
// empty one a cancel. A name typed without an extension gets the one asked for.
@(private = "file")
file_dialog_done :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	heap := runtime.heap_allocator()
	kind := File_Kind(uintptr(userdata))
	sync.lock(&pending.lock)
	defer sync.unlock(&pending.lock)
	pending.dialog = false
	if filelist == nil {
		delete(pending.error, heap)
		pending.error = strings.clone(string(sdl.GetError()), heap)
		return
	}
	if filelist[0] == nil do return
	path := string(filelist[0])
	suffix := ""
	if filepath.ext(path) == "" {
		#partial switch kind {
		case .Save, .Save_Copy: suffix = ".sculpt"
		case .Export: suffix = EXPORT_SUFFIX[filter] if filter >= 0 && int(filter) < len(EXPORT_SUFFIX) else ".obj"
		case .Screenshot: suffix = ".png"
		case .Save_Strokes: suffix = ".strokes"
		}
	}
	delete(pending.req.path, heap)
	pending.req = {kind, strings.concatenate({path, suffix}, heap)}
}

// Queues a request for a file already named (Ctrl+S on a saved scene, the flags).
file_post :: proc(kind: File_Kind, path: string) {
	heap := runtime.heap_allocator()
	sync.lock(&pending.lock)
	defer sync.unlock(&pending.lock)
	delete(pending.req.path, heap)
	pending.req = {kind, strings.clone(path, heap)}
}

// The waiting request, if any, which the caller frees with file_request_free; notes a
// dialog failure first.
file_take :: proc(app: ^App) -> (req: File_Request, ok: bool) {
	sync.lock(&pending.lock)
	defer sync.unlock(&pending.lock)
	if pending.error != "" {
		file_note(app, true, "The file dialog failed: %s", pending.error)
		delete(pending.error, runtime.heap_allocator())
		pending.error = ""
	}
	if pending.req.kind == .None do return {}, false
	req, pending.req = pending.req, {}
	return req, true
}

// Whether a request waits for the next frame, which the autosave's rest counts as busy.
file_pending :: proc() -> bool {
	return file_pending_kind() != .None
}

// What the waiting request is, .None for nothing.
file_pending_kind :: proc() -> File_Kind {
	sync.lock(&pending.lock)
	defer sync.unlock(&pending.lock)
	return pending.req.kind
}

file_request_free :: proc(req: File_Request) {
	delete(req.path, runtime.heap_allocator())
}

// Drops a request no frame took, at exit.
file_shutdown :: proc(app: ^App) {
	sync.lock(&pending.lock)
	file_request_free(pending.req)
	delete(pending.error, runtime.heap_allocator())
	pending.req, pending.error = {}, ""
	sync.unlock(&pending.lock)
}

// The bytes of a file the person picked: an import, a scene, an alpha, a script or a
// stroke recording. Android's picker hands back a content:// URI, which only SDL's IO
// can open (through the activity's content resolver), so such a path is read with
// SDL_LoadFile; every other path goes through os, whose errors say more.
file_read_any :: proc(path: string, allocator := context.allocator) -> (data: []u8, err: os.Error) {
	if !strings.has_prefix(path, "content://") do return os.read_entire_file(path, allocator)
	size: uint
	raw := sdl.LoadFile(strings.clone_to_cstring(path, context.temp_allocator), &size)
	if raw == nil do return nil, .Not_Exist
	defer sdl.free(raw)
	data = make([]u8, int(size), allocator) or_return
	copy(data, ([^]u8)(raw)[:size])
	return data, nil
}

// Reports a file action's outcome (results.odin), which shows as a toast.
file_note :: proc(app: ^App, warning: bool, format: string, args: ..any) {
	report(app, nil, {.Warning} if warning else {}, format, ..args)
}

// Runs a request. Returns false only on a fatal GPU failure; the outcome, whatever it
// is, becomes the file note.
file_apply :: proc(app: ^App, req: File_Request) -> bool {
	switch req.kind {
	case .None:
	case .Import:
		before := len(app.scene.objects)
		if !scene_import(app, req.path) do return false
		if len(app.scene.objects) > before do history_record_added(app)
	case .Export:
		obj := selected_object(app)
		if obj == nil {
			file_note(app, true, "Select an object to export first")
			return true
		}
		if object_export_bytes(obj, req.path) > SAVE_SHOW_FIRST {
			// As a big save: the window says what it waits for before the frame stops.
			app.saving = {req.kind, strings.clone(req.path, runtime.heap_allocator())}
			app.saving_at = app.kit.ctx.time
			report(app, nil, {.Busy}, "Exporting %s...", filepath.base(req.path))
			return true
		}
		_ = object_export(app, obj, req.path)
	case .Save, .Save_Copy:
		if app.saving.kind != .None do return true
		if scene_save_bytes(app) > SAVE_SHOW_FIRST {
			// The frame stops for the whole save, so first the window says what it is
			// waiting for; save_pending runs it once the toast is up.
			app.saving = {req.kind, strings.clone(req.path, runtime.heap_allocator())}
			app.saving_at = app.kit.ctx.time
			report(app, nil, {.Busy}, "Saving %s...", filepath.base(req.path))
			return true
		}
		scene_save_request(app, req)
	case .Open:
		opened, ok := scene_open(app, req.path)
		if opened do scene_remember_path(app, req.path)
		return ok
	case .Open_Version:
		return version_open(app, req.path)
	case .Alpha:
		_ = alpha_keep(app, req.path)
	case .Screenshot:
		_ = screenshot_save(app, req.path)
	case .Timelapse:
		timelapse_start(app, req.path)
	case .Bake:
		bake_to_folder(app, req.path)
	case .Save_Strokes:
		_ = strokes_save(app, req.path)
	case .Load_Strokes:
		_ = strokes_load(app, req.path)
	case .Recover:
		return autosave_recover(app, req.path)
	case .Discard_Autosave:
		autosave_discard(app, req.path)
	case .Run_Script:
		script_file_run(app, req.path)
	}
	return true
}

// Writes the viewport as the last frame drew it, without the brush outline or gizmo,
// to a PNG file (or a binary PPM when the path ends in .ppm, for the render checks).
screenshot_save :: proc(app: ^App, path: string) -> bool {
	start := time.tick_now()
	w, h := int(app.target.width), int(app.target.height)
	// What the viewport shows: the studio render's image while it is on.
	shown := render.studio_texture(&app.studio) if app.studio_on else nil
	pixels := render.viewport_download(&app.renderer, &app.target, context.temp_allocator, shown)
	if pixels == nil {
		file_note(app, true, "Could not read the viewport back: %s", sdl.GetError())
		return false
	}
	if !image_save(app, path, pixels, w, h) do return false
	file_note(app, false, "Saved %s (%d x %d) in %.0f ms", filepath.base(path), w, h, time.duration_milliseconds(time.tick_since(start)))
	return true
}

// Writes RGBA8 rows, top to bottom, to a PNG file (or a binary PPM when the path ends
// in .ppm), noting a failure.
image_save :: proc(app: ^App, path: string, pixels: []u8, w, h: int) -> bool {
	written: bool
	if strings.equal_fold(filepath.ext(path), ".ppm") {
		written = write_ppm(path, pixels, w, h)
	} else {
		data := png_write.encode(pixels, w, h, alpha = false, allocator = context.temp_allocator)
		written = os.write_entire_file(path, data) == nil
	}
	if !written {
		file_note(app, true, "Could not write %s", path)
		return false
	}
	return true
}

// Where Ctrl+S saves the scene from now on.
scene_remember_path :: proc(app: ^App, path: string) {
	delete(app.scene_path)
	app.scene_path = strings.clone(path)
	versions_refresh(app)
}

// Reads an OBJ or PLY file into a new object beside the others, sized like a sphere
// (its place in the file is kept for export: see Object.file). Returns false only on a
// GPU failure.
scene_import :: proc(app: ^App, path: string) -> bool {
	start := time.tick_now()
	name := filepath.base(path)
	data, err := file_read_any(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot import %s: %v", name, err)
		return true
	}
	defer delete(data)
	read := time.tick_now()
	mesh: geom.Mesh
	failed: geom.Mesh_File_Error
	line: int
	kind := strings.to_lower(filepath.ext(path), context.temp_allocator)
	// A content:// URI from Android's picker has no extension, so there the bytes decide:
	// a PLY file starts with "ply", and anything else is tried as OBJ text.
	if strings.has_prefix(path, "content://") && kind != ".obj" && kind != ".ply" do kind = ".ply" if strings.has_prefix(string(data), "ply") else ".obj"
	switch kind {
	case ".obj":
		mesh, failed, line = geom.mesh_read_obj(data, &app.pool)
	case ".ply":
		mesh, failed, line = geom.mesh_read_ply(data, &app.pool)
	case:
		file_note(app, true, "Cannot import %s: only .obj and .ply files import", name)
		return true
	}
	cleaned: geom.Mesh_Clean_Report
	if failed == .None do cleaned, failed = geom.mesh_clean(&mesh, &app.pool)
	if failed != .None {
		geom.mesh_destroy(&mesh)
		if line > 0 {
			file_note(app, true, "Cannot import %s, line %d: %s", name, line, geom.MESH_FILE_ERROR_TEXT[failed])
		} else {
			file_note(app, true, "Cannot import %s: %s", name, geom.MESH_FILE_ERROR_TEXT[failed])
		}
		return true
	}
	parsed := time.tick_now()
	center, radius := geom.mesh_normalize(&mesh, &app.pool)
	edges := geom.mesh_edges(mesh, &app.pool)
	flipped := geom.mesh_edges_closed(edges) && edges.volume < 0
	// A closed surface facing inward would be culled from outside, and remeshes empty.
	if flipped do geom.mesh_flip(&mesh, &app.pool)
	free_all(context.temp_allocator)
	read_ms := time.duration_milliseconds(time.tick_diff(start, read))
	parse_ms := time.duration_milliseconds(time.tick_diff(read, parsed))
	// The note leads with what matters most: a surface that is not closed, then the size.
	closed := geom.mesh_edges_closed(edges)
	note := strings.builder_make(context.temp_allocator)
	strings.write_string(&note, fmt.tprintf("Imported %s", name))
	if closed {
		strings.write_string(&note, ":")
	} else {
		strings.write_string(&note, fmt.tprintf(", but its surface is not closed (%d border edges, %d flipped or shared by more than two triangles): it sculpts, but subdivision, HD and remesh need a closed one.", edges.border, edges.bad))
	}
	strings.write_string(&note, fmt.tprintf(" %d vertices, %d triangles, read in %.0f ms and parsed in %.0f ms", geom.mesh_vertex_count(mesh), geom.mesh_triangle_count(mesh), read_ms, parse_ms))
	if cleaned != {} do strings.write_string(&note, fmt.tprintf("; %d vertices welded, %d triangles and %d vertices dropped", cleaned.welded, cleaned.dropped_triangles, cleaned.dropped_vertices))
	if flipped do strings.write_string(&note, "; turned outward")
	file_note(app, !closed, "%s", strings.to_string(note))
	stem := filepath.stem(path)
	if !scene_add_mesh(app, mesh, stem if stem != "" else "Import", {position = center, scale = radius}, {position = next_free_position(app), scale = 1}, start) do return false
	// After the new object's stats reset.
	app.stats.file_read_ms, app.stats.file_parse_ms = read_ms, parse_ms
	return true
}

// Writes the object's shown level (packed, if dynamic) to an OBJ, PLY, binary glTF or
// USD text file, where it was in the file it came from (Object.file); Move tool placement
// is not written. glTF and USD also carry the normals and the sculpt layers, as morph
// targets or blend shapes (shape keys) at their strengths; USD the polygroups too, and a
// retopologized base level as its quads and UVs, as OBJ does. Returns whether it was
// written.
object_export :: proc(app: ^App, obj: ^Object, path: string) -> bool {
	start := time.tick_now()
	name := filepath.base(path)
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	if ext != ".obj" && ext != ".ply" && ext != ".glb" && ext != ".usda" {
		file_note(app, true, "Cannot export to %s: the name needs to end in .obj, .ply, .glb or .usda", name)
		return false
	}
	// A stroke, pose or slider drag under way would otherwise land half in the file, and
	// a recording stroke's movement in the base rather than its layer.
	stroke_finish(app)
	inspector_drags_end(app)
	lv := sculpt.levels_current(&obj.levels)
	positions, normals, indices := lv.mesh.positions[:], lv.mesh.normals[:], lv.mesh.indices[:]
	// Polypaint as plain vertex colours: the paint over white as far as it covers.
	colors: [][3]u8
	if c := lv.sculptor.color; c != nil && !object_dynamic(obj) {
		colors = make([][3]u8, len(c), context.temp_allocator)
		for x, v in c {
			for k in 0 ..< 3 do colors[v][k] = u8((u32(x[k]) * u32(x.a) + 255 * (255 - u32(x.a)) + 127) / 255)
		}
	}
	packed: geom.Mesh
	defer geom.mesh_destroy(&packed)
	if object_dynamic(obj) {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(&lv.sculptor)
		delete(mask)
		positions, normals, indices = packed.positions[:], packed.normals[:], packed.indices[:]
	}
	out := make([dynamic]u8)
	defer delete(out)
	layers := 0
	switch {
	case ext == ".glb" || ext == ".usda":
		// Dynamic topology bakes the layers, so a dynamic object has none to write.
		sculpt.sculptor_refresh_normals(&lv.sculptor)
		list := sculpt.sculptor_layers(&lv.sculptor)
		morphs := make([]geom.Morph_Target, len(list), context.temp_allocator)
		for &l, k in list {
			vertices, deltas := sculpt.sculptor_layer_sparse(&lv.sculptor, k, context.temp_allocator)
			morphs[k] = {sculpt.sculptor_layer_name(&l), sculpt.layer_weight(l), vertices, deltas}
		}
		layers = len(morphs)
		m := geom.Mesh_Export {
			name      = object_label(obj),
			positions = positions,
			normals   = normals,
			indices   = indices,
			colors    = colors,
			morphs    = morphs,
			scale     = obj.file.scale,
			offset    = obj.file.position,
		}
		if ext == ".usda" {
			usd_extras(obj, lv, &m)
			geom.mesh_write_usda(&out, m, &app.pool)
		} else if !geom.mesh_write_glb(&out, m, &app.pool) {
			free_all(context.temp_allocator)
			file_note(app, true, "Cannot export %s: a glTF file holds at most 4 GB; fewer layers or a lower level would fit", name)
			return false
		}
	case ext == ".obj" && obj.levels.current == 0 && sculpt.levels_has_quads(&obj.levels) && !object_dynamic(obj):
		// A retopologized object's base level goes as its quads, with their UVs.
		q := sculpt.levels_quad_mesh(&obj.levels)
		geom.quad_mesh_write_obj(&out, q.positions, q.quads, obj.levels.faces.uv.uvs, obj.file.scale, obj.file.position)
	case ext == ".obj":
		geom.mesh_write_obj(&out, positions, indices, obj.file.scale, obj.file.position, &app.pool, colors)
	case:
		geom.mesh_write_ply(&out, positions, indices, obj.file.scale, obj.file.position, &app.pool, colors)
	}
	free_all(context.temp_allocator)
	if !write_file_safely(app, path, out[:], "export") do return false
	// The times shown are this action's alone.
	app.stats.file_read_ms, app.stats.file_parse_ms = 0, 0
	app.stats.file_write_ms = time.duration_milliseconds(time.tick_since(start))
	with := fmt.tprintf(", %d %s as shape keys", layers, "layer" if layers == 1 else "layers") if layers > 0 else ""
	file_note(app, false, "Exported %s: %d vertices, %d triangles%s, %d MB in %.0f ms", name, len(positions), len(indices) / 3, with, len(out) >> 20, app.stats.file_write_ms)
	return true
}

// What USD carries beyond glTF: a retopologized base level's quads and UVs, as OBJ
// writes them, and the polygroups, one a face. A quad takes the group its first corner
// shows, since the base's triangles are in the sculptor's order rather than two a quad.
@(private = "file")
usd_extras :: proc(obj: ^Object, lv: ^sculpt.Level, m: ^geom.Mesh_Export) {
	g := lv.sculptor.groups
	if obj.levels.current == 0 && sculpt.levels_has_quads(&obj.levels) && !object_dynamic(obj) {
		m.quads, m.uvs = obj.levels.faces.quads, obj.levels.faces.uv.uvs
		if g.tris != nil && g.vertex != nil {
			groups := make([]u16, len(m.quads), context.temp_allocator)
			for q, i in m.quads do groups[i] = g.vertex[q[0]]
			m.groups = groups
		}
		return
	}
	// A dynamic object's packed triangles are not the sculptor's, and it has no groups
	// to write.
	if g.tris != nil && !object_dynamic(obj) do m.groups = g.tris
}

// Saves every object with all its levels and mask, and the camera. HD detail is not
// saved (the HD steps are); the undo history stays as it is. Returns whether it was
// written.
scene_save :: proc(app: ^App, path: string, copy := false) -> bool {
	stroke_finish(app)
	start := time.tick_now()
	out := make([dynamic]u8)
	defer delete(out)
	scene_header_put(app, &out)
	hd_dropped := 0
	for obj in app.scene.objects {
		object_hd_leave(app, obj)
		if sculpt.levels_hd_stats(&obj.levels).stored_nodes > 0 do hd_dropped += 1
		object_put(app, &out, obj)
	}
	partial, err := write_partial(path, out[:])
	if err != "" {
		file_note(app, true, "Cannot save %s: %s", filepath.base(path), err)
		return false
	}
	// The file this save replaces becomes a version first, so that at every moment the
	// path holds a whole file and the old one is still somewhere. A copy keeps none: it
	// is a new file, and one it lands on was not this scene's.
	keep := int(versions_kept(app.versions_kept))
	keep_err := ""
	if !copy && keep > 0 && os.exists(path) do _, keep_err = version_keep(path)
	if err = replace_partial(partial, path); err != "" {
		file_note(app, true, "Cannot save %s: %s", filepath.base(path), err)
		return false
	}
	if !copy {
		versions_prune(path, keep)
		autosave_scene_saved(app, path)
	}
	// The times shown are this action's alone.
	app.stats.file_read_ms, app.stats.file_parse_ms = 0, 0
	app.stats.file_write_ms = time.duration_milliseconds(time.tick_since(start))
	what := fmt.tprintf("%s: %d %s, %d MB in %.0f ms", filepath.base(path), len(app.scene.objects), "object" if len(app.scene.objects) == 1 else "objects", len(out) >> 20, app.stats.file_write_ms)
	hd := fmt.tprintf(". The HD detail of %d of them is not saved, only their HD steps", hd_dropped) if hd_dropped > 0 else ""
	switch {
	case copy && app.scene_path != "":
		file_note(app, hd_dropped > 0, "Saved a copy as %s%s; this scene still saves to %s", what, hd, filepath.base(app.scene_path))
	case copy:
		file_note(app, hd_dropped > 0, "Saved a copy as %s%s; this scene is still not saved", what, hd)
	case keep_err != "":
		file_note(app, true, "Saved %s%s, but the earlier save was not kept: %s", what, hd, keep_err)
	case:
		file_note(app, hd_dropped > 0, "Saved %s%s", what, hd)
	}
	return true
}

// Above this many bytes (about 1M vertices) a save stops the frame for long enough that
// the window shows "Saving..." first instead of freezing without a word.
SAVE_SHOW_FIRST :: 32 << 20

// About what the scene's file will take: what saving it costs, levels and all.
scene_save_bytes :: proc(app: ^App) -> int {
	bytes := 0
	for obj in app.scene.objects do bytes += object_put_estimate(obj)
	return bytes
}

// About what exporting the object's shown level writes, in the biggest of the binary
// formats, or as USD text, which spells out every number and takes several times as long.
object_export_bytes :: proc(obj: ^Object, path := "") -> int {
	lv := sculpt.levels_current(&obj.levels)
	if strings.equal_fold(filepath.ext(path), ".usda") do return 130 * len(lv.mesh.positions) + 10 * len(lv.mesh.indices)
	return 40 * len(lv.mesh.positions) + 4 * len(lv.mesh.indices)
}

// Runs the save or export that was waiting for its toast, once the toast has come in,
// or at once when `now` (anything else about to change the scene, or the app closing):
// it writes the scene, or the selected object, as it stands, whatever the frames in
// between did.
save_pending :: proc(app: ^App, now: bool) {
	if app.saving.kind == .None do return
	if !now && app.kit.ctx.time - app.saving_at < f64(app.kit.ctx.theme.toast_time) + 0.05 do return
	req := app.saving
	app.saving = {}
	defer file_request_free(req)
	if req.kind == .Export {
		if obj := selected_object(app); obj != nil {
			_ = object_export(app, obj, req.path)
		} else {
			file_note(app, true, "Select an object to export first")
		}
		return
	}
	autosave_settle(app)
	scene_save_request(app, req)
}

// Saves as `req` asks: as the scene's file, or as a copy that leaves the scene's file
// as it was.
@(private = "file")
scene_save_request :: proc(app: ^App, req: File_Request) {
	if req.kind == .Save_Copy {
		_ = scene_save(app, req.path, copy = true)
	} else if scene_save(app, req.path) {
		scene_remember_path(app, req.path)
	}
}

// The scene file's start: its magic and version, how many objects follow, the selected
// one, the next id and the camera.
scene_header_put :: proc(app: ^App, out: ^[dynamic]u8) {
	append(out, SCENE_MAGIC)
	geom.byte_put(out, SCENE_VERSION)
	geom.byte_put(out, u32(len(app.scene.objects)))
	geom.byte_put(out, i32(app.scene.selected))
	geom.byte_put(out, i32(app.scene.next_id))
	c := app.camera
	geom.byte_put(out, c.target)
	geom.byte_put(out, c.distance)
	geom.byte_put(out, c.yaw)
	geom.byte_put(out, c.pitch)
	geom.byte_put(out, c.roll)
	geom.byte_put(out, u8(app.scene.solo)) // version 8
	// Version 9: the folders, each with how it is shown.
	geom.byte_put(out, u32(len(app.scene.folders)))
	for f in app.scene.folders {
		geom.byte_put(out, i32(f.id))
		geom.byte_put_string(out, f.name)
		geom.byte_put(out, u8(f.open) | u8(f.off) << 1 | u8(f.ghost) << 2)
	}
	geom.byte_put(out, i32(app.scene.next_folder_id))
}

// The folders a scene file of `version` lists after its header, owned; ok is false
// when they are damaged (an id twice or not positive, unknown flags), with none kept.
folders_get :: proc(r: ^geom.Byte_Reader, version: u32) -> (folders: [dynamic]Folder, next_id: int, ok: bool) {
	if version < 9 do return nil, 0, true
	count := int(geom.byte_get(r, u32))
	if !r.ok || count > MAX_FOLDERS do return nil, 0, false
	folders = make([dynamic]Folder, 0, count)
	for _ in 0 ..< count {
		f := Folder{id = int(geom.byte_get(r, i32)), name = geom.byte_get_string(r)}
		bits := geom.byte_get(r, u8)
		f.open, f.off, f.ghost = bits & 1 != 0, bits & 2 != 0, bits & 4 != 0
		append(&folders, f)
		unique := true
		for g in folders[:len(folders) - 1] do unique &&= g.id != f.id
		if !r.ok || f.id <= 0 || bits > 7 || !unique {
			folders_clear(&folders)
			delete(folders)
			return nil, 0, false
		}
	}
	next_id = int(geom.byte_get(r, i32))
	return folders, next_id, true
}

// More folders than a scene file may list: a count past it is damage.
MAX_FOLDERS :: 4096

// Replaces the scene with a saved one: every object is read and uploaded before
// anything of the old scene goes, so a damaged file leaves the scene as it was (and
// for a moment both are in memory). `opened` says whether it was; ok is false only on
// a GPU failure.
scene_open :: proc(app: ^App, path: string) -> (opened, ok: bool) {
	start := time.tick_now()
	name := filepath.base(path)
	data, err := file_read_any(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot open %s: %v", name, err)
		return false, true
	}
	defer delete(data)
	r := geom.byte_reader(data)
	magic: [len(SCENE_MAGIC)]u8
	geom.byte_get_slice(&r, magic[:])
	version := geom.byte_get(&r, u32)
	if !r.ok || string(magic[:]) != SCENE_MAGIC || version < 1 || version > SCENE_VERSION {
		file_note(app, true, "Cannot open %s: it is not a scene this version of the app reads", name)
		return false, true
	}
	count := int(geom.byte_get(&r, u32))
	selected := int(geom.byte_get(&r, i32))
	next_id := int(geom.byte_get(&r, i32))
	view := app.camera
	view.target = geom.byte_get(&r, Vec3)
	view.distance = geom.byte_get(&r, f32)
	view.yaw = geom.byte_get(&r, f32)
	view.pitch = geom.byte_get(&r, f32)
	view.roll = geom.byte_get(&r, f32) if version >= 7 else 0
	solo := geom.byte_get(&r, u8) if version >= 8 else 0
	folders, next_folder_id, folders_ok := folders_get(&r, version)
	defer if folders != nil {
		folders_clear(&folders)
		delete(folders)
	}
	if !folders_ok || !r.ok || solo > 1 || count > len(data) || selected >= count || !finite(view.target) || !finite({view.distance, view.yaw, view.pitch}) || !finite({view.roll, 0, 0}) {
		file_note(app, true, "Cannot open %s: it is damaged", name)
		return false, true
	}
	view.distance = clamp(view.distance, camera.MIN_DISTANCE, camera.MAX_DISTANCE)
	view.yaw, view.pitch, view.roll = camera.wrap_angle(view.yaw), camera.wrap_angle(view.pitch), camera.wrap_angle(view.roll)

	objects := make([dynamic]^Object, 0, count)
	defer delete(objects)
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	for i in 0 ..< count {
		obj, read, made := object_get(app, &r, version)
		if !read {
			file_note(app, true, "Cannot open %s: object %d of %d is damaged", name, i + 1, count)
			for other in objects do object_discard(app, other)
			return false, true
		}
		if !made {
			for other in objects do object_discard(app, other)
			return false, false
		}
		next_id = max(next_id, obj.id)
		append(&objects, obj)
	}

	scene_replace(app, objects[:], selected if selected >= 0 else (0 if count > 0 else -1), next_id, view)
	app.scene.solo = solo == 1
	delete(app.scene.folders)
	app.scene.folders, folders = folders, nil
	app.scene.next_folder_id = max(next_folder_id, 0)
	scene_folders_normalize(app)
	scene_selection_fix(app)
	autosave_scene_saved(app, path)
	app.stats.file_read_ms = time.duration_milliseconds(time.tick_since(start))
	vertices := 0
	for obj in objects do vertices += object_vertex_count(obj)
	file_note(app, false, "Opened %s: %d %s, %d vertices shown, in %.0f ms", name, count, "object" if count == 1 else "objects", vertices, app.stats.file_read_ms)
	return true, true
}

// Makes `objects` the scene in place of the one there, as opening a scene or starting a
// new one does, with `selected` selected and the camera at `view` (its projection kept,
// a view setting rather than part of the scene). The old objects go, and with them the
// History, which names objects by id (the new ones may reuse the old ids), and whatever
// was going on in the old scene: a stroke, a replay, the timeline's play or scrub, a
// time-lapse. The caller builds every new object first, so one that fails to build
// leaves the old scene as it was.
scene_replace :: proc(app: ^App, objects: []^Object, selected, next_id: int, view: camera.Orbit) {
	replay_stop(app)
	stroke_finish(app)
	timelapse_stop(app, "the scene was replaced")
	app.timeline.playing, app.timeline.seeking = false, false
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	history_clear(&app.history)
	for obj in app.scene.objects do object_free(app, obj)
	clear(&app.scene.objects)
	append(&app.scene.objects, ..objects)
	app.scene.selected = selected
	app.scene.solo = false
	folders_clear(&app.scene.folders)
	app.scene.next_folder_id = 0
	// A drag over the old tree, and the column changes it queued, name the old objects.
	app.kit.tree_drag, app.kit.tree_column = {}, {}
	clear(&app.scene.also)
	// Ids only grow, so nothing kept by id (the pivot, a pending tap) finds a new object.
	app.scene.next_id = max(next_id, app.scene.next_id)
	ortho := app.camera.ortho
	app.camera = view
	app.camera.ortho = ortho
	camera_history_clear(app)
	app.move.drag = {}
	// The last stroke was on an object of the old scene, whose id the new one may reuse.
	app.pivot.set, app.pivot.pinned = false, false
	app.stroke_end.valid = false
	clear(&app.stroke.pending)
	app.stats = {}
	render.viewport_invalidate(&app.target)
}

// Replaces the scene with one object: a sphere or a starter of about `vertices` vertices
// (with its subdivision levels), seen from the front, with no file to save to (Save then asks where)
// and an empty History, as Menu > New scene does. Returns false only on a GPU failure;
// a shape that cannot be built leaves the scene as it was.
scene_new :: proc(app: ^App, shape: geom.Primitive, vertices: int) -> bool {
	start := time.tick_now()
	obj, ok := object_make_primitive(app, shape, vertices, {scale = 1})
	if obj == nil do return ok
	obj.id = app.scene.next_id + 1
	// The view the app starts with, which shows a starter from the front and a side.
	scene_replace(app, {obj}, 0, obj.id, camera.orbit_default())
	scene_remember_path(app, "")
	autosave_scene_saved(app, "")
	levels := len(obj.levels.levels)
	report(app, nil, {}, "New scene: %v, %d %s, %s vertices, in %.0f ms", shape, levels, "level" if levels == 1 else "levels",
		count_label(object_vertex_count(obj)), time.duration_milliseconds(time.tick_since(start)))
	return true
}

// Appends one object as the scene file stores it: its id, name, placement and every
// level with the mask. Leaves any HD window first, whose detail is not stored.
object_put :: proc(app: ^App, out: ^[dynamic]u8, obj: ^Object) {
	object_hd_leave(app, obj)
	_ = object_put_bytes(out, obj)
	free_all(context.temp_allocator)
}

// object_put without leaving HD, for the autosave thread, which writes as `opts` says
// and may be stopped (false, with part of the object in `out`).
object_put_bytes :: proc(out: ^[dynamic]u8, obj: ^Object, opts := sculpt.Write_Options{}) -> bool {
	// Room for it up front: a 50M-vertex object is about 2 GB, and growing the buffer to
	// that a doubling at a time copies it all over again and touches twice the memory.
	reserve(out, len(out) + object_put_estimate(obj))
	geom.byte_put(out, i32(obj.id))
	geom.byte_put_string(out, obj.name)
	put_transform(out, obj.transform)
	put_transform(out, obj.file)
	geom.byte_put(out, obj.transform.rotation) // version 2
	geom.byte_put(out, u8(obj.boolean)) // version 5
	geom.byte_put(out, object_view_bits(obj)) // version 8
	geom.byte_put(out, i32(obj.folder)) // version 9
	return sculpt.levels_write(&obj.levels, out, opts)
}

// About how many bytes object_put writes for `obj`: every level's positions and sculpt
// layers, the base's triangles and node layout, and the shown level's mask, paint and
// groups.
@(private = "file")
object_put_estimate :: proc(obj: ^Object) -> int {
	bytes := 4096
	for lv, j in obj.levels.levels {
		bytes += size_of(Vec3) * len(lv.mesh.positions)
		if j == 0 do bytes += size_of(u32) * len(lv.mesh.indices) + 8 * len(lv.sculptor.nodes)
		// Layers are written whole, a displacement a vertex each, with a name and sliders.
		bytes += len(lv.sculptor.layers.list) * (64 + size_of(Vec3) * len(lv.mesh.positions))
	}
	s := &sculpt.levels_current(&obj.levels).sculptor
	n := len(s.mesh.positions)
	if s.mask != nil do bytes += n
	if s.color != nil do bytes += size_of(sculpt.Color) * n
	if s.groups.tris != nil do bytes += size_of(u16) * len(s.groups.tris)
	// A set is written again in file order, at most a byte a vertex.
	for set in sculpt.levels_sets(&obj.levels) do bytes += 64 + set.vertices
	return bytes
}

// An object's eye (off is 1) and ghost (2) as the scene file stores them.
OBJECT_VIEW_BITS :: 3
object_view_bits :: proc(obj: ^Object) -> u8 {return u8(obj.off) | u8(obj.ghost) << 1}

// Reads one object written by object_put (by a scene file of `version`) and uploads
// its shown level. `read` is false
// when the bytes are damaged (no object is made); `made` is false on a GPU failure,
// with the object returned for the caller to discard.
object_get :: proc(app: ^App, r: ^geom.Byte_Reader, version := SCENE_VERSION) -> (obj: ^Object, read, made: bool) {
	obj = new(Object)
	object_get_fields(r, obj, version)
	if !r.ok || obj.transform.scale <= 0 || obj.file.scale <= 0 || !sculpt.levels_read(&obj.levels, r, &app.pool) {
		delete(obj.name)
		free(obj)
		free_all(context.temp_allocator)
		return nil, false, false
	}
	lv := sculpt.levels_current(&obj.levels)
	obj.gpu[obj.levels.current], made = render.mesh_buffers_create(&app.renderer, lv.mesh, lv.sculptor.mask)
	free_all(context.temp_allocator)
	return obj, true, made
}

// Reads what object_put writes before the levels: the id, name, placement, boolean mode
// and view flags, as a file of `version` has them; r.ok goes false on damage. The
// caller owns obj.name.
object_get_fields :: proc(r: ^geom.Byte_Reader, obj: ^Object, version := SCENE_VERSION) {
	obj.id = int(geom.byte_get(r, i32))
	obj.name = geom.byte_get_string(r)
	obj.transform = get_transform(r)
	obj.file = get_transform(r)
	if version >= 2 {
		obj.transform.rotation = geom.byte_get(r, Vec3)
		if !finite(obj.transform.rotation) do r.ok = false
	}
	if version >= 5 {
		mode := geom.byte_get(r, u8)
		if mode > u8(max(Boolean_Mode)) do r.ok = false
		else do obj.boolean = Boolean_Mode(mode)
	}
	if version >= 8 {
		bits := geom.byte_get(r, u8)
		if bits > OBJECT_VIEW_BITS do r.ok = false
		obj.off, obj.ghost = bits & 1 != 0, bits & 2 != 0
	}
	if version >= 9 {
		obj.folder = int(geom.byte_get(r, i32))
		if obj.folder < 0 do r.ok = false
	}
}

// Frees an object read for a scene that never got it: it has no history and draws
// nothing yet. The caller has waited for the GPU.
object_discard :: proc(app: ^App, obj: ^Object) {
	for &gpu in obj.gpu do render.mesh_buffers_destroy(&app.renderer, &gpu)
	sculpt.levels_destroy(&obj.levels)
	delete(obj.name)
	free(obj)
}

@(private = "file")
put_transform :: proc(out: ^[dynamic]u8, t: Transform) {
	geom.byte_put(out, t.position)
	geom.byte_put(out, t.scale)
}

@(private = "file")
get_transform :: proc(r: ^geom.Byte_Reader) -> Transform {
	t := Transform{position = geom.byte_get(r, Vec3), scale = geom.byte_get(r, f32)}
	if !finite(t.position) || !finite({t.scale, 0, 0}) do r.ok = false
	return t
}

@(private = "file")
finite :: proc(v: Vec3) -> bool {
	for x in v do if math.is_nan(x) || math.is_inf(x) do return false
	return true
}

// Writes next to the file, makes sure the bytes reached the disk, and renames over it,
// so a failed write, a crash or a power cut never leaves a half-written file where a good
// one was, and a note saying the file was saved is true when it shows. `what` names the
// action for the note.
write_file_safely :: proc(app: ^App, path: string, data: []u8, what: string) -> bool {
	if err := write_durably(path, data); err != "" {
		file_note(app, true, "Cannot %s %s: %s", what, filepath.base(path), err)
		return false
	}
	return true
}

// Big writes go out in pieces so that one call never holds a whole scene's worth of the
// system's write buffers (and an autosave thread's write yields between them).
WRITE_CHUNK :: 8 << 20

// Writes `data` to path.partial a chunk at a time, syncs it, and replaces `path` with it
// (replace_durably). Returns what went wrong, "" for nothing; nothing is left behind.
write_durably :: proc(path: string, data: []u8) -> string {
	partial, err := write_partial(path, data)
	if err != "" do return err
	return replace_partial(partial, path)
}

// The first half of write_durably: `data` in path.partial, synced (temp path). On a
// failure nothing is left behind.
write_partial :: proc(path: string, data: []u8) -> (partial: string, err: string) {
	partial = strings.concatenate({path, ".partial"}, context.temp_allocator)
	f, oerr := os.open(partial, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if oerr != nil do return "", fmt.tprintf("cannot write %s: %v", filepath.base(partial), oerr)
	for at := 0; at < len(data); at += WRITE_CHUNK {
		if _, werr := os.write(f, data[at:min(at + WRITE_CHUNK, len(data))]); werr != nil {
			os.close(f)
			_ = os.remove(partial)
			return "", fmt.tprintf("cannot write %s: %v", filepath.base(partial), werr)
		}
	}
	// A power cut after the rename must not find an empty file where the old one was.
	serr := os.sync(f)
	os.close(f)
	if serr != nil {
		_ = os.remove(partial)
		return "", fmt.tprintf("cannot write %s: %v", filepath.base(partial), serr)
	}
	return partial, ""
}

// The second half: the synced partial replaces `path` (replace_durably), or is removed.
replace_partial :: proc(partial, path: string) -> string {
	if err := replace_durably(partial, path); err != nil {
		_ = os.remove(partial)
		return fmt.tprintf("cannot write %s: %v", filepath.base(path), err)
	}
	return ""
}
