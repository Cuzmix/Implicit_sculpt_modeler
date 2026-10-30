package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../geom"
import "../sculpt"
import "../ui"
import "../voxel"
import "../zip"

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

// Sets the scene's scale so that box `b` (scene units) prints `mm` tall; false when it has
// no height or the scale would leave its range.
print_set_height :: proc(app: ^App, b: geom.Aabb, mm: f32) -> bool {
	side := b.hi.y - b.lo.y
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
	out := print_world(positions, t, mm)
	parts := [1][]Vec3{out}
	print_stand(parts[:])
	return out
}

// The positions through the object's placement in millimetres and turned Z up, where
// they stand in the scene. Temp memory.
print_world :: proc(positions: []Vec3, t: Transform, mm: f32) -> []Vec3 {
	out := make([]Vec3, len(positions), context.temp_allocator)
	// The scale in millimetres goes into the placement's matrix, made once.
	m := transform_matrix({position = t.position * mm, scale = t.scale * mm, rotation = t.rotation})
	for p, i in positions {
		w := (m * [4]f32{p.x, p.y, p.z, 1}).xyz
		out[i] = {w.x, -w.z, w.y}
	}
	return out
}

// Moves the parts of a print together to stand on Z 0 and centre over the origin, as
// they stand to each other in the scene.
print_stand :: proc(parts: [][]Vec3) {
	lo, hi := Vec3{max(f32), max(f32), max(f32)}, Vec3{min(f32), min(f32), min(f32)}
	for part in parts do for q in part do lo, hi = linalg.min(lo, q), linalg.max(hi, q)
	if lo.x > hi.x do return
	shift := Vec3{-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z}
	for part in parts do for &q in part do q += shift
}

// The print file formats the Export sheet offers, and their suffixes.
Print_File :: enum u8 {
	STL,
	OBJ,
	Model_3MF,
}
PRINT_FILE_SUFFIX := [Print_File]string {
	.STL       = ".stl",
	.OBJ       = ".obj",
	.Model_3MF = ".3mf",
}

// The objects a print takes: the selected ones, or with the Export sheet's Only the
// selected objects off every one shown, in the scene's order. Temp memory.
print_objects :: proc(app: ^App) -> []^Object {
	return print_objects_of(app, app.kit.export.print_all)
}

// The objects shown and selected, or with `all` every one shown. Temp memory.
print_objects_of :: proc(app: ^App, all: bool) -> []^Object {
	out := make([dynamic]^Object, 0, 4, context.temp_allocator)
	if all {
		for obj in app.scene.objects do if object_shown(app, obj) do append(&out, obj)
		return out[:]
	}
	for obj in app.scene.objects {
		if !object_shown(app, obj) do continue
		for id in selection_ids(app) do if id == obj.id {
			append(&out, obj)
			break
		}
	}
	return out[:]
}

// The box round the objects of a print in the scene, in scene units.
print_bounds_of :: proc(objs: []^Object) -> geom.Aabb {
	b := geom.AABB_EMPTY
	for obj in objs do b = geom.aabb_union(b, print_bounds(obj))
	return b
}

// The print of `objs` along X, Y and Z, in millimetres.
print_size_of :: proc(app: ^App, objs: []^Object) -> Vec3 {
	b := print_bounds_of(objs)
	if b.lo.x > b.hi.x do return {}
	return (b.hi - b.lo) * print_scale(app)
}

// Writes the objects a print takes (print_objects) to `path`: one object STL or OBJ as
// object_export writes it, else print_export_many; `once` holds the Export sheet's For
// this file options.
print_export :: proc(app: ^App, path: string, once := Export_Once{}) -> bool {
	objs := print_objects(app)
	if len(objs) == 0 {
		file_note(app, true, "Select an object to export first")
		return false
	}
	if len(objs) == 1 && !strings.equal_fold(filepath.ext(path), ".3mf") do return object_export(app, objs[0], path, print = true, once = once)
	return print_export_many(app, objs, path, once)
}

