package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import "../ui"

// The scene tree's view of the objects: which are shown, which a press can pick, and
// the changes to that (the eye, ghost and solo, as ZBrush's SubTool list and Nomad's
// scene have them). These are view state, saved with the scene but not undo steps, as
// the eye is in Blender and ZBrush. Whatever draws or picks objects asks object_shown
// and object_pickable rather than reading the flags, so the draw list, the raycasts and
// the panels agree. Folders gather objects one level deep; changes to them, and to
// names, are undo steps (History_Kind.Arrange) holding the tree before and after.

// A folder of objects. Its eye and ghost apply to every object in it, over the objects'
// own; `open` shows its objects in the Scene palette.
Folder :: struct {
	id:    int, // never reused within a scene
	name:  string, // owned
	open:  bool,
	off:   bool,
	ghost: bool,
	vis_off: u8, // its eye in each stored visibility, as Object.vis_off
}

// The longest name a rename takes, in bytes.
NAME_BYTES :: 64

View_Change :: enum u8 {
	Hide, // turns the object's eye off
	Show, // turns it on again
	Ghost, // draws the object dimmed and puts it out of reach
	Unghost, // makes a ghost solid again
	Show_All, // turns every eye on, and Solo off
	Solo, // turns Solo on or off
	Select, // selects the object, bringing it and its folder back into view and reach
	Folder_Hide, // turns a folder's eye off: every object in it leaves view
	Folder_Show,
	Folder_Ghost, // makes every object in a folder a ghost
	Folder_Unghost,
	Folder_Fold, // folds an open folder in the Scene palette, or opens a folded one
	Paint_Hide, // leaves the object's polypaint out of the drawing
	Paint_Show,
	Folder_Paint_Hide, // leaves the polypaint of every object in a folder out
	Folder_Paint_Show,
	Visibility_Slot, // keeps the eyes in the stored visibility chosen, and brings back those of V`id`
	Lock, // puts the object out of reach of presses in the view, drawn as it is
	Unlock,
	Lock_Others, // locks every other object and unlocks this one (ZBrush's Freeze others)
	Space_Hide, // leaves the object out of a space: out of view and reach while it is current
	Space_Show,
}

// How many visibilities Store visibility keeps.
VIS_SLOTS :: 8

// Changes to the tree that are undo steps.
Arrange_Change :: enum u8 {
	New_Folder, // puts the object in a new folder
	Into_Folder, // moves the object into `folder`
	Out_Of_Folder, // takes the object out of its folder
	Ungroup, // empties folder `id` into the list and removes it
	Delete_Folder, // deletes folder `id` with every object in it
	Rename_Object,
	Rename_Folder,
	Reorder, // moves the object before `before` (0: to the end), in folder `folder` (0: none)
	Reorder_Folder, // moves folder `id`'s objects, together, before `before` (0: to the end)
}

// A ghost is drawn in the idle colour darkened to this share: opaque, so it needs no
// blending, and plainly not part of the work.
GHOST_SHADE :: 0.45

// Whether `obj` and its folder have their eyes off (or `obj` is left out of the current
// space), and whether either is a ghost.
object_flags :: proc(app: ^App, obj: ^Object) -> (off, ghost: bool) {
	off, ghost = obj.off || app.kit.spaces.current in obj.spaces_off, obj.ghost
	if f := folder_by_id(app, obj.folder); f != nil {
		off ||= f.off
		ghost ||= f.ghost
	}
	return
}

// Whether `obj` is drawn: its eye and its folder's are on and, with Solo on, it is the
// selected object.
object_shown :: proc(app: ^App, obj: ^Object) -> bool {
	if off, _ := object_flags(app, obj); off do return false
	if app.scene.solo {
		if sel := selected_object(app); sel != nil && sel != obj do return false
	}
	return true
}

// Whether a press in the viewport can pick `obj` (select, sculpt or pivot on it): shown,
// not a ghost, which is there only to look at, and not locked.
object_pickable :: proc(app: ^App, obj: ^Object) -> bool {
	_, ghost := object_flags(app, obj)
	return !ghost && !obj.locked && object_shown(app, obj)
}

// Whether `obj` could be picked were Solo off.
@(private = "file")
object_in_reach :: proc(app: ^App, obj: ^Object) -> bool {
	off, ghost := object_flags(app, obj)
	return !off && !ghost && !obj.locked
}

