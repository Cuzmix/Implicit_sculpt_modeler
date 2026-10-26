package main

import "core:fmt"

import "../sculpt"
import "../ui"

// Selection sets (sculpt/selection_sets.odin) in the app: Store mask as set, a row per
// set to rename and restore it, and Add, Subtract, Store over and Delete for the set the
// list picks. Storing, renaming and deleting are no undo steps, as in ZBrush, so each
// counts as a scene edit for autosave; a restore is a mask step. Changes are made from
// a press, and autosave always lets go of the scene before one is handled.

// Whether the selected object's sets can be stored and restored now; says why not when
// `say` is set.
sets_ready :: proc(app: ^App, obj: ^Object, say := true) -> bool {
	if obj == nil do return false
	if sculpt.levels_sets_ready(&obj.levels) do return true
	if say do report(app, Kit_Section.Sets, {.Warning}, "Selection sets need %s", "the HD window left first (A)" if object_in_hd(obj) else "dynamic topology off")
	return false
}

// Stores the selected object's mask as a new set, or over set `over`'s mask (0: a new
// one), named "Set N".
set_store :: proc(app: ^App, over: u32 = 0) {
	stroke_finish(app)
	obj := selected_object(app)
	if !sets_ready(app, obj) do return
	l := &obj.levels
	if over == 0 && len(sculpt.levels_sets(l)) >= sculpt.MAX_SELECTION_SETS {
		report(app, Kit_Section.Sets, {.Warning}, "An object keeps at most %d selection sets: delete one first", sculpt.MAX_SELECTION_SETS)
		return
	}
	// The first "Set N" from the count up that no set is called already.
	name: string
	for n := len(sculpt.levels_sets(l)) + 1; ; n += 1 {
		name = fmt.tprintf("Set %d", n)
		taken := false
		for &set in sculpt.levels_sets(l) do taken ||= sculpt.selection_set_name(&set) == name
		if !taken do break
	}
	id := sculpt.levels_set_store(l, name, over)
	if id == 0 {
		report(app, Kit_Section.Sets, {.Warning}, "Nothing is masked to store")
		return
	}
	app.scene_edits += 1
	i := sculpt.levels_set_index(l, id)
	app.ui.set_selected = i
	set := &sculpt.levels_sets(l)[i]
	report(app, Kit_Section.Sets, {}, "Stored the mask %s %s (%s masked)", "over" if over != 0 else "as", sculpt.selection_set_name(set), set_percent(set.masked))
}

// Brings back set `id` of the selected object by `mode`, as a mask undo step.
set_restore :: proc(app: ^App, id: u32, mode: sculpt.Set_Mode) {
	stroke_finish(app)
	obj := selected_object(app)
	if !sets_ready(app, obj) do return
	l := &obj.levels
	i := sculpt.levels_set_index(l, id)
	if i < 0 do return
	name := sculpt.selection_set_name(&sculpt.levels_sets(l)[i])
	verb := SET_MODE_VERBS[mode]
	if !sculpt.levels_set_restore(l, id, mode) {
		report(app, Kit_Section.Sets, {}, "%s %s: the mask is as it was", verb, name)
		return
	}
	history_record(app, obj, .Mask, fmt.tprintf("%s %s", verb, name))
	report(app, Kit_Section.Sets, {.Undo}, "%s %s", verb, name)
}

@(rodata)
SET_MODE_VERBS := [sculpt.Set_Mode]string {
	.Replace  = "Restored",
	.Add      = "Added",
	.Subtract = "Subtracted",
}

// Deletes set `id` of the selected object; there is no undo for it.
set_delete :: proc(app: ^App, id: u32) {
	obj := selected_object(app)
	if obj == nil do return
	l := &obj.levels
	i := sculpt.levels_set_index(l, id)
	if i < 0 do return
	report(app, Kit_Section.Sets, {}, "Deleted %s", sculpt.selection_set_name(&sculpt.levels_sets(l)[i]))
	sculpt.levels_set_delete(l, id)
	app.scene_edits += 1
}

