package main

import "core:math"

import "../geom"
import "../gizmo"
import "../ui"

// The feedback flashes (the overhaul's round 3, Motion II): a moment of light that says
// where a command landed, as Procreate's undo flash and Blender's selection outline do, so
// a change too small or too far off to see still shows that it happened and where. The
// box of what an undo or redo changed glows once; a mask command sweeps a soft band across
// the object; a newly selected object's outline draws in around it; a save puts a tick
// beside the file block's status. Each is drawn over the viewport or the bar, never into
// the model, and each is a kind in Settings > Interface > Motion. Reduced keeps them as
// fades in place; Off, or the kind turned off, drops them.

UNDO_FLASH_TIME :: 0.35
MASK_WIPE_TIME :: 0.3
SELECTION_TIME :: 0.45
SAVE_TICK_TIME :: 1.4
// How many frames an undo waits for the frame's upload to say what it changed, before
// the flash falls back to the whole object (a placing, or a step the upload never sees).
UNDO_FLASH_WAIT :: 3

// One flash: when it began on the interface's clock, and on what.
Flash :: struct {
	on:  bool,
	at:  f64,
	id:  int, // the object
	box: geom.Aabb, // in the scene's space
}

Flashes :: struct {
	undo, mask, selection: Flash,
	undo_wait:     int, // frames left to see what an undo changed (undo.box gathers it)
	saved:         Flash,
	// The object selected last frame, so a new selection is seen; `seen` false after a
	// scene opens, so what an open selects does not flash.
	selected_id:   int,
	selected_seen: bool,
	// Flashes begun, for the exit stats.
	undos, masks, selections, saves: int,
}

// How far along flash `f` of kind `k` is, 0 to 1, and whether it shows now; it ends
// itself once run, and never shows with its kind's motion off.
flash_progress :: proc(app: ^App, f: ^Flash, k: Motion_Kind, duration: f32) -> (t: f32, ok: bool) {
	if !f.on do return
	run := ui.motion_duration(&app.kit.ctx, motion_class(k), duration)
	t = f32(app.kit.ctx.time - f.at) / max(run, 1e-6)
	if run <= 0 || t >= 1 || t < 0 {
		f.on = false
		return 0, false
	}
	return t, true
}

// Starts flash `f` of kind `k` on object `id`'s `box`, unless that kind of motion is off;
// whether it started.
@(private = "file")
flash_start :: proc(app: ^App, f: ^Flash, k: Motion_Kind, id: int, box: geom.Aabb) -> bool {
	if ui.motion_duration(&app.kit.ctx, motion_class(k), 1) <= 0 do return false
	f^ = {on = true, at = app.kit.ctx.time, id = id, box = box}
	return true
}

// After an undo or redo stepped object `id`: the frame's upload says what it changed
// (flash_damage), and the flash starts once it has (flash_frame_end).
flash_undo_begin :: proc(app: ^App, id: int) {
	f := &app.flashes
	if ui.motion_duration(&app.kit.ctx, motion_class(.Undo_Flash), 1) <= 0 do return
	f.undo = {id = id, box = geom.AABB_EMPTY}
	f.undo_wait = UNDO_FLASH_WAIT
}

// The part of object `obj` this frame's upload changed, `damage` in its own space, for an
// undo flash waiting on it.
flash_damage :: proc(app: ^App, obj: ^Object, damage: geom.Aabb) {
	f := &app.flashes
	if f.undo_wait <= 0 || obj.id != f.undo.id || damage.lo.x > damage.hi.x do return
	f.undo.box = geom.aabb_union(f.undo.box, box_to_world(obj, damage))
}

// At the end of the frame's uploads: an undo flash that has seen what changed starts,
// and one that waited its frames out flashes the whole object.
flash_frame_end :: proc(app: ^App) {
	f := &app.flashes
	if f.undo_wait <= 0 do return
	box := f.undo.box
	f.undo_wait -= 1
	if box.lo.x > box.hi.x {
		if f.undo_wait > 0 do return
		obj := object_by_id(app, f.undo.id)
		if obj == nil do return
		box = flash_object_box(obj)
		if box.lo.x > box.hi.x do return
	}
	f.undo_wait = 0
	if flash_start(app, &f.undo, .Undo_Flash, f.undo.id, box) do f.undos += 1
}

// After a mask command changed object `obj`'s mask.
flash_mask :: proc(app: ^App, obj: ^Object) {
	box := flash_object_box(obj)
	if box.lo.x > box.hi.x do return
	if flash_start(app, &app.flashes.mask, .Mask_Wipe, obj.id, box) do app.flashes.masks += 1
}

// After a save of the scene.
flash_saved :: proc(app: ^App) {
	if flash_start(app, &app.flashes.saved, .Save_Tick, 0, {}) do app.flashes.saves += 1
}

