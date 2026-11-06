package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"

import "../camera"

import "../jobs"
import "../sculpt"
import "../ui"
import "../uv"

// Unwrap (the Surface plan's UV4, mock C): one tap gives the selected object UVs, as
// ZBrush's UV Master, Nomad's auto unwrap and Blender's Smart UV Project do: seams where
// they are least seen (creases, polygroup borders), each piece laid flat (ABF++), relaxed
// and packed into the square (uv.unwrap). It lives in the Mesh card's UVs section; where
// something needs UVs that are missing (Bake, Textures) an ask opens that section rather
// than a second button. A quad object keeps its quads whole, so its UVs still bake and
// export as quads. The UVs replace the old ones in one undo step, with the maps that
// followed the old ones (the .Textures step), and a big object unwraps on
// the long job's thread with progress and Cancel.

// Relax steps by default and at most: five already brings a sphere's stretch from 1.03 to
// about 1.005, and past twenty the gain is too small for the time.
UNWRAP_RELAX_DEFAULT :: 5
UNWRAP_RELAX_MAX :: 20
// Set texel density's Density, in texels of a map Bake's size a unit of the scene: from a
// prop seen far off to a close-up's detail.
UV_TEXEL_PX_MIN :: 16
UV_TEXEL_PX_MAX :: 16384
UV_TEXEL_PX_DEFAULT :: 1024

// The plane mirrored islands are laid out alike across, if any (uv.Symmetry's axis + 1).
Unwrap_Symmetry :: enum u8 {
	Off,
	X,
	Y,
	Z,
}

UNWRAP_SYMMETRY_NAMES := [Unwrap_Symmetry]string {
	.Off = "Off",
	.X   = "X",
	.Y   = "Y",
	.Z   = "Z",
}

// What one Unwrap is asked for: the section's settings when it was tapped.
Unwrap_Setup :: struct {
	relax:     i32,
	symmetry:  Unwrap_Symmetry,
	keep:      bool, // flatten along the UVs' own seams
}

unwrap_setup :: proc(app: ^App) -> Unwrap_Setup {
	return {app.ui.unwrap_relax, app.ui.unwrap_symmetry, app.ui.unwrap_keep_seams}
}

// Counted for the exit stats.
Unwrap_Stats :: struct {
	runs:    int,
	islands: int, // the last one's
	ms:      f64,
}

// The UVs section's readout, worked out again only when the object or its UVs change:
// the stretch reads every triangle.
Uv_Readout :: struct {
	id:      int,
	layout:  u32,
	corners: rawptr,
	count:   int,
	l2:      f64,
	flips:   int,
	density: f64, // the UVs' length a unit of the object's own surface takes (uv.Stretch)
}

// Whether `obj` can be unwrapped now, saying why not when it cannot: its base level's
// triangles are what get UVs, and dynamic topology changes them under every stroke.
unwrap_check :: proc(app: ^App, obj: ^Object) -> bool {
	if obj.curve != nil || obj.cage != nil {
		report(app, Section.Uvs, {.Warning}, "Unwrap needs a sculpt: %s has no surface of its own", object_label(obj))
		return false
	}
	if object_dynamic(obj) {
		report(app, Section.Uvs, {.Warning}, "Unwrap keeps to fixed triangles: turn dynamic topology off on %s first (Mesh > Topology)", object_label(obj))
		return false
	}
	return true
}

