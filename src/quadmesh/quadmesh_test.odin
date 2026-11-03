package quadmesh

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:thread"
import "core:time"

import "../geom"
import "../jobs"

@(private = "file")
sphere_remesh :: proc(t: ^testing.T, threads: int, progress: ^jobs.Progress = nil) -> (out: Polygon_Mesh, report: Report, err: Error, reason: string) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	params := DEFAULT_PARAMS
	params.quads, params.threads = 1500, threads
	return remesh(source.positions[:], source.indices[:], params, progress)
}

// A sphere remeshed to 1500 quads comes back as quads only but for a few polygons, closed
// and consistently wound facing out, nearly every vertex with four polygons round it,
// every vertex on the sphere: what sets the engine apart from the retopology it replaces.
@(test)
sphere_becomes_regular_quads :: proc(t: ^testing.T) {
	when !AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	out, report, err, reason := sphere_remesh(t, 4)
	defer polygon_mesh_destroy(&out)
	if !testing.expectf(t, err == .None, "remesh failed: %v %s", err, reason) do return
	log.infof("sphere: %d faces (%d quads, %d triangles, %d n-gons), %d vertices in %.0f ms", report.faces, report.quads, report.triangles, report.ngons, len(out.positions), report.ms)
	testing.expectf(t, report.quads >= 1425 && report.quads <= 1575, "%d quads for 1500 asked", report.quads)
	testing.expectf(t, f32(report.quads) >= 0.99 * f32(report.faces), "only %d of %d polygons are quads", report.quads, report.faces)
	uses := make(map[u64]int, 4 * report.faces, context.temp_allocator)
	valence := make([]int, len(out.positions), context.temp_allocator)
	for f in 0 ..< report.faces {
		c := out.corners[out.first[f]:out.first[f + 1]]
		centre, normal: geom.Vec3
		for v, k in c {
			uses[u64(v) << 32 | u64(c[(k + 1) % len(c)])] += 1
			valence[v] += 1
			centre += out.positions[v] / f32(len(c))
			normal += linalg.cross(out.positions[v], out.positions[c[(k + 1) % len(c)]])
		}
		testing.expect(t, linalg.dot(normal, centre) > 0, "a polygon faces in")
	}
	for key, count in uses {
		back := (key & 0xffff_ffff) << 32 | key >> 32
		testing.expect(t, count == 1 && uses[back] == 1, "an edge is open or used twice the same way")
	}
	regular := 0
	for n in valence do if n == 4 do regular += 1
	testing.expectf(t, f32(regular) >= 0.95 * f32(len(valence)), "only %d of %d vertices are regular", regular, len(valence))
	far: f32
	for p in out.positions do far = max(far, abs(linalg.length(p) - 1))
	testing.expectf(t, far < 0.02, "a vertex is %v off the sphere", far)
}

// The same input gives the same polygons on one thread and on four.
@(test)
threads_do_not_change_the_result :: proc(t: ^testing.T) {
	when !AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	one, _, err1, _ := sphere_remesh(t, 1)
	defer polygon_mesh_destroy(&one)
	four, _, err4, _ := sphere_remesh(t, 4)
	defer polygon_mesh_destroy(&four)
	if !testing.expect(t, err1 == .None && err4 == .None) do return
	same := len(one.positions) == len(four.positions) && len(one.first) == len(four.first) && len(one.corners) == len(four.corners)
	if same do for p, i in one.positions do if p != four.positions[i] do same = false
	if same do for c, i in one.corners do if c != four.corners[i] do same = false
	if same do for f, i in one.first do if f != four.first[i] do same = false
	testing.expect(t, same, "one thread and four give different polygons")
}

// Two spheres in one mesh are two islands, which the remesh runs on its own threads when
// given them: the polygons of each island come back in the same order, bit for bit, on one
// thread and on four, and the count lands over the two islands together.
@(test)
islands_do_not_change_the_result :: proc(t: ^testing.T) {
	when !AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	two_spheres :: proc(threads: int) -> (out: Polygon_Mesh, report: Report, err: Error, reason: string) {
		source := geom.icosphere(3)
		defer geom.mesh_destroy(&source)
		n := len(source.positions)
		positions := make([]geom.Vec3, 2 * n, context.temp_allocator)
		indices := make([]u32, 2 * len(source.indices), context.temp_allocator)
		for p, i in source.positions {
			positions[i] = p + {-1.5, 0, 0}
			positions[n + i] = 0.6 * p + {1.5, 0, 0}
		}
		for v, i in source.indices {
			indices[i] = v
			indices[len(source.indices) + i] = v + u32(n)
		}
		params := DEFAULT_PARAMS
		params.quads, params.threads = 1000, threads
		return remesh(positions, indices, params)
	}
	one, report, err1, reason := two_spheres(1)
	defer polygon_mesh_destroy(&one)
	if !testing.expectf(t, err1 == .None, "remesh failed: %v %s", err1, reason) do return
	log.infof("two spheres: %d faces (%d quads) in %.0f ms", report.faces, report.quads, report.ms)
	testing.expectf(t, report.quads >= 900 && report.quads <= 1100, "%d quads for 1000 asked over two islands", report.quads)
	four, _, err4, _ := two_spheres(4)
	defer polygon_mesh_destroy(&four)
	if !testing.expect(t, err4 == .None) do return
	same := len(one.positions) == len(four.positions) && len(one.first) == len(four.first) && len(one.corners) == len(four.corners)
	if same do for p, i in one.positions do if p != four.positions[i] do same = false
	if same do for c, i in one.corners do if c != four.corners[i] do same = false
	if same do for f, i in one.first do if f != four.first[i] do same = false
	testing.expect(t, same, "one thread and four give different polygons over two islands")
}

