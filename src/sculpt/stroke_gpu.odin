package sculpt

import "core:slice"

import "../geom"
import "../jobs"

// The GPU's share of a stroke (README "Sculpt on the GPU"). This package moves the
// vertices and keeps the mesh; the kernels, buffers and readbacks belong to the app's
// renderer, which this package knows nothing of, so it reaches them through these
// callbacks alone, as Smooth_Gpu does for Smooth all. The app sets `stroke_gpu` once at
// start-up; the tests and the bench leave it empty, and every stroke then runs on the CPU
// as before.
//
// A stroke asks once, at its first dab, and the GPU takes it one of two ways. Normals: the
// CPU lays the dabs and uploads the positions they moved, and the flushes of the stroke
// hand the vertex ranges whose normals they would recompute to the GPU, which brings them
// back by a readback a frame or two later. Dabs: the dabs themselves run on the GPU too:
// apply_dab does everything around a dab here (the leaf query, the undo's saves, the
// marking) and records the dab instead of moving anything, the flush hands the frame's
// records over, and the GPU's positions come back by the same readback, so the CPU's mesh
// is a mirror a frame or two behind the GPU's while the stroke runs. A sync waits for every
// readback of the mesh and applies it, and lays any dab recorded but not yet handed over
// on the CPU (which turns the stroke to Normals: the flush then uploads what it laid):
// before anything reads or writes the positions or normals outside the dab path, so
// between strokes the CPU's mesh is the GPU's, within the twelve bits the packed normals
// keep. A stroke only ever steps down: Dabs to Normals to the CPU, never up, so its undo
// step and its flushes agree on what the mesh holds.
Stroke_Gpu :: struct {
	data: rawptr,
	// How the GPU takes the stroke under way on `s`, drawn with `brush`: asked once, at
	// the stroke's first dab; the answer holds until the stroke's last flush.
	begin:   proc(data: rawptr, s: ^Sculptor, brush: Brush) -> Gpu_Take,
	// Runs the frame's dab records on the GPU, in order, before the normals of the same
	// flush; false leaves them to the CPU, which lays them itself from the mirror, and
	// turns the stroke to Normals.
	dabs:    proc(data: rawptr, s: ^Sculptor, dabs: []Gpu_Dab) -> bool,
	// Recomputes the normals of `ranges` (the mesh's owned vertex ranges of the nodes whose
	// shape or border moved, coalesced and sorted) on the GPU, the stroke's last flush
	// with `last`, and reads the ranges' positions and normals back; false leaves them to
	// the CPU, this flush and every later one of the stroke.
	normals: proc(data: rawptr, s: ^Sculptor, ranges: []Vertex_Range, last: bool) -> bool,
	// Waits for every readback of `s`'s mesh already submitted and writes it into the
	// mesh; false where one is recorded this frame and not yet submitted, which cannot be
	// waited for (the caller then tries again next frame).
	sync:    proc(data: rawptr, s: ^Sculptor) -> bool,
}

// How much of a stroke the GPU takes.
Gpu_Take :: enum u8 {
	None,    // the CPU, as before
	Normals, // the vertex normals of its flushes
	Dabs,    // its dabs and their normals
}

// One dab the GPU lays (dab_gpu_record): what the kernels need of it, in the sculptor's
// terms, which the app translates for the renderer. The kinds in GPU_DAB_KINDS only.
Gpu_Dab :: struct {
	kind:        Brush_Kind,
	center:      Vec3,
	r2:          f32, // the squared reach
	inv_r2:      f32, // 1 / radius²
	inv_sample2: f32, // 1 / (the sample radius)²: the area is sampled inside it
	amount:      f32, // signed: displacement at the centre (Draw, Inflate, Crease), plane side (Clay), direction (Flatten, Pinch)
	strength:    f32,
	radius:      f32,
	plane_offset: f32, // Clay: how far along the normal its plane sits above the surface, signed
	tilt:        matrix[3, 3]f32, // turns the area normal; the zero matrix leaves it
	view:        Vec3, // Projected: the view direction over the radius, zero for Sphere
	facing:      Vec3, // front faces only: the way toward the viewer, zero for off
	plane_short: [2]f32, // Flatten's reach short of a radius above and below its plane
	// Smooth: each pass's share of the step toward the neighbours, and how it smooths.
	rates:       [SMOOTH_PASSES_HARD]f32,
	passes:      int,
	smooth_mode: Smooth_Mode,
	smooth_only: Smooth_Only,
	// Draw and Inflate with Accumulate off: the stroke's heights (Sculptor.layer, numbered
	// `stroke`) cap each vertex's move, as displace's ONCE does.
	once:        bool,
	stroke:      u32,
	// The hit leaves' owned vertex ranges, coalesced and sorted: what the kernels work
	// on. Set for the hand-off; valid until the next sculptor_flush.
	ranges:      []Vertex_Range,
	range_first, range_count: int, // its ranges in Sculptor.gpu_ranges
}

