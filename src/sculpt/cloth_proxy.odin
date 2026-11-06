package sculpt

import "base:runtime"
import "core:math"
import "core:math/linalg"

import "../geom"
import "../jobs"

// The cloth proxy: a dense mesh with no level coarse enough for the cloth runs its cloth
// on a simplified copy of itself, as Marvelous Designer simulates a coarse particle
// distance and ZBrush's Dynamics their Max Simulation Points. The copy keeps a subset of
// the mesh's own vertices (geom.simplify), so its free part is the mesh's; every vertex
// of the mesh is bound to the copy's nearest triangle, by where on it and how far off it
// in the triangle's own frame, so the detail turns with the cloth. While the run goes on
// the app draws the copy; at its end sculptor_proxy_write puts the mesh where the binding
// says, as one undo step of the mesh's.
Cloth_Proxy :: struct {
	sculptor: Sculptor, // the copy, which the cloth runs on
	mesh:     geom.Mesh, // its mesh, which the sculptor points to
	// Per vertex of the mesh (the fine one): how free the cloth leaves it, the copy's
	// triangle it is bound to, where on it (the weights of its first two corners) and its
	// offset in the triangle's frame (along its first edge, across it, along its normal).
	free:     []f32,
	tri:      []u32,
	bary:     [][2]f32,
	offset:   []Vec3,
	nodes:    [dynamic]u32, // the fine mesh's nodes holding a free vertex
}

// The copy's triangles for `free` of the fine mesh's vertices left free to come to about
// `budget`, the free share taken as even over the mesh; never fewer than this.
CLOTH_PROXY_MIN_TRIANGLES :: 2048
// The copy is made a run of about this many of the mesh's triangles at a time (in
// parallel), then the runs together.
CLOTH_PROXY_PART_TRIANGLES :: 1 << 16

