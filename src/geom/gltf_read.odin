package geom

import "core:encoding/base64"
import "core:encoding/json"
import "core:math"
import "core:math/linalg"
import "core:strconv"
import "core:strings"

// glTF 2.0 in: a binary .glb, or .gltf JSON whose buffers are inside it (data: URIs) or
// files beside it, which the caller hands over through `resolve` (geom reads no files).
// Every mesh a node of the scene places becomes a part, its node transforms applied, so
// a mesh placed twice comes twice. A part takes its primitives' triangles (lists, strips
// and fans; points and lines are left out), its POSITION, its COLOR_0 as sRGB vertex
// colours, and a group for each material its primitives use. Primitives compressed with
// Draco or meshopt, which this reader does not decode, are left out and counted, and so
// are skins, animations and morph targets (a skinned mesh comes in its bind pose). A part's
// folder is the nearest named node above its own. glTF is Y up and
// metres, as the app's space is, so nothing turns. Given a Mesh_Look, the materials'
// base colour factors and textures fill it, and the parts' triangles and corners get
// their materials and texture coordinates.

// What a glTF read left out, for the note.
Gltf_Skipped :: struct {
	compressed: int, // primitives compressed by KHR_draco_mesh_compression or EXT_meshopt_compression
	not_faces:  int, // primitives of points or lines
	rig:        Rig_Found, // its skins, animations and the morph targets of the meshes placed
}

GLB_MAGIC :: "glTF"

