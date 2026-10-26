package main

import "core:flags"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
@(require) import "core:mem" // only used when ODIN_DEBUG
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../jobs"
import "../render"
import "../sculpt"
import "../ui"

Options :: struct {
	frames:    int `usage:"Exit after this many frames (0 runs until the window closes)."`,
	no_settings: bool `usage:"Neither read nor write the remembered settings (brush, view, Scene tab choices, the Settings panel); runs with --frames or a benchmark never do."`,
	settings_file: string `usage:"Read and write the remembered settings at this path instead of the per-user folder, scripted runs included (for testing that settings persist)."`,
	orbit_style: string `usage:"Start with this orbit style: free (ZBrush's Rot XYZ) or turntable (Rot Y), as Settings > Camera does."`,
	orbit_pivot: string `usage:"Start turning the view about this, as Settings > Camera > Turn about does: stroke (the middle of the last stroke, the default), pointer (the surface under the press) or centre (the middle of the view)."`,
	flat_ring: bool `usage:"Start with the brush ring flat on the screen instead of lying on the surface, as Settings > Interface > Lay the brush ring on the surface off does (for comparison)."`,
	no_edge_orbit: bool `usage:"Start with the safe zone off, as Settings > Camera > Edges always turn the view does: a press near an edge over the model goes to the tool."`,
	gpu_debug: bool `usage:"Create the GPU device in debug mode (enables validation where available)."`,
	subdiv:    int `usage:"Icosphere subdivision level (default 6)."`,
	vertices:  int `usage:"Start with a geodesic sphere of about this many vertices instead (e.g. 10000000)."`,
	shape:     string `usage:"Start with this shape instead of spheres: cube, cylinder, cone or torus (of --vertices vertices, 40962 when not given), as the Scene tab's Add object does."`,
	threads:   int `usage:"Worker threads for sculpting, including the main thread (default: one per core)."`,
	width:     int `usage:"Initial window width (default 1600)."`,
	height:    int `usage:"Initial window height (default 900)."`,
	spheres:   int `usage:"Start with this many spheres side by side, all of the starting size (default 1)."`,
	subdivide: int `usage:"Give each starting sphere this many subdivision levels above it, as Ctrl+D does (e.g. --vertices=40000 --subdivide=4 tops out at 10M)."`,
	level:     int `usage:"Start on this subdivision level, 1 being the base (default: the top one)."`,
	hd:        int `usage:"Give each starting sphere an HD level this many Loop steps (1 to 3) above its top level, as Divide HD does."`,
	hd_open:   bool `usage:"Start sculpting HD on the first sphere, in a window around the side facing the camera (needs --hd)."`,
	hd_window: int `usage:"Vertices an HD window holds (default 4000000)."`,
	no_cache:  bool `usage:"Draw every object every frame instead of caching the idle ones (for comparison)."`,
	no_cull:   bool `usage:"Draw every triangle instead of skipping off-screen and back-facing chunks (for comparison)."`,
	reduce_motion: bool `usage:"Start with the interface's animations off, as Menu > Reduce motion does."`,
	ui_dt:     f32 `usage:"Move the interface's clock (animations, tooltips, long presses) this many seconds a frame instead of by the time that passed, for scripted runs whose checks must not depend on how fast frames come (scripts/touch_check.py passes 1/60). The 90 ms a finger waits before it sculpts and the right tap that opens the pie stay on the real clock."`,
	finger_orbits: bool `usage:"Start with one finger on the model turning the view instead of sculpting, as Settings > Touch and pen > One finger on the model does."`,
	ui_events: string `usage:"Drive the pointer, fingers and pen as SDL events would, for tests: FRAME:move:X,Y, FRAME:down, FRAME:up, FRAME:right (a right click), FRAME:wheel:N, FRAME:key:NAME (a key press: shift, ctrl, alt held until FRAME:keyup:NAME), FRAME:fdown:ID:X,Y, FRAME:fmove:ID:X,Y, FRAME:fup:ID and FRAME:fcancel:ID (finger ID on a touch screen), FRAME:pdown:X,Y, FRAME:pmove:X,Y, FRAME:pup and FRAME:pnear / FRAME:pfar (the pen), separated by semicolons; X and Y in window points."`,
	dump_screen: string `usage:"On exit, write the whole window as the interface drew it (viewport and panels) to this path: a PNG, or a binary PPM when it ends in .ppm."`,
	dump_viewport: string `usage:"On exit, write the last viewport image to this path: a PNG, or a binary PPM when it ends in .ppm (for checking renders), as Menu > Save screenshot does."`,
	check_mesh: bool `usage:"On exit, check every object's current mesh (closed, consistently wound, no degenerate triangles or NaN) and print the counts as mesh_* lines (slow on large meshes)."`,
	no_partial: bool `usage:"Redraw the whole viewport every frame instead of only what changed (for comparison)."`,
	no_simplify: bool `usage:"Draw every chunk at full detail while the view moves too, instead of simplified copies of the far ones (for comparison)."`,
	orbit:     bool `usage:"Turn the camera around the scene by itself, once every 240 frames (to watch or time drawing while the view moves)."`,
	bench_stroke: int `usage:"Run a synthetic brush stroke over this many frames, print brush stats, then exit."`,
	bench_samples: int `usage:"Give each --bench-stroke frame this many pointer samples along the path, like a high-rate mouse (default: one position a frame)."`,
	bench_lifts: int `usage:"Lift the pen of --bench-stroke this many times along its path, so it makes that many strokes plus one (for the History timeline)."`,
	timelapse: string `usage:"Record a time-lapse of the History into this folder, as History > Record time-lapse does: once --bench-stroke ends, or at the start; the run lasts until it is done."`,
	timelapse_steps: int `usage:"Steps of the History each --timelapse frame shows (default 1)."`,
	timelapse_spin: f32 `usage:"Degrees the camera turns each --timelapse frame (default 0)."`,
	bench_loops: int `usage:"Make --bench-stroke this many circles around the middle of the sphere instead of a wavy line."`,
	brush:     string `usage:"Start with this brush: draw, smooth, clay, flatten, inflate, pinch, crease, grab, mask, layer, snake hook, morph, paint or cloth (also what --bench-stroke uses)."`,
	cloth:     string `usage:"What the Cloth brush does: drag (the default), gravity, pinch or expand."`,
	stroke:    string `usage:"Start with this stroke: dots (the default) or drag_rect (one stamp sized and turned by the drag, as the Brush tab's Drag rectangle)."`,
	front_only: bool `usage:"Start with Front faces only on: brushes and mask shapes leave what faces away from the viewer."`,
	symmetry:  string `usage:"Start with brush symmetry across these axes, e.g. x or xz."`,
	material:  string `usage:"Shade objects with this material (the Scene tab's Material): clay (the default), red wax, white, grey, skin, gold, copper, chrome, steel, plastic, ceramic, rubber or pbr clay."`,
	studio:    bool `usage:"Start with View > Studio render on: ambient occlusion and soft shadows build up while the view stays still."`,
	studio_samples: int `usage:"Light samples the studio render stops at (default 256, at most 1024)."`,
	flat:      bool `usage:"Start with flat shading, each triangle lit by its own normal, as View > Flat shading does."`,
	ortho:     bool `usage:"Start with parallel (orthographic) projection, as View > Orthographic (P) does."`,
	view:      string `usage:"Start looking from front, back, right, left, top or bottom, as the Scene tab's Camera section does."`,
	wireframe: bool `usage:"Show the selected object's edges, as View > Wireframe (Shift+F) does."`,
	falloff:   string `usage:"Start every brush with this falloff: smooth (the default), linear, sharp, firm or flat, as the Brush tab's Falloff presets set."`,
	rotate:    string `usage:"Turn the first object this many degrees about x, y and z before starting, e.g. 0,45,0 (as the Object tab's Transform does)."`,
	mirror:    string `usage:"Mirror and weld the first object before starting, as the Object tab's Mirror and weld does: x, y or z keeps that axis's + side, -x, -y or -z the - side (after --remesh)."`,
	slice:     string `usage:"Slice the first object in two across its middle before starting, as a Slice line does: x, y or z is the axis the cut goes across (after --mirror)."`,
	hide:      string `usage:"Hide the + side of the first object's middle across an axis before starting (x, y or z), or the - side (-x, -y or -z), as a hide rectangle does (after --slice)."`,
	store_morph: bool `usage:"Store the first object's surface as its morph target before starting, as the Object tab's Morph target > Store does (after the other start-up changes)."`,
	decimate:  int `usage:"Decimate the first object to about this many vertices before starting, as the Object tab's Decimate does (after --remesh)."`,
	remesh:    int `usage:"Voxel remesh the first sphere to about this many vertices before starting, as Remesh selected does (after --subdivide and --level)."`,
	dyntopo:   bool `usage:"Turn dynamic topology on for the first sphere before starting (after --remesh), as Ctrl+T does."`,
	detail:    f32 `usage:"Dynamic topology detail: edges longer than this many pixels on screen split (default 10)."`,
	tilt_strength: f32 `usage:"How far a leaning pen turns the brush, 0 to 1 (default 0: not at all), as the Brush tab's Pen > Tilt sets."`,
	alpha:     string `usage:"Start with this brush alpha: a built-in one (square, noise, rings, stripes, dots or star) or an image file (PNG, JPEG, BMP, TGA or QOI)."`,
	alpha_mode: string `usage:"Which way the alpha's top faces: stroke (along the stroke, the default), fixed or random."`,
	alpha_angle: f32 `usage:"Turn the alpha this many degrees counter-clockwise on top of what --alpha-mode gives."`,
	bench_tilt: f32 `usage:"Lean the synthetic pen of --bench-stroke this many degrees to the right (with --tilt-strength)."`,
	no_vsync:  bool `usage:"Show each frame as soon as it is ready instead of waiting for the display's refresh, so frame times are not capped at the refresh rate."`,
	time_gpu:  bool `usage:"Measure the GPU time of the 3D viewport every frame. Waits for the GPU each frame, so frames no longer overlap."`,
	gpubench:  string `usage:"Time the GPU and CPU while orbiting and sculpting one sphere at 500k, 1M, 5M, 7M and 10M vertices (only --vertices when given), with each speed setting on and off; write the markdown tables to this path and exit."`,
	gpu_smooth: bool `usage:"Start with the Object tab's Deformation > On the GPU on, so Smooth all runs as a compute shader (the GPU compute trial)."`,
	smooth_all: int `usage:"Smooth the first object this many steps before starting, as the Object tab's Deformation > Smooth all does (after the other start-up changes; on the GPU with --gpu-smooth)."`,
	compute_bench: string `usage:"Time Smooth all on the CPU and as a GPU compute shader, upload and readback included, at 500k, 1M, 5M, 7M and 10M vertices (only --vertices when given); check the GPU's result against the CPU's, write the markdown tables to this path and exit."`,
	groups:    string `usage:"Group the first object before starting, as the Object tab's Polygroups section (Select page) does: creases (Groups by creases), visible or masked; with --show-groups to see them."`,
	show_groups: bool `usage:"Start showing polygroups, as View > Polygroups (Shift+W) does."`,
	paint_color: string `usage:"The Paint brush's colour, as red,green,blue from 0 to 1 (e.g. 0.2,0.4,0.9)."`,
	fill_paint: bool `usage:"Fill the first object with the Paint brush's colour before starting, as the Object tab's Fill with colour does (after --groups)."`,
	layer:      bool `usage:"Add a sculpt layer to the first object before starting, recording, as the Object tab's Layers > New layer does (after --fill-paint), so --bench-stroke goes into it."`,
	retopo:     int `usage:"Retopologize the first object into about this many quads before starting, as the Object tab's Retopologize selected does (after --layer); the new object is selected."`,
	bake:       string `usage:"On exit, bake the first object's detail onto the selected quad object (from --retopo) into this folder, as Bake maps... does (before --export)."`,
	boolean:    string `usage:"Mark every object but the first union, subtract or intersect (the Object tab's Booleans) and move them to overlap it, before starting (after --retopo); with --spheres=2 or more."`,
	live_boolean: bool `usage:"Start with the Object tab's Booleans > Live boolean on."`,
	make_boolean: bool `usage:"Make the boolean mesh before starting, as Make boolean mesh does (after --boolean)."`,
	extract:    f32 `usage:"Extract the first object's masked part before starting, as the Object tab's Extract masked does, this thick (a share of its size; after --boolean); masks what the top third of the view shows first when nothing is masked."`,
	project:    bool `usage:"Project the first object's detail onto the selected one before starting, as the Object tab's Project detail does (after --retopo)."`,
	curve:      string `usage:"Draw a curve of this kind (tube, stitches or zipper) across the middle of the view before starting, as the Curve tool does (after --extract)."`,
	insert:     string `usage:"Insert this shape (sphere, cube, cylinder, cone or torus) at the middle of the view before starting, as a click of the Insert tool does (after --curve)."`,
	bake_size:  int `usage:"Texels square for --bake (512, 1024, 2048 or 4096; default 2048)."`,
	gpubench_frames: int `usage:"Measured frames per --gpubench case (default 120, at most 240)."`,
	open:      string `usage:"Start with the scene saved in this .sculpt file instead of spheres, as Menu > Open scene... does."`,
	import_mesh: string `args:"name=import" usage:"Start with the mesh in this .obj or .ply file instead of spheres (after any --open), as Menu > Import mesh... does."`,
	export:    string `usage:"On exit, write the selected object's shown level to this .obj or .ply file, as Menu > Export mesh... does."`,
	save:      string `usage:"On exit, save the scene to this .sculpt file, as Menu > Save scene does."`,
	load_strokes: string `usage:"Load the strokes in this .strokes file and replay them where they were drawn, as the Stroke recorder's Load and Replay do: once --bench-stroke ends, or at the start; the run lasts until they are done."`,
	replay_shift: string `usage:"Replay --load-strokes moved this many pixels right and down from where they were drawn, in the current view, as R at the pointer does, e.g. 120,-40."`,
	instant_replay: bool `usage:"Replay every recorded frame at once instead of one a frame, as the Stroke recorder's Instant does."`,
	record_strokes: bool `usage:"Record every stroke from the start, as the Stroke recorder's Record does (for --save-strokes)."`,
	save_strokes: string `usage:"On exit, save the recorded strokes (or else the last stroke) to this .strokes file, as the Stroke recorder's Save strokes does."`,
}

