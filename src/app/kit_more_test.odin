package main

import "core:testing"

import "../geom"
import "../sculpt"
import "../ui"

// The Brush and Scene palettes' sections draw without an object; section_controls calls
// them through by_tab. Per thread, since tests run side by side.
@(private = "file", thread_local)
tab_draw: proc(app: ^App)

@(private = "file")
by_tab :: proc(app: ^App, _: ^Object) {tab_draw(app)}

// A scene for counting controls in each section's widest state: the selected object
// with one layer and UVs (so Layers and Retopology show every row), a second object (a
// source for Project and baking), the built-in alphas with the first in use (its mode
// and angle show). section_scene_free undoes it.
section_scene :: proc(app: ^App) -> ^Object {
	kit_init(app)
	for id in 1 ..= 2 {
		obj := new(Object)
		obj.id = id
		sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
		append(&app.scene.objects, obj)
	}
	obj := app.scene.objects[0]
	testing_layer := sculpt.sculptor_layer_add(object_sculptor(obj))
	assert(testing_layer == 0)
	// Only whether there are UVs decides what the section shows.
	obj.levels.faces.uv.uvs = make([][4][2]f32, 1)
	alphas_init(app)
	app.brush.alpha = 0
	return obj
}

section_scene_free :: proc(app: ^App) {
	delete(app.scene.objects[0].levels.faces.uv.uvs)
	app.scene.objects[0].levels.faces.uv.uvs = nil
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
	alphas_destroy(app)
	results_destroy(app)
	ui.destroy(&app.kit.ctx)
}

// How many controls one section lays out in a headless frame, with its More folded or,
// with `all`, everything shown. A section's own lists are its content, not its options,
// so the alpha thumbnails and each layer's row (record, show, name, strength) are not
// counted.
@(private = "file")
section_controls :: proc(app: ^App, sec: Kit_Section, draw: proc(app: ^App, obj: ^Object), obj: ^Object, all: bool) -> int {
	ctx := &app.kit.ctx
	app.kit.all_options = all
	ui.frame_begin(ctx, {window = {1600, 900}, pixel_density = 1, dt = 1.0 / 60})
	ui.begin_anchored(ctx, "sections", .End, .Start, {0, 0}, {direction = .Column, width = KIT_INSPECTOR_W})
	before := ctx.controls
	draw(app, obj)
	n := ctx.controls - before
	ui.end(ctx)
	ui.frame_end(ctx)
	free_all(context.temp_allocator)
	#partial switch sec {
	case .Alpha:  n -= len(app.alphas) + 1
	case .Layers: n -= 4 * len(sculpt.sculptor_layers(object_sculptor(obj)))
	}
	return n
}

// Every inspector section shows at most five controls until its More options open (UX
// rule "Basic ≤ 5 controls"): for every brush and stroke mode on the Brush palette, the Object palette's pages,
// the Scene palette, and the Curve and Insert tools.
@(test)
sections_show_at_most_five_controls :: proc(t: ^testing.T) {
	app: App
	obj := section_scene(&app)
	defer section_scene_free(&app)
	for kind in sculpt.Brush_Kind do for mode in Stroke_Mode {
		app.brush.kind, app.brush.stroke = kind, mode
		for sec in BRUSH_SECTIONS {
			if sec.shown != nil && !sec.shown(&app) do continue
			tab_draw = sec.draw
			n := section_controls(&app, sec.section, by_tab, obj, false)
			testing.expectf(t, n <= 5, "%v brush, %v stroke, %s: %d controls", kind, mode, sec.title, n)
		}
	}
	app.brush.stroke = .Dots
	// The Preset section is widest on a preset.
	app.brush.kind = .Clay
	_ = preset_save_new(&app)
	for sec in BRUSH_SECTIONS {
		if sec.section != .Preset do continue
		tab_draw = sec.draw
		n := section_controls(&app, sec.section, by_tab, obj, false)
		testing.expectf(t, n <= 5, "On a preset, %s: %d controls", sec.title, n)
	}
	preset_delete(&app, 0)
	for sec in OBJECT_SECTIONS {
		n := section_controls(&app, sec.section, sec.draw, obj, false)
		testing.expectf(t, n <= 5, "Object palette, %s: %d controls", sec.title, n)
	}
	for sec in SCENE_SECTIONS {
		tab_draw = sec.draw
		n := section_controls(&app, sec.section, by_tab, obj, false)
		testing.expectf(t, n <= 5, "Scene palette, %s: %d controls", sec.title, n)
	}
	for draw in ([?]proc(app: ^App){kit_curve_settings, kit_insert_settings}) {
		tab_draw = draw
		n := section_controls(&app, .Options, by_tab, obj, false)
		testing.expectf(t, n <= 5, "Curve or Insert tab: %d controls", n)
	}
}

// Show every option shows what the folds keep: each folded section has as many controls
// with it as before it gained the fold, and fewer without it.
@(test)
show_every_option_unfolds_the_sections :: proc(t: ^testing.T) {
	app: App
	obj := section_scene(&app)
	defer section_scene_free(&app)
	Full :: struct {
		section:  Kit_Section,
		controls: int,
	}
	// UVs and baking has 5: its Quads count and Retopologize moved to Shape > Rebuild.
	full := [?]Full{{.Preset, 6}, {.Recorder, 7}, {.Transform, 8}, {.Mask, 11}, {.Groups, 6}, {.Retopo, 5}, {.Project, 6}, {.Material, 10}, {.Camera, 6}}
	app.brush.kind = .Clay
	_ = preset_save_new(&app)
	for f in full {
		draw: proc(app: ^App, obj: ^Object)
		for sec in OBJECT_SECTIONS do if sec.section == f.section do draw = sec.draw
		for sec in BRUSH_SECTIONS do if sec.section == f.section do tab_draw, draw = sec.draw, by_tab
		for sec in SCENE_SECTIONS do if sec.section == f.section do tab_draw, draw = sec.draw, by_tab
		testing.expectf(t, draw != nil, "%v: no such section", f.section)
		if draw == nil do continue
		all := section_controls(&app, f.section, draw, obj, true)
		folded := section_controls(&app, f.section, draw, obj, false)
		testing.expectf(t, all == f.controls, "%v: %d controls with every option, want %d", f.section, all, f.controls)
		testing.expectf(t, folded < all, "%v: More hides nothing (%d)", f.section, folded)
	}
}
