package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"

import "../camera"
import "../geom"
import "../render"

// --gpubench: on one sphere at each size, times the GPU work of the 3D viewport and the
// CPU work of the whole frame while the camera orbits and while a brush stroke runs,
// with the speed settings on and off, then writes the results as markdown tables.
// Runs with vsync off where the display allows it, and with GPU timing on.

GPUBENCH_SIZES :: [?]int{500_000, 1_000_000, 5_000_000, 7_000_000, 10_000_000}
GPUBENCH_WARMUP :: 30 // frames run before each case is measured
GPUBENCH_FRAMES :: 120 // default measured frames per case

Gpubench_Case :: struct {
	label:    string,
	stroke:   bool, // drag the brush back and forth across the sphere; otherwise orbit it once
	cull:     bool,
	partial:  bool,
	simplify: bool,
}

// How far the stroke moves each frame, as a share of the brush radius: two dabs a
// frame at the usual spacing, like a fast real stroke.
GPUBENCH_STROKE_STEP :: 2 * DAB_SPACING

@(rodata)
gpubench_cases := [?]Gpubench_Case {
	{"Orbit", false, true, true, true},
	{"Orbit, no simplify", false, true, true, false},
	{"Orbit, no culling", false, false, true, false},
	// Strokes keep the camera still, so they draw at full detail either way; with
	// simplify off they skip the one full redraw that ends simplified drawing.
	{"Stroke", true, true, true, false},
	{"Stroke, no partial redraw", true, true, false, false},
	{"Stroke, neither", true, false, false, false},
}

Gpubench_Cell :: struct {
	gpu_p50, gpu_p99: f32,
	cpu_p50, cpu_p99: f32,
	triangles:        f32, // drawn per frame, p50
	samples:          int, // measured frames (in stroke cases, only those that sculpted)
}

Gpubench_Row :: struct {
	vertices: int, // as built; geodesic spheres come in fixed steps
	cells:    [len(gpubench_cases)]Gpubench_Cell,
}

Gpubench :: struct {
	path:   string,
	sizes:  [dynamic]int,
	frames: int, // measured frames per case
	size:   int, // index into sizes
	kase:   int, // index into gpubench_cases
	frame:  int, // frames run in the current case, warm-up included
	gpu:    Sample_Ring, // the current case's measured frames
	cpu:    Sample_Ring,
	tris:   Sample_Ring,
	rows:   [dynamic]Gpubench_Row,
	done:   bool,
}

// One size (`vertices`) or all of GPUBENCH_SIZES (vertices = 0).
gpubench_init :: proc(b: ^Gpubench, path: string, vertices, frames: int) {
	b.path = path
	if vertices > 0 {
		append(&b.sizes, vertices)
	} else {
		sizes := GPUBENCH_SIZES
		append(&b.sizes, ..sizes[:])
	}
	b.frames = clamp(frames if frames > 0 else GPUBENCH_FRAMES, 1, HISTORY)
}

gpubench_destroy :: proc(b: ^Gpubench) {
	delete(b.sizes)
	delete(b.rows)
	b^ = {}
}

// Sets the app up for this frame of the current case and returns its input.
gpubench_input :: proc(app: ^App, b: ^Gpubench, size: [2]f32) -> Viewport_Input {
	c := gpubench_cases[b.kase]
	app.renderer.cull = c.cull
	app.renderer.partial = c.partial
	app.simplify = c.simplify
	app.lod_finish = true // every copy is built before a case measures anything
	app.tool = .Brush
	app.scene.selected = 0
	app.camera = camera.orbit_default()
	if c.stroke {
		// Back and forth across the middle of the sphere at a steady speed, with a wave.
		center, radius := first_object_on_screen(app, size)
		width := 1.2 * radius
		along := f32(b.frame) * GPUBENCH_STROKE_STEP * app.brush.radius_px
		x := math.mod(along, 2 * width)
		if x > width do x = 2 * width - x
		y := 0.3 * radius * math.sin(math.PI * along / width)
		return bench_drag(size, center + {x - width / 2, y})
	}
	camera.orbit_spin(&app.camera, 2 * math.PI * f32(b.frame) / f32(GPUBENCH_WARMUP + b.frames))
	return {size = size}
}

