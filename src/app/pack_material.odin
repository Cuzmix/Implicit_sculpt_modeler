package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import sdl "vendor:sdl3"

import "../render"

// A content pack's matcaps and materials. Matcaps are images of a lit sphere right in its
// `matcaps/` folder; `materials.txt` has one `material <name> <r> <g> <b> <metallic>
// <roughness> <matcap>` line a material, its colour in linear light as the settings
// keep Custom's, and its matcap `-` for the lights, a built-in's word (`red-wax`,
// `clay`, `grey`, `skin`, `pearl`, `toon`) or one of the pack's own by its stem, which
// wins over a built-in's word. A matcap no line names is a material of its own, white,
// named after it, so a folder of matcap pictures is a pack as it stands. Install checks
// every picture on its thread and writes materials.txt back with a `matcap <stem>
// <file>` line for each picture, so a start reads that one file and decodes nothing.
// A matcap's texture is made only once something shows it (pack_matcaps_settle), so a
// library of many costs GPU memory only for the ones in use.

PACK_MATCAPS :: "matcaps"
PACK_MATERIALS :: "materials.txt"
// The most matcaps and materials (its own and the matcaps' by themselves) a pack brings.
PACK_MATCAPS_MAX :: 32
PACK_MATERIALS_MAX :: 64
// The largest matcap picture, across and down: 4 MB of GPU memory, more than a sphere
// needs at any screen size, and a decode short enough not to hold up a frame.
PACK_MATCAP_SIZE_MAX :: 1024

// Material.matcap's value for a content pack's matcap: PACK_MATCAP + its index in
// Library.matcaps, apart from the built-ins and the loaded image.
PACK_MATCAP :: 1 << 16

// A pack's matcap, in Library.matcaps. A removed pack's are marked gone and stay, so an
// index into the list holds for the run (Material.matcap).
Pack_Matcap :: struct {
	pack:    string, // the pack's id, owned
	stem:    string, // owned
	file:    string, // owned: the full path
	texture: ^sdl.GPUTexture, // nil until something shows it
	failed:  bool, // the file did not read when it was wanted, so it is not tried again
	gone:    bool,
}

// A pack's material, in Library.materials; its `material` names it with `label`, which
// the library owns until it is destroyed, so a copy in an object never dangles.
Pack_Material :: struct {
	pack:     string, // owned
	name:     string, // owned
	label:    cstring, // owned, the name again
	material: Material,
	gone:     bool,
}

// A matcap an install checked: its stem and its file's name in the matcaps folder.
Pack_Matcap_Read :: struct {
	stem, file: string, // owned
}

// A materials.txt line as read, before its matcap word is looked up.
Pack_Material_Read :: struct {
	name:     string, // owned by the allocator it was read with
	material: Material,
	matcap:   string, // `-`, a built-in's word or a stem; owned likewise
}

// A material's content pack parts by name, for the scene file: `<id>/<name>` and
// `<id>/<stem>`, "" for none.
Material_Refs :: struct {
	material, matcap: string,
}

// The word materials.txt takes for built-in matcap `i` (from 1): its name in lower case
// with dashes.
matcap_word :: proc(i: int) -> string {
	w, _ := strings.replace_all(strings.to_lower(string(MATCAP_RECIPES[i - 1].label), context.temp_allocator), " ", "-", context.temp_allocator)
	return w
}

// Checks one matcap of a pack on the install thread: "" when it reads and is small
// enough, otherwise why not.
pack_matcap_check :: proc(data: []u8) -> (failed: string) {
	rgba, width, height, why := matcap_pixels(data, context.temp_allocator)
	if why != "" do return why
	_ = rgba
	if width > PACK_MATCAP_SIZE_MAX || height > PACK_MATCAP_SIZE_MAX do return fmt.tprintf("it is %d x %d, and a MatCap may be at most %d x %d", width, height, PACK_MATCAP_SIZE_MAX, PACK_MATCAP_SIZE_MAX)
	return ""
}

