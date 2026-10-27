package geom

import "core:math"
import "core:slice"
import "core:testing"

import "../jobs"

@(private = "file")
expect_same_mesh :: proc(t: ^testing.T, a, b: Mesh, loc := #caller_location) {
	testing.expect_value(t, len(b.positions), len(a.positions), loc = loc)
	testing.expect_value(t, len(b.indices), len(a.indices), loc = loc)
	if len(a.positions) != len(b.positions) || len(a.indices) != len(b.indices) do return
	testing.expect(t, slice.equal(slice.to_bytes(a.positions[:]), slice.to_bytes(b.positions[:])), "positions differ in some bit", loc = loc)
	testing.expect(t, slice.equal(a.indices[:], b.indices[:]), "indices differ", loc = loc)
	testing.expect_value(t, len(b.normals), len(b.positions), loc = loc)
}

@(private = "file")
text_bytes :: proc(s: string) -> []u8 {return transmute([]u8)s}

@(test)
obj_and_ply_round_trips_are_exact :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(4)
	defer mesh_destroy(&sphere)
	// Values format_f32 writes in each of its forms.
	sphere.positions[0] = {1e-7, -3.4e38, 123456789}
	sphere.positions[1] = {-0.0, 1.5e-45, 0.000012345}

	obj := make([dynamic]u8)
	defer delete(obj)
	mesh_write_obj(&obj, sphere.positions[:], sphere.indices[:], pool = &pool)
	from_obj, err, line := mesh_read_obj(obj[:], &pool, chunk_bytes = 4096)
	defer mesh_destroy(&from_obj)
	testing.expectf(t, err == .None, "%v at line %d", err, line)
	expect_same_mesh(t, sphere, from_obj)

	ply := make([dynamic]u8)
	defer delete(ply)
	mesh_write_ply(&ply, sphere.positions[:], sphere.indices[:], pool = &pool)
	from_ply, ply_err, _ := mesh_read_ply(ply[:], &pool)
	defer mesh_destroy(&from_ply)
	testing.expect_value(t, ply_err, Mesh_File_Error.None)
	expect_same_mesh(t, sphere, from_ply)

	// Written as file coordinates: 2p + (1, 0, 0).
	moved := make([dynamic]u8)
	defer delete(moved)
	mesh_write_ply(&moved, sphere.positions[:], sphere.indices[:], 2, {1, 0, 0})
	scaled, _, _ := mesh_read_ply(moved[:], nil)
	defer mesh_destroy(&scaled)
	testing.expect_value(t, scaled.positions[5], sphere.positions[5] * 2 + {1, 0, 0})
}

@(test)
format_f32_reads_back_exactly :: proc(t: ^testing.T) {
	buf: [32]u8
	bits: u32 = 1
	bad := 0
	// A spread of bit patterns over every exponent, finite ones only.
	for _ in 0 ..< 200_000 {
		bits = bits * 1664525 + 1013904223
		x := transmute(f32)bits
		if math.is_nan(x) || math.is_inf(x) do continue
		n := format_f32(buf[:], x)
		at := 0
		y, ok := parse_float(buf[:n], &at)
		if !ok || at != n || transmute(u32)y != transmute(u32)x {
			if bad < 5 do testing.expectf(t, false, "%v (%x) wrote %s and read back %v", x, bits, string(buf[:n]), y)
			bad += 1
		}
	}
	testing.expect_value(t, bad, 0)
	for c in ([?]struct {
		x:    f32,
		text: string,
	}{{0, "0"}, {1, "1"}, {-2.5, "-2.5"}, {100, "100"}, {0.1, "0.100000001"}, {1e9, "1e9"}, {1e-6, "9.99999997e-7"}, {0.0001, "0.0000999999975"}}) {
		n := format_f32(buf[:], c.x)
		testing.expect_value(t, string(buf[:n]), c.text)
	}
}

