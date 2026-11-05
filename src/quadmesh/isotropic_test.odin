package quadmesh

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:testing"
import "core:time"

import "../geom"
import "../jobs"

// The isotropic remesh on its own, held to what a remesh must be (the smallest angle and
// the spread of the edges, the island's topology, about the triangles its edge asks for),
// on borders, hard edges, pinches and damaged input, serial against parallel, and
// cancelled.

// An island of a mesh, from the heap as the stages' are.
@(private)
island_of :: proc(positions: []geom.Vec3, indices: []u32) -> (m: Island) {
	heap := runtime.heap_allocator()
	m.positions = make([][3]f64, len(positions), heap)
	for p, v in positions do m.positions[v] = {f64(p.x), f64(p.y), f64(p.z)}
	m.triangles = make([][3]u32, len(indices) / 3, heap)
	for &t, f in m.triangles do t = {indices[3 * f], indices[3 * f + 1], indices[3 * f + 2]}
	return
}

// The stage's edge for about `quads` quads over the island, as the driver sizes it.
@(private)
edge_for :: proc(m: Island, quads: int) -> f64 {
	area := f64(0)
	for t in m.triangles do area += triangle_area(m.positions[t[0]], m.positions[t[1]], m.positions[t[2]])
	return math.sqrt(area / (2 * f64(quads)) / EQUILATERAL_AREA)
}

// The share of triangles whose smallest angle is under 30 degrees.
@(private = "file")
thin_share :: proc(iso: Isotropic) -> f64 {
	thin := 0
	for t in iso.triangles {
		smallest := f64(180)
		for k in 0 ..< 3 {
			p, q, r := iso.positions[t[k]], iso.positions[t[(k + 1) % 3]], iso.positions[t[(k + 2) % 3]]
			u, v := q - p, r - p
			lu, lv := math.sqrt(dot3(u, u)), math.sqrt(dot3(v, v))
			if lu > 0 && lv > 0 do smallest = min(smallest, math.acos(clamp(dot3(u, v) / (lu * lv), -1, 1)) * 180 / math.PI)
		}
		if smallest < 30 do thin += 1
	}
	return 100 * f64(thin) / f64(max(len(iso.triangles), 1))
}

// What the remesh of a fixture must give: its smallest angle at least, the spread of its
// edges (their standard deviation over their mean) at most, both set a little past what
// the stage gives, which is past AutoRemesher's isotropic remesher on every one of these
// (its smallest angles were 10 to 35 degrees, and its spreads up to 0.27); and its
// triangles within a fifth of what the edge asks of the area (`count`, off where a
// density or refinement asks for more).
@(private = "file")
Iso_Want :: struct {
	angle:  f64,
	spread: f64,
	count:  bool,
}

// The stage on the island, held to `want`, its surface as closed as the island and of the
// island's Euler characteristic. Returns its checks.
@(private = "file")
isotropic_holds :: proc(t: ^testing.T, name: string, island: Island, edge, adaptivity, sharp: f64, want: Iso_Want, pool: ^jobs.Pool = nil, loc := #caller_location) -> (c: Checks) {
	run := Stage_Run{threads = 4, pool = pool}
	reason: Reason
	t0 := time.tick_now()
	iso, err := odin_isotropic(island, edge, adaptivity, sharp, &run, &reason, &c)
	ms := time.duration_milliseconds(time.tick_since(t0))
	defer isotropic_destroy(&iso)
	if !testing.expectf(t, err == .None, "%s: the stage failed: %v %s", name, err, reason_string(&reason), loc = loc) do return
	checks_isotropic(&c, iso)
	area := f64(0)
	for tri in island.triangles do area += triangle_area(island.positions[tri[0]], island.positions[tri[1]], island.positions[tri[2]])
	asked := area / (EQUILATERAL_AREA * edge * edge)
	euler := island_euler(island)
	log.infof("%s: %d triangles for %.0f asked, smallest angle %.2f, spread %.3f, %.1f%% under 30 degrees, mean edge %.4f, %.0f ms", name, c.iso_triangles, asked, c.iso_min_angle, c.iso_edge_spread, thin_share(iso), iso.mean_edge, ms)
	testing.expectf(t, c.iso_min_angle >= want.angle, "%s: smallest angle %.2f, at least %.2f expected", name, c.iso_min_angle, want.angle, loc = loc)
	testing.expectf(t, c.iso_edge_spread <= want.spread, "%s: edge spread %.3f, at most %.3f expected", name, c.iso_edge_spread, want.spread, loc = loc)
	testing.expectf(t, c.iso_nonmanifold == 0 && c.iso_euler == euler, "%s: %d non-manifold edges, Euler characteristic %d for the island's %d", name, c.iso_nonmanifold, c.iso_euler, euler, loc = loc)
	ratio := f64(c.iso_triangles) / asked
	testing.expectf(t, !want.count || (ratio > 0.8 && ratio < 1.2), "%s: %d triangles where the edge asks for %.0f", name, c.iso_triangles, asked, loc = loc)
	return
}

