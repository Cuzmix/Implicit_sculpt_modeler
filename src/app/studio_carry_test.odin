package main

import "core:testing"

import "../camera"
import "../render"

// What the studio render's samples are of changes with a mesh's contents, its place and
// what of it is hidden, and with the viewport starting over, but not with its material or
// colour, which the composite reads fresh every frame: those keep the samples.
@(test)
studio_scene_key_follows_the_geometry :: proc(t: ^testing.T) {
	mesh := render.Mesh_Buffers{version = 1, index_count = 3}
	hidden := []bool{false, false}
	items := []render.Draw_Item{{mesh = &mesh, model = 1, color = {0.8, 0.7, 0.6, 1}, hidden = hidden}}
	key := render.studio_scene_key(items, 0.06, 0)
	testing.expect_value(t, render.studio_scene_key(items, 0.06, 0), key)

	items[0].color = {1, 0, 0, 1}
	items[0].material = {0.1, 0.5, 20, 0}
	testing.expect_value(t, render.studio_scene_key(items, 0.06, 0), key)

	mesh.version = 2
	testing.expect(t, render.studio_scene_key(items, 0.06, 0) != key, "a stroke kept the samples")
	mesh.version = 1
	items[0].model[3, 0] = 0.5
	testing.expect(t, render.studio_scene_key(items, 0.06, 0) != key, "moving the object kept the samples")
	items[0].model[3, 0] = 0
	hidden[1] = true
	testing.expect(t, render.studio_scene_key(items, 0.06, 0) != key, "hiding a part kept the samples")
	hidden[1] = false
	testing.expect(t, render.studio_scene_key(items, 0.06, 1) != key, "the viewport starting over kept the samples")
	testing.expect(t, render.studio_scene_key(items, 0.1, 0) != key, "a softer light kept the samples")
	testing.expect_value(t, render.studio_scene_key(items, 0.06, 0), key)
}

// Lights fixed to the camera turn with the view, so their shadows are not carried across a
// turn; lights that stand still in the world, as lights fixed to the scene do, keep them.
@(test)
studio_lights_key_follows_the_lights_in_the_world :: proc(t: ^testing.T) {
	a := camera.Orbit{yaw = 0.6, pitch = 0.35, distance = 3.5}
	b := a
	b.yaw += 0.3
	va, vb := camera.orbit_view(a), camera.orbit_view(b)
	center := [3]f32{0, 0, 0}
	camera_fixed := render.lights_default()
	testing.expect_value(t, render.studio_lights_key(camera_fixed, va, center, 0.06), render.studio_lights_key(camera_fixed, va, center, 0.06))
	testing.expect(t, render.studio_lights_key(camera_fixed, va, center, 0.06) != render.studio_lights_key(camera_fixed, vb, center, 0.06), "a camera-fixed light kept its shadows across a turn")
	// The same lights handed over in each view's own space, as the app turns lights fixed to
	// the scene: the same in the world.
	world_a := render.lights_to_world(camera_fixed, va, center, 0.06)
	in_b := camera_fixed
	for i in 0 ..< render.LIGHT_COUNT {
		p := world_a.pos[i]
		if p.w == render.LIGHT_SUN {
			d := vb * [4]f32{p.x, p.y, p.z, 0}
			in_b.pos[i] = {d.x, d.y, d.z, p.w}
		}
	}
	testing.expect_value(t, render.studio_lights_key(in_b, vb, center, 0.06), render.studio_lights_key(camera_fixed, va, center, 0.06))
}
