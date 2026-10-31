package main

import "core:fmt"
import "core:math"
import "core:time"

import "../sculpt"
import "../ui"

// The Object palette's Deformation section: one slider for each of ZBrush's Deformation
// operations, with Blender's mesh transforms and filters and Nomad's live filters as the
// other half. Pick what it does (Offset, Rotate, Size, Skew, S bend, Squeeze, Noise,
// Inflate, Spherize, Gravity, Polish or Relax), the axes it works along where it has any,
// and drag Amount: the part the mask leaves free (all that is shown, with no mask) takes
// it live, as a pose (sculpt/reshape.odin), and letting go is one undo step, after which
// the slider springs back to 0 for the next. Polish and Relax go over the surface's
// neighbours a number of times, so they run once, when the slider is let go, with that
// many steps. Repeat on the others gives every other shown object the last one, each over
// its own free part, as one undo step. Smooth all keeps its place in the section.

Reshape_Choice :: enum u8 {
	Offset,
	Rotate,
	Size,
	Skew,
	S_Bend,
	Squeeze,
	Noise,
	Inflate,
	Spherize,
	Gravity,
	Polish,
	Relax,
}

@(rodata)
RESHAPE_NAMES := [Reshape_Choice]string {
	.Offset   = "Offset",
	.Rotate   = "Rotate",
	.Size     = "Size",
	.Skew     = "Skew",
	.S_Bend   = "S bend",
	.Squeeze  = "Squeeze",
	.Noise    = "Noise",
	.Inflate  = "Inflate",
	.Spherize = "Spherize",
	.Gravity  = "Gravity",
	.Polish   = "Polish",
	.Relax    = "Relax",
}

@(rodata)
RESHAPE_DONE := [Reshape_Choice]string {
	.Offset   = "Offset",
	.Rotate   = "Rotated",
	.Size     = "Sized",
	.Skew     = "Skewed",
	.S_Bend   = "S-bent",
	.Squeeze  = "Squeezed",
	.Noise    = "Roughened",
	.Inflate  = "Inflated",
	.Spherize = "Spherized",
	.Gravity  = "Sagged",
	.Polish   = "Polished",
	.Relax    = "Relaxed",
}

// What each does, for the line under the slider.
@(rodata)
RESHAPE_HELP := [Reshape_Choice]string {
	.Offset   = "Moves the free part along the axes by a share of its size.",
	.Rotate   = "Turns the free part about its middle, about each axis in turn.",
	.Size     = "Scales the free part about its middle along the axes.",
	.Skew     = "Leans the free part along the axis, the more the higher it is (along X for Y).",
	.S_Bend   = "Waves the free part along the axis once each way, an S over its height.",
	.Squeeze  = "Pinches the middle of the free part across the axis; the other way bulges it.",
	.Noise    = "Roughens the surface in and out along its normals, smooth bumps an eighth of the size across.",
	.Inflate  = "Pushes the surface out along its normals, or in the other way.",
	.Spherize = "Rounds the free part toward a ball as wide as it is.",
	.Gravity  = "Sags the outer parts down the axis, the further out the more, as a soft drape.",
	.Polish   = "Smooths the roughness away and keeps the size, which Smooth shrinks; the amount is the steps.",
	.Relax    = "Evens out the spacing of the vertices over the surface and keeps its shape; the amount is the steps.",
}

// Polish and Relax go once over the surface for each step, up to this many in one go.
RESHAPE_STEPS_MAX :: 20

Reshape_Panel :: struct {
	choice:  Reshape_Choice,
	axes:    [Reshape_Choice]bit_set[sculpt.Axis], // each kind's own, kept as the kinds change
	amount:  f32, // the slider: percent, degrees or steps; 0 between drags
	drag:    Reshape_Drag,
	wait_release: bool, // as the Deformers' Amount: a drag ended under a held pointer
	last:    Reshape_Last,
	count:   int, // reshapes made, for the exit stats
	ms:      f64, // the last one's time applying it
}

Reshape_Drag :: struct {
	active:  bool,
	id:      int, // the object, which the selection may leave meanwhile
	choice:  Reshape_Choice,
	reshape: sculpt.Reshape, // a pose's: set when the drag starts, its amount following the slider
	posed:   bool, // a pose is under way (Polish and Relax wait for the release instead)
	ms:      f64,
}

// The last reshape, for Repeat on the others.
Reshape_Last :: struct {
	valid:  bool,
	choice: Reshape_Choice,
	axes:   bit_set[sculpt.Axis],
	amount: f32, // as the slider showed it
}

