package main

import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

import "../ui"

// The command palette: every command the registry holds, and each Settings tab, found
// by typing part of its name, or a name another app gives it (DynaMesh, Freeze,
// SubTool...). Ctrl+K, `/` or the Search button opens it; Up and Down pick, Enter or a
// tap runs, Escape closes. Starred commands come first while nothing is typed, then what
// was run last. It runs commands
// through command_run like every menu, so it shows the same shortcuts and states and
// does nothing the menus could not. A long press (or a right-click) on a row, or
// Shift+Enter, shows where the command lives instead: the tray opens on its section with
// its control marked (tray_show).

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
// the field, the captions, the help, its row of buttons and the padding: from 2 up to
// PALETTE_ROWS. A row is a touch target less 4, plus the column's gap of 2.
palette_rows :: proc(room, target: f32) -> int {
	fixed := 16 + (target + 2) + 2 * (22 + 2) + (1 + 2) + (74 + 2) + (target + 2)
	return clamp(int((room - fixed) / (target - 2)), 2, PALETTE_ROWS)
}

// Other words each command is found by: names other apps give it and words people
// reach for. The label itself is always searched; the help sentence is not, since it
// would match nearly everything.
@(rodata)
SEARCH_WORDS := #partial [Command_Id]string {
	.New_Scene        = "start starter base mesh template blockout reset clear empty",
	.Open_Scene       = "load file",
	.Save_Scene       = "file write",
	.Save_Scene_As    = "file write",
	.Save_Scene_Copy  = "file write copy duplicate backup variation",
	.Save_Scene_Next  = "file write increment numbered version iteration",
	.Delete_Older_History = "undo history clear forget free memory purge",
	.Scene_Versions   = "versions history revert restore backup older previous incremental",
	.Open_Last_Autosave = "recover restore crash backup autosave lost unsaved quicksave",
	.Import_Mesh      = "obj ply load append file",
	.Export_Mesh      = "obj ply file",
	.Export_Print     = "stl 3d printer printing millimetres inches size scale units",
	.Send_To_Blender  = "goz blender link export round trip",
	.Get_From_Blender = "goz blender link import round trip back",
	.Macro_Record     = "macro record recording automate repeat actions steps",
	.Run_Macro        = "macro play replay run recorded automate repeat",
	.Macros           = "macros list manage rename delete key recorded automate",
	.Run_Plugin       = "plugin script luau run automate extension add-on",
	.Reload_Plugins   = "plugins reload refresh script luau extension add-on",
	.Run_Script       = "script file run commands automate batch cmd",
	.Library          = "library packs content assets alphas installed manage remove",
	.Pick_Pack        = "content pack install add sculptpack zip alphas assets",
	.Save_Pack        = "content pack make create share export sculptpack zip my alphas presets",
	.Screenshot       = "png capture image",
	.Coach_Tips       = "tutorial onboarding coach intro getting started hints",
	.Pie              = "quick menu favourites radial marking menu spacebar custom",
	.Pie_Editor       = "quick menu favourites radial custom pies slots",
	.Undo             = "back revert",
	.Redo             = "forward",
	.Delete_Object    = "subtool remove",
	.Duplicate_Object = "subtool copy clone",
	.Objects_Card     = "subtools subtool list outliner scene objects card",
	.Copy_Object      = "subtool clipboard",
	.Paste_Object     = "subtool clipboard insert",
	.Object_To_Top    = "subtool order move up first",
	.Object_To_Bottom = "subtool order move down last",
	.Delete_Other_Objects = "subtool remove others keep only",
	.Delete_All_Objects = "subtool remove clear empty",
	.All_Lowest_Level = "subtool subdivision levels lowest all low",
	.All_Highest_Level = "subtool subdivision levels highest all high",
	.Visibility_Slot  = "store subtool visibility v1 v2 v3 v4 v5 v6 v7 v8 eyes shown hidden objects",
	.Split_Object     = "subtool split hidden masked groups polygroups parts pieces separate objects",
	.Merge_Down       = "subtool mergedown merge join combine objects",
	.Merge_Visible    = "subtool mergevisible merge join combine shown objects",
	.Align_Objects    = "subtool align line up objects left right top bottom centre center",
	.Distribute_Objects = "subtool distribute space evenly spread objects",
	.Tool_Move        = "select transform gizmo",
	.Tool_Sculpt      = "brush",
	.Tool_Curve       = "spline tube",
	.Tool_Insert      = "imm insert mesh",
	.Gizmo            = "transform translate rotate rotation scale size manipulator handles pose posing",
	.Gizmo_Snap       = "grid increment step snapping",
	.Gizmo_Pivot      = "origin center centre anchor transform point",
	.Gizmo_Pivot_Reset = "origin center centre anchor",
	.Reset_Transform  = "clear transform origin zero identity unrotate",
	.Symmetry_X       = "mirror",
	.Local_Symmetry   = "mirror centre center own middle",
	.Radial_Symmetry  = "mirror around rotate repeat kaleidoscope",
	.Brush_Add        = "zadd raise build positive plus",
	.Brush_Subtract   = "zsub dig carve negative minus invert",
	.Paint_Channel    = "rgb mrgb colour color channel paint sculpt both",
	.Swap_Colors      = "secondary colour color switch main",
	.Front_Only       = "backfacemask backface filter",
	.Lock_Plane       = "original plane lock filter",
	.Connected        = "automasking topology topological connected filter",
	.Size_Down        = "radius smaller draw size",
	.Size_Up          = "radius bigger draw size",
	.Strength_Down    = "intensity weaker",
	.Strength_Up      = "intensity stronger",
	.Preset_Save_New  = "preset save brush clone copy new custom",
	.Preset_Save      = "preset update store",
	.Preset_Revert    = "preset reset undo changes",
	.Preset_Delete    = "preset remove",
	.Brush_Reset      = "default revert factory",
	.Replay_Stroke    = "record repeat stamp",
	.Remesh           = "dynamesh voxel voxelize",
	.Dyntopo_Toggle   = "dynamic topology sculptris tessellation",
	.Subdivide        = "divide smooth level multires",
	.Level_Up         = "subdivision higher multires",
	.Level_Down       = "subdivision lower multires",
	.Hd_Toggle        = "hd geometry",
	.Group_Shortcut   = "polygroup face set",
	.Mask             = "freeze",
	.Mask_By          = "freeze auto cavity peaks curvature smoothness depth view colour color hue saturation polypaint border edge crease feature",
	.Mask_Adjust      = "freeze curve profile sharpen soften",
	.Show_All         = "unhide visibility",
	.Invert_Hidden    = "visibility",
	.Hide_Masked      = "visibility freeze mask selection",
	.Hide_Unmasked    = "visibility freeze mask isolate selection",
	.Grow_Visible     = "visibility unhide expand more ring",
	.Shrink_Visible   = "visibility hide contract less ring",
	.Grow_All_Visible = "visibility unhide connected piece whole",
	.Outer_Ring       = "visibility border edge loop",
	.Grow_To_Groups   = "visibility unhide polygroup face set",
	.Show_Masked      = "visibility unhide mask freeze",
	.Store_Selection_Set   = "save keep selection mask freeze",
	.Restore_Selection_Set = "load selection mask freeze",
	.Paint            = "polypaint colour color",
	.Group            = "polygroup face set",
	.Delete_Lower_Levels  = "subdivision",
	.Delete_Higher_Levels = "subdivision",
	.Hd_Divide        = "hd geometry",
	.Hd_Delete        = "hd geometry",
	.Hd_Sculpt        = "hd geometry",
	.Hd_Leave         = "hd geometry",
	.Morph_Store      = "morph target",
	.Morph_Delete     = "morph target",
	.New_Layer        = "sculpt layers record",
	.Layer_Edit       = "sculpt layers copy flip negate combine order reorder apply flatten",
	.Recall_Earlier   = "historyrecall local undo recall point",
	.Recall_Later     = "historyrecall local undo recall point",
	.Recall_Oldest    = "historyrecall local undo recall point first",
	.Smooth_All       = "relax",
	.Deformer         = "deform simple deform gizmo bend twist taper curve arc ffd cage free form",
	.Deformation      = "deform deformation slider transform shear randomize push pull to sphere filter smooth",
	.Reshape_Repeat   = "repeat other subtools apply last action to all deformation",
	.Remesh_To        = "dynamesh voxel voxelize resolution",
	.Decimate_To      = "decimation master reduce simplify",
	.Mirror_Weld      = "symmetrize mirror",
	.Close_Holes      = "fill holes cap open border repair watertight modify topology",
	.Delete_Hidden    = "del hidden remove hidden part polygons modify topology",
	.Weld_Points      = "merge by distance remove doubles duplicate vertices seams repair",
	.Check_Mesh       = "mesh integrity inspect non manifold holes errors 3d print check",
	.Fix_Mesh         = "fix mesh integrity repair normals flipped faces recalculate outside duplicates",
	.Delete_Half      = "delete by symmetry remove side cut half mirror",
	.Retopologize     = "zremesher quadriflow quads retopo quad",
	.Make_Boolean     = "live boolean subtract union intersect",
	.Live_Boolean     = "preview subtract union intersect",
	.Extract_Masked   = "extract shell",
	.Convert_To_Mesh  = "voxels clay volume triangles surface",
	.Convert_To_Voxels = "mesh clay volume voxelise voxelize sdf",
	.Voxel_Res_Up     = "resolution double finer voxels increase resample",
	.Voxel_Res_Down   = "resolution halve coarser voxels decrease resample",
	.Adjust_Last      = "redo last tweak change settings again stroke amount",
	.Add_Object       = "subtool primitive append sphere cube",
	.Frame_All        = "fit zoom extents home",
	.Hide_Object      = "subtool eye visibility visible toggle",
	.Ghost_Object     = "transparent see through reference xray template",
	.Show_All_Objects = "unhide subtools eyes visibility visible all",
	.Solo_Object      = "isolate local view only alone focus",
	.New_Folder       = "collection outliner organise organize subtools",
	.Rename_Object    = "name label title subtool",
	.View_Axis        = "camera",
	.Ortho_Toggle     = "orthographic perspective camera",
	.Focus_Selected   = "frame zoom fit",
	.Reset_Camera     = "home view",
	.Wireframe        = "edges polyframe",
	.Floor_Grid       = "floor ground plane wall axes axis lines",
	.Transparency     = "transparent see through xray x-ray transp",
	.Flat_Shading     = "faceted",
	.Texture_View     = "textures maps uv checker normal map bake preview textured",
	.Load_Texture     = "texture map image load base colour albedo diffuse orm roughness metal occlusion normal map",
	.Remove_Textures  = "texture maps remove delete clear",
	.Polygroups       = "polyframe colours colors",
	.Studio_Render    = "bpr render",
	.Live_Occlusion   = "ambient occlusion ao ssao gtao live shadows creases",
	.Render_Mode      = "render path trace tracing cycles rendered view global illumination gi bounce final",
	.Pick_Focus       = "depth of field dof focus point eyedropper lens camera blur bokeh aperture",
	.Focus_Pivot      = "depth of field dof focus pivot reset lens camera",
	.Viewport_Look    = "look matcap shading style preset viewport sculpt studio classic grey",
	.View_Back        = "camera undo back history last view",
	.View_Forward     = "camera redo forward history",
	.Stats            = "performance fps statistics",
	.Inspector        = "panel properties tray subpalette",
	.Show_Section     = "palette section subpalette panel go",
	.Settings         = "preferences options",
	.Reduce_Motion    = "animation accessibility",
}

