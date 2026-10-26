package main

import "core:fmt"
import "core:math"

import "../sculpt"
import "../ui"

// Adjust last operation, as Blender has it: after a remesh, decimate, mirror and weld,
// retopology, extract or smooth all, its settings stay at hand over the dock, and a change
// runs it again from the state before it rather than on its own result, since a remesh
// of a remesh loses detail and Decimate to 200k after Decimate to 500k is not Decimate to
// 200k. A re-run takes the operation's undo step back and records its own, so the History
// holds one entry for it however many values were tried.
//
// A stroke is adjusted another way, as ZBrush's Adjust Last: its amount, from nothing to
// half as much again, is set in place on its own undo step (sculpt.sculptor_stroke_adjust),
// cheaply enough to follow a slider as it is dragged. It has no action bar group, which
// would show after every stroke: the Stroke section's More has it, and so do the palette
// and any key given to Adjust last operation.

Adjust_Op :: enum u8 {
	None,
	Remesh,
	Decimate,
	Mirror,
	Retopo,
	Extract,
	Smooth_All,
	Stroke,
}

// The most Adjust last stroke sets a stroke to: half as much again as drawn.
ADJUST_STROKE_MAX :: f32(1.5)

@(rodata)
ADJUST_NAMES := [Adjust_Op]string {
	.None       = "",
	.Remesh     = "Remesh",
	.Decimate   = "Decimate",
	.Mirror     = "Mirror",
	.Retopo     = "Retopology",
	.Extract    = "Extract",
	.Smooth_All = "Smooth all",
	.Stroke     = "last stroke",
}

// The inspector section whose settings each operation takes.
@(rodata)
ADJUST_SECTIONS := [Adjust_Op]Kit_Section {
	.None       = .Remesh,
	.Remesh     = .Remesh,
	.Decimate   = .Remesh,
	.Mirror     = .Mirror,
	.Retopo     = .Retopo,
	.Extract    = .Extract,
	.Smooth_All = .Deform,
	.Stroke     = .Stroke,
}

// The last operation that can be adjusted and what it ran with, and what tells whether
// it still can: everything an undo of its step would take back with it must be as the
// operation left it (adjust_live).
Adjustable :: struct {
	op:        Adjust_Op,
	cmd:       Scene_Command, // a scene command's own settings (Remesh, Decimate, Mirror, Retopo)
	steps:     i32, // Smooth all's steps...
	amount:    f32, // ...and strength, or Extract's thickness, or the stroke's amount (1 as drawn)
	sculptor:  ^sculpt.Sculptor, // a stroke's: the level or HD window it was laid on, only compared
	source:    int, // the object it ran on
	result:    int, // the object it left selected: the source, or the one it made
	mark:      Undo_Mark, // its undo step
	serial:    u64, // history.serial after it, which any step, undo, redo or forgetting moves
	edits:     u64, // scene_edits after it
	transform: Transform, // the result's, which undoing a rebuild would put back
	boolean:   Boolean_Mode, // ...and its boolean mode, the same
	adjusts:   int, // re-runs this session, for the exit stats
}

// The operation a scene command is, if it can be adjusted.
adjust_op_of :: proc(kind: type_of(Scene_Command{}.kind)) -> Adjust_Op {
	#partial switch kind {
	case .Remesh:     return .Remesh
	case .Decimate:   return .Decimate
	case .Symmetrize: return .Mirror
	case .Retopo:     return .Retopo
	case .Extract:    return .Extract
	}
	return .None
}

// Remembers `op`, which just recorded the newest undo step on object `source` and left
// the selected object as its result.
adjust_set :: proc(app: ^App, op: Adjust_Op, cmd: Scene_Command, source: int) {
	obj := selected_object(app)
	mark, ok := undo_mark(app.history.done[:]).?
	a := &app.adjustable
	if obj == nil || !ok {
		a.op = .None
		return
	}
	a^ = {
		op        = op,
		cmd       = cmd,
		steps     = app.ui.smooth_steps,
		amount    = app.ui.boolean.thickness if op == .Extract else app.ui.smooth_strength,
		source    = source,
		result    = obj.id,
		mark      = mark,
		serial    = app.history.serial,
		edits     = app.scene_edits,
		transform = obj.transform,
		boolean   = obj.boolean,
		adjusts   = a.adjusts,
	}
	a.cmd.adjust = false
}