// Reads materials.txt's `material` lines into `out`, given the stems of the pack's own
// matcaps; returns how many lines it cannot use (damaged, a value out of range, a name
// taken by a preset, by Custom or by an earlier line, a matcap the pack lacks, or past
// the limit). Blank lines, `#` comments and `matcap` lines are not counted.
pack_materials_parse :: proc(text: string, stems: []string, out: ^[dynamic]Pack_Material_Read, allocator := context.allocator) -> (bad: int) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 || strings.has_prefix(f[0], "#") || f[0] == "matcap" do continue
		if len(f) != 8 || f[0] != "material" || len(out) >= PACK_MATERIALS_MAX {
			bad += 1
			continue
		}
		name := strings.trim_space(preset_unescape(f[1]))
		v: [5]f32
		// No control characters, which a list or a settings line could not show or hold.
		ok := name != "" && len(name) <= PRESET_NAME_MAX && !strings.equal_fold(name, "custom") && !strings.contains_any(name, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\x0c\r\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x7f")
		for k in 0 ..< 5 {
			n, n_ok := strconv.parse_f32(f[2 + k])
			v[k] = n
			ok &&= n_ok && n >= (0.04 if k == 4 else 0) && n <= 1
		}
		_, preset := material_by_name(name)
		for r in out do ok &&= !strings.equal_fold(r.name, name)
		word := preset_unescape(f[7])
		known := word == "-"
		for s in stems do known ||= strings.equal_fold(s, word)
		for i in 1 ..= len(MATCAP_RECIPES) do known ||= word == matcap_word(i)
		if !ok || preset || !known {
			bad += 1
			continue
		}
		m := Material {
			selected  = {v[0], v[1], v[2], 1},
			idle      = {0.42, 0.42, 0.44, 1} if word == "-" else MATCAP_IDLE,
			metallic  = v[3],
			roughness = v[4],
		}
		append(out, Pack_Material_Read{name = strings.clone(name, allocator), material = m, matcap = strings.clone(word, allocator)})
	}
	return
}

// Adds a material of its own for each of `stems` that no read material uses: white,
// shaded by it, named after it (numbered when the name is taken), while there is room.
pack_materials_for_matcaps :: proc(stems: []string, out: ^[dynamic]Pack_Material_Read, allocator := context.allocator) {
	for s in stems {
		used := false
		for r in out do used ||= strings.equal_fold(r.matcap, s)
		// Named as a line may name it, so a start reads back what install writes: trimmed,
		// and short enough with a number after it.
		base := preset_name_fit_room(strings.trim_space(s), 3)
		if used || base == "" || len(out) >= PACK_MATERIALS_MAX do continue
		for n := 1; ; n += 1 {
			name := base if n == 1 else fmt.tprintf("%s %d", base, n)
			_, taken := material_by_name(name)
			for r in out do taken ||= strings.equal_fold(r.name, name)
			if taken do continue
			// The roughness is what a line must have, though a matcap's picture holds the sheen.
			m := Material{selected = {1, 1, 1, 1}, idle = MATCAP_IDLE, roughness = 0.5}
			append(out, Pack_Material_Read{name = strings.clone(name, allocator), material = m, matcap = strings.clone(s, allocator)})
			break
		}
	}
}

// materials.txt as install writes it back: a `matcap <stem> <file>` line a picture, then
// every material, names escaped as preset names are.
pack_materials_index :: proc(matcaps: []Pack_Matcap_Read, materials: []Pack_Material_Read) -> string {
	out := strings.builder_make(context.temp_allocator)
	for m in matcaps do fmt.sbprintfln(&out, "matcap %s %s", preset_escape(m.stem), preset_escape(m.file))
	for r in materials {
		m := r.material
		fmt.sbprintfln(&out, "material %s %g %g %g %g %g %s", preset_escape(r.name), m.selected.r, m.selected.g, m.selected.b, m.metallic, m.roughness, preset_escape(r.matcap))
	}
	return strings.to_string(out)
}

