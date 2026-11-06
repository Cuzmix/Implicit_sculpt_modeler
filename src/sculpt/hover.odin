package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"

// The hover preview's trial dabs (README "Hover preview"): while the pen or the mouse
// hovers over the model, the app shows what the first dab of a stroke would do under the
// brush ring. The GPU lays the dab in the mesh's own buffers and puts them back as the
// frame ends (render/sculpt_gpu.odin, sculpt_gpu_trial), so nothing here moves a vertex:
// this file only works out the dabs, one for the brush and one for each image of its
// symmetry, as a stroke's first dab would record them for the GPU (dab_once,
// gpu_dab_make), with the hit nodes' ranges they work on. The CPU's mesh, the undo, the
// tree and the stroke's records stay as they were.

// The most vertices a frame's trial dabs may reach together: past it the trial would cost
// what a large dab costs, every frame the pointer moves, so the app shows the ring alone.
HOVER_VERTS_MAX :: 262_144

// The trial dabs of `brush` centred on `center` (local space) and its symmetry's images,
// each with its hit nodes' owned ranges, in `allocator`, and how many vertices they reach
// together. `boost` scales how far each moves (1 is the stroke's own first dab), so a
// faint dab still reads. Not ok, with nothing allocated, while a stroke records, where the
// GPU's kernels do not lay the brush on this sculptor (dab_gpu_takes), where no dab
// reaches a vertex, or past HOVER_VERTS_MAX (`verts` then says how many it would reach).
sculptor_trial_dabs :: proc(s: ^Sculptor, brush: Brush, center: Vec3, boost: f32, allocator := context.allocator) -> (dabs: []Gpu_Dab, verts: int, ok: bool) {
	if s.history.recording || !dab_gpu_takes(s, brush) || brush.radius <= 0 do return
	images := symmetry_images(brush)
	b := brush
	b.strength /= symmetry_feather(brush, images[:], center)
	hits := make([dynamic]u32, 0, 64, context.temp_allocator)
	out := make([dynamic]Gpu_Dab, 0, len(images), context.temp_allocator)
	spans := make([dynamic]Vertex_Range, 0, 64, context.temp_allocator)
	for img in images {
		ib := sym_brush(b, img)
		at := sym_point(img, b.sym_center, center)
		// Its reach and view as dab_once works them out for the kinds the kernels lay.
		reach := ib.radius * (ib.alpha.reach if ib.alpha != nil else 1)
		view: Vec3
		if projects(ib) {
			view = linalg.normalize(ib.projected) / ib.radius
			reach = math.SQRT_TWO * ib.radius
		}
		d := Dab{s = s, brush = ib, center = at, r2 = reach * reach, inv_r2 = 1 / (ib.radius * ib.radius), view = view}
		clear(&hits)
		geom.bvh_query_leaves(&s.bvh, at, reach, &hits)
		if len(hits) == 0 do continue
		first := len(spans)
		for leaf in hits {
			n := s.nodes[s.node_of[leaf]]
			if n.vert_count == 0 do continue
			append(&spans, Vertex_Range{n.vert_first, n.vert_count})
			verts += int(n.vert_count)
		}
		rec := gpu_dab_make(s, &d, ib)
		rec.once, rec.stroke = false, 0
		trial_boost(&rec, boost)
		rec.range_first, rec.range_count = first, len(spans) - first
		append(&out, rec)
	}
	if len(out) == 0 || verts > HOVER_VERTS_MAX do return nil, verts, false
	// Each dab's ranges in vertex order, coalesced, in one block the dabs slice.
	ranges := make([]Vertex_Range, len(spans), allocator)
	dabs = make([]Gpu_Dab, len(out), allocator)
	used := 0
	for rec, i in out {
		own := spans[rec.range_first:][:rec.range_count]
		slice.sort_by(own, proc(a, b: Vertex_Range) -> bool {return a.first < b.first})
		first := used
		for sp in own {
			if used > first && ranges[used - 1].first + ranges[used - 1].count == sp.first {
				ranges[used - 1].count += sp.count
				continue
			}
			ranges[used] = sp
			used += 1
		}
		dabs[i] = rec
		dabs[i].range_first, dabs[i].range_count = first, used - first
		dabs[i].ranges = ranges[first:used]
	}
	return dabs, verts, true
}

// Every vertex range the trial dabs work on, merged and coalesced, in `allocator`: what
// the GPU saves before them and puts back after.
sculptor_trial_ranges :: proc(dabs: []Gpu_Dab, allocator := context.allocator) -> []Vertex_Range {
	all := make([dynamic]Vertex_Range, 0, 16, context.temp_allocator)
	for d in dabs do append(&all, ..d.ranges)
	slice.sort_by(all[:], proc(a, b: Vertex_Range) -> bool {return a.first < b.first})
	out := make([dynamic]Vertex_Range, 0, len(all), allocator)
	for r in all {
		if l := len(out); l > 0 && out[l - 1].first + out[l - 1].count >= r.first {
			out[l - 1].count = max(out[l - 1].count, r.first + r.count - out[l - 1].first)
			continue
		}
		append(&out, r)
	}
	return out[:]
}

// How far a trial dab of each kind moves, `boost` times its own: the displacement of Draw,
// Inflate and Crease, the strength the plane kinds and Pinch go toward their targets with
// (which the kernels keep within the whole way), and Smooth's share a pass.
@(private = "file")
trial_boost :: proc(rec: ^Gpu_Dab, boost: f32) {
	#partial switch rec.kind {
	case .Draw, .Inflate, .Crease:
		rec.amount *= boost
	case .Clay, .Flatten, .Pinch:
		rec.strength *= boost
	case .Smooth:
		for &rate in rec.rates[:rec.passes] do rate = min(rate * boost, 1)
	}
}
