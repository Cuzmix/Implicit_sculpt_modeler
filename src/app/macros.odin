package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

import "../sculpt"
import "../ui"

// Macros, as ZBrush's: Record macro keeps every command run from then on, by any route
// (a key, a button, a menu, the palette, a pie), as a line of a command script
// (script.odin); Stop asks for a name and keeps the script in one of MACRO_SLOTS numbered
// slots, a plain text file in the macros folder beside the settings file; Run macro N
// runs it through the script runner as the person's own work, each command its own undo
// step. Strokes, turns of the view, drags and clicks on objects are not commands and are
// not recorded, so a macro acts on whatever is selected when it runs.

MACRO_SLOTS :: 16
MACRO_FOLDER :: "macros"

Macro :: struct {
	name: string, // heap; "" for a free slot
	text: string, // heap: the script
}

// A value a recorded command read from its panel, as the `set` line before it says it.
Macro_Value :: struct {
	key, text: string, // heap
}

// One recorded command: its lines (the `set`s for what it read that differ from the
// recording's last, then itself), the values those lines set, and the undo step it made,
// so that undoing that step takes it out of the recording again.
Macro_Entry :: struct {
	text:   string, // heap
	values: []Macro_Value, // heap
	mark:   Maybe(Undo_Mark),
}

// A command whose scene command applies at the start of the next frame: recorded once
// that has changed the scene, dropped when it changed nothing or warned.
Macro_Pending :: struct {
	active: bool,
	id:     Command_Id,
	arg:    int,
	sets:   string, // heap
	values: []Macro_Value, // heap
	mark:   Maybe(Undo_Mark), // the History's top before it
	at:     time.Tick,
}

Macro_State :: struct {
	recording:   bool,
	entries:     [dynamic]Macro_Entry,
	left_out:    int, // commands run that a macro cannot hold (open, save, export...)
	pending:     Macro_Pending,
	slots:       [MACRO_SLOTS]Macro,
	folder:      string, // heap; "" when this run keeps no files
	runs, steps: int, // macros started, and the statements macros and script files ran, for the exit stats
	scripts:     int, // script files started (Run script)
}

// The popover Stop opens: the new macro's name, Save and Discard.
Macro_Save_Entry :: struct {
	open:   bool,
	typing: bool, // its field had the keys, which go back when it closes
	at:     ui.Rect, // the recording chip, which it hangs under
	text:   [NAME_BYTES]u8,
}

// What a command is to a recording.
@(private = "file")
Macro_Kind :: enum u8 {
	Record,
	Skip, // the interface, the view, routes to other commands, and undo: not recorded or counted
	Left_Out, // asks for a file or a pick a script cannot give: counted in the save note
}

@(private = "file")
macro_kind :: proc(id: Command_Id) -> Macro_Kind {
	#partial switch id {
	case .None, .Undo, .Redo, .Macro_Record, .Run_Macro, .Run_Plugin, .Reload_Plugins:
		return .Skip
	case .Inspector, .Objects_Card, .Show_Section, .Pin_Section, .Panels_Reset, .Workspace, .Workspace_Save, .Workspace_Save_As, .Workspace_Revert, .Workspace_Reset, .Workspace_Rename, .Workspace_Delete, .Workspace_Export, .Workspace_Import, .View_Pass, .View_Pass_Last, .View_Grid, .View_Wipe, .View_Guides, .View_Guides_Reset, .Render_Preview, .View_Window, .View_Windows_Close, .Settings, .Help, .Stats, .Coach_Tips, .Adjust_Last, .Reduce_Motion, .Left_Handed, .Macros, .Library, .New_Dock, .Stack_Density:
		return .Skip
	case .View_Axis, .Focus_Selected, .Frame_All, .Reset_Camera, .View_Back, .View_Forward:
		return .Skip
	case .Command_Palette, .Pie, .Pie_Editor, .Brush_Pie, .Brush_Value:
		return .Skip
	case .New_Scene:
		return .Left_Out
	}
	return .Record if script_allows(id) else .Left_Out
}

