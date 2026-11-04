package quadmesh

import "base:runtime"
import "core:c"

import "../geom"
import "../jobs"

// The C++ core through its C boundary (quadmesh_shim.h): qm_remesh, the whole pipeline in
// C++ (Core.Cpp), and its stages one call at a time, which the Odin driver runs
// (driver.odin). Every array crossing is copied, so the C++ keeps nothing of the caller's
// and the caller nothing of the C++'s.

// The whole remesh in C++, as Quad Remesh ran it before the driver existed: the reference
// the driver is checked against.
@(private)
cpp_remesh :: proc(positions: []geom.Vec3, indices: []u32, params: Params, progress: ^jobs.Progress, share: [2]f32, allocator: runtime.Allocator) -> (out: Polygon_Mesh, times: Qm_Times, err: Error, reason: string) {
	when AVAILABLE {
		tag := Progress_Tag{progress, share}
		p := Qm_Params {
			quads          = u32(params.quads),
			adaptivity     = params.adaptivity,
			sharp_degrees  = params.sharp_degrees,
			anisotropy     = params.anisotropy,
			scaling        = params.scaling,
			threads        = u32(clamp(params.threads, 1, MAX_THREADS)),
			features       = raw_data(params.features) if len(params.features) >= 2 else nil,
			feature_count  = u32(len(params.features) / 2),
			density        = raw_data(params.density) if len(params.density) == len(positions) else nil,
			density_count  = u32(len(params.density)) if len(params.density) == len(positions) else 0,
			refine         = raw_data(params.refine) if len(params.refine) == len(positions) else nil,
			refine_count   = u32(len(params.refine)) if len(params.refine) == len(positions) else 0,
			guides         = ([^]f32)(raw_data(params.guides)),
			guide_count    = u32(len(params.guides) / 2),
			guide_strength = params.guide_strength,
			cap_axes       = cap_axes(params.cap),
			cap_center     = params.cap.center,
			cap_snap       = params.cap_snap,
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
		qm_times(result, &times)
		return out, times, .None, ""
	} else {
		return {}, {}, .Unavailable, "Quad Remesh is not built for this platform"
	}
}

// Keep symmetry's cap planes as qm_remesh takes them: bit a for the plane square to axis a.
@(private)
cap_axes :: proc(m: geom.Remesh_Mirror) -> u32 {
	return u32(m.axes[0]) | u32(m.axes[1]) << 1 | u32(m.axes[2]) << 2
}

// The first stage in C++ (qm_stage_thin): feature chains under two quad edges dropped, an
// island far denser than its target decimated by meshoptimizer, pinched vertices split.
cpp_thin :: proc(island: Island, voxel_size, quad_edge, sharp_degrees: f64, reason: ^Reason) -> (out: Island, decimated: bool, added: int, err: Stage_Error) {
	when AVAILABLE {
		m := qm_mesh(island.positions, island.triangles)
		m.features = cast([^]u32)raw_data(island.features)
		m.feature_count = u32(len(island.features))
		m.density = raw_data(island.density) if len(island.density) == len(island.positions) else nil
		m.refine = raw_data(island.refine) if len(island.refine) == len(island.positions) else nil
		stage: ^Qm_Stage
		if err = stage_code(qm_stage_thin(&m, voxel_size, quad_edge, sharp_degrees, &stage, raw_data(reason.text[:]), REASON_MAX)); err != .None do return
		defer qm_stage_free(stage)
		v: Qm_Stage_View
		qm_stage_view(stage, &v)
		out.positions = copy_out([3]f64, v.positions, v.vertex_count)
		out.triangles = copy_out([3]u32, v.triangles, v.triangle_count)
		out.features = copy_out([2]u32, v.features, v.feature_count)
		if v.density != nil do out.density = copy_out(f64, v.density, v.vertex_count)
		if v.refine != nil do out.refine = copy_out(f64, v.refine, v.vertex_count)
		return out, v.decimated != 0, int(v.added), .None
	} else {
		return {}, false, 0, .Unavailable
	}
}

// The isotropic remesh in C++ (qm_stage_isotropic), with Adaptivity's target lengths, the
// density's edge factor and the refinement; its feature edges come back as corner flags.
cpp_isotropic :: proc(island: Island, voxel_size, adaptivity, sharp_degrees: f64, run: ^Stage_Run, reason: ^Reason) -> (out: Isotropic, err: Stage_Error) {
	when AVAILABLE {
		m := qm_mesh(island.positions, island.triangles)
		m.features = cast([^]u32)raw_data(island.features)
		m.feature_count = u32(len(island.features))
		m.density = raw_data(island.density) if len(island.density) == len(island.positions) else nil
		m.refine = raw_data(island.refine) if len(island.refine) == len(island.positions) else nil
		r := qm_run(run)
		stage: ^Qm_Stage
		if err = stage_code(qm_stage_isotropic(&m, voxel_size, adaptivity, sharp_degrees, &r, &stage, raw_data(reason.text[:]), REASON_MAX)); err != .None do return
		defer qm_stage_free(stage)
		v: Qm_Stage_View
		qm_stage_view(stage, &v)
		out.positions = copy_out([3]f64, v.positions, v.vertex_count)
		out.triangles = copy_out([3]u32, v.triangles, v.triangle_count)
		if v.vertex_scale != nil do out.vertex_scale = copy_out(f64, v.vertex_scale, v.vertex_count)
		if v.corner_feature != nil do out.corner_feature = copy_out(u8, v.corner_feature, 3 * v.triangle_count)
		out.mean_edge = v.mean_edge
		return out, .None
	} else {
		return {}, .Unavailable
	}
}

// The guide curves (two points a segment) as a direction per isotropic triangle, times
// its weight, in C++ (qm_stage_face_guides); nil when no guide comes near.
cpp_face_guides :: proc(iso: Isotropic, quad_edge: f64, guides: []geom.Vec3, strength: f32, reason: ^Reason) -> (out: [][3]f64, err: Stage_Error) {
	when AVAILABLE {
		m := qm_mesh(iso.positions, iso.triangles)
		m.vertex_scale = raw_data(iso.vertex_scale) if len(iso.vertex_scale) == len(iso.positions) else nil
		stage: ^Qm_Stage
		if err = stage_code(qm_stage_face_guides(&m, quad_edge, ([^]f32)(raw_data(guides)), u32(len(guides) / 2), strength, &stage, raw_data(reason.text[:]), REASON_MAX)); err != .None do return
		defer qm_stage_free(stage)
		v: Qm_Stage_View
		qm_stage_view(stage, &v)
		if v.face_guides != nil do out = copy_out([3]f64, v.face_guides, u32(len(iso.triangles)))
		return out, .None
	} else {
		return nil, .Unavailable
	}
}

// One quad cover at `scaling` in C++ (qm_stage_cover): the frame field, the singularity
// simplification and the cover. Failed with an empty reason when the core gave up without
// one of its own (qm_console_line then has its line).
cpp_cover :: proc(iso: Isotropic, face_guides: [][3]f64, scaling, adaptivity, anisotropy, sharp_degrees: f64, run: ^Stage_Run, reason: ^Reason) -> (out: Cover, err: Stage_Error) {
	when AVAILABLE {
		m := qm_mesh(iso.positions, iso.triangles)
		m.vertex_scale = raw_data(iso.vertex_scale) if len(iso.vertex_scale) == len(iso.positions) else nil
		m.corner_feature = raw_data(iso.corner_feature) if len(iso.corner_feature) == 3 * len(iso.triangles) else nil
		m.face_guides = cast([^]f64)raw_data(face_guides) if len(face_guides) == len(iso.triangles) else nil
		r := qm_run(run)
		stage: ^Qm_Stage
		if err = stage_code(qm_stage_cover(&m, scaling, adaptivity, anisotropy, sharp_degrees, &r, &stage, raw_data(reason.text[:]), REASON_MAX)); err != .None do return
		defer qm_stage_free(stage)
		v: Qm_Stage_View
		qm_stage_view(stage, &v)
		out.uvs = copy_out([3][2]f64, v.uvs, u32(len(iso.triangles)) if v.uvs != nil else 0)
		out.singular = copy_out(u32, v.singular, v.singular_count)
		return out, .None
	} else {
		return {}, .Unavailable
	}
}

// The quads traced from a cover in C++ (qm_stage_extract): none when the extractor gave none.
cpp_extract :: proc(iso: Isotropic, cover: Cover, run: ^Stage_Run, reason: ^Reason) -> (out: Quads, err: Stage_Error) {
	when AVAILABLE {
		m := qm_mesh(iso.positions, iso.triangles)
		m.corner_feature = raw_data(iso.corner_feature) if len(iso.corner_feature) == 3 * len(iso.triangles) else nil
		m.uvs = cast([^]f64)raw_data(cover.uvs)
		m.singular = raw_data(cover.singular)
		m.singular_count = u32(len(cover.singular))
		r := qm_run(run)
		stage: ^Qm_Stage
		if err = stage_code(qm_stage_extract(&m, &r, &stage, raw_data(reason.text[:]), REASON_MAX)); err != .None do return
		defer qm_stage_free(stage)
		v: Qm_Stage_View
		qm_stage_view(stage, &v)
		if v.face_count == 0 do return {}, .None
		out.positions = copy_out([3]f64, v.positions, v.vertex_count)
		out.first = copy_out(u32, v.first, v.face_count + 1)
		out.corners = copy_out(u32, v.corners, v.first[v.face_count])
		return out, .None
	} else {
		return {}, .Unavailable
	}
}

// The last whole line the C++ core wrote to its console, the reason it gave for giving up.
cpp_console_line :: proc(reason: ^Reason) {
	when AVAILABLE {
		qm_console_line(raw_data(reason.text[:]), REASON_MAX)
	} else {
		reason.text[0] = 0
	}
}

// `n` elements from the C++'s memory into a slice of the heap's.
@(private = "file")
copy_out :: proc($T: typeid, from: rawptr, n: u32) -> []T {
	if n == 0 || from == nil do return nil
	out := make([]T, n, runtime.heap_allocator())
	runtime.mem_copy_non_overlapping(raw_data(out), from, int(n) * size_of(T))
	return out
}

@(private = "file")
stage_code :: proc(code: c.int) -> Stage_Error {
	switch code {
	case QM_OK: return .None
	case QM_CANCELLED: return .Cancelled
	case QM_OUT_OF_MEMORY: return .Out_Of_Memory
	}
	return .Failed
}

@(private = "file")
qm_mesh :: proc(positions: [][3]f64, triangles: [][3]u32) -> Qm_Mesh {
	return {positions = cast([^]f64)raw_data(positions), vertex_count = u32(len(positions)), triangles = cast([^]u32)raw_data(triangles), triangle_count = u32(len(triangles))}
}

@(private = "file")
qm_run :: proc(run: ^Stage_Run) -> Qm_Stage_Run {
	if run == nil do return {threads = 1}
	return {threads = u32(clamp(run.threads, 1, MAX_THREADS)), serial = 1 if run.serial else 0, progress = stage_progress_c if run.progress != nil else nil, tag = run}
}

// A stage's progress from the C++'s threads, onto the run's own proc; its false cancels.
@(private = "file")
stage_progress_c :: proc "c" (tag: rawptr, fraction: f32, stage: cstring) -> c.int {
	context = runtime.default_context()
	run := (^Stage_Run)(tag)
	return 1 if run.progress(run.tag, fraction) else 0
}

// What qm_remesh's progress handler gets as its tag.
@(private = "file")
Progress_Tag :: struct {
	progress: ^jobs.Progress,
	share:    [2]f32,
}

// qm_remesh's progress, from the remesh's own threads: 0 to 1 onto the caller's share, and
// the caller's cancel back as "stop".
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
	quads:          u32,
	adaptivity:     f32,
	sharp_degrees:  f32,
	anisotropy:     f32,
	scaling:        f32,
	threads:        u32,
	features:       [^]u32,
	feature_count:  u32,
	density:        [^]f32,
	density_count:  u32,
	refine:         [^]f32,
	refine_count:   u32,
	guides:         [^]f32,
	guide_count:    u32,
	guide_strength: f32,
	cap_axes:       u32,
	cap_center:     [3]f32,
	cap_snap:       f32,
}

