package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strconv"
import "core:strings"
import "core:time"

import "../geom"
import "../gizmo"
import "../render"
import "../sculpt"
import "../ui"

// The live stack (README "Live stack"): rows on an object that change how it is shown,
// not what it holds, as Blender's modifiers, Nomad's repeaters and ZBrush's Array Mesh do,
// each switched off, tuned or applied at any time. On a sculpt a row only makes copies:
// each copy is the object's own GPU mesh drawn again under another placing
// (render.Draw_Item.copy), so a stroke costs what it costs with none. Rows that change
// the polygons stay with Model mode's cages (Cage_Look), which are small enough to build
// again after every edit.
//
// The rows come in a fixed order, one of each kind, as each one copies what the rows
// above it make: Mirror, then Array, then Radial, then Along a curve.
//
// Mirror draws the object clipped at its own plane through its origin on each axis, and
// its image across the plane, as Blender's Mirror with Clipping does; nothing is cut, so
// the levels, the mask, the layers and an HD window stay. The half it hides is still the
// object's and the brush's symmetry is on across the plane while the row shows (locked:
// brush_symmetry), so the hidden half follows every stroke and a press on the image
// sculpts the hidden half under it, which symmetry mirrors back.
//
// Array repeats the object a step at a time (a move, a turn and a size each step), and
// Radial turns it about an axis through a pivot. A press on any of their copies sculpts
// the object as if that copy were it (stroke_frame), so every copy follows. Along lays
// the object and what the rows above make on a curve object of the scene, evenly from end
// to end, each turned with the curve; the object itself stays where it is, as the model
// the curve repeats, and the copies follow the curve as it is edited.

// The most the object and its copies draw together, so a row's counts never make a frame
// draw the mesh more often than a phone can.
STACK_COPIES_MAX :: 256
STACK_COUNT_MAX :: 64

Stack :: struct {
	mirror: Stack_Mirror,
	array:  Stack_Array,
	radial: Stack_Radial,
	along:  Stack_Along,
}

// A row is in the stack while `added`; `shown` is its eye.
Stack_Mirror :: struct {
	added, shown: bool,
	axes:         sculpt.Symmetry,
	minus:        bool, // keep and show the - side instead of the + side
}

Stack_Array :: struct {
	added, shown: bool,
	count:        int, // the object's own included: 2 is the object and one copy
	offset:       Vec3, // each step's move, in the object's own space
	turn:         Vec3, // each step's turn, degrees about x, then y, then z
	grow:         f32, // each step's size against the one before it
}

Stack_Radial :: struct {
	added, shown: bool,
	count:        int, // the object's own included
	axis:         sculpt.Axis,
	pivot:        Vec3, // the point of the object's space the copies turn about
}

Stack_Along :: struct {
	added, shown: bool,
	curve:        int, // the curve object's id; no copies while it is not in the scene
	count:        int, // the copies laid on the curve, from end to end
	axis:         sculpt.Axis, // the object's own axis that runs along the curve
}

STACK_ARRAY_DEFAULT :: Stack_Array{added = true, shown = true, count = 3, offset = {2.2, 0, 0}, grow = 1}
STACK_RADIAL_DEFAULT :: Stack_Radial{added = true, shown = true, count = 6, axis = .Y, pivot = {-2.5, 0, 0}}

// Undo's copy of a stack before and after a change, owned by its History entry.
Stack_Step :: struct {
	before, after: Stack,
}

// A drag of one of the card's values, one undo step from its press to its release
// (stack_drag_end), as the Transform values are.
Stack_Drag :: struct {
	active: bool,
	id:     int,
	from:   Stack,
}

// Whether the object's Mirror row shows: added, its eye open, and at least one plane.
stack_mirror_on :: proc(obj: ^Object) -> bool {
	m := obj.stack.mirror
	return m.added && m.shown && m.axes != {} && obj.cage == nil
}

stack_array_on :: proc(obj: ^Object) -> bool {
	a := obj.stack.array
	return a.added && a.shown && a.count > 1 && obj.cage == nil
}

stack_radial_on :: proc(obj: ^Object) -> bool {
	r := obj.stack.radial
	return r.added && r.shown && r.count > 1 && obj.cage == nil
}

// The curve object the Along row lays copies on, while the row shows and the curve is in
// the scene; nil otherwise.
stack_along_curve :: proc(app: ^App, obj: ^Object) -> ^Object {
	a := obj.stack.along
	if !a.added || !a.shown || a.count < 1 || obj.cage != nil do return nil
	curve := object_by_id(app, a.curve)
	if curve == nil || curve == obj || curve.curve == nil || len(curve.curve.points) < 2 do return nil
	return curve
}

stack_along_on :: proc(app: ^App, obj: ^Object) -> bool {return stack_along_curve(app, obj) != nil}

// Whether any row of the object's stack is in it, shown or not.
stack_has_rows :: proc(s: Stack) -> bool {return s.mirror.added || s.array.added || s.radial.added || s.along.added}