// The brush kinds the GPU's dab kernels lay (dab_move.comp.slang and the Smooth pair).
GPU_DAB_KINDS :: bit_set[Brush_Kind]{.Draw, .Inflate, .Clay, .Flatten, .Pinch, .Crease, .Smooth}

// What laying a recorded dab on the CPU needs beside its Gpu_Dab (gpu_replay).
@(private)
Gpu_Replay :: struct {
	d:           Dab, // as dab_once prepared it, before the area pass
	brush:       Brush,
	leaf_first:  int, // its hit leaves in Sculptor.gpu_leaves
	leaf_count:  int,
}

stroke_gpu: Stroke_Gpu

// Brings the CPU's mesh up to date with the GPU's: waits for the readbacks of the mesh
// already submitted and applies them, and lays any dab recorded for the GPU but not yet
// handed over on the CPU instead, which turns the stroke to Normals. True when the mesh
// is then the GPU's; false where a readback recorded this frame is not yet submitted, so
// the mesh still lags by it (the caller waits for the next frame, as sculptor_lod_update
// does). Nothing, and true, where no stroke ran on the GPU.
sculptor_gpu_sync :: proc(s: ^Sculptor) -> bool {
	exact := true
	if stroke_gpu.sync != nil do exact = stroke_gpu.sync(stroke_gpu.data, s)
	if len(s.gpu_replay) > 0 do gpu_replay(s)
	return exact
}

// Whether the stroke under way runs on the GPU, and how much of it, decided at its first dab.
sculptor_stroke_on_gpu :: proc(s: ^Sculptor) -> Gpu_Take {return s.gpu_take}

// Asks the GPU for the stroke under way, once, at its first dab: a stroke never changes
// hands halfway, so its undo step and its flushes come from one source; it may step down
// (Dabs to Normals) when something writes the mesh on the CPU meanwhile.
@(private)
stroke_gpu_decide :: proc(s: ^Sculptor, brush: Brush) {
	if s.gpu_asked || !s.history.recording do return
	s.gpu_asked = true
	s.gpu_take = .None
	if stroke_gpu.begin != nil do s.gpu_take = stroke_gpu.begin(stroke_gpu.data, s, brush)
	if s.gpu_take == .Dabs && !dab_gpu_takes(s, brush) do s.gpu_take = .Normals
}

// Whether the GPU's dab kernels lay dabs of `brush` on `s`: one of their kinds, with the
// round falloff (no alpha, drawn shape or VDM), the area taken afresh each dab (no lock
// plane or stabilize), every vertex in reach (no Connected, no mask, no HD fade, nothing
// hidden), the surface alone (no paint channel, no skin, no layer recording, no dynamic
// topology), and Smooth plain (no Polish, no Stable). Accumulate off is theirs too: the
// kernels keep the stroke's heights as displace does.
@(private)
dab_gpu_takes :: proc(s: ^Sculptor, brush: Brush) -> bool {
	if brush.kind not_in GPU_DAB_KINDS do return false
	if brush.alpha != nil || brush.falloff_shape != nil || brush.lock_plane || brush.stabilize > 0 || brush.connected do return false
	if brush.channel != .Sculpt || brush.skin do return false
	if brush.kind == .Smooth && (brush.smooth_mode == .Polish || brush.smooth_stable) do return false
	if s.mask != nil || s.fade != nil || s.dyn != nil || s.skin != nil || s.layers.recording != 0 do return false
	return true
}

