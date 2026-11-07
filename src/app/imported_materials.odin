package main

import "core:fmt"
import "core:strings"

import "../geom"

// The materials an imported file brought with an object: what import made of each (the
// object's own material or a polygroup's, Group_Material), kept so the Material card can
// list them ("In this scene") by the file's names, with the maps the file named. A material
// the file gave nothing but a name (`valued` false: Blender writes an empty glTF material
// when a node graph feeds its shader) is listed but left on the default material, since its
// values are not in the file to take.
Imported_Material :: struct {
	name:   string, // owned: the file's name for it, "" for none
	group:  u16, // the polygroup it is on; 0 for the object's own material
	maps:   [geom.Mesh_Map]string, // owned: the file names of the maps it names, "" for none
	valued: bool,
}

imported_materials_destroy :: proc(list: ^[dynamic]Imported_Material) {
	for &e in list {
		delete(e.name)
		for name in e.maps do delete(name)
	}
	delete(list^)
	list^ = {}
}

// A file's material as a material of the app's: Custom, physically based, with the
// file's colour, metal, roughness and layers. A roughness of 0 would pick the classic
// shading, so a mirror-smooth one is kept just above it.
import_material :: proc(mm: geom.Mesh_Material) -> Material {
	pbr_clay, _ := material_by_name("PBR clay")
	m := MATERIALS[pbr_clay]
	m.label = "Custom"
	m.selected = {mm.color.r, mm.color.g, mm.color.b, 1}
	m.metallic = clamp(mm.metallic, 0, 1)
	m.roughness = clamp(mm.roughness, IMPORT_ROUGHNESS_MIN, 1)
	m.layers = geom.material_layers_clamp(mm.layers)
	return m
}

// The roughness a file's mirror-smooth material takes: the smallest the physically based
// shading keeps (0 means the classic shading).
IMPORT_ROUGHNESS_MIN :: 0.02

// Gives `obj` the materials its part brought (`list`, from geom.mesh_parts_material_groups):
// each valued one as the object's own material (group 0) or its polygroup's, and every one
// in obj.imported. Returns how many the file left without values, for the note.
object_take_imported :: proc(obj: ^Object, list: []geom.Part_Material) -> (unvalued: int) {
	for e in list {
		mm := e.material
		entry := Imported_Material{name = strings.clone(mm.name), group = e.group, valued = mm.valued}
		for name, which in mm.maps do entry.maps[which] = strings.clone(name)
		append(&obj.imported, entry)
		if !mm.valued {
			unvalued += 1
			continue
		}
		m := import_material(mm)
		if e.group == 0 {
			obj.material = m
		} else if why := group_material_set(obj, e.group, m); why != "" {
			fmt.eprintfln("import: %s", why)
		}
	}
	return
}

// The scene file's form of obj.imported (object_put), a record (tags are never reused or
// retyped, geom/record.odin) of an entry each: its name, group, whether it was valued and
// its maps' names.
Imported_Tag :: enum u16 {
	Entry = 1, // Imported_Entry_Tag record
}

Imported_Entry_Tag :: enum u16 {
	Name        = 1, // text
	Group       = 2, // u16
	Valued      = 3, // u8
	Base_Color  = 4, // text: the map's file name
	Metal_Rough = 5, // text
	Normal      = 6, // text
}

// The field of each map's name.
@(private = "file")
IMPORTED_MAP_TAGS := [geom.Mesh_Map]Imported_Entry_Tag {
	.Base_Color  = .Base_Color,
	.Metal_Rough = .Metal_Rough,
	.Normal      = .Normal,
}

imported_put :: proc(out: ^[dynamic]u8, obj: ^Object) {
	rec := geom.record_begin(out)
	defer geom.record_end(out, rec)
	for e in obj.imported {
		at := geom.rec_begin(out, Imported_Tag.Entry)
		geom.rec_put_string(out, Imported_Entry_Tag.Name, e.name)
		geom.rec_put(out, Imported_Entry_Tag.Group, e.group)
		geom.rec_put(out, Imported_Entry_Tag.Valued, u8(e.valued))
		for name, m in e.maps do if name != "" do geom.rec_put_string(out, IMPORTED_MAP_TAGS[m], name)
		geom.rec_end(out, at)
	}
}

// Reads what imported_put writes; r.ok goes false on a count or flag no object has.
imported_get :: proc(r: ^geom.Byte_Reader, obj: ^Object) {
	rec := geom.record_take(r)
	known, _ := geom.record_known(&rec, Imported_Tag)
	n := geom.rec_count(&rec, Imported_Tag.Entry)
	if !rec.ok || !known || n > IMPORTED_MATERIALS_MAX {
		r.ok = false
		return
	}
	at := 0
	for _ in 0 ..< n {
		payload, _ := geom.rec_next(&rec, Imported_Tag.Entry, &at)
		er := geom.record_of(payload)
		e := Imported_Material{name = geom.rec_get_string(&er, Imported_Entry_Tag.Name)}
		e.group = geom.rec_get(&er, Imported_Entry_Tag.Group, u16, 0)
		valued := geom.rec_get(&er, Imported_Entry_Tag.Valued, u8, 0)
		e.valued = valued == 1
		for &name, m in e.maps do name = geom.rec_get_string(&er, IMPORTED_MAP_TAGS[m])
		append(&obj.imported, e)
		if !er.ok || valued > 1 || int(e.group) > geom.PART_MATERIALS_MAX {
			r.ok = false
			return
		}
	}
}

// The most imported materials an object lists: its own and one a polygroup.
IMPORTED_MATERIALS_MAX :: geom.PART_MATERIALS_MAX + 1
