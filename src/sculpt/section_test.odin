package sculpt

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

// A sculptor over `mesh`, its nodes' boxes current, as the app's are after a flush.
@(private = "file")
section_sculptor :: proc(s: ^Sculptor, mesh: ^geom.Mesh) {
	sculptor_init(s, mesh, nil, 64)
	for id in 0 ..< len(s.nodes) do mark_stale(s, u32(id), .Shape)
	_ = sculptor_flush(s)
}

// The length of a section's polyline, round the loop when closed.
@(private = "file")
section_length :: proc(sec: Section, line: Section_Line) -> f32 {
	points := sec.points[line.first:][:line.count]
	total: f32
	for i in 1 ..< len(points) do total += linalg.length(points[i].at - points[i - 1].at)
	if line.closed do total += linalg.length(points[0].at - points[len(points) - 1].at)
	return total
}

// The plane through a sphere's middle cuts it in one closed loop lying on the plane, about
// the great circle's length, with every point's face normal pointing outward; a plane
// past the sphere cuts nothing.
@(test)
section_of_a_sphere_is_one_closed_loop :: proc(t: ^testing.T) {
	mesh := geom.icosphere(4)
	defer geom.mesh_destroy(&mesh)
	s: Sculptor
	section_sculptor(&s, &mesh)
	defer sculptor_destroy(&s)
	sec: Section
	defer section_destroy(&sec)

	// The icosphere has vertices on x = 0, which count as in front of the plane.
	sculptor_plane_section(&s, {}, {1, 0, 0}, &sec)
	testing.expect_value(t, len(sec.lines), 1)
	if len(sec.lines) != 1 do return
	line := sec.lines[0]
	testing.expect(t, line.closed)
	testing.expect_value(t, int(line.count), len(sec.points))
	for p in sec.points {
		testing.expectf(t, abs(p.at.x) < 1e-6, "point off the plane: %v", p.at)
		testing.expectf(t, linalg.dot(p.normal, p.at) > 0.9 * linalg.length(p.at), "normal not outward: %v at %v", p.normal, p.at)
	}
	length := section_length(sec, line)
	testing.expectf(t, abs(length - 2 * math.PI) < 0.05, "loop length %v", length)

	// Off to the side, the circle is smaller; past the sphere there is none.
	sculptor_plane_section(&s, {0.6, 0, 0}, {1, 0, 0}, &sec)
	testing.expect_value(t, len(sec.lines), 1)
	if len(sec.lines) == 1 {
		length = section_length(sec, sec.lines[0])
		testing.expectf(t, abs(length - 2 * math.PI * 0.8) < 0.05, "loop length %v", length)
	}
	sculptor_plane_section(&s, {1.5, 0, 0}, {1, 0, 0}, &sec)
	testing.expect_value(t, len(sec.lines), 0)
	testing.expect_value(t, len(sec.points), 0)
}

// Across an open sheet the cut is one open polyline from edge to edge, a point on every
// row of edges it crosses, in order along it.
@(test)
section_across_a_sheet_is_one_open_line :: proc(t: ^testing.T) {
	N :: 12
	mesh: geom.Mesh
	defer geom.mesh_destroy(&mesh)
	for y in 0 ..= N do for x in 0 ..= N do append(&mesh.positions, Vec3{f32(x) / N, f32(y) / N, 0})
	for y in 0 ..< N do for x in 0 ..< N {
		a := u32(y * (N + 1) + x)
		b, c, d := a + 1, a + N + 1, a + N + 2
		append(&mesh.indices, a, b, d, a, d, c)
	}
	resize(&mesh.normals, len(mesh.positions))
	s: Sculptor
	section_sculptor(&s, &mesh)
	defer sculptor_destroy(&s)
	sec: Section
	defer section_destroy(&sec)

	sculptor_plane_section(&s, {0.37, 0, 0}, {1, 0, 0}, &sec)
	testing.expect_value(t, len(sec.lines), 1)
	if len(sec.lines) != 1 do return
	line := sec.lines[0]
	testing.expect(t, !line.closed)
	points := sec.points[line.first:][:line.count]
	ends := [2]f32{points[0].at.y, points[len(points) - 1].at.y}
	testing.expectf(t, min(ends[0], ends[1]) < 1e-6 && max(ends[0], ends[1]) > 1 - 1e-6, "ends at %v", ends)
	step: f32 = 1 if ends[1] > ends[0] else -1
	for i in 1 ..< len(points) {
		testing.expectf(t, (points[i].at.y - points[i - 1].at.y) * step > -1e-6, "out of order at %d: %v", i, points[i].at)
		testing.expectf(t, abs(points[i].at.x - 0.37) < 1e-5, "point off the plane: %v", points[i].at)
	}
	length := section_length(sec, line)
	testing.expectf(t, abs(length - 1) < 1e-4, "line length %v", length)
}

// Cut on worker threads, the section is the same as cut on one, point for point.
@(test)
section_is_the_same_serial_and_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	mesh := geom.icosphere(6)
	defer geom.mesh_destroy(&mesh)
	s: Sculptor
	section_sculptor(&s, &mesh)
	defer sculptor_destroy(&s)
	serial, parallel: Section
	defer section_destroy(&serial)
	defer section_destroy(&parallel)
	normal := linalg.normalize(Vec3{1, 0.3, -0.2})
	sculptor_plane_section(&s, {0.1, 0, 0}, normal, &serial)
	s.pool = &pool
	sculptor_plane_section(&s, {0.1, 0, 0}, normal, &parallel)
	s.pool = nil
	testing.expect(t, len(serial.points) > 100)
	testing.expect_value(t, len(parallel.points), len(serial.points))
	testing.expect_value(t, len(parallel.lines), len(serial.lines))
	if len(parallel.points) != len(serial.points) do return
	for p, i in serial.points do if p != parallel.points[i] {
		testing.expectf(t, false, "point %d differs: %v and %v", i, p, parallel.points[i])
		break
	}
}
