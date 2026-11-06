package main

import "core:fmt"
import "core:math/linalg"
import "core:time"

import "../camera"
import "../geom"
import "../sculpt"
import "../ui"

// The Physics card (Object palette, Surface page): an object's cloth, as ZBrush's
// Simulation palette and Blender's cloth filter keep it. What the object is made of
// (Stiffness, Firmness, Damping, Keep area) and what it meets (the floor, the other
// objects, itself) serve Settle, the filters, the Physics switch and posing with Physics;
// the Cloth brush keeps its own make-up, as each of ZBrush's cloth brushes does, and takes
// the object's collisions and gravity's way. Settle lets the free part fall as cloth
// (ZBrush's Run Simulation); the filters pull it toward an inflated, expanded or scaled
// copy of itself while it stays cloth, so it folds instead of stretching.

Gravity_Way :: enum u8 {
	World,  // down the scene's Y axis
	Screen, // toward the bottom of the screen as it is each step
	Set,    // the way the screen's down pointed when Set direction was pressed
}

@(rodata)
GRAVITY_WAY_NAMES := [Gravity_Way]string {
	.World  = "World down",
	.Screen = "Screen down",
	.Set    = "Set",
}

Object_Physics :: struct {
	// Set once the card first changed it or a scene file gave it; until then the object
	// has PHYSICS_DEFAULTS (object_physics), so every way of making an object starts there.
	set:          bool,
	gravity:      f32, // Settle's pull, 0 to 1
	way:          Gravity_Way,
	down:         Vec3, // Set: the world direction, unit length
	floor:        bool,
	objects:      bool,
	gap:          f32, // how far the cloth stays off other objects, a share of its object's size
	self_collide: bool,
	thickness:    f32, // how far apart self collision keeps the cloth, in edges
	on_masked:    bool, // Settle and the filters move the masked part instead of the free one
	stiffness:    f32,
	firmness:     f32,
	damping:      f32,
	keep_area:    bool,
	allow_shrink: bool,
	allow_expand: bool,
}

PHYSICS_DEFAULTS :: Object_Physics {
	set       = true,
	gravity   = 1,
	way       = .World,
	down      = {0, -1, 0},
	floor     = true,
	objects   = true,
	gap       = PHYSICS_GAP_DEFAULT,
	thickness = 1,
	stiffness = sculpt.CLOTH_DEFAULTS.stiffness,
	firmness  = sculpt.CLOTH_DEFAULTS.firmness,
	damping   = sculpt.CLOTH_DEFAULTS.damping,
}

// The ranges of the card's sliders, which a scene file's values are held to as well.
PHYSICS_GAP_DEFAULT :: f32(0.01)
PHYSICS_GAP_MAX :: f32(0.05)
PHYSICS_THICKNESS_MIN :: f32(0.5)
PHYSICS_THICKNESS_MAX :: f32(3)

// The most vertices the cloth simulates at once for Settle, a filter or a pose, unless
// --physics-budget says otherwise: past it a step a frame no longer keeps up with the
// pointer (about 10 ms on a desktop's cores, the tablets' fewer and slower ones taking
// fewer). An object over it with subdivision levels runs on the finest level under it.
PHYSICS_BUDGET :: 120_000 when MOBILE else 300_000

// The most vertices Physics simulates at once: --physics-budget's, or PHYSICS_BUDGET.
physics_budget :: proc(app: ^App) -> int {
	return app.physics_budget if app.physics_budget > 0 else PHYSICS_BUDGET
}

// Settle stops by itself once no vertex has moved more than this share of an edge for
// PHYSICS_REST_FRAMES frames in a row, or after PHYSICS_SETTLE_FRAMES frames at most.
PHYSICS_REST :: f32(0.001)
PHYSICS_REST_FRAMES :: 10
PHYSICS_SETTLE_FRAMES :: 1500
// A press of Settle held longer than this runs while held and stops on release; a shorter
// one, a tap, leaves it running until it rests or is tapped again.
PHYSICS_HOLD_SECONDS :: 0.35

Physics_Card :: struct {
	settle: Settle_Run,
	filter: Physics_Filter,
	filter_axes: bit_set[sculpt.Axis],
	filter_frame: Filter_Frame,
	amount: f32, // the filter's slider, -100 to 100; 0 between drags
	wait_release: bool, // a drag ended under a held pointer: the slider stays at 0 till it lets go
	drag: Filter_Drag,
	settles, filters: int, // run, for the exit stats
	settle_ms: f64, // the last Settle's time stepping
	// The run under way moved to a coarser level to keep under the budget: the object and
	// the level it goes back to when the run ends (id 0: none). Runs on a coarser level
	// are counted for the exit stats.
	back: struct {
		id, level: int,
	},
	coarse_runs: int,
}