@(private = "file")
Qm_Result :: struct {}

@(private)
Qm_Times :: struct {
	decimate_ms, isotropic_ms, parameterize_ms, extract_ms, total_ms: f32,
	isotropic_triangles, covers:                                      u32,
}

@(private = "file")
Qm_Stage :: struct {}

@(private = "file")
Qm_Progress_C :: proc "c" (tag: rawptr, fraction: f32, stage: cstring) -> c.int

@(private = "file")
Qm_Stage_Run :: struct {
	threads:  u32,
	serial:   c.int,
	progress: Qm_Progress_C,
	tag:      rawptr,
}

@(private = "file")
Qm_Mesh :: struct {
	positions:      [^]f64,
	vertex_count:   u32,
	triangles:      [^]u32,
	triangle_count: u32,
	features:       [^]u32,
	feature_count:  u32,
	density:        [^]f64,
	refine:         [^]f64,
	vertex_scale:   [^]f64,
	corner_feature: [^]u8,
	face_guides:    [^]f64,
	uvs:            [^]f64,
	singular:       [^]u32,
	singular_count: u32,
}

@(private = "file")
Qm_Stage_View :: struct {
	positions:      [^]f64,
	vertex_count:   u32,
	triangles:      [^]u32,
	triangle_count: u32,
	features:       [^]u32,
	feature_count:  u32,
	density:        [^]f64,
	refine:         [^]f64,
	vertex_scale:   [^]f64,
	corner_feature: [^]u8,
	mean_edge:      f64,
	face_guides:    [^]f64,
	uvs:            [^]f64,
	singular:       [^]u32,
	singular_count: u32,
	first:          [^]u32,
	corners:        [^]u32,
	face_count:     u32,
	added:          u32,
	decimated:      c.int,
}

