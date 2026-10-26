package main

import "core:fmt"
import "core:math"
import "core:time"

import "../sculpt"
import "../ui"

// Deformers (sculpt/deform.odin) from the Object tab's Deformers section: a bend, twist or
// taper of the part the mask leaves free (all that is shown, with no mask), along one of
// the object's own axes over that part's extent. A drag of Amount deforms it live from
// where the drag began and is one undo step when let go; the slider then springs back to
// 0, so every drag is a fresh deformation of the surface as it is, and Adjust last
// operation sets the last one's amount again.

// Which end of the free part stays put.
Deform_End :: enum u8 {
	Auto, // the end nearest the mask's soft edge, where a freed limb joins the rest; the - end with no mask
	Minus,
	Plus,
}

// The section's choices and the drag under way.
Deform_Panel :: struct {
	kind:   sculpt.Deform_Kind,
	along:  sculpt.Axis,
	toward: sculpt.Axis,
	fixed:  Deform_End,
	amount: f32, // the slider, in degrees (Bend, Twist) or percent (Taper); 0 between drags
	drag:   Deform_Drag,
	seen:   Deform_Seen,
	lattice: Lattice_View, // Lattice picked instead of a kind, and its cage (lattice.odin)
	// A drag ended under a pointer still held (a key's command, a scene change): the
	// slider is ignored until the pointer lets go, or the next frame would start a new
	// drag at the same value and deform the result as far again.
	wait_release: bool,
	count:  int, // deformations made, for the exit stats
	last:   sculpt.Deform_Kind, // ...the last one's kind...
	ms:     f64, // ...and its time applying it
}

Deform_Drag :: struct {
	active: bool,
	id:     int, // the object, which the selection may leave meanwhile
	deform: sculpt.Deform, // set when the drag starts; its amount follows the slider
	ms:     f64, // time spent applying it
}

// The free part's bounds, kept until the object, its level or the history changes (every
// mask, hide and vertex change is a step), so the section can say what a drag would do
// without a pass over the mesh every frame.
Deform_Seen :: struct {
	id, level, levels: int,
	serial:            u64,
	lo, hi:            Vec3,
	ok, valid:         bool,
}

@(rodata)
DEFORM_NAMES := [sculpt.Deform_Kind]string {
	.Bend  = "Bend",
	.Twist = "Twist",
	.Taper = "Taper",
}

// The section's choices, the kinds then Lattice, as its tabs and the palette name them.
DEFORMERS :: len(sculpt.Deform_Kind) + 1

deformer_name :: proc(choice: int) -> string {
	return DEFORM_NAMES[sculpt.Deform_Kind(choice)] if choice < len(sculpt.Deform_Kind) else "Lattice"
}

// Picks a kind or, past the kinds, Lattice.
deformer_pick :: proc(app: ^App, choice: int) {
	p := &app.ui.deform
	p.lattice.on = choice >= len(sculpt.Deform_Kind)
	if !p.lattice.on do p.kind = sculpt.Deform_Kind(choice)
}

@(rodata)
DEFORM_DONE := [sculpt.Deform_Kind]string {
	.Bend  = "Bent",
	.Twist = "Twisted",
	.Taper = "Tapered",
}

// A whole turn either way is as far as a twist is worth dragging to in one go; past it
// the slider would only lose precision, and a second drag twists further.
DEFORM_TWIST_MAX :: 360 // degrees
// Four times as wide at the far end: more is a spike, which a second drag can still make.
DEFORM_TAPER_MAX :: 300 // percent

// The free part's bounds in `obj`'s own space, from the cache while it holds.
deform_bounds :: proc(app: ^App, obj: ^Object) -> (lo, hi: Vec3, ok: bool) {
	level := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	c := &app.ui.deform.seen
	if !(c.valid && c.id == obj.id && c.level == level && c.levels == len(obj.levels.levels) && c.serial == app.history.serial) {
		c^ = {id = obj.id, level = level, levels = len(obj.levels.levels), serial = app.history.serial, valid = true}
		c.lo, c.hi, c.ok = sculpt.sculptor_free_bounds(object_sculptor(obj))
	}
	return c.lo, c.hi, c.ok
}

// The axis a bend goes toward when the chosen one is the axis it runs along: the next.
@(private = "file")
deform_toward :: proc(p: ^Deform_Panel) -> sculpt.Axis {
	return p.toward if p.toward != p.along else sculpt.Axis((int(p.along) + 1) % 3)
}

// The slider's value as the deformation's amount: radians, or the far end's scale less 1.
deform_amount_of :: proc(kind: sculpt.Deform_Kind, shown: f32) -> f32 {
	return shown / 100 if kind == .Taper else math.to_radians(shown)
}

// The deformation's amount as the slider shows it.
deform_shown_of :: proc(d: sculpt.Deform) -> f32 {
	return d.amount * 100 if d.kind == .Taper else math.to_degrees(d.amount)
}

