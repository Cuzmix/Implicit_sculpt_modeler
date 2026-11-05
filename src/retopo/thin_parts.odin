package retopo

import pq "core:container/priority_queue"
import "core:math"
import "core:math/linalg"

import "../geom"
import "../jobs"

// Thin parts (a tail, a finger, a horn, a rod) under Quad Remesh with AutoRemesher: the
// quads are sized from the count alone, so a part whose girth is a few quad edges or less
// gets two or three quads round it, or none, and comes back folded or gone (a rod a
// twentieth of a sphere's width vanished). Here each vertex measures the part under it:
// a ray inward against its normal to the surface it leaves the solid by gives the part's
// thickness there, and from halfway along it rays across, square to the first, give its
// width, the narrowest of four directions. The cross-section's round is then about that
// of an ellipse of those two diameters, pi (thickness + width) / 2: a tube's is its
// circumference, while a plate (an ear, a fin, an eyelid) is as thin as a tube one way
// but wide the other, and its round is mostly its width. Where the round is under
// THIN_AROUND quad edges, the vertex asks for quads small enough that THIN_AROUND go
// round, as density (quads per area, quadmesh.Params.density) on top of what paint and
// mask ask. The count stays what was asked: the rest's quads grow a little to pay. Six
// quads round are still too few for AutoRemesher's extraction over triangles the quads'
// own size (a tube under about seven round came back as a handful of faces), so a thin
// part also asks for an isotropic mesh THIN_REFINE as coarse (quadmesh.Params.refine),
// with which a tube five quads round comes back whole.

// The quads wanted round a thin part.
THIN_AROUND :: 6
// How squarely the far surface must face away from the vertex (the cosine of the angle
// between its normal and the vertex's reversed, about 45 degrees at most).
THIN_FACING :: f32(0.7)
// The directions the width is measured in, spread over half a turn.
THIN_ACROSS :: 4
// The most a thin part asks for (AutoRemesher holds density within 1/16 to 16).
THIN_DENSITY_MAX :: f32(16)
// The vertices measured per quad asked, about: a sculpt has hundreds of vertices to a
// quad (500k for 2,500 quads on a creature, where measuring them all took a second), and
// a part thin enough to matter has dozens of these within a quad of it. The rest take
// the most their measured neighbours ask.
THIN_SAMPLES_PER_QUAD :: 32
// The most vertices measured, whatever the count: at 20,000 quads on a creature of 500k
// vertices the rule above measured every one, nine rays each, which took 0.85 s of the
// remesh's 5.5; this many still puts six on each quad's area (the creature's largest
// miss fell from 0.86 % to 0.43 % of its size), and below 3,750 quads it changes nothing.
THIN_SAMPLES_MAX :: 120_000
// The rounds of averaging the refinement with the neighbours, so it fades out over a few
// edges rather than stepping (the ray's own noise goes too).
THIN_BLUR_ROUNDS :: 3
// How fast the quad edge asked may grow away from a thin part: by this share of the
// distance (a quarter of a quad edge a quad edge away), as mesh sizing fields grade.
THIN_GRADING :: f32(0.25)
// The isotropic mesh's edge under a thin part, as a share of the quads' there.
THIN_REFINE :: f32(0.5)
// The most the thin parts' density is raised so that they keep it after the remesh takes
// all densities relative to their mean (thin_density says how).
THIN_RAISE_MAX :: f32(4)

