package main

import "core:math/linalg"

import "../camera"
import "../ui"

// Masking by shape, as ZBrush does: with the Brush tool, Ctrl and a left drag that
// starts on empty space draws a rectangle (or a lasso, as the Mask section sets), and
// letting go masks everything of the selected object inside it, through to the back;
// with Alt too it unmasks. A drag that starts on an object is a stroke as usual.

Mask_Shape_Kind :: enum u8 {
	Rectangle,
	Lasso,
}

Mask_Shape :: struct {
	active: bool,
	unmask: bool,
	points: [dynamic][2]f32, // viewport pixels; a rectangle uses the first and the last
}

// The distance in pixels the pointer must move before a lasso takes another point.
LASSO_STEP_PX :: 3

// Follows a mask shape gesture with this frame's input. Returns true while one runs (or
// ended this frame), so the brush stays out of it.
mask_shape_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	g := &app.mask_shape
	if !g.active {
		if !input.press || !input.invert || app.stroke.active do return false
		origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
		if _, _, hit := scene_raycast(app, origin, dir); hit do return false
		g.active, g.unmask = true, input.alt
		clear(&g.points)
		append(&g.points, input.mouse_pos)
		return true
	}
	if input.primary {
		if linalg.length(input.mouse_pos - g.points[len(g.points) - 1]) >= LASSO_STEP_PX do append(&g.points, input.mouse_pos)
		return true
	}
	g.active = false
	shape := shape_polygon(g.points[:], app.ui.mask_shape_kind == .Rectangle, input.size)
	if len(shape) >= 3 do mask_shape_command(app, shape, input.size, g.unmask)
	return true
}

// A dragged shape (`points` in viewport pixels, oldest first) as a polygon in normalized
// device coordinates (y up): with `rectangle`, the four corners of the box from the
// first point to the last, otherwise the lasso's points. Temporary.
shape_polygon :: proc(points: [][2]f32, rectangle: bool, size: [2]f32) -> [][2]f32 {
	ndc :: proc(p, size: [2]f32) -> [2]f32 {return {2 * p.x / size.x - 1, 1 - 2 * p.y / size.y}}
	if rectangle {
		a, b := points[0], points[len(points) - 1]
		if b == a do return nil
		corners := make([][2]f32, 4, context.temp_allocator)
		for c, i in ([4][2]f32{a, {b.x, a.y}, b, {a.x, b.y}}) do corners[i] = ndc(c, size)
		return corners
	}
	out := make([][2]f32, len(points), context.temp_allocator)
	for p, i in points do out[i] = ndc(p, size)
	return out
}

// Local space of the object to clip space, for the shape's test.
object_clip :: proc(app: ^App, obj: ^Object, size: [2]f32) -> matrix[4, 4]f32 {
	return camera.orbit_proj(app.camera, size.x / size.y) * camera.orbit_view(app.camera) * transform_matrix(obj.transform)
}

// Draws the shape being dragged.
draw_mask_shape :: proc(app: ^App, o: Overlay, mouse: [2]f32) {
	g := &app.mask_shape
	if !g.active do return
	color := overlay_color({0.95, 0.55, 0.35, 1} if !g.unmask else {0.5, 0.8, 1, 1})
	fill := overlay_color({0.95, 0.55, 0.35, 0.12} if !g.unmask else {0.5, 0.8, 1, 0.12})
	draw_shape_outline(o, g.points[:], mouse, app.ui.mask_shape_kind == .Rectangle, color, fill)
}

// Draws a shape being dragged: the box from the first point to `mouse`, filled, or the
// lasso through `points`.
draw_shape_outline :: proc(o: Overlay, points: [][2]f32, mouse: [2]f32, rectangle: bool, color, fill: ui.Color) {
	if rectangle {
		overlay_box(o, points[0], mouse, color, fill, 1.5)
		return
	}
	// Outline only: a lasso can cross itself, which a filled polygon cannot draw.
	if len(points) >= 2 do overlay_polyline(o, points, color, 1.5, closed = true)
}

mask_shape_destroy :: proc(g: ^Mask_Shape) {delete(g.points)}
