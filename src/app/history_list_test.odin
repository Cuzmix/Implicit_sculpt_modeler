package main

import "core:testing"
import "core:time"

import "../geom"
import "../sculpt"

// The list's rows, newest first: strokes of one brush on one object in a row group, but not
// across where the History stands, not across another object or brush, and not with an
// adjusted stroke; chained entries ride with their step; an opened group lists its strokes
// after it; the selected object's filter keeps only its rows.
@(test)
history_rows_group_repeated_strokes :: proc(t: ^testing.T) {
	app: App
	defer delete(app.history.done)
	defer delete(app.history.undone)
	at := time.Tick{1000}
	add :: proc(app: ^App, at: ^time.Tick, id: int, kind: History_Kind, what: string, chain := false, adjusted := false) {
		at._nsec += 1
		append(&app.history.done, History_Entry{id = id, kind = kind, what = what, at = at^, chain = chain, adjusted = adjusted, bytes = 10})
	}
	add(&app, &at, 1, .Stroke, "Clay") // 0
	add(&app, &at, 1, .Stroke, "Clay") // 1
	add(&app, &at, 1, .Stroke, "Clay") // 2
	add(&app, &at, 2, .Stroke, "Clay") // 3: another object
	add(&app, &at, 1, .Rebuild, "slice") // 4
	add(&app, &at, 2, .Rebuild, "slice", chain = true) // 5: rides with 4
	add(&app, &at, 1, .Stroke, "Draw") // 6
	add(&app, &at, 1, .Stroke, "Draw", adjusted = true) // 7
	add(&app, &at, 1, .Stroke, "Draw") // 8
	add(&app, &at, 1, .Stroke, "Draw") // 9
	// The newest stroke undone: it stands apart from the done ones before it.
	append(&app.history.undone, pop(&app.history.done))

	rows := history_rows(&app)
	want := []History_Row {
		{head = 9, last = 9, oldest = 9, count = 1},
		{head = 8, last = 8, oldest = 8, count = 1},
		{head = 7, last = 7, oldest = 7, count = 1},
		{head = 6, last = 6, oldest = 6, count = 1},
		{head = 4, last = 5, oldest = 4, count = 1},
		{head = 3, last = 3, oldest = 3, count = 1},
		{head = 2, last = 2, oldest = 0, count = 3},
	}
	testing.expect_value(t, len(rows), len(want))
	for r, i in rows do if i < len(want) do testing.expect_value(t, r, want[i])
	testing.expect_value(t, history_row_bytes(&app, rows[4]), 20)
	testing.expect_value(t, history_row_bytes(&app, rows[6]), 30)

	// Opened by its oldest stroke, the group lists its three strokes after it.
	rows = history_rows(&app, open_at = app.history.done[0].at)
	testing.expect_value(t, len(rows), len(want) + 3)
	testing.expect(t, rows[6].open && rows[7].sub && rows[7].head == 2 && rows[9].head == 0)

	// Only object 2's: its stroke, and the slice it is chained into is object 1's.
	rows = history_rows(&app, only = 2)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].head, 3)
}

// A step records what it held, the History says what it holds in all, and the steps the
// cap drops are counted for the list's first row.
@(test)
history_steps_know_their_size :: proc(t: ^testing.T) {
	app: App
	defer {
		for obj in app.scene.objects {
			sculpt.levels_destroy(&obj.levels)
			free(obj)
		}
		delete(app.scene.objects)
		history_destroy(&app.history)
		results_destroy(&app)
	}
	app.ui.smooth_steps, app.ui.smooth_strength = 1, 0.5
	obj := new(Object)
	obj.id, obj.transform = 1, {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(3), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = 0
	for _ in 0 ..< 4 do smooth_command(&app, 1)
	testing.expect_value(t, len(app.history.done), 4)
	for e in app.history.done do testing.expect(t, e.bytes > 0)
	bytes, full := history_memory(&app)
	testing.expect_value(t, bytes, object_sculptor(obj).history.bytes)
	testing.expect(t, full > 0 && full < 1)
	app.undo_steps = 3
	history_cap(&app)
	testing.expect_value(t, app.history.dropped, 1)
	history_clear(&app.history)
	testing.expect_value(t, app.history.dropped, 0)
	testing.expect(t, app.history.began != {})
}