// Records a dab for the GPU in place of moving its vertices, after dab_once found its
// hit leaves and saved them for undo: marks every hit leaf as moved (the GPU moves what
// it moves, which the readback shows) and records them for the undo step. The tree keeps
// bounding the mirror exactly, which the raycast of the next dabs and the cursor read (a
// tree widened by the dab's reach made a raycast at 25M cost 28 ms instead of 0.4); the
// leaf query reaches gpu_query_margin further instead, and the chunk bounds grow by it
// (job_node_shape), until the positions land and the bounds are refit
// (sculptor_positions_landed).
@(private)
dab_gpu_record :: proc(s: ^Sculptor, d: ^Dab, brush: Brush) {
	clear(&s.changed)
	for leaf in s.hit {
		append(&s.changed, leaf)
		mark_shape_changed(s, s.node_of[leaf])
	}
	if s.history.recording do record_changed(s)
	// Draw and Inflate move a tenth of a radius at full strength, Crease that and its
	// pinch, Pinch a quarter of the way to the centre, each dab adding to the last (with
	// Accumulate off a vertex stops at one dab's height); Clay and Flatten stop at their
	// plane, within half a radius; Smooth moves toward the neighbours' mean, within an
	// edge, which a brush far smaller than the mesh's triangles may exceed.
	bound: f32
	once := false
	#partial switch brush.kind {
	case .Draw, .Inflate:
		bound, once = brush.radius * brush.strength * DRAW_HEIGHT, brush.no_accumulate
	case .Crease:
		bound = brush.radius * brush.strength * (DRAW_HEIGHT + CREASE_PINCH)
	case .Pinch:
		bound = brush.radius * brush.strength * PINCH_RATE
	case .Clay, .Flatten:
		bound, once = brush.radius * 0.5, true
	case .Smooth:
		bound = brush.radius * 0.1
	}
	if once do s.gpu_margin_once = max(s.gpu_margin_once, bound)
	else do s.gpu_margin_dab = max(s.gpu_margin_dab, bound)
	s.gpu_unlanded += 1
	s.gpu_flush_count += 1

	// The amounts as dab_once sets them for each kind (the area the kernels find themselves).
	sign: f32 = -1 if brush.invert else 1
	rec := Gpu_Dab {
		kind         = brush.kind,
		center       = d.center,
		r2           = d.r2,
		inv_r2       = d.inv_r2,
		inv_sample2  = 1 / (dab_sample_radius(brush) * dab_sample_radius(brush)),
		strength     = brush.strength,
		radius       = brush.radius,
		tilt         = brush.tilt,
		view         = d.view,
		facing       = brush.facing,
		plane_short  = brush.plane_short,
		smooth_mode  = brush.smooth_mode,
		smooth_only  = brush.smooth_only,
		stroke       = s.layer_stroke,
	}
	#partial switch brush.kind {
	case .Draw, .Inflate:
		rec.amount = sign * brush.radius * brush.strength * DRAW_HEIGHT
		rec.once = brush.no_accumulate
		if rec.once {
			// The GPU's heights come back with the positions, into the same entries the
			// CPU's dabs write (sculptor_gpu_heights).
			layer_heights_fit(s)
			s.gpu_once = true
		}
	case .Clay:
		rec.amount = sign
		rec.plane_offset = sign * brush.radius * CLAY_HEIGHT
	case .Flatten, .Pinch:
		rec.amount = sign
	case .Crease:
		// Cuts in by default, like ZBrush's and Blender's crease brushes.
		rec.amount = -sign * brush.radius * brush.strength * DRAW_HEIGHT
	case .Smooth:
		for rate, i in smooth_passes(brush.strength) {
			rec.rates[i] = rate
			rec.passes = i + 1
		}
	}
	// The hit leaves' owned ranges, coalesced in vertex order as the flush reports its own.
	first := len(s.gpu_ranges)
	spans := make([]Vertex_Range, len(s.hit), context.temp_allocator)
	for leaf, i in s.hit {
		n := s.nodes[s.node_of[leaf]]
		spans[i] = {n.vert_first, n.vert_count}
	}
	slice.sort_by(spans, proc(a, b: Vertex_Range) -> bool {return a.first < b.first})
	for sp in spans {
		if len(s.gpu_ranges) > first {
			last := &s.gpu_ranges[len(s.gpu_ranges) - 1]
			if last.first + last.count == sp.first {
				last.count += sp.count
				continue
			}
		}
		append(&s.gpu_ranges, sp)
	}
	rec.range_first, rec.range_count = first, len(s.gpu_ranges) - first
	append(&s.gpu_dabs, rec)
	leaf_first := len(s.gpu_leaves)
	append(&s.gpu_leaves, ..s.hit[:])
	append(&s.gpu_replay, Gpu_Replay{d = d^, brush = brush, leaf_first = leaf_first, leaf_count = len(s.hit)})
}

