package main

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import sdl "vendor:sdl3"

import "../geom"
import "../jobs"
import "../sculpt"
import "../voxel"

// The live link with Blender, after ZBrush's GoZ: Send to Blender writes the selected
// objects to a folder the Blender add-on (tools/blender/sculpt_link.py) reads, and Get
// from Blender takes back what the add-on wrote there, with no file dialogs on either
// side. It is files in a folder and nothing else: no network, no process started.
//
// The app writes each object's shown level as `<id>.ply` in its own space (never the
// file placement exports use), so a mesh Blender leaves alone comes back bit for bit, and
// then `link.txt`, which names them. Blender writes `blender-<id>.ply` and `blender.txt`
// the same way. A manifest's lines:
//
//	sculpt_link 1                 (blender_link 1 for Blender's)
//	scene <token>                 the scene the objects are from, 16 hex digits
//	sent <n>                      rises with each send, so a reader can tell a new one
//	object <id> <level> <name> <file> <vertices> <triangles> <x y z> <rx ry rz> <scale>
//	light <name> <kind> <x y z> <dx dy dz> <r g b> <intensity> <range> <inner> <outer> <size>
//
// A name is escaped as the settings escape one (preset_escape); the transform is the
// object's (Transform), in the app's axes, Y up. Blender gives id 0 to an object it made.
// The scene token is made by the first send from a scene and saved with it (scene file
// version 17), so ids from another scene, which may name an unrelated object here, never
// replace anything: they come back as new objects.
//
// Each send also lists the scene's lights that are on, in Sculpt's axes, as a glTF export
// gives them (export_lights: directional, point or spot; the place, unused by a
// directional one; the way it shines; linear colour; lux or candela; range, 0 for none;
// a spot's inner and outer half angles in radians), so Blender lights the objects as
// Sculpt does. They go one way: Blender sends no lights back, and a reader that does not
// know the line skips it.

LINK_FOLDER :: "link"
LINK_SENT_FILE :: "link.txt"
LINK_BACK_FILE :: "blender.txt"
// The newest of Blender's sends taken, `taken <token> <n>`, kept in the folder so a send is
// taken once even across runs.
LINK_TAKEN_FILE :: "taken.txt"
LINK_VERSION :: 1
// More objects than a manifest may list, and a longer name than one may give: damage.
LINK_MAX_OBJECTS :: 256
LINK_NAME_MAX :: 256

// The link is a desktop one: there is no Blender on a tablet to link with.
LINK_AVAILABLE :: ODIN_PLATFORM_SUBTARGET != .Android

Link :: struct {
	folder: string, // owned; "" in a run that keeps no settings, which has no link
	sent:   [dynamic]Link_Sent,
	seq:    int, // the last send's number
	// The window got the focus back: Blender's folder is looked at once nothing else is
	// waiting (link_frame). Only in a run with a person (`auto`).
	check: bool,
	auto:  bool,
	// What this run did, for the exit stats: objects sent, and got back by moving their
	// vertices, by a new mesh, or as new objects.
	sends, moved, swapped, added: int,
}

// An object this run sent, and when, to tell a change made here since then.
Link_Sent :: struct {
	id: int,
	at: time.Tick,
}

// One object line of a manifest. Strings are owned by the manifest's allocator.
Link_Object :: struct {
	id:        int,
	level:     int,
	name:      string,
	file:      string,
	vertices:  int,
	triangles: int,
	transform: Transform,
}

Link_Manifest :: struct {
	token:   u64,
	seq:     int,
	objects: [dynamic]Link_Object,
}

// What a get does with an object Blender sent back.
Link_Action :: enum u8 {
	Project, // its vertices move to Blender's: the same triangles, at the level sent
	Keep,    // a voxel or dynamic object Blender sent back exactly as it went: only its place comes back
	Swap,    // it is rebuilt from Blender's mesh: other triangles, or not a plain mesh here
	Add,     // a new object: one Blender made, or one this scene does not know
}