// The selected object's set `index` (0 for the first), for the commands that take one;
// 0 when there is none.
set_id_at :: proc(app: ^App, index: int) -> u32 {
	obj := selected_object(app)
	if obj == nil do return 0
	sets := sculpt.levels_sets(&obj.levels)
	return sets[index].id if index >= 0 && index < len(sets) else 0
}

// The Object tab's Selection sets section.
kit_sets :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	ready := sets_ready(app, obj, say = false)
	_ = command_button(app, .Store_Selection_Set, glyph = ui.ICON_PLUS, width = ui.fill_width(ctx))
	l := &obj.levels
	sets := sculpt.levels_sets(l)
	// A word rather than an icon, since no glyph says "bring this mask back" at a glance;
	// wide enough for it at the largest text size.
	restore_width: f32 = 104
	field := ui.fill_width(ctx) - restore_width - 4
	for &set, i in sets {
		ui.begin(ctx, fmt.tprintf("set %d %d", obj.id, set.id), {direction = .Row, gap = 4, center = true})
		name := set.name
		// Keyed by the object too: set ids start again for each object.
		if ui.text_field(ctx, fmt.tprintf("name##set %d %d", obj.id, set.id), name[:], field, hint = "Name") {
			sculpt.levels_set_rename(l, set.id, cstring_of(name[:]))
			app.scene_edits += 1
			app.ui.set_selected = i
		}
		// The first SET_COMMANDS rows are the palette's Restore selection set 1 to 9, so
		// they show a key given to one; the rest restore directly.
		if i < SET_COMMANDS {
			if command_button(app, .Restore_Selection_Set, i, fmt.tprintf("Restore##set %d %d", obj.id, set.id), width = restore_width) do app.ui.set_selected = i
		} else if ui.button(ctx, fmt.tprintf("Restore##set %d %d", obj.id, set.id), width = restore_width, enabled = ready) {
			app.ui.set_selected = i
			set_restore(app, set.id, .Replace)
		}
		ui.end(ctx)
	}
	if len(sets) > 0 {
		chosen := clamp(int(app.ui.set_selected), 0, len(sets) - 1)
		names := make([]string, len(sets), context.temp_allocator)
		for &set, i in sets do names[i] = fmt.tprintf("%s · %s", sculpt.selection_set_name(&set), set_percent(set.masked))
		if picked := ui.select(ctx, "set to change", names, chosen); picked >= 0 do chosen = picked
		app.ui.set_selected = chosen
		id := sets[chosen].id
		add, subtract := kit_button_pair(ctx, "Add to mask", "Subtract", ready, ready)
		if add do set_restore(app, id, .Add)
		if subtract do set_restore(app, id, .Subtract)
		if kit_more(app, .Sets) {
			over, remove := kit_button_pair(ctx, "Store over", "Delete", ready, true, tone_b = .Danger)
			if over do set_store(app, id)
			if remove do set_delete(app, id)
			kit_more_end(app)
		}
	}
	ui.paragraph(ctx, fmt.tprintf("Keeps masks to bring back: Restore makes a set the mask, Add and Subtract mix it in, and hidden parts keep their mask. A set restores on any subdivision level. %d of %d kept. Storing, renaming and deleting are not undo steps; a remesh or any rebuild, and dynamic topology, drop them.", len(sets), sculpt.MAX_SELECTION_SETS))
	kit_last_result(app, .Sets)
}

// How much of the object a set masks, as "34%", or "under 1%" for a small part that
// would otherwise read as nothing.
@(private = "file")
set_percent :: proc(masked: f32) -> string {
	if masked > 0 && masked < 0.005 do return "under 1%"
	return fmt.tprintf("%.0f%%", 100 * masked)
}

// The text before the first zero byte.
@(private = "file")
cstring_of :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0 do n += 1
	return string(b[:n])
}