// Writes `objs` as one print: an STL or OBJ of all their triangles together, or a 3MF
// with each object its own part, which a slicer keeps apart; every one at the scene's
// one scale, Z up, and the whole standing on the bed as the objects stand together.
// Decimate for this file only shares its triangles among the objects by how many each has.
print_export_many :: proc(app: ^App, objs: []^Object, path: string, once := Export_Once{}) -> bool {
	start := time.tick_now()
	name := filepath.base(path)
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	if ext != ".stl" && ext != ".obj" && ext != ".3mf" {
		file_note(app, true, "Cannot export %s for printing: the name needs to end in .stl, .obj or .3mf", name)
		return false
	}
	stroke_finish(app)
	inspector_drags_end(app)
	mm := print_scale(app)
	parts := make([]geom.Model_Part, len(objs), context.temp_allocator)
	positions := make([][]Vec3, len(objs), context.temp_allocator)
	colors := make([][][3]u8, len(objs), context.temp_allocator)
	// The meshes made here outlive the temp allocator, which is freed before the file is
	// written, so they and the slices holding them come from the context's allocator.
	packed := make([]geom.Mesh, len(objs))
	decimated := make([]geom.Mesh, len(objs))
	defer {
		for &m in packed do geom.mesh_destroy(&m)
		for &m in decimated do geom.mesh_destroy(&m)
		delete(packed)
		delete(decimated)
	}
	total, walls := 0, 0
	for obj in objs do total += object_triangle_count(obj)
	painted := false
	for obj, i in objs {
		lv := sculpt.levels_current(&obj.levels)
		at, indices := lv.mesh.positions[:], lv.mesh.indices[:]
		if vp := obj.voxel; vp != nil {
			packed[i] = voxel.clay_to_mesh(&vp.clay)
			at, indices = packed[i].positions[:], packed[i].indices[:]
		} else if object_dynamic(obj) {
			mask: []u8
			packed[i], mask = sculpt.sculptor_compact_mesh(&lv.sculptor)
			delete(mask)
			at, indices = packed[i].positions[:], packed[i].indices[:]
		} else if c := lv.sculptor.color; c != nil {
			colors[i] = make([][3]u8, len(c), context.temp_allocator)
			for x, v in c do colors[i][v] = paint_over(x, {255, 255, 255})
			painted = true
		}
		if once.decimate > 0 && total > 0 {
			share := max(int(i64(once.decimate) * i64(len(indices) / 3) / i64(total)), 4)
			if len(indices) / 3 > share {
				src := packed[i] if obj.voxel != nil || object_dynamic(obj) else lv.mesh
				from: [dynamic]u32
				defer delete(from)
				ok: bool
				decimated[i], _, ok = geom.mesh_decimate(src, share, &app.pool, from = &from)
				if ok {
					at, indices = decimated[i].positions[:], decimated[i].indices[:]
					if colors[i] != nil {
						kept := make([][3]u8, len(from), context.temp_allocator)
						for v, k in from do kept[k] = colors[i][v]
						colors[i] = kept
					}
				}
			}
		}
		positions[i] = print_world(at, obj.transform, mm)
		if once.hollow > 0 {
			added: int
			hollowed: bool
			positions[i], indices, added, hollowed = print_hollow(app, positions[i], indices, once.hollow)
			if !hollowed {
				free_all(context.temp_allocator)
				print_hollow_refused(app, name, once.hollow)
				return false
			}
			walls += added
			// The wall's vertices take white, unseen inside.
			if colors[i] != nil && added > 0 {
				white := make([][3]u8, len(positions[i]), context.temp_allocator)
				copy(white, colors[i])
				for &w in white[len(colors[i]):] do w = {255, 255, 255}
				colors[i] = white
			}
		}
		parts[i] = {object_label(obj), positions[i], indices}
	}
	print_stand(positions)
	out := make([dynamic]u8)
	defer delete(out)
	triangles := 0
	for p in parts do triangles += len(p.indices) / 3
	if ext == ".3mf" {
		model := make([dynamic]u8)
		defer delete(model)
		geom.mesh_write_3mf_model(&model, parts, &app.pool)
		files := [3]zip.File{{"[Content_Types].xml", transmute([]u8)string(geom.MODEL_3MF_CONTENT_TYPES)}, {"_rels/.rels", transmute([]u8)string(geom.MODEL_3MF_RELS)}, {"3D/3dmodel.model", model[:]}}
		archive, ok := zip.write(files[:])
		if !ok {
			free_all(context.temp_allocator)
			file_note(app, true, "Cannot export %s: a 3MF file holds at most 4 GB", name)
			return false
		}
		append(&out, ..archive)
		delete(archive)
	} else {
		// One mesh of every part, its indices moved past the parts before it.
		joined := make([dynamic]Vec3, 0, 0, context.temp_allocator)
		indices := make([dynamic]u32, 0, 3 * triangles, context.temp_allocator)
		paint := make([dynamic][3]u8, 0, 0, context.temp_allocator)
		for p, i in parts {
			base := u32(len(joined))
			append(&joined, ..p.positions)
			for k in p.indices do append(&indices, base + k)
			if !painted do continue
			if colors[i] != nil {
				append(&paint, ..colors[i])
			} else {
				for _ in p.positions do append(&paint, [3]u8{255, 255, 255})
			}
		}
		all := joined[:]
		if ext == ".obj" {
			geom.mesh_write_obj(&out, all, indices[:], 1, {}, &app.pool, paint[:] if painted else nil)
		} else {
			geom.mesh_write_stl(&out, all, indices[:], pool = &app.pool)
		}
	}
	size := print_size_of(app, objs)
	free_all(context.temp_allocator)
	if !write_file_safely(app, path, out[:], "export") do return false
	app.stats.file_read_ms, app.stats.file_parse_ms = 0, 0
	app.stats.file_write_ms = time.duration_milliseconds(time.tick_since(start))
	app.print_exports += 1
	if once.decimate > 0 do app.export_decimated = triangles
	if once.hollow > 0 do app.export_hollowed = walls
	file_note(app, false, "Exported %s for printing: %d object%s, %.1f x %.1f x %.1f mm; %d triangles in %.0f ms", name, len(objs), "" if len(objs) == 1 else "s", size.x, size.z, size.y, triangles, app.stats.file_write_ms)
	return true
}

