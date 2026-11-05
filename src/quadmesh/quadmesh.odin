package quadmesh

import "core:os"
import "core:time"

import "../geom"
import "../jobs"

// Quad remeshing, AutoRemesher's pipeline ported to Odin (AutoRemesher by the Dust3D
// project, MIT, and its isotropic remesher, MIT: their notices are in assets/licenses): a
// triangle mesh in, a polygon mesh of quads out, following the surface's curvature as
// ZBrush's ZRemesher does. The driver (driver.odin) splits the mesh into islands, sizes and
// lands the quad count and gathers the quads; each island goes through the stages in turn,
// the thinning (thin.odin), the isotropic remesh (isotropic.odin), the frame field
// (field.odin), the quad cover (cover.odin) and the extraction (extract.odin), each checked
// as it hands on (checks.odin) and written out when asked (dump.odin). Knows nothing of the
// app, rendering or the interface; the caller validates what it sends (the remesh takes
// seconds and hundreds of megabytes on a million triangles) and what it gets back (an edge
// may come back open or non-manifold on thin parts, and a polygon may have other than four
// corners where the cover folds).

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
	// A folder each stage's output is written to (dump.odin), or "".
	dump:           string,
}

// AutoRemesher's own values.
DEFAULT_PARAMS :: Params{quads = 4000, adaptivity = 0, sharp_degrees = 90, threads = 1}

// The most threads a remesh takes: islands each on a thread of their own, or one island's
// stages' loops spread over them.
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
	covers:                                                 int, // the quad covers solved, over the islands (up to LANDING_COVERS each)
	checks:                                                 Checks, // what each stage gave
}

Error :: enum u8 {
	None,
	Refused, // the input cannot be remeshed: `reason` says why
	Cancelled, // the progress was cancelled
	Failed, // the remesh gave up: `reason` says why
}

// The longest reason a stage keeps.
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
	if params.dump != "" do _ = os.make_directory_all(params.dump)
	times: Times
	out, times, report.checks, err, reason = driver_remesh(positions, indices, params, progress, share, allocator)
	if err != .None do return {}, {}, err, reason
	report.faces = len(out.first) - 1
	report.quads, report.triangles, report.ngons = polygon_share(out)
	report.decimate_ms = times.decimate_ms
	report.isotropic_ms = times.isotropic_ms
	report.parameterize_ms = times.parameterize_ms
	report.extract_ms = times.extract_ms
	report.isotropic_triangles = times.isotropic_triangles
	report.covers = times.covers
	report.ms = time.duration_milliseconds(time.tick_since(start))
	return out, report, .None, ""
}

// The stages' times, summed over the islands, and what they made.
@(private)
Times :: struct {
	decimate_ms, isotropic_ms, parameterize_ms, extract_ms: f64,
	isotropic_triangles, covers:                            int,
}