// The density each vertex of `m` asks for its thickness (1 where it is not thin), for
// quads of edge `quad_edge` elsewhere, the refinement it asks for (THIN_REFINE where thin,
// 1 elsewhere), and how many vertices are thin; nil, nil and 0 when none is. Parallel over
// the vertices; the same result for any thread count.
thin_density :: proc(m: geom.Mesh, quad_edge: f32, pool: ^jobs.Pool) -> (density, refine: []f32, thin: int) {
	n := len(m.positions)
	if n == 0 || len(m.indices) < 3 || !(quad_edge > 0) do return
	// The round below which a part is thin, THIN_AROUND quads of edge quad_edge, and so
	// the most thickness plus width that can be: round = pi (thickness + width) / 2.
	round_below := f32(THIN_AROUND) * quad_edge
	reach := 2 * round_below / math.PI
	// A vertex's normal, its triangles' area-weighted.
	normals := make([]geom.Vec3, n)
	defer delete(normals)
	for k := 0; k + 2 < len(m.indices); k += 3 {
		a, b, c := m.indices[k], m.indices[k + 1], m.indices[k + 2]
		w := linalg.cross(m.positions[b] - m.positions[a], m.positions[c] - m.positions[a])
		normals[a] += w
		normals[b] += w
		normals[c] += w
	}
	bvh := geom.bvh_build_morton(m, geom.BVH_LEAF_SIZE, pool)
	defer geom.bvh_destroy(&bvh)
	// One vertex in `every` is measured, picked by a hash of its index so the picks
	// spread over the surface whatever order the vertices come in.
	area: f64
	for k := 0; k + 2 < len(m.indices); k += 3 {
		a, b, c := m.positions[m.indices[k]], m.positions[m.indices[k + 1]], m.positions[m.indices[k + 2]]
		area += f64(linalg.length(linalg.cross(b - a, c - a))) / 2
	}
	samples := min(area / f64(quad_edge * quad_edge) * THIN_SAMPLES_PER_QUAD, THIN_SAMPLES_MAX)
	every := u32(max(1, f64(n) / max(samples, 1)))
	asked := make([]f32, n)
	Job :: struct {
		m:           geom.Mesh,
		bvh:         ^geom.Bvh,
		normals:     []geom.Vec3,
		asked:       []f32,
		quad_edge:   f32,
		round_below: f32,
		reach:       f32,
		every:       u32,
	}
	job := Job{m, &bvh, normals, asked, quad_edge, round_below, reach, every}
	jobs.parallel_ranges(pool, n, &job, proc(data: rawptr, lo, hi: int) {
		j := (^Job)(data)
		stack := make([dynamic]u32, 0, 64, context.temp_allocator)
		for v in lo ..< hi {
			// 0 for not measured, filled in from the neighbours after.
			if j.every > 1 && (u32(v) * 2654435761) % j.every != 0 {
				j.asked[v] = 0
				continue
			}
			j.asked[v] = 1
			normal := j.normals[v]
			length := linalg.length(normal)
			if !(length > 0) do continue
			dir := -normal / length
			// From a hair inside, so the vertex's own triangles are behind the ray.
			lift := j.quad_edge * 1e-3
			t, tri, ok := geom.bvh_raycast_with(j.bvh^, j.m, j.m.positions[v] + dir * lift, dir, j.reach, &stack)
			if !ok do continue
			// Only a surface facing about opposite the vertex (within THIN_FACING) is the
			// other side of a part, as a tube's or a plate's far wall is: beside a sharp
			// edge the ray leaves by the other face of the edge, near but not across, and a
			// surface the ray enters by means the normal or the winding is not to be
			// trusted here.
			if linalg.dot(face_normal(j.m, tri), dir) < THIN_FACING do continue
			thickness := max(t + lift, j.quad_edge * 1e-2)
			// The width: from halfway through, both ways along each direction square to
			// the ray, the narrowest. Only a wall the ray meets about squarely (within
			// THIN_FACING) bounds it, as a tube's does: inside a plate the ray runs between
			// its two faces and leaves by one at a glance, and a direction that meets no
			// such wall within what is left of the reach is as wide as that.
			middle := j.m.positions[v] + dir * (lift + t / 2)
			u := linalg.normalize(linalg.cross(dir, geom.Vec3{1, 0, 0} if abs(dir.x) < 0.6 else geom.Vec3{0, 1, 0}))
			w := linalg.cross(dir, u)
			left := j.reach - thickness
			if left <= 0 do continue
			width := left
			for k in 0 ..< THIN_ACROSS {
				angle := math.PI * f32(k) / f32(THIN_ACROSS)
				across := u * math.cos(angle) + w * math.sin(angle)
				span: f32
				for side in ([2]f32{1, -1}) {
					d := across * side
					a, at, hit := geom.bvh_raycast_with(j.bvh^, j.m, middle, d, left - span, &stack)
					if !hit || linalg.dot(face_normal(j.m, at), d) < THIN_FACING {
						span = left
						break
					}
					span += a
				}
				width = min(width, span)
			}
			round := math.PI * (thickness + width) / 2
			if round >= j.round_below do continue
			edge := round / f32(THIN_AROUND)
			j.asked[v] = min((j.quad_edge / edge) * (j.quad_edge / edge), THIN_DENSITY_MAX)
		}
	}, 4096)
	if every > 1 do fill_unmeasured(m, asked)
	for a in asked do if a > 1 do thin += 1
	if thin == 0 {
		delete(asked)
		return
	}
	finer := make([]f32, n)
	for &r, v in finer do r = THIN_REFINE if asked[v] > 1 else 1
	blur(m, finer)
	// The quad edge asked, graded so it grows by at most THIN_GRADING of the distance
	// away from a thin part, and the density from it: a thin part's quads a quarter the
	// size of the rest's next to the rest's, as measured, folded the quad cover on a
	// creature's half (a tenth of the cells, then twice too many), while a few edges of
	// averaging on a dense sculpt spread the step over less than a quad.
	size := make([]f32, n)
	defer delete(size)
	for &h, v in size do h = quad_edge / math.sqrt(asked[v])
	grade(m, size, quad_edge)
	for &d, v in asked do d = (quad_edge / size[v]) * (quad_edge / size[v])
	// The remesh takes the densities relative to their mean over the area, which the thin
	// parts raise, so they would get fewer quads round than asked (five for six on a rod
	// through a sphere): raised by s, the extra density 1 + (d - 1) s over the mean
	// 1 + s E / W (E the extra density over the area, W the area) keeps about d where d is
	// large, for s = W / (W - E), held to THIN_RAISE_MAX where the thin parts are most of
	// the surface.
	vertex_area := make([]f32, n)
	defer delete(vertex_area)
	for k := 0; k + 2 < len(m.indices); k += 3 {
		a, b, c := m.indices[k], m.indices[k + 1], m.indices[k + 2]
		third := linalg.length(linalg.cross(m.positions[b] - m.positions[a], m.positions[c] - m.positions[a])) / 6
		vertex_area[a] += third
		vertex_area[b] += third
		vertex_area[c] += third
	}
	whole, extra: f64
	for w, v in vertex_area {
		whole += f64(w)
		extra += f64(w) * f64(asked[v] - 1)
	}
	raise := THIN_RAISE_MAX
	if whole - extra > 0 do raise = clamp(f32(whole / (whole - extra)), 1, THIN_RAISE_MAX)
	for &d in asked do d = min(1 + (d - 1) * raise, THIN_DENSITY_MAX)
	return asked, finer, thin
}