// The island's vertices less its edges plus its triangles.
@(private = "file")
island_euler :: proc(m: Island) -> int {
	heap := runtime.heap_allocator()
	keys := make([]u64, 3 * len(m.triangles), heap)
	defer delete(keys, heap)
	for tri, f in m.triangles do for k in 0 ..< 3 do keys[3 * f + k] = edge_key(tri[k], tri[(k + 1) % 3])
	slice.sort(keys)
	edges := 0
	for key, i in keys do if i == 0 || key != keys[i - 1] do edges += 1
	return len(m.positions) - edges + len(m.triangles)
}

// A torus of nu by nv quads cut in two triangles each, wound outward.
@(private)
torus_island :: proc(nu, nv: int, big, small: f64) -> (m: Island) {
	heap := runtime.heap_allocator()
	m.positions = make([][3]f64, nu * nv, heap)
	m.triangles = make([][3]u32, 2 * nu * nv, heap)
	for i in 0 ..< nu do for j in 0 ..< nv {
		u := 2 * math.PI * f64(i) / f64(nu)
		v := 2 * math.PI * f64(j) / f64(nv)
		r := big + small * math.cos(v)
		m.positions[i * nv + j] = {r * math.cos(u), r * math.sin(u), small * math.sin(v)}
	}
	at :: proc(i, j, nu, nv: int) -> u32 {return u32((i % nu) * nv + j % nv)}
	for i in 0 ..< nu do for j in 0 ..< nv {
		a, b, c, d := at(i, j, nu, nv), at(i + 1, j, nu, nv), at(i + 1, j + 1, nu, nv), at(i, j + 1, nu, nv)
		m.triangles[2 * (i * nv + j)] = {a, b, c}
		m.triangles[2 * (i * nv + j) + 1] = {a, c, d}
	}
	return
}

// A cube of side 2 with each face an n by n grid, wound outward.
@(private)
cube_island :: proc(n: int) -> (m: Island) {
	heap := runtime.heap_allocator()
	positions := make([dynamic][3]f64, heap)
	triangles := make([dynamic][3]u32, heap)
	// Each axis's two faces: the normal axis and the two axes across it in the order that
	// winds the positive side outward (the negative side swaps them).
	faces := [3][3]int{{0, 1, 2}, {1, 2, 0}, {2, 0, 1}}
	for face in faces {
		for side in ([2]f64{1, -1}) {
			axis, u, v := face[0], face[1], face[2]
			if side < 0 do u, v = v, u
			first := u32(len(positions))
			for a in 0 ..= n do for b in 0 ..= n {
				p: [3]f64
				p[axis] = side
				p[u] = -1 + 2 * f64(a) / f64(n)
				p[v] = -1 + 2 * f64(b) / f64(n)
				append(&positions, p)
			}
			at :: proc(first: u32, a, b, n: int) -> u32 {return first + u32(a * (n + 1) + b)}
			for a in 0 ..< n do for b in 0 ..< n {
				append(&triangles, [3]u32{at(first, a, b, n), at(first, a + 1, b, n), at(first, a + 1, b + 1, n)})
				append(&triangles, [3]u32{at(first, a, b, n), at(first, a + 1, b + 1, n), at(first, a, b + 1, n)})
			}
		}
	}
	// The faces' grids share their border points: weld them.
	weld := make(map[[3]f64]u32, len(positions), heap)
	defer delete(weld)
	renumber := make([]u32, len(positions), heap)
	defer delete(renumber, heap)
	welded := make([dynamic][3]f64, heap)
	for p, i in positions {
		if w, ok := weld[p]; ok {
			renumber[i] = w
		} else {
			renumber[i] = u32(len(welded))
			weld[p] = renumber[i]
			append(&welded, p)
		}
	}
	for &t in triangles do t = {renumber[t[0]], renumber[t[1]], renumber[t[2]]}
	delete(positions)
	m.positions = welded[:]
	m.triangles = triangles[:]
	return
}

