package main

import "core:fmt"
import "core:strings"

import "../camera"
import "../geom"
import "../ui"

// The Scene palette's Objects section: the tree of objects and folders, what acts on the
// selection, and how long the last file took (Lens's stack draws it as its Scene card).
kit_scene_objects :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	total := 0
	for obj in app.scene.objects do total += object_vertex_count(obj)
	ui.caption(ctx, fmt.tprintf("OBJECTS  %d  ·  %s VERTICES", len(app.scene.objects), count_label(total)))
	k.tree_rows = 0
	base := boolean_base(app)
	// The list's order is the tree's: a folder's objects are next to each other, so one
	// walk draws each folder's row before what it holds.
	lines := tree_lines(app)
	spots := make([dynamic]Tree_Spot, 0, len(lines), context.temp_allocator)
	for line in lines {
		if line.object >= 0 do kit_object_row(app, &spots, line.object, base, line.depth)
		else do kit_folder_row(app, &spots, line)
	}
	kit_tree_drags(app, spots[:], {k.inspector_body, &k.scroll, k.inspector_limit})
	// The switch above the note, so it stays put under a finger as the note comes and goes.
	_ = ui.switch_row(ctx, "Select several", &k.select_several, keys = "Shift + click")
	if n := len(selection_ids(app)); n > 1 {
		ui.paragraph(ctx, fmt.tprintf("%d objects selected. The gizmo, the Transform values, Reset, Duplicate and Delete take all of them; everything else works on %s, which has the gizmo.", n, object_label(selected_object(app))))
	}
	off, ghosts := scene_view_counts(app)
	if off > 0 || app.scene.solo {
		_ = command_button(app, .Show_All_Objects, width = ui.fill_width(ctx), glyph = ui.ICON_EYE)
	}
	if app.scene.solo {
		ui.paragraph(ctx, fmt.tprintf("Solo shows only the selected object. %s turns it off.", command_keys(app, .Solo_Object)))
	} else if ghosts > 0 {
		ui.paragraph(ctx, "Ghosts are dimmed and let presses through; their ghost icon makes them solid.")
	}
	if len(app.scene.objects) == 0 do ui.paragraph(ctx, "The scene is empty. Add a shape below or open a scene from the menu.")
	half := (ui.fill_width(ctx) - 8) * 0.5
	ui.begin(ctx, "object actions", {direction = .Row, gap = 8})
	_ = command_button(app, .Duplicate_Object, width = half, glyph = ui.ICON_COPY)
	_ = command_button(app, .Delete_Object, tone = .Danger, width = half, glyph = ui.ICON_TRASH)
	ui.end(ctx)
	// Opening a scene counts building it as reading; importing parses apart.
	if s := app.stats; s.file_read_ms > 0 || s.file_write_ms > 0 {
		parts := make([dynamic]string, context.temp_allocator)
		if s.file_read_ms > 0 do append(&parts, fmt.tprintf("read in %.0f ms", s.file_read_ms))
		if s.file_parse_ms > 0 do append(&parts, fmt.tprintf("parsed in %.0f ms", s.file_parse_ms))
		if s.file_write_ms > 0 do append(&parts, fmt.tprintf("written in %.0f ms", s.file_write_ms))
		ui.paragraph(ctx, fmt.tprintf("Last file %s.", strings.join(parts[:], ", ", context.temp_allocator)))
	}
}

// An object's row in the Scene palette, the list's `i`th, `depth` folders in.
@(private = "file")
kit_object_row :: proc(app: ^App, spots: ^[dynamic]Tree_Spot, i: int, base: ^Object, depth: int) {
	k := &app.kit
	ctx := &k.ctx
	objects := app.scene.objects[:]
	obj := objects[i]
	detail := count_label(object_vertex_count(obj))
	if n := len(obj.levels.levels); n > 1 do detail = fmt.tprintf("%s, level %d/%d", detail, obj.levels.current + 1, n)
	if object_dynamic(obj) do detail = fmt.tprintf("%s, dynamic", detail)
	// The boolean's base is the first object not marked, so the list's order decides it.
	if obj == base do detail = fmt.tprintf("base, %s", detail)
	toggles := row_toggles(object_label(obj), obj.off, obj.ghost)
	dragged := k.tree_drag.active && k.tree_drag.key == obj.id
	row := ui.tree_row(ctx, fmt.tprintf("%s##%d", object_label(obj), obj.id), detail, object_in_selection(app, obj), min(depth, TREE_DEPTH_SHOWN), all_toggles = toggles[:], glyph = ui.ICON_FRAME, dim = dragged || !object_shown(app, obj), grip = true)
	append(spots, object_spot(app, row.rect, i, depth))
	kit_row_drags(app, row.grip, row.held_toggle, row.rect, obj.id, obj.ghost, obj.off)
	// A press running down the column sets the rows it crosses instead (kit_tree_drags).
	if !k.tree_column.active {
		switch row.toggled {
		case 0: app.ui.scene_command = {kind = .View, view = .Unghost if obj.ghost else .Ghost, id = obj.id}
		case 1: app.ui.scene_command = {kind = .View, view = .Show if obj.off else .Hide, id = obj.id}
		}
	}
	// Picking an object out of view or reach brings it back, as ZBrush's SubTool list does.
	// Ctrl or Shift, or Select several, adds it to the selection or takes it out; the
	// menu keeps the selection it is opened on, for Delete and Duplicate to take all of it.
	several := k.select_several || ctx.input.ctrl || ctx.input.shift
	if !object_pickable(app, obj) {
		if row.clicked || row.menu do app.ui.scene_command = {kind = .View, view = .Select, id = obj.id}
	} else if row.clicked && several {
		selection_toggle(app, i)
	} else if row.clicked {
		select_only(app, i)
	} else if row.menu {
		selection_make_primary(app, i)
	}
	if row.menu do object_menu_open(app, obj.id, {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0}, .Pointer, .List)
	k.tree_rows += 1
}

