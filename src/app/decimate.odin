package main

import "core:slice"

import "../geom"
import "../jobs"
import "../sculpt"
import "../ui"

// Decimate (Rebuild's Fewer goal), after ZBrush's Decimation Master and Blender's Decimate
// modifier: how much to keep as a share of the object (Blender's Ratio, ZBrush's percent
// of decimation) or as a vertex count (ZBrush's k-points), and what to keep besides the
// shape. Polypaint and polygroups follow the vertices and triangles that stay, since a
// collapse only ever keeps one of the mesh's own vertices; the lines between polygroups
// stay where they are, as ZBrush's Keep Groups holds them; open edges slide along
// themselves unless Keep borders holds them (its Keep Borders); masked areas and the
// edges in the paint keep more of their triangles (its Use Mask and Use Polypaint).
// UVs belong to quad faces in this app, which a decimation turns into triangles, so they
// go, as they do in Blender; New UVs lays out fresh ones.

Decimate_By :: enum u8 {
	Percent, // a share of the object's vertices
	Count,   // a vertex count
}

DECIMATE_BY_NAMES := [Decimate_By]string {
	.Percent = "Percent",
	.Count   = "Count",
}

// The share the Keep slider offers: from a fiftieth, for a game copy of a sculpt, to nine
// tenths, a light tidy.
DECIMATE_PERCENT_MIN :: 1
DECIMATE_PERCENT_MAX :: 90
DECIMATE_PERCENT_DEFAULT :: 20
// The shares Adjust last offers a decimation that kept a share: halving steps from half,
// the ones taken most.
@(rodata)
DECIMATE_ADJUST_PERCENTS := [5]int{50, 25, 10, 5, 2}

// How many times dearer a fully masked vertex is to move than an unmasked one, and one on
// the sharpest edge in the paint: enough that such detail goes only after most of the
// rest, as Decimation Master's Use Mask and Use Polypaint keep it.
DECIMATE_MASK_WEIGHT :: 16
DECIMATE_PAINT_WEIGHT :: 8

// What a decimation keeps besides the shape, and how much: carried in its scene command
// so the job's thread reads nothing of the panel.
Decimate_Setup :: struct {
	percent:      f32,  // the share of the object's vertices to keep, or 0 to keep the command's count
	keep_paint:   bool, // polypaint follows the vertices, and its edges keep more triangles
	keep_groups:  bool, // polygroups follow the triangles, and the lines between them stay
	keep_borders: bool, // open edges stay exactly as they are rather than thin out along themselves
	use_mask:     bool, // masked areas keep more triangles
}

// The panel's options as a command takes them.
decimate_setup :: proc(app: ^App) -> Decimate_Setup {
	u := &app.ui
	return {u.decimate_percent if u.decimate_by == .Percent else 0, u.decimate_keep_paint, u.decimate_keep_groups, u.decimate_keep_borders, u.decimate_use_mask}
}

// The panel set to a command's options (Adjust last).
decimate_setup_set :: proc(app: ^App, s: Decimate_Setup) {
	u := &app.ui
	if s.percent > 0 do u.decimate_by, u.decimate_percent = .Percent, s.percent
	else do u.decimate_by = .Count
	u.decimate_keep_paint, u.decimate_keep_groups, u.decimate_keep_borders, u.decimate_use_mask = s.keep_paint, s.keep_groups, s.keep_borders, s.use_mask
}

// The vertices a decimation of an object of `now` vertices aims for: the share `setup`
// keeps, or `vertices` when it keeps a count.
decimate_target :: proc(now, vertices: int, setup: Decimate_Setup) -> int {
	if setup.percent <= 0 do return vertices
	return max(int(f64(now) * f64(setup.percent) / 100 + 0.5), 4)
}

// What a decimation reads of an object, its own copies: the level's triangles (compacted
// from a dynamic layout), and the polypaint, polygroups and mask `setup` asks for. A
// dynamic layout has no groups, and its paint is not carried, as a remesh carries none.
Decimate_Source :: struct {
	mesh:   geom.Mesh,
	color:  []sculpt.Color,
	groups: []u16,
	mask:   []u8,
	borrowed: bool, // `mesh` is the level's own, not a copy
}