// Reads a glTF file's meshes as parts appended to `parts`. Refuses a file that is not
// glTF 2, whose JSON or binary does not hold together, or that names a buffer `resolve`
// cannot give (Missing_File); a file whose meshes all were left out is Empty.
mesh_read_gltf :: proc(parts: ^[dynamic]Mesh_Part, data: []u8, resolve: Mesh_Resolve = nil, resolve_data: rawptr = nil, look: ^Mesh_Look = nil) -> (skipped: Gltf_Skipped, err: Mesh_File_Error) {
	text: []u8
	bin: []u8
	if len(data) >= 12 && string(data[:4]) == GLB_MAGIC {
		// A 12-byte header, then chunks: the JSON first, then any binary buffer.
		r := byte_reader(data[4:])
		version := byte_get(&r, u32le)
		if version != 2 do return {}, .Not_Recognised
		length := min(int(byte_get(&r, u32le)), len(data))
		at := 12
		for at + 8 <= length {
			size := int((^u32le)(&data[at])^)
			kind := u32((^u32le)(&data[at + 4])^)
			if size > length - at - 8 do return {}, .Truncated
			chunk := data[at + 8:][:size]
			switch kind {
			case 0x4E4F534A: if text == nil do text = chunk
			case 0x004E4942: if bin == nil do bin = chunk
			}
			at += 8 + ((size + 3) &~ 3)
		}
		if text == nil do return {}, .Bad_Structure
	} else {
		text = data
	}
	root_value, jerr := json.parse(text, .JSON, allocator = context.temp_allocator)
	if jerr != .None do return {}, .Not_Recognised
	root, is_object := root_value.(json.Object)
	if !is_object do return {}, .Not_Recognised
	asset, _ := root["asset"].(json.Object)
	version, _ := asset["version"].(json.String)
	if !strings.has_prefix(version, "2") do return {}, .Not_Recognised

	g := Gltf_Reader{root = root, bin = bin}
	// Every buffer, fetched once.
	buffers := gltf_array(root, "buffers")
	g.buffers = make([][]u8, len(buffers), context.temp_allocator)
	for b, i in buffers {
		bo, _ := b.(json.Object)
		uri, has_uri := bo["uri"].(json.String)
		length := gltf_int(bo, "byteLength", -1)
		switch {
		case !has_uri:
			if i != 0 || bin == nil do return {}, .Bad_Structure
			g.buffers[i] = bin
		case strings.has_prefix(uri, "data:"):
			comma := strings.index_byte(uri, ',')
			if comma < 0 || !strings.contains(uri[:comma], ";base64") do return {}, .Bad_Structure
			decoded, derr := base64.decode(uri[comma + 1:], allocator = context.temp_allocator)
			if derr != nil do return {}, .Bad_Structure
			g.buffers[i] = decoded
		case:
			if resolve == nil do return {}, .Missing_File
			bytes, ok := resolve(resolve_data, gltf_uri_decode(uri))
			if !ok do return {}, .Missing_File
			g.buffers[i] = bytes
		}
		if length < 0 || length > len(g.buffers[i]) do return {}, .Truncated
		g.buffers[i] = g.buffers[i][:length]
	}
	if look != nil do gltf_look(&g, look, resolve, resolve_data)

	// The scene's root nodes: the default scene's, or every node no other names as a child.
	nodes := gltf_array(root, "nodes")
	roots := make([dynamic]int, context.temp_allocator)
	scenes := gltf_array(root, "scenes")
	if s := gltf_int(root, "scene", 0); s >= 0 && s < len(scenes) {
		so, _ := scenes[s].(json.Object)
		for n in gltf_array(so, "nodes") do append(&roots, gltf_number_int(n))
	} else {
		child := make([]bool, len(nodes), context.temp_allocator)
		for n in nodes {
			no, _ := n.(json.Object)
			for c in gltf_array(no, "children") do if k := gltf_number_int(c); k >= 0 && k < len(nodes) do child[k] = true
		}
		for is_child, k in child do if !is_child do append(&roots, k)
	}
	// Depth first with an explicit stack; a node reached a second time down one path (a
	// cycle, which glTF forbids) is not followed again.
	// `folder` is the nearest named node above it, which names its parts' folder.
	Visit :: struct {
		node:   int,
		world:  matrix[4, 4]f64,
		depth:  int,
		folder: string,
	}
	stack := make([dynamic]Visit, context.temp_allocator)
	#reverse for r in roots do append(&stack, Visit{r, 1, 0, ""})
	skipped.rig.skins = len(gltf_array(root, "skins"))
	skipped.rig.animations = len(gltf_array(root, "animations"))
	for len(stack) > 0 {
		v := pop(&stack)
		if v.node < 0 || v.node >= len(nodes) || v.depth > len(nodes) do continue
		no, _ := nodes[v.node].(json.Object)
		world := v.world * gltf_local(no)
		if mesh, has := no["mesh"]; has {
			name, _ := no["name"].(json.String)
			// A skinned mesh's node transform is ignored (the joints place it), so it
			// comes in its bind pose, where it was modelled.
			_, skinned := no["skin"]
			before := len(parts)
			err = gltf_mesh(&g, parts, gltf_number_int(mesh), 1 if skinned else world, name, &skipped)
			if err != .None do return
			if len(parts) > before do parts[len(parts) - 1].folder = strings.clone(v.folder)
		}
		children := gltf_array(no, "children")
		folder := v.folder
		if name, _ := no["name"].(json.String); name != "" do folder = name
		#reverse for c in children do append(&stack, Visit{gltf_number_int(c), world, v.depth + 1, folder})
	}
	if len(parts) == 0 do return skipped, .Empty
	return skipped, .None
}

@(private = "file")
Gltf_Reader :: struct {
	root:          json.Object,
	bin:           []u8,
	buffers:       [][]u8,
	look:          ^Mesh_Look,
	material_base: int, // the file's first material's number in the look
	coord:         []int, // each material's TEXCOORD set for its image, or -1 for none
}

