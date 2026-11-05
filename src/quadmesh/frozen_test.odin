package quadmesh

import "core:log"
import "core:math"
import "core:testing"

import "../geom"

// A disc of `segments` border edges round a unit circle, rings of triangles inside, in the
// plane z = 0, or bulged into a bowl when `bowl`.
@(private = "file")
frozen_disc :: proc(segments, rings: int, bowl: bool) -> (positions: [dynamic]geom.Vec3, indices: [dynamic]u32) {
	append(&positions, geom.Vec3{0, 0, -1 if bowl else 0})
	for r in 1 ..= rings do for k in 0 ..< segments {
		a := 2 * math.PI * f64(k) / f64(segments)
		radius := f64(r) / f64(rings)
		z := -math.sqrt(max(0, 1 - radius * radius)) if bowl else 0
		append(&positions, geom.Vec3{f32(radius * math.cos(a)), f32(radius * math.sin(a)), f32(z)})
	}
	at :: proc(r, k, segments: int) -> u32 {return 0 if r == 0 else u32(1 + (r - 1) * segments + k % segments)}
	for k in 0 ..< segments do append(&indices, 0, at(1, k, segments), at(1, k + 1, segments))
	for r in 1 ..< rings do for k in 0 ..< segments {
		append(&indices, at(r, k, segments), at(r + 1, k, segments), at(r + 1, k + 1, segments))
		append(&indices, at(r, k, segments), at(r + 1, k + 1, segments), at(r, k + 1, segments))
	}
	return
}

// What a remesh with the border frozen kept of it: how many of the frozen vertices the
// quads have a vertex exactly on, how many border edges the quads have, and their faces
// by sides.
@(private = "file")
Frozen_Result :: struct {
	kept, border_edges, quads, triangles, others: int,
}

@(private = "file")
frozen_measure :: proc(out: Polygon_Mesh, positions: []geom.Vec3, frozen: []bool) -> (r: Frozen_Result) {
	at := make(map[geom.Vec3]bool, len(out.positions), context.temp_allocator)
	for p in out.positions do at[p] = true
	for f, v in frozen do if f && at[positions[v]] do r.kept += 1
	uses := make(map[u64]int, 4 * len(out.corners), context.temp_allocator)
	for f in 0 ..< len(out.first) - 1 {
		c := out.corners[out.first[f]:out.first[f + 1]]
		switch len(c) {
		case 4: r.quads += 1
		case 3: r.triangles += 1
		case: r.others += 1
		}
		for v, k in c do uses[edge_key(v, c[(k + 1) % len(c)])] += 1
	}
	for _, n in uses do if n == 1 do r.border_edges += 1
	return
}

@(private = "file")
frozen_run :: proc(t: ^testing.T, name: string, segments, rings, quads: int, bowl: bool, share := 1) -> (r: Frozen_Result, report: Report) {
	positions, indices := frozen_disc(segments, rings, bowl)
	defer delete(positions)
	defer delete(indices)
	frozen := make([]bool, len(positions), context.temp_allocator)
	marked := 0
	for k in 0 ..< segments {
		if share > 1 && k > segments / share do continue
		frozen[len(positions) - segments + k] = true
		marked += 1
	}
	params := DEFAULT_PARAMS
	params.quads, params.threads, params.frozen = quads, 4, frozen
	out, rep, err, reason := remesh(positions[:], indices[:], params)
	defer polygon_mesh_destroy(&out)
	if !testing.expectf(t, err == .None, "%s: remesh failed: %v %s", name, err, reason) do return
	r = frozen_measure(out, positions[:], frozen)
	c := rep.checks
	log.infof("%s: %d of %d frozen kept, %d border edges for %d, %d quads %d triangles %d others; frozen %d kept %d mended %d; covers %d flipped %d cells %.0f/%.0f; extract tris %d holes %d bays %d filled %d", name, r.kept, marked, r.border_edges, segments, r.quads, r.triangles, r.others, c.frozen_vertices, c.frozen_kept, c.frozen_mended, c.covers, c.cover_flipped, c.cover_cells, c.cover_cells_wanted, c.quad_triangles, c.extract_holes, c.extract_bays, c.extract_filled)
	return r, rep
}

// Every frozen border vertex kept where it was, one quad edge between each two, and the
// rest quads but for a few triangles where the border's count and the field's disagree,
// which retopo's finish pairs up (quad_remesh_keeps_the_border).
@(private = "file")
frozen_expect :: proc(t: ^testing.T, name: string, r: Frozen_Result, kept, edges: int, loc := #caller_location) {
	testing.expectf(t, r.kept == kept && (edges < 0 || r.border_edges == edges), "%s: %d of %d border vertices kept, %d border edges", name, r.kept, kept, r.border_edges, loc = loc)
	faces := r.quads + r.triangles + r.others
	testing.expectf(t, r.others == 0 && 20 * r.triangles <= faces, "%s: %d triangles and %d larger polygons of %d", name, r.triangles, r.others, faces, loc = loc)
}

// A flat disc whose border is finer than its quads: the quads beside it are its edges'
// size, growing away from it.
@(test)
frozen_disc_keeps_its_border :: proc(t: ^testing.T) {
	r, _ := frozen_run(t, "disc 96", 96, 24, 400, false)
	frozen_expect(t, "disc 96", r, 96, 96)
}

// An odd border, which a quad mesh cannot close on without a triangle or a pole.
@(test)
frozen_odd_border :: proc(t: ^testing.T) {
	r, _ := frozen_run(t, "disc 95", 95, 24, 400, false)
	frozen_expect(t, "disc 95", r, 95, 95)
}

// A border that alone asks more quads than the count: the border comes first.
@(test)
frozen_dense_border :: proc(t: ^testing.T) {
	r, _ := frozen_run(t, "bowl 200", 200, 30, 100, true)
	frozen_expect(t, "bowl 200", r, 200, 200)
}

// A border coarser than the quads asked.
@(test)
frozen_coarse_border :: proc(t: ^testing.T) {
	r, _ := frozen_run(t, "bowl 24", 24, 30, 1500, true)
	frozen_expect(t, "bowl 24", r, 24, 24)
}

// Half the rim frozen: that half kept, the other remeshed as an open border is.
@(test)
frozen_half_border :: proc(t: ^testing.T) {
	r, _ := frozen_run(t, "bowl half", 120, 30, 600, true, 2)
	frozen_expect(t, "bowl half", r, 61, -1)
}