// The link's folder: `link` beside the settings file or, for a settings file of another
// name (--settings-file), `<its name>-link`, as library_folder does.
link_folder :: proc(settings: string) -> string {
	if settings == "" do return ""
	dir, base := filepath.split(settings)
	name := LINK_FOLDER if base == SETTINGS_FILE else fmt.tprintf("%s-%s", filepath.stem(base), LINK_FOLDER)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

link_init :: proc(app: ^App, folder: string, auto: bool) {
	app.link.folder = strings.clone(folder) if LINK_AVAILABLE else ""
	app.link.auto = auto && app.link.folder != ""
}

link_destroy :: proc(app: ^App) {
	delete(app.link.folder)
	delete(app.link.sent)
	app.link = {}
}

link_manifest_free :: proc(m: ^Link_Manifest) {
	for o in m.objects {
		delete(o.name, m.objects.allocator)
		delete(o.file, m.objects.allocator)
	}
	delete(m.objects)
	m^ = {}
}

// A manifest as its file holds it, `head` being sculpt_link or blender_link. In the temp
// allocator.
link_manifest_text :: proc(head: string, m: Link_Manifest, lights: []geom.Export_Light = nil) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s %d\nscene %016x\nsent %d\n", head, LINK_VERSION, m.token, m.seq)
	for o in m.objects {
		// %v writes the shortest digits that read back as the same float.
		p, r := o.transform.position, o.transform.rotation
		fmt.sbprintf(&b, "object %d %d %s %s %d %d %v %v %v %v %v %v %v\n", o.id, o.level, link_name_word(o.name), o.file, o.vertices, o.triangles, p.x, p.y, p.z, r.x, r.y, r.z, o.transform.scale)
	}
	for l in lights {
		p, d, c := l.position, l.direction, l.color
		fmt.sbprintf(&b, "light %s %s %v %v %v %v %v %v %v %v %v %v %v %v %v %v\n", link_name_word(l.name), LINK_LIGHT_KINDS[l.kind], p.x, p.y, p.z, d.x, d.y, d.z, c.r, c.g, c.b, l.intensity, l.range, l.inner_cone, l.outer_cone, l.size)
	}
	return strings.to_string(b)
}

// Each kind of light as a manifest names it, as glTF does.
@(rodata)
LINK_LIGHT_KINDS := [geom.Export_Light_Kind]string {
	.Directional = "directional",
	.Point       = "point",
	.Spot        = "spot",
}

// A name as one word of a manifest: %, every control byte and space, and every byte of a
// character past ASCII (some of which are white space to a reader splitting at it) as %XX,
// which preset_unescape reads; "-" for no name (a name that is "-" itself is escaped).
@(private = "file")
link_name_word :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)name {
		if c > ' ' && c < 0x7f && c != '%' do strings.write_byte(&b, c)
		else do fmt.sbprintf(&b, "%%%02X", c)
	}
	word := strings.to_string(b)
	switch word {
	case "":  return "-"
	case "-": return "%2D"
	}
	return word
}

// Reads a manifest whose first line is `head`, its strings in `allocator`. Refused
// whole (false) on any damage, so a get never takes part of what was sent: a line it
// does not know is skipped, for later versions, but an object line must be whole and
// sound.
link_manifest_parse :: proc(text, head: string, allocator := context.allocator) -> (m: Link_Manifest, ok: bool) {
	m.objects = make([dynamic]Link_Object, allocator)
	if !link_manifest_read(&m, text, head) {
		link_manifest_free(&m)
		return {}, false
	}
	return m, true
}

