package main

import "core:math"
import "core:math/linalg"
import "core:os"
import "core:testing"

import "../camera"
import "../geom"
import "../gizmo"
import "../render"

@(private = "file")
near :: proc(a, b: [3]f32, eps: f32 = 1e-5) -> bool {
	return linalg.length(a - b) < eps
}

// The shader's light_at (mesh_shading.glsl) on the CPU: toward light `i` from `p` (view
// space) and how much of its strength arrives there.
@(private = "file")
light_at :: proc(l: render.Lights, i: int, p: [3]f32) -> (k: f32, toward: [3]f32) {
	at := l.pos[i]
	if at.w < 0.5 do return 1, at.xyz
	d := at.xyz - p
	dist2 := max(linalg.dot(d, d), 1e-8)
	toward = d / math.sqrt(dist2)
	shape := l.shape[i]
	k = shape.x * shape.x / dist2
	if shape.y > 0 {
		x := dist2 / (shape.y * shape.y)
		w := clamp(1 - x * x, 0, 1)
		k *= w * w
	}
	if at.w > 1.5 {
		e0, e1 := l.spot[i].w, shape.z
		c := clamp((linalg.dot(-toward, l.spot[i].xyz) - e0) / (e1 - e0), 0, 1)
		k *= c * c * (3 - 2 * c)
	}
	return
}

// Reset, the lights are the renderer's default: the key and fill on, the other two off,
// all white, full ambient light, the studio unturned. Turning the set a quarter to the
// right swings the key light from the viewer's left to the right.
@(test)
lights_default_to_the_renderers_lights :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	lights_reset(&app)
	got, want := viewport_lights(&app), render.lights_default()
	for c in 0 ..< 3 do testing.expectf(t, linalg.length(got.rig[c] - want.rig[c]) < 1e-6, "studio column %d: %v against %v", c, got.rig[c], want.rig[c])
	for i in 0 ..< LIGHT_COUNT {
		testing.expectf(t, linalg.length(got.pos[i] - want.pos[i]) < 1e-6, "light %d at %v against %v", i + 1, got.pos[i], want.pos[i])
		testing.expect_value(t, got.color[i], want.color[i])
		testing.expect_value(t, got.spot[i], want.spot[i])
		testing.expect_value(t, got.shape[i], want.shape[i])
	}
	key := light_view_dir(&app, 0)
	app.light_turn = 90
	turned := light_view_dir(&app, 0)
	testing.expectf(t, turned.x > 0.5 && abs(turned.y - key.y) < 1e-5, "turned key %v", turned)
	app.light_height = 30
	testing.expect(t, light_view_dir(&app, 0).y > turned.y)
	// Lights that are off, or past the count, send nothing; the colour goes through with
	// the strength.
	app.scene.lights.lights[0].on = false
	app.scene.lights.lights[1].color = {1, 0.5, 0.25}
	app.scene.lights.lights[5].on = true
	l := viewport_lights(&app)
	testing.expect_value(t, l.color[0], [4]f32{})
	testing.expect_value(t, l.pos[0], [4]f32{})
	testing.expect_value(t, l.color[1], [4]f32{1, 0.5, 0.25, render.FILL_STRENGTH})
	testing.expect_value(t, l.color[5], [4]f32{})
}

// A point light is as bright as a sun of its strength at its reference distance and
// falls off with the square of the distance, faded to nothing at its reach; a spot lights
// only inside its cone, its edge faded over the soft edge.
@(test)
point_and_spot_lights_fall_off :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	lights_reset(&app)
	set := &app.scene.lights
	set.lights[2] = {on = true, kind = .Point, dir = {0, 0, 1}, strength = 1, color = 1, cone = 45, blend = 0.25}
	lights_settle(&app)
	p := set.lights[2]
	testing.expectf(t, abs(p.ref - app.camera.distance) < 1e-4, "placed at %v, ref %v", p.pos, p.ref)
	testing.expect(t, near(p.pos, {0, 0, app.camera.distance}, 1e-4))
	l := viewport_lights(&app)
	target := view_target(&app)
	testing.expect(t, near(l.pos[2].xyz, target + {0, 0, app.camera.distance}, 1e-4))
	testing.expect_value(t, l.pos[2].w, f32(render.LIGHT_POINT))
	k, toward := light_at(l, 2, target)
	testing.expectf(t, abs(k - 1) < 1e-4 && near(toward, {0, 0, 1}), "at the target %v %v", k, toward)
	half := target + {0, 0, app.camera.distance * 0.5}
	k, _ = light_at(l, 2, half)
	testing.expectf(t, abs(k - 4) < 1e-3, "twice as close is four times as bright: %v", k)
	set.lights[2].reach = app.camera.distance * 1.5
	l = viewport_lights(&app)
	k, _ = light_at(l, 2, target)
	window := 1 - math.pow(f32(1) / 1.5, 4)
	testing.expectf(t, abs(k - window * window) < 1e-4, "inside its reach %v", k)
	k, _ = light_at(l, 2, target - {0, 0, app.camera.distance})
	testing.expectf(t, k == 0, "past its reach %v", k)

	// A spot aimed at the target: full on its axis, nothing outside its cone.
	set.lights[2].kind, set.lights[2].reach, set.lights[2].cone, set.lights[2].blend = .Spot, 0, 40, 0.5
	l = viewport_lights(&app)
	testing.expect(t, near(l.spot[2].xyz, {0, 0, -1}))
	testing.expectf(t, abs(l.spot[2].w - math.cos(math.to_radians(f32(20)))) < 1e-6, "outer %v", l.spot[2].w)
	testing.expectf(t, abs(l.shape[2].z - math.cos(math.to_radians(f32(10)))) < 1e-6, "inner %v", l.shape[2].z)
	k, _ = light_at(l, 2, target)
	testing.expectf(t, abs(k - 1) < 1e-4, "on the axis %v", k)
	side := target + {app.camera.distance * math.tan(math.to_radians(f32(30))), 0, 0}
	k, _ = light_at(l, 2, side)
	testing.expectf(t, k == 0, "outside the cone %v", k)
	edge := target + {app.camera.distance * math.tan(math.to_radians(f32(15))), 0, 0}
	k, _ = light_at(l, 2, edge)
	testing.expectf(t, k > 0.05 && k < 1, "in the soft edge %v", k)
	// A hard edge still has an inner cosine above the outer one.
	set.lights[2].blend = 0
	l = viewport_lights(&app)
	testing.expect(t, l.shape[2].z > l.spot[2].w)
	// The studio render's shadow comes from where the brightest light stands.
	set.lights[0].strength, set.lights[1].on, set.lights[2].strength = 0.5, false, 2
	dir, lit := render.lights_key(viewport_lights(&app), target - {1, 0, 0})
	testing.expectf(t, lit && near(dir, linalg.normalize([3]f32{1, 0, app.camera.distance})), "key from %v", dir)
}