// The axes each kind starts with: up for those that move or sag, X for those that lean,
// all three for Size.
reshape_panel_default :: proc() -> (p: Reshape_Panel) {
	for c in Reshape_Choice do p.axes[c] = {.Y}
	p.axes[.Size] = {.X, .Y, .Z}
	p.axes[.Skew] = {.X}
	p.axes[.S_Bend] = {.X}
	return
}

// The pose kind of a choice; ok is false for Polish and Relax.
reshape_kind :: proc(c: Reshape_Choice) -> (kind: sculpt.Reshape_Kind, ok: bool) {
	if c >= .Polish do return
	return sculpt.Reshape_Kind(c), true
}

// Whether a choice takes axes, and only one of them.
reshape_choice_axes :: proc(c: Reshape_Choice) -> (has, one: bool) {
	kind, posed := reshape_kind(c)
	if !posed do return
	return sculpt.reshape_has_axes(kind), sculpt.reshape_one_axis(kind)
}

// The slider's range and unit for a choice.
reshape_range :: proc(c: Reshape_Choice) -> (lo, hi: f32, unit: string) {
	switch c {
	case .Rotate:   return -180, 180, "°"
	case .Skew:     return -math.to_degrees(f32(sculpt.RESHAPE_SKEW_MAX)), math.to_degrees(f32(sculpt.RESHAPE_SKEW_MAX)), "°"
	case .Size:     return sculpt.RESHAPE_SIZE_MIN * 100, 200, "%"
	case .Spherize: return 0, 100, "%"
	case .Polish, .Relax: return 0, RESHAPE_STEPS_MAX, " steps"
	case .Offset, .S_Bend, .Squeeze, .Noise, .Inflate, .Gravity:
	}
	return -100, 100, "%"
}

// The slider's value as the pose's amount: radians for the turns, a share for the rest.
reshape_amount_of :: proc(c: Reshape_Choice, shown: f32) -> f32 {
	#partial switch c {
	case .Rotate, .Skew: return math.to_radians(shown)
	}
	return shown / 100
}

// How a reshape is told: "Rotate 30° about Y", "Polish, 5 steps".
reshape_text :: proc(c: Reshape_Choice, axes: bit_set[sculpt.Axis], shown: f32) -> string {
	_, _, unit := reshape_range(c)
	if c >= .Polish do return fmt.tprintf("%s, %d steps", RESHAPE_NAMES[c], int(shown + 0.5))
	has, _ := reshape_choice_axes(c)
	if !has do return fmt.tprintf("%s %+.0f%s", RESHAPE_NAMES[c], shown, unit)
	names := ""
	for a in sculpt.Axis do if a in axes do names = fmt.tprintf("%s%v", names, a)
	return fmt.tprintf("%s %+.0f%s along %s", RESHAPE_NAMES[c], shown, unit, names)
}

// The axes a choice works along as the panel has them: one kind's lowest, if it takes one.
@(private = "file")
reshape_axes :: proc(p: ^Reshape_Panel, c: Reshape_Choice) -> bit_set[sculpt.Axis] {
	axes := p.axes[c]
	if _, one := reshape_choice_axes(c); one {
		for a in sculpt.Axis do if a in axes do return {a}
	}
	return axes
}

// Follows the slider on `obj`: the first change of a drag starts it, the rest set a
// pose afresh from where it began. A drag still held on another object ends first.
reshape_drag_to :: proc(app: ^App, obj: ^Object) {
	p := &app.ui.reshape
	if p.drag.active && p.drag.id != obj.id do reshape_drag_end(app, force = true)
	if p.wait_release || !(p.drag.active || reshape_drag_begin(app, obj)) {
		p.amount = 0
		return
	}
	drag := &p.drag
	if !drag.posed do return
	drag.reshape.amount = reshape_amount_of(drag.choice, p.amount)
	start := time.tick_now()
	sculpt.sculptor_pose_apply(object_sculptor(obj), {kind = .Reshape, reshape = drag.reshape})
	drag.ms += time.duration_milliseconds(time.tick_since(start))
}

// Starts a drag of Amount on `obj`. False, saying why, when it cannot be reshaped.
@(private = "file")
reshape_drag_begin :: proc(app: ^App, obj: ^Object) -> bool {
	inspector_drags_end(app)
	stroke_finish(app)
	p := &app.ui.reshape
	if !reshape_allowed(app, obj, quiet = false) do return false
	drag := Reshape_Drag{active = true, id = obj.id, choice = p.choice}
	if kind, posed := reshape_kind(p.choice); posed {
		r, ok := reshape_of(app, obj, kind, reshape_axes(p, p.choice))
		if !ok do return false
		if !sculpt.sculptor_pose_begin(object_sculptor(obj)) {
			report(app, Kit_Section.Deform, {.Warning}, "Nothing is free to reshape: the mask covers all that is shown")
			return false
		}
		drag.reshape, drag.posed = r, true
	}
	p.drag = drag
	return true
}

