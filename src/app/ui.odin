package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:time"

import imgui "deps:odin-imgui"

import "../camera"
import "../geom"
import "../gizmo"
import "../render"
import "../sculpt"

// UI-only state. Sculpt and render state live in App; panels edit them through pointers
// handed over each frame and never keep references between frames.
Ui_State :: struct {
	viewport_request: [2]f32, // pixel size the viewport panel wants its render target to be
	layout_built:     bool,
	show_demo:        bool,
	sphere_vertices:  i32, // vertex count typed into the Scene panel for Add and Remesh
	add_shape:        geom.Primitive, // what the Scene panel's Add adds
	// Set by the Scene panel; the app applies it at the start of the next frame.
	scene_command:    Scene_Command,
	// Where the viewport image was drawn this frame, so the overlay (brush circle,
	// gizmo) can be added after the tools have run.
	viewport_draw_list: ^imgui.DrawList,
	viewport_origin:    imgui.Vec2,
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
	mask_last:          Mask_Done,
	clip_last:          Clip_Done,
	hide_last:          Clip_Done,
	smooth_steps:       i32, // steps each Smooth all press takes
	smooth_strength:    f32, // how far each step moves a vertex toward its neighbours' average, 0 to 1
	smooth_on_gpu:      bool, // run Smooth all as a compute shader (the GPU compute trial); off by default
	smooth_last:        Smooth_Done,
	crease_degrees:     f32, // Polygroups' Creases: how sharp a crease starts a new group
	layer_selected:     int,  // the Layers section's row that Delete and Bake act on
	layer_dragging:     bool, // a layer's strength slider is being dragged: one undo step
	retopo_quads:       i32,  // quads Retopologize asks for
	retopo_last:        struct {quads, charts: int, ms: f64, set: bool},
	bake:               Bake_Settings,
	bake_last:          struct {ms, hit: f64, range: f32, set: bool},
}

// The last Smooth all, for the Deformation section to report.
Smooth_Done :: struct {
	steps:   int,
	ms:      f64, // the whole command, undo saving and normals included
	changed: bool,
	on_gpu:  bool,
	gpu:     render.Smooth_Timing, // the GPU's parts, when on_gpu
	set:     bool, // false until it has run
}

// The last clip or hiding change, for the Tools panel to report.
Clip_Done :: struct {
	ms:      f64,
	changed: bool,
	set:     bool, // false until a clip has run
}