// A light moving with the camera stays where it is on screen while the camera goes
// round; one in the scene stays where it is in the scene. Moving a light from one to the
// other keeps it where it is, and back again gives the numbers it had.
@(test)
camera_and_scene_lights_stay_where_they_belong :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.yaw, app.camera.pitch = 0.4, -0.2
	app.camera.target = {0.3, -0.1, 0.2}
	lights_reset(&app)
	app.light_turn, app.light_height = 25, 10
	set := &app.scene.lights
	set.lights[2] = {on = true, kind = .Spot, dir = {0.3, 0.5, 0.8}, pos = {0.5, 0.8, 1.6}, ref = 2, strength = 1, color = 1, cone = 30}
	set.lights[3] = {on = true, kind = .Point, space = .Scene, dir = {0, 1, 0}, pos = {1, 2, -1}, ref = 2, strength = 1, color = 1, cone = 45}
	first := viewport_lights(&app)
	world :: proc(app: ^App, at: [3]f32) -> [3]f32 {
		v := camera.orbit_view(app.camera)
		inv := linalg.inverse(v)
		return (inv * [4]f32{at.x, at.y, at.z, 1}).xyz
	}
	held := world(&app, first.pos[3].xyz)
	testing.expect(t, near(held, {1, 2, -1}, 1e-4))
	app.camera.yaw += 1.3
	app.camera.pitch = 0.5
	second := viewport_lights(&app)
	testing.expectf(t, near(second.pos[2].xyz, first.pos[2].xyz, 1e-4), "the camera's spot moved on screen: %v to %v", first.pos[2], second.pos[2])
	testing.expect(t, near(second.spot[2].xyz, first.spot[2].xyz, 1e-5))
	testing.expectf(t, near(world(&app, second.pos[3].xyz), held, 1e-4), "the scene's point moved in the scene")

	// Round trips, both ways, keep the light where it is and its numbers.
	for i in 2 ..= 3 {
		was := set.lights[i]
		shown := viewport_lights(&app)
		other := Light_Space.Scene if was.space == .Camera else .Camera
		light_set_space(&app, i, other)
		moved := viewport_lights(&app)
		testing.expectf(t, near(moved.pos[i].xyz, shown.pos[i].xyz, 1e-4) && near(moved.spot[i].xyz, shown.spot[i].xyz, 1e-5), "light %d moved on screen going to %v", i + 1, other)
		light_set_space(&app, i, was.space)
		back := set.lights[i]
		testing.expectf(t, near(back.dir, was.dir) && near(back.pos, was.pos) && back.space == was.space, "light %d came back as %v, was %v", i + 1, back, was)
	}
}

// Fixing the lights to the scene keeps every one exactly where it is on screen, and they
// then stay put in the scene while the camera turns; the environment goes with them.
@(test)
lights_fixed_to_the_scene_stay_put :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.yaw = math.to_radians(f32(70))
	app.camera.pitch = 0
	lights_reset(&app)
	app.light_turn = 20
	before := light_view_dir(&app, 0)
	lights_fix(&app, true)
	testing.expect(t, lights_fixed(&app) && app.env.fixed)
	after := light_view_dir(&app, 0)
	testing.expectf(t, near(after, before, 1e-4), "fixing moved the key from %v to %v", before, after)

	// In the scene: the view-space key turned back by the camera's turn is the same.
	world :: proc(app: ^App, dir: [3]f32) -> [3]f32 {
		return linalg.transpose(view_rotation(app)) * dir
	}
	held := world(&app, after)
	app.camera.yaw += 1.1
	app.camera.pitch = 0.4
	moved := world(&app, light_view_dir(&app, 0))
	testing.expectf(t, near(moved, held, 1e-4), "the key moved in the scene from %v to %v", held, moved)

	shown := light_view_dir(&app, 0)
	lights_fix(&app, false)
	testing.expect(t, !lights_fixed(&app) && !app.env.fixed)
	testing.expect(t, near(light_view_dir(&app, 0), shown, 1e-4))
	testing.expect(t, app.light_turn >= -180 && app.light_turn <= 180)
}

