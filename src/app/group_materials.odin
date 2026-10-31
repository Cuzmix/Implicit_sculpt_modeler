package main

import "core:math"
import "core:math/linalg"

import "../geom"
import "../render"
import "../sculpt"

// Materials of polygroups (Scene > Material, Group): gold trim on a steel plate in one
// object. Each object keeps a short table of its groups that have a material of their own,
// by group number, which every level shares (levels carry group numbers between them).
// The renderer looks each triangle's group up in it (render.Material_Slots); every other
// group shows the object's material. Like the object's material it is outside Undo, but a
// group command that renumbers the groups moves the table with them, as part of that step
// (group_materials_follow), and a rebuild's swap step keeps the table with the mesh.

Group_Material :: struct {
	group:    u16,
	material: Material,
}

// Slot 0 is the object's own material.
GROUP_MATERIALS_MAX :: render.GROUP_SLOTS - 1

// Whether `m` can shade a group: any but a MatCap, since a draw has one matcap picture,
// the object's.
group_material_allowed :: proc(m: Material) -> bool {
	return m.matcap == 0
}

// The material group `group` of `obj` is shaded with: its own, or the object's.
group_material_of :: proc(app: ^App, obj: ^Object, group: u16) -> (m: Material, own: bool) {
	for e in obj.group_materials do if e.group == group do return e.material, true
	return object_material(app, obj), false
}

// Gives group `group` of `obj` material `m`, or with `clear` gives it back the object's.
// Returns why it could not, or "": group 0 is the object's own, a MatCap cannot shade a
// group, and an object has at most GROUP_MATERIALS_MAX. The table stays sorted by group.
group_material_set :: proc(obj: ^Object, group: u16, m: Material, clear := false) -> (why: string) {
	if group == 0 do return "group 0 shows the object's own material"
	at := len(obj.group_materials)
	for e, i in obj.group_materials {
		if e.group >= group {
			at = i
			break
		}
	}
	exists := at < len(obj.group_materials) && obj.group_materials[at].group == group
	if clear {
		if exists do ordered_remove(&obj.group_materials, at)
		return ""
	}
	if !group_material_allowed(m) do return "a MatCap cannot shade a group: pick a lit material"
	m := m
	m.selected.a, m.idle.a = 1, 1
	if m.label == nil do m.label = "Custom"
	// A Custom one made from a content pack's material (the object's, say) is no longer
	// the pack's.
	if m.label == "Custom" do m.pack = 0
	if exists {
		obj.group_materials[at].material = m
		return ""
	}
	if len(obj.group_materials) >= GROUP_MATERIALS_MAX do return "an object has at most 15 groups with materials of their own"
	inject_at(&obj.group_materials, at, Group_Material{group, m})
	return ""
}

// A Scene_Command's .Group_Material: gives group cmd.group of object cmd.id the material
// cmd.material, or with cmd.on the object's again. The scene counts as changed; nothing is
// an undo step.
group_material_apply :: proc(app: ^App, cmd: Scene_Command) {
	obj := object_by_id(app, cmd.id)
	if obj == nil || obj.voxel != nil do return
	// The autosave thread may be writing the table.
	autosave_settle(app)
	if why := group_material_set(obj, cmd.group, cmd.material, cmd.on); why != "" {
		report(app, Kit_Section.Material, {.Warning}, "Group %d keeps its material: %s", cmd.group, why)
		return
	}
	app.scene_edits += 1
}

// The draw colour `m` takes on object `obj` (the i-th): selected, muted or between, and
// shaded as a ghost, as object_draw_tint gives the object's own.
material_draw_tint :: proc(app: ^App, obj: ^Object, i: int, m: Material) -> [4]f32 {
	selected := i == app.scene.selected
	idle := m.idle if app.dim_others else m.selected
	color := m.selected if selected else idle
	if object_in_selection(app, obj) && !selected do color = linalg.lerp(idle, m.selected, SELECTION_TINT)
	if _, ghost := object_flags(app, obj); ghost do color.rgb *= GHOST_SHADE
	return color
}

// The renderer's slots for `obj`'s group materials this frame, or nil for none: made in
// the frame's temporary memory, for its draw items only.
object_material_slots :: proc(app: ^App, obj: ^Object, i: int) -> ^render.Material_Slots {
	if len(obj.group_materials) == 0 do return nil
	slots := new(render.Material_Slots, context.temp_allocator)
	slots.groups = render.SLOT_NONE
	for e, k in obj.group_materials {
		if k + 1 >= render.GROUP_SLOTS do break
		m := e.material
		slots.groups[k + 1] = u32(e.group)
		slots.uniforms.color[k + 1] = material_draw_tint(app, obj, i, m)
		slots.uniforms.params[k + 1] = m.shading if m.shading != {} else render.DEFAULT_MATERIAL
		slots.uniforms.surface[k + 1] = {m.metallic, m.roughness, 0, 0}
	}
	return slots
}