@(test)
obj_reads_polygons_negative_indices_and_corner_forms :: proc(t: ^testing.T) {
	text := "# a comment\r\n" +
		"mtllib x.mtl\r\n" +
		"o quad\r\n" +
		"v 0 0 0\r\n" +
		"v 1 0 0 1.0\r\n" + // a w coordinate, ignored
		"vt 0 0\r\n" +
		"vn 0 0 1\r\n" +
		"v 1 1 0\r\n" +
		"\tv  0 1 0 # trailing comment\r\n" +
		"f 1/1/1 2/1/1 3/1/1 4/1/1\r\n" + // a quad: two triangles
		"f -4//1 -3//1 -2//1\r\n" +
		"s off\r\n" +
		"f 1 3 4"
	for chunk in ([?]int{OBJ_CHUNK, 16}) {
		m, err, line := mesh_read_obj(text_bytes(text), nil, chunk_bytes = chunk)
		defer mesh_destroy(&m)
		testing.expectf(t, err == .None, "%v at line %d", err, line)
		testing.expect_value(t, len(m.positions), 4)
		testing.expect(t, slice.equal(m.indices[:], []u32{0, 1, 2, 0, 2, 3, 0, 1, 2, 0, 2, 3}), "indices")
		testing.expect_value(t, m.positions[3], Vec3{0, 1, 0})
	}
}

@(test)
obj_errors_name_the_line :: proc(t: ^testing.T) {
	cases := [?]struct {
		text: string,
		err:  Mesh_File_Error,
		line: int,
	} {
		{"v 0 0 0\nv 1 0\nv 0 1 0\nf 1 2 3\n", .Bad_Number, 2},
		{"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 x\n", .Bad_Number, 4},
		{"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 0 1 2\n", .Bad_Index, 4},
		{"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 4\n", .Bad_Index, 0},
		{"v 0 0 0\nv 1 0 0\nv 0 1 0\nf -1 -2 -4\n", .Bad_Index, 0},
		{"v 0 0 0\nv 1 0 0\nv 0 1 0\n", .Empty, 0},
		{"v 0 0 0\nv 1e5000 0 0\nv 0 1 0\nf 1 2 3\n", .None, 0}, // infinite: mesh_clean refuses it
	}
	for c in cases {
		for chunk in ([?]int{OBJ_CHUNK, 8}) {
			m, err, line := mesh_read_obj(text_bytes(c.text), nil, chunk_bytes = chunk)
			defer mesh_destroy(&m)
			testing.expectf(t, err == c.err && line == c.line, "%q: %v at line %d, wanted %v at line %d", c.text, err, line, c.err, c.line)
			if err == .None {
				_, clean_err := mesh_clean(&m, nil)
				testing.expect_value(t, clean_err, Mesh_File_Error.Not_Finite)
			}
		}
	}
}

@(test)
obj_chunks_and_threads_give_the_same_mesh :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := geodesic_sphere(30, &pool)
	defer mesh_destroy(&sphere)
	obj := make([dynamic]u8)
	defer delete(obj)
	mesh_write_obj(&obj, sphere.positions[:], sphere.indices[:])
	// The same faces again with negative indices, which then reach back across chunks.
	for tri := 0; tri < len(sphere.indices); tri += 3 {
		append(&obj, 'f')
		for c in 0 ..< 3 {
			buf: [16]u8
			append(&obj, ' ', '-')
			append(&obj, ..buf[:format_u32(buf[:], u32(len(sphere.positions)) - sphere.indices[tri + c])])
		}
		append(&obj, '\n')
	}
	whole, _, _ := mesh_read_obj(obj[:], nil)
	defer mesh_destroy(&whole)
	testing.expect_value(t, len(whole.indices), 2 * len(sphere.indices))
	testing.expect(t, slice.equal(whole.indices[:len(sphere.indices)], whole.indices[len(sphere.indices):]), "negative indices differ from positive ones")
	for chunk in ([?]int{1000, 77_777}) {
		serial, _, _ := mesh_read_obj(obj[:], nil, chunk_bytes = chunk)
		defer mesh_destroy(&serial)
		parallel, _, _ := mesh_read_obj(obj[:], &pool, chunk_bytes = chunk)
		defer mesh_destroy(&parallel)
		expect_same_mesh(t, whole, serial)
		expect_same_mesh(t, whole, parallel)
	}
}

