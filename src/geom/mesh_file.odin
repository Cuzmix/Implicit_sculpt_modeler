package geom

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../jobs"

// Meshes in and out of files: OBJ (text; positions, vertex colours and polygons,
// everything else ignored), PLY (text or binary, either byte order) and STL (text or binary), read in
// parallel where the format allows. mesh_clean makes what was read sculptable and mesh_normalize sizes it
// like the app's spheres. Everything works on bytes in memory: the caller reads and
// writes the file, and tests need none.

Mesh_File_Error :: enum u8 {
	None,
	Not_Recognised, // not the format asked for
	Bad_Header,     // a PLY header this reader cannot follow, or one without x, y and z
	Bad_Number,     // a coordinate, count or index that does not parse
	Bad_Index,      // a face corner of 0 or past the vertices
	Truncated,      // less binary data than the header promises
	Not_Finite,     // a NaN or infinite coordinate
	Too_Large,      // more vertices than 32-bit indices reach
	Empty,          // no triangles
	Not_Clean,      // a triangle with a repeated corner, or a vertex no triangle uses
	Bad_Structure,  // a glTF or USD file whose parts do not refer to each other as they must
	Missing_File,   // a file it names (a glTF buffer) that cannot be read
}

MESH_FILE_ERROR_TEXT := [Mesh_File_Error]string {
	.None           = "no error",
	.Not_Recognised = "it is not a file of that format: it may be damaged, or named with another format's extension",
	.Bad_Header     = "a PLY header without a vertex element with x, y and z, or one this reader does not follow",
	.Bad_Number     = "a number that does not parse",
	.Bad_Index      = "a face names a vertex the file does not have (0, or past the last)",
	.Truncated      = "the file ends before the data it promises: it may have been cut short while copying",
	.Not_Finite     = "a coordinate that is not a number or is infinite",
	.Too_Large      = "more vertices or triangles than 32-bit indices reach (over 4 billion)",
	.Empty          = "no surfaces in it: only points, lines, or nothing",
	.Not_Clean      = "a triangle with a repeated corner, or a vertex no triangle uses",
	.Bad_Structure  = "parts of the file that do not fit together: it may be damaged",
	.Missing_File   = "a file it names beside it (a buffer) is missing: keep the files together, or export it as one file (.glb, .usdz or a binary FBX)",
}

// Bytes of OBJ text one parse job takes: enough lines to be worth a job, few enough
// that a large file spreads over every core.
OBJ_CHUNK :: 4 << 20

// Reads the `v` and `f` lines of an OBJ file, ignoring every other line and the
// texture and normal parts of face corners (a, a/b, a/b/c and a//c all give a);
// negative indices count back from the last vertex so far, and polygons are split into
// fans. Chunks of `chunk_bytes` parse in parallel and join in file order, so the
// result is the same whatever the pool. `line` is where an error was found (0 when no
// one line is to blame). Normals are left zero.
//
// When `colors` is given it receives the vertex colours, one a vertex, when the file
// has any (and is left empty otherwise): the three numbers after a `v` line's position
// that Blender, MeshLab and most scanners write, or else ZBrush's `#MRGB` comment
// blocks. A vertex without one gets alpha 0, so its clay shows. When `labels` is given
// it receives what the `o`, `g` and `usemtl` lines say of the triangles (see
// Obj_Labels). When `uvs` is given it receives each corner's texture coordinate from the
// `vt` lines, turned so v runs down from the image's top (NaN, NaN for a corner without
// one), and is left empty when the file has no `vt` lines. When `polys` is given it receives, one a triangle, the polygon each was cut
// from (see Mesh_Part.polys), and is left empty when every face is a triangle.
mesh_read_obj :: proc(data: []u8, pool: ^jobs.Pool, chunk_bytes := OBJ_CHUNK, colors: ^[dynamic]Vertex_Color = nil, labels: ^Obj_Labels = nil, uvs: ^[dynamic][2]f32 = nil, allocator := context.allocator, polys: ^[dynamic]u32 = nil) -> (m: Mesh, err: Mesh_File_Error, line: int) {
	starts := make([dynamic]int, 0, len(data) / max(chunk_bytes, 1) + 2, context.temp_allocator)
	append(&starts, 0)
	for {
		at := starts[len(starts) - 1] + max(chunk_bytes, 1)
		if at >= len(data) do break
		nl := bytes.index_byte(data[at:], '\n')
		if nl < 0 || at + nl + 1 >= len(data) do break
		append(&starts, at + nl + 1)
	}
	job := Obj_Job{chunks = make([]Obj_Chunk, len(starts), context.temp_allocator), want_uvs = uvs != nil, want_polys = polys != nil}
	for &c, i in job.chunks {
		c.start = starts[i]
		c.text = data[starts[i]:starts[i + 1] if i + 1 < len(starts) else len(data)]
	}
	defer for &c in job.chunks {
		delete(c.positions)
		delete(c.indices)
		delete(c.relative)
		delete(c.colors)
		delete(c.mrgb)
		delete(c.labels)
		delete(c.uvs)
		delete(c.uv_index)
		delete(c.uv_relative)
		delete(c.polys)
	}
	jobs.parallel_for(pool, len(job.chunks), &job, job_obj_chunk)
	vertices, corners, coordinates := 0, 0, 0
	colored, mrgb, polygons := false, 0, false
	for &c in job.chunks {
		if c.err != .None do return {}, c.err, 1 + bytes.count(data[:c.start + c.err_at], []u8{'\n'})
		c.first_vertex, c.first_index, c.first_uv = vertices, corners, coordinates
		vertices += len(c.positions)
		corners += len(c.indices)
		coordinates += len(c.uvs)
		colored ||= len(c.colors) > 0
		mrgb += len(c.mrgb)
		polygons ||= c.polygons
	}
	if vertices >= int(max(u32)) do return {}, .Too_Large, 0
	m.positions = make([dynamic]Vec3, vertices, allocator)
	m.normals = make([dynamic]Vec3, vertices, allocator)
	m.indices = make([dynamic]u32, corners, allocator)
	job.m = &m
	jobs.parallel_for(pool, len(job.chunks), &job, proc(data: rawptr, i: int) {
		job := cast(^Obj_Job)data
		c := &job.chunks[i]
		copy(job.m.positions[c.first_vertex:], c.positions[:])
		out := job.m.indices[c.first_index:][:len(c.indices)]
		copy(out, c.indices[:])
		// A negative index was stored counted from the chunk's first vertex; wrapping
		// arithmetic gives the right index whenever the true one is in range.
		for k in c.relative do out[k] += u32(c.first_vertex)
	})
	if !indices_in_range(m.indices[:], vertices, pool) {
		mesh_destroy(&m)
		return {}, .Bad_Index, 0
	}
	if corners == 0 {
		mesh_destroy(&m)
		return {}, .Empty, 0
	}
	if colors != nil && (colored || mrgb > 0) {
		// Colours on the `v` lines win over ZBrush's blocks, which list the vertices'
		// colours in order, up to 64 a line, wherever in the file they come.
		resize(colors, vertices)
		at := 0
		for c in job.chunks {
			if colored {
				dst := colors[c.first_vertex:][:len(c.positions)]
				copy(dst, c.colors[:])
				mem.zero_slice(dst[len(c.colors):])
			} else {
				n := min(len(c.mrgb), vertices - at)
				copy(colors[at:][:n], c.mrgb[:n])
				at += n
			}
		}
		if !colored do mem.zero_slice(colors[at:])
	}
	if labels != nil do obj_labels_join(labels, job.chunks, corners / 3)
	if polys != nil && polygons {
		// A face's triangles are numbered by its first, counted through the whole file.
		resize(polys, corners / 3)
		for c in job.chunks {
			dst := polys[c.first_index / 3:][:len(c.polys)]
			for first, t in c.polys do dst[t] = first + u32(c.first_index / 3)
		}
	}
	if uvs != nil && coordinates > 0 {
		job.vt = make([][2]f32, coordinates, context.temp_allocator)
		for c in job.chunks do copy(job.vt[c.first_uv:], c.uvs[:])
		resize(uvs, corners)
		job.uvs = uvs[:]
		jobs.parallel_for(pool, len(job.chunks), &job, proc(data: rawptr, i: int) {
			job := cast(^Obj_Job)data
			c := &job.chunks[i]
			// As with positions, a negative index was counted from the chunk's first.
			for k in c.uv_relative do c.uv_index[k] += u32(c.first_uv)
			out := job.uvs[c.first_index:][:len(c.indices)]
			for &uv, k in out {
				at := c.uv_index[k] if k < len(c.uv_index) else OBJ_NO_UV
				uv = {math.nan_f32(), math.nan_f32()}
				if int(at) < len(job.vt) do uv = {job.vt[at].x, 1 - job.vt[at].y}
			}
		})
	}
	return m, .None, 0
}

// One mesh of a file that may hold several (OBJ objects, glTF nodes' meshes, FBX models,
// USD Mesh prims): triangles in the file's units with the file's own transforms
// applied, normals zero, its name, and what it brings for the surface. A reader given a
// Mesh_Look also fills `materials` and `uvs`, which mesh_parts_paint turns into colours,
// dropping the materials before the part is cleaned; the OBJ reader fills `uvs` from any
// `vt` lines, which an object of quads keeps as its UVs. A reader of a format with polygons fills `polys`:
// one a triangle, a number the triangles cut from one polygon share, those triangles
// next to each other and no other run of triangles next to them sharing it (the number
// itself means nothing else); empty when the file's faces are all triangles.
// mesh_polygons turns it back into the polygons.
Mesh_Part :: struct {
	name:      string, // owned; "" for none
	// The names of the nodes, prims or groups holding it in the file's hierarchy, from the
	// file's top down to its nearest named parent, owned; empty for one at the top or a
	// format without one. Import makes a folder of each, nested as the file nests them.
	folders:   []string,
	mesh:      Mesh,
	colors:    [dynamic]Vertex_Color, // one a vertex, or empty
	groups:    [dynamic]u16, // one a triangle, or empty
	materials: [dynamic]i32, // one a triangle (into Mesh_Look.materials, -1 for none), or empty
	uvs:       [dynamic][2]f32, // one a corner (u right, v down from the image's top), or empty
	polys:     [dynamic]u32, // one a triangle, or empty
}

// A copy of `path` for a part's folders, each name owned.
mesh_part_folders :: proc(path: []string) -> []string {
	if len(path) == 0 do return nil
	out := make([]string, len(path))
	for name, i in path do out[i] = strings.clone(name)
	return out
}

mesh_part_destroy :: proc(p: ^Mesh_Part) {
	delete(p.name)
	for f in p.folders do delete(f)
	delete(p.folders)
	mesh_destroy(&p.mesh)
	delete(p.colors)
	delete(p.groups)
	delete(p.materials)
	delete(p.uvs)
	delete(p.polys)
	p^ = {}
}

