package main

import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../render"

// Lights: up to eight lights of the scene's own, each a sun that shines from a direction,
// a point light that shines every way from a place, or a spot that shines from a place
// into a cone. Each moves with the camera, as ZBrush's and Blender's studio lights do, so
// the model always reads the same way while it turns, or stays put in the scene, as
// Blender's, Marmoset's and KeyShot's lights do, which is how a turntable is judged. They
// are saved with the scene (files.odin); a new scene, and one saved before scenes held
// lights, starts with the starting lights the settings keep (App.start_lights). The
// Lights section (kit_lights.odin) places each on a sphere (kit_light_sphere), sets its
// strength, colour, kind and cone, and turns the camera's lights with the studio; each
// change there is one undo step (Light_Drag). MatCaps carry their own light and ignore
// them.

LIGHT_STRENGTH_MAX :: 2
LIGHT_COUNT :: render.LIGHT_COUNT
// A spot's cone, its full angle in degrees.
LIGHT_CONE_MIN :: 1
LIGHT_CONE_MAX :: 160

Light_Kind :: enum u8 {
	Sun,   // from a direction, as from far away
	Point, // from a place, every way
	Spot,  // from a place, into a cone
}

@(rodata)
LIGHT_KIND_LABELS := [len(Light_Kind)]string{"Sun", "Point", "Spot"}

// What a light keeps its place in: the camera's view, turned by Turn all and Height all
// (lights_frame), or the scene.
Light_Space :: enum u8 {
	Camera,
	Scene,
}

@(rodata)
LIGHT_SPACE_LABELS := [len(Light_Space)]string{"Camera", "Scene"}

// One light, as the Lights section edits it and the scene file stores it.
Light :: struct {
	on:       bool,
	kind:     Light_Kind,
	space:    Light_Space,
	// Toward the light: in the lights' own frame for a light that moves with the camera
	// (unturned, +x is right, +y up and +z toward the viewer), in the scene's axes for one
	// that stays in the scene. A spot shines the other way, along -dir. Kept as set, so a
	// script can set it number by number, and made unit length where it is used.
	dir:      [3]f32,
	// Where a point or spot light is: moving with the camera, its offset from the orbit's
	// target in the lights' own frame; in the scene, its place there. Unused by a sun.
	pos:      [3]f32,
	strength: f32, // 0 to LIGHT_STRENGTH_MAX
	// The distance at which a point or spot light is as bright as a sun of its strength,
	// taken where it is first placed and kept, so moving it brightens or dims the model as
	// a real lamp does; 0 until placed (lights_settle).
	ref:      f32,
	// Where a point or spot light fades to nothing, in scene units; 0 for never.
	reach:    f32,
	cone:     f32, // a spot's full angle in degrees, LIGHT_CONE_MIN to LIGHT_CONE_MAX
	blend:    f32, // how much of the spot's cone, from its edge in, fades: 0 a hard edge, 1 all of it
	color:    [3]f32, // linear light
}

// The scene's lights: the first `count` of `lights` are the scene's, and the ambient
// light's strength.
Light_Set :: struct {
	lights:  [LIGHT_COUNT]Light,
	count:   i32,
	ambient: f32,
}

// The lights as a fresh install has them: the renderer's key and fill (render.KEY_DIR and
// FILL_DIR) on, so the default look is the one the app always had, a rim light behind on
// the upper right and a bounce from below, both off until wanted, and four more suns kept
// for when lights are added, all moving with the camera.
@(rodata)
LIGHTS_DEFAULT := Light_Set {
	lights = {
		{on = true, dir = render.KEY_DIR, strength = 1, color = 1, cone = 45, blend = 0.25},
		{on = true, dir = render.FILL_DIR, strength = render.FILL_STRENGTH, color = 1, cone = 45, blend = 0.25},
		{on = false, dir = {0.55, 0.45, -0.7}, strength = 0.6, color = 1, cone = 45, blend = 0.25},
		{on = false, dir = {0, -0.85, 0.5}, strength = 0.3, color = 1, cone = 45, blend = 0.25},
		{on = false, dir = {0.6, 0.6, 0.5}, strength = 1, color = 1, cone = 45, blend = 0.25},
		{on = false, dir = {-0.7, 0.2, -0.6}, strength = 1, color = 1, cone = 45, blend = 0.25},
		{on = false, dir = {0, 1, 0}, strength = 1, color = 1, cone = 45, blend = 0.25},
		{on = false, dir = {0, 0, 1}, strength = 1, color = 1, cone = 45, blend = 0.25},
	},
	count = 4,
	ambient = 1,
}

// The rotation that takes the lights' own frame into view space for the lights that move
// with the camera: the set turned `light_turn` degrees about the up axis (to the right)
// and `light_height` degrees up or down.
lights_frame :: proc(app: ^App) -> linalg.Matrix3f32 {
	return linalg.matrix3_rotate_f32(math.to_radians(app.light_turn), {0, 1, 0}) * linalg.matrix3_rotate_f32(math.to_radians(-app.light_height), {1, 0, 0})
}

