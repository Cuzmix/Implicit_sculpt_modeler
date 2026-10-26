package main

import "core:fmt"

import "../camera"
import "../geom"
import "../render"
import "../sculpt"
import "../ui"

// Interface state that is not the kit's own. Sculpt and render state live in App; the
// panels edit them through pointers handed over each frame and never keep references
// between frames.
Ui_State :: struct {
	viewport_request: [2]f32, // pixel size the viewport wants its render target to be
	// Set by a panel; the app applies it at the start of the next frame.
	scene_command:    Scene_Command,
	// The pointer over the viewport this frame, for shortcuts that act where it points.
	viewport_mouse:     [2]f32,
	viewport_size:      [2]f32,
	viewport_hovered:   bool,
	pie:                Pie,
	adjust:             Brush_Adjust,
	curve_handle:       int, // the pressure curve's control point being dragged (1 or 2), or 0
	falloff_handle:     int, // ...and the falloff curve's
	mask_steps:         i32, // steps each Blur, Sharpen, Grow or Shrink press takes
	mask_shape_kind:    Mask_Shape_Kind, // what Ctrl + drag on empty space draws
	mirror_axis:        i32, // Mirror and weld: 0 x, 1 y, 2 z
	mirror_negative:    bool, // Mirror and weld keeps the - side instead of the + side
	smooth_steps:       i32, // steps each Smooth all press takes
	smooth_strength:    f32, // how far each step moves a vertex toward its neighbours' average, 0 to 1
	smooth_on_gpu:      bool, // run Smooth all as a compute shader (the GPU compute trial); off by default
	crease_degrees:     f32, // Polygroups' Creases: how sharp a crease starts a new group
	layer_selected:     int,  // the Layers section's row that Delete and Bake act on
	layer_dragging:     bool, // a layer's strength slider is being dragged: one undo step
	transform_drag:     Transform_Drag, // the Transform section's values are being dragged: one undo step
	retopo_quads:       i32,  // quads Retopologize asks for
	rebuild_goal:       Rebuild_Goal, // what the Rebuild section makes: an even mesh, fewer polygons or quads
	rebuild_even:       i32,  // vertices Rebuild's Even goal asks for
	rebuild_fewer:      i32,  // ...and its Fewer goal
	bake:               Bake_Settings,
	boolean:            Boolean_State,
	project:            Project_Settings,
}

MASK_COMMAND_NAMES := [sculpt.Mask_Command]string {
	.Clear   = "Clear",
	.Invert  = "Invert",
	.Fill    = "Mask all",
	.Cavity  = "Mask cavities",
	.Blur    = "Blur",
	.Sharpen = "Sharpen",
	.Grow    = "Grow",
	.Shrink  = "Shrink",
}

SPHERE_PRESETS := [?]struct {
	label:    cstring,
	vertices: i32,
} {
	{"41k", 40_962},
	{"500k", 500_000},
	{"1M", 1_000_000},
	{"5M", 5_000_000},
	{"10M", 10_000_000},
	{"25M", 25_000_000},
}

// Measured at 25M vertices: mesh, sculpt nodes and topology together.
BYTES_PER_VERTEX :: 108

// What the viewport saw this frame, in window coordinates. This is the only thing the
// camera and the tools read; none of them touches the interface directly.
Viewport_Input :: struct {
	size:        [2]f32,
	mouse_pos:   [2]f32,
	mouse_delta: [2]f32,
	wheel:       f32,
	hovered:     bool,
	dragging:    bool, // a drag that started in the viewport, even if the cursor has left it
	orbit_drag:  bool, // the drag turns the view (navigate.odin says which drags do)...
	orbit_pivot: Vec3, // ...about this point, which stays put on screen
	pan_drag:    bool, // ...or pans it
	primary:     bool, // left mouse without Alt: drives the active tool
	press:       bool, // the left button went down in the viewport this frame
	smooth:      bool, // Shift held during a stroke: smooth brush
	invert:      bool, // Ctrl held during a stroke: invert the brush
	alt:         bool, // Alt held with Ctrl: a mask shape unmasks
	mask:        bool, // the rail's Mask: the stroke paints the mask
	mask_shape:  bool, // a press from empty space draws a mask shape (Ctrl, or the rail's Mask)
	samples:     []Input_Sample, // every pointer sample this frame, oldest first
	pen_tilt:    [2]f32, // the pen's lean now, in degrees; zero without a pen
	zoom_drag:   bool, // Ctrl + right mouse: up zooms in
	touch_pan:   [2]f32, // two fingers' middle moved this far (touch.odin)
	touch_zoom:  f32, // ...and their spread grew this many times; 0 for no fingers
	touch_zoom_at: [2]f32, // ...toward this point, from the viewport's middle (x right, y down)
	touch_roll:  f32, // ...and they twisted this many radians clockwise
	touch_orbit: [2]f32, // the finger left of two moved this far, turning the view...
	touch_pivot: Vec3, // ...about this point (touch_lift_orbit)
}

