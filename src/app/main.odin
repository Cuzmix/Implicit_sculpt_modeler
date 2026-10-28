package main

import "core:flags"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:math/linalg"
@(require) import "core:mem" // only used when ODIN_DEBUG
import "core:os"
import "core:path/filepath"
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
import "../voxel"

Options :: struct {
	frames:    int `usage:"Exit after this many frames (0 runs until the window closes)."`,
	no_settings: bool `usage:"Neither read nor write the remembered settings (brush, view, Scene palette choices, the Settings panel); runs with --frames or a benchmark never do."`,
	settings_file: string `usage:"Read and write the remembered settings at this path instead of the per-user folder, scripted runs included (for testing that settings persist)."`,
	coach: bool `usage:"Show the first-run tips from the first one, even in a scripted run (an interactive run shows them until they are done or skipped)."`,
	gpu_debug: bool `usage:"Create the GPU device in debug mode (enables validation where available)."`,
	subdiv:    int `usage:"Icosphere subdivision level (default 6)."`,
	vertices:  int `usage:"Start with a geodesic sphere of about this many vertices instead (e.g. 10000000)."`,
	shape:     string `usage:"Start with this shape instead of spheres: cube, cylinder, cone or torus (of --vertices vertices, 40962 when not given), as the Scene palette's Add object does."`,
	voxels:    int `usage:"Start with a voxel sphere this many voxels across (32 to 1024) instead of a mesh sphere, as Add object with As voxels does; 256 meshes to about 350k vertices, 512 to 1.4M."`,
	threads:   int `usage:"Worker threads for sculpting, including the main thread (default: one per core)."`,
	width:     int `usage:"Initial window width (default 1600)."`,
	height:    int `usage:"Initial window height (default 900)."`,
	spheres:   int `usage:"Start with this many spheres side by side, all of the starting size (default 1)."`,
	subdivide: int `usage:"Give each starting sphere this many subdivision levels above it, as Ctrl+D does (e.g. --vertices=40000 --subdivide=4 tops out at 10M)."`,
	level:     int `usage:"Start on this subdivision level, 1 being the base (default: the top one)."`,
	hd:        int `usage:"Give each starting sphere an HD level this many Loop steps (1 to 3) above its top level, as Divide HD does."`,
	hd_open:   bool `usage:"Start sculpting HD on the first sphere, in a window around the side facing the camera (needs --hd)."`,
	no_cache:  bool `usage:"Draw every object every frame instead of caching the idle ones (for comparison)."`,
	no_cull:   bool `usage:"Draw every triangle instead of skipping off-screen and back-facing chunks (for comparison)."`,
	ui_dt:     f32 `usage:"Move the interface's clock (animations, tooltips, long presses) this many seconds a frame instead of by the time that passed, for scripted runs whose checks must not depend on how fast frames come (scripts/touch_check.py passes 1/60). A stroke then lays every dab its frame's samples ask for, up to 64, however long they take. The 90 ms a finger waits before it sculpts and the right tap that opens the pie stay on the real clock."`,
	ui_events: string `usage:"Drive the pointer, fingers and pen as SDL events would, for tests: FRAME:move:X,Y, FRAME:down, FRAME:up, FRAME:right (a right click), FRAME:mdown, FRAME:mup, FRAME:rdown and FRAME:rup (the middle and right buttons held and let go), FRAME:wheel:N, FRAME:key:NAME (a key press: shift, ctrl, alt held until FRAME:keyup:NAME), FRAME:fdown:ID:X,Y, FRAME:fmove:ID:X,Y, FRAME:fup:ID and FRAME:fcancel:ID (finger ID on a touch screen), FRAME:pdown:X,Y, FRAME:pmove:X,Y, FRAME:pup, FRAME:pnear / FRAME:pfar, FRAME:pright (the pen, the last its side button) and FRAME:ppress:P (the pen's pressure from then on, 0 to 1; 0 until set), separated by semicolons; X and Y in window points."`,
	dump_screen: string `usage:"On exit, write the whole window as the interface drew it (viewport and panels) to this path: a PNG, or a binary PPM when it ends in .ppm."`,
	dump_viewport: string `usage:"On exit, write the last viewport image to this path: a PNG, or a binary PPM when it ends in .ppm (for checking renders), as Menu > Save screenshot does."`,
	check_mesh: bool `usage:"On exit, check every object's current mesh (closed, consistently wound, no degenerate triangles or NaN) and print the counts as mesh_* lines (slow on large meshes)."`,
	no_partial: bool `usage:"Redraw the whole viewport every frame instead of only what changed (for comparison)."`,
	no_trace: bool `usage:"Give the studio render's occlusion and shadow from shadow maps only, never by casting rays at the triangles (for comparison)."`,
	no_simplify: bool `usage:"Draw every chunk at full detail while the view moves too, instead of simplified copies of the far ones (for comparison)."`,
	orbit:     bool `usage:"Turn the camera around the scene by itself, once every 240 frames (to watch or time drawing while the view moves)."`,
	bench_stroke: int `usage:"Run a synthetic brush stroke over this many frames, print brush stats, then exit."`,
	bench_samples: int `usage:"Give each --bench-stroke frame this many pointer samples along the path, like a high-rate mouse (default: one position a frame)."`,
	bench_lifts: int `usage:"Lift the pen of --bench-stroke this many times along its path, so it makes that many strokes plus one (for the History timeline)."`,
	timelapse: string `usage:"Record a time-lapse of the History into this folder, as History > Record time-lapse does: once --bench-stroke ends, or at the start; the run lasts until it is done."`,
	timelapse_steps: int `usage:"Steps of the History each --timelapse frame shows (default 1)."`,
	timelapse_spin: f32 `usage:"Degrees the camera turns each --timelapse frame (default 0)."`,
	turntable: string `usage:"Record a turntable into this folder at the last of the --frames (or once --bench-stroke ends), as Scene > Turntable > Record turntable... does; the run lasts until it is done."`,
	turntable_frames: int `usage:"Frames of the --turntable (24 to 720; default the remembered setting, 120 at first)."`,
	bench_loops: int `usage:"Make --bench-stroke this many circles around the middle of the sphere instead of a wavy line."`,
	density_preview: int `usage:"Show Object > Shape > Rebuild's density checkerboard on the selected object for an even remesh of this many vertices, held on as holding its Density slider shows it (for screenshots and timing)."`,
	bench_tilt: f32 `usage:"Lean the synthetic pen of --bench-stroke this many degrees to the right (with set tilt_strength in a start-up script)."`,
	no_vsync:  bool `usage:"Show each frame as soon as it is ready instead of waiting for the display's refresh, so frame times are not capped at the refresh rate."`,
	idle_sleep: bool `usage:"Rest when idle (Settings > System) in a scripted run too, which otherwise never rests: for testing it."`,
	frame_limit: int `usage:"Draw at most N frames a second (Settings > System > Frame rate > Limit)."`,
	time_gpu:  bool `usage:"Measure the GPU time of the 3D viewport every frame. Waits for the GPU each frame, so frames no longer overlap."`,
	gpubench:  string `usage:"Time the GPU and CPU while orbiting and sculpting one sphere at 500k, 1M, 5M, 7M and 10M vertices (only --vertices when given), with each speed setting on and off; write the markdown tables to this path and exit."`,
	gpu_smooth: bool `usage:"Start with the Object palette's Deformation > On the GPU on, so Smooth all runs as a compute shader (the GPU compute trial)."`,
	compute_bench: string `usage:"Time Smooth all on the CPU and as a GPU compute shader, upload and readback included, at 500k, 1M, 5M, 7M and 10M vertices (only --vertices when given); check the GPU's result against the CPU's, write the markdown tables to this path and exit."`,
	bake:       string `usage:"On exit, bake the first object's detail onto the selected quad object (from retopologize in a start-up script) into this folder, as Bake maps... does (before --export)."`,
	bake_size:  int `usage:"Texels square for --bake (512, 1024, 2048 or 4096; default 2048)."`,
	gpubench_frames: int `usage:"Measured frames per --gpubench case (default 120, at most 240)."`,
	open:      string `usage:"Start with the scene saved in this .sculpt file instead of spheres, as Menu > Open scene... does."`,
	import_mesh: string `args:"name=import" usage:"Start with the mesh in this .obj, .ply or .stl file instead of spheres (after any --open), as Menu > Import mesh... does."`,
	export:    string `usage:"On exit, write the selected object's shown level to this .obj, .ply, .stl, .glb or .usda file, as Menu > Export mesh... does."`,
	export_workspace: string `usage:"On exit, write the current workspace's layout to this .workspace file, as the workspace menu's Export workspace... does."`,
	import_workspace: string `usage:"Read this .workspace file as a new workspace of your own and switch to it on the first frame, as the workspace menu's Import workspace... does."`,
	export_print: string `usage:"On exit, write the selected object to this .stl file at its print size, as Scene > 3D print > Export for printing... does."`,
	save:      string `usage:"On exit, save the scene to this .sculpt file, as Menu > Save scene does."`,
	autosave:  f32 `usage:"Autosave every this many seconds once the scene changed and the app rested, as Settings > System > Autosave does every few minutes; scripted runs only autosave with this or --autosave-folder."`,
	autosave_folder: string `usage:"Keep the autosaves in this folder instead of the app's own (and offer the ones a crashed run left there, as an interactive start does)."`,
	autosave_rest: f32 `usage:"Seconds without a press, key or stroke before an autosave starts (default 1.5)."`,
	check_autosave: bool `usage:"Check that nothing an autosave reads changes while it reads it: the exit stats count it as autosave_torn."`,
	crash_after_autosave: bool `usage:"Exit with code 3 right after the first autosave is written, skipping the clean exit, as a crash would: the kill test of autosave and recovery."`,
	bench_after_autosave: bool `usage:"Start --bench-stroke only once an autosave of the scene as it starts is being written, so the stroke runs while the file is written (the autosave benchmark)."`,
	load_strokes: string `usage:"Load the strokes in this .strokes file and replay them where they were drawn, as the Stroke recorder's Load and Replay do: once --bench-stroke ends, or at the start; the run lasts until they are done."`,
	replay_shift: string `usage:"Replay --load-strokes moved this many pixels right and down from where they were drawn, in the current view, as R at the pointer does, e.g. 120,-40."`,
	instant_replay: bool `usage:"Replay every recorded frame at once instead of one a frame, as the Stroke recorder's Instant does."`,
	record_strokes: bool `usage:"Record every stroke from the start, as the Stroke recorder's Record does (for --save-strokes)."`,
	run:        string `usage:"Run the command script in this file once the window is up, as set-up: commands by name, settings with set, wait and select (README \"Command scripts\"). A script with an error runs none of it and exits with code 2; so does a statement that does nothing in a run with --frames. --frames and the frames of --ui-events count from where it ends."`,
	script:     string `usage:"Run this command script, given here with ; between statements, as --run does a file's."`,
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
	shape_pending: Shape_Pending, // a drawn shape waiting for Apply (shape_pending.odin)
	clip:     Clip_Gesture, // a Ctrl + Shift + drag in progress (clip.odin)
	curve:    Curve_Tool,
	insert:   Insert_Tool,
	gesture:  Gesture_Tool, // what a Ctrl + Shift + drag does
	smooth_gpu: render.Smooth_Compute, // Smooth all's compute shader and buffers, made on first use
	smooth_gpu_failed: bool, // the device refused the compute pipeline; Smooth all stays on the CPU
	// Each brush's drawn or shifted falloff as the sculptor reads it, remade when its curve
	// or focal shift changes.
	falloff_tables: [sculpt.Brush_Kind]struct {
		falloff: sculpt.Falloff,
		shape:   Falloff_Setting,
		built:   bool,
	},
	stroke:   Stroke,
	script:   Script_Run, // the script running: the start-up one (--run, --script), or a macro
	startup_script: Script_Outcome, // how the start-up script went, for the exit stats and files
	macro:    Macro_State, // the recording and the macros kept (macros.odin)
	plugins:  Plugins, // the script plugins and their commands' slots (plugins.odin)
	alphas:   [dynamic]Alpha_Entry, // the brush alphas the Brush palette offers (alphas.odin)
	library:  Library, // the folder that keeps the person's own alphas across starts (library.odin)
	link:     Link, // the live link with Blender (link.odin)
	presets:      [MAX_PRESETS]Brush_Preset, // the user's brush presets (presets.odin), the first preset_count in use
	preset_count: int,
	built_in:     [len(BUILT_IN_PRESETS)]Brush_Preset, // the built-in presets (builtin_presets.odin), each made on first use
	// The user's key changes (keymap.odin), and the bindings in effect built from them.
	key_overrides:      [MAX_KEY_OVERRIDES]Key_Override,
	key_override_count: int,
	bindings:           [MAX_BINDINGS]Binding,
	binding_count:      int,
	stroke_seed: u64, // the seed the next stroke takes (Stroke.seed), one more each stroke
	// The strength scale the next stroke takes (Stroke.scale) when above 0, as a replay
	// or a waiting tap sets it; 0 takes it from the pointer.
	stroke_scale_from: f32,
	stroke_end:  Stroke_End, // where the last stroke ended, for Join strokes
	samples:  [dynamic]Input_Sample, // this frame's pointer samples, in window coordinates
	pen_pressure: f32, // the pen's latest pressure
	pen_tilt: [2]f32, // the pen's latest lean in degrees, x to the right and y down
	pen_seen: bool,
	// How far the pen turned about its own length this frame, degrees clockwise, where the
	// platform reports it (pen_roll_take), and the turn it last reported.
	pen_roll: f32,
	pen_roll_last: Maybe(f32),
	// The first-run tips (kit_coach.odin): whether this run shows them, and the steps
	// done since the card last moved on.
	coach_run:  bool,
	coach_seen: bit_set[Coach_Step],
	coach_touch: f32, // how far two fingers moved or pinched in this touch, in points
	finger_seen: bool, // a finger touched the screen this run
	touch:    Touch, // fingers and the pen on a touch screen (touch.odin)
	rail:     Modifier_Rail, // Smooth, Invert, Mask and Hide as buttons (modifiers.odin)
	drag:     Drag, // who the press on the viewport belongs to (navigate.odin)
	dab_wait: Dab_Wait, // a finger tap's dab waiting for a second tap (navigate.odin)
	pivot:    Stroke_Pivot, // the last stroke's middle, which orbits turn about (navigate.odin)
	orbit_sign: f32, // the single-axis orbit's way round for the turn under way (orbit_latch)
	double_tap: Double_Tap, // the last finger tap a double tap could follow (navigate.odin)
	one_tap:  f64, // input_clock when a one-finger tap waiting to run lifted, 0 for none (one_tap_wait)
	one_taps: int, // one-finger taps that ran their gesture, for the exit stats
	cursor:   Brush_Cursor, // the surface under the brush ring this frame (cursor.odin)
	mask_seen: Mask_Seen, // whether the selected object has a mask, kept (history.odin)
	sets_lost: int, // selection sets a rebuild dropped, for the note of the command that ran it (selection_sets.odin)
	sets_noted: int, // how many the last such note named, for the exit stats
	// Sculpt layers a rebuild carried onto the new mesh, and those that went with the old
	// one's other levels, for the note of the command that ran it (scene.odin).
	layers_kept: int,
	layers_lost: int,
	layers_noted: int, // how many the last such note said were kept, for the exit stats
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
	// Counts the changes to what a scene file stores that the History does not list (a
	// sculpt layer's name, UVs laid out again), for the autosave's fingerprint.
	scene_edits: u64,
	// Changes to which objects are shown (scene_tree.odin): saved, so autosave counts them,
	// but no edit, so Adjust last operation stays offered across them.
	view_edits:  u64,
	adjustable: Adjustable, // the last operation, to run again with other settings (adjust_last.odin)
	views:      Camera_History, // the views the camera rested on, for Previous and Next view (camera_history.odin)
	rebuild:    Rebuild_Preview, // the Rebuild panel's density checkerboard (rebuild.odin)
	autosave: Autosave, // the background autosave and crash recovery (autosave.odin)
	preview:  Scene_Preview, // the picture scene files keep for the Home screen (scene_preview.odin)
	home:     Home, // the Home screen's pictures and autosaves (home.odin)
	thumbnail: Picture, // the second view's picture (thumbnail.odin)
	panes:     [GRID_VIEWS]Picture, // the view panes' pictures (grid.odin)
	work_still: render.Viewport_Target, // what the main pane holds while a view pane is worked in (grid_work)
	pictures_drawn: int, // second-view pictures drawn this frame (picture_frame)
	capture:   Capture, // a transparent screenshot waiting for its frame (capture.odin)
	turntable: Turntable, // Scene > Turntable's recording (turntable.odin)
	turntable_frames: i32, // how many frames it takes, remembered
	print_unit:    Print_Unit, // Scene > 3D print's unit, remembered
	print_exports: int, // files exported for printing, for the exit stats
	repair:        Repair_Stats, // Modify topology's repairs, for the exit stats
	// The scenes saved or opened lately, newest first, at most HOME_RECENT_MAX (remembered).
	recent_scenes: [dynamic]string,
	start_home: bool, // an interactive run given no scene starts on Home (Settings > Interface)
	timeline: Timeline, // the History panel's scrubbing, playback and time-lapse (timeline.odin)
	replay:   Replay, // the Stroke recorder's last stroke, recording and replay (replay.odin)
	// View > Studio render (Shift+R): ambient occlusion and soft shadows built up while
	// the view stays still (render.Studio).
	studio:         render.Studio,
	// Remembered; a device that cannot run it leaves it on and shows the plain viewport
	// (studio_running), so a failure never saves as "off".
	studio_on:      bool,
	studio_samples: i32, // samples it stops at
	studio_ao:      f32, // how strongly occlusion darkens, 0 to 1
	studio_shadow:  f32, // ...and the key light's shadow
	studio_softness: f32, // the key light's radius in radians, how soft its shadow's edge is
	// Scene > Studio render > Occlusion while working (live_ao.odin): screen-space ambient
	// occlusion every frame, with studio_ao's strength.
	live_ao:        render.Live_AO,
	live_ao_on:     bool,
	live_ao_reach:  f32, // a share of the scene's radius
	// Scene > Render (render_mode.odin): the view path traced while it stays still. Not
	// remembered; its samples and bounces are.
	path:           render.Path_Render,
	render_on:      bool,
	render_samples: i32,
	render_bounces: i32,
	render_denoise: bool,
	render_half:    bool, // trace at half size each way: on by default on tablets
	// Scene > Lens (lens.odin): depth of field and its Blur, remembered, and the point
	// Pick focus took, for the session (none: the pivot).
	render_dof:     bool,
	render_blur:    f32,
	focus:          Maybe(Vec3),
	// The navigation head in the top-right corner (nav_head.odin), and the texture it was
	// drawn into this frame, for the interface to show; nil when there is none.
	nav_head:       render.Nav_Head,
	nav_shown:      ^sdl.GPUTexture,
	// The Objects card's pictures of objects (object_thumbs.odin): the atlas they are drawn
	// into and which object each of its cells shows.
	thumbs:         render.Thumbs,
	thumb_slots:    Thumb_Slots,
	// An object copied with Copy, as the scene file stores it, for Paste (scene_paste);
	// kept across new scenes, as a clipboard is.
	clipboard:      [dynamic]u8,
	// Objects Split made, objects Merge took, and objects Align and Distribute moved, for
	// the exit stats (split_merge.odin).
	split_made, merged, aligned: int,
	material:  int,  // the index in MATERIALS objects are shaded with, or CUSTOM_MATERIAL
	custom:    Material, // what the Material section's sliders made
	// The built-in matcaps' textures (nil where the device refused one), and the image
	// loaded with Load MatCap with its path ("" for none).
	matcaps:      [len(MATCAP_RECIPES)]^sdl.GPUTexture,
	matcap_image: ^sdl.GPUTexture,
	matcap_path:  string,
	// The image environment the physically based materials light with (environment.odin).
	env:       Environment_State,
	flat:      bool, // shade with each triangle's own normal (faceted) instead of smoothed normals
	// What objects with texture maps show of them (textures.odin): .Off draws them as clay.
	texture_view: render.Texture_View,
	texture_decodes: int, // texture decode threads running: one at a time
	// Polyframe (the Wireframe command): while on, the selected object shows its edges when
	// `polyframe_lines` is set and its polygroups' colours when `polyframe_fill` is.
	wireframe:       bool,
	polyframe_lines: bool,
	polyframe_fill:  bool,
	floor:           Floor_Settings, // the floor grid (floor_grid.odin)
	floor_state:     Floor_State,
	background:      Background_Settings, // the viewport's background (background.odin)
	// Screenshots on a see-through ground (capture.odin).
	screenshot_transparent: bool,
	sym_center:      Symmetry_Center, // local symmetry's middle, kept (symmetry.odin)
	// Transparency: every shown object but the selected one is drawn see-through, at
	// SEE_THROUGH_OPACITY, so the selected one shows through whatever stands before it.
	see_through:     bool,
	// How the viewport shows its shading (View > Material): brighter or darker in stops,
	// creases darkened and crests lightened by the surface's curvature, 0 to 1 each.
	exposure:  f32,
	cavity:    f32,
	ridge:     f32,
	// The shading's style (render.Draw_Item.style, viewport_style): while on, a rim of
	// strength `rim` and `underside` of the ambient light under the forms; off, the classic
	// rim and an even ambient light.
	styled:    bool,
	// Scene > Look (look.odin): a preset was put on, by hand or on the first run; the
	// settings keep it, so the first run's happens once.
	look_chosen: bool,
	rim:       f32,
	underside: f32,
	// The lights (lights.odin; the scene's own are Scene.lights): those a new scene starts
	// with, which the settings keep, the one the Lights section edits, and the turn of the
	// camera's lights and the studio about the up axis and up or down in degrees.
	start_lights:             Light_Set,
	light_pick:               int,
	light_turn, light_height: f32,
	// Objects other than the selected one show their material's muted colour (on by
	// default), so the one being sculpted stands out; off, each shows its own colour.
	dim_others:               bool,
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
	frame_rate:  Frame_Rate, // how often to draw (frame_rate.odin), applied at the start of the next frame
	frame_limit: i32,        // frames a second at most, for Frame_Rate.Limit
	pacer:       Frame_Pacer,
	idle_sleep:  bool, // rest between frames while nothing changes (idle.odin)
	idle:        Idle,
	msaa:     Msaa, // wanted anti-aliasing, applied before the next frame sizes the viewport (msaa.odin)
	time_gpu: bool, // wait for each frame's 3D work, to measure its GPU time
	window:   ^sdl.Window, // what file dialogs belong to
	scene_path: string, // where the scene was last saved or opened from, for Ctrl+S (owned)
	saving:     File_Request, // a big save waiting a few frames for its "Saving..." toast to show (save_pending)
	saving_at:  f64, // the interface time it started waiting
	versions_kept: i32, // earlier saves kept beside a scene file (versions.odin), 0 for none
	undo_steps:    i32, // undo steps the History keeps (history_cap), 0 for no limit but memory's
	versions:   [dynamic]Version_Row, // the scene file's earlier saves, newest first (versions_refresh)
	saved_fp:   u64, // scene_fingerprint when the scene last matched its file (autosave_scene_saved)
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
	exit_code := 0
	ok := run(opts, &exit_code)

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
	if exit_code != 0 do os.exit(exit_code)
}