// Everything the app owns. The interface only ever sees pointers handed to it per frame.
App :: struct {
	renderer: render.Renderer,
	pool:     jobs.Pool,
	target:   render.Viewport_Target,
	scene:    Scene,
	tool:     Tool,
	move:     Move_Tool,
	brush:    Brush_Settings,
	mask_shape: Mask_Shape, // a Ctrl + drag on empty space in progress (mask_shape.odin)
	clip:     Clip_Gesture, // a Ctrl + Shift + drag in progress (clip.odin)
	curve:    Curve_Tool,
	insert:   Insert_Tool,
	gesture:  Gesture_Tool, // what a Ctrl + Shift + drag does
	smooth_gpu: render.Smooth_Compute, // Smooth all's compute shader and buffers, made on first use
	smooth_gpu_failed: bool, // the device refused the compute pipeline; Smooth all stays on the CPU
	// Each brush's drawn falloff as the sculptor reads it, remade when its curve changes.
	falloff_tables: [sculpt.Brush_Kind]struct {
		falloff: sculpt.Falloff,
		curve:   geom.Curve,
		built:   bool,
	},
	stroke:   Stroke,
	alphas:   [dynamic]Alpha_Entry, // the brush alphas the Brush tab offers (alphas.odin)
	alpha_seed: u32, // Random alpha mode's generator
	samples:  [dynamic]Input_Sample, // this frame's pointer samples, in window coordinates
	pen_pressure: f32, // the pen's latest pressure
	pen_tilt: [2]f32, // the pen's latest lean in degrees, x to the right and y down
	pen_seen: bool,
	touch:    Touch, // fingers and the pen on a touch screen (touch.odin)
	rail:     Modifier_Rail, // Smooth, Invert, Mask and Hide as buttons (modifiers.odin)
	drag:     Drag, // who the press on the viewport belongs to (navigate.odin)
	dab_wait: Dab_Wait, // a finger tap's dab waiting for a second tap (navigate.odin)
	pivot:    Stroke_Pivot, // the last stroke's middle, which orbits turn about (navigate.odin)
	double_tap: Double_Tap, // the last finger tap a double tap could follow (navigate.odin)
	cursor:   Brush_Cursor, // the surface under the brush ring this frame (cursor.odin)
	mask_seen: Mask_Seen, // whether the selected object has a mask, kept (history.odin)
	settings_file: string, // where the settings are remembered, "" when this run does not
	nav:      Nav_Prefs, // how the pointer, fingers and pen navigate (Settings)
	device:   Device, // this frame's keys and pointer (device.odin)
	kit:      Kit_State,
	kit_drew: bool, // the last frame drew the interface...
	kit_size: [2]u32, // ...this many pixels
	camera:   camera.Orbit,
	ui:       Ui_State,
	stats:    Frame_Stats,
	history:  History,
	timeline: Timeline, // the History panel's scrubbing, playback and time-lapse (timeline.odin)
	replay:   Replay, // the Stroke recorder's last stroke, recording and replay (replay.odin)
	// View > Studio render (Shift+R): ambient occlusion and soft shadows built up while
	// the view stays still (render.Studio).
	studio:         render.Studio,
	studio_on:      bool,
	studio_samples: i32, // samples it stops at
	studio_ao:      f32, // how strongly occlusion darkens, 0 to 1
	studio_shadow:  f32, // ...and the key light's shadow
	material:  int,  // the index in MATERIALS objects are shaded with, or CUSTOM_MATERIAL
	custom:    Material, // what the Material section's sliders made
	flat:      bool, // shade with each triangle's own normal (faceted) instead of smoothed normals
	wireframe: bool, // draw the selected object's edges over it
	show_groups: bool, // draw every object's polygroups in their colours instead of its clay and paint
	cache_idle: bool, // draw unselected objects from the viewport cache while they stay put
	hd_window_vertices: int, // size of the HD windows the A key opens
	// While the view moves, draw far groups of chunks from simplified copies that stray
	// at most simplify_px pixels; full detail once it has stayed put for LOD_SETTLE.
	simplify:    bool,
	simplify_px: f32,
	lod_finish:  bool, // build every pending copy each frame, not a batch (gpubench)
	view_key:    u64,       // camera, viewport size and object transforms last frame
	view_moved:  time.Tick, // when view_key last changed
	vsync:    bool, // wanted present mode, applied at the start of the next frame
	time_gpu: bool, // wait for each frame's 3D work, to measure its GPU time
	window:   ^sdl.Window, // what file dialogs belong to
	scene_path: string, // where the scene was last saved or opened from, for Ctrl+S (owned)
	result:     Op_Result, // what the last operation did (results.odin)
	running:  bool,
}

