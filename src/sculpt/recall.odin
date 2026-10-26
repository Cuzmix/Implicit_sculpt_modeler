package sculpt

import "../jobs"

// The History brush's target, as ZBrush's HistoryRecall: the surface as it was before an
// earlier step of this sculptor's history, which the brush paints back toward where it
// is brushed, a local undo. A build copies the positions and writes over them the before
// positions each step back to the chosen one saved, newest first, so the oldest step's
// before wins wherever several steps touched a node. The target is a copy: later strokes,
// the History brush's own among them, leave it as it is. It is dropped with the sculptor
// and when dynamic topology turns on, as the morph target is.
//
// A build reads back only through steps whose saved positions still tell what changed:
// none under dynamic topology (turning it on or off clears the history), and none from
// before the levels last carried another level's edits here (history_seal), since those
// moves are in no step of this sculptor. A target from before such a seal is out of reach
// too: it would paint away the carried edits.

// How many of the newest steps a build can read back through: 0 when none.
sculptor_recall_reach :: proc(s: ^Sculptor) -> int {
	h := &s.history
	if s.dyn != nil || h.recording do return 0
	reach := 0
	#reverse for step in h.done {
		if step.id <= h.sealed do break
		reach += 1
	}
	return reach
}

// Makes the target the surface as it was before the step `back` steps back (1 is the
// newest), replacing any earlier target. `pinned` says the user chose the point, rather
// than it being the oldest by default (sculptor_recall_pinned). False, changing nothing,
// when `back` is out of reach (sculptor_recall_reach).
sculptor_recall_build :: proc(s: ^Sculptor, back: int, pinned := false) -> bool {
	if back < 1 || back > sculptor_recall_reach(s) do return false
	h := &s.history
	if len(s.recall) != len(s.mesh.positions) {
		delete(s.recall, h.allocator)
		s.recall = make([]Vec3, len(s.mesh.positions), h.allocator)
	}
	// The copy is the build's cost (120 MB at 10M vertices, its pages touched the first
	// time), so the threads share it.
	jobs.parallel_ranges(s.pool, len(s.recall), s, proc(data: rawptr, lo, hi: int) {
		s := cast(^Sculptor)data
		copy(s.recall[lo:hi], s.mesh.positions[lo:hi])
	})
	// Steps one after another, so an older step's before lands over a newer one's; the
	// nodes of one step write disjoint ranges, in parallel.
	b := Recall_Build{s = s}
	for i := len(h.done) - 1; i >= len(h.done) - back; i -= 1 {
		b.step = &h.done[i]
		verts := 0
		for sv in b.step.saved do if sv.positions != nil do verts += len(sv.positions)
		jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(b.step.saved), &b, proc(data: rawptr, j: int) {
			b := cast(^Recall_Build)data
			sv := b.step.saved[j]
			if sv.positions == nil || sv.full || sv.is_delta do return
			copy(b.s.recall[b.s.nodes[sv.node].vert_first:][:len(sv.positions)], sv.positions)
		})
	}
	s.recall_step = h.done[len(h.done) - back].id
	s.recall_pinned = pinned
	return true
}

@(private = "file")
Recall_Build :: struct {
	s:    ^Sculptor,
	step: ^Undo_Step,
}

// How many steps back the target is from (1: before the newest step), while that step is
// still done and in reach; false when there is no target, or its step was undone, dropped
// or sealed off.
sculptor_recall_back :: proc(s: ^Sculptor) -> (back: int, ok: bool) {
	if s.recall == nil || len(s.recall) != len(s.mesh.positions) || s.recall_step <= s.history.sealed do return 0, false
	done := s.history.done[:]
	#reverse for step, i in done do if step.id == s.recall_step do return len(done) - i, true
	return 0, false
}

// Whether the user chose the target's point, rather than it being the oldest by default.
sculptor_recall_pinned :: proc(s: ^Sculptor) -> bool {return s.recall != nil && s.recall_pinned}

sculptor_recall_clear :: proc(s: ^Sculptor) {
	delete(s.recall, s.history.allocator)
	s.recall, s.recall_step, s.recall_pinned = nil, 0, false
}