@(private = "file")
link_manifest_read :: proc(m: ^Link_Manifest, text, head: string) -> (ok: bool) {
	allocator := m.objects.allocator
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) == 0 do return
	first := strings.fields(lines[0], context.temp_allocator)
	if len(first) != 2 || first[0] != head do return
	if version, parsed := strconv.parse_int(first[1]); !parsed || version < 1 do return
	seen_token, seen_seq := false, false
	for line in lines[1:] {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 do continue
		switch f[0] {
		case "scene":
			if len(f) != 2 || len(f[1]) != 16 do return
			token, parsed := strconv.parse_u64_of_base(f[1], 16)
			if !parsed do return
			m.token, seen_token = token, true
		case "sent":
			if len(f) != 2 do return
			seq, parsed := strconv.parse_int(f[1])
			if !parsed || seq < 0 do return
			m.seq, seen_seq = seq, true
		case "object":
			if len(f) != 14 || len(m.objects) >= LINK_MAX_OBJECTS do return
			o: Link_Object
			ints := [4]^int{&o.id, &o.level, &o.vertices, &o.triangles}
			words := [4]string{f[1], f[2], f[5], f[6]}
			for p, k in ints {
				v, parsed := strconv.parse_int(words[k])
				if !parsed do return
				p^ = v
			}
			floats: [7]f32
			for &v, k in floats {
				parsed: bool
				v, parsed = strconv.parse_f32(f[7 + k])
				if !parsed do return
			}
			o.transform = {position = {floats[0], floats[1], floats[2]}, rotation = {floats[3], floats[4], floats[5]}, scale = floats[6]}
			name := "" if f[3] == "-" else preset_unescape(f[3])
			sound := o.id >= 0 && o.level >= 0 && o.level < sculpt.MAX_LEVELS && o.vertices > 0 && o.triangles > 0 && o.vertices < int(max(u32)) && o.triangles < int(max(u32) / 3)
			sound &&= link_file_ok(f[4]) && len(name) <= LINK_NAME_MAX && finite(o.transform.position) && finite(o.transform.rotation) && finite({o.transform.scale, 0, 0}) && o.transform.scale > 0
			for other in m.objects do sound &&= other.file != f[4] && (o.id == 0 || other.id != o.id)
			if !sound do return
			o.name = strings.clone(name, allocator)
			o.file = strings.clone(f[4], allocator)
			append(&m.objects, o)
		}
	}
	return seen_token && seen_seq
}

// Whether `name` may be a link file: a plain name in the folder itself, of letters,
// digits and hyphens, ending in .ply. Nothing a manifest says reaches outside the folder.
link_file_ok :: proc(name: string) -> bool {
	if !strings.has_suffix(name, ".ply") || len(name) <= 4 || len(name) > 64 do return false
	for c in transmute([]u8)name[:len(name) - 4] {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-':
		case: return false
		}
	}
	return true
}

// The scene's link token, made the first time anything is sent from it. Making it is a
// change to what the scene saves, though no edit (view_edits counts it for the autosave).
link_scene_token :: proc(app: ^App) -> u64 {
	if app.scene.link_token == 0 do app.view_edits += 1
	for app.scene.link_token == 0 do app.scene.link_token = rand.uint64()
	return app.scene.link_token
}

// Whether anything is selected to send, in a run that has a link.
link_can_send :: proc(app: ^App) -> bool {return LINK_AVAILABLE && app.link.folder != "" && selected_object(app) != nil}
link_can_get :: proc(app: ^App) -> bool {return LINK_AVAILABLE && app.link.folder != ""}

// About what sending the selected objects writes, for the busy toast.
link_send_bytes :: proc(app: ^App) -> int {
	bytes := 0
	for id in selection_ids(app) do if obj := object_by_id(app, id); obj != nil do bytes += object_export_bytes(obj)
	return bytes
}

// About what getting Blender's objects reads: the size of the files its manifest names.
link_get_bytes :: proc(app: ^App) -> int {
	if app.link.folder == "" do return 0
	data, err := os.read_entire_file(link_path(app, LINK_BACK_FILE), context.temp_allocator)
	if err != nil do return 0
	m, ok := link_manifest_parse(string(data), "blender_link", context.temp_allocator)
	if !ok do return 0
	bytes := 0
	for o in m.objects {
		if info, serr := os.stat(link_path(app, o.file), context.temp_allocator); serr == nil do bytes += int(info.size)
	}
	return bytes
}

@(private = "file")
link_path :: proc(app: ^App, name: string) -> string {
	path, _ := filepath.join({app.link.folder, name}, context.temp_allocator)
	return path
}