// The first frame --load-strokes may replay on: the viewport takes the window's size on
// the first frame and its render target follows at the start of the next, and until then
// it is not its real size, which replaying at the pointer would take as the view.
LOAD_STROKES_FRAME :: 3

main :: proc() {
	context.logger = platform_logger()
	defer platform_logger_destroy(context.logger)

	when ODIN_DEBUG {
		tracking: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking, context.allocator)
		context.allocator = mem.tracking_allocator(&tracking)
	}

	opts := Options{subdiv = 6, width = 1600, height = 900, spheres = 1}
	flags.parse_or_exit(&opts, os.args, .Unix)
	ok := run(opts)

	when ODIN_DEBUG {
		leaks := len(tracking.allocation_map)
		for _, entry in tracking.allocation_map {
			log.errorf("leak: %v bytes at %v", entry.size, entry.location)
		}
		for entry in tracking.bad_free_array {
			log.errorf("bad free at %v", entry.location)
		}
		if leaks == 0 && len(tracking.bad_free_array) == 0 {
			log.info("allocation tracking: no leaks")
		}
		ok = ok && leaks == 0 && len(tracking.bad_free_array) == 0
		mem.tracking_allocator_destroy(&tracking)
	}
	if !ok do os.exit(1)
}

run :: proc(opts: Options) -> bool {
	opts := opts
	bench: Gpubench
	defer gpubench_destroy(&bench)
	if opts.gpubench != "" {
		gpubench_init(&bench, opts.gpubench, opts.vertices, opts.gpubench_frames)
		opts.vertices, opts.spheres = bench.sizes[0], 1
	}

	platform_hints()
	if !sdl.Init({.VIDEO}) {
		log.errorf("SDL_Init failed: %s", sdl.GetError())
		return false
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("Sculpt", i32(opts.width), i32(opts.height), platform_window_flags())
	if window == nil {
		log.errorf("CreateWindow failed: %s", sdl.GetError())
		return false
	}
	defer sdl.DestroyWindow(window)

	app: App
	app.window = window
	defer delete(app.scene_path)
	defer file_shutdown(&app)
	defer results_destroy(&app)
	if !render.renderer_init(&app.renderer, window, opts.gpu_debug) do return false
	defer render.renderer_destroy(&app.renderer)
	defer render.smooth_compute_destroy(&app.renderer, &app.smooth_gpu)
	defer render.studio_destroy(&app.renderer, &app.studio)

	jobs.pool_init(&app.pool, opts.threads - 1 if opts.threads > 0 else 0)
	defer jobs.pool_destroy(&app.pool)
	log.infof("sculpt threads: %d", jobs.pool_size(&app.pool))
	if opts.compute_bench != "" do return computebench_run(&app, opts.compute_bench, opts.vertices)
	app.scene.selected = -1
	defer render.mesh_buffers_destroy(&app.renderer, &app.ui.boolean.preview)
	defer scene_destroy(&app)
	defer history_destroy(&app.history)
	timeline_init(&app.timeline)
	defer timeline_destroy(&app.timeline)
	replay_init(&app.replay)
	defer replay_destroy(&app.replay)
	app.replay.instant = opts.instant_replay
	app.replay.recording = opts.record_strokes
	defer delete(app.samples)
	defer delete(app.drag.held)
	defer delete(app.dab_wait.samples)
	defer delete(app.stroke.pending)
	defer mask_shape_destroy(&app.mask_shape)
	defer clip_gesture_destroy(&app.clip)
	defer curve_tool_destroy(&app.curve)
	app.hd_window_vertices = opts.hd_window if opts.hd_window > 0 else sculpt.HD_WINDOW_VERTICES
	if opts.open != "" {
		opened, ok := scene_open(&app, opts.open)
		if !ok || !opened do return false
		scene_remember_path(&app, opts.open)
	}
	if opts.import_mesh != "" {
		before := len(app.scene.objects)
		if !scene_import(&app, opts.import_mesh) || len(app.scene.objects) == before do return false
	}
	// Spheres unless a file gave the scene; then the steps below apply to its objects.
	starting := 0 if opts.open != "" || opts.import_mesh != "" else max(opts.spheres, 1)
	shape := geom.Primitive.Sphere
	if opts.shape != "" {
		found := false
		for p in geom.Primitive {
			if !strings.equal_fold(opts.shape, fmt.tprint(p)) do continue
			shape, found = p, true
		}
		if !found {
			log.errorf("unknown --shape %q", opts.shape)
			return false
		}
	}
	for _ in 0 ..< starting {
		t := Transform{position = next_free_position(&app), scale = 1}
		if shape == .Sphere {
			if !scene_add_sphere(&app, opts.vertices, opts.subdiv, t) do return false
		} else {
			if !scene_add_primitive(&app, shape, opts.vertices if opts.vertices > 0 else 40962, t) do return false
		}
	}
	for obj in app.scene.objects {
		defer if opts.hd > 0 && !sculpt.levels_hd_set_steps(&obj.levels, opts.hd) do log.warn("HD: the top level is not a closed manifold mesh")
		if opts.subdivide <= 0 && opts.level <= 0 do continue
		start := time.tick_now()
		for _ in 0 ..< opts.subdivide {
			if !sculpt.levels_subdivide(&obj.levels) do break
			free_all(context.temp_allocator)
		}
		log.infof("levels: %d, top level %d vertices, built in %.0f ms", len(obj.levels.levels),
			geom.mesh_vertex_count(object_mesh(obj)^), time.duration_milliseconds(time.tick_since(start)))
		if opts.level > 0 do sculpt.levels_set_current(&obj.levels, opts.level - 1)
		if !object_show_level(&app, obj, start) do return false
	}
	if len(app.scene.objects) == 0 {
		log.error("the scene has no objects to start with")
		return false
	}
	// The first sphere; otherwise what the file selected, or the import.
	if starting > 0 do app.scene.selected = 0
	if opts.remesh > 0 {
		if _, ok := object_remesh(&app, app.scene.objects[0], opts.remesh); !ok do return false
	}
	if opts.decimate > 0 {
		if _, ok := object_decimate(&app, app.scene.objects[0], opts.decimate); !ok do return false
	}
	if opts.rotate != "" {
		parts := strings.split(opts.rotate, ",", context.temp_allocator)
		if len(parts) != 3 {
			log.errorf("--rotate wants three angles, like 0,45,0")
			return false
		}
		for part, i in parts {
			a, ok := strconv.parse_f32(strings.trim_space(part))
			if !ok {
				log.errorf("--rotate: %q is not an angle", part)
				return false
			}
			app.scene.objects[0].transform.rotation[i] = a
		}
	}
	if opts.mirror != "" {
		axes := [?]string{"x", "y", "z"}
		name := strings.trim_prefix(opts.mirror, "-")
		axis := -1
		for a, i in axes do if strings.equal_fold(name, a) do axis = i
		if axis < 0 {
			log.errorf("unknown --mirror axis %q", opts.mirror)
			return false
		}
		if _, ok := object_symmetrize(&app, app.scene.objects[0], axis, !strings.has_prefix(opts.mirror, "-")); !ok do return false
	}
	for flag, i in ([2]string{opts.slice, opts.hide}) {
		if flag == "" do continue
		axes := [?]string{"x", "y", "z"}
		name := strings.trim_prefix(flag, "-")
		axis := -1
		for a, k in axes do if strings.equal_fold(name, a) do axis = k
		if axis < 0 {
			log.errorf("unknown --%s axis %q", "slice" if i == 0 else "hide", flag)
			return false
		}
		obj := app.scene.objects[0]
		app.scene.selected = 0
		if i == 0 {
			if !scene_slice_axis(&app, obj, axis) do return false
		} else {
			hide_axis(&app, obj, axis, !strings.has_prefix(flag, "-"))
		}
	}
	if opts.dyntopo {
		obj := app.scene.objects[0]
		if _, ok := object_set_dyntopo(&app, obj, true); !ok do return false
		if !object_dynamic(obj) do return false // refused, with the reason logged
	}
	if opts.store_morph && !sculpt.sculptor_morph_store(object_sculptor(app.scene.objects[0])) {
		log.errorf("--store-morph: not with dynamic topology")
		return false
	}
	defer render.viewport_target_destroy(&app.renderer, &app.target)
	app.camera = camera.orbit_default()
	app.camera.ortho = opts.ortho
	if opts.view != "" {
		found := false
		for view in camera.Axis_View {
			if !strings.equal_fold(opts.view, fmt.tprint(view)) do continue
			camera.orbit_axis_view(&app.camera, view)
			found = true
		}
		if !found {
			log.errorf("unknown --view %q", opts.view)
			return false
		}
	}
	if opts.hd_open {
		obj := app.scene.objects[0]
		toward := camera.orbit_eye(app.camera) - obj.transform.position
		if !object_hd_enter(&app, obj, linalg.normalize(to_local_dir(obj.transform, toward))) do return false
	}

	// The interface. It is torn down before the renderer (defers run LIFO).
	kit_init(&app)
	defer kit_destroy(&app)
	if !kit_events_parse(&app, opts.ui_events) do return false

	if len(app.scene.objects) > 1 do frame_all(&app)
	app.cache_idle = !opts.no_cache
	app.custom = MATERIALS[len(MATERIALS) - 1]
	app.custom.label = "Custom"
	app.renderer.cull = !opts.no_cull
	app.renderer.partial = !opts.no_partial
	app.simplify = !opts.no_simplify
	app.simplify_px = 1
	app.vsync = !opts.no_vsync && opts.gpubench == ""
	app.time_gpu = opts.time_gpu || opts.gpubench != ""
	app.ui = ui_state_default()
	app.curve, app.insert = CURVE_DEFAULTS, INSERT_DEFAULTS
	app.brush = {kind = .Draw, radius_px = DEFAULT_RADIUS_PX, pressure_strength = true, pressure_curve = geom.CURVE_LINEAR, detail_px = 10, collapse = true, alpha = -1, color = {0.75, 0.2, 0.15}}
	for &s, kind in app.brush.strengths do s = BRUSHES[kind].strength
	app.nav = NAV_DEFAULT
	// What earlier interactive runs left, before the flags, which win over it.
	remember := (opts.frames == 0 && opts.gpubench == "" && opts.bench_stroke == 0 && !opts.no_settings) || opts.settings_file != ""
	settings := (opts.settings_file if opts.settings_file != "" else settings_path()) if remember else ""
	if remember do settings = strings.clone(settings)
	defer delete(settings)
	settings_load(&app, settings)
	app.settings_file = settings
	if opts.reduce_motion do app.kit.ctx.reduced_motion = true
	app.kit.fixed_dt = opts.ui_dt
	if opts.finger_orbits do app.nav.finger_model = .Orbit
	switch opts.orbit_style {
	case "":
	case "free":      app.nav.orbit_style = .Free
	case "turntable": app.nav.orbit_style = .Turntable
	case:
		log.errorf("--orbit-style is free or turntable, not %q", opts.orbit_style)
		return false
	}
	switch opts.orbit_pivot {
	case "":
	case "stroke":  app.nav.pivot = .Stroke
	case "pointer": app.nav.pivot = .Pointer
	case "centre":  app.nav.pivot = .Centre
	case:
		log.errorf("--orbit-pivot is stroke, pointer or centre, not %q", opts.orbit_pivot)
		return false
	}
	if opts.no_edge_orbit do app.nav.edge_orbit = false
	if opts.flat_ring do app.kit.surface_ring = false
	if opts.no_vsync do app.vsync = false
	app.ui.smooth_on_gpu = opts.gpu_smooth
	if opts.smooth_all > 0 do smooth_command(&app, opts.smooth_all)
	if opts.paint_color != "" {
		parts := strings.split(opts.paint_color, ",", context.temp_allocator)
		if len(parts) != 3 {
			log.errorf("--paint-color takes red,green,blue, not %q", opts.paint_color)
			return false
		}
		for p, k in parts do app.brush.color[k] = clamp(strconv.parse_f32(p) or_else 0, 0, 1)
	}
	if opts.show_groups do app.show_groups = true
	if opts.groups != "" {
		switch strings.to_lower(opts.groups, context.temp_allocator) {
		case "creases": group_command(&app, .Creases)
		case "visible": group_command(&app, .Visible)
		case "masked":  group_command(&app, .Masked)
		case:
			log.errorf("unknown --groups %q", opts.groups)
			return false
		}
		app.show_groups = opts.show_groups
	}
	if opts.fill_paint do paint_command(&app, .Fill)
	if opts.layer do layer_add(&app)
	if opts.retopo > 0 {
		app.scene.selected = 0
		if _, ok := object_retopo(&app, app.scene.objects[0], opts.retopo); !ok do return false
	}
	if opts.boolean != "" {
		mode: Boolean_Mode
		for m in Boolean_Mode do if m != .None && strings.equal_fold(opts.boolean, fmt.tprint(m)) do mode = m
		if mode == .None || len(app.scene.objects) < 2 {
			log.errorf("--boolean takes union, subtract or intersect, and two objects or more, not %q", opts.boolean)
			return false
		}
		first := app.scene.objects[0]
		for obj, i in app.scene.objects[1:] {
			obj.boolean = mode
			obj.transform.position = first.transform.position + {0.9, 0.4 * f32(i), 0} * first.transform.scale
		}
	}
	if opts.live_boolean do app.ui.boolean.live = true
	if opts.make_boolean && !boolean_make(&app) do return false
	if opts.extract > 0 {
		app.scene.selected = 0
		app.ui.boolean.thickness = opts.extract
		if object_sculptor(app.scene.objects[0]).mask == nil {
			top := [4][2]f32{{-1, 0.33}, {1, 0.33}, {1, 1}, {-1, 1}}
			// The viewport has no size before the first frame: the size it asks for.
			mask_shape_command(&app, top[:], app.ui.viewport_request, false)
		}
		if !extract_masked(&app) do return false
	}
	if opts.project && len(app.scene.objects) > 1 do project_detail(&app, selected_object(&app), app.scene.objects[0])
	if opts.curve != "" {
		found := false
		for k in Curve_Kind do if strings.equal_fold(opts.curve, fmt.tprint(k)) {
			app.curve.kind, found = k, true
		}
		if !found {
			log.errorf("unknown --curve %q", opts.curve)
			return false
		}
		// The viewport has no size before the first frame: the size it asks for.
		size := app.ui.viewport_request
		for i in 0 ..= 40 do curve_add_point(&app, {size.x * (0.3 + 0.01 * f32(i)), size.y * (0.5 + 0.08 * math.sin(f32(i) / 6))}, size)
		if !curve_make(&app) do return false
	}
	if opts.insert != "" {
		found := false
		for p in geom.Primitive do if strings.equal_fold(opts.insert, fmt.tprint(p)) {
			app.insert.shape, found = p, true
		}
		if !found {
			log.errorf("unknown --insert %q", opts.insert)
			return false
		}
		size := app.ui.viewport_request
		origin, dir := mouse_ray(app.camera, 0.5 * size, size)
		if _, hit, n, ok := scene_raycast_surface(&app, origin, dir); ok {
			if !insert_make(&app, hit, n, app.brush.radius_px * camera.orbit_world_per_px(app.camera, hit, size.y)) do return false
		}
	}
	if opts.bake_size > 0 do app.ui.bake.size = i32(opts.bake_size)
	defer if remember do _ = settings_save(&app, settings)
	if opts.ortho do app.camera.ortho = true
	if opts.wireframe do app.wireframe = true
	if opts.flat do app.flat = true
	app.studio_samples, app.studio_ao, app.studio_shadow = STUDIO_SAMPLES_DEFAULT, 0.85, 0.6
	if opts.studio do app.studio_on = true
	if opts.studio_samples > 0 do app.studio_samples = i32(min(opts.studio_samples, STUDIO_SAMPLES_MAX))
	if opts.front_only do app.brush.front_only = true
	if opts.stroke != "" {
		found := false
		for mode in Stroke_Mode do if strings.equal_fold(opts.stroke, fmt.tprint(mode)) {
			app.brush.stroke = mode
			found = true
		}
		if !found {
			log.errorf("unknown --stroke %q", opts.stroke)
			return false
		}
	}
	if opts.material != "" {
		found: bool
		app.material, found = material_by_name(opts.material)
		if !found {
			log.errorf("unknown material %q", opts.material)
			return false
		}
	}
	if opts.falloff != "" {
		found := false
		for preset in FALLOFF_PRESETS {
			if !strings.equal_fold(opts.falloff, string(preset.label)) do continue
			for &f in app.brush.falloffs do f = {drawn = preset.drawn, curve = preset.curve}
			found = true
		}
		if !found {
			log.errorf("unknown falloff %q", opts.falloff)
			return false
		}
	}
	if opts.detail > 0 do app.brush.detail_px = opts.detail
	if opts.tilt_strength > 0 do app.brush.tilt_strength = clamp(opts.tilt_strength, 0, 1)
	if opts.brush != "" {
		kind, found := brush_by_name(opts.brush)
		if !found {
			log.errorf("unknown brush %q", opts.brush)
			return false
		}
		app.brush.kind = kind
	}
	if opts.cloth != "" {
		found := false
		for mode in sculpt.Cloth_Mode do if strings.equal_fold(opts.cloth, fmt.tprint(mode)) {
			app.brush.cloth_mode = mode
			found = true
		}
		if !found {
			log.errorf("unknown --cloth %q", opts.cloth)
			return false
		}
	}
	alphas_init(&app)
	defer alphas_destroy(&app)
	app.alpha_seed = 1
	if opts.alpha != "" && !alpha_select(&app, opts.alpha) do return false
	if opts.alpha_angle != 0 do app.brush.alpha_angle = opts.alpha_angle
	switch strings.to_lower(opts.alpha_mode, context.temp_allocator) {
	case "":
	case "stroke":     app.brush.alpha_mode = .Stroke
	case "fixed":      app.brush.alpha_mode = .Fixed
	case "random":     app.brush.alpha_mode = .Random
	case:
		log.errorf("unknown alpha mode %q", opts.alpha_mode)
		return false
	}
	for c in strings.to_lower(opts.symmetry, context.temp_allocator) {
		switch c {
		case 'x': app.brush.symmetry += {.X}
		case 'y': app.brush.symmetry += {.Y}
		case 'z': app.brush.symmetry += {.Z}
		case:
			log.errorf("unknown symmetry axis %q in %q", c, opts.symmetry)
			return false
		}
	}
	app.tool = .Brush
	app.running = true
	frame_index := 0
	// The previous frame's, kept while timing the GPU so the next frame can wait for it.
	present_fence: ^sdl.GPUFence
	defer if present_fence != nil {
		_ = sdl.WaitForGPUFences(app.renderer.device, true, &present_fence, 1)
		sdl.ReleaseGPUFence(app.renderer.device, present_fence)
	}

	for app.running {
		frame_start := time.tick_now()
		if command := app.ui.scene_command; command.kind != .None {
			app.ui.scene_command = {}
			if !scene_run(&app, command) do return false
		}
		if req, ok := file_take(&app); ok {
			applied := file_apply(&app, req)
			file_request_free(req)
			if !applied do return false
		}
		if opts.timelapse != "" && frame_index == opts.bench_stroke {
			if opts.timelapse_steps > 0 do app.timeline.lapse.steps = i32(opts.timelapse_steps)
			app.timeline.lapse.spin = opts.timelapse_spin
			timelapse_start(&app, opts.timelapse)
		}
		if opts.load_strokes != "" && frame_index == max(opts.bench_stroke, LOAD_STROKES_FRAME) {
			if !strokes_load(&app, opts.load_strokes) do return false
			if opts.replay_shift != "" {
				shift: [2]f32
				parts := strings.split(opts.replay_shift, ",", context.temp_allocator)
				ok := len(parts) == 2
				for part, i in parts {
					if i >= 2 do break
					v, parsed := strconv.parse_f32(strings.trim_space(part))
					shift[i], ok = v, ok && parsed
				}
				if !ok {
					log.errorf("--replay-shift wants two pixel counts, like 120,-40")
					return false
				}
				replay_start(&app, &app.replay.take, true, take_start(&app.replay.take) + shift)
			} else {
				replay_start(&app, &app.replay.take)
			}
		}
		timeline_frame(&app)
		// Changing the present mode recreates the swapchain, so it happens before this
		// frame acquires a swapchain texture.
		if app.vsync != (app.renderer.present_mode == .VSYNC) {
			if !render.renderer_set_vsync(&app.renderer, app.vsync) do app.vsync = app.renderer.present_mode == .VSYNC
		}

		// Wait for the display, and while timing the GPU for the previous frame too,
		// before reading input: the frame then shows the newest input rather than input
		// that sat through the wait.
		wait_start := time.tick_now()
		if present_fence != nil {
			_ = sdl.WaitForGPUFences(app.renderer.device, true, &present_fence, 1)
			sdl.ReleaseGPUFence(app.renderer.device, present_fence)
			present_fence = nil
		}
		present_cmd := sdl.AcquireGPUCommandBuffer(app.renderer.device)
		if present_cmd == nil {
			log.errorf("AcquireGPUCommandBuffer failed: %s", sdl.GetError())
			return false
		}
		swapchain: ^sdl.GPUTexture
		swapchain_size: [2]u32
		if !sdl.WaitAndAcquireGPUSwapchainTexture(present_cmd, window, &swapchain, &swapchain_size.x, &swapchain_size.y) {
			log.errorf("acquire swapchain failed: %s", sdl.GetError())
			_ = sdl.CancelGPUCommandBuffer(present_cmd)
			return false
		}
		waited := time.tick_since(wait_start)

		// Every pointer sample, not only where the pointer ended up, so the brush can
		// follow the whole path. A pen also sends mouse events, marked PEN_MOUSEID; its
		// pressure arrives separately as an axis event.
		clear(&app.samples)
		device_frame_begin(&app.device)
		kit_events_push(&app, window)
		e: sdl.Event
		for sdl.PollEvent(&e) {
			// Space over the viewport is the brush pie's (pie.odin) rather than a key of the
			// frame; once it went down there, its release is the pie's too.
			if (e.type == .KEY_DOWN || e.type == .KEY_UP) && e.key.scancode == .SPACE {
				pie := &app.ui.pie
				if pie.space_down || (e.key.down && app.ui.viewport_hovered && !typing(&app)) {
					// A tap's dab waiting for a second tap plays before the pie opens.
					if e.key.down do app.dab_wait.play = true
					if e.key.down && !e.key.repeat do pie.space_pressed = true
					if !e.key.down do pie.space_released = true
					pie.space_down = e.key.down
					continue
				}
			}
			device_event(&app.device, &e)
			dab_wait_event(&app, &e, window)
			touch_event(&app, &e, window)
			#partial switch e.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				app.running = false
			case .DID_ENTER_BACKGROUND:
				// The system may end the app from the background without another word.
				if app.settings_file != "" do _ = settings_save(&app, app.settings_file)
			case .MOUSE_MOTION:
				pen := e.motion.which == sdl.PEN_MOUSEID
				append(&app.samples, Input_Sample{{e.motion.x, e.motion.y}, app.pen_pressure if pen else 1, .Move, app.pen_tilt if pen else {}})
			case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
				if e.button.button == sdl.BUTTON_LEFT {
					pen := e.button.which == sdl.PEN_MOUSEID
					append(&app.samples, Input_Sample{{e.button.x, e.button.y}, app.pen_pressure if pen else 1, .Press if e.button.down else .Release, app.pen_tilt if pen else {}})
				}
			case .PEN_AXIS:
				#partial switch e.paxis.axis {
				case .PRESSURE:
					app.pen_pressure = e.paxis.value
				case .XTILT:
					app.pen_tilt.x = e.paxis.value
				case .YTILT:
					app.pen_tilt.y = e.paxis.value
				}
				app.pen_seen = true
			}
		}
		device_frame_end(&app.device)

		// Resize to the size the interface asked for last frame, before it references the
		// texture, so it never draws a texture released this frame.
		want := app.ui.viewport_request
		if !render.viewport_target_resize(&app.renderer, &app.target, u32(want.x), u32(want.y)) do return false

		// A tap's dab that waited for a second tap plays before anything this frame does.
		waited_dab := dab_wait_resolve(&app)
		ui_start := time.tick_now()
		input := kit_frame(&app, window)
		ring_push(&app.stats.ui_ms, time.duration_milliseconds(time.tick_since(ui_start)))
		if opts.bench_stroke > 0 && frame_index < opts.bench_stroke {
			input = bench_input(&app, frame_index, opts.bench_stroke, opts.bench_samples, opts.bench_loops, {opts.bench_tilt, 0}, {f32(app.target.width), f32(app.target.height)})
			// A lifted frame ends the stroke; the next frame presses again.
			if every := opts.bench_stroke / (opts.bench_lifts + 1); opts.bench_lifts > 0 && every > 0 && (frame_index + 1) % every == 0 {
				input.primary = false
			}
			app.device.input_at = sdl.GetTicksNS()
		} else if opts.gpubench != "" {
			input = gpubench_input(&app, &bench, {f32(app.target.width), f32(app.target.height)})
			app.device.input_at = sdl.GetTicksNS()
		}
		camera_apply_input(&app, input)
		if opts.orbit do camera.orbit_spin(&app.camera, 2 * math.PI / 240)
		sculpted: Sculpt_Frame_Result
		switch app.tool {
		case .Brush:
			if clip_frame(&app, input) || mask_shape_frame(&app, input) {
				stroke_finish(&app)
			} else if replay_busy(&app) {
				// A replay sculpts in place of the pointer.
				sculpted = replay_frame(&app, input)
			} else {
				replay_frame_begin(&app)
				sculpted = sculpt_frame(&app, input)
				replay_record(&app, input, sculpted)
			}
		case .Move:
			replay_stop(&app)
			stroke_finish(&app)
			move_tool_frame(&app, input)
		case .Curve:
			stroke_finish(&app)
			if !curve_tool_frame(&app, input) do return false
		case .Insert:
			stroke_finish(&app)
			if !insert_tool_frame(&app, input) do return false
		}
		sculpted.dabs += waited_dab.dabs
		sculpted.raycast_ms += waited_dab.raycast_ms
		sculpted.brush_ms += waited_dab.brush_ms
		cursor_update(&app, input)
		draw_viewport_overlay(&app, input)

		// The 3D viewport goes in its own command buffer, submitted ahead of the one that
		// presents, so its GPU time can be measured on its own.
		cmd := sdl.AcquireGPUCommandBuffer(app.renderer.device)
		if cmd == nil {
			log.errorf("AcquireGPUCommandBuffer failed: %s", sdl.GetError())
			_ = sdl.SubmitGPUCommandBuffer(present_cmd) // holds a swapchain texture: cannot be cancelled
			return false
		}
		uploaded: int // bytes
		normals_ms: f64
		lod_ms := -1.0 // time building simplified copies; none built when negative
		if !boolean_live_update(&app) {
			_ = sdl.SubmitGPUCommandBuffer(cmd)
			_ = sdl.SubmitGPUCommandBuffer(present_cmd)
			return false
		}
		draws := make([dynamic]render.Draw_Item, 0, 2 * len(app.scene.objects) + 1, context.temp_allocator)
		for obj, i in app.scene.objects {
			// An object sculpting HD shows its top level around the window.
			parts := [2]^sculpt.Level{sculpt.levels_current(&obj.levels), obj.levels.hd.window}
			gpus := [2]^render.Mesh_Buffers{&obj.gpu[obj.levels.current], &obj.hd_gpu}
			for lv, part in parts {
				if lv == nil do continue
				gpu := gpus[part]
				t_flush := time.tick_now()
				ranges := sculpt.sculptor_flush(&lv.sculptor)
				normals_ms += time.duration_milliseconds(time.tick_since(t_flush))
				bytes, uploaded_ok := level_upload(&app, cmd, gpu, lv, ranges)
				if !uploaded_ok {
					_ = sdl.SubmitGPUCommandBuffer(cmd)
					_ = sdl.SubmitGPUCommandBuffer(present_cmd)
					return false
				}
				uploaded += bytes
				// Simplified copies are built a batch a frame, for one level at a time, and
				// never during a stroke, whose frames should stay as short as they can be.
				if app.simplify && !app.stroke.active && lod_ms < 0 && sculpt.sculptor_lod_pending(&lv.sculptor) > 0 {
					t_lod := time.tick_now()
					lod_ranges, all := sculpt.sculptor_lod_update(&lv.sculptor, app.lod_finish)
					render.mesh_buffers_upload_lod(&app.renderer, cmd, gpu, lv.sculptor.lod.indices[:], lod_ranges, all, len(lv.mesh.indices) / 2)
					lod_ms = time.duration_milliseconds(time.tick_since(t_lod))
				}
				// The live boolean's preview stands in for it (drawn below).
				if boolean_hides(&app, obj, i) do continue
				// The selected object is in the material's colour; the others are muted. Only
				// the selected one is sculpted or moved, so the rest can come from the cache.
				selected := i == app.scene.selected
				material := current_material(&app)
				append(&draws, render.Draw_Item {
					mesh   = gpu,
					model  = transform_matrix(obj.transform),
					color  = material.selected if selected else material.idle,
					material = material.shading,
					surface = {material.metallic, material.roughness},
					flat = app.flat,
					wireframe = selected && app.wireframe,
					paint  = sculpt.sculptor_has_color(&lv.sculptor),
					groups = app.show_groups && sculpt.sculptor_has_groups(&lv.sculptor),
					live   = selected,
					chunks = lv.sculptor.chunks,
					chunk_groups = sculpt.sculptor_chunk_groups(&lv.sculptor),
					damage = lv.sculptor.changed_bounds,
					lod    = lv.sculptor.lod.tree,
					hidden = sculpt.levels_hd_hidden(&obj.levels) if part == 0 && obj.levels.hd.window != nil else sculpt.sculptor_hidden_units(&lv.sculptor),
				})
			}
		}
		if b := &app.ui.boolean; b.shown {
			if base := object_by_id(&app, b.base); base != nil {
				material := current_material(&app)
				append(&draws, render.Draw_Item {
					mesh     = &b.preview,
					model    = transform_matrix(base.transform),
					color    = material.selected,
					material = material.shading,
					surface  = {material.metallic, material.roughness},
					flat     = app.flat,
					damage   = geom.AABB_EMPTY,
				})
			}
		}
		aspect := f32(app.target.width) / f32(app.target.height)
		view, proj := camera.orbit_view(app.camera), camera.orbit_proj(app.camera, aspect)
		if view_changed(&app, view, proj) do app.view_moved = time.tick_now()
		moving := time.tick_since(app.view_moved) < LOD_SETTLE
		app.renderer.lod_px = app.simplify_px if app.simplify && moving && !timelapse_capturing(&app) else 0
		drawn := render.render_viewport(&app.renderer, cmd, &app.target, view, proj, draws[:], app.cache_idle)
		if app.studio_on {
			// Anything redrawn this frame starts the samples over.
			changed := !drawn.partial || drawn.redrawn_px > 0
			app.studio_on = render.studio_frame(&app.renderer, &app.studio, cmd, &app.target, view, proj, draws[:], changed, int(app.studio_samples), app.studio_ao, app.studio_shadow)
		}

		gpu_wait: time.Duration
		if app.time_gpu {
			// Nothing else is queued (the previous frame was waited for above), so the
			// time from submit to the fence is the GPU time of this work.
			submit_start := time.tick_now()
			fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
			if fence == nil {
				log.errorf("submit failed: %s", sdl.GetError())
				_ = sdl.SubmitGPUCommandBuffer(present_cmd)
				return false
			}
			_ = sdl.WaitForGPUFences(app.renderer.device, true, &fence, 1)
			sdl.ReleaseGPUFence(app.renderer.device, fence)
			gpu_wait = time.tick_since(submit_start)
			ring_push(&app.stats.gpu_ms, time.duration_milliseconds(gpu_wait))
		} else if !sdl.SubmitGPUCommandBuffer(cmd) {
			log.errorf("submit failed: %s", sdl.GetError())
			_ = sdl.SubmitGPUCommandBuffer(present_cmd)
			return false
		}

		// The interface, the viewport image in it, into the swapchain.
		kit_ready := false
		if swapchain != nil {
			kit_ready = kit_upload(&app, present_cmd)
		} else {
			_ = ui.frame_end(&app.kit.ctx)
		}
		app.stats.ui_vertices = len(app.kit.ctx.draw.vertices)
		// The pass clears the image even when the interface could not be uploaded, so a
		// failed upload shows an empty frame rather than whatever the image held.
		if swapchain != nil {
			target := sdl.GPUColorTargetInfo {
				texture     = swapchain,
				clear_color = {0.08, 0.08, 0.09, 1},
				load_op     = .CLEAR,
				store_op    = .STORE,
			}
			pass := sdl.BeginGPURenderPass(present_cmd, &target, 1, nil)
			if kit_ready {
				format := sdl.GetGPUSwapchainTextureFormat(app.renderer.device, window)
				render.ui_pass_draw(&app.renderer, &app.kit.pass, present_cmd, pass, format, swapchain_size, kit_draws(&app, &app.kit.ctx.draw))
			}
			sdl.EndGPURenderPass(pass)
		}
		app.kit_drew = kit_ready
		app.kit_size = swapchain_size
		// Some drivers wait for the display here rather than when the swapchain texture
		// is acquired, so this counts as waiting too.
		present_start := time.tick_now()
		submitted := false
		if app.time_gpu {
			present_fence = sdl.SubmitGPUCommandBufferAndAcquireFence(present_cmd)
			submitted = present_fence != nil
		} else {
			submitted = sdl.SubmitGPUCommandBuffer(present_cmd)
		}
		if !submitted {
			log.errorf("submit failed: %s", sdl.GetError())
			return false
		}

		submitted_ns := sdl.GetTicksNS()
		waited += time.tick_since(present_start)

		frame_time := time.tick_since(frame_start)
		cpu_time := frame_time - waited - gpu_wait
		ring_push(&app.stats.frame_ms, time.duration_milliseconds(frame_time))
		ring_push(&app.stats.wait_ms, time.duration_milliseconds(waited))
		ring_push(&app.stats.cpu_ms, time.duration_milliseconds(cpu_time))
		app.stats.viewport = drawn
		app.stats.cache_redraws += int(drawn.cache_redrawn)
		app.stats.partial_frames += int(drawn.partial)
		if lod_ms >= 0 do ring_push(&app.stats.lod_ms, lod_ms)
		if sculpted.dabs > 0 {
			ring_push(&app.stats.raycast_ms, sculpted.raycast_ms)
			ring_push(&app.stats.brush_ms, sculpted.brush_ms)
			ring_push(&app.stats.normals_ms, normals_ms)
			ring_push(&app.stats.upload_kb, f64(uploaded) / 1024)
			ring_push(&app.stats.latency_ms, f64(submitted_ns - app.device.input_at) / 1e6)
			app.stats.dabs_total += sculpted.dabs
		}
		free_all(context.temp_allocator)

		frame_index += 1
		if (opts.frames > 0 && frame_index >= opts.frames) || (opts.bench_stroke > 0 && frame_index >= opts.bench_stroke) {
			// A --timelapse run goes on until the recording is done.
			// So does one replaying --load-strokes, which starts the frame after.
			replaying := replay_busy(&app) || (opts.load_strokes != "" && frame_index <= max(opts.bench_stroke, LOAD_STROKES_FRAME))
			if (opts.timelapse == "" || (frame_index > opts.bench_stroke && !timeline_busy(&app))) && !replaying do app.running = false
		}
		if opts.gpubench != "" && gpubench_end_frame(&app, &bench, time.duration_milliseconds(gpu_wait), time.duration_milliseconds(cpu_time), sculpted.dabs) {
			app.running = false
			if !gpubench_write(&app, &bench) do return false
		}
	}
	if opts.gpubench != "" && !bench.done {
		log.warn("gpubench: stopped before every case ran; nothing written")
		return false
	}

	if opts.dump_viewport != "" do _ = screenshot_save(&app, opts.dump_viewport)
	if opts.dump_screen != "" {
		if app.kit_drew {
			_ = kit_screen_save(&app, opts.dump_screen, app.kit_size)
		} else {
			// Only a frame without a swapchain image (a minimized window) draws nothing.
			log.error("--dump-screen: the last frame was not drawn (the window had no image to draw into)")
		}
	}

	if opts.bake != "" {
		// The quads are the newest object; the stroke may have selected another.
		app.ui.bake.source = app.scene.objects[0].id
		app.scene.selected = len(app.scene.objects) - 1
		bake_to_folder(&app, opts.bake)
	}
	if opts.export != "" {
		obj := selected_object(&app)
		if obj == nil || !object_export(&app, obj, opts.export) do return false
	}
	if opts.save != "" && !scene_save(&app, opts.save) do return false
	if opts.save_strokes != "" && !strokes_save(&app, opts.save_strokes) do return false

	print_stat :: proc(name: string, r: Sample_Ring) {
		p50, p99 := ring_percentiles(r)
		fmt.printfln("%s_p50=%.3f %s_p99=%.3f", name, p50, name, p99)
	}
	vertices: int
	for obj in app.scene.objects do vertices += object_vertex_count(obj)
	fmt.printfln("frames=%d dabs=%d objects=%d vertices=%d", frame_index, app.stats.dabs_total, len(app.scene.objects), vertices)
	{
		c := app.camera
		fmt.printfln("camera_yaw=%.4f camera_pitch=%.4f camera_roll=%.4f camera_distance=%.4f camera_target=%.4f,%.4f,%.4f", c.yaw, c.pitch, c.roll, c.distance, c.target.x, c.target.y, c.target.z)
		p := app.pivot.used
		fmt.printfln("orbit_pivot=%.4f,%.4f,%.4f pivot_source=%s pinned=%d framed=%d touch_repeats=%d", p.x, p.y, p.z, strings.to_lower(fmt.tprint(app.pivot.from), context.temp_allocator), int(app.pivot.pinned), app.double_tap.framed, app.touch.hold.done)
		fmt.printfln("undo_steps=%d redo_steps=%d brush_radius_px=%.2f brush_strength=%.3f selected=%d", len(app.history.done), len(app.history.undone), app.brush.radius_px, brush_strength(&app)^, app.scene.selected)
		{
			// What the last stroke was, the rail's latches, and whether the selected object
			// has a mask, for touch_check's modifier rail scenarios.
			latched := "none"
			for m in app.rail.latched {
				name := strings.to_lower(MODIFIER_NAMES[m], context.temp_allocator)
				latched = name if latched == "none" else strings.concatenate({latched, "+", name}, context.temp_allocator)
			}
			obj := selected_object(&app)
			masked := obj != nil && sculpt.sculptor_has_mask(object_sculptor(obj))
			// The whole mask, as a mean from 0 to 1, so a check can tell inverting from blurring.
			mask_mean: f64
			if obj != nil {
				s := object_sculptor(obj)
				for k in s.mask do mask_mean += f64(k)
				mask_mean /= max(f64(len(s.mask)) * 255, 1)
			}
			fmt.printfln("stroke_kind=%s stroke_invert=%d rail_latched=%s masked=%d mask_mean=%.4f", strings.to_lower(fmt.tprint(app.stroke.kind), context.temp_allocator), int(app.stroke.invert), latched, int(masked), mask_mean)
			// What the last operation said, up to its first comma, spaces as underscores.
			last := app.result.text
			if i := strings.index_byte(last, ','); i >= 0 do last = last[:i]
			if i := strings.index(last, " in "); i >= 0 do last = last[:i]
			last_op, _ := strings.replace_all(last, " ", "_", context.temp_allocator)
			fmt.printfln("last_op=%s toast_undo=%d", last_op if last_op != "" else "none", int(app.result.undo != nil))
		}
		// The last tooltip a long press showed, spaces as underscores so it stays one value.
		tip_text, tip_keys := ui.long_tip_shown(&app.kit.ctx)
		long_tip, _ := strings.replace_all(tip_text, " ", "_", context.temp_allocator)
		long_tip_keys, _ := strings.replace_all(tip_keys, " ", "_", context.temp_allocator)
		fmt.printfln("long_tip_keys=%s", long_tip_keys if long_tip_keys != "" else "none")
		fmt.printfln("long_tip=%s object_menu=%d inspector_tab=%s brush_kind=%s", long_tip if long_tip != "" else "none", int(app.kit.object_menu), strings.to_lower(fmt.tprint(app.kit.tab), context.temp_allocator), strings.to_lower(fmt.tprint(app.brush.kind), context.temp_allocator))
		fmt.printfln("inspector_scroll=%.1f settings_scroll=%.1f settings_open=%d", app.kit.scroll, app.kit.settings_scroll, int(app.kit.settings))
		n := app.cursor.normal
		fmt.printfln("cursor_hit=%d cursor_normal=%.4f,%.4f,%.4f", int(app.cursor.ok), n.x, n.y, n.z)
		k := &app.kit
		fmt.printfln("palette=%d palette_runs=%d palette_last=%s settings_tab=%v tool=%s", int(k.palette), k.palette_runs, palette_entry_name(k.palette_last) if k.palette_ran else "none", k.settings_tab, strings.to_lower(fmt.tprint(app.tool), context.temp_allocator))
		fmt.printfln("help_open=%d help_tab=%v help_scroll=%.1f object_page=%v", int(k.help), k.help_tab, k.help_scroll, k.object_page)
		// The inspector sections showing their More options, as Kit_Section names.
		more := "none"
		for open, sec in k.more {
			if !open do continue
			name := strings.to_lower(fmt.tprint(sec), context.temp_allocator)
			more = name if more == "none" else strings.concatenate({more, "+", name}, context.temp_allocator)
		}
		fmt.printfln("more=%s all_options=%d", more, int(k.all_options))
		// The action bar's groups as it last showed them (none while it waits for room), and
		// how often the mask was read.
		bar_groups := "none"
		if bar, _ := ui.prev_layout(&k.ctx, "action bar"); bar.x > 0 && action_bar_shown(&app) {
			for g in action_groups_now(&app) {
				name := strings.to_lower(fmt.tprint(g), context.temp_allocator)
				bar_groups = name if bar_groups == "none" else strings.concatenate({bar_groups, "+", name}, context.temp_allocator)
			}
		}
		fmt.printfln("action_bar=%s action_pop=%d mask_scans=%d", bar_groups, int(k.action_pop), app.mask_seen.scans)
		open := [Kit_Window]bool{.Inspector = k.inspector && !side_panel_open(k), .Stats = k.stats, .History = k.history, .Settings = k.settings, .Help = k.help}
		names := [Kit_Window]string{.Inspector = "inspector", .Stats = "stats", .History = "history panel", .Settings = "settings", .Help = "help"}
		for w, which in k.windows {
			r := ui.prev_rect(&k.ctx, names[which])
			fmt.printf("window_%s=%d,%d,%.0f,%.0f ", strings.to_lower(fmt.tprint(which), context.temp_allocator), int(open[which]), int(w.minimized), r.x, r.y)
		}
		fmt.println()
		// Where the modifier rail and what must stay clear of it ended up, in points, for
		// touch_check's window size scenarios.
		for name in ([?]string{"modifier rail", "sliders", "dock", "status", "inspector", "action bar"}) {
			r := ui.prev_rect(&k.ctx, name)
			key, _ := strings.replace_all(name, " ", "_", context.temp_allocator)
			fmt.printf("layout_%s=%.0f,%.0f,%.0f,%.0f ", key, r.x, r.y, r.w, r.h)
		}
		fmt.println()
	}
	if opts.check_mesh {
		for obj in app.scene.objects {
			if !object_dynamic(obj) {
				geom.mesh_report_print(geom.mesh_check(object_mesh(obj)^))
				continue
			}
			// Without the unused slots of the dynamic layout, which are not part of the surface.
			packed, mask := sculpt.sculptor_compact_mesh(object_sculptor(obj))
			geom.mesh_report_print(geom.mesh_check(packed))
			geom.mesh_destroy(&packed)
			delete(mask)
		}
	}
	for obj in app.scene.objects {
		if hidden := sculpt.sculptor_hidden_count(object_sculptor(obj)); hidden > 0 {
			fmt.printfln("hide object=%d hidden_triangles=%d triangles=%d", obj.id, hidden, object_triangle_count(obj))
		}
	}
	if s := app.stats; s.slice_ms > 0 do fmt.printfln("slice_ms=%.1f slice_setup_ms=%.1f", s.slice_ms, s.slice_setup_ms)
	for obj in app.scene.objects {
		if !object_dynamic(obj) do continue
		splits, collapses := sculpt.sculptor_dyn_edits(object_sculptor(obj))
		fmt.printfln("dyntopo object=%d triangles=%d splits=%d collapses=%d pages=%d gpu_regrows=%d", obj.id, object_triangle_count(obj),
			splits, collapses, sculpt.sculptor_dyn_pages(object_sculptor(obj)), app.stats.gpu_regrows)
	}
	if s := app.stats; s.file_read_ms > 0 || s.file_write_ms > 0 {
		fmt.printfln("file_read_ms=%.1f file_parse_ms=%.1f file_write_ms=%.1f", s.file_read_ms, s.file_parse_ms, s.file_write_ms)
	}
	fmt.printfln("idle_cache=%v cache_redraws=%d last_frame_triangles=%d", app.cache_idle, app.stats.cache_redraws, app.stats.viewport.triangles)
	v := app.stats.viewport
	fmt.printfln("cull=%v last_frame_draws=%d chunks=%d culled_view=%d culled_back=%d cull_ms=%.3f", app.renderer.cull, v.draws, v.chunks, v.culled_view, v.culled_back, v.cull_ms)
	fmt.printfln("partial=%v partial_frames=%d last_frame_partial=%v last_frame_redrawn_px=%d viewport_px=%d", app.renderer.partial, app.stats.partial_frames, v.partial, v.redrawn_px, app.target.width * app.target.height)
	lod_pending := 0
	for obj in app.scene.objects do lod_pending += sculpt.sculptor_lod_pending(object_sculptor(obj))
	fmt.printfln("simplify=%v last_frame_lod_px=%.2f last_frame_simplified=%d lod_pending=%d", app.simplify, app.renderer.lod_px, v.simplified, lod_pending)
	if app.stats.lod_ms.count > 0 do print_stat("lod_build_ms", app.stats.lod_ms)
	print_stat("frame_ms", app.stats.frame_ms)
	print_stat("cpu_ms", app.stats.cpu_ms)
	print_stat("wait_ms", app.stats.wait_ms)
	if app.time_gpu do print_stat("gpu_ms", app.stats.gpu_ms)
	if app.stats.ui_ms.count > 0 {
		print_stat("ui_ms", app.stats.ui_ms)
		fmt.printfln("ui_vertices=%d", app.stats.ui_vertices)
	}
	if app.stats.cursor_ms.count > 0 do print_stat("cursor_ms", app.stats.cursor_ms)
	if app.stats.dabs_total > 0 {
		print_stat("raycast_ms", app.stats.raycast_ms)
		print_stat("brush_ms", app.stats.brush_ms)
		print_stat("normals_ms", app.stats.normals_ms)
		print_stat("upload_kb", app.stats.upload_kb)
		print_stat("latency_ms", app.stats.latency_ms)
	}
	if opts.bench_stroke > 0 {
		// The synthetic stroke never lifts the button: end it, then time undo and redo
		// of the whole stroke, each including the normal update that follows.
		stroke_finish(&app)
		undo_bytes := 0
		for obj in app.scene.objects do undo_bytes += sculpt.sculptor_undo_bytes(object_sculptor(obj))
		t0 := time.tick_now()
		history_undo(&app)
		for obj in app.scene.objects do _ = sculpt.sculptor_flush(object_sculptor(obj))
		t1 := time.tick_now()
		history_redo(&app)
		for obj in app.scene.objects do _ = sculpt.sculptor_flush(object_sculptor(obj))
		fmt.printfln("undo_mb=%.2f undo_ms=%.3f redo_ms=%.3f", f64(undo_bytes) / (1 << 20),
			time.duration_milliseconds(time.tick_diff(t0, t1)), time.duration_milliseconds(time.tick_since(t1)))
		// With levels: step down to the base, carrying the stroke along, then jump back.
		// Each change prints the time to update the levels plus the time to show the new one.
		obj := app.scene.objects[0]
		if start := obj.levels.current; len(obj.levels.levels) > 1 {
			fmt.printf("level_changes_ms=")
			for to := start - 1; to >= -1; to -= 1 {
				from := obj.levels.current
				target := to if to >= 0 else start
				if !object_set_level(&app, obj, target) do return false
				fmt.printf("%d->%d:%.1f+%.1f ", from + 1, target + 1, app.stats.level_sync_ms, app.stats.level_show_ms)
				free_all(context.temp_allocator)
			}
			fmt.println()
		}
	}
	return true
}

