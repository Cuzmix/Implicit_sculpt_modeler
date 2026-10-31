package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../geom"
import "../poly"
import "../render"
import "../sculpt"
import "../ui"
import "../voxel"

// The exit stats: key=value lines on stdout once the run's last frame is done, which
// scripts/touch_check.py, the gate, the benchmarks and tests read. run calls this last;
// false when a step it times (the level changes after a bench stroke) fails.

exit_stats_print :: proc(app: ^App, opts: Options, loop: ^Frame_Loop, exit_code: ^int) -> bool {
	if as := &app.autosave; as.on {
		fmt.printfln("autosaves=%d autosave_aborts=%d autosave_torn=%d autosave_wait_ms=%.1f autosave_sync_ms=%.1f autosave_serialize_ms=%.1f autosave_write_ms=%.1f autosave_mb=%.1f recovered=%d recover_offers=%d",
			as.written, as.aborts, as.torn, as.wait_ms, as.sync_ms, as.serialize_ms, as.write_ms, f64(as.bytes) / (1 << 20), as.recovered, len(as.offers))
	}
	// The scene file's preview picture: how many were taken, the last one's size and the
	// milliseconds it took to shrink and encode.
	fmt.printfln("previews=%d preview_size=%dx%d preview_kb=%.1f preview_ms=%.2f", app.preview.taken, app.preview.w, app.preview.h, f64(len(app.preview.png)) / 1024, app.preview.ms)
	sv := app.kit.second
	fmt.printfln("thumbnail=%d thumbnail_draws=%d thumbnail_ms=%.2f thumbnail_px=%dx%d thumbnail_flip=%d second_camera=%v second_pass=%v second_turns=%d second_linked=%d", int(app.kit.thumbnail), app.thumbnail.draws, app.thumbnail.ms, app.kit.thumbnail_px.x, app.kit.thumbnail_px.y, int(app.kit.thumbnail_flip), sv.camera, sv.pass, sv.turns, sv.linked)
	{
		g := &app.kit.grid
		draws, ms, turns, links, linked := 0, 0.0, 0, 0, 0
		for pic in app.panes do draws, ms = draws + pic.draws, max(ms, pic.ms)
		n := grid_panes(g)
		for &v, i in g.views {
			turns, linked = turns + v.turns, linked + v.linked
			if i + 1 < n && second_linked(&v) do links += 1
		}
		// The shares of the first two splits, in the tree's order.
		split: [2]f32
		found := 0
		for node in g.tree.nodes[:g.tree.count] do if node.split && found < 2 {
			split[found] = node.share
			found += 1
		}
		heavy := 0
		for v, i in g.views do if i + 1 < n && second_pass_heavy(v.pass) do heavy += 1
		fmt.printfln("grid=%v grid_panes=%d grid_split=%.3f,%.3f grid_max=%d grid_drags=%d pane_draws=%d pane_ms=%.2f pane_px=%dx%d pane_camera=%v pane_turns=%d pane_links=%d linked_turns=%d viewport_origin=%.0f,%.0f grid_main=%.0fx%.0f pane_work=%d pane_works=%d pane_work_dabs=%d pane_samples=%d pane_heavy=%d pane_render_samples=%d", grid_shape_name(g), n, split.x, split.y, g.maximised, g.drags, draws, ms, g.px[0].x, g.px[0].y, g.views[0].camera, turns, links, linked, app.ui.viewport_origin.x, app.ui.viewport_origin.y, g.main.w, g.main.h, g.work, g.works, g.work_dabs + (app.stats.dabs_total - g.work_dabs_from if g.work != 0 else 0), app.panes[0].studio.samples, heavy, app.panes[0].path.samples)
		ar := &g.areas
		tree := strings.builder_make(context.temp_allocator)
		grid_tree_write(&tree, &g.tree)
		// Commas for its spaces, so the stat stays one word.
		tree_text, _ := strings.replace_all(strings.to_string(tree), " ", ",", context.temp_allocator)
		fmt.printfln("grid_tree=%s grid_splits=%d grid_joins=%d grid_swaps=%d grid_docks=%d grid_undos=%d grid_redos=%d grid_refused=%d grid_cancels=%d grid_undo_steps=%d", tree_text if g.tree.count > 0 else "0", ar.splits, ar.joins, ar.swaps, ar.docks, ar.undos, ar.redos, ar.refused, ar.cancels, g.undo.back_n)
		// What each view pane shows, its shading mode or pass, with no spaces so the stat
		// stays one word.
		shows := strings.builder_make(context.temp_allocator)
		for &v, i in g.views[:n - 1] {
			if i > 0 do strings.write_byte(&shows, ',')
			name, _ := strings.replace_all(second_shows_name(&v), " ", "_", context.temp_allocator)
			strings.write_string(&shows, name)
		}
		fmt.printfln("pane_shows=%s pane_lighting=%v", strings.to_string(shows) if n > 1 else "none", g.views[0].shading.lighting)
		fmt.printfln("grid_closes=%d grid_evens=%d new_panes=%v pane_menu=%d stack_strip=%d stack_tab=%s stack_tabs=%d stack_density=%s", g.closes, g.evens, app.kit.new_panes, int(app.kit.pane_menu.open), int(stack_strip_shown(app)), fmt.tprint(app.kit.stack.tab) if app.kit.stack.tab_open else "none", app.kit.stack.tabs, "icons" if app.kit.stack.density == .Icons else "panels")
	}
	{
		vws := &app.view_windows
		open, draws, presents := view_windows_stats(app)
		// The first window's camera and pass, "none" without one.
		first := vws.open[0]
		camera_name := fmt.tprint(first.view.camera) if first != nil else "none"
		pass_name := fmt.tprint(first.view.pass) if first != nil else "none"
		fmt.printfln("view_windows=%d view_window_opens=%d view_window_draws=%d view_window_presents=%d view_window_refused=%d view_window_camera=%s view_window_pass=%s", open, vws.opens, draws, presents, vws.refused, camera_name, pass_name)
	}
	fmt.printfln("screenshot_transparent=%d turntable_frames=%d turntable_written=%d", int(app.screenshot_transparent), app.turntable_frames, app.turntable.frame)
	fmt.printfln("print_mm=%g print_unit=%d print_exports=%d", print_scale(app), int(app.print_unit), app.print_exports)
	// A check of a big surface still running is waited for, so its findings are here.
	print_checks_stop(app)
	fmt.printfln("print_checks=%d print_open_edges=%d print_holes=%d print_wall=%g print_check_ms=%.1f print_bed=%gx%gx%g print_wall_least=%g", app.print_checks.runs, app.print_checks.result.open_edges, app.print_checks.result.holes, app.print_checks.result.wall, app.print_checks.ms, print_bed(app)[0], print_bed(app)[1], print_bed(app)[2], print_wall_least(app))
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
	if app.kit.events_unnamed > 0 {
		fmt.printfln("ui_events_unnamed=%d", app.kit.events_unnamed)
		exit_code^ = 2
	}
	macros_kept := 0
	for s in app.macro.slots do macros_kept += int(s.name != "")
	pack_alphas, pack_presets, pack_meshes, pack_materials := 0, 0, 0, 0
	for p in app.library.packs do pack_alphas, pack_presets, pack_meshes, pack_materials = pack_alphas + p.alphas, pack_presets + p.presets, pack_meshes + p.meshes, pack_materials + p.materials
	pack_matcaps := 0
	for m in app.library.matcaps do if !m.gone do pack_matcaps += 1
	fmt.printfln("library_alphas=%d library_skipped=%d alpha=%s packs=%d pack_alphas=%d pack_presets=%d pack_meshes=%d pack_materials=%d pack_matcaps=%d pack_matcap_textures=%d packs_installed=%d packs_refused=%d", app.library.alphas, app.library.skipped, alpha_ref(app, app.brush.alpha), len(app.library.packs), pack_alphas, pack_presets, pack_meshes, pack_materials, pack_matcaps, app.library.textures_made, app.library.installed, app.library.refused)
	fmt.printfln("link_sent=%d link_moved=%d link_swapped=%d link_added=%d link_token=%d", app.link.sends, app.link.moved, app.link.swapped, app.link.added, int(app.scene.link_token != 0))
	fmt.printfln("macros=%d macro_recording=%d macro_entries=%d macro_left_out=%d macros_run=%d scripts_run=%d macro_steps=%d", macros_kept, int(app.macro.recording), len(app.macro.entries), app.macro.left_out, app.macro.runs, app.macro.scripts, app.macro.steps)
	plugin_commands := 0
	for _, slot in app.plugins.slots do plugin_commands += int(plugin_slot_loaded(app, slot))
	fmt.printfln("plugins=%d plugin_commands=%d plugin_errors=%d plugin_runs=%d plugin_steps=%d", len(app.plugins.plugins) - plugins_failed(app), plugin_commands, app.plugins.errors, app.plugins.runs, app.plugins.steps)
	fmt.printfln("frames=%d dabs=%d objects=%d vertices=%d", loop.frame_index, app.stats.dabs_total, len(app.scene.objects), vertices)
	fmt.printfln("one_taps=%d tap_switches=%d", app.one_taps, app.tap_switches)
	diag_stats(app)
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
		// The Model mode cages: how many, what they are made of, and whether every one is sound.
		cages, points, edges, faces, ngons, broken, chosen, smooth, creased, corners, live_faces := 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
		mirrored, live_broken := 0, 0
		for obj in app.scene.objects {
			cp := obj.cage
			if cp == nil do continue
			c := poly.mesh_check(&cp.mesh)
			cages += 1
			points += c.vertices
			edges += c.edges
			faces += c.faces
			ngons += c.ngons
			broken += int(!poly.check_ok(c))
			for x in cp.mesh.selected do chosen += int(x)
			smooth = max(smooth, cp.look.smooth)
			e, v := poly.crease_count(&cp.mesh)
			creased += e
			corners += v
			if cp.live.vert_first != nil {
				live_faces += len(cp.live.mesh.face_he)
				live_broken += int(!poly.check_ok(poly.mesh_check(&cp.live.mesh)))
				mirrored += int(cp.look.live.mirror != {} && !cp.live.mirror_refused)
			}
		}
		fmt.printfln("cages=%d cage_points=%d cage_edges=%d cage_faces=%d cage_ngons=%d cage_broken=%d cage_selected=%d cage_smooth=%d cage_creases=%d cage_corners=%d cage_live_faces=%d cage_live_broken=%d cage_mirrored=%d tool=%v", cages, points, edges, faces, ngons, broken, chosen, smooth, creased, corners, live_faces, live_broken, mirrored, app.tool)
		fmt.printfln("model_action=%v model_target=%v model_done=%d model_refused=%d", app.model.action, model_target(&app.model, app.model.action), app.model.done, app.model.refused)
		// Where the selected object sits, which Align parts moves a whole cage to.
		at: Vec3
		if obj := selected_object(app); obj != nil do at = obj.transform.position
		fmt.printfln("selected_x=%.4f selected_y=%.4f selected_z=%.4f", at.x, at.y, at.z)
		tp := &app.model.topo
		fmt.printfln("topo_pen_dots=%d topo_pen_faces=%d topo_pen_welds=%d topo_pen_extends=%d topo_pen_relaxes=%d topo_pen_sheets=%d", len(tp.dots), tp.faces, tp.welds, tp.extends, tp.relaxes, tp.sheets)
		// How the selected object's levels above its base are made: Loop for a sculpt,
		// Smooth or Flat for one applied from a cage.
		if obj := selected_object(app); obj != nil && obj.voxel == nil && len(obj.levels.levels) > 0 {
			fmt.printfln("levels_rule=%v", obj.levels.rule)
		}
	}
	{
		off, ghosts := scene_view_counts(app)
		shown := 0
		for obj in app.scene.objects do shown += int(object_shown(app, obj))
		fmt.printfln("objects_shown=%d objects_off=%d objects_ghost=%d solo=%d selected_count=%d", shown, off, ghosts, int(app.scene.solo), len(selection_ids(app)))
		order, folders, names, places := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
		for obj, i in app.scene.objects {
			p := obj.transform.position
			fmt.sbprintf(&places, "%s%.3f:%.3f:%.3f", "," if i > 0 else "", p.x, p.y, p.z)
			fmt.sbprintf(&order, "%s%d", "," if i > 0 else "", obj.id)
			fmt.sbprintf(&folders, "%s%d", "," if i > 0 else "", obj.folder)
			fmt.sbprintf(&names, "%s%s", "," if i > 0 else "", object_label(obj))
		}
		// Each folder's name, whether it is open, and the folder it is in (0 for none).
		parents := strings.builder_make(context.temp_allocator)
		for &f, i in app.scene.folders {
			fmt.sbprintf(&names, "%s%s:%s", ";" if i == 0 else ",", folder_label(&f), "open" if f.open else "folded")
			fmt.sbprintf(&parents, "%s%d:%d", "," if i > 0 else "", f.id, f.parent)
		}
		spaced, _ := strings.replace_all(strings.to_string(names), " ", "_", context.temp_allocator)
		fmt.printfln("folders=%d tree_rows=%d scene_order=%s scene_folders=%s scene_names=%s scene_positions=%s folder_parents=%s", len(app.scene.folders), app.kit.tree_rows, strings.to_string(order), strings.to_string(folders), spaced, strings.to_string(places), strings.to_string(parents))
		fmt.printfln("import_folders=%d import_skins=%d import_animations=%d import_shapes=%d import_quads_joined=%d", app.import_folders, app.import_rig.skins, app.import_rig.animations, app.import_rig.shapes, app.import_joined)
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
		// Whether the camera is gliding to a view (camera_ease.odin), and how many glides
		// began and were cut short by the hand.
		fmt.printfln("camera_easing=%d camera_eases=%d camera_ease_cuts=%d", int(app.camera_ease.on), app.camera_ease.eases, app.camera_ease.cuts)
		// Motion II's moves as the run ends: how far the pie has unfolded, how far from its
		// place the hand switch still draws the bars, how many times view panes faded in, and
		// how many times Arrange opened (its outlines drawing in each time).
		fmt.printfln("pie_unfold=%.2f hand_slide=%.2f pane_fades=%d arrange_openings=%d", pie_unfolded(app), app.kit.ctx.mirror_slide, app.kit.grid.fades, app.kit.arrange.openings)
		fmt.printfln("long_job_running=%d long_jobs=%d long_job_cancels=%d long_job_ms=%.0f long_job_progress=%.2f", int(app.long_job.on), app.long_job.runs, app.long_job.cancels, app.long_job.ms, long_job_progress(app))
		fmt.printfln("cross_fading=%d look_fades=%d mesh_fades=%d", int(app.cross_fade.on), app.cross_fade.looks, app.cross_fade.meshes)
		fmt.printfln("flashing=%d undo_flashes=%d mask_wipes=%d selection_outlines=%d save_ticks=%d", int(flashing(app)), app.flashes.undos, app.flashes.masks, app.flashes.selections, app.flashes.saves)
		tw := app.pen_twist
		h := tw.hit.? or_else {}
		hint, _ := strings.replace_all(string(app.kit.ctx.roll_hint[:app.kit.ctx.roll_hint_len]), " ", "_", context.temp_allocator)
		fmt.printfln("pen_rolls=%d pen_roll_area=%s pen_roll_hit=%.4f,%.4f,%.4f roll_hint=%s", tw.rolls, strings.to_lower(fmt.tprint(tw.area), context.temp_allocator), h.x, h.y, h.z, hint if hint != "" else "none")
		p := app.pivot.used
		fmt.printfln("orbit_pivot=%.4f,%.4f,%.4f pivot_source=%s pinned=%d framed=%d touch_repeats=%d", p.x, p.y, p.z, strings.to_lower(fmt.tprint(app.pivot.from), context.temp_allocator), int(app.pivot.pinned), app.double_tap.framed, app.touch.hold.done)
		last_step := "none"
		if n := len(app.history.done); n > 0 do last_step, _ = strings.replace_all(app.history.done[n - 1].what, " ", "_", context.temp_allocator)
		fmt.printfln("size_previews=%d size_preview=%d", app.ui.size_preview.shown, int(app.ui.size_preview.kind != .None))
		fmt.printfln("undo_steps=%d redo_steps=%d brush_radius_px=%.2f brush_strength=%.3f brush_focal=%.0f selected=%d last_step=%s", len(app.history.done), len(app.history.undone), app.brush.radius_px, brush_strength(app)^, focal_shift(app)^, app.scene.selected, last_step)
		{
			m := app.move
			tr: Transform
			if obj := selected_object(app); obj != nil do tr = obj.transform
			transform_undo := 0
			for e in app.history.done do if e.kind == .Transform do transform_undo += 1
			lower :: proc(v: any) -> string {return strings.to_lower(fmt.tprint(v), context.temp_allocator)}
			pivot := "none"
			if obj := selected_object(app); obj != nil && gizmo_pivot_set(app) {
				at := gizmo_center(app, obj)
				pivot = fmt.tprintf("%.3f,%.3f,%.3f", at.x, at.y, at.z)
			}
			e := app.kit.gizmo_entry
			fmt.printfln("gizmo_pivot=%s gizmo_pivot_latch=%d gizmo_entry=%s", pivot, int(m.pivot_latch), lower(e.handle) if e.open else "none")
			// The sum of the selected object's coordinates, so a scenario can tell a mesh that
			// moved from one put back exactly.
			mesh_sum: f64
			if obj := selected_object(app); obj != nil do for q in object_sculptor(obj).mesh.positions do mesh_sum += f64(q.x) + f64(q.y) + f64(q.z)
			fmt.printfln("stroke_lines=%d stroke_joins=%d", app.stroke_end.lines, app.stroke_end.joins)
			fmt.printfln("gesture=%s mask_shape=%s", lower(app.gesture), lower(app.ui.mask_shape_kind))
			// The lights: which is picked, how many are on, the first one's view-space
			// direction as the sphere shows it, and taps that flipped a light's side.
			lights_on := 0
			set := &app.scene.lights
			for light in set.lights[:set.count] do lights_on += int(light.on)
			l1 := light_view_dir(app, 0)
			l1_name, _ := strings.replace_all(light_name(set, 0), " ", "_", context.temp_allocator)
			// Where the first light stands in the scene, a point light's or spot's place.
			l1_at := light_world_pos(app, set.lights[0]) if set.lights[0].kind != .Sun else Vec3{}
			fmt.printfln("light_pick=%d lights_on=%d light1=%.2f,%.2f,%.2f light1_on=%d light_flips=%d light_count=%d light1_kind=%s light1_space=%s light_moves=%d light1_name=%s light1_kelvin=%.0f light1_at=%.2f,%.2f,%.2f light_pick_strength=%.2f", app.light_pick + 1, lights_on, l1.x, l1.y, l1.z, int(set.lights[0].on), app.kit.light_sphere.flips, set.count, lower(set.lights[0].kind), lower(set.lights[0].space), app.ui.light_press.moves, l1_name, set.lights[0].kelvin, l1_at.x, l1_at.y, l1_at.z, set.lights[clamp(app.light_pick, 0, max(int(set.count) - 1, 0))].strength)
			fmt.printfln("brush_front_only=%d brush_lock_plane=%d brush_connected=%d brush_grab_depth=%d brush_grab_topological=%d brush_smooth_only=%v", int(app.brush.front_only), int(app.brush.lock_plane), int(app.brush.connected), int(app.brush.grab_depth), int(app.brush.grab_topological), app.brush.smooth_only)
			fmt.printfln("brush_hardness=%.2f brush_projected=%d", app.brush.falloffs[app.brush.kind].hardness, int(app.brush.falloffs[app.brush.kind].projected))
			d := detail_edit(&app.brush, app.brush.kind)
			fmt.printfln("detail_by_radius=%d detail_falloff=%d brush_dyntopo=%d brush_detail_own=%d", int(d.by_radius^), int(app.brush.detail_falloff), int(!app.brush.dyns[app.brush.kind].off), int(app.brush.dyns[app.brush.kind].own))
			fmt.printfln("pressure_response=%d pressure_own=%d", pressure_response(pressure_edit(&app.brush)), int(app.brush.pressures[app.brush.kind].own))
			fmt.printfln("grab_refine_splits=%d grab_refine_ms=%.2f", app.grab_refine.splits, app.grab_refine.ms)
			fmt.printfln("stretch_repair_splits=%d stretch_repair_ms=%.2f", app.stretch_repair.splits, app.stretch_repair.ms)
			fmt.printfln("pose_mode=%d pose_drags=%d pose_moved=%d mesh_sum=%.4f topo_masks=%d topo_reach=%.3f", int(pose_mode(app)), m.pose_drags, m.pose_moved, mesh_sum, m.topo_masks, m.topo_reach)
			fmt.printfln("gizmo_at=%.0f,%.0f gizmo_mode=%s gizmo_hover=%s gizmo_last=%s gizmo_drags=%d gizmo_snap=%d transform=%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.4f transform_undo=%d",
				m.drawn.x, m.drawn.y, lower(m.mode), lower(m.hover), lower(m.last), m.drags, int(m.snap), tr.position.x, tr.position.y, tr.position.z, tr.rotation.x, tr.rotation.y, tr.rotation.z, tr.scale, transform_undo)
		}
		{
			// The selected object's levels, name and material, the New scene shape armed and
			// whether the menu is open, for the starter and pack scenarios.
			obj := selected_object(app)
			name, _ := strings.replace_all(object_label(obj) if obj != nil else "none", " ", "_", context.temp_allocator)
			material := "none"
			if obj != nil && obj.material.label != nil do material, _ = strings.replace_all(string(obj.material.label), " ", "_", context.temp_allocator)
			fmt.printfln("selected_levels=%d selected_name=%s selected_material=%s new_armed=%d menu=%d", len(obj.levels.levels) if obj != nil else 0, name, material, app.kit.new_armed, int(app.kit.menu))
			objects_matcap := 0
			for o in app.scene.objects do if o.material.matcap != 0 do objects_matcap += 1
			fmt.printfln("material_tab=%s material_previews=%d material_keeps=%d selected_matcap=%d objects_matcap=%d material_to=%s material_favorites=%d material_favorite_changes=%d", strings.to_lower(MATERIAL_TAB_NAMES[app.kit.material_card.tab], context.temp_allocator), app.material_previews, app.material_keeps, obj.material.matcap if obj != nil else 0, objects_matcap, strings.to_lower(fmt.tprint(app.ui.material_to), context.temp_allocator), app.kit.material_card.favorite_count, app.kit.material_card.favorite_changes)
			preset := "none"
			if p, on := brush_preset(app); on do preset, _ = strings.replace_all(preset_name(p), " ", "_", context.temp_allocator)
			fmt.printfln("presets=%d preset=%d preset_name=%s preset_changed=%d", app.preset_count, app.brush.preset, preset, int(preset_changed(app)))
			fmt.printfln("browser=%d bar_tools=%s bars_edit=%d bar_slot_menu=%d bar_lifts=%d bar_drops=%d bar_refusals=%d bar_drops_off=%d bar_carry=%d", int(app.kit.browser), bar_names(app, .Tools), int(app.kit.bars_edit), int(app.kit.bar_slot.open),
				app.kit.bar_lifts, app.kit.bar_drops, app.kit.bar_refusals, app.kit.bar_drops_off, int(app.kit.bar_carry != nil))
			// The island's items and how its values show, the values on every bar, and the
			// value popovers opened, the chips scrubbed and the value the popover is on.
			fmt.printfln("offhand=%s offhand_looks=%s values=%d value_pops=%d value_scrubs=%d value_pop=%s pressure_size=%d pressure_strength=%d", bar_names(app, .Offhand), bar_looks(app, .Offhand),
				values_on_bars(app), app.kit.value_pops, app.kit.value_scrubs, strings.to_lower(fmt.tprint(app.kit.bar_pop.value), context.temp_allocator),
				int(app.brush.pressure_size), int(app.brush.pressure_strength))
			bind := &app.kit.bind
			fmt.printfln("key_overrides=%d bind_open=%d bind_command=%s bind_state=%s", app.key_override_count, int(bind.open), command_name(bind.id, bind.arg) if bind.id != .None else "none",
				strings.to_lower(fmt.tprint(bind.state), context.temp_allocator))
			// Which pie is open (-1 none, 0 the brushes) and its slice under the pointer, the
			// stars, pies 1 and 3 by command name, and two commands a pie runs, for the pie
			// scenarios.
			pie := app.ui.pie
			fmt.printfln("pie_open=%d pie_hover=%d pie_runs=%d pie_editor=%d favourites=%d pie1=%s pie3=%s wireframe=%d ortho=%d", pie.which if pie.open else -1, pie.hover if pie.open else -1,
				app.kit.pie_runs, int(app.kit.pie_editor), app.kit.favourite_count, pie_names(app, 0), pie_names(app, 2), int(app.wireframe), int(app.camera.ortho))
			// The haptics asked of the pencil, and whether the iPad's Only Draw with Apple Pencil
			// was on, for the pencil scenarios.
			fmt.printfln("haptics=%d pencil_only=%d pen_distance=%.2f", app.pencil.haptics, int(app.pencil.only), app.pen_distance)
			// The polygon edges the selected object's wireframe showed, none for triangles.
			poly_edges := 0
			if sel := selected_object(app); sel != nil && poly_edges_shown(app, sel) do poly_edges = int(sel.gpu[sel.levels.current].edge_indices) / 2
			fmt.printfln("floor_grid=%d floor_planes=%d%d%d transparent=%d fov=%.0f polyframe_lines=%d polyframe_fill=%d poly_edges=%d", int(app.floor.on), int(app.floor.planes[0]), int(app.floor.planes[1]), int(app.floor.planes[2]), int(app.see_through), math.to_degrees(app.camera.fov_y), int(app.polyframe_lines), int(app.polyframe_fill), poly_edges)
			bg := app.background
			fmt.printfln("background_gradient=%d background_top=%s background_bottom=%s", int(bg.gradient), hex_text(bg.top), hex_text(bg.bottom))
			lao := app.live_ao
			tr := app.studio.trace
			fmt.printfln("trace=%d trace_mb=%.1f trace_build_ms=%.1f trace_chunks_built=%d trace_rq=%d blas_builds=%d blas_refits=%d", tr.samples, f64(tr.bytes) / (1 << 20), tr.build_ms, tr.chunks_built, tr.rq_samples, tr.blas_builds, tr.blas_refits)
			fmt.printfln("live_ao=%d live_ao_full=%d live_ao_partial=%d live_ao_skipped=%d", int(app.live_ao_on), lao.full, lao.partial, lao.skipped)
			pr := app.path
			fmt.printfln("render_switch=%d render_quality=%s studio=%d", int(render_switch_on(app)), "full" if app.render_quality == .Full else "fast", int(app.studio_on))
			st := &app.studio
			fmt.printfln("studio_samples=%d studio_sequence=%d studio_carried=%d studio_carries=%d studio_carried_bare=%d studio_restarts=%d", st.samples, st.sequence, int(st.carried), st.carries, st.carried_bare, st.restarts)
			fmt.printfln("finish=%d finish_curve=%v finish_passes=%d finish_failed=%d finish_bloomed=%d finish_bloom_levels=%d finish_sharpened=%d thumbnail_finish_passes=%d", int(finish_wanted(app)), app.finish.curve, app.finished.passes, int(app.finished.failed), app.finished.bloomed, app.finished.levels, app.finished.sharpened, app.thumbnail.finished.passes)
			fmt.printfln("render=%d render_samples=%d render_ms=%.1f render_mb=%.1f render_failed=%d render_rq=%d", int(app.render_on), pr.total_samples, pr.total_ms / f64(max(pr.total_samples, 1)), f64(pr.bytes) / (1 << 20), int(pr.failed), pr.rq_samples)
			// Depth of field, whether a point was picked to focus on and where the focus is,
			// and whether Pick focus still waits for a press.
			focus := focus_point(app)
			_, picked := app.focus.?
			fmt.printfln("render_dof=%d render_blur=%.2f focus_picked=%d focus=%.3f,%.3f,%.3f focus_armed=%d", int(app.render_dof), app.render_blur, int(picked), focus.x, focus.y, focus.z, int(app.ui.focus_armed))
			env := app.env
			fmt.printfln("environment=%s environment_size=%dx%d environment_background=%d environment_mb=%.1f", "image" if env.kind == .Image && env.gpu.source != nil else "built_in", env.gpu.width, env.gpu.height, int(env.background), f32(render.environment_bytes(env.gpu)) / (1024 * 1024))
			fmt.printfln("environment_turn=%.1f environment_tilt=%.1f environment_turns=%d environment_recent=%d environment_backdrop=%s", env.turn, env.tilt, env.turns, len(env.recent), strings.to_lower(fmt.tprint(environment_backdrop(&env)), context.temp_allocator))
		}
		{
			// What the last stroke was, the rail's latches, and whether the selected object
			// has a mask, for touch_check's modifier rail scenarios.
			latched := "none"
			for m in app.rail.latched {
				name := strings.to_lower(MODIFIER_NAMES[m], context.temp_allocator)
				latched = name if latched == "none" else strings.concatenate({latched, "+", name}, context.temp_allocator)
			}
			obj := selected_object(app)
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
		fmt.printfln("labels_on=%d labels_kept=%d labels_shows=%d labels_drawn=%d labels_dropped=%d", int(help_labels_on(&app.kit)), int(app.kit.labels.latched), app.kit.labels.shows, app.kit.ctx.labels.drawn, app.kit.ctx.labels.dropped)
		fmt.printfln("long_tip=%s object_menu=%d object_menu_type=%v object_menu_rows=%d inspector_tab=%s brush_kind=%s", long_tip if long_tip != "" else "none", int(app.kit.object_menu), app.kit.object_menu_type, app.kit.object_menu_rows, strings.to_lower(fmt.tprint(section_palette(app.kit.stack.revealed.? or_else .Preset)), context.temp_allocator), strings.to_lower(fmt.tprint(app.brush.kind), context.temp_allocator))
		fmt.printfln("scene_menu=%d object_menu_opened_by=%s right_click=%s", int(app.kit.scene_menu), strings.to_lower(fmt.tprint(app.kit.object_menu_by), context.temp_allocator), strings.to_lower(fmt.tprint(app.nav.right_click), context.temp_allocator))
		fmt.printfln("offer=%v offer_fixes=%d colour_island=%d paint_on=%s", app.kit.offer, app.kit.offer_fixes, int(app.kit.colour_island), strings.to_lower(fmt.tprint(app.brush.paint_on), context.temp_allocator))
		fmt.printfln("motion=%s motion_off=%s", strings.to_lower(fmt.tprint(app.kit.ctx.motion), context.temp_allocator), strings.join(strings.fields(motion_off_text(&app.kit.ctx), context.temp_allocator), ",", context.temp_allocator) if motion_off_text(&app.kit.ctx) != "" else "none")
		// The stack scrolls in its column's body while docked and in its own while floating.
		tray_scroll := app.kit.scroll
		if _, docked := stack_docked(&app.kit); docked do tray_scroll = app.kit.panels.scroll
		fmt.printfln("inspector_scroll=%.1f settings_scroll=%.1f settings_open=%d", tray_scroll, app.kit.settings_scroll, int(app.kit.settings))
		n := app.cursor.normal
		fmt.printfln("cursor_hit=%d cursor_normal=%.4f,%.4f,%.4f", int(app.cursor.ok), n.x, n.y, n.z)
		k := &app.kit
		fmt.printfln("keyboard_down=%d keyboard_restarts=%d", int(k.keyboard_down), k.keyboard_restarts)
		fmt.printfln("palette=%d palette_runs=%d palette_last=%s settings_tab=%v settings_section=%v settings_found=%s tool=%s", int(k.palette), k.palette_runs, palette_entry_name(k.palette_last) if k.palette_ran else "none", k.settings_tab, k.settings_section, settings_found_text(k), strings.to_lower(fmt.tprint(app.tool), context.temp_allocator))
		fmt.printfln("export_open=%d export_preset=%v export_format=%v export_runs=%d export_last=%s export_print_all=%d export_decimate=%d export_decimate_to=%d export_decimated=%d export_hollow=%d export_hollow_wall=%.2f export_hollowed=%d", int(k.export.open), k.export.preset, k.export.format, k.export.runs, fmt.tprint(k.export.last_format) if k.export.ran else "none", int(k.export.print_all), int(k.export.decimate), k.export.decimate_to, app.export_decimated, int(k.export.hollow), export_hollow_wall(&k.export), app.export_hollowed)
		dial := strings.builder_make(context.temp_allocator)
		for d, i in dial_of(k) {
			if i > 0 do strings.write_byte(&dial, ',')
			switch v in d {
			case Modifier: fmt.sbprint(&dial, v)
			case Bar_Slot: strings.write_string(&dial, command_name(v.id, v.arg))
			}
		}
		zone := "none"
		if z, ok := k.arrange.picked.?; ok do zone = fmt.tprint(z)
		changed := 0
		for s in Space do if !dial_is_default(k, s) do changed += 1
		fmt.printfln("dial_spaces=%d exposure=%.1f light_place=%d", changed, app.exposure, int(app.ui.light_place))
		fmt.printfln("bar_places=%s bar_carries=%d", bar_places_text(k), k.arrange.carries)
		// The chip bar's sections standing on their own, and how many Arrange let go.
		fmt.printfln("chip_islands=%s chip_carries=%d", chip_islands_text(k), k.arrange.chip_carries)
		// The person's docks, and where each one shown was laid out, for touch_check.
		fmt.printf("user_docks=%s docks_made=%d docks_deleted=%d", user_docks_text(k), k.arrange.docks_made, k.arrange.docks_deleted)
		for i in 0 ..< USER_DOCKS do if k.docks[i].used {
			r := ui.prev_rect(&k.ctx, PLACE_BAR_ROOTS[user_dock_place(i)])
			fmt.printf(" layout_user_dock_%d=%.0f,%.0f,%.0f,%.0f", i + 1, r.x, r.y, r.w, r.h)
		}
		fmt.println()
		fmt.printfln("dial_sectors=%s arrange_zone=%s arrange_resets=%d library=%d library_tab=%v", strings.to_string(dial), zone, k.arrange.resets, int(k.bars_edit && !k.arrange.library_off), k.arrange.tab)
		groups := strings.builder_make(context.temp_allocator)
		for g in k.palette_groups do fmt.sbprintf(&groups, "%s%v", "," if strings.builder_len(groups) > 0 else "", g)
		locks := 0
		for obj in app.scene.objects do if obj.locked do locks += 1
		recording, level := -1, -1
		if obj := selected_object(app); obj != nil do recording, level = sculpt.sculptor_layer_recording(object_sculptor(obj)), obj.levels.current
		fmt.printfln("scene_filter=%d scene_rows=%d object_locks=%d layer_rows=%d layer_picked=%d layer_recording=%d layer_swipes=%d layer_menus=%d layer_tints=%d layer_pictures_drawn=%d tools_tab=%s mask_hidden=%d selected_level=%d", int(k.scene_query), k.scene_rows, locks, k.layer_rows, app.ui.layer_selected, recording, k.layer_panel.swipes, k.layer_panel.menus, k.layer_panel.tints, app.layer_picture_slots.drawn, strings.to_lower(TOOLS_TAB_NAMES[k.tools_tab], context.temp_allocator), int(app.ui.mask_hidden), level)
		spaces_off := 0
		for obj in app.scene.objects do if obj.spaces_off != {} do spaces_off += 1
		fmt.printfln("scene_kind=%s scene_adds=%d scene_light_switches=%d scene_row_menus=%d scene_space_changes=%d objects_spaces_off=%d", strings.to_lower(SCENE_KIND_NAMES[k.outliner.kind], context.temp_allocator), k.outliner.adds, k.outliner.switches, k.outliner.menus, k.outliner.space_changes, spaces_off)
		fmt.printfln("lens_focus=%d menu_sub=%v menu_subs=%d menu_recent_opens=%d palette_bar_puts=%d palette_groups=%s palette_pick=%s", int(lens_focus(k)), k.menu_sub, k.menu_subs, k.menu_recent_opens, k.palette_bar_puts, strings.to_string(groups) if strings.builder_len(groups) > 0 else "none", palette_entry_name(k.palette_picked.?) if k.palette_picked != nil && k.palette else "none")
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
		fmt.printfln("tray_section=%s tray_marked=%d mask_steps=%d mask_by=%s nav_taps=%d", fmt.tprint(k.stack.revealed.? or_else .Preset) if k.stack.revealed != nil else "none", int(k.pointed.id != .None && k.ctx.marked.found), app.ui.mask_steps, mask_by_word(app.ui.mask_by.kind), k.nav.taps)
		fmt.printfln("tour=%d tour_shown=%d tour_step=%s tour_done=%d tour_finished=%d", k.tour.step, int(k.tour.shown), strings.to_lower(fmt.tprint(k.tour.showing), context.temp_allocator) if k.tour.shown else "none", int(k.tour.done), k.tour.finished)
		fmt.printfln("coach=%d coach_shown=%d coach_step=%s", k.coach, int(k.coach_shown), strings.to_lower(fmt.tprint(k.coach_last), context.temp_allocator) if k.coach_shown else "none")
		// The action bar's groups as it last showed them (none while it waits for room), and
		// how often the mask was read.
		bar_groups := "none"
		if bar, _ := ui.prev_layout(&k.ctx, "action bar"); bar.x > 0 && action_bar_shown(app) {
			for g in action_groups_now(app) {
				name := strings.to_lower(fmt.tprint(g), context.temp_allocator)
				bar_groups = name if bar_groups == "none" else strings.concatenate({bar_groups, "+", name}, context.temp_allocator)
			}
		}
		fmt.printfln("action_bar=%s action_pop=%d mask_scans=%d", bar_groups, int(k.action_pop), app.mask_seen.scans)
		// The operation the bar can adjust now, how many re-runs there were, and whether
		// its popover is open.
		adjust_name, _ := strings.replace_all(strings.to_lower(ADJUST_NAMES[adjust_op_now(app)], context.temp_allocator), " ", "_", context.temp_allocator)
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
		recall_back, recall_reach, _ := recall_now(app)
		recall_pinned := false
		if obj := selected_object(app); obj != nil do recall_pinned = sculpt.sculptor_recall_pinned(object_sculptor(obj))
		fmt.printfln("recall_back=%d recall_reach=%d recall_pinned=%d recall_ms=%.1f", recall_back, recall_reach, int(recall_pinned), app.stats.recall_ms)
		// The History panel's view, how many rows its list holds (an opened group's strokes
		// among them), what the History holds and how many old steps it dropped.
		history_bytes, _ := history_memory(app)
		fmt.printfln("history_view=%s history_rows=%d history_bytes=%d history_dropped=%d history_bookmarks=%d history_menus=%d history_tints=%d history_tint=%d history_page=%s history_limit_mb=%d history_quick_scrubs=%d history_quick_last=%d history_quick=%s history_pictures_drawn=%d history_picture=%d history_pictures=%d", strings.to_lower(fmt.tprint(app.timeline.view), context.temp_allocator), len(history_rows(app, open_at = app.timeline.open_at, group = !app.history_ungrouped)), history_bytes, app.history.dropped, history_bookmarks(app), app.timeline.menus, app.timeline.tints, int(history_tint_step(app) != {}), "settings" if app.timeline.settings else "steps", app.history_limit_mb, app.timeline.quick.scrubs, app.timeline.quick.last, strings.to_lower(fmt.tprint(app.timeline.quick.by), context.temp_allocator), app.step_picture_slots.drawn, int(newest_step_pictured(app)), int(app.history_pictures))
		open := [Kit_Window]bool{.Inspector = k.inspector && !side_panel_open(k), .Stats = k.stats, .History = k.history, .Settings = k.settings, .Help = k.help, .Macros = k.macros, .Library = k.library, .Objects = k.objects_card, .Colors = k.colors_card, .Thumbnail = k.thumbnail}
		names := [Kit_Window]string{.Inspector = "inspector", .Stats = "stats", .History = "history panel", .Settings = "settings", .Help = "help", .Macros = "macros", .Library = "library", .Objects = "objects card", .Colors = "colors card", .Thumbnail = "thumbnail"}
		for w, which in k.windows {
			r := ui.prev_rect(&k.ctx, names[which])
			if which in PANEL_WINDOWS do r = panel_rect(app, which)
			fmt.printf("window_%s=%d,%d,%.0f,%.0f ", strings.to_lower(fmt.tprint(which), context.temp_allocator), int(open[which]), int(w.minimized), r.x, r.y)
		}
		fmt.println()
		// Where the stack goes (in layout terms), and which sections are kept in it.
		fmt.printf("stack_place=%s ", strings.to_lower(fmt.tprint(k.stack.place), context.temp_allocator))
		pins := strings.builder_make(context.temp_allocator)
		for c in k.stack.order {
			sec, is := panel_section(c)
			if !is || !k.stack.set || !stack_kept(&k.stack, c) do continue
			if strings.builder_len(pins) > 0 do strings.write_byte(&pins, ',')
			strings.write_string(&pins, strings.to_lower(fmt.tprint(sec), context.temp_allocator))
		}
		fmt.printfln("panel_pins=%s panel_moves=%d panel_menu=%d", strings.to_string(pins) if strings.builder_len(pins) > 0 else "none", k.panels.moves, int(k.panels.menu))
		// On a narrow window, the side whose docked stack is popped over the view.
		popped := "none"
		if side, docked := stack_docked(k); docked && k.panels.popped do popped = "left" if side == .Left else "right"
		fmt.printfln("columns_narrow=%d column_popped=%s column_pops=%d", int(stack_narrow(app)), popped, k.panels.pops)
		// The workspace (its name escaped, as it may hold spaces), whether its layout has
		// changes not saved, how many there are, and the zones hidden (by it or a view toggle).
		if w := &k.workspaces; len(w.list) > 0 {
			count := 0
			for ws in w.list do if ws.used do count += 1
			zones := strings.builder_make(context.temp_allocator)
			for z in Zone do if zone_hidden(k, z) do fmt.sbprintf(&zones, "%s%s", "," if strings.builder_len(zones) > 0 else "", strings.to_lower(fmt.tprint(z), context.temp_allocator))
			fmt.printfln("workspace=%s workspace_modified=%d workspace_count=%d workspace_menu=%d workspace_switches=%d workspace_exports=%d workspace_imports=%d zones_hidden=%s", preset_escape(workspace_name(k, w.current)), int(w.modified), count, int(w.menu), w.switches, w.exports, w.imports, strings.to_string(zones) if strings.builder_len(zones) > 0 else "none")
			// The working space, how many times it changed, and the view toggles.
			// The interface's layout faults in the last whole frame (ui.layout_fault): rows
			// whose children lie over each other or spill out of a fixed size.
			lo := k.ctx.overlap_prev
			fmt.printfln("layout_overlaps=%d layout_overlap_at=%.0f,%.0f,%.0f,%.0f", k.ctx.overlaps_prev, lo.x, lo.y, lo.w, lo.h)
			fmt.printfln("space=%s space_switches=%d focus_mode=%d inspect_mode=%d object_chip=%s view_chips=%d view_chips_at=%.0f,%.0f", strings.to_lower(SPACE_NAMES[k.spaces.current], context.temp_allocator), k.spaces.switches, int(k.focus_mode), int(k.inspect.on), object_chip_stat(app), int(k.view_chips_shown), k.view_chips_at.x, k.view_chips_at.y)
			// The second line of the top bar's file block.
			fmt.printfln("file_status=%s clean_view=%d panels_faded=%d camera_shift=%.3f,%.3f", preset_escape(file_status(app, time.now())), int(k.clean), k.panels_faded, app.camera.shift.x, app.camera.shift.y)
			// The chrome round the view: the view rail's slots, the mini view's swaps, the
			// main camera's projection, and where the island, the chips, the navigation head and
			// the mini view stood last, in points.
			island, chips, head := ui.prev_rect(&k.ctx, "brush bar"), ui.prev_rect(&k.ctx, "points"), ui.prev_rect(&k.ctx, "navigation head")
			mini := panel_rect(app, Kit_Window.Thumbnail)
			fmt.printfln("view_rail=%s mini_swaps=%d mini_rows=%d camera_ortho=%d island=%.0f,%.0f,%.0f,%.0f chips=%.0f,%.0f nav_head=%.0f,%.0f mini=%.0f,%.0f,%.0f,%.0f", bar_names(app, .View_Rail), k.mini_swaps, int(k.mini_rows), int(app.camera.ortho), island.x, island.y, island.w, island.h, chips.x, chips.y, head.x, head.y, mini.x, mini.y, mini.w, mini.h)
			sh := &k.shelf
			page_word, _ := strings.replace_all(shelf_page_name(k, sh.page), " ", "_", context.temp_allocator)
			fmt.printfln("shelf_page=%v shelf=%s shelf_quick=%d brush_sheet=%d shelf_drops=%d shelf_turns=%d shelf_swipes=%d shelf_tools=%d shelf_shown=%d shelf_fits=%d shelf_tile=%.0f brush_grid_scroll=%.0f shelf_active=%d shelf_pages=%d shelf_page_name=%s shelf_pages_added=%d", sh.page, bar_names(app, shelf_which(sh.page)), int(sh.quick), int(k.browser && k.browser_at == .Dock), sh.drops, sh.turns, sh.swipes, sh.tools, sh.shown, sh.fits, sh.tile_w, k.grid_scroll, int(sh.active), len(shelf_pages(k, k.spaces.current)), page_word, sh.added)
			fmt.printfln("brush_pie=%s pie_quicks=%d", bar_names(app, .Brush_Pie), k.pie_quicks)
			fmt.printfln("stack_visit=%s stack_visits=%d", stack_visit_text(k), k.stack.visits)
			fmt.printfln("stack=%s stack_shut=%s stack_menu=%d stack_folds=%d stack_moves=%d stack_joins=%d stack_shown=%s stack_drops=%d stack_carry=%s stack_target=%v", stack_text(k), stack_shut_text(k), int(k.stack.menu), k.stack.folds, k.stack.moves, k.stack.joins, stack_shown_text(k), k.stack.drops, stack_carry_text(k), k.stack.target.kind)
			fmt.printfln("stack_width=%d stack_sizes=%s stack_resizes=%d stack_columns=%s tray_width=%d", int(stack_width(k)), stack_sizes_text(k), k.stack.resizes, stack_columns_text(k), int(tray_width(app)))
			// What floats in front of everything else, as the floating order ends.
			front := "none"
			if n := len(k.order); n > 0 do front = fmt.tprint(k.order[n - 1])
			fmt.printfln("float_front=%s", front)
			fmt.printfln("pass=%v pass_shown=%v pass_menu=%d pass_switches=%d", k.passes.pass, viewport_pass(k), int(k.passes.menu), k.passes.switches)
			fmt.printfln("shading_mode=%v solid_lighting=%v solid_color=%v solid_matcap=%d", main_shading_mode(app), k.passes.shading.lighting, k.passes.shading.color, k.passes.shading.matcap)
			fmt.printfln("wipe=%d wipe_at=%.3f wipe_right=%v wipe_drags=%d", int(wipe_shown(k)), k.passes.wipe_at, wipe_right(k), k.passes.wipe_drags)
			fmt.printfln("guides=%d guide_heights=%s guide_lines=%d guide_drags=%d", int(app.scene.guides.shown), guides_heights_text(app.scene.guides), k.guide_lines, k.guide_drags)
		}
		// The side bars' popover: what it shows (a section by its name), or none; the look.
		pop := "none"
		if p := k.bar_pop; p.open do pop = strings.to_lower(fmt.tprint(p.section) if p.kind == .Section else fmt.tprint(p.kind), context.temp_allocator)
		fmt.printfln("bar_pop=%s look=%s symmetry=%s live_boolean=%d dynamic=%d", pop, strings.to_lower(fmt.tprint(k.look), context.temp_allocator), symmetry_label(app),
			int(app.ui.boolean.live), int(command_checked(app, .Dyntopo_Toggle)))
		// The brush's colours and channel, whether it subtracts, and how many vertices of the
		// selected object carry paint.
		painted := 0
		if obj := selected_object(app); obj != nil && obj.voxel == nil {
			for c in object_sculptor(obj).color do if c.a > 0 do painted += 1
		}
		main_hex, second_hex: [8]u8
		color_hex_format(app.brush.color, main_hex[:])
		color_hex_format(app.brush.color2, second_hex[:])
		fmt.printfln("paint_channel=%s paint_color=%s paint_color2=%s brush_subtract=%d painted_vertices=%d paint_dial=%d", strings.to_lower(fmt.tprint(app.brush.channel), context.temp_allocator), string(main_hex[1:7]), string(second_hex[1:7]), int(.Invert in app.rail.latched), painted, int(app.brush.paint_dial))
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
			if name == "inspector" do r = panel_rect(app, Kit_Window.Inspector)
			key, _ := strings.replace_all(name, " ", "_", context.temp_allocator)
			fmt.printf("layout_%s=%.0f,%.0f,%.0f,%.0f ", key, r.x, r.y, r.w, r.h)
		}
		for r, side in k.panels.rect do fmt.printf("layout_%s_column=%.0f,%.0f,%.0f,%.0f ", "left" if side == .Left else "right", r.x, r.y, r.w, r.h)
		fmt.println()
	}
	if opts.check_mesh {
		// A --bench-stroke run exits with its pen down; the check is of the finished stroke
		// (a clay's band repair and saddle pass run at its end).
		stroke_finish(app)
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
	fmt.printfln("peak_rss_mb=%.0f", peak_rss_mb())
	layers := 0
	for obj in app.scene.objects do layers += sculpt.levels_layer_count(&obj.levels)
	// The selected object's picked layer's strength, as the Layers panel shows it.
	picked_strength: f32
	// The selected object's layers with a mask, and the layer whose mask is picked (-1 for none).
	masked, mask_picked := 0, -1
	if obj := selected_object(app); obj != nil {
		s := object_sculptor(obj)
		list := sculpt.sculptor_layers(s)
		if i := app.ui.layer_selected; i >= 0 && i < len(list) do picked_strength = list[i].strength
		for _, i in list do if sculpt.sculptor_layer_has_mask(s, i) do masked += 1
		mask_picked = sculpt.sculptor_layer_mask_picked(s)
	}
	fmt.printfln("layers=%d layers_noted=%d layers_carry_ms=%.1f layer_strength=%.2f layer_masks=%d layer_mask_picked=%d layer_mask_picks=%d", layers, app.layers_noted, app.stats.layers_carry_ms, picked_strength, masked, mask_picked, app.ui.layer_mask.picks)
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
	fmt.printfln("cull=%v last_frame_draws=%d chunks=%d culled_view=%d culled_back=%d cull_ms=%.3f gpu_cull=%v gpu_culls=%d", app.renderer.cull, v.draws, v.chunks, v.culled_view, v.culled_back, v.cull_ms, app.renderer.gpu_cull && render.caps(&app.renderer).gpu_cull, app.renderer.gpu_culling.culls)
	if app.renderer.gpu_culling.check {
		meshes, commands, mismatch := render.gpu_cull_check(&app.renderer)
		fmt.printfln("cull_meshes=%d cull_commands=%d cull_mismatch=%d", meshes, commands, mismatch)
	}
	fmt.printfln("idle_rests=%d idle_rest_ms=%.0f", app.idle.rests, app.idle.rest_ms)
	fmt.printfln("partial=%v partial_frames=%d last_frame_partial=%v last_frame_redrawn_px=%d viewport_px=%d", app.renderer.partial, app.stats.partial_frames, v.partial, v.redrawn_px, app.target.width * app.target.height)
	fmt.printfln("viewport_tile=%v viewport_target_mb=%.1f", app.target.tile, f64(render.viewport_target_bytes(app.target)) / (1 << 20))
	lod_pending := 0
	for obj in app.scene.objects do lod_pending += sculpt.sculptor_lod_pending(object_sculptor(obj))
	fmt.printfln("simplify=%v last_frame_lod_px=%.2f last_frame_simplified=%d lod_pending=%d", app.simplify, app.renderer.lod_px, v.simplified, lod_pending)
	if app.stats.lod_ms.count > 0 do print_stat("lod_build_ms", app.stats.lod_ms)
	fmt.printfln("gpu_backend=%s gpu_choice=%v gpu_fallback=%v", render.backend_name(), app.graphics_start, render.backend_fallback() != "")
	fmt.printfln("present_mode=%s present_offers=%s", render.renderer_present_name(&app.renderer), present_offers(app))
	fmt.printfln("pre_rotate=%v swapchain_turns=%d", !opts.no_pre_rotate && ODIN_PLATFORM_SUBTARGET == .Android, render.swapchain_turns(loop.window))
	caps := render.caps(&app.renderer)
	fmt.printfln("low_latency=%v frames_in_flight=%d frames_cheap=%v present_timing=%v", app.low_latency, caps.frames_in_flight, caps.frames_cheap, caps.present_timing)
	if linked, known := render.display_link_frames(&app.renderer); known do fmt.printfln("display_link=%v display_link_frames=%d", app.display_link, linked)
	print_stat("frame_ms", app.stats.frame_ms)
	print_stat("cpu_ms", app.stats.cpu_ms)
	print_stat("wait_ms", app.stats.wait_ms)
	if app.time_gpu do print_stat("gpu_ms", app.stats.gpu_ms)
	fmt.printfln("gpu_timestamps=%v gpu_subgroup_size=%d gpu_int64_atomics=%v shared_buffers=%v transient_targets=%v exact_compute=%v texture_arrays=%d async_compute=%v render_async=%v ray_query=%v ray_query_check=%v", render.caps(&app.renderer).timestamps, render.caps(&app.renderer).subgroup_size, render.caps(&app.renderer).int64_atomics, render.caps(&app.renderer).shared_buffers, render.caps(&app.renderer).transient_targets, render.caps(&app.renderer).exact_compute, render.caps(&app.renderer).texture_arrays, render.caps(&app.renderer).async_compute, render_async(app), render.caps(&app.renderer).ray_query, app.renderer.ray_query_check)
	for r, span in app.stats.gpu_spans do if r.count > 0 do print_stat(fmt.tprintf("gpu_%s_ms", render.GPU_SPAN_NAMES[span]), r)
	if app.stats.ui_ms.count > 0 {
		print_stat("ui_ms", app.stats.ui_ms)
		fmt.printfln("ui_vertices=%d", app.stats.ui_vertices)
		cache := &app.kit.ctx.fonts.cache
		fmt.printfln("ui_text_lines=%d ui_text_layouts=%d ui_text_reads=%d", len(cache.runs), cache.misses, cache.hits)
	}
	if app.stats.cursor_ms.count > 0 do print_stat("cursor_ms", app.stats.cursor_ms)
	if p := app.pen_samples; p.frames > 0 {
		fmt.printfln("samples_frames=%d samples_frame_mean=%.2f samples_frame_max=%d samples_coalesced=%d", p.frames, f64(p.total) / f64(p.frames), p.most, p.coalesced)
	}
	if app.stats.dabs_total > 0 {
		print_stat("raycast_ms", app.stats.raycast_ms)
		print_stat("brush_ms", app.stats.brush_ms)
		print_stat("normals_ms", app.stats.normals_ms)
		print_stat("upload_kb", app.stats.upload_kb)
		print_stat("latency_ms", app.stats.latency_ms)
	}
	if app.stats.display_ms.count > 0 do print_stat("display_ms", app.stats.display_ms)
	if dropped, known := render.frames_dropped(&app.renderer); known do fmt.printfln("frames_dropped=%d", dropped)
	if opts.bench_stroke > 0 {
		// The synthetic stroke never lifts the button: end it, then time undo and redo
		// of the whole stroke, each including the normal update that follows.
		stroke_finish(app)
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
		history_undo(app)
		flush_all(app)
		t1 := time.tick_now()
		history_redo(app)
		flush_all(app)
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
				if !object_set_level(app, obj, target) do return false
				fmt.printf("%d->%d:%.1f+%.1f ", from + 1, target + 1, app.stats.level_sync_ms, app.stats.level_show_ms)
				free_all(context.temp_allocator)
			}
			fmt.println()
		}
	}
	return true
}
