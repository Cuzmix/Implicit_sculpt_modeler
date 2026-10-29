package fbx

import "core:c"
import "core:path/slashpath"
import "core:strings"

import "../geom"

// FBX in through ufbx (deps/ufbx-src at UFBX_TAG in scripts/versions.env, MIT or public
// domain), which reads every FBX version, binary and text, as Blender 4.5's importer
// does. The app's shim (fbx_shim.c) holds ufbx's large structs on the C side, so this
// binding is six calls. Knows nothing of the app, rendering or the interface; the
// caller reads the file.

FBX_BINARY_MAGIC :: "Kaydara FBX Binary"

// Whether `data` looks like an FBX file: the binary header, or the text form's
// FBXHeaderExtension near its start (after its comment lines).
recognised :: proc(data: []u8) -> bool {
	if strings.has_prefix(string(data), FBX_BINARY_MAGIC) do return true
	head := string(data[:min(len(data), 4096)])
	return strings.contains(head, "FBXHeaderExtension:")
}

// The longest reason a failed read gives.
ERROR_MAX :: 256

Scene :: struct {}

when ODIN_OS == .Windows {
	// Built with /MT, as the app is.
	foreign import lib "../../deps/ufbx/ufbx.lib"
} else when ODIN_PLATFORM_SUBTARGET == .Android || ODIN_PLATFORM_SUBTARGET == .iPhone {
	// Android's CMakeLists and `build.sh ios` compile fbx_shim.c and link it with the
	// app's object themselves.
	foreign import lib "system:ufbx"
} else {
	foreign import lib {"../../deps/ufbx/libufbx.a", "system:m"}
}

@(default_calling_convention = "c")
foreign lib {
	sculpt_fbx_load :: proc(data: rawptr, size: c.size_t, error: [^]u8, error_size: c.size_t) -> ^Scene ---
	sculpt_fbx_part_count :: proc(f: ^Scene) -> c.size_t ---
	sculpt_fbx_material_count :: proc(f: ^Scene) -> c.size_t ---
	sculpt_fbx_material :: proc(f: ^Scene, k: c.size_t, color: ^[3]f32, texture_file: ^i32) ---
	sculpt_fbx_texture_file_count :: proc(f: ^Scene) -> c.size_t ---
	sculpt_fbx_texture_file :: proc(f: ^Scene, k: c.size_t, content: ^rawptr, content_size: ^c.size_t, relative: ^[^]u8, relative_len: ^c.size_t, absolute: ^[^]u8, absolute_len: ^c.size_t) ---
	sculpt_fbx_part_size :: proc(f: ^Scene, part: c.size_t, name: ^[^]u8, name_len: ^c.size_t, vertices, triangles: ^c.size_t, colors, groups, uvs: ^bool) ---
	sculpt_fbx_part_fill :: proc(f: ^Scene, part: c.size_t, positions: [^]f32, indices: [^]u32, colors: [^]u8, groups: [^]u16, materials: [^]i32, uvs: [^]f32) -> bool ---
	sculpt_fbx_free :: proc(f: ^Scene) ---
}

