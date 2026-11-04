package quadmesh

import "core:os"
import "core:time"

import "../geom"
import "../jobs"

// Quad remeshing through AutoRemesher's core (deps/autoremesher-src at AUTOREMESHER_COMMIT
// in scripts/versions.env, MIT; built with the app's C boundary quadmesh_shim.cpp by
// scripts/build_autoremesher.py): a triangle mesh in, a polygon mesh of nearly all quads
// out, following the surface's curvature as ZBrush's ZRemesher does. Knows nothing of the
// app, rendering or the interface; the caller validates what it sends (the remesh takes
// seconds and hundreds of megabytes on a million triangles, and never ends on some
// non-manifold input) and what it gets back (a few polygons may be triangles or pentagons,
// and an edge may come back non-manifold on thin parts).
//
// Two sides run the pipeline (Params.core): the boundary's qm_remesh whole (cpp.odin), or
// the Odin driver (driver.odin), which splits the mesh into islands, sizes and lands the
// quad count and gathers the quads itself and calls the boundary's stage calls for the
// rest, one at a time, checking what each gave (checks.odin) and writing it out when asked
// (dump.odin). The stages move to Odin one by one behind the same seams, each checked
// against the C++'s, which the driver matches byte for byte while every stage is the C++'s.

// Built on the desktops only for now: Android's and the iPad's builds do not compile the
// C++ yet, and the proc then refuses with .Unavailable (the Odin side compiles everywhere).
AVAILABLE :: (ODIN_OS == .Windows || ODIN_OS == .Linux || ODIN_OS == .Darwin) && ODIN_PLATFORM_SUBTARGET != .Android && ODIN_PLATFORM_SUBTARGET != .iPhone

// What a remesh is asked for.
Params :: struct {
	quads:         int, // wanted; the quad edge is sqrt(area / quads), so the count lands within a few percent at adaptivity 0
	adaptivity:    f32, // 0 quads of one size, 1 smaller quads where the surface bends and larger where it is flat, at the same count
	sharp_degrees: f32, // an edge whose faces meet sharper than this is kept as an edge
	anisotropy:    f32, // 0 for AutoRemesher's own
	scaling:       f32, // 0 for the quad edge from the count; else the quad edge as a multiple of the isotropic mesh's mean edge
	threads:       int, // threads the remesh may use, 1 to MAX_THREADS; the result is the same for any count
	// Feature edges, two vertex indices each: edges kept as quad edges whatever their
	// angle (a polygroup border, a crease), so the quads' edges run along them, as
	// ZRemesher's KeepGroups and KeepCreases do. Nil for none.
	features:      []u32,
	// Density per vertex (one per position, or nil): quads per area relative to the rest,
	// 1 as usual, 4 four times as many, 0.25 a quarter, clamped to 1/16..16 and taken
	// relative to its mean over the area, so the count stays what was asked, as
	// ZRemesher's Use PolyPaint moves its quads.
	density:       []f32,
	// Refinement per vertex (one per position, or nil): the isotropic mesh's edge there as
	// a share of what the quad size alone gives, 1 as usual, 0.5 twice as fine, clamped to
	// 0.25..1. The quads keep their size: a part only a few quads round (a thin tube) needs
	// the finer triangles under them for its quads to be extracted at all.
	refine:        []f32,
	// Guide curves, two points a segment, lying on or near the surface: the quads' edges
	// are pulled to run along them, by `guide_strength` (0 not at all, 1 as closely as
	// the field can follow), as ZRemesher's Curves and Curves Strength. Nil for none.
	guides:         []geom.Vec3,
	guide_strength: f32,
	// Keep symmetry's caps: the planes of `cap` the caller drops the polygons on after the
	// remesh. A triangle lying on one (every corner within `cap_snap`) counts for none of
	// the quads asked, which go to the rest. None by default.
	cap:      geom.Remesh_Mirror,
	cap_snap: f32,
	// Which side runs the pipeline: the C++ core whole, or the Odin driver a stage at a
	// time (driver.odin), with every stage the C++'s or with the stages ported so far in
	// Odin, each checked against the C++'s.
	core: Core,
	// A folder each stage's output is written to (dump.odin; the driver only), or "".
	dump: string,
}

// Who runs the pipeline (Params.core).
Core :: enum u8 {
	Cpp, // qm_remesh: AutoRemesher's stages as the C++ boundary drives them
	Driver, // the Odin driver with every stage the C++'s: qm_remesh's result bit for bit
	Odin, // the Odin driver with the stages ported so far in Odin (thinning, isotropic remesh, extraction), the rest the C++'s
}