// The sphere places a light as the camera sees it, whatever the set's turn or the
// camera: a point on the sphere is where the light then shows, on the side it was on; a
// point past the outline is pulled onto it; a flip sends it behind at the same place. A
// point light moves round the target at the distance it was.
@(test)
the_light_sphere_places_lights_as_the_camera_sees_them :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.yaw = 0.8
	app.camera.pitch = -0.3
	lights_reset(&app)
	app.light_turn, app.light_height = 35, -20
	lights_fix(&app, true)

	d := light_sphere_dir({0.3, 0.4}, true)
	testing.expectf(t, near(d, {0.3, 0.4, math.sqrt(f32(0.75))}), "front point %v", d)
	testing.expectf(t, light_sphere_dir({0.3, 0.4}, false).z < 0, "behind")
	edge := light_sphere_dir({3, 4}, true)
	testing.expectf(t, near(edge, {0.6, 0.8, 0}), "past the outline %v", edge)

	light_set_view_dir(&app, 2, d)
	testing.expectf(t, near(light_view_dir(&app, 2), d), "light 3 shows at %v, placed at %v", light_view_dir(&app, 2), d)
	light_flip(&app, 2)
	flipped := light_view_dir(&app, 2)
	testing.expectf(t, near(flipped, {d.x, d.y, -d.z}), "flipped to %v", flipped)
	light_flip(&app, 2)
	testing.expect(t, near(light_view_dir(&app, 2), d))

	set := &app.scene.lights
	for space in Light_Space {
		set.lights[1].kind, set.lights[1].ref, set.lights[1].pos = .Point, 0, {}
		light_set_space(&app, 1, space)
		lights_settle(&app)
		far := light_distance(&app, set.lights[1])
		light_set_view_dir(&app, 1, d)
		testing.expectf(t, near(light_view_dir(&app, 1), d, 1e-4), "a %v point light shows at %v, placed at %v", space, light_view_dir(&app, 1), d)
		testing.expectf(t, abs(light_distance(&app, set.lights[1]) - far) < 1e-4, "and stays as far away")
	}

	// A direction set to nothing (a script setting it number by number) is its default's.
	set.lights[3].dir = {}
	lights_fix(&app, false)
	app.light_turn, app.light_height = 0, 0
	testing.expect(t, near(light_view_dir(&app, 3), linalg.normalize(LIGHTS_DEFAULT.lights[3].dir)))
}

// A press picks the nearest light that is on within the reach of a finger; lights that
// are off, or past the count, have no marker to press.
@(test)
the_light_sphere_picks_the_nearest_light :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	lights_reset(&app)
	centre, radius := [2]f32{100, 100}, f32(80)
	key := light_marker(&app, 0, centre, radius)
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, key + {5, 5}, 22), 0)
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, light_marker(&app, 1, centre, radius), 22), 1)
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, centre, 22), -1)
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, light_marker(&app, 2, centre, radius), 22), -1)
	app.scene.lights.lights[2].on = true
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, light_marker(&app, 2, centre, radius), 22), 2)
	app.scene.lights.count = 2
	testing.expect_value(t, light_sphere_hit(&app, centre, radius, light_marker(&app, 2, centre, radius), 22), -1)
}

