package main

import "core:fmt"

import "../ui"

// The object menu (the overhaul's round 3, PR 6): what can be done to the selected object,
// by what it is and the space at work, as Blender's object context menu and Nomad's object
// popover offer it. Its head names the object, its type and size; a quick row of icons
// frames, solos, hides and locks it (and opens its layers); then this space's verbs for
// its type, the other spaces' main verbs tagged with their space (picking one switches
// there first), the rows every object has (material, folders, rename, duplicate, its
// conversion) and Delete. The rows are a table of registry commands, so a verb's label,
// shortcut, enabled rule and undo are the command's own.

Object_Type :: enum u8 {
	Sculpt_Mesh,
	Voxel_Clay,
	Cage,
	Curve,
}

@(rodata)
OBJECT_TYPE_NAMES := [Object_Type]string {
	.Sculpt_Mesh = "Sculpt mesh",
	.Voxel_Clay  = "Voxel clay",
	.Cage        = "Cage",
	.Curve       = "Curve",
}

@(rodata)
OBJECT_TYPE_ICONS := [Object_Type]rune {
	.Sculpt_Mesh = ICON_SCULPT_MESH,
	.Voxel_Clay  = ICON_VOXEL_CLAY,
	.Cage        = ICON_CAGE,
	.Curve       = ui.ICON_SPLINE,
}

// What `obj` is, as its chip says: clay, then a cage, then a curve, else a mesh to sculpt.
object_type :: proc(obj: ^Object) -> Object_Type {
	if obj.voxel != nil do return .Voxel_Clay
	if obj.cage != nil do return .Cage
	if obj.curve != nil do return .Curve
	return .Sculpt_Mesh
}

// A row of the menu: a registry command and its argument, under its own label or, with
// none, the command's.
Object_Verb :: struct {
	id:    Command_Id,
	arg:   int,
	label: string,
}

// Each type's verbs in each space, the first its main one there, which the other spaces'
// menus offer with this space's tag. A space with none for a type offers nothing of its
// own (the rows every object has stay).
@(rodata)
OBJECT_VERBS := [Object_Type][Space][]Object_Verb {
	.Sculpt_Mesh = {
		.Sculpt = {{id = .Subdivide}, {id = .Remesh}, {id = .Dyntopo_Toggle}, {id = .New_Layer}, {id = .Extract_Masked}, {id = .Mirror_Weld}},
		.Model  = {{id = .Edit_Cage, label = "Make editable"}, {id = .Retopologize}},
		.Render = {},
	},
	.Voxel_Clay = {
		.Sculpt = {{id = .Voxel_Res_Up, label = "More voxels (Res+)"}, {id = .Voxel_Res_Down, label = "Fewer voxels (Res-)"}},
		.Model  = {{id = .Convert_To_Mesh, label = "Make a mesh to edit"}},
		.Render = {},
	},
	.Cage = {
		.Sculpt = {{id = .Apply_Cage, label = "Make sculptable"}},
		.Model  = {{id = .Cage_Smooth, arg = 2, label = "Smooth twice"}, {id = .Cage_Smooth, arg = 0, label = "Draw unsmoothed"}, {id = .Tidy_Cage, arg = int(Cage_Tidy.Dissolve_Flat), label = "Dissolve flat faces"}, {id = .Tidy_Cage, arg = int(Cage_Tidy.Merge_Close), label = "Merge close points"}},
		.Render = {},
	},
	// A curve is drawn and edited in Sculpt's Curve tool; in Model it makes cages, and Bake
	// makes what it shows a mesh in any space.
	.Curve = {
		.Sculpt = {{id = .Curve_Bake, label = "Bake to mesh"}, {id = .Curve_Close}},
		.Model  = {{id = .Curve_Pipe_Cage, label = "Pipe cage"}, {id = .Curve_Lathe_Cage, label = "Lathe cage"}, {id = .Curve_Loft_Cage, label = "Loft cage"}, {id = .Curve_Bake, label = "Bake to mesh"}},
		.Render = {},
	},
}

// The conversion every type offers among the rows always there.
@(rodata)
OBJECT_CONVERSIONS := [Object_Type]Object_Verb {
	.Sculpt_Mesh = {id = .Convert_To_Voxels},
	.Voxel_Clay  = {id = .Convert_To_Mesh},
	.Cage        = {id = .Apply_Cage, label = "Make sculptable"},
	.Curve       = {id = .Curve_Bake, label = "Bake to mesh"},
}