// The table after a group command changed each triangle's group from `before` to `after`
// (nil: all 0): each entry follows the group now holding most of its triangles (on a tie
// the lower number), in group order, and goes when that is group 0, when an earlier entry
// went there, or when it had no triangles. Visible and Masked so carry a material to the
// part they regroup when it was most of its group, Creases to the part that kept most of
// it, and Clear drops what it cleared. Made with `allocator`.
group_materials_follow :: proc(table: []Group_Material, before, after: []u16, allocator := context.allocator) -> (out: [dynamic]Group_Material) {
	out = make([dynamic]Group_Material, 0, len(table), allocator)
	if len(table) == 0 do return
	// Entry index + 1 by group number, and per entry how many triangles went to each group.
	which := make([]u8, 1 << 16, context.temp_allocator)
	for e, k in table do which[e.group] = u8(k + 1)
	counts := make([]map[u16]int, len(table), context.temp_allocator)
	for &c in counts do c = make(map[u16]int, 8, context.temp_allocator)
	if before != nil {
		for g, t in before {
			k := which[g]
			if k == 0 do continue
			to := after[t] if after != nil else 0
			counts[k - 1][to] += 1
		}
	}
	for e, k in table {
		best, most := u16(0), 0
		for g, n in counts[k] {
			if n > most || (n == most && g < best) do best, most = g, n
		}
		if most == 0 || best == 0 do continue
		taken := false
		for o in out do taken ||= o.group == best
		if taken do continue
		// Kept in group order.
		at := len(out)
		for o, i in out {
			if o.group > best {
				at = i
				break
			}
		}
		inject_at(&out, at, Group_Material{best, e.material})
	}
	return
}

// The table before and after a group command, for its History entry: undo puts back the
// one, redo the other.
Group_Table_Step :: struct {
	before, after: [dynamic]Group_Material,
}

group_table_step_free :: proc(step: ^Group_Table_Step) {
	if step == nil do return
	delete(step.before)
	delete(step.after)
	free(step)
}

// Puts `table` in place of `obj`'s, copying it.
group_materials_replace :: proc(app: ^App, obj: ^Object, table: []Group_Material) {
	autosave_settle(app)
	clear(&obj.group_materials)
	append(&obj.group_materials, ..table)
}

// The scene file's form of an object's table (object_put, version 15): the count, then
// each group and its material, with its content pack parts by name, one of `refs` a
// group (version 16; none for none).
group_materials_put :: proc(out: ^[dynamic]u8, obj: ^Object, refs: []Material_Refs = nil) {
	geom.byte_put(out, u16(len(obj.group_materials)))
	for e, k in obj.group_materials {
		geom.byte_put(out, e.group)
		material_put(out, e.material, refs[k] if k < len(refs) else {})
	}
}

// Reads what group_materials_put writes into obj.group_materials; r.ok goes false on a
// table no object has: too long, groups not rising from 1, or a material that is unset, a
// MatCap or damaged. Groups need not exist: a table may hold groups a later step brings
// back. A content pack's material is looked up in `app` as material_get does.
group_materials_get :: proc(r: ^geom.Byte_Reader, obj: ^Object, app: ^App = nil, version := SCENE_VERSION, missing: ^int = nil) {
	n := int(geom.byte_get(r, u16))
	if !r.ok || n > GROUP_MATERIALS_MAX {
		r.ok = false
		return
	}
	last := u16(0)
	for _ in 0 ..< n {
		group := geom.byte_get(r, u16)
		m := material_get(r, app, version, missing)
		if !r.ok || group <= last || m.label == nil || !group_material_allowed(m) {
			r.ok = false
			return
		}
		append(&obj.group_materials, Group_Material{group, m})
		last = group
	}
}

// Whether `obj` draws group materials now: it has some, and the shown level has groups
// (none under dynamic topology).
object_shows_group_materials :: proc(obj: ^Object) -> bool {
	return len(obj.group_materials) > 0 && obj.voxel == nil && sculpt.sculptor_has_groups(&sculpt.levels_current(&obj.levels).sculptor)
}

