package main

import "core:fmt"
import "core:strings"

import "../ui"

// What a panel holds (round 3, PR 4; one enum since PR 9): a card of the stack
// (lens_stack.odin) or a tray section's palette. The groups hold these, so one set of procs
// gives any of them its title, icon, folded line and content, and a group draws whatever it
// holds without knowing which kind it is. A visiting section and a kept one draw through
// panel_body alike, so the two never drift apart.

// The palette that draws tray section `sec` as the tray did: Layers, Material, Lights
// and Environment their cards, Objects and Add object the Scene card, so each has one
// interface wherever it opens; false for the Stats panel's sections, which no palette
// shows.
panel_of_section :: proc(sec: Kit_Section) -> (Panel_Kind, bool) {
	if int(sec) >= TRAY_SECTIONS do return .Brush, false
	#partial switch sec {
	case .Layers:      return .Layers, true
	case .Material:    return .Material, true
	case .Lights:      return .Lights, true
	case .Objects, .Add: return .Scene, true
	case .Environment: return .Environment, true
	}
	return PANEL_OF_SECTION[sec], true
}

// Whether section `sec` is a card's twin (Layers, Material, Lights, Environment, and
// Objects and Add object the Scene card's): it has no card of its own, and is offered and
// named only as that card (Show panel).
section_is_card :: proc(sec: Kit_Section) -> bool {
	p, ok := panel_of_section(sec)
	return ok && !panel_is_section(p)
}

// The section card `p` draws; false for the cards of their own.
panel_section :: proc(p: Panel_Kind) -> (Kit_Section, bool) {
	if p not_in STACK_SECTION_PANELS do return .Preset, false
	return SECTION_OF_PANEL[p], true
}

// Whether `p` is a section's card rather than a card of its own.
panel_is_section :: proc(p: Panel_Kind) -> bool {
	return p in STACK_SECTION_PANELS
}
// The cards that are a tray section too, drawn wherever that section opens.
CARDS_AS_SECTIONS :: bit_set[Panel_Kind]{.Layers, .Scene, .Material, .Lights, .Environment}

// The two directions of panel_of_section, as tables: the sections keep their order in
// both enums, so these only spell it out.
@(rodata)
PANEL_OF_SECTION := #partial [Kit_Section]Panel_Kind {
	.Preset = .Preset, .Stroke = .Stroke, .Paint_Color = .Paint_Color, .Recall = .Recall, .Falloff = .Falloff,
	.Samples = .Samples, .Alpha = .Alpha, .Pen = .Pen, .Options = .Options, .Recorder = .Recorder,
	.Transform = .Transform, .Levels = .Levels, .Hd = .Hd, .Topology = .Topology, .Mask = .Mask, .Sets = .Sets,
	.Visibility = .Visibility, .Paint = .Paint, .Groups = .Groups, .Morph = .Morph,
	.Deform = .Deform, .Deformers = .Deformers, .Remesh = .Remesh, .Mirror = .Mirror, .Voxels = .Voxels,
	.Retopo = .Retopo, .Textures = .Textures, .Project = .Project, .Booleans = .Booleans, .Extract = .Extract,
	.Look = .Look, .Render = .Render, .Lens = .Lens, .Finish = .Finish, .Camera = .Camera,
	.Turntable = .Turntable, .Print = .Print, .Floor = .Floor, .Background = .Background,
}

@(rodata)
SECTION_OF_PANEL := #partial [Panel_Kind]Kit_Section {
	.Preset = .Preset, .Stroke = .Stroke, .Paint_Color = .Paint_Color, .Recall = .Recall, .Falloff = .Falloff,
	.Samples = .Samples, .Alpha = .Alpha, .Pen = .Pen, .Options = .Options, .Recorder = .Recorder,
	.Transform = .Transform, .Levels = .Levels, .Hd = .Hd, .Topology = .Topology, .Mask = .Mask, .Sets = .Sets,
	.Visibility = .Visibility, .Paint = .Paint, .Groups = .Groups, .Morph = .Morph,
	.Deform = .Deform, .Deformers = .Deformers, .Remesh = .Remesh, .Mirror = .Mirror, .Voxels = .Voxels,
	.Retopo = .Retopo, .Textures = .Textures, .Project = .Project, .Booleans = .Booleans, .Extract = .Extract,
	.Look = .Look, .Render = .Render, .Lens = .Lens, .Finish = .Finish, .Camera = .Camera, .Turntable = .Turntable,
	.Print = .Print, .Floor = .Floor, .Background = .Background,
}

// Its title, as its header shows it.
panel_kind_title :: proc(app: ^App, kind: Panel_Kind) -> string {
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
		// Only a section with a card of its own: a card's twin is named as the card.
		for sec in Kit_Section do if which == fmt.tprint(sec) {
			p, ok := panel_of_section(sec)
			if ok && panel_is_section(p) do return p, true
		}
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