// What opened the object menu or the scene menu, for the exit stats.
Menu_Opener :: enum u8 {
	None,
	Chip, // a tap on the chip bar's object chip
	List, // a Scene palette row's right-click or long press
	Right, // a right click on the view
	Pen, // the pen's side button (the Object menu command, run by the gesture map)
	Finger, // one finger held still on the view
	Command, // the Object menu command from a key or Search
}

// Opens the object menu on object `id`, `side` of `at`. The menu acts on the selection, so
// the object becomes the selection's first: at once when a press could pick it, as the
// Scene palette's row does; a hidden, ghosted or locked one is brought back and selected by
// a scene change, which applies at the next frame's start.
object_menu_open :: proc(app: ^App, id: int, at: ui.Rect, side: ui.Side, by: Menu_Opener) {
	k := &app.kit
	k.object_menu, k.object_menu_id, k.object_menu_at, k.object_menu_side = true, id, at, side
	k.object_menu_wait, k.object_menu_by = false, by
	if obj := selected_object(app); obj != nil && obj.id == id do return
	for obj, i in app.scene.objects {
		if obj.id != id do continue
		if object_pickable(app, obj) {
			selection_make_primary(app, i)
		} else {
			app.ui.scene_command = {kind = .View, view = .Select, id = id}
			k.object_menu_wait = true
		}
	}
}

// Opens the menu for what is under `pos` (the main view's coordinates, `size` its size):
// the object menu on an object there, else the scene menu, at that point. Everything else
// floating closes first, as a menu opening anywhere does.
view_menu_open :: proc(app: ^App, pos, size: [2]f32, by: Menu_Opener) {
	k := &app.kit
	kit_floats_close(k)
	p := (pos + app.ui.viewport_origin) / k.scale
	at := ui.Rect{p.x, p.y, 0, 0}
	origin, dir := mouse_ray(app.camera, pos, size)
	if index, _, ok := scene_raycast(app, origin, dir); ok {
		object_menu_open(app, app.scene.objects[index].id, at, .Pointer, by)
		return
	}
	scene_menu_open(app, at, .Pointer, by)
}

scene_menu_open :: proc(app: ^App, at: ui.Rect, side: ui.Side, by: Menu_Opener) {
	k := &app.kit
	k.scene_menu, k.scene_menu_at, k.scene_menu_side, k.object_menu_by = true, at, side, by
}

// The Object menu command: at the pointer while it is on the view (a key pressed there, the
// pen's side button), else under the object chip for the selection, or the scene menu there
// with nothing selected.
object_menu_here :: proc(app: ^App) {
	k := &app.kit
	by := Menu_Opener.Pen if app.device.pointer == .Pen else .Command
	pos := viewport_point(app, app.device.mouse)
	size := app.ui.viewport_size
	inside := pos.x >= 0 && pos.y >= 0 && pos.x <= size.x && pos.y <= size.y
	if inside && !ui.wants_pointer(&k.ctx) {
		view_menu_open(app, pos, size, by)
		return
	}
	kit_floats_close(k)
	if obj := selected_object(app); obj != nil {
		object_menu_open(app, obj.id, k.object_chip_at, .Below, by)
	} else {
		scene_menu_open(app, k.object_chip_at, .Below, by)
	}
}

