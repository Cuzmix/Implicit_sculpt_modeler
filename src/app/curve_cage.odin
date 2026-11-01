package main

import "core:fmt"
import "core:log"
import "core:math/linalg"

import "../geom"
import "../poly"
import "../ui"

// Model mode cages from a curve, as Nomad's Pipe and Lathe make quad meshes to model:
// Pipe Cage runs rings round the curve, Lathe Cage spins it round its lathe axis (the
// view's vertical when the curve has never been a lathe), Loft Cage bridges it and other
// curves. Each is a new cage object in
// the curve's place and folder, selected, one undo step; the curve stays, to make another.

// What a cage from curves is.
Curve_Cage_Kind :: enum u8 {
	Pipe,
	Lathe,
	Loft,
}

// Adds a cage made from `obj`'s curve (a pipe round it, a lathe spun from it, or a loft
// through it and the curves curve_loft_sections finds) as a new selected object after
// it, one undo step. Returns false only on a GPU failure.
curve_make_cage :: proc(app: ^App, obj: ^Object, kind: Curve_Cage_Kind) -> bool {
	cp := obj.curve
	o := app.curve.cage
	cage: poly.Mesh
	err: poly.Build_Error
	names := [Curve_Cage_Kind]string{.Pipe = "Pipe cage", .Lathe = "Lathe cage", .Loft = "Loft cage"}
	what := names[kind]
	switch kind {
	case .Lathe:
		l := cp.lathe
		if cp.use != .Lathe do l = curve_use_look(app, obj, .Lathe).lathe
		cage, err = poly.lathe_cage(cp.points[:], cp.closed, l, o)
	case .Pipe:
		cage, err = poly.pipe_cage(cp.points[:], cp.closed, o, curve_up(cp))
	case .Loft:
		curves, why := curve_loft_sections(app)
		if why != "" {
			report(app, nil, {.Warning}, "%s: %s", what, why)
			return true
		}
		// Every section in the first curve's space, which the cage takes as its own.
		t := curves[0].transform
		sections := make([][]geom.Bezier_Point, len(curves), context.temp_allocator)
		for c, i in curves {
			ct := c.transform
			scale := ct.scale / t.scale
			sections[i] = make([]geom.Bezier_Point, len(c.curve.points), context.temp_allocator)
			for p, k in c.curve.points {
				q := p
				q.p = to_local(t, to_world(ct, p.p))
				q.h_in = to_local_dir(t, to_world_dir(ct, p.h_in)) * scale
				q.h_out = to_local_dir(t, to_world_dir(ct, p.h_out)) * scale
				sections[i][k] = q
			}
		}
		cage, err = poly.loft_cage(sections, cp.closed, o)
	}
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
	if kind == .Loft do app.curve.lofts += 1
	c := poly.mesh_check(&made.cage.mesh)
	log.infof("%s: %d points, %d faces (%d quads)", object_label(made), c.vertices, c.faces, c.quads)
	return true
}

// The curves a loft runs through, the selected one first and each next the nearest left
// by the middle of its points (scene order breaking ties): the selected curves when two
// or more are selected, else the selected curve and every other shown, unlocked Line
// curve as open or closed as it. At most poly.LOFT_SECTIONS_MAX, the nearest. In temp
// memory; why it cannot loft, or "".
curve_loft_sections :: proc(app: ^App) -> (curves: []^Object, why: string) {
	first := selected_curve(app)
	if first == nil do return nil, "select a curve"
	left := make([dynamic]^Object, context.temp_allocator)
	for id in selection_ids(app)[1:] {
		if obj := object_by_id(app, id); obj != nil && obj.curve != nil do append(&left, obj)
	}
	if len(left) == 0 {
		for obj in app.scene.objects {
			// Only curves that can loft with the selected one: a loop elsewhere does not stop
			// open curves lofting.
			if obj == first || obj.curve == nil || obj.curve.use != .None || !object_shown(app, obj) || obj.locked || obj.curve.closed != first.curve.closed do continue
			append(&left, obj)
		}
	}
	if len(left) == 0 do return nil, "draw or select a second curve to loft to"
	middle :: proc(obj: ^Object) -> Vec3 {
		sum: Vec3
		for p in obj.curve.points do sum += to_world(obj.transform, p.p)
		return sum / f32(max(len(obj.curve.points), 1))
	}
	out := make([dynamic]^Object, 0, len(left) + 1, context.temp_allocator)
	append(&out, first)
	for len(left) > 0 && len(out) < poly.LOFT_SECTIONS_MAX {
		at := middle(out[len(out) - 1])
		best, nearest := max(f32), 0
		for c, i in left do if d := linalg.length2(middle(c) - at); d < best do best, nearest = d, i
		append(&out, left[nearest])
		ordered_remove(&left, nearest)
	}
	for c in out do if c.curve.closed != first.curve.closed do return nil, "the curves must all be closed, or all open"
	return out[:], ""
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
	if ui.button(ctx, "Loft cage", keys = command_hint(app, .Curve_Loft_Cage), enabled = command_enabled(app, .Curve_Loft_Cage)) do command_run(app, .Curve_Loft_Cage)
	ui.paragraph(ctx, "In Model mode, Spine and Extrude lifted over a curve grow along it, and a Knife tap on a curve cuts along it. Loop to curve makes a curve from a cage's edge loop.")
	if ui.button(ctx, "Loop to curve", keys = command_hint(app, .Model_Action, int(Model_Action.Loop_Curve))) do command_run(app, .Model_Action, int(Model_Action.Loop_Curve))
}

