package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strconv"
import "core:strings"
import "core:time"

import "../geom"
import "../gizmo"
import "../poly"
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
	return a.added && a.shown && a.count > 1
}

stack_radial_on :: proc(obj: ^Object) -> bool {
	r := obj.stack.radial
	return r.added && r.shown && r.count > 1
}

// The curve object the Along row lays copies on, while the row shows and the curve is in
// the scene; nil otherwise.
stack_along_curve :: proc(app: ^App, obj: ^Object) -> ^Object {
	a := obj.stack.along
	if !a.added || !a.shown || a.count < 1 do return nil
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

// The Live stack card (Card.Stack), drawn as folded rows as the Scene card draws objects:
// a line per row with its icon, its name, what it does now, its eye and its ⋯, one row
// open at a time under its line. A cage's own rows (SHAPE) come before the copies, as they
// change what the copies copy. One Add opens a menu of what the object can take, so the
// card never grows a row of buttons wider than itself; Remove and Reset are in each row's
// menu, and Apply stays in the foot.
Stack_Row :: enum u8 {
	Smooth,
	Cage_Mirror,
	Thickness,
	Bevel,
	Deform,
	Curve,
	Wrap,
	Displace,
	Mirror,
	Array,
	Radial,
	Along,
}

STACK_ROW_NAMES := [Stack_Row]string {
	.Smooth      = "Smooth",
	.Cage_Mirror = "Mirror",
	.Thickness   = "Thickness",
	.Bevel       = "Bevel",
	.Deform      = "Deform",
	.Curve       = "Curve",
	.Wrap        = "Wrap",
	.Displace    = "Displace",
	.Mirror      = "Mirror",
	.Array       = "Array",
	.Radial      = "Radial",
	.Along       = "Along a curve",
}

STACK_ROW_GLYPHS := [Stack_Row]rune {
	.Smooth      = ICON_SUBDIVIDE,
	.Cage_Mirror = ICON_SYMMETRY,
	.Thickness   = ICON_STRETCH_VERTICAL,
	.Bevel       = ui.ICON_SHAPES,
	.Deform      = ICON_DEFORM,
	.Curve       = ICON_CAGE_CURVE,
	.Wrap        = ICON_CAGE_WRAP,
	.Displace    = ICON_DISPLACE,
	.Mirror      = ICON_SYMMETRY,
	.Array       = ui.ICON_COPY,
	.Radial      = ICON_TURN,
	.Along       = ui.ICON_SPLINE,
}

// The card's own state between frames, which holds no sculpt state: which object's row is
// open, and the Add and row menus with where they open from.
Stack_Card :: struct {
	object:    int, // the object `open` is of; another selection shows every row folded
	open:      Stack_Row,
	opened:    bool,
	add:       bool,
	add_at:    ui.Rect,
	menu:      bool,
	menu_at:   ui.Rect,
	menu_row:  Stack_Row,
	menu_side: ui.Side,
}

// Whether a cage's row `r` is the one open, which keeps it in the card while its value is
// dragged down to Off, so a drag through zero does not fold it away under the finger.
@(private = "file")
stack_row_held :: proc(app: ^App, obj: ^Object, r: Stack_Row) -> bool {
	c := &app.kit.stack
	return c.opened && c.object == obj.id && c.open == r
}

// Whether the object's stack holds row `r`: a cage's own rows while they change its
// polygons, the copies' rows while added.
stack_row_in :: proc(app: ^App, obj: ^Object, r: Stack_Row) -> bool {
	cp := obj.cage
	switch r {
	case .Smooth: return cp != nil && (cp.look.smooth > 0 || stack_row_held(app, obj, r))
	case .Cage_Mirror: return cp != nil && (cp.look.live.mirror != {} || stack_row_held(app, obj, r))
	case .Thickness: return cp != nil && (cp.look.live.thickness > 0 || stack_row_held(app, obj, r))
	case .Bevel: return cp != nil && (cp.look.live.bevel > 0 || stack_row_held(app, obj, r))
	case .Deform: return cp != nil && (cp.look.live.deform != .Off || stack_row_held(app, obj, r))
	case .Curve: return cp != nil && (cp.look.follow.curve != 0 || stack_row_held(app, obj, r))
	case .Wrap: return cp != nil && (cp.look.follow.wrap != 0 || stack_row_held(app, obj, r))
	case .Displace: return cp != nil && (cp.look.live.displace > 0 || stack_row_held(app, obj, r))
	case .Mirror: return cp == nil && obj.stack.mirror.added
	case .Array: return obj.stack.array.added
	case .Radial: return obj.stack.radial.added
	case .Along: return obj.stack.along.added
	}
	return false
}

// A cage's own rows, which change its polygons and have no eye.
stack_row_cage :: proc(r: Stack_Row) -> bool {return r <= .Displace}

// Whether the object can take row `r` at all: a cage's rows only on a cage, Mirror's
// copies only on a sculpt (a cage mirrors its polygons instead).
@(private = "file")
stack_row_fits :: proc(obj: ^Object, r: Stack_Row) -> bool {
	if stack_row_cage(r) do return obj.cage != nil
	return r != .Mirror || obj.cage == nil
}

@(private = "file")
row_shown :: proc(s: ^Stack, r: Stack_Row) -> ^bool {
	#partial switch r {
	case .Array: return &s.array.shown
	case .Radial: return &s.radial.shown
	case .Along: return &s.along.shown
	}
	return &s.mirror.shown
}

