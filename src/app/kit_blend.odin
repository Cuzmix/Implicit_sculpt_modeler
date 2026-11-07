package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// The Smooth blend row of the Live stack card (design: .claude/project-memory/notes/
// smooth-blend/design.md, mock A): WITH as Chosen or Same folder, the chosen objects as
// chips (a tap takes one out) and Add, a checklist of the scene's objects each tagged with
// how it sits against this one; then Radius and Strength. The card keeps no sculpt state:
// every change is a stack_set (one undo step, a slider's drag at its release).

// How another object sits against this one, for the checklist: touching when their boxes
// meet, near when the gap between them is within twice the radius, apart beyond.
Blend_Contact :: enum u8 {
	Touching,
	Near,
	Apart,
}

BLEND_CONTACT_NAMES := [Blend_Contact]string {
	.Touching = "touching",
	.Near     = "near",
	.Apart    = "apart",
}

blend_contact :: proc(a, b: ^Object, radius: f32) -> Blend_Contact {
	ba, bb := object_world_bounds(a), object_world_bounds(b)
	gap: f32
	for k in 0 ..< 3 do gap = max(gap, ba.lo[k] - bb.hi[k], bb.lo[k] - ba.hi[k])
	if gap <= 0 do return .Touching
	return .Near if gap <= 2 * radius else .Apart
}

// Why another object cannot be joined, "" when it can: a cage has its own rows, clay
// remakes its vertices, a curve has no surface.
blend_refusal :: proc(obj: ^Object) -> string {
	if obj.cage != nil do return "a cage object"
	if obj.voxel != nil do return "a clay object"
	if !object_draws_triangles(obj) do return "no surface"
	return ""
}

// The object a new row joins at first: the first that touches it, else the nearest by
// box, among those it can join; nil when the scene has none.
blend_first_partner :: proc(app: ^App, obj: ^Object) -> ^Object {
	best: ^Object
	best_gap := max(f32)
	ba := object_world_bounds(obj)
	for o in app.scene.objects {
		if o == obj || blend_refusal(o) != "" || !object_shown(app, o) do continue
		bb := object_world_bounds(o)
		gap: f32
		for k in 0 ..< 3 do gap = max(gap, ba.lo[k] - bb.hi[k], bb.lo[k] - ba.hi[k])
		if gap < best_gap do best, best_gap = o, gap
	}
	return best
}

// Why the object's blend does not show now, "" when nothing stops it: what blend_fits
// refuses, in the row's words.
blend_paused :: proc(app: ^App, obj: ^Object) -> string {
	if !object_shown(app, obj) do return "Paused while the object is hidden"
	if obj.levels.hd.window != nil do return "Paused while the HD window is open"
	lv := sculpt.levels_current(&obj.levels)
	if lv.sculptor.dyn != nil do return "Paused: dynamic topology"
	return ""
}

// The row's line under its name: whom it joins and at what radius, or why it shows nothing.
blend_row_detail :: proc(app: ^App, obj: ^Object) -> string {
	b := obj.stack.blend
	if why := blend_paused(app, obj); why != "" do return why
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	if b.folder {
		if obj.folder == 0 do return "Same folder, but the object is in none"
		append(&names, "its folder")
	} else {
		for id in b.with {
			if id == 0 do continue
			if o := object_by_id(app, int(id)); o != nil do append(&names, object_label(o))
		}
		if len(names) == 0 do return "No object chosen"
	}
	with := names[0] if len(names) == 1 else fmt.tprintf("%s and %d more", names[0], len(names) - 1)
	return fmt.tprintf("With %s · radius %.2f", with, b.radius)
}

