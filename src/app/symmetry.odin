package main

import "core:fmt"
import "core:strings"

import "../geom"
import "../sculpt"

// Local and radial symmetry on the app side. The brush's mirror planes and radial axis pass
// through the symmetry's centre: the object's origin, or with Local its own middle, the
// middle of its shown surface's box in its own space, as the reference app's Local
// Symmetry takes the object's centre rather than the world's.

// How many copies Radial makes when first turned on, and the most and fewest it offers.
RADIAL_DEFAULT :: 8
RADIAL_MIN :: 2

// The middle local symmetry turns about, kept until the work or the object changes (the
// history's serial counts every stroke, so it holds still through a stroke).
Symmetry_Center :: struct {
	object: int,
	level:  int,
	serial: u64,
	center: Vec3,
}

// Where the selected brush's symmetry turns about on `obj`, in its own space: the origin,
// or with Local the middle of its shown surface.
symmetry_center :: proc(app: ^App, obj: ^Object) -> Vec3 {
	if !app.brush.sym_local || obj == nil do return {}
	c := &app.sym_center
	if c.object == obj.id && c.level == obj.levels.current && c.serial == app.history.serial do return c.center
	c^ = {obj.id, obj.levels.current, app.history.serial, object_local_middle(obj)}
	return c.center
}

// A brush carrying only the selected brush's symmetry on `obj`: its planes, its radial
// copies and the centre they turn about, as the dabs and Clip take them.
brush_symmetry :: proc(app: ^App, obj: ^Object) -> sculpt.Brush {
	b := app.brush
	return {
		symmetry    = b.symmetry,
		radial      = u8(clamp(b.radial_count, RADIAL_MIN, sculpt.RADIAL_MAX)) if b.radial_on else 0,
		radial_axis = b.radial_axis,
		sym_center  = symmetry_center(app, obj),
	}
}

// The middle of the box round the object's shown surface, in its own space: a mesh
// object's current level (never an HD window, which is part of it) or a voxel object's clay.
object_local_middle :: proc(obj: ^Object) -> Vec3 {
	chunks := obj.voxel.clay.surface.chunks[:] if obj.voxel != nil else sculpt.levels_current(&obj.levels).sculptor.chunks
	box := geom.AABB_EMPTY
	for ch in chunks {
		if ch.bounds.lo.x > ch.bounds.hi.x do continue
		geom.aabb_grow(&box, ch.bounds.lo)
		geom.aabb_grow(&box, ch.bounds.hi)
	}
	if box.lo.x > box.hi.x do return {}
	return (box.lo + box.hi) / 2
}

// The brush's symmetry as the exit stats print it: the planes ("xz", or none), then
// "+local" and "+radial<count><axis>" when on.
symmetry_label :: proc(app: ^App) -> string {
	b := app.brush
	names := "xyz"
	planes := strings.builder_make(context.temp_allocator)
	for axis in b.symmetry do strings.write_byte(&planes, names[int(axis)])
	if b.symmetry == {} do strings.write_string(&planes, "none")
	if b.sym_local do strings.write_string(&planes, "+local")
	if b.radial_on do fmt.sbprintf(&planes, "+radial%d%c", b.radial_count, names[int(b.radial_axis)])
	return strings.to_string(planes)
}

// Whether the selected brush has any symmetry on: a mirror plane or radial copies.
symmetry_on :: proc(app: ^App) -> bool {
	return app.brush.symmetry != {} || app.brush.radial_on
}

// Where the selected brush's mirror planes cut the selected object, in its own space, as
// Nomad draws its plane's thin line across the model (Settings > Interface > Show the
// symmetry line), and with Radial the box the axis is drawn across. Worked out again only
// when the work, the object, its level or the symmetry changes, so a frame costs only the
// drawing; through a stroke the line keeps the shape the stroke began on.
Symmetry_Lines :: struct {
	valid:    bool,
	object:   int,
	sculptor: ^sculpt.Sculptor,
	serial:   u64,
	edits:    u64,
	symmetry: sculpt.Symmetry,
	center:   Vec3,
	box:      geom.Aabb, // the object's shown surface, for the radial axis
	cuts:     [sculpt.Axis]sculpt.Section,
}

symmetry_lines_destroy :: proc(l: ^Symmetry_Lines) {
	for &cut in l.cuts do sculpt.section_destroy(&cut)
	l^ = {}
}

// The selected object's symmetry lines, brought up to date, or nil when the selected
// object has none to show (no symmetry, a voxel object, nothing selected).
symmetry_lines :: proc(app: ^App) -> (^Object, ^Symmetry_Lines) {
	obj := selected_object(app)
	if obj == nil || obj.voxel != nil || !symmetry_on(app) do return nil, nil
	l := &app.sym_lines
	s := object_sculptor(obj)
	sym := brush_symmetry(app, obj)
	if l.valid && l.object == obj.id && l.sculptor == s && l.serial == app.history.serial && l.edits == app.scene_edits && l.symmetry == sym.symmetry && l.center == sym.sym_center {
		return obj, l
	}
	l.valid, l.object, l.sculptor, l.serial, l.edits = true, obj.id, s, app.history.serial, app.scene_edits
	l.symmetry, l.center = sym.symmetry, sym.sym_center
	l.box = geom.AABB_EMPTY
	for ch in s.chunks {
		if ch.bounds.lo.x > ch.bounds.hi.x do continue
		geom.aabb_grow(&l.box, ch.bounds.lo)
		geom.aabb_grow(&l.box, ch.bounds.hi)
	}
	for axis in sculpt.Axis {
		sculpt.section_clear(&l.cuts[axis])
		if axis not_in sym.symmetry do continue
		normal: Vec3
		normal[int(axis)] = 1
		sculpt.sculptor_plane_section(s, sym.sym_center, normal, &l.cuts[axis])
	}
	return obj, l
}