// The slider's range for `d`: a bend no further than folds the inside over itself.
deform_range :: proc(d: sculpt.Deform) -> (lo, hi: f32) {
	switch d.kind {
	case .Bend:
		limit := math.to_degrees(sculpt.deform_bend_limit(d))
		return -limit, limit
	case .Twist:
		return -DEFORM_TWIST_MAX, DEFORM_TWIST_MAX
	case .Taper:
		return sculpt.DEFORM_TAPER_MIN * 100, DEFORM_TAPER_MAX
	}
	return
}

// How a deformation is told: "40° along Y toward +X".
deform_text :: proc(d: sculpt.Deform) -> string {
	amount := deform_shown_of(d)
	switch d.kind {
	case .Bend:
		return fmt.tprintf("%.0f° along %v toward %s%v", abs(amount), d.along, "-" if amount < 0 else "+", d.toward)
	case .Twist:
		return fmt.tprintf("%.0f° about %v", amount, d.along)
	case .Taper:
		return fmt.tprintf("%+.0f%% along %v", amount, d.along)
	}
	return ""
}

// The deformation the section's choices make of `obj`'s free part, its amount still 0.
// ok is false (and why is reported) when there is nothing to deform along that axis.
// With `panel` (the section working out the slider's range every frame) it says nothing
// and leaves Auto's end unfound, which takes a pass over the mesh and no range needs.
deform_of :: proc(app: ^App, obj: ^Object, panel := false) -> (d: sculpt.Deform, ok: bool) {
	quiet := panel
	p := &app.ui.deform
	lo, hi, free := deform_bounds(app, obj)
	if !free {
		if !quiet do report(app, Kit_Section.Deformers, {.Warning}, "Nothing is free to deform: the mask covers all that is shown")
		return
	}
	i := int(p.along)
	if !(hi[i] - lo[i] > 1e-6) {
		if !quiet do report(app, Kit_Section.Deformers, {.Warning}, "The free part is flat along %v; pick another axis", p.along)
		return
	}
	d = {kind = p.kind, along = p.along, toward = deform_toward(p), lo = lo, hi = hi}
	switch p.fixed {
	case .Minus: d.from_plus = false
	case .Plus:  d.from_plus = true
	case .Auto:
		if !panel && object_has_mask(app, obj) {
			if edge, found := sculpt.sculptor_mask_centroid(object_sculptor(obj)); found do d.from_plus = abs(edge[i] - hi[i]) < abs(edge[i] - lo[i])
		}
	}
	return d, true
}

// Deforms `obj` by the slider's amount: the first change of a drag starts it (a pose of
// the free part), the rest set it afresh from where it began. A drag still held on
// another object ends first.
deform_drag_to :: proc(app: ^App, obj: ^Object) {
	p := &app.ui.deform
	if p.drag.active && p.drag.id != obj.id do deform_drag_end(app, force = true)
	if !p.wait_release && (p.drag.active || deform_drag_begin(app, obj)) do deform_drag_set(app, obj)
	else do p.amount = 0
}

// Starts a drag of the Amount slider on `obj`: a pose of its free part. False, saying
// why, when it cannot be deformed.
@(private = "file")
deform_drag_begin :: proc(app: ^App, obj: ^Object) -> bool {
	inspector_drags_end(app)
	stroke_finish(app)
	if !deform_allowed(app, obj, quiet = false) do return false
	d := deform_of(app, obj) or_return
	if !sculpt.sculptor_pose_begin(object_sculptor(obj)) {
		report(app, Kit_Section.Deformers, {.Warning}, "Nothing is free to deform: the mask covers all that is shown")
		return false
	}
	app.ui.deform.drag = {active = true, id = obj.id, deform = d}
	return true
}

// Sets the drag's deformation to the slider's amount, from where the drag began.
@(private = "file")
deform_drag_set :: proc(app: ^App, obj: ^Object) {
	drag := &app.ui.deform.drag
	drag.deform.amount = deform_amount_of(drag.deform.kind, app.ui.deform.amount)
	start := time.tick_now()
	sculpt.sculptor_pose_apply(object_sculptor(obj), {kind = .Deform, deform = drag.deform})
	drag.ms += time.duration_milliseconds(time.tick_since(start))
}

// Ends a drag of Amount once the pointer lets go (or at once with `force`, before a
// command, an undo or a scene change changes what it deforms), as one undo step when it
// changed something; the slider springs back to 0. Runs every frame, so a drag ends even
// if its section closed meanwhile.
deform_drag_end :: proc(app: ^App, force := false) {
	p := &app.ui.deform
	held := .Left in app.device.down
	if !held do p.wait_release = false
	if !p.drag.active || (!force && held) do return
	drag := p.drag
	p.drag, p.amount, p.wait_release = {}, 0, held
	obj := object_by_id(app, drag.id)
	if obj == nil do return
	s := object_sculptor(obj)
	if drag.deform.amount == 0 {
		sculpt.sculptor_pose_cancel(s)
		return
	}
	if !sculpt.sculptor_pose_end(s) do return
	deform_done(app, obj, drag.deform, drag.ms)
}

