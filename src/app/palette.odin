package main

import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

import "../camera"
import "../sculpt"
import "../ui"

// The command palette: every command the registry holds, and each Settings tab, found
// by typing part of its name, or a name another app gives it (DynaMesh, Freeze,
// SubTool...). Ctrl+K, `/` or the Search button opens it; Up and Down pick, Enter or a
// tap runs, Escape closes. What was run last comes first next time. It runs commands
// through command_run like every menu, so it shows the same shortcuts and states and
// does nothing the menus could not.

Palette_Kind :: enum u8 {
	Command,
	Settings_Tab,
}

// One thing the palette can run: a command with its argument, or a Settings tab (`arg`).
Palette_Entry :: struct {
	kind: Palette_Kind,
	id:   Command_Id,
	arg:  int,
}

// The most result rows shown at once (fewer when the window is short: palette_rows),
// and how many recent entries are kept.
PALETTE_ROWS :: 8
PALETTE_RECENT :: 8

// How many result rows fit in `room` points of height under the Search button, besides
// the field, the captions, the help and the padding: from 2 up to PALETTE_ROWS. A row is
// a touch target less 4, plus the column's gap of 2.
palette_rows :: proc(room, target: f32) -> int {
	fixed := 16 + (target + 2) + 2 * (22 + 2) + (1 + 2) + (56 + 2)
	return clamp(int((room - fixed) / (target - 2)), 2, PALETTE_ROWS)
}

// Other words each command is found by: names other apps give it and words people
// reach for. The label itself is always searched; the help sentence is not, since it
// would match nearly everything.
@(rodata)
SEARCH_WORDS := #partial [Command_Id]string {
	.Open_Scene       = "load file",
	.Save_Scene       = "file write",
	.Save_Scene_As    = "file write copy",
	.Import_Mesh      = "obj ply load append file",
	.Export_Mesh      = "obj ply file",
	.Screenshot       = "png capture image",
	.Undo             = "back revert",
	.Redo             = "forward",
	.Delete_Object    = "subtool remove",
	.Duplicate_Object = "subtool copy clone",
	.Tool_Move        = "select transform gizmo",
	.Tool_Sculpt      = "brush",
	.Tool_Curve       = "spline tube",
	.Tool_Insert      = "imm insert mesh",
	.Symmetry_X       = "mirror",
	.Size_Down        = "radius smaller draw size",
	.Size_Up          = "radius bigger draw size",
	.Strength_Down    = "intensity weaker",
	.Strength_Up      = "intensity stronger",
	.Replay_Stroke    = "record repeat stamp",
	.Remesh           = "dynamesh voxel",
	.Dyntopo_Toggle   = "dynamic topology sculptris tessellation",
	.Subdivide        = "divide smooth level",
	.Level_Up         = "subdivision higher",
	.Level_Down       = "subdivision lower",
	.Hd_Toggle        = "hd geometry",
	.Group_Shortcut   = "polygroup",
	.Mask             = "freeze",
	.Show_All         = "unhide visibility",
	.Invert_Hidden    = "visibility",
	.Paint            = "polypaint colour color",
	.Group            = "polygroup",
	.Delete_Lower_Levels  = "subdivision",
	.Delete_Higher_Levels = "subdivision",
	.Hd_Divide        = "hd geometry",
	.Hd_Delete        = "hd geometry",
	.Hd_Sculpt        = "hd geometry",
	.Hd_Leave         = "hd geometry",
	.Morph_Store      = "morph target",
	.Morph_Delete     = "morph target",
	.Smooth_All       = "relax",
	.Remesh_To        = "dynamesh voxel resolution",
	.Decimate_To      = "decimation master reduce simplify",
	.Mirror_Weld      = "symmetrize mirror",
	.Retopologize     = "zremesher quads retopo quad",
	.Make_Boolean     = "live boolean subtract union intersect",
	.Extract_Masked   = "extract shell",
	.Add_Object       = "subtool primitive append sphere cube",
	.Frame_All        = "fit zoom extents home",
	.View_Axis        = "camera",
	.Ortho_Toggle     = "orthographic perspective camera",
	.Focus_Selected   = "frame zoom fit",
	.Reset_Camera     = "home view",
	.Wireframe        = "edges polyframe",
	.Flat_Shading     = "faceted",
	.Polygroups       = "polyframe colours colors",
	.Studio_Render    = "bpr render",
	.Stats            = "performance fps statistics",
	.Inspector        = "panel properties",
	.Settings         = "preferences options",
	.Reduce_Motion    = "animation accessibility",
}

