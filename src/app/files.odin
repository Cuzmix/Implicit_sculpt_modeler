package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
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
	Open,   // a .sculpt file replaces the scene
	Alpha,  // an image becomes a brush alpha (alphas.odin)
}

File_Request :: struct {
	kind: File_Kind,
	path: string, // from runtime.heap_allocator(): a dialog's thread may make it
}

// What the menu bar shows of the last file action, and for how long: the log alone may
// be in a console nobody watches.
File_Note :: struct {
	text:    string, // owned
	warning: bool,
	at:      time.Tick,
}

FILE_NOTE_SHOWN :: 15 * time.Second

// The native scene file starts with these bytes, then its version.
SCENE_MAGIC :: "SCULPTSC"
SCENE_VERSION :: u32(1)

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
@(private = "file")
SCENE_FILTERS := [?]sdl.DialogFileFilter{{"Sculpt scene", "sculpt"}}
@(private = "file")
IMAGE_FILTERS := [?]sdl.DialogFileFilter{{"Images (PNG, JPEG, BMP, TGA, QOI)", "png;jpg;jpeg;bmp;tga;qoi"}}

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
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(MESH_FILTERS[:]), len(MESH_FILTERS), nil)
	case .Save:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(SCENE_FILTERS[:]), len(SCENE_FILTERS), nil)
	case .Open:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(SCENE_FILTERS[:]), len(SCENE_FILTERS), nil, false)
	case .Alpha:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(IMAGE_FILTERS[:]), len(IMAGE_FILTERS), nil, false)
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
		case .Save: suffix = ".sculpt"
		case .Export: suffix = ".ply" if filter == 2 else ".obj"
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

file_request_free :: proc(req: File_Request) {
	delete(req.path, runtime.heap_allocator())
}

// Drops a request no frame took and the last note, at exit.
file_shutdown :: proc(app: ^App) {
	sync.lock(&pending.lock)
	file_request_free(pending.req)
	delete(pending.error, runtime.heap_allocator())
	pending.req, pending.error = {}, ""
	sync.unlock(&pending.lock)
	delete(app.file_note.text)
	app.file_note = {}
}

// Logs a file action's outcome and keeps it for the menu bar.
file_note :: proc(app: ^App, warning: bool, format: string, args: ..any) {
	text := fmt.aprintf(format, ..args)
	if warning do log.warn(text)
	else do log.info(text)
	delete(app.file_note.text)
	app.file_note = {text, warning, time.tick_now()}
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
		_ = object_export(app, obj, req.path)
	case .Save:
		if scene_save(app, req.path) do scene_remember_path(app, req.path)
	case .Open:
		opened, ok := scene_open(app, req.path)
		if opened do scene_remember_path(app, req.path)
		return ok
	case .Alpha:
		_ = alpha_load(app, req.path)
	}
	return true
}

// Where Ctrl+S saves the scene from now on.
scene_remember_path :: proc(app: ^App, path: string) {
	delete(app.scene_path)
	app.scene_path = strings.clone(path)
}