// Fills `look` with the file's materials' base colours and the images their base colour
// textures use: an image in a buffer view, in a data: URI or in a file `resolve` gives
// (nil bytes when it cannot be had, so its material shows its factor alone).
@(private = "file")
gltf_look :: proc(g: ^Gltf_Reader, look: ^Mesh_Look, resolve: Mesh_Resolve, resolve_data: rawptr) {
	g.look = look
	image_base := len(look.images)
	for im in gltf_array(g.root, "images") {
		io, _ := im.(json.Object)
		bytes: []u8
		if view, has_view := io["bufferView"]; has_view {
			bytes, _, _ = gltf_view(g, gltf_number_int(view))
		} else if uri, has_uri := io["uri"].(json.String); has_uri {
			if strings.has_prefix(uri, "data:") {
				if comma := strings.index_byte(uri, ','); comma >= 0 && strings.contains(uri[:comma], ";base64") {
					decoded, derr := base64.decode(uri[comma + 1:], allocator = context.temp_allocator)
					if derr == nil do bytes = decoded
				}
			} else if resolve != nil {
				found: bool
				bytes, found = resolve(resolve_data, gltf_uri_decode(uri))
				if !found do bytes = nil
			}
		}
		append(&look.images, Mesh_Image{bytes = bytes})
	}
	textures := gltf_array(g.root, "textures")
	materials := gltf_array(g.root, "materials")
	g.material_base = len(look.materials)
	g.coord = make([]int, len(materials), context.temp_allocator)
	for m, k in materials {
		mo, _ := m.(json.Object)
		pbr, _ := mo["pbrMetallicRoughness"].(json.Object)
		out := Mesh_Material{color = 1, image = -1}
		if factor := gltf_array(pbr, "baseColorFactor"); len(factor) >= 3 {
			for c in 0 ..< 3 do out.color[c] = clamp(f32(gltf_number(factor[c])), 0, 1)
		}
		g.coord[k] = -1
		if texture, has := pbr["baseColorTexture"].(json.Object); has {
			t := gltf_int(texture, "index", -1)
			if t >= 0 && t < len(textures) {
				to, _ := textures[t].(json.Object)
				source := gltf_int(to, "source", -1)
				if source >= 0 && image_base + source < len(look.images) {
					out.image = image_base + source
					g.coord[k] = gltf_int(texture, "texCoord", 0)
				}
			}
		}
		append(&look.materials, out)
	}
}

// glTF's component types.
@(private = "file")
GL_BYTE :: 5120
@(private = "file")
GL_UNSIGNED_BYTE :: 5121
@(private = "file")
GL_SHORT :: 5122
@(private = "file")
GL_UNSIGNED_SHORT :: 5123
@(private = "file")
GL_UNSIGNED_INT :: 5125
@(private = "file")
GL_FLOAT :: 5126