// The dimmer line under a row's name: what the row does now, in a few words.
stack_row_detail :: proc(app: ^App, obj: ^Object, r: Stack_Row) -> string {
	s := &obj.stack
	if !stack_row_cage(r) && !row_shown(s, r)^ do return "Hidden"
	switch r {
	case .Smooth:
		n := obj.cage.look.smooth
		line := "Off" if n <= 0 else fmt.tprintf("%d step%s", n, "" if n == 1 else "s")
		return fmt.tprintf("%s, flat corners", line) if obj.cage.look.flat else line
	case .Cage_Mirror:
		if obj.cage.live.mirror_refused do return "Off: a face crosses the plane"
		axes: sculpt.Symmetry
		for a in poly.Mirror_Axis do if a in obj.cage.look.live.mirror do axes += {sculpt.Axis(int(a))}
		return "No plane" if axes == {} else stack_axes_label(axes)
	case .Thickness:
		l := obj.cage.look.live
		if l.thickness <= 0 do return "Off"
		sides := [poly.Thickness_Side]string{.Out = "out", .In = "in", .Centre = "both ways"}
		return fmt.tprintf("%.1f%%, %s", 100 * l.thickness / cage_size(obj.cage), sides[l.side])
	case .Bevel:
		l := obj.cage.look.live
		if l.bevel <= 0 do return "Off"
		return fmt.tprintf("%.1f%%, %d segment%s", 100 * l.bevel / cage_size(obj.cage), l.bevel_segments, "" if l.bevel_segments == 1 else "s")
	case .Deform:
		l := obj.cage.look.live
		switch l.deform {
		case .Off: return "Off"
		case .Bend: return fmt.tprintf("Bend %.0f° along %v", math.to_degrees(l.deform_amount), l.deform_axis)
		case .Twist: return fmt.tprintf("Twist %.0f° along %v", math.to_degrees(l.deform_amount), l.deform_axis)
		case .Taper: return fmt.tprintf("Taper %+.0f%% along %v", 100 * l.deform_amount, l.deform_axis)
		}
	case .Curve:
		f := obj.cage.look.follow
		curve := cage_follow_curve(app, obj, f)
		if curve == nil do return "No curve picked" if f.curve == 0 else "Its curve is gone"
		return fmt.tprintf("%v along %s%s", f.curve_axis, stack_curve_label(app, curve), ", fitted" if f.curve_fit else "")
	case .Wrap:
		f := obj.cage.look.follow
		target := cage_follow_wrap(app, obj, f)
		if target == nil do return "No object picked" if f.wrap == 0 else "Its object is gone"
		off := 100 * f.wrap_offset / cage_size(obj.cage)
		return fmt.tprintf("On %s", cage_follow_label(app, target)) if abs(off) < 0.05 else fmt.tprintf("On %s, %+.1f%%", cage_follow_label(app, target), off)
	case .Displace:
		l := obj.cage.look.live
		if l.displace <= 0 do return "Off"
		size := cage_size(obj.cage)
		return fmt.tprintf("%.1f%%, features %.0f%%", 100 * l.displace / size, 100 * l.displace_scale / size)
	case .Mirror:
		m := s.mirror
		if m.axes == {} do return "No plane"
		return fmt.tprintf("%s, keeps %s", stack_axes_label(m.axes), "−" if m.minus else "+")
	case .Array:
		a := s.array
		return fmt.tprintf("%d, %.2f apart", a.count, linalg.length(a.offset))
	case .Radial:
		return fmt.tprintf("%d round %v", s.radial.count, s.radial.axis)
	case .Along:
		curve := object_by_id(app, s.along.curve)
		if curve == nil || curve.curve == nil do return "No curve picked"
		return fmt.tprintf("%d along %s", s.along.count, stack_curve_label(app, curve))
	}
	return ""
}