// The placings of the Along row's copies in the object's own space: the curve sampled
// evenly from end to end (round a closed one), each sample's frame turning the object's
// `axis` along the curve and the next axis out along the frame's normal, at the object's
// own size. None without a curve.
@(private = "file")
stack_along_places :: proc(app: ^App, obj: ^Object) -> [dynamic]render.Mat4 {
	out := make([dynamic]render.Mat4, 0, 8, context.temp_allocator)
	curve := stack_along_curve(app, obj)
	if curve == nil do return out
	a := obj.stack.along
	cp := curve.curve
	length := geom.bezier_length(cp.points[:], cp.closed)
	if !(length > 0) do return out
	steps := a.count if cp.closed else max(a.count - 1, 1)
	samples := geom.bezier_sample(cp.points[:], cp.closed, length / f32(steps), context.temp_allocator)
	frames := geom.bezier_frames(samples, {0, 1, 0}, cp.closed, context.temp_allocator)
	inv := linalg.inverse(transform_matrix(obj.transform))
	turn := transform_rotation(curve.transform)
	ax := int(a.axis)
	for f, k in frames {
		if k >= a.count do break
		cols: [3]Vec3
		cols[ax], cols[(ax + 1) % 3], cols[(ax + 2) % 3] = turn * f.t, turn * f.n, turn * f.b
		rot: matrix[3, 3]f32
		for r in 0 ..< 3 do for c in 0 ..< 3 do rot[r, c] = cols[c][r]
		append(&out, inv * similarity(rot, obj.transform.scale, to_world(curve.transform, f.p)))
	}
	return out
}

// The similarity that turns by `rot`, scales by `size` and then moves by `move`.
@(private = "file")
similarity :: proc(rot: matrix[3, 3]f32, size: f32, move: Vec3) -> render.Mat4 {
	return render.Mat4{
		size * rot[0, 0], size * rot[0, 1], size * rot[0, 2], move.x,
		size * rot[1, 0], size * rot[1, 1], size * rot[1, 2], move.y,
		size * rot[2, 0], size * rot[2, 1], size * rot[2, 2], move.z,
		0, 0, 0, 1,
	}
}

// The transform a similarity matrix places by: its scale is the length of its first
// column, its turn what is left of its 3x3 part. A reflection has no transform.
transform_of_matrix :: proc(m: render.Mat4) -> Transform {
	s := linalg.length(Vec3{m[0, 0], m[1, 0], m[2, 0]})
	rot: matrix[3, 3]f32
	for r in 0 ..< 3 do for c in 0 ..< 3 do rot[r, c] = m[r, c] / s
	return {position = {m[0, 3], m[1, 3], m[2, 3]}, scale = s, rotation = gizmo.rotation_degrees(rot)}
}

// The placings Array, Radial and Along make, in the object's own space, the object's own
// (the identity) first: each Radial turn of each Array step, then all of them again at
// each of Along's places. None turns space over, so each is a transform a stroke can
// sculpt through (stack_frames).
stack_steps :: proc(app: ^App, obj: ^Object, allocator := context.temp_allocator) -> [dynamic]render.Mat4 {
	out := make([dynamic]render.Mat4, 0, 8, allocator)
	turns := make([dynamic]render.Mat4, 0, 8, context.temp_allocator)
	append(&turns, render.Mat4(1))
	if stack_radial_on(obj) {
		r := obj.stack.radial
		about: Vec3
		about[int(r.axis)] = 1
		for j in 1 ..< r.count {
			rot := linalg.matrix3_rotate_f32(f32(j) * math.TAU / f32(r.count), about)
			append(&turns, similarity(rot, 1, r.pivot - rot * r.pivot))
		}
	}
	steps := make([dynamic]render.Mat4, 0, 8, context.temp_allocator)
	append(&steps, render.Mat4(1))
	if stack_array_on(obj) {
		a := obj.stack.array
		step := similarity(gizmo.rotation_matrix(a.turn), a.grow, a.offset)
		at := render.Mat4(1)
		for _ in 1 ..< a.count {
			at = step * at
			append(&steps, at)
		}
	}
	images := 1 << uint(card(obj.stack.mirror.axes)) if stack_mirror_on(obj) else 1
	most := max(1, STACK_COPIES_MAX / images)
	places := make([dynamic]render.Mat4, 0, 8, context.temp_allocator)
	append(&places, render.Mat4(1))
	append(&places, ..stack_along_places(app, obj)[:])
	for at in places {
		for t in turns {
			for a in steps {
				if len(out) == most do return out
				append(&out, at * t * a)
			}
		}
	}
	return out
}