// With `borrow` (on the frame thread, which changes nothing before it is done) a fixed
// layout's triangles are read in place rather than copied: at 10M vertices a copy is
// 360 MB. A long job's thread needs its own.
decimate_source :: proc(obj: ^Object, setup: Decimate_Setup, borrow := false) -> (src: Decimate_Source) {
	s := object_sculptor(obj)
	if object_dynamic(obj) {
		mask: []u8
		src.mesh, mask = sculpt.sculptor_compact_mesh(s)
		if setup.use_mask do src.mask = mask
		else do delete(mask)
		return
	}
	m := object_mesh(obj)
	if borrow {
		src.mesh, src.borrowed = {positions = m.positions, indices = m.indices}, true
	} else {
		src.mesh.positions = make([dynamic]geom.Vec3, len(m.positions))
		src.mesh.indices = make([dynamic]u32, len(m.indices))
		copy(src.mesh.positions[:], m.positions[:])
		copy(src.mesh.indices[:], m.indices[:])
	}
	if setup.keep_paint && s.color != nil do src.color = slice.clone(s.color)
	if setup.keep_groups && sculpt.sculptor_has_groups(s) do src.groups = slice.clone(sculpt.sculptor_groups(s))
	if setup.use_mask && s.mask != nil do src.mask = slice.clone(s.mask)
	return
}

decimate_source_free :: proc(src: ^Decimate_Source) {
	if !src.borrowed do geom.mesh_destroy(&src.mesh)
	delete(src.color)
	delete(src.groups)
	delete(src.mask)
	src^ = {}
}

// How dear each vertex of `src` is to move: dearer where it is masked and where the paint
// changes sharply across its edges; nil when nothing makes any dearer.
@(private = "file")
decimate_weights :: proc(src: Decimate_Source, allocator := context.allocator) -> []f32 {
	if src.mask == nil && src.color == nil do return nil
	weight := make([]f32, len(src.mesh.positions), allocator)
	slice.fill(weight, 1)
	if src.mask != nil {
		for m, v in src.mask do weight[v] += DECIMATE_MASK_WEIGHT * f32(m) / 255
	}
	if c := src.color; c != nil {
		// The largest change of any channel along a vertex's edges, from 0 to 1.
		contrast := make([]u8, len(c), context.temp_allocator)
		ix := src.mesh.indices[:]
		for i := 0; i + 2 < len(ix); i += 3 {
			for k in 0 ..< 3 {
				a, b := ix[i + k], ix[i + (k + 1) % 3]
				d: u8
				for ch in 0 ..< 4 do d = max(d, max(c[a][ch], c[b][ch]) - min(c[a][ch], c[b][ch]))
				contrast[a] = max(contrast[a], d)
				contrast[b] = max(contrast[b], d)
			}
		}
		for d, v in contrast do weight[v] *= 1 + DECIMATE_PAINT_WEIGHT * f32(d) / 255
	}
	return weight
}

// Decimates `src` to about `vertices` vertices under `setup`, on the frame thread or a
// long job's: the new mesh with zero normals, the largest stray (geom.mesh_decimate), and
// the polypaint and polygroups that followed it (the caller frees them). Not built when
// the object has no more vertices than asked, or after a cancel.
decimate_compute :: proc(src: Decimate_Source, vertices: int, setup: Decimate_Setup, pool: ^jobs.Pool, progress: ^jobs.Progress = nil, share := [2]f32{0, 1}) -> (mesh: geom.Mesh, error: f32, surface: Surface, built: bool) {
	weight := decimate_weights(src)
	defer delete(weight)
	guide := geom.Simplify_Guide{weight = weight, labels = src.groups, slide_borders = !setup.keep_borders}
	from: [dynamic]u32
	defer delete(from)
	labels: [dynamic]u16
	defer delete(labels)
	// A closed surface has about two triangles a vertex.
	mesh, error, built = geom.mesh_decimate(src.mesh, 2 * vertices, pool, progress = progress, share = share, from = &from, guide = guide, out_labels = &labels)
	if !built do return
	if src.color != nil {
		surface.color = make([]sculpt.Color, len(from))
		for v, k in from do surface.color[k] = src.color[v]
	}
	if src.groups != nil do surface.groups = slice.clone(labels[:])
	return
}

// Rebuild's Fewer goal under More options: whether it keeps a share or a count, and what it
// keeps besides the shape. Keep groups and Use mask grey out on an object with nothing for
// them to keep.
kit_decimate_options :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	u := &app.ui
	names: [len(Decimate_By)]string
	for b in Decimate_By do names[int(b)] = DECIMATE_BY_NAMES[b]
	if picked := ui.tabs(ctx, "decimate by", names[:], int(u.decimate_by)); picked >= 0 do u.decimate_by = Decimate_By(picked)
	s := object_sculptor(obj)
	dynamic_layout := object_dynamic(obj)
	_ = ui.switch_row(ctx, "Keep paint", &u.decimate_keep_paint, enabled = s.color != nil && !dynamic_layout)
	_ = ui.switch_row(ctx, "Keep groups", &u.decimate_keep_groups, enabled = sculpt.sculptor_has_groups(s) && !dynamic_layout)
	_ = ui.switch_row(ctx, "Keep borders", &u.decimate_keep_borders)
	_ = ui.switch_row(ctx, "Use mask", &u.decimate_use_mask, enabled = s.mask != nil)
}
