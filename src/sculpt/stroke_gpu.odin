package sculpt

import "../geom"
import "../jobs"

// The GPU's share of a stroke (README "Sculpt on the GPU"). This package moves the
// vertices and keeps the mesh; the kernels, buffers and readbacks belong to the app's
// renderer, which this package knows nothing of, so it reaches them through these
// callbacks alone, as Smooth_Gpu does for Smooth all. The app sets `stroke_gpu` once at
// start-up; the tests and the bench leave it empty, and every stroke then runs on the CPU
// as before.
//
// Today the GPU takes a stroke's vertex normals: the flushes of a stroke the GPU took
// hand it the vertex ranges whose normals they would recompute, and leave the CPU's
// normals of those ranges to the readback the app brings in a frame or two later, so the
// dabs of such a stroke read normals that are a little older than the CPU path's. A sync
// waits for every readback of the mesh and applies it: before the CPU recomputes any
// normals itself, before a stroke begins and before the sculptor goes, so outside a stroke
// the CPU's normals are the GPU's, within the twelve bits the GPU's packing keeps.
Stroke_Gpu :: struct {
	data: rawptr,
	// Whether the GPU takes the normals of the stroke under way on `s`, drawn with `brush`:
	// asked once, at the stroke's first dab; the answer holds until the stroke's last flush.
	begin:   proc(data: rawptr, s: ^Sculptor, brush: Brush) -> bool,
	// Recomputes the normals of `ranges` (the mesh's owned vertex ranges of the nodes whose
	// shape or border moved, coalesced and sorted) on the GPU, the stroke's last flush
	// with `last`; false leaves them to the CPU, this flush and every later one of the
	// stroke.
	normals: proc(data: rawptr, s: ^Sculptor, ranges: []Vertex_Range, last: bool) -> bool,
	// Waits for every readback of `s`'s normals still under way and writes them into the
	// mesh.
	sync:    proc(data: rawptr, s: ^Sculptor),
}

stroke_gpu: Stroke_Gpu

// Brings the CPU's normals up to date with the GPU's where a readback is still under way;
// nothing where no stroke ran on the GPU.
sculptor_gpu_sync :: proc(s: ^Sculptor) {
	if stroke_gpu.sync != nil do stroke_gpu.sync(stroke_gpu.data, s)
}

// Whether the stroke under way runs its normals on the GPU, decided at its first dab.
sculptor_stroke_on_gpu :: proc(s: ^Sculptor) -> bool {return s.gpu_stroke}

// Asks the GPU for the stroke under way, once, at its first dab: a stroke never changes
// hands halfway, so its undo step and its flushes come from one source.
@(private)
stroke_gpu_decide :: proc(s: ^Sculptor, brush: Brush) {
	if s.gpu_asked || !s.history.recording do return
	s.gpu_asked = true
	s.gpu_stroke = stroke_gpu.begin != nil && stroke_gpu.begin(stroke_gpu.data, s, brush)
}

// Hands a flush's normals to the GPU when the stroke runs there: true when it took them,
// and then the nodes' bounds and chunks are brought up to date here as job_node_normals
// would, with nothing of their normals. The stroke's last flush gives it back.
@(private)
stroke_gpu_normals :: proc(s: ^Sculptor) -> bool {
	if !s.gpu_stroke do return false
	last := !s.history.recording
	taken := stroke_gpu.normals != nil && stroke_gpu.normals(stroke_gpu.data, s, s.ranges[:], last)
	if !taken || last do s.gpu_stroke = false
	if !taken do return false
	jobs.parallel_for(s.pool if len(s.dirty_nodes) >= 64 else nil, len(s.dirty_nodes), s, job_node_shape)
	return true
}

// The bounds and chunk of a dirty node whose shape changed, as job_node_normals keeps
// them during a stroke, its normals left to the GPU.
@(private = "file")
job_node_shape :: proc(data: rawptr, i: int) {
	s := cast(^Sculptor)data
	id := s.dirty_nodes[i]
	if s.stale[id] != .Shape do return
	n := s.nodes[id]
	s.chunks[id].bounds = s.bvh.nodes[n.leaf].bounds if n.leaf != geom.BVH_NONE else geom.AABB_EMPTY
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
