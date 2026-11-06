package main

import "core:time"

import "../gizmo"
import "../sculpt"

// Find steps at a spot (the History card's head): the next press on the model picks a spot,
// and the History list then shows only the steps that changed it, newest first, until the
// chip under the head is tapped. Strokes of the level shown are matched exactly, by the
// three corners of the triangle the press hit, through the undo data alone
// (sculpt.sculptor_steps_changing); a step of another level of the object, or of a clay
// object, by its box (History_Entry.area) holding the spot, and its row says "near". Asking
// copies no mesh and adds nothing to a stroke: a pass over the steps' saved nodes, once,
// when the press lands and again when the History changes while the filter is on.

// What the find holds, in the timeline (Timeline.find).
History_Find :: struct {
	armed:   bool, // the next press on the model picks the spot
	held:    bool, // the press that picked it is still down, so no tool takes it
	on:      bool, // the list shows only the steps found
	object:  int, // the object's id
	level:   int, // the level (or HD_LEVEL) shown when the spot was picked
	point:   Vec3, // the spot in the object's own space
	corners: [3]u32, // the corners of the triangle hit, in that level's numbering; none on clay
	exact:   bool, // the corners are known (a mesh object, not clay)
	// The entries found, by when they were made (History_Entry.at, which stays with an
	// entry as it is undone and redone), each with whether it was only near.
	found:   [dynamic]History_Found,
	serial:  u64, // the History's serial the steps were found at
	retry:   bool, // the GPU's positions were not back: asked again next frame
	finds:   int, // spots picked this run, for the exit stats
}

History_Found :: struct {
	at:   time.Tick,
	near: bool,
}

history_find_destroy :: proc(f: ^History_Find) {
	delete(f.found)
	f^ = {}
}

// The Find steps at a spot command: arms the pick, or with it armed, waits no more.
history_find_command :: proc(app: ^App) {
	f := &app.timeline.find
	f.armed = !f.armed
}

// Takes the filter away.
history_find_clear :: proc(app: ^App) {
	f := &app.timeline.find
	f.on, f.armed = false, false
	clear(&f.found)
}

// Follows an armed find with this frame's input: the press on the viewport picks the spot
// and finds its steps; the press stays the find's until it lets go, so no tool takes it.
// Returns true while it does.
history_find_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	f := &app.timeline.find
	if f.held {
		if !input.primary do f.held = false
		return true
	}
	if !f.armed || !input.press do return false
	f.armed, f.held = false, input.primary
	origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
	index, hit, frame, _, ok := scene_raycast_framed(app, origin, dir)
	if !ok {
		report(app, Section.History, {.Warning}, "Find steps at a spot: the press missed every object")
		return true
	}
	obj := app.scene.objects[index]
	f.object, f.point, f.exact = obj.id, to_local(frame, hit), false
	f.level = HD_LEVEL if object_in_hd(obj) else obj.levels.current
	if obj.voxel == nil && !object_dynamic(obj) {
		s := object_sculptor(obj)
		if _, tri, tri_ok := sculpt.sculptor_raycast_triangle(s, to_local(frame, origin), to_local_dir(frame, dir)); tri_ok {
			idx := s.mesh.indices[3 * tri:][:3]
			f.corners = {idx[0], idx[1], idx[2]}
			f.exact = true
		}
	}
	f.on = true
	f.finds += 1
	history_find_run(app)
	app.timeline.list_scroll = 0
	n := len(f.found)
	report(app, Section.History, {.Quiet}, "%d step%s changed this spot", n, "" if n == 1 else "s")
	return true
}

// Finds the steps again when the History changed since, while the filter is on and no
// stroke is under way (a stroke's step is found once it ends).
history_find_settle :: proc(app: ^App) {
	f := &app.timeline.find
	if !f.on || (!f.retry && f.serial == app.history.serial) || app.stroke.active do return
	history_find_run(app)
}

// Finds the entries that changed the spot: exactly for the steps of the level it was
// picked on, by their sculptor's step ids, and by box for the rest of the object's steps
// and for those the sculptor cannot read back (sculpt.Step_Change.Unknown).
@(private = "file")
history_find_run :: proc(app: ^App) {
	f := &app.timeline.find
	clear(&f.found)
	obj := object_by_id(app, f.object)
	if obj == nil {
		history_find_clear(app)
		return
	}
	shown := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	steps: []sculpt.Step_Seen
	exact := false
	if f.exact && shown == f.level && obj.voxel == nil {
		steps, exact = sculpt.sculptor_steps_changing(object_sculptor(obj), f.corners[:], context.temp_allocator)
		// The GPU's last positions are not back yet: asked again next frame.
		if !exact && !object_dynamic(obj) && !app.stroke.active {
			f.retry = true
			return
		}
	}
	f.serial, f.retry = app.history.serial, false
	for list in ([2][]History_Entry{app.history.done[:], app.history.undone[:]}) {
		#reverse for e in list {
			if e.id != f.object do continue
			if exact && e.level == f.level && e.step_id != 0 {
				change := sculpt.Step_Change.Unchanged
				// A step the memory limit dropped is in no list: it changed nothing now.
				for st in steps do if st.id == e.step_id do change = st.change
				switch change {
				case .Changed:
					append(&f.found, History_Found{e.at, false})
				case .Unknown:
					history_find_near(f, e)
				case .Unchanged:
				}
				continue
			}
			history_find_near(f, e)
		}
	}
}

// Keeps `e` as near when its box holds the spot: a step whose values the sculptor cannot
// compare, or of another level, or of clay. Steps of the whole object say nothing of a spot.
@(private = "file")
history_find_near :: proc(f: ^History_Find, e: History_Entry) {
	if e.kind == .Transform || e.kind == .Arrange || e.kind == .Lights || e.kind == .References || e.kind == .Textures || e.kind == .Stack do return
	a := e.area
	// An empty or zero box is a step of the whole object or of none.
	if a.lo.x > a.hi.x || a.lo == a.hi do return
	p := f.point
	if p.x >= a.lo.x && p.y >= a.lo.y && p.z >= a.lo.z && p.x <= a.hi.x && p.y <= a.hi.y && p.z <= a.hi.z do append(&f.found, History_Found{e.at, true})
}

// Whether the list shows `row` while the filter is on, and whether only as near.
history_find_row :: proc(app: ^App, row: History_Row) -> (shown, near: bool) {
	f := &app.timeline.find
	near = true
	for i in row.oldest ..= row.last {
		at := history_entry_at(app, i).at
		for x in f.found do if x.at == at {
			shown = true
			if !x.near do near = false
		}
	}
	if !shown do near = false
	return
}

// The spot's marker while the filter is on and its object still there: a ring with a dot,
// in the History's colour, where the press picked.
draw_history_find :: proc(app: ^App, o: Overlay, size: [2]f32) {
	f := &app.timeline.find
	if !f.on do return
	obj := object_by_id(app, f.object)
	if obj == nil do return
	s, ok := gizmo.project(view_proj_of(app, size), to_world(obj.transform, f.point), size)
	if !ok do return
	px := gizmo_scale(app)
	colour := overlay_color(KIND_COLORS[.Stroke])
	overlay_circle(o, s, 10 * px, overlay_color({0.08, 0.08, 0.09, 0.6}), 5 * px)
	overlay_circle(o, s, 10 * px, colour, 2 * px)
	overlay_disc(o, s, 2.5 * px, colour)
}
