package main

import "core:math"
import "core:math/linalg"

import "../camera"
import "../render"

// Lights: four directional lights, each switched on or off with its own direction,
// strength and colour, an ambient light, and the studio the physically based materials
// reflect. By default they are fixed to the camera as ZBrush's and Blender's studio
// lights are, so the model always reads the same way while it turns. The Lights section
// places each light on a sphere (kit_light_sphere), sets its strength and colour, and
// turns the whole set with the studio; fixed to the scene, the lights stay put while the
// camera goes round, which is how a turntable is judged. MatCaps carry their own light
// and ignore them.

LIGHT_STRENGTH_MAX :: 2
LIGHT_COUNT :: render.LIGHT_COUNT

// One light, as the Lights section edits it.
Light :: struct {
	on:       bool,
	// Toward the light in the lights' own frame, turned into view space by the Turn all
	// and Height all sliders and, fixed to the scene, the camera (lights_frame); unturned
	// and fixed to the camera, +x is right, +y up and +z toward the viewer. Kept as set,
	// so a script can set it number by number, and made unit length where it is used.
	dir:      [3]f32,
	strength: f32, // 0 to LIGHT_STRENGTH_MAX
	color:    [3]f32, // linear light
}

// The lights as a fresh install has them: the renderer's key and fill (render.KEY_DIR and
// FILL_DIR) on, so the default look is the one the app always had, and a rim light behind
// on the upper right and a bounce from below, both off until wanted.
@(rodata)
LIGHTS_DEFAULT := [LIGHT_COUNT]Light {
	{on = true, dir = render.KEY_DIR, strength = 1, color = 1},
	{on = true, dir = render.FILL_DIR, strength = render.FILL_STRENGTH, color = 1},
	{on = false, dir = {0.55, 0.45, -0.7}, strength = 0.6, color = 1},
	{on = false, dir = {0, -0.85, 0.5}, strength = 0.3, color = 1},
}

// The rotation that takes the lights' own frame into view space: the set turned
// `light_turn` degrees about the up axis (to the right) and `light_height` degrees up or
// down, in view space, or in the scene's space seen through the camera when fixed to it.
lights_frame :: proc(app: ^App) -> linalg.Matrix3f32 {
	rig := linalg.matrix3_rotate_f32(math.to_radians(app.light_turn), {0, 1, 0}) * linalg.matrix3_rotate_f32(math.to_radians(-app.light_height), {1, 0, 0})
	if app.lights_fixed {
		v := camera.orbit_view(app.camera)
		rig = linalg.Matrix3f32{v[0, 0], v[0, 1], v[0, 2], v[1, 0], v[1, 1], v[1, 2], v[2, 0], v[2, 1], v[2, 2]} * rig
	}
	return rig
}

// Light `i`'s direction in view space, unit length: where the light sphere shows it. A
// direction set to nothing (by a script, number by number) is its default's.
light_view_dir :: proc(app: ^App, i: int) -> [3]f32 {
	dir := app.lights[i].dir
	if linalg.length(dir) < 1e-6 do dir = LIGHTS_DEFAULT[i].dir
	return linalg.normalize(lights_frame(app) * linalg.normalize(dir))
}

// Points light `i` along the view-space direction `view` (unit length), as the light
// sphere places it, keeping it where it is in its own frame whatever the turn.
light_set_view_dir :: proc(app: ^App, i: int, view: [3]f32) {
	app.lights[i].dir = linalg.transpose(lights_frame(app)) * view
}

// The lights as render.Draw_Item.lights, in view space (lights_frame), with the studio
// turned the same way. Unturned it is render.lights_default() exactly, so the look the
// app always had stays the default.
viewport_lights :: proc(app: ^App) -> render.Lights {
	rig := lights_frame(app)
	l: render.Lights
	for c in 0 ..< 3 do l.rig[c] = {rig[0, c], rig[1, c], rig[2, c], 0}
	l.rig[0].w = app.light_ambient
	for light, i in app.lights {
		d := light_view_dir(app, i)
		l.dir[i] = {d.x, d.y, d.z, light.strength if light.on else 0}
		l.color[i] = {light.color.r, light.color.g, light.color.b, 0}
	}
	return l
}

// Fixes the lights to the scene, or to the camera again, keeping them where they are as
// far as a turn about the up axis can: the turn takes the camera's own turn about it in
// or out, so only a camera tilted up or down sees them move.
lights_fix :: proc(app: ^App, fixed: bool) {
	if fixed == app.lights_fixed do return
	v := camera.orbit_view(app.camera)
	yaw := math.to_degrees(math.atan2(v[2, 0], v[2, 2]))
	turn := app.light_turn + yaw if fixed else app.light_turn - yaw
	app.light_turn = math.mod(turn + 540, 360) - 180
	app.lights_fixed = fixed
}

// The lights as a fresh install has them: fixed to the camera, unturned, LIGHTS_DEFAULT,
// full ambient light, the first light picked.
lights_reset :: proc(app: ^App) {
	app.light_turn, app.light_height, app.lights_fixed = 0, 0, false
	app.lights = LIGHTS_DEFAULT
	app.light_ambient, app.light_pick = 1, 0
}

// The view-space direction a point on the light sphere stands for: `at` from the
// sphere's centre in its radii (+y up), pulled onto the disc, on the side of the sphere
// `front` says (toward the viewer, in front of the model).
light_sphere_dir :: proc(at: [2]f32, front: bool) -> [3]f32 {
	p := at
	if r := linalg.length(p); r > 1 do p /= r
	z := math.sqrt(max(1 - linalg.dot(p, p), 0))
	return {p.x, p.y, z if front else -z}
}

// Sends light `i` behind the model, or brings it back in front, as the camera sees it:
// mirrored through the sphere's outline, so its marker stays where it was.
light_flip :: proc(app: ^App, i: int) {
	v := light_view_dir(app, i)
	light_set_view_dir(app, i, {v.x, v.y, -v.z})
}
