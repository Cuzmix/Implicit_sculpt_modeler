package main

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:time"

import "../geom"
import "../render"
import "../sculpt"

// The Objects card's Split, Merge, Align and Distribute, as ZBrush's Subtool actions:
// Split makes parts of one object into objects of their own, Merge makes several objects
// into one, and Align and Distribute line objects up or space them out. Split and Merge
// rebuild objects, as Slice does, so the levels, HD detail, mask and strokes of what they
// rebuild go; the polypaint and polygroups stay, and a merge gives each object it takes
// a polygroup of its own, so Groups split takes a merge apart again. Each is one undo step.

// What Split makes into objects of their own.
Split_Mode :: enum u8 {
	Hidden, // the hidden part becomes an object; the object keeps what is shown
	Masked, // the masked part (each triangle masked at least half at every corner) becomes an object
	Groups, // each polygroup becomes an object
	Parts,  // each connected piece becomes an object
}

@(rodata)
SPLIT_NAMES := [Split_Mode]string {
	.Hidden = "Split hidden",
	.Masked = "Split masked",
	.Groups = "Groups split",
	.Parts  = "Split to parts",
}

// More objects than one split makes: past it the split is refused, so a mesh of
// scattered crumbs never fills the list with thousands of objects.
MAX_SPLIT_PARTS :: 64

// Each triangle's part of the object's shown level for `mode`, and how many parts; `why`
// says why there is nothing to split. The parts are in temp memory.
split_parts :: proc(obj: ^Object, mode: Split_Mode) -> (part: []u32, count: int, why: string) {
	s := object_sculptor(obj)
	m := object_mesh(obj)
	tcount := len(m.indices) / 3
	part = make([]u32, tcount, context.temp_allocator)
	switch mode {
	case .Hidden:
		hidden := sculpt.sculptor_hidden_tris(s)
		if hidden == nil do return nil, 0, "nothing of it is hidden"
		for h, t in hidden do part[t] = u32(h)
		count = 2
	case .Masked:
		if s.mask == nil do return nil, 0, "nothing of it is masked"
		masked := 0
		for t in 0 ..< tcount {
			in_mask := true
			for c in 0 ..< 3 do in_mask &&= s.mask[m.indices[3 * t + c]] >= sculpt.MASK_HALF
			part[t] = u32(in_mask)
			masked += int(in_mask)
		}
		if masked == 0 do return nil, 0, "nothing of it is masked"
		if masked == tcount do return nil, 0, "all of it is masked"
		count = 2
	case .Groups:
		groups := sculpt.sculptor_groups(s)
		if groups == nil do return nil, 0, "it has one polygroup"
		// Parts in the order of each group's first triangle.
		number := make([]u32, int(max(u16)) + 1, context.temp_allocator)
		slice.fill(number, geom.SPLIT_NONE)
		for g, t in groups {
			if number[g] == geom.SPLIT_NONE {
				number[g] = u32(count)
				count += 1
			}
			part[t] = number[g]
		}
		if count < 2 do return nil, 0, "it has one polygroup"
	case .Parts:
		part, count = geom.mesh_components(m^, context.temp_allocator)
		if count < 2 do return nil, 0, "it is in one piece"
	}
	if count > MAX_SPLIT_PARTS do return nil, 0, fmt.tprintf("it would make %d objects, more than %d", count, MAX_SPLIT_PARTS)
	return
}