// A sphere of rings and segments whose top is one polygroup and the rest another, with
// the ring between them given as feature edges, comes back with a closed loop of quad
// edges along that ring: every output edge whose ends lie on the ring, and each vertex of
// that loop has two of them. The count still lands.
@(test)
feature_edges_become_a_loop :: proc(t: ^testing.T) {
	when !AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	RINGS :: 32
	SEGMENTS :: 64
	source: geom.Mesh
	defer geom.mesh_destroy(&source)
	append(&source.positions, geom.Vec3{0, 0, 1})
	for r in 1 ..< RINGS {
		phi := math.PI * f32(r) / RINGS
		for k in 0 ..< SEGMENTS {
			theta := 2 * math.PI * f32(k) / SEGMENTS
			append(&source.positions, geom.Vec3{math.sin(phi) * math.cos(theta), math.sin(phi) * math.sin(theta), math.cos(phi)})
		}
	}
	append(&source.positions, geom.Vec3{0, 0, -1})
	at := proc(r, k: int) -> u32 {return u32(1 + (r - 1) * SEGMENTS + k % SEGMENTS)}
	for k in 0 ..< SEGMENTS do append(&source.indices, 0, at(1, k), at(1, k + 1))
	for r in 1 ..< RINGS - 1 do for k in 0 ..< SEGMENTS {
		append(&source.indices, at(r, k), at(r + 1, k), at(r + 1, k + 1))
		append(&source.indices, at(r, k), at(r + 1, k + 1), at(r, k + 1))
	}
	last := u32(len(source.positions) - 1)
	for k in 0 ..< SEGMENTS do append(&source.indices, last, at(RINGS - 1, k + 1), at(RINGS - 1, k))
	// The border: ring 10's edges (at z = cos(10π/32), about 0.56).
	BORDER :: 10
	features := make([dynamic]u32, context.temp_allocator)
	for k in 0 ..< SEGMENTS do append(&features, at(BORDER, k), at(BORDER, k + 1))
	params := DEFAULT_PARAMS
	params.quads, params.threads, params.features = 1500, 4, features[:]
	out, report, err, reason := remesh(source.positions[:], source.indices[:], params)
	defer polygon_mesh_destroy(&out)
	if !testing.expectf(t, err == .None, "remesh failed: %v %s", err, reason) do return
	testing.expectf(t, report.quads >= 1350 && report.quads <= 1650, "%d quads for 1500 asked", report.quads)
	// A point on the ring: within a hundredth (the chords between remeshed ring vertices
	// sag that far at most from the ring's own 64 chords) of its polyline.
	z := math.cos(math.PI * f32(BORDER) / RINGS)
	on := make([]bool, len(out.positions), context.temp_allocator)
	for p, v in out.positions {
		best := f32(1e9)
		for k in 0 ..< SEGMENTS {
			a, b := source.positions[at(BORDER, k)], source.positions[at(BORDER, k + 1)]
			d := b - a
			s := clamp(linalg.dot(p - a, d) / max(linalg.dot(d, d), 1e-12), 0, 1)
			best = min(best, linalg.length(p - (a + d * s)))
		}
		on[v] = best < 0.01
	}
	loop_edges := make(map[u64]bool, 4 * report.faces, context.temp_allocator)
	degree := make([]int, len(out.positions), context.temp_allocator)
	for f in 0 ..< report.faces {
		c := out.corners[out.first[f]:out.first[f + 1]]
		for v, k in c {
			w := c[(k + 1) % len(c)]
			if !on[v] || !on[w] do continue
			key := u64(min(v, w)) << 32 | u64(max(v, w))
			if key in loop_edges do continue
			loop_edges[key] = true
			degree[v] += 1
			degree[w] += 1
		}
	}
	ring := 0
	broken := 0
	for d, v in degree do if on[v] {
		ring += 1
		if d != 2 do broken += 1
	}
	// The ring is 2π·sin(10π/32) long, about 5.2, so about 57 quad edges at the edge
	// 1500 quads give; a loop needs most of them.
	expected := int(2 * math.PI * math.sqrt(1 - z * z) / math.sqrt(f32(4 * math.PI / 1500)))
	log.infof("feature loop: %d quad edges on the ring (about %d expected), %d vertices on it, %d not of degree two, %d quads in %.0f ms", len(loop_edges), expected, ring, broken, report.quads, report.ms)
	testing.expectf(t, len(loop_edges) >= expected * 3 / 4, "only %d quad edges lie on the ring, about %d expected", len(loop_edges), expected)
	testing.expectf(t, broken == 0, "%d ring vertices do not have two ring edges", broken)
}

