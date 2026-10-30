package main

import "core:fmt"
import "core:hash"
import "core:math/linalg"
import "core:mem"
import "core:time"

import "../camera"
import "../geom"
import "../render"
import "../sculpt"
import "../ui"

// The Layers panel's pictures and tint (panels P1). Each layer row the panel shows gets a
// picture of where the layer worked: the object alone, seen the way the main view looks
// at it but in parallel, fitted to the box round the vertices the layer moves
// (sculptor_layer_bounds), drawn into a cell of its own atlas (render.Step_Pictures, a
// second one). As the Objects card's pictures are, a cell is drawn again only once what it
// shows has stayed unchanged for THUMB_SETTLE, never during a stroke or while the view
// moves, at most one a frame. Resting on a row or pressing it tints the same box on the
// model in the accent's colour, as the History tints what a step changed.

// A cell: the object and layer it shows, what that looks like now and what the cell holds
// (layer_picture_key; 0 for nothing yet), when the first last changed, and the frame the
// panel last showed it, which decides the cell given up for another layer.
Layer_Picture_Slot :: struct {
	id:      int,
	layer:   int, // index + 1, so a zero cell shows nothing
	want:    u64,
	drawn:   u64,
	changed: time.Tick,
	used:    int,
}

Layer_Picture_Slots :: struct {
	slots: [render.STEP_PICTURE_SLOTS]Layer_Picture_Slot,
	frame: int, // counts frames from 1, so a cell never shown has an older frame
	drawn: int, // pictures drawn, for the exit stats
}

// The image id the interface draws the layers' pictures with.
KIT_LAYER_PICTURES_IMAGE :: KIT_STEP_PICTURES_IMAGE + 1

// What decides how a layer's picture looks: the object's drawn buffers and turn, and the
// layer's place, strength and eye.
@(private = "file")
layer_picture_key :: proc(obj: ^Object, index: int) -> u64 {
	l := sculpt.sculptor_layers(object_sculptor(obj))[index]
	r := obj.transform.rotation
	keyed := [8]u64{object_gpu(obj).version, u64(obj.levels.current), u64(index), u64(transmute(u32)l.strength), u64(l.visible), u64(transmute(u32)r.x), u64(transmute(u32)r.y), u64(transmute(u32)r.z)}
	return max(hash.fnv64a(mem.slice_to_bytes(keyed[:])), 1)
}

// Draws the picture of layer `index` of `obj` in `r`, faded by `fade`, giving it a cell
// when it has none; false while it has no picture yet, for the caller to draw something
// else. Called by the panel for each row it shows, which keeps those cells from going to
// other layers.
layer_picture_draw :: proc(app: ^App, obj: ^Object, index: int, r: ui.Rect, fade: f32 = 1) -> bool {
	ls := &app.layer_picture_slots
	if ls.frame == 0 do ls.frame = 1
	slot := -1
	for s, i in ls.slots do if s.id == obj.id && s.layer == index + 1 {
		slot = i
		break
	}
	if slot < 0 {
		// The cell shown longest ago, empty ones first; never one shown this frame.
		for s, i in ls.slots {
			if s.id != 0 && s.used == ls.frame do continue
			if slot < 0 || s.used < ls.slots[slot].used do slot = i
		}
		if slot < 0 do return false
		ls.slots[slot] = {id = obj.id, layer = index + 1}
	}
	s := &ls.slots[slot]
	if key := layer_picture_key(obj, index); s.want != key do s.want, s.changed = key, time.tick_now()
	s.used = ls.frame
	if s.drawn == 0 || app.layer_pictures.atlas == nil do return false
	lo, hi := render.step_picture_uv(slot)
	ctx := &app.kit.ctx
	ui.image_part(ctx, r, KIT_LAYER_PICTURES_IMAGE, lo, hi, {255, 255, 255, u8(255 * clamp(fade, 0, 1))})
	ui.stroke_rect(ctx, r, 4, ui.color_fade(ctx.theme.border, fade), 1)
	return true
}

