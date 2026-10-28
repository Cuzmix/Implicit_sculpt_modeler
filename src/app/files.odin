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
import "core:unicode/utf8"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../jobs"
import "../png_write"
import "../render"
import "../sculpt"
import "../poly"
import "../voxel"

// Files: meshes in and out as OBJ, PLY or STL (and out as glTF and USD), and whole scenes saved and opened in the
// native format. A request comes from a File menu dialog, a shortcut or a flag and runs
// at the start of a frame (file_take), as a Scene_Command does.

File_Kind :: enum u8 {
	None,
	Import, // a mesh file becomes a new object
	Export, // the selected object's shown level goes to a mesh file
	Export_Print, // ...to an STL file at its print size (print.odin)
	Save,   // the scene goes to a .sculpt file
	Save_Copy, // the scene goes to a .sculpt file, and stays the file it was (versions.odin)
	Open,   // a .sculpt file replaces the scene
	Alpha,  // an image becomes a brush alpha (alphas.odin)
	Screenshot, // the viewport image goes to a PNG file
	Timelapse,  // the History is recorded as PNG frames into a folder (timeline.odin)
	Turntable,  // the camera goes round the scene, saving each frame into a folder (turntable.odin)
	Bake,       // maps baked onto the selected quad object go into a folder (retopo.odin)
	Save_Strokes, // the recorded strokes go to a .strokes file (replay.odin)
	Load_Strokes, // a .strokes file becomes the recording
	Recover,      // an earlier session's newest autosave replaces the scene (autosave.odin); the path names the session, "" for the newest of any
	Discard_Autosave, // an earlier session's autosaves are deleted; the path names the session
	Open_Version, // an earlier save of the scene's file replaces the scene, which still saves to its file (versions.odin)
	Run_Script,   // a command script file runs as the person's own work (macros.odin)
	Install_Pack, // a content pack goes into the library (pack.odin)
	Make_Pack,    // the person's own alphas and presets go to a content pack file (pack_make.odin)
	Matcap,       // an image of a lit sphere becomes the Custom material's MatCap (matcaps.odin)
	Base_Color_Map, // an image becomes the selected object's base colour map (textures.odin)
	Orm_Map,        // ... its occlusion, roughness and metal map
	Normal_Map,     // ... its normal map
	Link_Send,    // the selected objects go to the Blender link's folder (link.odin); no path
	Link_Get,     // what Blender left in the link's folder comes in; the path is LINK_AUTO for the focus check's
	Environment,  // a panorama lights the physically based materials (environment.odin)
	Export_Workspace, // the current workspace goes to a .workspace file (workspace_file.odin)
	Import_Workspace, // a .workspace file becomes a workspace of the user's own
}

File_Request :: struct {
	kind: File_Kind,
	path: string, // from runtime.heap_allocator(): a dialog's thread may make it
}

// The last file action's outcome, which the interface shows as a note: the log alone may
// be in a console nobody watches. `at` tells a new note from the one already shown.
// The native scene file starts with these bytes, then its version.
SCENE_MAGIC :: "SCULPTSC"
SCENE_VERSION :: u32(28) // 2: each object's rotation; 3: the current level's polypaint and polygroups; 4: sculpt layers, and a retopologized object's quads and UVs (sculpt.levels_write); 5: each object's boolean mode; 6: the base level's node layout (sculpt.levels_write); 7: the camera's roll; 8: each object's eye and ghost, and Solo; 9: folders, and each object's folder; 10: selection sets (sculpt.levels_write); 11: each object's polypaint shown or not (a third view bit); 12: stored visibility (V1 to V8): the slot chosen and used, and each folder's and object's eyes in them; 13: each object's kind (mesh or voxel), a voxel object's resolution and clay after its empty level (voxel.clay_write); 14: each object's material (material_put); 15: each object's polygroups with materials of their own (group_materials_put); 16: the content pack parts of the object's and its groups' materials, by name (material_refs); 17: the scene's Blender link token (link.odin); 18: each object's texture maps (textures_put); 19: the scene's lights (lights_put); 20: each light's colour temperature and name; 21: each light's size (a sun's angle, a lamp's radius); 22: the preview block after the version (scene_preview.odin); 23: the millimetres per unit a print takes (print.odin); 24: the proportion guides (guides.odin); 25: each object's lock (a fourth view bit); 26: Model mode cages (OBJECT_KIND_CAGE, poly.mesh_write in the levels' place); 27: a cage's selected faces (poly.mesh_write's own version 2); 28: a cage's Smooth steps and Flat after it (Cage_Look)

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
MESH_FILTERS := [?]sdl.DialogFileFilter{{"Meshes (OBJ, PLY, STL)", "obj;ply;stl"}, {"OBJ", "obj"}, {"PLY", "ply"}, {"STL", "stl"}}
// Export writes two formats Import does not read, so it offers its own list; a name
// typed without an extension takes the one of the filter chosen (EXPORT_SUFFIX).
@(private = "file")
EXPORT_FILTERS := [?]sdl.DialogFileFilter{{"Meshes (OBJ, PLY, STL, glTF, USD)", "obj;ply;stl;glb;usda"}, {"OBJ", "obj"}, {"PLY", "ply"}, {"STL (3D printing)", "stl"}, {"glTF binary (layers as shape keys)", "glb"}, {"USD text (layers as blend shapes)", "usda"}}
@(private = "file")
EXPORT_SUFFIX := [len(EXPORT_FILTERS)]string{".obj", ".obj", ".ply", ".stl", ".glb", ".usda"}
@(private = "file")
STL_FILTERS := [?]sdl.DialogFileFilter{{"STL (3D printing)", "stl"}}
@(private = "file")
SCENE_FILTERS := [?]sdl.DialogFileFilter{{"Sculpt scene", "sculpt"}}
@(private = "file")
PNG_FILTERS := [?]sdl.DialogFileFilter{{"PNG image", "png"}}
@(private = "file")
IMAGE_FILTERS := [?]sdl.DialogFileFilter{{"Images (PNG, JPEG, BMP, TGA, QOI)", "png;jpg;jpeg;bmp;tga;qoi"}}
// Android's picker knows no MIME type for `.hdr` and would hide Radiance files, so there
// every file is offered and the decoder's own check of the bytes decides, as for packs.
when ODIN_PLATFORM_SUBTARGET == .Android {
	ENVIRONMENT_FILTERS := [?]sdl.DialogFileFilter{{"All files", "*"}}
} else {
	ENVIRONMENT_FILTERS := [?]sdl.DialogFileFilter{{"Panoramas (Radiance HDR, PNG, JPEG, BMP, TGA, QOI)", "hdr;png;jpg;jpeg;bmp;tga;qoi"}}
}
// On Android SDL turns an extension it does not know into no MIME type at all, so there
// every file is offered and the file's own first line decides, as for packs.
when ODIN_PLATFORM_SUBTARGET == .Android {
	WORKSPACE_FILTERS := [?]sdl.DialogFileFilter{{"All files", "*"}}
} else {
	WORKSPACE_FILTERS := [?]sdl.DialogFileFilter{{"Workspaces", "workspace"}}
}
@(private = "file")
STROKES_FILTERS := [?]sdl.DialogFileFilter{{"Recorded strokes", "strokes"}}
@(private = "file")
SCRIPT_FILTERS := [?]sdl.DialogFileFilter{{"Command scripts", "cmd;txt"}}
// On Android SDL turns extensions into MIME types, and `sculptpack;zip` becomes
// application/zip alone, which hides .sculptpack files, so there every file is offered
// and the archive's own bytes decide.
when ODIN_PLATFORM_SUBTARGET == .Android {
	PACK_FILTERS := [?]sdl.DialogFileFilter{{"All files", "*"}}
} else {
	PACK_FILTERS := [?]sdl.DialogFileFilter{{"Content packs", "sculptpack;zip"}}
}

