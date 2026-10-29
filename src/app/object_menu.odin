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
}

@(rodata)
OBJECT_TYPE_NAMES := [Object_Type]string {
	.Sculpt_Mesh = "Sculpt mesh",
	.Voxel_Clay  = "Voxel clay",
	.Cage        = "Cage",
}

@(rodata)
OBJECT_TYPE_ICONS := [Object_Type]rune {
	.Sculpt_Mesh = ICON_SCULPT_MESH,
	.Voxel_Clay  = ICON_VOXEL_CLAY,
	.Cage        = ICON_CAGE,
}

// What `obj` is, as its chip says: clay, then a cage, else a mesh to sculpt.
object_type :: proc(obj: ^Object) -> Object_Type {
	if obj.voxel != nil do return .Voxel_Clay
	if obj.cage != nil do return .Cage
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
}

// The conversion every type offers among the rows always there.
@(rodata)
OBJECT_CONVERSIONS := [Object_Type]Object_Verb {
	.Sculpt_Mesh = {id = .Convert_To_Voxels},
	.Voxel_Clay  = {id = .Convert_To_Mesh},
	.Cage        = {id = .Apply_Cage, label = "Make sculptable"},
}

// Opens the object menu on object `id`, `side` of `at`. The menu acts on the selection, so
// the object becomes the selection's first: at once when a press could pick it, as the
// Scene palette's row does; a hidden, ghosted or locked one is brought back and selected by
// a scene change, which applies at the next frame's start.
object_menu_open :: proc(app: ^App, id: int, at: ui.Rect, side: ui.Side) {
	k := &app.kit
	k.object_menu, k.object_menu_id, k.object_menu_at, k.object_menu_side = true, id, at, side
	k.object_menu_wait = false
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
	// Where it can go in the tree: a new folder, each other folder, or out of its own.
	if command_menu_item(app, .New_Folder) do picked = true
	for &f in app.scene.folders {
		if f.id == obj.folder do continue
		if ui.menu_item(ctx, fmt.tprintf("Move to %s##into %d", folder_label(&f), f.id), glyph = ui.ICON_FOLDER) {
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