// The reshape of `obj`'s free part along `axes`, its amount still 0; ok is false, saying
// why, when nothing is free.
@(private = "file")
reshape_of :: proc(app: ^App, obj: ^Object, kind: sculpt.Reshape_Kind, axes: bit_set[sculpt.Axis], quiet := false) -> (r: sculpt.Reshape, ok: bool) {
	lo, hi, free := deform_bounds(app, obj)
	if !free {
		if !quiet do report(app, Kit_Section.Deform, {.Warning}, "Nothing is free to reshape: the mask covers all that is shown")
		return
	}
	if sculpt.reshape_has_axes(kind) && card(axes) == 0 {
		if !quiet do report(app, Kit_Section.Deform, {.Warning}, "Pick an axis for %s", RESHAPE_NAMES[Reshape_Choice(kind)])
		return
	}
	return {kind = kind, axes = axes, lo = lo, hi = hi}, true
}

// Ends a drag of Amount once the pointer lets go (or at once with `force`), as one undo
// step when it changed something; Polish and Relax run here. The slider springs back to
// 0. Runs every frame, so a drag ends even if its section closed meanwhile.
reshape_drag_end :: proc(app: ^App, force := false) {
	p := &app.ui.reshape
	held := .Left in app.device.down
	if !held do p.wait_release = false
	if !p.drag.active || (!force && held) do return
	drag, shown := p.drag, p.amount
	p.drag, p.amount, p.wait_release = {}, 0, held
	obj := object_by_id(app, drag.id)
	if obj == nil do return
	s := object_sculptor(obj)
	if !drag.posed {
		steps := int(shown + 0.5)
		if steps > 0 do _ = reshape_smooth(app, obj, drag.choice, steps, chain = false)
		return
	}
	if drag.reshape.amount == 0 {
		sculpt.sculptor_pose_cancel(s)
		return
	}
	if !sculpt.sculptor_pose_end(s) do return
	reshape_done(app, obj, drag.choice, drag.reshape.axes, shown, drag.ms, chain = false)
}

// Polishes or relaxes `obj` by `steps` as one undo step (chained to the one before with
// `chain`). False when nothing moved.
@(private = "file")
reshape_smooth :: proc(app: ^App, obj: ^Object, c: Reshape_Choice, steps: int, chain: bool) -> bool {
	start := time.tick_now()
	mode := sculpt.Smooth_Mode.Polish if c == .Polish else .Relax
	changed, _ := sculpt.sculptor_smooth_all(object_sculptor(obj), steps, 1, mode = mode)
	if !changed do return false
	reshape_done(app, obj, c, {}, f32(steps), time.duration_milliseconds(time.tick_since(start)), chain)
	return true
}

// Records a reshape of `obj` just made as an undo step, says what it did and keeps it for
// Repeat on the others.
@(private = "file")
reshape_done :: proc(app: ^App, obj: ^Object, c: Reshape_Choice, axes: bit_set[sculpt.Axis], shown: f32, ms: f64, chain: bool) {
	history_record(app, obj, .Deform, RESHAPE_NAMES[c], chain = chain)
	p := &app.ui.reshape
	p.count += 1
	p.ms = ms
	p.last = {valid = true, choice = c, axes = axes, amount = shown}
	if !chain do report(app, Kit_Section.Deform, {.Undo}, "%s %s: %s (%.0f ms)", RESHAPE_DONE[c], object_label(obj), reshape_text(c, axes, shown), ms)
}