kit_stack :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	c := &app.kit.stack
	if obj.cage == nil && obj.voxel == nil && !object_draws_triangles(obj) {
		ui.paragraph(ctx, "A curve shows no surface to copy.")
		return
	}
	if c.object != obj.id do c.opened = false
	has := false
	for r in Stack_Row do if stack_row_in(app, obj, r) do has = true
	if !has {
		ui.paragraph(ctx, "Rows here change how the object is shown, not what it holds: switch them off, tune them or apply them at any time. Copies cost a stroke nothing, and a stroke on any copy sculpts them all.")
	}
	shape := false
	for r in Stack_Row.Smooth ..= Stack_Row.Displace do if stack_row_in(app, obj, r) do shape = true
	copies := false
	for r in Stack_Row.Mirror ..= Stack_Row.Along do if stack_row_in(app, obj, r) do copies = true
	if shape do ui.caption(ctx, "SHAPE")
	for r in Stack_Row.Smooth ..= Stack_Row.Displace do if stack_row_in(app, obj, r) do kit_stack_row(app, obj, r)
	if shape && copies do ui.caption(ctx, "COPIES")
	for r in Stack_Row.Mirror ..= Stack_Row.Along do if stack_row_in(app, obj, r) do kit_stack_row(app, obj, r)
	kit_stack_foot(app, obj, has)
	kit_last_result(app, .Stack)
}

// Row `r`'s line and, open, its body. A tap on the line or its chevron opens it and
// folds the others; the eye shows or hides a row of copies (an undo step), and the ⋯ or a
// long press opens its menu.
@(private = "file")
kit_stack_row :: proc(app: ^App, obj: ^Object, r: Stack_Row) {
	ctx := &app.kit.ctx
	c := &app.kit.stack
	name := STACK_ROW_NAMES[r]
	is_open := c.opened && c.object == obj.id && c.open == r
	open := is_open
	shown := stack_row_cage(r) || row_shown(&obj.stack, r)^
	toggles := make([dynamic]ui.Row_Toggle, 0, 2, context.temp_allocator)
	if !stack_row_cage(r) {
		append(&toggles, ui.Row_Toggle{name = fmt.tprintf("%s %s", "Hide" if shown else "Show", strings.to_lower(name, context.temp_allocator)), glyph = ui.ICON_EYE if shown else ui.ICON_EYE_OFF, faint = !shown})
	}
	append(&toggles, ui.Row_Toggle{name = fmt.tprintf("%s's menu", name), glyph = ui.ICON_MORE})
	parts := ui.Thumb_Row{glyph = STACK_ROW_GLYPHS[r], count = -1, compact = true, detail = stack_row_detail(app, obj, r), open = &open}
	row := ui.thumb_row(ctx, fmt.tprintf("%s##stack row %v", name, r), parts, selected = is_open, dim = !shown, all_toggles = toggles[:])
	if row.clicked do open = !open
	if open != is_open {
		c.object, c.open, c.opened = obj.id, r, open
	}
	more := len(toggles) - 1
	switch {
	case row.toggled == 0 && more == 1:
		s := obj.stack
		row_shown(&s, r)^ = !shown
		stack_set(app, obj, s, fmt.tprintf("%s %s", "Hide" if shown else "Show", strings.to_lower(name, context.temp_allocator)))
	case row.toggled == more:
		c.menu, c.menu_row, c.menu_at, c.menu_side, c.object = true, r, row_toggle_rect(ctx, row.rect, more, len(toggles)), .Below_End, obj.id
	case row.menu:
		c.menu, c.menu_row, c.menu_at, c.menu_side, c.object = true, r, {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0}, .Pointer, obj.id
	}
	if !(c.opened && c.object == obj.id && c.open == r) do return
	w := ui.fill_width(ctx)
	ui.begin(ctx, fmt.tprintf("stack body %v", r), {direction = .Column, gap = ui.SPACE_S, width = w})
	defer ui.end(ctx)
	switch r {
	case .Smooth: kit_cage_smooth(app, obj)
	case .Cage_Mirror: kit_cage_mirror(app, obj)
	case .Thickness: kit_cage_thickness(app, obj)
	case .Bevel: kit_cage_bevel(app, obj)
	case .Deform: kit_cage_deform(app, obj)
	case .Curve: kit_cage_curve(app, obj)
	case .Wrap: kit_cage_wrap(app, obj)
	case .Displace: kit_cage_displace(app, obj)
	case .Mirror: kit_stack_mirror(app, obj)
	case .Array: kit_stack_array(app, obj)
	case .Radial: kit_stack_radial(app, obj)
	case .Along: kit_stack_along(app, obj)
	}
}

