package render

import "../gpu"
import "core:log"
import "core:math"
import "core:math/linalg"


// The ray query check, run when the device is made under --gpu-debug where Gpu_Caps.ray_query
// is true: a bottom level over a fixture of two triangles (an opaque geometry and one that
// is not), a top level of two instances of it (one moved and scaled), and rays whose
// answers were worked out by hand: the distance along the unnormalised ray, the instance's
// number, the geometry, the triangle within it and the barycentrics, closest hits and hits
// from behind. It then moves the vertices, refits the bottom level and rebuilds the top one
// in place, and traces again. A wrong answer counts as a validation error, so smoke and
// parity_check.py fail on it. Under the own Metal backend, where nothing here has run it on
// a device, it also runs once before the first kernel traces (ray_query_trusted).

Ray_Query_Check :: enum u8 {
	Not_Run,
	Passed,
	Failed,
}

RAY_QUERY_CHECK_COMP_CODE :: #load("shaders/ray_query_check.comp" + RQ_EXT, string)

@(private = "file")
Rq_Ray :: struct {
	origin, direction: [3]f32,
	// What it hits in each round (before and after the vertices move up by 1): t is -1 for
	// a miss.
	t:                 [2]f32,
	instance:          u32,
	geometry:          u32,
	primitive:         u32,
	bary:              [2]f32,
}

// Instance A is the fixture where it is (number 7); B is it scaled by 2 and moved 4 down
// (number 300000, which needs more than 16 bits). The fixture is the square from (-1, -1)
// to (1, 1) at z = 0: triangle 0 (corners 0, 1, 2, below the diagonal) is geometry 0,
// opaque; triangle 1 (corners 0, 2, 3) is geometry 1, not opaque.
@(private = "file")
RQ_RAYS := [?]Rq_Ray {
	{origin = {0.5, -0.5, 5}, direction = {0, 0, -1}, t = {5, 4}, instance = 7, geometry = 0, primitive = 0, bary = {0.5, 0.25}},
	{origin = {-0.5, 0.5, 5}, direction = {0, 0, -1}, t = {5, 4}, instance = 7, geometry = 1, primitive = 0, bary = {0.25, 0.5}},
	// Past A's edge, onto B.
	{origin = {1.5, -1, 5}, direction = {0, 0, -1}, t = {9, 7}, instance = 300000, geometry = 0, primitive = 0, bary = {0.625, 0.25}},
	// Away from both.
	{origin = {0, 0, 5}, direction = {0, 0, 1}, t = {-1, -1}},
	// t is the parameter of the ray as given, not a distance.
	{origin = {0.5, -0.5, 5}, direction = {0, 0, -2}, t = {2.5, 2}, instance = 7, geometry = 0, primitive = 0, bary = {0.5, 0.25}},
	// From below: B's back face first, then A's.
	{origin = {0.5, -0.5, -10}, direction = {0, 0, 1}, t = {6, 8}, instance = 300000, geometry = 0, primitive = 0, bary = {0.25, 0.375}},
}

@(private = "file")
RQ_INDICES := [6]u32{0, 1, 2, 0, 2, 3}

// Runs the check and logs what it found.
ray_query_check :: proc(r: ^Renderer) -> Ray_Query_Check {
	if !r.caps.ray_query do return .Not_Run
	ok := ray_query_check_run(r)
	if ok {
		log.info("ray query check: passed")
	} else {
		gpu.validation_error("ray query check: failed; the studio and render mode walk the app's own trees")
	}
	return .Passed if ok else .Failed
}

// Whether ray queries may trace. Under the own Metal backend, whose ray tracing has not been
// run on a device from here, the check runs once first (it waits for the GPU, before the
// first traced kernel is made), and a wrong answer keeps every view on the app's own trees.
ray_query_trusted :: proc(r: ^Renderer) -> bool {
	when gpu.METAL do if r.ray_query_check == .Not_Run do r.ray_query_check = ray_query_check(r)
	return r.ray_query_check != .Failed
}

