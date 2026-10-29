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
// overlay; off the model the ring stays the flat circle on the screen. With symmetry on,
// the ring's copies at every mirrored and turned image of the brush, as ZBrush shows its
// mirrored cursor, so where the other side will move shows before a stroke starts.
Brush_Cursor :: struct {
	ok:     bool, // the ring's middle is over the model this frame
	at:     Vec3, // where, in world space
	normal: Vec3, // the way the surface faces there, unit length (the brush's area normal)
	radius: f32, // the brush's radius there, in world units
	images: [dynamic; sculpt.SYM_IMAGES_MAX]Cursor_Image, // the symmetry's copies, the ring itself left out
}

// One of the brush ring's symmetry copies, in world space.
Cursor_Image :: struct {
	at:     Vec3,
	normal: Vec3,
}

// How far out from the middle, in radii, the brush in use falls to half strength, while its
// focal shift or hardness moves that; 0 while both are 0 and the ring shows no inner circle.
brush_half_radius :: proc(app: ^App) -> f32 {
	if f := app.brush.falloffs[app.brush.kind]; f.focal == 0 && f.hardness == 0 do return 0
	f := brush_falloff(app, app.brush.kind)
	if f == nil do return 0
	for w, i in f.table do if w < 0.5 do return math.sqrt(f32(i) / sculpt.FALLOFF_STEPS)
	return 1
}

// The pointer's lead for the brush ring (cursor_lead): where it was a frame ago while
// pressed, how far it moved since, and the platform's own prediction where it gives one.
Cursor_Predict :: struct {
	down:     bool,
	last:     [2]f32,
	velocity: [2]f32, // pixels a frame
	// The iPad's predicted touch, from the pen's newest sample (pen_samples.odin), and how
	// many frames ago it came: 1 means since the frame before this one.
	platform:     [2]f32,
	platform_age: int,
}

// The most the ring leads the pointer: past this a prediction is more guess than motion.
PREDICT_MAX_PX :: 48

// Moves the prediction on by this frame's pointer. Called once a frame before the ring is
// placed.
cursor_predict_frame :: proc(app: ^App, input: Viewport_Input) {
	p := &app.predict
	p.platform_age += 1
	if !input.primary {
		p.down, p.velocity = false, {}
		return
	}
	if p.down do p.velocity = input.mouse_pos - p.last
	p.down, p.last = true, input.mouse_pos
}

// How far ahead of the pointer the brush ring is drawn: by the iPad's predicted touch when
// it gave one this frame, else by one frame of the pointer's motion, as the frame is shown
// about a frame after its samples; never past PREDICT_MAX_PX. Only while a stroke draws
// with the ring on the pointer, never under a trailing brush, and only the ring: dabs go
// where the pointer went.
cursor_lead :: proc(app: ^App) -> [2]f32 {
	p := app.predict
	if !app.nav.predict_cursor || !app.stroke.active || stroke_trails(app) || !p.down do return {}
	lead := p.platform if p.platform_age == 1 else p.velocity
	if l := linalg.length(lead); l > PREDICT_MAX_PX do lead *= PREDICT_MAX_PX / l
	return lead
}

// Where the brush ring's middle is drawn: the brush itself while it trails the pointer
// (the lazy string, the smoothing's lag), else the pointer led by its prediction.
ring_center :: proc(app: ^App, input: Viewport_Input) -> [2]f32 {
	if app.stroke.active && stroke_trails(app) do return app.stroke.pos
	return input.mouse_pos + cursor_lead(app)
}

// Finds the surface under the brush ring's middle for this frame's overlay: a raycast,
// then the falloff-weighted normal of the vertices the brush would reach, as a dab works
// out the way it pushes. Runs after the tools, so it sees this frame's stroke; the normals
// a stroke moved this frame are a frame old until sculptor_flush, which is not to be seen.
cursor_update :: proc(app: ^App, input: Viewport_Input) {
	c := &app.cursor
	c.ok = false
	clear(&c.images)
	// The symmetry's copies need the surface under the pointer even with the ring flat.
	if !(app.kit.surface_ring || symmetry_on(app)) || app.tool != .Brush || !(input.hovered || input.dragging) || app.ui.pie.open do return
	// The gestures, the S/U adjust and the Drag rectangle stamp draw their own outlines,
	// and an alpha's square stays flat on the screen.
	if app.clip.active || app.mask_shape.active || app.ui.adjust.kind != .None || (app.stroke.active && app.stroke.rect) do return
	if brush_alpha(app) != nil && held_brush(input) do return
	start := time.tick_now()
	defer ring_push(&app.stats.cursor_ms, time.duration_milliseconds(time.tick_since(start)))
	origin, dir := mouse_ray(app.camera, ring_center(app, input), input.size)
	index, hit, face, ok := scene_raycast_surface(app, origin, dir)
	if !ok do return
	obj := app.scene.objects[index]
	t := obj.transform
	per_px := camera.orbit_world_per_px(app.camera, hit, input.size.y)
	radius := app.brush.radius_px * brush_size_scale(app, per_px, input.size.y) * per_px
	normal := face
	if n, found := sculpt.sculptor_area_normal(object_sculptor(obj), to_local(t, hit), radius / t.scale, to_local_dir(t, face)); found {
		normal = linalg.normalize0(to_world_dir(t, n))
	}
	if normal == {} do return
	c.ok, c.at, c.normal, c.radius = true, hit, normal, radius
	if !symmetry_on(app) do return
	// Each image as a dab takes it, in the object's own space, then back to the world.
	sym := brush_symmetry(app, obj)
	local, local_n := to_local(t, hit), to_local_dir(t, normal)
	for img, i in sculpt.symmetry_images(sym) {
		if i == 0 do continue
		at := to_world(t, sculpt.sym_point(img, sym.sym_center, local))
		append(&c.images, Cursor_Image{at, linalg.normalize0(to_world_dir(t, img.turn * local_n))})
	}
}