// Appends mesh `index` placed by `world` as a part named `name` (or the mesh's own).
@(private = "file")
gltf_mesh :: proc(g: ^Gltf_Reader, parts: ^[dynamic]Mesh_Part, index: int, world: matrix[4, 4]f64, name: string, skipped: ^Gltf_Skipped) -> Mesh_File_Error {
	meshes := gltf_array(g.root, "meshes")
	if index < 0 || index >= len(meshes) do return .Bad_Structure
	mo, _ := meshes[index].(json.Object)
	part: Mesh_Part
	part_name := name
	if part_name == "" do part_name, _ = mo["name"].(json.String)
	colored, grouped := false, false
	first_group := -2
	mirrored := linalg.determinant(world) < 0
	// Every primitive of a mesh has the same morph targets, which are its shape keys.
	shapes := 0
	defer skipped.rig.shapes += shapes
	for prim in gltf_array(mo, "primitives") {
		po, _ := prim.(json.Object)
		shapes = max(shapes, len(gltf_array(po, "targets")))
		mode := gltf_int(po, "mode", 4)
		if mode < 4 || mode > 6 {
			skipped.not_faces += 1
			continue
		}
		attributes, _ := po["attributes"].(json.Object)
		if gltf_compressed(g, po, attributes) {
			skipped.compressed += 1
			continue
		}
		position, has_position := attributes["POSITION"]
		if !has_position do continue
		points, components, err := gltf_accessor(g, gltf_number_int(position), context.temp_allocator)
		if err != .None {
			mesh_part_destroy(&part)
			return err
		}
		if components != 3 {
			mesh_part_destroy(&part)
			return .Bad_Structure
		}
		count := len(points) / 3
		base := len(part.mesh.positions)
		if base + count >= int(max(u32)) {
			mesh_part_destroy(&part)
			return .Too_Large
		}
		for v in 0 ..< count {
			p := world * [4]f64{f64(points[3 * v]), f64(points[3 * v + 1]), f64(points[3 * v + 2]), 1}
			append(&part.mesh.positions, Vec3{f32(p.x), f32(p.y), f32(p.z)})
		}
		// Colours: linear in the file, sRGB in polypaint; a primitive without them shows
		// its clay when others of the part have them.
		if color, has_color := attributes["COLOR_0"]; has_color {
			values, n, cerr := gltf_accessor(g, gltf_number_int(color), context.temp_allocator)
			if cerr == .None && (n == 3 || n == 4) && len(values) / n == count {
				if !colored do resize(&part.colors, base)
				colored = true
				for v in 0 ..< count {
					c := Vertex_Color{0, 0, 0, 255}
					for k in 0 ..< 3 do c[k] = srgb_byte_of_linear(values[n * v + k])
					append(&part.colors, c)
				}
			}
		}
		if colored && len(part.colors) < len(part.mesh.positions) do resize(&part.colors, len(part.mesh.positions))
		// Corners, then triangles.
		corners: []u32
		if indices, has_indices := po["indices"]; has_indices {
			values, n, ierr := gltf_accessor(g, gltf_number_int(indices), context.temp_allocator, as_index = true)
			if ierr != .None || n != 1 {
				mesh_part_destroy(&part)
				return .Bad_Structure if ierr == .None else ierr
			}
			corners = transmute([]u32)values
		} else {
			corners = make([]u32, count, context.temp_allocator)
			for &c, i in corners do c = u32(i)
		}
		for c in corners do if int(c) >= count {
			mesh_part_destroy(&part)
			return .Bad_Index
		}
		before := len(part.mesh.indices)
		triangles := make([dynamic][3]u32, 0, len(corners) / 3 + 1, context.temp_allocator)
		switch mode {
		case 4:
			for t := 0; t + 2 < len(corners); t += 3 do append(&triangles, [3]u32{corners[t], corners[t + 1], corners[t + 2]})
		case 5:
			// A strip turns every other triangle round to keep one winding.
			for t in 0 ..< max(len(corners) - 2, 0) {
				if t % 2 == 0 do append(&triangles, [3]u32{corners[t], corners[t + 1], corners[t + 2]})
				else do append(&triangles, [3]u32{corners[t + 1], corners[t], corners[t + 2]})
			}
		case 6:
			for t in 1 ..< max(len(corners) - 1, 1) do append(&triangles, [3]u32{corners[0], corners[t], corners[t + 1]})
		}
		for &tri in triangles {
			if mirrored do tri.yz = tri.zy
			for c in tri do append(&part.mesh.indices, u32(base) + c)
		}
		material := gltf_int(po, "material", -1)
		// The triangles' material, and the corners' coordinates: from the TEXCOORD set the
		// material's image names, or else TEXCOORD_0, which Import keeps as the UVs of an
		// object of quads (a primitive without them, beside one with them, gets 0, 0).
		coord := 0
		if g.look != nil {
			look_material := g.material_base + material if material >= 0 && material < len(g.coord) else -1
			for _ in triangles do append(&part.materials, i32(look_material))
			if look_material >= 0 && g.coord[material] >= 0 do coord = g.coord[material]
		}
		uv: []f32
		if a, has := attributes[fmt_texcoord(coord)]; has {
			values, n, uerr := gltf_accessor(g, gltf_number_int(a), context.temp_allocator)
			if uerr == .None && n == 2 && len(values) / 2 == count do uv = values
		}
		if uv != nil && len(part.uvs) < before do resize(&part.uvs, before)
		if uv != nil || len(part.uvs) > 0 {
			for tri in triangles do for c in tri {
				append(&part.uvs, [2]f32{uv[2 * c], uv[2 * c + 1]} if uv != nil else [2]f32{})
			}
		}
		// The primitive's material names its group: 0 for none, k + 1 for material k.
		group := material + 1
		if first_group == -2 do first_group = group
		if group != first_group && !grouped {
			grouped = true
			resize(&part.groups, before / 3)
			for &x in part.groups do x = u16(max(first_group, 0))
		}
		if grouped do for _ in before / 3 ..< len(part.mesh.indices) / 3 do append(&part.groups, u16(min(group, int(max(u16)))))
	}
	if len(part.mesh.indices) == 0 {
		mesh_part_destroy(&part)
		return .None
	}
	resize(&part.mesh.normals, len(part.mesh.positions))
	part.name = strings.clone(part_name)
	append(parts, part)
	return .None
}

