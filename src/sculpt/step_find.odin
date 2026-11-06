package sculpt

// Which of a sculptor's steps changed a spot of the surface, for the History's Find steps
// at a spot: the list then shows only those. It reads the undo data alone and copies no
// mesh, so asking costs a pass over the steps' saved lists and adds nothing to a stroke.
//
// A done step holds, for each node it touched, the node's values from before it; an undone
// step, which undo swapped with the live values, holds them from after it. So for one node
// and one kind of value, walking the done steps from the newest back, the value after each
// is the live one or the before of the newer step that saved the node last seen, and the
// step changed a vertex exactly when its own before differs from that. The undone steps
// walk the other way in time from the live values, which stand between the two lists, each
// one's before being the after of the older undone step last seen. Masks follow the mask
// they painted (Undo_Step.mask_layer) and colours their paint layer, each in a chain of its
// own, since a mask stroke between two strokes saves nothing of the positions.

// The kind of value a saved node holds, as the chains above keep them apart.
@(private = "file")
Find_Kind :: enum u8 {
	Positions,
	Masks,
	Colors,
	// Values not compared per vertex (grouped triangles, skin heights, a whole node saved
	// under dynamic topology): the step's change to the spot is Unknown.
	Other,
}

// A saved node of one step holding one of the vertices asked about.
@(private = "file")
Find_Hit :: struct {
	order: int, // the step's place in time: done steps oldest first from 0, then the undone ones
	step:  ^Undo_Step,
	saved: int, // in step.saved
	kind:  Find_Kind,
	layer: u32, // mask_layer for masks, paint_layer for colours
}

// What a step did to the spot asked about.
Step_Change :: enum u8 {
	Unchanged,
	Changed,
	// Not readable from the undo data: a step from before a move no step holds (the levels
	// carrying another level's edits, history.sealed), a mask stroke after the sculpt layers
	// were renumbered, a change of groups or skin heights, which are not per vertex. The
	// caller judges these some other way (the History by the step's box).
	Unknown,
}

// A step of the history, by its id (Undo_Step.id, kept through undo and redo), and what it
// did to the spot.
Step_Seen :: struct {
	id:     u64,
	change: Step_Change,
}

// What each done and undone step did to the position, mask or colour of any of `vertices`
// (the sculptor's numbering; the corners of the triangle a pick hit, say), one entry a step,
// done steps oldest first and then the undone ones in time. A step that saved none of their
// nodes is Unchanged. Not ok, with nothing allocated, under dynamic topology, whose steps
// renumber the vertices, while a stroke is being recorded, or while the GPU's last positions
// are not back yet (ask again next frame).
sculptor_steps_changing :: proc(s: ^Sculptor, vertices: []u32, allocator := context.allocator) -> (steps: []Step_Seen, ok: bool) {
	h := &s.history
	if s.dyn != nil || h.recording do return
	// The values compared must be the ones the GPU left, not the mirror a frame behind.
	if !sculptor_gpu_sync(s, normals = false) do return
	ok = true
	steps = make([]Step_Seen, len(h.done) + len(h.undone), allocator)
	// Done steps oldest first, then the undone ones in time: the undone list is a stack,
	// the next to redo last, so in time it runs backwards.
	for step, i in h.done do steps[i].id = step.id
	for j in 0 ..< len(h.undone) do steps[len(h.done) + j].id = h.undone[len(h.undone) - 1 - j].id
	// A step that adds, removes or reorders sculpt layers renumbers their masks, so a mask
	// chain cannot be followed across one.
	renumbered := false
	for step in h.done do if step.layer_op.active || step.layer_move.active || step.layer_stack.active do renumbered = true
	for step in h.undone do if step.layer_op.active || step.layer_move.active || step.layer_stack.active do renumbered = true
	hits := make([dynamic]Find_Hit, context.temp_allocator)
	for v in vertices {
		if int(v) >= len(s.mesh.positions) do continue
		id, found := node_owning(s, v)
		if !found do continue
		clear(&hits)
		for &step, i in h.done do find_hits(&hits, &step, i, id)
		for j := len(h.undone) - 1; j >= 0; j -= 1 do find_hits(&hits, &h.undone[j], len(h.done) + (len(h.undone) - 1 - j), id)
		at := int(v - s.nodes[id].vert_first)
		for hit in hits do if hit.kind == .Other do mark(steps, hit.order, .Unknown)
		// Each chain once: positions, then each mask and each paint layer met.
		for hit, i in hits {
			if hit.kind == .Other do continue
			first := true
			for other in hits[:i] do if other.kind == hit.kind && other.layer == hit.layer do first = false
			if !first do continue
			live, known := find_live(s, hit.kind, hit.layer, int(v))
			if hit.kind == .Masks && renumbered do known = false
			// Done steps from the newest back: each one's after is the live value or the
			// before of the newer step met last.
			state := live
			for k := len(hits) - 1; k >= 0; k -= 1 {
				c := hits[k]
				if c.kind != hit.kind || c.layer != hit.layer || c.order >= len(h.done) do continue
				before := find_saved(c, at)
				verdict(steps, h, c.order, before != state, known)
				state = before
			}
			// Undone steps from the oldest in time: each one's before is the live value or
			// the after of the older undone step met last.
			state = live
			for c in hits {
				if c.kind != hit.kind || c.layer != hit.layer || c.order < len(h.done) do continue
				after := find_saved(c, at)
				verdict(steps, h, c.order, after != state, known)
				state = after
			}
		}
	}
	return
}

