package main

import "core:image"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import "../geom"
import "../hdri"
import "../sculpt"

// Maps in (the Detail skin section's Load map into skin...): a displacement or vector
// displacement image read into the selected object's skin through its UVs. The skin's
// side is sculpt/skin_map.odin.

// What the image is, as the Detail skin section's MAP IS tabs pick it.
SKIN_MAP_KIND_NAMES := [sculpt.Skin_Map_Kind]string {
	.Height         = "Height",
	.Tangent_Vector = "Vector",
	.Object_Vector  = "Vector, object",
}

// Why the selected object's skin cannot take a map now, or "" when it can.
skin_map_refusal :: proc(obj: ^Object) -> string {
	switch {
	case obj == nil: return "Select an object first."
	case object_top_skin(obj) == nil: return "Give it a detail skin first."
	case !sculpt.levels_has_quad_uvs(&obj.levels): return "It needs quads with UVs: Quad Remesh makes an object with them."
	case len(obj.levels.levels) != 1: return "Its UVs are its base level's: delete the levels above first."
	}
	return ""
}

// Reads the image at `path` into the selected object's skin, as one undo step, as
// app.skin_map_kind says it is. A grey PNG (8 or 16 bits) is a height, its middle grey
// the surface and black and white skin_map_range in and out, unless a text file beside it
// gives that distance as the bake's NAME_displacement.txt does; an OpenEXR file holds
// distances (a height in its first channel, or an offset in all three) as they are, all
// in the units of the OBJ the bake writes beside them.
skin_map_load :: proc(app: ^App, path: string) -> bool {
	name := filepath.base(path)
	obj := selected_object(app)
	if why := skin_map_refusal(obj); why != "" {
		file_note(app, true, "Cannot load %s into the skin: %s", name, why)
		return false
	}
	data, err := file_read_any(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot load %s into the skin: %v", name, err)
		return false
	}
	defer delete(data)
	m := sculpt.Skin_Map{kind = app.skin_map_kind, scale = 1}
	if hdri.exr_is(data) {
		img, why := hdri.exr_decode_picture(data, hdri.MAX_SIDE, context.temp_allocator)
		if why != "" {
			file_note(app, true, "Cannot load %s into the skin: %s", name, why)
			return false
		}
		m.width, m.height, m.pixels = img.width, img.height, img.pixels
	} else {
		if m.kind != .Height {
			file_note(app, true, "Cannot load %s into the skin: a vector map is an OpenEXR file", name)
			return false
		}
		img, img_err := image.load_from_bytes(data)
		if img_err != nil {
			file_note(app, true, "Cannot load %s into the skin: %v (PNG and OpenEXR maps work)", name, img_err)
			return false
		}
		defer image.destroy(img)
		grey := make([]f32, img.width * img.height, context.temp_allocator)
		if !image_grey(img, grey) {
			file_note(app, true, "Cannot load %s into the skin: %d-bit channels are not supported", name, img.depth)
			return false
		}
		m.width, m.height = img.width, img.height
		m.pixels = make([][3]f32, len(grey), context.temp_allocator)
		for g, i in grey do m.pixels[i] = {g, g, g}
		m.mid = 0.5
		m.scale = 2 * skin_map_range_beside(path, app.skin_map_range)
	}
	// Files hold distances in the OBJ's units (the bake writes them so), the skin the mesh's.
	if obj.file.scale > 0 do m.scale /= obj.file.scale
	uvs, ok := sculpt.levels_tri_uvs(&obj.levels, context.temp_allocator)
	if !ok {
		file_note(app, true, "Cannot load %s into the skin: its quads do not match its triangles", name)
		return false
	}
	stroke_finish(app)
	if !sculpt.sculptor_skin_from_map(object_sculptor(obj), m, uvs) {
		file_note(app, true, "Cannot load %s into the skin of %s", name, object_label(obj))
		return false
	}
	history_record(app, obj, .Deform, "Map into skin")
	app.skin_maps_loaded += 1
	report(app, Kit_Section.Hd, {.Undo}, "Read %s (%d by %d, %s) into the skin of %s", name, m.width, m.height, SKIN_MAP_KIND_NAMES[m.kind], object_label(obj))
	return true
}

// The distance black and white stand for: the number a bake's NAME_displacement.txt
// beside a NAME_displacement.png gives ("... are D units in and out ..."), else `fallback`.
@(private = "file")
skin_map_range_beside :: proc(path: string, fallback: f32) -> f32 {
	text_path := strings.concatenate({strings.trim_suffix(path, filepath.ext(path)), ".txt"}, context.temp_allocator)
	data, err := file_read_any(text_path, context.temp_allocator)
	if err != nil do return fallback
	text := string(data)
	at := strings.index(text, " are ")
	if at < 0 do return fallback
	rest := text[at + 5:]
	end := strings.index_byte(rest, ' ')
	if end < 0 do return fallback
	d, ok := strconv.parse_f32(rest[:end])
	return d if ok && d > 0 else fallback
}

// Writes the selected object's skin to `path` as an NVIDIA displacement micro-map
// (geom.bary_encode): the top level's triangles with their vertex normals as the
// directions, in the units and place an OBJ export gives them, each triangle subdivided
// as the skin is. A vector page cannot go into a scalar map; the note says it was left out.
skin_bary_export :: proc(app: ^App, path: string) -> bool {
	name := filepath.base(path)
	obj := selected_object(app)
	if object_top_skin(obj) == nil {
		file_note(app, true, "Cannot export %s: select an object with a detail skin first", name)
		return false
	}
	stroke_finish(app)
	top := &obj.levels.levels[len(obj.levels.levels) - 1].sculptor
	values, level, folded, ok := sculpt.sculptor_skin_bary(top, context.temp_allocator)
	if !ok {
		file_note(app, true, "Cannot export %s: the skin's segments are not a power of two", name)
		return false
	}
	mesh := top.mesh
	scale := obj.file.scale if obj.file.scale > 0 else 1
	positions := make([]geom.Vec3, len(mesh.positions), context.temp_allocator)
	for p, i in mesh.positions do positions[i] = p * scale + obj.file.position
	for &v in values do v *= scale
	data := geom.bary_encode({positions = positions, directions = mesh.normals[:], indices = mesh.indices[:], level = level, values = values}, context.temp_allocator)
	if data == nil {
		file_note(app, true, "Cannot export %s: the mesh and its skin do not match", name)
		return false
	}
	if failed := write_durably(path, data); failed != "" {
		file_note(app, true, "Cannot export %s: %s", name, failed)
		return false
	}
	app.skin_bary_exports += 1
	file_note(app, folded, "Exported %s: %s triangles at level %d (%d segments)%s", name, count_label(len(mesh.indices) / 3), level, 1 << level, ", without the skin's sideways offsets, which a micro-map cannot hold" if folded else "")
	return true
}