// Keeps the selection on an object a press could pick, so nothing edits what cannot be
// seen: when the selected one was hidden, made a ghost or locked, the next one that is none
// takes over (as ZBrush moves to the next SubTool), Solo going with it, or nothing is
// selected. Run after every frame's scene command, which covers undo, files and
// adjusting the last operation too.
scene_selection_fix :: proc(app: ^App) {
	selection_primary_fix(app)
	selection_prune(app)
}

@(private = "file")
selection_primary_fix :: proc(app: ^App) {
	s := &app.scene
	obj := selected_object(app)
	if obj == nil {
		s.solo = false
		return
	}
	if object_in_reach(app, obj) do return
	n := len(s.objects)
	for k in 1 ..< n {
		i := (s.selected + k) % n
		if object_in_reach(app, s.objects[i]) {
			s.selected = i
			return
		}
	}
	s.selected = -1
	s.solo = false
}

// Clears the selection, as a tap on empty space with the Move tool does; with Solo on the
// selected object is the one shown, so it stays rather than end Solo unasked.
scene_deselect :: proc(app: ^App) {
	if app.scene.solo do return
	app.scene.selected = -1
	clear(&app.scene.also)
}

// Several objects selected, as Blender's and Maya's outliners have them: `selected` stays
// the primary, which carries the gizmo and which every panel and tool works on, and
// `also` holds the others. The gizmo, the Transform values, Reset transform, Duplicate and
// Delete act on all of them; nothing else does. Anything that picks a new primary another
// way (adding an object, a plain tap, an undo) leaves it alone selected: `also` counts
// only while the primary is still the object `also_for` names.

// How far the rest of a selection is drawn from the idle colour toward the selected one:
// plainly chosen, and still apart from the one with the gizmo.
SELECTION_TINT :: 0.6

// Whether `obj` is selected, as the primary or one of the others.
object_in_selection :: proc(app: ^App, obj: ^Object) -> bool {
	sel := selected_object(app)
	if obj == nil || sel == nil do return false
	return obj == sel || (sel.id == app.scene.also_for && slice.contains(app.scene.also[:], obj.id))
}

// The selected objects' ids, the primary's first, in temp memory.
selection_ids :: proc(app: ^App) -> []int {
	sel := selected_object(app)
	if sel == nil do return nil
	ids := make([dynamic]int, 0, 1 + len(app.scene.also), context.temp_allocator)
	append(&ids, sel.id)
	if sel.id == app.scene.also_for do append(&ids, ..app.scene.also[:])
	return ids[:]
}

// Selects the objects `ids` names, the first as the primary.
selection_set :: proc(app: ^App, ids: []int) {
	s := &app.scene
	clear(&s.also)
	if len(ids) == 0 {
		s.selected = -1
		return
	}
	select_object(app, object_by_id(app, ids[0]))
	append(&s.also, ..ids[1:])
	s.also_for = ids[0]
}

// Selects the list's `i`th object alone.
select_only :: proc(app: ^App, i: int) {
	app.scene.selected = i
	clear(&app.scene.also)
}

// Adds the list's `i`th object to the selection as its primary (the one the gizmo is on,
// as the last one clicked is active in Blender), or takes it out when it was in, the
// primary before it taking over.
selection_toggle :: proc(app: ^App, i: int) {
	s := &app.scene
	ids := selection_ids(app)
	obj := s.objects[i]
	if len(ids) == 0 {
		select_only(app, i)
		return
	}
	if at, found := slice.linear_search(ids, obj.id); found {
		if len(ids) == 1 do return
		rest := make([dynamic]int, 0, len(ids), context.temp_allocator)
		append(&rest, ..ids[:at])
		append(&rest, ..ids[at + 1:])
		// The others are listed newest first, so the primary before it takes the gizmo back.
		selection_set(app, rest[:])
		return
	}
	more := make([dynamic]int, 0, len(ids) + 1, context.temp_allocator)
	append(&more, obj.id)
	append(&more, ..ids)
	selection_set(app, more[:])
}

// Makes the list's `i`th object the primary: one of the selection keeps the others with
// it (a press on it drags them all), any other is selected alone.
selection_make_primary :: proc(app: ^App, i: int) {
	obj := app.scene.objects[i]
	ids := selection_ids(app)
	at, found := slice.linear_search(ids, obj.id)
	if !found {
		select_only(app, i)
		return
	}
	ids[0], ids[at] = ids[at], ids[0]
	selection_set(app, ids)
}