// The words each Settings tab is found by, besides its name.
@(rodata)
SETTINGS_SEARCH_WORDS := [Settings_Tab]string {
	.Interface   = "preferences scale size theme ui",
	.Camera      = "preferences orbit turn pivot",
	.Touch       = "preferences pen finger gesture tablet stylus pressure",
	.Performance = "preferences speed fps vsync threads",
}

// Every entry the palette searches, in the registry's order then the Settings tabs': a
// command with an argument once per argument. In the temp allocator.
palette_entries :: proc() -> []Palette_Entry {
	out := make([dynamic]Palette_Entry, 0, 128, context.temp_allocator)
	for id in Command_Id {
		if !palette_lists(id) do continue
		n := COMMANDS[id].args
		for arg in 0 ..< max(n, 1) do append(&out, Palette_Entry{.Command, id, arg})
	}
	for tab in Settings_Tab do append(&out, Palette_Entry{kind = .Settings_Tab, arg = int(tab)})
	return out[:]
}

// Whether the palette lists the command: not None, not itself, and not the two that act
// where the pointer is (A's HD window and R's replay), which over the palette would act
// on the palette's spot; the Object tab and Sculpt HD cover them.
palette_lists :: proc(id: Command_Id) -> bool {
	return id != .None && id != .Command_Palette && id != .Hd_Toggle && id != .Replay_Stroke
}

// Where a menu's own heading names what a label leaves out ("Delete" under the object's
// menu), the palette, which has no headings, says it.
@(rodata)
PALETTE_LABELS := #partial [Command_Id]string {
	.Delete_Object    = "Delete object",
	.Duplicate_Object = "Duplicate object",
	.Polygroups       = "Show polygroups",
	.Stats            = "Stats panel",
}

// What the palette shows for the entry.
palette_label :: proc(e: Palette_Entry) -> string {
	if e.kind == .Settings_Tab do return fmt.tprintf("Settings: %s", SETTINGS_TAB_NAMES[Settings_Tab(e.arg)])
	if COMMANDS[e.id].args == 0 && PALETTE_LABELS[e.id] != "" do return PALETTE_LABELS[e.id]
	return command_label(e.id, e.arg)
}

palette_words_of :: proc(e: Palette_Entry) -> string {
	if e.kind == .Settings_Tab do return SETTINGS_SEARCH_WORDS[Settings_Tab(e.arg)]
	return SEARCH_WORDS[e.id]
}

// How well an entry matched, best first: the label is the query, starts with it, has a
// word starting with each query word, has such a word among it and its other words, or
// holds the query's letters in order (fuzzy, scored by the gaps between them).
Palette_Tier :: enum u8 {
	Exact,
	Prefix,
	Words,
	Synonyms,
	Fuzzy,
	None,
}

// Lower case for ASCII letters; anything else is kept, so the result is the same length.
@(private = "file")
fold :: proc(s: string) -> string {
	b := make([]u8, len(s), context.temp_allocator)
	for i in 0 ..< len(s) do b[i] = s[i] + 32 if s[i] >= 'A' && s[i] <= 'Z' else s[i]
	return string(b)
}

// The words in folded `s`: runs of letters and digits.
@(private = "file")
words :: proc(s: string) -> []string {
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	start := -1
	for i in 0 ..= len(s) {
		word := i < len(s) && (s[i] >= 'a' && s[i] <= 'z' || s[i] >= '0' && s[i] <= '9' || s[i] >= 0x80)
		if word && start < 0 do start = i
		if !word && start >= 0 {
			append(&out, s[start:i])
			start = -1
		}
	}
	return out[:]
}

// Whether every query word starts some word in `pool`.
@(private = "file")
all_prefix :: proc(query, pool: []string) -> bool {
	for q in query {
		found := false
		for w in pool do if strings.has_prefix(w, q) {found = true; break}
		if !found do return false
	}
	return true
}