// Whether the last operation can still be adjusted: its step is the newest with nothing
// undone or changed since (a stroke, a mask, leaving HD, a scrub of the History), and
// its result is selected, unmoved and in the same boolean mode.
adjust_live :: proc(app: ^App) -> bool {
	a := &app.adjustable
	if a.op == .None || app.stroke.active || timeline_busy(app) do return false
	if len(app.history.undone) > 0 || app.history.serial != a.serial || app.scene_edits != a.edits do return false
	if !undo_mark_on_top(app.history.done[:], a.mark) do return false
	obj := selected_object(app)
	if obj == nil || obj.id != a.result || obj.transform != a.transform || obj.boolean != a.boolean do return false
	// A stroke adjusts on the level or HD window it was laid on, while that is the one shown.
	return a.op != .Stroke || (object_sculptor(obj) == a.sculptor && sculpt.sculptor_can_adjust(a.sculptor))
}

// Makes the stroke just recorded on `obj` the one to adjust, when its step can be.
adjust_set_stroke :: proc(app: ^App, obj: ^Object) {
	s := object_sculptor(obj)
	mark, ok := undo_mark(app.history.done[:]).?
	a := &app.adjustable
	if !ok || !sculpt.sculptor_can_adjust(s) {
		a.op = .None
		return
	}
	a^ = {
		op        = .Stroke,
		amount    = 1,
		source    = obj.id,
		result    = obj.id,
		mark      = mark,
		serial    = app.history.serial,
		edits     = app.scene_edits,
		transform = obj.transform,
		boolean   = obj.boolean,
		sculptor  = s,
		adjusts   = a.adjusts,
	}
}

// Sets the last stroke to `amount` of itself as drawn, in place on its undo step, and
// notes it on the History's newest entry. False when it can no longer be adjusted.
adjust_stroke :: proc(app: ^App, amount: f32) -> bool {
	a := &app.adjustable
	if !adjust_live(app) || a.op != .Stroke do return false
	k := clamp(amount, 0, ADJUST_STROKE_MAX)
	if !sculpt.sculptor_stroke_adjust(a.sculptor, k) do return false
	a.amount = k
	a.adjusts += 1
	// A stroke not as drawn no longer ends where the next one would join it.
	if k != 1 do app.stroke_end.valid = false
	e := &app.history.done[len(app.history.done) - 1]
	e.adjusted, e.amount = true, k
	// What the mask and the autosave read changed, so the History counts it as a change;
	// the adjust stays live through it.
	app.history.serial += 1
	if e.level != HD_LEVEL do app.history.edits += 1
	a.serial = app.history.serial
	return true
}

// The live operation, or none.
adjust_op_now :: proc(app: ^App) -> Adjust_Op {
	return app.adjustable.op if adjust_live(app) else .None
}

// Takes the operation's step back and selects the object it ran on, ready to run it
// again; with a stroke still going it is finished first, which ends the adjust. False
// (with a warning) when `op` is no longer the one to adjust.
adjust_begin :: proc(app: ^App, op: Adjust_Op) -> bool {
	stroke_finish(app)
	if !adjust_live(app) || app.adjustable.op != op {
		report(app, nil, {.Warning}, "Nothing to adjust: the %s is no longer the last step", ADJUST_NAMES[op])
		return false
	}
	history_undo(app)
	object_select_id(app, app.adjustable.source)
	app.adjustable.adjusts += 1
	return true
}

// After a re-run that recorded nothing (it changed nothing with those settings, or
// refused them), puts the earlier result back, which is still the one to adjust.
adjust_unchanged :: proc(app: ^App) {
	a := &app.adjustable
	history_redo(app)
	object_select_id(app, a.result)
	a.serial, a.edits = app.history.serial, app.scene_edits
	report(app, ADJUST_SECTIONS[a.op], {.Warning}, "%s changed nothing with those settings, so the earlier result stays", ADJUST_NAMES[a.op])
}