// The values each command reads from its panel when it runs, by the keys `set` takes:
// a replay sets them first, so it does what the command did then, whatever the panel
// holds when it runs.
@(private = "file")
macro_reads :: proc(app: ^App, id: Command_Id, arg: int) -> []string {
	@(static, rodata) SMOOTH := []string{"smooth_steps", "smooth_strength"}
	@(static, rodata) MIRROR := []string{"mirror_axis", "mirror_negative"}
	@(static, rodata) HOLES := []string{"holes_leave_largest"}
	@(static, rodata) WELD := []string{"weld_distance"}
	@(static, rodata) EVEN := []string{"rebuild_goal", "rebuild_even"}
	@(static, rodata) FEWER := []string{"rebuild_goal", "rebuild_fewer"}
	@(static, rodata) QUADS := []string{"rebuild_goal", "retopo_quads"}
	@(static, rodata) RETOPO := []string{"retopo_quads"}
	@(static, rodata) EXTRACT := []string{"extract_thickness"}
	@(static, rodata) BOOLEAN := []string{"boolean_vertices"}
	@(static, rodata) MASK := []string{"mask_steps"}
	@(static, rodata) CREASES := []string{"crease_degrees"}
	@(static, rodata) MASK_BY := []string{"mask_by_strength", "mask_by_blur", "mask_by_curve", "crease_degrees", "paint_color"}
	@(static, rodata) MASK_ADJUST := []string{"mask_adjust_blur", "mask_adjust_curve"}
	@(static, rodata) PAINT := []string{"paint_color"}
	@(static, rodata) ADD := []string{"new_shape", "new_vertices", "new_voxels"}
	#partial switch id {
	case .Smooth_All:     return SMOOTH
	case .Mirror_Weld, .Delete_Half: return MIRROR
	case .Close_Holes:    return HOLES
	case .Weld_Points:    return WELD
	case .Retopologize:   return RETOPO
	case .Extract_Masked: return EXTRACT
	case .Make_Boolean:   return BOOLEAN
	case .Add_Object:
		// A content pack's mesh is named by its own line (macro_statement).
		if _, mesh := pack_mesh_at(app, app.kit.add_mesh - 1); mesh do return nil
		return ADD
	case .Rebuild:
		switch app.ui.rebuild_goal {
		case .Even:  return EVEN
		case .Fewer: return FEWER
		case .Quads: return QUADS
		}
	case .Mask:
		#partial switch sculpt.Mask_Command(arg) {
		case .Blur, .Sharpen, .Grow, .Shrink: return MASK
		}
	case .Mask_By:     return MASK_BY
	case .Mask_Adjust: return MASK_ADJUST
	case .Group:
		#partial switch sculpt.Group_Command(arg) {
		case .Creases, .Normals: return CREASES
		}
	case .Paint:
		if sculpt.Paint_Command(arg) == .Fill do return PAINT
	}
	return nil
}

// A value's text as a `set` line writes it: a row's as the settings file has it, a
// line's as its `text` gives it.
macro_value_text :: proc(app: ^App, key: string) -> string {
	if row, ok := script_setting(key); ok do return setting_text(app, row)
	if line := setting_line(key); line.text != nil do return line.text(app)
	return ""
}

// The recording's last value for `key`, from the newest entry that set it.
@(private = "file")
macro_last_value :: proc(m: ^Macro_State, key: string) -> (string, bool) {
	#reverse for e in m.entries do for v in e.values do if v.key == key do return v.text, true
	return "", false
}

// What command_run notes before running a command, for macro_log after it.
Macro_Before :: struct {
	mark: Maybe(Undo_Mark),
	at:   time.Tick,
}

macro_before :: proc(app: ^App) -> Macro_Before {
	return {undo_mark(app.history.done[:]), time.tick_now()}
}

// Records the command just run, if a recording is on: at once, or, when it queued a
// scene command, once that has applied (macro_settle).
macro_log :: proc(app: ^App, id: Command_Id, arg: int, before: Macro_Before) {
	m := &app.macro
	if !m.recording || app.script.running do return
	switch macro_kind(id) {
	case .Skip:
		return
	case .Left_Out:
		m.left_out += 1
		return
	case .Record:
	}
	// A command queued before this one in the same frame was replaced and never runs.
	macro_pending_drop(m)
	sets := strings.builder_make()
	values := make([dynamic]Macro_Value)
	for key in macro_reads(app, id, arg) {
		text := macro_value_text(app, key)
		if last, ok := macro_last_value(m, key); ok && last == text do continue
		fmt.sbprintfln(&sets, "set %s %s", key, text)
		append(&values, Macro_Value{strings.clone(key), strings.clone(text)})
	}
	m.pending = {true, id, arg, strings.to_string(sets), values[:], before.mark, before.at}
	if app.ui.scene_command.kind == .None do macro_settle(app, true)
}