// What a file holds for animation that Import leaves for later, for the note: the meshes
// come in their rest pose, as modelled.
Rig_Found :: struct {
	skins:      int, // skins or skeletons binding meshes to joints
	animations: int, // animations, clips or animation stacks
	shapes:     int, // morph targets, blend shapes or shape keys
}

// The note's words for what `r` counts, "" for nothing: "1 skin, 2 animations and 3 shape
// keys". Temp memory.
rig_found_text :: proc(r: Rig_Found) -> string {
	words := make([dynamic]string, context.temp_allocator)
	plural :: proc(n: int, one, many: string) -> string {return fmt.tprintf("%d %s", n, one if n == 1 else many)}
	if r.skins > 0 do append(&words, plural(r.skins, "skin", "skins"))
	if r.animations > 0 do append(&words, plural(r.animations, "animation", "animations"))
	if r.shapes > 0 do append(&words, plural(r.shapes, "shape key", "shape keys"))
	switch len(words) {
	case 0: return ""
	case 1: return words[0]
	}
	head := strings.join(words[:len(words) - 1], ", ", context.temp_allocator)
	return fmt.tprintf("%s and %s", head, words[len(words) - 1])
}

mesh_parts_destroy :: proc(parts: ^[dynamic]Mesh_Part) {
	for &p in parts do mesh_part_destroy(&p)
	delete(parts^)
	parts^ = {}
}

// Appends the parts of `m` that `part` (one a triangle, below len(names)) names to
// `parts`, in part order, each with its share of `colors`, `groups`, `materials`, `uvs`
// and `polys` (any may be empty) and its name; a part with no triangles is left out, and
// so are groups when a part's triangles all have the same one.
mesh_parts_split :: proc(parts: ^[dynamic]Mesh_Part, m: Mesh, colors: []Vertex_Color, groups: []u16, part: []u32, names: []string, materials: []i32 = nil, uvs: [][2]f32 = nil, polys: []u32 = nil) {
	pieces := mesh_split(m, part, len(names))
	defer split_parts_destroy(pieces)
	for &piece, k in pieces {
		if len(piece.tri_from) == 0 do continue
		out := Mesh_Part{name = strings.clone(names[k]), mesh = piece.mesh}
		piece.mesh = {}
		if len(colors) > 0 {
			out.colors = make([dynamic]Vertex_Color, len(piece.vertex_from))
			for v, i in piece.vertex_from do out.colors[i] = colors[v]
		}
		if len(groups) > 0 && !slice.all_of(groups_of(groups, piece.tri_from[:]), groups[piece.tri_from[0]]) {
			out.groups = make([dynamic]u16, len(piece.tri_from))
			for t, i in piece.tri_from do out.groups[i] = groups[t]
		}
		// mesh_split keeps each triangle's corners in order, so its corners' coordinates
		// follow it.
		if len(materials) > 0 {
			out.materials = make([dynamic]i32, len(piece.tri_from))
			for t, i in piece.tri_from do out.materials[i] = materials[t]
		}
		if len(uvs) > 0 {
			out.uvs = make([dynamic][2]f32, 3 * len(piece.tri_from))
			for t, i in piece.tri_from do copy(out.uvs[3 * i:][:3], uvs[3 * t:][:3])
		}
		// A part keeps its triangles in their file order, so a polygon's stay together.
		if len(polys) > 0 {
			out.polys = make([dynamic]u32, len(piece.tri_from))
			for t, i in piece.tri_from do out.polys[i] = polys[t]
		}
		append(parts, out)
	}
	groups_of :: proc(groups: []u16, tris: []u32) -> []u16 {
		out := make([]u16, len(tris), context.temp_allocator)
		for t, i in tris do out[i] = groups[t]
		return out
	}
}

// The most parts a file becomes objects as; a file of more becomes one object with a
// polygroup a part (mesh_parts_merge), as a scan or game export cut in thousands of
// pieces would otherwise flood the scene and the undo list.
MESH_PARTS_MAX :: 256

// Joins all the parts into the first, each part's triangles becoming a polygroup of
// their own (numbered from 1 in part order, up to the u16 limit), the colours following
// their vertices and the polygons their triangles; the first keeps its name.
mesh_parts_merge :: proc(parts: ^[dynamic]Mesh_Part) {
	if len(parts) < 2 do return
	out := &parts[0]
	colored, polygons, mapped := false, false, true
	for p in parts {
		colored ||= len(p.colors) > 0
		polygons ||= len(p.polys) > 0
		mapped &&= len(p.uvs) > 0
	}
	// Texture coordinates stay only when every part has them.
	if !mapped do delete(out.uvs)
	if !mapped do out.uvs = {}
	if colored && len(out.colors) == 0 do resize(&out.colors, len(out.mesh.positions))
	// Polygons are renumbered from 0 in triangle order, so two parts' numbers never meet;
	// a part without them gives each triangle a number of its own.
	next_poly: u32
	if polygons do next_poly = polys_renumber(&out.polys, len(out.mesh.indices) / 3, 0)
	resize(&out.groups, len(out.mesh.indices) / 3)
	for &g in out.groups do g = 1
	for &p, k in parts[1:] {
		base := u32(len(out.mesh.positions))
		append(&out.mesh.positions, ..p.mesh.positions[:])
		for i in p.mesh.indices do append(&out.mesh.indices, base + i)
		if colored {
			if len(p.colors) > 0 do append(&out.colors, ..p.colors[:])
			else do resize(&out.colors, len(out.mesh.positions))
		}
		for _ in 0 ..< len(p.mesh.indices) / 3 do append(&out.groups, u16(min(k + 2, int(max(u16)))))
		if polygons {
			next_poly = polys_renumber(&p.polys, len(p.mesh.indices) / 3, next_poly)
			append(&out.polys, ..p.polys[:])
		}
		if mapped do append(&out.uvs, ..p.uvs[:])
		mesh_part_destroy(&p)
	}
	resize(&out.mesh.normals, len(out.mesh.positions))
	resize(parts, 1)
}

// Reads an OBJ file as its parts: one for each object its `o` lines name (or one for the
// whole file), with its colours and the groups its `g` lines give (or, without any, its
// materials when it has several), as mesh_read_obj reads them. Given a `look` and a
// `resolve`, the MTL files its `mtllib` lines name fill the look, and each part's
// triangles get their materials and, when a material has an image, its corners their
// texture coordinates.
mesh_read_obj_parts :: proc(parts: ^[dynamic]Mesh_Part, data: []u8, pool: ^jobs.Pool, chunk_bytes := OBJ_CHUNK, look: ^Mesh_Look = nil, resolve: Mesh_Resolve = nil, resolve_data: rawptr = nil) -> (err: Mesh_File_Error, line: int) {
	names := make(map[string]i32, context.temp_allocator)
	if look != nil && resolve != nil do obj_look(data, look, resolve, resolve_data, &names)
	colors := make([dynamic]Vertex_Color)
	uvs: [dynamic][2]f32
	labels: Obj_Labels
	defer obj_labels_destroy(&labels)
	m: Mesh
	polys: [dynamic]u32
	// Texture coordinates are read whatever the materials say: an object of quads keeps
	// them as its UVs.
	m, err, line = mesh_read_obj(data, pool, chunk_bytes, &colors, &labels, &uvs, polys = &polys)
	if err != .None {
		delete(colors)
		delete(uvs)
		delete(polys)
		return
	}
	// A part none of whose corners has a coordinate has no UVs; in one that has some, a
	// corner without one is at 0, 0.
	first_part := len(parts)
	defer for &p in parts[first_part:] {
		some := false
		for uv in p.uvs do some ||= !math.is_nan(uv.x)
		if !some {
			delete(p.uvs)
			p.uvs = {}
		}
		for &uv in p.uvs do if math.is_nan(uv.x) do uv = {0, 0}
	}
	// Materials name groups when nothing else does, as glTF's do.
	if len(labels.group) == 0 && len(labels.material) > 0 && !slice.all_of(labels.material[:], labels.material[0]) {
		resize(&labels.group, len(labels.material))
		for x, t in labels.material do labels.group[t] = u16(min(int(x) + 1, int(max(u16))))
	}
	// The file's material numbers become the look's, by name; a name no MTL file defines
	// is none.
	materials: [dynamic]i32
	if len(names) > 0 && len(labels.material) > 0 {
		lookup := make([]i32, len(labels.material_names), context.temp_allocator)
		for name, k in labels.material_names {
			x, known := names[name]
			lookup[k] = x if known else -1
		}
		materials = make([dynamic]i32, len(labels.material))
		for x, t in labels.material do materials[t] = lookup[x] if x >= 0 else -1
	}
	if len(labels.object) == 0 || slice.all_of(labels.object[:], labels.object[0]) {
		single := Mesh_Part{mesh = m, colors = colors, materials = materials, uvs = uvs, polys = polys}
		if len(labels.object) > 0 do single.name = strings.clone(labels.object_names[labels.object[0]])
		if len(labels.group) > 0 && !slice.all_of(labels.group[:], labels.group[0]) {
			single.groups = labels.group
			labels.group = {}
		}
		append(parts, single)
		return
	}
	defer {
		mesh_destroy(&m)
		delete(colors)
		delete(materials)
		delete(uvs)
		delete(polys)
	}
	mesh_parts_split(parts, m, colors[:], labels.group[:], labels.object[:], labels.object_names[:], materials[:], uvs[:], polys[:])
	return
}

// What an OBJ file's `o`, `g` and `usemtl` lines say of its triangles: each triangle's
// object, when there is more than one, its group, when there is any, and its material,
// when there is any. Triangles before the first `o` line are in an object named "",
// before the first `g` line in group 0 and before the first `usemtl` line in material
// -1; the others are numbered in the order their names first come, a name seen again
// taking its number.
Obj_Labels :: struct {
	object:         [dynamic]u32, // per triangle, or empty for one object
	object_names:   [dynamic]string, // per object, from the file's bytes (not owned)
	group:          [dynamic]u16, // per triangle, or empty for no groups
	material:       [dynamic]i32, // per triangle, or empty for no materials
	material_names: [dynamic]string, // per material, from the file's bytes (not owned)
}

obj_labels_destroy :: proc(l: ^Obj_Labels) {
	delete(l.object)
	delete(l.object_names)
	delete(l.group)
	delete(l.material)
	delete(l.material_names)
	l^ = {}
}

// An `o`, `g` or `usemtl` line of a chunk: the name it gives and the chunk's triangle it
// starts at.
@(private = "file")
Obj_Label :: struct {
	kind:     enum u8 {
		Group,
		Object,
		Material,
	},
	name:     string,
	triangle: int,
}

