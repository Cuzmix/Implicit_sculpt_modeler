package main

import "core:fmt"
import "core:log"

import "../geom"
import "../sculpt"
import "../ui"

// The check before a heavy step. A remesh or a subdivision of a dense object needs, for a
// few seconds, the object as it is, its undo copy, the remesh thread's copy of its
// triangles and the new mesh all at once; on the iPad that can pass what the system lets
// the app take, and the system then ends the app without a word, as Nomad's developer
// says of Nomad ("if you hit the memory limit it's over, the app quits"). So before such a
// step the app compares what it will need with what the system says it may still take
// (memory_headroom) and, when it does not fit, asks first: free the undo history and go
// on, a smaller count, go on anyway after an autosave, or cancel. No app compared in the
// plan checks before the step; their undo budgets are the whole answer, and this keeps
// ours (History may use) beside it.
//
// The costs per vertex were measured on a 15M object (a scratch probe over geom and
// sculpt, 4 threads): an object ready to sculpt holds about 120 bytes a vertex on the CPU
// and 40 on the GPU, a remesh's lattice peaks at about 116 bytes a vertex it makes, and
// making the result ready about 74 more while the old object is still alive. Each check
// writes one `memory:` log line, so a device's crash log shows how far the estimate was.

// What a check found and the step it holds back while the person decides.
Memory_Ask :: struct {
	on:      bool,
	cmd:     Scene_Command, // the step, run again with `checked` once decided
	object:  int, // the object it was asked for: a change of selection drops the ask
	need:    int, // bytes the step needs while it runs, its undo copy included
	free:    int, // bytes the system said the app may still take
	history: int, // bytes the undo history holds, which Free history gives back
	fits:    bool, // whether freeing the history makes it fit
	smaller: int, // the largest count that fits once the history is freed, 0 for none
	remember: bool, // Remember my choice, as the popup's switch is set
	// Continue anyway waits here for the autosave it started before running the step.
	saving:  bool,
	// What the exit stats count: asks shown, and each answer.
	asks, freed, smaller_runs, continued, cancelled: int,
}

// Settings > Files > Undo history: what a step that needs memory the history holds does
// without asking, once the person said so on the popup.
Memory_Short :: enum u8 {
	Ask,
	Free_History,
	Continue,
}

// In Memory_Short's order.
MEMORY_SHORT_NAMES := [?]string{"Ask", "Free older history", "Continue anyway"}
#assert(len(MEMORY_SHORT_NAMES) == len(Memory_Short))

// The commands the check comes before: the ones that build a dense mesh beside the one
// there is. Decimate and Quad Remesh make fewer vertices than they read and are left out
// until their own peaks are measured.
MEMORY_CHECKED :: bit_set[Scene_Command_Kind]{.Remesh, .Subdivide}

// Bytes per vertex, from the measurement above.
MEMORY_OBJECT_BYTES :: 160 // an object ready to sculpt: 120 on the CPU, 40 on the GPU
MEMORY_REMESH_BYTES :: 116 // a remesh's lattice, per vertex it makes
MEMORY_READY_BYTES :: 74 // making that ready to sculpt, while the old object lives
MEMORY_SNAPSHOT_BYTES :: 40 // the undo copy of the object as it was, per vertex of every level
MEMORY_COPY_BYTES :: 36 // the remesh thread's copy of the level: a position and two triangles a vertex
// The share of what the system says the app may take that a step may plan on: the rest
// is for what the frame itself allocates meanwhile, and for the estimate being low.
MEMORY_MARGIN :: 0.9
// A smaller count under this is no help: it would lose more than it keeps.
MEMORY_SMALLEST :: 100_000

