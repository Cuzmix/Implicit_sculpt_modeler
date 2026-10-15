package main

import imgui "deps:odin-imgui"

import "../camera"
import "../geom"

// UI-only state. Sculpt and render state live in App; panels edit them through pointers
// handed over each frame and never keep references between frames.
Ui_State :: struct {
	viewport_request: [2]f32, // pixel size the viewport panel wants its render target to be
	layout_built:     bool,
	show_demo:        bool,
	mesh_choice:      i32,
	// Set by the Mesh panel; the app rebuilds the mesh at the start of the next frame.
	mesh_request:     Mesh_Request,
}

Mesh_Request :: struct {
	vertices: int,
	subdiv:   int,
}

MESH_SIZES := [?]struct {
	label:   cstring,
	request: Mesh_Request,
} {
	{"Icosphere 41k", {subdiv = 6}},
	{"500k vertices", {vertices = 500_000}},
	{"1M vertices", {vertices = 1_000_000}},
	{"5M vertices", {vertices = 5_000_000}},
	{"7M vertices", {vertices = 7_000_000}},
	{"10M vertices", {vertices = 10_000_000}},
	{"25M vertices", {vertices = 25_000_000}},
}

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
	stroke:      bool, // left mouse without Alt: sculpt
	smooth:      bool, // Shift held during a stroke: smooth brush
	invert:      bool, // Ctrl held during a stroke: invert the brush
}

ui_state_default :: proc() -> Ui_State {
	return {viewport_request = {1280, 720}}
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
	draw_stats_panel(app)
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
	right: imgui.ID
	main := dockspace
	imgui.DockBuilderSplitNode(main, .Right, 0.24, &right, &main)
	right_bottom: imgui.ID
	imgui.DockBuilderSplitNode(right, .Down, 0.5, &right_bottom, &right)
	imgui.DockBuilderDockWindow("Viewport", main)
	imgui.DockBuilderDockWindow("Tools", right)
	imgui.DockBuilderDockWindow("Stats", right_bottom)
	imgui.DockBuilderFinish(dockspace)
}

@(private = "file")
draw_menu_bar :: proc(app: ^App) {
	if !imgui.BeginMainMenuBar() do return
	defer imgui.EndMainMenuBar()
	if imgui.BeginMenu("File") {
		if imgui.MenuItem("Quit", "Alt+F4") do app.running = false
		imgui.EndMenu()
	}
	if imgui.BeginMenu("View") {
		if imgui.MenuItem("Reset camera") do app.camera = camera.orbit_default()
		if imgui.MenuItem("ImGui demo", nil, app.ui.show_demo) do app.ui.show_demo = !app.ui.show_demo
		imgui.EndMenu()
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
	imgui.Image(imgui.TextureRef{_TexID = imgui.TextureID(uintptr(app.target.color))}, avail)

	// An invisible button over the image captures mouse input so dragging in the
	// viewport never moves the window or leaks to panels underneath.
	imgui.SetCursorScreenPos(origin)
	imgui.InvisibleButton("viewport_input", avail, {.MouseButtonLeft, .MouseButtonRight, .MouseButtonMiddle})

	io := imgui.GetIO()
	input.size = {avail.x, avail.y}
	input.hovered = imgui.IsItemHovered()
	input.dragging = imgui.IsItemActive()
	input.mouse_pos = {io.MousePos.x - origin.x, io.MousePos.y - origin.y}
	input.mouse_delta = {io.MouseDelta.x, io.MouseDelta.y}
	input.wheel = io.MouseWheel

	left := imgui.IsMouseDown(.Left)
	right := imgui.IsMouseDown(.Right)
	middle := imgui.IsMouseDown(.Middle)
	if input.dragging {
		input.orbit_drag = (right && !io.KeyShift) || (left && io.KeyAlt)
		input.pan_drag = middle || (right && io.KeyShift)
		input.stroke = left && !io.KeyAlt
		input.smooth = input.stroke && io.KeyShift
		input.invert = input.stroke && io.KeyCtrl
	}
	if input.hovered || input.dragging {
		center := imgui.Vec2{io.MousePos.x, io.MousePos.y}
		color := imgui.ColorConvertFloat4ToU32({1, 1, 1, 0.6} if !input.stroke else {1, 0.8, 0.4, 0.9})
		imgui.DrawList_AddCircle(imgui.GetWindowDrawList(), center, app.brush.radius_px, color, 48, 1.5)
	}
	return
}

@(private = "file")
draw_tools_panel :: proc(app: ^App) {
	defer imgui.End()
	if !imgui.Begin("Tools") do return
	imgui.SeparatorText("Camera")
	imgui.Text("Orbit: right drag, or Alt + left drag")
	imgui.Text("Pan: middle drag, or Shift + right drag")
	imgui.Text("Zoom: mouse wheel")
	imgui.SliderFloat("Distance", &app.camera.distance, camera.MIN_DISTANCE, 20, "%.2f", {.Logarithmic})
	if imgui.Button("Reset camera") do app.camera = camera.orbit_default()

	imgui.SeparatorText("Brush")
	if imgui.RadioButton("Draw", app.brush.kind == .Draw) do app.brush.kind = .Draw
	imgui.SameLine()
	if imgui.RadioButton("Smooth", app.brush.kind == .Smooth) do app.brush.kind = .Smooth
	imgui.SliderFloat("Radius (px)", &app.brush.radius_px, 5, 300, "%.0f")
	imgui.SliderFloat("Strength", &app.brush.strength, 0.01, 1, "%.2f")
	imgui.TextDisabled("Left drag sculpts. Shift smooths, Ctrl inverts.")

	imgui.SeparatorText("Mesh")
	imgui.Text("Vertices:  %d", i32(geom.mesh_vertex_count(app.mesh)))
	imgui.Text("Triangles: %d", i32(geom.mesh_triangle_count(app.mesh)))
	if imgui.BeginCombo("Size", MESH_SIZES[app.ui.mesh_choice].label) {
		for size, i in MESH_SIZES {
			if imgui.Selectable(size.label, i32(i) == app.ui.mesh_choice) do app.ui.mesh_choice = i32(i)
		}
		imgui.EndCombo()
	}
	if imgui.Button("New sphere") do app.ui.mesh_request = MESH_SIZES[app.ui.mesh_choice].request
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
	row("CPU (UI)", s.cpu_ms, "ms")
	imgui.PlotLines("##frame_ms", &s.frame_ms.values[0], HISTORY, i32(s.frame_ms.head), "frame ms", 0, 33.3, {0, 80})
	imgui.SeparatorText("While sculpting")
	row("Raycast", s.raycast_ms, "ms")
	row("Brush", s.brush_ms, "ms")
	row("Normals", s.normals_ms, "ms")
	row("Upload", s.upload_kb, "KB")
	row("Input->submit", s.latency_ms, "ms")
	imgui.Text("Dabs %d   Viewport %d x %d px", i32(s.dabs_total), i32(app.target.width), i32(app.target.height))
}