// Reads pack `id`'s materials.txt in `folder` into the library: its matcaps whose files
// are there, then its materials. Returns how many materials it added and whether a line
// was refused (changed by hand since install wrote it).
pack_materials_load :: proc(app: ^App, id, folder: string) -> (added: int, refused: bool) {
	path, _ := filepath.join({folder, PACK_MATERIALS}, context.temp_allocator)
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	matcaps := make([dynamic]Pack_Matcap_Read, context.temp_allocator)
	rest := string(text)
	for line in strings.split_lines_iterator(&rest) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 || f[0] != "matcap" do continue
		file := preset_unescape(f[2]) if len(f) == 3 else ""
		full, _ := filepath.join({folder, PACK_MATCAPS, file}, context.temp_allocator)
		if file == "" || strings.contains_any(file, "/\\") || !os.exists(full) || len(matcaps) >= PACK_MATCAPS_MAX {
			refused = true
			continue
		}
		append(&matcaps, Pack_Matcap_Read{stem = preset_unescape(f[1]), file = full})
	}
	stems := make([]string, len(matcaps), context.temp_allocator)
	for m, i in matcaps do stems[i] = m.stem
	read := make([dynamic]Pack_Material_Read, context.temp_allocator)
	refused ||= pack_materials_parse(string(text), stems, &read, context.temp_allocator) > 0
	return pack_materials_add(app, id, matcaps[:], read[:]), refused
}

// Adds pack `id`'s matcaps (`file` a full path) and materials to the library, the
// materials' matcap words looked up: the pack's own first, then the built-ins.
pack_materials_add :: proc(app: ^App, id: string, matcaps: []Pack_Matcap_Read, materials: []Pack_Material_Read) -> (added: int) {
	l := &app.library
	first := len(l.matcaps)
	for m in matcaps do append(&l.matcaps, Pack_Matcap{pack = strings.clone(id), stem = strings.clone(m.stem), file = strings.clone(m.file)})
	for r in materials {
		m := r.material
		for k in first ..< len(l.matcaps) do if m.matcap == 0 && strings.equal_fold(l.matcaps[k].stem, r.matcap) do m.matcap = PACK_MATCAP + k
		for i in 1 ..= len(MATCAP_RECIPES) do if m.matcap == 0 && r.matcap == matcap_word(i) do m.matcap = i
		label := strings.clone_to_cstring(r.name)
		m.label, m.pack = label, len(l.materials) + 1
		append(&l.materials, Pack_Material{pack = strings.clone(id), name = strings.clone(r.name), label = label, material = m})
		added += 1
	}
	return
}

pack_material_free :: proc(m: ^Pack_Material) {
	delete(m.pack)
	delete(m.name)
	delete(m.label)
	m^ = {}
}

// Frees a matcap's strings and its texture, which the GPU is done with first.
pack_matcap_free :: proc(app: ^App, m: ^Pack_Matcap) {
	render.matcap_destroy(&app.renderer, &m.texture)
	delete(m.pack)
	delete(m.stem)
	delete(m.file)
	m^ = {}
}

// The library's matcap `k`, unless it is gone.
pack_matcap_at :: proc(app: ^App, k: int) -> (^Pack_Matcap, bool) {
	if k < 0 || k >= len(app.library.matcaps) || app.library.matcaps[k].gone do return nil, false
	return &app.library.matcaps[k], true
}

// The library's material `j`, unless it is gone.
pack_material_at :: proc(app: ^App, j: int) -> (^Pack_Material, bool) {
	if j < 0 || j >= len(app.library.materials) || app.library.materials[j].gone do return nil, false
	return &app.library.materials[j], true
}

// Pack `id`'s matcap named `stem` (ignoring case), or -1.
pack_matcap_find :: proc(app: ^App, id, stem: string) -> int {
	for m, k in app.library.matcaps do if !m.gone && strings.equal_fold(m.pack, id) && strings.equal_fold(m.stem, stem) do return k
	return -1
}

