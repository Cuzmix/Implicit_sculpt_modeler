package main

import "core:fmt"
import "core:strings"
import "core:time"

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
// Mirror draws the object clipped at its own plane through its origin on each axis, and
// its image across the plane, as Blender's Mirror with Clipping does; nothing is cut, so
// the levels, the mask, the layers and an HD window stay. The half it hides is still the
// object's and the brush's symmetry is on across the plane while the row shows (locked:
// brush_symmetry), so the hidden half follows every stroke and a press on the image
// sculpts the hidden half under it, which symmetry mirrors back. Apply is Mirror and weld.

Stack :: struct {
	mirror: Stack_Mirror,
}

// A row is in the stack while `added`; `shown` is its eye.
Stack_Mirror :: struct {
	added, shown: bool,
	axes:         sculpt.Symmetry,
	minus:        bool, // keep and show the - side instead of the + side
}

// Undo's copy of a stack before and after a change, owned by its History entry.
Stack_Step :: struct {
	before, after: Stack,
}

// Whether the object's Mirror row shows: added, its eye open, and at least one plane.
stack_mirror_on :: proc(obj: ^Object) -> bool {
	m := obj.stack.mirror
	return m.added && m.shown && m.axes != {} && obj.cage == nil
}

// The placings of the object's copies, in its own space, its own (the identity) left
// out: the mirror images across each plane and their combinations (X and Z give three).
// Each is a similarity, the mirror's an odd number of reflections.
stack_placings :: proc(obj: ^Object, allocator := context.temp_allocator) -> [dynamic]render.Mat4 {
	out := make([dynamic]render.Mat4, 0, 8, allocator)
	if !stack_mirror_on(obj) do return out
	list := make([dynamic]render.Mat4, 0, 8, context.temp_allocator)
	append(&list, render.Mat4(1))
	for a in sculpt.Axis {
		if a not_in obj.stack.mirror.axes do continue
		flip := render.Mat4(1)
		flip[int(a), int(a)] = -1
		count := len(list)
		for k in 0 ..< count do append(&list, flip * list[k])
	}
	for m in list[1:] do append(&out, m)
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
		placings := stack_placings(obj)
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

// Sets the object's stack to `s` as one undo step named `what`, when it changes it.
stack_set :: proc(app: ^App, obj: ^Object, s: Stack, what: string) {
	if obj.stack == s do return
	step := new(Stack_Step)
	step^ = {obj.stack, s}
	obj.stack = s
	app.scene_edits += 1
	history_push(app, History_Entry{id = obj.id, kind = .Stack, what = what, at = time.tick_now(), stack = step})
}

// Undo or redo of a .Stack entry: the stack as it was on the other side.
stack_step_apply :: proc(app: ^App, obj: ^Object, step: ^Stack_Step, back: bool) {
	obj.stack = step.before if back else step.after
	app.scene_edits += 1
}

// What the stack writes into the object's bytes (object_put_bytes), read back by
// stack_get; a damaged one is refused.
stack_put :: proc(out: ^[dynamic]u8, s: Stack) {
	m := s.mirror
	bits := u8(m.added) | u8(m.shown) << 1 | u8(m.minus) << 2
	append(out, bits, transmute(u8)m.axes)
}

stack_get :: proc(bytes: []u8) -> (s: Stack, ok: bool) {
	if len(bytes) != 2 do return
	bits, axes := bytes[0], bytes[1]
	if bits > 7 || axes > 7 do return
	s.mirror = {added = bits & 1 != 0, shown = bits & 2 != 0, minus = bits & 4 != 0, axes = transmute(sculpt.Symmetry)axes}
	return s, true
}

STACK_BYTES :: 2

// The Live stack card (Card.Stack): the selected object's rows, each with its eye, its
// settings, Apply and Remove, then what can be added.
kit_stack :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	t := ctx.theme
	if obj.cage != nil {
		ui.paragraph(ctx, "A cage's live rows (Mirror, Thickness, Bevel creases) are in the Model palette for now.")
		return
	}
	if obj.voxel == nil && object_draws_triangles(obj) == false {
		ui.paragraph(ctx, "A curve shows no surface to copy.")
		return
	}
	s := obj.stack
	m := &s.mirror
	if !m.added {
		ui.paragraph(ctx, "Rows here change how the object is shown, not what it holds: switch them off, tune them or apply them at any time. Copies cost a stroke nothing.")
		if ui.button(ctx, "Add Mirror", glyph = ICON_SYMMETRY, tone = .Accent) {
			m^ = {added = true, shown = true, axes = {.X}}
			stack_set(app, obj, s, "Add mirror")
		}
		return
	}
	ui.label(ctx, "Mirror", t.text_size, t.text, .Semibold)
	shown := m.shown
	if ui.switch_row(ctx, "Show##mirror", &shown) {
		m.shown = shown
		stack_set(app, obj, s, "Show mirror" if shown else "Hide mirror")
		s = obj.stack
	}
	ui.begin(ctx, "stack mirror axes", {direction = .Row})
	for a in sculpt.Axis {
		name := fmt.tprintf("%v##mirror", a)
		if ui.toggle_button(ctx, name, a in m.axes, 48, tooltip = fmt.tprintf("Mirror across the object's own %v plane", a)) {
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
		s = obj.stack
	}
	if stack_mirror_on(obj) {
		ui.paragraph(ctx, fmt.tprintf("Symmetry across %s stays on for this object while the mirror shows, so the hidden half follows every stroke. Apply welds the halves (Mirror and weld): levels and mask go, Ctrl+Z brings them back.", stack_axes_label(m.axes)))
	}
	ui.begin(ctx, "stack mirror actions", {direction = .Row})
	if ui.button(ctx, "Apply##mirror", enabled = m.axes != {} && obj.voxel == nil && !app.stroke.active, reason = "Needs a plane and a mesh object") {
		app.ui.scene_command = {kind = .Stack_Apply}
	}
	if ui.button(ctx, "Remove##mirror", tone = .Danger) {
		m^ = {}
		stack_set(app, obj, s, "Remove mirror")
	}
	ui.end(ctx)
	kit_last_result(app, .Stack)
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

// The card's line: what the stack holds.
stack_summary :: proc(obj: ^Object) -> string {
	if obj == nil || !obj.stack.mirror.added do return ""
	m := obj.stack.mirror
	if !m.shown do return "Mirror (hidden)"
	return fmt.tprintf("Mirror %s", stack_axes_label(m.axes))
}

// Apply of the Mirror row: Mirror and weld across each of its planes, keeping its side,
// one swap step with the row taken out, so Undo brings back the mirror and what it hid.
// False only when rebuilding the object failed.
stack_apply_mirror :: proc(app: ^App, obj: ^Object) -> bool {
	m := obj.stack.mirror
	if !m.added || m.axes == {} || obj.voxel != nil || obj.cage != nil do return true
	before := history_snapshot(app, obj, "apply mirror")
	start := time.tick_now()
	changed := false
	for a in m.axes {
		did, ok := object_symmetrize(app, obj, int(a), !m.minus)
		if !ok {
			history_snapshot_drop(before)
			return false
		}
		changed ||= did
	}
	obj.stack.mirror = {}
	history_record_swap(app, obj.id, before)
	if changed {
		report(app, .Stack, {.Undo}, "Applied the mirror across %s (%.0f ms)", stack_axes_label(m.axes), time.duration_milliseconds(time.tick_since(start)))
	} else {
		report(app, .Stack, {.Warning, .Undo}, "Nothing of the object was on the side to keep: the mirror is taken out")
	}
	return true
}

// The script verb `stack`: "mirror x" (any of x, y and z together, "-x" style for the -
// side), "mirror off", "hide mirror", "show mirror" or "apply mirror". What went wrong, or
// "" when it did what it says.
stack_script :: proc(app: ^App, obj: ^Object, text: string) -> string {
	if obj == nil do return "nothing is selected"
	words := strings.fields(text, context.temp_allocator)
	if len(words) != 2 do return "stack takes two words: mirror x, mirror off, show mirror, hide mirror or apply mirror"
	s := obj.stack
	switch {
	case words[0] == "mirror" && words[1] == "off":
		s.mirror = {}
	case words[0] == "mirror":
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
	case words[1] != "mirror":
		return "only the mirror row exists so far"
	case words[0] == "show" || words[0] == "hide":
		if !s.mirror.added do return "the object has no mirror row"
		s.mirror.shown = words[0] == "show"
	case words[0] == "apply":
		if !s.mirror.added do return "the object has no mirror row"
		app.ui.scene_command = {kind = .Stack_Apply}
		return ""
	case:
		return fmt.tprintf("%q is not show, hide or apply", words[0])
	}
	stack_set(app, obj, s, "Live stack")
	return ""
}