// A folder's row, from tree_lines: its chevron folds it, its eye and ghost apply to
// everything in it, its grip drags it with all it holds, a tap selects its first object
// and a long press or right-click opens its menu.
@(private = "file")
kit_folder_row :: proc(app: ^App, spots: ^[dynamic]Tree_Spot, line: Tree_Line) {
	k := &app.kit
	ctx := &k.ctx
	f := line.folder
	members := app.scene.objects[line.first:line.end]
	vertices := 0
	for obj in members do vertices += object_vertex_count(obj)
	detail := "empty" if len(members) == 0 else fmt.tprintf("%d · %s", len(members), count_label(vertices))
	selected := false
	if sel := selected_object(app); sel != nil && !f.open do selected = sel.folder != 0 && folder_within(app, sel.folder, f.id)
	toggles := row_toggles(folder_label(f), f.off, f.ghost)
	// The panel only reads the folder: folding it is a view command like its eye.
	open := f.open
	dragged := k.tree_drag.active && k.tree_drag.key == -f.id
	row := ui.tree_row(ctx, fmt.tprintf("%s##folder %d", folder_label(f), f.id), detail, selected, min(line.depth, TREE_DEPTH_SHOWN), open = &open, all_toggles = toggles[:], glyph = ui.ICON_FOLDER, dim = dragged || folder_hidden(app, f.id), grip = true)
	append(spots, folder_spot(app, row.rect, line))
	kit_row_drags(app, row.grip, row.held_toggle, row.rect, -f.id, f.ghost, f.off)
	if row.folded do app.ui.scene_command = {kind = .View, view = .Folder_Fold, id = f.id}
	if !k.tree_column.active {
		switch row.toggled {
		case 0: app.ui.scene_command = {kind = .View, view = .Folder_Unghost if f.ghost else .Folder_Ghost, id = f.id}
		case 1: app.ui.scene_command = {kind = .View, view = .Folder_Show if f.off else .Folder_Hide, id = f.id}
		}
	}
	if row.clicked && len(members) > 0 {
		app.ui.scene_command = {kind = .View, view = .Select, id = members[0].id}
	}
	if row.menu do folder_menu_open(app, f.id, {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0})
	k.tree_rows += 1
}

// A row of the Scene palette as laid out this frame, which the drags over the tree read.
Tree_Spot :: struct {
	rect:      ui.Rect,
	id:        int, // the object's id, or the folder's
	is_folder: bool,
	folder:    int, // the object's folder (0 for none), or a folder row's own id
	parent:    int, // the folder the row is in: an object's own, or the one a folder is in
	depth:     int, // how many folders in it is
	first:     int, // a folder row: its first object's id, 0 when it has none
	// The id of the object after the row's object, or after the folder's objects; 0 at
	// the end of the list.
	next:      int,
	off:       bool, // its own eye and ghost, which its toggles show
	ghost:     bool,
}

// The most folders in a row is drawn indented: deeper rows line up with the last, so a
// narrow panel keeps room for their names.
TREE_DEPTH_SHOWN :: 6

// The spot of the row `rect` of the list's `i`th object, `depth` folders in.
object_spot :: proc(app: ^App, rect: ui.Rect, i, depth: int) -> Tree_Spot {
	objects := app.scene.objects[:]
	obj := objects[i]
	return {rect = rect, id = obj.id, folder = obj.folder, parent = obj.folder, depth = depth, next = objects[i + 1].id if i + 1 < len(objects) else 0, off = obj.off, ghost = obj.ghost}
}