// The settings file keeps every starting light, its kind, place and colour, how many
// there are and the ambient light; a file from before the four lights keeps its key and
// fill strengths, the fill's as the share of its full strength it was, and one from
// before each light had its own space keeps lights fixed to the scene where they were.
@(test)
lights_are_remembered :: proc(t: ^testing.T) {
	path := "build/lights_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	lights_reset(&a)
	a.start_lights.lights[2] = {on = true, kind = .Spot, space = .Scene, dir = linalg.normalize([3]f32{0.2, -0.5, -0.6}), pos = {1.5, -2, 3.25}, strength = 1.4, ref = 2.5, reach = 7, cone = 33, blend = 0.6, color = {0.9, 0.3, 0.1}}
	a.start_lights.lights[6] = {on = true, kind = .Point, dir = {0, 1, 0}, strength = 0.5, cone = 45, color = 1, kelvin = 3200, radius = 0.4, angle = 7}
	light_name_set(&a.start_lights.lights[6], "Warm #2 lamp")
	a.start_lights.lights[0].on = false
	a.start_lights.ambient, a.start_lights.count = 0.4, 7
	testing.expect(t, settings_save(&a, path))
	b: App
	defer results_destroy(&b)
	lights_reset(&b)
	settings_load(&b, path)
	for i in 0 ..< LIGHT_COUNT {
		x, y := a.start_lights.lights[i], b.start_lights.lights[i]
		testing.expectf(t, x.on == y.on && x.kind == y.kind && x.space == y.space, "light %d: %v against %v", i + 1, y, x)
		testing.expectf(t, near(y.dir, x.dir, 1e-4) && near(y.pos, x.pos, 1e-4) && near(y.color, x.color, 1e-5), "light %d at %v against %v", i + 1, y, x)
		testing.expectf(t, abs(y.angle - x.angle) < 1e-4 && abs(y.radius - x.radius) < 1e-5, "light %d sized %v %v against %v %v", i + 1, y.angle, y.radius, x.angle, x.radius)
		testing.expectf(t, y.kelvin == x.kelvin && y.name == x.name, "light %d named %q at %v K against %q at %v K", i + 1, light_name(&b.start_lights, i), y.kelvin, light_name(&a.start_lights, i), x.kelvin)
		testing.expectf(t, abs(y.strength - x.strength) < 1e-5 && abs(y.ref - x.ref) < 1e-5 && abs(y.reach - x.reach) < 1e-5 && abs(y.cone - x.cone) < 1e-4 && abs(y.blend - x.blend) < 1e-5, "light %d: %v against %v", i + 1, y, x)
	}
	testing.expect_value(t, b.start_lights.ambient, 0.4)
	testing.expect_value(t, b.start_lights.count, 7)
	// The scene's own lights are not the settings'.
	testing.expect_value(t, b.scene.lights, LIGHTS_DEFAULT)

	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("light_key 1.5\nlight_fill 2\nlight3_on 1\nlight3_x 0\nlight3_y 0\nlight3_z 1\nlight_turn 90\nlights_fixed 1\n")) == nil)
	c: App
	defer results_destroy(&c)
	lights_reset(&c)
	settings_load(&c, path)
	testing.expect_value(t, c.start_lights.lights[0].strength, 1.5)
	testing.expectf(t, abs(c.start_lights.lights[1].strength - 2 * render.FILL_STRENGTH) < 1e-6, "fill %v", c.start_lights.lights[1].strength)
	// Fixed then meant the set turned by Turn all in the scene's axes: a light toward the
	// viewer turned a quarter to the right is toward +x in the scene.
	l3 := c.start_lights.lights[2]
	testing.expectf(t, l3.space == .Scene && near(l3.dir, {1, 0, 0}, 1e-5), "the old fixed light 3 is %v", l3)
	testing.expect(t, c.env.fixed)
	// Older scripts still set the first two lights' strengths by their old names, and
	// scripts set the scene's lights, not the starting ones.
	for key in ([2]string{"light_key", "light_fill"}) {
		s, found := script_setting(key)
		testing.expectf(t, found, "%s is a script value", key)
		testing.expect(t, s.offset >= offset_of(App, scene) && s.offset < offset_of(App, scene) + size_of(Scene))
	}
	free_all(context.temp_allocator)
}

// Every light key names the light and field its row writes, scripts' and the settings
// file's alike, and lands on a field of the type it says.
@(test)
light_keys_name_their_fields :: proc(t: ^testing.T) {
	for keys, i in LIGHT_KEYS {
		for key, f in keys {
			testing.expect_value(t, key, fmt_light_key(i, LIGHT_FIELDS[f].name))
			for base in ([2]uintptr{offset_of(App, start_lights), offset_of(App, scene) + offset_of(Scene, lights)}) {
				row, ok := light_setting(base, key)
				testing.expect(t, ok && row == light_row(base, i, f))
				testing.expect(t, row.offset >= base && row.offset + uintptr(size_of(f32)) <= base + size_of(Light_Set))
			}
		}
	}
	for key in LIGHT_COLOR_KEYS {
		_, ok := light_color_key(key)
		testing.expect(t, ok && script_line(key).parse != nil)
	}
	for key, i in LIGHT_NAME_KEYS do testing.expect_value(t, key, fmt_light_key(i, "name"))
	_, ok := light_setting(0, "light9_on")
	testing.expect(t, !ok)
}

@(private = "file")
fmt_light_key :: proc(i: int, field: string) -> string {
	buf: [32]u8
	n := copy(buf[:], "light")
	buf[n] = u8('1' + i)
	n += 1
	buf[n] = '_'
	n += 1
	n += copy(buf[n:], field)
	return string(buf[:n])
}