// After a scene opened or a new one began: what it selects is not a new selection.
flash_scene_opened :: proc(app: ^App) {
	app.flashes.selected_seen = false
}

// Once a frame: a different object selected than last frame outlines itself.
flash_selection_frame :: proc(app: ^App) {
	f := &app.flashes
	id := -1
	if obj := selected_object(app); obj != nil do id = obj.id
	if !f.selected_seen || id == f.selected_id {
		f.selected_id, f.selected_seen = id, true
		return
	}
	f.selected_id = id
	obj := selected_object(app)
	if obj == nil {
		f.selection.on = false
		return
	}
	box := flash_object_box(obj)
	if box.lo.x > box.hi.x do return
	if flash_start(app, &f.selection, .Selection, id, box) do f.selections += 1
}

// Object `obj`'s box in the scene's space: its clay's surface, or its sculptor's chunks.
flash_object_box :: proc(obj: ^Object) -> geom.Aabb {
	if vp := obj.voxel; vp != nil {
		local := geom.AABB_EMPTY
		for c in vp.clay.surface.chunks do local = geom.aabb_union(local, c.bounds)
		if local.lo.x > local.hi.x do return local
		return box_to_world(obj, local)
	}
	return object_world_bounds(obj)
}

// Box `b` in object `obj`'s own space as a box in the scene's, around its eight corners
// placed.
@(private = "file")
box_to_world :: proc(obj: ^Object, b: geom.Aabb) -> geom.Aabb {
	model := transform_matrix(obj.transform)
	world := geom.AABB_EMPTY
	for corner in 0 ..< 8 {
		p := Vec3{b.hi.x if corner & 1 != 0 else b.lo.x, b.hi.y if corner & 2 != 0 else b.lo.y, b.hi.z if corner & 4 != 0 else b.lo.z}
		q := model * [4]f32{p.x, p.y, p.z, 1}
		geom.aabb_grow(&world, q.xyz)
	}
	return world
}

// Box `b`'s corners on the viewport of `size` through `view_proj`, grown into `lo` and `hi`
// for those in front of the camera; whether any was.
@(private = "file")
grow_screen_box :: proc(view_proj: matrix[4, 4]f32, b: geom.Aabb, size: [2]f32, lo, hi: ^[2]f32) -> (ok: bool) {
	for corner in 0 ..< 8 {
		p := Vec3{b.hi.x if corner & 1 != 0 else b.lo.x, b.hi.y if corner & 2 != 0 else b.lo.y, b.hi.z if corner & 4 != 0 else b.lo.z}
		q, front := gizmo.project(view_proj, p, size)
		if !front do continue
		lo^ = {min(lo.x, q.x), min(lo.y, q.y)}
		hi^ = {max(hi.x, q.x), max(hi.y, q.y)}
		ok = true
	}
	return
}

// The rectangle on the viewport of `size` round a flash: its object's surface, from up
// to FLASH_SAMPLES of its points projected (with `whole`, all of them; else those inside
// the box it was given), which hugs the outline as no box in the scene's space can once
// perspective spreads its corners; else, when too few points fall in it, the box's own
// corners. A box filling the view says nothing about where, so the view's edge bounds it.
flash_screen_box :: proc(app: ^App, f: Flash, size: [2]f32, whole: bool) -> (lo, hi: [2]f32, ok: bool) {
	FLASH_SAMPLES :: 4096
	view_proj := view_proj_of(app, size)
	lo, hi = {math.F32_MAX, math.F32_MAX}, {-math.F32_MAX, -math.F32_MAX}
	if obj := object_by_id(app, f.id); obj != nil {
		points := obj.voxel.clay.surface.mesh.positions[:] if obj.voxel != nil else object_mesh(obj).positions[:]
		model := transform_matrix(obj.transform)
		step := max(len(points) / FLASH_SAMPLES, 1)
		inside := 0
		for i := 0; i < len(points); i += step {
			w := (model * [4]f32{points[i].x, points[i].y, points[i].z, 1}).xyz
			if !whole && (w.x < f.box.lo.x || w.y < f.box.lo.y || w.z < f.box.lo.z || w.x > f.box.hi.x || w.y > f.box.hi.y || w.z > f.box.hi.z) do continue
			q, front := gizmo.project(view_proj, w, size)
			if !front do continue
			lo = {min(lo.x, q.x), min(lo.y, q.y)}
			hi = {max(hi.x, q.x), max(hi.y, q.y)}
			inside += 1
		}
		ok = inside >= (1 if whole else 16)
	}
	if !ok {
		lo, hi = {math.F32_MAX, math.F32_MAX}, {-math.F32_MAX, -math.F32_MAX}
		ok = grow_screen_box(view_proj, f.box, size, &lo, &hi)
	}
	lo = {max(lo.x, -8), max(lo.y, -8)}
	hi = {min(hi.x, size.x + 8), min(hi.y, size.y + 8)}
	return lo, hi, ok && hi.x > lo.x && hi.y > lo.y
}