// The words each Help tab is found by, besides its name: a command's words are the same
// for every argument, but each tab is looked for by its own.
@(rodata)
HELP_SEARCH_WORDS := [Help_Tab]string {
	.Keys     = "shortcuts cheat sheet keyboard mouse controls",
	.Gestures = "fingers pen tablet controls",
	.Glossary = "terms words names meaning",
}

// The words each Settings tab is found by, besides its name.
@(rodata)
SETTINGS_SEARCH_WORDS := [Settings_Tab]string {
	.Interface   = "preferences scale size theme ui",
	.Camera      = "preferences orbit turn pivot",
	.Touch       = "preferences pen finger gesture tablet stylus pressure",
	.Keys        = "keymap shortcuts hotkeys bindings mouse buttons navigation blender maya zbrush",
	.Performance = "preferences performance speed fps frame rate refresh hz vsync battery idle rest threads statistics autosave recovery backup crash",
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

// The entries as this run has them: Run macro only for the slots that hold a macro.
palette_entries_shown :: proc(app: ^App) -> []Palette_Entry {
	out := make([dynamic]Palette_Entry, 0, 160, context.temp_allocator)
	for e in palette_entries() {
		if e.kind == .Command && e.id == .Run_Macro && app.macro.slots[e.arg].name == "" do continue
		if e.kind == .Command && e.id == .Run_Plugin && !plugin_slot_loaded(app, e.arg) do continue
		if e.kind == .Command && e.id == .Reload_Plugins && !PLUGINS_AVAILABLE do continue
		append(&out, e)
	}
	return out[:]
}

// What the palette and Settings > Keys show for the entry: a macro by its name.
entry_title :: proc(app: ^App, e: Palette_Entry) -> string {
	if e.kind == .Command && e.id == .Run_Macro && app.macro.slots[e.arg].name != "" do return fmt.tprintf("Macro: %s", app.macro.slots[e.arg].name)
	if e.kind == .Command && e.id == .Run_Plugin && app.plugins.slots[e.arg].key != "" do return plugin_slot_title(app, e.arg)
	return palette_label(e)
}

// Whether the palette lists the command: not None, not itself, and not the two that act
// where the pointer is (A's HD window and R's replay), which over the palette would act
// on the palette's spot; the Object palette and Sculpt HD cover them.
palette_lists :: proc(id: Command_Id) -> bool {
	if !LINK_AVAILABLE && (id == .Send_To_Blender || id == .Get_From_Blender) do return false
	return id != .None && id != .Command_Palette && id != .Hd_Toggle && id != .Replay_Stroke
}

// Where a menu's own heading names what a label leaves out ("Delete" under the object's
// menu), the palette, which has no headings, says it.
@(rodata)
PALETTE_LABELS := #partial [Command_Id]string {
	.Delete_Object    = "Delete object",
	.Duplicate_Object = "Duplicate object",
	.Polygroups       = "Show polygroups",
	.Solo_Object      = "Solo object",
	.Rename_Object    = "Rename object",
	.Copy_Object      = "Copy object",
	.Paste_Object     = "Paste object",
	.Object_To_Top    = "Bring object to top",
	.Object_To_Bottom = "Send object to bottom",
	.Delete_Other_Objects = "Delete other objects",
	.Delete_All_Objects = "Delete all objects",
	.All_Lowest_Level = "All objects to lowest level",
	.All_Highest_Level = "All objects to highest level",
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
	if e.id == .Help do return HELP_SEARCH_WORDS[Help_Tab(e.arg)]
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
	// Where it is among the favourites while nothing is typed, else MAX_FAVOURITES.
	favourite: int,
	recent:  int, // where it is among the recents, or PALETTE_RECENT when it is not
	enabled: bool,
	length:  int, // the label's length
}