// The spot of the row `rect` of a folder's line.
folder_spot :: proc(app: ^App, rect: ui.Rect, line: Tree_Line) -> Tree_Spot {
	objects := app.scene.objects[:]
	f := line.folder
	spot := Tree_Spot{rect = rect, id = f.id, is_folder = true, folder = f.id, parent = f.parent, depth = line.depth, off = f.off, ghost = f.ghost}
	if line.end > line.first {
		spot.first = objects[line.first].id
		if line.end < len(objects) do spot.next = objects[line.end].id
	}
	return spot
}

// A row dragged by its grip: which (an object's id, or minus a folder's; 0 for none),
// whether the press has gone further than the slop, after which the drop line shows and
// letting go moves the row, and whether the grip was held this frame.
Tree_Drag :: struct {
	key:    int,
	active: bool,
	held:   bool,
}

// A press on an eye or a ghost dragged down its column, as in Blender's outliner: every
// row it crosses gets the value the pressed one's toggle was going to, so hiding ten
// objects is one sweep. It goes active once the pointer leaves the pressed row. Its
// changes are view commands queued here and sent one a frame, as the frame has one.
Tree_Column :: struct {
	armed:  bool, // a toggle is held
	active: bool, // ...and the pointer has left its row
	held:   bool, // the toggle was held this frame
	column: int, // 0 the ghosts, 1 the eyes
	value:  bool, // the flag the rows get: a ghost, or out of view
	row:    ui.Rect, // the pressed row
	last_y: f32, // where the pointer was, so a fast drag sets every row it passed
	// The changes still to send, at most a row's worth each, so 64 is more than a
	// frame's sweep crosses; and the folders' rows it crossed.
	queue:  [64]Tree_Set,
	count:  int,
	folders: [16]int,
	folder_count: int,
}

// A column drag's change to one row: what changes, on which object or folder.
Tree_Set :: struct {
	view: View_Change,
	id:   int,
}

// Where a dragged row would go if let go now.
Tree_Drop :: struct {
	ok:     bool, // the pointer is over the tree's column
	before: int, // the object it goes before, 0 for the end of the list
	folder: int, // the folder it ends in, 0 for none
	into:   int, // the spot of the folder row it goes into, -1 for none
	depth:  int, // how many folders in it ends, where the drop line starts
	y:      f32, // where the drop line is drawn
}

// Where the row `dragged` (an object's id, or minus a folder's) goes when let go at `at`,
// the rows indented `indent` a folder. Over the middle half of a folder's row it goes
// into the folder, after what it holds. Otherwise each row has a gap above it and the
// list one under its last row: the gap nearest the pointer takes the row, into the
// folder of the row under it; in a gap where folders end (under a folder's last row),
// the further right the pointer, the deeper of them it stays in, as Blender's outliner
// reads the pointer's indent. A folder never goes into itself or a folder inside it,
// and takes what it holds along.
tree_drop :: proc(spots: []Tree_Spot, dragged: int, at: [2]f32, indent: f32 = ui.TREE_INDENT) -> (d: Tree_Drop) {
	d.into = -1
	if len(spots) == 0 do return
	top := spots[0].rect
	if at.x < top.x || at.x > top.x + top.w do return
	d.ok = true
	// The dragged folder's rows, itself and those inside it: [lo, hi).
	lo, hi := -1, -1
	if dragged < 0 {
		for s, i in spots do if s.is_folder && s.id == -dragged {
			lo, hi = i, i + 1
			for hi < len(spots) && spots[hi].depth > s.depth do hi += 1
			break
		}
	}
	for s, i in spots {
		if !s.is_folder || at.y < s.rect.y + s.rect.h * 0.25 || at.y > s.rect.y + s.rect.h * 0.75 do continue
		if i >= lo && i < hi do continue
		d.into, d.before, d.folder, d.depth, d.y = i, s.next, s.id, s.depth + 1, s.rect.y + s.rect.h * 0.5
		return
	}
	// Empty folders at the top come after every object, so the list's end is above them.
	n := len(spots)
	for n > 1 && spots[n - 1].is_folder && spots[n - 1].first == 0 && spots[n - 1].depth == 0 do n -= 1
	last := spots[n - 1].rect
	best, best_dist := n, abs(at.y - (last.y + last.h))
	d.y = last.y + last.h
	for s, j in spots[:n] {
		if j > lo && j < hi do continue
		y := s.rect.y if j == 0 else (spots[j - 1].rect.y + spots[j - 1].rect.h + s.rect.y) * 0.5
		if dist := abs(at.y - y); dist < best_dist do best, best_dist, d.y = j, dist, y
	}
	// How deep it can go: as deep as the row under the gap at least, and as the row above
	// at most; never inside the dragged folder.
	below := spots[best].depth if best < n else 0
	above := spots[best - 1].depth if best > 0 else 0
	deepest := max(above, below)
	if lo >= 0 && best == hi do deepest = min(deepest, spots[lo].depth)
	d.depth = clamp(int((at.x - top.x - 8) / indent), below, max(deepest, below))
	// The folder at that depth is the nearest folder row above one less deep.
	d.folder = 0
	if d.depth > 0 {
		#reverse for s in spots[:best] do if s.is_folder && s.depth == d.depth - 1 {
			d.folder = s.id
			break
		}
	}
	// Before the first object at or after the gap that is not the dragged folder's own.
	d.before = 0
	for s, j in spots[best:] {
		if best + j >= lo && best + j < hi do continue
		lead := s.first if s.is_folder else s.id
		if lead != 0 {
			d.before = lead
			break
		}
	}
	return
}