// The new UVs of `obj`'s base level as `setup` asks, made with the levels' allocator, on
// whatever thread calls it (the frame's or the long job's, with its own `pool`, while the
// scene holds still). False, with nothing made, when `progress` was cancelled.
unwrap_compute :: proc(obj: ^Object, setup: Unwrap_Setup, pool: ^jobs.Pool, progress: ^jobs.Progress = nil) -> (u: uv.Uvs, r: uv.Unwrap_Report, ok: bool) {
	l := &obj.levels
	base := l.levels[0]
	indices := base.mesh.indices[:]
	faces := base.sculptor.faces
	partner: []i32
	if sculpt.levels_has_quads(l) {
		// A quad object whose triangles are not all halves of its quads unwraps as triangles.
		partner, _ = uv.quad_partners(sculpt.levels_quad_mesh(l), indices, faces, context.temp_allocator)
	}
	keep := setup.keep && uv.has(l.uvs)
	u = uv.clone(l.uvs, l.allocator) if keep else uv.make_uvs(len(indices) / 3, l.allocator)
	options := uv.DEFAULT_UNWRAP
	options.relax, options.keep_seams = int(setup.relax), keep
	if setup.symmetry != .Off {
		options.symmetric = true
		options.symmetry.axis = u8(setup.symmetry) - 1
	}
	r = uv.unwrap(&u, base.mesh.positions[:], indices, faces, sculpt.sculptor_groups(&base.sculptor), nil, options, pool, partner, progress)
	if r.cancelled {
		uv.destroy(&u, l.allocator)
		return {}, r, false
	}
	return u, r, true
}

// Unwrap on the frame's thread, for a small object or a scripted run.
object_unwrap :: proc(app: ^App, obj: ^Object, setup: Unwrap_Setup) {
	start := time.tick_now()
	sculpt.levels_sync(&obj.levels)
	u, r, ok := unwrap_compute(obj, setup, &app.pool)
	if ok do unwrap_apply(app, obj, u, r, start)
}

// Takes the new UVs `u` as `obj`'s, in one undo step with the maps that followed the old
// ones, and reports what came of it.
unwrap_apply :: proc(app: ^App, obj: ^Object, u: uv.Uvs, r: uv.Unwrap_Report, start: time.Tick) {
	had := object_has_textures(obj)
	textures_replace(app, obj, {}, "unwrap", u)
	ms := time.duration_milliseconds(time.tick_since(start))
	app.unwraps.runs += 1
	app.unwraps.islands, app.unwraps.ms = u.islands, ms
	note := ", its maps removed (they followed the old UVs)" if had else ""
	lost := r.flatten.failed + r.flatten.closed
	if lost > 0 {
		report(app, Section.Uvs, {.Warning}, "Unwrapped %s: %d islands filling %.0f%%, %d of them not laid flat (%.0f ms)%s", object_label(obj), u.islands, 100 * u.filled, lost, ms, note)
	} else {
		report(app, Section.Uvs, {}, "Unwrapped %s: %d islands filling %.0f%% (%.0f ms)%s", object_label(obj), u.islands, 100 * u.filled, ms, note)
	}
}

// Straighten (UV6b): lays each of a quad object's islands out as a grid (uv.straighten),
// in one undo step with the maps that followed the old UVs, as Unwrap does.
object_straighten :: proc(app: ^App, obj: ^Object) {
	start := time.tick_now()
	l := &obj.levels
	sculpt.levels_sync(l)
	if !sculpt.levels_has_quad_uvs(l) {
		report(app, Section.Uvs, {.Warning}, "Straighten needs a quad object with UVs: %s has none", object_label(obj))
		return
	}
	base := l.levels[0]
	indices := base.mesh.indices[:]
	partner, ok := uv.quad_partners(sculpt.levels_quad_mesh(l), indices, base.sculptor.faces, context.temp_allocator)
	if !ok {
		report(app, Section.Uvs, {.Warning}, "Straighten needs whole quads: %s's triangles are not all halves of its quads", object_label(obj))
		return
	}
	u := uv.clone(l.uvs, l.allocator)
	r := uv.straighten(&u, base.mesh.positions[:], indices, base.sculptor.faces, partner)
	if r.straightened == 0 {
		uv.destroy(&u, l.allocator)
		report(app, Section.Uvs, {.Warning}, "Straighten left %s as it was: none of its %d islands is a clean grid of quads", object_label(obj), r.kept)
		return
	}
	had := object_has_textures(obj)
	textures_replace(app, obj, {}, "straighten", u)
	ms := time.duration_milliseconds(time.tick_since(start))
	kept := fmt.tprintf(", %d not a clean grid of quads kept %s shape", r.kept, "its" if r.kept == 1 else "their") if r.kept > 0 else ""
	note := ", its maps removed (they followed the old UVs)" if had else ""
	report(app, Section.Uvs, {}, "Straightened %d %s of %s%s, filling %.0f%% (%.0f ms)%s", r.straightened, "island" if r.straightened == 1 else "islands", object_label(obj), kept, 100 * u.filled, ms, note)
}