// The card's foot: Add, which opens the menu of rows, and Apply, which bakes them (a
// cage's Apply to sculpt, as a cage's copies are drawn only); then how many copies draw.
@(private = "file")
kit_stack_foot :: proc(app: ^App, obj: ^Object, has: bool) {
	ctx := &app.kit.ctx
	c := &app.kit.stack
	w := ui.fill_width(ctx)
	half := (w - ui.SPACE_S) * 0.5
	ui.begin(ctx, "stack foot", {direction = .Row, gap = ui.SPACE_S, width = w})
	if ui.button(ctx, "Add##stack", variant = .Bordered, width = half if has else w, glyph = ui.ICON_PLUS) {
		c.add, c.add_at, c.object = !c.add, ctx.last_rect, obj.id
	}
	if has {
		if obj.cage != nil {
			_ = command_button(app, .Apply_Cage, label = "Apply to sculpt", variant = .Solid, tone = .Accent, width = half)
		} else {
			can := obj.voxel == nil && !app.stroke.active && stack_shows(app, obj)
			if ui.button(ctx, "Apply stack", variant = .Solid, tone = .Accent, width = half, enabled = can, reason = "Needs a shown row on a mesh object") {
				app.ui.scene_command = {kind = .Stack_Apply}
			}
		}
	}
	ui.end(ctx)
	if !has do return
	if n := len(stack_placings(app, obj)); n > 0 {
		line := fmt.tprintf("%d cop%s drawn. A stroke on any copy sculpts them all, at no extra cost.", n, "y" if n == 1 else "ies")
		if obj.cage != nil do line = fmt.tprintf("%d cop%s drawn. Apply to sculpt makes the cage a mesh, whose copies then apply.", n, "y" if n == 1 else "ies")
		ui.paragraph(ctx, line, color = ctx.theme.text_tertiary)
	}
}

// The Add menu and a row's menu, drawn over everything after the cards (new_ui.odin),
// each acting on the object it was opened on while it is still the selected one.
kit_stack_menus :: proc(app: ^App) {
	ctx := &app.kit.ctx
	c := &app.kit.stack
	obj := selected_object(app)
	if obj == nil || obj.id != c.object {
		c.add, c.menu = false, false
		return
	}
	if c.add && ui.popover_begin(ctx, "stack add menu", &c.add, c.add_at, .Below, {direction = .Column, gap = 0, padding = ui.MENU_PAD, width = ui.MENU_W}) {
		kit_stack_add_menu(app, obj)
		ui.popover_end(ctx)
	}
	if c.menu && ui.popover_begin(ctx, "stack row menu", &c.menu, c.menu_at, c.menu_side, {direction = .Column, gap = 0, padding = ui.MENU_PAD, width = ui.MENU_W}) {
		kit_stack_row_menu(app, obj, c.menu_row)
		ui.popover_end(ctx)
	}
}

// Every row the object can take, grouped as the card groups them; one it already holds
// is ticked and opens it instead, as each kind is in the stack once.
@(private = "file")
kit_stack_add_menu :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	t := ctx.theme
	c := &app.kit.stack
	hints := [Stack_Row]string {
		.Smooth      = "Steps of smoothing over the cage",
		.Cage_Mirror = "The cage mirrored across X",
		.Thickness   = "A shell of the cage's faces",
		.Bevel       = "Creased edges rounded",
		.Deform      = "Bent, twisted or tapered along an axis",
		.Curve       = "Laid along a curve object, following it",
		.Wrap        = "Hugging another object's surface",
		.Displace    = "Pushed in and out by a noise",
		.Mirror      = "The other half, clipped at the plane",
		.Array       = "Copies a step apart",
		.Radial      = "Copies turned round an axis",
		.Along       = "Copies laid along a curve object",
	}
	for group in 0 ..< 2 {
		if obj.cage != nil do ui.label(ctx, "SHAPE" if group == 0 else "COPIES", t.caption_size, t.text_tertiary, .Semibold)
		for r in Stack_Row {
			if stack_row_cage(r) != (group == 0) || !stack_row_fits(obj, r) do continue
			held := stack_row_in(app, obj, r)
			curves := (r != .Along && r != .Curve) || stack_first_curve(app, obj) != 0
			targets := r != .Wrap || cage_first_wrap(app, obj) != 0
			reason := "Draw a curve object first" if !curves else "Add an object to wrap onto first"
			if !ui.menu_item(ctx, fmt.tprintf("%s##stack add", STACK_ROW_NAMES[r]), glyph = STACK_ROW_GLYPHS[r], checked = held, enabled = held || (curves && targets), hint = hints[r], reason = reason) do continue
			if !held do stack_row_add(app, obj, r)
			c.object, c.open, c.opened, c.add = obj.id, r, true, false
		}
	}
}

