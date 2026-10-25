package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

import "../geom"
import "../jobs"
import "../render"
import "../sculpt"

// --compute-bench: the GPU compute trial's numbers. On a rough sphere at each size, times
// Smooth all's steps on every CPU core and as a compute shader, the GPU's upload,
// dispatches and readback each waited for, and checks the GPU's result against the CPU's.
// "Cold" uploads the triangles and lookup with the positions, as a press of Smooth all
// does now; "warm" keeps them on the GPU from the run before, so only positions and
// weights travel, as they would if the mesh lived on the GPU between commands. Undo
// saving and the normals afterwards are the same either way and are left out.

COMPUTEBENCH_STEPS :: [?]int{1, 10}
COMPUTEBENCH_RUNS :: 3 // timed runs per case; the fastest counts
// How far the sphere's vertices are pushed in and out, so smoothing has work to do.
COMPUTEBENCH_ROUGHNESS :: 0.01
// The weight of each step where the sphere is not masked (below y = -0.5 is, to cover
// the shader's skip).
COMPUTEBENCH_WEIGHT :: 0.5

@(private = "file")
Computebench_Gpu :: struct {
	timing: render.Smooth_Timing,
	ok:     bool,
}

@(private = "file")
Computebench_Row :: struct {
	vertices: int,
	steps:    int,
	cpu_ms:   f64,
	cold:     render.Smooth_Timing,
	warm:     render.Smooth_Timing,
	max_diff: f32, // largest coordinate difference between the GPU's result and the CPU's
	moved:    f32, // largest coordinate the CPU moved, for scale
	ok:       bool,
}

computebench_run :: proc(app: ^App, path: string, vertices: int) -> bool {
	// Not temp memory: each size frees the temp allocator when it is done.
	sizes := make([dynamic]int)
	defer delete(sizes)
	if vertices > 0 {
		append(&sizes, vertices)
	} else {
		all := GPUBENCH_SIZES
		append(&sizes, ..all[:])
	}
	if !render.smooth_compute_init(&app.renderer, &app.smooth_gpu) do return false
	rows := make([dynamic]Computebench_Row)
	defer delete(rows)
	all_ok := true
	for size in sizes {
		mesh := geom.geodesic_sphere(geom.geodesic_frequency_for(size), &app.pool)
		defer geom.mesh_destroy(&mesh)
		geom.mesh_sort_vertices_spatially(&mesh)
		for &p, v in mesh.positions {
			// A fixed hash of the index: the same bumps every run.
			h := u32(v) * 2654435761
			h ~= h >> 15
			p *= 1 + COMPUTEBENCH_ROUGHNESS * (f32(h & 0xffff) / 0xffff - 0.5)
		}
		faces := geom.vertex_faces_build(mesh, &app.pool)
		defer geom.vertex_faces_destroy(&faces)
		weights := make([]f32, len(mesh.positions))
		defer delete(weights)
		for p, v in mesh.positions do weights[v] = COMPUTEBENCH_WEIGHT if p.y > -0.5 else 0
		base := mesh.positions[:]
		cpu := make([]geom.Vec3, len(base))
		defer delete(cpu)
		gpu := make([]geom.Vec3, len(base))
		defer delete(gpu)
		log.infof("compute bench: %d vertices, %d triangles", len(base), len(mesh.indices) / 3)

		for steps in COMPUTEBENCH_STEPS {
			row := Computebench_Row{vertices = len(base), steps = steps, cpu_ms = math.F64_MAX, ok = true}
			for _ in 0 ..< COMPUTEBENCH_RUNS {
				copy(cpu, base)
				start := time.tick_now()
				sculpt.smooth_all_cpu(&app.pool, cpu, mesh.indices[:], faces, weights, steps)
				row.cpu_ms = min(row.cpu_ms, time.duration_milliseconds(time.tick_since(start)))
			}
			gpu_case :: proc(app: ^App, gpu, base: []geom.Vec3, mesh: geom.Mesh, faces: geom.Vertex_Faces, weights: []f32, steps: int, key: u64) -> (best: render.Smooth_Timing, ok: bool) {
				// One run first, untimed, so buffer creation and a resident topology are in place.
				copy(gpu, base)
				if _, ok = render.smooth_compute_run(&app.renderer, &app.smooth_gpu, gpu, mesh.indices[:], faces.offsets, faces.tris, weights, steps, key); !ok do return
				for run in 0 ..< COMPUTEBENCH_RUNS {
					copy(gpu, base)
					t: render.Smooth_Timing
					t, ok = render.smooth_compute_run(&app.renderer, &app.smooth_gpu, gpu, mesh.indices[:], faces.offsets, faces.tris, weights, steps, key)
					if !ok do return
					if run == 0 || render.smooth_timing_total(t) < render.smooth_timing_total(best) do best = t
				}
				return best, true
			}
			ok: bool
			row.cold, ok = gpu_case(app, gpu, base, mesh, faces, weights, steps, 0)
			row.ok = row.ok && ok
			row.warm, ok = gpu_case(app, gpu, base, mesh, faces, weights, steps, u64(len(base)))
			row.ok = row.ok && ok
			for v in 0 ..< len(base) {
				for k in 0 ..< 3 {
					row.max_diff = max(row.max_diff, abs(gpu[v][k] - cpu[v][k]))
					row.moved = max(row.moved, abs(cpu[v][k] - base[v][k]))
				}
			}
			if !row.ok do all_ok = false
			log.infof("compute bench: %d vertices, %d steps: CPU %.1f ms, GPU cold %.1f ms, warm %.1f ms, max diff %g",
				row.vertices, steps, row.cpu_ms, render.smooth_timing_total(row.cold), render.smooth_timing_total(row.warm), row.max_diff)
			append(&rows, row)
		}
		free_all(context.temp_allocator)
	}
	return computebench_write(app, path, rows[:]) && all_ok
}