@(test)
ply_reads_text_big_endian_and_other_properties :: proc(t: ^testing.T) {
	ascii := "ply\r\nformat ascii 1.0\r\ncomment made by hand\r\nelement vertex 4\r\nproperty float x\r\nproperty float y\r\n" +
		"property double z\r\nproperty uchar red\r\nelement face 2\r\nproperty uchar flags\r\nproperty list uchar int vertex_indices\r\n" +
		"element edge 1\r\nproperty int vertex1\r\nproperty int vertex2\r\nend_header\r\n" +
		"0 0 0 255\r\n1 0 0 255\r\n1 1 0.5 255\r\n0 1 0 255\r\n" +
		"7 4 0 1 2 3\r\n0 3 0 2 3\r\n0 1\r\n"
	m, err, line := mesh_read_ply(text_bytes(ascii), nil)
	defer mesh_destroy(&m)
	testing.expectf(t, err == .None, "%v at line %d", err, line)
	testing.expect(t, slice.equal(m.indices[:], []u32{0, 1, 2, 0, 2, 3, 0, 2, 3}), "indices")
	testing.expect_value(t, m.positions[2], Vec3{1, 1, 0.5})

	// The same in big-endian binary, with short corners and a vertex_index list.
	head := "ply\nformat binary_big_endian 1.0\nelement vertex 4\nproperty float x\nproperty float y\nproperty float z\n" +
		"element face 2\nproperty list uchar ushort vertex_index\nend_header\n"
	big := make([dynamic]u8)
	defer delete(big)
	append(&big, head)
	for p in m.positions {
		for x in p {
			b := transmute([4]u8)x
			append(&big, b[3], b[2], b[1], b[0])
		}
	}
	append(&big, 4, 0, 0, 0, 1, 0, 2, 0, 3)
	append(&big, 3, 0, 0, 0, 2, 0, 3)
	b, big_err, _ := mesh_read_ply(big[:], nil)
	defer mesh_destroy(&b)
	testing.expect_value(t, big_err, Mesh_File_Error.None)
	testing.expect(t, slice.equal(b.indices[:], m.indices[:]), "big-endian indices")
	testing.expect(t, slice.equal(b.positions[:], m.positions[:]), "big-endian positions")

	_, short_err, _ := mesh_read_ply(big[:len(big) - 1], nil)
	testing.expect_value(t, short_err, Mesh_File_Error.Truncated)
	_, no_ply, _ := mesh_read_ply(text_bytes("v 0 0 0\n"), nil)
	testing.expect_value(t, no_ply, Mesh_File_Error.Not_Recognised)
	_, no_z, _ := mesh_read_ply(text_bytes("ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty float y\nend_header\n0 0\n"), nil)
	testing.expect_value(t, no_z, Mesh_File_Error.Bad_Header)
}

@(test)
ply_binary_polygons_fall_back_from_the_fast_path :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := geodesic_sphere(40, &pool)
	defer mesh_destroy(&sphere)
	ply := make([dynamic]u8)
	defer delete(ply)
	mesh_write_ply(&ply, sphere.positions[:], sphere.indices[:])
	// A quad after the triangles, more than one range of them, so the parallel read
	// finds a face that is not a triangle and the serial one reads the file instead.
	append(&ply, 4, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0)
	n := len(sphere.indices) / 3
	m, err, _ := mesh_read_ply(fix_face_count(ply[:], n, n + 1), &pool)
	defer mesh_destroy(&m)
	testing.expect_value(t, err, Mesh_File_Error.None)
	testing.expect_value(t, len(m.indices), len(sphere.indices) + 6)
	testing.expect(t, slice.equal(m.indices[:len(sphere.indices)], sphere.indices[:]), "triangles before the quad")
	testing.expect(t, slice.equal(m.indices[len(sphere.indices):], []u32{0, 1, 2, 0, 2, 3}), "the quad")
}

// The PLY with its face count `from` replaced by `to`, from the temp allocator.
@(private = "file")
fix_face_count :: proc(ply: []u8, from, to: int) -> []u8 {
	buf: [16]u8
	old := string(buf[:format_u32(buf[:], u32(from))])
	key := "element face "
	text := string(ply)
	at := 0
	for i in 0 ..< len(text) - len(key) {
		if text[i:][:len(key)] == key {
			at = i + len(key)
			break
		}
	}
	out := make([dynamic]u8, 0, len(ply) + 4, context.temp_allocator)
	append(&out, ..ply[:at])
	nbuf: [16]u8
	append(&out, ..nbuf[:format_u32(nbuf[:], u32(to))])
	append(&out, ..ply[at + len(old):])
	return out[:]
}

