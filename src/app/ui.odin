package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

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
	// The main pane's top left in window coordinates (grid.odin), zero while the viewport
	// fills the window: Viewport_Input and the overlay are in the pane's coordinates.
	viewport_origin:  [2]f32,
	// Set by a panel; the app applies it at the start of the next frame.
	scene_command:    Scene_Command,
	// The pointer over the viewport this frame, for shortcuts that act where it points.
	viewport_mouse:     [2]f32,
	viewport_size:      [2]f32,
	viewport_hovered:   bool,
	// The viewport's drag is a stroke, with the primary button, a finger or the pen,
	// rather than a turn or a pan: the panels it passes under fade (panel_fade).
	viewport_stroke:    bool,
	pie:                Pie,
	adjust:             Brush_Adjust,
	curve_handle:       int, // the pressure curve's control point being dragged (1 or 2), or 0
	falloff_handle:     int, // ...and the falloff curve's
	mask_steps:         i32, // steps each Blur, Sharpen, Grow or Shrink press takes
	mask_hidden:        bool, // the view draws masked parts as the rest (the Tools card's Show the mask off), as ZBrush's View mask
	mask_by:            Mask_By_Settings, // the Mask section's Mask by and Mask adjust (mask_by_command)
	mask_shape_kind:    Mask_Shape_Kind, // what Ctrl + drag on empty space draws
	mirror_axis:        i32, // Mirror and weld: 0 x, 1 y, 2 z
	mirror_negative:    bool, // Mirror and weld and Delete half keep the - side instead of the + side
	holes_leave_largest: bool, // Close holes leaves the hole with the longest border open
	weld_distance:      f32, // Weld points: how far apart vertices weld, as a share of the object's largest side
	smooth_steps:       i32, // steps each Smooth all press takes
	smooth_strength:    f32, // how far each step moves a vertex toward its neighbours' average, 0 to 1
	smooth_on_gpu:      bool, // run Smooth all as a compute shader (the GPU compute trial); off by default
	crease_degrees:     f32, // Polygroups' Creases: how sharp a crease starts a new group
	// Scene > Material's Group target (group_materials.odin): the section edits polygroup
	// group_target's material, of object group_target_id (0 for none picked); Pick a group
	// waits for a press on the selected object, which is held out of the tools until it lifts.
	material_groups:    bool,
	group_pick:         bool,
	group_pick_held:    bool,
	// The Eyedropper (kit_colors.odin): armed, it waits for a press on the viewport; held,
	// the loupe at `eyedrop_at` (window pixels) shows the colour under it, if it `hit` one.
	eyedrop_armed:      bool,
	eyedrop_held:       bool,
	eyedrop_at:         [2]f32,
	eyedrop_color:      [3]f32,
	eyedrop_hit:        bool,
	// Pick focus (lens.odin): armed, it waits for a press on the viewport; held, the press
	// moves the focus, and `hit` says whether it met the model yet.
	focus_armed:        bool,
	focus_held:         bool,
	focus_hit:          bool,
	group_target:       u16,
	group_target_id:    int,
	layer_selected:     int,  // the Layers section's row that Delete and Bake act on
	set_selected:       int,  // the Selection sets section's set that Add, Subtract, Store over and Delete act on
	layer_dragging:     bool, // a layer's strength slider is being dragged: one undo step
	layer_wide:         bool, // the strength sliders go from -5 to 5 rather than -1 to 2
	layer_drag_id:      int,  // the object whose layer is being dragged, which the selection may leave meanwhile
	layer_drag_wide:    bool, // the dragged strength slider began on the wide range, which it keeps until release
	layer_mask:         Layer_Mask_Paint, // the layer mask a row's mask square picked for painting (layer_masks.odin)
	deform:             Deform_Panel, // the Deformers section's choices and its Amount drag (deformers.odin)
	reshape:            Reshape_Panel, // the Deformation section's choices and its Amount drag (reshape.odin)
	transform_drag:     Transform_Drag, // the Transform section's values are being dragged: one undo step
	light_drag:         Light_Drag, // the Lights section's values are being changed: one undo step
	light_press:        Light_Press, // a press on the lights in the viewport (light_markers.odin)
	light_place:        bool, // Place highlight: a press on the model moves the picked light's highlight there
	retopo_quads:       i32,  // quads Quad Remesh asks for
	retopo_engine:      Quad_Engine, // ...and from which engine (retopo.odin)...
	retopo_adaptivity:  f32,  // ...with smaller quads where the surface bends (AutoRemesher)
	retopo_symmetry:    Quad_Symmetry, // ...one half remeshed and mirrored (AutoRemesher)
	retopo_close_first: bool, // ...an open or unsound mesh voxel remeshed first
	rebuild_goal:       Rebuild_Goal, // what the Rebuild section makes: an even mesh, fewer polygons or quads
	rebuild_even:       i32,  // vertices Rebuild's Even goal asks for
	remesh_smooth:      i32,  // ...with this many relax rounds (remesh.odin)...
	remesh_keep_detail: bool, // ...put back on the old surface, polypaint and polygroups along...
	remesh_groups:      bool, // ...each polygroup a closed piece of its own
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
	.Region  = "Mask region",
	.Hidden  = "Mask hidden",
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
	pen_roll:    f32, // the pen's turn about its own length now, degrees clockwise from its top; zero without one
	pen_hover:   f32, // how far the pen hovers above the screen, 0 to 1 (App.pen_distance); 0 touching or without one
	zoom_drag:   bool, // Ctrl + right mouse: up zooms in
	touch_pan:   [2]f32, // two fingers' middle moved this far (touch.odin)
	touch_zoom:  f32, // ...and their spread grew this many times; 0 for no fingers
	touch_roll:  f32, // ...and they twisted this many radians clockwise...
	touch_at:    [2]f32, // ...toward and about this point, from the viewport's middle (x right, y down)
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
	return {viewport_request = {1280, 720}, mask_steps = 3, mask_by = MASK_BY_SETTINGS_DEFAULT, smooth_steps = 5, smooth_strength = 0.5, crease_degrees = sculpt.CREASE_GROUP_DEGREES, retopo_quads = 4000, rebuild_even = 500_000, remesh_smooth = geom.REMESH_SMOOTH_DEFAULT, rebuild_fewer = 100_000, bake = {size = 2048, reach_edges = 2, base_color = true, orm = true, occlusion_rays = 16, occlusion_reach = 0.2}, boolean = {live_vertices = 200_000, vertices = 1_000_000, thickness = 0.02}, project = PROJECT_DEFAULTS, deform = {along = .Y, lattice = {points = LATTICE_POINTS_DEFAULT}}, reshape = reshape_panel_default(), weld_distance = WELD_DISTANCE_DEFAULT}
}

