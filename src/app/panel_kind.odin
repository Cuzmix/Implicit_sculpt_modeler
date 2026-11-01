package main

import "core:fmt"
import "core:strings"

import "../ui"

// What a panel holds (round 3, PR 4; one enum since PR 9): a card of the stack
// (lens_stack.odin) or a tray section's palette. The groups hold these, so one set of procs
// gives any of them its title, icon, folded line and content, and a group draws whatever it
// holds without knowing which kind it is. A visiting section and a kept one draw through
// panel_body alike, so the two never drift apart.

// The palette that draws tray section `sec` as the tray did: Layers, Material and Lights
// their full sections beside their cards, Environment its card; false for the Stats
// panel's sections, which no palette shows.
panel_of_section :: proc(sec: Kit_Section) -> (Panel_Kind, bool) {
	if int(sec) >= TRAY_SECTIONS do return .Brush, false
	#partial switch sec {
	case .Layers:      return .Layer_Settings, true
	case .Material:    return .Material_Settings, true
	case .Lights:      return .Light_Settings, true
	case .Environment: return .Environment, true
	}
	return PANEL_OF_SECTION[sec], true
}

// The section palette `p` draws; false for the cards (Environment's too, which is a card
// first).
panel_section :: proc(p: Panel_Kind) -> (Kit_Section, bool) {
	if p not_in STACK_SECTION_PANELS do return .Preset, false
	return SECTION_OF_PANEL[p], true
}

// Whether `p` is a tray section's palette rather than a card.
panel_is_section :: proc(p: Panel_Kind) -> bool {
	return p in STACK_SECTION_PANELS
}

// The two directions of panel_of_section, as tables: the sections keep their order in
// both enums, so these only spell it out.
@(rodata)
PANEL_OF_SECTION := #partial [Kit_Section]Panel_Kind {
	.Preset = .Preset, .Stroke = .Stroke, .Paint_Color = .Paint_Color, .Recall = .Recall, .Falloff = .Falloff,
	.Samples = .Samples, .Alpha = .Alpha, .Pen = .Pen, .Options = .Options, .Recorder = .Recorder,
	.Transform = .Transform, .Levels = .Levels, .Hd = .Hd, .Topology = .Topology, .Mask = .Mask, .Sets = .Sets,
	.Visibility = .Visibility, .Paint = .Paint, .Groups = .Groups, .Morph = .Morph, .Layers = .Layer_Settings,
	.Deform = .Deform, .Deformers = .Deformers, .Remesh = .Remesh, .Mirror = .Mirror, .Voxels = .Voxels,
	.Retopo = .Retopo, .Textures = .Textures, .Project = .Project, .Booleans = .Booleans, .Extract = .Extract,
	.Objects = .Objects, .Add = .Add, .Look = .Look, .Material = .Material_Settings, .Lights = .Light_Settings,
	.Environment = .Environment, .Render = .Render, .Lens = .Lens, .Finish = .Finish, .Camera = .Camera,
	.Turntable = .Turntable, .Print = .Print, .Floor = .Floor, .Background = .Background,
}

@(rodata)
SECTION_OF_PANEL := #partial [Panel_Kind]Kit_Section {
	.Preset = .Preset, .Stroke = .Stroke, .Paint_Color = .Paint_Color, .Recall = .Recall, .Falloff = .Falloff,
	.Samples = .Samples, .Alpha = .Alpha, .Pen = .Pen, .Options = .Options, .Recorder = .Recorder,
	.Transform = .Transform, .Levels = .Levels, .Hd = .Hd, .Topology = .Topology, .Mask = .Mask, .Sets = .Sets,
	.Visibility = .Visibility, .Paint = .Paint, .Groups = .Groups, .Morph = .Morph, .Layer_Settings = .Layers,
	.Deform = .Deform, .Deformers = .Deformers, .Remesh = .Remesh, .Mirror = .Mirror, .Voxels = .Voxels,
	.Retopo = .Retopo, .Textures = .Textures, .Project = .Project, .Booleans = .Booleans, .Extract = .Extract,
	.Objects = .Objects, .Add = .Add, .Look = .Look, .Material_Settings = .Material, .Light_Settings = .Lights,
	.Render = .Render, .Lens = .Lens, .Finish = .Finish, .Camera = .Camera, .Turntable = .Turntable,
	.Print = .Print, .Floor = .Floor, .Background = .Background,
}

