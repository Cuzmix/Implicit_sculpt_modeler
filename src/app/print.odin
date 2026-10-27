package main

import "core:fmt"
import "core:math"
import "core:math/linalg"

import "../geom"
import "../ui"
import "../voxel"

// 3D printing (Scene > 3D print): the selected object's size in millimetres, centimetres
// or inches, set by dragging any of its three sides, and Export for printing..., an STL
// file at that size. It takes the best of a sculpting app's print hub, where the size is
// typed and the others follow, and of a modelling app's scene units, where every part of
// a print shares one scale: the size sets the scene's millimetres per unit
// (Scene.print_mm, saved with the scene), so the parts of a figure printed one by one
// still fit together. The file is what a slicer expects, as a 3D printing exporter
// prepares it: millimetres, Z up, standing on the bed (its lowest point at Z 0) and
// centred over the origin, with the object's own placement in the scene applied.

Print_Unit :: enum u8 {
	Millimetres,
	Centimetres,
	Inches,
}

PRINT_UNIT_MM := [Print_Unit]f32 {
	.Millimetres = 1,
	.Centimetres = 10,
	.Inches      = 25.4,
}
PRINT_UNIT_NAMES := [Print_Unit]string {
	.Millimetres = "mm",
	.Centimetres = "cm",
	.Inches      = "in",
}

// A new scene's millimetres per unit: the starting sphere, two units across, prints
// 50 mm wide, a size most printers make in an hour or two.
PRINT_MM_DEFAULT :: 25
// The scale's range: a print from a hundredth of a millimetre per unit to ten metres.
PRINT_MM_MIN :: 0.01
PRINT_MM_MAX :: 10_000
// A mesh with more indices than this is not checked for holes after it is written: the
// check sorts eight bytes per index from the temp memory.
PRINT_CHECK_MAX :: 12_000_000

// The object's box in the scene, its placement applied, in scene units: the shown
// level's (a voxel object's bricks'). Close rather than exact on a turned object.
print_bounds :: proc(obj: ^Object) -> geom.Aabb {
	if vp := obj.voxel; vp != nil {
		local := voxel.clay_bounds(&vp.clay)
		world := geom.AABB_EMPTY
		if local.lo.x > local.hi.x do return world
		for corner in 0 ..< 8 {
			p := Vec3{local.hi.x if corner & 1 != 0 else local.lo.x, local.hi.y if corner & 2 != 0 else local.lo.y, local.hi.z if corner & 4 != 0 else local.lo.z}
			geom.aabb_grow(&world, to_world(obj.transform, p))
		}
		return world
	}
	return object_world_bounds(obj)
}

// The scene's millimetres per unit; a new scene's until something sets it.
print_scale :: proc(app: ^App) -> f32 {
	return app.scene.print_mm if app.scene.print_mm > 0 else PRINT_MM_DEFAULT
}

// The object's printed size along X, Y and Z, in millimetres.
print_size_mm :: proc(app: ^App, obj: ^Object) -> Vec3 {
	b := print_bounds(obj)
	if b.lo.x > b.hi.x do return {}
	return (b.hi - b.lo) * print_scale(app)
}

// Sets the scene's scale so that the object's side along `axis` prints `mm` long; false
// when that side has no length or the scale would leave its range.
print_set_side :: proc(app: ^App, obj: ^Object, axis: int, mm: f32) -> bool {
	b := print_bounds(obj)
	side := b.hi[axis] - b.lo[axis]
	if b.lo.x > b.hi.x || !(side > 1e-12) || !(mm > 0) do return false
	scale := clamp(mm / side, PRINT_MM_MIN, PRINT_MM_MAX)
	if scale == print_scale(app) do return false
	app.scene.print_mm = scale
	app.scene_edits += 1
	return true
}