// Set texel density (UV6d): evens out `obj`'s islands to one density and sets it to `px`
// texels of a map Bake's size a unit of the scene, the object's scale counted, or the most
// one square holds, in one undo step with the maps that followed the old UVs.
object_texel_density :: proc(app: ^App, obj: ^Object, px: f64) {
	l := &obj.levels
	sculpt.levels_sync(l)
	if !sculpt.levels_has_uvs(l) {
		report(app, Section.Uvs, {.Warning}, "Set texel density needs UVs: %s has none", object_label(obj))
		return
	}
	side := f64(app.ui.bake.size)
	scale := f64(obj.transform.scale)
	if side <= 0 || scale <= 0 || px <= 0 do return
	base := l.levels[0]
	u := uv.clone(l.uvs, l.allocator)
	r := uv.set_density(&u, base.mesh.positions[:], base.mesh.indices[:], px * scale / side)
	if r.reached <= 0 {
		uv.destroy(&u, l.allocator)
		report(app, Section.Uvs, {.Warning}, "Set texel density left %s as it was: its UVs have no area", object_label(obj))
		return
	}
	had := object_has_textures(obj)
	textures_replace(app, obj, {}, "texel density", u)
	reached, most := r.reached * side / scale, r.most * side / scale
	held := fmt.tprintf(" (%.0f asked, the most one square holds)", px) if most < px - 0.5 else fmt.tprintf(", up to %.0f fits", most)
	note := ", its maps removed (they followed the old UVs)" if had else ""
	report(app, Section.Uvs, {}, "Set %s to %.0f px a unit at %d%s, filling %.0f%%%s", object_label(obj), reached, app.ui.bake.size, held, 100 * u.filled, note)
}

// How far Peel lays `obj` flat: the UVs section's Peel for the object it was set on while
// that object is selected, else 0.
uv_peel_of :: proc(app: ^App, obj: ^Object) -> f32 {
	if app.ui.uv_peel <= 0 || obj.id != app.ui.uv_peel_id || selected_object(app) != obj do return 0
	return app.ui.uv_peel
}

// The selected object's UVs measured, again only when they changed.
uv_readout :: proc(app: ^App, obj: ^Object) -> Uv_Readout {
	u := obj.levels.uvs
	r := &app.ui.uv_readout
	if r.id == obj.id && r.layout == obj.textures.layout && r.corners == raw_data(u.corner) && r.count == len(u.corner) do return r^
	base := obj.levels.levels[0]
	s := uv.stretch(u, base.mesh.positions[:], base.mesh.indices[:])
	r^ = {obj.id, obj.textures.layout, raw_data(u.corner), len(u.corner), s.l2, s.flips, s.density}
	return r^
}

// The folded UVs section's line: how the object's UVs are laid out, or that it has none.
uvs_summary :: proc(obj: ^Object) -> string {
	if obj == nil || obj.voxel != nil || obj.curve != nil do return ""
	u := obj.levels.uvs
	if !uv.has(u) do return "No UVs"
	return fmt.tprintf("%d islands · %.0f%%", u.islands, 100 * u.filled)
}

