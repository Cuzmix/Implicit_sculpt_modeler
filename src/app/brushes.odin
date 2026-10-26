package main

import "core:fmt"
import "core:strings"

import "../sculpt"

// Everything the app knows about each brush, one row each: what the interface shows
// and what the stroke does differently. Adding a brush is its value in
// sculpt.Brush_Kind with its dab in sculpt, and a row here.
Brush_Info :: struct {
	name:     string, // "Snake hook": tiles, the pie, menus, the history, --brush
	help:     cstring, // what it does, with a line break where its tooltip wraps
	icon:     rune, // in the Lucide font
	strength: f32, // a fresh install's
	flags:    Brush_Flags,
}

Brush_Flag :: enum u8 {
	Grab, // moves what was under the press with the pointer, as one piece: no alpha
	Hook, // pulls the surface out after the pointer (sculpt.Brush.drag)
	Cloth, // simulates the surface around it as cloth while held
	Paint, // colours instead of shaping: the Colour section; not in HD or with dynamic topology
	Mask, // paints the mask: its strokes are mask steps in the history
}
Brush_Flags :: bit_set[Brush_Flag;u8]

@(rodata)
BRUSHES := [sculpt.Brush_Kind]Brush_Info {
	.Draw       = {"Draw", "Pushes the surface out (Ctrl: in).", 0xe1d3 /* brush */, 0.5, {}},
	.Smooth     = {"Smooth", "Evens out bumps. Shift smooths with any brush.", 0xe283 /* waves */, 0.5, {}},
	.Clay       = {"Clay", "Builds up toward a flat top, filling dips first (Ctrl: digs).", 0xe104 /* layers */, 0.5, {}},
	.Flatten    = {"Flatten", "Levels the surface to its average plane (Ctrl: away from it).", 0xe120 /* minus */, 0.5, {}},
	.Inflate    = {"Inflate", "Swells along the surface's own normals (Ctrl: shrinks).", 0xe349 /* circle-dot */, 0.5, {}},
	.Pinch      = {"Pinch", "Pulls the surface together under the brush (Ctrl: apart).", 0xe220 /* shrink */, 0.5, {}},
	.Crease     = {"Crease", "Cuts a sharp groove (Ctrl: a sharp ridge).", 0xe522 /* slash */, 0.5, {}},
	.Grab       = {"Grab", "Drags what is under the brush with the pointer.", 0xe1d7 /* hand */, 0.5, {.Grab}},
	.Mask       = {"Mask", "Paints the mask (Ctrl: erases it).", 0xe0a1 /* contrast */, 0.5, {.Mask}},
	.Layer      = {"Layer", "Raises a flat layer of one height per stroke; going\nover it again adds nothing (Ctrl: lowers).", 0xe52e /* layers-2 */, 0.5, {}},
	.Snake_Hook = {"Snake hook", "Pulls the surface out after the pointer, for horns,\ntentacles and fingers. Best with dynamic topology.", 0xe38f /* spline */, 0.5, {.Hook}},
	.Morph      = {"Morph", "Brings the surface back to the stored morph target\n(Object tab > Morph target), painting later work away.", 0xe1f5 /* history */, 0.5, {}},
	.Paint      = {"Paint", "Polypaint: colours the surface with the colour below,\nmoving nothing (Ctrl: takes the paint off).", 0xe2e7 /* paintbrush */, 0.5, {.Paint}},
	.Cloth      = {"Cloth", "The surface around the brush acts as cloth while you\nhold: drag it into folds, let it sag, or bunch it up.", 0xe1ca /* shirt */, 0.5, {.Cloth}},
	.History    = {"History", "A local undo: paints the surface back to how it was\nbefore an earlier step, only where you brush.", 0xe456 /* undo-dot */, 0.5, {}},
}

brush_by_name :: proc(name: string) -> (sculpt.Brush_Kind, bool) {
	for kind in sculpt.Brush_Kind {
		// "snake_hook" or "snakehook" on the command line find "Snake hook".
		if strings.equal_fold(name, BRUSHES[kind].name) || strings.equal_fold(name, fmt.tprint(kind)) do return kind, true
		if spaced, _ := strings.remove_all(BRUSHES[kind].name, " ", context.temp_allocator); strings.equal_fold(name, spaced) do return kind, true
	}
	return {}, false
}
