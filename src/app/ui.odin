package main

import "core:fmt"

import imgui "deps:odin-imgui"

import "../camera"
import "../geom"
import "../gizmo"
import "../sculpt"

// UI-only state. Sculpt and render state live in App; panels edit them through pointers
// handed over each frame and never keep references between frames.
Ui_State :: struct {
	viewport_request: [2]f32, // pixel size the viewport panel wants its render target to be
	layout_built:     bool,
	show_demo:        bool,
	sphere_vertices:  i32, // vertex count typed into the Scene panel for Add and Remesh
	// Set by the Scene panel; the app applies it at the start of the next frame.
	scene_command:    Scene_Command,
	// Where the viewport image was drawn this frame, so the overlay (brush circle,
	// gizmo) can be added after the tools have run.
	viewport_draw_list: ^imgui.DrawList,
	viewport_origin:    imgui.Vec2,
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
	samples:     []Input_Sample, // every pointer sample this frame, oldest first
}

ui_state_default :: proc() -> Ui_State {
	return {viewport_request = {1280, 720}, sphere_vertices = 500_000}
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
	right: imgui.ID
	main := dockspace
	imgui.DockBuilderSplitNode(main, .Right, 0.24, &right, &main)
	right_bottom, right_middle: imgui.ID
	imgui.DockBuilderSplitNode(right, .Down, 0.66, &right_bottom, &right)
	imgui.DockBuilderSplitNode(right_bottom, .Down, 0.4, &right_bottom, &right_middle)
	imgui.DockBuilderDockWindow("Viewport", main)
	imgui.DockBuilderDockWindow("Tools", right)
	imgui.DockBuilderDockWindow("Scene", right_middle)
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
	if imgui.BeginMenu("Edit") {
		if imgui.MenuItem("Undo stroke", "Ctrl+Z", false, history_can_undo(app)) do history_undo(app)
		if imgui.MenuItem("Redo stroke", "Ctrl+Shift+Z", false, history_can_redo(app)) do history_redo(app)
		imgui.EndMenu()
	}
	if imgui.BeginMenu("View") {
		if imgui.MenuItem("Reset camera") do app.camera = camera.orbit_default()
		if imgui.MenuItem("Focus selected", "F") do focus_selected(app)
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
	input.samples = make([]Input_Sample, len(app.samples), context.temp_allocator)
	for s, i in app.samples do input.samples[i] = {s.pos - {origin.x, origin.y}, s.pressure, s.kind}
	input.mouse_delta = {io.MouseDelta.x, io.MouseDelta.y}
	input.wheel = io.MouseWheel

	left := imgui.IsMouseDown(.Left)
	right := imgui.IsMouseDown(.Right)
	middle := imgui.IsMouseDown(.Middle)
	if input.dragging {
		input.orbit_drag = (right && !io.KeyShift) || (left && io.KeyAlt)
		input.pan_drag = middle || (right && io.KeyShift)
		input.primary = left && !io.KeyAlt
		input.press = input.primary && imgui.IsMouseClicked(.Left)
		input.smooth = input.primary && io.KeyShift
		input.invert = input.primary && io.KeyCtrl
	}
	app.ui.viewport_draw_list = imgui.GetWindowDrawList()
	app.ui.viewport_origin = origin
	return
}

// Draws the brush circle or the move gizmo over the viewport image. Runs after the
// tools have handled this frame's input, so the overlay matches what gets rendered.
draw_viewport_overlay :: proc(app: ^App, input: Viewport_Input) {
	list := app.ui.viewport_draw_list
	if list == nil do return
	app.ui.viewport_draw_list = nil
	o := app.ui.viewport_origin
	imgui.DrawList_PushClipRect(list, o, o + input.size)
	defer imgui.DrawList_PopClipRect(list)
	rgba :: proc(c: [4]f32) -> u32 {return imgui.ColorConvertFloat4ToU32(c)}

	switch app.tool {
	case .Brush:
		if input.hovered || input.dragging {
			color := rgba({1, 1, 1, 0.6} if !input.primary else {1, 0.8, 0.4, 0.9})
			center := input.mouse_pos
			if app.stroke.active && app.brush.lazy_px > 0 {
				// The brush trails the cursor: draw it where it is, on its string.
				center = app.stroke.pos
				imgui.DrawList_AddLine(list, o + center, o + input.mouse_pos, color, 1)
			}
			imgui.DrawList_AddCircle(list, o + center, app.brush.radius_px, color, 48, 1.5)
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
		imgui.TextDisabled("Left drag sculpts the object under the cursor.\nShift smooths, Ctrl inverts.")
	}

	imgui.SeparatorText("Brush")
	if imgui.RadioButton("Draw", app.brush.kind == .Draw) do app.brush.kind = .Draw
	imgui.SameLine()
	if imgui.RadioButton("Smooth", app.brush.kind == .Smooth) do app.brush.kind = .Smooth
	imgui.SliderFloat("Radius (px)", &app.brush.radius_px, 5, 300, "%.0f")
	imgui.SliderFloat("Strength", &app.brush.strength, 0.01, 1, "%.2f")
	imgui.SliderFloat("Lazy mouse (px)", &app.brush.lazy_px, 0, 150, "%.0f")
	imgui.Checkbox("Pressure sets strength", &app.brush.pressure_strength)
	imgui.Checkbox("Pressure sets size", &app.brush.pressure_size)
	if app.pen_seen {
		imgui.TextDisabled("Pen pressure %.2f", app.pen_pressure)
	} else {
		imgui.TextDisabled("No pen seen yet; a mouse always has full pressure.")
	}

	imgui.SeparatorText("Camera")
	imgui.Text("Orbit: right drag, or Alt + left drag")
	imgui.Text("Pan: middle drag, or Shift + right drag")
	imgui.Text("Zoom: mouse wheel.  Focus selected: F")
	imgui.SliderFloat("Distance", &app.camera.distance, camera.MIN_DISTANCE, 20, "%.2f", {.Logarithmic})
	if imgui.Button("Reset camera") do app.camera = camera.orbit_default()
}

@(private = "file")
draw_scene_panel :: proc(app: ^App) {
	defer imgui.End()
	if !imgui.Begin("Scene") do return
	scene := &app.scene

	total: int
	for obj in scene.objects do total += geom.mesh_vertex_count(object_mesh(obj)^)
	imgui.Text("%d object%s, %d vertices shown", i32(len(scene.objects)), cstring("" if len(scene.objects) == 1 else "s"), i32(total))
	if imgui.BeginListBox("##objects", {-1, 4.25 * imgui.GetTextLineHeightWithSpacing()}) {
		for obj, i in scene.objects {
			levels := ""
			if n := len(obj.levels.levels); n > 1 do levels = fmt.tprintf(", level %d of %d", obj.levels.current + 1, n)
			label := fmt.ctprintf("Sphere %d  (%s vertices%s)", obj.id, count_label(geom.mesh_vertex_count(object_mesh(obj)^)), levels)
			if imgui.Selectable(label, i == scene.selected) do scene.selected = i
		}
		imgui.EndListBox()
	}

	if obj := selected_object(app); obj != nil {
		imgui.SeparatorText(fmt.ctprintf("Sphere %d", obj.id))
		imgui.DragFloat3("Position", &obj.transform.position, 0.01, 0, 0, "%.3f")
		imgui.DragFloat("Scale", &obj.transform.scale, 0.005, 0.01, 100, "%.3f", {.Logarithmic})
		obj.transform.scale = clamp(obj.transform.scale, 0.01, 100)
		imgui.Text("%d vertices, %d triangles", i32(geom.mesh_vertex_count(object_mesh(obj)^)), i32(geom.mesh_triangle_count(object_mesh(obj)^)))
		draw_levels_section(app, obj)
	}

	imgui.SeparatorText("Sphere resolution")
	imgui.SetNextItemWidth(-90)
	imgui.InputInt("Vertices", &app.ui.sphere_vertices, 10_000, 1_000_000)
	app.ui.sphere_vertices = clamp(app.ui.sphere_vertices, MIN_SPHERE_VERTICES, MAX_SPHERE_VERTICES)
	for preset, i in SPHERE_PRESETS {
		if i > 0 do imgui.SameLine()
		if imgui.SmallButton(preset.label) do app.ui.sphere_vertices = preset.vertices
	}
	// Geodesic spheres come in steps of 10*f^2 + 2 vertices; show what will be built.
	f := geom.geodesic_frequency_for(int(app.ui.sphere_vertices))
	actual := 10 * f * f + 2
	imgui.TextDisabled("Builds %d vertices, about %s of memory", i32(actual), fmt.ctprintf("%s", bytes_label(actual * BYTES_PER_VERTEX)))

	requested := int(app.ui.sphere_vertices)
	if imgui.Button("Add sphere") do app.ui.scene_command = {kind = .Add, vertices = requested}
	imgui.SameLine()
	imgui.BeginDisabled(selected_object(app) == nil)
	if imgui.Button("Remesh selected") do app.ui.scene_command = {kind = .Remesh, vertices = requested}
	imgui.SameLine()
	if imgui.Button("Delete selected") do app.ui.scene_command = {kind = .Delete}
	imgui.EndDisabled()
	imgui.TextDisabled("Remesh rebuilds the sphere at this count, with one\nlevel; sculpted detail is not kept yet.")
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

	vertices, _, bytes := sculpt.levels_subdivide_estimate(levels)
	imgui.BeginDisabled(count >= sculpt.MAX_LEVELS || bytes > MAX_SUBDIVIDE_BYTES)
	if imgui.Button("Subdivide") do app.ui.scene_command = {kind = .Subdivide}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.TextDisabled("%s", fmt.ctprintf("adds a level of %s vertices, about %s", count_label(vertices), bytes_label(bytes)))
	imgui.BeginDisabled(levels.current == 0)
	if imgui.Button("Delete lower") do app.ui.scene_command = {kind = .Delete_Lower}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.BeginDisabled(levels.current == count - 1)
	if imgui.Button("Delete higher") do app.ui.scene_command = {kind = .Delete_Higher}
	imgui.EndDisabled()
	imgui.SameLine()
	imgui.TextDisabled("(clears its undo)")
	imgui.TextDisabled("Ctrl+D subdivides; D and Shift+D go up and down.\nAll levels use %s of memory.", fmt.ctprintf("%s", bytes_label(sculpt.levels_bytes(levels))))
	if s := app.stats; s.level_sync_ms + s.level_show_ms > 0 {
		imgui.TextDisabled("Last change: %.0f ms to update levels, %.0f ms to show", s.level_sync_ms, s.level_show_ms)
	}
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
	if imgui.IsKeyPressed(.W, false) do app.tool = .Move
	if imgui.IsKeyPressed(.B, false) do app.tool = .Brush
	if imgui.IsKeyPressed(.F, false) do focus_selected(app)
	if obj := selected_object(app); obj != nil && imgui.IsKeyPressed(.D, false) {
		switch {
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
	imgui.SeparatorText("While sculpting")
	row("Raycast", s.raycast_ms, "ms")
	row("Brush", s.brush_ms, "ms")
	row("Normals", s.normals_ms, "ms")
	row("Upload", s.upload_kb, "KB")
	row("Input->submit", s.latency_ms, "ms")
	imgui.Text("Dabs %d   Viewport %d x %d px", i32(s.dabs_total), i32(app.target.width), i32(app.target.height))
	undo_bytes := 0
	for obj in app.scene.objects do for lv in obj.levels.levels do undo_bytes += sculpt.sculptor_undo_bytes(&lv.sculptor)
	imgui.Text("Undo %d strokes, %.1f MB", i32(len(app.history.done)), f64(undo_bytes) / (1 << 20))
}