// Reads an FBX file's meshes as parts appended to `parts`: one for each node that holds
// a mesh, placed in the scene Y up and in metres, with its vertex colours, a group for
// each material when it has several, and, given a `look`, its materials' base colours
// and textures (embedded in the file, or files beside it that `resolve` gives) for the
// paint. A file ufbx refuses is Not_Recognised, with ufbx's reason in `reason` (temp
// memory); a file with no mesh is Empty.
read :: proc(parts: ^[dynamic]geom.Mesh_Part, data: []u8, look: ^geom.Mesh_Look = nil, resolve: geom.Mesh_Resolve = nil, resolve_data: rawptr = nil) -> (err: geom.Mesh_File_Error, reason: string) {
	if len(data) == 0 do return .Empty, ""
	message := make([]u8, ERROR_MAX, context.temp_allocator)
	scene := sculpt_fbx_load(raw_data(data), c.size_t(len(data)), raw_data(message), c.size_t(len(message)))
	if scene == nil do return .Not_Recognised, string(cstring(raw_data(message)))
	defer sculpt_fbx_free(scene)

	material_base := 0
	if look != nil {
		material_base = len(look.materials)
		image_base := len(look.images)
		for k in 0 ..< int(sculpt_fbx_texture_file_count(scene)) {
			content: rawptr
			content_size: c.size_t
			relative, absolute: [^]u8
			relative_len, absolute_len: c.size_t
			sculpt_fbx_texture_file(scene, c.size_t(k), &content, &content_size, &relative, &relative_len, &absolute, &absolute_len)
			bytes: []u8
			if content != nil {
				// The scene, which holds it, is freed when the read returns, before the
				// caller paints, so it is copied to temp memory.
				bytes = make([]u8, int(content_size), context.temp_allocator)
				copy(bytes, ([^]u8)(content)[:content_size])
			} else if resolve != nil {
				bytes = texture_beside(string(relative[:relative_len]), string(absolute[:absolute_len]), resolve, resolve_data)
			}
			append(&look.images, geom.Mesh_Image{bytes = bytes})
		}
		for k in 0 ..< int(sculpt_fbx_material_count(scene)) {
			m := geom.Mesh_Material{image = -1}
			file: i32
			sculpt_fbx_material(scene, c.size_t(k), &m.color, &file)
			if file >= 0 && image_base + int(file) < len(look.images) do m.image = image_base + int(file)
			append(&look.materials, m)
		}
	}

	count := int(sculpt_fbx_part_count(scene))
	for k in 0 ..< count {
		name: [^]u8
		name_len, vertices, triangles: c.size_t
		colored, grouped, textured: bool
		sculpt_fbx_part_size(scene, c.size_t(k), &name, &name_len, &vertices, &triangles, &colored, &grouped, &textured)
		if int(vertices) >= int(max(u32)) || int(triangles) > int(max(u32)) / 3 do return .Too_Large, ""
		part := geom.Mesh_Part{name = strings.clone(string(name[:name_len]))}
		resize(&part.mesh.positions, int(vertices))
		resize(&part.mesh.normals, int(vertices))
		resize(&part.mesh.indices, 3 * int(triangles))
		if colored do resize(&part.colors, int(vertices))
		if grouped do resize(&part.groups, int(triangles))
		if look != nil {
			resize(&part.materials, int(triangles))
			if textured do resize(&part.uvs, 3 * int(triangles))
		}
		ok := sculpt_fbx_part_fill(scene, c.size_t(k), ([^]f32)(raw_data(part.mesh.positions)), raw_data(part.mesh.indices), ([^]u8)(raw_data(part.colors)) if colored else nil, raw_data(part.groups) if grouped else nil, raw_data(part.materials) if look != nil else nil, ([^]f32)(raw_data(part.uvs)) if textured && look != nil else nil)
		if !ok {
			geom.mesh_part_destroy(&part)
			return .Too_Large, "out of memory"
		}
		for &m in part.materials do if m >= 0 do m += i32(material_base)
		append(parts, part)
	}
	if len(parts) == 0 do return .Empty, ""
	return .None, ""
}

// The bytes of a texture the file names but does not hold: by its relative path, by
// its absolute one's name, beside the file.
@(private = "file")
texture_beside :: proc(relative, absolute: string, resolve: geom.Mesh_Resolve, resolve_data: rawptr) -> []u8 {
	tries := [3]string{relative, slashpath.base(slashes(relative)), slashpath.base(slashes(absolute))}
	for path in tries {
		if path == "" || path == "." || path == "/" do continue
		if bytes, ok := resolve(resolve_data, slashes(path)); ok do return bytes
	}
	return nil
}

@(private = "file")
slashes :: proc(path: string) -> string {
	out, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	return out
}