// Pack `id`'s material named `name` (ignoring case), or -1.
pack_material_find :: proc(app: ^App, id, name: string) -> int {
	for m, j in app.library.materials do if !m.gone && strings.equal_fold(m.pack, id) && strings.equal_fold(m.name, name) do return j
	return -1
}

// The matcap or material a reference names, `<pack id>/<name>`, or -1.
pack_matcap_by_ref :: proc(app: ^App, ref: string) -> int {
	slash := strings.index_byte(ref, '/')
	return pack_matcap_find(app, ref[:slash], ref[slash + 1:]) if slash >= 0 else -1
}
pack_material_by_ref :: proc(app: ^App, ref: string) -> int {
	slash := strings.index_byte(ref, '/')
	return pack_material_find(app, ref[:slash], ref[slash + 1:]) if slash >= 0 else -1
}

// Whether `ref` is "" or `<id>/<name>` with both parts there, as the scene file must hold.
material_ref_valid :: proc(ref: string) -> bool {
	slash := strings.index_byte(ref, '/')
	return ref == "" || (slash > 0 && slash < len(ref) - 1)
}

// The name of the pack material `j` comes from, for lists.
pack_material_pack_name :: proc(app: ^App, j: int) -> string {
	for p in app.library.packs do if p.id == app.library.materials[j].pack do return p.name
	return app.library.materials[j].pack
}

// What of `m` is a content pack's, by name (temp memory), for the scene file.
material_refs :: proc(app: ^App, m: Material) -> (refs: Material_Refs) {
	if pm, ok := pack_material_at(app, m.pack - 1); ok && m.pack > 0 do refs.material = fmt.tprintf("%s/%s", pm.pack, pm.name)
	if mc, ok := pack_matcap_at(app, m.matcap - PACK_MATCAP); ok && m.matcap >= PACK_MATCAP do refs.matcap = fmt.tprintf("%s/%s", mc.pack, mc.stem)
	return
}

// The content pack parts by name (temp memory) of `obj`'s material and then of each of its
// groups' (object_put_bytes).
object_material_refs :: proc(app: ^App, obj: ^Object) -> []Material_Refs {
	refs := make([]Material_Refs, 1 + len(obj.group_materials), context.temp_allocator)
	refs[0] = material_refs(app, obj.material)
	for e, k in obj.group_materials do refs[1 + k] = material_refs(app, e.material)
	return refs
}

// After a pack's matcaps and materials were marked gone: what used one (the default new
// objects take, Custom, and every object) moves to the one of the same pack and name
// now, as a replaced pack has, or falls back: a material to a Custom one of the same
// colours and the lights, Custom's matcap to the lights, the default to Clay. Releases
// the gone matcaps' textures. Returns how many objects fell back.
pack_materials_retarget :: proc(app: ^App) -> (fell: int) {
	l := &app.library
	if app.material >= PACK_MATERIAL {
		j := app.material - PACK_MATERIAL
		app.material = 0
		if j < len(l.materials) {
			if !l.materials[j].gone do app.material = PACK_MATERIAL + j
			else if n := pack_material_find(app, l.materials[j].pack, l.materials[j].name); n >= 0 do app.material = PACK_MATERIAL + n
		}
	}
	app.custom.matcap = pack_matcap_moved(app, app.custom.matcap)
	changed := false
	for obj in app.scene.objects {
		m, dropped := pack_material_moved(app, obj.material)
		// Its groups' too: one that falls back counts the object once.
		group_dropped := false
		for &e in obj.group_materials {
			g, gone := pack_material_moved(app, e.material)
			if g == e.material do continue
			// The autosave thread may be reading the object's materials.
			if !changed do autosave_settle(app)
			e.material = g
			changed = true
			group_dropped ||= gone
		}
		if group_dropped && !dropped do fell += 1
		if m == obj.material do continue
		if !changed do autosave_settle(app)
		obj.material = m
		changed = true
		if dropped do fell += 1
	}
	if changed do app.scene_edits += 1
	released := false
	for &mc in l.matcaps {
		if !mc.gone || mc.texture == nil do continue
		render.matcap_destroy(&app.renderer, &mc.texture)
		released = true
	}
	if released || changed do render.viewport_invalidate(&app.target)
	return
}