// The mesh formats an export can be limited to, by their place in EXPORT_FILTERS.
Export_Filter :: enum u8 {
	OBJ  = 1,
	PLY  = 2,
	STL  = 3,
	GLTF = 4,
	USD  = 5,
}

// The suffix an export in `f` takes.
export_suffix :: proc(f: Export_Filter) -> string {
	return EXPORT_SUFFIX[int(f)]
}

// Shows the save dialog for an export in format `f` alone (the Export sheet's), so the
// dialog offers that format, suggests `name`'s file when there is one, and a name typed
// without an extension takes the format's. Does nothing while another dialog is showing.
file_dialog_export :: proc(app: ^App, f: Export_Filter, name := "") {
	sync.lock(&pending.lock)
	busy := pending.dialog
	pending.dialog = true
	sync.unlock(&pending.lock)
	if busy do return
	// The kind in the low byte, the filter after it, for file_dialog_done.
	userdata := rawptr(uintptr(File_Kind.Export) | uintptr(f) << 8)
	where_: cstring = nil
	if name != "" do where_ = strings.clone_to_cstring(name, context.temp_allocator)
	sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, &EXPORT_FILTERS[int(f)], 1, where_)
}

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
	case .Export_Print:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(STL_FILTERS[:]), len(STL_FILTERS), nil)
	case .Save, .Save_Copy:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(SCENE_FILTERS[:]), len(SCENE_FILTERS), nil)
	case .Open:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(SCENE_FILTERS[:]), len(SCENE_FILTERS), nil, false)
	case .Alpha, .Matcap, .Base_Color_Map, .Orm_Map, .Normal_Map:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(IMAGE_FILTERS[:]), len(IMAGE_FILTERS), nil, false)
	case .Environment:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(ENVIRONMENT_FILTERS[:]), len(ENVIRONMENT_FILTERS), nil, false)
	case .Screenshot:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(PNG_FILTERS[:]), len(PNG_FILTERS), nil)
	case .Save_Strokes:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(STROKES_FILTERS[:]), len(STROKES_FILTERS), nil)
	case .Load_Strokes:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(STROKES_FILTERS[:]), len(STROKES_FILTERS), nil, false)
	case .Run_Script:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(SCRIPT_FILTERS[:]), len(SCRIPT_FILTERS), nil, false)
	case .Install_Pack:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(PACK_FILTERS[:]), len(PACK_FILTERS), nil, false)
	case .Make_Pack:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(PACK_FILTERS[:]), len(PACK_FILTERS), nil)
	case .Export_Workspace:
		sdl.ShowSaveFileDialog(file_dialog_done, userdata, app.window, raw_data(WORKSPACE_FILTERS[:]), len(WORKSPACE_FILTERS), nil)
	case .Import_Workspace:
		sdl.ShowOpenFileDialog(file_dialog_done, userdata, app.window, raw_data(WORKSPACE_FILTERS[:]), len(WORKSPACE_FILTERS), nil, false)
	case .Timelapse, .Turntable, .Bake:
		sdl.ShowOpenFolderDialog(file_dialog_done, userdata, app.window, nil, false)
	}
}

// SDL's answer to a dialog, on whichever thread SDL likes: a nil list is a failure, an
// empty one a cancel. A name typed without an extension gets the one asked for.
@(private = "file")
file_dialog_done :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	heap := runtime.heap_allocator()
	kind := File_Kind(uintptr(userdata) & 0xff)
	// An export limited to one format (file_dialog_export) offered only its filter.
	only := int(uintptr(userdata) >> 8)
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
		case .Export:
			switch {
			case only > 0 && only < len(EXPORT_SUFFIX):     suffix = EXPORT_SUFFIX[only]
			case filter >= 0 && int(filter) < len(EXPORT_SUFFIX): suffix = EXPORT_SUFFIX[filter]
			case:                                            suffix = ".obj"
			}
		case .Export_Print: suffix = ".stl"
		case .Screenshot: suffix = ".png"
		case .Save_Strokes: suffix = ".strokes"
		case .Make_Pack: suffix = ".sculptpack"
		case .Export_Workspace: suffix = WORKSPACE_FILE_SUFFIX
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