// The menu, while open.
kit_object_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	k.object_menu_rows = 0
	obj := selected_object(app)
	// The selection is the menu's object, or a scene change is bringing it back: else it has
	// gone (deleted, undone) or another was selected, and the menu goes with it.
	ready := obj != nil && obj.id == k.object_menu_id
	if !ready && !k.object_menu_wait do k.object_menu = false
	if ready do k.object_menu_wait = false
	if !ui.popover_begin(ctx, "object menu", &k.object_menu, k.object_menu_at, k.object_menu_side, {direction = .Column, padding = 6, width = OBJECT_MENU_W}) do return
	defer ui.popover_end(ctx)
	if !ready {
		ui.paragraph(ctx, "Selecting it...")
		return
	}
	kind := object_type(obj)
	space := k.spaces.current
	k.object_menu_type = kind
	object_menu_head(app, obj, kind)
	picked := object_menu_quick(app, kind)
	ui.divider(ctx, across = true)
	shown := make([dynamic]Object_Verb, 0, 16, context.temp_allocator)
	for v in OBJECT_VERBS[kind][space] {
		if command_menu_item(app, v.id, v.arg, label = v.label) do picked = true
		append(&shown, v)
		k.object_menu_rows += 1
	}
	// Another space's main verb (its first that can run on this object), tagged with that
	// space: enabled as the command is here, so a switch never lands on a refusal; picked, it
	// switches space, then runs. The tag takes the shortcut's place, so the shortcut is in the tooltip.
	for s in Space {
		if s == space || len(OBJECT_VERBS[kind][s]) == 0 do continue
		v := OBJECT_VERBS[kind][s][0]
		for w in OBJECT_VERBS[kind][s] do if command_enabled(app, w.id, w.arg) {
			v = w
			break
		}
		label := v.label if v.label != "" else command_label(v.id, v.arg)
		if ui.menu_item(ctx, fmt.tprintf("%s##in %v", label, s), glyph = COMMANDS[v.id].icon, enabled = command_enabled(app, v.id, v.arg), hint = command_hint(app, v.id, v.arg), tag = SPACE_NAMES[s], tag_color = t.tints[int(s)]) {
			command_run(app, .Space_Switch, int(s))
			command_run(app, v.id, v.arg)
			picked = true
		}
		append(&shown, v)
		k.object_menu_rows += 1
	}
	ui.divider(ctx, across = true)
	if command_menu_item(app, .Show_Section, int(Kit_Section.Material), label = "Material") do picked = true
	if command_menu_item(app, .Rename_Object) do picked = true
	if command_menu_item(app, .Duplicate_Object) do picked = true
	k.object_menu_rows += 3
	conv := OBJECT_CONVERSIONS[kind]
	seen := false
	for v in shown do seen ||= v.id == conv.id && v.arg == conv.arg
	if !seen {
		if command_menu_item(app, conv.id, conv.arg, label = conv.label) do picked = true
		k.object_menu_rows += 1
	}
	// Where it can go in the tree: a new folder, each other folder (named with the folders
	// holding it, so two of one name tell apart), or out of its own, one level up.
	if command_menu_item(app, .New_Folder) do picked = true
	for &f in app.scene.folders {
		if f.id == obj.folder do continue
		if ui.menu_item(ctx, fmt.tprintf("Move to %s##into %d", folder_path_label(app, &f), f.id), glyph = ui.ICON_FOLDER) {
			app.ui.scene_command = {kind = .Arrange, arrange = .Into_Folder, id = obj.id, folder = f.id}
			picked = true
		}
	}
	if obj.folder != 0 && ui.menu_item(ctx, "Take out of folder", glyph = ui.ICON_FOLDER) {
		app.ui.scene_command = {kind = .Arrange, arrange = .Out_Of_Folder, id = obj.id}
		picked = true
	}
	ui.divider(ctx, across = true)
	if command_menu_item(app, .Delete_Object, tone = .Danger) do picked = true
	if picked do k.object_menu = false
}

// Wide enough for the quick row's five touch targets and the padding round them.
OBJECT_MENU_W :: 268

// The head: the type's icon, the name, the type and how big it is; not pressable.
@(private = "file")
object_menu_head :: proc(app: ^App, obj: ^Object, kind: Object_Type) {
	ctx := &app.kit.ctx
	t := ctx.theme
	a := ui.area(ctx, "object menu head", {OBJECT_MENU_W - 12, t.target})
	y := a.rect.y + a.rect.h * 0.5
	ui.icon(ctx, OBJECT_TYPE_ICONS[kind], {a.rect.x + 18, y}, t.icon_small, t.text_secondary)
	name := object_label(obj)
	ui.text(ctx, ui.text_fit(ctx, name, t.text_size, a.rect.w - 140), a.rect.x + 36, y - 8, t.text_size, t.text, .Semibold)
	ui.text(ctx, fmt.tprintf("%s · %s tris", OBJECT_TYPE_NAMES[kind], count_label(object_triangle_count(obj))), a.rect.x + 36, y + 9, t.small_size, t.text_tertiary)
}

// The quick row: Focus, Solo, Hide, Lock and (a mesh's) Layers, as icons.
@(private = "file")
object_menu_quick :: proc(app: ^App, kind: Object_Type) -> (picked: bool) {
	ctx := &app.kit.ctx
	ui.begin(ctx, "object menu quick", {direction = .Row, gap = 4})
	defer ui.end(ctx)
	for id in ([?]Command_Id{.Focus_Selected, .Solo_Object, .Hide_Object, .Lock_Object}) {
		if command_button(app, id, glyph = COMMANDS[id].icon, icon_only = true) do picked = true
	}
	if kind == .Sculpt_Mesh && command_button(app, .Show_Section, int(Kit_Section.Layers), label = "Layers", glyph = STACK_CARD_ICONS[.Layers], icon_only = true) do picked = true
	return
}