// What `cmd` needs on `obj` while it runs, in bytes, and for a remesh what each vertex it
// makes adds on top of what does not depend on its count (`fixed`), for the smaller count.
memory_need :: proc(app: ^App, obj: ^Object, cmd: Scene_Command) -> (need, fixed, per_vertex: int) {
	all := 0
	for lv in obj.levels.levels do all += len(lv.mesh.positions)
	snapshot := MEMORY_SNAPSHOT_BYTES * all
	#partial switch cmd.kind {
	case .Remesh:
		source := object_vertex_count(obj)
		made := memory_remesh_count(app, obj, cmd)
		fixed = snapshot + MEMORY_COPY_BYTES * source
		per_vertex = max(MEMORY_REMESH_BYTES, MEMORY_OBJECT_BYTES + MEMORY_READY_BYTES)
		return fixed + per_vertex * made, fixed, per_vertex
	case .Subdivide:
		vertices, _, bytes := sculpt.levels_subdivide_estimate(&obj.levels)
		// Its GPU buffers beside the CPU's, and a copy of the object first when the top
		// level's sculpt layers move up (subdivide_record).
		need = bytes + (MEMORY_OBJECT_BYTES - 120) * vertices
		if len(obj.levels.levels[len(obj.levels.levels) - 1].sculptor.layers.list) > 0 do need += snapshot
		return need, need, 0
	}
	return 0, 0, 0
}

// About how many vertices a remesh of `obj` makes: the command's count, or at a cell size
// (Rebuild's Cell size, Remesh again) the surface's area over the cell's, which a remesh
// at a cell size fills with about 1.7 vertices a cell face (a 15M quad remesh measured).
memory_remesh_count :: proc(app: ^App, obj: ^Object, cmd: Scene_Command) -> int {
	cell := cmd.remesh.cell
	if cell <= 0 do return cmd.vertices
	area, _ := geom.mesh_area_bounds(sculpt.levels_current(&obj.levels).mesh, &app.pool)
	return int(1.7 * area / f64(cell * cell))
}

// Whether `cmd` waits for the person: it does when it is a heavy step on the selected
// object that does not fit what the system says the app may take. A step the check
// already passed, one run again in place of the last (Adjust last, which undoes and
// redoes within a frame), and one a macro, script or replay runs (no one to ask) go on
// as they are. With Remember my choice set, the remembered answer is taken instead of
// asking, except when even the freed history leaves too little: then it always asks.
memory_check_holds :: proc(app: ^App, cmd: Scene_Command) -> bool {
	if cmd.checked || cmd.adjust || cmd.kind not_in MEMORY_CHECKED do return false
	if app.macro.recording || app.macro.pending.active || app.script.running || replay_busy(app) do return false
	obj := selected_object(app)
	if obj == nil || obj.voxel != nil || obj.curve != nil || obj.cage != nil do return false
	free := app.memory_free_test << 20 if app.memory_free_test > 0 else memory_headroom()
	need, fixed, per_vertex := memory_need(app, obj, cmd)
	history, _ := history_memory(app)
	room := int(MEMORY_MARGIN * f64(free))
	room_freed := int(MEMORY_MARGIN * f64(free + history))
	log.infof("memory: %v needs about %d MB; the system leaves %d MB, the history holds %d MB", cmd.kind, need >> 20, free >> 20, history >> 20)
	if free <= 0 || need <= room do return false
	fits := need <= room_freed
	if fits && app.memory_short == .Free_History {
		memory_free_history(app)
		return false
	}
	if fits && app.memory_short == .Continue {
		memory_continue_start(app, cmd, obj, free_history = false)
		return true
	}
	smaller := 0
	if per_vertex > 0 && room_freed > fixed {
		smaller = memory_round_down((room_freed - fixed) / per_vertex)
		if smaller < MEMORY_SMALLEST || smaller >= cmd.vertices do smaller = 0
	}
	a := &app.memory_ask
	a.on, a.cmd, a.object, a.need, a.free, a.history, a.fits, a.smaller = true, cmd, obj.id, need, free, history, fits, smaller
	a.remember, a.saving = false, false
	a.asks += 1
	return true
}