// The name of TEXCOORD set `n`.
@(private = "file")
fmt_texcoord :: proc(n: int) -> string {
	buf := make([]u8, 32, context.temp_allocator)
	return strings.concatenate({"TEXCOORD_", strconv.write_int(buf, i64(n), 10)}, context.temp_allocator)
}

// Whether a primitive's data is compressed in a way this reader does not decode: Draco
// on the primitive, or meshopt on a buffer view its attributes or indices read.
@(private = "file")
gltf_compressed :: proc(g: ^Gltf_Reader, po: json.Object, attributes: json.Object) -> bool {
	if ext, ok := po["extensions"].(json.Object); ok {
		if _, draco := ext["KHR_draco_mesh_compression"]; draco do return true
	}
	accessors := gltf_array(g.root, "accessors")
	views := gltf_array(g.root, "bufferViews")
	meshopt :: proc(accessors, views: json.Array, a: int) -> bool {
		if a < 0 || a >= len(accessors) do return false
		ao, _ := accessors[a].(json.Object)
		view := gltf_int(ao, "bufferView", -1)
		if view < 0 || view >= len(views) do return false
		vo, _ := views[view].(json.Object)
		ext, ok := vo["extensions"].(json.Object)
		if !ok do return false
		_, has := ext["EXT_meshopt_compression"]
		return has
	}
	if p, ok := attributes["POSITION"]; ok && meshopt(accessors, views, gltf_number_int(p)) do return true
	if i, ok := po["indices"]; ok && meshopt(accessors, views, gltf_number_int(i)) do return true
	return false
}