// Splits the object as `mode` says: the object keeps the first part (what is shown, what
// is not masked, the first group or piece) and each other part becomes a new object after
// it in the list, in its folder, with its transform, so nothing moves. Its levels, HD
// detail, mask, hidden parts and strokes go; polypaint, polygroups and the shown level's
// sculpt layers stay (the caller records the change). Without `keep_parts` the other
// parts are thrown away instead (Delete hidden). `parts` lists the new objects' ids in
// order (owned); ok is false only on a GPU failure.
object_split :: proc(app: ^App, obj: ^Object, mode: Split_Mode, keep_parts := true) -> (parts: [dynamic]int, changed, ok: bool) {
	stroke_finish(app)
	object_hd_leave(app, obj)
	if object_dynamic(obj) {
		report(app, nil, {.Warning}, "%s: turn dynamic topology off first", SPLIT_NAMES[mode])
		return nil, false, true
	}
	what := SPLIT_NAMES[mode] if keep_parts else "Delete hidden"
	part, count, why := split_parts(obj, mode)
	if why == "" && !keep_parts && !slice.contains(part, 0) do why = "all of it is hidden"
	if why != "" {
		report(app, nil, {.Warning}, "%s: %s", what, why)
		return nil, false, true
	}
	start := time.tick_now()
	s := object_sculptor(obj)
	pieces := geom.mesh_split(object_mesh(obj)^, part, count)
	defer {
		// The meshes go to the objects; what is left is freed here.
		for &p in pieces {
			geom.mesh_destroy(&p.mesh)
			delete(p.vertex_from)
			delete(p.tri_from)
		}
		delete(pieces)
	}
	// Each piece's polypaint and polygroups, before the object's own go with its levels.
	surfaces := make([]Surface, count)
	defer {
		for sf in surfaces {
			delete(sf.color)
			delete(sf.groups)
		}
		delete(surfaces)
	}
	for p, k in pieces {
		if k > 0 && !keep_parts do break
		if s.color != nil {
			surfaces[k].color = make([]sculpt.Color, len(p.vertex_from))
			for v, i in p.vertex_from do surfaces[k].color[i] = s.color[v]
		}
		if groups := sculpt.sculptor_groups(s); groups != nil {
			surfaces[k].groups = make([]u16, len(p.tri_from))
			for t, i in p.tri_from do surfaces[k].groups[i] = groups[t]
		}
	}
	free_all(context.temp_allocator)
	cut := time.tick_now()
	render.wait_idle(&app.renderer)
	// Every piece takes the layers, so the level they came from stays until the last has.
	layered := object_take_layered(app, obj)
	defer sculpt.layered_level_free(&layered)
	object_release_mesh(app, obj)
	first := pieces[0].mesh
	pieces[0].mesh = {}
	if !object_build_from(app, obj, first, cut, normals = true, surface = surfaces[0]) do return nil, false, false
	object_carry_layers(app, obj, layered)
	index := -1
	for o, i in app.scene.objects do if o == obj do index = i
	parts = make([dynamic]int, 0, count - 1)
	for k in 1 ..< (count if keep_parts else 1) {
		mesh := pieces[k].mesh
		pieces[k].mesh = {}
		// Not temporary: building frees the temp allocator before the name is copied.
		name := fmt.aprintf("%s %d", object_label(obj), k + 1)
		defer delete(name)
		if !scene_add_mesh(app, mesh, name, obj.file, obj.transform, cut, surface = surfaces[k], material = obj.material) do return parts, true, false
		piece := app.scene.objects[len(app.scene.objects) - 1]
		object_carry_layers(app, piece, layered, counted = false)
		piece.folder = obj.folder
		ordered_remove(&app.scene.objects, len(app.scene.objects) - 1)
		inject_at(&app.scene.objects, index + k, piece)
		append(&parts, piece.id)
	}
	// Each piece keeps the group materials of the groups it has; one left with a single
	// group that had its own takes that as its material.
	table := slice.clone(obj.group_materials[:], context.temp_allocator)
	split_group_materials(app, obj, table, surfaces[0].groups)
	for id, k in parts do split_group_materials(app, object_by_id(app, id), table, surfaces[k + 1].groups)
	app.scene.selected = index
	app.split_made += len(parts)
	log.infof("%s: %d objects in %.0f ms, ready in %.0f ms more", what, len(parts) + 1, time.duration_milliseconds(time.tick_diff(start, cut)), time.duration_milliseconds(time.tick_since(cut)))
	return parts, true, true
}

// Gives split piece `piece`, with per-triangle groups `groups`, the entries of `table`
// for the groups it has. A piece of a single group that had its own material takes it as
// the piece's material instead (as Split by groups makes them).
@(private = "file")
split_group_materials :: proc(app: ^App, piece: ^Object, table: []Group_Material, groups: []u16) {
	if piece == nil do return
	kept := make([dynamic]Group_Material, 0, len(table), context.temp_allocator)
	if groups != nil && len(table) > 0 {
		present := make([]bool, 1 << 16, context.temp_allocator)
		for g in groups do present[g] = true
		for e in table do if present[e.group] do append(&kept, e)
		single := true
		for g in groups do single &&= g == groups[0]
		if single && len(kept) == 1 {
			autosave_settle(app)
			piece.material = kept[0].material
			clear(&kept)
		}
	}
	group_materials_replace(app, piece, kept[:])
}