// Runs Smooth all again from before it, with the Deformation section's steps and strength.
smooth_adjust :: proc(app: ^App) {
	if !adjust_begin(app, .Smooth_All) do return
	serial := app.history.serial
	smooth_command(app, int(app.ui.smooth_steps))
	if app.history.serial == serial do adjust_unchanged(app)
}

object_select_id :: proc(app: ^App, id: int) {
	for obj, i in app.scene.objects do if obj.id == id do app.scene.selected = i
}

// Opens the adjust popover with the section's settings put back to what the operation
// ran with, so that the two agree.
adjust_open :: proc(app: ^App) {
	a := &app.adjustable
	#partial switch a.op {
	case .Mirror:
		app.ui.mirror_axis, app.ui.mirror_negative = i32(a.cmd.axis), !a.cmd.on
	case .Remesh:
		app.ui.rebuild_even = rebuild_count(a.cmd.vertices)
	case .Decimate:
		app.ui.rebuild_fewer = rebuild_count(a.cmd.vertices)
	case .Retopo:
		app.ui.retopo_quads = i32(a.cmd.vertices)
	case .Smooth_All:
		app.ui.smooth_steps, app.ui.smooth_strength = a.steps, a.amount
	case .Extract:
		app.ui.boolean.thickness = a.amount
	}
	k := &app.kit
	kit_floats_close(k)
	k.adjust_pop, k.adjust_dirty = true, false
	// The popover says what the operation did, under the toast that said it first.
	if k.undo_toast.serial != 0 do ui.toast_dismiss(&k.ctx, k.undo_toast.serial)
}

// Runs the live operation again with the section's settings (and `vertices` for Remesh
// and Decimate): a scene command at the next frame's start, or Smooth all at once, as
// its button does.
@(private = "file")
adjust_post :: proc(app: ^App, vertices := 0) {
	a := &app.adjustable
	switch a.op {
	case .None:
	case .Remesh, .Decimate:
		app.ui.scene_command = {kind = a.cmd.kind, vertices = vertices, adjust = true}
	case .Mirror:
		app.ui.scene_command = {kind = .Symmetrize, axis = int(app.ui.mirror_axis), on = !app.ui.mirror_negative, adjust = true}
	case .Retopo:
		app.ui.scene_command = {kind = .Retopo, vertices = int(app.ui.retopo_quads), adjust = true}
	case .Extract:
		app.ui.scene_command = {kind = .Extract, adjust = true}
	case .Smooth_All:
		smooth_adjust(app)
	case .Stroke:
		// It follows the slider as it moves (kit_adjust_popover); nothing runs again.
	}
}

