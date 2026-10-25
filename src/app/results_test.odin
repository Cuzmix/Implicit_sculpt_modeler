package main

import "core:testing"
import "core:time"

// A result keeps its own copy of the line, frees the one it replaces, and offers Undo
// for the undo step just recorded.
@(test)
results_keep_the_latest_line :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	defer delete(app.history.done)
	name := [6]u8{'S', 'p', 'h', 'e', 'r', 'e'}
	report(&app, Kit_Section.Mask, {.Quiet}, "Blur %s", string(name[:]))
	name[0] = 'X'
	testing.expect_value(t, app.result.text, "Blur Sphere")
	testing.expect(t, app.result.undo == nil)
	r, ok := result_for(&app, .Mask)
	testing.expect(t, ok && r.text == "Blur Sphere")
	_, ok = result_for(&app, .Visibility)
	testing.expect(t, !ok)

	append(&app.history.done, History_Entry{id = 1}, History_Entry{id = 2, at = time.tick_now()})
	report(&app, Kit_Section.Deform, {.Undo}, "Smoothed %s", "Sphere")
	report_detail(&app, "GPU: %d ms", 3)
	testing.expect(t, app.result.undo == Undo_Mark{2, app.history.done[1].at})
	testing.expect_value(t, app.result.detail, "GPU: 3 ms")
	_, ok = result_for(&app, .Mask)
	testing.expect(t, !ok)

	// A file note belongs to no section.
	report(&app, nil, {.Warning}, "Cannot open %s", "a.sculpt")
	testing.expect_value(t, app.result.detail, "")
	for s in Kit_Section {
		_, ok = result_for(&app, s)
		testing.expect(t, !ok)
	}
}

@(test)
scene_reports_read_in_the_past_tense :: proc(t: ^testing.T) {
	cases := [?]struct {
		verb, label: string,
		vertices:    int,
		ms:          f64,
		line:        string,
	} {
		{"Deleted %s", "Sphere 2", -1, 3, "Deleted Sphere 2"},
		{"Remeshed %s", "Sphere 1", 1002113, 312.4, "Remeshed Sphere 1: 1,002,113 vertices (312 ms)"},
		{"Decimated %s", "Torus", 5000, 12, "Decimated Torus: 5,000 vertices"},
		{"Sliced %s in two", "", -1, 8012, "Sliced the object in two (8012 ms)"},
	}
	for c in cases do testing.expect_value(t, scene_report_line(c.verb, c.label, c.vertices, c.ms), c.line)
	free_all(context.temp_allocator)
}

// Undo from a toast takes back its own step or nothing: not a step made after it in its
// place, and not refused because the list around it shrank.
@(test)
undo_marks_follow_the_step_not_the_count :: proc(t: ^testing.T) {
	tick :: proc(ns: i64) -> time.Tick {return time.Tick{ns}}
	snapshot: Object_Snapshot
	stroke_a := History_Entry{id = 1, at = tick(10)}
	stroke_b := History_Entry{id = 1, at = tick(20)}
	remesh := History_Entry{id = 1, at = tick(30), swap = &snapshot}
	mark := Undo_Mark{1, tick(30)}

	// Remeshing forgets the object's strokes, so the list is shorter than before it.
	before := []History_Entry{stroke_a, stroke_b}
	after := []History_Entry{remesh}
	testing.expect(t, len(after) < len(before))
	testing.expect(t, swap_since(after, tick(25)))
	testing.expect(t, undo_mark_on_top(after, mark))

	// Undone, then a stroke made: the same count, another step on top.
	stroke_c := History_Entry{id = 1, at = tick(40)}
	testing.expect(t, !undo_mark_on_top([]History_Entry{stroke_c}, mark))
	// Redone: the same step again.
	testing.expect(t, undo_mark_on_top([]History_Entry{remesh}, mark))
	// Trimmed at the limit from the bottom, or another object's strokes forgotten: on top.
	testing.expect(t, undo_mark_on_top([]History_Entry{History_Entry{id = 2, at = tick(5)}, remesh}, mark))
	testing.expect(t, !undo_mark_on_top([]History_Entry{}, mark))

	// A stroke the command finished first is not the command's step: no swap.
	testing.expect(t, !swap_since([]History_Entry{History_Entry{id = 1, at = tick(35)}}, tick(30)))
	// A swap from before the command is not its step either.
	testing.expect(t, !swap_since(after, tick(31)))
	// A slice's chained second step is on top, and is a swap.
	part := History_Entry{id = 7, at = tick(31), swap = &snapshot, chain = true}
	testing.expect(t, swap_since([]History_Entry{remesh, part}, tick(30)))
}