// The placings of the object's copies, in its own space, its own (the identity) left
// out: the mirror images across each plane and their combinations (X and Z give three),
// each copied by every Array and Radial step, at most STACK_COPIES_MAX - 1.
stack_placings :: proc(app: ^App, obj: ^Object, allocator := context.temp_allocator) -> [dynamic]render.Mat4 {
	out := make([dynamic]render.Mat4, 0, 8, allocator)
	images := make([dynamic]render.Mat4, 0, 8, context.temp_allocator)
	append(&images, render.Mat4(1))
	if stack_mirror_on(obj) {
		for a in sculpt.Axis {
			if a not_in obj.stack.mirror.axes do continue
			flip := render.Mat4(1)
			flip[int(a), int(a)] = -1
			count := len(images)
			for k in 0 ..< count do append(&images, flip * images[k])
		}
	}
	steps := stack_steps(app, obj)
	for s, i in steps {
		for m, k in images {
			if i == 0 && k == 0 do continue
			append(&out, s * m)
		}
	}
	return out
}

// The world transforms a stroke can sculpt the object through besides its own: one for
// each Array and Radial step, a mirror image's being its step's, whose hidden half lies
// under the image.
stack_frames :: proc(app: ^App, obj: ^Object, allocator := context.temp_allocator) -> [dynamic]Transform {
	out := make([dynamic]Transform, 0, 8, allocator)
	steps := stack_steps(app, obj)
	if len(steps) < 2 do return out
	world := transform_matrix(obj.transform)
	for s in steps[1:] do append(&out, transform_of_matrix(world * s))
	return out
}

// The clip planes of render.Draw_Item.clip the object draws with: the kept side of each
// mirror plane; zero without a mirror.
stack_clip :: proc(obj: ^Object) -> (clip: [3]f32) {
	if !stack_mirror_on(obj) do return
	for a in obj.stack.mirror.axes do clip[int(a)] = -1 if obj.stack.mirror.minus else 1
	return
}

// Appends the copies of every item an object with a live stack drew this frame, each
// beside the one it copies in `froms`, and clips the items and their copies where the
// mirror says. Copies share the item's mesh, chunks, hidden parts and damage, so a stroke
// redraws them with it and the idle cache keys them as it does the item.
stack_draw_copies :: proc(app: ^App, draws: ^[dynamic]render.Draw_Item, froms: ^[dynamic]Item_From) {
	n := len(draws)
	copies := 0
	for i in 0 ..< n {
		obj := froms[i].obj
		if obj == nil do continue
		placings := stack_placings(app, obj)
		if len(placings) == 0 do continue
		draws[i].clip = stack_clip(obj)
		item, from := draws[i], froms[i]
		for p, k in placings {
			c := item
			c.model = item.model * p
			c.copy = u32(k + 1)
			append(draws, c)
			append(froms, from)
			copies += 1
		}
	}
	app.stats.stack_copies = copies
}

// The brush's mirror planes on `obj` as its Mirror row adds them, which the row's planes
// hold on while it shows; none otherwise.
stack_symmetry :: proc(obj: ^Object) -> sculpt.Symmetry {
	if obj == nil || !stack_mirror_on(obj) do return {}
	return obj.stack.mirror.axes
}

// The transform the stroke on `obj` sculpts through: the copy it was pressed on
// (Stroke.frame), or the object's own.
stroke_frame :: proc(app: ^App, obj: ^Object) -> Transform {
	st := &app.stroke
	if st.active && st.object == obj.id && st.framed do return st.frame
	return obj.transform
}

// Sets the object's stack to `s` as one undo step named `what`, when it changes it.
stack_set :: proc(app: ^App, obj: ^Object, s: Stack, what: string) {
	if obj.stack == s do return
	step := new(Stack_Step)
	step^ = {obj.stack, s}
	obj.stack = s
	app.scene_edits += 1
	history_push(app, History_Entry{id = obj.id, kind = .Stack, what = what, at = time.tick_now(), stack = step})
}

// A value of the card changed under a drag: the drag's first frame keeps the stack as it
// was, for the one undo step its release records.
stack_drag_changed :: proc(app: ^App, obj: ^Object, before: Stack) {
	d := &app.ui.stack_drag
	if !d.active || d.id != obj.id {
		stack_drag_end(app, force = true)
		d^ = {active = true, id = obj.id, from = before}
	}
	app.scene_edits += 1
}

// Ends a drag of the card's values once the pointer lets go (or at once with `force`), as
// one undo step. Runs every frame, so a drag ends even if the card closed meanwhile.
stack_drag_end :: proc(app: ^App, force := false) {
	d := &app.ui.stack_drag
	if !d.active || (!force && .Left in app.device.down) do return
	d.active = false
	obj := object_by_id(app, d.id)
	if obj == nil || obj.stack == d.from do return
	now := obj.stack
	obj.stack = d.from
	stack_set(app, obj, now, "Live stack")
}

// Undo or redo of a .Stack entry: the stack as it was on the other side.
stack_step_apply :: proc(app: ^App, obj: ^Object, step: ^Stack_Step, back: bool) {
	obj.stack = step.before if back else step.after
	app.scene_edits += 1
}