// Writes the selected objects' shown levels and the manifest naming them to the link
// folder. A voxel object goes as its surface, a dynamic one packed, as Export writes them;
// paint goes as vertex colours over white.
link_send :: proc(app: ^App) {
	l := &app.link
	if !link_can_send(app) {
		file_note(app, true, "Select an object to send to Blender first" if l.folder != "" else "This run keeps no settings, so it has no link folder for Blender")
		return
	}
	stroke_finish(app)
	inspector_drags_end(app)
	start := time.tick_now()
	ids := slice.clone(selection_ids(app))
	defer delete(ids)
	if err := os.make_directory_all(l.folder); err != nil && !os.exists(l.folder) {
		file_note(app, true, "Cannot send to Blender: cannot make the link folder %s: %v", l.folder, err)
		return
	}
	m := Link_Manifest{token = link_scene_token(app), objects = make([dynamic]Link_Object)}
	defer link_manifest_free(&m)
	// The number goes on from the folder's, so Blender sees a new send even from a new run.
	if data, err := os.read_entire_file(link_path(app, LINK_SENT_FILE), context.temp_allocator); err == nil {
		if old, ok := link_manifest_parse(string(data), "sculpt_link", context.temp_allocator); ok do l.seq = max(l.seq, old.seq)
	}
	m.seq = l.seq + 1
	vertices := 0
	for id in ids {
		obj := object_by_id(app, id)
		if obj == nil do continue
		file := fmt.aprintf("%d.ply", obj.id)
		append(&m.objects, Link_Object{id = obj.id, level = obj.levels.current, name = strings.clone(object_label(obj)), file = file, transform = obj.transform})
		o := &m.objects[len(m.objects) - 1]
		out := make([dynamic]u8)
		defer delete(out)
		o.vertices, o.triangles = link_object_ply(app, obj, &out)
		vertices += o.vertices
		if err := write_durably(link_path(app, file), out[:]); err != "" {
			file_note(app, true, "Cannot send %s to Blender: %s", object_label(obj), err)
			return
		}
	}
	// The objects of earlier sends that this one does not list go, so the folder holds no
	// more than one send.
	if infos, err := folder_entries(l.folder, context.temp_allocator); err == nil {
		for fi in infos {
			stem := strings.trim_suffix(fi.name, ".ply")
			if stem == fi.name || len(stem) == 0 || strings.trim_left(stem, "0123456789") != "" do continue
			listed := false
			for o in m.objects do listed ||= o.file == fi.name
			if !listed do _ = os.remove(fi.fullpath)
		}
	}
	// The manifest goes last, so Blender never reads one whose files are not all there.
	if err := write_durably(link_path(app, LINK_SENT_FILE), transmute([]u8)link_manifest_text("sculpt_link", m, export_lights(app))); err != "" {
		file_note(app, true, "Cannot send to Blender: %s", err)
		return
	}
	l.seq = m.seq
	now := time.tick_now()
	for o in m.objects do link_sent_mark(app, o.id, now)
	l.sends += len(m.objects)
	ms := time.duration_milliseconds(time.tick_since(start))
	what := m.objects[0].name if len(m.objects) == 1 else fmt.tprintf("%d objects", len(m.objects))
	file_note(app, false, "Sent %s to Blender: %s vertices in %.0f ms. In Blender, Get from Sculpt in the Sculpt tab brings them in", what, count_label(vertices), ms)
}

// Writes the object's shown level to `out` as a binary PLY in its own space, as Export
// would shape it. Returns its vertex and triangle counts.
@(private = "file")
link_object_ply :: proc(app: ^App, obj: ^Object, out: ^[dynamic]u8) -> (vertices, triangles: int) {
	lv := sculpt.levels_current(&obj.levels)
	positions, indices := lv.mesh.positions[:], lv.mesh.indices[:]
	packed: geom.Mesh
	defer geom.mesh_destroy(&packed)
	colors: [][3]u8
	defer delete(colors)
	if vp := obj.voxel; vp != nil {
		packed = voxel.clay_to_mesh(&vp.clay)
		positions, indices = packed.positions[:], packed.indices[:]
	} else if object_dynamic(obj) {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(&lv.sculptor)
		delete(mask)
		positions, indices = packed.positions[:], packed.indices[:]
	} else if c := lv.sculptor.color; c != nil {
		colors = make([][3]u8, len(c))
		for x, v in c do colors[v] = paint_over(x, {255, 255, 255})
	}
	geom.mesh_write_ply(out, positions, indices, 1, {}, &app.pool, colors)
	return len(positions), len(indices) / 3
}

// Puts the link folder's path on the clipboard, for the add-on's Link folder.
link_copy_path :: proc(app: ^App) {
	if sdl.SetClipboardText(strings.clone_to_cstring(app.link.folder, context.temp_allocator)) {
		report(app, nil, {}, "Copied the link folder's path: paste it into Link folder in Blender's Sculpt tab")
	} else {
		report(app, nil, {.Warning}, "Cannot copy the path: %s", sdl.GetError())
	}
}