// The entries that match `query`, best first: by tier, then recent first, then those
// that can run now, then the tighter fuzzy match, then the shorter label, then the
// table's order, so equal matches always come in the same order. With no query every
// entry matches, the favourites first in the order they were starred, then recent, then
// those that can run, then in the table's order; a query ranks favourites as any other.
// `enabled[i]` says whether entries[i] can run now. In the temp allocator.
palette_rank :: proc(query: string, entries: []Palette_Entry, recent: []Palette_Entry, enabled: []bool, favourites: []Palette_Entry = nil, titles: []string = nil) -> []Palette_Hit {
	assert(len(enabled) == len(entries))
	q := fold(strings.trim_space(query))
	hits := make([dynamic]Palette_Hit, 0, len(entries), context.temp_allocator)
	for e, i in entries {
		label := fold(titles[i] if titles != nil else palette_label(e))
		tier, score := palette_match(q, label, fold(palette_words_of(e)))
		if tier == .None do continue
		r := PALETTE_RECENT
		for f, j in recent do if f == e {r = j; break}
		star := MAX_FAVOURITES
		if q == "" {
			for f, j in favourites do if f == e {star = j; break}
		}
		append(&hits, Palette_Hit{i, tier, score, star, r, enabled[i], 0 if q == "" else len(label)})
	}
	slice.sort_by(hits[:], proc(a, b: Palette_Hit) -> bool {
		if a.tier != b.tier do return a.tier < b.tier
		if a.favourite != b.favourite do return a.favourite < b.favourite
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
	return command_name(e.id, e.arg)
}

// Reads a name palette_entry_name wrote; false for one this version does not know.
// A size reads back as the nearest preset, as `new_vertices` does.
palette_entry_from_name :: proc(name: string) -> (e: Palette_Entry, ok: bool) {
	head, _, tail := strings.partition(name, ":")
	if head == "Settings_Tab" {
		tab := reflect.enum_from_name(Settings_Tab, tail) or_return
		return {kind = .Settings_Tab, arg = int(tab)}, true
	}
	id, arg := command_from_name(name) or_return
	if !palette_lists(id) do return
	return {.Command, id, arg}, true
}

// Opens the palette with an empty query, closing whatever else floats so two popovers are
// never open at once. Its text field takes the keys from the next frame it is drawn.
palette_open :: proc(app: ^App) {
	k := &app.kit
	k.palette, k.palette_pick, k.palette_first = true, 0, 0
	k.palette_query = {}
	k.palette_for = nil
	kit_floats_close(k)
}

// Opens the palette to choose what gesture `slot` runs: every command a gesture may hold,
// whether or not it can run now, and no Settings tabs; a pick puts it on the gesture.
palette_open_for :: proc(app: ^App, slot: Gesture_Slot) {
	palette_open(app)
	app.kit.palette_for = slot
}

// Closes it and gives the keys back.
palette_close :: proc(app: ^App) {
	app.kit.palette = false
	app.kit.palette_for = nil
	app.kit.ctx.text_focus = 0
}

// Runs the entry as its menu row or button would, then closes the palette; what ran is
// remembered as recent (and counted for the exit stats). While choosing for a gesture, it
// puts the entry on the gesture instead, which neither runs it nor counts as a recent.
palette_run :: proc(app: ^App, e: Palette_Entry) {
	k := &app.kit
	if slot, choosing := k.palette_for.?; choosing {
		palette_close(app)
		if e.kind != .Command || !gesture_lists(e.id) do return
		app.nav.gestures[slot] = {e.id, e.arg}
		report(app, nil, {}, "%s now runs %s", GESTURE_SLOT_NAMES[slot], pie_slot_label({e.id, e.arg}))
		return
	}
	palette_close(app)
	ran := false
	switch e.kind {
	case .Command:
		ran = command_run(app, e.id, e.arg)
	case .Settings_Tab:
		ran = settings_open(app, Settings_Tab(e.arg))
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
kit_palette :: proc(app: ^App, anchor: ui.Rect, side: ui.Side) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	area := ui.safe_area(ctx)
	width := min(420, area.w - 2 * t.edge)
	rows := palette_rows(area.y + area.h - (anchor.y + anchor.h + 6) - 4, t.target)
	was := k.palette
	if !ui.popover_begin(ctx, "palette", &k.palette, anchor, side, {direction = .Column, gap = 2, padding = 8, width = width}) do return
	defer ui.popover_end(ctx)
	// A press outside closed it: give the keys back.
	if was && !k.palette do ctx.text_focus = 0
	d := &app.device
	// Its chord with a modifier (Ctrl+K) closes it again, read here since the shortcuts
	// are off while it is open; a plain `/` is text then. The chord that opened it was
	// read after this frame's layout, so it never closes it at once.
	for b in keymap(app) {
		if k.palette && b.command == .Command_Palette && b.chord.mods != {} && chord_down(d, b.chord) do palette_close(app)
	}
	if ui.text_field(ctx, "Search commands##palette", k.palette_query[:], hold = k.palette, hint = "Search commands and settings") {
		k.palette_pick, k.palette_first = 0, 0
	}
	query := string(cstring(&k.palette_query[0]))
	entries := palette_entries_shown(app)
	choosing_for, choosing := k.palette_for.?
	if choosing {
		// Only what a gesture may hold, the palette itself included.
		kept := make([dynamic]Palette_Entry, 0, len(entries) + 1, context.temp_allocator)
		for e in entries do if e.kind == .Command && gesture_lists(e.id) do append(&kept, e)
		append(&kept, Palette_Entry{.Command, .Command_Palette, 0})
		entries = kept[:]
		ui.caption(ctx, fmt.tprintf("  CHOOSE WHAT %s RUNS", strings.to_upper(GESTURE_SLOT_NAMES[choosing_for], context.temp_allocator)))
	}
	enabled := make([]bool, len(entries), context.temp_allocator)
	titles := make([]string, len(entries), context.temp_allocator)
	// A gesture may hold a command that cannot run now (Level up with no levels yet).
	for e, i in entries do enabled[i], titles[i] = choosing || palette_enabled(app, e), entry_title(app, e)
	hits := palette_rank(query, entries, k.palette_recent[:k.palette_recent_count], enabled, favourite_entries(app), titles)
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

	if query == "" && !choosing {
		switch {
		case k.favourite_count > 0 && k.palette_recent_count > 0: ui.caption(ctx, "  STARRED, RECENT, THEN EVERYTHING")
		case k.favourite_count > 0:                               ui.caption(ctx, "  STARRED, THEN EVERYTHING")
		case k.palette_recent_count > 0:                          ui.caption(ctx, "  RECENT, THEN EVERYTHING")
		}
	}
	ran, shown: Maybe(Palette_Entry)
	for i in k.palette_first ..< min(k.palette_first + rows, n) {
		h := hits[i]
		e := entries[h.entry]
		// A row's id comes from its entry, so it stays the same widget while the list
		// around it changes.
		label := fmt.tprintf("%s##palette %d", titles[h.entry], h.entry)
		keys := command_keys(app, e.id, e.arg) if e.kind == .Command else ""
		checked := e.kind == .Command && command_checked(app, e.id, e.arg)
		starred := e.kind == .Command && favourite_find(app, e.id, e.arg) >= 0
		if ui.menu_item(ctx, label, keys, palette_icon(e), checked, .Neutral, h.enabled, i == k.palette_pick, starred = starred) do ran = e
		if ui.secondary(ctx) && palette_home(e) != "" do shown = e
	}
	if n == 0 do ui.paragraph(ctx, "Nothing matches. Try another word, such as remesh, mask or wireframe.")
	// The pick's help, in a fixed height so the popover does not jump as the pick moves.
	ui.divider(ctx, across = true)
	ui.begin(ctx, "palette help", {direction = .Column, height = 74})
	if n > 0 {
		e := entries[hits[k.palette_pick].entry]
		help := fmt.tprintf("Opens Settings on the %s tab.", SETTINGS_TAB_NAMES[Settings_Tab(e.arg)]) if e.kind == .Settings_Tab else COMMANDS[e.id].help
		if e.kind == .Command {
			if gesture := command_gesture(app, e.id, e.arg); gesture != "" do help = fmt.tprintf("%s By touch: %s%s.", help, strings.to_lower(gesture[:1], context.temp_allocator), gesture[1:])
		}
		if !hits[k.palette_pick].enabled do help = fmt.tprintf("Not now: %s", help)
		if home := palette_home(e); home != "" do help = fmt.tprintf("%s In %s: a long press or Shift+Enter shows it there.", help, home)
		ui.paragraph(ctx, help)
	}
	ui.end(ctx)
	// What the pick can be made into, enabled or not (Ctrl+Alt+click reaches only the
	// controls that can run now): a star, a pie's slot, a key. A Settings tab is none of
	// these, so its row stays, empty, and the popover keeps its height.
	ui.begin(ctx, "palette actions", {direction = .Row, gap = 8, height = t.target})
	if n > 0 && entries[hits[k.palette_pick].entry].kind == .Command && !choosing {
		e := entries[hits[k.palette_pick].entry]
		third := (width - 16 - 16) / 3
		starred := favourite_find(app, e.id, e.arg) >= 0
		if ui.button(ctx, "Starred##palette star" if starred else "Star##palette star", .Flat if starred else .Bordered, .Accent if starred else .Neutral, third, ui.ICON_STAR) {
			if favourite_toggle(app, e.id, e.arg) do pies_saved(app)
		}
		if ui.button(ctx, "Put in a pie", .Bordered, width = third, glyph = ui.ICON_PIE, enabled = pie_lists(e.id)) {
			pie_editor_open(app, e.id, e.arg, anchor)
		}
		if ui.button(ctx, "Assign key", .Bordered, width = third, glyph = ui.ICON_KEYBOARD) {
			bind_open(app, e.id, e.arg, ctx.last_rect)
		}
	}
	ui.end(ctx)
	if n > rows do ui.caption(ctx, fmt.tprintf("  %d-%d OF %d: TYPE MORE TO NARROW", k.palette_first + 1, min(k.palette_first + rows, n), n))
	enter := key_pressed(d, sdl.K_RETURN) || key_pressed(d, sdl.K_KP_ENTER)
	if k.palette && n > 0 && enter {
		e := entries[hits[k.palette_pick].entry]
		if d.shift {
			if palette_home(e) != "" do shown = e
		} else if hits[k.palette_pick].enabled do ran = e
	}
	if !k.palette do return
	if e, ok := shown.?; ok {
		palette_close(app)
		_ = tray_show(app, e.id, e.arg)
		return
	}
	if e, ok := ran.?; ok do palette_run(app, e)
}

// Where the entry's control is in the tray, as "the Object palette's Mask section", or
// "" for one with no home there (a Settings tab, or a command only the bars or keys run).
palette_home :: proc(e: Palette_Entry) -> string {
	if e.kind != .Command do return ""
	sec, ok := COMMAND_HOMES[e.id].?
	if !ok do return ""
	return fmt.tprintf("the %s palette's %s section", palette_name(section_palette(sec)), tray_section_title(sec))
}