// The Mesh card's UVs section (mock C): Unwrap, its help, Relax, Symmetry and Keep my
// seams, Peel, then how the UVs read now, and Straighten and Set texel density under
// More options.
kit_uvs_section :: proc(app: ^App) {
	ctx := &app.kit.ctx
	obj := selected_object(app)
	kit_last_result(app, .Uvs)
	_ = command_button(app, .Unwrap, variant = .Solid, tone = .Accent)
	ui.paragraph(ctx, "Cuts seams along creases and polygroup borders, lays each piece flat and packs them in the square. A quad object keeps its quads whole. The new UVs replace the old ones, and the maps made on them, in one undo step.")
	relax := f32(app.ui.unwrap_relax)
	if ui.slider(ctx, "Relax", &relax, 0, UNWRAP_RELAX_MAX, .Linear, fmt.tprintf("%d steps", app.ui.unwrap_relax) if app.ui.unwrap_relax > 0 else "Off") do app.ui.unwrap_relax = i32(relax + 0.5)
	axes: [len(Unwrap_Symmetry)]string
	for s in Unwrap_Symmetry do axes[int(s)] = UNWRAP_SYMMETRY_NAMES[s]
	ui.label(ctx, "SYMMETRY")
	if picked := ui.tabs(ctx, "unwrap symmetry", axes[:], int(app.ui.unwrap_symmetry)); picked >= 0 do app.ui.unwrap_symmetry = Unwrap_Symmetry(picked)
	has := obj != nil && obj.voxel == nil && obj.curve == nil && uv.has(obj.levels.uvs)
	_ = ui.switch_row(ctx, "Keep my seams" if has else "Keep my seams (no UVs yet)", &app.ui.unwrap_keep_seams, enabled = has)
	if has {
		// Peel morphs the object into its layout and back, a look only.
		peel := uv_peel_of(app, obj)
		if ui.slider(ctx, "Peel", &peel, 0, 1, .Linear, fmt.tprintf("%.0f%%", 100 * peel) if peel > 0 else "Off") {
			// A peel faces the view it began in and holds there while the camera turns, so
			// the flat layout can be looked round like any object.
			if uv_peel_of(app, obj) == 0 {
				right, up, back := camera.orbit_basis(app.camera)
				turn := linalg.transpose(transform_rotation(obj.transform))
				app.ui.uv_peel_frame = {turn * right, turn * up, turn * back}
			}
			app.ui.uv_peel, app.ui.uv_peel_id = peel, obj.id
		}
		r := uv_readout(app, obj)
		u := obj.levels.uvs
		flips := fmt.tprintf(", %d folded", r.flips) if r.flips > 0 else ""
		ui.value_row(ctx, "Now", fmt.tprintf("%d islands · stretch %.3f · %.0f%% filled%s", u.islands, r.l2, 100 * u.filled, flips))
		// In texels of a map Bake's size across a unit of the scene, the object's scale counted.
		side := app.ui.bake.size
		scale := f64(obj.transform.scale)
		if scale > 0 do ui.value_row(ctx, "Texel density", fmt.tprintf("%.0f px a unit at %d", r.density * f64(side) / scale, side))
	}
	if kit_more(app, .Uvs) {
		_ = command_button(app, .Straighten, variant = .Bordered)
		ui.paragraph(ctx, "Lays each quad island out as a grid of rectangles, its rows and columns as long as on the model, so texture rows run along the loops. Islands that are not a clean grid of quads keep their shape, and all are packed again.")
		// The density Set texel density sets, read in the same texels as the readout above.
		if ui.slider(ctx, "Density", &app.ui.uv_texel_px, UV_TEXEL_PX_MIN, UV_TEXEL_PX_MAX, .Logarithmic, fmt.tprintf("%.0f px a unit", app.ui.uv_texel_px)) do app.ui.uv_texel_px = math.round(app.ui.uv_texel_px)
		_ = command_button(app, .Texel_Density, variant = .Bordered)
		ui.paragraph(ctx, "Evens out every island to one density, so detail is as fine all over, then sets it to Density as near as the square holds: less leaves the square partly empty.")
		kit_more_end(app)
	}
}

// The ask where something needs UVs the object lacks (Bake, Textures): one line and a
// button that opens the UVs section, so Unwrap keeps one home.
kit_uvs_ask :: proc(app: ^App, why: string) {
	ctx := &app.kit.ctx
	ui.paragraph(ctx, why)
	_ = command_button(app, .Open_Section, int(Section.Uvs), label = "Unwrap in Mesh", variant = .Bordered)
}