@(private = "file")
ray_query_check_run :: proc(r: ^Renderer) -> bool {
	RAYS :: len(RQ_RAYS)
	positions := gpu.create_buffer({usage = {.Vertex}, size = 4 * 12}, accel_input = true)
	indices := gpu.create_buffer({usage = {.Index}, size = size_of(RQ_INDICES)}, accel_input = true)
	rays := gpu.create_buffer({usage = {.Storage_Read}, size = RAYS * 32})
	hits := gpu.create_buffer({usage = {.Storage_Write}, size = RAYS * 32})
	download := gpu.create_transfer_buffer({usage = .Download, size = RAYS * 32})
	pipeline := gpu.create_compute_pipeline_traced({
		code = RAY_QUERY_CHECK_COMP_CODE, entrypoint = RQ_ENTRY,
		format = SHADER_FORMAT, num_readonly_storage_buffers = 1, num_readwrite_storage_buffers = 1, num_uniform_buffers = 1,
		threadcount_x = 64, threadcount_y = 1, threadcount_z = 1,
	})
	blas, tlas: ^gpu.Gpu_Accel
	defer {
		gpu.release_accel(tlas)
		gpu.release_accel(blas)
		gpu.release_compute_pipeline(pipeline)
		gpu.release_transfer_buffer(download)
		gpu.release_buffer(hits)
		gpu.release_buffer(rays)
		gpu.release_buffer(indices)
		gpu.release_buffer(positions)
	}
	if positions == 0 || indices == 0 || rays == 0 || hits == 0 || download == 0 || pipeline == 0 {
		log.errorf("ray query check: its buffers or kernel could not be made (%s)", gpu.last_error())
		return false
	}
	geometries := [2]gpu.Blas_Geometry{{first_triangle = 0, triangle_count = 1, opaque = true}, {first_triangle = 1, triangle_count = 1, opaque = false}}
	for round in 0 ..< 2 {
		// The first round fills everything; the second moves the vertices up by 1.
		z := f32(round)
		corners := [4][3]f32{{-1, -1, z}, {1, -1, z}, {1, 1, z}, {-1, 1, z}}
		indices_data := RQ_INDICES
		ray_words: [2 * RAYS][4]f32
		for ray, i in RQ_RAYS {
			ray_words[2 * i] = {ray.origin.x, ray.origin.y, ray.origin.z, 0}
			ray_words[2 * i + 1] = {ray.direction.x, ray.direction.y, ray.direction.z, 0}
		}
		cmd := gpu.acquire_command_buffer()
		if cmd == nil do return false
		if !gpu.upload(cmd, positions, 0, ([^]u8)(&corners)[:4 * 12]) || !gpu.upload(cmd, indices, 0, ([^]u8)(&indices_data)[:size_of(RQ_INDICES)]) || !gpu.upload(cmd, rays, 0, ([^]u8)(&ray_words)[:RAYS * 32]) {
			_ = gpu.cancel_command_buffer(cmd)
			return false
		}
		new_blas := gpu.build_blas(cmd, positions, indices, 4, geometries[:], blas)
		if round == 1 && new_blas != blas {
			log.error("ray query check: the refit made a new bottom level")
			if new_blas != nil do gpu.release_accel(new_blas)
			_, _ = gpu.submit(cmd)
			return false
		}
		blas = new_blas
		instances := [2]gpu.Tlas_Instance {
			{blas = blas, transform = 1, custom = 7},
			{blas = blas, transform = linalg.matrix4_translate_f32({0, 0, -4}) * linalg.matrix4_scale_f32({2, 2, 2}), custom = 300000},
		}
		new_tlas: ^gpu.Gpu_Accel
		if blas != nil do new_tlas = gpu.build_tlas(cmd, instances[:], tlas)
		if round == 1 && new_tlas != tlas {
			log.error("ray query check: the top level was not rebuilt in place")
			if new_tlas != nil do gpu.release_accel(new_tlas)
			_, _ = gpu.submit(cmd)
			return false
		}
		tlas = new_tlas
		if tlas == nil {
			log.error("ray query check: the acceleration structures could not be built")
			_, _ = gpu.submit(cmd)
			return false
		}
		write := gpu.Storage_Buffer_Binding{buffer = hits}
		pass := gpu.begin_compute_pass(cmd, nil, 0, &write, 1)
		gpu.bind_compute_pipeline(pass, pipeline)
		gpu.bind_compute_storage_buffers(pass, 0, &rays, 1)
		gpu.bind_compute_accel(pass, tlas)
		count := u32(RAYS)
		gpu.push_compute_uniform_data(cmd, 0, &count, size_of(count))
		gpu.dispatch_compute(pass, 1, 1, 1)
		gpu.end_compute_pass(pass)
		copy_pass := gpu.begin_copy_pass(cmd)
		gpu.download_from_buffer(copy_pass, {buffer = hits, size = RAYS * 32}, {transfer_buffer = download})
		gpu.end_copy_pass(copy_pass)
		ticket, submitted := gpu.submit(cmd)
		if !submitted || !gpu.wait(ticket) do return false
		got := ([^][4]f32)(gpu.map_transfer_buffer(download, false))
		if got == nil do return false
		ok := true
		for ray, i in RQ_RAYS {
			hit, bary := got[2 * i], got[2 * i + 1]
			want_t := ray.t[round]
			close :: proc(a, b: f32) -> bool {return math.abs(a - b) <= 1e-4 * max(1, math.abs(b))}
			right := close(hit[0], want_t)
			if want_t >= 0 do right = right && u32(hit[1]) == ray.instance && u32(hit[2]) == ray.primitive && u32(hit[3]) == ray.geometry && close(bary[0], ray.bary[0]) && close(bary[1], ray.bary[1])
			if !right {
				log.errorf("ray query check: round %d ray %d hit t=%v instance=%v primitive=%v geometry=%v barycentrics=%v, not t=%v instance=%v primitive=%v geometry=%v barycentrics=%v", round, i, hit[0], hit[1], hit[2], hit[3], bary.xy, want_t, ray.instance, ray.primitive, ray.geometry, ray.bary)
				ok = false
			}
		}
		gpu.unmap_transfer_buffer(download)
		if !ok do return false
	}
	return true
}