// The query's letters in order in `label`, or -1: the gaps between them times 100, plus
// where the first one is, so tighter and earlier matches score lower.
@(private = "file")
fuzzy :: proc(query, label: string) -> int {
	at, last, first, gaps := 0, -1, -1, 0
	for i in 0 ..< len(query) {
		c := query[i]
		if c == ' ' do continue
		for at < len(label) && label[at] != c do at += 1
		if at == len(label) do return -1
		if first < 0 do first = at
		if last >= 0 && at != last + 1 do gaps += 1
		last = at
		at += 1
	}
	return gaps * 100 + max(first, 0)
}

// How `label` and its other words match `query`; all three folded, the query trimmed.
palette_match :: proc(query, label, synonyms: string) -> (tier: Palette_Tier, score: int) {
	if query == "" do return .Exact, 0
	q := words(query)
	if len(q) == 0 do return .None, 0
	// Exact and prefix compare the words alone, so "settings" is "Settings..." exactly.
	lw := words(label)
	qj := strings.join(q, " ", context.temp_allocator)
	lj := strings.join(lw, " ", context.temp_allocator)
	if lj == qj do return .Exact, 0
	if strings.has_prefix(lj, qj) do return .Prefix, 0
	if all_prefix(q, lw) do return .Words, 0
	pool := make([dynamic]string, 0, len(lw) + 8, context.temp_allocator)
	append(&pool, ..lw)
	append(&pool, ..words(synonyms))
	if all_prefix(q, pool[:]) do return .Synonyms, 0
	// One or two letters in order match nearly every label, so fuzzy waits for three.
	if len(qj) >= 3 {
		if s := fuzzy(query, label); s >= 0 do return .Fuzzy, s
	}
	return .None, 0
}

Palette_Hit :: struct {
	entry:   int, // into the entries ranked
	tier:    Palette_Tier,
	score:   int,
	recent:  int, // where it is among the recents, or PALETTE_RECENT when it is not
	enabled: bool,
	length:  int, // the label's length
}

// The entries that match `query`, best first: by tier, then recent first, then those
// that can run now, then the tighter fuzzy match, then the shorter label, then the
// table's order, so equal matches always come in the same order. With no query every
// entry matches, recent first, then those that can run, then in the table's order.
// `enabled[i]` says whether entries[i] can run now. In the temp allocator.
palette_rank :: proc(query: string, entries: []Palette_Entry, recent: []Palette_Entry, enabled: []bool) -> []Palette_Hit {
	assert(len(enabled) == len(entries))
	q := fold(strings.trim_space(query))
	hits := make([dynamic]Palette_Hit, 0, len(entries), context.temp_allocator)
	for e, i in entries {
		label := fold(palette_label(e))
		tier, score := palette_match(q, label, fold(palette_words_of(e)))
		if tier == .None do continue
		r := PALETTE_RECENT
		for f, j in recent do if f == e {r = j; break}
		append(&hits, Palette_Hit{i, tier, score, r, enabled[i], 0 if q == "" else len(label)})
	}
	slice.sort_by(hits[:], proc(a, b: Palette_Hit) -> bool {
		if a.tier != b.tier do return a.tier < b.tier
		if a.recent != b.recent do return a.recent < b.recent
		if a.enabled != b.enabled do return a.enabled
		if a.score != b.score do return a.score < b.score
		if a.length != b.length do return a.length < b.length
		return a.entry < b.entry
	})
	return hits[:]
}

// Puts `e` first among the recents, dropping it from where it was or the oldest.
palette_remember :: proc(recent: ^[PALETTE_RECENT]Palette_Entry, count: ^int, e: Palette_Entry) {
	at := count^
	for f, i in recent[:count^] do if f == e {at = i; break}
	if at == count^ && count^ < PALETTE_RECENT do count^ += 1
	at = min(at, PALETTE_RECENT - 1)
	for i := at; i > 0; i -= 1 do recent[i] = recent[i - 1]
	recent[0] = e
}

// Whether the entry can run now.
palette_enabled :: proc(app: ^App, e: Palette_Entry) -> bool {
	return e.kind == .Settings_Tab || command_enabled(app, e.id, e.arg)
}

// The row's icon: the command's own, or a wand for one that has none, so every label in
// the list starts at the same place.
palette_icon :: proc(e: Palette_Entry) -> rune {
	if e.kind == .Settings_Tab do return ui.ICON_SETTINGS
	return COMMANDS[e.id].icon if COMMANDS[e.id].icon != 0 else ui.ICON_WAND
}

