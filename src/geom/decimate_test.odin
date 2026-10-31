package geom

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../jobs"

@(test)
decimate_keeps_a_closed_shape :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	// A bumpy sphere big enough for the parallel first round.
	m := geodesic_sphere(130, &pool)
	defer mesh_destroy(&m)
	for &p in m.positions do p *= 1 + 0.05 * math.sin(p.x * 9) * math.sin(p.y * 7)
	before := mesh_check(m)
	testing.expect(t, before.triangles > 200_000)
	for target in ([2]int{20_000, 1_000}) {
		from: [dynamic]u32
		defer delete(from)
		out, err, ok := mesh_decimate(m, target, &pool, from = &from)
		defer mesh_destroy(&out)
		testing.expect(t, ok)
		// Every vertex kept is one of the mesh's own, which `from` names.
		testing.expect_value(t, len(from), len(out.positions))
		for k in 0 ..< len(from) do if out.positions[k] != m.positions[from[k]] {
			testing.expectf(t, false, "%d: vertex %d is not the mesh's %d", target, k, from[k])
			break
		}
		r := mesh_check(out)
		testing.expectf(t, r.closed && r.degenerate_triangles == 0 && !r.inverted && r.non_manifold_edges == 0, "%d: %v", target, r)
		testing.expectf(t, r.vertices - r.triangles / 2 == 2, "%d: not a sphere's count (%d, %d)", target, r.vertices, r.triangles)
		testing.expectf(t, abs(r.triangles - target) <= target / 20, "%d: %d triangles", target, r.triangles)
		// Collapsing onto existing vertices cuts corners: a little volume goes, more the
		// fewer triangles are left.
		loose := 0.02 if target > 10_000 else 0.05
		testing.expectf(t, abs(r.volume - before.volume) < loose * before.volume, "%d: volume %.4f from %.4f", target, r.volume, before.volume)
		testing.expectf(t, err < f32(loose * 2), "%d: error %f", target, err)
		testing.expect(t, len(out.normals) == len(out.positions))
	}
	// Nothing to do.
	_, _, ok := mesh_decimate(m, before.triangles, &pool)
	testing.expect(t, !ok)
}

// Labels for the triangles of `m`: 1 where the triangle's middle is above z = 0, else 0.
@(private = "file")
halves :: proc(m: Mesh, allocator := context.allocator) -> []u16 {
	labels := make([]u16, len(m.indices) / 3, allocator)
	for &l, t in labels {
		z := m.positions[m.indices[3 * t]].z + m.positions[m.indices[3 * t + 1]].z + m.positions[m.indices[3 * t + 2]].z
		l = 1 if z > 0 else 0
	}
	return labels
}

// The vertices on an edge between two labels.
@(private = "file")
label_border :: proc(indices: []u32, labels: []u16, vertices: int) -> []bool {
	first := make(map[[2]u32]u16, context.temp_allocator)
	on := make([]bool, vertices, context.temp_allocator)
	for t in 0 ..< len(indices) / 3 {
		for k in 0 ..< 3 {
			a, b := indices[3 * t + k], indices[3 * t + (k + 1) % 3]
			key := [2]u32{min(a, b), max(a, b)}
			if l, seen := first[key]; seen {
				if l != labels[t] do on[a], on[b] = true, true
			} else {
				first[key] = labels[t]
			}
		}
	}
	return on
}