// Drops from the others what is no longer selectable: gone, out of view or reach, the
// primary itself, or everything once the primary changed or Solo shows only it.
@(private = "file")
selection_prune :: proc(app: ^App) {
	s := &app.scene
	sel := selected_object(app)
	if sel == nil || sel.id != s.also_for || s.solo {
		clear(&s.also)
		s.also_for = sel.id if sel != nil else 0
		return
	}
	kept := 0
	for id in s.also {
		obj := object_by_id(app, id)
		if obj == nil || obj == sel || !object_in_reach(app, obj) || slice.contains(s.also[:kept], id) do continue
		s.also[kept] = id
		kept += 1
	}
	resize(&s.also, kept)
}

// Applies a View command to object `id` (or the whole scene).
scene_view :: proc(app: ^App, change: View_Change, id: int, space := Space.Sculpt) {
	// A stroke going on an object that leaves view or reach ends here, rather than keep
	// dabbing where nobody sees it.
	stroke_finish(app)
	s := &app.scene
	obj := object_by_id(app, id)
	folder := folder_by_id(app, id)
	switch change {
	case .Hide, .Show:
		if obj == nil do return
		obj.off = change == .Hide
		if change == .Hide {
			report(app, nil, {}, "Hid %s; %s shows every object again", object_label(obj), command_keys(app, .Show_All_Objects))
		}
	case .Ghost, .Unghost:
		if obj == nil do return
		obj.ghost = change == .Ghost
	case .Show_All:
		for o in s.objects do o.off, o.spaces_off = false, o.spaces_off - {app.kit.spaces.current}
		for &f in s.folders do f.off = false
		s.solo = false
	case .Solo:
		s.solo = !s.solo && selected_object(app) != nil
		if s.solo do report(app, nil, {.Quiet}, "Solo: only %s is shown", object_label(selected_object(app)))
	case .Select:
		if obj == nil do return
		obj.off, obj.ghost, obj.locked = false, false, false
		obj.spaces_off -= {app.kit.spaces.current}
		if f := folder_by_id(app, obj.folder); f != nil do f.off, f.ghost = false, false
		for o, i in s.objects do if o == obj do s.selected = i
	case .Folder_Hide, .Folder_Show:
		if folder == nil do return
		folder.off = change == .Folder_Hide
	case .Folder_Ghost, .Folder_Unghost:
		if folder == nil do return
		folder.ghost = change == .Folder_Ghost
	case .Folder_Fold:
		if folder == nil do return
		folder.open = !folder.open
	case .Paint_Hide, .Paint_Show:
		if obj == nil do return
		obj.paint_off = change == .Paint_Hide
	case .Folder_Paint_Hide, .Folder_Paint_Show:
		if folder == nil do return
		for o in s.objects do if o.folder == folder.id do o.paint_off = change == .Folder_Paint_Hide
	case .Visibility_Slot:
		visibility_slot(app, id)
	case .Lock, .Unlock:
		if obj == nil do return
		obj.locked = change == .Lock
		if obj.locked do report(app, nil, {.Quiet}, "Locked %s: presses in the view pass over it", object_label(obj))
	case .Lock_Others:
		if obj == nil do return
		for o in s.objects do o.locked = o != obj
		report(app, nil, {.Quiet}, "Locked every object but %s", object_label(obj))
	case .Space_Hide, .Space_Show:
		if obj == nil do return
		if change == .Space_Hide do obj.spaces_off += {space}
		else do obj.spaces_off -= {space}
	}
	app.view_edits += 1
	scene_selection_fix(app)
}

// Chooses stored visibility `slot` (1 to VIS_SLOTS), as ZBrush's V1 to V8: the eyes as
// they are go into the one chosen before, and the new one's come back; one that holds
// none yet takes the eyes as they are, so choosing it changes nothing until eyes are
// turned. Not an undo step, as turning an eye is not. The selected object stays in view,
// as ZBrush keeps it whatever its slot says.
visibility_slot :: proc(app: ^App, slot: int) {
	s := &app.scene
	if slot < 1 || slot > VIS_SLOTS || slot == s.vis_slot do return
	if s.vis_slot != 0 {
		bit := u8(1) << uint(s.vis_slot - 1)
		for o in s.objects do o.vis_off = o.vis_off &~ bit | (bit if o.off else 0)
		for &f in s.folders do f.vis_off = f.vis_off &~ bit | (bit if f.off else 0)
	}
	bit := u8(1) << uint(slot - 1)
	if s.vis_used & bit != 0 {
		for o in s.objects do o.off = o.vis_off & bit != 0
		for &f in s.folders do f.off = f.vis_off & bit != 0
	} else {
		s.vis_used |= bit
		for o in s.objects do o.vis_off = o.vis_off &~ bit | (bit if o.off else 0)
		for &f in s.folders do f.vis_off = f.vis_off &~ bit | (bit if f.off else 0)
	}
	s.vis_slot = slot
	if sel := selected_object(app); sel != nil {
		sel.off = false
		if f := folder_by_id(app, sel.folder); f != nil do f.off = false
	}
}

