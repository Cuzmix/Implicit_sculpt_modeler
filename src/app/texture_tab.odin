package main

import "core:fmt"
import "core:math"

import "../render"
import "../ui"

// The Texture tab (docking DK2), the first 2D kind of tab: one map of the selected object
// shown flat, as Substance's 2D view and Blender's image editor show a texture, to read
// what a bake or a loaded file holds. It follows the selection, as a property panel does.
// It is drawn by the interface kit over the map the textured preview already holds on the
// GPU (Texture_Preview), so it costs no picture, no memory and no draw of the scene; only
// the part inside the pane is drawn. A drag pans, the wheel or a pinch zooms about the
// pointer, a double tap fits; past TEXEL_GRID_ZOOM the texels show as squares with a grid.

// A 2D tab's view of its image: which map, and where it looks. Zoom is points a texel
// (0: fit the pane), `centre` the image point (0 to 1 across and down) at the pane's
// middle.
Flat_Tab :: struct {
	which:  render.Texture_Map,
	zoom:   f32,
	centre: [2]f32,
	// A drag on it: the pointer last frame; a pinch: the fingers' spread and middle last
	// frame (0 spread: none yet).
	last:   [2]f32,
	spread: f32,
	middle: [2]f32,
	tap:    Handle_Tap,
}

// Points a texel past which the texels show as squares, sampled nearest, with a grid
// between them.
TEXEL_GRID_ZOOM :: 8
// The zoom's range, in points a texel.
FLAT_ZOOM_MIN :: 1.0 / 64
FLAT_ZOOM_MAX :: 64
// The checker the image stands on, so where it is see-through shows, in points.
FLAT_CHECKER :: 16
// How far a wheel notch zooms.
FLAT_WHEEL_STEP :: 1.2

// The image a Texture tab in view pane `pane` (1 to 3) shows, for kit_draws.
KIT_TAB_IMAGE :: KIT_BRUSH_PREVIEWS_IMAGE + 1
KIT_TAB_IMAGE_END :: KIT_TAB_IMAGE + GRID_VIEWS

// The map a Texture tab shows: the selected object's, once its preview holds it.
flat_texture :: proc(app: ^App, f: ^Flat_Tab) -> (tex: render.Texture, size: [2]u32) {
	obj := selected_object(app)
	if obj == nil do return nil, {}
	m := &obj.preview.mesh
	return m.maps[f.which], m.sizes[f.which]
}

// The zoom a tab shows at: its own, or the one that fits `size` texels into `room`.
flat_zoom :: proc(f: ^Flat_Tab, size: [2]u32, room: ui.Rect) -> f32 {
	if f.zoom > 0 do return f.zoom
	if size.x == 0 || size.y == 0 do return 1
	return min((room.w - 24) / f32(size.x), (room.h - 24) / f32(size.y))
}

// Where the image lies in the pane at `r`, in points.
flat_image_rect :: proc(f: ^Flat_Tab, size: [2]u32, r: ui.Rect) -> ui.Rect {
	z := flat_zoom(f, size, r)
	w, h := f32(size.x) * z, f32(size.y) * z
	centre := f.centre if f.zoom > 0 else [2]f32{0.5, 0.5}
	return {r.x + r.w * 0.5 - centre.x * w, r.y + r.h * 0.5 - centre.y * h, w, h}
}

// Zooms tab `f` by `by` about point `at` of the pane at `r`, so what lies under it stays.
flat_zoom_about :: proc(f: ^Flat_Tab, size: [2]u32, r: ui.Rect, at: [2]f32, by: f32) {
	if size.x == 0 || size.y == 0 do return
	img := flat_image_rect(f, size, r)
	under := [2]f32{(at.x - img.x) / img.w, (at.y - img.y) / img.h}
	z := clamp(flat_zoom(f, size, r) * by, FLAT_ZOOM_MIN, FLAT_ZOOM_MAX)
	f.zoom = z
	w, h := f32(size.x) * z, f32(size.y) * z
	// The new image's point `under` lands on `at`.
	f.centre = {under.x - (at.x - r.x - r.w * 0.5) / w, under.y - (at.y - r.y - r.h * 0.5) / h}
}

// Pans tab `f` by `d` points.
flat_pan :: proc(f: ^Flat_Tab, size: [2]u32, r: ui.Rect, d: [2]f32) {
	if size.x == 0 || size.y == 0 do return
	if f.zoom <= 0 do f.zoom, f.centre = flat_zoom(f, size, r), {0.5, 0.5}
	f.centre -= {d.x / (f32(size.x) * f.zoom), d.y / (f32(size.y) * f.zoom)}
	f.centre = {clamp(f.centre.x, 0, 1), clamp(f.centre.y, 0, 1)}
}

