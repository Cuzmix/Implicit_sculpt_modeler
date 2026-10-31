package main

import "core:flags"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math/linalg"
@(require) import "core:mem" // only used when ODIN_DEBUG
import "core:os"
import "core:slice"
@(require) import "core:strconv" // only used on Linux and Android (peak_rss_mb)
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
	no_settings: bool `usage:"Neither read nor write the remembered settings (brush, view, Scene palette choices, the Settings panel); runs with --frames or a benchmark never do."`,
	settings_file: string `usage:"Read and write the remembered settings at this path instead of the per-user folder, scripted runs included (for testing that settings persist)."`,
	coach: bool `usage:"Show the first-run tips from the first one, even in a scripted run (an interactive run shows them until they are done or skipped)."`,
	tour: bool `usage:"Show the tour from its first step, even in a scripted run (an interactive run shows it after the first-run tips until it is done or skipped)."`,
	gpu_debug: bool `usage:"Create the GPU device in debug mode (enables validation where available)."`,
	no_pre_rotate: bool `usage:"Leave turning the picture to the system on a turned Android tablet instead of drawing it turned (for comparing frame and GPU times)."`,
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
	cpu_cull:  bool `usage:"Cull chunks on the CPU for this run, as Stats > Drawing > Cull on the GPU off does, where the GPU could (for comparison)."`,
	gpu_cull:  bool `usage:"Cull chunks on the GPU for this run where it is offered but starts off: a tablet's or phone's tile GPU (for comparison; Stats > Drawing > Cull on the GPU)."`,
	dump_cull: bool `usage:"Check GPU culling against the CPU's: at exit, print cull_meshes=, cull_commands= and cull_mismatch= (triangles the two disagree on) for each mesh's last pass."`,
	system_palms: bool `usage:"Act as an iPad does, whose system rejects a hand resting on the screen while its pen is in use: only the pen's tip, and the fifth of a second after it lifts, makes a lone finger a palm, not the pen hovering near (for testing that on a desktop)."`,
	pen_no_leave: bool `usage:"Act as the iPad's SDL does, which never says that the pen left: the pen then counts as gone half a second after its last report while its tip is up (for testing that on a desktop)."`,
	ui_dt:     f32 `usage:"Move the interface's clock (animations, tooltips, long presses) this many seconds a frame instead of by the time that passed, for scripted runs whose checks must not depend on how fast frames come (scripts/touch_check.py passes 1/60). A stroke then lays every dab its frame's samples ask for, up to 64, however long they take. The 90 ms a finger waits before it sculpts and the right tap that opens the pie stay on the real clock."`,
	ui_events: string `usage:"Drive the pointer, fingers and pen as SDL events would, for tests: FRAME:move:X,Y, FRAME:down, FRAME:up, FRAME:right (a right click), FRAME:mdown, FRAME:mup, FRAME:rdown and FRAME:rup (the middle and right buttons held and let go), FRAME:wheel:N, FRAME:key:NAME (a key press: shift, ctrl, alt held until FRAME:keyup:NAME), FRAME:fdown:ID:X,Y, FRAME:fmove:ID:X,Y, FRAME:fup:ID and FRAME:fcancel:ID (finger ID on a touch screen), FRAME:pdown:X,Y, FRAME:pmove:X,Y, FRAME:pup, FRAME:pnear / FRAME:pfar, FRAME:pright (the pen, the last its side button), FRAME:pedown:X,Y (its eraser end down), FRAME:pbutton:N (barrel button N), FRAME:pdtap and FRAME:psqueeze (an Apple Pencil's double-tap and squeeze, :ACTION naming the iPad's preferred action), FRAME:ponly:1 or :0 (the iPad's Only Draw with Apple Pencil), FRAME:ptilt:X,Y and FRAME:pdist:D (the pen's lean and hover height from then on), FRAME:ppress:P (the pen's pressure from then on, 0 to 1; 0 until set) and FRAME:pcoal:X,Y or FRAME:pcoal:X,Y:P (one of the pen's samples between frames, as a tablet's bridge sends it ahead of the frame's next pmove) FRAME:kbhide (the on-screen keyboard put away by its own key, as an iPad's SDL reports it) and FRAME:drop:PATH (a file dropped on the window), separated by semicolons; X and Y in window points. FRAME:winN:... sends an event to view window N (1 to 3) instead, in its points."`,
	dump_view_window: string `usage:"On exit, write view window 1 as its interface drew it (its picture and head) to this path: a PNG, or a binary PPM when it ends in .ppm."`,
	view_windows: int `usage:"Open this many view windows (up to 3, desktop only) at the start, each showing what Camera > New view window would."`,
	ui_map: string `usage:"On exit, write the controls the interface drew in its last frame to this file, a line each: its path (the labels of the containers it sits in and its own, joined by /), a tab, and its rectangle's x, y, width and height in points. The names --ui-events taps by."`,
	dump_screen: string `usage:"On exit, write the whole window as the interface drew it (viewport and panels) to this path: a PNG, or a binary PPM when it ends in .ppm."`,
	dump_viewport: string `usage:"On exit, write the last viewport image to this path: a PNG, or a binary PPM when it ends in .ppm (for checking renders), as Menu > Save screenshot does."`,
	check_mesh: bool `usage:"On exit, check every object's current mesh (closed, consistently wound, no degenerate triangles or NaN) and print the counts as mesh_* lines (slow on large meshes)."`,
	no_partial: bool `usage:"Redraw the whole viewport every frame instead of only what changed (for comparison)."`,
	tile_msaa: bool `usage:"With anti-aliasing and partial redraw off, keep the viewport's samples only inside its pass, as a tile GPU does, on any GPU (for testing that mode)."`,
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
	async_jobs: bool `usage:"Run Remesh, Decimate and Retopologize on a thread of their own in a scripted run too, and on any size of object, as an interactive run does on a big one: for testing it."`,
	camera_ease: bool `usage:"Let Frame all, Focus selected, Reset camera, the axis views and Previous and Next view glide in a scripted run too, which otherwise jumps: for testing it."`,
	frame_limit: int `usage:"Draw at most N frames a second (Settings > System > Frame rate > Limit)."`,
	time_gpu:  bool `usage:"Measure the GPU time of the 3D viewport every frame. Waits for the GPU each frame, so frames no longer overlap."`,
	gpubench:  string `usage:"Time the GPU and CPU while orbiting and sculpting one sphere at 500k, 1M, 5M, 7M, 10M and 20M vertices (only --vertices when given), with each speed setting on and off; write the markdown tables to this path and exit."`,
	async_compute: bool `usage:"Run render mode's bands on a compute queue of their own for this run, as Settings > System > Graphics > Async compute does, even on a device with one queue, where nothing overlaps but the waits between the queues still run: for testing them."`,
	no_ray_query: bool `usage:"Trace the studio render's and render mode's rays by walking the app's own trees for this run, as Settings > System > Graphics > Ray tracing hardware off does, even where the GPU offers ray queries (for comparison)."`,
	cpu_smooth: bool `usage:"Start with the Object palette's Deformation > On the GPU off, so Smooth all runs on the CPU even where the GPU is offered."`,
	compute_bench: string `usage:"Time Smooth all on the CPU and as a GPU compute shader, upload and readback included, at 500k, 1M, 5M, 7M and 10M vertices (only --vertices when given); check the GPU's result against the CPU's, write the markdown tables to this path and exit."`,
	bake:       string `usage:"On exit, bake the first object's detail onto the selected quad object (from retopologize in a start-up script) into this folder, as Bake maps... does (before --export)."`,
	bake_size:  int `usage:"Texels square for --bake (512, 1024, 2048 or 4096; default 2048)."`,
	gpubench_frames: int `usage:"Measured frames per --gpubench case (default 120, at most 240)."`,
	open:      string `usage:"Start with the scene saved in this .sculpt file instead of spheres, as Menu > Open scene... does."`,
	import_mesh: string `args:"name=import" usage:"Start with the mesh in this .obj, .ply, .stl, .glb, .gltf, .usd, .usda, .usdc, .usdz or .fbx file instead of spheres (after any --open), as Menu > Import mesh... does."`,
	export:    string `usage:"On exit, write the selected object's shown level to this .obj, .ply, .stl, .glb or .usda file, as Menu > Export mesh... does."`,
	export_workspace: string `usage:"On exit, write the current workspace's layout to this .workspace file, as the workspace menu's Export workspace... does."`,
	import_workspace: string `usage:"Read this .workspace file as a new workspace of your own and switch to it on the first frame, as the workspace menu's Import workspace... does."`,
	export_print: string `usage:"On exit, write the selected objects to this .stl, .obj or .3mf file at their print size, as the Export sheet's 3D print does."`,
	save:      string `usage:"On exit, save the scene to this .sculpt file, as Menu > Save scene does."`,
	autosave:  f32 `usage:"Autosave every this many seconds once the scene changed and the app rested, as Settings > System > Autosave does every few minutes; scripted runs only autosave with this or --autosave-folder."`,
	autosave_folder: string `usage:"Keep the autosaves in this folder instead of the app's own (and offer the ones a crashed run left there, as an interactive start does)."`,
	autosave_rest: f32 `usage:"Seconds without a press, key or stroke before an autosave starts (default 1.5)."`,
	check_autosave: bool `usage:"Check that nothing an autosave reads changes while it reads it: the exit stats count it as autosave_torn."`,
	crash_after_autosave: bool `usage:"Exit with code 3 right after the first autosave is written, skipping the clean exit, as a crash would: the kill test of autosave and recovery."`,
	autosave_hold: bool `usage:"Hold the first autosave before it reads the scene until a stroke, a command or the end of the run stops it, so a test sees the stop on a machine of any speed."`,
	bench_after_autosave: bool `usage:"Start --bench-stroke only once an autosave of the scene as it starts is being written, so the stroke runs while the file is written (the autosave benchmark)."`,
	load_strokes: string `usage:"Load the strokes in this .strokes file and replay them where they were drawn, as the Stroke recorder's Load and Replay do: once --bench-stroke ends, or at the start; the run lasts until they are done."`,
	replay_shift: string `usage:"Replay --load-strokes moved this many pixels right and down from where they were drawn, in the current view, as R at the pointer does, e.g. 120,-40."`,
	instant_replay: bool `usage:"Replay every recorded frame at once instead of one a frame, as the Stroke recorder's Instant does."`,
	record_strokes: bool `usage:"Record every stroke from the start, as the Stroke recorder's Record does (for --save-strokes)."`,
	run:        string `usage:"Run the command script in this file once the window is up, as set-up: commands by name, settings with set, wait and select (README \"Command scripts\"). A script with an error runs none of it and exits with code 2; so does a statement that does nothing in a run with --frames. --frames and the frames of --ui-events count from where it ends."`,
	script:     string `usage:"Run this command script, given here with ; between statements, as --run does a file's."`,
	save_strokes: string `usage:"On exit, save the recorded strokes (or else the last stroke) to this .strokes file, as the Stroke recorder's Save strokes does."`,
	input_diagnostics: bool `usage:"Open the Input diagnostics screen at the start, in any build (debug builds and the developer iPad build also reach it from Search and Settings > Statistics)."`,
	diag_test: string `usage:"Open Input diagnostics at the start and run this test (finger_tap, roll_right, ...: README \"Input diagnostics\")."`,
	diag_export: string `usage:"On exit, write the Input diagnostics report (a ZIP of diagnostic-report.md, diagnostic-events.jsonl and diagnostic-summary.json) to this path, as its Export report does."`,
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
	model:    Model_Tool,
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
	stroke_edit: Stroke_Edit, // the stroke held to edit, while one is (stroke_edit.odin)
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
	// What the grabs' refinements under dynamic topology did, in all (exit stats).
	grab_refine: struct {
		splits: int,
		ms:     f64,
	},
	// ...and the Snake hook and Cloth strokes' stretch repairs (sculptor_stretch_repair).
	stretch_repair: struct {
		splits: int,
		ms:     f64,
	},
	samples:  [dynamic]Input_Sample, // this frame's pointer samples, in window coordinates
	pen_samples: Pen_Samples, // the pen's samples between frames, which SDL leaves out
	predict:     Cursor_Predict, // where the pointer will be when the frame shows (cursor_lead)
	pen_pressure: f32, // the pen's latest pressure
	pen_tilt: [2]f32, // the pen's latest lean in degrees, x to the right and y down
	// How far the hovering pen is above the screen, 0 touching to 1 at the edge of its
	// hover range, where the platform reports it (an iPad's Pencil); 0 otherwise.
	pen_distance: f32,
	pen_seen: bool,
	// How far the pen turned about its own length this frame, degrees clockwise, where the
	// platform reports it (pen_roll_take), and the turn it last reported.
	pen_roll: f32,
	pen_roll_last: Maybe(f32),
	pen_twist: Pen_Twist, // the pen's roll over the view under way (pen_roll.odin)
	// The pen's roll that a Pen roll alpha turns by, from the frame's Viewport_Input, so a
	// replayed stroke turns as it was drawn.
	alpha_roll: f32,
	pencil:   Pencil, // the pencil's double-tap and squeeze, the pen's second button and eraser end (pencil.odin)
	diag:     Diag, // the Input diagnostics screen and its log (diagnostics.odin)
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
	tap_switches: int, // finger taps that switched the selected object (tap_switch_target), for the exit stats
	// The folders the last import made and what its file held for animation, left out, for
	// the exit stats.
	import_folders: int,
	import_rig:     geom.Rig_Found,
	import_joined:  int, // quads the last import found again from an STL or glTF file's triangles
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
	camera_ease: Camera_Ease, // the camera gliding to a view a command asked for (camera_ease.odin)
	flashes:     Flashes, // the undo glow, mask wipe, selection outline and save tick (feedback_motion.odin)
	long_job:    Long_Job, // a rebuild, subdivision or voxel conversion running on a thread of its own (long_job.odin)
	cross_fade:  Cross_Fade, // the last picture fading out over a new pass, look or mesh (cross_fade.odin)
	rebuild:    Rebuild_Preview, // the Rebuild panel's density checkerboard (rebuild.odin)
	autosave: Autosave, // the background autosave and crash recovery (autosave.odin)
	preview:  Scene_Preview, // the picture scene files keep for the Home screen (scene_preview.odin)
	home:     Home, // the Home screen's pictures and autosaves (home.odin)
	thumbnail: Picture, // the second view's picture (thumbnail.odin)
	panes:     [GRID_VIEWS]Picture, // the view panes' pictures (grid.odin)
	view_windows: View_Windows, // second views in OS windows of their own (view_window.odin)
	work_still: render.Viewport_Target, // what the main pane holds while a view pane is worked in (grid_work)
	pictures_drawn: int, // second-view pictures drawn this frame (picture_frame)
	capture:   Capture, // a transparent screenshot waiting for its frame (capture.odin)
	turntable: Turntable, // Scene > Turntable's recording (turntable.odin)
	turntable_frames: i32, // how many frames it takes, remembered
	print_unit:    Print_Unit, // Scene > 3D print's unit, remembered
	print_exports: int, // files exported for printing, for the exit stats
	print_bed:     [3]f32, // the printer's bed in millimetres (Settings > Files > 3D printer); 0 for the default
	print_wall:    f32, // the least wall a print should have, in millimetres; 0 for the default
	print_checks:  Print_Checks, // the Export sheet's checks of the selected object (print_checks.odin)
	export_once:      Export_Once, // the Export sheet's For this file options for the export it started (lens_export.odin)
	export_decimated: int, // the triangles the last decimated export wrote, for the exit stats
	export_hollowed:  int, // the triangles the last hollow print's inside wall added, for the exit stats
	repair:        Repair_Stats, // Modify topology's repairs, for the exit stats
	// The scenes saved or opened lately, newest first, at most HOME_RECENT_MAX (remembered).
	recent_scenes: [dynamic]string,
	start_home: bool, // an interactive run given no scene starts on Home (Settings > Interface)
	timeline: Timeline, // the History panel's scrubbing, playback and time-lapse (timeline.odin)
	replay:   Replay, // the Stroke recorder's last stroke, recording and replay (replay.odin)
	// Scene > Render at Fast quality (render_mode.odin; Shift+R): ambient occlusion and
	// soft shadows built up while the view stays still (render.Studio).
	studio:         render.Studio,
	// Remembered; a device that cannot run it leaves it on and shows the plain viewport
	// (studio_running), so a failure never saves as "off".
	studio_on:      bool,
	studio_samples: i32, // samples it stops at
	studio_ao:      f32, // how strongly occlusion darkens, 0 to 1
	studio_shadow:  f32, // ...and the key light's shadow
	studio_softness: f32, // the key light's radius in radians, how soft its shadow's edge is
	// Scene > Look > Occlusion while working (live_ao.odin): screen-space ambient
	// occlusion every frame, with studio_ao's strength.
	live_ao:        render.Live_AO,
	live_ao_on:     bool,
	live_ao_reach:  f32, // a share of the scene's radius
	// Scene > Render (render_mode.odin): the view path traced while it stays still. Not
	// remembered; its samples and bounces are.
	path:           render.Path_Render,
	render_on:      bool,
	render_quality: Render_Quality, // Scene > Render's Quality, which the switch turns on
	render_samples: i32,
	render_bounces: i32,
	render_denoise: bool,
	render_half:    bool, // trace at half size each way: on by default on tablets
	// Scene > Lens (lens.odin): depth of field and its Blur, remembered, and the point
	// Pick focus took, for the session (none: the pivot).
	render_dof:     bool,
	render_blur:    f32,
	focus:          Maybe(Vec3),
	// Scene > Finish (finish.odin): the camera's finishing of the picture while the Render
	// switch is on, remembered; what it made, and how many frames redrew anything, which
	// names what its source holds and moves the grain on.
	finish:         Finish_Settings,
	finished:       render.Finish,
	finish_redraws: u64,
	// The navigation head in the top-right corner (nav_head.odin), and the texture it was
	// drawn into this frame, for the interface to show; nil when there is none.
	nav_head:       render.Nav_Head,
	nav_shown:      render.Texture,
	// The Objects card's pictures of objects (object_thumbs.odin): the atlas they are drawn
	// into and which object each of its cells shows.
	thumbs:         render.Thumbs,
	thumb_slots:    Thumb_Slots,
	step_pictures:  render.Step_Pictures, // the History's pictures of steps (history_pictures.odin)
	step_picture_slots: Step_Picture_Slots,
	layer_pictures: render.Step_Pictures, // the Layers panel's pictures of layers (layer_pictures.odin)
	layer_picture_slots: Layer_Picture_Slots,
	// An object copied with Copy, as the scene file stores it, for Paste (scene_paste);
	// kept across new scenes, as a clipboard is.
	clipboard:      [dynamic]u8,
	// Objects Split made, objects Merge took, and objects Align and Distribute moved, for
	// the exit stats (split_merge.odin).
	split_made, merged, aligned: int,
	material:  int,  // the index in MATERIALS objects are shaded with, or CUSTOM_MATERIAL
	custom:    Material, // what the Material section's sliders made
	// A scrub over the Material card's spheres: what the objects had (material.odin), and
	// the previews shown and scrubs kept, for the exit stats.
	material_saved:    Material_Saved,
	material_previews: int,
	material_keeps:    int,
	// The built-in matcaps' textures (nil where the device refused one), and the image
	// loaded with Load MatCap with its path ("" for none).
	matcaps:      [len(MATCAP_RECIPES)]render.Texture,
	matcap_image: render.Texture,
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
	sym_lines:       Symmetry_Lines, // where the mirror planes cut the selected object, kept (symmetry.odin)
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
	low_latency: Low_Latency, // how far the GPU may run behind (frame_rate.odin), applied as frame_rate is
	display_link: bool, // Settings > System > Frame rate > Pace with the display: the Metal display link (a trial)
	idle_sleep:  bool, // rest between frames while nothing changes (idle.odin)
	idle:        Idle,
	msaa:     Msaa, // wanted anti-aliasing, applied before the next frame sizes the viewport (msaa.odin)
	async_compute:  bool, // Settings > System > Graphics > Async compute: render mode's bands on a second queue
	async_compute_run: bool, // --async-compute: on for this run, on one queue too
	ray_query:      bool, // Settings > System > Graphics > Ray tracing hardware: rays against the driver's structures where offered
	no_ray_query_run: bool, // --no-ray-query: off for this run
	time_gpu: bool, // wait for each frame's 3D work, to measure its GPU time
	window:   ^sdl.Window, // what file dialogs belong to
	scene_path: string, // where the scene was last saved or opened from, for Ctrl+S (owned)
	saving:     File_Request, // a big save waiting a few frames for its "Saving..." toast to show (save_pending)
	saving_at:  f64, // the interface time it started waiting
	versions_kept: i32, // earlier saves kept beside a scene file (versions.odin), 0 for none
	undo_steps:    i32, // undo steps the History keeps (history_cap), 0 for no limit but memory's
	// The History's settings (History panel > Settings, Settings > Files): the memory it may
	// use in MB (0 for the stores' own limits), whether light and scene tree changes stay out
	// of it, whether undo puts the camera back as the step had it, and whether the list
	// leaves repeated strokes apart. Each off is the default, so a fresh App is as before.
	history_limit_mb:  i32,
	history_no_lights: bool,
	history_no_tree:   bool,
	history_camera:    bool,
	history_ungrouped: bool,
	history_no_finger_scrub: bool, // two fingers held then slid do not scrub the History (History > Settings)
	history_pictures:  bool, // the History list shows each step's picture (History > Settings)
	versions:   [dynamic]Version_Row, // the scene file's earlier saves, newest first (versions_refresh)
	saved_fp:   u64, // scene_fingerprint when the scene last matched its file (autosave_scene_saved)
	saved_at:   time.Time, // when its file was last written (by this save, or before it was opened); zero for no file
	result:     Op_Result, // what the last operation did (results.odin)
	running:  bool,
}