@(test)
isotropic_holds_on_smooth_shapes :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	edge := edge_for(sphere, 1500)
	c := isotropic_holds(t, "sphere", sphere, edge, 0, 90, {38, 0.09, true})
	testing.expectf(t, c.iso_open_edges == 0 && c.iso_euler == 2, "sphere: %s", checks_line(c))
	_ = isotropic_holds(t, "sphere at full adaptivity", sphere, edge, 1, 90, {38, 0.09, true})
	_ = isotropic_holds(t, "sphere, coarse", sphere, edge_for(sphere, 300), 0, 90, {38, 0.095, true})
	_ = isotropic_holds(t, "sphere, fine", sphere, edge_for(sphere, 6000), 0, 90, {38, 0.08, true})

	torus := torus_island(96, 48, 1, 0.4)
	defer island_destroy(&torus)
	c = isotropic_holds(t, "torus", torus, edge_for(torus, 1500), 0, 90, {34, 0.14, true})
	testing.expectf(t, c.iso_euler == 0, "torus: Euler characteristic %d", c.iso_euler)
}

// The density shortens the edges where it asks for more quads and rides the vertices as
// the quad size; the refinement shortens them alone.
@(test)
isotropic_follows_density_and_refinement :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	source := geom.icosphere(5)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	sphere.density = make([]f64, len(sphere.positions), heap)
	for p, v in sphere.positions do sphere.density[v] = 4 if p.z > 0 else 1
	edge := edge_for(sphere, 2000)
	_ = isotropic_holds(t, "density 4 above", sphere, edge, 0, 90, {35, 0.39, false})
	run := Stage_Run{}
	reason: Reason
	checks: Checks
	iso, err := odin_isotropic(sphere, edge, 0, 90, &run, &reason, &checks)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, err == .None && len(iso.vertex_scale) == len(iso.positions)) do return
	upper, lower, nu, nl := f64(0), f64(0), 0, 0
	for p, v in iso.positions {
		if p.z > 0.3 {
			upper += iso.vertex_scale[v]
			nu += 1
		} else if p.z < -0.3 {
			lower += iso.vertex_scale[v]
			nl += 1
		}
	}
	upper /= f64(max(nu, 1))
	lower /= f64(max(nl, 1))
	log.infof("density: quad size %.3f above and %.3f below", upper, lower)
	testing.expectf(t, abs(upper - 0.5) < 0.05 && abs(lower - 1) < 0.05, "the quad size is %.3f above and %.3f below, not a half and one", upper, lower)
	delete(sphere.density, heap)
	sphere.density = nil

	sphere.refine = make([]f64, len(sphere.positions), heap)
	for p, v in sphere.positions do sphere.refine[v] = 0.5 if p.z > 0 else 1
	_ = isotropic_holds(t, "refined above", sphere, edge, 0, 90, {35, 0.39, false})
}