// Numbers the chunks' `o` and `g` lines in file order into per triangle objects and
// groups; serial, as names decide numbers by when they first come.
@(private = "file")
obj_labels_join :: proc(l: ^Obj_Labels, chunks: []Obj_Chunk, triangles: int) {
	objects, groups, materials := 0, 0, 0
	for c in chunks do for e in c.labels {
		switch e.kind {
		case .Object: objects += 1
		case .Group: groups += 1
		case .Material: materials += 1
		}
	}
	// Looked up, never walked, so no map order reaches the numbers.
	named := make(map[string]int, context.temp_allocator)
	objects_named := make(map[string]u32, context.temp_allocator)
	objects_named[""] = 0
	append(&l.object_names, "")
	materials_named := make(map[string]i32, context.temp_allocator)
	if objects > 0 do resize(&l.object, triangles)
	if groups > 0 do resize(&l.group, triangles)
	if materials > 0 do resize(&l.material, triangles)
	object, group, material := u32(0), u16(0), i32(-1)
	group_count := 1
	at := 0
	for c in chunks {
		first := c.first_index / 3
		for e in c.labels {
			// The triangles since the last label take the numbers set then.
			upto := first + e.triangle
			if objects > 0 do slice.fill(l.object[at:upto], object)
			if groups > 0 do slice.fill(l.group[at:upto], group)
			if materials > 0 do slice.fill(l.material[at:upto], material)
			at = upto
			if e.kind == .Material {
				k, seen := materials_named[e.name]
				if !seen {
					k = i32(len(l.material_names))
					materials_named[e.name] = k
					append(&l.material_names, e.name)
				}
				material = k
			} else if e.kind == .Object {
				k, seen := objects_named[e.name]
				if !seen {
					k = u32(len(l.object_names))
					objects_named[e.name] = k
					append(&l.object_names, e.name)
				}
				object = k
			} else if e.name == "" {
				group = 0
			} else if k, ok := named[e.name]; ok {
				group = u16(k)
			} else if group_count <= int(max(u16)) {
				named[e.name] = group_count
				group = u16(group_count)
				group_count += 1
			}
		}
	}
	if objects > 0 do slice.fill(l.object[at:], object)
	if groups > 0 do slice.fill(l.group[at:], group)
	if materials > 0 do slice.fill(l.material[at:], material)
}

@(private = "file")
Obj_Chunk :: struct {
	text:         []u8,
	start:        int, // of text, in the file
	positions:    [dynamic]Vec3,
	indices:      [dynamic]u32,
	relative:     [dynamic]u32, // entries of indices counted from this chunk's first vertex
	// The `v` lines' colours from the first that has one (earlier ones get none), and
	// the colours of `#MRGB` blocks.
	colors:       [dynamic]Vertex_Color,
	mrgb:         [dynamic]Vertex_Color,
	labels:       [dynamic]Obj_Label, // the `o`, `g` and `usemtl` lines, in order
	// The `vt` lines, and each corner's index into them (OBJ_NO_UV for none), when asked.
	uvs:          [dynamic][2]f32,
	uv_index:     [dynamic]u32,
	uv_relative:  [dynamic]u32, // entries of uv_index counted from this chunk's first `vt`
	// Each triangle's face as the chunk's number of its first triangle, when asked, and
	// whether any face had more than three corners.
	polys:        [dynamic]u32,
	polygons:     bool,
	err:          Mesh_File_Error,
	err_at:       int, // where in text the failing line starts
	first_vertex: int,
	first_index:  int,
	first_uv:     int,
}

@(private = "file")
OBJ_NO_UV :: max(u32)

@(private = "file")
Obj_Job :: struct {
	chunks:     []Obj_Chunk,
	m:          ^Mesh,
	want_uvs:   bool,
	want_polys: bool,
	vt:         [][2]f32, // every `vt` line, in file order
	uvs:        [][2]f32, // the result, one a corner
}

@(private = "file")
job_obj_chunk :: proc(data: rawptr, i: int) {
	job := cast(^Obj_Job)data
	c := &job.chunks[i]
	heap := runtime.heap_allocator()
	text := c.text
	n := len(text)
	c.positions = make([dynamic]Vec3, 0, n / 128, heap)
	c.indices = make([dynamic]u32, 0, n / 32, heap)
	c.relative = make([dynamic]u32, heap)
	if job.want_polys do c.polys = make([dynamic]u32, 0, n / 32, heap)
	corners := make([dynamic]u32, 0, 16, heap)
	defer delete(corners)
	relative := make([dynamic]bool, 0, 16, heap)
	defer delete(relative)
	// Each corner's `vt` index and whether it counts back, when they are wanted.
	corner_uvs := make([dynamic]u32, 0, 16, heap)
	defer delete(corner_uvs)
	uv_relative := make([dynamic]bool, 0, 16, heap)
	defer delete(uv_relative)
	at := 0
	for at < n {
		line_start := at
		skip_blanks(text, &at)
		if bytes.has_prefix(text[at:], transmute([]u8)string("#MRGB ")) {
			at += 6
			obj_mrgb(c, text, &at)
		} else if at + 1 < n && (text[at] == 'o' || text[at] == 'g') && (is_blank(text[at + 1]) || text[at + 1] == '\n' || text[at + 1] == '\r') {
			if c.labels == nil do c.labels = make([dynamic]Obj_Label, heap)
			end := at + 1
			for end < n && text[end] != '\n' && text[end] != '\r' && text[end] != '#' do end += 1
			append(&c.labels, Obj_Label{kind = .Object if text[at] == 'o' else .Group, name = strings.trim_space(string(text[at + 1:end])), triangle = len(c.indices) / 3})
		} else if bytes.has_prefix(text[at:], transmute([]u8)string("usemtl")) && at + 6 < n && is_blank(text[at + 6]) {
			if c.labels == nil do c.labels = make([dynamic]Obj_Label, heap)
			end := at + 6
			for end < n && text[end] != '\n' && text[end] != '\r' && text[end] != '#' do end += 1
			append(&c.labels, Obj_Label{kind = .Material, name = strings.trim_space(string(text[at + 6:end])), triangle = len(c.indices) / 3})
		} else if job.want_uvs && at + 2 < n && text[at] == 'v' && text[at + 1] == 't' && is_blank(text[at + 2]) {
			// A texture coordinate: u, then v when there is one (a missing v is 0).
			at += 3
			uv: [2]f32
			for k in 0 ..< 2 {
				skip_blanks(text, &at)
				value, ok := parse_float(text, &at)
				if !ok || !ends_token(text, at) do break
				uv[k] = value
			}
			append(&c.uvs, uv)
		} else if at + 1 < n && is_blank(text[at + 1]) && (text[at] == 'v' || text[at] == 'f') {
			kind := text[at]
			at += 2
			if kind == 'v' {
				p: Vec3
				for k in 0 ..< 3 {
					skip_blanks(text, &at)
					value, ok := parse_float(text, &at)
					if !ok || !ends_token(text, at) {
						c.err, c.err_at = .Bad_Number, line_start
						return
					}
					p[k] = value
				}
				append(&c.positions, p)
				// Three or four more numbers are a colour (and its alpha, which is left
				// out); one alone is the rational weight some writers give, never a colour.
				extra: [4]f32
				count := 0
				for count < 4 {
					skip_blanks(text, &at)
					value, ok := parse_float(text, &at)
					if !ok || !ends_token(text, at) do break
					extra[count] = value
					count += 1
				}
				if count >= 3 {
					if len(c.colors) == 0 do resize(&c.colors, len(c.positions) - 1)
					append(&c.colors, obj_color(extra.rgb))
				} else if len(c.colors) > 0 {
					append(&c.colors, Vertex_Color{})
				}
			} else {
				clear(&corners)
				clear(&relative)
				clear(&corner_uvs)
				clear(&uv_relative)
				for {
					skip_blanks(text, &at)
					if at >= n || text[at] == '\n' || text[at] == '\r' || text[at] == '#' do break
					index, ok := parse_int(text, &at)
					uv_at, uv_back := OBJ_NO_UV, false
					if ok && at < n && text[at] == '/' {
						at += 1
						if job.want_uvs && at < n && text[at] != '/' {
							// A bad or out of range texture index costs the corner its
							// coordinate, never the file.
							if t, t_ok := parse_int(text, &at); t_ok {
								if t > 0 && t <= i64(max(u32) - 1) do uv_at = u32(t - 1)
								else if t < 0 && t >= -i64(max(u32) - 1) do uv_at, uv_back = u32(i64(len(c.uvs)) + t), true
							}
						}
						for at < n && !is_space(text[at]) do at += 1
					}
					if job.want_uvs {
						append(&corner_uvs, uv_at)
						append(&uv_relative, uv_back)
					}
					if !ok || !ends_token(text, at) {
						c.err, c.err_at = .Bad_Number, line_start
						return
					}
					switch {
					case index > 0 && index <= i64(max(u32)):
						append(&corners, u32(index - 1))
						append(&relative, false)
					case index < 0 && index >= -i64(max(u32)):
						append(&corners, u32(i64(len(c.positions)) + index))
						append(&relative, true)
					case:
						c.err, c.err_at = .Bad_Index, line_start
						return
					}
				}
				if job.want_polys && len(corners) >= 3 {
					first := u32(len(c.indices) / 3)
					for _ in 0 ..< len(corners) - 2 do append(&c.polys, first)
					c.polygons ||= len(corners) > 3
				}
				for k in 1 ..< max(len(corners) - 1, 1) {
					for j in ([3]int{0, k, k + 1}) {
						if relative[j] do append(&c.relative, u32(len(c.indices)))
						if job.want_uvs {
							if uv_relative[j] do append(&c.uv_relative, u32(len(c.uv_index)))
							append(&c.uv_index, corner_uvs[j])
						}
						append(&c.indices, corners[j])
					}
				}
			}
		}
		nl := bytes.index_byte(text[at:], '\n')
		at = n if nl < 0 else at + nl + 1
	}
}

// A `v` line's colour as bytes, its numbers from 0 to 1, or from 0 to 255 when any is
// above 1, as a few scanners write them.
@(private = "file")
obj_color :: proc(rgb: [3]f32) -> Vertex_Color {
	scale: f32 = 255 if max(rgb.r, rgb.g, rgb.b) <= 1 else 1
	out := Vertex_Color{0, 0, 0, 255}
	for x, k in rgb do out[k] = u8(math.round(clamp(x * scale, 0, 255)))
	return out
}

// The colours of a ZBrush `#MRGB` line: eight hex digits a vertex, the mask's byte (left
// out) and then red, green and blue.
@(private = "file")
obj_mrgb :: proc(c: ^Obj_Chunk, text: []u8, at: ^int) {
	hex :: #force_inline proc(x: u8) -> (u8, bool) {
		switch x {
		case '0' ..= '9': return x - '0', true
		case 'a' ..= 'f': return x - 'a' + 10, true
		case 'A' ..= 'F': return x - 'A' + 10, true
		}
		return 0, false
	}
	skip_blanks(text, at)
	for at^ + 8 <= len(text) {
		digits: [8]u8
		for k in 0 ..< 8 {
			d, ok := hex(text[at^ + k])
			if !ok do return
			digits[k] = d
		}
		append(&c.mrgb, Vertex_Color{digits[2] << 4 | digits[3], digits[4] << 4 | digits[5], digits[6] << 4 | digits[7], 255})
		at^ += 8
	}
}