// Hands the frame's dab records to the GPU, from sculptor_flush before the normals; where
// it refuses them the CPU lays them (gpu_replay). The records' slices into the ranges
// arena stay valid until the next flush, as the hand-off's contract says, and the replay
// data stays until then too, for a dispatch the GPU refuses after all
// (sculptor_gpu_refused).
@(private)
stroke_gpu_dabs :: proc(s: ^Sculptor) {
	clear(&s.gpu_ranges_last)
	clear(&s.gpu_leaves_last)
	clear(&s.gpu_replay_last)
	if len(s.gpu_dabs) == 0 do return
	for &rec in s.gpu_dabs do rec.ranges = s.gpu_ranges[rec.range_first:][:rec.range_count]
	taken := s.gpu_take == .Dabs && stroke_gpu.dabs != nil && stroke_gpu.dabs(stroke_gpu.data, s, s.gpu_dabs[:])
	if !taken {
		gpu_replay(s)
		return
	}
	// Kept one flush for sculptor_gpu_refused; the arenas swap so this flush's records
	// stay addressable while the next frame's dabs record into the other.
	s.gpu_ranges, s.gpu_ranges_last = s.gpu_ranges_last, s.gpu_ranges
	s.gpu_leaves, s.gpu_leaves_last = s.gpu_leaves_last, s.gpu_leaves
	s.gpu_replay, s.gpu_replay_last = s.gpu_replay_last, s.gpu_replay
	clear(&s.gpu_dabs)
}

// The GPU could not run what the last flush handed over after all (the device refused a
// buffer): `ranges` are the flush's, whose readback never comes, so their normals are
// stale (sculptor_normals_stale) and, where the flush handed dabs over too, the CPU lays
// them from the mirror, which the sync inside brings up to date first, and the stroke
// steps down to Normals, so the next flush uploads what it laid.
sculptor_gpu_refused :: proc(s: ^Sculptor, ranges: []Vertex_Range) {
	if s.gpu_pending_on {
		for id in nodes_of_ranges(s, ranges) do s.gpu_pending[id] -= 1
		s.gpu_pending_on = false
		gpu_flush_done(s)
	}
	sculptor_normals_stale(s, ranges)
	if len(s.gpu_replay_last) == 0 do return
	s.gpu_replay, s.gpu_replay_last = s.gpu_replay_last, s.gpu_replay
	s.gpu_leaves, s.gpu_leaves_last = s.gpu_leaves_last, s.gpu_leaves
	_ = sculptor_gpu_sync(s)
}

// The ids of the nodes owning `ranges`, in order, in temp memory.
@(private = "file")
nodes_of_ranges :: proc(s: ^Sculptor, ranges: []Vertex_Range) -> []u32 {
	ids := make([dynamic]u32, 0, 2 * len(ranges), context.temp_allocator)
	for rg in ranges {
		if rg.count == 0 do continue
		first, last := owner_node(s.nodes, rg.first), owner_node(s.nodes, rg.first + rg.count - 1)
		for id in first ..= last do append(&ids, id)
	}
	return ids[:]
}

// Lays every dab recorded for the GPU on the CPU instead, in order, from the mesh as it
// stands (the mirror, brought up to date by the sync that calls this), and drops the
// records; the stroke steps down to Normals, so the flush uploads the positions.
@(private = "file")
gpu_replay :: proc(s: ^Sculptor) {
	for &rec in s.gpu_replay {
		clear(&s.hit)
		append(&s.hit, ..s.gpu_leaves[rec.leaf_first:][:rec.leaf_count])
		resize(&s.partials, len(s.hit))
		slice.zero(s.partials[:])
		candidates: u32
		for leaf in s.hit do candidates += s.nodes[s.node_of[leaf]].vert_count
		d := rec.d
		d.s = s
		_ = dab_lay(s, &d, rec.brush, s.pool if candidates >= PARALLEL_MIN_VERTS else nil, {}, true)
	}
	clear(&s.gpu_replay)
	clear(&s.gpu_dabs)
	clear(&s.gpu_leaves)
	clear(&s.gpu_ranges)
	if s.gpu_take == .Dabs do s.gpu_take = .Normals
}