// Its title, as its header shows it: the full sections beside a card say so.
panel_kind_title :: proc(app: ^App, kind: Panel_Kind) -> string {
	#partial switch kind {
	case .Layer_Settings:    return "Layer settings"
	case .Material_Settings: return "Material settings"
	case .Light_Settings:    return "Light settings"
	}
	if sec, ok := panel_section(kind); ok do return tray_section_title(sec)
	return stack_title(app, kind)
}

// Its icon: the card's, or the one Show section has on a bar.
panel_kind_icon :: proc(app: ^App, kind: Panel_Kind) -> rune {
	if sec, ok := panel_section(kind); ok do return bar_icon(app, {.Show_Section, int(sec)})
	if kind == .Brush do return stack_brush_icon(app)
	return STACK_CARD_ICONS[kind]
}

// What it holds, in a few words, for its folded header.
panel_kind_summary :: proc(app: ^App, kind: Panel_Kind) -> string {
	if sec, ok := panel_section(kind); ok do return section_summary(app, sec)
	return stack_summary(app, kind)
}

// Its content, `inner` points wide: a card's body, or a section's controls (asking for an
// object first when the section is an object's and none is selected). Every panel is part
// of the tray, so search's Show where can mark a control on any of them (the Layers card's
// New layer, say).
panel_body :: proc(app: ^App, kind: Panel_Kind, inner: f32) {
	k := &app.kit
	k.in_tray = true
	defer k.in_tray = false
	hints := hints_push(app)
	defer k.ctx.hints = hints
	sec, section := panel_section(kind)
	if !section {
		stack_card_body(app, kind, inner)
		return
	}
	for s in OBJECT_SECTIONS do if s.section == sec do k.object_page = s.page
	// The Objects tree is the Scene palette's first section, in no section table.
	if sec == .Objects {
		kit_scene_objects(app)
		return
	}
	ctx := &app.kit.ctx
	_, draw, obj_draw, found := bar_section(app, sec)
	obj := selected_object(app)
	switch {
	case !found:
		ui.paragraph(ctx, "Nothing to show here.")
	case obj_draw != nil && obj == nil:
		ui.paragraph(ctx, "Add or select an object first.")
	case obj_draw != nil:
		obj_draw(app, obj)
	case:
		draw(app)
	}
}

// Its name in a group's line: `card:Brush` or `section:Stroke` (the full sections by their
// section's name, `section:Layers`).
panel_kind_name :: proc(kind: Panel_Kind) -> string {
	if sec, ok := panel_section(kind); ok do return fmt.tprintf("section:%v", sec)
	return fmt.tprintf("card:%v", kind)
}

// The kind a group's line names; false for a name this version does not know, or a
// section no palette shows.
panel_kind_from_name :: proc(name: string) -> (Panel_Kind, bool) {
	what, _, which := strings.partition(name, ":")
	switch what {
	case "card":
		for c in STACK_CARDS do if which == fmt.tprint(c) do return c, true
	case "section":
		for sec in Kit_Section do if which == fmt.tprint(sec) do return panel_of_section(sec)
	}
	return .Brush, false
}

// Its word in the stack's and the sizes' lines: a card bare, as every build has written it
// (`Brush`), a section's palette as in a group's line (`section:Mask`), so a build that
// knows no sections passes over it.
panel_word :: proc(kind: Panel_Kind) -> string {
	if panel_is_section(kind) do return panel_kind_name(kind)
	return fmt.tprint(kind)
}

// The kind a stack or sizes line's word names, any case; false for one this version does
// not know.
panel_from_word :: proc(word: string) -> (Panel_Kind, bool) {
	if strings.has_prefix(word, "section:") do return panel_kind_from_name(word)
	for c in STACK_CARDS do if strings.equal_fold(word, fmt.tprint(c)) do return c, true
	return .Brush, false
}