// The shown level of each of `objs` in the space `into` places, as one mesh with zero
// normals, and its surface: polypaint when any of them has it, and polygroups numbered
// on from the ones before for each (each object's own numbered densely, in the order of
// their first triangles), so their parts stay apart (owned). ok is false, with nothing
// made, when that takes more polygroups than there are numbers for. With `table`, the
// merged object's group materials go there: each object's own, renumbered, and for every
// object after the first its other groups in its own material, so each part looks as it
// did (at most GROUP_MATERIALS_MAX, in group order).
merge_meshes :: proc(objs: []^Object, into: Transform, table: ^[dynamic]Group_Material = nil) -> (out: geom.Mesh, surface: Surface, ok: bool) {
	// The groups first, as they decide whether the merge can be made.
	tris := 0
	for obj in objs do tris += sculpt.sculptor_triangle_count(object_sculptor(obj))
	groups_out := make([dynamic]u16, 0, tris)
	number := make([]u32, int(max(u16)) + 1, context.temp_allocator)
	slice.fill(number, geom.SPLIT_NONE)
	used := make([dynamic]u16, 0, 64, context.temp_allocator)
	// Numbering starts at 1 when the first object has group materials, so none of its
	// groups lands on 0, which shows the merged object's own.
	base := 1 if len(objs) > 0 && len(objs[0].group_materials) > 0 else 0
	for obj, k in objs {
		s := object_sculptor(obj)
		tcount := sculpt.sculptor_triangle_count(s)
		// Under dynamic topology there are no groups (and no paint).
		groups := sculpt.sculptor_groups(s) if !object_dynamic(obj) else nil
		top := 0
		for t in 0 ..< tcount {
			g := groups[t] if groups != nil else 0
			if number[g] == geom.SPLIT_NONE {
				number[g] = u32(top)
				top += 1
				append(&used, g)
			}
			if base + int(number[g]) > int(max(u16)) {
				delete(groups_out)
				return {}, {}, false
			}
			append(&groups_out, u16(base + int(number[g])))
		}
		if table != nil {
			for g in used {
				m, own := Material{}, false
				for e in obj.group_materials do if e.group == g do m, own = e.material, true
				if !own && k > 0 && obj.material.label != nil && group_material_allowed(obj.material) do m, own = obj.material, true
				to := u16(base + int(number[g]))
				if own && to != 0 do append(table, Group_Material{to, m})
			}
		}
		for g in used do number[g] = geom.SPLIT_NONE
		clear(&used)
		base += top
	}
	meshes := make([]geom.Mesh, len(objs), context.temp_allocator)
	painted := false
	for obj, k in objs {
		meshes[k] = shape_in(obj, into)
		painted ||= sculpt.sculptor_has_color(object_sculptor(obj)) && !object_dynamic(obj)
	}
	defer for &m in meshes do geom.mesh_destroy(&m)
	out = geom.mesh_join(meshes)
	assert(len(groups_out) == len(out.indices) / 3)
	if table != nil {
		slice.sort_by(table[:], proc(a, b: Group_Material) -> bool {return a.group < b.group})
		if len(table) > GROUP_MATERIALS_MAX {
			log.warnf("merge: %d groups had materials of their own; the first %d keep them", len(table), GROUP_MATERIALS_MAX)
			resize(table, GROUP_MATERIALS_MAX)
		}
	}
	surface.groups = groups_out[:]
	if painted do surface.color = make([]sculpt.Color, len(out.positions))
	vertex := 0
	for obj, k in objs {
		s := object_sculptor(obj)
		vcount := len(meshes[k].positions)
		if painted && s.color != nil && !object_dynamic(obj) do copy(surface.color[vertex:][:vcount], s.color)
		vertex += vcount
	}
	return out, surface, true
}