// The first frame --load-strokes may replay on: the viewport takes the window's size on
// the first frame and its render target follows at the start of the next, and until then
// it is not its real size, which replaying at the pointer would take as the view.
LOAD_STROKES_FRAME :: 3

main :: proc() {
	// UIKit owns an iPad app's main thread from launch, so there SDL starts UIKit first and
	// calls app_main back once the app has launched (ios.odin); everywhere else the app
	// starts here.
	when ODIN_PLATFORM_SUBTARGET_IOS {
		ios_start()
	} else {
		app_main()
	}
}

// The whole run on the main thread: the logger, the debug build's leak tracking, the
// flags, then run. Exits the process with 1 on a failure, or with the run's own code.
app_main :: proc() {
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
	if errors := render.validation_errors(); errors > 0 {
		log.errorf("Vulkan: %d validation errors", errors)
		ok = false
	}

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

	// What earlier interactive runs left; a start-up script runs after it and wins over it.
	remember := (opts.frames == 0 && opts.gpubench == "" && opts.bench_stroke == 0 && !opts.no_settings) || opts.settings_file != ""
	settings := (opts.settings_file if opts.settings_file != "" else settings_path()) if remember else ""
	if remember do settings = strings.clone(settings)
	defer delete(settings)
	// The backend is readied before the window, which is made for it. A device that cannot
	// run it is told so (no one is, in a run with no one watching) and the start ends.
	unattended := opts.frames != 0 || opts.gpubench != "" || opts.bench_stroke != 0
	if !render.backend_select() {
		platform_alert(nil, "Sculpt cannot start", graphics_failed_text(), unattended)
		return false
	}
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
	defer {delete(app.material_saved.ids); delete(app.material_saved.before)}
	if opts.no_pre_rotate do render.set_pre_rotate(false)
	if !render.renderer_init(&app.renderer, window, opts.gpu_debug) {
		platform_alert(window, "Sculpt cannot start", graphics_failed_text(), unattended)
		return false
	}
	defer render.renderer_destroy(&app.renderer)
	matcaps_create(&app)
	defer matcaps_destroy(&app)
	defer environment_destroy(&app)
	defer render.smooth_compute_destroy(&app.renderer, &app.smooth_gpu)
	defer render.studio_destroy(&app.renderer, &app.studio)
	defer render.live_ao_destroy(&app.renderer, &app.live_ao)
	defer render.path_render_destroy(&app.renderer, &app.path)
	defer render.finish_destroy(&app.renderer, &app.finished)
	defer render.nav_head_destroy(&app.renderer, &app.nav_head)
	defer render.thumbs_destroy(&app.renderer, &app.thumbs)
	defer render.step_pictures_destroy(&app.renderer, &app.step_pictures)
	defer render.step_pictures_destroy(&app.renderer, &app.layer_pictures)
	defer delete(app.clipboard)

	jobs.pool_init(&app.pool, opts.threads - 1 if opts.threads > 0 else 0)
	app.renderer.pool = &app.pool
	defer jobs.pool_destroy(&app.pool)
	log.infof("sculpt threads: %d", jobs.pool_size(&app.pool))
	if opts.compute_bench != "" do return computebench_run(&app, opts.compute_bench, opts.vertices)
	app.scene.selected = -1
	defer render.mesh_buffers_destroy(&app.renderer, &app.ui.boolean.preview)
	defer geom.mesh_destroy(&app.ui.boolean.preview_mesh)
	defer boolean_coarse_drop(&app)
	defer scene_destroy(&app)
	defer history_destroy(&app.history)
	// Before the history and the scene go: a job still running holds a snapshot and reads
	// nothing of theirs, but its thread must end first.
	defer long_job_stop(&app)
	defer print_checks_stop(&app)
	// A look slider still held when the app ends has its snapshot unrecorded.
	defer if app.model.look_drag.before != nil do history_snapshot_drop(app.model.look_drag.before)
	timeline_init(&app.timeline)
	defer timeline_destroy(&app.timeline)
	app.history.began = time.tick_now()
	replay_init(&app.replay)
	defer replay_destroy(&app.replay)
	app.replay.instant = opts.instant_replay
	app.replay.recording = opts.record_strokes
	defer delete(app.samples)
	defer delete(app.drag.held)
	defer delete(app.dab_wait.samples)
	defer delete(app.stroke.pending)
	defer delete(app.stroke.path)
	defer stroke_edit_destroy(&app.stroke_edit)
	defer mask_shape_destroy(&app.mask_shape)
	defer clip_gesture_destroy(&app.clip)
	defer symmetry_lines_destroy(&app.sym_lines)
	defer shape_pending_destroy(&app.shape_pending)
	defer rebuild_preview_destroy(&app.rebuild)
	defer curve_tool_destroy(&app.curve)
	defer model_tool_free(&app.model)
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
		if !scene_import(&app, opts.import_mesh, record = false) || len(app.scene.objects) == before do return false
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
	// Scripted events that name a control, and --ui-map, need the interface's control map.
	ui.names_show(&app.kit.ctx, opts.ui_map != "" || strings.contains(opts.ui_events, "@"))
	defer diag_destroy(&app)

	if len(app.scene.objects) > 1 do frame_all(&app)
	app.cache_idle = !opts.no_cache
	app.polyframe_lines = true
	app.floor = FLOOR_DEFAULT
	app.background = BACKGROUND_DEFAULT
	// Custom starts as PBR clay, the last physically based preset, until a slider changes it.
	app.custom = MATERIALS[FIRST_MATCAP - 1]
	app.custom.label = "Custom"
	app.renderer.cull = !opts.no_cull
	app.renderer.gpu_cull = !opts.cpu_cull && (render.caps(&app.renderer).gpu_cull_default || opts.gpu_cull)
	app.renderer.gpu_culling.check = opts.dump_cull
	app.renderer.partial = !opts.no_partial
	app.renderer.tile_msaa = opts.tile_msaa
	app.renderer.trace = !opts.no_trace
	app.simplify = !opts.no_simplify
	app.simplify_px = 1
	app.frame_rate = .Unlimited if opts.no_vsync || opts.gpubench != "" else .Match_Display
	app.frame_limit = FRAME_LIMIT_DEFAULT
	app.idle_sleep = true
	app.ray_query = RAY_QUERY_DEFAULT
	app.async_compute = true
	app.start_home = true
	app.idle.forced = opts.idle_sleep
	app.msaa = MSAA_DEFAULT
	// Before the settings file, which brings back what earlier runs chose.
	app.cavity, app.ridge = CAVITY_DEFAULT, RIDGE_DEFAULT
	app.rim, app.underside = RIM_DEFAULT, UNDERSIDE_DEFAULT
	app.studio_softness = render.STUDIO_KEY_SOFTNESS
	app.studio_samples, app.studio_ao, app.studio_shadow = STUDIO_SAMPLES_DEFAULT, STUDIO_AO_DEFAULT, STUDIO_SHADOW_DEFAULT
	app.render_samples, app.render_bounces, app.render_denoise = render.RENDER_SAMPLES_DEFAULT, render.RENDER_BOUNCES_DEFAULT, true
	app.render_half = MOBILE
	app.render_blur = RENDER_BLUR_DEFAULT
	app.finish = FINISH_DEFAULTS
	app.turntable_frames = TURNTABLE_FRAMES_DEFAULT
	environment_settings_default(&app)
	app.dim_others = true
	app.time_gpu = opts.time_gpu || opts.gpubench != ""
	app.ui = ui_state_default()
	app.curve, app.insert = CURVE_DEFAULTS, INSERT_DEFAULTS
	app.brush = brush_defaults()
	for &s, kind in app.brush.strengths do s = BRUSHES[kind].strength
	app.nav = NAV_DEFAULT
	app.autosave.minutes = AUTOSAVE_DEFAULT_MINUTES
	app.versions_kept = VERSIONS_DEFAULT
	// The alphas come first, the library's too, so that presets and the brush in the
	// settings find the alphas they name.
	alphas_init(&app)
	defer alphas_destroy(&app)
	library_load(&app, library_folder(settings))
	// Runs after settings_save and the scene's last use, which read the pack materials'
	// names, and before the renderer goes, which their textures need: keep it here.
	defer library_destroy(&app)
	settings_load(&app, settings)
	pencil_init(&app, window)
	app.pencil.no_leave = !PEN_LEAVE_SAID || opts.pen_no_leave
	app.pencil.system_palms = SYSTEM_PALMS || opts.system_palms
	pen_samples_init(&app, window)
	// The benchmarks measure the viewport filling the window, so their numbers stay
	// comparable whatever grid a workspace keeps.
	if opts.bench_stroke > 0 || opts.gpubench != "" do app.kit.grid.tree = grid_preset_tree(.Single)
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
	app.kit.tour.run, app.kit.tour.since = (remember && opts.frames == 0) || opts.tour, -1
	if opts.tour do app.kit.tour.step = 0
	app.kit.fixed_dt = opts.ui_dt
	// After the clock is chosen, which the session's times count on.
	app.diag.allowed = DIAGNOSTICS || opts.input_diagnostics || opts.diag_test != "" || opts.diag_export != ""
	if opts.input_diagnostics || opts.diag_test != "" do diag_open(&app)
	if opts.diag_test != "" {
		test, known := diag_test_named(opts.diag_test)
		if !known {
			log.errorf("--diag-test=%s: no such test (README \"Input diagnostics\" lists them)", opts.diag_test)
			return false
		}
		diag_show(&app, test)
		diag_run_start(&app, test)
	}
	if opts.no_vsync do app.frame_rate = .Unlimited
	if opts.frame_limit > 0 do app.frame_rate, app.frame_limit = .Limit, i32(clamp(opts.frame_limit, FRAME_LIMIT_MIN, FRAME_LIMIT_MAX))
	app.ui.smooth_on_gpu = !opts.cpu_smooth
	app.async_compute_run = opts.async_compute
	app.no_ray_query_run = opts.no_ray_query
	if opts.bake_size > 0 do app.ui.bake.size = i32(opts.bake_size)
	// Freed after the settings are saved at exit, which write them.
	defer {
		for s in app.recent_scenes do delete(s)
		delete(app.recent_scenes)
	}
	defer if remember do _ = settings_save(&app, settings)
	interactive := opts.frames == 0 && opts.gpubench == "" && opts.bench_stroke == 0 && opts.compute_bench == ""
	app.camera_ease.allowed = interactive || opts.camera_ease
	app.long_job.allowed, app.long_job.forced = interactive || opts.async_jobs, opts.async_jobs
	autosave_init(&app, interactive, f64(opts.autosave), opts.autosave_folder, f64(opts.autosave_rest), opts.check_autosave, opts.crash_after_autosave)
	defer autosave_destroy(&app)
	defer scene_preview_destroy(&app)
	defer home_destroy(&app)
	defer thumbnail_destroy(&app)
	defer grid_destroy(&app)
	// Before the renderer and the interface go, which the windows' buffers belong to.
	defer view_windows_destroy(&app)
	defer capture_destroy(&app)
	defer turntable_destroy(&app)
	// After autosave_init, whose folder Home's Autosaves lists.
	if home_at_start(&app, opts, interactive) do home_open(&app)
	// Read on the first frame, as a file picked in the dialog is.
	if opts.import_workspace != "" do file_post(.Import_Workspace, opts.import_workspace)
	// The benchmark's autosave writes the scene it starts with.
	if opts.bench_after_autosave do app.autosave.clean = 0
	if opts.autosave_hold do autosave_hold(&app)
	if opts.density_preview > 0 {
		app.ui.rebuild_goal, app.ui.rebuild_even, app.rebuild.pinned = .Even, rebuild_count(opts.density_preview), true
	}
	app.live_ao_reach = LIVE_AO_REACH_DEFAULT
	app.stroke_seed = 1
	app.tool = .Brush
	app.running = true
	loop := Frame_Loop {
		opts        = &opts,
		window      = window,
		main_window = sdl.GetWindowID(window),
		bench       = &bench,
		driven      = interactive && opts.run == "" && opts.script == "" && opts.ui_events == "" && opts.load_strokes == "" && opts.timelapse == "" && !opts.orbit,
	}
	defer render.fence_finish(&app.renderer, &loop.present_fence)
	for _ in 0 ..< min(opts.view_windows, VIEW_WINDOWS_MAX) do view_window_request(&app, view_window_default(&app))
	for app.running {
		if !frame_step(&app, &loop) do return false
	}
	if opts.gpubench != "" && !bench.done {
		log.warn("gpubench: stopped before every case ran; nothing written")
		return false
	}

	if opts.dump_viewport != "" && !(app.screenshot_transparent && opts.frames > 0) do _ = screenshot_save(&app, opts.dump_viewport)
	if opts.dump_view_window != "" do _ = view_window_save(&app, 1, opts.dump_view_window)
	if opts.ui_map != "" {
		b := strings.builder_make(context.temp_allocator)
		ui.names_write(&app.kit.ctx, &b)
		if os.write_entire_file(opts.ui_map, b.buf[:]) != nil do log.errorf("--ui-map: cannot write %s", opts.ui_map)
	}
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
	if opts.export_print != "" && set_up && !print_export(&app, opts.export_print) do return false
	if opts.save != "" && set_up && !scene_save(&app, opts.save) do return false
	if opts.save_strokes != "" && set_up && !strokes_save(&app, opts.save_strokes) do return false
	if opts.export_workspace != "" && set_up && !workspace_export(&app, opts.export_workspace) do return false
	// A run still under way at exit ends here, so its verdict is in the stats and the report.
	if app.diag.run_open do diag_run_end(&app, .End)
	if opts.diag_export != "" && !diag_export(&app, opts.diag_export) do return false
	save_pending(&app, true)
	autosave_close(&app, window)
	return exit_stats_print(&app, opts, &loop, exit_code)
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

// The most memory the process has held, in MB, as the kernel counted it: from
// /proc/self/status on Linux and Android, 0 where there is no such file (scripts that
// measure a run, such as scripts/remesh_check.py, read it from the exit stats).
peak_rss_mb :: proc() -> f64 {
	when ODIN_OS == .Linux {
		data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
		if err != nil do return 0
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if strings.has_prefix(line, "VmHWM:") {
				fields := strings.fields(line, context.temp_allocator)
				if kb, ok := strconv.parse_f64(fields[1]); ok do return kb / 1024
			}
		}
	}
	return 0
}