// `n` rounded down to two figures (12,345,678 to 12M), as the Remesh to presets read.
memory_round_down :: proc(n: int) -> int {
	step := 1
	for n / step >= 100 do step *= 10
	return n / step * step
}

// Frees the undo history, what could be redone too, so a step has its memory: every step
// is gone, and the note says how much came back.
memory_free_history :: proc(app: ^App) {
	before, _ := history_memory(app)
	history_free_all(app)
	after, _ := history_memory(app)
	app.memory_ask.freed += 1
	file_note(app, false, "Freed the undo history (%s) to make room", bytes_label(before - after))
}

// Continue anyway: the step runs as it would without the check, after an autosave, so if
// the system ends the app the next start offers the scene back as it was just before.
// With `free_history`, the history goes first, as it is then too much to keep.
memory_continue_start :: proc(app: ^App, cmd: Scene_Command, obj: ^Object, free_history: bool) {
	a := &app.memory_ask
	if free_history do memory_free_history(app)
	a.on, a.cmd, a.object = true, cmd, obj.id
	a.continued += 1
	a.saving = autosave_now(app)
	if !a.saving do memory_ask_run(app)
}

// Runs the step the ask held back, marked as checked, at the start of the next frame.
@(private = "file")
memory_ask_run :: proc(app: ^App) {
	a := &app.memory_ask
	cmd := a.cmd
	cmd.checked = true
	a.on, a.saving = false, false
	if obj := selected_object(app); obj == nil || obj.id != a.object do return
	app.ui.scene_command = cmd
}

// Once a frame, before the scene command: an ask whose object is no longer selected goes,
// and Continue anyway's autosave, once written, lets its step run.
memory_ask_frame :: proc(app: ^App) {
	a := &app.memory_ask
	if !a.on do return
	if obj := selected_object(app); obj == nil || obj.id != a.object {
		a.on, a.saving = false, false
		return
	}
	if a.saving && !autosave_busy(app) do memory_ask_run(app)
}

// Whether the scene holds still for Continue anyway's autosave, as it does for a job.
memory_ask_holds :: proc(app: ^App) -> bool {
	return app.memory_ask.on && app.memory_ask.saving
}