Physics_Filter :: enum u8 {
	Inflate,
	Expand,
	Scale,
}

Filter_Frame :: enum u8 {
	Object,
	World,
	Screen,
}

Settle_Run :: struct {
	active:  bool,
	id:      int, // the object, which the selection may leave meanwhile
	held:    bool, // runs while the press that began it is held, and stops on release
	press:   time.Tick,
	frames:  int,
	resting: int, // frames in a row it moved less than PHYSICS_REST
	ms:      f64,
}

Filter_Drag :: struct {
	active: bool,
	id:     int,
	ms:     f64,
}

// The object's cloth settings: its own once set, else the defaults.
object_physics :: proc(obj: ^Object) -> Object_Physics {
	return obj.physics if obj.physics.set else PHYSICS_DEFAULTS
}

// The object's cloth settings to change, made its own first.
@(private = "file")
object_physics_edit :: proc(obj: ^Object) -> ^Object_Physics {
	if !obj.physics.set do obj.physics = PHYSICS_DEFAULTS
	return &obj.physics
}

// The object's make-up and what it collides with as the solver takes them, `region` and
// `gravity` the caller's.
object_cloth_settings :: proc(obj: ^Object, region := sculpt.Cloth_Region.Whole, gravity: f32 = 0) -> sculpt.Cloth_Settings {
	p := object_physics(obj)
	return {
		region = region, stiffness = p.stiffness, firmness = p.firmness, damping = p.damping, gravity = gravity,
		keep_area = p.keep_area, allow_shrink = p.allow_shrink, allow_expand = p.allow_expand,
		floor = p.floor, objects = p.objects, self_collide = p.self_collide,
	}
}

// The Cloth brush's settings with the object's collisions in place of its own.
cloth_brush_settings :: proc(app: ^App, obj: ^Object) -> sculpt.Cloth_Settings {
	set := app.brush.cloth
	p := object_physics(obj)
	set.floor, set.objects, set.self_collide, set.on_masked = p.floor, p.objects, p.self_collide, false
	return set
}

// The way gravity pulls on `obj`, in its own space, as its card says.
physics_down :: proc(app: ^App, obj: ^Object) -> Vec3 {
	p := object_physics(obj)
	world: Vec3
	switch p.way {
	case .World:  world = {0, -1, 0}
	case .Screen: world = screen_down(app)
	case .Set:    world = p.down
	}
	return linalg.normalize0(to_local_dir(obj.transform, world))
}

// The bottom of the screen as a world direction.
@(private = "file")
screen_down :: proc(app: ^App) -> Vec3 {
	view := camera.orbit_view(app.camera)
	return -Vec3{view[1, 0], view[1, 1], view[1, 2]}
}

// The gap and thickness of the object's card, as the solver takes them.
@(private = "file")
physics_collide :: proc(app: ^App, obj: ^Object, set: sculpt.Cloth_Settings) -> sculpt.Cloth_Collisions {
	with := cloth_collisions(app, obj, set)
	p := object_physics(obj)
	s := object_sculptor(obj)
	if len(s.bvh.nodes) > 0 {
		box := s.bvh.nodes[0].bounds
		with.gap = p.gap * linalg.length(box.hi - box.lo)
	}
	with.thickness = p.thickness
	return with
}

// Whether the card's runs can work on `obj`: a mesh object, out of HD and without
// dynamic topology, saying why not in the card unless `quiet`.
physics_card_allowed :: proc(app: ^App, obj: ^Object, quiet := true) -> bool {
	why := ""
	if obj.voxel != nil || obj.cage != nil || obj.curve != nil do why = "Physics works on a sculpted mesh, not voxel clay, a cage or a curve"
	else if object_in_hd(obj) do why = "Physics needs the HD window left first (A)"
	else if object_dynamic(obj) do why = "Physics needs dynamic topology off"
	if why == "" do return true
	if !quiet do report(app, Section.Physics, {.Warning}, "%s", why)
	return false
}