// Merges the selected object with the object after it in the list into one, in the
// selected object's place and space, as ZBrush's MergeDown; the other object goes. One
// undo step. False only on a GPU failure.
merge_down :: proc(app: ^App) -> bool {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return true
	below := app.scene.selected + 1
	if below >= len(app.scene.objects) {
		report(app, nil, {.Warning}, "Merge down: there is no object below %s", object_label(obj))
		return true
	}
	other := app.scene.objects[below]
	other_name := fmt.aprintf("%s", object_label(other))
	defer delete(other_name)
	object_hd_leave(app, obj)
	object_hd_leave(app, other)
	pair := [2]^Object{obj, other}
	table: [dynamic]Group_Material
	defer delete(table)
	mesh, surface, made := merge_meshes(pair[:], obj.transform, &table)
	if !made {
		report(app, nil, {.Warning}, "Merge down: together they have more polygroups than one object can keep")
		return true
	}
	defer {
		delete(surface.color)
		delete(surface.groups)
	}
	before := history_snapshot(app, obj, "merge down")
	start := time.tick_now()
	render.wait_idle(&app.renderer)
	app.layers_lost += sculpt.levels_layer_count(&obj.levels)
	object_release_mesh(app, obj)
	if !object_build_from(app, obj, mesh, start, normals = true, surface = surface) {
		history_snapshot_drop(before)
		scene_delete_selected(app, undoable = false)
		return false
	}
	group_materials_replace(app, obj, table[:])
	history_record_swap(app, obj.id, before)
	// The object merged in goes, chained to the rebuild.
	app.scene.selected = below
	scene_delete_selected(app, chain = true)
	select_object(app, obj)
	app.merged += 2
	report(app, nil, {.Undo}, "Merged %s into %s", other_name, object_label(obj))
	return true
}

// Makes the shown objects into one new object at the end of the list, as ZBrush's
// MergeVisible: of the whole scene, or with `folder` of that folder and those inside it
// (Merge folder). The
// objects stay as they are. One undo step; false only on a GPU failure.
merge_visible :: proc(app: ^App, folder: int) -> bool {
	stroke_finish(app)
	objs := make([dynamic]^Object, 0, len(app.scene.objects), context.temp_allocator)
	for obj in app.scene.objects {
		if folder != 0 && (obj.folder == 0 || !folder_within(app, obj.folder, folder)) do continue
		if object_shown(app, obj) do append(&objs, obj)
	}
	what := "Merge folder" if folder != 0 else "Merge visible"
	if len(objs) < 2 {
		report(app, nil, {.Warning}, "%s: show two objects or more first", what)
		return true
	}
	for obj in objs do object_hd_leave(app, obj)
	bytes := 0
	for obj in objs do bytes += object_put_estimate(obj)
	if bytes > MAX_SUBDIVIDE_BYTES {
		report(app, nil, {.Warning}, "%s: the new object would need about %d MB; the limit is %d MB", what, bytes >> 20, MAX_SUBDIVIDE_BYTES >> 20)
		return true
	}
	table: [dynamic]Group_Material
	defer delete(table)
	mesh, surface, made := merge_meshes(objs[:], {scale = 1}, &table)
	if !made {
		report(app, nil, {.Warning}, "%s: together they have more polygroups than one object can keep", what)
		return true
	}
	defer {
		delete(surface.color)
		delete(surface.groups)
	}
	count := len(objs)
	// Not temporary: building frees the temp allocator before the name is copied.
	name := fmt.aprintf("%s merged", folder_label(folder_by_id(app, folder))) if folder != 0 else strings.clone("Merged")
	defer delete(name)
	// The merged object is shaded as the first of them was.
	if !scene_add_mesh(app, mesh, name, {scale = 1}, {scale = 1}, time.tick_now(), surface = surface, material = objs[0].material) do return false
	group_materials_replace(app, app.scene.objects[len(app.scene.objects) - 1], table[:])
	history_record_added(app)
	app.merged += count
	report(app, nil, {.Undo}, "%s: %d objects into %s", what, count, name)
	return true
}

// The object's shown level's bounds in the scene: every corner of each chunk's box
// through its transform, which stays close on a turned object.
object_world_bounds :: proc(obj: ^Object) -> geom.Aabb {
	s := object_sculptor(obj)
	model := transform_matrix(obj.transform)
	world := geom.AABB_EMPTY
	grow :: proc(world: ^geom.Aabb, model: render.Mat4, b: geom.Aabb) {
		if b.lo.x > b.hi.x do return
		for corner in 0 ..< 8 {
			p := Vec3{b.hi.x if corner & 1 != 0 else b.lo.x, b.hi.y if corner & 2 != 0 else b.lo.y, b.hi.z if corner & 4 != 0 else b.lo.z}
			q := model * [4]f32{p.x, p.y, p.z, 1}
			geom.aabb_grow(world, q.xyz)
		}
	}
	for c in s.chunks do grow(&world, model, c.bounds)
	if len(s.chunks) == 0 {
		local := geom.AABB_EMPTY
		for p in object_mesh(obj).positions do geom.aabb_grow(&local, p)
		grow(&world, model, local)
	}
	return world
}