// Element and property names and types of a PLY header.
@(private = "file")
Ply_Type :: enum u8 {
	None,
	I8,
	U8,
	I16,
	U16,
	I32,
	U32,
	F32,
	F64,
}

@(private = "file")
PLY_TYPE_SIZE := [Ply_Type]int {
	.None = 0,
	.I8   = 1,
	.U8   = 1,
	.I16  = 2,
	.U16  = 2,
	.I32  = 4,
	.U32  = 4,
	.F32  = 4,
	.F64  = 8,
}

@(private = "file")
Ply_Property :: struct {
	name:       string,
	type:       Ply_Type, // of the value, or of a list's items
	count_type: Ply_Type, // of a list's length; None for a single value
}

@(private = "file")
Ply_Element :: struct {
	name:  string,
	count: int,
	props: [dynamic]Ply_Property,
}

@(private = "file")
Ply_Format :: enum u8 {
	Ascii,
	Little,
	Big,
}

// Reads the vertices (x, y and z) and faces (vertex_indices or vertex_index) of a PLY
// file, text or binary in either byte order, with any property types; other elements
// and properties are skipped. Binary vertices, and binary faces that are all
// triangles, are read in parallel. Polygons are split into fans; normals are left zero.
// When `colors` is given and the vertices have red, green and blue (or diffuse_red,
// diffuse_green and diffuse_blue), it receives them, one a vertex; bytes are taken as
// they are, other integers and floats from 0 to their type's top or to 1. When `polys`
// is given it receives, one a triangle, the polygon each was cut from (see
// Mesh_Part.polys), and is left empty when every face is a triangle.
mesh_read_ply :: proc(data: []u8, pool: ^jobs.Pool, colors: ^[dynamic]Vertex_Color = nil, allocator := context.allocator, polys: ^[dynamic]u32 = nil) -> (m: Mesh, err: Mesh_File_Error, line: int) {
	if !bytes.has_prefix(data, transmute([]u8)string("ply")) do return {}, .Not_Recognised, 1
	head := string(data[:min(len(data), 1 << 20)])
	end := strings.index(head, "end_header")
	if end < 0 do return {}, .Bad_Header, 0
	body := end + bytes.index_byte(data[end:], '\n') + 1
	if body <= end do return {}, .Bad_Header, 0

	format: Maybe(Ply_Format)
	elements := make([dynamic]Ply_Element, context.temp_allocator)
	header := head[:end]
	for raw, n in strings.split_lines(header, context.temp_allocator) {
		fields := strings.fields(raw, context.temp_allocator)
		if len(fields) == 0 do continue
		switch fields[0] {
		case "format":
			if len(fields) < 2 do return {}, .Bad_Header, n + 1
			switch fields[1] {
			case "ascii": format = .Ascii
			case "binary_little_endian": format = .Little
			case "binary_big_endian": format = .Big
			case: return {}, .Bad_Header, n + 1
			}
		case "element":
			if len(fields) != 3 do return {}, .Bad_Header, n + 1
			count, ok := strconv.parse_int(fields[2])
			if !ok || count < 0 do return {}, .Bad_Header, n + 1
			append(&elements, Ply_Element{name = fields[1], count = count, props = make([dynamic]Ply_Property, context.temp_allocator)})
		case "property":
			if len(elements) == 0 do return {}, .Bad_Header, n + 1
			p: Ply_Property
			if len(fields) == 5 && fields[1] == "list" {
				p = {fields[4], ply_type(fields[3]), ply_type(fields[2])}
				if p.count_type == .None || p.count_type == .F32 || p.count_type == .F64 do return {}, .Bad_Header, n + 1
			} else if len(fields) == 3 {
				p = {fields[2], ply_type(fields[1]), .None}
			}
			if p.type == .None do return {}, .Bad_Header, n + 1
			append(&elements[len(elements) - 1].props, p)
		}
	}
	if format == nil do return {}, .Bad_Header, 0

	r := Ply_Reader{data = data, at = body, format = format.?, pool = pool, polys = polys}
	vertices, faces := -1, -1
	for e, i in elements {
		if e.name == "vertex" do vertices = i
		if e.name == "face" do faces = i
	}
	if vertices < 0 do return {}, .Bad_Header, 0
	for name, axis in ([3]string{"x", "y", "z"}) {
		k := ply_property(elements[vertices], name)
		if k < 0 || elements[vertices].props[k].count_type != .None do return {}, .Bad_Header, 0
		r.xyz[axis] = k
	}
	r.rgb = -1
	if colors != nil {
		for names in ([2][3]string{{"red", "green", "blue"}, {"diffuse_red", "diffuse_green", "diffuse_blue"}}) {
			found: [3]int
			for name, k in names do found[k] = ply_property(elements[vertices], name)
			if min(found[0], found[1], found[2]) >= 0 && elements[vertices].props[found[0]].count_type == .None && elements[vertices].props[found[1]].count_type == .None && elements[vertices].props[found[2]].count_type == .None {
				r.rgb = found
				break
			}
		}
	}
	if faces >= 0 {
		r.list = ply_property(elements[faces], "vertex_indices")
		if r.list < 0 do r.list = ply_property(elements[faces], "vertex_index")
		if r.list < 0 || elements[faces].props[r.list].count_type == .None do return {}, .Bad_Header, 0
	}
	if elements[vertices].count >= int(max(u32)) do return {}, .Too_Large, 0

	m.positions = make([dynamic]Vec3, elements[vertices].count, allocator)
	m.normals = make([dynamic]Vec3, elements[vertices].count, allocator)
	m.indices = make([dynamic]u32, allocator)
	r.m = &m
	if r.rgb[0] >= 0 {
		resize(colors, elements[vertices].count)
		r.colors = colors[:]
	}
	for e, i in elements {
		err = ply_element(&r, e, i == vertices, i == faces)
		if err != .None {
			if r.format == .Ascii do line = 1 + bytes.count(data[:min(r.at, len(data))], []u8{'\n'})
			mesh_destroy(&m)
			if colors != nil do clear(colors)
			if polys != nil do clear(polys)
			return {}, err, line
		}
		if i >= vertices && i >= faces do break // nothing after them is read
	}
	failed: Mesh_File_Error
	if len(m.indices) == 0 do failed = .Empty
	else if !indices_in_range(m.indices[:], len(m.positions), pool) do failed = .Bad_Index
	if failed != .None {
		mesh_destroy(&m)
		if colors != nil do clear(colors)
		if polys != nil do clear(polys)
		return {}, failed, 0
	}
	if polys != nil && !r.polygons do clear(polys)
	return m, .None, 0
}

@(private = "file")
Ply_Reader :: struct {
	data:      []u8,
	at:        int,
	format:    Ply_Format,
	pool:      ^jobs.Pool,
	m:         ^Mesh,
	xyz:       [3]int, // the vertex element's x, y and z properties
	rgb:       [3]int, // ...and its red, green and blue, or -1s for none wanted or there
	colors:    []Vertex_Color, // one a vertex when rgb is there
	list:      int, // the face element's index list property
	// One a triangle when wanted: the number of its face's first triangle (see
	// Mesh_Part.polys), and whether any face had more than three corners.
	polys:     ^[dynamic]u32,
	polygons:  bool,
}

// A colour property's value as a byte: bytes as they are, other integers scaled from
// their top, floats from 1.
@(private = "file")
ply_color_byte :: #force_inline proc(v: f64, t: Ply_Type) -> u8 {
	top: f64
	#partial switch t {
	case .U8, .I8: top = 255
	case .U16, .I16: top = 65535
	case .U32, .I32: top = 4294967295
	case: top = 1
	}
	return u8(math.round(clamp(v / top * 255, 0, 255)))
}

@(private = "file")
ply_type :: proc(name: string) -> Ply_Type {
	switch name {
	case "char", "int8": return .I8
	case "uchar", "uint8": return .U8
	case "short", "int16": return .I16
	case "ushort", "uint16": return .U16
	case "int", "int32": return .I32
	case "uint", "uint32": return .U32
	case "float", "float32": return .F32
	case "double", "float64": return .F64
	}
	return .None
}

@(private = "file")
ply_property :: proc(e: Ply_Element, name: string) -> int {
	for p, k in e.props do if p.name == name do return k
	return -1
}

// Reads one element's rows, keeping the positions or the triangles when it is the
// vertex or face element.
@(private = "file")
ply_element :: proc(r: ^Ply_Reader, e: Ply_Element, is_vertex, is_face: bool) -> Mesh_File_Error {
	if r.format == .Ascii do return ply_element_ascii(r, e, is_vertex, is_face)
	big := r.format == .Big
	stride, fixed := 0, true
	for p in e.props {
		if p.count_type != .None do fixed = false
		stride += PLY_TYPE_SIZE[p.type]
	}
	if fixed {
		if (len(r.data) - r.at) / max(stride, 1) < e.count do return .Truncated
		if is_vertex {
			// x, y and z, then red, green and blue.
			Rows :: struct {
				r:       ^Ply_Reader,
				offsets: [6]int,
				types:   [6]Ply_Type,
				stride:  int,
				big:     bool,
			}
			rows := Rows{r = r, stride = stride, big = big}
			for k in 0 ..< 6 {
				p := r.xyz[k] if k < 3 else r.rgb[k - 3]
				if p < 0 do continue
				rows.types[k] = e.props[p].type
				for q in e.props[:p] do rows.offsets[k] += PLY_TYPE_SIZE[q.type]
			}
			jobs.parallel_ranges(r.pool, e.count, &rows, proc(data: rawptr, lo, hi: int) {
				rows := cast(^Rows)data
				r := rows.r
				for v in lo ..< hi {
					row := r.at + v * rows.stride
					for k in 0 ..< 3 do r.m.positions[v][k] = f32(ply_value(r.data, row + rows.offsets[k], rows.types[k], rows.big))
					if r.colors == nil do continue
					c := Vertex_Color{0, 0, 0, 255}
					for k in 0 ..< 3 do c[k] = ply_color_byte(ply_value(r.data, row + rows.offsets[3 + k], rows.types[3 + k], rows.big), rows.types[3 + k])
					r.colors[v] = c
				}
			}, RANGE_GRAIN)
		}
		r.at += e.count * stride
		return .None
	}
	if is_face && len(e.props) == 1 && e.props[0].count_type == .U8 && (e.props[0].type == .I32 || e.props[0].type == .U32) {
		if ply_triangles_fast(r, e.count) do return .None
	}
	for _ in 0 ..< e.count {
		for p, k in e.props {
			if p.count_type == .None {
				r.at += PLY_TYPE_SIZE[p.type]
				continue
			}
			if r.at + PLY_TYPE_SIZE[p.count_type] > len(r.data) do return .Truncated
			count := int(ply_value(r.data, r.at, p.count_type, big))
			r.at += PLY_TYPE_SIZE[p.count_type]
			size := PLY_TYPE_SIZE[p.type]
			if count < 0 || (len(r.data) - r.at) / size < count do return .Truncated
			if is_face && k == r.list && count >= 3 {
				ply_face(r, count)
				first := ply_index(r.data, r.at, p.type, big)
				for c in 1 ..< count - 1 {
					append(&r.m.indices, first, ply_index(r.data, r.at + c * size, p.type, big), ply_index(r.data, r.at + (c + 1) * size, p.type, big))
				}
			}
			r.at += count * size
		}
		if r.at > len(r.data) do return .Truncated
	}
	return .None
}