// Starts the cloth over the free part of `obj` for Settle (`filter` false) or the card's
// filter, as one stroke. Over the budget it moves to the finest level under it, where the
// object has levels, and comes back when the run ends (physics_run_end): the run is then
// that level's stroke, as ZBrush's Dynamics run on a lower subdivision level, and the
// levels above take its moves as any lower level's stroke does. False, saying why, when
// it cannot.
@(private = "file")
physics_run_begin :: proc(app: ^App, obj: ^Object, filter: bool) -> bool {
	if !physics_card_allowed(app, obj, quiet = false) do return false
	c := &app.ui.physics
	c.back = {}
	for {
		n, began := physics_run_try(app, obj, filter)
		if began do return true
		why := ""
		if n == 0 do why = "Nothing is free to move: the mask holds all that is shown" if !object_physics(obj).on_masked else "Nothing is masked to move (On masked)"
		else if n < 0 do return physics_run_back(app, obj)
		else if k := physics_level_under(app, obj, n); k >= 0 {
			if c.back.id == 0 do c.back = {obj.id, obj.levels.current}
			if !object_set_level(app, obj, k) {
				app.running = false // a GPU failure
				return false
			}
			continue
		} else {
			why = fmt.tprintf("Physics moves up to %d vertices at once; this one has %d free and no coarser subdivision level to run on", physics_budget(app), n)
		}
		report(app, Section.Physics, {.Warning}, "%s", why)
		return physics_run_back(app, obj)
	}
}

// Begins the run on the object's current level when its free part is within the budget:
// returns how many vertices are free and whether it began (-1: the sculptor was busy).
@(private = "file")
physics_run_try :: proc(app: ^App, obj: ^Object, filter: bool) -> (n: int, began: bool) {
	s := object_sculptor(obj)
	if s.history.recording || sculpt.sculptor_posing(s) do return -1, false
	p := object_physics(obj)
	set := object_cloth_settings(obj, gravity = p.gravity)
	set.on_masked = p.on_masked
	sculpt.sculptor_stroke_begin(s)
	if filter {
		c := &app.ui.physics
		n = sculpt.sculptor_filter_begin(s, sculpt.Cloth_Filter_Kind(c.filter), set, physics_filter_frame(app, obj), c.filter_axes)
	} else {
		n = sculpt.sculptor_settle_begin(s, set)
	}
	if n == 0 || n > physics_budget(app) {
		sculpt.sculptor_cloth_end(s)
		_ = sculpt.sculptor_stroke_discard(s)
		return n, false
	}
	sculpt.sculptor_cloth_collide(s, physics_collide(app, obj, set))
	return n, true
}

// The finest level below the current one where `free` vertices free now would come to no
// more than the budget, the share of them free taken as the same on every level; -1 for
// none.
@(private = "file")
physics_level_under :: proc(app: ^App, obj: ^Object, free: int) -> int {
	l := &obj.levels
	all := max(sculpt.sculptor_vertex_count(&l.levels[l.current].sculptor), 1)
	for k := l.current - 1; k >= 0; k -= 1 {
		if sculpt.sculptor_vertex_count(&l.levels[k].sculptor) * free / all <= physics_budget(app) do return k
	}
	return -1
}

// Takes the object back to the level a run moved it from, if it moved; false, for the
// callers' convenience.
@(private = "file")
physics_run_back :: proc(app: ^App, obj: ^Object) -> bool {
	c := &app.ui.physics
	if c.back.id != obj.id do return false
	level := c.back.level
	c.back = {}
	if !object_set_level(app, obj, level) do app.running = false // a GPU failure
	return false
}

// Ends the card's run on `obj` as one undo step named `what` when it moved anything, and
// says where it ran when that was a coarser level (" on level 2 of 4", else "").
@(private = "file")
physics_run_end :: proc(app: ^App, obj: ^Object, what: string) -> (moved: bool, note: string) {
	s := object_sculptor(obj)
	sculpt.sculptor_cloth_end(s)
	moved = sculpt.sculptor_stroke_end(s)
	if moved do history_record(app, obj, .Deform, what)
	if c := &app.ui.physics; c.back.id == obj.id {
		if moved do c.coarse_runs += 1
		note = fmt.tprintf(" on level %d of %d", obj.levels.current + 1, len(obj.levels.levels))
		_ = physics_run_back(app, obj)
	}
	return
}

