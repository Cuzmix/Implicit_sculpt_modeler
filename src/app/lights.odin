package main

import "core:math"
import "core:math/linalg"

import "../camera"

// Lights: the shading's key and fill lights and the studio the physically based
// materials reflect turn together as one rig, by default fixed to the camera as ZBrush's
// and Blender's studio lights are, so the model always reads the same way while it
// turns. The Lights section turns the rig to light a form from another side and sets the
// key and fill strengths; fixed to the scene, the light stays put while the camera goes
// round, which is how a turntable is judged. MatCaps carry their own light and ignore it.

LIGHT_STRENGTH_MAX :: 2

// The rig as render.Draw_Item.lights: turned `light_turn` degrees about the up axis (to
// the right) and `light_height` degrees up or down, in view space, or in the scene's
// space seen through the camera when fixed to it. Unturned and at full strength it is
// render.DEFAULT_LIGHTS exactly, so the default look is unchanged.
viewport_lights :: proc(app: ^App) -> [3][4]f32 {
	rig := linalg.matrix3_rotate_f32(math.to_radians(app.light_turn), {0, 1, 0}) * linalg.matrix3_rotate_f32(math.to_radians(-app.light_height), {1, 0, 0})
	if app.lights_fixed {
		v := camera.orbit_view(app.camera)
		rig = linalg.Matrix3f32{v[0, 0], v[0, 1], v[0, 2], v[1, 0], v[1, 1], v[1, 2], v[2, 0], v[2, 1], v[2, 2]} * rig
	}
	column :: proc(m: linalg.Matrix3f32, c: int, w: f32) -> [4]f32 {return {m[0, c], m[1, c], m[2, c], w}}
	return {column(rig, 0, app.light_key), column(rig, 1, app.light_fill), column(rig, 2, 0)}
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

// The lights as a fresh install has them: fixed to the camera, unturned, full strength.
lights_reset :: proc(app: ^App) {
	app.light_turn, app.light_height, app.light_key, app.light_fill, app.lights_fixed = 0, 0, 1, 1, false
}