// What the stack writes into the object's bytes (object_put_bytes), read back by
// stack_get, which refuses a damaged one.
stack_put :: proc(out: ^[dynamic]u8, s: Stack) {
	m := s.mirror
	geom.byte_put(out, u8(m.added) | u8(m.shown) << 1 | u8(m.minus) << 2)
	geom.byte_put(out, transmute(u8)m.axes)
	a := s.array
	geom.byte_put(out, u8(a.added) | u8(a.shown) << 1)
	geom.byte_put(out, u8(a.count))
	geom.byte_put(out, a.offset)
	geom.byte_put(out, a.turn)
	geom.byte_put(out, a.grow)
	r := s.radial
	geom.byte_put(out, u8(r.added) | u8(r.shown) << 1)
	geom.byte_put(out, u8(r.count))
	geom.byte_put(out, u8(r.axis))
	geom.byte_put(out, r.pivot)
	l := s.along
	geom.byte_put(out, u8(l.added) | u8(l.shown) << 1)
	geom.byte_put(out, u8(l.count))
	geom.byte_put(out, u8(l.axis))
	geom.byte_put(out, i32(l.curve))
}

stack_get :: proc(r: ^geom.Byte_Reader) -> (s: Stack, ok: bool) {
	mb, axes := geom.byte_get(r, u8), geom.byte_get(r, u8)
	ab, ac := geom.byte_get(r, u8), geom.byte_get(r, u8)
	offset, turn, grow := geom.byte_get(r, Vec3), geom.byte_get(r, Vec3), geom.byte_get(r, f32)
	rb, rc, ra := geom.byte_get(r, u8), geom.byte_get(r, u8), geom.byte_get(r, u8)
	pivot := geom.byte_get(r, Vec3)
	lb, lc, la, curve := geom.byte_get(r, u8), geom.byte_get(r, u8), geom.byte_get(r, u8), geom.byte_get(r, i32)
	if !r.ok || mb > 7 || axes > 7 || ab > 3 || rb > 3 || ra > 2 do return
	if ac > STACK_COUNT_MAX || rc > STACK_COUNT_MAX || lc > STACK_COUNT_MAX || lb > 3 || la > 2 || curve < 0 do return
	if lb & 1 != 0 && lc < 1 do return
	if !vec_finite(offset) || !vec_finite(turn) || !vec_finite(pivot) do return
	// A row not in the stack is all zeros; one in it has copies and a size step.
	if ab & 1 != 0 && (ac < 2 || !(grow >= STACK_GROW_MIN && grow <= STACK_GROW_MAX)) || rb & 1 != 0 && rc < 2 do return
	s.mirror = {added = mb & 1 != 0, shown = mb & 2 != 0, minus = mb & 4 != 0, axes = transmute(sculpt.Symmetry)axes}
	s.array = {added = ab & 1 != 0, shown = ab & 2 != 0, count = int(ac), offset = offset, turn = turn, grow = grow}
	s.radial = {added = rb & 1 != 0, shown = rb & 2 != 0, count = int(rc), axis = sculpt.Axis(ra), pivot = pivot}
	s.along = {added = lb & 1 != 0, shown = lb & 2 != 0, count = int(lc), axis = sculpt.Axis(la), curve = int(curve)}
	return s, true
}

STACK_GROW_MIN :: 0.05
// What stack_put writes: the mirror's 2 bytes, the array's 30, the radial's 15 and
// Along's 7.
STACK_BYTES :: 54
STACK_GROW_MAX :: 4

@(private = "file")
vec_finite :: proc(v: Vec3) -> bool {
	for x in v do if !(abs(x) <= 1e6) do return false
	return true
}

// The Live stack card (Card.Stack): the selected object's rows in their order, each with
// its eye, its settings and Remove, then what can be added and Apply, which bakes them.
kit_stack :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	if obj.cage != nil {
		ui.paragraph(ctx, "A cage's live rows (Mirror, Thickness, Bevel creases) are in the Model palette for now.")
		return
	}
	if obj.voxel == nil && object_draws_triangles(obj) == false {
		ui.paragraph(ctx, "A curve shows no surface to copy.")
		return
	}
	if !stack_has_rows(obj.stack) {
		ui.paragraph(ctx, "Rows here change how the object is shown, not what it holds: switch them off, tune them or apply them at any time. Copies cost a stroke nothing, and a stroke on any copy sculpts them all.")
	}
	if obj.stack.mirror.added do kit_stack_mirror(app, obj)
	if obj.stack.array.added do kit_stack_array(app, obj)
	if obj.stack.radial.added do kit_stack_radial(app, obj)
	if obj.stack.along.added do kit_stack_along(app, obj)
	if stack_has_rows(obj.stack) do ui.divider(ctx, across = true)
	kit_stack_add(app, obj)
	if stack_has_rows(obj.stack) {
		can := obj.voxel == nil && !app.stroke.active && (stack_mirror_on(obj) || stack_array_on(obj) || stack_radial_on(obj) || stack_along_on(app, obj))
		if ui.button(ctx, "Apply the stack", enabled = can, reason = "Needs a shown row on a mesh object") {
			app.ui.scene_command = {kind = .Stack_Apply}
		}
	}
	kit_last_result(app, .Stack)
}