// Each vertex not measured (asked 0) takes the most its measured neighbours ask, round by
// round outward from them, each round from the last's values; one no round reaches (a
// piece with no measured vertex) asks 1.
@(private = "file")
fill_unmeasured :: proc(m: geom.Mesh, asked: []f32) {
	next := make([]f32, len(asked))
	defer delete(next)
	for {
		copy(next, asked)
		grew := false
		for k := 0; k + 2 < len(m.indices); k += 3 {
			for e in 0 ..< 3 {
				a, b := m.indices[k + e], m.indices[k + (e + 1) % 3]
				if asked[a] == 0 && asked[b] > 0 && asked[b] > next[a] {
					next[a] = asked[b]
					grew = true
				}
				if asked[b] == 0 && asked[a] > 0 && asked[a] > next[b] {
					next[b] = asked[a]
					grew = true
				}
			}
		}
		copy(asked, next)
		if !grew do break
	}
	for &a in asked do if a == 0 do a = 1
}

// Each vertex's size lowered to the least of its own and any vertex's size plus
// THIN_GRADING times the length of the edge path between them, by a shortest-path walk
// out from the vertices under `top` (Dijkstra's, along the edges); a size reaching `top`
// goes no further, since nothing at or above it is lowered.
@(private = "file")
grade :: proc(m: geom.Mesh, size: []f32, top: f32) {
	n := len(size)
	// The neighbours of each vertex, both other corners of each triangle it is in (an
	// edge twice from its two triangles, which the walk does not mind).
	start := make([]u32, n + 1)
	defer delete(start)
	for i in m.indices do start[i + 1] += 2
	for v in 0 ..< n do start[v + 1] += start[v]
	next := make([]u32, n)
	defer delete(next)
	copy(next, start[:n])
	around := make([]u32, start[n])
	defer delete(around)
	for k := 0; k + 2 < len(m.indices); k += 3 {
		for e in 0 ..< 3 {
			v := m.indices[k + e]
			around[next[v]] = m.indices[k + (e + 1) % 3]
			around[next[v] + 1] = m.indices[k + (e + 2) % 3]
			next[v] += 2
		}
	}
	Item :: struct {
		size:   f32,
		vertex: u32,
	}
	queue: pq.Priority_Queue(Item)
	pq.init(&queue, proc(a, b: Item) -> bool {return a.size < b.size || (a.size == b.size && a.vertex < b.vertex)}, pq.default_swap_proc(Item))
	defer pq.destroy(&queue)
	for h, v in size do if h < top do pq.push(&queue, Item{h, u32(v)})
	for pq.len(queue) > 0 {
		item := pq.pop(&queue)
		if item.size > size[item.vertex] do continue
		p := m.positions[item.vertex]
		for u in around[start[item.vertex]:start[item.vertex + 1]] {
			h := item.size + THIN_GRADING * linalg.length(m.positions[u] - p)
			if h < size[u] && h < top {
				size[u] = h
				pq.push(&queue, Item{h, u})
			}
		}
	}
}

// Triangle `tri`'s unit normal by its winding.
@(private = "file")
face_normal :: proc(m: geom.Mesh, tri: u32) -> geom.Vec3 {
	i := m.indices[3 * tri:][:3]
	return linalg.normalize0(linalg.cross(m.positions[i[1]] - m.positions[i[0]], m.positions[i[2]] - m.positions[i[0]]))
}

// Each value averaged with the mean of its neighbours along `m`'s edges, THIN_BLUR_ROUNDS
// times, each round from the last's values.
@(private = "file")
blur :: proc(m: geom.Mesh, values: []f32) {
	neighbours := make([]f32, len(values))
	defer delete(neighbours)
	counts := make([]u32, len(values))
	defer delete(counts)
	for _ in 0 ..< THIN_BLUR_ROUNDS {
		for &x in neighbours do x = 0
		for &x in counts do x = 0
		for k := 0; k + 2 < len(m.indices); k += 3 {
			for e in 0 ..< 3 {
				a, b := m.indices[k + e], m.indices[k + (e + 1) % 3]
				neighbours[a] += values[b]
				neighbours[b] += values[a]
				counts[a] += 1
				counts[b] += 1
			}
		}
		for &x, v in values do if counts[v] > 0 do x = (x + neighbours[v] / f32(counts[v])) / 2
	}
}