// A hard-edged cube keeps its edges and corners (sharp by angle), every vertex stays on
// its faces, and the caller's features stay edges on their polyline.
@(test)
isotropic_keeps_hard_edges_and_features :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	cube := cube_island(30)
	defer island_destroy(&cube)
	edge := edge_for(cube, 600)
	_ = isotropic_holds(t, "cube", cube, edge, 0, 60, {18, 0.15, true})
	run := Stage_Run{}
	reason: Reason
	checks: Checks
	iso, err := odin_isotropic(cube, edge, 0, 60, &run, &reason, &checks)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, err == .None) do return
	off, corners := 0, 0
	for p in iso.positions {
		on := 0
		for k in 0 ..< 3 do if abs(abs(p[k]) - 1) < 1e-9 do on += 1
		if on == 0 do off += 1
		if on == 3 do corners += 1
	}
	testing.expectf(t, off == 0, "%d vertices left the cube's faces", off)
	testing.expectf(t, corners == 8, "%d of the cube's 8 corners are vertices", corners)

	// The caller's features: a ring round the cube at y = 0.
	ring := make([dynamic][2]u32, heap)
	for tri in cube.triangles do for k in 0 ..< 3 {
		a, b := tri[k], tri[(k + 1) % 3]
		if a < b && abs(cube.positions[a].y) < 1e-12 && abs(cube.positions[b].y) < 1e-12 do append(&ring, [2]u32{a, b})
	}
	cube.features = ring[:]
	iso2, err2 := odin_isotropic(cube, edge, 0, 60, &run, &reason, &checks)
	defer isotropic_destroy(&iso2)
	if !testing.expect(t, err2 == .None && len(iso2.corner_feature) == 3 * len(iso2.triangles)) do return
	flagged, strays := 0, 0
	for tri, f in iso2.triangles do for k in 0 ..< 3 {
		if iso2.corner_feature[3 * f + k] == 0 do continue
		flagged += 1
		a, b := iso2.positions[tri[k]], iso2.positions[tri[(k + 1) % 3]]
		// A flagged edge is on the ring or on a cube edge (sharp by angle).
		on_ring := abs(a.y) < 1e-9 && abs(b.y) < 1e-9
		hard :: proc(p, q: [3]f64) -> bool {
			for i in 0 ..< 3 do for j in i + 1 ..< 3 do if abs(abs(p[i]) - 1) < 1e-9 && abs(abs(p[j]) - 1) < 1e-9 && abs(abs(q[i]) - 1) < 1e-9 && abs(abs(q[j]) - 1) < 1e-9 do return true
			return false
		}
		if !on_ring && !hard(a, b) do strays += 1
	}
	log.infof("cube with a ring: %d flagged corners, %d off the ring and the hard edges", flagged, strays)
	testing.expectf(t, flagged > 0 && strays == 0, "%d flagged corners, %d of them off the ring and the cube's edges", flagged, strays)
}