// The axes a filter scales along, as columns in `obj`'s space.
@(private = "file")
physics_filter_frame :: proc(app: ^App, obj: ^Object) -> matrix[3, 3]f32 {
	axes: [3]Vec3
	switch app.ui.physics.filter_frame {
	case .Object:
		return 1
	case .World:
		axes = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
	case .Screen:
		view := camera.orbit_view(app.camera)
		for k in 0 ..< 3 do axes[k] = {view[k, 0], view[k, 1], view[k, 2]}
	}
	m: matrix[3, 3]f32
	for k in 0 ..< 3 {
		a := linalg.normalize0(to_local_dir(obj.transform, axes[k]))
		m[0, k], m[1, k], m[2, k] = a.x, a.y, a.z
	}
	return m
}

// Starts Settle on `obj`, held (`held`, stopping on release) or running till it rests.
settle_start :: proc(app: ^App, obj: ^Object, held: bool) -> bool {
	inspector_drags_end(app)
	stroke_finish(app)
	if !physics_run_begin(app, obj, filter = false) do return false
	app.ui.physics.settle = {active = true, id = obj.id, held = held, press = time.tick_now()}
	return true
}

// Stops Settle, if it runs, as one undo step.
settle_stop :: proc(app: ^App) {
	c := &app.ui.physics
	run := c.settle
	if !run.active do return
	c.settle = {}
	obj := object_by_id(app, run.id)
	if obj == nil do return
	moved, note := physics_run_end(app, obj, "Settle")
	if !moved do return
	c.settles += 1
	c.settle_ms = run.ms
	report(app, Section.Physics, {.Undo}, "Settled %s%s: %d steps (%.0f ms)", object_label(obj), note, run.frames, run.ms)
}

// Starts or stops Settle on the selected object: the Settle command and a tap of the
// card's button.
settle_toggle :: proc(app: ^App) {
	if app.ui.physics.settle.active {
		settle_stop(app)
		return
	}
	if obj := selected_object(app); obj != nil do _ = settle_start(app, obj, held = false)
}

// Follows the filter's slider on `obj`: its first change starts the drag.
@(private = "file")
filter_drag_to :: proc(app: ^App, obj: ^Object) {
	c := &app.ui.physics
	if c.drag.active && c.drag.id != obj.id do filter_drag_end(app, force = true)
	if c.drag.active || c.wait_release do return
	settle_stop(app)
	inspector_drags_end(app)
	stroke_finish(app)
	if !physics_run_begin(app, obj, filter = true) {
		c.amount = 0
		return
	}
	c.drag = {active = true, id = obj.id}
}

// Ends the filter's drag once the pointer lets go (or at once with `force`) as one undo
// step; the slider springs back to 0. Runs every frame, so a drag ends even if the card
// closed meanwhile.
filter_drag_end :: proc(app: ^App, force := false) {
	c := &app.ui.physics
	held := .Left in app.device.down
	if !held do c.wait_release = false
	if !c.drag.active || (!force && held) do return
	drag := c.drag
	c.drag, c.amount, c.wait_release = {}, 0, held
	obj := object_by_id(app, drag.id)
	if obj == nil do return
	moved, note := physics_run_end(app, obj, PHYSICS_FILTER_NAMES[c.filter])
	if !moved do return
	c.filters += 1
	report(app, Section.Physics, {.Undo}, "%s %s%s (%.0f ms)", PHYSICS_FILTER_NAMES[c.filter], object_label(obj), note, drag.ms)
}

@(rodata)
PHYSICS_FILTER_NAMES := [Physics_Filter]string {
	.Inflate = "Inflate",
	.Expand  = "Expand",
	.Scale   = "Scale",
}

@(rodata)
PHYSICS_FILTER_HELP := [Physics_Filter]string {
	.Inflate = "Pulls the free part out along its normals (in, the other way), as cloth: it puffs and wrinkles instead of swelling smoothly.",
	.Expand  = "Pulls the free part away from its middle (toward it, the other way), as cloth: drawn in, it gathers into folds.",
	.Scale   = "Pulls the free part toward a copy scaled along the chosen axes, from half to twice the size, as cloth: shrunk, it folds.",
}

