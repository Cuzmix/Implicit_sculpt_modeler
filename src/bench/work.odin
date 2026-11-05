package bench

import "core:fmt"

import "../sculpt"

// The work table under the stroke table: for each stroke, how many vertices the dabs
// scanned and moved, how many normals the flushes recomputed and how many positions
// undo saved (sculpt.Work_Counts), against the distinct vertices that moved in each
// frame and in the whole stroke, and what the calling thread allocated over the stroke
// (alloc_count.odin). Scanned, normals and saved grow with whole nodes, moved only with
// the brush: at 1.00 a ratio would do no work on vertices that did not move.
work_header :: proc() {
	fmt.println("| Vertices | Brush | Scanned/dab | Moved/dab | Scanned per moved | Moved/frame | Normals/frame | Normals per moved | Moved/stroke | Undo saved/stroke | Saved per moved | Allocs/dab | Heap KB/dab | Temp KB/dab |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
}

// One row of the work table from a stroke of `frames` flushes, which moved
// `frame_moved` distinct vertices summed over its frames and `stroke_moved` over all of it.
work_row :: proc(vertices: int, radius: f32, w: sculpt.Work_Counts, a: Alloc_Reading, frames, frame_moved, stroke_moved: int) -> string {
	dabs := f64(max(w.dabs, 1))
	per := proc(n: u64, d: int) -> f64 {return f64(n) / f64(max(d, 1))}
	return fmt.aprintf("| %s | r=%.2f | %.0f | %.0f | %.2f | %.0f | %.0f | %.2f | %d | %d | %.2f | %.2f | %.1f | %.1f |",
		thousands(vertices), radius, f64(w.scanned) / dabs, f64(w.moved) / dabs, per(w.scanned, int(w.moved)),
		f64(frame_moved) / f64(max(frames, 1)), per(w.renormalised, frames), per(w.renormalised, frame_moved),
		stroke_moved, w.saved, per(w.saved, stroke_moved),
		f64(a.heap_calls + a.temp_calls) / dabs, f64(a.heap_bytes) / dabs / 1024, f64(a.temp_bytes) / dabs / 1024)
}