// An open disc keeps its border on the circle and every vertex in its plane.
@(test)
isotropic_keeps_a_border :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	RINGS :: 24
	SEGMENTS :: 96
	disc: Island
	positions := make([dynamic][3]f64, heap)
	triangles := make([dynamic][3]u32, heap)
	append(&positions, [3]f64{0, 0, 0})
	for r in 1 ..= RINGS do for k in 0 ..< SEGMENTS {
		a := 2 * math.PI * f64(k) / SEGMENTS
		append(&positions, [3]f64{f64(r) / RINGS * math.cos(a), f64(r) / RINGS * math.sin(a), 0})
	}
	at :: proc(r, k: int) -> u32 {return 0 if r == 0 else u32(1 + (r - 1) * SEGMENTS + k % SEGMENTS)}
	for k in 0 ..< SEGMENTS do append(&triangles, [3]u32{0, at(1, k), at(1, k + 1)})
	for r in 1 ..< RINGS do for k in 0 ..< SEGMENTS {
		append(&triangles, [3]u32{at(r, k), at(r + 1, k), at(r + 1, k + 1)})
		append(&triangles, [3]u32{at(r, k), at(r + 1, k + 1), at(r, k + 1)})
	}
	disc.positions, disc.triangles = positions[:], triangles[:]
	defer island_destroy(&disc)
	edge := edge_for(disc, 400)
	c := isotropic_holds(t, "disc", disc, edge, 0, 90, {30, 0.165, true})
	testing.expectf(t, c.iso_open_edges > 0 && c.iso_euler == 1, "disc: %s", checks_line(c))
	run := Stage_Run{}
	reason: Reason
	checks: Checks
	iso, err := odin_isotropic(disc, edge, 0, 90, &run, &reason, &checks)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, err == .None) do return
	flat, off := 0, 0
	border := make([]bool, len(iso.positions), heap)
	defer delete(border, heap)
	keys := make([]u64, 3 * len(iso.triangles), heap)
	defer delete(keys, heap)
	for tri, f in iso.triangles do for k in 0 ..< 3 do keys[3 * f + k] = edge_key(tri[k], tri[(k + 1) % 3])
	slice.sort(keys)
	for i := 0; i < len(keys); {
		j := i + 1
		for j < len(keys) && keys[j] == keys[i] do j += 1
		if j - i == 1 do border[keys[i] >> 32], border[keys[i] & 0xffffffff] = true, true
		i = j
	}
	for p, v in iso.positions {
		if abs(p.z) > 1e-12 do flat += 1
		if border[v] && abs(math.sqrt(p.x * p.x + p.y * p.y) - 1) > 1e-9 do off += 1
	}
	testing.expectf(t, flat == 0 && off == 0, "%d vertices left the plane and %d border vertices the circle", flat, off)

	// An open cylinder of 96 long slivers, a column of two a side (the corpus's): the
	// splits must cut them across as well as along, and the cap must leave room for it.
	// AutoRemesher's remesher cut them into slivers, a quarter of its triangles under 30
	// degrees, and made more than the area asks for; the count is held to the area's, the
	// 2000 quads' 4000 triangles, give or take a fifth (the edges' band, 0.8 to 1.33
	// targets, lets a mesh settle a little coarse or fine).
	SIDES :: 48
	tube: Island
	tube_positions := make([dynamic][3]f64, heap)
	tube_triangles := make([dynamic][3]u32, heap)
	for s in 0 ..< 2 do for i in 0 ..< SIDES {
		a := 2 * math.PI * f64(i) / SIDES
		append(&tube_positions, [3]f64{0.5 * math.cos(a), f64(2 * s - 1), 0.5 * math.sin(a)})
	}
	for i in 0 ..< SIDES {
		j := (i + 1) % SIDES
		append(&tube_triangles, [3]u32{u32(i), u32(SIDES + j), u32(SIDES + i)}, [3]u32{u32(i), u32(j), u32(SIDES + j)})
	}
	tube.positions, tube.triangles = tube_positions[:], tube_triangles[:]
	defer island_destroy(&tube)
	c = isotropic_holds(t, "open cylinder of slivers", tube, edge_for(tube, 2000), 0, 90, {38, 0.07, true})
	testing.expectf(t, c.iso_capped == 0 && c.iso_euler == 0, "open cylinder: %s", checks_line(c))
	testing.expectf(t, c.iso_triangles > 3200 && c.iso_triangles < 4800, "open cylinder: %d triangles, the area asks for 4000", c.iso_triangles)
}