// How far beyond the mirror's bounds a vertex may be on the GPU, for the leaf query and
// the chunk bounds while the stroke's dabs run there: nothing once it steps down or ends,
// since the mirror then catches up before anything reads it.
@(private)
gpu_query_margin :: proc(s: ^Sculptor) -> f32 {
	if s.gpu_take != .Dabs do return 0
	return s.gpu_margin_once + s.gpu_margin_dab * f32(s.gpu_unlanded)
}

// A flush's readback landed or was refused: its dabs no longer count toward the margin.
@(private = "file")
gpu_flush_done :: proc(s: ^Sculptor) {
	if len(s.gpu_flush_dabs) == 0 do return
	s.gpu_unlanded = max(s.gpu_unlanded - s.gpu_flush_dabs[0], 0)
	ordered_remove(&s.gpu_flush_dabs, 0)
}

// Hands a flush's normals to the GPU when the stroke runs there: true when it took them,
// and then the nodes' bounds and chunks are brought up to date here as job_node_normals
// would, with nothing of their normals. The stroke's last flush gives it back.
@(private)
stroke_gpu_normals :: proc(s: ^Sculptor) -> bool {
	if s.gpu_take == .None do return false
	last := !s.history.recording
	taken := stroke_gpu.normals != nil && stroke_gpu.normals(stroke_gpu.data, s, s.ranges[:], last)
	// The positions of the ranges come back with the normals while the dabs run there:
	// each node counts the readbacks on their way, for sculptor_positions_landed.
	s.gpu_pending_on = taken && s.gpu_take == .Dabs
	if s.gpu_pending_on {
		for id in nodes_of_ranges(s, s.ranges[:]) do s.gpu_pending[id] += 1
		append(&s.gpu_flush_dabs, s.gpu_flush_count)
	}
	s.gpu_flush_count = 0
	if !taken || last do s.gpu_take = .None
	if !taken do return false
	jobs.parallel_for(s.pool if len(s.dirty_nodes) >= 64 else nil, len(s.dirty_nodes), s, job_node_shape)
	return true
}

// Whether the mesh's positions of this flush's ranges are the GPU's, not the CPU's: the
// stroke runs its dabs there, so the frame must not upload them (it would overwrite what
// the kernels moved) and reads them back instead. Asked after sculptor_flush.
sculptor_positions_on_gpu :: proc(s: ^Sculptor) -> bool {return s.gpu_take == .Dabs}

// The stroke heights the GPU's dabs keep (Layer_Height a vertex: the stroke's number and
// how far it raised the vertex), which the readback of a flush's ranges writes beside
// their positions; nil where no dab of the stroke under way keeps any (Accumulate on).
sculptor_gpu_heights :: proc(s: ^Sculptor) -> []Layer_Height {
	if s.gpu_take != .Dabs || !s.gpu_once do return nil
	return s.layer
}

// The bounds and chunk of a dirty node whose shape changed, as job_node_normals keeps
// them during a stroke, its normals left to the GPU; with the dabs there too, the chunk
// reaches gpu_margin beyond the mirror's bounds, so culling keeps what the GPU may have
// moved out of them.
@(private = "file")
job_node_shape :: proc(data: rawptr, i: int) {
	s := cast(^Sculptor)data
	id := s.dirty_nodes[i]
	if s.stale[id] != .Shape do return
	n := s.nodes[id]
	b := s.bvh.nodes[n.leaf].bounds if n.leaf != geom.BVH_NONE else geom.AABB_EMPTY
	if margin := gpu_query_margin(s); margin > 0 && b.lo.x <= b.hi.x {
		b.lo -= margin
		b.hi += margin
	}
	s.chunks[id].bounds = b
	s.chunks[id].cone_cutoff = 1
	s.chunks[id].index_count = 3 * n.tri_count
	chunk_touched(s, id)
}

// Marks the nodes owning `ranges` as moved, so the next flush recomputes their normals on
// the CPU and uploads them: for ranges the GPU could not take after all.
sculptor_normals_stale :: proc(s: ^Sculptor, ranges: []Vertex_Range) {
	for rg in ranges {
		if rg.count == 0 do continue
		first, last := owner_node(s.nodes, rg.first), owner_node(s.nodes, rg.first + rg.count - 1)
		for id in first ..= last do mark_stale(s, id, .Shape)
	}
}