// The buttons for the rows not yet in the stack.
@(private = "file")
kit_stack_add :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	s := obj.stack
	if s.mirror.added && s.array.added && s.radial.added && s.along.added do return
	ui.begin(ctx, "stack add", {direction = .Row})
	if !s.mirror.added && ui.button(ctx, "Mirror##add", glyph = ICON_SYMMETRY, tone = .Accent) {
		s.mirror = {added = true, shown = true, axes = {.X}}
		stack_set(app, obj, s, "Add mirror")
	}
	if !s.array.added && ui.button(ctx, "Array##add", glyph = ui.ICON_PLUS, tone = .Accent) {
		s.array = STACK_ARRAY_DEFAULT
		stack_set(app, obj, s, "Add array")
	}
	if !s.radial.added && ui.button(ctx, "Radial##add", glyph = ui.ICON_PLUS, tone = .Accent) {
		s.radial = STACK_RADIAL_DEFAULT
		stack_set(app, obj, s, "Add radial")
	}
	if !s.along.added && ui.button(ctx, "Along##add", glyph = ui.ICON_SPLINE, tone = .Accent) {
		s.along = {added = true, shown = true, count = 6, curve = stack_first_curve(app, obj)}
		stack_set(app, obj, s, "Add along a curve")
	}
	ui.end(ctx)
}

// A row's head: its name and its eye.
@(private = "file")
kit_stack_head :: proc(app: ^App, obj: ^Object, name: string, shown: bool) {
	ctx := &app.kit.ctx
	t := ctx.theme
	ui.divider(ctx, across = true)
	ui.label(ctx, name, t.text_size, t.text, .Semibold)
	eye := shown
	if ui.switch_row(ctx, fmt.tprintf("Show##%s", name), &eye) {
		s := obj.stack
		row_shown(&s, name)^ = eye
		stack_set(app, obj, s, fmt.tprintf("%s %s", "Show" if eye else "Hide", strings.to_lower(name, context.temp_allocator)))
	}
}

// A row's foot: Remove, quiet as it is in a row of many; Undo brings the row back.
@(private = "file")
kit_stack_remove :: proc(app: ^App, obj: ^Object, name: string) {
	if !ui.button(&app.kit.ctx, fmt.tprintf("Remove %s##stack", strings.to_lower(name, context.temp_allocator)), variant = .Light, tone = .Danger) do return
	s := obj.stack
	switch name {
	case "Mirror": s.mirror = {}
	case "Array": s.array = {}
	case "Radial": s.radial = {}
	case "Along": s.along = {}
	}
	stack_set(app, obj, s, fmt.tprintf("Remove %s", strings.to_lower(name, context.temp_allocator)))
}

@(private = "file")
row_shown :: proc(s: ^Stack, name: string) -> ^bool {
	switch name {
	case "Array": return &s.array.shown
	case "Radial": return &s.radial.shown
	case "Along": return &s.along.shown
	}
	return &s.mirror.shown
}

@(private = "file")
kit_stack_mirror :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	kit_stack_head(app, obj, "Mirror", obj.stack.mirror.shown)
	defer kit_stack_remove(app, obj, "Mirror")
	s := obj.stack
	m := &s.mirror
	ui.begin(ctx, "stack mirror axes", {direction = .Row})
	for a in sculpt.Axis {
		if ui.toggle_button(ctx, fmt.tprintf("%v##mirror", a), a in m.axes, 48, tooltip = fmt.tprintf("Mirror across the object's own %v plane", a)) {
			m.axes ~= {a}
			stack_set(app, obj, s, "Mirror planes")
			s = obj.stack
		}
	}
	ui.end(ctx)
	minus := m.minus
	if ui.switch_row(ctx, "Keep the - side##mirror", &minus) {
		m.minus = minus
		stack_set(app, obj, s, "Mirror side")
	}
	if stack_mirror_on(obj) {
		ui.paragraph(ctx, fmt.tprintf("Symmetry across %s stays on for this object while the mirror shows, so the hidden half follows every stroke.", stack_axes_label(obj.stack.mirror.axes)))
	}
}

@(private = "file")
kit_stack_array :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	kit_stack_head(app, obj, "Array", obj.stack.array.shown)
	defer kit_stack_remove(app, obj, "Array")
	a := &obj.stack.array
	before := obj.stack
	count := f32(a.count)
	if ui.drag_value(ctx, "Count##array", &count, 0.05, 2, STACK_COUNT_MAX, fmt.tprintf("%d", a.count)) do a.count = int(math.round(count))
	axes := [3]string{"X", "Y", "Z"}
	for axis, i in axes {
		_ = ui.drag_value(ctx, fmt.tprintf("Step %s##array", axis), &a.offset[i], 0.01, -100, 100, fmt.tprintf("%.2f", a.offset[i]))
	}
	if kit_more(app, .Stack) {
		for axis, i in axes {
			_ = ui.drag_value(ctx, fmt.tprintf("Turn about %s##array", axis), &a.turn[i], 0.5, -360, 360, fmt.tprintf("%.1f°", a.turn[i]))
		}
		_ = ui.drag_value(ctx, "Size each step##array", &a.grow, 0.002, 0.05, STACK_GROW_MAX, fmt.tprintf("%.3f", a.grow))
		kit_more_end(app)
	}
	if obj.stack != before do stack_drag_changed(app, obj, before)
}

