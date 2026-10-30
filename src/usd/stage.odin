package usd

import "core:math"
import "core:math/linalg"
import "core:strings"

import "../geom"

// What a USD layer says, as far as meshes need it, whichever form it came in (usda.odin
// reads text, usdc.odin the binary crate): its prims as a tree, each with the
// properties it gives values to, and the layer's up axis and units. Composition is not
// followed: references, payloads, sublayers, variants and instancing are counted for
// the note and left out, so a file imports what its own layer defines.

// A property's value, its numbers in the narrowest type that holds them exactly: ints
// for int types, f32 for float, half, point, colour, normal and vector types, f64 for
// double types and matrices; a tuple or array of tuples is flattened. Tokens, strings,
// asset paths and path targets are strings.
Value :: union {
	[]i32,
	[]f32,
	[]f64,
	[]string,
	string,
	bool,
}

Prop :: struct {
	type_name:     string, // as the file names it: "point3f[]", "matrix4d", "token"
	value:         Value, // its default, or else its first time sample; nil for none
	interpolation: string, // a primvar's, "" for the default (constant)
}

Specifier :: enum u8 {
	Def,
	Over,
	Class,
}

Prim :: struct {
	name:      string,
	type_name: string, // "Mesh", "Xform", "GeomSubset", ... or "" for none
	specifier: Specifier,
	parent:    int, // -1 for a root prim
	children:  [dynamic]int,
	props:     map[string]Prop,
	active:    bool,
	composed:  bool, // it has references, payloads, variants or is instanceable: not followed
}

Stage :: struct {
	prims:           [dynamic]Prim,
	up_z:            bool, // upAxis = "Z"
	meters_per_unit: f64, // 0 for the default, centimetres
}

// What reading left out, for the note.
Skipped :: struct {
	composed: int, // prims whose references, payloads, variants or instancing were not followed
	not_mesh: int, // Mesh prims without points or faces
}

// Each Mesh prim the stage defines (every prim up to the root a def, active and visible) as a part appended to `parts`: its faces split into fans (holes left
// out), placed by its own and its parents' xformOps, turned round where it is
// leftHanded or mirrored, in metres and Y up; its displayColor as sRGB vertex colours
// (a face's or corner's colours averaged at each vertex), and its materialBind
// GeomSubsets as polygroups (one each, from 1, in the order they come), or else the
// primvars:polygroup the app's own export writes.
stage_parts :: proc(s: ^Stage, parts: ^[dynamic]geom.Mesh_Part, skipped: ^Skipped) -> geom.Mesh_File_Error {
	world := make([]matrix[4, 4]f64, len(s.prims), context.temp_allocator)
	units := s.meters_per_unit if s.meters_per_unit > 0 else 0.01
	// Z up becomes Y up by a turn about x, (x, y, z) -> (x, z, -y), which mirrors nothing.
	axes: matrix[4, 4]f64 = 1
	if s.up_z do axes = {1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1}
	root := axes * linalg.matrix4_scale_f64(units)
	// Parents come before their children in the list, as both readers make it.
	for &p, i in s.prims {
		parent := root if p.parent < 0 else world[p.parent]
		local, reset := xform_local(&p)
		world[i] = (root if reset else parent) * local
	}
	for &p, i in s.prims {
		if p.type_name != "Mesh" do continue
		if !prim_defined(s, i) do continue
		if p.composed do skipped.composed += 1
		err := mesh_part(s, i, world[i], parts, skipped)
		if err != .None do return err
	}
	for p in s.prims do if p.composed && p.type_name != "Mesh" do skipped.composed += 1
	return .None
}

// Whether prim i is defined, active and shown: every prim from it to the root is a def
// (an over only adds to what another layer defines, and this reader reads one) and none
// is inactive or invisible.
@(private)
prim_defined :: proc(s: ^Stage, i: int) -> bool {
	for k := i; k >= 0; k = s.prims[k].parent {
		p := &s.prims[k]
		visibility, _ := p.props["visibility"].value.(string)
		if !p.active || visibility == "invisible" || p.specifier != .Def do return false
	}
	return true
}

