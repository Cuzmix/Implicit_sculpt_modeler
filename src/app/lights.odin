package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../geom"
import "../render"
import "../ui"

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
// A colour temperature's range in kelvin: candlelight to a clear blue sky, where the
// Planckian locus fit kelvin_rgb uses holds.
LIGHT_KELVIN_MIN :: 1700
LIGHT_KELVIN_MAX :: 12000
// The bytes a light's name keeps, its last always 0, so it is at most 23 long.
LIGHT_NAME :: 24

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
	// A colour temperature in kelvin, LIGHT_KELVIN_MIN to LIGHT_KELVIN_MAX, which the light
	// shines in instead of `color`, as a lamp in Blender, KeyShot or Marmoset is set; 0
	// for the colour as picked.
	kelvin:   f32,
	name:     [LIGHT_NAME]u8, // as typed, 0 after it; empty for "Light <N>"
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
		// A script's colour temperature below the range is the warmest there is.
		if l.kelvin > 0 do l.kelvin = clamp(l.kelvin, LIGHT_KELVIN_MIN, LIGHT_KELVIN_MAX)
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
		rgb := light_rgb(l)
		out.color[i] = {rgb.r, rgb.g, rgb.b, l.strength}
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

// Adds a light of `kind` after the others, picked, and returns its place; -1 when there
// are LIGHT_COUNT already. A sun moves with the camera, shining from the upper right in
// front, as a fill is placed; a point light or a spot stands in the scene, as a lamp does
// in Blender or KeyShot, up and to the right of the orbit's centre, as far away as the
// camera, a spot aimed at the centre.
light_add :: proc(app: ^App, kind: Light_Kind) -> int {
	set := &app.scene.lights
	if set.count >= LIGHT_COUNT do return -1
	i := int(set.count)
	set.lights[i] = {on = true, kind = kind, dir = {0.5, 0.45, 0.75}, strength = 1, color = 1, cone = 45, blend = 0.25}
	set.count += 1
	lights_settle(app)
	if kind != .Sun do light_set_space(app, i, .Scene)
	app.light_pick = i
	return i
}

// Deletes light `i`, the ones after it moving up; the pick stays on the light after it,
// or the last.
light_delete :: proc(app: ^App, i: int) {
	set := &app.scene.lights
	if i < 0 || i >= int(set.count) do return
	copy(set.lights[i:set.count], set.lights[i + 1:set.count])
	set.count -= 1
	// The slot the last light left keeps a copy of it, past the count, where nothing reads
	// it; a light added later is made whole.
	app.light_pick = clamp(app.light_pick, 0, max(int(set.count) - 1, 0))
}

// A light's name in the Lights section and the History: the one typed for it, else its
// place, as the markers on the sphere number it.
light_name :: proc(set: ^Light_Set, i: int) -> string {
	if name := rename_text(set.lights[i].name[:]); name != "" do return name
	return fmt.tprintf("Light %d", i + 1)
}

// The illuminance, in lux, a sun of strength 1 stands for in a file: a white surface
// facing it shows white, as a sun of pi watts a square metre does in Blender, at the 683
// lumens a watt glTF's importers count.
LIGHT_SUN_LUX :: math.PI * 683

// The scene's lights that are on, as a file exported from `obj` carries them: placed and
// pointing as the view shows them now, in the object's own space as its mesh is written;
// a point light's or a spot's candela are what makes it as bright as the sun of its
// Intensity at the distance it matches one (Light.ref), in the object's units.
export_lights :: proc(app: ^App, obj: ^Object) -> []geom.Export_Light {
	set := &app.scene.lights
	out := make([dynamic]geom.Export_Light, 0, int(set.count), context.temp_allocator)
	t := obj.transform
	for l, i in set.lights[:set.count] {
		if !l.on || l.strength <= 0 do continue
		e := geom.Export_Light {
			name      = light_name(set, i),
			color     = light_rgb(l),
			intensity = l.strength * LIGHT_SUN_LUX,
			direction = linalg.normalize(to_local_dir(t, -light_world_dir(app, i))),
		}
		if l.kind != .Sun && l.pos != {} {
			e.kind = .Point if l.kind == .Point else .Spot
			e.position = to_local(t, light_world_pos(app, l))
			ref := l.ref / t.scale
			e.intensity *= ref * ref
			e.range = l.reach / t.scale
			half := math.to_radians(clamp(l.cone, LIGHT_CONE_MIN, LIGHT_CONE_MAX)) * 0.5
			e.outer_cone, e.inner_cone = half, half * (1 - clamp(l.blend, 0, 1))
		}
		append(&out, e)
	}
	return out[:]
}