// Records the deformation of `obj` just ended as an undo step, says what it did and
// makes it the operation Adjust last sets again.
@(private = "file")
deform_done :: proc(app: ^App, obj: ^Object, d: sculpt.Deform, ms: f64) {
	history_record(app, obj, .Deform, DEFORM_NAMES[d.kind])
	p := &app.ui.deform
	p.count += 1
	p.last, p.ms = d.kind, ms
	report(app, Kit_Section.Deformers, {.Undo}, "%s %s by %s (%.0f ms)", DEFORM_DONE[d.kind], object_label(obj), deform_text(d), ms)
	adjust_set(app, .Deformer, {}, obj.id)
	if app.adjustable.op == .Deformer do app.adjustable.deform, app.adjustable.sculptor = d, object_sculptor(obj)
}

// Deforms `obj` by `d` at once, as one undo step (Adjust last's re-run). False when it
// changed nothing.
deform_run :: proc(app: ^App, obj: ^Object, d: sculpt.Deform) -> bool {
	s := object_sculptor(obj)
	if d.amount == 0 || !sculpt.sculptor_pose_begin(s) do return false
	start := time.tick_now()
	sculpt.sculptor_pose_apply(s, {kind = .Deform, deform = d})
	ms := time.duration_milliseconds(time.tick_since(start))
	if !sculpt.sculptor_pose_end(s) do return false
	deform_done(app, obj, d, ms)
	return true
}

// Ends the drags held in the inspector (a layer's strength, a deformer's Amount), each as
// its own undo step, before a command, a scene command, a file or an undo changes what
// they act on.
inspector_drags_end :: proc(app: ^App) {
	layer_drag_finish(app)
	deform_drag_end(app, force = true)
}

// Whether `obj` can be deformed: not in an HD window, nor under dynamic topology, whose
// strokes save whole nodes rather than the positions a deformation starts from.
deform_allowed :: proc(app: ^App, obj: ^Object, quiet := true) -> bool {
	if object_in_hd(obj) {
		if !quiet do report(app, Kit_Section.Deformers, {.Warning}, "Deformers need the HD window left first (A)")
		return false
	}
	if object_dynamic(obj) {
		if !quiet do report(app, Kit_Section.Deformers, {.Warning}, "Deformers need dynamic topology off")
		return false
	}
	return true
}

// The Deformers section: the kind, the axis it runs along (for a bend also the axis it
// bends toward), the end that stays, and Amount to drag.
kit_deformers :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	t := ctx.theme
	p := &app.ui.deform
	kinds: [DEFORMERS]string
	for &name, i in kinds do name = deformer_name(i)
	chosen := len(sculpt.Deform_Kind) if p.lattice.on else int(p.kind)
	if picked := ui.tabs(ctx, "deformer", kinds[:], chosen); picked >= 0 && !p.drag.active && app.move.drag.lattice == 0 do deformer_pick(app, picked)
	if p.lattice.on {
		kit_lattice(app)
		kit_last_result(app, .Deformers)
		return
	}
	ui.label(ctx, "About the axis" if p.kind == .Twist else "Along the axis", t.small_size)
	axes := [3]string{"X##along", "Y##along", "Z##along"}
	if picked := ui.tabs(ctx, "deform along", axes[:], int(p.along)); picked >= 0 && !p.drag.active do p.along = sculpt.Axis(picked)
	if p.kind == .Bend {
		// The two axes across the one it runs along.
		ui.label(ctx, "Toward", t.small_size)
		across := [2]sculpt.Axis{sculpt.Axis((int(p.along) + 1) % 3), sculpt.Axis((int(p.along) + 2) % 3)}
		if across[0] > across[1] do across[0], across[1] = across[1], across[0]
		names := [2]string{fmt.tprintf("%v##toward", across[0]), fmt.tprintf("%v##toward", across[1])}
		if picked := ui.tabs(ctx, "deform toward", names[:], 1 if deform_toward(p) == across[1] else 0); picked >= 0 && !p.drag.active do p.toward = across[picked]
	}
	ui.label(ctx, "Fixed end", t.small_size)
	ends := [3]string{"Auto", "- end", "+ end"}
	if picked := ui.tabs(ctx, "deform fixed end", ends[:], int(p.fixed)); picked >= 0 && !p.drag.active do p.fixed = Deform_End(picked)
	can := deform_allowed(app, obj)
	d, ok := deform_of(app, obj, panel = true)
	if p.drag.active do d = p.drag.deform
	lo, hi := deform_range(d)
	if !ok do lo, hi = -1, 1
	unit := "%" if p.kind == .Taper else "°"
	if p.wait_release do p.amount = 0
	if ui.slider(ctx, "Amount##deform", &p.amount, lo, hi, .Linear, fmt.tprintf("%+.0f%s", p.amount, unit), enabled = can && (ok || p.drag.active)) do deform_drag_to(app, obj)
	ui.paragraph(ctx, "Drag Amount to bend, twist or taper the part the mask leaves free (all of it with no mask) along the object's own axis, from the fixed end; Auto keeps the end at the mask's edge. Letting go is one undo step and the slider springs back for the next. Not in HD or with dynamic topology.")
	kit_last_result(app, .Deformers)
}