// The scene menu, while open: what empty space offers, as Blender's Add menu and Nomad's
// scene popover do: add an object, paste one, show every object, frame them all.
kit_scene_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	if !ui.popover_begin(ctx, "scene menu", &k.scene_menu, k.scene_menu_at, k.scene_menu_side, {direction = .Column, padding = 6, width = SCENE_MENU_W}) do return
	defer ui.popover_end(ctx)
	n := len(app.scene.objects)
	ui.caption(ctx, fmt.tprintf("SCENE · %d OBJECT%s", n, "" if n == 1 else "S"))
	picked := false
	for id in ([?]Command_Id{.Add_Object, .Paste_Object, .Show_All_Objects, .Frame_All}) {
		if command_menu_item(app, id) do picked = true
	}
	if picked do k.scene_menu = false
}

SCENE_MENU_W :: 220

// How long one finger held still on the view takes to open the menu there: longer than a
// control's long press, since a finger resting on the view is more often about to turn it.
HOLD_MENU :: 0.5

// One finger held still on the view for HOLD_MENU opens the menu for what it is on, only
// where a press lays no stroke: the drag turns the view (empty space, or the model when a
// finger turns it), or the Move or Model tool holds it. Never on a stroke waiting to begin,
// a handle, the shape, the safe zone, a mask, a light, Pick focus, a topological mask, the
// pivot latch, the Knife or Spine, a replay, the dial's modifiers held, a gesture, a palm or
// a pen near. The press is then muted, as a cancelled touch is: what it began is put back.
// Returns whether it opened this frame.
hold_menu_check :: proc(app: ^App, input: ^Viewport_Input) -> bool {
	g := &app.drag
	if !hold_menu_waits(app) do return false
	if input_clock(app) - g.at < HOLD_MENU do return false
	if g.owner == .Tool && app.tool == .Move do move_cancel(app)
	if g.owner == .Tool && app.tool == .Model do app.model.drag.state = .None
	view_menu_open(app, g.from, input.size, .Finger)
	g.owner = .Muted
	route_mute(input)
	return true
}

// Whether the press under way is one hold_menu_check may still open the menu for.
hold_menu_waits :: proc(app: ^App) -> bool {
	g := &app.drag
	t := &app.touch
	d := &app.device
	if d.pointer != .Finger || g.travel > app.kit.ctx.theme.slop * app.kit.scale || g.moving || g.pending || g.edge || g.mask_tap do return false
	if t.palm || t.gesture || t.pen_near || t.pen_down || t.fingers.count != 1 || pen_holds_hand(app, input_clock(app)) do return false
	if replay_busy(app) || app.ui.focus_armed || app.rail.press.mods != {} || kit_floating(app) do return false
	size := app.ui.viewport_size
	switch g.owner {
	case .Orbit:
	case .Tool:
		if lights_take_press(app, g.from, size) do return false
		switch app.tool {
		case .Move:
			// A press on the body holds the View handle without moving yet; one on the gizmo,
			// the lattice or a posing handle is that handle's.
			m := &app.move.drag
			if app.move.pivot_latch || app.move.topo.phase != .None || m.on_handle || m.live || m.posed do return false
			if lattice_pick(app, g.from, size) > 0 do return false
		case .Model:
			m := &app.model
			if m.action == .Topo || m.action in MODEL_STROKES || m.drag.state != .Pressed do return false
		case .Brush, .Curve, .Insert:
			return false
		}
	case .None, .Pan, .Zoom, .Muted, .Shape, .Environment:
		return false
	}
	return true
}

// The ring that fills round the finger as it nears the menu, from the theme's long_ring on,
// as a control's long press shows its own.
kit_hold_menu_ring :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	g := &app.drag
	if !hold_menu_waits(app) do return
	t := ctx.theme
	held := f32(input_clock(app) - g.at)
	if held < t.long_ring do return
	p := (g.from + app.ui.viewport_origin) / k.scale
	ui.hold_ring(ctx, p, 34, (held - t.long_ring) / (HOLD_MENU - t.long_ring))
}