CORE_NAMES := [Core]string {
	.Cpp    = "cpp",
	.Driver = "driver",
	.Odin   = "odin",
}

// What a result line says of who ran the pipeline: nothing for the C++ core.
CORE_LABELS := [Core]string {
	.Cpp    = "",
	.Driver = "through the Odin driver",
	.Odin   = "with the stages ported to Odin",
}

// AutoRemesher's own values.
DEFAULT_PARAMS :: Params{quads = 4000, adaptivity = 0, sharp_degrees = 90, threads = 1}

// The shim's parallel_for cuts a range into at most this many threads.
MAX_THREADS :: 16

// The polygons a remesh gives: polygon p's corners are corners[first[p]:first[p + 1]],
// counter-clockwise seen from outside, into `positions`.
Polygon_Mesh :: struct {
	positions: []geom.Vec3,
	first:     []u32,
	corners:   []u32,
}

Report :: struct {
	faces, quads, triangles, ngons:                        int, // ngons are polygons of five or more corners
	ms:                                                    f64,
	decimate_ms, isotropic_ms, parameterize_ms, extract_ms: f64, // the stages, summed over the islands (so over the threads)
	isotropic_triangles:                                    int, // the isotropic meshes' triangles, over the islands
	covers:                                                 int, // the quad covers solved, over the islands (up to three each)
	checks:                                                 Checks, // what each stage gave (the Odin driver only)
}

Error :: enum u8 {
	None,
	Unavailable, // not built on this platform
	Refused, // the input cannot be remeshed: `reason` says why
	Cancelled, // the progress was cancelled
	Failed, // AutoRemesher gave up: `reason` is its own message
}

// The longest reason the boundary passes back.
@(private)
REASON_MAX :: 256

polygon_mesh_destroy :: proc(m: ^Polygon_Mesh, allocator := context.allocator) {
	delete(m.positions, allocator)
	delete(m.first, allocator)
	delete(m.corners, allocator)
	m^ = {}
}

// How many of the polygons are quads, triangles and larger.
polygon_share :: proc(m: Polygon_Mesh) -> (quads, triangles, ngons: int) {
	for f in 0 ..< len(m.first) - 1 {
		switch m.first[f + 1] - m.first[f] {
		case 4: quads += 1
		case 3: triangles += 1
		case: ngons += 1
		}
	}
	return
}

// Remeshes the triangles `indices` (three a triangle) over `positions` into polygons made
// with `allocator`, moving `progress` from share[0] to share[1] of the way as it goes and
// stopping at its cancel. On any error the mesh is empty and `reason` (temp memory, "" for
// a cancel) says why. Refuses an empty mesh, a broken index and a zero count itself, so a
// mesh straight from a file is safe to send.
remesh :: proc(positions: []geom.Vec3, indices: []u32, params: Params, progress: ^jobs.Progress = nil, share := [2]f32{0, 1}, allocator := context.allocator) -> (out: Polygon_Mesh, report: Report, err: Error, reason: string) {
	if len(positions) == 0 || len(indices) < 3 do return {}, {}, .Refused, "the mesh is empty"
	if len(indices) % 3 != 0 do return {}, {}, .Refused, "the triangle list is not whole triangles"
	for i in indices do if int(i) >= len(positions) do return {}, {}, .Refused, "a triangle names a vertex the mesh does not have"
	if params.quads <= 0 do return {}, {}, .Refused, "no quads asked for"
	start := time.tick_now()
	times: Qm_Times
	switch params.core {
	case .Cpp:
		out, times, err, reason = cpp_remesh(positions, indices, params, progress, share, allocator)
	case .Driver, .Odin:
		if params.dump != "" do _ = os.make_directory_all(params.dump)
		out, times, report.checks, err, reason = driver_remesh(positions, indices, params, progress, share, allocator)
	}
	if err != .None do return {}, {}, err, reason
	report.faces = len(out.first) - 1
	report.quads, report.triangles, report.ngons = polygon_share(out)
	report.decimate_ms = f64(times.decimate_ms)
	report.isotropic_ms = f64(times.isotropic_ms)
	report.parameterize_ms = f64(times.parameterize_ms)
	report.extract_ms = f64(times.extract_ms)
	report.isotropic_triangles = int(times.isotropic_triangles)
	report.covers = int(times.covers)
	report.ms = time.duration_milliseconds(time.tick_since(start))
	return out, report, .None, ""
}
