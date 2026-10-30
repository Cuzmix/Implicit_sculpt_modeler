package main

import "core:fmt"
import "core:reflect"
import "core:strings"

import "../ui"

// The motion settings (the overhaul's round 3, PR 10; Settings > Interface > Motion): how
// much the interface moves, Full, Reduced or Off (ui.Motion_Level, in the kit's context),
// and one switch per kind of motion, so any one of them can be turned off. The first kinds
// are the kit's own (ui.MOTION_PRESS and on, in the same order); the app's own come after.
// Nothing a stroke, the camera under a finger or a drag follows ever animates, so none of
// those is here.
Motion_Kind :: enum u8 {
	Press, // presses, hovers and switch knobs
	Popovers, // popovers, menus and lists opening, and the offer line rising
	Panels, // sections opening and windows sliding
	Tabs, // the indicator under a tab or a choice sliding
	Toasts, // notes rising and stacking
	Tooltips, // tooltips fading in
	Pages, // the shelf's page sliding in after a swipe
	Camera, // the camera gliding to a view a command asks for (camera_ease.odin)
	Pie, // the pies' slices and the dial unfolding from their middle
	Hand_Switch, // the bars and panels sliding across when the hand changes
	Home, // the Home screen fading in, and the scene growing out of it
	Panes, // view panes fading in when the view grid changes
	Arrange, // Arrange's outlines drawing in
	Undo_Flash, // what an undo or redo changed glowing once (feedback_motion.odin)
	Mask_Wipe, // a mask command sweeping a soft band across the object
	Selection, // a newly selected object's outline drawing in
	Save_Tick, // the tick beside the file's status after a save
}

#assert(int(Motion_Kind.Tooltips) == int(ui.MOTION_TOOLTIPS) && len(Motion_Kind) <= 32)

MOTION_KIND_NAMES := [Motion_Kind]string {
	.Press       = "Presses and hovers",
	.Popovers    = "Menus and popovers",
	.Panels      = "Panels and sections",
	.Tabs        = "Tabs and choices",
	.Toasts      = "Notes",
	.Tooltips    = "Tooltips",
	.Pages       = "Shelf pages",
	.Camera      = "Camera moves",
	.Pie         = "Pies and the dial",
	.Hand_Switch = "Changing hands",
	.Home        = "Home screen",
	.Panes       = "View panes",
	.Arrange     = "Arrange outlines",
	.Undo_Flash  = "Undo and redo glow",
	.Mask_Wipe   = "Mask commands",
	.Selection   = "Selection outline",
	.Save_Tick   = "Save tick",
}

MOTION_LEVEL_NAMES := [ui.Motion_Level]string {
	.Full    = "Full",
	.Reduced = "Reduced",
	.Off     = "Off",
}

// The kit's class for kind `k`.
motion_class :: proc(k: Motion_Kind) -> ui.Motion_Class {
	return ui.Motion_Class(k)
}

// Settings > Interface > Motion: the level, then (unless Off) a switch per kind.
settings_motion :: proc(app: ^App) {
	ctx := &app.kit.ctx
	names: [len(ui.Motion_Level)]string
	for l in ui.Motion_Level do names[int(l)] = MOTION_LEVEL_NAMES[l]
	if picked := ui.tabs(ctx, "Motion", names[:], int(ctx.motion)); picked >= 0 do ctx.motion = ui.Motion_Level(picked)
	switch ctx.motion {
	case .Full:    ui.paragraph(ctx, "Panels, menus and tabs move as they open and change.")
	case .Reduced: ui.paragraph(ctx, "Things fade in place rather than slide or grow, as the systems' reduced motion asks.")
	case .Off:     ui.paragraph(ctx, "Panels and menus appear and change without animating.")
	}
	if ctx.motion == .Off do return
	for k in Motion_Kind {
		on := int(k) not_in ctx.motion_off
		if ui.switch_row(ctx, MOTION_KIND_NAMES[k], &on) {
			if on do ctx.motion_off -= {int(k)}
			else do ctx.motion_off += {int(k)}
		}
	}
}

// The kinds turned off, by name, for the settings file's `motion_off` line and the stats;
// "" for none.
motion_off_text :: proc(ctx: ^ui.Context) -> string {
	b := strings.builder_make(context.temp_allocator)
	for k in Motion_Kind {
		if int(k) not_in ctx.motion_off do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
		fmt.sbprint(&b, k)
	}
	return strings.to_string(b)
}

// Reads a `motion_off` line's names; an unknown one is passed over.
motion_off_read :: proc(ctx: ^ui.Context, names: []string) {
	ctx.motion_off = {}
	for name in names {
		if k, ok := reflect.enum_from_name(Motion_Kind, name); ok do ctx.motion_off += {int(k)}
	}
}