CLOTH_MODE_NAMES := [sculpt.Cloth_Mode]cstring {
	.Drag    = "Drag",
	.Gravity = "Gravity",
	.Pinch   = "Pinch",
	.Expand  = "Expand",
}

CLOTH_MODE_HELP := [sculpt.Cloth_Mode]cstring {
	.Drag    = "What is under the brush follows the pointer;\nthe cloth around it folds as it is pulled.",
	.Gravity = "The cloth sags toward the bottom of the screen\nwhile the button is held (Ctrl: rises).",
	.Pinch   = "Gathers the cloth toward the brush into folds\n(Ctrl: Expand).",
	.Expand  = "Pushes the cloth out from the brush so it\nbuckles into ridges (Ctrl: Pinch).",
}

ui_state_default :: proc() -> Ui_State {
	return {viewport_request = {1280, 720}, mask_steps = 3, smooth_steps = 5, smooth_strength = 0.5, crease_degrees = sculpt.CREASE_GROUP_DEGREES, retopo_quads = 4000, rebuild_even = 500_000, rebuild_fewer = 100_000, bake = {size = 2048, reach_edges = 2}, boolean = {live_vertices = 200_000, vertices = 1_000_000, thickness = 0.02}, project = PROJECT_DEFAULTS}
}

// Turns the studio render on or off; on, it starts from the plain viewport.
studio_toggle :: proc(app: ^App) {
	app.studio_on = !app.studio_on
	render.studio_reset(&app.studio)
}

// Saves where the scene was last saved or opened, or asks where to the first time.
save_scene :: proc(app: ^App) {
	if app.scene_path != "" {
		file_post(.Save, app.scene_path)
	} else {
		file_dialog(app, .Save)
	}
}

// Back to the starting view, keeping the projection.
reset_camera :: proc(app: ^App) {
	ortho := app.camera.ortho
	app.camera = camera.orbit_default()
	app.camera.ortho = ortho
	app.pivot.set, app.pivot.pinned = false, false
}

PRESSURE_PRESETS := [?]struct {
	label: cstring,
	curve: geom.Curve,
} {
	{"Linear", geom.CURVE_LINEAR},
	{"Soft", {{0.1, 0.6}, {0.4, 0.95}}}, // a light touch goes far
	{"Firm", {{0.6, 0.05}, {0.95, 0.4}}}, // it takes a press
	{"S", {{0.55, 0}, {0.45, 1}}}, // light stays light, a press goes full
}

FALLOFF_SMOOTH_CURVE :: geom.Curve{{0.3, 0}, {0.6, 1}} // near the built-in one

FALLOFF_PRESETS := [?]struct {
	label: cstring,
	drawn: bool,
	curve: geom.Curve,
} {
	{"Smooth", false, FALLOFF_SMOOTH_CURVE}, // the built-in one
	{"Linear", true, geom.CURVE_LINEAR}, // a cone
	{"Sharp", true, {{0.7, 0}, {0.95, 0.3}}}, // a point in the middle, for creases and pores
	{"Firm", true, {{0.05, 0.7}, {0.3, 1}}}, // most of the radius at full strength
	{"Flat", true, {{0, 1}, {0.02, 1}}}, // full strength to the rim, a hard edge
}

// Whether a text field has the keys, or the command palette or the Assign key popover is
// open, when no shortcut, S or U, or Space fires. The palette counts from the frame it opens, though its field
// takes the keys only once its popover starts to show a frame or two later, so a letter
// typed in between never runs its shortcut.
typing :: proc(app: ^App) -> bool {
	return ui.typing(&app.kit.ctx) || app.kit.palette || app.kit.bind.open
}

count_label :: proc(n: int) -> string {
	switch {
	case n >= 1_000_000:
		return fmt.tprintf("%.1fM", f64(n) / 1e6)
	case n >= 1_000:
		return fmt.tprintf("%dk", n / 1000)
	}
	return fmt.tprintf("%d", n)
}

bytes_label :: proc(n: int) -> string {
	if n >= 1 << 30 do return fmt.tprintf("%.1f GB", f64(n) / f64(1 << 30))
	return fmt.tprintf("%d MB", max(n >> 20, 1))
}