// Two spheres touching at one vertex (a pinch, which hung AutoRemesher's remesher before
// its unpinch step), damaged triangles (repeated, a vertex twice, slivers and no area) and a
// tiny piece: the stage splits or cuts them, never hangs, and leaves no edge of three
// triangles.
@(test)
isotropic_survives_pinches_and_damage :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	source := geom.icosphere(3)
	defer geom.mesh_destroy(&source)
	n := u32(len(source.positions))
	pinched: Island
	positions := make([dynamic][3]f64, heap)
	triangles := make([dynamic][3]u32, heap)
	for p in source.positions do append(&positions, [3]f64{f64(p.x), f64(p.y), f64(p.z)})
	// The second sphere, moved so its vertex 0 lands on the first's vertex 0, shares it.
	shift := [3]f64{2 * f64(source.positions[0].x), 2 * f64(source.positions[0].y), 2 * f64(source.positions[0].z)}
	for p in source.positions do append(&positions, [3]f64{-f64(p.x), -f64(p.y), -f64(p.z)} + shift)
	for f in 0 ..< len(source.indices) / 3 {
		tri := [3]u32{source.indices[3 * f], source.indices[3 * f + 1], source.indices[3 * f + 2]}
		append(&triangles, tri)
		// The mirror image through a point turns the winding inside out: put it back.
		other := [3]u32{tri[0] + n, tri[2] + n, tri[1] + n}
		for &v in other do if v == n do v = 0
		append(&triangles, other)
	}
	pinched.positions, pinched.triangles = positions[:], triangles[:]
	defer island_destroy(&pinched)
	edge := edge_for(pinched, 600)
	run := Stage_Run{}
	reason: Reason
	checks: Checks
	iso, err := odin_isotropic(pinched, edge, 0, 90, &run, &reason, &checks)
	defer isotropic_destroy(&iso)
	if !testing.expect(t, err == .None) do return
	checks_isotropic(&checks, iso)
	log.infof("pinch: %s", checks_line(checks))
	testing.expectf(t, checks.iso_split_fans == 1, "%d fans split, one expected", checks.iso_split_fans)
	testing.expectf(t, checks.iso_open_edges == 0 && checks.iso_nonmanifold == 0 && checks.iso_euler == 4, "pinch: %s", checks_line(checks))

	// The damage, on a sphere of its own.
	damaged: Island
	dpos := make([dynamic][3]f64, heap)
	dtri := make([dynamic][3]u32, heap)
	for p in source.positions do append(&dpos, [3]f64{f64(p.x), f64(p.y), f64(p.z)})
	for f in 0 ..< len(source.indices) / 3 do append(&dtri, [3]u32{source.indices[3 * f], source.indices[3 * f + 1], source.indices[3 * f + 2]})
	append(&dtri, dtri[0]) // a triangle twice: its edges have three or four triangles
	append(&dtri, [3]u32{dtri[5][0], dtri[5][0], dtri[5][1]}) // a vertex twice
	far := u32(len(dpos))
	append(&dpos, [3]f64{3, 0, 0}, [3]f64{4, 0, 0}, [3]f64{5, 0, 0}, [3]f64{3, 1e-9, 0}, [3]f64{3, 0, 1e-12})
	append(&dtri, [3]u32{far, far + 1, far + 2}) // no area
	append(&dtri, [3]u32{far, far + 3, far + 4}) // a tiny sliver of a piece
	append(&dtri, [3]u32{far, far + 1, far + 3})
	damaged.positions, damaged.triangles = dpos[:], dtri[:]
	defer island_destroy(&damaged)
	checks = {}
	iso2, err2 := odin_isotropic(damaged, edge_for(damaged, 400), 0, 90, &run, &reason, &checks)
	defer isotropic_destroy(&iso2)
	if !testing.expect(t, err2 == .None) do return
	checks_isotropic(&checks, iso2)
	log.infof("damage: %s", checks_line(checks))
	testing.expectf(t, checks.iso_torn_edges > 0 && checks.iso_dropped == 1, "%d torn edges and %d dropped triangles", checks.iso_torn_edges, checks.iso_dropped)
	testing.expectf(t, checks.iso_nonmanifold == 0, "%d non-manifold edges", checks.iso_nonmanifold)
}

// The pool changes nothing: one thread and four give the same mesh, bit for bit.
@(test)
isotropic_is_the_same_on_any_thread_count :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	source := geom.icosphere(5)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	sphere.density = make([]f64, len(sphere.positions), heap)
	for p, v in sphere.positions do sphere.density[v] = 2 if p.x > 0 else 1
	edge := edge_for(sphere, 2000)
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	reason: Reason
	checks: Checks
	one := Stage_Run{}
	four := Stage_Run{pool = &pool}
	a, err_a := odin_isotropic(sphere, edge, 1, 90, &one, &reason, &checks)
	defer isotropic_destroy(&a)
	b, err_b := odin_isotropic(sphere, edge, 1, 90, &four, &reason, &checks)
	defer isotropic_destroy(&b)
	if !testing.expect(t, err_a == .None && err_b == .None) do return
	same := len(a.positions) == len(b.positions) && len(a.triangles) == len(b.triangles)
	if same do for p, v in a.positions do if transmute([3]u64)p != transmute([3]u64)b.positions[v] do same = false
	if same do for tri, f in a.triangles do if tri != b.triangles[f] do same = false
	if same do for s, v in a.vertex_scale do if transmute(u64)s != transmute(u64)b.vertex_scale[v] do same = false
	testing.expectf(t, same, "one thread gave %d vertices and %d triangles, four %d and %d, or the bits differ", len(a.positions), len(a.triangles), len(b.positions), len(b.triangles))
}

// A cancel from the progress stops the stage.
@(test)
isotropic_stops_when_cancelled :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	calls := 0
	run := Stage_Run{progress = proc(tag: rawptr, fraction: f32) -> bool {
			n := cast(^int)tag
			n^ += 1
			return n^ < 3
		}, tag = &calls}
	reason: Reason
	checks: Checks
	iso, err := odin_isotropic(sphere, edge_for(sphere, 1500), 0, 90, &run, &reason, &checks)
	defer isotropic_destroy(&iso)
	testing.expectf(t, err == .Cancelled && calls == 3, "%v after %d reports", err, calls)
}