// Notes what a row's grip and toggles hold this frame: `grip`, whether whatever drags the
// row is held, and `held_toggle`, which toggle is (0 the ghost, 1 the eye; -1 none).
// `rect` is the row's and `key` the object's id, or minus the folder's. The Scene palette's tree and the
// Objects card both drag through this, never both at once (the card and the tray share
// their place, so only one is open).
kit_row_drags :: proc(app: ^App, grip: bool, held_toggle: int, rect: ui.Rect, key: int, ghost, off: bool) {
	k := &app.kit
	if grip {
		if k.tree_drag.key != key do k.tree_drag = {key = key}
		k.tree_drag.held = true
		if k.ctx.long.travel > k.ctx.theme.slop do k.tree_drag.active = true
	}
	c := &k.tree_column
	if held_toggle >= 0 {
		if !c.armed {
			c.armed, c.active, c.column, c.row, c.folder_count = true, false, held_toggle, rect, 0
			c.value = !(ghost if held_toggle == 0 else off)
		}
		c.held = true
	}
}

// The scrolling body a list of rows is in, as last laid out: a drag near its top or
// bottom scrolls it.
Tree_Scroll :: struct {
	body:  ui.Rect,
	value: ^f32,
	limit: f32,
}

// After the tree's rows: runs a column drag over the rows it crossed, shows where a
// dragged row would go and moves it there when let go, scrolls the body the rows are in
// while either is near its top or bottom, and sends the column's next change.
kit_tree_drags :: proc(app: ^App, spots: []Tree_Spot, scroll: Tree_Scroll, indent: f32 = ui.TREE_INDENT) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	in_ := ctx.input
	c := &k.tree_column
	if c.armed && in_.cancel {
		// The system took the press back (a palm): the sweep is undone as far as it is
		// still queued.
		c^ = {}
	} else if c.armed && !c.held {
		c.armed, c.active = false, false
	} else if c.armed {
		y := in_.mouse.y
		if !c.active && (y < c.row.y || y > c.row.y + c.row.h) {
			c.active = true
			c.last_y = c.row.y + c.row.h * 0.5
		}
		if c.active {
			lo, hi := min(c.last_y, y), max(c.last_y, y)
			for s in spots {
				if s.rect.y + s.rect.h < lo || s.rect.y > hi do continue
				// A folder's row the sweep crossed decides for what it holds: their rows
				// keep their own flags, so turning the folder back shows them as they were.
				within := false
				for f in c.folders[:c.folder_count] do within ||= s.parent != 0 && folder_within(app, s.parent, f)
				if within do continue
				if s.is_folder && c.folder_count < len(c.folders) {
					c.folders[c.folder_count] = s.id
					c.folder_count += 1
				}
				if (s.ghost if c.column == 0 else s.off) == c.value do continue
				view: View_Change
				switch {
				case c.column == 0 && s.is_folder: view = .Folder_Ghost if c.value else .Folder_Unghost
				case c.column == 0: view = .Ghost if c.value else .Unghost
				case s.is_folder: view = .Folder_Hide if c.value else .Folder_Show
				case: view = .Hide if c.value else .Show
				}
				queued := false
				for q in c.queue[:c.count] do queued ||= q == {view, s.id}
				if !queued && c.count < len(c.queue) {
					c.queue[c.count] = {view, s.id}
					c.count += 1
				}
			}
			c.last_y = y
			kit_tree_autoscroll(app, scroll)
		}
	}
	c.held = false

	d := &k.tree_drag
	if d.key == 0 do return
	drop := tree_drop(spots, d.key, in_.mouse, indent)
	if d.held {
		d.held = false
		if !d.active || !drop.ok do return
		kit_tree_autoscroll(app, scroll)
		if drop.into >= 0 {
			r := spots[drop.into].rect
			ui.stroke_rect(ctx, {r.x, r.y + (r.h - t.row) * 0.5, r.w, t.row}, t.radius_medium, t.accent, 2)
			return
		}
		top := spots[0].rect
		x := top.x + 8 + indent * f32(min(drop.depth, TREE_DEPTH_SHOWN))
		ui.fill_circle(ctx, {x, drop.y}, 4, t.accent)
		ui.fill_circle(ctx, {x, drop.y}, 2, t.surface)
		ui.fill_rect(ctx, {x + 4, drop.y - 1, top.x + top.w - 8 - x - 4, 2}, 1, t.accent)
		return
	}
	// Let go: a drag that went somewhere moves the row; a cancelled one does nothing.
	if d.active && drop.ok && .Left in in_.released && !in_.cancel {
		if d.key < 0 do app.ui.scene_command = {kind = .Arrange, arrange = .Reorder_Folder, id = -d.key, before = drop.before, folder = drop.folder}
		else do app.ui.scene_command = {kind = .Arrange, arrange = .Reorder, id = d.key, before = drop.before, folder = drop.folder}
	}
	d^ = {}
}