@(test)
clean_welds_a_triangle_soup_into_a_closed_mesh :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(3)
	defer mesh_destroy(&sphere)
	// Each triangle with its own three vertices, as STL-like exporters write, plus a
	// triangle with a repeated corner and a vertex no triangle uses.
	results: [2]Mesh
	for &soup, run in results {
		for i in sphere.indices {
			append(&soup.positions, sphere.positions[i])
			append(&soup.indices, u32(len(soup.indices)))
		}
		append(&soup.positions, Vec3{5, 5, 5})
		append(&soup.indices, 0, 0, 1)
		resize(&soup.normals, len(soup.positions))
		report, err := mesh_clean(&soup, &pool if run == 1 else nil)
		testing.expect_value(t, err, Mesh_File_Error.None)
		testing.expect_value(t, report.welded, len(sphere.indices) - len(sphere.positions))
		testing.expect_value(t, report.dropped_triangles, 1)
		testing.expect_value(t, report.dropped_vertices, len(sphere.indices) + 1 - len(sphere.positions))
		r := mesh_check(soup)
		testing.expectf(t, mesh_report_ok(r) && r.vertices == len(sphere.positions), "%v", r)
		testing.expect_value(t, len(soup.normals), len(soup.positions))
	}
	defer for &m in results do mesh_destroy(&m)
	expect_same_mesh(t, results[0], results[1])
	testing.expect(t, abs(mesh_check(results[0]).volume - mesh_check(sphere).volume) < 1e-9, "volume changed")
}

@(test)
edges_count_borders_flips_and_volume_like_mesh_check :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	m := icosphere(3)
	defer mesh_destroy(&m)
	e := mesh_edges(m, &pool)
	testing.expectf(t, mesh_edges_closed(e) && abs(e.volume - mesh_check(m).volume) < 1e-9, "%v", e)
	mesh_flip(&m, &pool)
	flipped := mesh_edges(m, nil)
	testing.expectf(t, mesh_edges_closed(flipped) && abs(flipped.volume + e.volume) < 1e-9, "%v", flipped)
	// One triangle turned back: its three edges are each run twice one way.
	m.indices[1], m.indices[2] = m.indices[2], m.indices[1]
	testing.expect(t, mesh_edges(m, &pool).bad > 0)
	m.indices[1], m.indices[2] = m.indices[2], m.indices[1]
	// One triangle gone: a hole of three border edges.
	remove_range(&m.indices, 0, 3)
	testing.expect_value(t, mesh_edges(m, &pool).border, 3)
}

// Far from the origin on x, the centre is the middle of the bounds; on y and z the
// origin is well inside them and stays the centre.
@(test)
normalize_centres_and_sizes_to_one :: proc(t: ^testing.T) {
	m := icosphere(2)
	defer mesh_destroy(&m)
	for &p in m.positions do p = p * 250 + {1000, -20, 3}
	center, radius := mesh_normalize(&m, nil)
	far: f32
	box := AABB_EMPTY
	for p in m.positions {
		far = max(far, length_of(p))
		aabb_grow(&box, p)
	}
	testing.expectf(t, abs(far - 1) < 1e-6, "farthest vertex %v", far)
	testing.expectf(t, abs(center.x - 1000) < 1e-3 && center.y == 0 && center.z == 0, "center %v", center)
	testing.expectf(t, abs(radius - (250 + length_of({0, 20, 3}))) < 0.5, "radius %v", radius)
	testing.expectf(t, abs(box.lo.x + box.hi.x) < 1e-6, "bounds %v", box)
}

@(private = "file")
length_of :: proc(p: Vec3) -> f32 {return math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)}