@(private = "file")
computebench_write :: proc(app: ^App, path: string, rows: []Computebench_Row) -> bool {
	sb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&sb)
	fmt.sbprintf(&sb, "## GPU compute trial: Smooth all\n\n")
	fmt.sbprintf(&sb, "- GPU: %s\n", render.gpu_description(&app.renderer))
	fmt.sbprintf(&sb, "- CPU: %d threads (`--threads`).\n", jobs.pool_size(&app.pool))
	fmt.sbprintf(&sb, "- A rough sphere, the part above y = -0.5 (three quarters) free to move with weight %.1f a step, the rest masked. Fastest of %d runs; times in ms.\n",
		COMPUTEBENCH_WEIGHT, COMPUTEBENCH_RUNS)
	fmt.sbprintf(&sb, "- GPU parts each include waiting for the GPU: upload (fill the transfer buffer, copy to the GPU) / compute (one dispatch a step) / readback (copy back, into the CPU mesh).\n")
	fmt.sbprintf(&sb, "- Cold uploads triangles and lookup too, as a Smooth all press does today; warm reuses them, as a GPU-resident mesh would.\n")
	fmt.sbprintf(&sb, "- Max diff is the largest coordinate difference between the GPU's result and the CPU's (the sphere's radius is 1).\n\n")
	fmt.sbprintf(&sb, "| Vertices | Steps | CPU | GPU cold | cold parts | cold MB | GPU warm | warm parts | warm MB | GPU compute / step | Warm vs CPU | Max diff |\n")
	fmt.sbprintf(&sb, "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n")
	for r in rows {
		if !r.ok {
			fmt.sbprintf(&sb, "| %s | %d | %.1f | failed | | | | | | | | |\n", size_label(r.vertices), r.steps, r.cpu_ms)
			continue
		}
		cold, warm := render.smooth_timing_total(r.cold), render.smooth_timing_total(r.warm)
		fmt.sbprintf(&sb, "| %s | %d | %.1f | %.1f | %.1f / %.1f / %.1f | %.0f | %.1f | %.1f / %.1f / %.1f | %.0f | %.2f | %.1fx | %.2g |\n",
			size_label(r.vertices), r.steps, r.cpu_ms,
			cold, r.cold.upload_ms, r.cold.compute_ms, r.cold.readback_ms, r.cold.upload_mb,
			warm, r.warm.upload_ms, r.warm.compute_ms, r.warm.readback_ms, r.warm.upload_mb,
			r.warm.compute_ms / f64(r.steps), r.cpu_ms / warm, r.max_diff)
	}
	report := strings.to_string(sb)
	fmt.print(report)
	if err := os.write_entire_file(path, transmute([]u8)report); err != nil {
		log.errorf("compute bench: could not write %s: %v", path, err)
		return false
	}
	log.infof("compute bench: wrote %s", path)
	return true
}