// Where matcap `matcap` is now: itself unless it is a gone pack matcap, which moves to
// the one of the same pack and stem or to 0, the lights.
@(private = "file")
pack_matcap_moved :: proc(app: ^App, matcap: int) -> int {
	k := matcap - PACK_MATCAP
	if matcap < PACK_MATCAP || k >= len(app.library.matcaps) || !app.library.matcaps[k].gone do return matcap
	if n := pack_matcap_find(app, app.library.matcaps[k].pack, app.library.matcaps[k].stem); n >= 0 do return PACK_MATCAP + n
	return 0
}

// The material `m` is now, and whether it fell back to a Custom one or the lights.
@(private = "file")
pack_material_moved :: proc(app: ^App, m: Material) -> (Material, bool) {
	m := m
	j := m.pack - 1
	if m.pack > 0 && j < len(app.library.materials) && app.library.materials[j].gone {
		if n := pack_material_find(app, app.library.materials[j].pack, app.library.materials[j].name); n >= 0 do return app.library.materials[n].material, false
		m.label, m.pack = "Custom", 0
		m.matcap = pack_matcap_moved(app, m.matcap)
		return m, true
	}
	before := m.matcap
	m.matcap = pack_matcap_moved(app, m.matcap)
	return m, before != m.matcap && m.matcap == 0
}

// At the end of each frame's interface, before its drawing: makes the texture of each
// pack matcap something now shows (an object's material, Custom or the default) and has
// none, so a pick shows in the frame it is made. Making one releases those nothing
// shows, so GPU memory holds only what is in use. A picture that no longer reads leaves
// one note and the lights, and is not tried again.
pack_matcaps_settle :: proc(app: ^App) {
	l := &app.library
	if len(l.matcaps) == 0 || app.renderer.device == nil do return
	need := make([]bool, len(l.matcaps), context.temp_allocator)
	mark :: proc(need: []bool, m: Material) {
		if k := m.matcap - PACK_MATCAP; m.matcap >= PACK_MATCAP && k < len(need) do need[k] = true
	}
	mark(need, app.custom)
	mark(need, current_material(app))
	for obj in app.scene.objects do mark(need, obj.material)
	made := false
	for &mc, k in l.matcaps {
		if !need[k] || mc.gone || mc.failed || mc.texture != nil do continue
		why := ""
		data, err := os.read_entire_file(mc.file, context.temp_allocator)
		if err != nil do why = fmt.tprintf("%v", err)
		if why == "" {
			pixels, w, h, failed := matcap_pixels(data, context.temp_allocator)
			// Install held it to the limit; a file changed by hand since is held to it too.
			if failed == "" && (w > PACK_MATCAP_SIZE_MAX || h > PACK_MATCAP_SIZE_MAX) do failed = fmt.tprintf("it is %d x %d, past the %d x %d a MatCap may be", w, h, PACK_MATCAP_SIZE_MAX, PACK_MATCAP_SIZE_MAX)
			if failed == "" do mc.texture = render.matcap_create(&app.renderer, pixels, w, h)
			why = failed if failed != "" else ("the GPU refused it" if mc.texture == nil else "")
		}
		if why != "" {
			mc.failed = true
			file_note(app, true, "Cannot show the MatCap %s: %s; it shows the lights", mc.stem, why)
			continue
		}
		made = true
		l.textures_made += 1
	}
	if !made do return
	for &mc, k in l.matcaps do if !need[k] && mc.texture != nil do render.matcap_destroy(&app.renderer, &mc.texture)
	render.viewport_invalidate(&app.target)
}
