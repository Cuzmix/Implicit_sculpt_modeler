package quadmesh

import "core:log"
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
	testing.expectf(t, report.quads >= 1000 && report.quads <= 1600, "%d quads for 1500 asked", report.quads)
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