// The scene file keeps the lights as they were, bit for bit, and refuses damaged ones.
@(test)
lights_round_trip_in_the_scene_file :: proc(t: ^testing.T) {
	set := LIGHTS_DEFAULT
	set.lights[1] = {on = true, kind = .Spot, space = .Scene, dir = {0.1, -0.2, 0.3}, pos = {-4, 5.5, 1e-3}, strength = 1.75, ref = 3, reach = 12, cone = 70, blend = 0.4, color = {0.2, 0.4, 1}, kelvin = 4100, angle = 4.5, radius = 0.75}
	light_name_set(&set.lights[1], "Rim ü")
	set.count, set.ambient = 3, 0.25
	out: [dynamic]u8
	defer delete(out)
	lights_put(&out, set)
	r := geom.byte_reader(out[:])
	back, ok := lights_get(&r, LIGHTS_DEFAULT)
	testing.expect(t, ok && r.ok && r.at == len(out))
	testing.expect_value(t, back, set)
	// Past the count the lights are the ones given for the rest.
	set.count = 1
	clear(&out)
	lights_put(&out, set)
	r = geom.byte_reader(out[:])
	back, ok = lights_get(&r, LIGHTS_DEFAULT)
	testing.expect(t, ok && back.lights[1] == LIGHTS_DEFAULT.lights[1] && back.count == 1)

	damage :: proc(t: ^testing.T, set: Light_Set, at: int, value: u8, bytes := 1) {
		out: [dynamic]u8
		defer delete(out)
		lights_put(&out, set)
		for &b in out[at:][:bytes] do b = value
		r := geom.byte_reader(out[:])
		_, ok := lights_get(&r, LIGHTS_DEFAULT)
		testing.expectf(t, !ok, "byte %d set to %d was read", at, value)
	}
	set.count = 2
	damage(t, set, 0, 9) // too many lights
	damage(t, set, 5, 2) // `on` is not 0 or 1
	damage(t, set, 6, 3) // no such kind
	damage(t, set, 7, 2) // no such space
	damage(t, set, 5 + 3, 0xff, 4) // the first direction's x a NaN
	damage(t, set, 5 + 3 + 24, 0xff, 4) // the strength a NaN
	damage(t, set, 5 + 3 + 24 + 12, 0, 4) // the cone 0 degrees
	LIGHT_BYTES :: 3 + 24 + 5 * 4 + 12 + 4 + LIGHT_NAME + 8
	damage(t, set, 5 + LIGHT_BYTES + 59, 0x10, 4) // the second light's temperature far too cold
	damage(t, set, 5 + LIGHT_BYTES + 63 + LIGHT_NAME - 1, 'x') // its name not ended by a zero
	damage(t, set, 5 + LIGHT_BYTES + 63 + 1, 0xff) // its name not UTF-8
	damage(t, set, 5 + LIGHT_BYTES + 63 + 10, 'x') // a byte after its name's zero
	damage(t, set, 5 + LIGHT_BYTES + 87, 0xff, 4) // its angle a NaN
	damage(t, set, 5 + LIGHT_BYTES + 91, 0x7f, 4) // its radius far too big
	// A file from before version 20 has neither, and reads as no temperature and no name.
	clear(&out)
	set.count = 2
	lights_put(&out, set)
	old: [dynamic]u8
	defer delete(old)
	append(&old, ..out[:5])
	for i in 0 ..< 2 do append(&old, ..out[5 + i * LIGHT_BYTES:][:LIGHT_BYTES - 8 - 4 - LIGHT_NAME])
	r = geom.byte_reader(old[:])
	back, ok = lights_get(&r, LIGHTS_DEFAULT, 19)
	testing.expect(t, ok && r.at == len(old))
	testing.expect(t, back.lights[1].kelvin == 0 && back.lights[1].name == {} && back.lights[1].color == set.lights[1].color)
	testing.expect(t, back.lights[1].angle == 0 && back.lights[1].radius == 0)
	// One from version 20 has the temperature and name but no size, which reads as none.
	clear(&old)
	append(&old, ..out[:5])
	for i in 0 ..< 2 do append(&old, ..out[5 + i * LIGHT_BYTES:][:LIGHT_BYTES - 8])
	r = geom.byte_reader(old[:])
	back, ok = lights_get(&r, LIGHTS_DEFAULT, 20)
	testing.expect(t, ok && r.at == len(old))
	testing.expect(t, back.lights[1].kelvin == 4100 && light_name(&back, 1) == "Rim ü" && back.lights[1].angle == 0 && back.lights[1].radius == 0)
	// Cut short.
	clear(&out)
	lights_put(&out, set)
	r = geom.byte_reader(out[:len(out) - 1])
	_, ok = lights_get(&r, LIGHTS_DEFAULT)
	testing.expect(t, !ok)
}

// A change in the Lights section, from press to release, is one undo step, which undo
// takes back and redo puts back; nothing is undone under it while it lasts.
@(test)
light_changes_are_undo_steps :: proc(t: ^testing.T) {
	app: App
	defer history_destroy(&app.history)
	app.camera = camera.orbit_default()
	lights_reset(&app)
	before := app.scene.lights
	app.device.down += {.Left}
	app.scene.lights.lights[0].strength = 0.5
	light_drag_changed(&app, before)
	app.scene.lights.lights[0].strength = 0.25
	light_drag_changed(&app, before)
	light_drag_end(&app)
	testing.expect(t, history_busy(&app))
	testing.expect_value(t, len(app.history.done), 0)
	app.device.down -= {.Left}
	light_drag_end(&app)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect_value(t, history_next_label(app.history.done[:]), "Lights")
	testing.expect(t, !entry_is_step(app.history.done[0]))
	history_undo(&app)
	testing.expect_value(t, app.scene.lights, before)
	history_redo(&app)
	testing.expect_value(t, app.scene.lights.lights[0].strength, 0.25)
	// A change that ends where it began is no step.
	light_drag_changed(&app, app.scene.lights)
	light_drag_end(&app)
	testing.expect_value(t, len(app.history.done), 1)
}