// Adds row `r` with its starting values, one undo step (a cage's as a Cage_Look command).
stack_row_add :: proc(app: ^App, obj: ^Object, r: Stack_Row) {
	if stack_row_cage(r) {
		look := obj.cage.look
		size := cage_size(obj.cage)
		#partial switch r {
		case .Smooth: look.smooth = 1
		case .Cage_Mirror: look.live.mirror = {.X}
		case .Thickness: look.live.thickness, look.live.thickness_segments = 0.05 * size, max(look.live.thickness_segments, 1)
		case .Bevel: look.live.bevel, look.live.bevel_segments = 0.02 * size, max(look.live.bevel_segments, 1)
		case .Deform: look.live.deform, look.live.deform_amount = .Bend, cage_deform_start(.Bend)
		case .Curve: look.follow.curve, look.follow.curve_fit = stack_first_curve(app, obj), true
		case .Wrap: look.follow.wrap, look.follow.wrap_offset = cage_first_wrap(app, obj), 0
		case .Displace: look.live.displace, look.live.displace_scale = 0.02 * size, CAGE_DISPLACE_SCALE_START * size
		}
		app.ui.scene_command = {kind = .Cage_Look, look = look}
		return
	}
	s := obj.stack
	#partial switch r {
	case .Mirror: s.mirror = {added = true, shown = true, axes = {.X}}
	case .Array: s.array = STACK_ARRAY_DEFAULT
	case .Radial: s.radial = STACK_RADIAL_DEFAULT
	case .Along: s.along = {added = true, shown = true, count = 6, curve = stack_first_curve(app, obj)}
	}
	stack_set(app, obj, s, fmt.tprintf("Add %s", strings.to_lower(STACK_ROW_NAMES[r], context.temp_allocator)))
}

// A row's menu: Apply mirror on a cage's Mirror (its halves made real polygons), Reset to
// the starting values on a row of copies, and Remove; each an undo step.
@(private = "file")
kit_stack_row_menu :: proc(app: ^App, obj: ^Object, r: Stack_Row) {
	ctx := &app.kit.ctx
	c := &app.kit.stack
	if !stack_row_in(app, obj, r) {
		c.menu = false
		return
	}
	lower := strings.to_lower(STACK_ROW_NAMES[r], context.temp_allocator)
	if r == .Cage_Mirror && obj.cage.look.live.mirror != {} {
		if ui.menu_item(ctx, "Apply mirror##stack menu", glyph = ICON_SYMMETRY, keys = command_hint(app, .Tidy_Cage, int(Cage_Tidy.Apply_Mirror)), hint = "The mirrored half becomes the cage's own") {
			_ = command_run(app, .Tidy_Cage, int(Cage_Tidy.Apply_Mirror))
			c.menu = false
		}
	}
	if !stack_row_cage(r) && ui.menu_item(ctx, "Reset values##stack menu", glyph = ui.ICON_UNDO) {
		stack_row_add(app, obj, r)
		c.menu = false
	}
	if ui.menu_item(ctx, fmt.tprintf("Remove %s##stack menu", lower), glyph = ui.ICON_TRASH, tone = .Danger) {
		if stack_row_cage(r) {
			look := obj.cage.look
			#partial switch r {
			case .Smooth: look.smooth = 0
			case .Cage_Mirror: look.live.mirror = {}
			case .Thickness: look.live.thickness = 0
			case .Bevel: look.live.bevel = 0
			case .Deform: look.live.deform = .Off
			case .Curve: look.follow.curve = 0
			case .Wrap: look.follow.wrap = 0
			case .Displace: look.live.displace = 0
			}
			app.ui.scene_command = {kind = .Cage_Look, look = look}
		} else {
			s := obj.stack
			#partial switch r {
			case .Mirror: s.mirror = {}
			case .Array: s.array = {}
			case .Radial: s.radial = {}
			case .Along: s.along = {}
			}
			stack_set(app, obj, s, fmt.tprintf("Remove %s", lower))
		}
		if c.open == r do c.opened = false
		c.menu = false
	}
}

// One undo step for a body's change: a tap (`what`) at once, a drag at its release.
@(private = "file")
stack_body_changed :: proc(app: ^App, obj: ^Object, before: Stack, tapped: string) {
	if obj.stack == before do return
	if tapped == "" {
		stack_drag_changed(app, obj, before)
		return
	}
	now := obj.stack
	obj.stack = before
	stack_set(app, obj, now, tapped)
}

// A count as a drag value between − and +, each tap one more or one fewer. Returns the
// undo step's name for a tap, "" for a drag or nothing.
@(private = "file")
kit_stack_count :: proc(app: ^App, key: string, count: ^int, lo: int) -> (tapped: string) {
	ctx := &app.kit.ctx
	t := ctx.theme
	w := ui.fill_width(ctx)
	ui.begin(ctx, fmt.tprintf("stack count %s", key), {direction = .Row, gap = ui.SPACE_XS, width = w})
	defer ui.end(ctx)
	ui.begin(ctx, fmt.tprintf("stack count value %s", key), {direction = .Column, width = w - 2 * (t.target + ui.SPACE_XS)})
	v := f32(count^)
	if ui.drag_value(ctx, fmt.tprintf("Count##%s", key), &v, 0.05, f32(lo), STACK_COUNT_MAX, fmt.tprintf("%d", count^)) do count^ = int(math.round(v))
	ui.end(ctx)
	if ui.button(ctx, fmt.tprintf("Fewer##%s", key), width = t.target, glyph = ICON_MINUS, icon_only = true, enabled = count^ > lo) {
		count^ -= 1
		tapped = "Fewer copies"
	}
	if ui.button(ctx, fmt.tprintf("More##%s", key), width = t.target, glyph = ui.ICON_PLUS, icon_only = true, enabled = count^ < STACK_COUNT_MAX) {
		count^ += 1
		tapped = "More copies"
	}
	return
}