// The camera's rotation, from the scene's axes into view space.
view_rotation :: proc(app: ^App) -> linalg.Matrix3f32 {
	v := camera.orbit_view(app.camera)
	return linalg.Matrix3f32{v[0, 0], v[0, 1], v[0, 2], v[1, 0], v[1, 1], v[1, 2], v[2, 0], v[2, 1], v[2, 2]}
}

// The rotation that takes a light's directions into view space.
light_frame :: proc(app: ^App, l: Light) -> linalg.Matrix3f32 {
	return view_rotation(app) if l.space == .Scene else lights_frame(app)
}

// The orbit's target in view space, which a camera light's place is an offset from.
view_target :: proc(app: ^App) -> [3]f32 {
	c := app.camera.target
	return (camera.orbit_view(app.camera) * [4]f32{c.x, c.y, c.z, 1}).xyz
}

// Where a point or spot light is, in view space.
light_view_pos :: proc(app: ^App, l: Light) -> [3]f32 {
	if l.space == .Camera do return view_target(app) + lights_frame(app) * l.pos
	return (camera.orbit_view(app.camera) * [4]f32{l.pos.x, l.pos.y, l.pos.z, 1}).xyz
}

// How far a point or spot light is from the orbit's target.
light_distance :: proc(app: ^App, l: Light) -> f32 {
	return linalg.length(l.pos if l.space == .Camera else l.pos - app.camera.target)
}

// Which way light `i`'s `dir` points in view space, unit length; a direction set to
// nothing (by a script, number by number) is its default's.
light_view_axis :: proc(app: ^App, i: int) -> [3]f32 {
	l := app.scene.lights.lights[i]
	dir := l.dir
	if linalg.length(dir) < 1e-6 do dir = LIGHTS_DEFAULT.lights[i].dir
	return linalg.normalize(light_frame(app, l) * linalg.normalize(dir))
}

// Light `i`'s direction in view space, unit length: where the light sphere shows it. A
// sun's is its direction; a point or spot light's is from the orbit's target toward it.
light_view_dir :: proc(app: ^App, i: int) -> [3]f32 {
	l := app.scene.lights.lights[i]
	if l.kind != .Sun && l.pos != {} {
		if d := light_view_pos(app, l) - view_target(app); linalg.length(d) > 1e-6 do return linalg.normalize(d)
	}
	return light_view_axis(app, i)
}

// Points light `i` along the view-space direction `view` (unit length), as the light
// sphere places it, keeping it where it is in its own frame whatever the turn or the
// camera; a point or spot light moves round the orbit's target at the distance it was,
// a spot still aimed at the target.
light_set_view_dir :: proc(app: ^App, i: int, view: [3]f32) {
	l := &app.scene.lights.lights[i]
	l.dir = linalg.transpose(light_frame(app, l^)) * view
	if l.kind == .Sun || l.pos == {} do return
	dist := light_distance(app, l^)
	l.pos = l.dir * dist if l.space == .Camera else app.camera.target + l.dir * dist
}

// Moves light `i` into `space` exactly where it is now as the camera sees it: its
// direction and place the same in view space, so nothing changes on screen.
light_set_space :: proc(app: ^App, i: int, space: Light_Space) {
	l := &app.scene.lights.lights[i]
	if l.space == space do return
	dir := light_frame(app, l^) * l.dir
	at := light_view_pos(app, l^)
	l.space = space
	frame := linalg.transpose(light_frame(app, l^))
	l.dir = frame * dir
	if space == .Camera do l.pos = frame * (at - view_target(app))
	else do l.pos = app.camera.target + frame * (at - view_target(app))
}

// Gives every point or spot light not yet placed a place: where its direction points
// from the orbit's target, as far away as the camera; and one without its strength's
// distance (just made, or set so by a script) the distance it is from the target.
lights_settle :: proc(app: ^App) {
	set := &app.scene.lights
	set.count = clamp(set.count, 0, LIGHT_COUNT)
	for &l, i in set.lights[:set.count] {
		if l.kind == .Sun do continue
		if l.pos == {} {
			dir := l.dir
			if linalg.length(dir) < 1e-6 do dir = LIGHTS_DEFAULT.lights[i].dir
			dir = linalg.normalize(dir) * app.camera.distance
			l.pos = dir if l.space == .Camera else app.camera.target + dir
		}
		if l.ref <= 0 do l.ref = max(light_distance(app, l), 1e-4)
	}
}