// Records or drops the command waiting for its scene command, now that it has applied
// (`changed`: whether it changed the scene). A command that warned did nothing.
macro_settle :: proc(app: ^App, changed: bool) {
	m := &app.macro
	p := m.pending
	if !p.active do return
	warned := .Warning in app.result.flags && time.tick_diff(p.at, app.result.at) >= 0
	if !changed || warned || !m.recording {
		macro_pending_drop(m)
		return
	}
	m.pending = {}
	mark := undo_mark(app.history.done[:])
	if mark == p.mark do mark = nil
	text := fmt.aprintf("%s%s", p.sets, macro_statement(app, p.id, p.arg))
	delete(p.sets)
	append(&m.entries, Macro_Entry{text, p.values, mark})
}

@(private = "file")
macro_pending_drop :: proc(m: ^Macro_State) {
	p := &m.pending
	if !p.active do return
	delete(p.sets)
	macro_values_free(p.values)
	p^ = {}
}

@(private = "file")
macro_values_free :: proc(values: []Macro_Value) {
	for v in values {
		delete(v.key)
		delete(v.text)
	}
	delete(values)
}

// The command as a script statement, as it left things: a choice by its name, a switch
// as the state it is in now (so a replay sets it rather than flips it), HD by whether it
// is open now.
@(private = "file")
macro_statement :: proc(app: ^App, id: Command_Id, arg: int) -> string {
	c := COMMANDS[id]
	name := script_name(fmt.tprint(id))
	switch {
	case id == .Hd_Toggle:
		obj := selected_object(app)
		return "hd_sculpt" if obj != nil && object_in_hd(obj) else "hd_leave"
	case id == .Add_Object && app.kit.add_mesh > 0:
		if m, ok := pack_mesh_at(app, app.kit.add_mesh - 1); ok do return fmt.tprintf("pack_mesh %s/%s", m.pack, m.stem)
	case c.args > 0:
		return fmt.tprintf("%s %s", name, script_name(command_arg_name(id, arg)))
	case c.checked != nil:
		return fmt.tprintf("%s %s", name, "on" if c.checked(app, arg) else "off")
	}
	return name
}

// An undo while recording: when the step it takes back is the newest recorded command's,
// that command leaves the recording too, as if it had not been run.
macro_undoing :: proc(app: ^App) {
	m := &app.macro
	if !m.recording || len(m.entries) == 0 do return
	e := m.entries[len(m.entries) - 1]
	if mark, ok := e.mark.?; ok && undo_mark_on_top(app.history.done[:], mark) {
		macro_entry_free(e)
		pop(&m.entries)
	}
}

@(private = "file")
macro_entry_free :: proc(e: Macro_Entry) {
	delete(e.text)
	macro_values_free(e.values)
}

@(private = "file")
macro_recording_clear :: proc(m: ^Macro_State) {
	macro_pending_drop(m)
	for e in m.entries do macro_entry_free(e)
	clear(&m.entries)
	m.left_out = 0
}

// Record macro: starts a recording, or stops it and asks what to call it.
macro_record_toggle :: proc(app: ^App) {
	m := &app.macro
	if !m.recording {
		macro_recording_clear(m)
		m.recording = true
		report(app, nil, {.Quiet}, "Recording a macro: the commands you run go into it; strokes and view changes do not")
		return
	}
	m.recording = false
	macro_pending_drop(m)
	if len(m.entries) == 0 {
		report(app, nil, {}, "Stopped recording: no commands were recorded%s", macro_left_out_text(m))
		macro_recording_clear(m)
		return
	}
	k := &app.kit
	kit_floats_close(k)
	k.macro_save = {open = true, at = k.macro_chip}
}

@(private = "file")
macro_left_out_text :: proc(m: ^Macro_State) -> string {
	if m.left_out == 0 do return ""
	return fmt.tprintf("; %d command%s that ask for a file or a pick on screen %s left out", m.left_out, "" if m.left_out == 1 else "s", "was" if m.left_out == 1 else "were")
}