// X, Y and Z of `v` on one line, each a drag value a third of the width.
@(private = "file")
kit_stack_xyz :: proc(app: ^App, key: string, v: ^Vec3, per_point, lo, hi: f32, format: string) {
	ctx := &app.kit.ctx
	w := ui.fill_width(ctx)
	third := (w - 2 * ui.SPACE_XS) / 3
	ui.begin(ctx, fmt.tprintf("stack xyz %s", key), {direction = .Row, gap = ui.SPACE_XS, width = w})
	defer ui.end(ctx)
	axes := [3]string{"X", "Y", "Z"}
	for axis, i in axes {
		ui.begin(ctx, fmt.tprintf("stack xyz %s %d", key, i), {direction = .Column, width = third})
		_ = ui.drag_value(ctx, fmt.tprintf("%s##%s", axis, key), &v[i], per_point, lo, hi, fmt.tprintf(format, v[i]))
		ui.end(ctx)
	}
}

// Three axis buttons in a row, the picked one lit; returns the one tapped.
@(private = "file")
kit_stack_axis :: proc(app: ^App, key: string, on: sculpt.Symmetry, tip: string) -> (tapped: sculpt.Axis, ok: bool) {
	ctx := &app.kit.ctx
	w := ui.fill_width(ctx)
	third := (w - 2 * ui.SPACE_XS) / 3
	ui.begin(ctx, fmt.tprintf("stack axis %s", key), {direction = .Row, gap = ui.SPACE_XS, width = w})
	defer ui.end(ctx)
	for a in sculpt.Axis {
		if ui.toggle_button(ctx, fmt.tprintf("%v##%s", a, key), a in on, third, tooltip = fmt.tprintf(tip, a)) do tapped, ok = a, true
	}
	return
}

@(private = "file")
kit_stack_mirror :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	ui.caption(ctx, "PLANES")
	if a, ok := kit_stack_axis(app, "mirror", obj.stack.mirror.axes, "Mirror across the object's own %v plane"); ok {
		s := obj.stack
		s.mirror.axes ~= {a}
		stack_set(app, obj, s, "Mirror planes")
	}
	minus := obj.stack.mirror.minus
	if ui.switch_row(ctx, "Keep the − side##mirror", &minus) {
		s := obj.stack
		s.mirror.minus = minus
		stack_set(app, obj, s, "Mirror side")
	}
	if stack_mirror_on(obj) {
		ui.paragraph(ctx, fmt.tprintf("Symmetry across %s stays on for this object while the mirror shows, so the hidden half follows every stroke.", stack_axes_label(obj.stack.mirror.axes)), color = ctx.theme.text_tertiary)
	}
}

@(private = "file")
kit_stack_array :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	before := obj.stack
	a := &obj.stack.array
	tapped := kit_stack_count(app, "array", &a.count, 2)
	ui.caption(ctx, "EACH STEP MOVES")
	kit_stack_xyz(app, "array step", &a.offset, 0.01, -100, 100, "%.2f")
	ui.paragraph(ctx, "Or drag the arrow's tip in the view.", color = ctx.theme.text_tertiary)
	if kit_more(app, .Stack) {
		ui.caption(ctx, "EACH STEP TURNS")
		kit_stack_xyz(app, "array turn", &a.turn, 0.5, -360, 360, "%.0f°")
		_ = ui.drag_value(ctx, "Size each step##array", &a.grow, 0.002, STACK_GROW_MIN, STACK_GROW_MAX, fmt.tprintf("%.3f", a.grow))
		kit_more_end(app)
	}
	stack_body_changed(app, obj, before, tapped)
}

@(private = "file")
kit_stack_radial :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	before := obj.stack
	r := &obj.stack.radial
	tapped := kit_stack_count(app, "radial", &r.count, 2)
	ui.caption(ctx, "TURNS ROUND")
	if a, ok := kit_stack_axis(app, "radial", {r.axis}, "Turn the copies about the object's own %v axis"); ok && a != r.axis {
		r.axis = a
		tapped = "Radial axis"
	}
	ui.caption(ctx, "ABOUT THE POINT")
	kit_stack_xyz(app, "radial pivot", &r.pivot, 0.01, -100, 100, "%.2f")
	ui.paragraph(ctx, "Or drag the pivot's dot in the view.", color = ctx.theme.text_tertiary)
	stack_body_changed(app, obj, before, tapped)
}

// The first curve object of the scene other than `obj`, by id; 0 for none.
stack_first_curve :: proc(app: ^App, obj: ^Object) -> int {
	for o in app.scene.objects do if o != obj && o.curve != nil do return o.id
	return 0
}