// An accessor's values as f32 components (`count` times its components), normalized
// integers scaled to 0 to 1 or -1 to 1 and other integers as they are; with `as_index`
// the values are u32 bits instead, for corners. Sparse entries are put over the base.
@(private = "file")
gltf_accessor :: proc(g: ^Gltf_Reader, index: int, allocator := context.allocator, as_index := false) -> (out: []f32, components: int, err: Mesh_File_Error) {
	accessors := gltf_array(g.root, "accessors")
	if index < 0 || index >= len(accessors) do return nil, 0, .Bad_Structure
	ao, _ := accessors[index].(json.Object)
	type_name, _ := ao["type"].(json.String)
	switch type_name {
	case "SCALAR": components = 1
	case "VEC2": components = 2
	case "VEC3": components = 3
	case "VEC4": components = 4
	case: return nil, 0, .Bad_Structure
	}
	kind := gltf_int(ao, "componentType", 0)
	normalized := gltf_bool(ao, "normalized")
	count := gltf_int(ao, "count", -1)
	size := gltf_component_size(kind)
	if size == 0 || count < 0 || count > (1 << 31) / components do return nil, 0, .Bad_Structure
	out = make([]f32, count * components, allocator)
	if view := gltf_int(ao, "bufferView", -1); view >= 0 {
		bytes, stride, verr := gltf_view(g, view)
		if verr != .None do return nil, 0, verr
		if stride == 0 do stride = size * components
		offset := gltf_int(ao, "byteOffset", 0)
		if count > 0 && (offset < 0 || offset + (count - 1) * stride + size * components > len(bytes)) do return nil, 0, .Truncated
		for v in 0 ..< count {
			for k in 0 ..< components {
				out[v * components + k] = gltf_value(bytes, offset + v * stride + k * size, kind, normalized, as_index)
			}
		}
	}
	if sparse, has_sparse := ao["sparse"].(json.Object); has_sparse {
		n := gltf_int(sparse, "count", 0)
		io, _ := sparse["indices"].(json.Object)
		vo, _ := sparse["values"].(json.Object)
		ibytes, _, ierr := gltf_view(g, gltf_int(io, "bufferView", -1))
		vbytes, _, verr := gltf_view(g, gltf_int(vo, "bufferView", -1))
		if ierr != .None do return nil, 0, ierr
		if verr != .None do return nil, 0, verr
		ikind := gltf_int(io, "componentType", 0)
		isize := gltf_component_size(ikind)
		ioff, voff := gltf_int(io, "byteOffset", 0), gltf_int(vo, "byteOffset", 0)
		if isize == 0 || n < 0 || ioff < 0 || voff < 0 || ioff + n * isize > len(ibytes) || voff + n * size * components > len(vbytes) do return nil, 0, .Truncated
		for e in 0 ..< n {
			at := int(transmute(u32)gltf_value(ibytes, ioff + e * isize, ikind, false, true))
			if at >= count do return nil, 0, .Bad_Index
			for k in 0 ..< components do out[at * components + k] = gltf_value(vbytes, voff + (e * components + k) * size, kind, normalized, as_index)
		}
	}
	return out, components, .None
}

// A buffer view's bytes and stride (0 for packed).
@(private = "file")
gltf_view :: proc(g: ^Gltf_Reader, index: int) -> (bytes: []u8, stride: int, err: Mesh_File_Error) {
	views := gltf_array(g.root, "bufferViews")
	if index < 0 || index >= len(views) do return nil, 0, .Bad_Structure
	vo, _ := views[index].(json.Object)
	buffer := gltf_int(vo, "buffer", -1)
	if buffer < 0 || buffer >= len(g.buffers) do return nil, 0, .Bad_Structure
	offset, length := gltf_int(vo, "byteOffset", 0), gltf_int(vo, "byteLength", -1)
	if offset < 0 || length < 0 || offset + length > len(g.buffers[buffer]) do return nil, 0, .Truncated
	return g.buffers[buffer][offset:][:length], max(gltf_int(vo, "byteStride", 0), 0), .None
}

@(private = "file")
gltf_component_size :: proc(kind: int) -> int {
	switch kind {
	case GL_BYTE, GL_UNSIGNED_BYTE: return 1
	case GL_SHORT, GL_UNSIGNED_SHORT: return 2
	case GL_UNSIGNED_INT, GL_FLOAT: return 4
	}
	return 0
}

// One component at `at` (bounds checked by the caller), little-endian as glTF stores it.
@(private = "file")
gltf_value :: #force_inline proc(bytes: []u8, at: int, kind: int, normalized, as_index: bool) -> f32 {
	if as_index {
		i: u32
		switch kind {
		case GL_UNSIGNED_BYTE: i = u32(bytes[at])
		case GL_UNSIGNED_SHORT: i = u32((^u16le)(&bytes[at])^)
		case GL_UNSIGNED_INT: i = u32((^u32le)(&bytes[at])^)
		case: i = max(u32)
		}
		return transmute(f32)i
	}
	switch kind {
	case GL_FLOAT: return f32((^f32le)(&bytes[at])^)
	case GL_BYTE:
		x := f32(cast(i8)bytes[at])
		return max(x / 127, -1) if normalized else x
	case GL_UNSIGNED_BYTE:
		x := f32(bytes[at])
		return x / 255 if normalized else x
	case GL_SHORT:
		x := f32(i16((^i16le)(&bytes[at])^))
		return max(x / 32767, -1) if normalized else x
	case GL_UNSIGNED_SHORT:
		x := f32(u16((^u16le)(&bytes[at])^))
		return x / 65535 if normalized else x
	case GL_UNSIGNED_INT:
		return f32(u32((^u32le)(&bytes[at])^))
	}
	return 0
}