// Numbers the triangles of a face of `count` corners that is about to be cut into a fan,
// when polygons are wanted.
@(private = "file")
ply_face :: proc(r: ^Ply_Reader, count: int) {
	if r.polys == nil do return
	// The faces before were all triangles read in parallel, each its own polygon.
	if len(r.polys) < len(r.m.indices) / 3 {
		for t in len(r.polys) ..< len(r.m.indices) / 3 do append(r.polys, u32(t))
	}
	first := u32(len(r.m.indices) / 3)
	for _ in 0 ..< count - 2 do append(r.polys, first)
	r.polygons ||= count > 3
}

// Binary faces that are all triangles (a count byte of 3 and three 32-bit indices)
// have a fixed size, so they read in parallel. Returns false, having read nothing,
// when any face is not a triangle.
@(private = "file")
ply_triangles_fast :: proc(r: ^Ply_Reader, count: int) -> bool {
	ROW :: 13
	if (len(r.data) - r.at) / ROW < count do return false
	Rows :: struct {
		r:      ^Ply_Reader,
		base:   int, // first index of these triangles in r.m.indices
		others: []bool, // per range: a face that is not a triangle
	}
	rows := Rows{r = r, base = len(r.m.indices), others = make([]bool, (count + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator)}
	resize(&r.m.indices, rows.base + 3 * count)
	jobs.parallel_ranges(r.pool, count, &rows, proc(data: rawptr, lo, hi: int) {
		rows := cast(^Rows)data
		r := rows.r
		big := r.format == .Big
		for f in lo ..< hi {
			row := r.at + f * ROW
			if r.data[row] != 3 {
				rows.others[lo / RANGE_GRAIN] = true
				return
			}
			for c in 0 ..< 3 do r.m.indices[rows.base + 3 * f + c] = ply_index(r.data, row + 1 + 4 * c, .U32, big)
		}
	}, RANGE_GRAIN)
	for other in rows.others {
		if other {
			resize(&r.m.indices, rows.base)
			return false
		}
	}
	r.at += count * ROW
	return true
}

// One binary value as an f64, which holds every type exactly but the 64-bit float's
// own NaNs.
@(private = "file")
ply_value :: #force_inline proc(data: []u8, at: int, t: Ply_Type, big: bool) -> f64 {
	raw: [8]u8
	size := PLY_TYPE_SIZE[t]
	copy(raw[:size], data[at:][:size])
	if big do slice.reverse(raw[:size])
	switch t {
	case .None: return 0
	case .I8: return f64(cast(i8)raw[0])
	case .U8: return f64(raw[0])
	case .I16: return f64((transmute([4]i16)raw)[0])
	case .U16: return f64((transmute([4]u16)raw)[0])
	case .I32: return f64((transmute([2]i32)raw)[0])
	case .U32: return f64((transmute([2]u32)raw)[0])
	case .F32: return f64((transmute([2]f32)raw)[0])
	case .F64: return transmute(f64)raw
	}
	return 0
}

// A face corner; a negative one becomes max(u32), which the range check refuses.
@(private = "file")
ply_index :: #force_inline proc(data: []u8, at: int, t: Ply_Type, big: bool) -> u32 {
	v := ply_value(data, at, t, big)
	return u32(v) if v >= 0 && v < f64(max(u32)) else max(u32)
}

@(private = "file")
ply_element_ascii :: proc(r: ^Ply_Reader, e: Ply_Element, is_vertex, is_face: bool) -> Mesh_File_Error {
	text := r.data
	corners := make([dynamic]u32, 0, 16, context.temp_allocator)
	for row in 0 ..< e.count {
		for p, k in e.props {
			skip_space(text, &r.at)
			if p.count_type == .None {
				value, ok := parse_float(text, &r.at)
				if !ok || !ends_token(text, r.at) do return .Bad_Number
				if is_vertex {
					for x, axis in r.xyz do if x == k do r.m.positions[row][axis] = value
					if r.colors != nil {
						for x, channel in r.rgb do if x == k {
							r.colors[row][channel] = ply_color_byte(f64(value), p.type)
							r.colors[row].a = 255
						}
					}
				}
				continue
			}
			count, ok := parse_int(text, &r.at)
			if !ok || !ends_token(text, r.at) || count < 0 do return .Bad_Number
			clear(&corners)
			for _ in 0 ..< count {
				skip_space(text, &r.at)
				index, index_ok := parse_int(text, &r.at)
				if !index_ok || !ends_token(text, r.at) do return .Bad_Number
				append(&corners, u32(index) if index >= 0 && index < i64(max(u32)) else max(u32))
			}
			if is_face && k == r.list {
				if len(corners) >= 3 do ply_face(r, len(corners))
				for c in 1 ..< max(len(corners) - 1, 1) do append(&r.m.indices, corners[0], corners[c], corners[c + 1])
			}
		}
	}
	return .None
}

// Whether every index is below `vertices`.
indices_in_range :: proc(indices: []u32, vertices: int, pool: ^jobs.Pool) -> bool {
	Check :: struct {
		indices:  []u32,
		vertices: u32,
		bad:      []bool, // per range
	}
	c := Check{indices, u32(vertices), make([]bool, (len(indices) + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator)}
	jobs.parallel_ranges(pool, len(indices), &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Check)data
		for i in c.indices[lo:hi] {
			if i >= c.vertices {
				c.bad[lo / RANGE_GRAIN] = true
				return
			}
		}
	}, RANGE_GRAIN)
	return !slice.contains(c.bad, true)
}

// What mesh_clean changed.
Mesh_Clean_Report :: struct {
	welded:            int, // vertices merged into an earlier one at exactly the same place
	dropped_triangles: int, // triangles left with a repeated corner
	dropped_vertices:  int, // vertices no triangle used (welded ones included)
}

// Makes a mesh read from a file sculptable: merges vertices at exactly the same place
// (files that list a vertex once per triangle, or once per side of a UV seam, would
// otherwise come apart under the brush), then drops triangles left with a repeated
// corner and vertices no triangle uses, keeping the order of what stays. Refuses NaN
// and infinite coordinates. Normals become zero, for the sculptor to compute. `colors`,
// one a vertex when not empty, follow the vertices: a welded vertex keeps the colour of
// the first at its place; `groups` and `polys`, one a triangle when not empty, and `uvs`,
// one a corner when not empty, follow the triangles.
mesh_clean :: proc(m: ^Mesh, pool: ^jobs.Pool, colors: ^[dynamic]Vertex_Color = nil, groups: ^[dynamic]u16 = nil, polys: ^[dynamic]u32 = nil, uvs: ^[dynamic][2]f32 = nil) -> (report: Mesh_Clean_Report, err: Mesh_File_Error) {
	colored := colors != nil && len(colors) > 0
	assert(!colored || len(colors) == len(m.positions), "one colour a vertex")
	grouped := groups != nil && len(groups) > 0
	assert(!grouped || 3 * len(groups) == len(m.indices), "one group a triangle")
	polygons := polys != nil && len(polys) > 0
	assert(!polygons || 3 * len(polys) == len(m.indices), "one polygon number a triangle")
	mapped := uvs != nil && len(uvs) > 0
	assert(!mapped || len(uvs) == len(m.indices), "one texture coordinate a corner")
	n := len(m.positions)
	if !positions_finite(m.positions[:], pool) do return {}, .Not_Finite

	// Weld: sort the vertices by a hash of their bits; within a run of equal hashes,
	// each vertex joins the first earlier one at the same place.
	Weld :: struct {
		positions: []Vec3,
		keys:      []u32,
		order:     []u32,
		rep:       []u32,
		indices:   []u32,
	}
	w := Weld {
		positions = m.positions[:],
		keys      = make([]u32, n, context.temp_allocator),
		order     = make([]u32, n, context.temp_allocator),
		rep       = make([]u32, n, context.temp_allocator),
		indices   = m.indices[:],
	}
	jobs.parallel_ranges(pool, n, &w, proc(data: rawptr, lo, hi: int) {
		w := cast(^Weld)data
		for v in lo ..< hi {
			w.keys[v] = position_hash(w.positions[v])
			w.order[v] = u32(v)
		}
	}, RANGE_GRAIN)
	radix_sort_pairs(w.keys, w.order, 32, pool)
	places := make([dynamic]u32, 0, 8, context.temp_allocator)
	for lo := 0; lo < n; {
		hi := lo + 1
		for hi < n && w.keys[hi] == w.keys[lo] do hi += 1
		clear(&places)
		run: for v in w.order[lo:hi] {
			for d in places {
				if same_place(w.positions[d], w.positions[v]) {
					w.rep[v] = d
					report.welded += 1
					continue run
				}
			}
			w.rep[v] = v
			append(&places, v)
		}
		lo = hi
	}
	if report.welded > 0 {
		jobs.parallel_ranges(pool, len(w.indices), &w, proc(data: rawptr, lo, hi: int) {
			w := cast(^Weld)data
			for &i in w.indices[lo:hi] do i = w.rep[i]
		}, RANGE_GRAIN)
	}

	// Drop triangles with a repeated corner, in place and in order.
	kept := 0
	for t := 0; t < len(m.indices); t += 3 {
		a, b, c := m.indices[t], m.indices[t + 1], m.indices[t + 2]
		if a == b || b == c || c == a do continue
		m.indices[kept], m.indices[kept + 1], m.indices[kept + 2] = a, b, c
		if grouped do groups[kept / 3] = groups[t / 3]
		if polygons do polys[kept / 3] = polys[t / 3]
		if mapped do copy(uvs[kept:][:3], uvs[t:][:3])
		kept += 3
	}
	report.dropped_triangles = (len(m.indices) - kept) / 3
	resize(&m.indices, kept)
	if grouped do resize(groups, kept / 3)
	if polygons do resize(polys, kept / 3)
	if mapped do resize(uvs, kept)

	// Drop unused vertices: number the used ones in order, then move them down.
	new_of := w.rep // reused: no longer needed
	slice.fill(new_of, max(u32))
	for i in m.indices do new_of[i] = 0
	next: u32
	for &k, v in new_of {
		if k == max(u32) do continue
		k = next
		m.positions[next] = m.positions[v]
		if colored do colors[next] = colors[v]
		next += 1
	}
	report.dropped_vertices = n - int(next)
	if report.dropped_vertices > 0 {
		w.rep, w.indices = new_of, m.indices[:]
		jobs.parallel_ranges(pool, len(w.indices), &w, proc(data: rawptr, lo, hi: int) {
			w := cast(^Weld)data
			for &i in w.indices[lo:hi] do i = w.rep[i]
		}, RANGE_GRAIN)
		resize(&m.positions, int(next))
		if colored do resize(colors, int(next))
	}
	resize(&m.normals, len(m.positions))
	slice.zero(m.normals[:])
	if len(m.indices) == 0 do return report, .Empty
	return report, .None
}