// Gives every other shown object that can take it the last reshape, each over its own
// free part, as one undo step with them all. Returns how many changed.
reshape_repeat :: proc(app: ^App) -> int {
	p := &app.ui.reshape
	if !p.last.valid do return 0
	inspector_drags_end(app)
	stroke_finish(app)
	last := p.last
	selected := selected_object(app)
	done := 0
	for obj in app.scene.objects {
		if obj == selected || !object_shown(app, obj) || !reshape_allowed(app, obj) do continue
		if kind, posed := reshape_kind(last.choice); posed {
			r, ok := reshape_of(app, obj, kind, last.axes, quiet = true)
			s := object_sculptor(obj)
			if !ok || !sculpt.sculptor_pose_begin(s) do continue
			r.amount = reshape_amount_of(last.choice, last.amount)
			sculpt.sculptor_pose_apply(s, {kind = .Reshape, reshape = r})
			if !sculpt.sculptor_pose_end(s) do continue
			reshape_done(app, obj, last.choice, last.axes, last.amount, 0, chain = done > 0)
		} else if !reshape_smooth(app, obj, last.choice, int(last.amount + 0.5), chain = done > 0) {
			continue
		}
		done += 1
	}
	p.last = last
	if done == 0 {
		report(app, Kit_Section.Deform, {.Warning}, "No other shown object could take %s", reshape_text(last.choice, last.axes, last.amount))
	} else {
		report(app, Kit_Section.Deform, {.Undo}, "%s on %d other object%s", reshape_text(last.choice, last.axes, last.amount), done, "" if done == 1 else "s")
	}
	return done
}

// Whether `obj` can be reshaped: a mesh, not in an HD window nor under dynamic topology,
// as the Deformers.
reshape_allowed :: proc(app: ^App, obj: ^Object, quiet := true) -> bool {
	if obj.voxel != nil {
		if !quiet do report(app, Kit_Section.Deform, {.Warning}, "Deformation needs a mesh: convert the clay first (Object palette, Voxels)")
		return false
	}
	if object_in_hd(obj) {
		if !quiet do report(app, Kit_Section.Deform, {.Warning}, "Deformation needs the HD window left first (A)")
		return false
	}
	if object_dynamic(obj) {
		if !quiet do report(app, Kit_Section.Deform, {.Warning}, "Deformation needs dynamic topology off")
		return false
	}
	return true
}

// The Deformation section: what it does, its axes, Amount; under More, Repeat on the
// others and Smooth all with its steps.
kit_deformation :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	p := &app.ui.reshape
	names: [len(Reshape_Choice)]string
	for c in Reshape_Choice do names[c] = RESHAPE_NAMES[c]
	if picked := ui.select(ctx, "deformation kind", names[:], int(p.choice)); picked >= 0 && !p.drag.active do p.choice = Reshape_Choice(picked)
	c := p.choice
	if has, one := reshape_choice_axes(c); has {
		ui.begin(ctx, "deformation axes", {direction = .Row, gap = 4})
		axes := reshape_axes(p, c)
		for a in sculpt.Axis {
			if ui.toggle_button(ctx, fmt.tprintf("%v##deformation", a), a in axes, 92) && !p.drag.active {
				switch {
				case one:         p.axes[c] = {a}
				case a in axes:   p.axes[c] -= {a}
				case:             p.axes[c] += {a}
				}
			}
		}
		ui.end(ctx)
	}
	can := reshape_allowed(app, obj)
	lo, hi, unit := reshape_range(c)
	if p.wait_release do p.amount = 0
	shown := fmt.tprintf("%d%s", int(p.amount + 0.5), unit) if c >= .Polish else fmt.tprintf("%+.0f%s", p.amount, unit)
	if ui.slider(ctx, "Amount##deformation", &p.amount, lo, hi, .Linear, shown, enabled = can) do reshape_drag_to(app, obj)
	when_let_go := " It runs when the slider is let go." if c >= .Polish else ""
	ui.paragraph(ctx, fmt.tprintf("%s%s The mask holds back what it covers; letting go is one undo step and the slider springs back. Not in HD or with dynamic topology.", RESHAPE_HELP[c], when_let_go))
	if kit_more(app, .Deform) {
		_ = command_button(app, .Reshape_Repeat)
		dyn := object_dynamic(obj)
		_ = command_button(app, .Smooth_All, tone = .Accent)
		_ = ui.switch_row(ctx, "On the GPU", &app.ui.smooth_on_gpu, enabled = !dyn)
		steps := f32(app.ui.smooth_steps)
		if ui.slider(ctx, "Steps", &steps, 1, 100, .Logarithmic, fmt.tprintf("%d", app.ui.smooth_steps), enabled = !dyn) do app.ui.smooth_steps = i32(steps + 0.5)
		_ = ui.slider(ctx, "Strength", &app.ui.smooth_strength, 0.05, 1, .Linear, fmt.tprintf("%.2f", app.ui.smooth_strength), enabled = !dyn)
		SMOOTH_HELP :: "Smooth all moves every vertex toward its neighbours' average, Steps times; masked parts stay."
		ui.paragraph(ctx, SMOOTH_HELP + " On the GPU runs the steps as a compute shader.")
		kit_more_end(app)
	}
	kit_last_result(app, .Deform)
}