// Sends the column drag's next queued change, once everything else this frame had its
// chance at the frame's one scene command, so neither is lost; it runs every frame, so the
// queue empties with the Scene palette hidden too.
tree_column_send :: proc(app: ^App) {
	c := &app.kit.tree_column
	if c.count == 0 || app.ui.scene_command.kind != .None do return
	app.ui.scene_command = {kind = .View, view = c.queue[0].view, id = c.queue[0].id}
	copy(c.queue[:], c.queue[1:c.count])
	c.count -= 1
}

// Scrolls the body while a drag over the rows is near its top or bottom, faster the
// nearer the edge, so a long list can be dragged along.
@(private = "file")
kit_tree_autoscroll :: proc(app: ^App, scroll: Tree_Scroll) {
	k := &app.kit
	EDGE :: 48 // a touch target: a finger can rest there without leaving the panel
	SPEED :: 900 // points a second at the very edge
	body := scroll.body
	y := k.ctx.input.mouse.y
	v: f32
	if y < body.y + EDGE do v = (y - body.y - EDGE) / EDGE
	else if y > body.y + body.h - EDGE do v = (y - body.y - body.h + EDGE) / EDGE
	if v == 0 do return
	scroll.value^ = clamp(scroll.value^ + clamp(v, -1, 1) * SPEED * k.ctx.input.dt, 0, scroll.limit)
}

// The Scene palette's sections in the order listed, after Objects.
@(rodata)
SCENE_SECTIONS := [?]Kit_Tab_Section {
	{.Add, "Add object", kit_add, nil},
	{.Look, "Look", kit_look, nil},
	{.Material, "Material", kit_material, nil},
	{.Lights, "Lights", kit_lights, nil},
	{.Environment, "Environment", kit_environment, nil},
	{.Render, "Render", kit_render, nil},
	{.Lens, "Lens", kit_lens, nil},
	{.Finish, "Finish", kit_finish, nil},
	{.Camera, "Camera", kit_camera, nil},
	{.Turntable, "Turntable", kit_turntable, nil},
	{.Print, "3D print", kit_print, nil},
	{.Floor, "Floor grid", kit_floor, nil},
	{.Background, "Background", kit_background, nil},
}

// The background: one colour or a gradient, and with the gradient a choice of which edge's
// colour the picker below edits.
@(private = "file")
kit_background :: proc(app: ^App) {
	ctx := &app.kit.ctx
	b := &app.background
	_ = ui.switch_row(ctx, "Gradient", &b.gradient)
	if !b.gradient {
		_ = kit_color(app, "background colour", &b.top)
		kit_background_transparent(app)
		return
	}
	edges := [2]string{"Top", "Bottom"}
	if picked := ui.tabs(ctx, "background edge", edges[:], int(app.kit.background_bottom)); picked >= 0 do app.kit.background_bottom = picked == 1
	if app.kit.background_bottom {
		_ = kit_color(app, "background bottom", &b.bottom)
	} else {
		_ = kit_color(app, "background top", &b.top)
	}
	ui.paragraph(ctx, "The top colour shades into the bottom one down the viewport. Screenshots and the render show it too.")
	kit_background_transparent(app)
}

// The turntable: how many frames the turn takes, and Record or, while it records, Stop
// with how far it is.
@(private = "file")
kit_turntable :: proc(app: ^App) {
	ctx := &app.kit.ctx
	tt := &app.turntable
	frames := f32(app.turntable_frames)
	seconds := fmt.tprintf("%d · %.1f s", app.turntable_frames, frames / TURNTABLE_FPS)
	if ui.slider(ctx, "Frames", &frames, TURNTABLE_FRAMES_MIN, TURNTABLE_FRAMES_MAX, .Logarithmic, seconds, enabled = !tt.on) do app.turntable_frames = i32(frames + 0.5)
	if tt.on {
		_ = command_button(app, .Record_Turntable, label = fmt.tprintf("Stop recording (%d of %d)", tt.frame, tt.frames), variant = .Solid, tone = .Danger, width = ui.fill_width(ctx), glyph = ui.ICON_STOP)
	} else {
		_ = command_button(app, .Record_Turntable, width = ui.fill_width(ctx), glyph = ui.ICON_FILM)
	}
	ui.paragraph(ctx, "The camera goes once round the scene. Each frame is saved as a picture, and the whole as one animated picture that loops; without the background when Screenshots without background is on.")
}

