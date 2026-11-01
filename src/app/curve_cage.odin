package main

import "core:fmt"
import "core:log"
import "core:math/linalg"

import "../geom"
import "../poly"
import "../ui"

// Model mode cages from a curve, as Nomad's Pipe and Lathe make quad meshes to model:
// Pipe Cage runs rings round the curve, Lathe Cage spins it round its lathe axis (the
// view's vertical when the curve has never been a lathe). Each is a new cage object in
// the curve's place and folder, selected, one undo step; the curve stays, to make another.

// Adds a cage made from `obj`'s curve (a lathe with `lathe`, else a pipe) as a new
// selected object after it, one undo step. Returns false only on a GPU failure.
curve_make_cage :: proc(app: ^App, obj: ^Object, lathe: bool) -> bool {
	cp := obj.curve
	o := app.curve.cage
	cage: poly.Mesh
	err: poly.Build_Error
	if lathe {
		l := cp.lathe
		if cp.use != .Lathe do l = curve_use_look(app, obj, .Lathe).lathe
		cage, err = poly.lathe_cage(cp.points[:], cp.closed, l, o)
	} else {
		cage, err = poly.pipe_cage(cp.points[:], cp.closed, o, curve_up(cp))
	}
	what := "Lathe cage" if lathe else "Pipe cage"
	if err != .None {
		poly.mesh_destroy(&cage)
		report(app, nil, {.Warning}, "%s: the curve makes no cage (%v)", what, err)
		return true
	}
	stroke_finish(app)
	made := new(Object)
	made.transform, made.file, made.folder = obj.transform, {scale = 1}, obj.folder
	if !object_build_cage(app, made, cage) {
		free(made)
		return false
	}
	made.name = fmt.aprintf("%s %d", what, app.scene.next_id + 1)
	scene_append(app, made)
	scene_place_after(app, made, obj)
	history_record_added(app)
	app.curve.cages += 1
	c := poly.mesh_check(&made.cage.mesh)
	log.infof("%s: %d points, %d faces (%d quads)", object_label(made), c.vertices, c.faces, c.quads)
	return true
}

// The way a curve's frames start: its Along up where it was drawn on a surface, else the
// tube's.
@(private = "file")
curve_up :: proc(cp: ^Curve_Part) -> Vec3 {
	if up := linalg.normalize0(cp.along.opts.up); up != {} && up != geom.ALONG_DEFAULTS.up do return up
	return geom.tube_up(cp.points[:])
}

// The cage-from-curve controls: points round a ring, rings between the curve's points,
// caps, and the two buttons.
kit_curve_cage :: proc(app: ^App) {
	ctx := &app.kit.ctx
	o := &app.curve.cage
	ui.caption(ctx, "CAGE FROM CURVE")
	around := f32(o.around)
	if ui.slider(ctx, "Around", &around, 3, 32, .Linear, fmt.tprint(o.around)) do o.around = int(around + 0.5)
	steps := f32(o.steps)
	if ui.slider(ctx, "Steps between points", &steps, 1, 8, .Linear, fmt.tprint(o.steps)) do o.steps = int(steps + 0.5)
	_ = ui.switch_row(ctx, "Cage caps", &o.caps)
	kit_command_pair(app, .Curve_Pipe_Cage, .Curve_Lathe_Cage, label_a = "Pipe cage", label_b = "Lathe cage")
	ui.paragraph(ctx, "In Model mode, Spine and Extrude lifted over a curve grow along it, and a Knife tap on a curve cuts along it. Loop to curve makes a curve from a cage's edge loop.")
	if ui.button(ctx, "Loop to curve", keys = command_hint(app, .Model_Action, int(Model_Action.Loop_Curve))) do command_run(app, .Model_Action, int(Model_Action.Loop_Curve))
}