// Queues a request only when no dialog shows and none waits, checked and queued under one
// lock, so a dialog's answer is never replaced. Returns whether it was queued.
file_post_when_idle :: proc(kind: File_Kind, path: string) -> bool {
	sync.lock(&pending.lock)
	defer sync.unlock(&pending.lock)
	if pending.dialog || pending.req.kind != .None do return false
	pending.req = {kind, strings.clone(path, runtime.heap_allocator())}
	return true
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
	case .Export, .Export_Print:
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
		_ = object_export(app, obj, req.path, print = req.kind == .Export_Print)
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
		if opened {
			scene_remember_path(app, req.path)
			recent_scene_add(app, req.path)
			// Opened from a shortcut while Home showed: the scene is what is wanted now.
			if app.kit.home do home_close(app)
		}
		return ok
	case .Open_Version:
		return version_open(app, req.path)
	case .Alpha:
		_ = alpha_keep(app, req.path)
	case .Matcap:
		_ = matcap_load(app, req.path)
	case .Environment:
		_ = environment_load(app, req.path)
	case .Base_Color_Map, .Orm_Map, .Normal_Map:
		for kind, m in TEXTURE_FILE_KINDS do if kind == req.kind {
			if why := texture_load(app, selected_object(app), m, req.path); why != "" do file_note(app, true, "%s", why)
		}
	case .Screenshot:
		if app.screenshot_transparent do capture_request(app, req.path)
		else do _ = screenshot_save(app, req.path)
	case .Timelapse:
		timelapse_start(app, req.path)
	case .Turntable:
		turntable_start(app, req.path)
	case .Bake:
		bake_to_folder(app, req.path)
	case .Save_Strokes:
		_ = strokes_save(app, req.path)
	case .Load_Strokes:
		_ = strokes_load(app, req.path)
	case .Install_Pack:
		pack_install_start(app, req.path)
	case .Make_Pack:
		_ = pack_make(app, req.path)
	case .Export_Workspace:
		_ = workspace_export(app, req.path)
	case .Import_Workspace:
		_ = workspace_import(app, req.path)
	case .Recover:
		return autosave_recover(app, req.path)
	case .Discard_Autosave:
		autosave_discard(app, req.path)
	case .Run_Script:
		script_file_run(app, req.path)
	case .Link_Send, .Link_Get:
		// As a big save: the window says what it waits for before the frame stops.
		big := link_send_bytes(app) if req.kind == .Link_Send else link_get_bytes(app)
		if big > SAVE_SHOW_FIRST {
			app.saving = {req.kind, strings.clone(req.path, runtime.heap_allocator())}
			app.saving_at = app.kit.ctx.time
			report(app, nil, {.Busy}, "Sending to Blender..." if req.kind == .Link_Send else "Getting from Blender...")
			return true
		}
		if req.kind == .Link_Send do link_send(app)
		else do return link_get(app, req.path == LINK_AUTO)
	}
	return true
}

// Writes the viewport as the last frame drew it, without the brush outline or gizmo,
// to a PNG file (or a binary PPM when the path ends in .ppm, for the render checks).
screenshot_save :: proc(app: ^App, path: string) -> bool {
	start := time.tick_now()
	w, h := int(app.target.width), int(app.target.height)
	// What the viewport shows: the studio render's or live occlusion's image while on.
	shown := viewport_shown(app)
	pixels := render.viewport_download(&app.renderer, &app.target, context.temp_allocator, shown)
	if pixels == nil {
		file_note(app, true, "Could not read the viewport back: %s", sdl.GetError())
		return false
	}
	if !image_save(app, path, pixels, w, h) do return false
	file_note(app, false, "Saved %s (%d x %d) in %.0f ms", filepath.base(path), w, h, time.duration_milliseconds(time.tick_since(start)))
	return true
}