// The window has the focus again: Blender may have sent something.
link_focus :: proc(app: ^App) {
	if app.link.auto do app.link.check = true
}

// Once the focus came back and nothing else is waiting or under way (a file request or
// dialog, a save, a stroke or drag, a script or a pack being installed), looks at
// Blender's manifest and, when it is a new send for this scene, asks for it to be got,
// as a request applied at the start of the next frame. A request rather than a command,
// so a macro being recorded never takes it in.
link_frame :: proc(app: ^App) {
	l := &app.link
	if !l.check do return
	// The History rewound by the timeline or a replay would lose its redo to the get's step.
	if file_pending() || app.saving.kind != .None || history_busy(app) || timeline_busy(app) || replay_busy(app) || app.script.running || pack_busy(app) do return
	data, err := os.read_entire_file(link_path(app, LINK_BACK_FILE), context.temp_allocator)
	if err != nil {
		l.check = false
		return
	}
	m, ok := link_manifest_parse(string(data), "blender_link", context.temp_allocator)
	taken_token, taken := link_taken(app)
	if !ok || m.token != app.scene.link_token || app.scene.link_token == 0 || (m.token == taken_token && m.seq <= taken) {
		l.check = false
		return
	}
	// Posted only when no dialog shows and nothing waits, under the requests' lock, so a
	// dialog's answer landing meanwhile is never replaced; tried again next frame.
	if file_post_when_idle(.Link_Get, LINK_AUTO) do l.check = false
}

// The path of a get the focus asked for, which says nothing when there is nothing new.
LINK_AUTO :: "auto"

// What one object of a get became, for the note.
@(private = "file")
Link_Result :: struct {
	label:  string, // owned
	id:     int, // the object it acted on or made; 0 for one refused
	action: Link_Action,
	moved:  int, // vertices, for Project
	held:   int, // of those, held back by the mask or hiding
	edited: bool, // it had changed here since it was sent
	why:    Link_Why,
}

Link_Why :: enum u8 {
	None,
	Topology, // other triangles
	Voxel,    // a voxel object, rebuilt as a mesh
	Cage,     // a Model mode cage, which takes no sculpting: rebuilt as a mesh
	Dynamic,  // dynamic topology, whose packed mesh is new to it
	Other_Scene,
	Gone,       // deleted here since it was sent
	Level_Gone, // its level was deleted, or is not the one sent (levels deleted below it)
	Made,       // made in Blender
}