// Whether a mesh meets what a sculptor needs of it (see sculptor_init): triangles of
// three different vertices in range, every vertex used, every position finite. For a
// mesh read from a file that mesh_clean has not seen.
mesh_sculptable :: proc(m: Mesh, pool: ^jobs.Pool) -> Mesh_File_Error {
	if len(m.indices) == 0 || len(m.indices) % 3 != 0 do return .Empty
	if !positions_finite(m.positions[:], pool) do return .Not_Finite
	if !indices_in_range(m.indices[:], len(m.positions), pool) do return .Bad_Index
	used := make([]bool, len(m.positions), context.temp_allocator)
	for t := 0; t < len(m.indices); t += 3 {
		a, b, c := m.indices[t], m.indices[t + 1], m.indices[t + 2]
		if a == b || b == c || c == a do return .Not_Clean
		used[a], used[b], used[c] = true, true, true
	}
	if slice.contains(used, false) do return .Not_Clean
	return .None
}

@(private = "file")
positions_finite :: proc(positions: []Vec3, pool: ^jobs.Pool) -> bool {
	Check :: struct {
		positions: []Vec3,
		bad:       []bool, // per range
	}
	c := Check{positions, make([]bool, (len(positions) + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator)}
	jobs.parallel_ranges(pool, len(positions), &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Check)data
		for p in c.positions[lo:hi] {
			for x in p {
				if math.is_nan(x) || math.is_inf(x) {
					c.bad[lo / RANGE_GRAIN] = true
					return
				}
			}
		}
	}, RANGE_GRAIN)
	return !slice.contains(c.bad, true)
}

// Bits of a position, with -0 and +0 the same, mixed into 32 (an FNV-1a step per
// coordinate, then a final avalanche so the radix sort's low bits spread).
@(private = "file")
position_hash :: #force_inline proc(p: Vec3) -> u32 {
	h: u32 = 2166136261
	for x in p {
		bits := transmute(u32)x
		if bits == 0x8000_0000 do bits = 0
		h = (h ~ bits) * 16777619
	}
	h ~= h >> 16
	h *= 0x7feb352d
	h ~= h >> 15
	return h
}

@(private = "file")
same_place :: #force_inline proc(a, b: Vec3) -> bool {return a == b}

// What a mesh's edges are, counted in parallel from each vertex's triangles rather
// than by mesh_check's sort, which takes seconds at 10M vertices.
Mesh_Edges :: struct {
	border:  int, // edges with one triangle: the mesh is open there
	bad:     int, // edges run twice the same way (a flipped triangle) or in more than two triangles
	volume:  f64, // signed, as mesh_check's: negative for a closed mesh facing inward
}

mesh_edges_closed :: proc(e: Mesh_Edges) -> bool {return e.border == 0 && e.bad == 0}

mesh_edges :: proc(m: Mesh, pool: ^jobs.Pool) -> Mesh_Edges {
	Count :: struct {
		m:      Mesh,
		faces:  Vertex_Faces,
		border: []int, // per range
		bad:    []int,
		volume: []f64,
	}
	ranges := (len(m.positions) + RANGE_GRAIN - 1) / RANGE_GRAIN
	c := Count{m = m, faces = vertex_faces_build(m, pool, context.temp_allocator)}
	c.border = make([]int, ranges, context.temp_allocator)
	c.bad = make([]int, ranges, context.temp_allocator)
	c.volume = make([]f64, (len(m.indices) / 3 + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator)
	jobs.parallel_ranges(pool, len(m.positions), &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Count)data
		idx := c.m.indices[:]
		next :: #force_inline proc(idx: []u32, f, v: u32) -> (after, before: u32) {
			t := idx[3 * f:][:3]
			if t[0] == v do return t[1], t[2]
			if t[1] == v do return t[2], t[0]
			return t[0], t[1]
		}
		for v in u32(lo) ..< u32(hi) {
			faces := vertex_faces_of(c.faces, v)
			for f in faces {
				w, _ := next(idx, f, v)
				same, back := 0, 0
				for g in faces {
					a, b := next(idx, g, v)
					same += int(a == w)
					back += int(b == w)
				}
				if same > 1 || back > 1 do c.bad[lo / RANGE_GRAIN] += 1
				if back == 0 do c.border[lo / RANGE_GRAIN] += 1
			}
		}
	}, RANGE_GRAIN)
	jobs.parallel_ranges(pool, len(m.indices) / 3, &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Count)data
		p := c.m.positions[:]
		idx := c.m.indices[:]
		sum: f64
		for t in lo ..< hi {
			p0, p1, p2 := p[idx[3 * t]], p[idx[3 * t + 1]], p[idx[3 * t + 2]]
			sum += f64(linalg.dot(p0, linalg.cross(p1, p2)))
		}
		c.volume[lo / RANGE_GRAIN] = sum
	}, RANGE_GRAIN)
	e: Mesh_Edges
	for n in c.border do e.border += n
	for n in c.bad do e.bad += n
	for x in c.volume do e.volume += x / 6
	return e
}

// Turns every triangle the other way round, and `uvs` (one a corner, or empty) with them.
mesh_flip :: proc(m: ^Mesh, pool: ^jobs.Pool, uvs: [][2]f32 = nil) {
	for t := 0; t < len(uvs); t += 3 do uvs[t + 1], uvs[t + 2] = uvs[t + 2], uvs[t + 1]
	jobs.parallel_ranges(pool, len(m.indices) / 3, m, proc(data: rawptr, lo, hi: int) {
		m := cast(^Mesh)data
		for t in lo ..< hi do m.indices[3 * t + 1], m.indices[3 * t + 2] = m.indices[3 * t + 2], m.indices[3 * t + 1]
	}, RANGE_GRAIN)
}

// Moves the mesh to a centre near the middle of its bounds and scales it so the
// farthest vertex is 1 away, which is how big the app expects an object to be (its
// camera, focus and brush sizes are set for that). On each axis the centre is the
// file's own origin when that lies in the middle half of the bounds, so a model built
// around a symmetry plane through its origin keeps the plane symmetric brushes mirror
// across; otherwise it is the middle of the bounds. Returns what undoes it: a file
// position is center + radius * p.
mesh_normalize :: proc(m: ^Mesh, pool: ^jobs.Pool) -> (center: Vec3, radius: f32) {
	Norm :: struct {
		positions: []Vec3,
		boxes:     []Aabb, // per range
		far:       []f32, // per range: largest squared distance from center
		center:    Vec3,
		inv:       f32,
	}
	ranges := (len(m.positions) + RANGE_GRAIN - 1) / RANGE_GRAIN
	nm := Norm{positions = m.positions[:], boxes = make([]Aabb, ranges, context.temp_allocator), far = make([]f32, ranges, context.temp_allocator)}
	jobs.parallel_ranges(pool, len(nm.positions), &nm, proc(data: rawptr, lo, hi: int) {
		nm := cast(^Norm)data
		box := AABB_EMPTY
		for p in nm.positions[lo:hi] do aabb_grow(&box, p)
		nm.boxes[lo / RANGE_GRAIN] = box
	}, RANGE_GRAIN)
	box := AABB_EMPTY
	for b in nm.boxes do box = aabb_union(box, b)
	for k in 0 ..< 3 {
		lo, hi := box.lo[k], box.hi[k]
		quarter := (hi - lo) * 0.25
		nm.center[k] = 0 if lo + quarter <= 0 && 0 <= hi - quarter else (lo + hi) * 0.5
	}
	jobs.parallel_ranges(pool, len(nm.positions), &nm, proc(data: rawptr, lo, hi: int) {
		nm := cast(^Norm)data
		far: f32
		for p in nm.positions[lo:hi] do far = max(far, linalg.length2(p - nm.center))
		nm.far[lo / RANGE_GRAIN] = far
	}, RANGE_GRAIN)
	far: f32
	for f in nm.far do far = max(far, f)
	radius = math.sqrt(far)
	if !(radius > 0) do radius = 1
	nm.inv = 1 / radius
	jobs.parallel_ranges(pool, len(nm.positions), &nm, proc(data: rawptr, lo, hi: int) {
		nm := cast(^Norm)data
		for &p in nm.positions[lo:hi] do p = (p - nm.center) * nm.inv
	}, RANGE_GRAIN)
	return nm.center, radius
}

// Sizes the parts of one file together as mesh_normalize sizes one mesh: one centre and
// radius for them all, so they keep their sizes and places relative to each other; then
// each part is moved to sit around its own middle, which `middles` gets (in the sized
// space), so it turns about itself. On each axis the middle is the shared centre when
// the part's middle half straddles it, as mesh_normalize keeps a file's origin, so a
// part built around the model's symmetry plane keeps the plane symmetry mirrors across;
// otherwise it is the middle of the part's bounds. A file position of part k is
// center + radius * (middles[k] + p). A single part keeps mesh_normalize's result
// exactly, with a middle of zero.
mesh_parts_normalize :: proc(parts: []Mesh_Part, pool: ^jobs.Pool, allocator := context.allocator) -> (center: Vec3, radius: f32, middles: []Vec3) {
	middles = make([]Vec3, len(parts), allocator)
	if len(parts) == 1 {
		center, radius = mesh_normalize(&parts[0].mesh, pool)
		return
	}
	// All the parts' positions as one list, sized as one mesh, then copied back.
	total := 0
	for p in parts do total += len(p.mesh.positions)
	whole: Mesh
	whole.positions = make([dynamic]Vec3, 0, total, context.temp_allocator)
	for p in parts do append(&whole.positions, ..p.mesh.positions[:])
	center, radius = mesh_normalize(&whole, pool)
	at := 0
	for &p, k in parts {
		n := len(p.mesh.positions)
		copy(p.mesh.positions[:], whole.positions[at:][:n])
		at += n
		box := AABB_EMPTY
		for q in p.mesh.positions do aabb_grow(&box, q)
		if n == 0 do continue
		for axis in 0 ..< 3 {
			lo, hi := box.lo[axis], box.hi[axis]
			quarter := (hi - lo) * 0.25
			middles[k][axis] = 0 if lo + quarter <= 0 && 0 <= hi - quarter else (lo + hi) * 0.5
		}
		for &q in p.mesh.positions do q -= middles[k]
	}
	return
}

