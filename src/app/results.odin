package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

import "../ui"

// What an operation did, said once: the log line, the toast (with Undo when it left an
// undo step), the "Last" line of the section that ran it and the Stats panel all read
// the one result kept here.

Op_Result :: struct {
	text:    string, // owned: one line, past tense, with how long it took
	detail:  string, // owned: more for the section that ran it (the GPU's split), or ""
	section: Maybe(Kit_Section), // the inspector section that shows it as its last; nil for file notes
	flags:   Report_Flags,
	undo:    Maybe(Undo_Mark), // with Undo offered: the step it takes back
	at:      time.Tick,
}

// One undo step, told apart from every other: its object and when it was made, which
// undoing, redoing and the history's tidying all keep. A count of steps would not do,
// since forgetting an object's strokes shrinks the list and new steps refill it.
Undo_Mark :: struct {
	id: int,
	at: time.Tick,
}

Report_Flag :: enum u8 {
	Warning,
	Quiet, // no toast: the change shows by itself (masking, hiding, clipping)
	Undo, // offer Undo for the undo step just recorded
	Busy, // something is under way, not done: a neutral toast, not a success
}
Report_Flags :: bit_set[Report_Flag;u8]

// Logs `format` and keeps it as the latest result.
report :: proc(app: ^App, section: Maybe(Kit_Section), flags: Report_Flags, format: string, args: ..any) {
	text := fmt.aprintf(format, ..args)
	if .Warning in flags do log.warn(text)
	else do log.info(text)
	results_destroy(app)
	app.result = {
		text    = text,
		section = section,
		flags   = flags,
		at      = time.tick_now(),
	}
	if .Undo in flags do app.result.undo = undo_mark(app.history.done[:])
}

// The newest undo step, or nil with none.
undo_mark :: proc(done: []History_Entry) -> Maybe(Undo_Mark) {
	if len(done) == 0 do return nil
	e := done[len(done) - 1]
	return Undo_Mark{e.id, e.at}
}

// Whether `mark` is still the newest step: what Undo would take back now.
undo_mark_on_top :: proc(done: []History_Entry, mark: Undo_Mark) -> bool {
	top, ok := undo_mark(done).?
	return ok && top == mark
}

// Whether the newest step rebuilt, added or removed an object (a swap) at or after
// `since`: a scene command's own step, not a stroke it finished first.
swap_since :: proc(done: []History_Entry, since: time.Tick) -> bool {
	if len(done) == 0 do return false
	e := done[len(done) - 1]
	return e.swap != nil && time.tick_diff(since, e.at) >= 0
}

// Adds a second line to the result just reported, for its section only.
report_detail :: proc(app: ^App, format: string, args: ..any) {
	delete(app.result.detail)
	app.result.detail = fmt.aprintf(format, ..args)
	log.info(app.result.detail)
}

// The latest result if it belongs to `section`: what the section shows as its last.
result_for :: proc(app: ^App, section: Kit_Section) -> (Op_Result, bool) {
	if s, ok := app.result.section.?; ok && s == section && app.result.text != "" do return app.result, true
	return {}, false
}

results_destroy :: proc(app: ^App) {
	delete(app.result.text)
	delete(app.result.detail)
	app.result = {}
}

// The section's last result, if the latest is its: the line, and any detail under it.
kit_last_result :: proc(app: ^App, section: Kit_Section) {
	r, ok := result_for(app, section)
	if !ok do return
	ctx := &app.kit.ctx
	ui.paragraph(ctx, fmt.tprintf("Last: %s.", r.text))
	if r.detail != "" do ui.paragraph(ctx, r.detail)
}

// What the destructive scene commands report when they do not say more themselves, and
// the section that shows it (none for Delete: the object and its sections are gone).
@(private = "file")
SCENE_REPORTS := #partial [type_of(Scene_Command{}.kind)]struct {
	verb:    string,
	section: Maybe(Kit_Section),
} {
	.Delete        = {"Deleted %s", nil},
	.Remesh        = {"Remeshed %s", .Remesh},
	.Decimate      = {"Decimated %s", .Remesh},
	.Retopo        = {"Retopologized %s", .Retopo},
	.Symmetrize    = {"Mirrored and welded %s", .Mirror},
	.Slice         = {"Sliced %s in two", .Visibility},
	.Boolean       = {"Made %s from the boolean", .Booleans},
	.Extract       = {"Extracted a shell from %s", .Extract},
	.Delete_Higher = {"Deleted the levels above on %s", .Levels},
	.Delete_Lower  = {"Deleted the levels below on %s", .Levels},
}

// Runs a deferred scene command (scene_apply) and, when a destructive one left an undo
// step, reports it with Undo offered. Returns false only on a fatal GPU failure.
scene_run :: proc(app: ^App, cmd: Scene_Command) -> bool {
	what := SCENE_REPORTS[cmd.kind]
	if what.verb == "" do return scene_apply(app, cmd)
	// A stroke still going ends first, as its own step, so it is not taken for the
	// command's.
	stroke_finish(app)
	op := adjust_op_of(cmd.kind)
	if cmd.adjust && !adjust_begin(app, op) do return true
	named := selected_object(app)
	if cmd.kind == .Boolean do named = boolean_base(app)
	source := named.id if named != nil else 0
	// A copy of its own: the object may be gone after, and the command may free temp memory.
	label := strings.clone(object_label(named) if named != nil else "")
	defer delete(label)
	start := time.tick_now()
	ok := scene_apply(app, cmd)
	if !swap_since(app.history.done[:], start) {
		if cmd.adjust && ok do adjust_unchanged(app)
		return ok
	}
	ms := time.duration_milliseconds(time.tick_since(start))
	if app.result.at == {} || time.tick_diff(start, app.result.at) < 0 {
		// It said nothing itself.
		vertices := -1
		#partial switch cmd.kind {
		case .Remesh, .Decimate, .Symmetrize:
			if obj := selected_object(app); obj != nil do vertices = object_vertex_count(obj)
		}
		report(app, what.section, {}, "%s", scene_report_line(what.verb, label, vertices, ms))
	}
	app.result.flags += {.Undo}
	app.result.undo = undo_mark(app.history.done[:])
	if op != .None do adjust_set(app, op, cmd, source)
	return ok
}

// "Remeshed Sphere 1: 1,002,113 vertices (312 ms)"; no vertex count when `vertices` < 0,
// no time under 50 ms, which reads as at once.
scene_report_line :: proc(verb, label: string, vertices: int, ms: f64) -> string {
	line := fmt.tprintf(verb, label if label != "" else "the object")
	if vertices >= 0 do line = fmt.tprintf("%s: %s vertices", line, thousands(vertices))
	if ms >= 50 do line = fmt.tprintf("%s (%.0f ms)", line, ms)
	return line
}