// Builds the proxy of `fine`'s free part (what the mask and hiding leave, or with
// `on_masked` what the mask covers) at about `budget` free vertices. The copy's mask
// holds each of its vertices as the fine mesh's own, so its cloth runs without On
// masked. False when the fine mesh has nothing free or the copy could not be made.
sculptor_proxy_build :: proc(p: ^Cloth_Proxy, fine: ^Sculptor, budget: int, on_masked: bool) -> bool {
	heap := runtime.heap_allocator()
	m := fine.mesh
	nv := len(m.positions)
	p.free = make([]f32, nv, heap)
	free_count := 0
	for v in 0 ..< nv {
		w := cloth_free(fine, u32(v), on_masked)
		p.free[v] = w
		if w > 0 do free_count += 1
	}
	if free_count == 0 do return false
	tris := len(m.indices) / 3
	target := max(int(f64(tris) * f64(budget) / f64(free_count)), CLOTH_PROXY_MIN_TRIANGLES)
	out := make([dynamic]u32, 0, target * 3 + 64, heap)
	defer delete(out)
	proxy_simplify(fine, target, &out)
	if len(out) < 3 do return false

	// The copy's vertices: the fine ones its triangles use, in ascending order.
	local := make([]u32, nv, heap)
	defer delete(local, heap)
	for &l in local do l = max(u32)
	for v in out do local[v] = 0
	fine_of := make([dynamic]u32, 0, len(out) / 2 + 16, context.temp_allocator)
	for v in 0 ..< nv {
		if local[v] == max(u32) do continue
		local[v] = u32(len(fine_of))
		append(&fine_of, u32(v))
	}
	p.mesh.positions = make([dynamic]Vec3, len(fine_of), heap)
	p.mesh.indices = make([dynamic]u32, len(out), heap)
	p.mesh.normals = make([dynamic]Vec3, len(fine_of), heap)
	for v, i in fine_of do p.mesh.positions[i] = m.positions[v]
	for v, i in out do p.mesh.indices[i] = local[v]
	geom.mesh_recompute_normals(&p.mesh)
	renumber := make([]u32, len(fine_of), context.temp_allocator)
	sculptor_init(&p.sculptor, &p.mesh, fine.pool, old_to_new = renumber)
	// The copy's mask holds each vertex as much as the fine mesh's free share leaves it.
	p.sculptor.mask = make([]u8, len(fine_of), p.sculptor.history.allocator)
	for v, i in fine_of do p.sculptor.mask[renumber[i]] = u8(255 - math.round(clamp(p.free[v], 0, 1) * 255))

	// The fine nodes the cloth may move, and the binding of their vertices.
	clear(&p.nodes)
	for n, id in fine.nodes {
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			if p.free[v] > 0 {
				append(&p.nodes, u32(id))
				break
			}
		}
	}
	p.tri = make([]u32, nv, heap)
	p.bary = make([][2]f32, nv, heap)
	p.offset = make([]Vec3, nv, heap)
	box := p.sculptor.bvh.nodes[0].bounds
	Bind :: struct {
		p:         ^Cloth_Proxy,
		fine:      ^Sculptor,
		bvh:       geom.Bvh,
		near, far: f32,
	}
	// A vertex lies within a few of the copy's edges of it, so the search starts there,
	// which keeps it to a few leaves; anything further looks over the whole copy.
	area: f64
	pm := &p.mesh
	for t := 0; t < len(pm.indices); t += 3 {
		a := pm.positions[pm.indices[t]]
		area += f64(linalg.length(linalg.cross(pm.positions[pm.indices[t + 1]] - a, pm.positions[pm.indices[t + 2]] - a))) * 0.5
	}
	edge := f32(math.sqrt(4 * area / (math.SQRT_THREE * f64(max(len(pm.indices) / 3, 1)))))
	// The sculptor's BVH has leaves of a node's thousand triangles, for brushes; a search
	// for the nearest triangle wants a few to a leaf.
	b := Bind{p = p, fine = fine, bvh = geom.bvh_build_morton(p.mesh, pool = fine.pool), near = 4 * edge, far = 2 * linalg.length(box.hi - box.lo) + 1}
	defer geom.bvh_destroy(&b.bvh)
	jobs.parallel_for(fine.pool, len(p.nodes), &b, proc(data: rawptr, k: int) {
		b := cast(^Bind)data
		p := b.p
		m := b.fine.mesh
		n := b.fine.nodes[p.nodes[k]]
		hint := geom.BVH_NONE
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			if p.free[v] <= 0 do continue
			at := m.positions[v]
			tri, bary, _, ok := geom.bvh_closest(b.bvh, p.mesh, at, b.near, hint)
			if !ok do tri, bary, _, ok = geom.bvh_closest(b.bvh, p.mesh, at, b.far, hint)
			if !ok {
				p.free[v] = 0
				continue
			}
			hint = tri
			a, e1, e2, nrm := proxy_frame(&p.mesh, tri)
			on := a + bary[1] * (proxy_corner(&p.mesh, tri, 1) - a) + bary[2] * (proxy_corner(&p.mesh, tri, 2) - a)
			d := at - on
			p.tri[v], p.bary[v] = tri, {bary[0], bary[1]}
			p.offset[v] = {linalg.dot(d, e1), linalg.dot(d, e2), linalg.dot(d, nrm)}
		}
	})
	return true
}

// The fine mesh's triangles simplified to about `target`, as indices into its positions:
// first each of a few runs of its nodes on its own, in parallel, their borders kept, then
// the runs' copies together, which takes the borders down too. The nodes lie along the
// BVH, so each run is a compact patch, and the last pass reads a fraction of the mesh.
@(private = "file")
proxy_simplify :: proc(fine: ^Sculptor, target: int, out: ^[dynamic]u32) {
	heap := runtime.heap_allocator()
	m := fine.mesh
	tris := len(m.indices) / 3
	// The runs depend on the mesh alone, never on the threads, so the copy is the same on
	// any number of them.
	parts := clamp(tris / CLOTH_PROXY_PART_TRIANGLES, 1, max(len(fine.nodes) / 4, 1))
	if parts == 1 {
		_ = geom.simplify(m.positions[:], m.indices[:], target, out, heap)
		return
	}
	Part :: struct {
		first, last: int, // nodes
		out:         [dynamic]u32,
	}
	Split :: struct {
		fine:   ^Sculptor,
		parts:  []Part,
		ratio:  f64,
	}
	sp := Split{fine = fine, parts = make([]Part, parts, heap), ratio = f64(target) / f64(tris)}
	defer delete(sp.parts, heap)
	// Runs of about equal triangles, in node order.
	at, sum := 0, 0
	for &part, k in sp.parts {
		part.first = at
		goal := tris * (k + 1) / parts
		for at < len(fine.nodes) && (sum < goal || at == part.first) {
			sum += int(fine.nodes[at].tri_count)
			at += 1
		}
		part.last = at if k < parts - 1 else len(fine.nodes)
	}
	jobs.parallel_for(fine.pool, parts, &sp, proc(data: rawptr, k: int) {
		sp := cast(^Split)data
		heap := runtime.heap_allocator()
		s := sp.fine
		part := &sp.parts[k]
		n := 0
		for id in part.first ..< part.last do n += int(s.nodes[id].tri_count)
		input := make([]u32, 3 * n, heap)
		defer delete(input, heap)
		at := 0
		for id in part.first ..< part.last {
			nd := s.nodes[id]
			copy(input[at:], s.mesh.indices[3 * nd.tri_first:][:3 * nd.tri_count])
			at += 3 * int(nd.tri_count)
		}
		part.out = make([dynamic]u32, 0, int(f64(3 * n) * sp.ratio) + 64, heap)
		_ = geom.simplify(s.mesh.positions[:], input, max(int(f64(n) * sp.ratio), 1), &part.out, heap)
	})
	joined := make([dynamic]u32, 0, 3 * target * 2 + 64, heap)
	defer delete(joined)
	for part in sp.parts {
		append(&joined, ..part.out[:])
		delete(part.out)
	}
	_ = geom.simplify(m.positions[:], joined[:], target, out, heap)
}