// Takes what Blender sent: each object of its manifest, in order, as one undo step. Every
// file is read before anything changes, so a send Blender is still writing, or a damaged
// file, changes nothing (and the send is not taken, so a later get tries again). `auto`
// is the focus check's: it says nothing when there is nothing new. Returns false only on
// a GPU failure.
link_get :: proc(app: ^App, auto := false) -> bool {
	if !link_can_get(app) {
		file_note(app, true, "This run keeps no settings, so it has no link folder for Blender")
		return true
	}
	start := time.tick_now()
	data, err := os.read_entire_file(link_path(app, LINK_BACK_FILE), context.allocator)
	if err != nil {
		if !auto do file_note(app, false, "Nothing from Blender yet: Send to Sculpt in Blender's Sculpt tab first")
		return true
	}
	m, ok := link_manifest_parse(string(data), "blender_link")
	delete(data)
	defer link_manifest_free(&m)
	if !ok {
		file_note(app, true, "Cannot get from Blender: its %s is damaged", LINK_BACK_FILE)
		return true
	}
	if taken_token, taken := link_taken(app); m.token == taken_token && m.seq <= taken {
		if !auto do file_note(app, false, "Nothing new from Blender since the last get")
		return true
	}
	if timeline_busy(app) || replay_busy(app) {
		file_note(app, true, "Cannot get from Blender while the History plays or a stroke replays: stop it first")
		return true
	}
	// What was sent, to tell a level changed since and an object sent back untouched.
	sent: Link_Manifest
	have_sent := false
	if text, serr := os.read_entire_file(link_path(app, LINK_SENT_FILE), context.allocator); serr == nil {
		sent, have_sent = link_manifest_parse(string(text), "sculpt_link")
		delete(text)
	}
	defer link_manifest_free(&sent)
	meshes := make([]geom.Mesh, len(m.objects))
	defer {
		for &mesh in meshes do geom.mesh_destroy(&mesh)
		delete(meshes)
	}
	for o, i in m.objects {
		bytes, rerr := os.read_entire_file(link_path(app, o.file), context.allocator)
		if rerr != nil {
			file_note(app, true, "Cannot get from Blender: %s is missing (%v)", o.file, rerr)
			return true
		}
		mesh, failed, _ := geom.mesh_read_ply(bytes, &app.pool)
		delete(bytes)
		meshes[i] = mesh
		if failed != .None || len(mesh.positions) != o.vertices || len(mesh.indices) != 3 * o.triangles || !link_finite(mesh.positions[:], &app.pool) {
			file_note(app, true, "Cannot get from Blender: %s is damaged or still being written; try again", o.file)
			return true
		}
	}
	stroke_finish(app)
	inspector_drags_end(app)
	results := make([dynamic]Link_Result)
	defer {
		for r in results do delete(r.label)
		delete(results)
	}
	chain := false
	for &o, i in m.objects {
		action, obj, why := link_plan(app, o, m.token, meshes[i], &sent if have_sent && sent.token == m.token else nil)
		r := Link_Result{action = action, why = why}
		if obj != nil do r.edited = link_edited(app, obj.id)
		if !link_apply(app, o, &meshes[i], action, obj, &chain, &r) do return false
		// Nothing of a change made here was replaced when nothing came back different.
		r.edited &&= r.action == .Swap || r.action == .Project && r.moved > 0
		append(&results, r)
	}
	// What came back is where the next get's changes are counted from, as a send is.
	now := time.tick_now()
	for r in results do if r.id != 0 do link_sent_mark(app, r.id, now)
	if err := link_take(app, m.token, m.seq); err != "" do log.warnf("blender link: cannot note the send as taken: %s", err)
	link_note(app, results[:], chain, time.duration_milliseconds(time.tick_since(start)))
	return true
}

// What a get does with object line `o` of a manifest for scene `token`, carrying `mesh`,
// given what the app last sent for that scene (`sent`, nil for nothing known): the object
// it acts on (nil for Add), and why when it is not the plain Project.
link_plan :: proc(app: ^App, o: Link_Object, token: u64, mesh: geom.Mesh, sent: ^Link_Manifest = nil) -> (action: Link_Action, obj: ^Object, why: Link_Why) {
	if o.id == 0 do return .Add, nil, .Made
	if token == 0 || token != app.scene.link_token do return .Add, nil, .Other_Scene
	obj = object_by_id(app, o.id)
	if obj == nil do return .Add, nil, .Gone
	went: ^Link_Object
	if sent != nil do for &s in sent.objects do if s.id == o.id do went = &s
	if obj.voxel != nil || obj.cage != nil || object_dynamic(obj) {
		if went != nil && link_same_as_sent(app, went.file, mesh) do return .Keep, obj, .None
		if obj.cage != nil do return .Swap, obj, .Cage
		return .Swap, obj, .Voxel if obj.voxel != nil else .Dynamic
	}
	if o.level >= len(obj.levels.levels) do return .Add, nil, .Level_Gone
	level := obj.levels.levels[o.level]
	// A level deleted below the one sent renumbers it: the level of that number now is
	// another, which the mesh must not replace.
	if went != nil && went.level == o.level && len(level.mesh.positions) != went.vertices do return .Add, nil, .Level_Gone
	if len(level.mesh.positions) != len(mesh.positions) || !link_same_triangles(level.mesh.indices[:], mesh.indices[:], &app.pool) do return .Swap, obj, .Topology
	return .Project, obj, .None
}

// Whether `mesh` is what the app sent as `file`, vertex for vertex and triangle for
// triangle.
@(private = "file")
link_same_as_sent :: proc(app: ^App, file: string, mesh: geom.Mesh) -> bool {
	data, err := os.read_entire_file(link_path(app, file), context.allocator)
	if err != nil do return false
	went, failed, _ := geom.mesh_read_ply(data, &app.pool)
	delete(data)
	defer geom.mesh_destroy(&went)
	if failed != .None || len(went.positions) != len(mesh.positions) do return false
	return link_count_moved(went.positions[:], mesh.positions[:], &app.pool) == 0 && link_same_triangles(went.indices[:], mesh.indices[:], &app.pool)
}