@(private = "file")
kit_stack_radial :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	kit_stack_head(app, obj, "Radial", obj.stack.radial.shown)
	defer kit_stack_remove(app, obj, "Radial")
	r := &obj.stack.radial
	before := obj.stack
	count := f32(r.count)
	if ui.drag_value(ctx, "Count##radial", &count, 0.05, 2, STACK_COUNT_MAX, fmt.tprintf("%d", r.count)) do r.count = int(math.round(count))
	ui.begin(ctx, "stack radial axis", {direction = .Row})
	for a in sculpt.Axis {
		if ui.toggle_button(ctx, fmt.tprintf("%v##radial", a), r.axis == a, 48, tooltip = fmt.tprintf("Turn the copies about the object's own %v axis", a)) do r.axis = a
	}
	ui.end(ctx)
	axes := [3]string{"X", "Y", "Z"}
	for axis, i in axes {
		_ = ui.drag_value(ctx, fmt.tprintf("Pivot %s##radial", axis), &r.pivot[i], 0.01, -100, 100, fmt.tprintf("%.2f", r.pivot[i]))
	}
	if obj.stack != before {
		// The axis is a tap, its own undo step; the values are drags.
		if obj.stack.radial.axis != before.radial.axis {
			now := obj.stack
			obj.stack = before
			stack_set(app, obj, now, "Radial axis")
		} else {
			stack_drag_changed(app, obj, before)
		}
	}
}

// The first curve object of the scene other than `obj`, by id; 0 for none.
stack_first_curve :: proc(app: ^App, obj: ^Object) -> int {
	for o in app.scene.objects do if o != obj && o.curve != nil do return o.id
	return 0
}

// A curve object's name in the Along row's list: its own, or "Curve" and its place among
// the scene's curves.
@(private = "file")
stack_curve_label :: proc(app: ^App, curve: ^Object) -> string {
	if curve.name != "" do return curve.name
	n := 0
	for o in app.scene.objects {
		if o.curve == nil do continue
		n += 1
		if o == curve do break
	}
	return fmt.tprintf("Curve %d", n)
}

@(private = "file")
kit_stack_along :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	kit_stack_head(app, obj, "Along", obj.stack.along.shown)
	defer kit_stack_remove(app, obj, "Along")
	curves := make([dynamic]^Object, 0, 4, context.temp_allocator)
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	chosen := -1
	for o in app.scene.objects {
		if o == obj || o.curve == nil do continue
		if o.id == obj.stack.along.curve do chosen = len(curves)
		append(&curves, o)
		append(&names, stack_curve_label(app, o))
	}
	if len(curves) == 0 {
		ui.paragraph(ctx, "Draw a curve object (Curve, then a stroke on the view) to lay copies along it.")
		return
	}
	if chosen < 0 do ui.paragraph(ctx, "Pick the curve to lay copies along.")
	if pick := ui.select(ctx, "Curve##along", names[:], chosen); pick != chosen && pick >= 0 {
		s := obj.stack
		s.along.curve = curves[pick].id
		stack_set(app, obj, s, "Along curve")
	}
	l := &obj.stack.along
	before := obj.stack
	count := f32(l.count)
	if ui.drag_value(ctx, "Count##along", &count, 0.05, 1, STACK_COUNT_MAX, fmt.tprintf("%d", l.count)) do l.count = int(math.round(count))
	if obj.stack != before do stack_drag_changed(app, obj, before)
	ui.begin(ctx, "stack along axis", {direction = .Row})
	for a in sculpt.Axis {
		if ui.toggle_button(ctx, fmt.tprintf("%v##along", a), obj.stack.along.axis == a, 48, tooltip = fmt.tprintf("The object's own %v axis runs along the curve", a)) {
			s := obj.stack
			s.along.axis = a
			stack_set(app, obj, s, "Along axis")
		}
	}
	ui.end(ctx)
}

// "X", "X and Z", "X, Y and Z".
stack_axes_label :: proc(axes: sculpt.Symmetry) -> string {
	names: [3]string
	n := 0
	for a in axes {
		names[n] = fmt.tprint(a)
		n += 1
	}
	switch n {
	case 0: return "no plane"
	case 1: return names[0]
	case 2: return fmt.tprintf("%s and %s", names[0], names[1])
	}
	return fmt.tprintf("%s, %s and %s", names[0], names[1], names[2])
}