// Whether screenshots leave the background out.
@(private = "file")
kit_background_transparent :: proc(app: ^App) {
	on := app.screenshot_transparent
	if ui.switch_row(&app.kit.ctx, "Screenshots without background", &on, keys = command_hint(app, .Screenshot_Transparent)) do command_run(app, .Screenshot_Transparent)
}

// The floor grid: whether it shows, which planes, the axes, and its cells.
@(private = "file")
kit_floor :: proc(app: ^App) {
	ctx := &app.kit.ctx
	f := &app.floor
	on := f.on
	if ui.switch_row(ctx, "Floor grid", &on, keys = command_hint(app, .Floor_Grid)) do command_run(app, .Floor_Grid)
	ui.caption(ctx, "PLANES")
	ui.begin(ctx, "floor planes", {direction = .Row, gap = 4})
	planes := [3]struct {
		name, tip: string,
	}{{"Side", "The wall square to X, on the far side"}, {"Floor", "The floor, under the scene"}, {"Back", "The wall square to Z, behind the scene"}}
	// Floor first, then the walls.
	for axis in ([3]int{1, 2, 0}) {
		p := planes[axis]
		if ui.toggle_button(ctx, p.name, f.planes[axis], 92, tooltip = p.tip) do f.planes[axis] = !f.planes[axis]
	}
	ui.end(ctx)
	if kit_more(app, .Floor) {
		_ = ui.switch_row(ctx, "Axes in colour", &f.axes)
		_ = ui.switch_row(ctx, "Fit cells to the scene", &f.fit)
		if !f.fit do _ = ui.slider(ctx, "Cell size", &f.cell, FLOOR_CELL_MIN, FLOOR_CELL_MAX, .Logarithmic, fmt.tprintf("%.3g", f.cell))
		kit_more_end(app)
	}
	ui.paragraph(ctx, "The floor lies under everything shown and the walls behind it as you look, with a brighter line every fifth cell. Red is X, green Y, blue Z.")
}

@(private = "file")
kit_add :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	// The shapes, then every content pack's meshes, by pack: picking a mesh adds it as
	// Import would, so it has no size to pick.
	shapes := make([dynamic]string, context.temp_allocator)
	meshes := make([dynamic]int, context.temp_allocator)
	for s in geom.Primitive do append(&shapes, fmt.tprint(s))
	for pack in app.library.packs {
		for m, j in app.library.meshes {
			if m.gone || m.pack != pack.id do continue
			append(&shapes, fmt.tprintf("%s (%s)", m.stem, pack.name))
			append(&meshes, j)
		}
	}
	shown := int(k.add_shape)
	for j, i in meshes do if k.add_mesh == j + 1 do shown = len(geom.Primitive) + i
	if picked := ui.select(ctx, "add shape", shapes[:], shown); picked >= 0 {
		if picked < len(geom.Primitive) do k.add_shape, k.add_mesh = geom.Primitive(picked), 0
		else do k.add_mesh = meshes[picked - len(geom.Primitive)] + 1
	}
	if pm, on := pack_mesh_at(app, k.add_mesh - 1); on {
		_ = command_button(app, .Add_Object, label = fmt.tprintf("Add %s", pm.stem), variant = .Solid, tone = .Accent, glyph = ui.ICON_PLUS)
		ui.paragraph(ctx, fmt.tprintf("From the content pack %s: %s vertices and %s triangles, added beside the others and sized as Import sizes a file.", pack_mesh_pack_name(app, k.add_mesh - 1), count_label(pm.vertices), count_label(pm.triangles)))
		return
	}
	if picked := ui.select(ctx, "add size", kit_size_names(), k.add_size); picked >= 0 do k.add_size = picked
	vertices := int(SPHERE_PRESETS[k.add_size].vertices)
	_ = ui.switch_row(ctx, "As voxels", &k.add_voxel)
	if k.add_voxel {
		// A voxel sphere of the resolution whose surface has about the size's vertices.
		resolution := voxel_resolution_for(vertices)
		_ = command_button(app, .Add_Object, label = "Add voxels", variant = .Solid, tone = .Accent, glyph = ui.ICON_PLUS)
		ui.paragraph(ctx, fmt.tprintf("Builds a sphere of clay %d voxels across, about %s surface vertices, sculpted as a volume: Draw, Clay and Layer add clay, Ctrl takes it away. Convert to mesh (Object palette, Voxels) for the other tools.", resolution, count_label(voxel_vertices_for(resolution))))
		return
	}
	_ = command_button(app, .Add_Object, label = fmt.tprintf("Add %v", k.add_shape), variant = .Solid, tone = .Accent, glyph = ui.ICON_PLUS)
	// Geodesic spheres come in steps of 10f² + 2 vertices; say what will be built.
	f := geom.geodesic_frequency_for(vertices)
	built := 10 * f * f + 2 if k.add_shape == .Sphere else vertices
	// A starter comes with subdivision levels, the ones below holding about a third more.
	levels := starter_levels(vertices) if geom.is_starter(k.add_shape) else 0
	memory := built + built / 3 if levels > 0 else built
	on := fmt.tprintf(" on %d subdivision levels", levels + 1) if levels > 0 else ""
	ui.paragraph(ctx, fmt.tprintf("Builds %s%s vertices%s, about %s of memory.", "" if k.add_shape == .Sphere else "about ", count_label(built), on, bytes_label(memory * BYTES_PER_VERTEX)))
}

