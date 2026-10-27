package main

import "core:fmt"
import "core:slice"
import "core:strings"

import "../camera"
import "../geom"
import "../ui"

// The tray's Scene palette: the objects, adding one, and how the whole scene is shown,
// the section picked in the tray's list.
kit_scene_tab :: proc(app: ^App) {
	ctx := &app.kit.ctx
	shown := tray_section(app, .Scene)
	if shown == .Objects {
		kit_scene_objects(app)
		return
	}
	for sec in SCENE_SECTIONS {
		if sec.section != shown do continue
		kit_section_title(ctx, sec.title)
		sec.draw(app)
	}
}

// The Scene palette's Objects section: the tree of objects and folders, what acts on the
// selection, and how long the last file took.
@(private = "file")
kit_scene_objects :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	total := 0
	for obj in app.scene.objects do total += object_vertex_count(obj)
	ui.caption(ctx, fmt.tprintf("OBJECTS  %d  ·  %s VERTICES", len(app.scene.objects), count_label(total)))
	k.tree_rows = 0
	base := boolean_base(app)
	// The list's order is the tree's: a folder's objects are next to each other, so one
	// walk draws each folder's row before its objects.
	objects := app.scene.objects[:]
	spots := make([dynamic]Tree_Spot, 0, len(objects) + len(app.scene.folders), context.temp_allocator)
	for i := 0; i < len(objects); {
		obj := objects[i]
		f := folder_by_id(app, obj.folder)
		if f == nil {
			kit_object_row(app, &spots, i, base, 0)
			i += 1
			continue
		}
		first, end := folder_span(app, f.id)
		kit_folder_row(app, &spots, f, first, end)
		if f.open do for j in first ..< end do kit_object_row(app, &spots, j, base, 1)
		i = end
	}
	// Folders with nothing in them yet come last.
	for &f in app.scene.folders {
		if first, end := folder_span(app, f.id); end > first do continue
		kit_folder_row(app, &spots, &f, 0, 0)
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

// An object's row in the Scene palette, the list's `i`th, under its folder's when `depth` is 1.
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
	row := ui.tree_row(ctx, fmt.tprintf("%s##%d", object_label(obj), obj.id), detail, object_in_selection(app, obj), depth, all_toggles = toggles[:], glyph = ui.ICON_FRAME, dim = dragged || !object_shown(app, obj), grip = true)
	append(spots, Tree_Spot{rect = row.rect, id = obj.id, folder = obj.folder, next = objects[i + 1].id if i + 1 < len(objects) else 0, off = obj.off, ghost = obj.ghost})
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
	if row.menu do object_menu_open(app, obj.id, {ctx.input.mouse.x, ctx.input.mouse.y, 0, 0}, .Pointer)
	k.tree_rows += 1
}

// A folder's row, its objects being the list's [first, end): its chevron folds it, its
// eye and ghost apply to everything in it, its grip drags them all, a tap selects its
// first object and a long press or right-click opens its menu.
@(private = "file")
kit_folder_row :: proc(app: ^App, spots: ^[dynamic]Tree_Spot, f: ^Folder, first, end: int) {
	k := &app.kit
	ctx := &k.ctx
	objects := app.scene.objects[:]
	members := objects[first:end]
	vertices := 0
	for obj in members do vertices += object_vertex_count(obj)
	detail := "empty" if len(members) == 0 else fmt.tprintf("%d · %s", len(members), count_label(vertices))
	selected := false
	if sel := selected_object(app); sel != nil && !f.open do selected = sel.folder == f.id
	toggles := row_toggles(folder_label(f), f.off, f.ghost)
	// The panel only reads the folder: folding it is a view command like its eye.
	open := f.open
	dragged := k.tree_drag.active && k.tree_drag.key == -f.id
	row := ui.tree_row(ctx, fmt.tprintf("%s##folder %d", folder_label(f), f.id), detail, selected, open = &open, all_toggles = toggles[:], glyph = ui.ICON_FOLDER, dim = dragged || f.off, grip = len(members) > 0)
	spot := Tree_Spot{rect = row.rect, id = f.id, is_folder = true, folder = f.id, off = f.off, ghost = f.ghost}
	if len(members) > 0 do spot.first = members[0].id
	if end < len(objects) && len(members) > 0 do spot.next = objects[end].id
	append(spots, spot)
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
	first:     int, // a folder row: its first object's id, 0 when it has none
	// The id of the object after the row's object, or after the folder's objects; 0 at
	// the end of the list.
	next:      int,
	off:       bool, // its own eye and ghost, which its toggles show
	ghost:     bool,
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
	folder: int, // the folder an object ends in, 0 for none
	into:   int, // the spot of the folder row it goes into, -1 for none
	y:      f32, // where the drop line is drawn
}