// The card's line: what the stack holds, its hidden rows marked.
stack_summary :: proc(obj: ^Object) -> string {
	if obj == nil || !stack_has_rows(obj.stack) do return ""
	s := obj.stack
	parts := make([dynamic]string, 0, 3, context.temp_allocator)
	if m := s.mirror; m.added do append(&parts, fmt.tprintf("Mirror %s", stack_axes_label(m.axes)) if m.shown else "Mirror (hidden)")
	if a := s.array; a.added do append(&parts, fmt.tprintf("Array %d", a.count) if a.shown else "Array (hidden)")
	if r := s.radial; r.added do append(&parts, fmt.tprintf("Radial %d", r.count) if r.shown else "Radial (hidden)")
	if l := s.along; l.added do append(&parts, fmt.tprintf("Along %d", l.count) if l.shown else "Along (hidden)")
	return strings.join(parts[:], ", ", context.temp_allocator)
}

// Apply of the stack: its shown rows baked into the object's mesh in their order (Mirror
// and weld across each mirror plane, keeping its side, then every Array and Radial copy
// joined in), one swap step with the rows taken out, so Undo brings back the stack and
// what it hid. A hidden row stays. False only when rebuilding the object failed.
stack_apply :: proc(app: ^App, obj: ^Object) -> bool {
	if obj.voxel != nil || obj.cage != nil do return true
	mirror, copies := stack_mirror_on(obj), stack_array_on(obj) || stack_radial_on(obj) || stack_along_on(app, obj)
	if !mirror && !copies do return true
	before := history_snapshot(app, obj, "apply stack")
	start := time.tick_now()
	m := obj.stack.mirror
	changed := false
	if mirror {
		for a in m.axes {
			did, ok := object_symmetrize(app, obj, int(a), !m.minus)
			if !ok {
				history_snapshot_drop(before)
				return false
			}
			changed ||= did
		}
		// The copies join the welded object, not the half the mirror kept.
		obj.stack.mirror = {}
	}
	if copies {
		did, ok := stack_join_copies(app, obj)
		if !ok {
			history_snapshot_drop(before)
			return false
		}
		changed ||= did
	}
	if stack_array_on(obj) do obj.stack.array = {}
	if stack_radial_on(obj) do obj.stack.radial = {}
	if stack_along_on(app, obj) do obj.stack.along = {}
	history_record_swap(app, obj.id, before)
	if changed {
		report(app, .Stack, {.Undo}, "Applied the stack: %d vertices (%.0f ms)", object_vertex_count(obj), time.duration_milliseconds(time.tick_since(start)))
	} else {
		report(app, .Stack, {.Warning, .Undo}, "Nothing of the object was on the side to keep: the rows are taken out")
	}
	return true
}

// The object's shown level and every Array and Radial copy of it joined into one mesh,
// its polygroups and polypaint copied onto each, which the object is rebuilt from, as a
// merge is (merge_meshes). `changed` is false when there were no copies.
@(private = "file")
stack_join_copies :: proc(app: ^App, obj: ^Object) -> (changed, ok: bool) {
	steps := stack_steps(app, obj)
	if len(steps) < 2 do return false, true
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	base := shape_in(obj, obj.transform)
	defer geom.mesh_destroy(&base)
	s := object_sculptor(obj)
	groups := sculpt.sculptor_groups(s) if !object_dynamic(obj) else nil
	shown := sculpt.sculptor_paint_shown(s) if !object_dynamic(obj) else nil
	parts := make([]geom.Mesh, len(steps), context.temp_allocator)
	for step, k in steps {
		parts[k] = {positions = make([dynamic]geom.Vec3, len(base.positions), context.temp_allocator), indices = base.indices}
		for p, v in base.positions {
			q := step * [4]f32{p.x, p.y, p.z, 1}
			parts[k].positions[v] = q.xyz
		}
	}
	mesh := geom.mesh_join(parts)
	surface: Surface
	vcount, tcount := len(base.positions), len(base.indices) / 3
	if groups != nil {
		surface.groups = make([]u16, tcount * len(steps))
		for k in 0 ..< len(steps) do copy(surface.groups[k * tcount:][:tcount], groups[:tcount])
	}
	if shown != nil {
		surface.color = make([]sculpt.Color, vcount * len(steps))
		for k in 0 ..< len(steps) do copy(surface.color[k * vcount:][:vcount], shown[:vcount])
	}
	defer delete(surface.groups)
	defer delete(surface.color)
	if !object_rebuild(app, obj, mesh, start, normals = true, surface = surface) do return true, false
	return true, true
}

