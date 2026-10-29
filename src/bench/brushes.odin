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
// per brush kind, plus Draw at the app's spacing, Draw with X symmetry (feathered), Draw
// over a half-masked sphere and Draw with the Noise alpha (whose square reaches past the
// round brush). Grab picks up the brush area at the first point and is dragged along the rest of the
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
		layer:    bool, // record the stroke into a new sculpt layer
		// The same path at the app's default spacing, a fifth of the radius rather than the
		// quarter the rest are laid at: a quarter more dabs a frame, each at Even
		// strength's 0.8 of the strength (sculpt.dab_overlap at 0.25 over 0.2).
		closer:   bool,
	}
	cases := [?]Case {
		{"Draw", .Draw, {}, false, false, false, false},
		{"Draw, spacing 0.2", .Draw, {}, false, false, false, true},
		{"Draw, recording a layer", .Draw, {}, false, false, true, false},
		{"Smooth", .Smooth, {}, false, false, false, false},
		{"Clay", .Clay, {}, false, false, false, false},
		{"Flatten", .Flatten, {}, false, false, false, false},
		{"Inflate", .Inflate, {}, false, false, false, false},
		{"Pinch", .Pinch, {}, false, false, false, false},
		{"Crease", .Crease, {}, false, false, false, false},
		{"Grab", .Grab, {}, false, false, false, false},
		{"Mask", .Mask, {}, false, false, false, false},
		{"Layer", .Layer, {}, false, false, false, false},
		{"Layer, second stroke", .Layer, {}, false, false, false, false},
		{"Snake hook", .Snake_Hook, {}, false, false, false, false},
		{"Morph", .Morph, {}, false, false, false, false},
		{"Paint", .Paint, {}, false, false, false, false},
		{"Draw, X symmetry", .Draw, {.X}, false, false, false, false},
		{"Draw, half masked", .Draw, {}, true, false, false, false},
		{"Draw, Noise alpha", .Draw, {}, false, true, false, false},
	}
	layer_line: string
	defer if layer_line != "" {
		fmt.println()
		fmt.println(layer_line)
		delete(layer_line)
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
		// Morph toward the surface as it is, which costs what any target does.
		if c.kind == .Morph do _ = sculpt.sculptor_morph_store(s)
		defer if c.kind == .Morph do sculpt.sculptor_morph_clear(s)
		// Symmetry feathers as the app's brushes do by default.
		brush := sculpt.Brush{kind = c.kind, radius = radius, strength = 0.3, symmetry = c.symmetry, color = {200, 60, 30}, feather = c.symmetry != {}}
		dabs, per_frame := DABS, DABS_PER_FRAME
		if c.closer {
			dabs, per_frame = DABS * 5 / 4, DABS_PER_FRAME * 5 / 4
			brush.strength *= sculpt.dab_overlap(nil, 0.25) / sculpt.dab_overlap(nil, 0.2)
		}
		if c.alpha do brush.alpha, brush.alpha_up = &noise, {0, 1, 0}
		frames := (dabs + per_frame - 1) / per_frame
		dab := make([]f64, dabs)
		flush, frame := make([]f64, frames), make([]f64, frames)
		defer delete(dab)
		defer delete(flush)
		defer delete(frame)
		touched := 0
		anchor: Vec3
		if c.layer do _ = sculpt.sculptor_layer_add(s)
		sculpt.sculptor_stroke_begin(s)
		for i in 0 ..< dabs {
			k := f32(i) / f32(dabs - 1)
			target_point := linalg.normalize(Vec3{-0.6 + 1.2 * k, 0.3 * math.sin(k * 4 * math.PI), 1})
			hit, ok := sculpt.sculptor_raycast(s, eye, linalg.normalize(target_point - eye))
			if !ok do hit = target_point
			f := i / per_frame
			tb := time.tick_now()
			if c.kind == .Grab {
				// Picked up at the first point, then one move per frame to the latest point.
				if i == 0 {
					touched = sculpt.sculptor_grab_begin(s, brush, hit)
					anchor = hit
				} else if i % per_frame == per_frame - 1 || i == dabs - 1 {
					_ = sculpt.sculptor_grab_move(s, 0.3 * (target_point - anchor))
				}
			} else {
				// A hook pulls outward a little each dab.
				if c.kind == .Snake_Hook do brush.drag = linalg.normalize(hit) * (radius * 0.05)
				touched += sculpt.apply_dab(s, brush, hit)
			}
			dab[i] = time.duration_milliseconds(time.tick_since(tb))
			frame[f] += dab[i]
			if i % per_frame == per_frame - 1 || i == dabs - 1 {
				tc := time.tick_now()
				_ = sculpt.sculptor_flush(s)
				flush[f] = time.duration_milliseconds(time.tick_since(tc))
				frame[f] += flush[f]
			}
		}
		sculpt.sculptor_grab_end(s)
		te := time.tick_now()
		_ = sculpt.sculptor_stroke_end(s)
		end_ms := time.duration_milliseconds(time.tick_since(te))
		for len(s.waiting_cones) > 0 do _ = sculpt.sculptor_flush(s)
		undo_mb := f64(sculpt.sculptor_undo_bytes(s)) / (1 << 20)
		if c.layer {
			// The stroke's end adds it to the layer; then one slider change, as a drag's
			// first frame makes it, with its flush.
			ts := time.tick_now()
			_ = sculpt.sculptor_layer_set(s, 0, 0.5, true)
			set_ms := time.duration_milliseconds(time.tick_since(ts))
			_ = sculpt.sculptor_flush(s)
			slider_ms := time.duration_milliseconds(time.tick_since(ts))
			_ = sculpt.sculptor_stroke_end(s)
			layer_line = fmt.aprintf("Sculpt layer at %s vertices: stroke end %.2f ms (adds the stroke to the layer), slider change %.2f ms, with its flush %.2f ms, layer %.1f MB",
				thousands(vcount), end_ms, set_ms, slider_ms, f64(sculpt.sculptor_layers_bytes(s)) / (1 << 20))
			_ = sculpt.sculptor_undo(s)
			_ = sculpt.sculptor_undo(s)
		}
		_ = sculpt.sculptor_undo(s)
		_ = sculpt.sculptor_flush(s)
		sculpt.sculptor_clear_history(s)
		if c.masked {
			_ = sculpt.sculptor_mask_command(s, .Clear)
			sculpt.sculptor_clear_history(s)
			_ = sculpt.sculptor_flush(s)
		}
		dab_ms := median(dab)
		per_dab := touched / dabs
		if c.kind == .Grab {
			// One move a frame: report a move's time and the vertices it carries.
			moves := make([dynamic]f64, 0, frames, context.temp_allocator)
			for i in 1 ..< dabs do if i % per_frame == per_frame - 1 || i == dabs - 1 do append(&moves, dab[i])
			dab_ms = median(moves[:])
			per_dab = touched
		}
		fmt.printfln("| %s | %s | %d | %.3f | %.3f | %.2f | %.2f | %.1f |",
			thousands(vcount), c.name, per_dab, dab_ms, median(flush), median(frame), slice.max(frame), undo_mb)
	}
}