@(test)
decimate_holds_the_lines_between_labels :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	// Big enough for the parallel rounds, which have to carry the labels too.
	m := geodesic_sphere(130, &pool)
	defer mesh_destroy(&m)
	labels := halves(m)
	defer delete(labels)
	before := label_border(m.indices[:], labels, len(m.positions))
	from: [dynamic]u32
	defer delete(from)
	kept: [dynamic]u16
	defer delete(kept)
	out, _, ok := mesh_decimate(m, 4_000, &pool, from = &from, guide = {labels = labels}, out_labels = &kept)
	defer mesh_destroy(&out)
	if !testing.expect(t, ok) do return
	testing.expect_value(t, len(kept), len(out.indices) / 3)
	r := mesh_check(out)
	testing.expectf(t, r.closed && r.degenerate_triangles == 0 && r.non_manifold_edges == 0, "%v", r)
	testing.expectf(t, abs(r.triangles - 4_000) <= 400, "%d triangles", r.triangles)
	// Each triangle keeps its side: its corners away from the middle are on its label's
	// side. The line between the sides is made of the line's own vertices: it thinned
	// along itself without wandering.
	after := label_border(out.indices[:], kept[:], len(out.positions))
	wrong := 0
	for l, i in kept {
		for k in 0 ..< 3 {
			z := out.positions[out.indices[3 * i + k]].z
			if abs(z) > 0.05 && (z > 0) != (l == 1) do wrong += 1
		}
	}
	testing.expectf(t, wrong == 0, "%d corners on the wrong side of their label", wrong)
	strays, line := 0, 0
	for on, v in after {
		if !on do continue
		line += 1
		if !before[from[v]] do strays += 1
	}
	testing.expectf(t, line > 20 && strays == 0, "%d of the line's %d vertices were not on it", strays, line)
	// The same bits from one thread.
	kept_serial: [dynamic]u16
	defer delete(kept_serial)
	serial, _, _ := mesh_decimate(m, 4_000, nil, guide = {labels = labels}, out_labels = &kept_serial)
	defer mesh_destroy(&serial)
	testing.expect(t, slice.equal(serial.indices[:], out.indices[:]) && slice.equal(kept_serial[:], kept[:]), "serial and parallel differ")
}

// A flat n x n grid in z = 0, open all round.
@(private = "file")
open_grid :: proc(n: int) -> (m: Mesh) {
	for y in 0 ..< n do for x in 0 ..< n do append(&m.positions, Vec3{f32(x), f32(y), 0})
	for y in 0 ..< n - 1 {
		for x in 0 ..< n - 1 {
			a, b := u32(y * n + x), u32(y * n + x + 1)
			append(&m.indices, a, b, b + u32(n), a, b + u32(n), a + u32(n))
		}
	}
	return
}

@(test)
decimate_slides_open_edges_when_asked :: proc(t: ^testing.T) {
	N :: 40
	m := open_grid(N)
	defer mesh_destroy(&m)
	border := 4 * (N - 1)
	for slide in ([2]bool{false, true}) {
		out, _, ok := mesh_decimate(m, 100, nil, guide = {slide_borders = slide})
		defer mesh_destroy(&out)
		if !testing.expect(t, ok) do continue
		r := mesh_check(out)
		testing.expectf(t, r.degenerate_triangles == 0 && r.non_manifold_edges == 0 && r.inconsistent_edges == 0, "%v: %v", slide, r)
		// Held, every border vertex stays; slid, the border thins out but stays the square's.
		if slide {
			testing.expectf(t, r.boundary_edges < border / 2, "slid: %d border edges of %d", r.boundary_edges, border)
		} else {
			testing.expect_value(t, r.boundary_edges, border)
		}
		testing.expectf(t, abs(r.bounds.lo.x) < 1e-6 && abs(r.bounds.hi.x - (N - 1)) < 1e-6 && abs(r.bounds.hi.y - (N - 1)) < 1e-6, "%v: the square shrank to %v", slide, r.bounds)
		area: f64
		for i := 0; i < len(out.indices); i += 3 {
			a, b, c := out.positions[out.indices[i]], out.positions[out.indices[i + 1]], out.positions[out.indices[i + 2]]
			area += f64(linalg.cross(b - a, c - a).z) / 2
		}
		testing.expectf(t, abs(area - (N - 1) * (N - 1)) < 1e-3, "%v: area %f", slide, area)
	}
}

@(test)
decimate_keeps_weighted_detail_longer :: proc(t: ^testing.T) {
	m := icosphere(5)
	defer mesh_destroy(&m)
	for &p in m.positions do p *= 1 + 0.05 * math.sin(p.x * 9) * math.sin(p.y * 7)
	weight := make([]f32, len(m.positions))
	defer delete(weight)
	for &w, v in weight do w = 16 if m.positions[v].z > 0 else 1
	count :: proc(out: Mesh) -> (top, bottom: int) {
		for p in out.positions {
			if p.z > 0 do top += 1
			else do bottom += 1
		}
		return
	}
	plain, _, _ := mesh_decimate(m, 1_000, nil)
	defer mesh_destroy(&plain)
	weighted, _, _ := mesh_decimate(m, 1_000, nil, guide = {weight = weight})
	defer mesh_destroy(&weighted)
	pt, pb := count(plain)
	wt, wb := count(weighted)
	testing.expectf(t, wt > 2 * wb && wt > pt, "weighted top %d bottom %d, plain top %d bottom %d", wt, wb, pt, pb)
}