// The script verb `stack`: "mirror x" (any of x, y and z together, "-x" style for the -
// side), "array 4 2.2 0 0" (the count and each step's move, then optionally "turn 0 30 0"
// and "size 0.9"), "radial 6 y" (the count and
// the axis), "along 8 x" (the count and the axis along the curve, on the row's curve or
// the scene's first), "<row> off", "show <row>", "hide <row>" or "apply stack". What went wrong, or
// "" when it did what it says.
stack_script :: proc(app: ^App, obj: ^Object, text: string) -> string {
	if obj == nil do return "nothing is selected"
	words := strings.fields(text, context.temp_allocator)
	USAGE :: "stack takes mirror x, array 4 2.2 0 0, radial 6 y, along 8 x, mirror off, show mirror, hide array or apply stack"
	if len(words) < 2 do return USAGE
	s := obj.stack
	is_row :: proc(w: string) -> bool {return w == "mirror" || w == "array" || w == "radial" || w == "along"}
	switch {
	case words[0] == "apply" && words[1] == "stack" && len(words) == 2:
		if !stack_has_rows(s) do return "the object has no live stack"
		app.ui.scene_command = {kind = .Stack_Apply}
		return ""
	case is_row(words[0]) && words[1] == "off" && len(words) == 2:
		switch words[0] {
		case "mirror": s.mirror = {}
		case "array": s.array = {}
		case "radial": s.radial = {}
		case "along": s.along = {}
		}
	case (words[0] == "show" || words[0] == "hide") && is_row(words[1]) && len(words) == 2:
		on := words[0] == "show"
		switch words[1] {
		case "mirror":
			if !s.mirror.added do return "the object has no mirror row"
			s.mirror.shown = on
		case "array":
			if !s.array.added do return "the object has no array row"
			s.array.shown = on
		case "radial":
			if !s.radial.added do return "the object has no radial row"
			s.radial.shown = on
		case "along":
			if !s.along.added do return "the object has no along row"
			s.along.shown = on
		}
	case words[0] == "mirror" && len(words) == 2:
		axes := words[1]
		minus := strings.has_prefix(axes, "-")
		axes = strings.trim_prefix(axes, "-")
		set: sculpt.Symmetry
		for c in axes {
			switch c {
			case 'x': set += {.X}
			case 'y': set += {.Y}
			case 'z': set += {.Z}
			case: return fmt.tprintf("%q names no planes: x, y and z, as xz or -x", words[1])
			}
		}
		if set == {} do return "mirror needs a plane"
		s.mirror = {added = true, shown = true, axes = set, minus = minus}
	case words[0] == "array" && len(words) >= 5:
		count, count_ok := strconv.parse_int(words[1])
		if !count_ok || count < 2 || count > STACK_COUNT_MAX do return fmt.tprintf("array's count is from 2 to %d", STACK_COUNT_MAX)
		a := STACK_ARRAY_DEFAULT
		a.count = count
		for k in 0 ..< 3 {
			v, v_ok := strconv.parse_f32(words[2 + k])
			if !v_ok || !(abs(v) <= 100) do return fmt.tprintf("%q is not a step from -100 to 100", words[2 + k])
			a.offset[k] = v
		}
		// Then "turn x y z" (degrees each step) and "size s" (each step's size), in any order.
		rest := words[5:]
		for len(rest) > 0 {
			switch {
			case rest[0] == "turn" && len(rest) >= 4:
				for k in 0 ..< 3 {
					v, v_ok := strconv.parse_f32(rest[1 + k])
					if !v_ok || !(abs(v) <= 360) do return fmt.tprintf("%q is not a turn from -360 to 360", rest[1 + k])
					a.turn[k] = v
				}
				rest = rest[4:]
			case rest[0] == "size" && len(rest) >= 2:
				v, v_ok := strconv.parse_f32(rest[1])
				if !v_ok || !(v >= STACK_GROW_MIN && v <= STACK_GROW_MAX) do return fmt.tprintf("%q is not a size from %.2f to %.0f", rest[1], STACK_GROW_MIN, STACK_GROW_MAX)
				a.grow = v
				rest = rest[2:]
			case:
				return fmt.tprintf("%q is not turn x y z or size s", rest[0])
			}
		}
		s.array = a
	case words[0] == "radial" && len(words) == 3:
		count, count_ok := strconv.parse_int(words[1])
		if !count_ok || count < 2 || count > STACK_COUNT_MAX do return fmt.tprintf("radial's count is from 2 to %d", STACK_COUNT_MAX)
		r := s.radial if s.radial.added else STACK_RADIAL_DEFAULT
		r.added, r.shown, r.count = true, true, count
		switch words[2] {
		case "x": r.axis = .X
		case "y": r.axis = .Y
		case "z": r.axis = .Z
		case: return fmt.tprintf("%q is not an axis: x, y or z", words[2])
		}
		s.radial = r
	case words[0] == "along" && len(words) == 3:
		count, count_ok := strconv.parse_int(words[1])
		if !count_ok || count < 1 || count > STACK_COUNT_MAX do return fmt.tprintf("along's count is from 1 to %d", STACK_COUNT_MAX)
		l := s.along
		if object_by_id(app, l.curve) == nil do l.curve = stack_first_curve(app, obj)
		if l.curve == 0 do return "along needs a curve object in the scene"
		l.added, l.shown, l.count = true, true, count
		switch words[2] {
		case "x": l.axis = .X
		case "y": l.axis = .Y
		case "z": l.axis = .Z
		case: return fmt.tprintf("%q is not an axis: x, y or z", words[2])
		}
		s.along = l
	case:
		return USAGE
	}
	stack_set(app, obj, s, "Live stack")
	return ""
}
