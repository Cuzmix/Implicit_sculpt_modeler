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
	stroke:      bool, // left mouse without modifiers: reserved for the brush
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
		input.stroke = left && !io.KeyAlt && !io.KeyShift && !io.KeyCtrl
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

	imgui.SeparatorText("Mesh")
	imgui.Text("Vertices:  %d", i32(geom.mesh_vertex_count(app.mesh)))
	imgui.Text("Triangles: %d", i32(geom.mesh_triangle_count(app.mesh)))
}

@(private = "file")
draw_stats_panel :: proc(app: ^App) {
	defer imgui.End()
	if !imgui.Begin("Stats") do return
	s := &app.stats
	p50, p99 := frame_stats_percentiles(s)
	imgui.Text("Frame  p50 %.2f ms   p99 %.2f ms", p50, p99)
	imgui.Text("CPU (events + UI) last %.2f ms", s.cpu_ms[(s.head + FRAME_HISTORY - 1) % FRAME_HISTORY])
	imgui.Text("Viewport %d x %d px", i32(app.target.width), i32(app.target.height))
	imgui.PlotLines("##frame_ms", &s.frame_ms[0], FRAME_HISTORY, i32(s.head), "frame ms", 0, 33.3, {0, 80})
}