// Names light `l` `text`, cut to what LIGHT_NAME keeps without splitting a character.
light_name_set :: proc(l: ^Light, text: string) {
	l.name = {}
	n := min(len(text), LIGHT_NAME - 1)
	for n > 0 && n < len(text) && text[n] & 0xc0 == 0x80 do n -= 1
	_ = copy(l.name[:], text[:n])
}

// The colour light `l` shines in, linear: its colour temperature's when it has one.
light_rgb :: proc(l: Light) -> [3]f32 {
	return kelvin_rgb(l.kelvin) if l.kelvin > 0 else l.color
}

// The colour of a black body at `kelvin`, linear sRGB scaled so its largest channel is 1:
// the Planckian locus's chromaticity by Kim et al.'s cubic fit (good from 1667 K to
// 25000 K), at a luminance of 1, through XYZ to linear sRGB, the negatives clipped.
// 6500 K is a faintly pink white, as the locus runs just above D65.
kelvin_rgb :: proc(kelvin: f32) -> [3]f32 {
	t := f64(clamp(kelvin, LIGHT_KELVIN_MIN, LIGHT_KELVIN_MAX))
	t1, t2, t3 := 1e3 / t, 1e6 / (t * t), 1e9 / (t * t * t)
	x := -0.2661239 * t3 - 0.2343589 * t2 + 0.8776956 * t1 + 0.179910 if t <= 4000 else -3.0258469 * t3 + 2.1070379 * t2 + 0.2226347 * t1 + 0.240390
	y: f64
	switch {
	case t <= 2222: y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
	case t <= 4000: y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
	case:           y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
	}
	X, Y, Z := x / y, 1.0, (1 - x - y) / y
	rgb := [3]f64{
		max(3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z, 0),
		max(-0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z, 0),
		max(0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z, 0),
	}
	top := max(rgb.r, rgb.g, rgb.b)
	return {f32(rgb.r / top), f32(rgb.g / top), f32(rgb.b / top)}
}

// A change to the lights in the Lights section, from its press to its release: one undo
// step, as a drag of the Transform values is.
Light_Drag :: struct {
	active: bool,
	from:   Light_Set,
	what:   string, // the step's name in the History (a constant)
	// The text field typed into, which keeps the step open while it has the keys, so a
	// name typed is one step; 0 for none.
	field:  ui.Id,
}

// Notes that the Lights section changed the lights from `before` this frame; `what` names
// the step, unless an earlier change of the same press already did, and `field` is a text
// field typed into, which keeps the step open while it has the keys.
light_drag_changed :: proc(app: ^App, before: Light_Set, what := "Lights", field: ui.Id = 0) {
	d := &app.ui.light_drag
	if !d.active do d^ = {active = true, from = before, what = what}
	if field != 0 do d.field = field
}

// Ends a change to the lights once the pointer lets go (or at once with `force`), as one
// undo step. Runs every frame, so a drag ends even if the section closed meanwhile.
light_drag_end :: proc(app: ^App, force := false) {
	d := &app.ui.light_drag
	if !d.active || (!force && (.Left in app.device.down || (d.field != 0 && app.kit.ctx.text_focus == d.field))) do return
	d.active = false
	if app.scene.lights != d.from do history_record_lights(app, d.from, d.what if d.what != "" else "Lights")
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
