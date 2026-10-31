package geom

import "core:testing"

// Every vertex's image across each plane of `mirror` is a vertex too (to `eps`).
@(private = "file")
unmatched_images :: proc(m: Mesh, mirror: Remesh_Mirror, eps: f32) -> (unmatched: int) {
	for a in 0 ..< 3 {
		if !mirror.axes[a] do continue
		for p in m.positions {
			image := p
			image[a] = 2 * mirror.center[a] - p[a]
			found := false
			for q in m.positions do if abs(q.x - image.x) <= eps && abs(q.y - image.y) <= eps && abs(q.z - image.z) <= eps {
				found = true
				break
			}
			if !found do unmatched += 1
		}
	}
	return
}

// Cut across two planes off the origin and mirrored straight back, a closed mesh comes
// back closed, manifold, facing out and its own mirror image, with each vertex of the cut
// part traced to the vertex it came from.
@(test)
mirror_cut_then_mirror_closes :: proc(t: ^testing.T) {
	m := icosphere(4)
	defer mesh_destroy(&m)
	for &p in m.positions do p += {0.3, 0, -0.2}
	mirror := Remesh_Mirror{axes = {true, false, true}, center = {0.3, 0, -0.2}}
	from: Slice_From
	defer slice_from_destroy(&from)
	half, ok := mirror_cut(m, mirror, false, nil, from = &from)
	defer mesh_destroy(&half)
	if !testing.expect(t, ok, "not cut") do return
	testing.expect_value(t, len(from.vertex), len(half.positions))
	testing.expect_value(t, len(from.triangle), len(half.indices) / 3)
	for v in from.vertex do if !testing.expect(t, v < u32(len(m.positions)), "a vertex from nowhere") do break
	for p in half.positions do if !testing.expect(t, p.x >= 0.3 - 1e-5 && p.z >= -0.2 - 1e-5, "a vertex on the far side") do break
	planes := mirror_seam(half, mirror, 1e-4)
	defer delete(planes)
	on_x, on_z := 0, 0
	for p in planes {
		if p & 1 != 0 do on_x += 1
		if p & 4 != 0 do on_z += 1
	}
	testing.expectf(t, on_x >= 8 && on_z >= 8, "seam %d on X, %d on Z", on_x, on_z)
	at := make([dynamic]u8, len(planes))
	defer delete(at)
	copy(at[:], planes)
	_ = mesh_mirror(&half, &at, mirror)
	check := mesh_check(half)
	testing.expectf(t, check.closed && check.non_manifold_edges == 0 && !check.inverted && check.degenerate_triangles == 0, "%v", check)
	testing.expect_value(t, unmatched_images(half, mirror, 1e-5), 0)
}

// A decimation steered by a seam thins the seam out along itself, keeps every vertex of
// it on its plane, and never joins two of its vertices across the surface: mirrored, the
// part closes into a manifold whole.
@(test)
decimate_with_a_seam_stays_on_the_plane :: proc(t: ^testing.T) {
	m := icosphere(5)
	defer mesh_destroy(&m)
	mirror := Remesh_Mirror{axes = {true, false, false}}
	half, ok := mirror_cut(m, mirror, false, nil)
	defer mesh_destroy(&half)
	if !testing.expect(t, ok, "not cut") do return
	planes := mirror_seam(half, mirror, 1e-4)
	defer delete(planes)
	seam := make([]bool, len(planes))
	defer delete(seam)
	before := 0
	for p, v in planes {
		seam[v] = p != 0
		if seam[v] do before += 1
	}
	from: [dynamic]u32
	defer delete(from)
	out, _, built := mesh_decimate(half, len(half.indices) / 30, nil, from = &from, guide = {seam = seam})
	defer mesh_destroy(&out)
	if !testing.expect(t, built, "not decimated") do return
	at := make([dynamic]u8, len(from))
	defer delete(at)
	after := 0
	for v, k in from {
		at[k] = planes[v]
		if planes[v] != 0 {
			after += 1
			testing.expectf(t, abs(out.positions[k].x) <= 1e-4, "seam vertex %d off the plane at %v", k, out.positions[k])
		}
	}
	testing.expectf(t, after > 4 && after < before / 4, "the seam kept %d of %d vertices", after, before)
	_ = mesh_mirror(&out, &at, mirror)
	check := mesh_check(out)
	testing.expectf(t, check.closed && check.non_manifold_edges == 0 && !check.inverted, "%v", check)
	testing.expect_value(t, unmatched_images(out, mirror, 1e-6), 0)
}