// The nodes' own vertex ranges tiling `ranges` (a flush's, which are whole nodes), in
// order: the readback finds each one's bounds while it copies the positions in, which
// sculptor_positions_landed then takes instead of reading the positions again.
sculptor_range_nodes :: proc(s: ^Sculptor, ranges: []Vertex_Range, allocator := context.temp_allocator) -> []Vertex_Range {
	ids := nodes_of_ranges(s, ranges)
	out := make([]Vertex_Range, len(ids), allocator)
	for id, k in ids do out[k] = {s.nodes[id].vert_first, s.nodes[id].vert_count}
	return out
}

// The positions of `ranges` (a flush's, handed to the GPU) landed in the mesh from the
// GPU: refits the bounds of their nodes from the positions as they are now, exactly,
// where no later dab of the stroke is still on its way for the node (its bounds keep the
// margin dab_gpu_record gave them until that one lands too), and the BVH above them.
// `nodes` and `bounds`, when the readback found them (sculptor_range_nodes), are the
// bounds of each node's own vertices as they landed: only its shared vertices are read
// then, and the result is the full refit's to the bit, the same vertices grown in the
// same order.
sculptor_positions_landed :: proc(s: ^Sculptor, ranges: []Vertex_Range, nodes: []Vertex_Range = nil, bounds: []geom.Aabb = nil) {
	gpu_flush_done(s)
	clear(&s.changed)
	ids := nodes_of_ranges(s, ranges)
	// The readback's nodes are these in this order when they tile the same ranges.
	known := len(nodes) == len(ids) && len(bounds) == len(ids)
	if known do for id, k in ids do if nodes[k].first != s.nodes[id].vert_first || nodes[k].count != s.nodes[id].vert_count {
		known = false
		break
	}
	owned_bounds := make([dynamic]geom.Aabb, 0, len(ids) if known else 0, context.temp_allocator)
	for id, k in ids {
		if s.gpu_pending[id] > 0 {
			s.gpu_pending[id] -= 1
			if s.gpu_pending[id] > 0 do continue
		}
		if s.nodes[id].leaf == geom.BVH_NONE do continue
		append(&s.changed, s.nodes[id].leaf)
		if known do append(&owned_bounds, bounds[k])
	}
	if len(s.changed) == 0 do return
	verts: u32
	for leaf in s.changed do verts += s.nodes[s.node_of[leaf]].vert_count
	l := Landing{s = s, owned = owned_bounds[:] if known else nil}
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(s.changed), &l, job_landed_bounds)
	geom.bvh_refit_leaves(&s.bvh, s.mesh^, s.changed[:], recompute_leaves = false)
	for leaf in s.changed {
		id := s.node_of[leaf]
		s.chunks[id].bounds = s.bvh.nodes[leaf].bounds
		chunk_touched(s, id)
	}
}

@(private = "file")
Landing :: struct {
	s:     ^Sculptor,
	owned: []geom.Aabb, // each changed leaf's own vertices' bounds, or nil to find them
}

// A landed leaf's bounds: its own vertices' (as the readback found them, or read here)
// grown by its shared vertices', as job_leaf_bounds finds them.
@(private = "file")
job_landed_bounds :: proc(data: rawptr, i: int) {
	l := cast(^Landing)data
	s := l.s
	leaf := s.changed[i]
	bounds := geom.AABB_EMPTY
	if l.owned != nil {
		bounds = l.owned[i]
	} else {
		first, last := owned(s, leaf)
		for v in first ..< last do geom.aabb_grow(&bounds, s.mesh.positions[v])
	}
	for v in shared_of(s, leaf) do geom.aabb_grow(&bounds, s.mesh.positions[v])
	s.bvh.nodes[leaf].bounds = bounds
}

// Frees what the GPU's records hold (sculptor_destroy).
@(private)
stroke_gpu_destroy :: proc(s: ^Sculptor) {
	delete(s.gpu_dabs)
	delete(s.gpu_replay)
	delete(s.gpu_replay_last)
	delete(s.gpu_leaves)
	delete(s.gpu_leaves_last)
	delete(s.gpu_ranges)
	delete(s.gpu_ranges_last)
	delete(s.gpu_pending)
	delete(s.gpu_flush_dabs)
}
