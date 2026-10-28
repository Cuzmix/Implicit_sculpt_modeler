package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

import "../camera"
import "../geom"

// A content pack's base meshes: OBJ or PLY files right in its `meshes/` folder. Install
// parses and cleans each on the install thread, so a pack whose mesh does not read is
// refused before anything reaches the library, then keeps the file as it came and lists
// it, with its counts, in the pack's meshes.txt, which a start reads instead of parsing
// every mesh again. A pack mesh opens as Import opens a file (cleaned, centred, sized):
// Scene > Add object and the Objects card add one beside the others, and Menu > New
// scene starts a scene from one.

PACK_MESHES :: "meshes"
PACK_MESH_INDEX :: "meshes.txt"
// The most meshes a pack brings; the archive's own limits bound their size.
PACK_MESHES_MAX :: 64

// A pack's mesh, in Library.meshes. A removed pack's are marked gone and stay, so an
// index into the list holds for the run (Scene_Command.mesh, Kit_State.add_mesh).
Pack_Mesh :: struct {
	pack:      string, // the pack's id, owned
	stem:      string, // owned: its name, the file's without the extension
	file:      string, // owned: the full path
	vertices:  int,
	triangles: int,
	gone:      bool,
}

// A mesh an install read: its file in the pack's meshes folder and its counts once
// cleaned.
Pack_Mesh_Read :: struct {
	stem, file:          string, // owned
	vertices, triangles: int,
}

pack_mesh_free :: proc(m: ^Pack_Mesh) {
	delete(m.pack)
	delete(m.stem)
	delete(m.file)
	m^ = {}
}

// Checks one mesh of a pack on the install thread: parsed and cleaned with no pool, as
// Import would, then dropped. "" when it reads, otherwise why not ("line 4: ...").
pack_mesh_check :: proc(name: string, data: []u8) -> (read: Pack_Mesh_Read, failed: string) {
	mesh, _, err, line := mesh_file_parse(data, mesh_file_kind(name, data), nil)
	if err != .None {
		if line > 0 do return {}, fmt.tprintf("line %d: %s", line, geom.MESH_FILE_ERROR_TEXT[err])
		return {}, geom.MESH_FILE_ERROR_TEXT[err]
	}
	defer geom.mesh_destroy(&mesh)
	return {vertices = geom.mesh_vertex_count(mesh), triangles = geom.mesh_triangle_count(mesh)}, ""
}

// meshes.txt: one `mesh <stem> <file> <vertices> <triangles>` line a mesh, names
// escaped as preset names are.
pack_mesh_index :: proc(meshes: []Pack_Mesh_Read) -> string {
	out := strings.builder_make(context.temp_allocator)
	for m in meshes do fmt.sbprintfln(&out, "mesh %s %s %d %d", preset_escape(m.stem), preset_escape(m.file), m.vertices, m.triangles)
	return strings.to_string(out)
}

// Reads pack `id`'s meshes.txt in `folder` (the pack's) into the library; a line that is
// damaged, or names a file that is not there, is left out. Returns how many it added.
pack_meshes_load :: proc(app: ^App, id, folder: string) -> (added: int) {
	path, _ := filepath.join({folder, PACK_MESH_INDEX}, context.temp_allocator)
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	rest := string(text)
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) != 5 || f[0] != "mesh" || added >= PACK_MESHES_MAX do continue
		vertices, v_ok := strconv.parse_int(f[3])
		triangles, t_ok := strconv.parse_int(f[4])
		file := preset_unescape(f[2])
		full, _ := filepath.join({folder, PACK_MESHES, file}, context.temp_allocator)
		if !v_ok || !t_ok || strings.contains_any(file, "/\\") || !os.exists(full) do continue
		pack_mesh_add(app, id, preset_unescape(f[1]), full, vertices, triangles)
		added += 1
	}
	return
}

// Adds a mesh of pack `id` to the library.
pack_mesh_add :: proc(app: ^App, id, stem, file: string, vertices, triangles: int) {
	append(&app.library.meshes, Pack_Mesh{pack = strings.clone(id), stem = strings.clone(stem), file = strings.clone(file), vertices = vertices, triangles = triangles})
}

// The library's mesh `j`, unless it is gone.
pack_mesh_at :: proc(app: ^App, j: int) -> (^Pack_Mesh, bool) {
	if j < 0 || j >= len(app.library.meshes) || app.library.meshes[j].gone do return nil, false
	return &app.library.meshes[j], true
}

// Pack `id`'s mesh named `stem` (ignoring case), or -1.
pack_mesh_find :: proc(app: ^App, id, stem: string) -> int {
	for m, j in app.library.meshes do if !m.gone && strings.equal_fold(m.pack, id) && strings.equal_fold(m.stem, stem) do return j
	return -1
}