// Asks for `change` on the selected object at the start of the next frame.
view_command :: proc(app: ^App, change: View_Change) {
	obj := selected_object(app)
	app.ui.scene_command = {kind = .View, view = change, id = obj.id if obj != nil else 0}
}

// How many objects are out of view and how many are ghosts, by their own flags or their
// folder's, for the panels and stats.
scene_view_counts :: proc(app: ^App) -> (off, ghosts: int) {
	for obj in app.scene.objects {
		o, g := object_flags(app, obj)
		if o do off += 1
		if g do ghosts += 1
	}
	return
}

// The eye and ghost toggles of a row in the Scene palette (an object's, or a folder's), ghost
// first so the eye sits at the row's end, where a finger running down the column finds it.
row_toggles :: proc(label: string, off, ghost: bool) -> [2]ui.Row_Toggle {
	return {
		{name = "Show solid" if ghost else "Make a ghost", glyph = ui.ICON_GHOST, lit = ghost, faint = !ghost},
		{name = fmt.tprintf("Show %s", label) if off else fmt.tprintf("Hide %s", label), glyph = ui.ICON_EYE_OFF if off else ui.ICON_EYE, faint = off},
	}
}

folder_by_id :: proc(app: ^App, id: int) -> ^Folder {
	if id == 0 do return nil
	for &f in app.scene.folders do if f.id == id do return &f
	return nil
}

folder_label :: proc(f: ^Folder) -> string {
	if f.name != "" do return f.name
	return fmt.tprintf("Folder %d", f.id)
}

folders_clear :: proc(folders: ^[dynamic]Folder) {
	for f in folders do delete(f.name)
	clear(folders)
}

// Where folder `id`'s objects are in the list: [first, end), empty when it has none.
folder_span :: proc(app: ^App, id: int) -> (first, end: int) {
	first, end = -1, -1
	for obj, i in app.scene.objects {
		if obj.folder != id do continue
		if first < 0 do first = i
		end = i + 1
	}
	if first < 0 do return 0, 0
	return
}

// Keeps the tree whole: an object naming a folder that is not there (a damaged file, an
// undo that brought back an object whose folder went since) is in none, and each
// folder's objects are moved together to where its first one is, keeping their order.
// The selected object stays selected. Cheap when nothing is out of place.
scene_folders_normalize :: proc(app: ^App) {
	s := &app.scene
	for obj in s.objects do if obj.folder != 0 && folder_by_id(app, obj.folder) == nil do obj.folder = 0
	if folders_contiguous(s.objects[:]) do return
	sel := selected_object(app)
	out := make([dynamic]^Object, 0, len(s.objects), context.temp_allocator)
	placed := make(map[int]bool, context.temp_allocator)
	for obj in s.objects {
		if obj.folder == 0 {
			append(&out, obj)
			continue
		}
		if placed[obj.folder] do continue
		placed[obj.folder] = true
		for o in s.objects do if o.folder == obj.folder do append(&out, o)
	}
	copy(s.objects[:], out[:])
	select_object(app, sel)
}

// Whether every folder's objects are next to each other.
folders_contiguous :: proc(objects: []^Object) -> bool {
	closed := make(map[int]bool, context.temp_allocator)
	last := 0
	for obj in objects {
		if obj.folder == last do continue
		if last != 0 do closed[last] = true
		if obj.folder != 0 && closed[obj.folder] do return false
		last = obj.folder
	}
	return true
}

// Takes `moved` (in list order) out of the list and puts them back together before the
// object with id `before`, or at the end when it is 0 or one of them.
objects_move :: proc(app: ^App, moved: []^Object, before: int) {
	s := &app.scene
	rest := make([dynamic]^Object, 0, len(s.objects), context.temp_allocator)
	for o in s.objects do if !slice.contains(moved, o) do append(&rest, o)
	at := len(rest)
	for o, i in rest do if o.id == before do at = i
	clear(&s.objects)
	append(&s.objects, ..rest[:at])
	append(&s.objects, ..moved)
	append(&s.objects, ..rest[at:])
}