// Turns the studio render on or off; on, it starts from the plain viewport.
studio_toggle :: proc(app: ^App) {
	app.studio_on = !app.studio_on
	render.studio_reset(&app.studio)
}

// Saves where the scene was last saved or opened, or asks where to the first time. On the
// iPad it asks too for a scene opened from Files alone, which the app may read but not save
// over (file_writable_beside).
save_scene :: proc(app: ^App) {
	if app.scene_path != "" && (!ODIN_PLATFORM_SUBTARGET_IOS || file_writable_beside(app.scene_path)) {
		file_post(.Save, app.scene_path)
	} else {
		file_dialog(app, .Save)
	}
}

// Saves the scene as the next numbered file beside the one it saves to (save_next_path),
// which it then saves to, as Save as does. Needs a file to number from.
save_scene_next :: proc(app: ^App) {
	if !save_next_allowed(app) do return
	next, ok := save_next_path(app.scene_path, proc(path: string) -> bool {return os.exists(path)})
	if !ok {
		file_note(app, true, "Cannot save next: the next thousand numbered names beside %s are all taken", filepath.base(app.scene_path))
		return
	}
	file_post(.Save, next)
}

// Whether Save next has a file to number from that it can write beside (file_writable_beside).
save_next_allowed :: proc(app: ^App) -> bool {
	return app.scene_path != "" && file_writable_beside(app.scene_path)
}

// The file Save next writes after `path`: its name's trailing `_NNN` counted up, keeping
// at least that many digits ("dragon_009" to "dragon_010"), or "_002" added to a name
// without one, the file itself standing for the first; a number whose file `taken` says
// exists is passed over, up to a thousand of them (false then: nothing is free). The
// result is in the temp allocator.
save_next_path :: proc(path: string, taken: proc(path: string) -> bool) -> (string, bool) {
	// The folder as written, separator and all, so the result sits beside `path`.
	file := filepath.base(path)
	dir := path[:len(path) - len(file)]
	ext := filepath.ext(file)
	stem := file[:len(file) - len(ext)]
	number, width := 1, 3
	if i := strings.last_index_byte(stem, '_'); i >= 0 && i + 1 < len(stem) && len(stem) - i - 1 <= 6 {
		digits := stem[i + 1:]
		if n, ok := strconv.parse_int(digits, 10); ok && strings.trim_left(digits, "0123456789") == "" {
			number, width, stem = n, max(len(digits), 3), stem[:i]
		}
	}
	numbered :: proc(dir, stem: string, number, width: int, ext: string) -> string {
		digits := fmt.tprintf("%d", number)
		zeros := strings.repeat("0", max(width - len(digits), 0), context.temp_allocator)
		return fmt.tprintf("%s%s_%s%s%s", dir, stem, zeros, digits, ext)
	}
	for _ in 0 ..< 1000 {
		number += 1
		if next := numbered(dir, stem, number, width, ext); !taken(next) do return next, true
	}
	return "", false
}

// Back to the starting view, keeping the projection.
reset_camera :: proc(app: ^App) {
	ortho, fov := app.camera.ortho, app.camera.fov_y
	app.camera = camera.orbit_default()
	app.camera.ortho = ortho
	camera.orbit_set_fov(&app.camera, fov)
	app.pivot.set, app.pivot.pinned = false, false
	view_fit_free(app, false)
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