// Appends the mesh as OBJ text: a comment, a `v` line per vertex and an `f` line per
// triangle, each position written as `scale * p + offset`. Coordinates have nine
// significant digits, which read back as the same f32 bits, with trailing zeros left
// out. Formatted in parallel, in ranges joined in order.
mesh_write_obj :: proc(out: ^[dynamic]u8, positions: []Vec3, indices: []u32, scale: f32 = 1, offset := Vec3{}, pool: ^jobs.Pool = nil, colors: [][3]u8 = nil) {
	Parts :: struct {
		positions: []Vec3,
		colors:    [][3]u8,
		indices:   []u32,
		scale:     f32,
		offset:    Vec3,
		parts:     [][dynamic]u8, // per range: vertex ranges, then triangle ranges
		vranges:   int,
	}
	triangles := len(indices) / 3
	p := Parts{positions = positions, colors = colors, indices = indices, scale = scale, offset = offset}
	p.vranges = (len(positions) + RANGE_GRAIN - 1) / RANGE_GRAIN
	p.parts = make([][dynamic]u8, p.vranges + (triangles + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator)
	jobs.parallel_ranges(pool, len(positions), &p, proc(data: rawptr, lo, hi: int) {
		p := cast(^Parts)data
		buf := make([dynamic]u8, 0, 40 * (hi - lo), runtime.heap_allocator())
		tmp: [32]u8
		for v in lo ..< hi {
			q := p.positions[v]
			if p.scale != 1 || p.offset != {} do q = q * p.scale + p.offset // only then, which keeps -0
			append(&buf, 'v')
			for x in q {
				append(&buf, ' ')
				append(&buf, ..tmp[:format_f32(tmp[:], x)])
			}
			// Vertex colours as most programs read them from OBJ: three more numbers, 0 to 1.
			if p.colors != nil {
				for c in p.colors[v] {
					append(&buf, ' ')
					append(&buf, ..tmp[:format_f32(tmp[:], f32(c) / 255)])
				}
			}
			append(&buf, '\n')
		}
		p.parts[lo / RANGE_GRAIN] = buf
	}, RANGE_GRAIN)
	jobs.parallel_ranges(pool, triangles, &p, proc(data: rawptr, lo, hi: int) {
		p := cast(^Parts)data
		buf := make([dynamic]u8, 0, 28 * (hi - lo), runtime.heap_allocator())
		tmp: [16]u8
		for t in lo ..< hi {
			append(&buf, 'f')
			for c in 0 ..< 3 {
				append(&buf, ' ')
				append(&buf, ..tmp[:format_u32(tmp[:], p.indices[3 * t + c] + 1)])
			}
			append(&buf, '\n')
		}
		p.parts[p.vranges + lo / RANGE_GRAIN] = buf
	}, RANGE_GRAIN)
	// Joined in parallel too: copying hundreds of megabytes on one thread, into memory
	// touched for the first time, would take as long as formatting them.
	Join :: struct {
		parts: [][dynamic]u8,
		at:    []int, // where each part goes in out
		out:   []u8,
	}
	head := "# Sculpt\n"
	append(out, head)
	j := Join{parts = p.parts, at = make([]int, len(p.parts) + 1, context.temp_allocator)}
	j.at[0] = len(out)
	for part, i in p.parts do j.at[i + 1] = j.at[i] + len(part)
	non_zero_resize(out, j.at[len(p.parts)])
	j.out = out[:]
	jobs.parallel_for(pool, len(p.parts), &j, proc(data: rawptr, i: int) {
		j := cast(^Join)data
		copy(j.out[j.at[i]:j.at[i + 1]], j.parts[i][:])
		delete(j.parts[i])
	})
}

// Appends the mesh as binary little-endian PLY: float x, y and z per vertex, each
// written as `scale * p + offset`, with uchar red, green and blue after them when
// `colors` are given, and a uchar count with three int indices per face.
mesh_write_ply :: proc(out: ^[dynamic]u8, positions: []Vec3, indices: []u32, scale: f32 = 1, offset := Vec3{}, pool: ^jobs.Pool = nil, colors: [][3]u8 = nil) {
	assert(len(positions) < int(max(i32)), "PLY faces store int indices")
	triangles := len(indices) / 3
	stride := 12 if colors == nil else 15
	head := strings.concatenate({
		"ply\nformat binary_little_endian 1.0\ncomment Sculpt\nelement vertex ", int_text(len(positions)),
		"\nproperty float x\nproperty float y\nproperty float z\n",
		"" if colors == nil else "property uchar red\nproperty uchar green\nproperty uchar blue\n",
		"element face ", int_text(triangles),
		"\nproperty list uchar int vertex_indices\nend_header\n",
	}, context.temp_allocator)
	start := len(out)
	append(out, head)
	Fill :: struct {
		positions: []Vec3,
		colors:    [][3]u8,
		indices:   []u32,
		scale:     f32,
		offset:    Vec3,
		stride:    int,
		vertices:  []u8,
		faces:     []u8,
	}
	resize(out, start + len(head) + stride * len(positions) + 13 * triangles)
	body := out[start + len(head):]
	f := Fill{positions, colors, indices, scale, offset, stride, body[:stride * len(positions)], body[stride * len(positions):]}
	jobs.parallel_ranges(pool, len(positions), &f, proc(data: rawptr, lo, hi: int) {
		f := cast(^Fill)data
		for v in lo ..< hi {
			q := f.positions[v]
			if f.scale != 1 || f.offset != {} do q = q * f.scale + f.offset // only then, which keeps -0
			mem.copy(&f.vertices[f.stride * v], &q, 12)
			if f.colors != nil do mem.copy(&f.vertices[f.stride * v + 12], &f.colors[v], 3)
		}
	}, RANGE_GRAIN)
	jobs.parallel_ranges(pool, triangles, &f, proc(data: rawptr, lo, hi: int) {
		f := cast(^Fill)data
		for t in lo ..< hi {
			row := f.faces[13 * t:]
			row[0] = 3
			mem.copy(&row[1], &f.indices[3 * t], 12)
		}
	}, RANGE_GRAIN)
}

// A binary STL file: an 80-byte header, a little-endian u32 triangle count, then per
// triangle a normal, three corners (twelve floats) and a 16-bit attribute.
STL_HEADER :: 84
STL_ROW :: 50

// Reads an STL file, binary or text. Each triangle brings its own three corners, which
// mesh_clean welds where they meet; the facet normals are ignored and normals are left
// zero. A binary file is known by its length matching its triangle count, since some
// writers begin a binary header with "solid" as text files do; a text loop of more
// than three corners is split into a fan.
mesh_read_stl :: proc(data: []u8, pool: ^jobs.Pool, allocator := context.allocator) -> (m: Mesh, err: Mesh_File_Error, line: int) {
	binary_size := -1
	if len(data) >= STL_HEADER do binary_size = STL_HEADER + STL_ROW * int((^u32le)(&data[80])^)
	at := 0
	skip_space(data, &at)
	text := bytes.has_prefix(data[at:], transmute([]u8)string("solid"))
	if binary_size != len(data) && text {
		m, err, line = stl_read_text(data, allocator)
		// Nothing read as text: a binary file whose header starts as text does, cut short
		// or with bytes after its triangles.
		if err != .Empty || binary_size < 0 do return
	}
	switch {
	case binary_size < 0: return {}, .Not_Recognised, 0
	case binary_size > len(data): return {}, .Truncated, 0
	}
	count := (binary_size - STL_HEADER) / STL_ROW
	if count == 0 do return {}, .Empty, 0
	if 3 * count >= int(max(u32)) do return {}, .Too_Large, 0
	m.positions = make([dynamic]Vec3, 3 * count, allocator)
	m.normals = make([dynamic]Vec3, 3 * count, allocator)
	m.indices = make([dynamic]u32, 3 * count, allocator)
	Rows :: struct {
		data: []u8,
		m:    ^Mesh,
	}
	rows := Rows{data, &m}
	jobs.parallel_ranges(pool, count, &rows, proc(data: rawptr, lo, hi: int) {
		rows := cast(^Rows)data
		for t in lo ..< hi {
			// Past the facet's normal.
			mem.copy(&rows.m.positions[3 * t], &rows.data[STL_HEADER + STL_ROW * t + 12], 36)
			for c in 0 ..< 3 do rows.m.indices[3 * t + c] = u32(3 * t + c)
		}
	}, RANGE_GRAIN)
	return m, .None, 0
}

// The `vertex x y z` lines of a text STL file, a triangle (or fan) for each
// `outer loop` ... `endloop`; every other word is passed over.
@(private = "file")
stl_read_text :: proc(data: []u8, allocator := context.allocator) -> (m: Mesh, err: Mesh_File_Error, line: int) {
	m.positions = make([dynamic]Vec3, allocator)
	m.indices = make([dynamic]u32, allocator)
	loop := 0 // the first corner of the loop being read
	at := 0
	fail: for {
		skip_space(data, &at)
		if at >= len(data) do break
		start := at
		for at < len(data) && !is_space(data[at]) do at += 1
		switch string(data[start:at]) {
		case "outer":
			loop = len(m.positions)
		case "vertex":
			p: Vec3
			for k in 0 ..< 3 {
				skip_space(data, &at)
				ok: bool
				p[k], ok = parse_float(data, &at)
				if !ok || !ends_token(data, at) {
					err = .Bad_Number
					break fail
				}
			}
			if len(m.positions) >= int(max(u32)) - 1 {
				err = .Too_Large
				break fail
			}
			append(&m.positions, p)
		case "endloop":
			for c in loop + 1 ..< len(m.positions) - 1 do append(&m.indices, u32(loop), u32(c), u32(c + 1))
			loop = len(m.positions)
		}
	}
	if err == .None && len(m.indices) == 0 do err = .Empty
	if err != .None {
		if err == .Bad_Number do line = 1 + bytes.count(data[:min(at, len(data))], []u8{'\n'})
		mesh_destroy(&m)
		return {}, err, line
	}
	m.normals = make([dynamic]Vec3, len(m.positions), allocator)
	return m, .None, 0
}

// Appends the mesh as binary STL, each corner written as `scale * p + offset`, with
// each triangle's normal as its corners give it (zero for a sliver) and no colour, as
// 3D printing tools expect. The header says what wrote it and, unlike a text file's,
// does not begin with "solid".
mesh_write_stl :: proc(out: ^[dynamic]u8, positions: []Vec3, indices: []u32, scale: f32 = 1, offset := Vec3{}, pool: ^jobs.Pool = nil) {
	triangles := len(indices) / 3
	assert(triangles <= int(max(u32)), "STL counts triangles in 32 bits")
	start := len(out)
	resize(out, start + STL_HEADER + STL_ROW * triangles)
	body := out[start:]
	mem.set(&body[0], ' ', 80)
	copy(body[:80], "Binary STL written by Sculpt")
	(^u32le)(&body[80])^ = u32le(triangles)
	Fill :: struct {
		positions: []Vec3,
		indices:   []u32,
		scale:     f32,
		offset:    Vec3,
		rows:      []u8,
	}
	f := Fill{positions, indices, scale, offset, body[STL_HEADER:]}
	jobs.parallel_ranges(pool, triangles, &f, proc(data: rawptr, lo, hi: int) {
		f := cast(^Fill)data
		for t in lo ..< hi {
			row: [12]f32
			corners: [3]Vec3
			for c in 0 ..< 3 {
				q := f.positions[f.indices[3 * t + c]]
				if f.scale != 1 || f.offset != {} do q = q * f.scale + f.offset // only then, which keeps -0
				corners[c] = q
			}
			n := linalg.cross(corners[1] - corners[0], corners[2] - corners[0])
			if length := linalg.length(n); length > 0 do n /= length
			row[0], row[1], row[2] = n.x, n.y, n.z
			for c in 0 ..< 3 do for k in 0 ..< 3 do row[3 + 3 * c + k] = corners[c][k]
			dst := f.rows[STL_ROW * t:]
			mem.copy(&dst[0], &row, 48)
			dst[48], dst[49] = 0, 0
		}
	}, RANGE_GRAIN)
}

@(private = "file")
int_text :: proc(n: int) -> string {
	buf := make([]u8, 24, context.temp_allocator)
	return strconv.write_int(buf, i64(n), 10)
}

// Writes x with nine significant digits, enough for any f32 to read back exactly,
// without trailing zeros: plain below 1e9 and down to 1e-5, otherwise with an
// exponent. Returns the length; buf needs 16 bytes.
@(private)
format_f32 :: proc(buf: []u8, x: f32) -> int {
	n := 0
	if math.sign_bit(x) {
		buf[0] = '-'
		n = 1
	}
	a := abs(f64(x))
	if a == 0 {
		buf[n] = '0'
		return n + 1
	}
	// Nine digits of a, as an integer in [1e8, 1e9), and the power of ten of the first.
	e := int(math.floor(math.log10(a)))
	if s := scale10(a, 8 - e); s >= 1e9 {
		e += 1
	} else if s < 1e8 {
		e -= 1
	}
	digits := u64(math.round(scale10(a, 8 - e)))
	if digits >= 1_000_000_000 {
		// 999999999.5 and up round to the next power of ten.
		digits /= 10
		e += 1
	}
	d: [9]u8
	for k := 8; k >= 0; k -= 1 {
		d[k] = u8('0' + digits % 10)
		digits /= 10
	}
	nd := 9
	for nd > 1 && d[nd - 1] == '0' do nd -= 1
	switch {
	case e >= 0 && e < 9:
		// Integer part, then any fraction.
		for k in 0 ..= e {
			buf[n] = d[k] if k < nd else '0'
			n += 1
		}
		if nd > e + 1 {
			buf[n] = '.'
			n += 1
			for k in e + 1 ..< nd {
				buf[n] = d[k]
				n += 1
			}
		}
	case e < 0 && e >= -5:
		buf[n], buf[n + 1] = '0', '.'
		n += 2
		for _ in 0 ..< -e - 1 {
			buf[n] = '0'
			n += 1
		}
		for k in 0 ..< nd {
			buf[n] = d[k]
			n += 1
		}
	case:
		buf[n] = d[0]
		n += 1
		if nd > 1 {
			buf[n] = '.'
			n += 1
			for k in 1 ..< nd {
				buf[n] = d[k]
				n += 1
			}
		}
		buf[n] = 'e'
		n += 1
		if e < 0 {
			buf[n] = '-'
			n += 1
		}
		n += format_u32(buf[n:], u32(abs(e)))
	}
	return n
}

// Writes n in decimal and returns the length; buf needs 10 bytes.
@(private)
format_u32 :: proc(buf: []u8, n: u32) -> int {
	tmp: [10]u8
	k := 10
	for v := n; ; v /= 10 {
		k -= 1
		tmp[k] = u8('0' + v % 10)
		if v < 10 do break
	}
	copy(buf, tmp[k:])
	return 10 - k
}

// The powers of ten an f64 holds exactly.
@(private = "file", rodata)
POW10 := [23]f64{1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22}

// a * 10^k, with exact powers of ten where f64 has them.
@(private = "file")
scale10 :: proc(a: f64, k: int) -> f64 {
	v, k := a, k
	for k > 22 {
		v *= 1e22
		k -= 22
	}
	for k < -22 {
		v /= 1e22
		k += 22
	}
	return v * POW10[k] if k >= 0 else v / POW10[-k]
}

// Parses a decimal number ([-+]digits[.digits][e[-+]digits], digits on at least one
// side of the point) at text[at^:], moving at past it. The first nineteen significant
// digits count, then one scaling by a power of ten: exact for anything format_f32
// writes and within an f32 rounding of the true value otherwise.
@(private)
parse_float :: proc(text: []u8, at: ^int) -> (value: f32, ok: bool) {
	i, n := at^, len(text)
	neg := false
	if i < n && (text[i] == '-' || text[i] == '+') {
		neg = text[i] == '-'
		i += 1
	}
	mantissa: u64
	digits, exp := 0, 0
	seen := false
	for i < n && text[i] >= '0' && text[i] <= '9' {
		d := u64(text[i] - '0')
		if digits < 19 {
			if mantissa != 0 || d != 0 {
				mantissa = mantissa * 10 + d
				digits += 1
			}
		} else {
			exp += 1
		}
		seen = true
		i += 1
	}
	if i < n && text[i] == '.' {
		i += 1
		for i < n && text[i] >= '0' && text[i] <= '9' {
			d := u64(text[i] - '0')
			if digits < 19 {
				if mantissa != 0 || d != 0 {
					mantissa = mantissa * 10 + d
					digits += 1
				}
				exp -= 1
			}
			seen = true
			i += 1
		}
	}
	if !seen do return 0, false
	if i < n && (text[i] == 'e' || text[i] == 'E') {
		i += 1
		eneg := false
		if i < n && (text[i] == '-' || text[i] == '+') {
			eneg = text[i] == '-'
			i += 1
		}
		e, any := 0, false
		for i < n && text[i] >= '0' && text[i] <= '9' {
			if e < 100_000 do e = e * 10 + int(text[i] - '0')
			any = true
			i += 1
		}
		if !any do return 0, false
		exp += -e if eneg else e
	}
	at^ = i
	v := f64(mantissa)
	switch {
	case mantissa == 0: v = 0
	case exp < -400: v = 0
	case exp > 400: v = math.inf_f64(1)
	case: v = scale10(v, exp)
	}
	return f32(-v if neg else v), true
}

// Parses [-+]digits at text[at^:], moving at past it.
@(private)
parse_int :: proc(text: []u8, at: ^int) -> (value: i64, ok: bool) {
	i, n := at^, len(text)
	neg := false
	if i < n && (text[i] == '-' || text[i] == '+') {
		neg = text[i] == '-'
		i += 1
	}
	digits := 0
	for i < n && text[i] >= '0' && text[i] <= '9' {
		if digits < 18 do value = value * 10 + i64(text[i] - '0')
		digits += 1
		i += 1
	}
	if digits == 0 || digits > 18 do return 0, false
	at^ = i
	return -value if neg else value, true
}

@(private = "file")
is_blank :: #force_inline proc(c: u8) -> bool {return c == ' ' || c == '\t'}

@(private = "file")
is_space :: #force_inline proc(c: u8) -> bool {return c == ' ' || c == '\t' || c == '\n' || c == '\r'}

@(private = "file")
skip_blanks :: #force_inline proc(text: []u8, at: ^int) {
	for at^ < len(text) && is_blank(text[at^]) do at^ += 1
}