// The selected object's material: the classic presets, the physically based ones, the
// MatCaps, Custom, then every content pack's by pack, and sliders that edit whichever is
// in use into a Custom one. A change goes to
// every selected object as a Scene_Command and becomes the material new objects take;
// with nothing selected it only sets that.
@(private = "file")
kit_material :: proc(app: ^App) {
	ctx := &app.kit.ctx
	sel := selected_object(app)
	// With polygroups the section edits the object's material or one group's.
	if sel != nil && command_enabled(app, .Pick_Group, 0) {
		targets := [2]string{"Object", "Group"}
		if picked := ui.tabs(ctx, "material target", targets[:], int(app.ui.material_groups)); picked >= 0 do app.ui.material_groups = picked == 1
		if app.ui.material_groups {
			kit_group_material(app, sel)
			return
		}
	}
	m := object_material(app, sel) if sel != nil else current_material(app)
	index := material_index(m)
	// Custom in the list is the object's own Custom, or the last one made.
	custom := m if index == CUSTOM_MATERIAL else app.custom
	// The list's names and, for each, what app.material calls it.
	names := make([dynamic]string, context.temp_allocator)
	numbers := make([dynamic]int, context.temp_allocator)
	for p, i in MATERIALS {
		append(&names, string(p.label) if i < FIRST_PBR || p.matcap != 0 else fmt.tprintf("%s (physically based)", p.label))
		append(&numbers, i)
	}
	append(&names, "Custom" if custom.matcap == 0 else fmt.tprintf("Custom (%s MatCap)", matcap_label(app, custom.matcap)))
	append(&numbers, CUSTOM_MATERIAL)
	for pack in app.library.packs {
		for pm, j in app.library.materials {
			if pm.gone || pm.pack != pack.id do continue
			append(&names, fmt.tprintf("%s (%s)", pm.name, pack.name))
			append(&numbers, PACK_MATERIAL + j)
		}
	}
	shown := 0
	for n, i in numbers do if n == index do shown = i
	if picked := ui.select(ctx, "material", names[:], shown); picked >= 0 {
		n := numbers[picked]
		switch {
		case n == CUSTOM_MATERIAL: app.ui.scene_command = {kind = .Material, material = custom}
		case n >= PACK_MATERIAL:   app.ui.scene_command = {kind = .Material, material = app.library.materials[n - PACK_MATERIAL].material}
		case:                      app.ui.scene_command = {kind = .Material, material = MATERIALS[n]}
		}
	}
	// The sliders show the material in use; moving one makes it Custom, so a preset is
	// never changed. A classic preset has no roughness yet, so it starts rough.
	if m.roughness == 0 do m.roughness = CUSTOM_ROUGHNESS
	changed := kit_color(app, "material colour", (^[3]f32)(&m.selected), linear = true)
	// How every material is shown, kept apart from the materials themselves: Cavity
	// darkens creases and Ridge lightens crests, so fine detail reads at any light angle.
	_ = ui.slider(ctx, "Cavity", &app.cavity, 0, 1, .Linear, fmt.tprintf("%.2f", app.cavity))
	if kit_more(app, .Material) {
		if ui.button(ctx, "Load MatCap...", .Bordered, glyph = ui.ICON_IMAGE) do file_dialog(app, .Matcap)
		// A matcap's picture holds its sheen, so it has no metallic or roughness.
		if m.matcap == 0 {
			changed |= ui.slider(ctx, "Metallic", &m.metallic, 0, 1, .Linear, fmt.tprintf("%.2f", m.metallic))
			changed |= ui.slider(ctx, "Roughness", &m.roughness, 0.04, 1, .Linear, fmt.tprintf("%.2f", m.roughness))
		}
		_ = ui.slider(ctx, "Ridge", &app.ridge, 0, 1, .Linear, fmt.tprintf("%.2f", app.ridge))
		_ = ui.slider(ctx, "Exposure", &app.exposure, -EXPOSURE_RANGE, EXPOSURE_RANGE, .Linear, fmt.tprintf("%+.1f stops", app.exposure))
		_ = ui.switch_row(ctx, "Dim the others", &app.dim_others)
		kit_more_end(app)
	}
	if changed {
		m.label = "Custom"
		app.ui.scene_command = {kind = .Material, material = m}
	}
	ui.paragraph(ctx, "Each object has its own material, kept in the scene file; this sets the selected objects' and the one new objects take. Content packs' materials come after Custom. Moving the colour, Metallic or Roughness makes it Custom; the presets stay as they are. A MatCap is a picture of a lit sphere that stands in for the lights, tinted by the colour. Cavity darkens creases and Ridge lightens crests on every material. Dim the others shows the objects not selected in a muted colour.")
}

