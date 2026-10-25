package bench

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"

// --brushes: at each size, the same stroke as the main table with the large brush, once
// per brush kind, plus Draw with X symmetry, Draw over a half-masked sphere and Draw
// with the Noise alpha (whose square reaches past the round brush). Grab
// picks up the brush area at the first point and is dragged along the rest of the
// path, one move per frame as the app does. Each stroke is undone before the next, so
// they all start from the same sphere.
brushes_header :: proc() {
	fmt.println("| Vertices | Brush | Verts/dab | Dab ms | Normals ms/frame | Frame ms | Frame ms max | Undo MB/stroke |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_brushes :: proc(target: int, pool: ^jobs.Pool) {
	sp := new(Sphere)
	defer free(sp)
	sp.mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool)
	defer geom.mesh_destroy(&sp.mesh)
	sculpt.sculptor_init(&sp.sculptor, &sp.mesh, pool, node_triangles)
	defer sculpt.sculptor_destroy(&sp.sculptor)
	free_all(context.temp_allocator)
	s := &sp.sculptor
	vcount := len(sp.mesh.positions)

	Case :: struct {
		name:     string,
		kind:     sculpt.Brush_Kind,
		symmetry: sculpt.Symmetry,
		masked:   bool,
		alpha:    bool,
	}
	cases := [?]Case {
		{"Draw", .Draw, {}, false, false},
		{"Smooth", .Smooth, {}, false, false},
		{"Clay", .Clay, {}, false, false},
		{"Flatten", .Flatten, {}, false, false},
		{"Inflate", .Inflate, {}, false, false},
		{"Pinch", .Pinch, {}, false, false},
		{"Crease", .Crease, {}, false, false},
		{"Grab", .Grab, {}, false, false},
		{"Mask", .Mask, {}, false, false},
		{"Layer", .Layer, {}, false, false},
		{"Layer, second stroke", .Layer, {}, false, false},
		{"Snake hook", .Snake_Hook, {}, false, false},
		{"Draw, X symmetry", .Draw, {.X}, false, false},
		{"Draw, half masked", .Draw, {}, true, false},
		{"Draw, Noise alpha", .Draw, {}, false, true},
	}
	noise := sculpt.alpha_make(.Noise)
	defer sculpt.alpha_destroy(&noise)
	radius: f32 = 0.13
	eye := Vec3{0, 0, 3.5}
	for c in cases {
		if c.masked {
			// Mask the left half, which the stroke crosses.
			_ = sculpt.sculptor_mask_command(s, .Fill)
			for p, v in sp.mesh.positions do if p.x > 0 do s.mask[v] = 0
			sculpt.sculptor_clear_history(s)
			_ = sculpt.sculptor_flush(s)
		}
		brush := sculpt.Brush{kind = c.kind, radius = radius, strength = 0.3, symmetry = c.symmetry}
		if c.alpha do brush.alpha, brush.alpha_up = &noise, {0, 1, 0}
		frames := (DABS + DABS_PER_FRAME - 1) / DABS_PER_FRAME
		dab := make([]f64, DABS)
		flush, frame := make([]f64, frames), make([]f64, frames)
		defer delete(dab)
		defer delete(flush)
		defer delete(frame)
		touched := 0
		anchor: Vec3
		sculpt.sculptor_stroke_begin(s)
		for i in 0 ..< DABS {
			k := f32(i) / (DABS - 1)
			target_point := linalg.normalize(Vec3{-0.6 + 1.2 * k, 0.3 * math.sin(k * 4 * math.PI), 1})
			hit, ok := sculpt.sculptor_raycast(s, eye, linalg.normalize(target_point - eye))
			if !ok do hit = target_point
			f := i / DABS_PER_FRAME
			tb := time.tick_now()
			if c.kind == .Grab {
				// Picked up at the first point, then one move per frame to the latest point.
				if i == 0 {
					touched = sculpt.sculptor_grab_begin(s, brush, hit)
					anchor = hit
				} else if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 || i == DABS - 1 {
					_ = sculpt.sculptor_grab_move(s, 0.3 * (target_point - anchor))
				}
			} else {
				// A hook pulls outward a little each dab.
				if c.kind == .Snake_Hook do brush.drag = linalg.normalize(hit) * (radius * 0.05)
				touched += sculpt.apply_dab(s, brush, hit)
			}
			dab[i] = time.duration_milliseconds(time.tick_since(tb))
			frame[f] += dab[i]
			if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 || i == DABS - 1 {
				tc := time.tick_now()
				_ = sculpt.sculptor_flush(s)
				flush[f] = time.duration_milliseconds(time.tick_since(tc))
				frame[f] += flush[f]
			}
		}
		sculpt.sculptor_grab_end(s)
		_ = sculpt.sculptor_stroke_end(s)
		for len(s.waiting_cones) > 0 do _ = sculpt.sculptor_flush(s)
		undo_mb := f64(sculpt.sculptor_undo_bytes(s)) / (1 << 20)
		_ = sculpt.sculptor_undo(s)
		_ = sculpt.sculptor_flush(s)
		sculpt.sculptor_clear_history(s)
		if c.masked {
			_ = sculpt.sculptor_mask_command(s, .Clear)
			sculpt.sculptor_clear_history(s)
			_ = sculpt.sculptor_flush(s)
		}
		dab_ms := median(dab)
		per_dab := touched / DABS
		if c.kind == .Grab {
			// One move a frame: report a move's time and the vertices it carries.
			moves := make([dynamic]f64, 0, frames, context.temp_allocator)
			for i in 1 ..< DABS do if i % DABS_PER_FRAME == DABS_PER_FRAME - 1 || i == DABS - 1 do append(&moves, dab[i])
			dab_ms = median(moves[:])
			per_dab = touched
		}
		fmt.printfln("| %s | %s | %d | %.3f | %.3f | %.2f | %.2f | %.1f |",
			thousands(vcount), c.name, per_dab, dab_ms, median(flush), median(frame), slice.max(frame), undo_mb)
	}
}
