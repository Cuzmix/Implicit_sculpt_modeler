package main

import "core:fmt"
import "core:strings"
import "core:time"

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
	// A Mirror row's planes pass through the object's origin, and the brush's with them.
	if !app.brush.sym_local || obj == nil || stack_symmetry(obj) != {} do return {}
	c := &app.sym_center
	if c.object == obj.id && c.level == obj.levels.current && c.serial == app.history.serial do return c.center
	c^ = {obj.id, obj.levels.current, app.history.serial, object_local_middle(obj)}
	return c.center
}

// The planes Keep symmetry keeps a rebuild of `obj` symmetric across (Remesh, Decimate,
// Quad remesh): the brush's symmetry planes, through the centre its dabs mirror about,
// so a sculpt made with symmetry comes out as symmetric as it went in, ready for more
// symmetric strokes. Radial symmetry asks nothing of them. None without an object.
symmetry_planes :: proc(app: ^App, obj: ^Object) -> (mirror: geom.Remesh_Mirror) {
	if obj == nil do return
	planes := app.brush.symmetry + stack_symmetry(obj)
	for a in sculpt.Axis do mirror.axes[int(a)] = a in planes
	if mirror.axes != {} do mirror.center = symmetry_center(app, obj)
	return
}

// "X", "X and Z", "X, Y and Z": the planes a result line names.
planes_label :: proc(mirror: geom.Remesh_Mirror) -> string {
	axis_names := [3]string{"X", "Y", "Z"}
	names: [3]string
	n := 0
	for a in 0 ..< 3 do if mirror.axes[a] {
		names[n] = axis_names[a]
		n += 1
	}
	switch n {
	case 0: return ""
	case 1: return names[0]
	case 2: return fmt.tprintf("%s and %s", names[0], names[1])
	}
	return fmt.tprintf("%s, %s and %s", names[0], names[1], names[2])
}

// A brush carrying only the selected brush's symmetry on `obj`: its planes, its radial
// copies and the centre they turn about, as the dabs and Clip take them.
brush_symmetry :: proc(app: ^App, obj: ^Object) -> sculpt.Brush {
	b := app.brush
	return {
		// A Mirror row holds its planes on while it shows, so the half it hides follows.
		symmetry    = b.symmetry + stack_symmetry(obj),
		radial      = u8(clamp(b.radial_count, RADIAL_MIN, sculpt.RADIAL_MAX)) if b.radial_on else 0,
		radial_axis = b.radial_axis,
		sym_center  = symmetry_center(app, obj),
		poseable    = b.poseable && b.symmetry + stack_symmetry(obj) != {},
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
	if b.poseable do strings.write_string(&planes, "+poseable")
	if b.radial_on do fmt.sbprintf(&planes, "+radial%d%c", b.radial_count, names[int(b.radial_axis)])
	return strings.to_string(planes)
}

// Whether the selected brush has any symmetry on: a mirror plane or radial copies.
symmetry_on :: proc(app: ^App) -> bool {
	return app.brush.symmetry != {} || app.brush.radial_on || stack_symmetry(selected_object(app)) != {}
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

// Poseable symmetry (sculpt/mirror_topo.odin) on the app side: the selected object's shown
// level is paired by its topology between strokes, once for each sculptor, axis and centre,
// and dabs then mirror by the pairs (Brush.poseable).

// What was last paired, or tried and refused, so a mesh with no pairs is not tried every
// frame.
Poseable_Tried :: struct {
	sculptor: ^sculpt.Sculptor,
	vertices: int,
	axis:     sculpt.Axis,
	center:   Vec3,
}

// The plane poseable symmetry pairs across: the first of the brush's planes (X when only
// asked before any is on).
poseable_axis :: proc(app: ^App, obj: ^Object) -> sculpt.Axis {
	for a in app.brush.symmetry + stack_symmetry(obj) do return a
	return .X
}

// Turns poseable symmetry on or off; on, the next frame pairs the selected object.
poseable_toggle :: proc(app: ^App) {
	app.brush.poseable = !app.brush.poseable
	app.poseable = {}
}

// Pairs the selected object's shown level when poseable symmetry is on and it has no
// pairs for the plane in use, and says how it went.
poseable_frame :: proc(app: ^App) {
	obj := selected_object(app)
	if !app.brush.poseable || app.brush.symmetry + stack_symmetry(obj) == {} do return
	if obj == nil || obj.voxel != nil || obj.curve != nil || obj.cage != nil || object_in_hd(obj) do return
	s := object_sculptor(obj)
	axis := poseable_axis(app, obj)
	center := symmetry_center(app, obj)
	key := Poseable_Tried{s, len(s.mesh.positions), axis, center}
	// Pairs a sculptor already has stay its pairs: the topology decides them, not the
	// centre, which only chose the seed.
	if (sculpt.sculptor_mirror_ready(s) && s.mirror_axis == axis) || app.poseable == key do return
	app.poseable = key
	if s.dyn != nil {
		report(app, Section.Symmetry, {.Warning}, "Poseable symmetry needs dynamic topology off on %s: strokes mirror across the plane", object_label(obj))
		return
	}
	start := time.tick_now()
	paired, ok := sculpt.sculptor_mirror_find(s, axis, center)
	ms := time.duration_milliseconds(time.tick_since(start))
	n := len(s.mesh.positions)
	if !ok {
		report(app, Section.Symmetry, {.Warning}, "Poseable symmetry found no matching halves on %s: strokes mirror across the plane", object_label(obj))
		return
	}
	if paired < n {
		report(app, Section.Symmetry, {.Warning}, "Poseable symmetry paired %s of %s vertices of %s across %v (%.0f ms); the rest mirror across the plane", count_label(paired), count_label(n), object_label(obj), axis, ms)
		return
	}
	report(app, Section.Symmetry, {}, "Poseable symmetry paired all %s vertices of %s across %v (%.0f ms)", count_label(n), object_label(obj), axis, ms)
}