// One polygroup's material: Pick a group, then a lit preset or Custom values for it, as the
// object's own are picked; under More its Metallic and Roughness, and Use the object's
// material to give its own back.
@(private = "file")
kit_group_material :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	u := &app.ui
	_ = command_button(app, .Pick_Group, label = "Press on a group..." if u.group_pick else "", variant = .Bordered, tone = .Accent if u.group_pick else .Neutral)
	if u.group_target_id != obj.id || u.group_target == 0 {
		ui.paragraph(ctx, "Pick a group, then a material for it: gold trim on a steel plate, in one object. Every other group keeps the object's material. Up to 15 groups an object; not MatCaps, whose picture is the object's.")
		return
	}
	group := u.group_target
	m, own := group_material_of(app, obj, group)
	// A MatCap object's material is lit for its groups.
	if m.matcap != 0 {
		m.matcap = 0
		m.label = "Custom"
	}
	index := material_index(m)
	custom := m if index == CUSTOM_MATERIAL || index >= FIRST_MATCAP else app.custom
	custom.matcap, custom.label = 0, "Custom"
	names: [FIRST_MATCAP + 1]string
	for i in 0 ..< FIRST_MATCAP do names[i] = string(MATERIALS[i].label) if i < FIRST_PBR else fmt.tprintf("%s (physically based)", MATERIALS[i].label)
	names[FIRST_MATCAP] = "Custom"
	send :: proc(app: ^App, obj: ^Object, group: u16, m: Material, clear := false) {
		app.ui.scene_command = {kind = .Group_Material, id = obj.id, group = group, material = m, on = clear}
	}
	shown := index if index < FIRST_MATCAP else FIRST_MATCAP
	if picked := ui.select(ctx, fmt.tprintf("Group %d", group), names[:], shown); picked >= 0 {
		send(app, obj, group, custom if picked == FIRST_MATCAP else MATERIALS[picked])
	}
	if m.roughness == 0 do m.roughness = CUSTOM_ROUGHNESS
	changed := kit_color(app, "group colour", (^[3]f32)(&m.selected), linear = true)
	if kit_more(app, .Material) {
		changed |= ui.slider(ctx, "Metallic", &m.metallic, 0, 1, .Linear, fmt.tprintf("%.2f", m.metallic))
		changed |= ui.slider(ctx, "Roughness", &m.roughness, 0.04, 1, .Linear, fmt.tprintf("%.2f", m.roughness))
		if ui.button(ctx, "Use the object's material", .Bordered, enabled = own) do send(app, obj, group, {}, clear = true)
		kit_more_end(app)
	}
	if changed {
		m.label = "Custom"
		send(app, obj, group, m)
	}
	ui.paragraph(ctx, fmt.tprintf("Group %d shows %s. Picking or moving anything here gives it its own; the object's other groups keep theirs.", group, "its own material" if own else "the object's material"))
}

@(private = "file")
kit_camera :: proc(app: ^App) {
	ctx := &app.kit.ctx
	ui.paragraph(ctx, "Orbit: right drag, or Alt + left drag. Pan: middle drag, or Shift + right drag. Zoom: the wheel. On a touch screen two fingers pan and pinch.")
	_ = ui.switch_row(ctx, "Orthographic", &app.camera.ortho, keys = command_hint(app, .Ortho_Toggle))
	// Two rows of three, each view beside its opposite's row: the keypad's 1, 3 and 7,
	// and with Ctrl the other side.
	views := [2][3]camera.Axis_View{{.Front, .Right, .Top}, {.Back, .Left, .Bottom}}
	for row, r in views {
		names, hints: [3]string
		for v, i in row do names[i], hints[i] = fmt.tprint(v), command_hint(app, .View_Axis, int(v))
		if picked := ui.tabs(ctx, fmt.tprintf("look from %d", r), names[:], -1, keys = hints[:]); picked >= 0 do command_run(app, .View_Axis, int(row[picked]))
	}
	kit_command_pair(app, .Reset_Camera, .Focus_Selected)
	if kit_more(app, .Camera) {
		_ = ui.slider(ctx, "Distance", &app.camera.distance, camera.MIN_DISTANCE, 20, .Logarithmic, fmt.tprintf("%.2f", app.camera.distance))
		kit_more_end(app)
	}
}