// A sphere asking four times the density on its upper half gets about four times the quads
// per area there, and one asking a quarter about a quarter, all quads, and the count still
// lands: Use paint's red, and its blue, against plain clay.
@(test)
density_moves_the_quads :: proc(t: ^testing.T) {
	when !AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	source := geom.icosphere(5)
	defer geom.mesh_destroy(&source)
	density := make([]f32, len(source.positions), context.temp_allocator)
	for upper_density in ([2]f32{4, 0.25}) {
		for p, v in source.positions do density[v] = upper_density if p.z > 0 else 1
		params := DEFAULT_PARAMS
		params.quads, params.threads, params.density = 2000, 4, density
		out, report, err, reason := remesh(source.positions[:], source.indices[:], params)
		defer polygon_mesh_destroy(&out)
		if !testing.expectf(t, err == .None, "remesh failed: %v %s", err, reason) do return
		upper, lower: int
		for f in 0 ..< report.faces {
			c := out.corners[out.first[f]:out.first[f + 1]]
			z: f32
			for v in c do z += out.positions[v].z / f32(len(c))
			if z > 0 do upper += 1
			else do lower += 1
		}
		// The halves have the same area, so the ratio of their counts is the ratio per area.
		ratio := f32(upper) / f32(max(lower, 1))
		log.infof("density %.2f above: %d faces (%d quads, %d triangles, %d n-gons), %d upper and %d lower, %.2f times, in %.0f ms", upper_density, report.faces, report.quads, report.triangles, report.ngons, upper, lower, ratio, report.ms)
		testing.expectf(t, report.faces >= 1900 && report.faces <= 2100, "%d faces for 2000 asked", report.faces)
		testing.expectf(t, ratio >= 0.75 * upper_density && ratio <= 1.25 * upper_density, "the half asked %.2f times as dense has %.2f times the quads", upper_density, ratio)
		testing.expectf(t, f32(report.quads) >= 0.99 * f32(report.faces), "only %d of %d polygons are quads", report.quads, report.faces)
	}
}

// An empty mesh, a broken index and a zero count are refused with a reason before anything
// runs, whatever the platform.
@(test)
bad_input_is_refused :: proc(t: ^testing.T) {
	positions := [3]geom.Vec3{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}
	indices := [3]u32{0, 1, 2}
	params := DEFAULT_PARAMS
	_, _, err, reason := remesh(nil, nil, params)
	testing.expect(t, err == .Refused && reason != "", "an empty mesh was taken")
	broken := [3]u32{0, 1, 7}
	_, _, err, reason = remesh(positions[:], broken[:], params)
	testing.expect(t, err == .Refused && reason != "", "a broken index was taken")
	params.quads = 0
	_, _, err, reason = remesh(positions[:], indices[:], params)
	testing.expect(t, err == .Refused && reason != "", "a zero count was taken")
}

// A cancel at the first progress report stops the remesh early, with nothing made. The
// cancelled remesh runs on a thread of its own: the shim cancels by throwing a C++ exception,
// which on Windows the test runner's vectored handler takes for a crash on any thread it set
// up, before the shim's catch can see it.
@(test)
cancel_stops_the_remesh :: proc(t: ^testing.T) {
	when !AVAILABLE {
		log.info("quadmesh is not built on this platform")
		return
	}
	full, whole, _, _ := sphere_remesh(t, 4)
	polygon_mesh_destroy(&full)
	Cancelled_Run :: struct {
		t:        ^testing.T,
		progress: jobs.Progress,
		out:      Polygon_Mesh,
		err:      Error,
		took:     f64,
	}
	run := Cancelled_Run{t = t}
	jobs.progress_cancel(&run.progress)
	worker := thread.create_and_start_with_data(&run, proc(data: rawptr) {
		r := (^Cancelled_Run)(data)
		start := time.tick_now()
		r.out, _, r.err, _ = sphere_remesh(r.t, 4, &r.progress)
		r.took = time.duration_milliseconds(time.tick_since(start))
	}, context)
	thread.destroy(worker)
	testing.expectf(t, run.err == .Cancelled, "a cancelled remesh ended %v", run.err)
	testing.expect(t, len(run.out.positions) == 0 && len(run.out.first) == 0, "a cancelled remesh made polygons")
	testing.expectf(t, run.took < whole.ms / 2, "the cancel took %.0f ms of a %.0f ms remesh", run.took, whole.ms)
}