// Where a row dragged to `at` goes. An object over the middle half of a folder's row
// goes into the folder, after its objects. Otherwise each row has a gap above it and the
// list one under its last row: the gap nearest the pointer takes the row, into the folder
// of the row under it, and one under a folder's last object keeps it in that folder when
// the pointer is right of the indent. A folder goes only into the gaps above rows outside
// folders, its objects going along.
tree_drop :: proc(spots: []Tree_Spot, folder_drag: bool, at: [2]f32) -> (d: Tree_Drop) {
	d.into = -1
	if len(spots) == 0 do return
	top, last := spots[0].rect, spots[len(spots) - 1].rect
	if at.x < top.x || at.x > top.x + top.w do return
	d.ok = true
	if !folder_drag {
		for s, i in spots {
			if !s.is_folder || at.y < s.rect.y + s.rect.h * 0.25 || at.y > s.rect.y + s.rect.h * 0.75 do continue
			d.into, d.before, d.folder, d.y = i, s.next, s.id, s.rect.y + s.rect.h * 0.5
			return
		}
	}
	// Empty folders come after every object, so the list's end is above them.
	n := len(spots)
	for n > 1 && spots[n - 1].is_folder && spots[n - 1].first == 0 do n -= 1
	last = spots[n - 1].rect
	best, best_dist := n, abs(at.y - (last.y + last.h))
	d.y = last.y + last.h
	for s, j in spots[:n] {
		if folder_drag && !s.is_folder && s.folder != 0 do continue
		y := s.rect.y if j == 0 else (spots[j - 1].rect.y + spots[j - 1].rect.h + s.rect.y) * 0.5
		if dist := abs(at.y - y); dist < best_dist do best, best_dist, d.y = j, dist, y
	}
	if best < n {
		s := spots[best]
		if s.is_folder do d.before = s.first
		else do d.before, d.folder = s.id, s.folder
	}
	if !folder_drag && best > 0 {
		a := spots[best - 1]
		if !a.is_folder && a.folder != 0 && a.folder != d.folder && at.x >= top.x + ui.TREE_INDENT + 8 do d.before, d.folder = a.next, a.folder
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
kit_tree_drags :: proc(app: ^App, spots: []Tree_Spot, scroll: Tree_Scroll) {
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
				// A folder's row the sweep crossed decides for its objects: theirs keep
				// their own flags, so turning the folder back shows them as they were.
				if s.is_folder && c.folder_count < len(c.folders) {
					c.folders[c.folder_count] = s.id
					c.folder_count += 1
				}
				if !s.is_folder && slice.contains(c.folders[:c.folder_count], s.folder) do continue
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
	drop := tree_drop(spots, d.key < 0, in_.mouse)
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
		x := top.x + 8 + (ui.TREE_INDENT if drop.folder != 0 else 0)
		ui.fill_circle(ctx, {x, drop.y}, 4, t.accent)
		ui.fill_circle(ctx, {x, drop.y}, 2, t.surface)
		ui.fill_rect(ctx, {x + 4, drop.y - 1, top.x + top.w - 8 - x - 4, 2}, 1, t.accent)
		return
	}
	// Let go: a drag that went somewhere moves the row; a cancelled one does nothing.
	if d.active && drop.ok && .Left in in_.released && !in_.cancel {
		if d.key < 0 do app.ui.scene_command = {kind = .Arrange, arrange = .Reorder_Folder, id = -d.key, before = drop.before}
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
	{.Material, "Material", kit_material, nil},
	{.Lights, "Lights", kit_lights, nil},
	{.Studio, "Studio render", kit_studio, nil},
	{.Camera, "Camera", kit_camera, nil},
}

@(private = "file")
kit_add :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	shapes: [len(geom.Primitive)]string
	for s, i in geom.Primitive do shapes[i] = fmt.tprint(s)
	if picked := ui.select(ctx, "add shape", shapes[:], int(k.add_shape)); picked >= 0 do k.add_shape = geom.Primitive(picked)
	if picked := ui.select(ctx, "add size", kit_size_names(), k.add_size); picked >= 0 do k.add_size = picked
	vertices := int(SPHERE_PRESETS[k.add_size].vertices)
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

// The classic presets, the physically based ones, the MatCaps, and sliders that edit
// whichever is in use into the Custom material.
@(private = "file")
kit_material :: proc(app: ^App) {
	ctx := &app.kit.ctx
	names: [len(MATERIALS) + 1]string
	for m, i in MATERIALS do names[i] = string(m.label) if i < FIRST_PBR || m.matcap != 0 else fmt.tprintf("%s (physically based)", m.label)
	names[CUSTOM_MATERIAL] = "Custom" if app.custom.matcap == 0 else fmt.tprintf("Custom (%s MatCap)", matcap_label(app, app.custom.matcap))
	if picked := ui.select(ctx, "material", names[:], app.material); picked >= 0 do app.material = picked
	// The sliders show the material in use; moving one copies it into Custom first, so a
	// preset is never changed. A classic preset has no roughness yet, so it starts rough.
	m := current_material(app)
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
		kit_more_end(app)
	}
	if changed {
		m.label = "Custom"
		app.custom = m
		app.material = CUSTOM_MATERIAL
	}
	ui.paragraph(ctx, "Moving the colour, Metallic or Roughness makes a Custom material from the one in use; the presets stay as they are. A MatCap is a picture of a lit sphere that stands in for the lights, tinted by the colour. Cavity darkens creases and Ridge lightens crests on every material.")
}

// The light rig's turn, height and strengths, and whether it stays with the camera or
// the scene (lights.odin).
@(private = "file")
kit_lights :: proc(app: ^App) {
	ctx := &app.kit.ctx
	_ = ui.slider(ctx, "Turn", &app.light_turn, -180, 180, .Linear, fmt.tprintf("%+.0f°", app.light_turn))
	_ = ui.slider(ctx, "Height", &app.light_height, -90, 90, .Linear, fmt.tprintf("%+.0f°", app.light_height))
	_ = ui.slider(ctx, "Key light", &app.light_key, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", app.light_key))
	fixed := app.lights_fixed
	if ui.switch_row(ctx, "Fixed to the scene", &fixed) do lights_fix(app, fixed)
	if kit_more(app, .Lights) {
		_ = ui.slider(ctx, "Fill light", &app.light_fill, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", app.light_fill))
		if ui.button(ctx, "Reset lights", .Bordered) do lights_reset(app)
		kit_more_end(app)
	}
	ui.paragraph(ctx, "Turn and Height swing the key light, the fill and the studio's reflections round together. Fixed to the scene, they stay put while the camera goes round, as on a turntable; otherwise they turn with the camera. MatCaps carry their own light.")
}

@(private = "file")
kit_studio :: proc(app: ^App) {
	ctx := &app.kit.ctx
	on := app.studio_on
	if ui.switch_row(ctx, "Studio render", &on, keys = command_hint(app, .Studio_Render)) do command_run(app, .Studio_Render)
	_ = ui.slider(ctx, "Occlusion", &app.studio_ao, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_ao))
	_ = ui.slider(ctx, "Shadow", &app.studio_shadow, 0, 1, .Linear, fmt.tprintf("%.2f", app.studio_shadow))
	samples := f32(app.studio_samples)
	if ui.slider(ctx, "Samples", &samples, 16, STUDIO_SAMPLES_MAX, .Logarithmic, fmt.tprintf("%d", app.studio_samples)) do app.studio_samples = i32(samples + 0.5)
	if app.studio_on && app.studio.samples > 0 && app.studio.samples < int(app.studio_samples) {
		ui.paragraph(ctx, fmt.tprintf("Built up %d of %d samples.", app.studio.samples, app.studio_samples))
	}
	ui.paragraph(ctx, fmt.tprintf("Ambient occlusion and soft shadows build up while the view stays still; any change starts them over. %s", command_keys(app, .Studio_Render)))
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