// A sphere of about 160,000 triangles down to 40,000 (the bench's 20,000 quads after the
// thinning), on four threads: the stage's time, which the log carries.
@(test)
isotropic_on_a_dense_sphere :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	source := geom.geodesic_sphere(90, &pool)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	_ = isotropic_holds(t, "dense sphere", sphere, edge_for(sphere, 20000), 0, 90, {38, 0.09, true}, &pool)
}

// Damaged meshes made at random from a few seeds: triangles added between random vertices
// (edges of three or more triangles, pinches), repeated and turned triangles, vertices
// moved onto one another, positions shaken, features between random vertices and a
// density from a quarter to two and a refinement from a half to one, at targets coarse
// to fine. The
// thinning and the isotropic remesh finish on every one (a hang would stop the run), with
// no edge of three triangles and every position finite.
@(test)
isotropic_survives_random_damage :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	rng := rand.create(11)
	context.random_generator = rand.default_random_generator(&rng)
	source := geom.icosphere(2)
	defer geom.mesh_destroy(&source)
	for round in 0 ..< 24 {
		m := island_of(source.positions[:], source.indices[:])
		defer island_destroy(&m)
		n := len(m.positions)
		triangles := make([dynamic][3]u32, 0, len(m.triangles) + 64, heap)
		for tri in m.triangles {
			switch rand.int_max(40) {
			case 0:
				// Turned over.
				append(&triangles, [3]u32{tri[0], tri[2], tri[1]})
			case 1:
				// Twice.
				append(&triangles, tri, tri)
			case 2:
				// Left out: a hole.
			case:
				append(&triangles, tri)
			}
		}
		for _ in 0 ..< rand.int_max(24) {
			append(&triangles, [3]u32{u32(rand.int_max(n)), u32(rand.int_max(n)), u32(rand.int_max(n))})
		}
		delete(m.triangles, heap)
		m.triangles = triangles[:]
		for _ in 0 ..< rand.int_max(16) do m.positions[rand.int_max(n)] = m.positions[rand.int_max(n)]
		shake := rand.float64_range(0, 0.05)
		for &p in m.positions do p += {rand.float64_range(-shake, shake), rand.float64_range(-shake, shake), rand.float64_range(-shake, shake)}
		features := make([dynamic][2]u32, heap)
		for _ in 0 ..< rand.int_max(40) do append(&features, [2]u32{u32(rand.int_max(n)), u32(rand.int_max(n))})
		// A run of the mesh's own edges too, so some features are kept.
		for tri in m.triangles[:rand.int_max(min(32, len(m.triangles)))] do append(&features, [2]u32{tri[0], tri[1]})
		m.features = features[:]
		if rand.int_max(2) == 0 {
			m.density = make([]f64, n, heap)
			for &d in m.density do d = rand.float64_range(0.25, 2)
		}
		if rand.int_max(3) == 0 {
			m.refine = make([]f64, n, heap)
			for &r in m.refine do r = rand.float64_range(0.5, 1)
		}
		counts := [3]int{60, 200, 600}
		angles := [3]f64{0, 45, 90}
		edge := edge_for(m, counts[rand.int_max(3)])
		sharp := angles[rand.int_max(3)]
		adaptivity := f64(rand.int_max(2))

		thin, _, thin_err := odin_thin(m, edge, 2 * edge, sharp, nil)
		defer island_destroy(&thin)
		if !testing.expectf(t, thin_err == .None, "round %d: the thinning failed: %v", round, thin_err) do continue
		run := Stage_Run{}
		reason: Reason
		checks: Checks
		iso, err := odin_isotropic(thin, edge, adaptivity, sharp, &run, &reason, &checks)
		defer isotropic_destroy(&iso)
		if !testing.expectf(t, err == .None, "round %d: %v %s", round, err, reason_string(&reason)) do continue
		checks_isotropic(&checks, iso)
		finite := true
		for p in iso.positions do for x in p do if !(abs(x) < 1e30) do finite = false
		testing.expectf(t, checks.iso_nonmanifold == 0 && finite, "round %d: %s, finite %v", round, checks_line(checks), finite)
	}
}