@(private = "file")
QM_OK :: 0
@(private = "file")
QM_CANCELLED :: 2
@(private = "file")
QM_OUT_OF_MEMORY :: 3

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
		qm_remesh :: proc(positions: [^]f32, vertex_count: u32, triangles: [^]u32, triangle_count: u32, params: ^Qm_Params, progress: Qm_Progress_C, tag: rawptr, out: ^^Qm_Result, error: [^]u8, error_size: c.size_t) -> c.int ---
		qm_counts :: proc(r: ^Qm_Result, vertices, faces, corners: ^u32) ---
		qm_copy :: proc(r: ^Qm_Result, positions: [^]f32, first: [^]u32, corners: [^]u32) ---
		qm_times :: proc(r: ^Qm_Result, times: ^Qm_Times) ---
		qm_free :: proc(r: ^Qm_Result) ---
		qm_stage_thin :: proc(mesh: ^Qm_Mesh, voxel_size, quad_edge, sharp_degrees: f64, out: ^^Qm_Stage, error: [^]u8, error_size: c.size_t) -> c.int ---
		qm_stage_isotropic :: proc(mesh: ^Qm_Mesh, voxel_size, adaptivity, sharp_degrees: f64, run: ^Qm_Stage_Run, out: ^^Qm_Stage, error: [^]u8, error_size: c.size_t) -> c.int ---
		qm_stage_face_guides :: proc(mesh: ^Qm_Mesh, quad_edge: f64, guides: [^]f32, guide_count: u32, guide_strength: f32, out: ^^Qm_Stage, error: [^]u8, error_size: c.size_t) -> c.int ---
		qm_stage_cover :: proc(mesh: ^Qm_Mesh, scaling, adaptivity, anisotropy, sharp_degrees: f64, run: ^Qm_Stage_Run, out: ^^Qm_Stage, error: [^]u8, error_size: c.size_t) -> c.int ---
		qm_stage_extract :: proc(mesh: ^Qm_Mesh, run: ^Qm_Stage_Run, out: ^^Qm_Stage, error: [^]u8, error_size: c.size_t) -> c.int ---
		qm_stage_view :: proc(stage: ^Qm_Stage, view: ^Qm_Stage_View) ---
		qm_stage_free :: proc(stage: ^Qm_Stage) ---
		qm_console_line :: proc(text: [^]u8, size: c.size_t) ---
	}
}