// Writes RGBA8 rows, top to bottom, to a PNG file, with its alpha or opaque (or a binary
// PPM when the path ends in .ppm, which has none), noting a failure.
image_save :: proc(app: ^App, path: string, pixels: []u8, w, h: int, alpha := false) -> bool {
	written: bool
	if strings.equal_fold(filepath.ext(path), ".ppm") {
		written = write_ppm(path, pixels, w, h)
	} else {
		data := png_write.encode(pixels, w, h, alpha = alpha, allocator = context.temp_allocator)
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

// Reads an OBJ, PLY or STL file into a new object beside the others, sized like a sphere
// (its place in the file is kept for export: see Object.file). Returns false only on a
// GPU failure.
scene_import :: proc(app: ^App, path: string) -> bool {
	m, read := mesh_import_read(app, path, fmt.tprintf("Imported %s", filepath.base(path)))
	if !read do return true
	stem := filepath.stem(path)
	if !scene_add_mesh(app, m.mesh, stem if stem != "" else "Import", m.file, {position = next_free_position(app), scale = 1}, m.start) do return false
	// After the new object's stats reset.
	app.stats.file_read_ms, app.stats.file_parse_ms = m.read_ms, m.parse_ms
	return true
}

// A mesh file read for a new object: the cleaned mesh, centred and sized like a sphere,
// where it sat in its file, and how long reading took.
Mesh_Import :: struct {
	mesh:              geom.Mesh,
	file:              Transform,
	start:             time.Tick,
	read_ms, parse_ms: f64,
}

Mesh_Kind :: enum u8 {
	None, // not a mesh file the app reads
	OBJ,
	PLY,
	STL,
}

// Which reader a mesh file takes: by its extension, or for a content:// URI from
// Android's picker, which has none, by its bytes (a PLY file starts with "ply", an STL
// file with "solid" or with a triangle count its length matches, and anything else is
// tried as OBJ text).
mesh_file_kind :: proc(path: string, data: []u8) -> Mesh_Kind {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".obj": return .OBJ
	case ".ply": return .PLY
	case ".stl": return .STL
	}
	if !strings.has_prefix(path, "content://") do return .None
	text := string(data)
	switch {
	case strings.has_prefix(text, "ply"): return .PLY
	case strings.has_prefix(text, "solid"): return .STL
	case len(data) >= geom.STL_HEADER && geom.STL_HEADER + geom.STL_ROW * int((^u32le)(&data[80])^) == len(data): return .STL
	}
	return .OBJ
}

// Parses and cleans a mesh file's bytes, as Import and a content pack's install both
// do; a nil pool runs it on the calling thread. `line` names the line of a parse error
// (0 for none).
mesh_file_parse :: proc(data: []u8, kind: Mesh_Kind, pool: ^jobs.Pool) -> (mesh: geom.Mesh, cleaned: geom.Mesh_Clean_Report, failed: geom.Mesh_File_Error, line: int) {
	switch kind {
	case .PLY: mesh, failed, line = geom.mesh_read_ply(data, pool)
	case .STL: mesh, failed, line = geom.mesh_read_stl(data, pool)
	case .OBJ, .None: mesh, failed, line = geom.mesh_read_obj(data, pool)
	}
	if failed == .None do cleaned, failed = geom.mesh_clean(&mesh, pool)
	if failed != .None do geom.mesh_destroy(&mesh)
	return
}

// Reads the mesh file at `path` for a new object, with a note led by `what` ("Imported
// rock.obj") saying what it holds; false, with a note saying why, when it cannot.
mesh_import_read :: proc(app: ^App, path, what: string) -> (m: Mesh_Import, ok: bool) {
	m.start = time.tick_now()
	// Kept apart from temp memory, which reading frees before the note is written.
	head := strings.clone(what)
	defer delete(head)
	name := strings.clone(filepath.base(path))
	defer delete(name)
	data, err := file_read_any(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot read %s: %v", name, err)
		return
	}
	defer delete(data)
	read := time.tick_now()
	kind := mesh_file_kind(path, data)
	if kind == .None {
		file_note(app, true, "Cannot import %s: only .obj, .ply and .stl files import", name)
		return
	}
	mesh, cleaned, failed, line := mesh_file_parse(data, kind, &app.pool)
	if failed != .None {
		if line > 0 {
			file_note(app, true, "Cannot read %s, line %d: %s", name, line, geom.MESH_FILE_ERROR_TEXT[failed])
		} else {
			file_note(app, true, "Cannot read %s: %s", name, geom.MESH_FILE_ERROR_TEXT[failed])
		}
		return
	}
	parsed := time.tick_now()
	center, radius := geom.mesh_normalize(&mesh, &app.pool)
	edges := geom.mesh_edges(mesh, &app.pool)
	flipped := geom.mesh_edges_closed(edges) && edges.volume < 0
	// A closed surface facing inward would be culled from outside, and remeshes empty.
	if flipped do geom.mesh_flip(&mesh, &app.pool)
	free_all(context.temp_allocator)
	m.read_ms = time.duration_milliseconds(time.tick_diff(m.start, read))
	m.parse_ms = time.duration_milliseconds(time.tick_diff(read, parsed))
	// The note leads with what matters most: a surface that is not closed, then the size.
	closed := geom.mesh_edges_closed(edges)
	note := strings.builder_make(context.temp_allocator)
	strings.write_string(&note, head)
	if closed {
		strings.write_string(&note, ":")
	} else {
		strings.write_string(&note, fmt.tprintf(", but its surface is not closed (%d border edges, %d flipped or shared by more than two triangles): it sculpts, but subdivision, HD and remesh need a closed one.", edges.border, edges.bad))
	}
	strings.write_string(&note, fmt.tprintf(" %d vertices, %d triangles, read in %.0f ms and parsed in %.0f ms", geom.mesh_vertex_count(mesh), geom.mesh_triangle_count(mesh), m.read_ms, m.parse_ms))
	// Every corner of an STL file comes on its own, so welding them is no news.
	if kind == .STL do cleaned.dropped_vertices, cleaned.welded = cleaned.dropped_vertices - cleaned.welded, 0
	if cleaned != {} do strings.write_string(&note, fmt.tprintf("; %d vertices welded, %d triangles and %d vertices dropped", cleaned.welded, cleaned.dropped_triangles, cleaned.dropped_vertices))
	if flipped do strings.write_string(&note, "; turned outward")
	file_note(app, !closed, "%s", strings.to_string(note))
	m.mesh, m.file = mesh, {position = center, scale = radius}
	return m, true
}

// Writes the object's shown level (packed, if dynamic) to an OBJ, PLY, STL, binary glTF
// or USD text file, where it was in the file it came from (Object.file); Move tool placement
// is not written. glTF and USD also carry the normals, the materials (the object's and its
// groups') and the sculpt layers, as morph targets or blend shapes (shape keys) at their
// strengths; USD the polygroups too, and a retopologized base level as its quads and UVs,
// as OBJ does. Returns whether it was written.
object_export :: proc(app: ^App, obj: ^Object, path: string, print := false) -> bool {
	start := time.tick_now()
	name := filepath.base(path)
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	if print && ext != ".stl" {
		file_note(app, true, "Cannot export %s for printing: the name needs to end in .stl", name)
		return false
	}
	if ext != ".obj" && ext != ".ply" && ext != ".stl" && ext != ".glb" && ext != ".usda" {
		file_note(app, true, "Cannot export to %s: the name needs to end in .obj, .ply, .stl, .glb or .usda", name)
		return false
	}
	// A stroke, pose or slider drag under way would otherwise land half in the file, and
	// a recording stroke's movement in the base rather than its layer.
	stroke_finish(app)
	inspector_drags_end(app)
	lv := sculpt.levels_current(&obj.levels)
	positions, normals, indices := lv.mesh.positions[:], lv.mesh.normals[:], lv.mesh.indices[:]
	packed: geom.Mesh
	defer geom.mesh_destroy(&packed)
	if vp := obj.voxel; vp != nil {
		// A voxel object's surface, welded, as Convert to mesh would make it.
		packed = voxel.clay_to_mesh(&vp.clay)
		positions, normals, indices = packed.positions[:], packed.normals[:], packed.indices[:]
	}
	// Polypaint as plain vertex colours: the paint over white as far as it covers, or for
	// glTF and USD, which carry the material, over the material's colour, as the viewport
	// shows it; the material's colour then goes as white, since both formats multiply
	// the two.
	material := export_material(object_material(app, obj))
	colors: [][3]u8
	if c := lv.sculptor.color; c != nil && !object_dynamic(obj) {
		under := [3]u32{255, 255, 255}
		if ext == ".glb" || ext == ".usda" {
			for k in 0 ..< 3 do under[k] = u32(math.round(srgb_encode(material.base[k]) * 255))
			material.base = 1
		}
		colors = make([][3]u8, len(c), context.temp_allocator)
		for x, v in c do colors[v] = paint_over(x, under)
	}
	if object_dynamic(obj) {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(&lv.sculptor)
		delete(mask)
		positions, normals, indices = packed.positions[:], packed.normals[:], packed.indices[:]
	}
	out := make([dynamic]u8)
	defer delete(out)
	layers := 0
	// The print note outlives the temp memory, freed before the file is written.
	printed: string
	defer delete(printed)
	// glTF copies the vertices on a seam between two group materials.
	vertices := len(positions)
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
		if ext == ".glb" && object_exports_textures(obj) {
			// Its maps go as the material's textures, through the UVs, on the quads split
			// where the UVs are, as a bake's own .glb has them (retopo.odin), with the
			// polypaint unless a base colour map stands for it (glTF would multiply the
			// two); polygroup materials stay out, since the maps give one material.
			q := sculpt.levels_quad_mesh(&obj.levels)
			paint := colors if obj.textures.image[.Base_Color] == nil else nil
			written: bool
			vertices, written = quad_object_glb(&out, obj, q, object_label(obj), obj.textures.image, material, true, morphs, paint, export_lights(app, obj.transform))
			if !written {
				free_all(context.temp_allocator)
				file_note(app, true, "Cannot export %s: a glTF file holds at most 4 GB", name)
				return false
			}
			break
		}
		m := geom.Mesh_Export {
			name      = object_label(obj),
			positions = positions,
			normals   = normals,
			indices   = indices,
			colors    = colors,
			morphs    = morphs,
			scale     = obj.file.scale,
			offset    = obj.file.position,
			material  = material,
			lights    = export_lights(app, obj.transform),
		}
		if ext == ".usda" do usd_extras(obj, lv, &m)
		if object_shows_group_materials(obj) && !object_dynamic(obj) {
			faces := m.groups if ext == ".usda" else lv.sculptor.groups.tris
			export_group_materials(app, obj, &m, faces, lv.sculptor.color, ext == ".glb")
		}
		vertices = len(m.positions)
		if ext == ".usda" {
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
	case print:
		at := print_positions(positions, obj.transform, print_scale(app))
		geom.mesh_write_stl(&out, at, indices, pool = &app.pool)
		printed = strings.clone(print_note(at, indices))
	case ext == ".stl":
		// STL carries no colour, which 3D printing tools would not read anyway.
		geom.mesh_write_stl(&out, positions, indices, obj.file.scale, obj.file.position, &app.pool)
	case:
		geom.mesh_write_ply(&out, positions, indices, obj.file.scale, obj.file.position, &app.pool, colors)
	}
	free_all(context.temp_allocator)
	if !write_file_safely(app, path, out[:], "export") do return false
	// The times shown are this action's alone.
	app.stats.file_read_ms, app.stats.file_parse_ms = 0, 0
	app.stats.file_write_ms = time.duration_milliseconds(time.tick_since(start))
	with := fmt.tprintf(", %d %s as shape keys", layers, "layer" if layers == 1 else "layers") if layers > 0 else ""
	if print {
		app.print_exports += 1
		file_note(app, false, "Exported %s for printing: %s; %d triangles in %.0f ms", name, printed, len(indices) / 3, app.stats.file_write_ms)
		return true
	}
	file_note(app, false, "Exported %s: %d vertices, %d triangles%s, %d MB in %.0f ms", name, vertices, len(indices) / 3, with, len(out) >> 20, app.stats.file_write_ms)
	return true
}

// Whether a .glb export of `obj` carries its maps: it has some and shows its base level,
// whose quads and UVs they follow, without dynamic topology.
object_exports_textures :: proc(obj: ^Object) -> bool {
	return object_has_textures(obj) && obj.voxel == nil && obj.levels.current == 0 && !object_dynamic(obj) && !object_in_hd(obj) && texture_target_check(obj) == ""
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
	preview_refresh(app)
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
	// STL spells out every triangle's corners and normal.
	if strings.equal_fold(filepath.ext(path), ".stl") do return 50 * len(lv.mesh.indices) / 3
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
	if req.kind == .Export || req.kind == .Export_Print {
		if obj := selected_object(app); obj != nil {
			_ = object_export(app, obj, req.path, print = req.kind == .Export_Print)
		} else {
			file_note(app, true, "Select an object to export first")
		}
		return
	}
	if req.kind == .Link_Send {
		link_send(app)
		return
	}
	if req.kind == .Link_Get {
		// Only a GPU failure stops a get, and the app cannot go on without the GPU.
		if !link_get(app, req.path == LINK_AUTO) do app.running = false
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
		recent_scene_add(app, req.path)
	}
}

// The scene file's start: its magic and version, how many objects follow, the selected
// one, the next id and the camera.
scene_header_put :: proc(app: ^App, out: ^[dynamic]u8) {
	append(out, SCENE_MAGIC)
	geom.byte_put(out, SCENE_VERSION)
	preview_block_put(app, out) // version 22
	geom.byte_put(out, u32(len(app.scene.objects)))
	geom.byte_put(out, i32(app.scene.selected))
	geom.byte_put(out, i32(app.scene.next_id))
	c := main_camera(app)
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
		geom.byte_put(out, f.vis_off) // version 12
	}
	geom.byte_put(out, i32(app.scene.next_folder_id))
	// Version 12: the stored visibility chosen and those in use.
	geom.byte_put(out, u8(app.scene.vis_slot))
	geom.byte_put(out, app.scene.vis_used)
	geom.byte_put(out, app.scene.link_token) // version 17
	lights_put(out, app.scene.lights) // version 19, 20, 21
	geom.byte_put(out, print_scale(app)) // version 23
	guides_put(out, app.scene.guides) // version 24
}

