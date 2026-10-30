package quadmesh

import "base:runtime"
import "core:c"
@(require) import "core:time" // used only where AVAILABLE

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

// Built on the desktops only for now: Android's and the iPad's builds do not compile the
// C++ yet, and the proc then refuses with .Unavailable (the Odin side compiles everywhere).
AVAILABLE :: (ODIN_OS == .Windows || ODIN_OS == .Linux || ODIN_OS == .Darwin) && ODIN_PLATFORM_SUBTARGET != .Android && ODIN_PLATFORM_SUBTARGET != .iPhone

// What a remesh is asked for.
Params :: struct {
	quads:         int, // wanted; the result lands within about a fifth under it at adaptivity 0
	adaptivity:    f32, // 0 quads of one size, 1 smaller quads where the surface bends (and far fewer than asked)
	sharp_degrees: f32, // an edge whose faces meet sharper than this is kept as an edge
	anisotropy:    f32, // 0 for AutoRemesher's own
	scaling:       f32, // 0 for AutoRemesher's own cell size from the count
	threads:       int, // threads the remesh may use, 1 to MAX_THREADS; the result is the same for any count
}

// AutoRemesher's own values, except adaptivity, whose 1 lands three times under the count.
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
	faces, quads, triangles, ngons: int, // ngons are polygons of five or more corners
	ms:                             f64,
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
	when AVAILABLE {
		start := time.tick_now()
		tag := Progress_Tag{progress, share}
		p := Qm_Params {
			quads         = u32(params.quads),
			adaptivity    = params.adaptivity,
			sharp_degrees = params.sharp_degrees,
			anisotropy    = params.anisotropy,
			scaling       = params.scaling,
			threads       = u32(clamp(params.threads, 1, MAX_THREADS)),
		}
		message := make([]u8, REASON_MAX, context.temp_allocator)
		result: ^Qm_Result
		code := qm_remesh(cast([^]f32)raw_data(positions), u32(len(positions)), raw_data(indices), u32(len(indices) / 3), &p, progress_c, &tag, &result, raw_data(message), c.size_t(len(message)))
		switch code {
		case QM_OK:
		case QM_CANCELLED:
			return {}, {}, .Cancelled, ""
		case:
			return {}, {}, .Failed, string(cstring(raw_data(message)))
		}
		defer qm_free(result)
		vertices, faces, corners: u32
		qm_counts(result, &vertices, &faces, &corners)
		out.positions = make([]geom.Vec3, vertices, allocator)
		out.first = make([]u32, faces + 1, allocator)
		out.corners = make([]u32, corners, allocator)
		qm_copy(result, cast([^]f32)raw_data(out.positions), raw_data(out.first), raw_data(out.corners))
		report.faces = int(faces)
		report.quads, report.triangles, report.ngons = polygon_share(out)
		report.ms = time.duration_milliseconds(time.tick_since(start))
		return out, report, .None, ""
	} else {
		return {}, {}, .Unavailable, "Quad Remesh is not built for this platform"
	}
}

// What the progress handler gets as its tag.
@(private = "file")
Progress_Tag :: struct {
	progress: ^jobs.Progress,
	share:    [2]f32,
}

// AutoRemesher's progress, from the remesh's own threads: 0 to 1 onto the caller's share,
// and the caller's cancel back as "stop".
@(private = "file")
progress_c :: proc "c" (tag: rawptr, fraction: f32, stage: cstring) -> c.int {
	context = runtime.default_context()
	t := (^Progress_Tag)(tag)
	jobs.progress_set(t.progress, t.share[0], t.share[1], fraction)
	return 0 if jobs.progress_cancelled(t.progress) else 1
}

// The C boundary, quadmesh_shim.h.
@(private = "file")
Qm_Params :: struct {
	quads:         u32,
	adaptivity:    f32,
	sharp_degrees: f32,
	anisotropy:    f32,
	scaling:       f32,
	threads:       u32,
}

@(private = "file")
Qm_Result :: struct {}

@(private = "file")
QM_OK :: 0
@(private = "file")
QM_CANCELLED :: 2

when AVAILABLE {
	when ODIN_OS == .Windows {
		// Built with /MT, as the app is.
		foreign import lib "../../deps/autoremesher/autoremesher.lib"
	} else when ODIN_OS == .Darwin {
		foreign import lib {"../../deps/autoremesher/libautoremesher.a", "system:c++"}
	} else {
		foreign import lib {"../../deps/autoremesher/libautoremesher.a", "system:stdc++", "system:m"}
	}

	@(default_calling_convention = "c")
	foreign lib {
		qm_remesh :: proc(positions: [^]f32, vertex_count: u32, triangles: [^]u32, triangle_count: u32, params: ^Qm_Params, progress: proc "c" (tag: rawptr, fraction: f32, stage: cstring) -> c.int, tag: rawptr, out: ^^Qm_Result, error: [^]u8, error_size: c.size_t) -> c.int ---
		qm_counts :: proc(r: ^Qm_Result, vertices, faces, corners: ^u32) ---
		qm_copy :: proc(r: ^Qm_Result, positions: [^]f32, first: [^]u32, corners: [^]u32) ---
		qm_free :: proc(r: ^Qm_Result) ---
	}
}