@(private)
mesh_part :: proc(s: ^Stage, i: int, world: matrix[4, 4]f64, parts: ^[dynamic]geom.Mesh_Part, skipped: ^Skipped) -> geom.Mesh_File_Error {
	p := &s.prims[i]
	points := prop_f32(p, "points")
	counts := prop_i32(p, "faceVertexCounts")
	corners := prop_i32(p, "faceVertexIndices")
	if len(points) < 9 || len(counts) == 0 || len(corners) < 3 {
		skipped.not_mesh += 1
		return .None
	}
	vertices := len(points) / 3
	if vertices >= int(max(u32)) do return .Too_Large
	holes := make(map[i32]bool, context.temp_allocator)
	for h in prop_i32(p, "holeIndices") do holes[h] = true
	left := false
	if o, ok := p.props["orientation"].value.(string); ok do left = o == "leftHanded"
	flip := left != (linalg.determinant(world) < 0)

	part: geom.Mesh_Part
	part.name = strings.clone(p.name)
	part.mesh.positions = make([dynamic]geom.Vec3, vertices)
	part.mesh.normals = make([dynamic]geom.Vec3, vertices)
	for v in 0 ..< vertices {
		q := world * [4]f64{f64(points[3 * v]), f64(points[3 * v + 1]), f64(points[3 * v + 2]), 1}
		part.mesh.positions[v] = {f32(q.x), f32(q.y), f32(q.z)}
	}
	// Faces into fans, remembering each triangle's face for groups and colours.
	face_of := make([dynamic]i32, context.temp_allocator)
	polygons := false
	at := 0
	for n, f in counts {
		if n < 0 || at + int(n) > len(corners) {
			geom.mesh_part_destroy(&part)
			return .Bad_Index
		}
		face := corners[at:][:n]
		at += int(n)
		if n < 3 || holes[i32(f)] do continue
		for c in face do if c < 0 || int(c) >= vertices {
			geom.mesh_part_destroy(&part)
			return .Bad_Index
		}
		polygons ||= n > 3
		for k in 1 ..< n - 1 {
			b, c := u32(face[k]), u32(face[k + 1])
			if flip do b, c = c, b
			append(&part.mesh.indices, u32(face[0]), b, c)
			append(&face_of, i32(f))
		}
	}
	// The faces themselves, for the object's polygons (geom.Mesh_Part.polys).
	if polygons {
		part.polys = make([dynamic]u32, len(face_of))
		for f, t in face_of do part.polys[t] = u32(f)
	}
	if len(part.mesh.indices) == 0 {
		geom.mesh_part_destroy(&part)
		skipped.not_mesh += 1
		return .None
	}
	mesh_colors(p, &part, counts, corners, holes)
	// Groups: each materialBind GeomSubset among the children names its faces.
	group_of := make([]u16, len(counts), context.temp_allocator)
	subsets := 0
	for c in p.children {
		sub := &s.prims[c]
		if sub.type_name != "GeomSubset" || !sub.active do continue
		family, _ := sub.props["familyName"].value.(string)
		if family != "materialBind" do continue
		subsets += 1
		for f in prop_i32(sub, "indices") do if f >= 0 && int(f) < len(group_of) do group_of[f] = u16(min(subsets, int(max(u16))))
	}
	// Without subsets, the polygroups the app's own export writes (primvars:polygroup).
	if pg := prop_i32(p, "primvars:polygroup"); subsets == 0 && len(pg) == len(counts) {
		for g, f in pg do group_of[f] = u16(clamp(g, 0, i32(max(u16))))
		subsets = 1
	}
	if subsets > 0 {
		part.groups = make([dynamic]u16, len(face_of))
		for f, t in face_of do part.groups[t] = group_of[f]
	}
	append(parts, part)
	return .None
}

// displayColor (with its :indices) as one colour a vertex, by its interpolation.
@(private)
mesh_colors :: proc(p: ^Prim, part: ^geom.Mesh_Part, counts, corners: []i32, holes: map[i32]bool) {
	prop, has := p.props["primvars:displayColor"]
	if !has do return
	values, _ := prop.value.([]f32)
	if len(values) < 3 do return
	indices := prop_i32(p, "primvars:displayColor:indices")
	color :: proc(values: []f32, indices: []i32, k: int) -> (c: [3]f32, ok: bool) {
		i := k
		if indices != nil {
			if k >= len(indices) do return
			i = int(indices[k])
		}
		if i < 0 || 3 * i + 2 >= len(values) do return
		return {values[3 * i], values[3 * i + 1], values[3 * i + 2]}, true
	}
	vertices := len(part.mesh.positions)
	sum := make([][4]f32, vertices, context.temp_allocator)
	switch prop.interpolation {
	case "vertex", "varying":
		for v in 0 ..< vertices do if c, ok := color(values, indices, v); ok do sum[v] = {c.r, c.g, c.b, 1}
	case "uniform":
		at := 0
		for n, f in counts {
			if c, ok := color(values, indices, f); ok && !holes[i32(f)] do for v in corners[at:][:max(n, 0)] do sum[v] += {c.r, c.g, c.b, 1}
			at += int(max(n, 0))
		}
	case "faceVarying":
		at := 0
		for n, f in counts {
			for k in 0 ..< int(max(n, 0)) {
				if c, ok := color(values, indices, at + k); ok && !holes[i32(f)] do sum[corners[at + k]] += {c.r, c.g, c.b, 1}
			}
			at += int(max(n, 0))
		}
	case:
		// Constant: one colour for all.
		c, ok := color(values, indices, 0)
		if !ok do return
		for &x in sum do x = {c.r, c.g, c.b, 1}
	}
	part.colors = make([dynamic]geom.Vertex_Color, vertices)
	for x, v in sum {
		if x.a == 0 do continue
		part.colors[v] = {geom.srgb_byte_of_linear(x.r / x.a), geom.srgb_byte_of_linear(x.g / x.a), geom.srgb_byte_of_linear(x.b / x.a), 255}
	}
}

