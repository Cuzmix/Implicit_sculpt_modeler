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