// Raises a step's verdict to `c`: Changed by one vertex stays so, and Unknown by any.
@(private = "file")
mark :: proc(steps: []Step_Seen, order: int, c: Step_Change) {
	if c > steps[order].change do steps[order].change = c
}

// A step's verdict from one comparison: Unknown when the chain cannot be read (a layer that
// went, or a step from before the history's seal), else Changed when the values differ.
@(private = "file")
verdict :: proc(steps: []Step_Seen, h: ^Undo_History, order: int, differs, known: bool) {
	switch {
	case !known || steps[order].id <= h.sealed:
		mark(steps, order, .Unknown)
	case differs:
		mark(steps, order, .Changed)
	}
}

// One vertex's value of any kind, compared as a whole.
@(private = "file")
Find_Value :: struct {
	position: Vec3,
	mask:     u8,
	color:    Color,
	material: Material_Paint,
}

// Lists the saved nodes of `step` that hold node `id`.
@(private = "file")
find_hits :: proc(hits: ^[dynamic]Find_Hit, step: ^Undo_Step, order: int, id: u32) {
	for sv, i in step.saved {
		if sv.node != id do continue
		hit := Find_Hit{order = order, step = step, saved = i, kind = .Other}
		switch {
		// A layer's displacement always sits beside the same node's positions, which are
		// compared; hiding changes no value of a vertex, and a picked triangle shows now.
		case sv.is_delta || sv.hidden != nil:
			continue
		case sv.full || sv.groups != nil || sv.heights != nil:
		case sv.positions != nil:
			hit.kind = .Positions
		case sv.masks != nil:
			hit.kind, hit.layer = .Masks, u32(step.mask_layer)
		case sv.colors != nil:
			hit.kind, hit.layer = .Colors, step.paint_layer
		}
		append(hits, hit)
	}
}

// The value a hit saved for the vertex `at` into its node.
@(private = "file")
find_saved :: proc(hit: Find_Hit, at: int) -> (v: Find_Value) {
	sv := hit.step.saved[hit.saved]
	switch hit.kind {
	case .Positions:
		if at < len(sv.positions) do v.position = sv.positions[at]
	case .Masks:
		if at < len(sv.masks) do v.mask = sv.masks[at]
	case .Colors:
		if at < len(sv.colors) do v.color = sv.colors[at]
		if at < len(sv.materials) do v.material = sv.materials[at]
	case .Other:
	}
	return
}

// The live value of vertex `v` that a chain of `kind` and `layer` starts from; not `known`
// when the mask or paint layer it painted is gone. Reads only: a mask nobody made yet is
// all zero, as step_mask would make it.
@(private = "file")
find_live :: proc(s: ^Sculptor, kind: Find_Kind, layer: u32, v: int) -> (value: Find_Value, known: bool) {
	known = true
	switch kind {
	case .Positions:
		value.position = s.mesh.positions[v]
	case .Masks:
		ls := &s.layers
		mask: []u8
		switch {
		case int(layer) == ls.picked:
			mask = s.mask
		case layer == 0:
			mask = ls.held
		case int(layer) <= len(ls.list):
			mask = ls.list[layer - 1].mask
		case:
			return {}, false
		}
		if v < len(mask) do value.mask = mask[v]
	case .Colors:
		colors := paint_colors_by_id(s, layer)
		if colors == nil do return {}, false
		if v < len(colors) do value.color = colors[v]
		// A step saves materials only while its layer had them, so the live ones count only
		// then; a step without them reads zero against zero.
		if m := paint_materials_by_id(s, layer); m != nil && v < len(m) do value.material = m[v]
	case .Other:
	}
	return
}

// The node owning vertex `v`: the one whose owned range holds it.
@(private = "file")
node_owning :: proc(s: ^Sculptor, v: u32) -> (id: u32, ok: bool) {
	for n, i in s.nodes do if v >= n.vert_first && v - n.vert_first < n.vert_count do return u32(i), true
	return
}