// A node's own transform: its matrix, or translation, rotation and scale.
@(private = "file")
gltf_local :: proc(no: json.Object) -> (m: matrix[4, 4]f64) {
	m = 1
	if values := gltf_array(no, "matrix"); len(values) == 16 {
		// Column by column, as glTF stores it.
		for k in 0 ..< 16 do m[k % 4, k / 4] = gltf_number(values[k])
		return
	}
	t, r, s := [3]f64{}, quaternion(w = 1, x = 0, y = 0, z = 0), [3]f64{1, 1, 1}
	if v := gltf_array(no, "translation"); len(v) == 3 do t = {gltf_number(v[0]), gltf_number(v[1]), gltf_number(v[2])}
	if v := gltf_array(no, "rotation"); len(v) == 4 do r = quaternion(w = gltf_number(v[3]), x = gltf_number(v[0]), y = gltf_number(v[1]), z = gltf_number(v[2]))
	if v := gltf_array(no, "scale"); len(v) == 3 do s = {gltf_number(v[0]), gltf_number(v[1]), gltf_number(v[2])}
	rot := linalg.matrix3_from_quaternion(linalg.normalize0(r))
	for col in 0 ..< 3 do for row in 0 ..< 3 do m[row, col] = rot[row, col] * s[col]
	m[0, 3], m[1, 3], m[2, 3] = t.x, t.y, t.z
	return
}

// A .gltf's buffer URI as a file name: percent escapes undone.
@(private = "file")
gltf_uri_decode :: proc(uri: string) -> string {
	if strings.index_byte(uri, '%') < 0 do return uri
	out := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(uri); i += 1 {
		if uri[i] == '%' && i + 2 < len(uri) {
			hi, lo := hex_digit(uri[i + 1]), hex_digit(uri[i + 2])
			if hi >= 0 && lo >= 0 {
				strings.write_byte(&out, u8(hi << 4 | lo))
				i += 2
				continue
			}
		}
		strings.write_byte(&out, uri[i])
	}
	return strings.to_string(out)

	hex_digit :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9': return int(c - '0')
		case 'a' ..= 'f': return int(c - 'a' + 10)
		case 'A' ..= 'F': return int(c - 'A' + 10)
		}
		return -1
	}
}

@(private = "file")
gltf_array :: proc(o: json.Object, key: string) -> json.Array {
	a, _ := o[key].(json.Array)
	return a
}

@(private = "file")
gltf_number :: proc(v: json.Value) -> f64 {
	#partial switch x in v {
	case json.Float: return x
	case json.Integer: return f64(x)
	}
	return 0
}

@(private = "file")
gltf_number_int :: proc(v: json.Value) -> int {
	x := gltf_number(v)
	return int(x) if x >= 0 && x < 1 << 31 && x == math.floor(x) else -1
}

@(private = "file")
gltf_int :: proc(o: json.Object, key: string, missing: int) -> int {
	v, has := o[key]
	return gltf_number_int(v) if has else missing
}

@(private = "file")
gltf_bool :: proc(o: json.Object, key: string) -> bool {
	b, _ := o[key].(json.Boolean)
	return b
}

// A linear colour channel, 0 to 1, as an sRGB byte.
srgb_byte_of_linear :: proc(linear: f32) -> u8 {
	x := clamp(linear, 0, 1)
	s := x * 12.92 if x <= 0.0031308 else 1.055 * math.pow(x, 1 / 2.4) - 0.055
	return u8(math.round(s * 255))
}
