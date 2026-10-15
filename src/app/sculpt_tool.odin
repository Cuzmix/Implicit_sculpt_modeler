package main

import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../sculpt"

// Brush settings as the user edits them. Radius is in screen pixels, converted to
// world units at the hit point each frame so the brush feels the same at any zoom.
Brush_Settings :: struct {
	kind:      sculpt.Brush_Kind,
	radius_px: f32,
	strength:  f32,
}

Stroke :: struct {
	active: bool,
	last:   sculpt.Vec3, // where the previous dab landed, in the object's local space
}

Sculpt_Frame_Result :: struct {
	dabs:       int,
	raycast_ms: f64,
	brush_ms:   f64,
}

DAB_SPACING :: 0.25 // fraction of the brush radius between dabs
MAX_DABS_PER_FRAME :: 64

// Turns this frame's viewport input into brush dabs. A stroke sculpts the object it
// started on, which becomes the selected object; dabs are placed in its local space.
sculpt_frame :: proc(app: ^App, input: Viewport_Input) -> (res: Sculpt_Frame_Result) {
	if !input.primary || input.size.x <= 0 || input.size.y <= 0 {
		app.stroke.active = false
		return
	}

	origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
	t0 := time.tick_now()
	obj: ^Object
	hit: Vec3
	ok: bool
	if !app.stroke.active {
		index: int
		index, hit, ok = scene_raycast(app, origin, dir)
		if ok {
			app.scene.selected = index
			obj = selected_object(app)
			hit = to_local(obj.transform, hit)
		}
	} else if obj = selected_object(app); obj != nil {
		hit, ok = sculpt.sculptor_raycast(&obj.sculptor, to_local(obj.transform, origin), dir)
	}
	res.raycast_ms = time.duration_milliseconds(time.tick_since(t0))
	if !ok do return // off the surface: keep the stroke alive so re-entry continues it

	t := obj.transform
	dist := linalg.length(to_world(t, hit) - camera.orbit_eye(app.camera))
	world_per_px := 2 * dist * math.tan(app.camera.fov_y / 2) / input.size.y
	brush := sculpt.Brush {
		kind     = .Smooth if input.smooth else app.brush.kind,
		radius   = app.brush.radius_px * world_per_px / t.scale,
		strength = app.brush.strength,
		invert   = input.invert,
	}

	t1 := time.tick_now()
	if !app.stroke.active {
		sculpt.apply_dab(&obj.sculptor, brush, hit)
		app.stroke = {active = true, last = hit}
		res.dabs = 1
	} else {
		spacing := brush.radius * DAB_SPACING
		delta := hit - app.stroke.last
		length := linalg.length(delta)
		steps := min(int(length / spacing), MAX_DABS_PER_FRAME)
		if steps > 0 {
			step := delta * (spacing / length)
			for _ in 0 ..< steps {
				app.stroke.last += step
				sculpt.apply_dab(&obj.sculptor, brush, app.stroke.last)
			}
			res.dabs = steps
		}
	}
	res.brush_ms = time.duration_milliseconds(time.tick_since(t1))
	return
}

// World-space ray through a viewport pixel (origin at the top-left).
mouse_ray :: proc(c: camera.Orbit, pos, size: [2]f32) -> (origin, dir: sculpt.Vec3) {
	ndc := [2]f32{2 * pos.x / size.x - 1, 1 - 2 * pos.y / size.y}
	inv := linalg.inverse(camera.orbit_proj(c, size.x / size.y) * camera.orbit_view(c))
	near := inv * [4]f32{ndc.x, ndc.y, 0, 1}
	far := inv * [4]f32{ndc.x, ndc.y, 1, 1}
	origin = near.xyz / near.w
	dir = linalg.normalize(far.xyz / far.w - origin)
	return
}

// Synthetic input for --bench-stroke: a wavy left-to-right drag across the first
// object, as it appears on screen.
bench_input :: proc(app: ^App, frame, total: int, size: [2]f32) -> Viewport_Input {
	t := f32(frame) / f32(max(total - 1, 1))
	center, radius := size * 0.5, size.y * 0.3
	if len(app.scene.objects) > 0 {
		obj := app.scene.objects[0]
		view_proj := camera.orbit_proj(app.camera, size.x / size.y) * camera.orbit_view(app.camera)
		to_px :: proc(m: matrix[4, 4]f32, p: Vec3, size: [2]f32) -> [2]f32 {
			c := m * [4]f32{p.x, p.y, p.z, 1}
			return {(c.x / c.w * 0.5 + 0.5) * size.x, (0.5 - c.y / c.w * 0.5) * size.y}
		}
		center = to_px(view_proj, obj.transform.position, size)
		up := Vec3{0, obj.transform.scale, 0}
		radius = linalg.length(to_px(view_proj, obj.transform.position + up, size) - center)
	}
	return Viewport_Input {
		size      = size,
		mouse_pos = center + radius * [2]f32{-0.6 + 1.2 * t, 0.3 * math.sin(t * 4 * math.PI)},
		hovered   = true,
		dragging  = true,
		primary   = true,
	}
}