@(private = "file")
skip_space :: #force_inline proc(text: []u8, at: ^int) {
	for at^ < len(text) && is_space(text[at^]) do at^ += 1
}

// Whether a number ending at text[at] ends its token: at the end, before a space or a
// line end, or before a comment.
@(private = "file")
ends_token :: #force_inline proc(text: []u8, at: int) -> bool {
	return at >= len(text) || is_space(text[at]) || text[at] == '#'
}

// Little-endian values in and out of bytes, for the native scene file. Readers check
// every length and turn `ok` false on the first short read, which every later read
// then returns zero for, so a caller checks once at the end of a section.
#assert(ODIN_ENDIAN == .Little)

Byte_Reader :: struct {
	data: []u8,
	at:   int,
	ok:   bool,
}

byte_reader :: proc(data: []u8) -> Byte_Reader {return {data, 0, true}}

byte_put :: proc(out: ^[dynamic]u8, v: $T) {
	v := v
	append(out, ..mem.ptr_to_bytes(&v))
}

byte_put_slice :: proc(out: ^[dynamic]u8, s: []$T) {
	append(out, ..slice.to_bytes(s))
}

byte_put_string :: proc(out: ^[dynamic]u8, s: string) {
	byte_put(out, u32(len(s)))
	append(out, s)
}

byte_get :: proc(r: ^Byte_Reader, $T: typeid) -> (v: T) {
	if !r.ok || len(r.data) - r.at < size_of(T) {
		r.ok = false
		return
	}
	mem.copy(&v, &r.data[r.at], size_of(T))
	r.at += size_of(T)
	return
}

// Fills dst from the next len(dst) values.
byte_get_slice :: proc(r: ^Byte_Reader, dst: []$T) {
	size := len(dst) * size_of(T)
	if !r.ok || len(r.data) - r.at < size {
		r.ok = false
		return
	}
	if size > 0 do mem.copy(raw_data(dst), &r.data[r.at], size)
	r.at += size
}

// The next `size` bytes, to read in place (nil, and `ok` false, when fewer are left).
byte_get_bytes :: proc(r: ^Byte_Reader, size: int) -> []u8 {
	if !r.ok || size < 0 || len(r.data) - r.at < size {
		r.ok = false
		return nil
	}
	b := r.data[r.at:][:size]
	r.at += size
	return b
}

// Grows `out` by `size` bytes and returns them, for the caller to fill in place.
byte_put_bytes :: proc(out: ^[dynamic]u8, size: int) -> []u8 {
	at := len(out)
	non_zero_resize(out, at + size)
	return out[at:]
}

byte_get_string :: proc(r: ^Byte_Reader, allocator := context.allocator) -> string {
	size := int(byte_get(r, u32))
	if !r.ok || len(r.data) - r.at < size {
		r.ok = false
		return ""
	}
	s := strings.clone(string(r.data[r.at:][:size]), allocator)
	r.at += size
	return s
}