// A curve object's name in the Along row's list: its own, or "Curve" and its place among
// the scene's curves.
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
	before := obj.stack
	l := &obj.stack.along
	tapped := kit_stack_count(app, "along", &l.count, 1)
	ui.caption(ctx, "RUNS ALONG THE CURVE")
	if a, ok := kit_stack_axis(app, "along", {l.axis}, "The object's own %v axis runs along the curve"); ok && a != l.axis {
		l.axis = a
		tapped = "Along axis"
	}
	stack_body_changed(app, obj, before, tapped)
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
	if obj == nil do return ""
	s := obj.stack
	parts := make([dynamic]string, 0, 3, context.temp_allocator)
	if cp := obj.cage; cp != nil {
		// A cage's own rows first, in the card's order.
		l := cp.look.live
		if cp.look.smooth > 0 do append(&parts, fmt.tprintf("Smooth %d", cp.look.smooth))
		if l.mirror != {} {
			axes: sculpt.Symmetry
			for a in poly.Mirror_Axis do if a in l.mirror do axes += {sculpt.Axis(int(a))}
			append(&parts, fmt.tprintf("Mirror %s", stack_axes_label(axes)))
		}
		if l.thickness > 0 do append(&parts, "Thickness")
		if l.bevel > 0 do append(&parts, "Bevel")
	}
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
	stack_take_shown(app, obj)
	history_record_swap(app, obj.id, before)
	if changed {
		report(app, .Stack, {.Undo}, "Applied the stack: %d vertices (%.0f ms)", object_vertex_count(obj), time.duration_milliseconds(time.tick_since(start)))
	} else {
		report(app, .Stack, {.Warning, .Undo}, "Nothing of the object was on the side to keep: the rows are taken out")
	}
	return true
}

