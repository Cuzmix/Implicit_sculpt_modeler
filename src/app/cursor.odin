package main

import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../sculpt"

// The brush ring lying on the surface under the pointer, as ZBrush and Blender draw it: a
// circle of the brush's radius in the plane the surface faces there, so its tilt shows
// which way the brush will push before a stroke starts (Settings > Interface > Lay the
// brush ring on the surface). Worked out each frame by cursor_update and drawn by the
// overlay; off the model the ring stays the flat circle on the screen.
Brush_Cursor :: struct {
	ok:     bool, // the ring's middle is over the model this frame
	at:     Vec3, // where, in world space
	normal: Vec3, // the way the surface faces there, unit length (the brush's area normal)
	radius: f32, // the brush's radius there, in world units
}

// How far out from the middle, in radii, the brush in use falls to half strength, while its
// focal shift moves that; 0 while the shift is 0 and the ring shows no inner circle.
brush_half_radius :: proc(app: ^App) -> f32 {
	if focal_shift(app)^ == 0 do return 0
	f := brush_falloff(app, app.brush.kind)
	if f == nil do return 0
	for w, i in f.table do if w < 0.5 do return math.sqrt(f32(i) / sculpt.FALLOFF_STEPS)
	return 1
}

// Finds the surface under the brush ring's middle for this frame's overlay: a raycast,
// then the falloff-weighted normal of the vertices the brush would reach, as a dab works
// out the way it pushes. Runs after the tools, so it sees this frame's stroke; the normals
// a stroke moved this frame are a frame old until sculptor_flush, which is not to be seen.
cursor_update :: proc(app: ^App, input: Viewport_Input) {
	c := &app.cursor
	c.ok = false
	if !app.kit.surface_ring || app.tool != .Brush || !(input.hovered || input.dragging) || app.ui.pie.open do return
	// The gestures, the S/U adjust and the Drag rectangle stamp draw their own outlines,
	// and an alpha's square stays flat on the screen.
	if app.clip.active || app.mask_shape.active || app.ui.adjust.kind != .None || (app.stroke.active && app.stroke.rect) do return
	if brush_alpha(app) != nil && held_brush(input) do return
	start := time.tick_now()
	defer ring_push(&app.stats.cursor_ms, time.duration_milliseconds(time.tick_since(start)))
	center := input.mouse_pos
	if app.stroke.active && stroke_trails(app) do center = app.stroke.pos
	origin, dir := mouse_ray(app.camera, center, input.size)
	index, hit, face, ok := scene_raycast_surface(app, origin, dir)
	if !ok do return
	obj := app.scene.objects[index]
	t := obj.transform
	radius := app.brush.radius_px * camera.orbit_world_per_px(app.camera, hit, input.size.y)
	normal := face
	if n, found := sculpt.sculptor_area_normal(object_sculptor(obj), to_local(t, hit), radius / t.scale, to_local_dir(t, face)); found {
		normal = linalg.normalize0(to_world_dir(t, n))
	}
	if normal == {} do return
	c^ = {ok = true, at = hit, normal = normal, radius = radius}
}