// The prim's own transform from its xformOpOrder, as a matrix for column vectors, and
// whether it starts afresh from the world (!resetXformStack!).
@(private)
xform_local :: proc(p: ^Prim) -> (m: matrix[4, 4]f64, reset: bool) {
	m = 1
	order, _ := p.props["xformOpOrder"].value.([]string)
	// USD applies the last op first: a point goes through them from the end of the list,
	// so the list read from the start multiplies on the right.
	for name in order {
		if name == "!resetXformStack!" {
			m, reset = 1, true
			continue
		}
		invert := strings.has_prefix(name, "!invert!")
		op := name[len("!invert!"):] if invert else name
		x := xform_op(p, op)
		if invert do x = linalg.inverse(x)
		m = m * x
	}
	return
}

// One xformOp as a matrix for column vectors; an op without a value is no change.
@(private)
xform_op :: proc(p: ^Prim, name: string) -> matrix[4, 4]f64 {
	prop, has := p.props[name]
	if !has do return 1
	v := prop_f64(prop.value)
	kind := strings.trim_prefix(name, "xformOp:")
	if colon := strings.index_byte(kind, ':'); colon >= 0 do kind = kind[:colon]
	rad :: proc(d: f64) -> f64 {return d * math.PI / 180}
	switch kind {
	case "translate":
		if len(v) == 3 do return linalg.matrix4_translate_f64({v[0], v[1], v[2]})
	case "scale":
		if len(v) == 3 do return linalg.matrix4_scale_f64({v[0], v[1], v[2]})
		if len(v) == 1 do return linalg.matrix4_scale_f64(v[0])
	case "rotateX", "rotateY", "rotateZ":
		if len(v) != 1 do return 1
		axis := [3]f64{1, 0, 0} if kind == "rotateX" else ([3]f64{0, 1, 0} if kind == "rotateY" else [3]f64{0, 0, 1})
		return linalg.matrix4_rotate_f64(rad(v[0]), axis)
	case "rotateXYZ", "rotateXZY", "rotateYXZ", "rotateYZX", "rotateZXY", "rotateZYX":
		if len(v) != 3 do return 1
		// The first axis named turns first; v holds the angles in x, y, z order.
		m: matrix[4, 4]f64 = 1
		for c in kind[len("rotate"):] {
			k := int(c - 'X')
			axis: [3]f64
			axis[k] = 1
			m = linalg.matrix4_rotate_f64(rad(v[k]), axis) * m
		}
		return m
	case "orient":
		// Stored real first, as GfQuat prints: (w, x, y, z).
		if len(v) == 4 do return linalg.matrix4_from_quaternion_f64(linalg.normalize0(quaternion(w = v[0], x = v[1], y = v[2], z = v[3])))
	case "transform":
		// A row-vector matrix, row by row: its transpose is ours.
		if len(v) == 16 {
			m: matrix[4, 4]f64
			for r in 0 ..< 4 do for c in 0 ..< 4 do m[c, r] = v[4 * r + c]
			return m
		}
	}
	return 1
}

@(private)
prop_f64 :: proc(v: Value) -> []f64 {
	switch x in v {
	case []f64: return x
	case []f32:
		out := make([]f64, len(x), context.temp_allocator)
		for y, i in x do out[i] = f64(y)
		return out
	case []i32:
		out := make([]f64, len(x), context.temp_allocator)
		for y, i in x do out[i] = f64(y)
		return out
	case []string, string, bool:
	}
	return nil
}

@(private)
prop_f32 :: proc(p: ^Prim, name: string) -> []f32 {
	#partial switch x in p.props[name].value {
	case []f32: return x
	case []f64:
		out := make([]f32, len(x), context.temp_allocator)
		for y, i in x do out[i] = f32(y)
		return out
	}
	return nil
}

@(private)
prop_i32 :: proc(p: ^Prim, name: string) -> []i32 {
	x, _ := p.props[name].value.([]i32)
	return x
}