// The proportion guides as a scene file stores them: a byte of flags (shown, seeded) and
// the three heights.
guides_put :: proc(out: ^[dynamic]u8, g: Guides) {
	geom.byte_put(out, u8(g.shown) | u8(g.seeded) << 1)
	for h in g.heights do geom.byte_put(out, h)
}

// The proportion guides from a scene file; false for flags no version wrote or a height
// that is not a number.
guides_get :: proc(r: ^geom.Byte_Reader) -> (g: Guides, ok: bool) {
	flags := geom.byte_get(r, u8)
	for &h in g.heights do h = geom.byte_get(r, f32)
	g.shown, g.seeded = flags & 1 != 0, flags & 2 != 0
	ok = r.ok && flags <= 3
	for h in g.heights do ok &&= finite({h, 0, 0})
	return
}

// The lights as a scene file stores them: how many, the ambient light, then each light.
lights_put :: proc(out: ^[dynamic]u8, set: Light_Set) {
	set := set
	count := clamp(set.count, 0, LIGHT_COUNT)
	geom.byte_put(out, u8(count))
	geom.byte_put(out, set.ambient)
	for l in set.lights[:count] {
		geom.byte_put(out, u8(l.on))
		geom.byte_put(out, u8(l.kind))
		geom.byte_put(out, u8(l.space))
		geom.byte_put(out, l.dir)
		geom.byte_put(out, l.pos)
		geom.byte_put(out, l.strength)
		geom.byte_put(out, l.ref)
		geom.byte_put(out, l.reach)
		geom.byte_put(out, l.cone)
		geom.byte_put(out, l.blend)
		geom.byte_put(out, l.color)
		geom.byte_put(out, l.kelvin)
		geom.byte_put(out, l.name)
		geom.byte_put(out, l.angle) // version 21
		geom.byte_put(out, l.radius)
	}
}

