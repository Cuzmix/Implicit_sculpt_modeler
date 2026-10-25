package geom

import "core:math/linalg"
import "core:testing"

@(private = "file")
retopo_sphere :: proc(t: ^testing.T, wanted: int) -> (q: Quad_Mesh, report: Retopo_Report, ok: bool) {
	source := icosphere(5)
	defer mesh_destroy(&source)
	bvh := bvh_build(source)
	defer bvh_destroy(&bvh)
	return mesh_retopo(source, &bvh, wanted, nil)
}

// Retopology of a sphere gives quads only, about as many as asked for, closed, facing
// out, on the sphere.
@(test)
retopo_makes_closed_quads_on_the_surface :: proc(t: ^testing.T) {
	q, report, ok := retopo_sphere(t, 2000)
	defer quad_mesh_destroy(&q)
	testing.expect(t, ok, "retopology failed")
	if !ok do return
	testing.expectf(t, len(q.quads) > 1000 && len(q.quads) < 4000, "%d quads for 2000 asked (%v)", len(q.quads), report)
	testing.expectf(t, report.paired > report.decimated / 2, "only %d of %d triangles paired", report.paired, report.decimated)
	testing.expect_value(t, report.unprojected, 0)
	uses := make(map[u64]int, 4 * len(q.quads), context.temp_allocator)
	for f in q.quads {
		for k in 0 ..< 4 do uses[u64(f[k]) << 32 | u64(f[(k + 1) % 4])] += 1
		n := linalg.cross(q.positions[f[2]] - q.positions[f[0]], q.positions[f[3]] - q.positions[f[1]])
		middle := 0.25 * (q.positions[f[0]] + q.positions[f[1]] + q.positions[f[2]] + q.positions[f[3]])
		testing.expect(t, linalg.dot(n, middle) > 0, "a quad faces in")
	}
	// Closed and consistently wound: each directed edge once, and its reverse once.
	for key, count in uses {
		back := (key & 0xffff_ffff) << 32 | key >> 32
		testing.expect(t, count == 1 && uses[back] == 1, "an edge is open or used twice the same way")
	}
	far: f32
	for p in q.positions do far = max(far, abs(linalg.length(p) - 1))
	testing.expectf(t, far < 0.01, "a vertex is %v off the sphere", far)
	// The same input gives the same quads.
	again, _, _ := retopo_sphere(t, 2000)
	defer quad_mesh_destroy(&again)
	same := len(again.quads) == len(q.quads) && len(again.positions) == len(q.positions)
	if same do for f, i in q.quads do if f != again.quads[i] do same = false
	if same do for p, i in q.positions do if p != again.positions[i] do same = false
	testing.expect(t, same, "two runs differ")
}

// UVs: every corner in the unit square, no triangle folded over, and no texel of a
// 512 square covered twice.
@(test)
uv_unwrap_lays_charts_apart :: proc(t: ^testing.T) {
	q, _, ok := retopo_sphere(t, 1500)
	defer quad_mesh_destroy(&q)
	if !testing.expect(t, ok) do return
	l := quad_uv_unwrap(q, 2.0 / 512)
	defer uv_layout_destroy(&l)
	testing.expectf(t, l.charts > 4 && l.charts < len(q.quads) / 10, "%d charts", l.charts)
	testing.expectf(t, l.filled > 0.35, "charts fill only %v of the square", l.filled)
	SIZE :: 512
	covered := make([]u8, SIZE * SIZE, context.temp_allocator)
	folded, twice := 0, 0
	for corners in l.uvs {
		for c in corners do testing.expect(t, c.x >= 0 && c.y >= 0 && c.x <= 1 && c.y <= 1, "a UV is outside the square")
		for half in ([2][3]int{{0, 1, 2}, {0, 2, 3}}) {
			a, b, c := corners[half[0]], corners[half[1]], corners[half[2]]
			area := (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
			if area <= 0 do folded += 1
		}
		// Each quad marks the texel centres inside it, rasterized as its two triangles.
		lo := linalg.min(linalg.min(corners[0], corners[1]), linalg.min(corners[2], corners[3]))
		hi := linalg.max(linalg.max(corners[0], corners[1]), linalg.max(corners[2], corners[3]))
		for y in int(lo.y * SIZE) ..= min(int(hi.y * SIZE), SIZE - 1) {
			for x in int(lo.x * SIZE) ..= min(int(hi.x * SIZE), SIZE - 1) {
				p := [2]f32{(f32(x) + 0.5) / SIZE, (f32(y) + 0.5) / SIZE}
				inside := false
				for half in ([2][3]int{{0, 1, 2}, {0, 2, 3}}) {
					a, b, c := corners[half[0]], corners[half[1]], corners[half[2]]
					w0 := (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
					w1 := (c.x - b.x) * (p.y - b.y) - (p.x - b.x) * (c.y - b.y)
					w2 := (a.x - c.x) * (p.y - c.y) - (p.x - c.x) * (a.y - c.y)
					if w0 > 0 && w1 > 0 && w2 > 0 do inside = true
				}
				if !inside do continue
				if covered[y * SIZE + x] > 0 do twice += 1
				covered[y * SIZE + x] += 1
			}
		}
	}
	testing.expect_value(t, folded, 0)
	testing.expectf(t, twice == 0, "%d texels covered twice", twice)
}

// Baking a mesh onto itself gives no displacement and normals straight out; onto a copy
// one percent larger, about a hundredth out everywhere.
@(test)
bake_finds_the_source_surface :: proc(t: ^testing.T) {
	q, _, ok := retopo_sphere(t, 1500)
	defer quad_mesh_destroy(&q)
	if !testing.expect(t, ok) do return
	l := quad_uv_unwrap(q, 4.0 / 256)
	defer uv_layout_destroy(&l)
	for grow in ([2]f32{1, 1.01}) {
		source := quad_mesh_triangulate(q)
		defer mesh_destroy(&source)
		for &p in source.positions do p *= grow
		mesh_recompute_normals(&source)
		bvh := bvh_build(source)
		defer bvh_destroy(&bvh)
		b := bake_maps(q, l, source, &bvh, 256, 0.1, nil)
		defer bake_maps_destroy(&b)
		testing.expectf(t, b.covered > 256 * 256 / 4, "only %d texels covered", b.covered)
		testing.expectf(t, b.hit == b.covered, "%d of %d texels found the surface", b.hit, b.covered)
		// Texels away from every chart keep no displacement; the rest must be right.
		off, tilted, near := 0, 0, 0
		for at in 0 ..< 256 * 256 {
			d := b.displacement[at]
			if abs(d - (grow - 1)) <= 0.004 do near += 1
			else if d != 0 do off += 1
			n := b.normal[4 * at:]
			if abs(int(n[0]) - 128) > 12 || abs(int(n[1]) - 128) > 12 || n[2] < 240 do tilted += 1
		}
		testing.expectf(t, off == 0, "grow %v: %d texels off (max %v)", grow, off, b.max_displacement)
		testing.expectf(t, near >= b.covered, "grow %v: %d texels right of %d covered", grow, near, b.covered)
		testing.expectf(t, tilted < 256 * 256 / 200, "grow %v: %d texels tilted", grow, tilted)
	}
}