// The Texture tab of view pane `i` at `r`: its ground, the checker under the image, the
// part of the map inside the pane, the texel grid when zoomed in, and its input.
kit_texture_tab :: proc(app: ^App, i: int, r: ui.Rect, tab: ^Pane_Tab) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	f := &tab.flat
	ui.begin_at(ctx, fmt.tprintf("view pane %d", i), {r.x, r.y}, {width = r.w, height = r.h})
	defer ui.end(ctx)
	a := ui.area(ctx, "picture", {r.w, r.h})
	ui.fill_rect(ctx, r, 0, t.pane)
	tex, size := flat_texture(app, f)
	if tex == nil {
		obj := selected_object(app)
		note := "Select an object to see its maps"
		if obj != nil do note = fmt.tprintf("%s has no %s map: bake one or load it in the Textures card", object_label(obj), TEXTURE_MAP_NAMES[f.which])
		if obj != nil && obj.textures.image[f.which] != nil do note = fmt.tprintf("The %s map of %s is loading", TEXTURE_MAP_NAMES[f.which], object_label(obj))
		ui.icon(ctx, ui.ICON_IMAGE, {r.x + r.w * 0.5, r.y + r.h * 0.5 - 22}, t.icon_small * 2, t.text_tertiary)
		ui.text(ctx, ui.text_fit(ctx, note, t.small_size, r.w - 24), r.x + r.w * 0.5, r.y + r.h * 0.5 + 6, t.small_size, t.text_secondary, .Regular, .Center)
		return
	}
	flat_input(app, r, a, f, size)
	img := flat_image_rect(f, size, r)
	// What of the image is inside the pane, and its part of the texture.
	x0, y0 := max(img.x, r.x), max(img.y, r.y)
	x1, y1 := min(img.x + img.w, r.x + r.w), min(img.y + img.h, r.y + r.h)
	if x1 <= x0 || y1 <= y0 do return
	shown := ui.Rect{x0, y0, x1 - x0, y1 - y0}
	// The checker, in cells fixed to the image so it moves with a pan.
	ui.fill_rect(ctx, shown, 0, t.fill)
	cx0 := int(math.floor((x0 - img.x) / FLAT_CHECKER))
	cy0 := int(math.floor((y0 - img.y) / FLAT_CHECKER))
	for cy := cy0; img.y + f32(cy) * FLAT_CHECKER < y1; cy += 1 {
		for cx := cx0 + (cy + cx0) % 2; img.x + f32(cx) * FLAT_CHECKER < x1; cx += 2 {
			c := ui.Rect{img.x + f32(cx) * FLAT_CHECKER, img.y + f32(cy) * FLAT_CHECKER, FLAT_CHECKER, FLAT_CHECKER}
			cl := ui.Rect{max(c.x, x0), max(c.y, y0), 0, 0}
			cl.w, cl.h = min(c.x + c.w, x1) - cl.x, min(c.y + c.h, y1) - cl.y
			if cl.w > 0 && cl.h > 0 do ui.fill_rect(ctx, cl, 0, t.fill_hover)
		}
	}
	lo := [2]f32{(x0 - img.x) / img.w, (y0 - img.y) / img.h}
	hi := [2]f32{(x1 - img.x) / img.w, (y1 - img.y) / img.h}
	ui.image_part(ctx, shown, KIT_TAB_IMAGE + u64(i - 1), lo, hi)
	z := flat_zoom(f, size, r)
	if z >= TEXEL_GRID_ZOOM {
		line := ui.color_fade(t.frame, 0.35)
		for tx := math.ceil((x0 - img.x) / z); img.x + tx * z < x1; tx += 1 do ui.fill_rect(ctx, {img.x + tx * z, y0, 1, y1 - y0}, 0, line)
		for ty := math.ceil((y0 - img.y) / z); img.y + ty * z < y1; ty += 1 do ui.fill_rect(ctx, {x0, img.y + ty * z, x1 - x0, 1}, 0, line)
	}
	ui.stroke_rect(ctx, img, 0, t.border, 1)
	// The size and the zoom, at the pane's foot.
	info := fmt.tprintf("%d x %d · %d%%", size.x, size.y, int(math.round(z * 100 * ctx.input.pixel_density)))
	ui.text(ctx, info, r.x + 12, r.y + r.h - 16, t.small_size, t.text_tertiary)
}

// A Texture tab's input: a drag pans, the wheel zooms about the pointer, two fingers pan
// and pinch, a double tap fits.
@(private = "file")
flat_input :: proc(app: ^App, r: ui.Rect, a: ui.Area, f: ^Flat_Tab, size: [2]u32) {
	ctx := &app.kit.ctx
	fingers := &app.touch.fingers
	if fingers.count >= 2 && (a.held || f.spread > 0) {
		// The fingers are in window coordinates; the pane is in points.
		scale := max(app.kit.scale, 1e-3)
		middle: [2]f32
		for d in fingers.down[:2] do middle += d.at / (2 * scale)
		spread := max(abs(fingers.down[0].at.x - fingers.down[1].at.x) + abs(fingers.down[0].at.y - fingers.down[1].at.y), 1) / scale
		if f.spread > 0 {
			flat_pan(f, size, r, middle - f.middle)
			flat_zoom_about(f, size, r, middle, spread / f.spread)
		}
		f.spread, f.middle = spread, middle
		return
	}
	f.spread = 0
	if a.pressed do f.last = a.mouse
	if a.held && a.mouse != f.last {
		flat_pan(f, size, r, a.mouse - f.last)
		f.last = a.mouse
	}
	if a.clicked && handle_double_tap(ctx, &f.tap, a.id) do f.zoom = 0
	if a.hovered && ctx.input.wheel != 0 do flat_zoom_about(f, size, r, a.mouse, math.pow(f32(FLAT_WHEEL_STEP), ctx.input.wheel))
}

// Fit, or one texel a pixel: the zoom chip's tap.
flat_zoom_toggle :: proc(app: ^App, f: ^Flat_Tab) {
	if f.zoom > 0 {
		f.zoom = 0
		return
	}
	f.zoom = 1 / max(app.kit.ctx.input.pixel_density, 1e-3)
	f.centre = {0.5, 0.5}
}