// One step a frame of the card's run under way: Settle until it rests, is let go or is
// stopped, or the filter at the slider's amount while it is dragged.
physics_card_frame :: proc(app: ^App) {
	c := &app.ui.physics
	filter_drag_end(app)
	if c.drag.active {
		if obj := object_by_id(app, c.drag.id); obj != nil {
			start := time.tick_now()
			_ = sculpt.sculptor_filter_step(object_sculptor(obj), c.amount / 100, physics_down(app, obj))
			c.drag.ms += time.duration_milliseconds(time.tick_since(start))
		}
	}
	run := &c.settle
	if !run.active do return
	obj := object_by_id(app, run.id)
	if obj == nil {
		run^ = {}
		return
	}
	// A press held past a tap runs only while it is held.
	if run.held && .Left not_in app.device.down {
		if time.duration_seconds(time.tick_since(run.press)) >= PHYSICS_HOLD_SECONDS {
			settle_stop(app)
			return
		}
		run.held = false
	}
	start := time.tick_now()
	motion := sculpt.sculptor_settle_step(object_sculptor(obj), physics_down(app, obj))
	run.ms += time.duration_milliseconds(time.tick_since(start))
	run.frames += 1
	run.resting = run.resting + 1 if motion < PHYSICS_REST else 0
	if !run.held && (run.resting >= PHYSICS_REST_FRAMES || run.frames >= PHYSICS_SETTLE_FRAMES) do settle_stop(app)
}

// Ends the card's runs at once, before a command, an undo or a scene change changes what
// they move.
physics_card_end :: proc(app: ^App) {
	settle_stop(app)
	filter_drag_end(app, force = true)
}

// The card: Settle and gravity, the filters, and under More what the cloth collides with
// and its make-up.
kit_physics :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	c := &app.ui.physics
	p := object_physics(obj)
	edit := p
	can := physics_card_allowed(app, obj)
	defer if edit != p do object_physics_edit(obj)^ = edit

	// Settle: a press runs it and a long one only while held; a tap leaves it running till
	// it rests, and a second tap stops it.
	running := c.settle.active && c.settle.id == obj.id
	label := "Stop settling" if running else "Settle"
	clicked := ui.button(ctx, label, .Solid if !running else .Flat, .Accent, glyph = ui.ICON_PLAY if !running else ui.ICON_PAUSE, enabled = can, keys = command_hint(app, .Settle))
	pressed := ctx.active == ctx.last_id && .Left in app.device.pressed
	if pressed && !running && can do _ = settle_start(app, obj, held = true)
	else if clicked && running && !c.settle.held do settle_stop(app)
	_ = ui.slider(ctx, "Gravity", &edit.gravity, 0, 1, .Linear, fmt.tprintf("%.0f%%", edit.gravity * 100))
	ways: [len(Gravity_Way)]string
	for name, w in GRAVITY_WAY_NAMES do ways[int(w)] = name
	if picked := ui.tabs(ctx, "gravity way", ways[:], int(edit.way)); picked >= 0 do edit.way = Gravity_Way(picked)
	if edit.way == .Set {
		if ui.button(ctx, "Set direction") do edit.down = screen_down(app)
	}
	ui.paragraph(ctx, "Settle lets the free part fall as cloth, onto the floor and the other objects, till it comes to rest: a tap runs it, a held press only while held, and a tap or Escape stops it, as one undo step. The mask holds what it covers (On masked, the other way round).")

	// The filters: a slider each drag pulls toward, live, as one undo step.
	filters: [len(Physics_Filter)]string
	for name, f in PHYSICS_FILTER_NAMES do filters[int(f)] = name
	if picked := ui.tabs(ctx, "physics filter", filters[:], int(c.filter)); picked >= 0 && !c.drag.active do c.filter = Physics_Filter(picked)
	if c.filter == .Scale {
		ui.begin(ctx, "physics filter axes", {direction = .Row, gap = ui.SPACE_XS})
		for a in sculpt.Axis {
			if ui.toggle_button(ctx, fmt.tprintf("%v##physics", a), a in c.filter_axes, 92) && !c.drag.active {
				if a in c.filter_axes do c.filter_axes -= {a}
				else do c.filter_axes += {a}
			}
		}
		ui.end(ctx)
		frames := [len(Filter_Frame)]string{"Object", "World", "Screen"}
		if picked := ui.tabs(ctx, "physics filter frame", frames[:], int(c.filter_frame)); picked >= 0 && !c.drag.active do c.filter_frame = Filter_Frame(picked)
	}
	if c.wait_release do c.amount = 0
	axes_ok := c.filter != .Scale || card(c.filter_axes) > 0
	if ui.slider(ctx, "Amount##physics", &c.amount, -100, 100, .Linear, fmt.tprintf("%+.0f%%", c.amount), enabled = can && axes_ok) do filter_drag_to(app, obj)
	ui.paragraph(ctx, PHYSICS_FILTER_HELP[c.filter])

	if kit_more(app, .Physics) {
		_ = ui.switch_row(ctx, "Collide with floor", &edit.floor)
		_ = ui.switch_row(ctx, "Collide with objects", &edit.objects)
		if edit.objects do _ = ui.slider(ctx, "Gap", &edit.gap, 0, PHYSICS_GAP_MAX, .Linear, fmt.tprintf("%.1f%%", edit.gap * 100))
		_ = ui.switch_row(ctx, "Self collision", &edit.self_collide)
		if edit.self_collide do _ = ui.slider(ctx, "Thickness", &edit.thickness, PHYSICS_THICKNESS_MIN, PHYSICS_THICKNESS_MAX, .Linear, fmt.tprintf("%.1f edges", edit.thickness))
		_ = ui.switch_row(ctx, "On masked", &edit.on_masked)
		_ = ui.slider(ctx, "Stiffness", &edit.stiffness, 0, 1, .Linear, fmt.tprintf("%.0f%%", edit.stiffness * 100))
		_ = ui.slider(ctx, "Firmness", &edit.firmness, 0, 1, .Linear, fmt.tprintf("%.0f%%", edit.firmness * 100))
		_ = ui.slider(ctx, "Damping", &edit.damping, 0, 1, .Linear, fmt.tprintf("%.0f%%", edit.damping * 100))
		_ = ui.switch_row(ctx, "Keep area", &edit.keep_area)
		_ = ui.switch_row(ctx, "Allow shrink", &edit.allow_shrink)
		_ = ui.switch_row(ctx, "Allow expand", &edit.allow_expand)
		ui.paragraph(ctx, "The floor stands at the bottom of the scene; Gap keeps the cloth that share of its size off the other objects, and Thickness keeps its own folds that many edges apart. On masked moves the masked part instead of the free one. Then what this object is made of, for Settle, the filters, the Physics switch and posing with Physics (the Cloth brush keeps its own): Stiffness is how firmly edges keep their length; Firmness how much it resists bending, for wider, fewer folds; Damping how quickly it settles. Keep area holds edges to the stored morph target's lengths; Allow shrink lets it crumple without pushing back; Allow expand lets it stretch like rubber. The collisions and gravity's way serve the Cloth brush too.")
		kit_more_end(app)
	}
	kit_last_result(app, .Physics)
}

