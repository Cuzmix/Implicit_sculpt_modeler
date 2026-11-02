package main

import "core:fmt"
import "core:time"

import "../geom"
import "../sculpt"

// The detail skin (sculpt/skin.odin) in the app: where a brush's detail goes, and adding,
// changing and taking off an object's skin.

// Where a brush's detail goes on an object with a detail skin, remembered per brush.
// Auto writes into the skin when the object has one; Mesh always moves vertices; Skin
// never moves a vertex, and refuses where there is no skin to write into. Grab, Pose,
// Cloth and the other brushes that move vertices sideways always move the mesh.
Detail_To :: enum u8 {
	Auto,
	Mesh,
	Skin,
}

@(rodata)
DETAIL_TO_NAMES := [Detail_To]string {
	.Auto = "Auto",
	.Mesh = "Mesh",
	.Skin = "Skin",
}

// The skin segments the Detail skin choice offers, Off first.
SKIN_SEGMENTS := [?]u32{0, 2, 4, 8, 16}

// The object's detail skin (on its current level's sculptor), nil for none, for a voxel
// object or a curve or cage, or while it sculpts HD.
object_skin :: proc(obj: ^Object) -> ^sculpt.Skin {
	if obj == nil || obj.voxel != nil || obj.curve != nil || obj.cage != nil || object_in_hd(obj) do return nil
	return sculpt.sculptor_skin(object_sculptor(obj))
}

// The detail skin on the object's top level, which a skin belongs to, whichever level is
// current; nil for none.
object_top_skin :: proc(obj: ^Object) -> ^sculpt.Skin {
	if obj == nil || obj.voxel != nil || obj.curve != nil || obj.cage != nil || len(obj.levels.levels) == 0 do return nil
	return sculpt.sculptor_skin(&obj.levels.levels[len(obj.levels.levels) - 1].sculptor)
}

// The commands a skinned object refuses: each would change the top level's triangles
// under the skin, or add finer detail that competes with it (HD, dynamic topology).
SKIN_REFUSED_COMMANDS :: Command_Set{.Subdivide, .Delete_Lower_Levels, .Delete_Higher_Levels, .Hd_Divide, .Hd_Sculpt, .Hd_Toggle, .Dyntopo_Toggle}

// The scene commands a skinned object refuses, for the same reasons, for scripts.
SKIN_REFUSED_SCENE :: bit_set[Scene_Command_Kind]{.Subdivide, .Delete_Higher, .Delete_Lower, .Hd_Enter, .Hd_Steps, .Dyntopo}

// Whether a stroke of `kind` on `obj` writes into its detail skin: a skin brush with
// Detail goes to on Auto or Skin. Auto moves the mesh while a sculpt layer records, since
// layers hold vertex moves only.
stroke_to_skin :: proc(app: ^App, obj: ^Object, kind: sculpt.Brush_Kind) -> bool {
	if kind not_in sculpt.SKIN_KINDS || object_skin(obj) == nil do return false
	switch app.brush.detail_to[kind] {
	case .Mesh: return false
	case .Skin: return true
	case .Auto: return sculpt.sculptor_layer_recording(object_sculptor(obj)) < 0
	}
	return false
}

// Whether a stroke of `kind` may start on `obj`: with Detail goes to on Skin, only where
// there is a skin and no sculpt layer records. With `say`, a refusal says why.
skin_stroke_allowed :: proc(app: ^App, obj: ^Object, kind: sculpt.Brush_Kind, say: bool) -> bool {
	if kind not_in sculpt.SKIN_KINDS || app.brush.detail_to[kind] != .Skin do return true
	if obj.voxel != nil do return true
	label := BRUSHES[kind].name
	if object_skin(obj) == nil {
		if say do report(app, Kit_Section.Hd, {.Warning}, "%s puts its detail in the skin, and %s has none: add a detail skin (Object palette, HD detail) or set Detail goes to Auto", label, object_label(obj))
		return false
	}
	if sculpt.sculptor_layer_recording(object_sculptor(obj)) >= 0 {
		if say do report(app, Kit_Section.Layers, {.Warning}, "%s puts its detail in the skin, and sculpt layers record vertex moves only: stop the recording or set Detail goes to Auto", label)
		return false
	}
	return true
}