// The popup, centred under the top bar as a sheet: what the step needs against what the
// system leaves, and the answers. A press outside it or Esc cancels.
kit_memory_ask :: proc(app: ^App) {
	a := &app.memory_ask
	if !a.on do return
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	open := true
	verb := memory_verb(a.cmd)
	what := fmt.tprintf("%s to %s", verb, memory_count_label(a.cmd.vertices)) if a.cmd.kind == .Remesh && a.cmd.remesh.cell <= 0 else verb
	title := fmt.tprintf("%s needs more memory", what) if a.fits else fmt.tprintf("%s won't fit right now", what)
	if a.saving do title = "Saving the scene first"
	inner, _, shown := sheet_begin(app, "memory ask", title, ICON_CHECK_WARN, &open, 440)
	if !shown do return
	defer sheet_end(app)
	if a.saving {
		ui.paragraph(ctx, fmt.tprintf("%s starts once the autosave is written, so if the system ends Sculpt the next start offers the scene back.", verb), inner, t.text_secondary)
		return
	}
	// What a step may plan on, as the check counts it, so the numbers read add up.
	room, back := int(MEMORY_MARGIN * f64(a.free)), int(MEMORY_MARGIN * f64(a.history))
	if a.fits {
		ui.paragraph(ctx, fmt.tprintf("It needs about %s while it runs, and Sculpt can take about %s more on this device. The undo history holds %s.", bytes_label(a.need), bytes_label(room), bytes_label(a.history)), inner)
	} else {
		ui.paragraph(ctx, fmt.tprintf("Even with the undo history freed it needs about %s, and Sculpt can take about %s on this device.", bytes_label(a.need), bytes_label(room + back)), inner)
	}
	memory_bar(ctx, inner, a.need, room, back)
	noun := "remesh" if a.cmd.kind == .Remesh else "subdivide"
	if a.fits && ui.button(ctx, fmt.tprintf("Free history and %s##memory free", noun), .Solid, .Accent, width = inner) {
		if a.remember do app.memory_short = .Free_History
		memory_free_history(app)
		memory_ask_run(app)
		return
	}
	if a.smaller > 0 && ui.button(ctx, fmt.tprintf("%s to %s instead##memory smaller", verb, memory_count_label(a.smaller)), .Light if a.fits else .Solid, .Neutral if a.fits else .Accent, width = inner) {
		a.cmd.vertices, a.cmd.remesh.cell = a.smaller, 0
		a.smaller_runs += 1
		if !a.fits do memory_free_history(app)
		memory_ask_run(app)
		return
	}
	go_on := "Continue anyway, keep history##memory go on" if a.fits else fmt.tprintf("Continue anyway at %s##memory go on", memory_count_label(a.cmd.vertices) if a.cmd.kind == .Remesh else "this size")
	if ui.button(ctx, go_on, .Light, .Danger, width = inner) {
		if a.remember do app.memory_short = .Continue
		obj := selected_object(app)
		if obj != nil do memory_continue_start(app, a.cmd, obj, free_history = !a.fits)
		return
	}
	if ui.button(ctx, "Cancel##memory cancel", .Light, width = inner, keys = "Esc") do open = false
	ui.paragraph(ctx, "Continue anyway saves the scene first, so if the system ends Sculpt you lose nothing." if a.fits else "Continue anyway frees the history, saves the scene and tries. The system may end Sculpt; the next start offers the saved scene back.", inner, t.text_tertiary)
	if a.fits do _ = ui.switch_row(ctx, "Remember my choice", &a.remember)
	if !open {
		a.on = false
		a.cancelled += 1
	}
}

// The bar under the words: the step's need against what is left, the history's share in
// its own colour, and where the device's room ends.
@(private = "file")
memory_bar :: proc(ctx: ^ui.Context, width: f32, need, free, history: int) {
	t := ctx.theme
	whole := f32(max(need, free + history))
	if whole <= 0 do return
	r := ui.place(ctx, {width, 10})
	ui.fill_rect(ctx, r, 5, t.track)
	ui.fill_rect(ctx, {r.x, r.y, r.w * f32(free) / whole, r.h}, 5, t.accent)
	ui.fill_rect(ctx, {r.x + r.w * f32(free) / whole, r.y, r.w * f32(history) / whole, r.h}, 0, t.warning)
	mark := r.x + r.w * f32(need) / whole
	ui.fill_rect(ctx, {mark - 1, r.y - 4, 2, r.h + 8}, 1, t.text)
	line := ui.place(ctx, {width, ui.line_height(t.small_size)})
	ui.text(ctx, fmt.tprintf("free %s · history %s", bytes_label(free), bytes_label(history)), line.x, line.y + line.h * 0.5, t.small_size, t.text_secondary)
	ui.text(ctx, fmt.tprintf("needs %s", bytes_label(need)), line.x + line.w, line.y + line.h * 0.5, t.small_size, t.text_secondary, .Regular, .Right)
}

@(private = "file")
memory_verb :: proc(cmd: Scene_Command) -> string {
	return "Voxel remesh" if cmd.kind == .Remesh else "Subdivide"
}

// A count as the Remesh to presets read it: 12M, 500k.
memory_count_label :: proc(n: int) -> string {
	if n >= 1_000_000 do return fmt.tprintf("%dM", n / 1_000_000) if n % 1_000_000 == 0 else fmt.tprintf("%.1fM", f64(n) / 1e6)
	if n >= 1000 do return fmt.tprintf("%dk", n / 1000)
	return fmt.tprintf("%d", n)
}