// Called at the end of each frame with its GPU time, CPU time and dab count. Moves on
// to the next case, and the next size, as each one finishes. Returns true once every
// case has run. Stroke cases only count frames that sculpted.
gpubench_end_frame :: proc(app: ^App, b: ^Gpubench, gpu_ms, cpu_ms: f64, dabs: int) -> bool {
	c := gpubench_cases[b.kase]
	if b.frame >= GPUBENCH_WARMUP && (!c.stroke || dabs > 0) {
		ring_push(&b.gpu, gpu_ms)
		ring_push(&b.cpu, cpu_ms)
		ring_push(&b.tris, f64(app.stats.viewport.triangles))
	}
	b.frame += 1
	if b.frame < GPUBENCH_WARMUP + b.frames do return false

	if b.kase == 0 {
		append(&b.rows, Gpubench_Row{vertices = geom.mesh_vertex_count(object_mesh(app.scene.objects[0])^)})
	}
	row := &b.rows[len(b.rows) - 1]
	cell := &row.cells[b.kase]
	cell.gpu_p50, cell.gpu_p99 = ring_percentiles(b.gpu)
	cell.cpu_p50, cell.cpu_p99 = ring_percentiles(b.cpu)
	cell.triangles, _ = ring_percentiles(b.tris)
	cell.samples = b.gpu.count
	b.gpu, b.cpu, b.tris = {}, {}, {}
	log.infof("gpubench: %d vertices, %s: GPU p50 %.2f ms, CPU p50 %.2f ms over %d frames",
		row.vertices, c.label, cell.gpu_p50, cell.cpu_p50, cell.samples)
	if c.stroke {
		// Take the stroke back, so every stroke case sculpts the same surface.
		stroke_finish(app)
		history_undo(app)
	}

	b.frame = 0
	b.kase += 1
	if b.kase < len(gpubench_cases) do return false
	b.kase = 0
	b.size += 1
	if b.size < len(b.sizes) {
		app.ui.scene_command = {kind = .Remesh, vertices = b.sizes[b.size]}
		return false
	}
	b.done = true
	return true
}

// Writes the tables to b.path and prints them.
gpubench_write :: proc(app: ^App, b: ^Gpubench) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	present: string
	switch app.renderer.present_mode {
	case .VSYNC:
		present = "vsync (the display offers no other mode)"
	case .MAILBOX:
		present = "mailbox (vsync off)"
	case .IMMEDIATE:
		present = "immediate (vsync off)"
	}
	fmt.sbprintf(&sb, "## GPU benchmark\n\n")
	fmt.sbprintf(&sb, "- GPU: %s\n", render.gpu_description(&app.renderer))
	fmt.sbprintf(&sb, "- Viewport: %d x %d px. Present mode: %s. Anti-aliasing: %s.\n", app.target.width, app.target.height, present, MSAA_NAMES[app.msaa])
	fmt.sbprintf(&sb, "- One sphere per size. Each case runs %d warm-up frames, then measures %d frames. ", GPUBENCH_WARMUP, b.frames)
	fmt.sbprintf(&sb, "Orbit turns the camera once around the sphere. Stroke drags the Draw brush (%.0f px) back and forth across it, ", app.brush.radius_px)
	fmt.sbprintf(&sb, "%.0f px a frame, and counts only frames that sculpted.\n", GPUBENCH_STROKE_STEP * app.brush.radius_px)
	fmt.sbprintf(&sb, "- Times in ms, p50 / p99. GPU is the 3D viewport's uploads and drawing; CPU is the whole frame minus waits.\n")
	fmt.sbprintf(&sb, "- Simplify draws far chunks from simplified copies (at most %.2f px off) while the view moves; every copy is built before the cases run.\n", app.simplify_px)

	Table :: enum {
		Gpu,
		Cpu,
		Triangles,
	}
	table :: proc(sb: ^strings.Builder, title: string, rows: []Gpubench_Row, kind: Table) {
		fmt.sbprintf(sb, "\n### %s\n\n| Vertices |", title)
		for c in gpubench_cases do fmt.sbprintf(sb, " %s |", c.label)
		fmt.sbprintf(sb, "\n| ---: |")
		for _ in gpubench_cases do fmt.sbprintf(sb, " ---: |")
		fmt.sbprintf(sb, "\n")
		for row in rows {
			fmt.sbprintf(sb, "| %s |", size_label(row.vertices))
			for cell in row.cells {
				p50, p99 := cell.cpu_p50, cell.cpu_p99
				if kind == .Gpu do p50, p99 = cell.gpu_p50, cell.gpu_p99
				switch {
				case cell.samples == 0:
					fmt.sbprintf(sb, " n/a |")
				case kind == .Triangles:
					fmt.sbprintf(sb, " %s |", size_label(int(cell.triangles)))
				case:
					fmt.sbprintf(sb, " %.2f / %.2f |", p50, p99)
				}
			}
			fmt.sbprintf(sb, "\n")
		}
	}
	table(&sb, "GPU time of the 3D viewport", b.rows[:], .Gpu)
	table(&sb, "CPU time per frame", b.rows[:], .Cpu)
	table(&sb, "Triangles drawn per frame (p50; strokes mostly redraw only around the brush)", b.rows[:], .Triangles)

	report := strings.to_string(sb)
	fmt.print(report)
	if err := os.write_entire_file(b.path, transmute([]u8)report); err != nil {
		log.errorf("gpubench: could not write %s: %v", b.path, err)
		return false
	}
	log.infof("gpubench: wrote %s", b.path)
	return true
}

// 500k, 1.0M, 10.0M and so on, from the vertex count as built.
size_label :: proc(n: int) -> string {
	if n >= 1_000_000 do return fmt.tprintf("%.1fM", f64(n) / 1e6)
	if n >= 1_000 do return fmt.tprintf("%dk", (n + 500) / 1000)
	return fmt.tprintf("%d", n)
}