// Draws at most one picture on `cmd` for this frame, from the frame's `draws`: the first
// cell shown this frame that is out of date, once what it shows has settled (at once when
// it has no picture yet). A layer that moves nothing yet has no picture.
layer_pictures_frame :: proc(app: ^App, cmd: render.Cmd, draws: []render.Draw_Item) {
	ls := &app.layer_picture_slots
	if ls.frame == 0 do ls.frame = 1
	defer ls.frame += 1
	if app.stroke.active || time.tick_since(app.view_moved) < LOD_SETTLE || app.kit.home do return
	for &s, i in ls.slots {
		if s.id == 0 || s.used != ls.frame || s.want == s.drawn do continue
		if s.drawn != 0 && time.tick_since(s.changed) < THUMB_SETTLE do continue
		obj := object_by_id(app, s.id)
		if obj == nil || s.layer > len(sculpt.sculptor_layers(object_sculptor(obj))) {
			s = {}
			continue
		}
		local := sculpt.sculptor_layer_bounds(object_sculptor(obj), s.layer - 1)
		if local.lo.x > local.hi.x {
			// Nothing to show yet: the row keeps its icon until the layer moves something.
			s.drawn = 0
			continue
		}
		gpu := object_gpu(obj)
		items := make([dynamic]render.Draw_Item, 0, 1, context.temp_allocator)
		for d in draws do if d.mesh == gpu do append(&items, d)
		if len(items) == 0 do continue
		view, proj := layer_picture_camera(app, box_to_world(obj, local))
		pane := color_f32(LOOK_THEMES[app.kit.look].pane)
		if render.step_pictures_draw(&app.renderer, &app.layer_pictures, cmd, i, view, proj, items[:], pane) {
			s.drawn = s.want
			ls.drawn += 1
		}
		return
	}
}

// The main view's way of looking, in parallel projection, fitted to `world` with a margin.
@(private = "file")
layer_picture_camera :: proc(app: ^App, world: geom.Aabb) -> (view, proj: render.Mat4) {
	v := camera.orbit_view(main_camera(app))
	up := geom.Vec3{v[1, 0], v[1, 1], v[1, 2]}
	back := geom.Vec3{v[2, 0], v[2, 1], v[2, 2]}
	center := (world.lo + world.hi) * 0.5
	half := (world.hi - world.lo) * 0.5
	reach := max(linalg.length(half), 1e-4)
	view = camera.look_at(center + back * 3 * reach, center, up)
	proj = camera.orthographic(reach * 1.15, 1, 0, 6 * reach)
	return
}

// How long, in seconds of the kit's clock, a rest on a row keeps the tint up after the
// last frame that saw it: a frame or two.
LAYER_TINT_HOLD :: 0.05

// A row of layer `index` of `obj` is rested on or pressed this frame.
layer_tint_rest :: proc(app: ^App, obj: ^Object, index: int) {
	lp := &app.kit.layer_panel
	lp.tint_id, lp.tint_layer, lp.tint_time = obj.id, index + 1, app.kit.ctx.time
}

// The tint over the viewport of `size` while a layer's row is rested on or pressed: a soft
// glow in the accent's colour over where the layer worked, with its name and strength.
draw_layer_tint :: proc(app: ^App, o: Overlay, size: [2]f32) {
	lp := &app.kit.layer_panel
	ctx := o.ctx
	// The panel may lay out after this is drawn in a frame, so a rest from the frame
	// before still counts.
	if lp.tint_layer == 0 || ctx.time - lp.tint_time > LAYER_TINT_HOLD {
		lp.tint_last = 0
		return
	}
	obj := object_by_id(app, lp.tint_id)
	if obj == nil do return
	s := object_sculptor(obj)
	if lp.tint_layer > len(sculpt.sculptor_layers(s)) do return
	if lp.tint_last != lp.tint_layer {
		lp.tint_last = lp.tint_layer
		lp.tints += 1
	}
	local := sculpt.sculptor_layer_bounds(s, lp.tint_layer - 1)
	if local.lo.x > local.hi.x do return
	lo, hi, seen := flash_screen_box(app, {id = obj.id, box = box_to_world(obj, local)}, size, false)
	if !seen do return
	l := &sculpt.sculptor_layers(s)[lp.tint_layer - 1]
	accent := ctx.theme.accent
	colour := [4]f32{f32(accent.r) / 255, f32(accent.g) / 255, f32(accent.b) / 255, 1}
	draw_tint_glow(o, lo, hi, colour, 1, fmt_layer_label(l))
}

@(private = "file")
fmt_layer_label :: proc(l: ^sculpt.Sculpt_Layer) -> string {
	return fmt.tprintf("%s · %.2f%s", sculpt.sculptor_layer_name(l), l.strength, "" if l.visible else " · hidden")
}