// Where along `axis` a box's `edge` is: 0 its low side, 1 its middle, 2 its high side.
@(private = "file")
box_edge :: proc(b: geom.Aabb, axis, edge: int) -> f32 {
	switch edge {
	case 0: return b.lo[axis]
	case 2: return b.hi[axis]
	}
	return (b.lo[axis] + b.hi[axis]) * 0.5
}

@(rodata)
AXIS_NAMES := [3]string{"X", "Y", "Z"}
@(rodata)
EDGE_NAMES := [3]string{"min", "centre", "max"}

// Lines objects up along `axis` at `edge` (0 low side, 1 middle, 2 high side), moving
// them only along it: with several selected, the others to the primary; with one, that
// one to the bounds of every shown object, as ZBrush aligns a subtool. One undo step.
align_objects :: proc(app: ^App, axis, edge: int) {
	stroke_finish(app)
	sel := selected_object(app)
	if sel == nil do return
	ids := selection_ids(app)
	movers := make([dynamic]^Object, 0, len(ids), context.temp_allocator)
	target: f32
	if len(ids) > 1 {
		target = box_edge(object_world_bounds(sel), axis, edge)
		for id in ids[1:] do if obj := object_by_id(app, id); obj != nil do append(&movers, obj)
	} else {
		all := geom.AABB_EMPTY
		for obj in app.scene.objects do if object_shown(app, obj) do all = geom.aabb_union(all, object_world_bounds(obj))
		target = box_edge(all, axis, edge)
		append(&movers, sel)
	}
	moved := 0
	for obj in movers {
		before := obj.transform
		obj.transform.position[axis] += target - box_edge(object_world_bounds(obj), axis, edge)
		if obj.transform != before {
			history_record_transform(app, obj, before, "align", chain = moved > 0)
			moved += 1
		}
	}
	app.aligned += moved
	if moved > 0 do report(app, nil, {.Undo}, "Aligned %d object%s at %s %s", moved, "" if moved == 1 else "s", AXIS_NAMES[axis], EDGE_NAMES[edge])
}

// Spaces objects evenly along `axis` by their `edge`: the selected ones when three or more
// are, or else every shown object. The first and last along the axis stay; the rest move
// along it only. One undo step.
distribute_objects :: proc(app: ^App, axis, edge: int) {
	stroke_finish(app)
	Place :: struct {
		obj: ^Object,
		at:  f32,
	}
	places := make([dynamic]Place, 0, len(app.scene.objects), context.temp_allocator)
	ids := selection_ids(app)
	if len(ids) >= 3 {
		for id in ids do if obj := object_by_id(app, id); obj != nil do append(&places, Place{obj, 0})
	} else {
		for obj in app.scene.objects do if object_shown(app, obj) do append(&places, Place{obj, 0})
	}
	if len(places) < 3 {
		report(app, nil, {.Warning}, "Distribute: needs three objects or more")
		return
	}
	for &p in places do p.at = box_edge(object_world_bounds(p.obj), axis, edge)
	// A stable sort, so objects at one place keep the list's order.
	slice.stable_sort_by(places[:], proc(a, b: Place) -> bool {return a.at < b.at})
	lo, hi := places[0].at, places[len(places) - 1].at
	moved := 0
	for p, i in places[1:len(places) - 1] {
		want := lo + (hi - lo) * f32(i + 1) / f32(len(places) - 1)
		before := p.obj.transform
		p.obj.transform.position[axis] += want - p.at
		if p.obj.transform != before {
			history_record_transform(app, p.obj, before, "distribute", chain = moved > 0)
			moved += 1
		}
	}
	app.aligned += moved
	if moved > 0 do report(app, nil, {.Undo}, "Spaced %d objects evenly along %s", len(places), AXIS_NAMES[axis])
}