// The adjust popover: the operation's own settings, laid out as its section has them,
// above the action bar's Adjust button (or above the dock when the bar is hidden). A
// pick re-runs it at once; a slider re-runs it when let go, since at 10M a run takes
// seconds. It stays open to try one value after another.
kit_adjust_popover :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	// A re-run waiting for the next frame is still the adjust's own.
	if !adjust_live(app) && !app.ui.scene_command.adjust do k.adjust_pop = false
	if !k.adjust_pop do return
	a := &app.adjustable
	anchor := k.adjust_anchor
	if anchor == {} {
		area := ui.safe_area(ctx)
		anchor = {area.x + area.w * 0.5 - 1, area.y + area.h - t.edge - dock_stack(app), 2, 1}
	}
	if !ui.popover_begin(ctx, "adjust last", &k.adjust_pop, anchor, .Above_Center, {direction = .Column, gap = 6, padding = 10, width = 300}) do return
	ui.label(ctx, fmt.tprintf("Adjust %s", ADJUST_NAMES[a.op]), t.small_size)
	// What it did and the note go above the controls, so that a longer line grows the
	// popover upward and the controls stay where the thumb is, just over the bar.
	if a.op == .Stroke {
		ui.paragraph(ctx, "How much of the stroke stays: 0% takes it away, 100% is as drawn. It stays one undo step.")
	} else {
		if r, ok := result_for(app, ADJUST_SECTIONS[a.op]); ok do ui.paragraph(ctx, fmt.tprintf("Last: %s.", r.text))
		ui.paragraph(ctx, "A change runs it again from before it, as one undo step.")
	}
	switch a.op {
	case .None:
	case .Stroke:
		_ = kit_stroke_amount(app, "Amount##adjust")
	case .Remesh, .Decimate:
		if !is_size_preset(a.cmd.vertices) do ui.paragraph(ctx, fmt.tprintf("It ran at %s vertices.", thousands(a.cmd.vertices)))
		names: [len(SPHERE_PRESETS)]string
		chosen := -1
		for p, i in SPHERE_PRESETS {
			names[i] = fmt.tprintf("%s", p.label)
			if int(p.vertices) == a.cmd.vertices do chosen = i
		}
		if picked := ui.tabs(ctx, "adjust size", names[:], chosen); picked >= 0 && picked != chosen {
			k.add_size = picked
			n := int(SPHERE_PRESETS[picked].vertices)
			if a.op == .Remesh do app.ui.rebuild_even = rebuild_count(n)
			if a.op == .Decimate do app.ui.rebuild_fewer = rebuild_count(n)
			adjust_post(app, n)
		}
	case .Mirror:
		axes := [3]string{"X##adjust", "Y##adjust", "Z##adjust"}
		if picked := ui.tabs(ctx, "adjust axis", axes[:], int(app.ui.mirror_axis)); picked >= 0 && picked != int(app.ui.mirror_axis) {
			app.ui.mirror_axis = i32(picked)
			adjust_post(app)
		}
		sides := [2]string{"Keep the + side", "Keep the - side"}
		side := int(app.ui.mirror_negative)
		if picked := ui.tabs(ctx, "adjust side", sides[:], side); picked >= 0 && picked != side {
			app.ui.mirror_negative = picked == 1
			adjust_post(app)
		}
	case .Retopo:
		if kit_count(ctx, "Quads##adjust", &app.ui.retopo_quads, 100, 1_000_000) do k.adjust_dirty = true
	case .Extract:
		if ui.slider(ctx, "Thickness##adjust", &app.ui.boolean.thickness, 0.002, 0.2, .Logarithmic, fmt.tprintf("%.3f", app.ui.boolean.thickness)) do k.adjust_dirty = true
	case .Smooth_All:
		steps := f32(app.ui.smooth_steps)
		if ui.slider(ctx, "Steps##adjust", &steps, 1, 100, .Logarithmic, fmt.tprintf("%d", app.ui.smooth_steps)) {
			app.ui.smooth_steps = i32(math.round(steps))
			k.adjust_dirty = true
		}
		if ui.slider(ctx, "Strength##adjust", &app.ui.smooth_strength, 0.05, 1, .Linear, fmt.tprintf("%.2f", app.ui.smooth_strength)) do k.adjust_dirty = true
	}
	// A slider runs it once let go, not on every frame of the drag.
	if k.adjust_dirty && .Left not_in ctx.input.down {
		k.adjust_dirty = false
		adjust_post(app)
	}
	ui.popover_end(ctx)
}

// Whether `vertices` is one of the sizes the popover's tabs offer.
@(private = "file")
is_size_preset :: proc(vertices: int) -> bool {
	for p in SPHERE_PRESETS do if int(p.vertices) == vertices do return true
	return false
}

// The last stroke's amount as a slider, from 0% to ADJUST_STROKE_MAX, following it as it
// is dragged; greyed at 100% when no stroke can be adjusted. True when it changed it.
kit_stroke_amount :: proc(app: ^App, name: string) -> bool {
	ctx := &app.kit.ctx
	live := adjust_live(app) && app.adjustable.op == .Stroke
	amount := app.adjustable.amount if live else 1
	if !ui.slider(ctx, name, &amount, 0, ADJUST_STROKE_MAX, .Linear, fmt.tprintf("%.0f%%", amount * 100), enabled = live) do return false
	return adjust_stroke(app, amount)
}