// Add puts a light of the kind after the others and picks it: a sun with the camera, a
// point light or a spot in the scene, as far away as the camera, a spot aimed at the
// orbit's centre; past eight there is no room. Delete moves the ones after it up.
@(test)
lights_are_added_and_deleted :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.target = {0.2, 0.1, -0.3}
	lights_reset(&app)
	set := &app.scene.lights
	testing.expect_value(t, light_add(&app, .Spot), 4)
	testing.expect_value(t, app.light_pick, 4)
	spot := set.lights[4]
	testing.expect(t, spot.on && spot.kind == .Spot && spot.space == .Scene && set.count == 5)
	testing.expectf(t, abs(light_distance(&app, spot) - app.camera.distance) < 1e-4 && abs(spot.ref - app.camera.distance) < 1e-4, "placed at %v", spot.pos)
	l := viewport_lights(&app)
	aim := linalg.normalize(view_target(&app) - l.pos[4].xyz)
	testing.expectf(t, near(l.spot[4].xyz, aim, 1e-4), "aimed along %v, the centre is along %v", l.spot[4].xyz, aim)
	testing.expect_value(t, light_add(&app, .Sun), 5)
	testing.expect(t, set.lights[5].space == .Camera)
	for set.count < LIGHT_COUNT do _ = light_add(&app, .Point)
	testing.expect_value(t, light_add(&app, .Point), -1)

	third := set.lights[2]
	light_delete(&app, 1)
	testing.expect_value(t, set.count, LIGHT_COUNT - 1)
	testing.expect_value(t, set.lights[1], third)
	app.light_pick = LIGHT_COUNT - 2
	light_delete(&app, LIGHT_COUNT - 2)
	testing.expect_value(t, app.light_pick, LIGHT_COUNT - 3)
	for set.count > 0 do light_delete(&app, 0)
	testing.expect_value(t, app.light_pick, 0)
	light_delete(&app, 0)
	testing.expect_value(t, set.count, 0)
	free_all(context.temp_allocator)
}

// A light set by where it is in the scene is where the viewport shows it, in either space;
// a sun straight behind the camera has its marker on the orbit's centre, one turned
// aside on the circle round it, and a point light behind the camera is held at the edge.
@(test)
light_markers_stand_where_the_lights_are :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.yaw, app.camera.pitch = 0.6, -0.3
	app.camera.target = {0.2, 0.1, -0.3}
	lights_reset(&app)
	app.light_turn = 30
	set := &app.scene.lights
	set.lights[2] = {on = true, kind = .Point, dir = {0, 0, 1}, pos = {0.4, 0.2, 1}, ref = 2, strength = 1, color = 1, cone = 45}
	set.lights[3] = {on = true, kind = .Spot, space = .Scene, dir = {0, 1, 0}, pos = {0, 2, 0}, ref = 2, strength = 1, color = 1, cone = 45}
	for i in 2 ..= 3 {
		at := Vec3{1.5, -0.5, 2}
		dir := linalg.normalize(Vec3{1, -0.5, 2})
		light_set_world(&app, i, dir, at)
		testing.expectf(t, near(light_world_pos(&app, set.lights[i]), at, 1e-4), "light %d is at %v", i + 1, light_world_pos(&app, set.lights[i]))
		testing.expectf(t, near(light_world_dir(&app, i), dir, 1e-5), "light %d points %v", i + 1, light_world_dir(&app, i))
	}

	size := [2]f32{1600, 900}
	eye := camera.orbit_eye(app.camera)
	light_set_world(&app, 0, linalg.normalize(eye - app.camera.target))
	s, front, edge := light_marker_at(&app, 0, size)
	testing.expectf(t, linalg.length(s - size * 0.5) < 0.5 && front && !edge, "a sun from the camera at %v", s)
	light_set_view_dir(&app, 0, {1, 0, 0})
	s, front, edge = light_marker_at(&app, 0, size)
	testing.expectf(t, abs(s.x - (800 + SUN_MARKER_RADIUS * 900)) < 0.5 && abs(s.y - 450) < 0.5 && front && !edge, "a sun from the right at %v", s)
	light_set_view_dir(&app, 0, {0, 0.6, -0.8})
	s, front, edge = light_marker_at(&app, 0, size)
	testing.expectf(t, s.y < 450 && !front, "a sun from behind, above, at %v", s)

	light_set_world(&app, 2, {0, 0, 1}, eye + (eye - app.camera.target) * 0.5 + Vec3{0.1, 0, 0})
	s, _, edge = light_marker_at(&app, 2, size)
	testing.expectf(t, edge && s.x >= 0 && s.x <= size.x && s.y >= 0 && s.y <= size.y, "a point light behind the camera at %v", s)
	testing.expect_value(t, light_marker_pick(&app, s + 3, size), 2)
	testing.expect_value(t, light_marker_pick(&app, {5, 5}, size), -1)
}