// Why the object cannot have a detail skin now, or "" when it can.
skin_refusal :: proc(obj: ^Object) -> string {
	switch {
	case obj == nil: return "Select an object first."
	case obj.voxel != nil: return "Voxel clay has no skin: convert it to a mesh first."
	case obj.curve != nil || obj.cage != nil: return "A skin goes on a sculpt mesh."
	case object_dynamic(obj): return "Turn dynamic topology off to add a skin."
	case obj.levels.hd.steps > 0: return "Delete the HD level to add a skin: both sculpt finer than the mesh."
	case obj.levels.current != len(obj.levels.levels) - 1: return "A skin goes on the top level: go up to it first."
	}
	return ""
}

// Gives the selected object a detail skin of `segments` along each triangle edge, or
// with 0 takes it off, as an undo step. Says why when it cannot.
skin_set :: proc(app: ^App, segments: u32) {
	stroke_finish(app)
	obj := selected_object(app)
	if why := skin_refusal(obj); why != "" {
		if segments != 0 || object_skin(obj) != nil do report(app, Kit_Section.Hd, {.Warning}, "%s", why)
		return
	}
	s := object_sculptor(obj)
	if !sculpt.sculptor_skin_change(s, segments) {
		if sk := sculpt.sculptor_skin(s); segments != 0 && (sk == nil || sk.segments != segments) {
			report(app, Kit_Section.Hd, {.Warning}, "%s needs a closed mesh for a skin: Rebuild or Close holes first", object_label(obj))
		}
		return
	}
	what := "Remove detail skin" if segments == 0 else "Detail skin"
	history_record(app, obj, .Deform, what)
	if segments == 0 {
		report(app, nil, {.Undo}, "Took the detail skin off %s", object_label(obj))
	} else {
		report(app, nil, {.Undo}, "%s has a detail skin of %d segments", object_label(obj), segments)
	}
}

// Why the object's skin cannot be applied now, or "" when it can.
skin_apply_refusal :: proc(obj: ^Object) -> string {
	top := object_top_skin(obj)
	if top == nil do return "Add a detail skin first."
	levels := &obj.levels
	steps := sculpt.levels_skin_apply_steps(levels)
	switch {
	case levels.current != len(levels.levels) - 1: return "Go up to the top level first: the skin lies on it."
	case len(levels.levels) + steps > sculpt.MAX_LEVELS: return fmt.tprintf("Apply adds %d levels and the object has room for %d.", steps, sculpt.MAX_LEVELS - len(levels.levels))
	case levels.rule != .Loop: return "Apply builds Loop levels, and this object subdivides as Catmull-Clark."
	}
	if _, _, bytes := sculpt.levels_skin_apply_estimate(levels); bytes > MAX_SUBDIVIDE_BYTES {
		return fmt.tprintf("Apply would need about %s; the limit is %s.", bytes_label(bytes), bytes_label(MAX_SUBDIVIDE_BYTES))
	}
	return ""
}

// Bakes the selected object's detail skin into subdivision levels (sculpt.levels_skin_apply)
// as one undo step, a swap that puts the skin back. Returns false on a GPU failure.
skin_apply :: proc(app: ^App) -> bool {
	obj := selected_object(app)
	if obj == nil do return true
	if why := skin_apply_refusal(obj); why != "" {
		report(app, Kit_Section.Hd, {.Warning}, "%s", why)
		return true
	}
	stroke_finish(app)
	start := time.tick_now()
	levels := &obj.levels
	layers := len(levels.levels[len(levels.levels) - 1].sculptor.layers.list)
	before := history_snapshot(app, obj, "apply detail skin")
	if !sculpt.levels_skin_apply(levels, carry_layers = layers > 0) {
		history_snapshot_drop(before)
		report(app, Kit_Section.Hd, {.Warning}, "%s needs a closed mesh to apply its skin: Rebuild or Close holes first", object_label(obj))
		return true
	}
	history_record_swap(app, obj.id, before)
	object_forget_history(app, obj)
	app.layers_kept += layers
	report(app, nil, {.Undo}, "Applied the detail skin of %s: level %d has %s vertices", object_label(obj), levels.current + 1, count_label(geom.mesh_vertex_count(object_mesh(obj)^)))
	return object_show_level(app, obj, start)
}