// Corner `k` of the copy's triangle `tri`, where it is now.
@(private = "file")
proxy_corner :: #force_inline proc(m: ^geom.Mesh, tri: u32, k: int) -> Vec3 {
	return m.positions[m.indices[3 * tri + u32(k)]]
}

// The copy's triangle `tri` as it is now: its first corner and its frame, along its first
// edge, across it in its plane and along its normal.
@(private = "file")
proxy_frame :: #force_inline proc(m: ^geom.Mesh, tri: u32) -> (a, e1, e2, n: Vec3) {
	a = proxy_corner(m, tri, 0)
	ab, ac := proxy_corner(m, tri, 1) - a, proxy_corner(m, tri, 2) - a
	e1 = linalg.normalize0(ab)
	n = linalg.normalize0(linalg.cross(ab, ac))
	e2 = linalg.cross(n, e1)
	return
}

// Puts the fine mesh where the copy now carries it, each free vertex its free share of
// the way, as part of the stroke under way on `fine` (begun before the proxy was built):
// what moves is recorded for undo first. Returns how many nodes moved.
sculptor_proxy_write :: proc(p: ^Cloth_Proxy, fine: ^Sculptor) -> int {
	if len(p.nodes) == 0 do return 0
	_ = sculptor_gpu_sync(fine)
	clear(&fine.hit)
	for id in p.nodes do append(&fine.hit, fine.nodes[id].leaf)
	if fine.history.recording do record_hit(fine, masks = false)
	Write :: struct {
		p:    ^Cloth_Proxy,
		fine: ^Sculptor,
	}
	w := Write{p, fine}
	jobs.parallel_for(fine.pool, len(p.nodes), &w, proc(data: rawptr, k: int) {
		w := cast(^Write)data
		p := w.p
		m := w.fine.mesh
		n := w.fine.nodes[p.nodes[k]]
		for v in n.vert_first ..< n.vert_first + n.vert_count {
			share := p.free[v]
			if share <= 0 do continue
			tri := p.tri[v]
			a, e1, e2, nrm := proxy_frame(&p.mesh, tri)
			b := p.bary[v]
			on := a + b[1] * (proxy_corner(&p.mesh, tri, 1) - a) + (1 - b[0] - b[1]) * (proxy_corner(&p.mesh, tri, 2) - a)
			o := p.offset[v]
			to := on + o.x * e1 + o.y * e2 + o.z * nrm
			m.positions[v] += (to - m.positions[v]) * clamp(share, 0, 1)
		}
	})
	sculptor_nodes_moved(fine, p.nodes[:])
	if fine.history.recording do record_changed(fine)
	return len(p.nodes)
}

// Frees the proxy, its copy with it.
cloth_proxy_destroy :: proc(p: ^Cloth_Proxy) {
	if p.sculptor.mesh != nil do sculptor_destroy(&p.sculptor)
	geom.mesh_destroy(&p.mesh)
	heap := runtime.heap_allocator()
	delete(p.free, heap)
	delete(p.tri, heap)
	delete(p.bary, heap)
	delete(p.offset, heap)
	delete(p.nodes)
	p^ = {}
}
