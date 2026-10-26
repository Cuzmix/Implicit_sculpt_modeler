package main

import "core:fmt"

import "../ui"

// The scene tree's view of the objects: which are shown, which a press can pick, and
// the changes to that (the eye, ghost and solo, as ZBrush's SubTool list and Nomad's
// scene have them). These are view state, saved with the scene but not undo steps, as
// the eye is in Blender and ZBrush. Whatever draws or picks objects asks object_shown
// and object_pickable rather than reading the flags, so the draw list, the raycasts and
// the panels agree.

View_Change :: enum u8 {
	Hide, // turns the object's eye off
	Show, // turns it on again
	Ghost, // draws the object dimmed and puts it out of reach
	Unghost, // makes a ghost solid again
	Show_All, // turns every eye on, and Solo off
	Solo, // turns Solo on or off
	Select, // selects the object, bringing it back into view and reach if it was not
}

// A ghost is drawn in the idle colour darkened to this share: opaque, so it needs no
// blending, and plainly not part of the work.
GHOST_SHADE :: 0.45

// Whether `obj` is drawn: its eye is on and, with Solo on, it is the selected object.
object_shown :: proc(app: ^App, obj: ^Object) -> bool {
	if obj.off do return false
	if app.scene.solo {
		if sel := selected_object(app); sel != nil && sel != obj do return false
	}
	return true
}

// Whether a press in the viewport can pick `obj` (select, sculpt or pivot on it): shown
// and not a ghost, which is there only to look at.
object_pickable :: proc(app: ^App, obj: ^Object) -> bool {
	return !obj.ghost && object_shown(app, obj)
}

// Keeps the selection on an object a press could pick, so nothing edits what cannot be
// seen: when the selected one was hidden or made a ghost, the next one that is neither
// takes over (as ZBrush moves to the next SubTool), Solo going with it, or nothing is
// selected. Run after every frame's scene command, which covers undo, files and
// adjusting the last operation too.
scene_selection_fix :: proc(app: ^App) {
	s := &app.scene
	obj := selected_object(app)
	if obj == nil {
		s.solo = false
		return
	}
	if !obj.off && !obj.ghost do return
	n := len(s.objects)
	for k in 1 ..< n {
		i := (s.selected + k) % n
		if o := s.objects[i]; !o.off && !o.ghost {
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
	if !app.scene.solo do app.scene.selected = -1
}

// Applies a View command to object `id` (or the whole scene).
scene_view :: proc(app: ^App, change: View_Change, id: int) {
	// A stroke going on an object that leaves view or reach ends here, rather than keep
	// dabbing where nobody sees it.
	stroke_finish(app)
	s := &app.scene
	obj := object_by_id(app, id)
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
		for o in s.objects do o.off = false
		s.solo = false
	case .Solo:
		s.solo = !s.solo && selected_object(app) != nil
		if s.solo do report(app, nil, {.Quiet}, "Solo: only %s is shown", object_label(selected_object(app)))
	case .Select:
		if obj == nil do return
		obj.off, obj.ghost = false, false
		for o, i in s.objects do if o == obj do s.selected = i
	}
	app.view_edits += 1
	scene_selection_fix(app)
}

// Asks for `change` on the selected object at the start of the next frame.
view_command :: proc(app: ^App, change: View_Change) {
	obj := selected_object(app)
	app.ui.scene_command = {kind = .View, view = change, id = obj.id if obj != nil else 0}
}

// How many objects are out of view and how many are ghosts, for the panels and stats.
scene_view_counts :: proc(app: ^App) -> (off, ghosts: int) {
	for obj in app.scene.objects {
		if obj.off do off += 1
		if obj.ghost do ghosts += 1
	}
	return
}

// The eye and ghost toggles of an object's row in the Scene tab, ghost first so the
// eye sits at the row's end, where a finger running down the column finds it.
object_row_toggles :: proc(obj: ^Object) -> [2]ui.Row_Toggle {
	return {
		{name = "Show solid" if obj.ghost else "Make a ghost", glyph = ui.ICON_GHOST, lit = obj.ghost, faint = !obj.ghost},
		{
			name = fmt.tprintf("Show %s", object_label(obj)) if obj.off else fmt.tprintf("Hide %s", object_label(obj)),
			glyph = ui.ICON_EYE_OFF if obj.off else ui.ICON_EYE,
			faint = obj.off,
		},
	}
}