// The positions as a print file holds them: through the object's placement, in
// millimetres, Y up turned to Z up (the scene's -Z, toward the viewer at the front, becomes
// the printer's +Y, away from it, as Blender's STL exporter turns them), then moved to
// stand on Z 0 and to centre over the origin. Temp memory.
print_positions :: proc(positions: []Vec3, t: Transform, mm: f32) -> []Vec3 {
	out := make([]Vec3, len(positions), context.temp_allocator)
	lo, hi := Vec3{max(f32), max(f32), max(f32)}, Vec3{min(f32), min(f32), min(f32)}
	// The scale in millimetres goes into the placement's matrix, made once.
	m := transform_matrix({position = t.position * mm, scale = t.scale * mm, rotation = t.rotation})
	for p, i in positions {
		w := (m * [4]f32{p.x, p.y, p.z, 1}).xyz
		q := Vec3{w.x, -w.z, w.y}
		out[i] = q
		lo, hi = linalg.min(lo, q), linalg.max(hi, q)
	}
	if len(out) == 0 do return out
	shift := Vec3{-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z}
	for &q in out do q += shift
	return out
}

// What the printed file holds, for the note after it is written: its size, and whether
// it is closed, which a slicer needs to know what is inside, with its volume then.
print_note :: proc(positions: []Vec3, indices: []u32) -> string {
	b := geom.AABB_EMPTY
	for p in positions do geom.aabb_grow(&b, p)
	size := b.hi - b.lo if len(positions) > 0 else Vec3{}
	text := fmt.tprintf("%.1f x %.1f x %.1f mm", size.x, size.y, size.z)
	if len(indices) > PRINT_CHECK_MAX do return text
	r := geom.mesh_check_indices(positions, indices)
	switch {
	case r.closed && !r.inverted:
		return fmt.tprintf("%s, closed, %.1f cm³", text, r.volume / 1000)
	case r.boundary_edges > 0:
		return fmt.tprintf("%s, %d open edges: a slicer may not know what is inside", text, r.boundary_edges)
	case:
		return fmt.tprintf("%s, not closed cleanly: a slicer may not know what is inside", text)
	}
}

// The Scene palette's 3D print section, beside the other ways out of the app (Render,
// Turntable): the unit, the selected object's three sides to drag, and the export. The
// scale it sets is the scene's, which is why it lives in the Scene palette.
kit_print :: proc(app: ^App) {
	ctx := &app.kit.ctx
	obj := selected_object(app)
	if obj == nil {
		ui.paragraph(ctx, "Select an object to see the size it prints at.")
		return
	}
	names: [len(Print_Unit)]string
	for u in Print_Unit do names[u] = PRINT_UNIT_NAMES[u]
	if picked := ui.tabs(ctx, "print unit", names[:], int(app.print_unit)); picked >= 0 do app.print_unit = Print_Unit(picked)
	unit := PRINT_UNIT_MM[app.print_unit]
	size := print_size_mm(app, obj)
	sides := [3]string{"Width (X)", "Height (Y)", "Depth (Z)"}
	for name, axis in sides {
		v := size[axis] / unit
		// A point's drag changes the side by a five-hundredth of itself, so a print of any
		// size takes about the same drag to double.
		step := max(v / 500, 0.001)
		if ui.drag_value(ctx, name, &v, step, 0, PRINT_MM_MAX * 1000, fmt.tprintf("%s %s", print_number(v), PRINT_UNIT_NAMES[app.print_unit]), enabled = size[axis] > 0) {
			_ = print_set_side(app, obj, axis, v * unit)
		}
	}
	_ = command_button(app, .Export_Print, variant = .Solid, tone = .Accent, width = ui.fill_width(ctx), glyph = ui.ICON_EXPORT)
	ui.paragraph(ctx, fmt.tprintf("Drag a side of %s and the others follow. Every object prints at one scale, 1 scene unit to %s mm, so the parts of a print fit together. The STL file is in millimetres with Z up, standing on the bed.", object_label(obj), print_number(print_scale(app))))
}

// A length with as many decimals as its size needs: 0.125, 12.5, 125.
print_number :: proc(v: f32) -> string {
	a := math.abs(v)
	switch {
	case a >= 100: return fmt.tprintf("%.0f", v)
	case a >= 10:  return fmt.tprintf("%.1f", v)
	case a >= 1:   return fmt.tprintf("%.2f", v)
	}
	return fmt.tprintf("%.3f", v)
}