// Takes the rows that show out of the object's stack, once they are baked into its mesh;
// a hidden row stays. The caller's swap step brings them back.
stack_take_shown :: proc(app: ^App, obj: ^Object) {
	if stack_mirror_on(obj) do obj.stack.mirror = {}
	if stack_array_on(obj) do obj.stack.array = {}
	if stack_radial_on(obj) do obj.stack.radial = {}
	if stack_along_on(app, obj) do obj.stack.along = {}
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

// Whether a row that changes what the object shows is on: a mirror, or copies.
stack_shows :: proc(app: ^App, obj: ^Object) -> bool {
	return obj != nil && (stack_mirror_on(obj) || stack_array_on(obj) || stack_radial_on(obj) || stack_along_on(app, obj))
}

// The most vertices a baked stack may hold, so every index fits in a u32 with room to
// spare for the writers' own copies (a glTF's seams).
STACK_BAKE_VERTICES_MAX :: 1 << 30

// The mesh of `positions` and `indices` (the object's shown level, in its own space) as
// its live stack shows it, for an export, the Blender link or a boolean, which take what
// the view shows: Mirror and weld across each mirror plane keeping its side
// (geom.mesh_symmetrize), then a copy at every Array, Radial and Along placing, with
// normals. With `from` given, each vertex's source vertex goes there, as
// geom.mesh_decimate's does, so paint and polygroups follow: a mirror image's vertex takes
// its kept vertex's, and a point the cut made the kept end of the edge it cut. `baked` is false,
// with nothing made, when no such row shows or the copies would pass
// STACK_BAKE_VERTICES_MAX; a mirror with nothing on its kept side is passed over, as the
// view shows nothing of it.
stack_bake :: proc(app: ^App, obj: ^Object, positions: []Vec3, indices: []u32, from: ^[dynamic]u32 = nil) -> (out: geom.Mesh, baked: bool) {
	if !stack_shows(app, obj) do return {}, false
	cur := geom.Mesh {
		positions = make([dynamic]Vec3, len(positions)),
		indices   = make([dynamic]u32, len(indices)),
		normals   = make([dynamic]Vec3, len(positions)),
	}
	copy(cur.positions[:], positions)
	copy(cur.indices[:], indices)
	origin := make([dynamic]u32, len(positions))
	defer delete(origin)
	for &o, v in origin do o = u32(v)
	if stack_mirror_on(obj) {
		m := obj.stack.mirror
		for a in sculpt.Axis {
			if a not_in m.axes do continue
			step_from: [dynamic]u32
			next, ok := geom.mesh_symmetrize(cur, int(a), !m.minus, &app.pool, out_from = &step_from)
			if !ok {
				delete(step_from)
				continue
			}
			for &f in step_from do f = origin[f]
			geom.mesh_destroy(&cur)
			delete(origin)
			cur, origin = next, step_from
		}
	}
	steps := stack_steps(app, obj)
	if len(steps) > 1 {
		n, m := len(cur.positions), len(cur.indices)
		if n * len(steps) > STACK_BAKE_VERTICES_MAX {
			geom.mesh_destroy(&cur)
			return {}, false
		}
		joined := geom.Mesh {
			positions = make([dynamic]Vec3, n * len(steps)),
			indices   = make([dynamic]u32, m * len(steps)),
			normals   = make([dynamic]Vec3, n * len(steps)),
		}
		joined_origin := make([dynamic]u32, n * len(steps))
		for step, k in steps {
			for p, v in cur.positions {
				q := step * [4]f32{p.x, p.y, p.z, 1}
				joined.positions[k * n + v] = q.xyz
			}
			for i, j in cur.indices do joined.indices[k * m + j] = i + u32(k * n)
			copy(joined_origin[k * n:][:n], origin[:])
		}
		geom.mesh_destroy(&cur)
		delete(origin)
		cur, origin = joined, joined_origin
	}
	geom.mesh_recompute_normals(&cur)
	if from != nil {
		clear(from)
		append(from, ..origin[:])
	}
	app.stack_bakes += 1
	return cur, true
}

// The shape of `obj` as shape_in gives it, in the space `into` places, with its live
// stack baked (stack_bake), as a boolean takes a marked object: each copy takes part.
stack_shape_in :: proc(app: ^App, obj: ^Object, into: Transform) -> geom.Mesh {
	if !stack_shows(app, obj) do return shape_in(obj, into)
	local := shape_in(obj, obj.transform)
	baked, ok := stack_bake(app, obj, local.positions[:], local.indices[:])
	if !ok {
		geom.mesh_destroy(&local)
		return shape_in(obj, into)
	}
	geom.mesh_destroy(&local)
	for &p in baked.positions do p = to_local(into, to_world(obj.transform, p))
	return baked
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
	USAGE :: "stack takes mirror x, array 4 2.2 0 0, radial 6 y, along 8 x, mirror off, show mirror, hide array, open array (or a cage's curve x, wrap 0, curve off, open deform, open displace, open curve, open wrap) or apply stack"
	if len(words) < 2 do return USAGE
	s := obj.stack
	is_row :: proc(w: string) -> bool {return w == "mirror" || w == "array" || w == "radial" || w == "along"}
	switch {
	case obj.cage != nil && words[0] == "curve" && len(words) == 2:
		// A cage laid along the scene's first curve, its axis along it, or taken off it.
		look := obj.cage.look
		switch words[1] {
		case "off": look.follow.curve = 0
		case "x", "y", "z":
			look.follow.curve = stack_first_curve(app, obj)
			if look.follow.curve == 0 do return "the scene has no curve object"
			look.follow.curve_axis = poly.Mirror_Axis(int(words[1][0] - 'x'))
			look.follow.curve_fit = true
		case: return "curve takes x, y, z or off"
		}
		app.ui.scene_command = {kind = .Cage_Look, look = look}
		return ""
	case obj.cage != nil && words[0] == "wrap" && len(words) == 2:
		// A cage wrapped onto the first object it can be, this far above it (a percentage
		// of the cage's size), or taken off it.
		look := obj.cage.look
		if words[1] == "off" {
			look.follow.wrap = 0
		} else {
			percent, ok := strconv.parse_f32(words[1])
			if !ok || abs(percent) > CAGE_WRAP_PERCENT_MAX do return fmt.tprintf("wrap takes off or a percentage from -%d to %d", CAGE_WRAP_PERCENT_MAX, CAGE_WRAP_PERCENT_MAX)
			look.follow.wrap = cage_first_wrap(app, obj)
			if look.follow.wrap == 0 do return "the scene has no object to wrap onto"
			look.follow.wrap_offset = percent / 100 * cage_size(obj.cage)
		}
		app.ui.scene_command = {kind = .Cage_Look, look = look}
		return ""
	case words[0] == "open" && (is_row(words[1]) || words[1] == "deform" || words[1] == "displace" || words[1] == "curve" || words[1] == "wrap") && len(words) == 2:
		// Opens the card on that row, as a tap on its line does, for its handle in the view
		// (a cage's Deform and Displace rows have none, but open the same way).
		r := Stack_Row.Mirror
		switch words[1] {
		case "array": r = .Array
		case "radial": r = .Radial
		case "along": r = .Along
		case "deform": r = .Deform
		case "displace": r = .Displace
		case "curve": r = .Curve
		case "wrap": r = .Wrap
		}
		if !stack_row_in(app, obj, r) do return fmt.tprintf("the object has no %s row", words[1])
		app.kit.stack.object, app.kit.stack.open, app.kit.stack.opened = obj.id, r, true
		card_open(app, .Stack)
		return ""
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
	case words[0] == "radial" && (len(words) == 3 || len(words) == 7 && words[3] == "pivot"):
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
		if len(words) == 7 {
			for k in 0 ..< 3 {
				v, v_ok := strconv.parse_f32(words[4 + k])
				if !v_ok || !(abs(v) <= 100) do return fmt.tprintf("%q is not a pivot from -100 to 100", words[4 + k])
				r.pivot[k] = v
			}
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