// Reads an OBJ or PLY file into a new object beside the others, sized like a sphere
// (its place in the file is kept for export: see Object.file). Returns false only on a
// GPU failure.
scene_import :: proc(app: ^App, path: string) -> bool {
	start := time.tick_now()
	name := filepath.base(path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot import %s: %v", name, err)
		return true
	}
	defer delete(data)
	read := time.tick_now()
	mesh: geom.Mesh
	failed: geom.Mesh_File_Error
	line: int
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
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

// Writes the object's shown level (packed, if dynamic) to an OBJ or PLY file, where
// it was in the file it came from (Object.file); Move tool placement is not written.
// Returns whether it was written.
object_export :: proc(app: ^App, obj: ^Object, path: string) -> bool {
	start := time.tick_now()
	name := filepath.base(path)
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	if ext != ".obj" && ext != ".ply" {
		file_note(app, true, "Cannot export to %s: the name needs to end in .obj or .ply", name)
		return false
	}
	lv := sculpt.levels_current(&obj.levels)
	positions, indices := lv.mesh.positions[:], lv.mesh.indices[:]
	packed: geom.Mesh
	defer geom.mesh_destroy(&packed)
	if object_dynamic(obj) {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(&lv.sculptor)
		delete(mask)
		positions, indices = packed.positions[:], packed.indices[:]
	}
	out := make([dynamic]u8)
	defer delete(out)
	if ext == ".obj" {
		geom.mesh_write_obj(&out, positions, indices, obj.file.scale, obj.file.position, &app.pool)
	} else {
		geom.mesh_write_ply(&out, positions, indices, obj.file.scale, obj.file.position, &app.pool)
	}
	free_all(context.temp_allocator)
	if !write_file_safely(app, path, out[:], "export") do return false
	// The times shown are this action's alone.
	app.stats.file_read_ms, app.stats.file_parse_ms = 0, 0
	app.stats.file_write_ms = time.duration_milliseconds(time.tick_since(start))
	file_note(app, false, "Exported %s: %d vertices, %d triangles, %d MB in %.0f ms", name, len(positions), len(indices) / 3, len(out) >> 20, app.stats.file_write_ms)
	return true
}

// Saves every object with all its levels and mask, and the camera. HD detail is not
// saved (the HD steps are); the undo history stays as it is. Returns whether it was
// written.
scene_save :: proc(app: ^App, path: string) -> bool {
	stroke_finish(app)
	start := time.tick_now()
	out := make([dynamic]u8)
	defer delete(out)
	append(&out, SCENE_MAGIC)
	geom.byte_put(&out, SCENE_VERSION)
	geom.byte_put(&out, u32(len(app.scene.objects)))
	geom.byte_put(&out, i32(app.scene.selected))
	geom.byte_put(&out, i32(app.scene.next_id))
	c := app.camera
	geom.byte_put(&out, c.target)
	geom.byte_put(&out, c.distance)
	geom.byte_put(&out, c.yaw)
	geom.byte_put(&out, c.pitch)
	hd_dropped := 0
	for obj in app.scene.objects {
		object_hd_leave(app, obj)
		if sculpt.levels_hd_stats(&obj.levels).stored_nodes > 0 do hd_dropped += 1
		object_put(app, &out, obj)
	}
	if !write_file_safely(app, path, out[:], "save") do return false
	// The times shown are this action's alone.
	app.stats.file_read_ms, app.stats.file_parse_ms = 0, 0
	app.stats.file_write_ms = time.duration_milliseconds(time.tick_since(start))
	file_note(app, hd_dropped > 0, "Saved %s: %d %s, %d MB in %.0f ms%s", filepath.base(path), len(app.scene.objects), "object" if len(app.scene.objects) == 1 else "objects", len(out) >> 20, app.stats.file_write_ms,
		fmt.tprintf(". The HD detail of %d of them is not saved, only their HD steps", hd_dropped) if hd_dropped > 0 else "")
	return true
}

// Replaces the scene with a saved one: every object is read and uploaded before
// anything of the old scene goes, so a damaged file leaves the scene as it was (and
// for a moment both are in memory). `opened` says whether it was; ok is false only on
// a GPU failure.
scene_open :: proc(app: ^App, path: string) -> (opened, ok: bool) {
	start := time.tick_now()
	name := filepath.base(path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot open %s: %v", name, err)
		return false, true
	}
	defer delete(data)
	r := geom.byte_reader(data)
	magic: [len(SCENE_MAGIC)]u8
	geom.byte_get_slice(&r, magic[:])
	version := geom.byte_get(&r, u32)
	if !r.ok || string(magic[:]) != SCENE_MAGIC || version != SCENE_VERSION {
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
	if !r.ok || count > len(data) || selected >= count || !finite(view.target) || !finite({view.distance, view.yaw, view.pitch}) {
		file_note(app, true, "Cannot open %s: it is damaged", name)
		return false, true
	}
	view.distance = clamp(view.distance, camera.MIN_DISTANCE, camera.MAX_DISTANCE)
	view.pitch = clamp(view.pitch, -camera.PITCH_LIMIT, camera.PITCH_LIMIT)

	objects := make([dynamic]^Object, 0, count)
	defer delete(objects)
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	for i in 0 ..< count {
		obj, read, made := object_get(app, &r)
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

	stroke_finish(app)
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	// The history names objects by id, and the file's ids can be ones the old scene used.
	history_clear(&app.history)
	for obj in app.scene.objects do object_free(app, obj)
	clear(&app.scene.objects)
	append(&app.scene.objects, ..objects[:])
	app.scene.selected = selected if selected >= 0 else (0 if count > 0 else -1)
	app.scene.next_id = max(next_id, app.scene.next_id)
	app.camera = view
	app.move.drag = {}
	clear(&app.stroke.pending)
	app.stats = {}
	render.viewport_invalidate(&app.target)
	app.stats.file_read_ms = time.duration_milliseconds(time.tick_since(start))
	vertices := 0
	for obj in objects do vertices += object_vertex_count(obj)
	file_note(app, false, "Opened %s: %d %s, %d vertices shown, in %.0f ms", name, count, "object" if count == 1 else "objects", vertices, app.stats.file_read_ms)
	return true, true
}

// Appends one object as the scene file stores it: its id, name, placement and every
// level with the mask. Leaves any HD window first, whose detail is not stored.
object_put :: proc(app: ^App, out: ^[dynamic]u8, obj: ^Object) {
	object_hd_leave(app, obj)
	geom.byte_put(out, i32(obj.id))
	geom.byte_put_string(out, obj.name)
	put_transform(out, obj.transform)
	put_transform(out, obj.file)
	sculpt.levels_write(&obj.levels, out)
	free_all(context.temp_allocator)
}

// Reads one object written by object_put and uploads its shown level. `read` is false
// when the bytes are damaged (no object is made); `made` is false on a GPU failure,
// with the object returned for the caller to discard.
object_get :: proc(app: ^App, r: ^geom.Byte_Reader) -> (obj: ^Object, read, made: bool) {
	obj = new(Object)
	obj.id = int(geom.byte_get(r, i32))
	obj.name = geom.byte_get_string(r)
	obj.transform = get_transform(r)
	obj.file = get_transform(r)
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

// Writes next to the file and then renames over it, so a failed write never leaves a
// half-written file where a good one was. `what` names the action for the note.
@(private = "file")
write_file_safely :: proc(app: ^App, path: string, data: []u8, what: string) -> bool {
	partial := strings.concatenate({path, ".partial"}, context.temp_allocator)
	if err := os.write_entire_file(partial, data); err != nil {
		file_note(app, true, "Cannot %s %s: %v", what, filepath.base(partial), err)
		_ = os.remove(partial)
		return false
	}
	if err := os.rename(partial, path); err != nil {
		file_note(app, true, "Cannot %s over %s: %v", what, filepath.base(path), err)
		_ = os.remove(partial)
		return false
	}
	return true
}