@(test)
byte_reader_stops_at_the_end :: proc(t: ^testing.T) {
	out := make([dynamic]u8)
	defer delete(out)
	byte_put(&out, u32(7))
	byte_put_string(&out, "name")
	byte_put_slice(&out, []Vec3{{1, 2, 3}})
	r := byte_reader(out[:])
	testing.expect_value(t, byte_get(&r, u32), 7)
	name := byte_get_string(&r, context.temp_allocator)
	testing.expect_value(t, name, "name")
	v: [1]Vec3
	byte_get_slice(&r, v[:])
	testing.expect(t, r.ok && v[0] == {1, 2, 3} && r.at == len(out), "read back")
	testing.expect_value(t, byte_get(&r, u8), 0)
	testing.expect(t, !r.ok, "a read past the end")
}

// Binary STL keeps every corner's bits; welded by mesh_clean, the triangles come back
// as the sphere they were. A text file reads its loops, a four-corner one as two
// triangles, and a binary file whose header starts with "solid" still reads as binary.
@(test)
stl_round_trips_and_reads_text :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(3)
	defer mesh_destroy(&sphere)
	sphere.positions[1] = {-0.0, 1.5e-45, 3.4e38}

	stl := make([dynamic]u8)
	defer delete(stl)
	mesh_write_stl(&stl, sphere.positions[:], sphere.indices[:], pool = &pool)
	testing.expect_value(t, len(stl), STL_HEADER + STL_ROW * len(sphere.indices) / 3)
	read, err, _ := mesh_read_stl(stl[:], &pool)
	defer mesh_destroy(&read)
	testing.expect_value(t, err, Mesh_File_Error.None)
	testing.expect_value(t, len(read.positions), len(sphere.indices))
	for c, i in sphere.indices {
		if transmute([3]u32)read.positions[i] != transmute([3]u32)sphere.positions[c] {
			testing.expectf(t, false, "corner %d moved", i)
			break
		}
	}
	report, clean_err := mesh_clean(&read, &pool)
	testing.expect_value(t, clean_err, Mesh_File_Error.None)
	testing.expect_value(t, len(read.positions), len(sphere.positions))
	testing.expect_value(t, report.welded, len(sphere.indices) - len(sphere.positions))

	// The same bytes with a header that looks like text, as some writers make it.
	copy(stl[:], "solid exported")
	as_binary, binary_err, _ := mesh_read_stl(stl[:], &pool)
	defer mesh_destroy(&as_binary)
	testing.expect_value(t, binary_err, Mesh_File_Error.None)
	testing.expect_value(t, len(as_binary.indices), len(sphere.indices))
	_, short, _ := mesh_read_stl(stl[:len(stl) - 7], &pool)
	testing.expect_value(t, short, Mesh_File_Error.Truncated)

	text := `solid square
  facet normal 0 0 1
    outer loop
      vertex 0 0 0
      vertex 1 0 0
      vertex 1 1 0
      vertex 0 1 0
    endloop
  endfacet
  facet normal 0 0 -1
    outer loop
      vertex 0 0 0
      vertex 1 1 -1e0
      vertex 1 0 0
    endloop
  endfacet
endsolid square
`
	square, text_err, _ := mesh_read_stl(text_bytes(text), &pool)
	defer mesh_destroy(&square)
	testing.expect_value(t, text_err, Mesh_File_Error.None)
	testing.expect_value(t, len(square.positions), 7)
	testing.expect(t, slice.equal(square.indices[:], []u32{0, 1, 2, 0, 2, 3, 4, 5, 6}))
	testing.expect_value(t, square.positions[5], Vec3{1, 1, -1})

	_, bad, line := mesh_read_stl(text_bytes("solid x\n facet normal 0 0 1\n  outer loop\n   vertex 0 0 zero\n"), &pool)
	testing.expect_value(t, bad, Mesh_File_Error.Bad_Number)
	testing.expect_value(t, line, 4)
	_, empty, _ := mesh_read_stl(text_bytes("solid x\nendsolid x\n"), &pool)
	testing.expect_value(t, empty, Mesh_File_Error.Empty)
	_, other, _ := mesh_read_stl(text_bytes("not a mesh"), &pool)
	testing.expect_value(t, other, Mesh_File_Error.Not_Recognised)
	free_all(context.temp_allocator)
}