// The lights as render.Draw_Item.lights, in view space, with the studio turned as the
// camera's lights are. With the default lights it is render.lights_default(), so the look
// the app always had stays the default.
viewport_lights :: proc(app: ^App) -> render.Lights {
	rig := lights_frame(app)
	set := &app.scene.lights
	out: render.Lights
	for c in 0 ..< 3 do out.rig[c] = {rig[0, c], rig[1, c], rig[2, c], 0}
	out.rig[0].w = set.ambient
	for l, i in set.lights[:clamp(set.count, 0, LIGHT_COUNT)] {
		if !l.on || l.strength <= 0 do continue
		axis := light_view_axis(app, i)
		out.color[i] = {l.color.r, l.color.g, l.color.b, l.strength}
		if l.kind == .Sun {
			out.pos[i] = {axis.x, axis.y, axis.z, render.LIGHT_SUN}
			continue
		}
		at := light_view_pos(app, l)
		out.pos[i] = {at.x, at.y, at.z, render.LIGHT_POINT if l.kind == .Point else render.LIGHT_SPOT}
		ref := l.ref if l.ref > 0 else app.camera.distance
		out.shape[i] = {ref, max(l.reach, 0), 0, 0}
		if l.kind == .Spot {
			half := math.to_radians(clamp(l.cone, LIGHT_CONE_MIN, LIGHT_CONE_MAX)) * 0.5
			outer := math.cos(half)
			// The inner cosine stays above the outer one, so the edge's fade is never a
			// division by nothing.
			inner := max(math.cos(half * (1 - clamp(l.blend, 0, 1))), outer + 1e-4)
			out.spot[i] = {-axis.x, -axis.y, -axis.z, outer}
			out.shape[i].z = inner
		}
	}
	return out
}

// Whether the lights stay with the scene, as the Lights section's All fixed to the scene
// shows it: every light does, or with none the environment does.
lights_fixed :: proc(app: ^App) -> bool {
	set := &app.scene.lights
	if set.count <= 0 do return app.env.fixed
	for l in set.lights[:set.count] do if l.space != .Scene do return false
	return true
}

// Fixes every light, and the environment, to the scene, or to the camera again, keeping
// each light exactly where it is on screen; the environment keeps where it is as far as a
// turn about the up axis can: the turn takes the camera's own turn about it in or out, so
// only a camera tilted up or down sees it move.
lights_fix :: proc(app: ^App, fixed: bool) {
	space := Light_Space.Scene if fixed else .Camera
	// Moved before the turn changes when they go to the scene, after it when they come
	// back, so the turn they move with is the one they then have.
	if fixed do for i in 0 ..< int(app.scene.lights.count) do light_set_space(app, i, space)
	if fixed != app.env.fixed {
		v := camera.orbit_view(app.camera)
		yaw := math.to_degrees(math.atan2(v[2, 0], v[2, 2]))
		turn := app.light_turn + yaw if fixed else app.light_turn - yaw
		app.light_turn = math.mod(turn + 540, 360) - 180
		app.env.fixed = fixed
	}
	if !fixed do for i in 0 ..< int(app.scene.lights.count) do light_set_space(app, i, space)
}

// Fixes `set`'s lights and the environment to the scene, or to the camera again, as
// `lights_fixed` meant in settings files and scripts from before each light had its own
// space: the lights' numbers stay and are read in the other frame, the scene's axes turned
// by Turn all and Height all, so a light fixed this way stays where the old flag put it.
lights_fixed_set :: proc(app: ^App, set: ^Light_Set, fixed: bool) {
	rig := lights_frame(app)
	for &l in set.lights {
		if l.space == (.Scene if fixed else .Camera) do continue
		if fixed {
			l.dir, l.pos = rig * l.dir, app.camera.target + rig * l.pos
		} else {
			back := linalg.transpose(rig)
			l.dir, l.pos = back * l.dir, back * (l.pos - app.camera.target)
		}
		l.space = .Scene if fixed else .Camera
	}
	app.env.fixed = fixed
}

// The lights as a fresh install has them: the scene's and the starting lights
// LIGHTS_DEFAULT, unturned, moving with the camera, the first light picked.
lights_reset :: proc(app: ^App) {
	app.light_turn, app.light_height, app.env.fixed = 0, 0, false
	app.scene.lights, app.start_lights = LIGHTS_DEFAULT, LIGHTS_DEFAULT
	app.light_pick = 0
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

// A change to the lights in the Lights section, from its press to its release: one undo
// step, as a drag of the Transform values is.
Light_Drag :: struct {
	active: bool,
	from:   Light_Set,
}

// Notes that the Lights section changed the lights from `before` this frame.
light_drag_changed :: proc(app: ^App, before: Light_Set) {
	d := &app.ui.light_drag
	if !d.active do d^ = {active = true, from = before}
}

// Ends a change to the lights once the pointer lets go (or at once with `force`), as one
// undo step. Runs every frame, so a drag ends even if the section closed meanwhile.
light_drag_end :: proc(app: ^App, force := false) {
	d := &app.ui.light_drag
	if !d.active || (!force && .Left in app.device.down) do return
	d.active = false
	if app.scene.lights != d.from do history_record_lights(app, d.from, "Lights")
}

// A .Lights entry's lights before the change and after it, owned by the entry.
Light_Step :: struct {
	before, after: Light_Set,
}

// Lists the change of the lights from `before` to what they are now as the newest undo
// step.
history_record_lights :: proc(app: ^App, before: Light_Set, what: string) {
	step := new(Light_Step)
	step^ = {before, app.scene.lights}
	history_push(app, History_Entry{kind = .Lights, what = what, at = time.tick_now(), lights = step})
}