// The first slot without a macro, or -1.
macro_free_slot :: proc(m: ^Macro_State) -> int {
	for s, i in m.slots do if s.name == "" do return i
	return -1
}

// The recording as a script: a comment with its name, then each command's lines.
macro_text :: proc(m: ^Macro_State, name: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintfln(&b, "# Macro: %s", name)
	for e in m.entries do fmt.sbprintln(&b, e.text)
	return strings.to_string(b)
}

// The slot's file.
macro_path :: proc(m: ^Macro_State, slot: int) -> string {
	path, _ := filepath.join({m.folder, fmt.tprintf("macro-%02d.cmd", slot + 1)}, context.temp_allocator)
	return path
}

// Keeps the recording as a macro named `name` in the first free slot, and its file.
// False, with a note, when every slot is taken or the file cannot be written: the
// recording stays for another try.
macro_save :: proc(app: ^App, name: string) -> bool {
	m := &app.macro
	slot := macro_free_slot(m)
	if slot < 0 {
		report(app, nil, {.Warning}, "All %d macro slots hold a macro: delete one first (its file is in %s)", MACRO_SLOTS, m.folder)
		return false
	}
	text := macro_text(m, name)
	if m.folder != "" {
		if err := os.make_directory_all(m.folder); err != nil && !os.exists(m.folder) {
			report(app, nil, {.Warning}, "Cannot save the macro: %v", err)
			delete(text)
			return false
		}
		if err := write_durably(macro_path(m, slot), transmute([]u8)text); err != "" {
			report(app, nil, {.Warning}, "Cannot save the macro: %s", err)
			delete(text)
			return false
		}
	}
	m.slots[slot] = {strings.clone(name), text}
	n := len(m.entries)
	kept := "" if m.folder != "" else "; this run keeps no files, so it lasts until the app closes"
	report(app, nil, {}, "Saved macro %s as Macro %d: %d step%s%s; strokes and view changes are not recorded%s", name, slot + 1, n, "" if n == 1 else "s", macro_left_out_text(m), kept)
	macro_recording_clear(m)
	return true
}

// Drops the recording without keeping it.
macro_discard :: proc(app: ^App) {
	macro_recording_clear(&app.macro)
	report(app, nil, {}, "Discarded the macro recording")
}

