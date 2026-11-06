package geom

import "core:testing"

// A cube of twelve triangles split at 30 degrees gives each corner three vertices (one
// per side meeting there), 24 in all, and each face's triangles still share theirs; at
// 100 degrees nothing splits, since every edge turns by 90.
@(test)
split_sharp_gives_a_cube_hard_corners :: proc(t: ^testing.T) {
	cube :: proc() -> Mesh {
		m := Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
		for z in 0 ..< 2 do for y in 0 ..< 2 do for x in 0 ..< 2 do append(&m.positions, Vec3{f32(x), f32(y), f32(z)})
		quads := [6][4]u32{{0, 2, 3, 1}, {4, 5, 7, 6}, {0, 1, 5, 4}, {2, 6, 7, 3}, {0, 4, 6, 2}, {1, 3, 7, 5}}
		for q in quads do append(&m.indices, q[0], q[1], q[2], q[0], q[2], q[3])
		resize(&m.normals, len(m.positions))
		return m
	}
	m := cube()
	defer mesh_destroy(&m)
	from := mesh_split_sharp(&m, 30)
	defer delete(from)
	testing.expect_value(t, len(m.positions), 24)
	testing.expect_value(t, len(from), 16)
	for f, k in from do testing.expect(t, m.positions[8 + k] == m.positions[f])
	used := make([]int, len(m.positions))
	defer delete(used)
	for i in m.indices do used[i] += 1
	for u in used do testing.expect(t, u > 0)
	soft := cube()
	defer mesh_destroy(&soft)
	none := mesh_split_sharp(&soft, 100)
	defer delete(none)
	testing.expect_value(t, len(none), 0)
	testing.expect_value(t, len(soft.positions), 8)
}