// The lights lights_put wrote in a scene file of `version`, the ones past their count as
// `rest` has them; ok is false when they are damaged: too many, an unknown kind or space,
// a number that is not finite or out of its range, a name not ended by a zero or not
// UTF-8.
lights_get :: proc(r: ^geom.Byte_Reader, rest: Light_Set, version := SCENE_VERSION) -> (set: Light_Set, ok: bool) {
	set = rest
	count := int(geom.byte_get(r, u8))
	set.count = i32(count)
	set.ambient = geom.byte_get(r, f32)
	if !r.ok || count > LIGHT_COUNT || !(set.ambient >= 0 && set.ambient <= LIGHT_STRENGTH_MAX) do return {}, false
	for &l in set.lights[:count] {
		on, kind, space := geom.byte_get(r, u8), geom.byte_get(r, u8), geom.byte_get(r, u8)
		l.dir = geom.byte_get(r, Vec3)
		l.pos = geom.byte_get(r, Vec3)
		l.strength = geom.byte_get(r, f32)
		l.ref = geom.byte_get(r, f32)
		l.reach = geom.byte_get(r, f32)
		l.cone = geom.byte_get(r, f32)
		l.blend = geom.byte_get(r, f32)
		l.color = geom.byte_get(r, Vec3)
		if !r.ok || on > 1 || kind >= len(Light_Kind) || space >= len(Light_Space) || !finite(l.dir) || !finite(l.pos) || !finite(l.color) do return {}, false
		// Written as `!(in range)`, so NaN is refused too.
		if !(l.strength >= 0 && l.strength <= LIGHT_STRENGTH_MAX) || !(l.ref >= 0 && l.ref < 1e30) || !(l.reach >= 0 && l.reach < 1e30) do return {}, false
		if !(l.cone >= LIGHT_CONE_MIN && l.cone <= LIGHT_CONE_MAX) || !(l.blend >= 0 && l.blend <= 1) || min(l.color.r, l.color.g, l.color.b) < 0 do return {}, false
		l.on, l.kind, l.space = on == 1, Light_Kind(kind), Light_Space(space)
		l.kelvin, l.name = 0, {}
		if version >= 20 {
			l.kelvin = geom.byte_get(r, f32)
			l.name = geom.byte_get(r, [LIGHT_NAME]u8)
			if !r.ok || !(l.kelvin == 0 || (l.kelvin >= LIGHT_KELVIN_MIN && l.kelvin <= LIGHT_KELVIN_MAX)) do return {}, false
			n := 0
			for n < LIGHT_NAME && l.name[n] != 0 do n += 1
			if n == LIGHT_NAME || !utf8.valid_string(string(l.name[:n])) do return {}, false
			for b in l.name[n:] do if b != 0 do return {}, false
		}
		l.angle, l.radius = 0, 0
		if version >= 21 {
			l.angle = geom.byte_get(r, f32)
			l.radius = geom.byte_get(r, f32)
			if !r.ok || !(l.angle >= 0 && l.angle <= LIGHT_ANGLE_MAX) || !(l.radius >= 0 && l.radius <= LIGHT_RADIUS_MAX) do return {}, false
		}
	}
	return set, true
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
		if version >= 12 do f.vis_off = geom.byte_get(r, u8)
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
	if version >= 22 && !preview_block_skip(&r) {
		file_note(app, true, "Cannot open %s: it is damaged", name)
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
	vis_slot, vis_used: u8
	if version >= 12 {
		vis_slot = geom.byte_get(&r, u8)
		vis_used = geom.byte_get(&r, u8)
	}
	link_token := geom.byte_get(&r, u64) if version >= 17 else 0
	// A scene from before scenes held lights is lit by the starting lights, as a new one is.
	lights, lights_ok := app.start_lights, true
	if version >= 19 do lights, lights_ok = lights_get(&r, app.start_lights, version)
	// A scene from before prints were sized prints at a new scene's scale.
	print_mm := f32(PRINT_MM_DEFAULT)
	if version >= 23 do print_mm = geom.byte_get(&r, f32)
	// A scene from before guides were kept has them off, seeded when first shown.
	guides, guides_ok := Guides{}, true
	if version >= 24 do guides, guides_ok = guides_get(&r)
	if !guides_ok || !lights_ok || !folders_ok || !r.ok || !(print_mm >= PRINT_MM_MIN && print_mm <= PRINT_MM_MAX) || solo > 1 || vis_slot > VIS_SLOTS || (vis_slot > 0 && vis_used & (1 << (vis_slot - 1)) == 0) || count > len(data) || selected >= count || !finite(view.target) || !finite({view.distance, view.yaw, view.pitch}) || !finite({view.roll, 0, 0}) {
		file_note(app, true, "Cannot open %s: it is damaged", name)
		return false, true
	}
	view.distance = clamp(view.distance, camera.MIN_DISTANCE, camera.MAX_DISTANCE)
	view.yaw, view.pitch, view.roll = camera.wrap_angle(view.yaw), camera.wrap_angle(view.pitch), camera.wrap_angle(view.roll)

	objects := make([dynamic]^Object, 0, count)
	defer delete(objects)
	render.wait_idle(&app.renderer)
	missing := 0
	for i in 0 ..< count {
		obj, read, made := object_get(app, &r, version, &missing)
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
	app.scene.vis_slot, app.scene.vis_used = int(vis_slot), vis_used
	app.scene.link_token = link_token
	app.scene.lights, app.scene.lights_own = lights, version >= 19
	app.scene.print_mm = print_mm
	app.scene.guides = guides
	scene_folders_normalize(app)
	scene_selection_fix(app)
	autosave_scene_saved(app, path)
	app.stats.file_read_ms = time.duration_milliseconds(time.tick_since(start))
	vertices := 0
	for obj in objects do vertices += object_vertex_count(obj)
	if missing > 0 {
		file_note(app, true, "Opened %s, but %d object%s use%s materials from content packs that are not installed, so they show Custom materials of the same colours", name, missing, "" if missing == 1 else "s", "s" if missing == 1 else "")
	} else {
		file_note(app, false, "Opened %s: %d %s, %d vertices shown, in %.0f ms", name, count, "object" if count == 1 else "objects", vertices, app.stats.file_read_ms)
	}
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
	render.wait_idle(&app.renderer)
	history_clear(&app.history)
	for obj in app.scene.objects do object_free(app, obj)
	clear(&app.scene.objects)
	append(&app.scene.objects, ..objects)
	app.scene.selected = selected
	app.scene.solo = false
	folders_clear(&app.scene.folders)
	app.scene.next_folder_id = 0
	app.scene.vis_slot, app.scene.vis_used = 0, 0
	// A new scene has no link with Blender until it sends; an opened one gets its own back.
	app.scene.link_token = 0
	clear(&app.link.sent)
	// A new scene prints at the starting scale; an opened one gets its own back.
	app.scene.print_mm = PRINT_MM_DEFAULT
	// A new scene has no guides until they are shown; an opened one gets its own back.
	app.scene.guides = {}
	// A new scene is lit by the starting lights; an opened one gets its own back. A change
	// to the old scene's lights still under way goes with its History.
	app.scene.lights, app.scene.lights_own = app.start_lights, false
	app.ui.light_drag = {}
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
	// The point in focus was on the old scene's model.
	app.focus = nil
	app.ui.focus_armed, app.ui.focus_held = false, false
	app.stroke_end.valid = false
	clear(&app.stroke.pending)
	app.stats = {}
	render.viewport_invalidate(&app.target)
}

// Replaces the scene with one object: a sphere or a starter of about `vertices` vertices
// (with its subdivision levels), seen from the front, with no file to save to (Save then asks where)
// and an empty History, as Menu > New scene does. Returns false only on a GPU failure;
// a shape that cannot be built leaves the scene as it was.
scene_new :: proc(app: ^App, shape: geom.Primitive, vertices: int, voxels := 0, empty := false) -> bool {
	start := time.tick_now()
	if empty {
		scene_replace(app, {}, -1, app.scene.next_id, camera.orbit_default())
		scene_new_done(app)
		report(app, nil, {}, "New scene: empty; Add object (Scene palette) or Import brings something in")
		return true
	}
	obj: ^Object
	if voxels > 0 {
		// A block of clay, which every voxel brush works on as it does on the sphere.
		obj = new(Object)
		obj.transform, obj.file = {scale = 1}, {scale = 1}
		if !object_build_voxel(app, obj, voxels, box = true) {
			free(obj)
			return false
		}
		obj.name = fmt.aprintf("Voxels %d", app.scene.next_id + 1)
	} else {
		ok: bool
		obj, ok = object_make_primitive(app, shape, vertices, {scale = 1})
		if obj == nil do return ok
	}
	obj.id = app.scene.next_id + 1
	// The view the app starts with, which shows a starter from the front and a side.
	scene_replace(app, {obj}, 0, obj.id, camera.orbit_default())
	scene_new_done(app)
	took := time.duration_milliseconds(time.tick_since(start))
	if voxels > 0 {
		report(app, nil, {}, "New scene: a voxel block %d voxels across, %s surface vertices, in %.0f ms", voxels, count_label(object_vertex_count(obj)), took)
		return true
	}
	levels := len(obj.levels.levels)
	report(app, nil, {}, "New scene: %v, %d %s, %s vertices, in %.0f ms", shape, levels, "level" if levels == 1 else "levels", count_label(object_vertex_count(obj)), took)
	return true
}

// What every new scene ends with: no file yet, and no autosave of one.
@(private = "file")
scene_new_done :: proc(app: ^App) {
	scene_remember_path(app, "")
	autosave_scene_saved(app, "")
}

// Appends one object as the scene file stores it: its id, name, placement and every
// level with the mask. Leaves any HD window first, whose detail is not stored.
object_put :: proc(app: ^App, out: ^[dynamic]u8, obj: ^Object) {
	object_hd_leave(app, obj)
	_ = object_put_bytes(out, obj, refs = object_material_refs(app, obj))
	free_all(context.temp_allocator)
}

// object_put without leaving HD, for the autosave thread, which writes as `opts` says
// and may be stopped (false, with part of the object in `out`). `refs` are the content
// pack parts by name of its material and then each group's (object_material_refs), which
// the frame loop works out, since the library is its; none for none.
object_put_bytes :: proc(out: ^[dynamic]u8, obj: ^Object, opts := sculpt.Write_Options{}, refs: []Material_Refs = nil) -> bool {
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
	geom.byte_put(out, obj.vis_off) // version 12
	geom.byte_put(out, u8(object_kind(obj))) // version 13, cages 26
	material_put(out, obj.material, refs[0] if len(refs) > 0 else {}) // version 14, its references 16
	group_materials_put(out, obj, refs[1:] if len(refs) > 0 else nil) // version 15, their references 16
	textures_put(out, obj.textures) // version 18
	// A voxel object's clay and the resolution it started at stand where a mesh's levels
	// go; its empty level is made again on reading.
	if vp := obj.voxel; vp != nil {
		geom.byte_put(out, i32(vp.resolution))
		return voxel.clay_write(&vp.clay, out, opts.abort)
	}
	// Likewise a cage stands there: its level is cut from it again on reading.
	if cp := obj.cage; cp != nil {
		poly.mesh_write(&cp.mesh, out)
		geom.byte_put(out, u8(cp.look.smooth))
		geom.byte_put(out, u8(cp.look.flat))
		return true
	}
	return sculpt.levels_write(&obj.levels, out, opts)
}

// What `obj` is in the scene file.
object_kind :: proc(obj: ^Object) -> int {
	if obj.voxel != nil do return OBJECT_KIND_VOXEL
	if obj.cage != nil do return OBJECT_KIND_CAGE
	return OBJECT_KIND_MESH
}

// What an object is in the scene file, from version 13: a mesh with levels, or a voxel
// object (its resolution and clay in the levels' place); from version 26 also a Model
// mode cage (poly.mesh_write's bytes in the levels' place).
OBJECT_KIND_MESH :: 0
OBJECT_KIND_VOXEL :: 1
OBJECT_KIND_CAGE :: 2

// About how many bytes object_put writes for `obj`: every level's positions and sculpt
// layers, the base's triangles and node layout, and the shown level's mask, paint and
// groups.
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
	if vp := obj.voxel; vp != nil do bytes += 4 + voxel.clay_write_estimate(&vp.clay)
	// A cage writes each point, corner and face once, with a few bytes a corner.
	if cp := obj.cage; cp != nil do bytes += 20 * len(cp.mesh.positions) + 8 * len(cp.mesh.he_vert) + 6 * len(cp.mesh.face_he)
	bytes += textures_bytes(obj.textures)
	return bytes
}

// An object's eye (off is 1), ghost (2), polypaint left out (4, from version 11) and lock
// (8, from version 25) as the scene file stores them.
OBJECT_VIEW_BITS :: 15
object_view_bits :: proc(obj: ^Object) -> u8 {return u8(obj.off) | u8(obj.ghost) << 1 | u8(obj.paint_off) << 2 | u8(obj.locked) << 3}

// Reads one object written by object_put (by a scene file of `version`) and uploads
// its shown level; an object whose material is a content pack's that is not installed
// counts in `missing` (material_get). `read` is false
// when the bytes are damaged (no object is made); `made` is false on a GPU failure,
// with the object returned for the caller to discard.
object_get :: proc(app: ^App, r: ^geom.Byte_Reader, version := SCENE_VERSION, missing: ^int = nil) -> (obj: ^Object, read, made: bool) {
	obj = new(Object)
	object_get_fields(r, obj, version)
	kind := geom.byte_get(r, u8) if version >= 13 else OBJECT_KIND_MESH
	// An older scene has no materials: its objects take the default (materials_settle),
	// which is how they showed.
	if version >= 14 do obj.material = material_get(r, app, version, missing)
	if version >= 15 do group_materials_get(r, obj, app, version, missing)
	if version >= 18 do obj.textures = textures_get(r)
	// A voxel object has no polygroups to shade, nor UVs to lay maps on.
	most := OBJECT_KIND_CAGE if version >= 26 else OBJECT_KIND_VOXEL
	// Nor has a cage UVs to lay maps on, yet.
	fields_ok := r.ok && obj.transform.scale > 0 && obj.file.scale > 0 && int(kind) <= most && !(kind == OBJECT_KIND_VOXEL && (len(obj.group_materials) > 0 || object_has_textures(obj))) && !(kind == OBJECT_KIND_CAGE && object_has_textures(obj))
	if fields_ok && kind == OBJECT_KIND_VOXEL {
		read, made = voxel_part_get(app, r, obj)
		if read {
			free_all(context.temp_allocator)
			return obj, true, made
		}
	} else if fields_ok && kind == OBJECT_KIND_CAGE {
		read, made = cage_part_get(app, r, obj, version)
		if read {
			free_all(context.temp_allocator)
			return obj, true, made
		}
	} else if fields_ok && sculpt.levels_read(&obj.levels, r, &app.pool) && (sculpt.levels_has_uvs(&obj.levels) || !object_has_textures(obj)) {
		lv := sculpt.levels_current(&obj.levels)
		obj.gpu[obj.levels.current], made = render.mesh_buffers_create(&app.renderer, lv.mesh, lv.sculptor.mask)
		free_all(context.temp_allocator)
		return obj, true, made
	}
	// Maps without the UVs they were made on are damage too.
	sculpt.levels_destroy(&obj.levels)
	delete(obj.name)
	delete(obj.group_materials)
	textures_free(&obj.textures)
	free(obj)
	free_all(context.temp_allocator)
	return nil, false, false
}

// Reads what object_put writes before the levels: the id, name, placement, boolean mode,
// view flags, folder and stored eyes, as a file of `version` has them; r.ok goes false on damage. The
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
		most: u8 = OBJECT_VIEW_BITS if version >= 25 else (7 if version >= 11 else 3)
		if bits > most do r.ok = false
		obj.off, obj.ghost, obj.paint_off, obj.locked = bits & 1 != 0, bits & 2 != 0, bits & 4 != 0, bits & 8 != 0
	}
	if version >= 9 {
		obj.folder = int(geom.byte_get(r, i32))
		if obj.folder < 0 do r.ok = false
	}
	if version >= 12 do obj.vis_off = geom.byte_get(r, u8)
}

// Frees an object read for a scene that never got it: it has no history and draws
// nothing yet. The caller has waited for the GPU.
object_discard :: proc(app: ^App, obj: ^Object) {
	for &gpu in obj.gpu do render.mesh_buffers_destroy(&app.renderer, &gpu)
	texture_preview_release(app, obj)
	sculpt.levels_destroy(&obj.levels)
	voxel_part_free(app, obj)
	cage_part_free(obj)
	delete(obj.name)
	delete(obj.group_materials)
	textures_free(&obj.textures)
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