// Light samples the studio render builds up to by default, and at most: about a quarter
// of them shadow the key light and the rest give the occlusion.
STUDIO_SAMPLES_DEFAULT :: 256
STUDIO_SAMPLES_MAX :: 1024

// How long the view has to stay put before simplified drawing gives way to full detail.
LOD_SETTLE :: 250 * time.Millisecond

// Whether the camera, the viewport size or any object's transform changed since the
// last call.
view_changed :: proc(app: ^App, view, proj: render.Mat4) -> bool {
	Key :: struct {
		view, proj:    render.Mat4,
		width, height: u32,
	}
	key := Key{view, proj, app.target.width, app.target.height}
	h := hash.fnv64a(slice.bytes_from_ptr(&key, size_of(key)))
	for obj in app.scene.objects {
		t := obj.transform
		h = hash.fnv64a(slice.bytes_from_ptr(&t, size_of(t)), h)
	}
	changed := h != app.view_key
	app.view_key = h
	return changed
}

// Writes RGBA8 pixels as a binary PPM (alpha dropped).
write_ppm :: proc(path: string, rgba: []u8, width, height: int) -> bool {
	out := make([dynamic]u8, 0, width * height * 3 + 32, context.temp_allocator)
	append(&out, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", width, height))
	for i := 0; i < len(rgba); i += 4 do append(&out, rgba[i], rgba[i + 1], rgba[i + 2])
	return os.write_entire_file(path, out[:]) == nil
}
