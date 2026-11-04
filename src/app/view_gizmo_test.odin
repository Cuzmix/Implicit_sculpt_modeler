package main

import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "../camera"
import "../geom"
import "../ui"

@(private = "file")
GIZMO_RECT :: ui.Rect{100, 100, VIEW_GIZMO_SIZE, VIEW_GIZMO_SIZE}

// The basis of a view looking from direction `from`.
@(private = "file")
basis_from :: proc(from: geom.Vec3) -> (right, up, back: geom.Vec3) {
	c := camera.orbit_default()
	camera.orbit_look_from(&c, from)
	return camera.orbit_basis(c)
}

// A tap on a ball looks from its side; on the ball already facing the eye, from the other
// side, as Blender's gizmo flips; between the balls, nothing.
@(test)
axes_balls_look_from_their_side :: proc(t: ^testing.T) {
	right, up, back := basis_from({0, 0, 1})
	balls := gizmo_balls(GIZMO_RECT, right, up, back)
	at :: proc(balls: [6]Gizmo_Ball, axis: int, minus: bool) -> [2]f32 {
		for b in balls do if b.axis == axis && b.minus == minus do return b.at
		return {}
	}
	// From the front, +X is to the right of the middle and +Y above it.
	mid := [2]f32{GIZMO_RECT.x + GIZMO_RECT.w * 0.5, GIZMO_RECT.y + GIZMO_RECT.h * 0.5}
	testing.expect(t, at(balls, 0, false).x > mid.x + 20 && at(balls, 1, false).y < mid.y - 20)
	from, ok := gizmo_axes_pick(GIZMO_RECT, right, up, back, at(balls, 0, false))
	testing.expect(t, ok && from == {1, 0, 0}, "the X ball looks from the right")
	from, ok = gizmo_axes_pick(GIZMO_RECT, right, up, back, at(balls, 1, true))
	testing.expect(t, ok && from == {0, -1, 0}, "the minus Y ball looks from below")
	// +Z faces the eye from the front (drawn last, over -Z in the middle): it flips to the back.
	from, ok = gizmo_axes_pick(GIZMO_RECT, right, up, back, mid)
	testing.expect(t, ok && from == {0, 0, -1}, "the facing ball flips the view")
	_, ok = gizmo_axes_pick(GIZMO_RECT, right, up, back, mid + {12, 12})
	testing.expect(t, !ok, "a tap between the balls looks from nowhere")
	// Back to front.
	for i in 1 ..< 6 do testing.expect(t, balls[i - 1].depth <= balls[i].depth)
}

// Seen from a corner, the cube shows three faces; the middle of the picture is that
// corner, an edge's middle looks from that edge, a face's middle from that face.
@(test)
cube_taps_take_faces_edges_and_corners :: proc(t: ^testing.T) {
	right, up, back := basis_from({1, 1, 1})
	faces, count := gizmo_cube_faces(GIZMO_RECT, right, up, back)
	testing.expect_value(t, count, 3)
	mid := [2]f32{GIZMO_RECT.x + GIZMO_RECT.w * 0.5, GIZMO_RECT.y + GIZMO_RECT.h * 0.5}
	_, zone, from, ok := gizmo_cube_pick(GIZMO_RECT, right, up, back, mid)
	testing.expect(t, ok && from == {1, 1, 1}, "the near corner looks from the corner")
	testing.expect(t, abs(zone.x) == 1 && abs(zone.y) == 1)
	for f in faces[:count] {
		face, z, there, on := gizmo_cube_pick(GIZMO_RECT, right, up, back, f.middle)
		testing.expect(t, on && face == f.face && z == {0, 0} && there == CUBE_FACES[f.face].normal, "a face's middle looks from the face")
		// The middle of the face's edge along its right.
		face, z, there, on = gizmo_cube_pick(GIZMO_RECT, right, up, back, f.middle + 0.85 * f.u)
		want := CUBE_FACES[f.face].normal + CUBE_FACES[f.face].u
		testing.expect(t, on && face == f.face && z == {1, 0} && there == want, "an edge looks from between its two faces")
	}
	// Straight from the front only the front shows, and outside the cube nothing is taken.
	right, up, back = basis_from({0, 0, 1})
	_, count = gizmo_cube_faces(GIZMO_RECT, right, up, back)
	testing.expect_value(t, count, 1)
	_, _, _, ok = gizmo_cube_pick(GIZMO_RECT, right, up, back, {GIZMO_RECT.x + 2, GIZMO_RECT.y + 2})
	testing.expect(t, !ok)
}

// The person's own model comes back from its file as it went in, sized to a unit round
// its middle; a damaged or foreign file is refused.
@(test)
view_model_keeps_and_refuses :: proc(t: ^testing.T) {
	m := geom.icosphere(1, 1)
	defer geom.mesh_destroy(&m)
	for &p in m.positions do p = p * 3 + {5, 0, 0}
	testing.expect(t, view_model_fit(&m, linalg.MATRIX3F32_IDENTITY))
	far: f32 = 0
	for p in m.positions do far = max(far, linalg.length(p))
	testing.expect(t, abs(far - 1) < 1e-4, "fitted to a unit")

	dir := os.get_working_directory(context.temp_allocator) or_else "."
	path, _ := filepath.join({dir, "view_model_test.bin"}, context.temp_allocator)
	defer _ = os.remove(path)
	testing.expect(t, view_model_save(m, "Figure", path))
	back, name, ok := view_model_load(path)
	defer geom.mesh_destroy(&back)
	defer delete(name)
	testing.expect(t, ok && name == "Figure")
	testing.expect_value(t, len(back.positions), len(m.positions))
	testing.expect_value(t, len(back.indices), len(m.indices))
	testing.expect_value(t, len(back.normals), len(m.positions))
	for p, i in m.positions do testing.expect(t, back.positions[i] == p)

	// One byte short, and an index past the vertices.
	data, _ := os.read_entire_file(path, context.temp_allocator)
	_ = os.write_entire_file(path, data[:len(data) - 1])
	_, _, ok = view_model_load(path)
	testing.expect(t, !ok, "a cut file is refused")
	data[len(data) - 2] = 0xff
	_ = os.write_entire_file(path, data)
	_, _, ok = view_model_load(path)
	testing.expect(t, !ok, "an index past the vertices is refused")
	_, _, ok = view_model_load("")
	testing.expect(t, !ok)
}