// The mesh a script names `<pack id>/<stem>`, or -1.
pack_mesh_by_ref :: proc(app: ^App, ref: string) -> int {
	slash := strings.index_byte(ref, '/')
	if slash < 0 do return -1
	return pack_mesh_find(app, ref[:slash], ref[slash + 1:])
}

// The name of the pack mesh `j` comes from, for lists and notes.
pack_mesh_pack_name :: proc(app: ^App, j: int) -> string {
	for p in app.library.packs do if p.id == app.library.meshes[j].pack do return p.name
	return app.library.meshes[j].pack
}

// After a pack's meshes were marked gone: what pointed at one (the Add object pick, an
// armed New scene) moves to the mesh of the same pack and name now, as a replaced pack
// has, or lets go of it.
pack_meshes_retarget :: proc(app: ^App) {
	k := &app.kit
	moved :: proc(app: ^App, j: int) -> int {
		if j < 0 || j >= len(app.library.meshes) || !app.library.meshes[j].gone do return j
		return pack_mesh_find(app, app.library.meshes[j].pack, app.library.meshes[j].stem)
	}
	if k.add_mesh > 0 do k.add_mesh = moved(app, k.add_mesh - 1) + 1
	if k.new_armed >= NEW_ARMED_MESH {
		if j := moved(app, k.new_armed - NEW_ARMED_MESH); j >= 0 do k.new_armed = NEW_ARMED_MESH + j
		else do k.new_armed = 0
	}
}

// Adds the library's mesh `j` as a new object beside the others, selected, as Import
// does. Returns false only on a GPU failure.
scene_add_pack_mesh :: proc(app: ^App, j: int) -> bool {
	pm, ok := pack_mesh_at(app, j)
	if !ok do return true
	m, read := mesh_import_read(app, pm.file, fmt.tprintf("Added %s from %s", pm.stem, pack_mesh_pack_name(app, j)))
	if !read do return true
	if !scene_add_mesh(app, m.mesh, pm.stem, m.file, {position = next_free_position(app), scale = 1}, m.start) do return false
	app.stats.file_read_ms, app.stats.file_parse_ms = m.read_ms, m.parse_ms
	return true
}

// Replaces the scene with the library's mesh `j`, as New scene does with a shape: seen
// from the front, with no file to save to and an empty History. A mesh that cannot be
// read leaves the scene as it was. Returns false only on a GPU failure.
scene_new_pack_mesh :: proc(app: ^App, j: int) -> bool {
	pm, ok := pack_mesh_at(app, j)
	if !ok do return true
	start := time.tick_now()
	m, read := mesh_import_read(app, pm.file, fmt.tprintf("New scene: %s from %s", pm.stem, pack_mesh_pack_name(app, j)))
	if !read do return true
	obj := object_from_mesh(app, m.mesh, pm.stem, m.file, {scale = 1}, start) or_return
	obj.id = app.scene.next_id + 1
	scene_replace(app, {obj}, 0, obj.id, camera.orbit_default())
	scene_remember_path(app, "")
	autosave_scene_saved(app, "")
	// After scene_replace, which starts the stats afresh.
	app.stats.file_read_ms, app.stats.file_parse_ms = m.read_ms, m.parse_ms
	return true
}

// How Kit_State.new_armed names a pack mesh's New scene: NEW_ARMED_MESH + its index,
// apart from the shapes' 1 to len(NEW_SCENES).
NEW_ARMED_MESH :: 1 << 16

// Whether New scene from the library's mesh `j` was asked once and a second ask now
// goes ahead.
new_mesh_armed :: proc(app: ^App, j: int) -> bool {
	k := &app.kit
	return k.new_armed == NEW_ARMED_MESH + j && k.ctx.time - k.new_armed_at < NEW_SCENE_ARM_TIME
}

// Starts a new scene of the library's mesh `j` at the next frame; with work to lose the
// first ask only arms it, as New scene does with a shape.
new_mesh_run :: proc(app: ^App, j: int) {
	k := &app.kit
	pm, ok := pack_mesh_at(app, j)
	if !ok do return
	if scene_has_work(app) && !new_mesh_armed(app, j) {
		k.new_armed, k.new_armed_at = NEW_ARMED_MESH + j, max(k.ctx.time, 1e-6)
		report(app, nil, {.Warning}, "New scene discards this scene and its History: pick %s again to go ahead", pm.stem)
		return
	}
	k.new_armed = 0
	app.ui.scene_command = {kind = .New, mesh = j + 1}
}