// Place highlight turns a sun so its highlight lands where the finger is: on the surface
// facing the camera the light comes from the camera, on a tilted one from the mirror
// direction; a point light keeps its distance from the spot, a spot aimed at it.
@(test)
place_highlight_puts_the_highlight_under_the_finger :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.yaw, app.camera.pitch = -0.4, 0.2
	lights_reset(&app)
	eye := camera.orbit_eye(app.camera)
	hit := app.camera.target
	view := linalg.normalize(eye - hit)
	light_place_highlight(&app, 0, hit, view, 1)
	testing.expectf(t, near(light_world_dir(&app, 0), view, 1e-5), "facing: %v against %v", light_world_dir(&app, 0), view)
	// Facing away, the normal is turned to the side the camera sees.
	light_place_highlight(&app, 0, hit, -view, 1)
	testing.expect(t, near(light_world_dir(&app, 0), view, 1e-5))

	normal := linalg.normalize(view + linalg.normalize(linalg.cross(view, Vec3{0, 1, 0})) * 0.5)
	light_place_highlight(&app, 0, hit, normal, 1)
	toward := light_world_dir(&app, 0)
	testing.expectf(t, abs(linalg.dot(toward, normal) - linalg.dot(view, normal)) < 1e-5, "mirrored about the normal: %v", toward)
	testing.expectf(t, linalg.length(linalg.normalize(toward + view) - normal) < 1e-5, "the half vector is the normal: %v", toward)

	app.scene.lights.lights[3] = {on = true, kind = .Spot, space = .Scene, dir = {0, 1, 0}, pos = {0, 2, 0}, ref = 2, strength = 1, color = 1, cone = 45}
	light_place_highlight(&app, 3, hit, normal, 2.5)
	l := app.scene.lights.lights[3]
	testing.expectf(t, abs(linalg.length(l.pos - hit) - 2.5) < 1e-4, "the spot stands %v from the spot it lights", linalg.length(l.pos - hit))
	testing.expectf(t, near(linalg.normalize(l.pos - hit), l.dir, 1e-5), "the spot is aimed at it: %v", l.dir)
}

// A colour temperature shines warm below daylight and cool above it, its largest channel
// 1; a light with one shines in it whatever its colour, and a name is cut to what fits
// without splitting a character, or the light keeps its number for a name.
@(test)
colour_temperatures_and_names :: proc(t: ^testing.T) {
	day := kelvin_rgb(6500)
	testing.expectf(t, min(day.r, day.g, day.b) > 0.9 && max(day.r, day.g, day.b) == 1, "6500 K is %v", day)
	warm := kelvin_rgb(2700)
	testing.expectf(t, warm.r == 1 && warm.g < 0.75 && warm.b < 0.5, "2700 K is %v", warm)
	cool := kelvin_rgb(10000)
	testing.expectf(t, cool.b == 1 && cool.r < 0.85, "10000 K is %v", cool)
	testing.expect(t, kelvin_rgb(3000).b < kelvin_rgb(4000).b && kelvin_rgb(4000).b < kelvin_rgb(5000).b)
	l := Light{color = {0.1, 0.2, 0.3}}
	testing.expect_value(t, light_rgb(l), [3]f32{0.1, 0.2, 0.3})
	l.kelvin = 2700
	testing.expect_value(t, light_rgb(l), warm)

	set := LIGHTS_DEFAULT
	testing.expect_value(t, light_name(&set, 2), "Light 3")
	light_name_set(&set.lights[2], "  Key ##light  ")
	testing.expect_value(t, light_name(&set, 2), "Key #light")
	// 22 ASCII letters then a two-byte letter: the letter does not fit in 23 bytes whole.
	light_name_set(&set.lights[2], "abcdefghijklmnopqrstuvé")
	testing.expect_value(t, light_name(&set, 2), "abcdefghijklmnopqrstuv")
	testing.expect_value(t, set.lights[2].name[LIGHT_NAME - 1], 0)
	free_all(context.temp_allocator)
}

// The Distance slider moves a point light or a spot along the line from the orbit's
// centre, and a spot keeps pointing the way it did.
@(test)
light_distance_moves_along_the_line_from_the_centre :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.target = {0.5, 0, -0.25}
	lights_reset(&app)
	for space in Light_Space {
		app.scene.lights.lights[2] = {on = true, kind = .Spot, dir = linalg.normalize([3]f32{0, 1, 1}), pos = {1, 2, 2}, ref = 2, strength = 1, color = 1, cone = 45}
		light_set_space(&app, 2, space)
		before := light_world_pos(&app, app.scene.lights.lights[2])
		pointing := light_world_dir(&app, 2)
		light_set_center_distance(&app, 2, 7.5)
		after := light_world_pos(&app, app.scene.lights.lights[2])
		testing.expectf(t, abs(light_center_distance(&app, 2) - 7.5) < 1e-4, "%v: %v from the centre", space, light_center_distance(&app, 2))
		testing.expect(t, near(linalg.normalize(after - app.camera.target), linalg.normalize(before - app.camera.target), 1e-5))
		testing.expect(t, near(light_world_dir(&app, 2), pointing, 1e-5))
	}
}

