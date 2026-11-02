package sculpt

import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

// A sculptor over an icosphere with its normals worked out, for the skin's tests; free
// with skin_sphere_free.
@(private = "file")
Skin_Sphere :: struct {
	mesh:     geom.Mesh,
	sculptor: Sculptor,
}

@(private = "file")
skin_sphere_make :: proc(subdiv: int, pool: ^jobs.Pool = nil) -> ^Skin_Sphere {
	sp := new(Skin_Sphere)
	sp.mesh = geom.icosphere(subdiv)
	sculptor_init(&sp.sculptor, &sp.mesh, pool, 64)
	for id in 0 ..< len(sp.sculptor.nodes) do mark_stale(&sp.sculptor, u32(id), .Shape)
	_ = sculptor_flush(&sp.sculptor)
	return sp
}

@(private = "file")
skin_sphere_free :: proc(sp: ^Skin_Sphere) {
	sculptor_destroy(&sp.sculptor)
	geom.mesh_destroy(&sp.mesh)
	free(sp)
}

// Heights that differ from sample to sample and repeat run to run.
@(private = "file")
skin_bumpy :: proc(sk: ^Skin) {
	x := u32(12345)
	for &h in sk.heights {
		x = x * 1664525 + 1013904223
		h = f16((f32(x >> 8) / f32(1 << 24) - 0.5) * 0.02)
	}
}

@(test)
skin_refuses_odd_segments_and_open_meshes :: proc(t: ^testing.T) {
	sp := skin_sphere_make(1)
	defer skin_sphere_free(sp)
	for bad in ([]u32{0, 1, 3, 6, 32}) {
		sk, ok := skin_make(&sp.sculptor, bad)
		testing.expectf(t, !ok, "%d segments made a skin", bad)
		skin_destroy(&sk)
	}
	open := geom.icosphere(1)
	resize(&open.indices, len(open.indices) - 3)
	defer geom.mesh_destroy(&open)
	s: Sculptor
	sculptor_init(&s, &open, nil, 64)
	defer sculptor_destroy(&s)
	sk, ok := skin_make(&s, 4)
	testing.expect(t, !ok, "a mesh with a hole made a skin")
	skin_destroy(&sk)
}

@(test)
skin_stores_each_sample_once :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	for segments in ([]u32{2, 4, 8, 16}) {
		sk, ok := skin_make(&sp.sculptor, segments)
		testing.expect(t, ok)
		defer skin_destroy(&sk)
		testing.expect_value(t, int(sk.edge_count), len(sp.mesh.indices) / 2)
		uses := make([]int, skin_sample_count(&sk), context.temp_allocator)
		I := sp.mesh.indices[:]
		S := sk.segments
		for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
			uses[skin_sample(&sk, I, tri, i, j)] += 1
		}
		// A vertex sample is used by each triangle at the vertex, an edge sample by the
		// edge's two triangles, an inside sample by its own triangle only.
		ok_all := true
		for n, x in uses {
			want := 1
			if x < int(sk.vert_count) {
				want = len(faces_of(&sp.sculptor, u32(x)))
			} else if x < int(sk.vert_count + sk.edge_count * (S - 1)) {
				want = 2
			}
			if n != want do ok_all = false
		}
		testing.expectf(t, ok_all, "%d segments: a sample is used the wrong number of times", segments)
	}
}

@(test)
skin_is_watertight :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 8)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	skin_bumpy(&sk)
	n := skin_sample_count(&sk)
	first := make([]Vec3, n, context.temp_allocator)
	seen := make([]bool, n, context.temp_allocator)
	I := sp.mesh.indices[:]
	mismatches := 0
	for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= sk.segments do for i in u32(0) ..= sk.segments - j {
		x := skin_sample(&sk, I, tri, i, j)
		p := skin_point(&sp.sculptor, &sk, tri, i, j)
		if !seen[x] {
			seen[x] = true
			first[x] = p
		} else if p != first[x] {
			mismatches += 1
		}
	}
	// Every triangle must reach a shared sample's point to the bit, or a crack shows.
	testing.expect_value(t, mismatches, 0)
}

@(test)
flat_skin_normals_are_the_mesh_normals :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 4)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	I := sp.mesh.indices[:]
	worst: f32 = 1
	for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= sk.segments do for i in u32(0) ..= sk.segments - j {
		_, want := skin_base(&sp.sculptor, &sk, tri, i, j)
		got := geom.oct_decode(sk.normals[skin_sample(&sk, I, tri, i, j)])
		worst = min(worst, linalg.dot(got, linalg.normalize(want)))
	}
	// Within what two 16-bit octahedral halves hold.
	testing.expectf(t, worst > 0.99999, "worst cosine %v", worst)
}

@(test)
even_skin_keeps_the_mesh_normals :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 8)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	// A skin raised by the same height everywhere is a bigger copy of the surface, so it
	// shades as the mesh does (to within the curve's change over one small triangle).
	for &h in sk.heights do h = 0.05
	skin_normals_all(&sp.sculptor, &sk)
	I := sp.mesh.indices[:]
	worst: f32 = 1
	for tri in u32(0) ..< sk.tri_count do for j in u32(0) ..= sk.segments do for i in u32(0) ..= sk.segments - j {
		_, want := skin_base(&sp.sculptor, &sk, tri, i, j)
		got := geom.oct_decode(sk.normals[skin_sample(&sk, I, tri, i, j)])
		worst = min(worst, linalg.dot(got, linalg.normalize(want)))
	}
	testing.expectf(t, worst > 0.999, "worst cosine %v", worst)
}

@(test)
skin_normals_lean_away_from_a_bump :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 4)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	I := sp.mesh.indices[:]
	v := I[0]
	sk.heights[v] = 0.02
	skin_normals_all(&sp.sculptor, &sk)
	// The samples one step from the raised vertex, on each triangle at it, lean away from it.
	bump := sp.mesh.positions[v]
	checked := 0
	for f in faces_of(&sp.sculptor, v) {
		c := skin_corner_of(I, f, v)
		i, j := skin_edge_place(sk.segments, c, 1)
		p, base := skin_base(&sp.sculptor, &sk, f, i, j)
		got := geom.oct_decode(sk.normals[skin_sample(&sk, I, f, i, j)])
		away := linalg.normalize(p - bump)
		testing.expectf(t, linalg.dot(got, away) > linalg.dot(linalg.normalize(base), away) + 0.01, "triangle %d does not lean away", f)
		checked += 1
	}
	testing.expect(t, checked >= 5)
}

@(test)
skin_normals_match_serial_and_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	serial := skin_sphere_make(3)
	defer skin_sphere_free(serial)
	parallel := skin_sphere_make(3, &pool)
	defer skin_sphere_free(parallel)
	a, ok_a := skin_make(&serial.sculptor, 8)
	b, ok_b := skin_make(&parallel.sculptor, 8)
	testing.expect(t, ok_a && ok_b)
	defer skin_destroy(&a)
	defer skin_destroy(&b)
	skin_bumpy(&a)
	skin_bumpy(&b)
	skin_normals_all(&serial.sculptor, &a)
	skin_normals_all(&parallel.sculptor, &b)
	same := len(a.normals) == len(b.normals)
	for n, x in a.normals do if n != b.normals[x] do same = false
	for e, x in a.edges do if e != b.edges[x] do same = false
	testing.expect(t, same, "the parallel skin differs from the serial one")
}