// The newest of Blender's sends taken (LINK_TAKEN_FILE): its scene token and number, 0s
// for none.
link_taken :: proc(app: ^App) -> (token: u64, seq: int) {
	data, err := os.read_entire_file(link_path(app, LINK_TAKEN_FILE), context.temp_allocator)
	if err != nil do return
	f := strings.fields(string(data), context.temp_allocator)
	if len(f) != 3 || f[0] != "taken" do return
	t, t_ok := strconv.parse_u64_of_base(f[1], 16)
	n, n_ok := strconv.parse_int(f[2])
	if !t_ok || !n_ok do return 0, 0
	return t, n
}

// Notes Blender's send `seq` for scene `token` as taken. Returns what went wrong, "" for
// nothing.
@(private = "file")
link_take :: proc(app: ^App, token: u64, seq: int) -> string {
	return write_durably(link_path(app, LINK_TAKEN_FILE), transmute([]u8)fmt.tprintf("taken %016x %d\n", token, seq))
}

// Notes that object `id` matches the other side as of `at`.
@(private = "file")
link_sent_mark :: proc(app: ^App, id: int, at: time.Tick) {
	for &s in app.link.sent do if s.id == id {
		s.at = at
		return
	}
	append(&app.link.sent, Link_Sent{id, at})
}

// Whether the object changed here (an undo step of it still done) since this run sent it.
@(private = "file")
link_edited :: proc(app: ^App, id: int) -> bool {
	for s in app.link.sent {
		if s.id != id do continue
		for e in app.history.done do if e.id == id && time.tick_diff(s.at, e.at) > 0 do return true
	}
	return false
}

@(private = "file")
link_apply :: proc(app: ^App, o: Link_Object, mesh: ^geom.Mesh, action: Link_Action, obj: ^Object, chain: ^bool, r: ^Link_Result) -> bool {
	l := &app.link
	switch action {
	case .Keep:
		r.moved = 0
	case .Project:
		// HD detail rides on the top level's moves, as for Project detail.
		object_hd_leave(app, obj)
		if obj.levels.current != o.level && !object_set_level(app, obj, o.level) do return false
		s := object_sculptor(obj)
		r.moved = link_count_moved(s.mesh.positions[:], mesh.positions[:], &app.pool)
		if sculpt.sculptor_project(s, mesh.positions[:], nil, 1) {
			history_record(app, obj, .Deform, "From Blender", chain = chain^)
			chain^ = true
		}
		r.held = link_count_moved(s.mesh.positions[:], mesh.positions[:], &app.pool)
		l.moved += 1
	case .Swap:
		if !link_clean(app, mesh) {
			r.label = strings.clone(object_label(obj))
			r.moved = -1
			return true
		}
		was_dynamic := object_dynamic(obj)
		object_hd_leave(app, obj)
		before := history_snapshot(app, obj, "From Blender (new topology)")
		if !object_replace_mesh(app, obj, mesh^) {
			// The old mesh is gone; drop the empty object rather than draw nothing.
			mesh^ = {}
			history_snapshot_drop(before)
			select_object(app, obj)
			scene_delete_selected(app, undoable = false)
			return false
		}
		mesh^ = {}
		if was_dynamic {
			if _, ok := object_set_dyntopo(app, obj, true); !ok do return false
		}
		history_record_swap(app, obj.id, before, chain^)
		chain^ = true
		l.swapped += 1
	case .Add:
		if !link_clean(app, mesh) {
			r.label = strings.clone(o.name if o.name != "" else "Blender")
			r.moved = -1
			return true
		}
		name := o.name if o.name != "" else "Blender"
		// Taken by the new object, or freed when it could not be made.
		made := scene_add_mesh(app, mesh^, name, {scale = 1}, o.transform, time.tick_now())
		mesh^ = {}
		if !made do return false
		added := selected_object(app)
		history_record_swap(app, added.id, history_snapshot(app, nil, "From Blender (new object)"), chain^)
		chain^ = true
		r.label = strings.clone(object_label(added))
		r.id = added.id
		l.added += 1
		return true
	}
	r.label = strings.clone(object_label(obj))
	r.id = obj.id
	if obj.transform != o.transform {
		before := obj.transform
		obj.transform = o.transform
		history_record_transform(app, obj, before, "From Blender", chain^)
		chain^ = true
	}
	return true
}