kit_stack_blend :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	t := ctx.theme
	c := &app.kit.stack
	ui.caption(ctx, "WITH")
	b := obj.stack.blend
	if pick := ui.tabs(ctx, "With##blend", {"Chosen", "Same folder"}, 1 if b.folder else 0); pick != (1 if b.folder else 0) {
		s := obj.stack
		s.blend.folder = pick == 1
		stack_set(app, obj, s, "Blend with")
	}
	if b.folder {
		// The folder's other objects, read live, greyed as they are not chosen one by one.
		names := make([dynamic]string, 0, 4, context.temp_allocator)
		for o in app.scene.objects do if stack_blend_names(obj, o) && blend_refusal(o) == "" do append(&names, object_label(o))
		line := "The object is in no folder: put it in one with the objects to join." if obj.folder == 0 else ("Nothing else is in its folder yet." if len(names) == 0 else strings.join(names[:], ", ", context.temp_allocator))
		ui.paragraph(ctx, line, color = t.text_tertiary)
	} else {
		// The chosen objects as chips, as many to a line as fit, then Add.
		w := ui.fill_width(ctx)
		line_w: f32 = 0
		line := 0
		open_line :: proc(ctx: ^ui.Context, n: int, w: f32) {
			ui.begin(ctx, fmt.tprintf("blend chips %d", n), {direction = .Row, gap = ui.SPACE_XS, width = w})
		}
		open_line(ctx, line, w)
		chip_width :: proc(ctx: ^ui.Context, label: string) -> f32 {
			t := ctx.theme
			return ui.text_width(ctx, label, t.text_size, .Semibold) + t.icon_small + 6 + 28
		}
		place :: proc(ctx: ^ui.Context, line: ^int, line_w: ^f32, cw, w: f32) {
			if line_w^ > 0 && line_w^ + ui.SPACE_XS + cw > w {
				ui.end(ctx)
				line^ += 1
				ui.begin(ctx, fmt.tprintf("blend chips %d", line^), {direction = .Row, gap = ui.SPACE_XS, width = w})
				line_w^ = 0
			}
			line_w^ += cw + (ui.SPACE_XS if line_w^ > 0 else 0)
		}
		for id, k in b.with {
			if id == 0 do continue
			o := object_by_id(app, int(id))
			label := object_label(o) if o != nil else "Gone"
			cw := min(chip_width(ctx, label), w)
			place(ctx, &line, &line_w, cw, w)
			if ui.button(ctx, fmt.tprintf("%s##blend with %d", label, k), variant = .Bordered, width = cw, glyph = ui.ICON_CLOSE) {
				s := obj.stack
				s.blend.with[k] = 0
				stack_set(app, obj, s, "Blend with")
			}
		}
		aw := chip_width(ctx, "Add")
		place(ctx, &line, &line_w, aw, w)
		if ui.button(ctx, "Add##blend with", variant = .Flat, width = aw, glyph = ui.ICON_PLUS) {
			c.with_menu, c.with_at, c.object = !c.with_menu, ctx.last_rect, obj.id
		}
		ui.end(ctx)
	}
	before := obj.stack
	bb := &obj.stack.blend
	_ = ui.slider(ctx, "Radius##blend", &bb.radius, STACK_BLEND_RADIUS_MIN, STACK_BLEND_RADIUS_MAX, .Logarithmic, fmt.tprintf("%.3f", bb.radius))
	strength := bb.strength * 100
	if ui.slider(ctx, "Strength##blend", &strength, 0, 100, .Linear, fmt.tprintf("%.0f%%", strength)) do bb.strength = strength / 100
	stack_body_changed(app, obj, before, "")
	if why := blend_paused(app, obj); why != "" {
		ui.paragraph(ctx, fmt.tprintf("%s: the blend shows again once it ends.", why), color = t.text_tertiary)
	} else {
		ui.paragraph(ctx, "Both objects are drawn joined; what they hold stays as it is.", color = t.text_tertiary)
	}
}

// The checklist Add opens: every other object of the scene, those touching first, each
// tagged with how it sits against this one; one tap joins or leaves it. One the row cannot
// join is dimmed with why.
kit_blend_with_menu :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	t := ctx.theme
	b := obj.stack.blend
	Entry :: struct {
		obj:     ^Object,
		contact: Blend_Contact,
	}
	entries := make([dynamic]Entry, 0, len(app.scene.objects), context.temp_allocator)
	for o in app.scene.objects {
		if o == obj || o.curve != nil do continue
		append(&entries, Entry{o, blend_contact(obj, o, b.radius) if blend_refusal(o) == "" else .Apart})
	}
	// Touching first, then near, then apart, each in the scene's order.
	for i in 1 ..< len(entries) {
		for j := i; j > 0 && entries[j].contact < entries[j - 1].contact; j -= 1 do entries[j], entries[j - 1] = entries[j - 1], entries[j]
	}
	if len(entries) == 0 {
		ui.paragraph(ctx, "The scene has no other object to join.", color = t.text_tertiary)
		return
	}
	for e in entries {
		held := stack_blend_names(obj, e.obj)
		why := blend_refusal(e.obj)
		tag := why if why != "" else BLEND_CONTACT_NAMES[e.contact]
		color := t.accent if why == "" && e.contact == .Touching else t.text_tertiary
		if !ui.menu_item(ctx, fmt.tprintf("%s##blend pick %d", object_label(e.obj), e.obj.id), checked = held, enabled = why == "", tag = tag, tag_color = color, reason = fmt.tprintf("A blend cannot join %s", why)) do continue
		s := obj.stack
		if held {
			for &id in s.blend.with do if int(id) == e.obj.id do id = 0
		} else {
			placed := false
			for &id in s.blend.with do if id == 0 && !placed {
				id = i32(e.obj.id)
				placed = true
			}
			if !placed {
				report(app, .Stack, {.Warning}, "A blend joins at most %d objects: take one out first", STACK_BLEND_WITH_MAX)
				continue
			}
		}
		stack_set(app, obj, s, "Blend with")
	}
}

// On an object another object's row joins, though it has no row of its own: a line saying
// so, as both sides are drawn joined.
kit_blend_joined :: proc(app: ^App, obj: ^Object) {
	if obj.stack.blend.added do return
	names := make([dynamic]string, 0, 2, context.temp_allocator)
	for o in app.scene.objects do if stack_blend_on(o) && stack_blend_names(o, obj) do append(&names, object_label(o))
	if len(names) == 0 do return
	ctx := &app.kit.ctx
	ui.paragraph(ctx, fmt.tprintf("Joined with %s (%s Smooth blend).", strings.join(names[:], ", ", context.temp_allocator), "its" if len(names) == 1 else "their"), color = ctx.theme.text_tertiary)
}