// The entry's name as settings.txt and the exit stats write it: the command's name, and
// its argument by name too ("Brush:Clay", "View_Axis:Front", "Remesh_To:1000000",
// "Settings_Tab:Touch"), so a reordered enum never turns one remembered command into
// another. In the temp allocator.
palette_entry_name :: proc(e: Palette_Entry) -> string {
	if e.kind == .Settings_Tab do return fmt.tprintf("Settings_Tab:%v", Settings_Tab(e.arg))
	if COMMANDS[e.id].args == 0 do return fmt.tprint(e.id)
	return fmt.tprintf("%v:%s", e.id, palette_arg_name(e.id, e.arg))
}

@(private = "file")
palette_arg_name :: proc(id: Command_Id, arg: int) -> string {
	#partial switch id {
	case .Brush:     return fmt.tprint(sculpt.Brush_Kind(arg))
	case .View_Axis: return fmt.tprint(camera.Axis_View(arg))
	case .Mask:      return fmt.tprint(sculpt.Mask_Command(arg))
	case .Paint:     return fmt.tprint(sculpt.Paint_Command(arg))
	case .Group:     return fmt.tprint(sculpt.Group_Command(arg))
	case .Remesh_To, .Decimate_To: return fmt.tprint(SPHERE_PRESETS[arg].vertices)
	}
	return fmt.tprint(arg)
}

// Reads a name palette_entry_name wrote; false for one this version does not know.
// A size reads back as the nearest preset, as `new_vertices` does.
palette_entry_from_name :: proc(name: string) -> (e: Palette_Entry, ok: bool) {
	head, _, tail := strings.partition(name, ":")
	if head == "Settings_Tab" {
		tab := reflect.enum_from_name(Settings_Tab, tail) or_return
		return {kind = .Settings_Tab, arg = int(tab)}, true
	}
	id := reflect.enum_from_name(Command_Id, head) or_return
	if !palette_lists(id) do return
	n := COMMANDS[id].args
	if n == 0 do return {.Command, id, 0}, tail == ""
	if id == .Remesh_To || id == .Decimate_To {
		want := strconv.parse_f64(tail) or_return
		best := -1.0
		for p, i in SPHERE_PRESETS {
			if d := abs(f64(p.vertices) - want); best < 0 || d < best do e, best = {.Command, id, i}, d
		}
		return e, best >= 0
	}
	for arg in 0 ..< n do if palette_arg_name(id, arg) == tail do return {.Command, id, arg}, true
	return
}

// Opens the palette with an empty query, closing whatever else floats so two popovers are
// never open at once. Its text field takes the keys from the next frame it is drawn.
palette_open :: proc(app: ^App) {
	k := &app.kit
	k.palette, k.palette_pick, k.palette_first = true, 0, 0
	k.palette_query = {}
	k.menu, k.view_menu, k.browser, k.object_menu = false, false, false, false
	k.ctx.select_open = 0
}

// Closes it and gives the keys back.
palette_close :: proc(app: ^App) {
	app.kit.palette = false
	app.kit.ctx.text_focus = 0
}

// Runs the entry as its menu row or button would, then closes the palette; what ran is
// remembered as recent (and counted for the exit stats).
palette_run :: proc(app: ^App, e: Palette_Entry) {
	k := &app.kit
	palette_close(app)
	ran := false
	switch e.kind {
	case .Command:
		ran = command_run(app, e.id, e.arg)
	case .Settings_Tab:
		// Settings opens as Menu > Settings opens it, on that tab from its top.
		ran = command_run(app, .Settings)
		k.settings_tab, k.settings_scroll = Settings_Tab(e.arg), 0
	}
	if !ran do return
	k.palette_runs += 1
	k.palette_last, k.palette_ran = e, true
	palette_remember(&k.palette_recent, &k.palette_recent_count, e)
}

