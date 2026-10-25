package sculpt

import "base:runtime"
import "core:log"
import "core:slice"

import "../geom"
import "../jobs"

// Smoothing the whole mesh at once, as ZBrush's Deformation > Smooth: every vertex moves
// toward the average of its triangles' corners, the step the Smooth brush takes, a
// number of times over. Masked vertices stay where they are (partly masked ones move part
// of the way), as with brushes. It is the operation the GPU compute trial runs on: the
// work is the same for every vertex and covers the whole mesh, which suits a compute
// shader, so the app can hand the steps to the GPU (Smooth_Gpu) and keep the CPU path as
// the default and the fallback.

// What a GPU smoothing pass needs: the mesh's positions, replaced by the result, its
// triangles and the vertex -> triangle lookup, the weight of each step at each vertex
// (0 leaves it alone) and the step count. Each step must give what smooth_all_cpu's does.
Smooth_Gpu_Job :: struct {
	positions: []Vec3,
	indices:   []u32,
	faces:     geom.Vertex_Faces,
	weights:   []f32,
	steps:     int,
}

// Runs the steps on the GPU; nil (or a run that returns false) smooths on the CPU. Kept
// as a callback so this package needs nothing of rendering.
Smooth_Gpu :: struct {
	data: rawptr,
	run:  proc(data: rawptr, job: Smooth_Gpu_Job) -> bool,
}

// Smooths the whole mesh `steps` times as one undo step, each step moving every vertex
// `strength` (0 to 1) of the way to its neighbours' average; ends any stroke in progress
// first. Returns whether anything moved and whether the GPU did the work. Refused (false)
// with dynamic topology, whose strokes save whole nodes, as clip is.
sculptor_smooth_all :: proc(s: ^Sculptor, steps: int, strength: f32, gpu: Smooth_Gpu = {}) -> (changed, on_gpu: bool) {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil || steps < 1 || strength <= 0 do return
	m := s.mesh
	Weights :: struct {
		s:        ^Sculptor,
		strength: f32,
		weights:  []f32,
		free:     []bool, // per node: some vertex it owns is free to move
	}
	wj := Weights {
		s        = s,
		strength = min(strength, 1),
		weights  = make([]f32, len(m.positions), context.temp_allocator),
		free     = make([]bool, len(s.nodes), context.temp_allocator),
	}
	jobs.parallel_ranges(s.pool, len(s.nodes), &wj, proc(data: rawptr, lo, hi: int) {
		wj := cast(^Weights)data
		s := wj.s
		for id in lo ..< hi {
			n := s.nodes[id]
			for v in n.vert_first ..< n.vert_first + n.vert_count {
				w := wj.strength * shield(s.fade, s.mask, v)
				wj.weights[v] = w
				if w > 0 do wj.free[id] = true
			}
		}
	}, NODE_GRAIN)
	moved := make([dynamic]u32, 0, len(s.nodes), context.temp_allocator)
	for f, id in wj.free do if f do append(&moved, u32(id))
	if len(moved) == 0 do return

	sculptor_stroke_begin(s)
	clear(&s.hit)
	for id in moved do append(&s.hit, s.nodes[id].leaf)
	record_hit(s, false)
	if gpu.run != nil {
		job := Smooth_Gpu_Job{m.positions[:], m.indices[:], s.faces, wj.weights, steps}
		on_gpu = gpu.run(gpu.data, job)
		if !on_gpu do log.warn("smooth: the GPU pass failed; smoothing on the CPU instead")
	}
	if !on_gpu do smooth_all_cpu(s.pool, m.positions[:], m.indices[:], s.faces, wj.weights, steps)
	sculptor_nodes_moved(s, moved[:])
	for leaf in s.changed do record_changed_node(s, s.node_of[leaf])
	changed = sculptor_stroke_end(s)
	return
}

// The CPU smoothing pass: `steps` Jacobi steps over every vertex, each reading the
// positions the step before left, in parallel over vertex ranges (every vertex is
// independent within a step, so the result does not depend on the thread count). A
// vertex goes to p·(1 − w) + target·w, where the target is the mean of its triangles'
// corners and w its weight; one without triangles, or with weight 0, stays.
smooth_all_cpu :: proc(pool: ^jobs.Pool, positions: []Vec3, indices: []u32, faces: geom.Vertex_Faces, weights: []f32, steps: int) {
	if steps < 1 || len(positions) == 0 do return
	Step :: struct {
		src, dst: []Vec3,
		indices:  []u32,
		faces:    geom.Vertex_Faces,
		weights:  []f32,
	}
	// Unzeroed: every step writes all of it before the next reads it.
	raw, _ := runtime.mem_alloc_non_zeroed(len(positions) * size_of(Vec3), align_of(Vec3))
	scratch := slice.reinterpret([]Vec3, raw)
	defer delete(scratch)
	st := Step{src = positions, dst = scratch, indices = indices, faces = faces, weights = weights}
	for _ in 0 ..< steps {
		jobs.parallel_ranges(pool, len(positions), &st, proc(data: rawptr, lo, hi: int) {
			st := cast(^Step)data
			for v in lo ..< hi {
				st.dst[v] = smooth_vertex(st.src, st.indices, st.faces, st.weights[v], u32(v))
			}
		}, SMOOTH_GRAIN)
		st.src, st.dst = st.dst, st.src
	}
	// After an odd number of steps the result is in the scratch copy.
	if raw_data(st.src) != raw_data(positions) do copy(positions, st.src)
}

// Vertices per claim in smooth_all_cpu: a vertex is a few dozen loads, so a claim must
// cover many to outweigh claiming.
@(private = "file")
SMOOTH_GRAIN :: 1 << 14

// One vertex's step. Written out in the order smooth_all.comp computes it (the corners
// summed per triangle, then the lerp as two products), so the GPU has the same
// arithmetic to match.
@(private = "file")
smooth_vertex :: #force_inline proc(src: []Vec3, indices: []u32, faces: geom.Vertex_Faces, w: f32, v: u32) -> Vec3 {
	p := src[v]
	if w <= 0 do return p
	tris := geom.vertex_faces_of(faces, v)
	if len(tris) == 0 do return p
	sum: Vec3
	for f in tris {
		sum += src[indices[3 * f]] + src[indices[3 * f + 1]] + src[indices[3 * f + 2]]
	}
	target := sum / f32(3 * len(tris))
	return p * (1 - w) + target * w
}