// What physics_put writes: six numbers, the set direction, the way and the switches.
PHYSICS_BYTES :: 6 * 4 + 3 * 4 + 1 + 1

// Appends the card's settings as the scene file's object keeps them.
physics_put :: proc(out: ^[dynamic]u8, p: Object_Physics) {
	geom.byte_put(out, [6]f32{p.gravity, p.gap, p.thickness, p.stiffness, p.firmness, p.damping})
	geom.byte_put(out, p.down)
	geom.byte_put(out, u8(p.way))
	flags := u8(p.floor) | u8(p.objects) << 1 | u8(p.self_collide) << 2 | u8(p.on_masked) << 3 | u8(p.keep_area) << 4 | u8(p.allow_shrink) << 5 | u8(p.allow_expand) << 6
	geom.byte_put(out, flags)
}

// Reads what physics_put writes; r.ok goes false on values out of the card's ranges.
physics_get :: proc(r: ^geom.Byte_Reader) -> (p: Object_Physics) {
	v := geom.byte_get(r, [6]f32)
	p.gravity, p.gap, p.thickness, p.stiffness, p.firmness, p.damping = v[0], v[1], v[2], v[3], v[4], v[5]
	p.down = geom.byte_get(r, Vec3)
	way := geom.byte_get(r, u8)
	flags := geom.byte_get(r, u8)
	in_unit :: proc(x: f32) -> bool {return x >= 0 && x <= 1}
	ok := in_unit(p.gravity) && in_unit(p.stiffness) && in_unit(p.firmness) && in_unit(p.damping)
	ok &&= p.gap >= 0 && p.gap <= PHYSICS_GAP_MAX && p.thickness >= PHYSICS_THICKNESS_MIN && p.thickness <= PHYSICS_THICKNESS_MAX
	ok &&= way <= u8(max(Gravity_Way)) && flags < 1 << 7 && abs(linalg.length(p.down) - 1) < 1e-3
	if !ok {
		r.ok = false
		return
	}
	p.way = Gravity_Way(way)
	p.floor, p.objects, p.self_collide, p.on_masked = flags & 1 != 0, flags & 2 != 0, flags & 4 != 0, flags & 8 != 0
	p.keep_area, p.allow_shrink, p.allow_expand = flags & 16 != 0, flags & 32 != 0, flags & 64 != 0
	p.set = true
	return
}