// Cleans a mesh that becomes an object's, as Import does but never resized: welded,
// unused vertices dropped, and a closed one facing inward turned outward. False when
// nothing is left of it.
@(private = "file")
link_clean :: proc(app: ^App, mesh: ^geom.Mesh) -> bool {
	if _, err := geom.mesh_clean(mesh, &app.pool); err != .None do return false
	edges := geom.mesh_edges(mesh^, &app.pool)
	if geom.mesh_edges_closed(edges) && edges.volume < 0 do geom.mesh_flip(mesh, &app.pool)
	free_all(context.temp_allocator)
	return true
}

// One note for the whole get: "From Blender: Head (moved 1,204 vertices), Hat (new
// topology), Cube (new object)", and what to know about any of them.
@(private = "file")
link_note :: proc(app: ^App, results: []Link_Result, recorded: bool, ms: f64) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "From Blender: ")
	warn := false
	for r, i in results {
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, r.label)
		switch {
		case r.moved < 0:
			strings.write_string(&b, " (refused: no triangles left)")
			warn = true
		case r.action == .Keep, r.action == .Project && r.moved == 0:
			strings.write_string(&b, " (unchanged)")
		case r.action == .Project && r.held > 0:
			fmt.sbprintf(&b, " (moved %s; the mask or hiding held %s back)", link_vertices(r.moved - r.held), count_label(r.held))
		case r.action == .Project:
			fmt.sbprintf(&b, " (moved %s)", link_vertices(r.moved))
		case r.why == .Voxel, r.why == .Cage:
			strings.write_string(&b, " (new topology: now a mesh)")
		case r.action == .Swap:
			strings.write_string(&b, " (new topology)")
		case r.why == .Other_Scene:
			strings.write_string(&b, " (new object: sent from another scene)")
		case r.why == .Level_Gone:
			strings.write_string(&b, " (new object: the level it was sent from is gone)")
		case:
			strings.write_string(&b, " (new object)")
		}
	}
	fmt.sbprintf(&b, ", in %.0f ms", ms)
	edited := 0
	for r in results do edited += int(r.edited)
	if edited > 0 {
		strings.write_string(&b, ". Changes made here since the send were replaced; Undo brings them back")
		warn = true
	}
	report(app, nil, ({.Warning} if warn else {}) + ({.Undo} if recorded else {}), "%s", strings.to_string(b))
}

@(private = "file")
link_vertices :: proc(n: int) -> string {return fmt.tprintf("%s %s", count_label(n), "vertex" if n == 1 else "vertices")}

// Whether two triangle lists are the same, compared a range at a time in parallel.
link_same_triangles :: proc(a, b: []u32, pool: ^jobs.Pool) -> bool {
	if len(a) != len(b) do return false
	Job :: struct {
		a, b:    []u32,
		differs: bool,
	}
	job := Job{a, b, false}
	jobs.parallel_ranges(pool, len(a), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		if !slice.equal(job.a[lo:hi], job.b[lo:hi]) do sync.atomic_store(&job.differs, true)
	}, 1 << 18)
	return !job.differs
}

// How many of the vertices are not where `next` puts them (bit for bit).
link_count_moved :: proc(now, next: []Vec3, pool: ^jobs.Pool) -> int {
	Job :: struct {
		now, next: []Vec3,
		count:     int,
	}
	job := Job{now, next, 0}
	jobs.parallel_ranges(pool, min(len(now), len(next)), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		n := 0
		for v in lo ..< hi do n += int(job.now[v] != job.next[v])
		sync.atomic_add(&job.count, n)
	}, 1 << 16)
	return job.count
}

@(private = "file")
link_finite :: proc(positions: []Vec3, pool: ^jobs.Pool) -> bool {
	Job :: struct {
		positions: []Vec3,
		bad:       bool,
	}
	job := Job{positions, false}
	jobs.parallel_ranges(pool, len(positions), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for p in job.positions[lo:hi] do if !finite(p) {sync.atomic_store(&job.bad, true); return}
	}, 1 << 16)
	return !job.bad
}