// The folder macros are kept in: `macros` beside the settings file, or, for a settings
// file of another name (--settings-file), `<its name>-macros`, so runs given their own
// settings keep their own macros.
macros_folder :: proc(settings: string) -> string {
	if settings == "" do return ""
	dir, base := filepath.split(settings)
	name := MACRO_FOLDER if base == SETTINGS_FILE else fmt.tprintf("%s-%s", filepath.stem(base), MACRO_FOLDER)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

// Reads the macros kept in `folder` (macros_folder), slot by slot. A file
// that is there takes its slot even when it is not a script that runs: running it says
// what is wrong, and it is the person's to fix.
macros_load :: proc(app: ^App, folder: string) {
	m := &app.macro
	m.folder = strings.clone(folder)
	if folder == "" do return
	for &s, i in m.slots {
		data, err := os.read_entire_file(macro_path(m, i), context.allocator)
		if err != nil do continue
		text := string(data)
		name := fmt.tprintf("Macro %d", i + 1)
		first := text
		if at := strings.index_byte(text, '\n'); at >= 0 do first = text[:at]
		if strings.has_prefix(first, "# Macro:") {
			if given := strings.trim_space(first[len("# Macro:"):]); given != "" do name = given
		}
		s = {strings.clone(name), text}
	}
}

macros_destroy :: proc(app: ^App) {
	m := &app.macro
	macro_recording_clear(m)
	delete(m.entries)
	for s in m.slots {
		delete(s.name)
		delete(s.text)
	}
	delete(m.folder)
	m^ = {}
}

// Takes a command slot that is going (a deleted macro, a forgotten plugin command) out
// of everything that runs it by number: its key, pie slots, star, gestures and recent
// searches, so nothing later put in the slot inherits them. Whether any of it changed.
command_slot_forget :: proc(app: ^App, id: Command_Id, slot: int) -> bool {
	at := Pie_Slot{id, slot}
	changed := key_override_find(app, id, slot) >= 0
	if changed do bind_reset(app, id, slot)
	k := &app.kit
	for &pie in k.pies do for &p in pie do if p == at {
		p = {}
		changed = true
	}
	if favourite_find(app, id, slot) >= 0 {
		_ = favourite_toggle(app, id, slot)
		changed = true
	}
	for &g in app.nav.gestures do if g == at {
		g = {}
		changed = true
	}
	kept := 0
	for e in k.palette_recent[:k.palette_recent_count] {
		if e.kind == .Command && e.id == id && e.arg == slot do continue
		k.palette_recent[kept] = e
		kept += 1
	}
	changed ||= kept != k.palette_recent_count
	for &e in k.palette_recent[kept:k.palette_recent_count] do e = {}
	k.palette_recent_count = kept
	return changed
}

// Whether a macro or a script file can start now. Not while a recording is on (the
// script's commands would not be recorded, and a macro would record itself), a script or
// another macro runs, a plugin's command or a reload waits for the next frame, a stroke
// or drag is under way, or a save or a file dialog waits.
script_can_start :: proc(app: ^App) -> bool {
	return !app.macro.recording && !app.long_job.on && !app.script.running && app.plugins.pending == 0 && !app.plugins.reload && !pie_busy(app) && app.saving.kind == .None && !file_pending()
}

// Run macro N: whether it can run now.
macro_can_run :: proc(app: ^App, slot: int) -> bool {
	return app.macro.slots[slot].name != "" && script_can_start(app)
}

// Starts `text` at the next frame's start as the person's work, each command its own
// undo step; `what` names it in the notes ("macro Zebra", "bevel.cmd"). False, with its
// first error in a warning note, when the text has one: nothing of it runs then.
@(private = "file")
script_work_start :: proc(app: ^App, text, what: string) -> bool {
	if errors := script_start(app, text, what, setup = false, scripted = false); errors != "" {
		first := errors
		if at := strings.index_byte(errors, '\n'); at >= 0 do first = errors[:at]
		report(app, nil, {.Warning}, "Cannot run %s: %s", what, strings.trim_prefix(first, "script: "))
		return false
	}
	return true
}

// Starts the macro in `slot`, at the next frame's start, as the person's work.
macro_run :: proc(app: ^App, slot: int) {
	m := &app.macro
	if script_work_start(app, m.slots[slot].text, fmt.tprintf("macro %s", m.slots[slot].name)) do m.runs += 1
}

// Run script: the file the dialog picked runs as a macro does, without being kept.
script_file_run :: proc(app: ^App, path: string) {
	name := filepath.base(path)
	if !script_can_start(app) {
		report(app, nil, {.Warning}, "Cannot run %s now: a recording, a script, a stroke or a save is under way", name)
		return
	}
	data, err := file_read_any(path, context.temp_allocator)
	if err != nil {
		report(app, nil, {.Warning}, "Cannot read %s: %v", name, err)
		return
	}
	if script_work_start(app, string(data), name) do app.macro.scripts += 1
}

// Gives the macro in `slot` a new name, in its file's first line too. False, with a
// note, when the file cannot be written: the name stays as it was.
macro_rename :: proc(app: ^App, slot: int, name: string) -> bool {
	m := &app.macro
	s := &m.slots[slot]
	if s.name == "" || name == s.name do return s.name != ""
	// The first line names the macro when it is a `# Macro:` comment; otherwise one goes
	// in front of the person's own lines.
	body := s.text
	if strings.has_prefix(body, "# Macro:") {
		at := strings.index_byte(body, '\n')
		body = body[at + 1:] if at >= 0 else ""
	}
	text := fmt.aprintf("# Macro: %s\n%s", name, body)
	if m.folder != "" {
		if err := write_durably(macro_path(m, slot), transmute([]u8)text); err != "" {
			report(app, nil, {.Warning}, "Cannot rename the macro: %s", err)
			delete(text)
			return false
		}
	}
	report(app, nil, {.Quiet}, "Renamed macro %s to %s", s.name, name)
	delete(s.name)
	delete(s.text)
	s^ = {strings.clone(name), text}
	return true
}

// Deletes the macro in `slot` and its file, and takes Run macro N off every key, pie
// slot, star, gesture and recent search that ran it, so that a macro saved in the slot
// later runs from none of them until it is given its own. False, with a note, when the
// file cannot be deleted: the macro stays.
macro_delete :: proc(app: ^App, slot: int) -> bool {
	m := &app.macro
	s := &m.slots[slot]
	if s.name == "" do return false
	if m.folder != "" {
		path := macro_path(m, slot)
		if err := os.remove(path); err != nil && os.exists(path) {
			report(app, nil, {.Warning}, "Cannot delete the macro: %v", err)
			return false
		}
	}
	changed := command_slot_forget(app, .Run_Macro, slot)
	// What ran it is remembered in the settings file, which says so at once.
	if changed && app.settings_file != "" do _ = settings_save(app, app.settings_file)
	report(app, nil, {}, "Deleted macro %s", s.name)
	delete(s.name)
	delete(s.text)
	s^ = {}
	return true
}

// Opens the Macros panel in the inspector's place, unfolded and in front.
macros_open :: proc(app: ^App) {
	k := &app.kit
	if k.settings do settings_close(app)
	k.help, k.macros, k.library, k.macro_armed = false, true, false, 0
	k.windows[.Macros].minimized = false
	window_raise(k, .Macros)
}

// The red chip at the top of the viewport while a recording is on: what it holds so far,
// and Stop.
kit_macro_chip :: proc(app: ^App) {
	m := &app.macro
	k := &app.kit
	if !m.recording do return
	ctx := &k.ctx
	t := ctx.theme
	stop_w := ui.text_width(ctx, "Stop", t.text_size, .Semibold) + 28
	shift, w, top, fits := kit_card_place(app, 340, 220)
	if !fits do return
	n := len(m.entries)
	ui.begin_anchored(ctx, "macro chip", .Center, .Start, {shift, top}, {direction = .Row, gap = 10, padding = 8, width = w, radius = t.radius_large + 4, background = .Panel, center = true})
	ui.begin(ctx, "macro dot", {width = 20, height = 20})
	ui.end(ctx)
	r := ctx.last_rect
	ui.icon(ctx, ui.ICON_RECORD, {r.x + 10, r.y + 10}, t.icon_size, t.danger)
	ui.begin(ctx, "macro words", {direction = .Column, width = w - 2 * 8 - 20 - 2 * 10 - stop_w})
	ui.label(ctx, "Recording macro", font = .Semibold, color = t.text)
	ui.label(ctx, fmt.tprintf("%d command%s", n, "" if n == 1 else "s"), t.caption_size, t.text_tertiary)
	ui.end(ctx)
	stop := ui.button(ctx, "Stop", .Light, .Danger, width = stop_w, keys = command_hint(app, .Macro_Record))
	ui.end(ctx)
	k.macro_chip = ctx.last_rect
	if stop do _ = command_run(app, .Macro_Record)
}

// The popover Stop opens under the chip: the name, then Save or Discard. Enter saves.
kit_macro_save :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.macro_save
	if !p.open && p.typing {
		ctx.text_focus = 0
		p.typing = false
		// Closed by Escape, Back or a tap elsewhere rather than Save: as Discard.
		if m := &app.macro; len(m.entries) > 0 && !m.recording do macro_discard(app)
	}
	if !ui.popover_begin(ctx, "macro save", &p.open, p.at, .Below_End, {direction = .Column, gap = 4, padding = 12, width = 300}) do return
	defer ui.popover_end(ctx)
	m := &app.macro
	n := len(m.entries)
	ui.caption(ctx, "SAVE MACRO")
	default_name := fmt.tprintf("Macro %d", max(macro_free_slot(m), 0) + 1)
	_ = ui.text_field(ctx, "name##macro", p.text[:len(p.text) - 1], hold = p.open, hint = default_name)
	p.typing ||= p.open
	ui.paragraph(ctx, fmt.tprintf("%d command%s%s. Strokes and view changes are not recorded; it acts on what is selected when it runs.", n, "" if n == 1 else "s", macro_left_out_text(m)))
	save, discard := kit_button_pair(ctx, "Save", "Discard", tone_a = .Accent)
	d := &app.device
	save ||= p.open && (key_pressed(d, sdl.K_RETURN) || key_pressed(d, sdl.K_KP_ENTER))
	if save && p.open {
		name := rename_text(p.text[:])
		if name == "" do name = default_name
		if macro_save(app, name) do p.open = false
	}
	if discard {
		macro_discard(app)
		p.open = false
	}
}