// The last mask command, for the Mask section to report.
Mask_Done :: struct {
	command: sculpt.Mask_Command,
	steps:   int,
	ms:      f64,
	changed: bool,
	set:     bool, // false until a command has run
	shape:   bool, // a mask shape: command is Fill for masking, Clear for unmasking
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

MIN_SPHERE_VERTICES :: 12
MAX_SPHERE_VERTICES :: 100_000_000
// Measured at 25M vertices: mesh, sculpt nodes and topology together.
BYTES_PER_VERTEX :: 108

// What the viewport panel saw this frame, in viewport-local pixels. This is the only
// thing the camera (and later the brush) reads; neither touches ImGui directly.
Viewport_Input :: struct {
	size:        [2]f32,
	mouse_pos:   [2]f32,
	mouse_delta: [2]f32,
	wheel:       f32,
	hovered:     bool,
	dragging:    bool, // a drag that started in the viewport, even if the cursor has left it
	orbit_drag:  bool, // right mouse, or Alt + left mouse
	pan_drag:    bool, // middle mouse, or Shift + right mouse
	primary:     bool, // left mouse without Alt: drives the active tool
	press:       bool, // the left button went down in the viewport this frame
	smooth:      bool, // Shift held during a stroke: smooth brush
	invert:      bool, // Ctrl held during a stroke: invert the brush
	alt:         bool, // Alt held with Ctrl: a mask shape unmasks
	samples:     []Input_Sample, // every pointer sample this frame, oldest first
	pen_tilt:    [2]f32, // the pen's lean now, in degrees; zero without a pen
}

BRUSH_NAMES := [sculpt.Brush_Kind]string {
	.Draw    = "Draw",
	.Smooth  = "Smooth",
	.Clay    = "Clay",
	.Flatten = "Flatten",
	.Inflate = "Inflate",
	.Pinch   = "Pinch",
	.Crease  = "Crease",
	.Grab    = "Grab",
	.Mask    = "Mask",
	.Layer   = "Layer",
	.Snake_Hook = "Snake hook",
	.Morph   = "Morph",
	.Paint   = "Paint",
	.Cloth   = "Cloth",
}

BRUSH_HELP := [sculpt.Brush_Kind]cstring {
	.Draw    = "Pushes the surface out (Ctrl: in).",
	.Smooth  = "Evens out bumps. Shift smooths with any brush.",
	.Clay    = "Builds up toward a flat top, filling dips first (Ctrl: digs).",
	.Flatten = "Levels the surface to its average plane (Ctrl: away from it).",
	.Inflate = "Swells along the surface's own normals (Ctrl: shrinks).",
	.Pinch   = "Pulls the surface together under the brush (Ctrl: apart).",
	.Crease  = "Cuts a sharp groove (Ctrl: a sharp ridge).",
	.Grab    = "Drags what is under the brush with the pointer.",
	.Mask    = "Paints the mask (Ctrl: erases it).",
	.Layer   = "Raises a flat layer of one height per stroke; going\nover it again adds nothing (Ctrl: lowers).",
	.Snake_Hook = "Pulls the surface out after the pointer, for horns,\ntentacles and fingers. Best with dynamic topology.",
	.Morph   = "Brings the surface back to the stored morph target\n(Tools > Morph target), painting later work away.",
	.Paint   = "Polypaint: colours the surface with the colour below,\nmoving nothing (Ctrl: takes the paint off).",
	.Cloth   = "The surface around the brush acts as cloth while you\nhold: drag it into folds, let it sag, or bunch it up.",
}

CLOTH_MODE_NAMES := [sculpt.Cloth_Mode]cstring {
	.Drag    = "Drag",
	.Gravity = "Gravity",
	.Pinch   = "Pinch",
	.Expand  = "Expand",
}

@(private = "file")
CLOTH_MODE_HELP := [sculpt.Cloth_Mode]cstring {
	.Drag    = "What is under the brush follows the pointer;\nthe cloth around it folds as it is pulled.",
	.Gravity = "The cloth sags toward the bottom of the screen\nwhile the button is held (Ctrl: rises).",
	.Pinch   = "Gathers the cloth toward the brush into folds\n(Ctrl: Expand).",
	.Expand  = "Pushes the cloth out from the brush so it\nbuckles into ridges (Ctrl: Pinch).",
}

brush_by_name :: proc(name: string) -> (sculpt.Brush_Kind, bool) {
	for kind in sculpt.Brush_Kind {
		// "snake_hook" or "snakehook" on the command line find "Snake hook".
		if strings.equal_fold(name, BRUSH_NAMES[kind]) || strings.equal_fold(name, fmt.tprint(kind)) do return kind, true
		if spaced, _ := strings.remove_all(BRUSH_NAMES[kind], " ", context.temp_allocator); strings.equal_fold(name, spaced) do return kind, true
	}
	return {}, false
}

ui_state_default :: proc() -> Ui_State {
	return {viewport_request = {1280, 720}, sphere_vertices = 500_000, mask_steps = 3, smooth_steps = 5, smooth_strength = 0.5, crease_degrees = sculpt.CREASE_GROUP_DEGREES, retopo_quads = 4000, bake = {size = 2048, reach_edges = 2}}
}

ui_draw :: proc(app: ^App) -> Viewport_Input {
	dockspace := imgui.DockSpaceOverViewport()
	if !app.ui.layout_built {
		build_default_layout(dockspace)
		app.ui.layout_built = true
	}

	draw_menu_bar(app)
	input := draw_viewport(app)
	draw_tools_panel(app)
	draw_scene_panel(app)
	draw_stats_panel(app)
	draw_history_panel(app)
	handle_shortcuts(app)
	if app.ui.show_demo {
		imgui.ShowDemoWindow(&app.ui.show_demo)
	}
	return input
}

// ImGuiDockNodeFlags_DockSpace (1 << 10) is internal and missing from the generated bindings.
@(private = "file")
DOCK_NODE_FLAGS_DOCKSPACE :: transmute(imgui.DockNodeFlags)i32(1 << 10)

@(private = "file")
build_default_layout :: proc(dockspace: imgui.ID) {
	imgui.DockBuilderRemoveNode(dockspace)
	imgui.DockBuilderAddNode(dockspace, DOCK_NODE_FLAGS_DOCKSPACE)
	imgui.DockBuilderSetNodeSize(dockspace, imgui.GetMainViewport().Size)
	right, bottom: imgui.ID
	main := dockspace
	imgui.DockBuilderSplitNode(main, .Right, 0.24, &right, &main)
	imgui.DockBuilderSplitNode(main, .Down, 0.13, &bottom, &main)
	right_bottom, right_middle: imgui.ID
	imgui.DockBuilderSplitNode(right, .Down, 0.66, &right_bottom, &right)
	imgui.DockBuilderSplitNode(right_bottom, .Down, 0.4, &right_bottom, &right_middle)
	imgui.DockBuilderDockWindow("Viewport", main)
	imgui.DockBuilderDockWindow("Tools", right)
	imgui.DockBuilderDockWindow("Scene", right_middle)
	imgui.DockBuilderDockWindow("Stats", right_bottom)
	imgui.DockBuilderDockWindow("History", bottom)
	imgui.DockBuilderFinish(dockspace)
}

@(private = "file")
AXIS_VIEW_NAMES := [camera.Axis_View]cstring{.Front = "Front", .Back = "Back", .Right = "Right", .Left = "Left", .Top = "Top", .Bottom = "Bottom"}
@(private = "file")
AXIS_VIEW_KEYS := [camera.Axis_View]cstring{.Front = "Num 1", .Back = "Ctrl+Num 1", .Right = "Num 3", .Left = "Ctrl+Num 3", .Top = "Num 7", .Bottom = "Ctrl+Num 7"}

@(private = "file")
draw_menu_bar :: proc(app: ^App) {
	if !imgui.BeginMainMenuBar() do return
	defer imgui.EndMainMenuBar()
	if imgui.BeginMenu("File") {
		if imgui.MenuItem("Open scene...", "Ctrl+O") do file_dialog(app, .Open)
		if imgui.MenuItem("Save scene", "Ctrl+S") do save_scene(app)
		if imgui.MenuItem("Save scene as...", "Ctrl+Shift+S") do file_dialog(app, .Save)
		imgui.Separator()
		if imgui.MenuItem("Import mesh (OBJ, PLY)...") do file_dialog(app, .Import)
		if imgui.MenuItem("Export selected (OBJ, PLY)...", nil, false, selected_object(app) != nil) do file_dialog(app, .Export)
		imgui.Separator()
		if imgui.MenuItem("Save screenshot (PNG)...", "F12") do file_dialog(app, .Screenshot)
		imgui.Separator()
		if imgui.MenuItem("Quit", "Alt+F4") do app.running = false
		imgui.EndMenu()
	}
	if imgui.BeginMenu("Edit") {
		if imgui.MenuItem(fmt.ctprintf("Undo %s", history_next_label(app.history.done[:])), "Ctrl+Z", false, history_can_undo(app)) do history_undo(app)
		if imgui.MenuItem(fmt.ctprintf("Redo %s", history_next_label(app.history.undone[:])), "Ctrl+Shift+Z", false, history_can_redo(app)) do history_redo(app)
		imgui.EndMenu()
	}
	if imgui.BeginMenu("View") {
		if imgui.MenuItem("Reset camera") do reset_camera(app)
		if imgui.MenuItem("Focus selected", "F") do focus_selected(app)
		if imgui.MenuItem("Orthographic", "P", app.camera.ortho) do app.camera.ortho = !app.camera.ortho
		if imgui.BeginMenu("Look from") {
			for view in camera.Axis_View {
				if imgui.MenuItem(AXIS_VIEW_NAMES[view], AXIS_VIEW_KEYS[view]) do camera.orbit_axis_view(&app.camera, view)
			}
			imgui.EndMenu()
		}
		imgui.Separator()
		if imgui.MenuItem("Wireframe", "Shift+F", app.wireframe) do app.wireframe = !app.wireframe
		if imgui.MenuItem("Flat shading", "Shift+G", app.flat) do app.flat = !app.flat
		if imgui.MenuItem("Polygroups", "Shift+W", app.show_groups) do app.show_groups = !app.show_groups
		if imgui.MenuItem("Studio render", "Shift+R", app.studio_on) do studio_toggle(app)
		if imgui.BeginMenu("Studio settings") {
			imgui.SliderFloat("Occlusion", &app.studio_ao, 0, 1, "%.2f")
			imgui.SliderFloat("Shadow", &app.studio_shadow, 0, 1, "%.2f")
			imgui.SliderInt("Samples", &app.studio_samples, 16, STUDIO_SAMPLES_MAX)
			imgui.TextDisabled("Builds up while the view stays still;\nany change starts it over.")
			imgui.EndMenu()
		}
		if imgui.BeginMenu("Material") {
			material_menu(app)
			imgui.EndMenu()
		}
		imgui.Separator()
		if imgui.MenuItem("ImGui demo", nil, app.ui.show_demo) do app.ui.show_demo = !app.ui.show_demo
		imgui.EndMenu()
	}
	if app.studio_on && app.studio.samples > 0 && app.studio.samples < int(app.studio_samples) {
		imgui.Separator()
		imgui.TextDisabled("Studio %d/%d", i32(app.studio.samples), app.studio_samples)
	}
	// The last file action's outcome, for a while; the whole of it on hover.
	if note := app.file_note; note.text != "" && time.tick_since(note.at) < FILE_NOTE_SHOWN {
		imgui.Separator()
		text := fmt.ctprintf("%s", note.text)
		if note.warning {
			imgui.TextColored({1, 0.75, 0.3, 1}, "%s", text)
		} else {
			imgui.TextDisabled("%s", text)
		}
		if imgui.IsItemHovered() do imgui.SetTooltip("%s", text)
	}
}

// Turns the studio render on or off; on, it starts from the plain viewport.
studio_toggle :: proc(app: ^App) {
	app.studio_on = !app.studio_on
	render.studio_reset(&app.studio)
}

// View > Material: the classic presets, the physically based ones, and sliders that edit
// whichever is in use into the Custom material.
@(private = "file")
material_menu :: proc(app: ^App) {
	for m, i in MATERIALS {
		if i == FIRST_PBR do imgui.SeparatorText("Physically based")
		if imgui.MenuItem(m.label, nil, app.material == i) do app.material = i
	}
	imgui.SeparatorText("Custom")
	if imgui.MenuItem("Custom", nil, app.material == CUSTOM_MATERIAL) do app.material = CUSTOM_MATERIAL
	// The sliders show the material in use; moving one copies it into Custom first, so a
	// preset is never changed. A classic preset has no roughness yet, so it starts rough.
	m := current_material(app)
	if m.roughness == 0 do m.roughness = CUSTOM_ROUGHNESS
	changed := imgui.ColorEdit3("Colour", (^[3]f32)(&m.selected), {.Float})
	changed |= imgui.SliderFloat("Metallic", &m.metallic, 0, 1, "%.2f")
	changed |= imgui.SliderFloat("Roughness", &m.roughness, 0.04, 1, "%.2f")
	if changed {
		m.label = "Custom"
		app.custom = m
		app.material = CUSTOM_MATERIAL
	}
}

// Saves where the scene was last saved or opened, or asks where to the first time.
@(private = "file")
save_scene :: proc(app: ^App) {
	if app.scene_path != "" {
		file_post(.Save, app.scene_path)
	} else {
		file_dialog(app, .Save)
	}
}

@(private = "file")
draw_viewport :: proc(app: ^App) -> (input: Viewport_Input) {
	imgui.PushStyleVarImVec2(.WindowPadding, {0, 0})
	defer imgui.PopStyleVar()
	visible := imgui.Begin("Viewport", nil, {.NoScrollbar, .NoScrollWithMouse, .NoCollapse})
	defer imgui.End()
	if !visible do return

	avail := imgui.GetContentRegionAvail()
	scale := imgui.GetWindowDpiScale()
	app.ui.viewport_request = {max(avail.x * scale, 1), max(avail.y * scale, 1)}

	origin := imgui.GetCursorScreenPos()
	// The studio render's image while it is on and has one, else the plain viewport.
	shown := app.target.color
	if app.studio_on {
		if tex := render.studio_texture(&app.studio); tex != nil do shown = tex
	}
	imgui.Image(imgui.TextureRef{_TexID = imgui.TextureID(uintptr(shown))}, avail)

	// An invisible button over the image captures mouse input so dragging in the
	// viewport never moves the window or leaks to panels underneath.
	imgui.SetCursorScreenPos(origin)
	imgui.InvisibleButton("viewport_input", avail, {.MouseButtonLeft, .MouseButtonRight, .MouseButtonMiddle})

	io := imgui.GetIO()
	// A right press let go soon and about where it began is a tap, which opens the brush
	// pie, rather than an orbit.
	right_tap :=
		imgui.IsItemDeactivated() && imgui.IsMouseReleased(.Right) && !io.KeyShift &&
		io.MouseDownDurationPrev[imgui.MouseButton.Right] < f32(time.duration_seconds(PIE_TAP)) &&
		io.MouseDragMaxDistanceSqr[imgui.MouseButton.Right] < PIE_TAP_PX * PIE_TAP_PX
	input.size = {avail.x, avail.y}
	input.hovered = imgui.IsItemHovered()
	input.dragging = imgui.IsItemActive()
	input.mouse_pos = {io.MousePos.x - origin.x, io.MousePos.y - origin.y}
	input.samples = make([]Input_Sample, len(app.samples), context.temp_allocator)
	for s, i in app.samples do input.samples[i] = {s.pos - {origin.x, origin.y}, s.pressure, s.kind, s.tilt}
	input.pen_tilt = app.pen_tilt
	input.mouse_delta = {io.MouseDelta.x, io.MouseDelta.y}
	input.wheel = io.MouseWheel

	left := imgui.IsMouseDown(.Left)
	right := imgui.IsMouseDown(.Right)
	middle := imgui.IsMouseDown(.Middle)
	if input.dragging {
		// Alt with Ctrl is a mask shape that unmasks, not an orbit.
		input.orbit_drag = (right && !io.KeyShift) || (left && io.KeyAlt && !io.KeyCtrl)
		input.pan_drag = middle || (right && io.KeyShift)
		input.primary = left && (!io.KeyAlt || io.KeyCtrl)
		input.alt = input.primary && io.KeyAlt
		input.press = input.primary && imgui.IsMouseClicked(.Left)
		input.smooth = input.primary && io.KeyShift
		input.invert = input.primary && io.KeyCtrl
	}
	pie_update(app, &input, right_tap)
	adjust_update(app, &input)
	app.ui.viewport_draw_list = imgui.GetWindowDrawList()
	app.ui.viewport_origin = origin
	app.ui.viewport_mouse, app.ui.viewport_size, app.ui.viewport_hovered = input.mouse_pos, input.size, input.hovered
	return
}

// Draws the brush circle or the move gizmo over the viewport image. Runs after the
// tools have handled this frame's input, so the overlay matches what gets rendered.
draw_viewport_overlay :: proc(app: ^App, input: Viewport_Input) {
	defer draw_pie(app)
	list := app.ui.viewport_draw_list
	if list == nil do return
	app.ui.viewport_draw_list = nil
	o := app.ui.viewport_origin
	imgui.DrawList_PushClipRect(list, o, o + input.size)
	defer imgui.DrawList_PopClipRect(list)
	rgba :: proc(c: [4]f32) -> u32 {return imgui.ColorConvertFloat4ToU32(c)}

	switch app.tool {
	case .Brush:
		if app.clip.active {
			draw_clip(app, list, o, input.size)
			break
		}
		if app.mask_shape.active {
			draw_mask_shape(app, list, o, input.mouse_pos)
			break
		}
		if draw_adjust(app, list, o) do break
		if st := app.stroke; st.active && st.rect {
			// The stamp being dragged out: its circle around where it began, and a line to
			// the pointer, the way its top faces.
			color := rgba({1, 0.8, 0.4, 0.9})
			imgui.DrawList_AddCircle(list, o + st.start, max(linalg.length(input.mouse_pos - st.start), 2), color, 64, 1.5)
			imgui.DrawList_AddLine(list, o + st.start, o + input.mouse_pos, color, 1.5)
			break
		}
		if (input.hovered || input.dragging) && !app.ui.pie.open {
			color := rgba({1, 1, 1, 0.6} if !input.primary else {1, 0.8, 0.4, 0.9})
			center := input.mouse_pos
			if app.stroke.active && app.brush.lazy_px > 0 {
				// The brush trails the cursor: draw it where it is, on its string.
				center = app.stroke.pos
				imgui.DrawList_AddLine(list, o + center, o + input.mouse_pos, color, 1)
			}
			if brush_alpha(app) != nil && !input.smooth {
				draw_alpha_outline(app, list, o + center, color)
			} else {
				imgui.DrawList_AddCircle(list, o + center, app.brush.radius_px, color, 48, 1.5)
			}
			// Which way a leaning pen turns the brush, and how far: toward the top of the
			// pen, a radius long at a right angle.
			if lean := input.pen_tilt * app.brush.tilt_strength; app.brush.tilt_strength > 0 && lean != {} {
				angle := min(linalg.to_radians(linalg.length(lean)), camera.MAX_TILT)
				tip := o + center + linalg.normalize(lean) * (app.brush.radius_px * math.sin(angle))
				imgui.DrawList_AddLine(list, o + center, tip, color, 2)
				imgui.DrawList_AddCircleFilled(list, tip, 3, color, 12)
			}
		}
	case .Move:
		gv := gizmo_view(app, input.size)
		if !gv.ok do return
		active := app.move.drag.handle if app.move.drag.handle != .None else app.move.hover
		AXIS_COLORS := [3][4]f32{{0.95, 0.3, 0.3, 1}, {0.4, 0.85, 0.35, 1}, {0.35, 0.55, 1, 1}}
		HIGHLIGHT :: [4]f32{1, 0.85, 0.3, 1}
		c := o + gv.center
		for i in 0 ..< 3 {
			if !gv.tip_ok[i] do continue
			color := rgba(HIGHLIGHT if active == gizmo.Handle(i + 1) else AXIS_COLORS[i])
			tip := o + gv.tips[i]
			imgui.DrawList_AddLine(list, c, tip, color, 3)
			imgui.DrawList_AddCircleFilled(list, tip, 5, color)
		}
		r := f32(gizmo.CENTER_PX)
		center_color := rgba(HIGHLIGHT if active == .View else {1, 1, 1, 0.85})
		imgui.DrawList_AddRect(list, c - r, c + r, center_color, 0, 2)
	}
}

@(private = "file")
draw_tools_panel :: proc(app: ^App) {
	defer imgui.End()
	if !imgui.Begin("Tools") do return
	imgui.SeparatorText("Tool")
	if imgui.RadioButton("Select / Move (W)", app.tool == .Move) do app.tool = .Move
	imgui.SameLine()
	if imgui.RadioButton("Brush (B)", app.tool == .Brush) do app.tool = .Brush
	switch app.tool {
	case .Move:
		imgui.TextDisabled("Click selects. Drag an object, or a gizmo arm\nto move along that axis.")
	case .Brush:
		imgui.TextDisabled("Left drag sculpts the object under the cursor.\nShift smooths, Ctrl inverts (the Mask brush erases).")
	}

	imgui.SeparatorText("Brush")
	for kind, i in sculpt.Brush_Kind {
		if i % 3 != 0 do imgui.SameLine()
		label := fmt.ctprintf("%v (%d)", BRUSH_NAMES[kind], (i + 1) % 10) if i < 10 else fmt.ctprintf("%v", BRUSH_NAMES[kind])
		if imgui.RadioButton(label, app.brush.kind == kind) do app.brush.kind = kind
	}
	imgui.TextDisabled("%s", BRUSH_HELP[app.brush.kind])
	if app.brush.kind == .Cloth {
		for mode in sculpt.Cloth_Mode {
			if mode != .Drag do imgui.SameLine()
			if imgui.RadioButton(CLOTH_MODE_NAMES[mode], app.brush.cloth_mode == mode) do app.brush.cloth_mode = mode
		}
		imgui.TextDisabled("%s", CLOTH_MODE_HELP[app.brush.cloth_mode])
	}
	imgui.SliderFloat("Radius (px)", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, "%.0f", {.Logarithmic})
	imgui.SliderFloat("Strength", brush_strength(app), MIN_STRENGTH, 1, "%.2f")
	imgui.TextDisabled("S or U over the viewport sizes the brush or sets its\nstrength there; [ and ] step the size, Shift+[ and ]\nthe strength. Each brush keeps its own strength.")
	imgui.SliderFloat("Lazy mouse (px)", &app.brush.lazy_px, 0, 150, "%.0f")
	imgui.Text("Stroke")
	imgui.SameLine()
	if imgui.RadioButton("Dots", app.brush.stroke == .Dots) do app.brush.stroke = .Dots
	imgui.SameLine()
	if imgui.RadioButton("Drag rectangle", app.brush.stroke == .Drag_Rect) do app.brush.stroke = .Drag_Rect
	if imgui.IsItemHovered() do imgui.SetTooltip("One stamp where the drag starts: its size is how far\nyou drag and, with an alpha, its top faces the pointer.\nFor placing alphas. Not with dynamic topology, Grab or\nSnake hook.")
	imgui.Checkbox("Front faces only", &app.brush.front_only)
	if imgui.IsItemHovered() do imgui.SetTooltip("Brushes and mask shapes leave what faces away from you,\nso a stroke on a thin part (an ear, a fin) leaves its\nfar side alone. Grab is not affected.")
	imgui.TextDisabled("Space, or a right click without dragging (a pen's side\nbutton), opens the brush pie.")
	imgui.Text("Symmetry")
	for axis in sculpt.Axis {
		imgui.SameLine()
		on := axis in app.brush.symmetry
		if imgui.Checkbox(fmt.ctprintf("%v", axis), &on) do app.brush.symmetry ~= {axis}
	}
	imgui.SameLine()
	imgui.TextDisabled("(X toggles X)")
	draw_falloff_section(app)
	draw_alpha_section(app)
	draw_dyntopo_section(app)
	draw_morph_section(app)
	draw_paint_section(app)
	draw_layers_section(app)

	imgui.SeparatorText("Mask")
	imgui.BeginDisabled(selected_object(app) == nil)
	if imgui.Button("Clear (Alt+M)") do mask_command(app, .Clear)
	imgui.SameLine()
	if imgui.Button("Invert (Ctrl+I)") do mask_command(app, .Invert)
	imgui.SameLine()
	if imgui.Button("Mask all") do mask_command(app, .Fill)
	imgui.SameLine()
	if imgui.Button("Mask cavities") do mask_command(app, .Cavity)
	for command, i in ([?]sculpt.Mask_Command{.Blur, .Sharpen, .Grow, .Shrink}) {
		if i > 0 do imgui.SameLine()
		if imgui.Button(fmt.ctprintf("%s", MASK_COMMAND_NAMES[command])) do mask_command(app, command)
	}
	imgui.SliderInt("Steps", &app.ui.mask_steps, 1, 50)
	imgui.EndDisabled()
	imgui.Text("Ctrl + drag on empty space:")
	imgui.SameLine()
	if imgui.RadioButton("Rectangle", app.ui.mask_shape_kind == .Rectangle) do app.ui.mask_shape_kind = .Rectangle
	imgui.SameLine()
	if imgui.RadioButton("Lasso", app.ui.mask_shape_kind == .Lasso) do app.ui.mask_shape_kind = .Lasso
	imgui.TextDisabled("Paint it with the Mask brush (9), or Ctrl + drag a\nshape from empty space (with Alt: unmask); masked\nareas show darker and no brush moves them. It follows level changes.\nBlur, Sharpen, Grow and Shrink move its edge\na ring of triangles a step, so a dense mesh\nneeds more steps.")
	if last := app.ui.mask_last; last.set {
		steps := fmt.tprintf(", %d steps", last.steps) if last.command >= .Blur else ""
		outcome := "" if last.changed else ", nothing changed"
		name := MASK_COMMAND_NAMES[last.command]
		if last.shape do name = "Unmask shape" if last.command == .Clear else "Mask shape"
		imgui.TextDisabled("%s", fmt.ctprintf("Last: %s%s in %.0f ms%s", name, steps, last.ms, outcome))
	}

	imgui.SeparatorText("Hide, clip and slice")
	imgui.Text("Ctrl + Shift + drag:")
	for tool, i in Gesture_Tool {
		if i == 2 do imgui.Text("   ")
		if i % 2 == 1 || i == 2 do imgui.SameLine()
		if imgui.RadioButton(GESTURE_NAMES[tool], app.gesture == tool) do app.gesture = tool
	}
	if imgui.Button("Show all (Ctrl+H)") do hide_command(app, .Show_All)
	imgui.SameLine()
	if imgui.Button("Invert (Ctrl+Shift+H)") do hide_command(app, .Invert)
	switch app.gesture {
	case .Hide_Rectangle, .Hide_Lasso:
		imgui.TextDisabled("Letting go keeps only what is inside the shape\nshown, through to the back (Alt: hides what is\ninside). Hidden parts are not drawn and no brush,\nmask or clip touches them. A Ctrl + Shift click\nshows everything. Not in HD or with dynamic topology.")
	case .Clip:
		imgui.TextDisabled("Letting go flattens the selected object on the\nshaded side (Alt: the other side) onto the line,\nthrough to the back. It follows symmetry and leaves\nmasked and hidden areas. Not with dynamic topology.")
	case .Slice:
		imgui.TextDisabled("Letting go cuts the selected object in two along\nthe line, through to the back, and closes each cut:\nthe part on the right of the drag becomes an object\nof its own. Levels, mask and hiding are dropped.")
	}
	if last := app.ui.hide_last; last.set {
		hidden := 0
		if obj := selected_object(app); obj != nil do hidden = sculpt.sculptor_hidden_count(object_sculptor(obj))
		imgui.TextDisabled("%s", fmt.ctprintf("Last hide: %.0f ms%s; %d triangles hidden", last.ms, "" if last.changed else ", nothing changed", hidden))
	}
	if last := app.ui.clip_last; last.set {
		imgui.TextDisabled("%s", fmt.ctprintf("Last clip: %.0f ms%s", last.ms, "" if last.changed else ", nothing changed"))
	}
	if app.stats.slice_ms > 0 {
		imgui.TextDisabled("%s", fmt.ctprintf("Last slice: %.0f ms, ready in %.0f ms more", app.stats.slice_ms, app.stats.slice_setup_ms))
	}

	draw_deformation_section(app)
	draw_pen_section(app)

	imgui.SeparatorText("Camera")
	imgui.Text("Orbit: right drag, or Alt + left drag")
	imgui.Text("Pan: middle drag, or Shift + right drag")
	imgui.Text("Zoom: mouse wheel.  Focus selected: F")
	imgui.SliderFloat("Distance", &app.camera.distance, camera.MIN_DISTANCE, 20, "%.2f", {.Logarithmic})
	if imgui.Button("Reset camera") do reset_camera(app)
	imgui.SameLine()
	imgui.Checkbox("Orthographic (P)", &app.camera.ortho)
}

// Back to the starting view, keeping the projection.
@(private = "file")
reset_camera :: proc(app: ^App) {
	ortho := app.camera.ortho
	app.camera = camera.orbit_default()
	app.camera.ortho = ortho
}

// What a pen does to the brush: pressure through a curve, and the lean.
@(private = "file")
draw_pen_section :: proc(app: ^App) {
	imgui.SeparatorText("Pen")
	imgui.Checkbox("Pressure sets strength", &app.brush.pressure_strength)
	imgui.SameLine()
	imgui.Checkbox("size", &app.brush.pressure_size)
	draw_pressure_curve(app)
	for preset, i in PRESSURE_PRESETS {
		if i > 0 do imgui.SameLine()
		if imgui.SmallButton(preset.label) do app.brush.pressure_curve = preset.curve
	}
	imgui.SliderFloat("Tilt", &app.brush.tilt_strength, 0, 1, "%.2f")
	imgui.SameLine()
	imgui.TextDisabled("(turns the brush as the pen leans)")
	if app.pen_seen {
		imgui.TextDisabled("Pen: pressure %.2f counts as %.2f; leaning %.0f° across, %.0f° down", app.pen_pressure, pressure_curved(app, app.pen_pressure), app.pen_tilt.x, app.pen_tilt.y)
	} else {
		imgui.TextDisabled("No pen seen yet; a mouse always has full pressure.")
	}
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

// The pressure curve as a graph to drag: pen pressure along, what it counts as up. The
// two round handles are the curve's control points; the dot is the pen now.
@(private = "file")
draw_pressure_curve :: proc(app: ^App) {
	dot: Maybe([2]f32)
	if app.pen_seen {
		x := clamp(app.pen_pressure, 0, 1)
		dot = [2]f32{x, pressure_curved(app, x)}
	}
	_ = draw_curve_editor("pressure_curve", &app.brush.pressure_curve, &app.ui.curve_handle, false, dot, nil)
	imgui.SameLine()
	imgui.TextDisabled("Pressure curve:\ndrag the handles.\nAlong: how hard\nthe pen presses.\nUp: what that\ncounts as.")
}

// A response curve as a graph to drag: the two round handles are its control points.
// With `mirrored` the curve is drawn right to left, as a falloff reads from the centre
// out. `dot` marks a point on it; `shown`, when given, is drawn instead of the curve
// (a built-in shape that is not a curve; its handles still show, to drag from). `handle` remembers which handle is held
// between frames. Returns whether a handle moved.
@(private = "file")
draw_curve_editor :: proc(id: cstring, curve: ^geom.Curve, handle: ^int, mirrored: bool, dot: Maybe([2]f32), shown: proc(x: f32) -> f32) -> (moved: bool) {
	SIZE :: imgui.Vec2{160, 110}
	HANDLE_PX :: 6
	o := imgui.GetCursorScreenPos()
	imgui.InvisibleButton(id, SIZE)
	list := imgui.GetWindowDrawList()
	rgba :: proc(c: [4]f32) -> u32 {return imgui.ColorConvertFloat4ToU32(c)}
	to_px :: proc(o: imgui.Vec2, p: [2]f32, mirrored: bool) -> imgui.Vec2 {
		x := 1 - p.x if mirrored else p.x
		return o + {x * SIZE.x, (1 - p.y) * SIZE.y}
	}

	mouse := imgui.GetIO().MousePos
	if imgui.IsItemActivated() {
		// Grab the nearer handle, if the press is near one.
		handle^ = 0
		best := f32(3 * HANDLE_PX)
		for c, i in ([2][2]f32{curve.c1, curve.c2}) {
			if d := linalg.length(mouse - to_px(o, c, mirrored)); d < best do handle^, best = i + 1, d
		}
	}
	if imgui.IsItemActive() && handle^ > 0 {
		x := clamp((mouse.x - o.x) / SIZE.x, 0, 1)
		p := [2]f32{1 - x if mirrored else x, clamp(1 - (mouse.y - o.y) / SIZE.y, 0, 1)}
		if handle^ == 1 do curve.c1 = p
		else do curve.c2 = p
		moved = true
	} else if !imgui.IsItemActive() {
		handle^ = 0
	}

	imgui.DrawList_AddRectFilled(list, o, o + SIZE, rgba({0.1, 0.1, 0.12, 1}))
	for k in 1 ..< 4 {
		f := f32(k) / 4
		grid := rgba({1, 1, 1, 0.07})
		imgui.DrawList_AddLine(list, to_px(o, {f, 0}, false), to_px(o, {f, 1}, false), grid)
		imgui.DrawList_AddLine(list, to_px(o, {0, f}, false), to_px(o, {1, f}, false), grid)
	}
	imgui.DrawList_AddLine(list, to_px(o, {0, 0}, mirrored), to_px(o, {1, 1}, mirrored), rgba({1, 1, 1, 0.15}))
	STEPS :: 48
	points: [STEPS + 1]imgui.Vec2
	for &q, i in points {
		x := f32(i) / STEPS
		q = to_px(o, {x, shown(x) if shown != nil else geom.curve_at(curve^, x)}, mirrored)
	}
	imgui.DrawList_AddPolyline(list, &points[0], STEPS + 1, rgba({0.95, 0.8, 0.45, 1}), 2)
	{
		h := rgba({0.6, 0.75, 1, 1})
		imgui.DrawList_AddLine(list, to_px(o, {0, 0}, mirrored), to_px(o, curve.c1, mirrored), h)
		imgui.DrawList_AddLine(list, to_px(o, {1, 1}, mirrored), to_px(o, curve.c2, mirrored), h)
		imgui.DrawList_AddCircleFilled(list, to_px(o, curve.c1, mirrored), HANDLE_PX, h, 16)
		imgui.DrawList_AddCircleFilled(list, to_px(o, curve.c2, mirrored), HANDLE_PX, h, 16)
	}
	if p, ok := dot.?; ok do imgui.DrawList_AddCircleFilled(list, to_px(o, p, mirrored), 4, rgba({1, 1, 1, 1}), 12)
	return
}

// The falloff of the brush in use: the built-in smooth one, or a curve drawn here.
@(private = "file")
draw_falloff_section :: proc(app: ^App) {
	imgui.SeparatorText("Falloff")
	kind := app.brush.kind
	shape := &app.brush.falloffs[kind]
	smooth :: proc(x: f32) -> f32 {
		// The built-in falloff over how far in from the rim, as the curve is read.
		d := 1 - x
		return sculpt.falloff(d * d)
	}
	// Dragging a handle of the built-in shape starts a drawn one close to it.
	if !shape.drawn do shape.curve = FALLOFF_SMOOTH_CURVE
	if draw_curve_editor("falloff_curve", &shape.curve, &app.ui.falloff_handle, true, nil, nil if shape.drawn else smooth) {
		shape.drawn = true
	}
	imgui.SameLine()
	imgui.TextDisabled("%s", fmt.ctprintf("%s falloff:\ncentre on the left,\nrim on the right.\nDrag a handle to\ndraw your own.", BRUSH_NAMES[kind]))
	for preset, i in FALLOFF_PRESETS {
		if i > 0 do imgui.SameLine()
		if imgui.SmallButton(preset.label) do shape^ = {drawn = preset.drawn, curve = preset.curve}
	}
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

// Polypaint's colour and commands, and Polygroups'.
@(private = "file")
draw_paint_section :: proc(app: ^App) {
	imgui.SeparatorText("Polypaint")
	imgui.ColorEdit3("Colour", &app.brush.color)
	obj := selected_object(app)
	imgui.BeginDisabled(obj == nil)
	if imgui.Button("Fill with colour") do paint_command(app, .Fill)
	imgui.SameLine()
	if imgui.Button("Clear paint") do paint_command(app, .Clear)
	imgui.EndDisabled()
	imgui.TextDisabled("The Paint brush paints the colour over the clay at\nevery vertex, Ctrl takes it off. Fill and Clear\nskip what is masked or hidden. Each level keeps its\nown paint; changing level carries what you painted.")

	imgui.SeparatorText("Polygroups")
	imgui.BeginDisabled(obj == nil)
	if imgui.Button("Group visible") do group_command(app, .Visible)
	imgui.SameLine()
	if imgui.Button("Group masked") do group_command(app, .Masked)
	imgui.SameLine()
	if imgui.Button("Clear groups") do group_command(app, .Clear)
	if imgui.Button("Groups by creases") do group_command(app, .Creases)
	imgui.SameLine()
	imgui.SetNextItemWidth(120)
	imgui.SliderFloat("Angle", &app.ui.crease_degrees, 1, 90, "%.0f deg")
	imgui.EndDisabled()
	imgui.Checkbox("Show polygroups (Shift+W)", &app.show_groups)
	imgui.TextDisabled("Ctrl+W groups the masked part (clearing the mask),\nor with nothing masked, what is shown. Ctrl + Shift\nclick a group to show only it (again: everything\nbut it); with Alt, to mask it. Not in HD or with\ndynamic topology.")
}

// The selected object's morph target: storing and deleting it.
@(private = "file")
draw_morph_section :: proc(app: ^App) {
	imgui.SeparatorText("Morph target")
	obj := selected_object(app)
	s := object_sculptor(obj) if obj != nil else nil
	imgui.BeginDisabled(s == nil || object_dynamic(obj) || object_in_hd(obj))
	if imgui.Button("Store") {
		stroke_finish(app)
		_ = sculpt.sculptor_morph_store(s)
	}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.BeginDisabled(s == nil || !sculpt.sculptor_has_morph(s))
	if imgui.Button("Delete") do sculpt.sculptor_morph_clear(s)
	imgui.EndDisabled()
	imgui.SameLine()
	if s != nil && sculpt.sculptor_has_morph(s) {
		imgui.TextDisabled("stored for this level")
	} else {
		imgui.TextDisabled("none")
	}
	imgui.TextDisabled("Store keeps the surface as it is now; the Morph brush\nthen brings any part back to it. One per level, not\nsaved with the scene; not with dynamic topology.")
}

// Dynamic topology for the selected object, and the detail its brushes add.
@(private = "file")
draw_dyntopo_section :: proc(app: ^App) {
	imgui.SeparatorText("Dynamic topology")
	obj := selected_object(app)
	on := obj != nil && object_dynamic(obj)
	can := obj != nil && len(obj.levels.levels) == 1 && obj.levels.hd.steps == 0
	imgui.BeginDisabled(!can)
	if imgui.Checkbox("On for the selected object (Ctrl+T)", &on) do app.ui.scene_command = {kind = .Dyntopo, on = on}
	imgui.EndDisabled()
	if obj != nil && !can {
		imgui.TextDisabled("Needs a single subdivision level and no HD level.")
	}
	imgui.SliderFloat("Detail (px)", &app.brush.detail_px, 2, 40, "%.1f", {.Logarithmic})
	imgui.Checkbox("Collapse short edges", &app.brush.collapse)
	imgui.TextDisabled("Brushes add triangles where they go: edges under\nthe brush longer than Detail on screen split, and\nwith collapse, much shorter ones merge. Turning it\non or off is an undo step of its own.")
	if !on do return
	splits, collapses := sculpt.sculptor_dyn_edits(object_sculptor(obj))
	imgui.TextDisabled("%s", fmt.ctprintf("%s splits, %s collapses so far; %d GPU regrows", count_label(splits), count_label(collapses), app.stats.gpu_regrows))
	if s := app.stats; s.dyntopo_ms > 0 {
		imgui.TextDisabled("Turned on in %.0f ms, uploaded in %.0f ms", s.dyntopo_ms, s.dyntopo_upload_ms)
	}
}

@(private = "file")
draw_scene_panel :: proc(app: ^App) {
	defer imgui.End()
	if !imgui.Begin("Scene") do return
	scene := &app.scene

	total: int
	for obj in scene.objects do total += object_vertex_count(obj)
	imgui.Text("%d object%s, %d vertices shown", i32(len(scene.objects)), cstring("" if len(scene.objects) == 1 else "s"), i32(total))
	if imgui.BeginListBox("##objects", {-1, 4.25 * imgui.GetTextLineHeightWithSpacing()}) {
		for obj, i in scene.objects {
			levels := ""
			if n := len(obj.levels.levels); n > 1 do levels = fmt.tprintf(", level %d of %d", obj.levels.current + 1, n)
			if object_dynamic(obj) do levels = ", dynamic"
			label := fmt.ctprintf("%s  (%s vertices%s)##%d", object_label(obj), count_label(object_vertex_count(obj)), levels, obj.id)
			if imgui.Selectable(label, i == scene.selected) do scene.selected = i
		}
		imgui.EndListBox()
	}

	if obj := selected_object(app); obj != nil {
		imgui.SeparatorText(fmt.ctprintf("%s", object_label(obj)))
		imgui.DragFloat3("Position", &obj.transform.position, 0.01, 0, 0, "%.3f")
		if imgui.DragFloat3("Rotation (°)", &obj.transform.rotation, 0.5, 0, 0, "%.1f") {
			for &a in obj.transform.rotation do a = math.mod(a + 540, 360) - 180
		}
		imgui.DragFloat("Scale", &obj.transform.scale, 0.005, 0.01, 100, "%.3f", {.Logarithmic})
		obj.transform.scale = clamp(obj.transform.scale, 0.01, 100)
		imgui.Text("%d vertices, %d triangles", i32(object_vertex_count(obj)), i32(object_triangle_count(obj)))
		draw_levels_section(app, obj)
	}

	imgui.SeparatorText("New object and remesh")
	imgui.SetNextItemWidth(-90)
	imgui.InputInt("Vertices", &app.ui.sphere_vertices, 10_000, 1_000_000)
	app.ui.sphere_vertices = clamp(app.ui.sphere_vertices, MIN_SPHERE_VERTICES, MAX_SPHERE_VERTICES)
	for preset, i in SPHERE_PRESETS {
		if i > 0 do imgui.SameLine()
		if imgui.SmallButton(preset.label) do app.ui.sphere_vertices = preset.vertices
	}
	// Geodesic spheres come in steps of 10*f^2 + 2 vertices; show what will be built.
	f := geom.geodesic_frequency_for(int(app.ui.sphere_vertices))
	actual := 10 * f * f + 2 if app.ui.add_shape == .Sphere else int(app.ui.sphere_vertices)
	imgui.TextDisabled("%s %d vertices, about %s of memory", cstring("Builds") if app.ui.add_shape == .Sphere else cstring("Builds about"), i32(actual), fmt.ctprintf("%s", bytes_label(actual * BYTES_PER_VERTEX)))

	requested := int(app.ui.sphere_vertices)
	imgui.SetNextItemWidth(110)
	if imgui.BeginCombo("##shape", fmt.ctprintf("%v", app.ui.add_shape)) {
		for shape in geom.Primitive {
			if imgui.Selectable(fmt.ctprintf("%v", shape), shape == app.ui.add_shape) do app.ui.add_shape = shape
		}
		imgui.EndCombo()
	}
	imgui.SameLine()
	if imgui.Button(fmt.ctprintf("Add %v", app.ui.add_shape)) do app.ui.scene_command = {kind = .Add, vertices = requested, shape = app.ui.add_shape}
	imgui.SameLine()
	imgui.BeginDisabled(selected_object(app) == nil)
	if imgui.Button("Remesh selected") do app.ui.scene_command = {kind = .Remesh, vertices = requested}
	imgui.SameLine()
	if imgui.Button("Decimate selected") do app.ui.scene_command = {kind = .Decimate, vertices = requested}
	if imgui.IsItemHovered() do imgui.SetTooltip("Keeps the shape with about this many vertices: dense where\nthe detail is, sparse where it is flat. For export; levels,\nHD detail and mask go (Ctrl+Z brings them back).")
	if imgui.Button("Delete selected (Del)") do app.ui.scene_command = {kind = .Delete}
	if imgui.Button("Duplicate selected (Ctrl+Shift+D)") do app.ui.scene_command = {kind = .Duplicate}
	imgui.EndDisabled()
	imgui.TextDisabled("Remesh rebuilds the selected object as an even mesh of\nabout this many vertices that keeps its shape, like\nDynaMesh. Ctrl+R does it at the object's own vertex\ncount. Levels, HD detail and mask go; Ctrl+Z brings\nthem back (HD detail apart).")
	if s := app.stats; s.remesh_ms > 0 {
		imgui.TextDisabled("Last remesh: %.0f ms, then %.0f ms to sculpt-ready", s.remesh_ms, s.remesh_setup_ms)
	}
	if s := app.stats; s.decimate_ms > 0 {
		imgui.TextDisabled("Last decimate: %.0f ms, strays at most %.4f", s.decimate_ms, s.decimate_error)
	}
	draw_retopo_section(app)

	imgui.SeparatorText("Mirror and weld")
	imgui.BeginDisabled(selected_object(app) == nil)
	for name, i in ([3]cstring{"X", "Y", "Z"}) {
		if i > 0 do imgui.SameLine()
		if imgui.RadioButton(name, app.ui.mirror_axis == i32(i)) do app.ui.mirror_axis = i32(i)
	}
	imgui.SameLine()
	imgui.Checkbox("keep the - side", &app.ui.mirror_negative)
	if imgui.Button("Mirror and weld") do app.ui.scene_command = {kind = .Symmetrize, axis = int(app.ui.mirror_axis), on = !app.ui.mirror_negative}
	imgui.EndDisabled()
	imgui.TextDisabled("Replaces one half of the selected object with a mirror\nimage of the other, across its own plane (the one\nsymmetry uses), welded along the cut. Levels and\nmask go; Ctrl+Z brings them back.")
	// Opening a scene counts building it as reading; importing parses apart.
	if s := app.stats; s.file_read_ms > 0 || s.file_write_ms > 0 {
		parts := make([dynamic]string, context.temp_allocator)
		if s.file_read_ms > 0 do append(&parts, fmt.tprintf("read in %.0f ms", s.file_read_ms))
		if s.file_parse_ms > 0 do append(&parts, fmt.tprintf("parsed in %.0f ms", s.file_parse_ms))
		if s.file_write_ms > 0 do append(&parts, fmt.tprintf("written in %.0f ms", s.file_write_ms))
		imgui.TextDisabled("%s", fmt.ctprintf("Last file %s", strings.join(parts[:], ", ", context.temp_allocator)))
	}
}

// Subdivision levels of the selected object, numbered from 1 as in ZBrush.
@(private = "file")
draw_levels_section :: proc(app: ^App, obj: ^Object) {
	levels := &obj.levels
	count := len(levels.levels)
	imgui.SeparatorText("Subdivision levels")
	level := i32(levels.current + 1)
	imgui.BeginDisabled(count < 2)
	imgui.SetNextItemWidth(-90)
	if imgui.SliderInt("Level", &level, 1, i32(max(count, 2)), fmt.ctprintf("%%d of %d", count)) {
		app.ui.scene_command = {kind = .Set_Level, level = int(level) - 1}
	}
	imgui.EndDisabled()

	dyntopo := object_dynamic(obj)
	vertices, _, bytes := sculpt.levels_subdivide_estimate(levels)
	imgui.BeginDisabled(count >= sculpt.MAX_LEVELS || bytes > MAX_SUBDIVIDE_BYTES || levels.hd.steps > 0 || dyntopo)
	if imgui.Button("Subdivide") do app.ui.scene_command = {kind = .Subdivide}
	imgui.EndDisabled()
	imgui.SameLine()
	if dyntopo {
		imgui.TextDisabled("(turn dynamic topology off first)")
	} else if levels.hd.steps > 0 {
		imgui.TextDisabled("(delete the HD level first)")
	} else {
		imgui.TextDisabled("%s", fmt.ctprintf("adds a level of %s vertices, about %s", count_label(vertices), bytes_label(bytes)))
	}
	imgui.BeginDisabled(levels.current == 0)
	if imgui.Button("Delete lower") do app.ui.scene_command = {kind = .Delete_Lower}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.BeginDisabled(levels.current == count - 1)
	if imgui.Button("Delete higher") do app.ui.scene_command = {kind = .Delete_Higher}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.TextDisabled("(Ctrl+Z undoes it)")
	imgui.TextDisabled("Ctrl+D subdivides; D and Shift+D go up and down.\nAll levels use %s of memory.", fmt.ctprintf("%s", bytes_label(sculpt.levels_bytes(levels))))
	if s := app.stats; s.level_sync_ms + s.level_show_ms > 0 {
		imgui.TextDisabled("Last change: %.0f ms to update levels, %.0f ms to show", s.level_sync_ms, s.level_show_ms)
	}
	draw_hd_section(app, obj)
}

// HD detail above the top level, sculpted a window at a time, as in ZBrush.
@(private = "file")
draw_hd_section :: proc(app: ^App, obj: ^Object) {
	levels := &obj.levels
	hd := sculpt.levels_hd_stats(levels)
	steps := levels.hd.steps
	imgui.SeparatorText("HD detail")
	imgui.BeginDisabled(steps >= sculpt.HD_MAX_STEPS || hd.stored_nodes > 0 || object_dynamic(obj))
	if imgui.Button("Divide HD") do app.ui.scene_command = {kind = .Hd_Steps, level = steps + 1}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.BeginDisabled(steps == 0)
	if imgui.Button("Delete HD") do app.ui.scene_command = {kind = .Hd_Delete}
	imgui.EndDisabled()
	imgui.SameLine()
	if steps == 0 {
		imgui.TextDisabled("(sculpt finer than the top level)")
		return
	}
	imgui.TextDisabled("%s", fmt.ctprintf("%d step%s up: %s vertices", steps, "" if steps == 1 else "s", count_label(sculpt.levels_hd_vertices(levels))))
	if object_in_hd(obj) {
		if imgui.Button("Leave HD (A)") do app.ui.scene_command = {kind = .Hd_Leave}
		imgui.SameLine()
		imgui.TextDisabled("%s", fmt.ctprintf("window of %s vertices, opened in %.0f + %.0f ms", count_label(hd.window_vertices), app.stats.hd_open_ms, app.stats.hd_upload_ms))
	} else {
		// From the button, the window opens around the middle of the viewport.
		if imgui.Button("Sculpt HD (A)") do app.ui.scene_command = {kind = .Hd_Enter, at = app.ui.viewport_size * 0.5, size = app.ui.viewport_size}
		imgui.SameLine()
		imgui.TextDisabled("A opens a window where the pointer is")
	}
	millions := i32(app.hd_window_vertices / 1_000_000)
	imgui.SetNextItemWidth(-140)
	if imgui.SliderInt("Window (M vertices)", &millions, 1, 16) do app.hd_window_vertices = int(millions) * 1_000_000
	imgui.TextDisabled("%s", fmt.ctprintf("Stored: %d of %d top-level nodes, %s. Leaving a window stores it.", hd.stored_nodes, len(levels.levels[len(levels.levels) - 1].sculptor.nodes), bytes_label(hd.stored_bytes)))
	if hd.stored_nodes > 0 do imgui.TextDisabled("Saving the scene keeps the HD steps but not this detail.")
	if app.stats.hd_leave_ms > 0 do imgui.TextDisabled("Last window stored in %.0f ms", app.stats.hd_leave_ms)
}

@(private = "file")
handle_shortcuts :: proc(app: ^App) {
	io := imgui.GetIO()
	if io.WantTextInput do return
	if io.KeyCtrl && imgui.IsKeyPressed(.Z, true) {
		if io.KeyShift do history_redo(app)
		else do history_undo(app)
	}
	if io.KeyCtrl && imgui.IsKeyPressed(.Y, true) do history_redo(app)
	if io.KeyCtrl && imgui.IsKeyPressed(.S, false) {
		if io.KeyShift do file_dialog(app, .Save)
		else do save_scene(app)
	}
	if io.KeyCtrl && imgui.IsKeyPressed(.O, false) do file_dialog(app, .Open)
	if imgui.IsKeyPressed(.F12, false) do file_dialog(app, .Screenshot)
	if imgui.IsKeyPressed(.W, false) {
		switch {
		case io.KeyCtrl:
			group_shortcut(app)
		case io.KeyShift:
			app.show_groups = !app.show_groups
		case !io.KeyAlt:
			app.tool = .Move
		}
	}
	if imgui.IsKeyPressed(.B, false) do app.tool = .Brush
	if !io.KeyCtrl && !io.KeyAlt {
		// 1 to 9 and 0 pick the brushes in the order the Tools panel lists them.
		for kind, i in sculpt.Brush_Kind {
			if i >= 10 do break
			if imgui.IsKeyPressed(imgui.Key._0 if i == 9 else imgui.Key(int(imgui.Key._1) + i), false) {
				app.brush.kind = kind
				app.tool = .Brush
			}
		}
		if imgui.IsKeyPressed(.X, false) do app.brush.symmetry ~= {.X}
		// [ and ] step the size by a sixth, Shift with them the strength by 0.05.
		for key, i in ([2]imgui.Key{.LeftBracket, .RightBracket}) {
			if !imgui.IsKeyPressed(key, true) do continue
			up := i == 1
			if io.KeyShift {
				s := brush_strength(app)
				s^ = clamp(s^ + (0.05 if up else -0.05), MIN_STRENGTH, 1)
			} else {
				app.brush.radius_px = clamp(app.brush.radius_px * (7.0 / 6 if up else 6.0 / 7), MIN_RADIUS_PX, MAX_RADIUS_PX)
			}
		}
	}
	if io.KeyAlt && imgui.IsKeyPressed(.M, false) do mask_command(app, .Clear)
	if obj := selected_object(app); obj != nil && io.KeyCtrl && imgui.IsKeyPressed(.R, false) {
		app.ui.scene_command = {kind = .Remesh, vertices = object_vertex_count(obj)}
	}
	if obj := selected_object(app); obj != nil && io.KeyCtrl && imgui.IsKeyPressed(.T, false) {
		app.ui.scene_command = {kind = .Dyntopo, on = !object_dynamic(obj)}
	}
	if io.KeyCtrl && imgui.IsKeyPressed(.I, false) do mask_command(app, .Invert)
	// Ctrl+H shows everything again and Ctrl+Shift+H swaps hidden and shown.
	if io.KeyCtrl && imgui.IsKeyPressed(.H, false) do hide_command(app, .Invert if io.KeyShift else .Show_All)
	// The keypad's 1, 3 and 7 look from the front, right and top, and with Ctrl from the
	// opposite side, as in Blender.
	for key, i in ([3]imgui.Key{.Keypad1, .Keypad3, .Keypad7}) {
		if !imgui.IsKeyPressed(key, false) do continue
		views := [3][2]camera.Axis_View{{.Front, .Back}, {.Right, .Left}, {.Top, .Bottom}}
		camera.orbit_axis_view(&app.camera, views[i][1 if io.KeyCtrl else 0])
	}
	// P (ZBrush's Persp toggle) or the keypad's 5 (Blender's) switches parallel projection.
	if (imgui.IsKeyPressed(.P, false) && !io.KeyCtrl) || imgui.IsKeyPressed(.Keypad5, false) do app.camera.ortho = !app.camera.ortho
	if imgui.IsKeyPressed(.F, false) {
		// Shift+F shows the edges, as ZBrush's PolyFrame; F alone frames the selection.
		if io.KeyShift {
			app.wireframe = !app.wireframe
		} else {
			focus_selected(app)
		}
	}
	// Shift+R, as ZBrush's BPR render, switches the studio render.
	if imgui.IsKeyPressed(.R, false) && io.KeyShift && !io.KeyCtrl do studio_toggle(app)
	// Shift+G shows the triangles as flat facets, beside Shift+F's wireframe.
	if imgui.IsKeyPressed(.G, false) && io.KeyShift && !io.KeyCtrl do app.flat = !app.flat
	// Delete removes the selected object; Ctrl+Z brings it back.
	if imgui.IsKeyPressed(.Delete, false) && selected_object(app) != nil do app.ui.scene_command = {kind = .Delete}
	if imgui.IsKeyPressed(.A, false) && !io.KeyCtrl {
		// Toggles HD sculpting: a window opens where the pointer is, on the object there.
		if obj := selected_object(app); obj != nil && object_in_hd(obj) {
			app.ui.scene_command = {kind = .Hd_Leave}
		} else if app.ui.viewport_hovered {
			app.ui.scene_command = {kind = .Hd_Enter, at = app.ui.viewport_mouse, size = app.ui.viewport_size}
		}
	}
	if obj := selected_object(app); obj != nil && imgui.IsKeyPressed(.D, false) {
		switch {
		case io.KeyCtrl && io.KeyShift:
			app.ui.scene_command = {kind = .Duplicate}
		case io.KeyCtrl:
			app.ui.scene_command = {kind = .Subdivide}
		case io.KeyShift:
			app.ui.scene_command = {kind = .Set_Level, level = obj.levels.current - 1}
		case:
			app.ui.scene_command = {kind = .Set_Level, level = obj.levels.current + 1}
		}
	}
}

@(private = "file")
count_label :: proc(n: int) -> string {
	switch {
	case n >= 1_000_000:
		return fmt.tprintf("%.1fM", f64(n) / 1e6)
	case n >= 1_000:
		return fmt.tprintf("%dk", n / 1000)
	}
	return fmt.tprintf("%d", n)
}

@(private = "file")
bytes_label :: proc(n: int) -> string {
	if n >= 1 << 30 do return fmt.tprintf("%.1f GB", f64(n) / f64(1 << 30))
	return fmt.tprintf("%d MB", max(n >> 20, 1))
}

@(private = "file")
draw_stats_panel :: proc(app: ^App) {
	defer imgui.End()
	if !imgui.Begin("Stats") do return
	s := &app.stats
	row :: proc(label: cstring, r: Sample_Ring, unit: cstring) {
		p50, p99 := ring_percentiles(r)
		imgui.Text("%-14s p50 %7.2f  p99 %7.2f %s", label, p50, p99, unit)
	}
	row("Frame", s.frame_ms, "ms")
	row("CPU", s.cpu_ms, "ms")
	if app.time_gpu do row("GPU (3D)", s.gpu_ms, "ms")
	row("Display wait", s.wait_ms, "ms")
	imgui.PlotLines("##frame_ms", &s.frame_ms.values[0], HISTORY, i32(s.frame_ms.head), "frame ms", 0, 33.3, {0, 80})
	imgui.Checkbox("VSync", &app.vsync)
	imgui.SameLine()
	switch app.renderer.present_mode {
	case .VSYNC:
		imgui.TextDisabled("(frame rate capped at the display's)")
	case .MAILBOX:
		imgui.TextDisabled("(off: mailbox)")
	case .IMMEDIATE:
		imgui.TextDisabled("(off: immediate, may tear)")
	}
	if imgui.Checkbox("Time GPU work", &app.time_gpu) do s.gpu_ms = {}
	imgui.SameLine()
	imgui.TextDisabled("(waits for the GPU every frame)")
	v := s.viewport
	imgui.Text("Triangles drawn %s in %d draws", fmt.ctprintf("%s", count_label(int(v.triangles))), i32(v.draws))
	imgui.Checkbox("Redraw only changes", &app.renderer.partial)
	imgui.SameLine()
	if v.partial {
		imgui.TextDisabled("(last frame: %.1f%% of the viewport)", 100 * f64(v.redrawn_px) / f64(max(app.target.width * app.target.height, 1)))
	} else {
		imgui.TextDisabled("(last frame: full redraw)")
	}
	imgui.Checkbox("Skip hidden chunks", &app.renderer.cull)
	imgui.SameLine()
	imgui.TextDisabled("(%d off, %d back, %.2f ms)", i32(v.culled_view), i32(v.culled_back), v.cull_ms)
	imgui.Checkbox("Cache idle objects", &app.cache_idle)
	imgui.SameLine()
	imgui.TextDisabled("(%s, redrawn %d times)", cstring("in use" if s.viewport.cache_used else "not in use"), i32(s.cache_redraws))
	imgui.Checkbox("Simplify while moving", &app.simplify)
	imgui.SameLine()
	pending := 0
	for obj in app.scene.objects do pending += sculpt.sculptor_lod_pending(object_sculptor(obj))
	if pending > 0 && app.simplify {
		imgui.TextDisabled("(%d groups to build)", i32(pending))
	} else {
		imgui.TextDisabled("(last frame: %d groups simplified)", i32(v.simplified))
	}
	if app.simplify {
		imgui.SetNextItemWidth(160)
		imgui.SliderFloat("Largest error (px)", &app.simplify_px, 0.25, 4, "%.2f")
		row("Build", s.lod_ms, "ms")
	}
	imgui.SeparatorText("While sculpting")
	row("Raycast", s.raycast_ms, "ms")
	row("Brush", s.brush_ms, "ms")
	row("Normals", s.normals_ms, "ms")
	row("Upload", s.upload_kb, "KB")
	row("Input->submit", s.latency_ms, "ms")
	imgui.Text("Dabs %d   Viewport %d x %d px", i32(s.dabs_total), i32(app.target.width), i32(app.target.height))
	undo_bytes := 0
	for obj in app.scene.objects {
		for lv in obj.levels.levels do undo_bytes += sculpt.sculptor_undo_bytes(&lv.sculptor)
		if w := obj.levels.hd.window; w != nil do undo_bytes += sculpt.sculptor_undo_bytes(&w.sculptor)
	}
	imgui.Text("Undo %d steps, %.1f MB of strokes, %.1f MB of object snapshots", i32(len(app.history.done)), f64(undo_bytes) / (1 << 20), f64(app.history.swap_bytes) / (1 << 20))
}

// Whole-mesh smoothing, and the switch that runs it on the GPU instead.
@(private = "file")
draw_deformation_section :: proc(app: ^App) {
	imgui.SeparatorText("Deformation")
	obj := selected_object(app)
	imgui.BeginDisabled(obj == nil || object_dynamic(obj))
	if imgui.Button("Smooth all") do smooth_command(app, int(app.ui.smooth_steps))
	if imgui.IsItemHovered() do imgui.SetTooltip("Smooths the whole selected object, each step moving\nevery vertex toward its neighbours' average, as the\nSmooth brush does under it. Masked areas stay. One\nundo step. Not with dynamic topology.")
	imgui.SameLine()
	imgui.Checkbox("On the GPU", &app.ui.smooth_on_gpu)
	if imgui.IsItemHovered() do imgui.SetTooltip("Runs the steps as a compute shader instead of on\nevery CPU core: a trial of GPU sculpting. The result\nmatches the CPU's to rounding. The times below show\nwhat the upload and readback cost.")
	imgui.SliderInt("Smooth steps", &app.ui.smooth_steps, 1, 100)
	imgui.SliderFloat("Smooth strength", &app.ui.smooth_strength, 0.05, 1, "%.2f")
	imgui.EndDisabled()
	if last := app.ui.smooth_last; last.set {
		outcome := "" if last.changed else ", nothing changed"
		imgui.TextDisabled("%s", fmt.ctprintf("Last: %d steps on the %s in %.0f ms%s", last.steps, "GPU" if last.on_gpu else "CPU", last.ms, outcome))
		if last.on_gpu {
			g := last.gpu
			imgui.TextDisabled("%s", fmt.ctprintf("GPU: upload %.1f ms (%.0f MB), compute %.1f ms,\nreadback %.1f ms", g.upload_ms, g.upload_mb, g.compute_ms, g.readback_ms))
		}
	}
}