// The flashes over the viewport, under the tools' own marks.
draw_flashes :: proc(app: ^App, o: Overlay, size: [2]f32) {
	f := &app.flashes
	accent := o.ctx.theme.accent
	reduced := o.ctx.motion != .Full
	if t, ok := flash_progress(app, &f.undo, .Undo_Flash, UNDO_FLASH_TIME); ok {
		if lo, hi, seen := flash_screen_box(app, f.undo, size, false); seen {
			// Up at once, then fading: the glow is the answer, so it is brightest first.
			fade := 1 - ui.ease(.Out_Quad, t)
			pad := 6 * o.scale
			overlay_rect(o, lo - pad, hi + pad, 10 * o.scale, ui.color_fade(accent, 0.25 * fade), ui.color_fade(accent, 0.7 * fade), 2 * o.scale)
		}
	}
	if t, ok := flash_progress(app, &f.mask, .Mask_Wipe, MASK_WIPE_TIME); ok {
		if lo, hi, seen := flash_screen_box(app, f.mask, size, true); seen {
			if reduced {
				draw_mask_band(o, lo, hi, 0, 0, ui.color_fade(accent, 0.25 * (1 - t)))
			} else {
				// A soft band of light passing over the object, left to right.
				band := (hi.x - lo.x) * 0.4
				mid := lo.x - band * 0.5 + (hi.x - lo.x + band) * ui.ease(.In_Out_Cubic, t)
				STRIPS :: 24
				for i in 0 ..< STRIPS {
					// A smooth hump over the band: nothing at its edges, most in its middle.
					w := math.sin((f32(i) + 0.5) / STRIPS * math.PI)
					x := mid - band * 0.5 + band * f32(i) / STRIPS
					draw_mask_band(o, lo, hi, x, x + band / STRIPS, ui.color_fade(accent, 0.4 * w * w))
				}
			}
		}
	}
	if t, ok := flash_progress(app, &f.selection, .Selection, SELECTION_TIME); ok {
		if lo, hi, seen := flash_screen_box(app, f.selection, size, true); seen {
			// Drawing in from a little way out to just round the object, and fading as it
			// lands, so it points without staying.
			k := ui.ease(.Out_Cubic, t)
			pad := (6 + (0 if reduced else 18 * (1 - k))) * o.scale
			fade := 1 - t * t
			overlay_rect(o, lo - pad, hi + pad, 12 * o.scale, {}, ui.color_fade(accent, 0.9 * fade), 2 * o.scale)
		}
	}
}

// The slice from `x0` to `x1` of the ellipse inside the rectangle from `lo` to `hi`
// (all of it when `x1` is not past `x0`), filled: the mask wipe's light keeps to
// the object's rounded outline rather than its square box.
@(private = "file")
draw_mask_band :: proc(o: Overlay, lo, hi: [2]f32, x0, x1: f32, color: ui.Color) {
	center, radius := (lo + hi) * 0.5, (hi - lo) * 0.5
	a, b := max(x0, lo.x), min(x1, hi.x)
	if x1 <= x0 do a, b = lo.x, hi.x
	if b <= a || color.a == 0 do return
	STEPS :: 8
	points: [2 * (STEPS + 1)][2]f32
	for i in 0 ..= STEPS {
		x := a + (b - a) * f32(i) / STEPS
		u := clamp((x - center.x) / radius.x, -1, 1)
		h := radius.y * math.sqrt(1 - u * u)
		points[i] = {x, center.y - h}
		points[2 * STEPS + 1 - i] = {x, center.y + h}
	}
	overlay_fill(o, points[:], color)
}

// The tick beside the file block's status after a save, at `p` (its middle) and `size`
// across: it grows on with a small overshoot, holds, then fades.
draw_save_tick :: proc(app: ^App, p: [2]f32, size: f32) {
	ctx := &app.kit.ctx
	t, ok := flash_progress(app, &app.flashes.saved, .Save_Tick, SAVE_TICK_TIME)
	if !ok do return
	elapsed := t * SAVE_TICK_TIME
	GROW :: 0.25
	FADE :: 0.5
	in_ := clamp(elapsed / GROW, 0, 1)
	alpha := ui.ease(.Out_Quad, in_) * clamp((SAVE_TICK_TIME - elapsed) / FADE, 0, 1)
	scale: f32 = 1
	if ctx.motion == .Full do scale = 0.4 + 0.6 * ui.ease(.Out_Back, in_)
	ui.icon(ctx, ui.ICON_CHECK, p, size * scale, ui.color_fade(ctx.theme.success, alpha))
}

// Whether any flash shows now, for the exit stats.
flashing :: proc(app: ^App) -> bool {
	f := &app.flashes
	return f.undo.on || f.mask.on || f.selection.on || f.saved.on || f.undo_wait > 0
}