// Selects `obj` wherever it now is in the list, or nothing when it is nil or gone.
select_object :: proc(app: ^App, obj: ^Object) {
	app.scene.selected = -1
	if obj == nil do return
	for o, i in app.scene.objects do if o == obj do app.scene.selected = i
}

// A new, empty folder at the end of the list.
folder_new :: proc(app: ^App) -> ^Folder {
	s := &app.scene
	s.next_folder_id = max(s.next_folder_id, 0) + 1
	for f in s.folders do s.next_folder_id = max(s.next_folder_id, f.id + 1)
	append(&s.folders, Folder{id = s.next_folder_id, open = true})
	return &s.folders[len(s.folders) - 1]
}

// The tree as an Arrange step keeps it: the objects' order, folders and names, and the
// folders. How each is shown is view state and not part of it.
Scene_Layout :: struct {
	ids:     []int,
	folder:  []int, // each object's folder
	names:   []string, // each object's name (owned)
	folders: []Folder, // names owned
}

layout_take :: proc(app: ^App) -> ^Scene_Layout {
	s := &app.scene
	l := new(Scene_Layout)
	n := len(s.objects)
	l.ids, l.folder, l.names = make([]int, n), make([]int, n), make([]string, n)
	for obj, i in s.objects do l.ids[i], l.folder[i], l.names[i] = obj.id, obj.folder, strings.clone(obj.name)
	l.folders = make([]Folder, len(s.folders))
	for f, i in s.folders {
		l.folders[i] = f
		l.folders[i].name = strings.clone(f.name)
	}
	return l
}

layout_free :: proc(l: ^Scene_Layout) {
	if l == nil do return
	for n in l.names do delete(n)
	for f in l.folders do delete(f.name)
	delete(l.ids)
	delete(l.folder)
	delete(l.names)
	delete(l.folders)
	free(l)
}

// Whether two layouts hold the same tree (how folders are shown aside).
@(private = "file")
layout_same :: proc(a, b: ^Scene_Layout) -> bool {
	if !slice.equal(a.ids, b.ids) || !slice.equal(a.folder, b.folder) || !slice.equal(a.names, b.names) || len(a.folders) != len(b.folders) do return false
	for f, i in a.folders do if f.id != b.folders[i].id || f.name != b.folders[i].name do return false
	return true
}

// Puts the tree back as `l` holds it. Objects it lists that are gone are skipped, and
// objects it does not list keep their place and folder (a swap undone in the same step
// may have brought one back or taken one away); a folder still here keeps how it is
// shown. The selected object stays selected.
layout_apply :: proc(app: ^App, l: ^Scene_Layout) {
	s := &app.scene
	sel := selected_object(app)
	folders := make([dynamic]Folder, 0, len(l.folders))
	for f in l.folders {
		g := f
		g.name = strings.clone(f.name)
		if old := folder_by_id(app, f.id); old != nil do g.open, g.off, g.ghost, g.vis_off = old.open, old.off, old.ghost, old.vis_off
		append(&folders, g)
		s.next_folder_id = max(s.next_folder_id, f.id)
	}
	folders_clear(&s.folders)
	delete(s.folders)
	s.folders = folders
	listed := make([dynamic]^Object, 0, len(l.ids), context.temp_allocator)
	for id, i in l.ids {
		obj := object_by_id(app, id)
		if obj == nil do continue
		obj.folder = l.folder[i]
		if obj.name != l.names[i] {
			delete(obj.name)
			obj.name = strings.clone(l.names[i])
		}
		append(&listed, obj)
	}
	// The listed objects take, in the layout's order, the places listed objects hold now.
	k := 0
	for obj, i in s.objects {
		if !slice.contains(l.ids, obj.id) do continue
		s.objects[i] = listed[k]
		k += 1
	}
	select_object(app, sel)
	scene_folders_normalize(app)
	app.kit.object_menu = false
}

// Lists the tree's change since `before` (from layout_take) as the newest undo step, or
// with `chain` as part of the newest; false, freeing `before`, when nothing changed.
history_record_arrange :: proc(app: ^App, before: ^Scene_Layout, what: string, chain := false) -> bool {
	after := layout_take(app)
	if layout_same(before, after) {
		layout_free(before)
		layout_free(after)
		return false
	}
	step := new(Arrange_Step)
	step^ = {before, after}
	history_push(app, History_Entry{kind = .Arrange, what = what, at = time.tick_now(), arrange = step, chain = chain && len(app.history.done) > 0})
	return true
}