// The palette's popover under the Search button: the field, as many results as fit (up
// to PALETTE_ROWS) with their shortcuts and states, the picked one's help, and how many
// more there are. Up and Down pick (the list scrolls to keep the pick in view), Enter or
// a tap runs, and Ctrl+K again closes. Escape and Back close it in kit_frame.
kit_palette :: proc(app: ^App, anchor: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	width := min(420, area.w - 2 * t.edge)
	rows := palette_rows(area.y + area.h - (anchor.y + anchor.h + 6) - 4, t.target)
	was := k.palette
	if !ui.popover_begin(ctx, "palette", &k.palette, anchor, .Below_End, {direction = .Column, gap = 2, padding = 8, width = width}) do return
	defer ui.popover_end(ctx)
	// A press outside closed it: give the keys back.
	if was && !k.palette do ctx.text_focus = 0
	d := &app.device
	// Its chord with a modifier (Ctrl+K) closes it again, read here since the shortcuts
	// are off while it is open; a plain `/` is text then. The chord that opened it was
	// read after this frame's layout, so it never closes it at once.
	for b in DEFAULT_BINDINGS {
		if k.palette && b.command == .Command_Palette && b.chord.mods != {} && chord_down(d, b.chord) do palette_close(app)
	}
	if ui.text_field(ctx, "Search commands##palette", k.palette_query[:], hold = k.palette, hint = "Search commands and settings") {
		k.palette_pick, k.palette_first = 0, 0
	}
	query := string(cstring(&k.palette_query[0]))
	entries := palette_entries()
	enabled := make([]bool, len(entries), context.temp_allocator)
	for e, i in entries do enabled[i] = palette_enabled(app, e)
	hits := palette_rank(query, entries, k.palette_recent[:k.palette_recent_count], enabled)
	n := len(hits)
	if k.palette && n > 0 {
		if key_pressed(d, sdl.K_DOWN, repeat = true) do k.palette_pick = (k.palette_pick + 1) % n
		if key_pressed(d, sdl.K_UP, repeat = true) do k.palette_pick = (k.palette_pick + n - 1) % n
	}
	k.palette_pick = clamp(k.palette_pick, 0, max(n - 1, 0))
	// The rows shown follow the pick.
	if k.palette_pick < k.palette_first do k.palette_first = k.palette_pick
	if k.palette_pick >= k.palette_first + rows do k.palette_first = k.palette_pick - rows + 1
	k.palette_first = clamp(k.palette_first, 0, max(n - rows, 0))

	if query == "" && k.palette_recent_count > 0 do ui.caption(ctx, "  RECENT, THEN EVERYTHING")
	ran: Maybe(Palette_Entry)
	for i in k.palette_first ..< min(k.palette_first + rows, n) {
		h := hits[i]
		e := entries[h.entry]
		// A row's id comes from its entry, so it stays the same widget while the list
		// around it changes.
		label := fmt.tprintf("%s##palette %d", palette_label(e), h.entry)
		keys := command_keys(e.id, e.arg) if e.kind == .Command else ""
		checked := e.kind == .Command && command_checked(app, e.id, e.arg)
		if ui.menu_item(ctx, label, keys, palette_icon(e), checked, .Neutral, h.enabled, i == k.palette_pick) do ran = e
	}
	if n == 0 do ui.paragraph(ctx, "Nothing matches. Try another word, such as remesh, mask or wireframe.")
	// The pick's help, in a fixed height so the popover does not jump as the pick moves.
	ui.divider(ctx, across = true)
	ui.begin(ctx, "palette help", {direction = .Column, height = 56})
	if n > 0 {
		e := entries[hits[k.palette_pick].entry]
		help := fmt.tprintf("Opens Settings on the %s tab.", SETTINGS_TAB_NAMES[Settings_Tab(e.arg)]) if e.kind == .Settings_Tab else COMMANDS[e.id].help
		if !hits[k.palette_pick].enabled do help = fmt.tprintf("Not now: %s", help)
		ui.paragraph(ctx, help)
	}
	ui.end(ctx)
	if n > rows do ui.caption(ctx, fmt.tprintf("  %d-%d OF %d: TYPE MORE TO NARROW", k.palette_first + 1, min(k.palette_first + rows, n), n))
	if k.palette && n > 0 && hits[k.palette_pick].enabled && (key_pressed(d, sdl.K_RETURN) || key_pressed(d, sdl.K_KP_ENTER)) {
		ran = entries[hits[k.palette_pick].entry]
	}
	if e, ok := ran.?; ok && k.palette do palette_run(app, e)
}