// A hollow print of `positions` and `indices` (in millimetres): them with the inside wall
// `wall` thick after them, its triangles facing the hollow (voxel.hollow_inner), in temp
// memory, and how many triangles the wall added (0 where the object is nowhere thicker
// than two walls, which stays solid). The wall is decimated to the object's triangles
// when it has more, since nothing sees it. Not ok for a wall too thin for the voxels an
// object that big would need.
print_hollow :: proc(app: ^App, positions: []Vec3, indices: []u32, wall: f32) -> (p: []Vec3, i: []u32, added: int, ok: bool) {
	src: geom.Mesh
	src.positions = make([dynamic]Vec3, 0, len(positions), context.temp_allocator)
	src.indices = make([dynamic]u32, 0, len(indices), context.temp_allocator)
	append(&src.positions, ..positions)
	append(&src.indices, ..indices)
	inner: geom.Mesh
	inner, ok = voxel.hollow_inner(src, wall, &app.pool, context.temp_allocator)
	if !ok do return positions, indices, 0, false
	if fewer := max(len(indices) / 3, EXPORT_DECIMATE_MIN); len(inner.indices) / 3 > fewer {
		if d, _, decimated := geom.mesh_decimate(inner, fewer, &app.pool, context.temp_allocator); decimated do inner = d
	}
	if len(inner.indices) == 0 do return positions, indices, 0, true
	all := make([]Vec3, len(positions) + len(inner.positions), context.temp_allocator)
	copy(all, positions)
	copy(all[len(positions):], inner.positions[:])
	tris := make([]u32, len(indices) + len(inner.indices), context.temp_allocator)
	copy(tris, indices)
	base := u32(len(positions))
	for k, n in inner.indices do tris[len(indices) + n] = base + k
	return all, tris, len(inner.indices) / 3, true
}

// The note for a print whose wall is too thin to hollow an object of its size.
print_hollow_refused :: proc(app: ^App, name: string, wall: f32) {
	file_note(app, true, "Cannot hollow %s: a %s mm wall is too thin for an object this big; a thicker wall would do", name, print_number(wall))
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
	print_controls(app, true)
}

// The 3D print section's controls; the Export sheet draws them without the export button
// (`button`), having one of its own.
print_controls :: proc(app: ^App, button: bool) {
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
	if button do _ = command_button(app, .Export_Print, variant = .Solid, tone = .Accent, width = ui.fill_width(ctx), glyph = ui.ICON_EXPORT)
	ui.paragraph(ctx, fmt.tprintf("Drag a side of %s and the others follow. Every object prints at one scale, 1 scene unit to %s mm, so the parts of a print fit together. The file is in millimetres with Z up, standing on the bed.", object_label(obj), print_number(print_scale(app))))
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
