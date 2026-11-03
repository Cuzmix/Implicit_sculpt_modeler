package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// The vector skin (Skin.side): sideways offsets in each sample's owner frame.

// Heights and sideways offsets that differ from sample to sample and repeat run to run.
@(private = "file")
side_bumpy :: proc(sk: ^Skin, allocator := context.allocator) {
	skin_side_fit(sk, allocator)
	x := u32(777)
	next :: proc(x: ^u32) -> f16 {
		x^ = x^ * 1664525 + 1013904223
		return f16((f32(x^ >> 8) / f32(1 << 24) - 0.5) * 0.02)
	}
	for &h in sk.heights do h = next(&x)
	for &sd in sk.side do sd = {next(&x), next(&x)}
	for h, i in sk.heights do sk.height_max = max(sk.height_max, abs(f32(h)) + abs(f32(sk.side[i].x)) + abs(f32(sk.side[i].y)))
}

// A vector page of zeros changes no normal, to the bit.
@(test)
skin_side_of_zeros_changes_nothing :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 8)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	for &h, i in sk.heights do h = f16(f32(i % 7) * 0.001)
	skin_normals_all(&sp.sculptor, &sk)
	want := slice.clone(sk.normals, context.temp_allocator)
	skin_side_fit(&sk, context.allocator)
	skin_normals_all(&sp.sculptor, &sk)
	testing.expect(t, slice.equal(sk.normals, want), "an empty vector page turned normals")
}

// Every triangle a sample lies on reaches the same point, sideways offsets and all, so
// the vector skin has no cracks; and the offsets turn the normals.
@(test)
skin_side_is_watertight_and_turns_normals :: proc(t: ^testing.T) {
	sp := skin_sphere_make(2)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 8)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	for &h, i in sk.heights do h = f16(f32(i % 7) * 0.001)
	skin_normals_all(&sp.sculptor, &sk)
	heights_only := slice.clone(sk.normals, context.temp_allocator)
	side_bumpy(&sk)
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
	testing.expect_value(t, mismatches, 0)
	skin_normals_all(&sp.sculptor, &sk)
	turned := 0
	for nn, i in sk.normals do if nn != heights_only[i] do turned += 1
	testing.expectf(t, turned > n / 2, "sideways offsets turned only %d of %d normals", turned, n)
}

// The grid pass gives each normal as skin_normal does, with sideways offsets too.
@(test)
skin_side_grid_pass_matches_each_normal :: proc(t: ^testing.T) {
	sp := skin_sphere_make(1)
	defer skin_sphere_free(sp)
	sk, ok := skin_make(&sp.sculptor, 8)
	testing.expect(t, ok)
	defer skin_destroy(&sk)
	side_bumpy(&sk)
	skin_normals_all(&sp.sculptor, &sk)
	I := sp.mesh.indices[:]
	S := sk.segments
	wrong := 0
	for tri in u32(0) ..< sk.tri_count do for j in u32(1) ..= S - 2 do for i in u32(1) ..= S - 1 - j {
		if sk.normals[skin_sample(&sk, I, tri, i, j)] != geom.oct_encode(skin_normal(&sp.sculptor, &sk, tri, i, j)) do wrong += 1
	}
	testing.expect_value(t, wrong, 0)
}

// A stroke that gave the skin its vector page undoes to no offsets and redoes to them.
@(test)
skin_side_undoes_with_its_stroke :: proc(t: ^testing.T) {
	sp := skin_sphere_with(2, 4)
	defer skin_sphere_free(sp)
	s := &sp.sculptor
	sculptor_stroke_begin(s)
	clear(&s.hit)
	for n in s.nodes do if n.leaf != geom.BVH_NONE do append(&s.hit, n.leaf)
	record_skin_hit(s)
	side_bumpy(s.skin, s.history.allocator)
	want := slice.clone(s.skin.side, context.temp_allocator)
	s.history.current.skinned = true
	testing.expect(t, sculptor_stroke_end(s), "the stroke was not recorded")
	testing.expect(t, sculptor_undo(s))
	for sd in s.skin.side do if sd != {} {
		testing.fail_now(t, "undo left an offset")
	}
	testing.expect(t, sculptor_redo(s))
	testing.expect(t, slice.equal(s.skin.side, want), "redo lost the offsets")
}

// The vector page goes into the scene file and comes back on a fresh build, each sample's
// point where it was to f16's rounding, whatever numbers the build gives.
@(test)
skin_side_file_round_trip_keeps_every_point :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	l: Levels
	levels_init(&l, geom.icosphere(1), &pool, 64)
	defer levels_destroy(&l)
	testing.expect(t, levels_subdivide(&l))
	top := &l.levels[1].sculptor
	testing.expect(t, sculptor_skin_set(top, 4))
	side_bumpy(top.skin, top.history.allocator)
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, levels_write(&l, &out))
	testing.expect(t, levels_skin_write(&l, &out))
	want := side_points(top)

	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, &pool, 64), "levels read failed")
	defer levels_destroy(&back)
	testing.expect(t, levels_skin_read(&back, &r), "skin read failed")
	testing.expect_value(t, r.at, len(out))
	if levels_skin(&back) == nil do return
	got := side_points(&back.levels[1].sculptor)
	testing.expect_value(t, len(got), len(want))
	if len(got) != len(want) do return
	worst: f32
	for p, i in got do worst = max(worst, linalg.length(p - want[i]))
	testing.expectf(t, worst < 2e-4, "a point moved %v", worst)
}

// Every sample's point on the skin, sorted by its flat point rounded, so two builds
// numbered apart compare.
@(private = "file")
side_points :: proc(s: ^Sculptor) -> []Vec3 {
	Placed :: struct {
		key:   [3]i32,
		point: Vec3,
	}
	sk := s.skin
	I := s.mesh.indices[:]
	S := sk.segments
	placed := make([]Placed, len(sk.heights), context.temp_allocator)
	for t in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		flat, point := skin_base_and_point(s, sk, t, i, j)
		placed[skin_sample(sk, I, t, i, j)] = {{i32(flat.x * 1e5), i32(flat.y * 1e5), i32(flat.z * 1e5)}, point}
	}
	slice.sort_by(placed, proc(a, b: Placed) -> bool {
		return a.key.x < b.key.x || (a.key.x == b.key.x && (a.key.y < b.key.y || (a.key.y == b.key.y && a.key.z < b.key.z)))
	})
	out := make([]Vec3, len(placed), context.temp_allocator)
	for p, i in placed do out[i] = p.point
	return out
}