// The name in `buf`, up to its first zero, without spaces around it and with "##" (which
// labels use to hide an id) made one "#", in the temp allocator.
rename_text :: proc(buf: []u8) -> string {
	n := 0
	for n < len(buf) && buf[n] != 0 do n += 1
	name := strings.trim_space(string(buf[:n]))
	for strings.contains(name, "##") do name, _ = strings.replace_all(name, "##", "#", context.temp_allocator)
	return name
}

// Applies an Arrange command as one undo step. Deleting a folder with objects in it
// records the tree first and each object's removal chained to it, so one undo brings
// the objects back and then the folder around them.
scene_arrange :: proc(app: ^App, cmd: Scene_Command) {
	cmd := cmd
	stroke_finish(app)
	s := &app.scene
	obj := object_by_id(app, cmd.id)
	folder := folder_by_id(app, cmd.id)
	before := layout_take(app)
	what: string
	switch cmd.arrange {
	case .New_Folder:
		if obj == nil do break
		f := folder_new(app)
		// Every selected object goes in with it, as Blender and Photoshop group a selection.
		if object_in_selection(app, obj) {
			for id in selection_ids(app) do if o := object_by_id(app, id); o != nil do o.folder = f.id
		}
		obj.folder = f.id
		what = "New folder"
	case .Into_Folder:
		if obj == nil || folder_by_id(app, cmd.folder) == nil do break
		obj.folder = cmd.folder
		what = "Move to folder"
	case .Out_Of_Folder:
		if obj == nil do break
		obj.folder = 0
		what = "Take out of folder"
	case .Ungroup, .Delete_Folder:
		if folder == nil do break
		id := folder.id
		// Not in temp memory, which taking each object's snapshot may free.
		members := make([dynamic]int, 0, 8)
		defer delete(members)
		for o in s.objects do if o.folder == id do append(&members, o.id)
		for o in s.objects do if o.folder == id do o.folder = 0
		for f, i in s.folders do if f.id == id {
			delete(f.name)
			ordered_remove(&s.folders, i)
			break
		}
		if cmd.arrange == .Ungroup {
			what = "Ungroup folder"
			break
		}
		// Its objects go after the folder, each a swap chained to the tree's step.
		if !history_record_arrange(app, before, "Delete folder") do return
		for m in members {
			select_object(app, object_by_id(app, m))
			scene_delete_selected(app, chain = true)
		}
		if len(members) == 0 do report(app, nil, {.Undo, .Quiet}, "Deleted an empty folder")
		else do report(app, nil, {.Undo}, "Deleted a folder and its %d object%s", len(members), "" if len(members) == 1 else "s")
		return
	case .Rename_Object:
		if obj == nil do break
		delete(obj.name)
		obj.name = strings.clone(rename_text(cmd.name[:]))
		what = "Rename object"
	case .Rename_Folder:
		if folder == nil do break
		delete(folder.name)
		folder.name = strings.clone(rename_text(cmd.name[:]))
		what = "Rename folder"
	case .Reorder:
		if obj == nil || (cmd.folder != 0 && folder_by_id(app, cmd.folder) == nil) do break
		sel := selected_object(app)
		// Before itself it keeps its place and may change folder only: a folder's first
		// object dropped above the folder's row leaves it there.
		if cmd.before != obj.id do objects_move(app, {obj}, cmd.before)
		obj.folder = cmd.folder
		select_object(app, sel)
		what = "Move object"
	case .Reorder_Folder:
		if folder == nil do break
		if b := object_by_id(app, cmd.before); b != nil && b.folder == folder.id do break
		sel := selected_object(app)
		moved := make([dynamic]^Object, 0, 8, context.temp_allocator)
		for o in s.objects do if o.folder == folder.id do append(&moved, o)
		objects_move(app, moved[:], cmd.before)
		select_object(app, sel)
		what = "Move folder"
	}
	scene_folders_normalize(app)
	if what != "" && app.history_no_tree {
		// History > Settings keeps the tree's own changes (names, folders, order) out of the
		// History; the scene still changed, for the autosave.
		layout_free(before)
		app.history.edits += 1
		return
	}
	if what == "" || !history_record_arrange(app, before, what) {
		if what == "" do layout_free(before)
		return
	}
	report(app, nil, {.Undo, .Quiet}, "%s", what)
}
