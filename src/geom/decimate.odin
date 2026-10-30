package geom

import "base:runtime"
import "core:math/linalg"

import "../jobs"

// Cells per axis the mesh is cut into for the parallel rounds of decimation.
DECIMATE_CELLS :: 4
// The parallel rounds stop at this many times the target, leaving the last, whole-mesh
// round room to choose freely.
DECIMATE_SLACK :: 12
// Each parallel round keeps at least this share of the triangles. A cell's border is
// held while its inside thins out, so a round that went much further would leave rows of
// small triangles along the borders meeting large ones, needles the later rounds could
// not collapse without folding them.
DECIMATE_ROUND_KEEP :: 4

// Rebuilds `m` with about `wanted` triangles that keep its shape, as ZBrush's
// Decimation Master does: edges collapse cheapest first by quadric error (simplify).
// Large meshes go in rounds: each of DECIMATE_CELLS³ cells on its own, in parallel,
// with its border held, to a quarter of the triangles a round, the cells shifted by
// half a cell every other round so the last round's borders come inside; then the
// whole result. Collapses that would fold
// the surface or pinch it are refused, so a closed manifold stays one, and it may
// stop above the target when nothing more can go. Returns the new mesh with zero
// normals and the largest error a collapse made (simplify's), or ok false when there
// is nothing to decimate. With `progress` (a job on a thread of its own) it says how far
// it has come within `share` of the whole, after each round and through the last
// simplify's passes, and stops after a cancel, returning not ok with nothing to free.
// The vertices kept are `m`'s own, in order of first use; with `from` each new vertex's
// number in `m` is appended to it, so what a vertex carries (paint, shape keys, groups)
// can follow it.
mesh_decimate :: proc(m: Mesh, wanted: int, pool: ^jobs.Pool, allocator := context.allocator, progress: ^jobs.Progress = nil, share := [2]f32{0, 1}, from: ^[dynamic]u32 = nil) -> (out: Mesh, error: f32, ok: bool) {
	triangles := len(m.indices) / 3
	if triangles == 0 || wanted >= triangles do return {}, 0, false
	target := max(wanted, 4)

	indices := m.indices[:]
	round: [dynamic]u32
	defer delete(round)
	// The rounds take about the first half of the time, each a quarter of what is left of
	// it; the last simplify the rest.
	rounds_end := share[0] + (share[1] - share[0]) * 0.5
	for shift := false; len(indices) / 3 > 2 * DECIMATE_SLACK * target && len(indices) / 3 > 200_000; shift = !shift {
		next := decimate_cells(m, indices, max(len(indices) / 3 / DECIMATE_ROUND_KEEP, DECIMATE_SLACK * target), shift, pool)
		delete(round)
		round = next
		indices = round[:]
		at := jobs.progress_get(progress)
		jobs.progress_set(progress, at, rounds_end, 0.75)
		if jobs.progress_cancelled(progress) do return {}, 0, false
	}
	kept := make([dynamic]u32, 0, 3 * target + 3, context.temp_allocator)
	error = simplify(m.positions[:], indices, target, &kept, context.temp_allocator, strict = true, progress = progress, share = {max(jobs.progress_get(progress), rounds_end), share[1]})
	if jobs.progress_cancelled(progress) do return {}, 0, false

	// Only the vertices still used, in order of first use.
	renumber := make([]u32, len(m.positions), context.temp_allocator)
	for &r in renumber do r = max(u32)
	out.positions = make([dynamic]Vec3, 0, len(kept) / 2 + 3, allocator)
	out.indices = make([dynamic]u32, 0, len(kept), allocator)
	for v in kept {
		if renumber[v] == max(u32) {
			renumber[v] = u32(len(out.positions))
			append(&out.positions, m.positions[v])
			if from != nil do append(from, v)
		}
		append(&out.indices, renumber[v])
	}
	out.normals = make([dynamic]Vec3, len(out.positions), allocator)
	return out, error, true
}

// One parallel round: the triangles `indices` bucketed by the cell their middle is in
// (the cells moved half a cell along each axis with `shift`), each bucket simplified to
// its share of `goal` on its own thread, the cells' shared borders held.
@(private = "file")
decimate_cells :: proc(m: Mesh, indices: []u32, goal: int, shift: bool, pool: ^jobs.Pool) -> [dynamic]u32 {
	CELLS :: DECIMATE_CELLS * DECIMATE_CELLS * DECIMATE_CELLS
	lo, hi := m.positions[0], m.positions[0]
	for p in m.positions {
		lo = linalg.min(lo, p)
		hi = linalg.max(hi, p)
	}
	scale := f32(DECIMATE_CELLS) / linalg.max(hi - lo, Vec3{1e-30, 1e-30, 1e-30})
	if shift do lo -= 0.5 / scale
	cell_of := proc(m: Mesh, indices: []u32, t: int, lo, scale: Vec3) -> int {
		c := (m.positions[indices[3 * t]] + m.positions[indices[3 * t + 1]] + m.positions[indices[3 * t + 2]]) / 3
		k := linalg.array_cast((c - lo) * scale, int)
		for &x in k do x = clamp(x, 0, DECIMATE_CELLS - 1)
		return (k.z * DECIMATE_CELLS + k.y) * DECIMATE_CELLS + k.x
	}
	triangles := len(indices) / 3
	counts: [CELLS + 1]int
	for t in 0 ..< triangles do counts[cell_of(m, indices, t, lo, scale) + 1] += 1
	for i in 1 ..= CELLS do counts[i] += counts[i - 1]
	bucketed := make([]u32, len(indices))
	defer delete(bucketed)
	cursor := counts
	for t in 0 ..< triangles {
		c := cell_of(m, indices, t, lo, scale)
		copy(bucketed[3 * cursor[c]:][:3], indices[3 * t:][:3])
		cursor[c] += 1
	}

	Work :: struct {
		m:       Mesh,
		goal:    int,
		total:   int,
		counts:  [CELLS + 1]int,
		indices: []u32,
		out:     [CELLS][dynamic]u32,
	}
	work := Work{m = m, goal = goal, total = triangles, counts = counts, indices = bucketed}
	jobs.parallel_for(pool, CELLS, &work, proc(data: rawptr, c: int) {
		w := cast(^Work)data
		first, last := w.counts[c], w.counts[c + 1]
		if first == last do return
		// Heap memory: each worker thread allocates on its own.
		heap := runtime.heap_allocator()
		w.out[c] = make([dynamic]u32, 0, 3 * (last - first), heap)
		share := max((last - first) * w.goal / w.total, 1)
		_ = simplify(w.m.positions[:], w.indices[3 * first:3 * last], share, &w.out[c], heap, strict = true)
	})
	total := 0
	for o in work.out do total += len(o)
	merged := make([dynamic]u32, 0, total)
	for &o in work.out {
		append(&merged, ..o[:])
		delete(o)
	}
	return merged
}