// Paint colour `x` over `under` (sRGB 0 to 255) as far as its alpha covers.
paint_over :: proc(x: sculpt.Color, under: [3]u32) -> (c: [3]u8) {
	for k in 0 ..< 3 do c[k] = u8((u32(x[k]) * u32(x.a) + under[k] * (255 - u32(x.a)) + 127) / 255)
	return
}

// The material slots of `obj` for an export or a bake, in temporary memory: per group
// number its slot (0 for the object's material, k + 1 for its k-th group material), and
// the materials, [0] the object's.
group_slots :: proc(app: ^App, obj: ^Object) -> (which: []u8, materials: []geom.Export_Material) {
	which = make([]u8, 1 << 16, context.temp_allocator)
	materials = make([]geom.Export_Material, 1 + len(obj.group_materials), context.temp_allocator)
	materials[0] = export_material(object_material(app, obj))
	for e, k in obj.group_materials {
		which[e.group] = u8(k + 1)
		materials[k + 1] = export_material(e.material)
	}
	return
}

// Gives a glTF or USD export `m` of `obj` its group materials: each written face's slot by
// its group (`face_groups`, one a face, nil for none), 0 being the object's material. With
// paint (`paint`, one a vertex) the colours become the paint over each face's own
// material, whose colour then goes as white as object_export does the object's: for glTF
// by giving each slot vertices of its own (`gltf`), for USD a face corner at a time.
// Leaves `m` as it is when no face has a material of its own.
export_group_materials :: proc(app: ^App, obj: ^Object, m: ^geom.Mesh_Export, face_groups: []u16, paint: []sculpt.Color, gltf: bool) {
	if face_groups == nil || len(obj.group_materials) == 0 do return
	which, all := group_slots(app, obj)
	slots := make([]u8, len(face_groups), context.temp_allocator)
	used := false
	for g, f in face_groups {
		slots[f] = which[g]
		used ||= slots[f] != 0
	}
	if !used do return
	materials := all[1:]
	under := make([][3]u32, len(all), context.temp_allocator)
	for m, k in all {
		for c in 0 ..< 3 do under[k][c] = u32(math.round(geom.srgb_encode(m.base[c]) * 255))
	}
	if paint != nil do for &m in materials do m.base = 1
	m.group_materials, m.face_material = materials, slots
	if paint == nil do return
	if gltf {
		from, slot := geom.mesh_export_split_materials(m)
		colors := make([][3]u8, len(from), context.temp_allocator)
		for v, k in from do colors[k] = paint_over(paint[v], under[slot[k]])
		m.colors = colors
		return
	}
	colors: [][3]u8
	if m.quads != nil {
		colors = make([][3]u8, 4 * len(m.quads), context.temp_allocator)
		for q, f in m.quads {
			for v, c in q do colors[4 * f + c] = paint_over(paint[v], under[slots[f]])
		}
	} else {
		colors = make([][3]u8, len(m.indices), context.temp_allocator)
		for v, i in m.indices do colors[i] = paint_over(paint[v], under[slots[i / 3]])
	}
	m.colors, m.corner_colors = colors, true
}

// Pick a group: starts waiting for a press on the selected object, or stops; either way
// the Material section shows its Group target.
group_pick_toggle :: proc(app: ^App) {
	app.ui.group_pick = !app.ui.group_pick
	app.ui.material_groups = true
}

// Follows Pick a group with this frame's input: a press on the selected object picks the
// polygroup under it as the Material section's group; a press anywhere else ends the pick
// with a note. Returns true while the press is the pick's, so no tool takes it.
group_pick_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	u := &app.ui
	if u.group_pick_held {
		if !input.primary do u.group_pick_held = false
		return true
	}
	if !u.group_pick || !input.press do return false
	u.group_pick = false
	u.group_pick_held = input.primary
	obj := selected_object(app)
	if obj == nil do return true
	origin, dir := mouse_ray(app.camera, gesture_start(input), input.size)
	index, _, hit := scene_raycast(app, origin, dir)
	if !hit || app.scene.objects[index] != obj {
		report(app, Kit_Section.Material, {.Warning}, "Pick a group: the press missed %s", object_label(obj))
		return true
	}
	s := object_sculptor(obj)
	if !sculpt.sculptor_has_groups(s) || object_in_hd(obj) do return true
	t := obj.transform
	group, on := sculpt.sculptor_group_at(s, to_local(t, origin), to_local_dir(t, dir))
	if !on do return true
	if group == 0 {
		report(app, Kit_Section.Material, {.Warning}, "Group 0 shows the object's own material: make a group of the part first (Object palette, Polygroups)")
		return true
	}
	u.group_target, u.group_target_id = group, obj.id
	u.material_groups = true
	return true
}