// An exported object's file carries the lights that are on, where the view shows them,
// in the object's own space: a sun of strength 1 as pi watts a square metre's lux, a
// point light or a spot that bright at its matching distance in the object's units.
@(test)
lights_go_out_with_an_export :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.yaw = 0.7
	lights_reset(&app)
	set := &app.scene.lights
	set.lights[1].on = false
	set.lights[2] = {on = true, kind = .Spot, space = .Scene, dir = {0, 1, 0}, pos = {1, 4, 2}, ref = 3, reach = 10, strength = 0.5, color = 1, kelvin = 3000, cone = 60, blend = 0.5}
	light_name_set(&set.lights[2], "Lamp")
	obj := Object{transform = {position = {1, 0, 0}, scale = 2, rotation = {0, 90, 0}}}
	got := export_lights(&app, obj.transform)
	defer free_all(context.temp_allocator)
	if !testing.expect_value(t, len(got), 2) do return
	sun := got[0]
	testing.expect(t, sun.kind == .Directional && sun.name == "Light 1")
	testing.expectf(t, abs(sun.intensity - math.PI * 683) < 1e-2, "the sun's %v lux", sun.intensity)
	testing.expect(t, near(to_world_dir(obj.transform, sun.direction), -light_world_dir(&app, 0), 1e-5))
	spot := got[1]
	testing.expect(t, spot.kind == .Spot && spot.name == "Lamp" && spot.color == kelvin_rgb(3000))
	testing.expect(t, near(to_world(obj.transform, spot.position), {1, 4, 2}, 1e-4))
	testing.expect(t, near(to_world_dir(obj.transform, spot.direction), {0, -1, 0}, 1e-5))
	testing.expectf(t, abs(spot.intensity - 0.5 * math.PI * 683 * 1.5 * 1.5) < 1e-2, "the spot's %v candela", spot.intensity)
	testing.expect_value(t, spot.range, 5)
	testing.expect(t, abs(spot.outer_cone - math.to_radians(f32(30))) < 1e-6 && abs(spot.inner_cone - math.to_radians(f32(15))) < 1e-6)
}

// A light's size reaches the shader as light_shape.w: the sine of a sun's angular radius,
// a lamp's radius as it is (the view never scales), and nothing for a light without one,
// so the default lights shade exactly as before.
@(test)
light_size_reaches_the_shader :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	lights_reset(&app)
	app.camera = camera.orbit_default()
	for w in viewport_lights(&app).shape do testing.expect_value(t, w.w, 0)
	app.scene.lights.lights[0].angle = 60
	app.scene.lights.lights[1].angle = LIGHT_ANGLE_MAX + 50 // a script's, past the end
	_ = light_add(&app, .Point)
	app.scene.lights.lights[4].radius = 0.3
	app.scene.lights.lights[4].angle = 20 // kept for when it is a sun again, unused now
	lights_settle(&app)
	testing.expect_value(t, app.scene.lights.lights[1].angle, LIGHT_ANGLE_MAX)
	l := viewport_lights(&app)
	testing.expectf(t, abs(l.shape[0].w - 0.5) < 1e-6, "a 60 degree sun %v", l.shape[0].w)
	testing.expect_value(t, l.shape[4].w, 0.3)
	app.scene.lights.lights[4].kind = .Sun
	l = viewport_lights(&app)
	testing.expectf(t, abs(l.shape[4].w - math.sin(math.to_radians(f32(10)))) < 1e-6, "back to a sun %v", l.shape[4].w)
}

// The picked point light's or spot's handles move it as the Move tool's do: along an arm
// it moves on that axis alone, by as much as the arm's world length the pointer covered;
// across a plane square it keeps the held axis exactly; a spot stays aimed where it was.
@(test)
light_gizmo_moves_along_an_axis_or_across_a_plane :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	app.camera.yaw, app.camera.pitch = 0.5, -0.35
	lights_reset(&app)
	set := &app.scene.lights
	set.lights[2] = {on = true, kind = .Spot, space = .Scene, dir = {0, 1, 0}, pos = {0.5, 0.6, 0.3}, ref = 2, strength = 1, color = 1, cone = 45}
	size := [2]f32{1600, 900}
	aim := light_world_pos(&app, set.lights[2]) - light_world_dir(&app, 2) * linalg.length(set.lights[2].pos - app.camera.target)

	sc := light_gizmo(&app, 2, size)
	testing.expect(t, sc.ok && gizmo.arm_shows(sc, 0))
	testing.expect(t, !light_gizmo(&app, 0, size).ok) // a sun has none
	p: Light_Press
	from := (sc.center + sc.tips[0]) * 0.5
	testing.expect(t, light_gizmo_begin(&app, &p, 2, .X, from, size))
	start := set.lights[2].pos
	light_gizmo_drag(&app, &p, 2, from + (sc.tips[0] - sc.center) * 0.5, size)
	moved := set.lights[2].pos - start
	arm := gizmo.ARM_PX * camera.orbit_world_per_px(app.camera, start, size.y)
	testing.expectf(t, moved.y == 0 && moved.z == 0 && abs(moved.x - 0.5 * arm) < 0.05 * arm, "along x by %v, the arm %v", moved, arm)
	testing.expectf(t, near(light_world_dir(&app, 2), linalg.normalize(set.lights[2].pos - aim), 1e-5), "the spot points %v", light_world_dir(&app, 2))

	// Across the plane square that holds y still.
	sc = light_gizmo(&app, 2, size)
	q, ok := gizmo.square_of(sc, 1)
	testing.expect(t, ok)
	inside := (q[0] + q[2]) * 0.5
	p = {}
	testing.expect(t, light_gizmo_begin(&app, &p, 2, .XZ, inside, size))
	start = set.lights[2].pos
	light_gizmo_drag(&app, &p, 2, inside + {40, 25}, size)
	moved = set.lights[2].pos - start
	testing.expectf(t, moved.y == 0 && abs(moved.x) + abs(moved.z) > 0.01, "across xz by %v", moved)
}