// The app, from start to exit. False on a failure (exit code 1); a run that ends as it
// should with another code, as a script with an error does, sets `exit_code`.
run :: proc(opts: Options, exit_code: ^int) -> bool {
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
	// The script is read and checked before the scene is set up, so one with an error
	// stops before the slow part; it runs once the frame loop has laid out the viewport.
	// The GPU benchmark makes its own scenes, case by case, which a script would not see.
	if (opts.run != "" || opts.script != "") && opts.gpubench != "" {
		fmt.eprintln("script: --gpubench sets its own scenes up; it takes no --run or --script")
		exit_code^ = 2
		return true
	}
	if !script_load(&app, opts.run, opts.script, opts.frames > 0 || opts.bench_stroke > 0) {
		exit_code^ = 2
		return true
	}
	defer script_unload(&app)
	defer macros_destroy(&app)
	defer delete(app.scene_path)
	defer file_request_free(app.saving)
	defer {
		versions_free(&app)
		delete(app.versions)
	}
	defer file_shutdown(&app)
	defer results_destroy(&app)
	if !render.renderer_init(&app.renderer, window, opts.gpu_debug) do return false
	defer render.renderer_destroy(&app.renderer)
	matcaps_create(&app)
	defer matcaps_destroy(&app)
	defer environment_destroy(&app)
	defer render.smooth_compute_destroy(&app.renderer, &app.smooth_gpu)
	defer render.studio_destroy(&app.renderer, &app.studio)
	defer render.live_ao_destroy(&app.renderer, &app.live_ao)
	defer render.path_render_destroy(&app.renderer, &app.path)
	defer render.nav_head_destroy(&app.renderer, &app.nav_head)
	defer render.thumbs_destroy(&app.renderer, &app.thumbs)
	defer delete(app.clipboard)

	jobs.pool_init(&app.pool, opts.threads - 1 if opts.threads > 0 else 0)
	defer jobs.pool_destroy(&app.pool)
	log.infof("sculpt threads: %d", jobs.pool_size(&app.pool))
	if opts.compute_bench != "" do return computebench_run(&app, opts.compute_bench, opts.vertices)
	app.scene.selected = -1
	defer render.mesh_buffers_destroy(&app.renderer, &app.ui.boolean.preview)
	defer geom.mesh_destroy(&app.ui.boolean.preview_mesh)
	defer boolean_coarse_drop(&app)
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
	defer shape_pending_destroy(&app.shape_pending)
	defer rebuild_preview_destroy(&app.rebuild)
	defer curve_tool_destroy(&app.curve)
	app.hd_window_vertices = sculpt.HD_WINDOW_VERTICES
	// Before a scene opens, which keeps the starting lights for the rest of the lights it
	// lists; the settings file brings back what earlier runs chose further down.
	lights_reset(&app)
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
	if opts.voxels != 0 && (opts.voxels < VOXELS_MIN || opts.voxels > VOXELS_MAX) {
		log.errorf("--voxels=%d: a voxel sphere is %d to %d voxels across", opts.voxels, VOXELS_MIN, VOXELS_MAX)
		return false
	}
	for _ in 0 ..< starting {
		t := Transform{position = next_free_position(&app), scale = 1}
		if opts.voxels > 0 {
			if !scene_add_voxel_sphere(&app, opts.voxels, t) do return false
		} else if shape == .Sphere {
			if !scene_add_sphere(&app, opts.vertices, opts.subdiv, t) do return false
		} else {
			if !scene_add_primitive(&app, shape, opts.vertices if opts.vertices > 0 else 40962, t) do return false
		}
	}
	for obj in app.scene.objects {
		// A voxel object has no levels to divide.
		if obj.voxel != nil do continue
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
	defer render.viewport_target_destroy(&app.renderer, &app.target)
	app.camera = camera.orbit_default()
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
	app.polyframe_lines = true
	app.floor = FLOOR_DEFAULT
	app.background = BACKGROUND_DEFAULT
	// Custom starts as PBR clay, the last physically based preset, until a slider changes it.
	app.custom = MATERIALS[FIRST_MATCAP - 1]
	app.custom.label = "Custom"
	app.renderer.cull = !opts.no_cull
	app.renderer.partial = !opts.no_partial
	app.renderer.trace = !opts.no_trace
	app.simplify = !opts.no_simplify
	app.simplify_px = 1
	app.frame_rate = .Unlimited if opts.no_vsync || opts.gpubench != "" else .Match_Display
	app.frame_limit = FRAME_LIMIT_DEFAULT
	app.idle_sleep = true
	app.start_home = true
	app.idle.forced = opts.idle_sleep
	app.msaa = MSAA_DEFAULT
	// Before the settings file, which brings back what earlier runs chose.
	app.cavity, app.ridge = CAVITY_DEFAULT, RIDGE_DEFAULT
	app.rim, app.underside = RIM_DEFAULT, UNDERSIDE_DEFAULT
	app.studio_softness = render.STUDIO_KEY_SOFTNESS
	app.studio_samples, app.studio_ao, app.studio_shadow = STUDIO_SAMPLES_DEFAULT, STUDIO_AO_DEFAULT, STUDIO_SHADOW_DEFAULT
	app.render_samples, app.render_bounces, app.render_denoise = render.RENDER_SAMPLES_DEFAULT, render.RENDER_BOUNCES_DEFAULT, true
	app.render_half = ODIN_PLATFORM_SUBTARGET == .Android
	app.render_blur = RENDER_BLUR_DEFAULT
	app.turntable_frames = TURNTABLE_FRAMES_DEFAULT
	environment_settings_default(&app)
	app.dim_others = true
	app.time_gpu = opts.time_gpu || opts.gpubench != ""
	app.ui = ui_state_default()
	app.curve, app.insert = CURVE_DEFAULTS, INSERT_DEFAULTS
	app.brush = {kind = .Draw, radius_px = DEFAULT_RADIUS_PX, pressure_strength = true, pressure_curve = geom.CURVE_LINEAR, detail_px = 10, collapse = true, alpha = -1, color = {0.75, 0.2, 0.15}, color2 = {0.95, 0.92, 0.85}, spray_spread = SPRAY_DEFAULT_SPREAD, spacing = DAB_SPACING, radial_count = RADIAL_DEFAULT, radial_axis = .Y}
	for &s, kind in app.brush.strengths do s = BRUSHES[kind].strength
	app.nav = NAV_DEFAULT
	app.autosave.minutes = AUTOSAVE_DEFAULT_MINUTES
	app.versions_kept = VERSIONS_DEFAULT
	// What earlier interactive runs left; a start-up script runs after it and wins over it.
	remember := (opts.frames == 0 && opts.gpubench == "" && opts.bench_stroke == 0 && !opts.no_settings) || opts.settings_file != ""
	settings := (opts.settings_file if opts.settings_file != "" else settings_path()) if remember else ""
	if remember do settings = strings.clone(settings)
	defer delete(settings)
	// The alphas come first, the library's too, so that presets and the brush in the
	// settings find the alphas they name.
	alphas_init(&app)
	defer alphas_destroy(&app)
	library_load(&app, library_folder(settings))
	// Runs after settings_save and the scene's last use, which read the pack materials'
	// names, and before the renderer goes, which their textures need: keep it here.
	defer library_destroy(&app)
	settings_load(&app, settings)
	// The benchmarks measure the viewport filling the window, so their numbers stay
	// comparable whatever grid a workspace keeps.
	if opts.bench_stroke > 0 || opts.gpubench != "" do app.kit.grid.preset = .Single
	// Only for the settings of everyday use: a run with a settings file of its own (a test's)
	// keeps the code's look unless the file says otherwise.
	if remember && opts.settings_file == "" do look_first_run(&app)
	// The first scene is lit by the starting lights, as every new one is, unless it was
	// opened from a file that keeps its own.
	if !app.scene.lights_own do app.scene.lights = app.start_lights
	app.settings_file = settings
	// Macros are kept beside the settings, so a run that keeps no settings keeps none.
	macros_load(&app, macros_folder(settings))
	// Plugins too, after the settings, which remember which slot each command has.
	plugins_load(&app, plugins_folder(settings))
	defer plugins_destroy(&app)
	// The focus check only where a person switches windows: a scripted run's focus
	// comes and goes with the test machine's windows, which no check may depend on.
	link_init(&app, link_folder(settings), opts.frames == 0 && opts.gpubench == "" && opts.bench_stroke == 0 && opts.compute_bench == "" && opts.run == "" && opts.script == "")
	defer link_destroy(&app)
	app.coach_run = (remember && opts.frames == 0) || opts.coach
	if opts.coach do app.kit.coach = 0
	app.kit.fixed_dt = opts.ui_dt
	if opts.no_vsync do app.frame_rate = .Unlimited
	if opts.frame_limit > 0 do app.frame_rate, app.frame_limit = .Limit, i32(clamp(opts.frame_limit, FRAME_LIMIT_MIN, FRAME_LIMIT_MAX))
	app.ui.smooth_on_gpu = opts.gpu_smooth
	if opts.bake_size > 0 do app.ui.bake.size = i32(opts.bake_size)
	// Freed after the settings are saved at exit, which write them.
	defer {
		for s in app.recent_scenes do delete(s)
		delete(app.recent_scenes)
	}
	defer if remember do _ = settings_save(&app, settings)
	interactive := opts.frames == 0 && opts.gpubench == "" && opts.bench_stroke == 0 && opts.compute_bench == ""
	autosave_init(&app, interactive, f64(opts.autosave), opts.autosave_folder, f64(opts.autosave_rest), opts.check_autosave, opts.crash_after_autosave)
	defer autosave_destroy(&app)
	defer scene_preview_destroy(&app)
	defer home_destroy(&app)
	defer thumbnail_destroy(&app)
	defer grid_destroy(&app)
	defer capture_destroy(&app)
	defer turntable_destroy(&app)
	// After autosave_init, whose folder Home's Autosaves lists.
	if home_at_start(&app, opts, interactive) do home_open(&app)
	// Read on the first frame, as a file picked in the dialog is.
	if opts.import_workspace != "" do file_post(.Import_Workspace, opts.import_workspace)
	// The benchmark's autosave writes the scene it starts with.
	if opts.bench_after_autosave do app.autosave.clean = 0
	if opts.density_preview > 0 {
		app.ui.rebuild_goal, app.ui.rebuild_even, app.rebuild.pinned = .Even, rebuild_count(opts.density_preview), true
	}
	app.live_ao_reach = LIVE_AO_REACH_DEFAULT
	app.stroke_seed = 1
	app.tool = .Brush
	app.running = true
	frame_index := 0
	bench_skipped := 0 // frames --bench-after-autosave held the stroke back
	// The previous frame's, kept while timing the GPU so the next frame can wait for it.
	present_fence: ^sdl.GPUFence
	defer if present_fence != nil {
		_ = sdl.WaitForGPUFences(app.renderer.device, true, &present_fence, 1)
		sdl.ReleaseGPUFence(app.renderer.device, present_fence)
	}

	// Only a run a person drives rests when idle; a scripted one keeps every frame.
	driven := interactive && opts.run == "" && opts.script == "" && opts.ui_events == "" && opts.load_strokes == "" && opts.timelapse == "" && !opts.orbit
	for app.running {
		idle_rest(&app, driven)
		frame_start := time.tick_now()
		// A waiting save or export goes first: before a scene command or file request
		// changes what it would write. A second Save during a save (Ctrl+S again) is
		// dropped by file_apply.
		file_next := file_pending_kind()
		saves := bit_set[File_Kind]{.Save, .Save_Copy}
		save_pending(&app, app.ui.scene_command.kind != .None || (file_next != .None && !(file_next in saves && app.saving.kind in saves)))
		if command := app.ui.scene_command; command.kind != .None {
			app.ui.scene_command = {}
			autosave_settle(&app)
			// A command being recorded counts once it changed the scene (macros.odin).
			before := script_scene_state(&app) if app.macro.pending.active else {}
			if !scene_run(&app, command) do return false
			if app.macro.pending.active do macro_settle(&app, script_scene_state(&app) != before)
		}
		library_frame(&app)
		link_frame(&app)
		if req, ok := file_take(&app); ok {
			autosave_settle(&app)
			inspector_drags_end(&app)
			applied := file_apply(&app, req)
			file_request_free(req)
			if !applied do return false
		}
		// Whatever changed the scene last frame (a command, a file, an undo), the
		// selection stays on an object in view and in reach.
		scene_folders_normalize(&app)
		scene_selection_fix(&app)
		materials_settle(&app)
		textures_settle(&app)
		if !script_frame(&app) do return false
		if !plugins_frame(&app) do return false
		// Until the script is done its frames are set-up: the run's own count from where
		// it ends (--frames, the bench stroke, --load-strokes, --timelapse, --ui-events).
		setting_up := app.script.running && app.script.setup
		if opts.timelapse != "" && frame_index == opts.bench_stroke && !setting_up {
			if opts.timelapse_steps > 0 do app.timeline.lapse.steps = i32(opts.timelapse_steps)
			app.timeline.lapse.spin = opts.timelapse_spin
			timelapse_start(&app, opts.timelapse)
		}
		// At the run's last frame, so that what led up to it (a script, a stroke) is done.
		if opts.turntable != "" && frame_index == max(opts.frames - 1, opts.bench_stroke, 0) && !setting_up && !turntable_recording(&app) && app.turntable.frame == 0 {
			if opts.turntable_frames > 0 do app.turntable_frames = i32(opts.turntable_frames)
			turntable_start(&app, opts.turntable)
		}
		if opts.load_strokes != "" && frame_index == max(opts.bench_stroke, LOAD_STROKES_FRAME) && !setting_up {
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
		turntable_frame(&app)
		history_cap(&app)
		// A point or spot light a script or an undo just made gets its place.
		lights_settle(&app)
		camera_history_frame(&app)
		// Wait for the display, or the frame rate limit, and while timing the GPU for the
		// previous frame too, before reading input: the frame then shows the newest input
		// rather than input that sat through the wait. Changing the present mode recreates
		// the swapchain, so frame_pace runs before this frame acquires a swapchain texture.
		wait_start := time.tick_now()
		frame_pace(&app, window)
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
		app.pen_roll = 0
		device_frame_begin(&app.device)
		// Scripted events count from the end of the set-up, and none go in before it.
		if !setting_up do kit_events_push(&app, window)
		e: sdl.Event
		for sdl.PollEvent(&e) {
			app.idle.events += 1
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
			// A held backquote peeks at the last other pass (passes.odin) until it is let go;
			// once it went down outside typing, its release is the peek's too.
			if (e.type == .KEY_DOWN || e.type == .KEY_UP) && e.key.key == sdl.K_GRAVE {
				ps := &app.kit.passes
				if ps.key_held || (e.key.down && !typing(&app)) {
					ps.key_held = e.key.down
					continue
				}
			}
			if e.type == .WINDOW_FOCUS_LOST do app.kit.passes.key_held = false
			device_event(&app.device, &e)
			dab_wait_event(&app, &e, window)
			touch_event(&app, &e, window)
			#partial switch e.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				app.running = false
			case .WINDOW_FOCUS_GAINED:
				link_focus(&app)
			case .DID_ENTER_FOREGROUND:
				// The window comes back with a new surface, which has to ask for its frame rate again.
				app.pacer.voted_window = nil
				app.preview.background = false
			case .DID_ENTER_BACKGROUND:
				// The system may end the app from the background without another word.
				if app.settings_file != "" do _ = settings_save(&app, app.settings_file)
				app.autosave.background = true
				app.preview.background = true
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
				case .ROTATION:
					pen_roll_take(&app, e.paxis.value)
				}
				app.pen_seen = true
			case .PEN_PROXIMITY_OUT:
				// A pen brought back may be turned otherwise: its first report starts afresh.
				app.pen_roll_last = nil
			}
		}
		device_frame_end(&app.device)
		// Nothing below may change the scene while the autosave thread reads it.
		autosave_guard(&app)

		// Resize to the size the interface asked for last frame, before it references the
		// texture, so it never draws a texture released this frame.
		want := app.ui.viewport_request
		msaa_apply(&app)
		if !msaa_viewport_resize(&app, u32(want.x), u32(want.y)) do return false

		// A tap's dab that waited for a second tap plays before anything this frame does.
		waited_dab := dab_wait_resolve(&app)
		ui_start := time.tick_now()
		input := kit_frame(&app, window)
		if !grid_work_gpu(&app) do return false
		ring_push(&app.stats.ui_ms, time.duration_milliseconds(time.tick_since(ui_start)))
		bench_waits := opts.bench_after_autosave && app.autosave.written == 0 && !autosave_writing(&app)
		if bench_waits && !setting_up do bench_skipped += 1
		bench_frame := frame_index - bench_skipped
		if opts.bench_stroke > 0 && bench_frame < opts.bench_stroke && !bench_waits && !setting_up {
			input = bench_input(&app, bench_frame, opts.bench_stroke, opts.bench_samples, opts.bench_loops, {opts.bench_tilt, 0}, {f32(app.target.width), f32(app.target.height)})
			// A lifted frame ends the stroke; the next frame presses again.
			if every := opts.bench_stroke / (opts.bench_lifts + 1); opts.bench_lifts > 0 && every > 0 && (bench_frame + 1) % every == 0 {
				input.primary = false
			}
			app.device.input_at = sdl.GetTicksNS()
		} else if opts.gpubench != "" {
			input = gpubench_input(&app, &bench, {f32(app.target.width), f32(app.target.height)})
			app.device.input_at = sdl.GetTicksNS()
		}
		camera_apply_input(&app, input)
		if opts.orbit && !setting_up do camera.orbit_spin(&app.camera, 2 * math.PI / 240)
		sculpted: Sculpt_Frame_Result
		shape_pending_frame(&app, input.size)
		// A gizmo drag the tool changed under ends as it is.
		if app.tool != .Move do move_end(&app)
		// A press that picks a polygroup for its material (Pick a group), a colour (the
		// Eyedropper) or the point in focus (Pick focus), or moves a light in the
		// viewport, is no tool's.
		if group_pick_frame(&app, input) || eyedropper_frame(&app, input) || focus_pick_frame(&app, input) || lights_viewport_frame(&app, input) {
			brush_stroke_finish(&app)
		} else {
			switch app.tool {
			case .Brush:
				if clip_frame(&app, input) || mask_shape_frame(&app, input) {
					brush_stroke_finish(&app)
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
				brush_stroke_finish(&app)
				move_tool_frame(&app, input)
			case .Curve:
				brush_stroke_finish(&app)
				if !curve_tool_frame(&app, input) do return false
			case .Insert:
				brush_stroke_finish(&app)
				if !insert_tool_frame(&app, input) do return false
			}
		}
		sculpted.dabs += waited_dab.dabs
		sculpted.raycast_ms += waited_dab.raycast_ms
		sculpted.brush_ms += waited_dab.brush_ms
		cursor_update(&app, input)
		draw_viewport_overlay(&app, input)
		// No pass is open yet, so a pack matcap first shown this frame can be uploaded
		// (with its own command buffer) and drawn with now.
		pack_matcaps_settle(&app)
		// Likewise a finished environment decode, whose prefilter has its own.
		_ = environment_poll(&app)

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
			if vp := obj.voxel; vp != nil {
				// A voxel object draws its clay's surface, remeshed where the frame's dabs landed.
				t_flush := time.tick_now()
				bytes, damage, uploaded_ok := voxel_upload(&app, cmd, obj, vp)
				normals_ms += time.duration_milliseconds(time.tick_since(t_flush))
				if !uploaded_ok {
					_ = sdl.SubmitGPUCommandBuffer(cmd)
					_ = sdl.SubmitGPUCommandBuffer(present_cmd)
					return false
				}
				uploaded += bytes
				if !object_shown(&app, obj) || boolean_hides(&app, obj, i) || len(vp.clay.surface.chunks) == 0 do continue
				color, live, selected := object_draw_tint(&app, obj, i)
				material := object_material(&app, obj)
				append(&draws, render.Draw_Item {
					mesh      = &vp.gpu,
					model     = transform_matrix(obj.transform),
					color     = color,
					material  = material.shading,
					surface   = {material.metallic, material.roughness},
					flat      = app.flat,
					look      = object_look(&app, selected),
					style     = viewport_style(&app),
					matcap    = material_matcap(&app, material),
					lights    = viewport_lights(&app),
					wireframe = selected && app.wireframe && app.polyframe_lines,
					live      = live,
					source    = &vp.clay.surface.mesh,
					chunks    = vp.clay.surface.chunks[:],
					damage    = damage,
				})
				continue
			}
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
				// The textured preview follows the base level as this frame uploaded it.
				textured: ^render.Textured_Mesh
				if part == 0 do textured = texture_preview_frame(&app, cmd, obj, gpu)
				// Simplified copies are built a batch a frame, for one level at a time, and
				// never during a stroke, whose frames should stay as short as they can be.
				if app.simplify && !app.stroke.active && lod_ms < 0 && sculpt.sculptor_lod_pending(&lv.sculptor) > 0 {
					t_lod := time.tick_now()
					lod_ranges, all := sculpt.sculptor_lod_update(&lv.sculptor, app.lod_finish)
					render.mesh_buffers_upload_lod(&app.renderer, cmd, gpu, lv.sculptor.lod.indices[:], lod_ranges, all, len(lv.mesh.indices) / 2)
					lod_ms = time.duration_milliseconds(time.tick_since(t_lod))
				}
				// An object out of view still uploads above, so it is current when shown again.
				if !object_shown(&app, obj) do continue
				// The live boolean's preview stands in for it (drawn below).
				if boolean_hides(&app, obj, i) do continue
				color, live, selected := object_draw_tint(&app, obj, i)
				material := object_material(&app, obj)
				if textured != nil do color = textured_color(color, material, app.texture_view == .Textured && textured.maps[.Base_Color] != nil)
				append(&draws, render.Draw_Item {
					mesh   = gpu,
					textured = textured,
					texture_view = app.texture_view if textured != nil else .Off,
					model  = transform_matrix(obj.transform),
					color  = color,
					material = material.shading,
					surface = {material.metallic, material.roughness},
					flat = app.flat,
					look = object_look(&app, selected),
					style = viewport_style(&app),
					lights = viewport_lights(&app),
					matcap = material_matcap(&app, material),
					wireframe = selected && app.wireframe && app.polyframe_lines,
					paint  = sculpt.sculptor_has_color(&lv.sculptor) && !obj.paint_off,
					groups = (app.show_groups || selected && app.wireframe && app.polyframe_fill) && sculpt.sculptor_has_groups(&lv.sculptor),
					// The HD window's mesh carries no groups.
					slots  = object_material_slots(&app, obj, i) if part == 0 && sculpt.sculptor_has_groups(&lv.sculptor) else nil,
					live   = live,
					source = &lv.mesh,
					chunks = lv.sculptor.chunks,
					chunk_groups = sculpt.sculptor_chunk_groups(&lv.sculptor),
					damage = lv.sculptor.changed_bounds,
					// A textured item's wireframe follows its full triangles, never a simplified copy.
					lod    = lv.sculptor.lod.tree if textured == nil else {},
					hidden = sculpt.levels_hd_hidden(&obj.levels) if part == 0 && obj.levels.hd.window != nil else sculpt.sculptor_hidden_units(&lv.sculptor),
				})
			}
		}
		// After the uploads, so the preview measures the mesh as this frame draws it.
		if checker := rebuild_preview_frame(&app); checker != {} {
			for &d in draws do if d.live do d.checker = checker
		}
		if b := &app.ui.boolean; b.shown {
			if base := object_by_id(&app, b.base); base != nil && object_shown(&app, base) {
				material := object_material(&app, base)
				color := material.selected
				if _, ghost := object_flags(&app, base); ghost do color.rgb *= GHOST_SHADE
				append(&draws, render.Draw_Item {
					mesh     = &b.preview,
					source   = &b.preview_mesh,
					model    = transform_matrix(base.transform),
					color    = color,
					material = material.shading,
					surface  = {material.metallic, material.roughness},
					flat     = app.flat,
					look     = viewport_look(&app),
					style    = viewport_style(&app),
					lights   = viewport_lights(&app),
					matcap   = material_matcap(&app, material),
					damage   = geom.AABB_EMPTY,
				})
			}
		}
		aspect := f32(app.target.width) / f32(app.target.height)
		view, proj := camera.orbit_view(app.camera), camera.orbit_proj(app.camera, aspect)
		// The main view's role lent to a view pane or given back is no turn of the view: what
		// either pane shows was already at rest, so neither is simplified for it.
		travelled := app.kit.grid.work_began || app.kit.grid.work_ended != 0
		if view_changed(&app, view, proj) && !travelled do app.view_moved = time.tick_now()
		moving := time.tick_since(app.view_moved) < LOD_SETTLE
		app.renderer.lod_px = app.simplify_px if app.simplify && moving && !timelapse_capturing(&app) && !turntable_recording(&app) else 0
		app.renderer.floor = floor_grid_frame(&app)
		app.renderer.background = background_frame(app.background)
		environment_view(&app)
		// A pass with a ground of its own shows it instead of the background or the
		// environment's image, and a Silhouette stands on nothing, as the thumbnail's does.
		app.kit.passes.recording = timelapse_capturing(&app) || turntable_recording(&app)
		shown_pass := viewport_pass(&app.kit)
		if wipe_shown(&app.kit) {
			pass_items(draws[:], view, shown_pass, wipe_right(&app.kit), wipe_line_px(app.kit.passes.wipe_at, app.target.width))
		} else {
			pass_items(draws[:], view, shown_pass)
		}
		if ground, ok := pass_ground(shown_pass); ok {
			app.renderer.background = ground
			app.renderer.environment_look.background = false
		}
		if shown_pass == .Silhouette do app.renderer.floor = {}
		// The view pane worked in looks as its own picture does at rest (picture_frame): on its
		// pass's ground or the pane colour, with no floor, a silhouette without wires or paint.
		if app.kit.grid.work != 0 {
			app.renderer.floor = {}
			if _, own := pass_ground(shown_pass); !own {
				pane := color_f32(LOOK_THEMES[app.kit.look].pane)
				app.renderer.background = {pane, pane}
				app.renderer.environment_look.background = false
			}
			if shown_pass == .Silhouette {
				for &d in draws {
					d.wireframe, d.paint, d.groups = false, false, false
					d.matcap, d.textured, d.slots = nil, nil, nil
					d.checker = {}
				}
			}
		}
		drawn := render.render_viewport(&app.renderer, cmd, &app.target, view, proj, draws[:], app.cache_idle)
		// Anything redrawn this frame starts the samples over.
		changed := !drawn.partial || drawn.redrawn_px > 0
		if studio_running(&app) {
			// Render mode takes the GPU while it runs; the studio waits, keeping what it built.
			studio_max := 0 if render_running(&app) else int(app.studio_samples)
			_ = render.studio_frame(&app.renderer, &app.studio, cmd, &app.target, view, proj, draws[:], changed, studio_max, app.studio_ao, app.studio_shadow, viewport_lights(&app), &app.pool, app.studio_softness)
		}
		render_mode_frame(&app, cmd, view, proj, draws[:], changed)
		live_ao_view_frame(&app, cmd, view, proj, draws[:], drawn)
		// A --dump-viewport run's last frame draws its transparent picture, when that is on.
		if opts.dump_viewport != "" && app.screenshot_transparent && opts.frames > 0 && frame_index == opts.frames - 1 do capture_request(&app, opts.dump_viewport)
		capture_frame(&app, cmd, view, proj, draws[:])
		// What follows draws its own views of the scene, which stay shaded whatever the pass.
		pass_items(draws[:], view, .Shaded)

		nav_head_frame(&app, cmd)
		thumbs_frame(&app, cmd)
		home_frame(&app, cmd)
		app.pictures_drawn = 0
		thumbnail_frame(&app, cmd, draws[:])
		grid_frame(&app, cmd, draws[:])

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
				clear_color = sdl.FColor(kit_frame_color(&app.kit)),
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
		idle_note(&app, drawn, sculpted.dabs)
		if sculpted.dabs > 0 {
			ring_push(&app.stats.raycast_ms, sculpted.raycast_ms)
			ring_push(&app.stats.brush_ms, sculpted.brush_ms)
			ring_push(&app.stats.normals_ms, normals_ms)
			ring_push(&app.stats.upload_kb, f64(uploaded) / 1024)
			ring_push(&app.stats.latency_ms, f64(submitted_ns - app.device.input_at) / 1e6)
			app.stats.dabs_total += sculpted.dabs
		}
		// A scripted stroke or replay changes the scene with no input to show for it.
		app.autosave.scripted = (opts.bench_stroke > 0 && !bench_waits && bench_frame < opts.bench_stroke) || opts.gpubench != "" ||
			(opts.load_strokes != "" && frame_index <= max(opts.bench_stroke, LOAD_STROKES_FRAME)) || (opts.timelapse != "" && frame_index <= opts.bench_stroke)
		capture_finish(&app)
		preview_frame(&app)
		autosave_frame(&app)
		free_all(context.temp_allocator)

		if setting_up do app.script.frames += 1
		else do frame_index += 1
		if (opts.frames > 0 && frame_index >= opts.frames) || (opts.bench_stroke > 0 && frame_index - bench_skipped >= opts.bench_stroke) {
			// A --timelapse run goes on until the recording is done.
			// So does one replaying --load-strokes, which starts the frame after.
			replaying := replay_busy(&app) || (opts.load_strokes != "" && frame_index <= max(opts.bench_stroke, LOAD_STROKES_FRAME))
			// And a --turntable run until its last frame is written.
			if (opts.timelapse == "" || (frame_index > opts.bench_stroke && !timeline_busy(&app))) && !replaying && !turntable_recording(&app) do app.running = false
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

	if opts.dump_viewport != "" && !(app.screenshot_transparent && opts.frames > 0) do _ = screenshot_save(&app, opts.dump_viewport)
	if opts.dump_screen != "" {
		if app.kit_drew {
			_ = kit_screen_save(&app, opts.dump_screen, app.kit_size)
		} else {
			// Only a frame without a swapchain image (a minimized window) draws nothing.
			log.error("--dump-screen: the last frame was not drawn (the window had no image to draw into)")
		}
	}

	// A run whose set-up script stopped writes none of the files it would have: the scene
	// is not the one asked for.
	set_up := !(app.startup_script.failed && app.startup_script.scripted)
	if opts.bake != "" && set_up {
		// The quads are the newest object; the stroke may have selected another.
		app.ui.bake.source = app.scene.objects[0].id
		app.scene.selected = len(app.scene.objects) - 1
		bake_to_folder(&app, opts.bake)
	}
	if opts.export != "" && set_up {
		obj := selected_object(&app)
		if obj == nil || !object_export(&app, obj, opts.export) do return false
	}
	if opts.export_print != "" && set_up {
		obj := selected_object(&app)
		if obj == nil || !object_export(&app, obj, opts.export_print, print = true) do return false
	}
	if opts.save != "" && set_up && !scene_save(&app, opts.save) do return false
	if opts.save_strokes != "" && set_up && !strokes_save(&app, opts.save_strokes) do return false
	if opts.export_workspace != "" && set_up && !workspace_export(&app, opts.export_workspace) do return false
	save_pending(&app, true)
	autosave_close(&app, window)
	if as := &app.autosave; as.on {
		fmt.printfln("autosaves=%d autosave_aborts=%d autosave_torn=%d autosave_wait_ms=%.1f autosave_sync_ms=%.1f autosave_serialize_ms=%.1f autosave_write_ms=%.1f autosave_mb=%.1f recovered=%d recover_offers=%d",
			as.written, as.aborts, as.torn, as.wait_ms, as.sync_ms, as.serialize_ms, as.write_ms, f64(as.bytes) / (1 << 20), as.recovered, len(as.offers))
	}
	// The scene file's preview picture: how many were taken, the last one's size and the
	// milliseconds it took to shrink and encode.
	fmt.printfln("previews=%d preview_size=%dx%d preview_kb=%.1f preview_ms=%.2f", app.preview.taken, app.preview.w, app.preview.h, f64(len(app.preview.png)) / 1024, app.preview.ms)
	sv := app.kit.second
	fmt.printfln("thumbnail=%d thumbnail_draws=%d thumbnail_ms=%.2f thumbnail_px=%dx%d thumbnail_flip=%d second_camera=%v second_pass=%v second_max=%d second_turns=%d second_linked=%d", int(app.kit.thumbnail), app.thumbnail.draws, app.thumbnail.ms, app.kit.thumbnail_px.x, app.kit.thumbnail_px.y, int(app.kit.thumbnail_flip), sv.camera, sv.pass, int(sv.max), sv.turns, sv.linked)
	{
		g := &app.kit.grid
		draws, ms, turns, links, linked := 0, 0.0, 0, 0, 0
		for pic in app.panes do draws, ms = draws + pic.draws, max(ms, pic.ms)
		for &v, i in g.views[g.preset] {
			turns, linked = turns + v.turns, linked + v.linked
			if i + 1 < grid_count(g.preset) && second_linked(&v) do links += 1
		}
		split := grid_split(g, g.preset)
		fmt.printfln("grid=%v grid_panes=%d grid_split=%.3f,%.3f grid_max=%d grid_drags=%d pane_draws=%d pane_ms=%.2f pane_px=%dx%d pane_camera=%v pane_turns=%d pane_links=%d linked_turns=%d viewport_origin=%.0f,%.0f grid_main=%.0fx%.0f pane_work=%d pane_works=%d pane_work_dabs=%d", g.preset, grid_count(g.preset), split.x, split.y, g.maximised, g.drags, draws, ms, g.px[0].x, g.px[0].y, g.views[g.preset][0].camera, turns, links, linked, app.ui.viewport_origin.x, app.ui.viewport_origin.y, g.main.w, g.main.h, g.work, g.works, g.work_dabs + (app.stats.dabs_total - g.work_dabs_from if g.work != 0 else 0))
	}
	fmt.printfln("screenshot_transparent=%d turntable_frames=%d turntable_written=%d", int(app.screenshot_transparent), app.turntable_frames, app.turntable.frame)
	fmt.printfln("print_mm=%g print_unit=%d print_exports=%d", print_scale(&app), int(app.print_unit), app.print_exports)
	// The scene's file by its name alone, which a test compares; "none" for no file.
	scene_name := filepath.base(app.scene_path) if app.scene_path != "" else "none"
	fmt.printfln("home=%d home_opened=%d home_read=%d home_pictures=%d recent_scenes=%d home_autosaves=%d scene_name=%s", int(app.kit.home), app.home.opened, app.home.read, app.home.uploaded, len(app.recent_scenes), len(app.home.autosaves), scene_name)

	print_stat :: proc(name: string, r: Sample_Ring) {
		p50, p99 := ring_percentiles(r)
		fmt.printfln("%s_p50=%.3f %s_p99=%.3f", name, p50, name, p99)
	}
	vertices: int
	for obj in app.scene.objects do vertices += object_vertex_count(obj)
	if r := app.startup_script; r.statements > 0 {
		fmt.printfln("script_statements=%d script_ran=%d script_frames=%d script_failed=%d", r.statements, r.ran, r.frames, int(r.failed))
		if r.failed && r.scripted do exit_code^ = 2
	}
	macros_kept := 0
	for s in app.macro.slots do macros_kept += int(s.name != "")
	pack_alphas, pack_presets, pack_meshes, pack_materials := 0, 0, 0, 0
	for p in app.library.packs do pack_alphas, pack_presets, pack_meshes, pack_materials = pack_alphas + p.alphas, pack_presets + p.presets, pack_meshes + p.meshes, pack_materials + p.materials
	pack_matcaps := 0
	for m in app.library.matcaps do if !m.gone do pack_matcaps += 1
	fmt.printfln("library_alphas=%d library_skipped=%d alpha=%s packs=%d pack_alphas=%d pack_presets=%d pack_meshes=%d pack_materials=%d pack_matcaps=%d pack_matcap_textures=%d packs_installed=%d packs_refused=%d", app.library.alphas, app.library.skipped, alpha_ref(&app, app.brush.alpha), len(app.library.packs), pack_alphas, pack_presets, pack_meshes, pack_materials, pack_matcaps, app.library.textures_made, app.library.installed, app.library.refused)
	fmt.printfln("link_sent=%d link_moved=%d link_swapped=%d link_added=%d link_token=%d", app.link.sends, app.link.moved, app.link.swapped, app.link.added, int(app.scene.link_token != 0))
	fmt.printfln("macros=%d macro_recording=%d macro_entries=%d macro_left_out=%d macros_run=%d scripts_run=%d macro_steps=%d", macros_kept, int(app.macro.recording), len(app.macro.entries), app.macro.left_out, app.macro.runs, app.macro.scripts, app.macro.steps)
	plugin_commands := 0
	for _, slot in app.plugins.slots do plugin_commands += int(plugin_slot_loaded(&app, slot))
	fmt.printfln("plugins=%d plugin_commands=%d plugin_errors=%d plugin_runs=%d plugin_steps=%d", len(app.plugins.plugins) - plugins_failed(&app), plugin_commands, app.plugins.errors, app.plugins.runs, app.plugins.steps)
	fmt.printfln("frames=%d dabs=%d objects=%d vertices=%d", frame_index, app.stats.dabs_total, len(app.scene.objects), vertices)
	{
		// The voxel objects: how many, their bricks, and what their fields, surfaces and undo
		// steps hold.
		voxel_objects, bricks, field, surface, undo, resolution := 0, 0, 0, 0, 0, 0
		for obj in app.scene.objects {
			vp := obj.voxel
			if vp == nil do continue
			voxel_objects += 1
			resolution = max(resolution, vp.resolution)
			bricks += voxel.volume_brick_count(&vp.clay.volume)
			field += voxel.volume_bytes(&vp.clay.volume)
			surface += voxel.surface_bytes(&vp.clay.surface)
			undo += voxel.clay_undo_bytes(&vp.clay)
		}
		fmt.printfln("voxel_objects=%d voxel_resolution=%d voxel_bricks=%d voxel_field_mb=%.1f voxel_surface_mb=%.1f voxel_undo_mb=%.2f", voxel_objects, resolution, bricks, f64(field) / (1 << 20), f64(surface) / (1 << 20), f64(undo) / (1 << 20))
	}
	{
		off, ghosts := scene_view_counts(&app)
		shown := 0
		for obj in app.scene.objects do shown += int(object_shown(&app, obj))
		fmt.printfln("objects_shown=%d objects_off=%d objects_ghost=%d solo=%d selected_count=%d", shown, off, ghosts, int(app.scene.solo), len(selection_ids(&app)))
		order, folders, names, places := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
		for obj, i in app.scene.objects {
			p := obj.transform.position
			fmt.sbprintf(&places, "%s%.3f:%.3f:%.3f", "," if i > 0 else "", p.x, p.y, p.z)
			fmt.sbprintf(&order, "%s%d", "," if i > 0 else "", obj.id)
			fmt.sbprintf(&folders, "%s%d", "," if i > 0 else "", obj.folder)
			fmt.sbprintf(&names, "%s%s", "," if i > 0 else "", object_label(obj))
		}
		for &f, i in app.scene.folders do fmt.sbprintf(&names, "%s%s:%s", ";" if i == 0 else ",", folder_label(&f), "open" if f.open else "folded")
		spaced, _ := strings.replace_all(strings.to_string(names), " ", "_", context.temp_allocator)
		fmt.printfln("folders=%d tree_rows=%d scene_order=%s scene_folders=%s scene_names=%s scene_positions=%s", len(app.scene.folders), app.kit.tree_rows, strings.to_string(order), strings.to_string(folders), spaced, strings.to_string(places))
		// The Objects card: rows drawn last frame, pictures drawn, its row menu, what Copy holds,
		// how many objects have their polypaint left out, and how many take part in booleans.
		paint_off, booleans := 0, 0
		for obj in app.scene.objects {
			if obj.paint_off do paint_off += 1
			if obj.boolean != .None do booleans += 1
		}
		fmt.printfln("card_rows=%d thumbs_drawn=%d card_menu=%d card_menu_full=%d clipboard_bytes=%d paint_off=%d booleans=%d", app.kit.card.rows, app.thumb_slots.drawn, int(app.kit.card.menu), int(app.kit.card.menu_all), len(app.clipboard), paint_off, booleans)
		fmt.printfln("card_actions=%d vis_slot=%d vis_used=%d split_made=%d merged=%d aligned=%d", int(app.kit.card.actions), app.scene.vis_slot, app.scene.vis_used, app.split_made, app.merged, app.aligned)
	}
	{
		c := app.camera
		fmt.printfln("camera_yaw=%.4f camera_pitch=%.4f camera_roll=%.4f camera_distance=%.4f camera_target=%.4f,%.4f,%.4f", c.yaw, c.pitch, c.roll, c.distance, c.target.x, c.target.y, c.target.z)
		p := app.pivot.used
		fmt.printfln("orbit_pivot=%.4f,%.4f,%.4f pivot_source=%s pinned=%d framed=%d touch_repeats=%d", p.x, p.y, p.z, strings.to_lower(fmt.tprint(app.pivot.from), context.temp_allocator), int(app.pivot.pinned), app.double_tap.framed, app.touch.hold.done)
		fmt.printfln("undo_steps=%d redo_steps=%d brush_radius_px=%.2f brush_strength=%.3f brush_focal=%.0f selected=%d", len(app.history.done), len(app.history.undone), app.brush.radius_px, brush_strength(&app)^, focal_shift(&app)^, app.scene.selected)
		{
			m := app.move
			tr: Transform
			if obj := selected_object(&app); obj != nil do tr = obj.transform
			transform_undo := 0
			for e in app.history.done do if e.kind == .Transform do transform_undo += 1
			lower :: proc(v: any) -> string {return strings.to_lower(fmt.tprint(v), context.temp_allocator)}
			pivot := "none"
			if obj := selected_object(&app); obj != nil && gizmo_pivot_set(&app) {
				at := gizmo_center(&app, obj)
				pivot = fmt.tprintf("%.3f,%.3f,%.3f", at.x, at.y, at.z)
			}
			e := app.kit.gizmo_entry
			fmt.printfln("gizmo_pivot=%s gizmo_pivot_latch=%d gizmo_entry=%s", pivot, int(m.pivot_latch), lower(e.handle) if e.open else "none")
			// The sum of the selected object's coordinates, so a scenario can tell a mesh that
			// moved from one put back exactly.
			mesh_sum: f64
			if obj := selected_object(&app); obj != nil do for q in object_sculptor(obj).mesh.positions do mesh_sum += f64(q.x) + f64(q.y) + f64(q.z)
			fmt.printfln("stroke_lines=%d stroke_joins=%d", app.stroke_end.lines, app.stroke_end.joins)
			fmt.printfln("gesture=%s mask_shape=%s", lower(app.gesture), lower(app.ui.mask_shape_kind))
			// The lights: which is picked, how many are on, the first one's view-space
			// direction as the sphere shows it, and taps that flipped a light's side.
			lights_on := 0
			set := &app.scene.lights
			for light in set.lights[:set.count] do lights_on += int(light.on)
			l1 := light_view_dir(&app, 0)
			l1_name, _ := strings.replace_all(light_name(set, 0), " ", "_", context.temp_allocator)
			// Where the first light stands in the scene, a point light's or spot's place.
			l1_at := light_world_pos(&app, set.lights[0]) if set.lights[0].kind != .Sun else Vec3{}
			fmt.printfln("light_pick=%d lights_on=%d light1=%.2f,%.2f,%.2f light1_on=%d light_flips=%d light_count=%d light1_kind=%s light1_space=%s light_moves=%d light1_name=%s light1_kelvin=%.0f light1_at=%.2f,%.2f,%.2f", app.light_pick + 1, lights_on, l1.x, l1.y, l1.z, int(set.lights[0].on), app.kit.light_sphere.flips, set.count, lower(set.lights[0].kind), lower(set.lights[0].space), app.ui.light_press.moves, l1_name, set.lights[0].kelvin, l1_at.x, l1_at.y, l1_at.z)
			fmt.printfln("brush_front_only=%d brush_lock_plane=%d brush_connected=%d brush_grab_depth=%d brush_smooth_only=%v", int(app.brush.front_only), int(app.brush.lock_plane), int(app.brush.connected), int(app.brush.grab_depth), app.brush.smooth_only)
			fmt.printfln("pose_mode=%d pose_drags=%d pose_moved=%d mesh_sum=%.4f topo_masks=%d topo_reach=%.3f", int(pose_mode(&app)), m.pose_drags, m.pose_moved, mesh_sum, m.topo_masks, m.topo_reach)
			fmt.printfln("gizmo_at=%.0f,%.0f gizmo_mode=%s gizmo_hover=%s gizmo_last=%s gizmo_drags=%d gizmo_snap=%d transform=%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.4f transform_undo=%d",
				m.drawn.x, m.drawn.y, lower(m.mode), lower(m.hover), lower(m.last), m.drags, int(m.snap), tr.position.x, tr.position.y, tr.position.z, tr.rotation.x, tr.rotation.y, tr.rotation.z, tr.scale, transform_undo)
		}
		{
			// The selected object's levels, name and material, the New scene shape armed and
			// whether the menu is open, for the starter and pack scenarios.
			obj := selected_object(&app)
			name, _ := strings.replace_all(object_label(obj) if obj != nil else "none", " ", "_", context.temp_allocator)
			material := "none"
			if obj != nil && obj.material.label != nil do material, _ = strings.replace_all(string(obj.material.label), " ", "_", context.temp_allocator)
			fmt.printfln("selected_levels=%d selected_name=%s selected_material=%s new_armed=%d menu=%d", len(obj.levels.levels) if obj != nil else 0, name, material, app.kit.new_armed, int(app.kit.menu))
			preset := "none"
			if p, on := brush_preset(&app); on do preset, _ = strings.replace_all(preset_name(p), " ", "_", context.temp_allocator)
			fmt.printfln("presets=%d preset=%d preset_name=%s preset_changed=%d", app.preset_count, app.brush.preset, preset, int(preset_changed(&app)))
			fmt.printfln("dock=%s dock_page=%d dock_pages=%d dock_menu=%d browser=%d", dock_names(&app, app.kit.dock_shown[0], app.kit.dock_shown[1]), app.kit.dock_page, dock_pages(&app), int(app.kit.dock_menu), int(app.kit.browser))
			fmt.printfln("dock_count=%d shortcuts=%s bar_tools=%s bars_edit=%d bar_slot_menu=%d", len(dock_used(&app)), bar_names(&app, .Shortcuts), bar_names(&app, .Tools), int(app.kit.bars_edit), int(app.kit.bar_slot.open))
			bind := &app.kit.bind
			fmt.printfln("key_overrides=%d bind_open=%d bind_command=%s bind_state=%s", app.key_override_count, int(bind.open), command_name(bind.id, bind.arg) if bind.id != .None else "none",
				strings.to_lower(fmt.tprint(bind.state), context.temp_allocator))
			// Which pie is open (-1 none, 0 the brushes) and its slice under the pointer, the
			// stars, pies 1 and 3 by command name, and two commands a pie runs, for the pie
			// scenarios.
			pie := app.ui.pie
			fmt.printfln("pie_open=%d pie_hover=%d pie_runs=%d pie_editor=%d favourites=%d pie1=%s pie3=%s wireframe=%d ortho=%d", pie.which if pie.open else -1, pie.hover if pie.open else -1,
				app.kit.pie_runs, int(app.kit.pie_editor), app.kit.favourite_count, pie_names(&app, 0), pie_names(&app, 2), int(app.wireframe), int(app.camera.ortho))
			fmt.printfln("floor_grid=%d floor_planes=%d%d%d transparent=%d fov=%.0f polyframe_lines=%d polyframe_fill=%d", int(app.floor.on), int(app.floor.planes[0]), int(app.floor.planes[1]), int(app.floor.planes[2]), int(app.see_through), math.to_degrees(app.camera.fov_y), int(app.polyframe_lines), int(app.polyframe_fill))
			bg := app.background
			fmt.printfln("background_gradient=%d background_top=%s background_bottom=%s", int(bg.gradient), hex_text(bg.top), hex_text(bg.bottom))
			lao := app.live_ao
			tr := app.studio.trace
			fmt.printfln("trace=%d trace_mb=%.1f trace_build_ms=%.1f trace_chunks_built=%d", tr.samples, f64(tr.bytes) / (1 << 20), tr.build_ms, tr.chunks_built)
			fmt.printfln("live_ao=%d live_ao_full=%d live_ao_partial=%d live_ao_skipped=%d", int(app.live_ao_on), lao.full, lao.partial, lao.skipped)
			pr := app.path
			fmt.printfln("render=%d render_samples=%d render_ms=%.1f render_mb=%.1f render_failed=%d", int(app.render_on), pr.total_samples, pr.total_ms / f64(max(pr.total_samples, 1)), f64(pr.bytes) / (1 << 20), int(pr.failed))
			// Depth of field, whether a point was picked to focus on and where the focus is,
			// and whether Pick focus still waits for a press.
			focus := focus_point(&app)
			_, picked := app.focus.?
			fmt.printfln("render_dof=%d render_blur=%.2f focus_picked=%d focus=%.3f,%.3f,%.3f focus_armed=%d", int(app.render_dof), app.render_blur, int(picked), focus.x, focus.y, focus.z, int(app.ui.focus_armed))
			env := app.env
			fmt.printfln("environment=%s environment_size=%dx%d environment_background=%d environment_mb=%.1f", "image" if env.kind == .Image && env.gpu.source != nil else "built_in", env.gpu.width, env.gpu.height, int(env.background), f32(render.environment_bytes(env.gpu)) / (1024 * 1024))
		}
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
			fmt.printfln("wheel_size=%s wheel_turn=%.0f wheel_labels=%s", strings.to_lower(fmt.tprint(app.kit.wheel_size), context.temp_allocator), app.kit.wheel_turn, strings.to_lower(fmt.tprint(app.kit.wheel_labels), context.temp_allocator))
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
		hover_tip, _ := strings.replace_all(ui.tip_showing(&app.kit.ctx), " ", "_", context.temp_allocator)
		fmt.printfln("tip_showing=%s", hover_tip if hover_tip != "" else "none")
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
		// The section the tray's open palette shows, whether Show where's mark is on a
		// control, and the Mask section's Steps and Mask by kind.
		fmt.printfln("tray_section=%v tray_marked=%d mask_steps=%d mask_by=%s nav_taps=%d", tray_section(&app, k.tab), int(k.pointed.id != .None && k.ctx.marked.found), app.ui.mask_steps, mask_by_word(app.ui.mask_by.kind), k.nav.taps)
		fmt.printfln("coach=%d coach_shown=%d coach_step=%s", k.coach, int(k.coach_shown), strings.to_lower(fmt.tprint(k.coach_last), context.temp_allocator) if k.coach_shown else "none")
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
		// The operation the bar can adjust now, how many re-runs there were, and whether
		// its popover is open.
		adjust_name, _ := strings.replace_all(strings.to_lower(ADJUST_NAMES[adjust_op_now(&app)], context.temp_allocator), " ", "_", context.temp_allocator)
		shape := strings.to_lower(fmt.tprint(app.shape_pending.kind), context.temp_allocator)
		// The waiting shape's box in window coordinates, so a check can tell it moved.
		box_lo, box_hi: [2]f32
		for q, i in app.shape_pending.points {
			box_lo, box_hi = (q if i == 0 else linalg.min(box_lo, q)), (q if i == 0 else linalg.max(box_hi, q))
		}
		fmt.printfln("shape_pending=%s shape_points=%d shape_flip=%d shape_box=%.0f,%.0f,%.0f,%.0f", shape, len(app.shape_pending.points), int(app.shape_pending.flip), box_lo.x, box_lo.y, box_hi.x, box_hi.y)
		goal := strings.to_lower(fmt.tprint(app.ui.rebuild_goal), context.temp_allocator)
		fmt.printfln("rebuild_goal=%s rebuild_preview=%d rebuild_cell=%.5f rebuild_area_ms=%.2f rebuild_step_ms=%.2f", goal, int(app.rebuild.shown), app.rebuild.cell if app.rebuild.shown else 0, app.rebuild.area_ms, app.rebuild.step_ms)
		fmt.printfln("camera_views=%d camera_view=%d camera_steps=%d", app.views.count, app.views.at + 1 if app.views.count > 0 else 0, app.views.steps)
		fmt.printfln("adjust_op=%s adjusts=%d adjust_pop=%d", adjust_name if adjust_name != "" else "none", app.adjustable.adjusts, int(k.adjust_pop))
		// The selected object's History brush target: how many steps back, chosen or not.
		recall_back, recall_reach, _ := recall_now(&app)
		recall_pinned := false
		if obj := selected_object(&app); obj != nil do recall_pinned = sculpt.sculptor_recall_pinned(object_sculptor(obj))
		fmt.printfln("recall_back=%d recall_reach=%d recall_pinned=%d recall_ms=%.1f", recall_back, recall_reach, int(recall_pinned), app.stats.recall_ms)
		open := [Kit_Window]bool{.Inspector = k.inspector && !side_panel_open(k), .Stats = k.stats, .History = k.history, .Settings = k.settings, .Help = k.help, .Macros = k.macros, .Library = k.library, .Objects = k.objects_card, .Colors = k.colors_card, .Thumbnail = k.thumbnail}
		names := [Kit_Window]string{.Inspector = "inspector", .Stats = "stats", .History = "history panel", .Settings = "settings", .Help = "help", .Macros = "macros", .Library = "library", .Objects = "objects card", .Colors = "colors card", .Thumbnail = "thumbnail"}
		for w, which in k.windows {
			r := ui.prev_rect(&k.ctx, names[which])
			if which in PANEL_WINDOWS do r = panel_rect(&app, which)
			fmt.printf("window_%s=%d,%d,%.0f,%.0f ", strings.to_lower(fmt.tprint(which), context.temp_allocator), int(open[which]), int(w.minimized), r.x, r.y)
		}
		fmt.println()
		// What each column holds, top to bottom, and which sections are pinned as panels.
		for side in Column_Side {
			b := strings.builder_make(context.temp_allocator)
			for r, i in k.panels.columns[side] {
				if i > 0 do strings.write_byte(&b, ',')
				switch v in r {
				case Kit_Window:  strings.write_string(&b, strings.to_lower(fmt.tprint(v), context.temp_allocator))
				case Kit_Section: strings.write_string(&b, strings.to_lower(fmt.tprint(v), context.temp_allocator))
				}
			}
			fmt.printf("column_%s=%s ", "left" if side == .Left else "right", strings.to_string(b) if len(k.panels.columns[side]) > 0 else "none")
		}
		pins := strings.builder_make(context.temp_allocator)
		for pin, sec in k.panels.pins {
			if !pin.on do continue
			if strings.builder_len(pins) > 0 do strings.write_byte(&pins, ',')
			strings.write_string(&pins, strings.to_lower(fmt.tprint(sec), context.temp_allocator))
		}
		fmt.printfln("panel_pins=%s panel_moves=%d panel_menu=%d", strings.to_string(pins) if strings.builder_len(pins) > 0 else "none", k.panels.moves, int(k.panels.menu))
		popped := "left,right" if k.panels.popped[.Left] && k.panels.popped[.Right] else "left" if k.panels.popped[.Left] else "right" if k.panels.popped[.Right] else "none"
		fmt.printfln("columns_narrow=%d column_popped=%s column_pops=%d", int(columns_narrow(&app)), popped, k.panels.pops)
		// The workspace (its name escaped, as it may hold spaces), whether its layout has
		// changes not saved, how many there are, and the zones it hides.
		if w := &k.workspaces; len(w.list) > 0 {
			count := 0
			for ws in w.list do if ws.used do count += 1
			zones := strings.builder_make(context.temp_allocator)
			for z in Zone do if z in k.hidden do fmt.sbprintf(&zones, "%s%s", "," if strings.builder_len(zones) > 0 else "", strings.to_lower(fmt.tprint(z), context.temp_allocator))
			fmt.printfln("workspace=%s workspace_modified=%d workspace_count=%d workspace_menu=%d workspace_switches=%d workspace_exports=%d workspace_imports=%d arrange_drawer=%d zones_hidden=%s", preset_escape(workspace_name(k, w.current)), int(w.modified), count, int(w.menu), w.switches, w.exports, w.imports, int(k.arrange_drawer), strings.to_string(zones) if strings.builder_len(zones) > 0 else "none")
			fmt.printfln("pass=%v pass_shown=%v pass_menu=%d pass_switches=%d", k.passes.pass, viewport_pass(k), int(k.passes.menu), k.passes.switches)
			fmt.printfln("wipe=%d wipe_at=%.3f wipe_right=%v wipe_drags=%d", int(wipe_shown(k)), k.passes.wipe_at, wipe_right(k), k.passes.wipe_drags)
			fmt.printfln("guides=%d guide_heights=%s guide_lines=%d guide_drags=%d", int(app.scene.guides.shown), guides_heights_text(app.scene.guides), k.guide_lines, k.guide_drags)
		}
		// The side bars' popover: what it shows (a section by its name), or none; the look.
		pop := "none"
		if p := k.bar_pop; p.open do pop = strings.to_lower(fmt.tprint(p.section) if p.kind == .Section else fmt.tprint(p.kind), context.temp_allocator)
		fmt.printfln("bar_pop=%s look=%s symmetry=%s live_boolean=%d dynamic=%d", pop, strings.to_lower(fmt.tprint(k.look), context.temp_allocator), symmetry_label(&app),
			int(app.ui.boolean.live), int(command_checked(&app, .Dyntopo_Toggle)))
		// The brush's colours and channel, whether it subtracts, and how many vertices of the
		// selected object carry paint.
		painted := 0
		if obj := selected_object(&app); obj != nil && obj.voxel == nil {
			for c in object_sculptor(obj).color do if c.a > 0 do painted += 1
		}
		main_hex, second_hex: [8]u8
		color_hex_format(app.brush.color, main_hex[:])
		color_hex_format(app.brush.color2, second_hex[:])
		fmt.printfln("paint_channel=%s paint_color=%s paint_color2=%s brush_subtract=%d painted_vertices=%d", strings.to_lower(fmt.tprint(app.brush.channel), context.temp_allocator), string(main_hex[1:7]), string(second_hex[1:7]), int(.Invert in app.rail.latched), painted)
		// The Colors card's tab, how many colours its history and your palettes hold, and
		// whether the eyedropper still waits for a press and the colour popover is open.
		fmt.printfln("colors_tab=%s color_history=%d color_palettes=%d eyedropper=%d color_popover=%d", strings.to_lower(fmt.tprint(k.colors.tab), context.temp_allocator), k.colors.history_count, k.colors.palette_count, int(app.ui.eyedrop_armed), int(k.colors.pop))
		// The brush browser's category, what Recent and Favorites hold, whether its
		// categories are hidden or a search is open, and how many tiles it picked from.
		fmt.printfln("brush_category=%s brush_recent=%d brush_favorites=%d brush_sidebar=%d brush_search=%d brush_browser_picks=%d", strings.to_lower(fmt.tprint(k.brushes.category), context.temp_allocator), k.brushes.recent_count, k.brushes.favorite_count, int(!k.brushes.sidebar_hidden), int(k.brushes.searching), k.brushes.picks)
		// Where the modifier rail and what must stay clear of it ended up, in points, for
		// touch_check's window size scenarios.
		for name in ([?]string{"modifier rail", "brush bar", "dock", "dock pages", "points", "inspector", "action bar", "coach", "view bar", "top bar", "adjust last", "shape bar"}) {
			r := ui.prev_rect(&k.ctx, name)
			if name == "inspector" do r = panel_rect(&app, Kit_Window.Inspector)
			key, _ := strings.replace_all(name, " ", "_", context.temp_allocator)
			fmt.printf("layout_%s=%.0f,%.0f,%.0f,%.0f ", key, r.x, r.y, r.w, r.h)
		}
		for r, side in k.panels.rect do fmt.printf("layout_%s_column=%.0f,%.0f,%.0f,%.0f ", "left" if side == .Left else "right", r.x, r.y, r.w, r.h)
		fmt.println()
	}
	if opts.check_mesh {
		// A --bench-stroke run exits with its pen down; the check is of the finished stroke
		// (a clay's band repair and saddle pass run at its end).
		stroke_finish(&app)
		for obj in app.scene.objects {
			if vp := obj.voxel; vp != nil {
				// The surface as Convert to mesh would make it: the nodes' borders welded.
				welded := voxel.clay_to_mesh(&vp.clay)
				geom.mesh_report_print(geom.mesh_check(welded))
				geom.mesh_destroy(&welded)
				continue
			}
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
	sets := 0
	for obj in app.scene.objects do sets += len(sculpt.levels_sets(&obj.levels))
	fmt.printfln("selection_sets=%d sets_noted=%d", sets, app.sets_noted)
	layers := 0
	for obj in app.scene.objects do layers += sculpt.levels_layer_count(&obj.levels)
	fmt.printfln("layers=%d layers_noted=%d layers_carry_ms=%.1f", layers, app.layers_noted, app.stats.layers_carry_ms)
	fmt.printfln("deforms=%d deform_ms=%.1f deform_kind=%v", app.ui.deform.count, app.ui.deform.ms, app.ui.deform.last)
	fmt.printfln("reshapes=%d reshape_ms=%.1f reshape_kind=%v", app.ui.reshape.count, app.ui.reshape.ms, app.ui.reshape.last.choice)
	check := app.repair.check
	fmt.printfln("repairs=%d repair_ms=%.1f repair_last=%v check_holes=%d check_pieces=%d check_non_manifold=%d check_duplicates=%d", app.repair.count, app.repair.ms, app.repair.last, check.holes, check.pieces, check.check.non_manifold_edges, check.duplicate_triangles)
	{
		l := app.ui.deform.lattice
		fmt.printfln("lattice_on=%d lattice_made=%d lattice_points=%d lattice_drags=%d lattice_ms=%.1f lattice_last=%.0f,%.0f", int(l.on), int(l.made), l.n, l.drags, l.ms, l.last_at.x, l.last_at.y)
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
	fmt.printfln("idle_cache=%v cache_redraws=%d last_frame_triangles=%d msaa=%v", app.cache_idle, app.stats.cache_redraws, app.stats.viewport.triangles, app.msaa)
	v := app.stats.viewport
	fmt.printfln("cull=%v last_frame_draws=%d chunks=%d culled_view=%d culled_back=%d cull_ms=%.3f", app.renderer.cull, v.draws, v.chunks, v.culled_view, v.culled_back, v.cull_ms)
	fmt.printfln("idle_rests=%d idle_rest_ms=%.0f", app.idle.rests, app.idle.rest_ms)
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
		for obj in app.scene.objects {
			undo_bytes += sculpt.sculptor_undo_bytes(object_sculptor(obj))
			if vp := obj.voxel; vp != nil do undo_bytes += voxel.clay_undo_bytes(&vp.clay)
		}
		// Each step's time includes the normal update (a mesh) or the remesh (a clay) after it.
		flush_all :: proc(app: ^App) {
			for obj in app.scene.objects {
				_ = sculpt.sculptor_flush(object_sculptor(obj))
				if vp := obj.voxel; vp != nil do _ = voxel.clay_flush(&vp.clay)
			}
		}
		t0 := time.tick_now()
		history_undo(&app)
		flush_all(&app)
		t1 := time.tick_now()
		history_redo(&app)
		flush_all(&app)
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

// How opaque Transparency draws the objects other than the selected one.
SEE_THROUGH_OPACITY :: 0.3

// How an object is shown (Draw_Item.look): the viewport's look, see-through while
// Transparency is on and it is not the selected object.
object_look :: proc(app: ^App, selected: bool) -> [4]f32 {
	look := viewport_look(app)
	if app.see_through && !selected do look.w = SEE_THROUGH_OPACITY
	return look
}

// How long the view has to stay put before simplified drawing gives way to full detail.
LOD_SETTLE :: 250 * time.Millisecond

// The colour object `i` is drawn in and whether it is drawn live: the selected object is
// in the material's colour, the rest of the selection most of the way to it, the others
// muted, and ghosts more so. Only the selection is sculpted or moved, so the rest can
// come from the cache; the rest of the selection is live only while it moves with the
// primary.
object_draw_tint :: proc(app: ^App, obj: ^Object, i: int) -> (color: [4]f32, live, selected: bool) {
	selected = i == app.scene.selected
	chosen := object_in_selection(app, obj)
	moving := app.move.drag.handle != .None || app.ui.transform_drag.active
	// With Dim the others off, every object shows its own colour.
	color = material_draw_tint(app, obj, i, object_material(app, obj))
	live = selected || (chosen && moving)
	return
}

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

// Adds the pen's turn about its own length since its last report, `degrees` from -180 to
// 180, to this frame's roll, the short way round, so turning past the half turn where the
// numbers wrap reads as the small turn it is.
pen_roll_take :: proc(app: ^App, degrees: f32) {
	if last, ok := app.pen_roll_last.?; ok {
		d := degrees - last
		d -= 360 * math.floor((d + 180) / 360)
		app.pen_roll += d
	}
	app.pen_roll_last = degrees
}
