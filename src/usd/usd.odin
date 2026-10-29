package usd

import "core:bytes"
import "core:strings"

import "../geom"
import "../zip"

// USD in: its text form (.usda), its binary crate (.usdc) and a .usdz package of either,
// read into one Stage (stage.odin) whose Mesh prims become parts. Knows nothing of the
// app, rendering or the interface; the caller reads the file.

USDC_MAGIC :: "PXR-USDC"

// Whether `data` looks like a USD file of any form: the text's or crate's first bytes,
// or a ZIP archive whose first entry is a layer (as a .usdz starts).
recognised :: proc(data: []u8) -> bool {
	if bytes.has_prefix(data, transmute([]u8)string(USDA_MAGIC)) || bytes.has_prefix(data, transmute([]u8)string(USDC_MAGIC)) do return true
	if !bytes.has_prefix(data, []u8{'P', 'K', 3, 4}) || len(data) < 30 do return false
	name_len := int(data[26]) | int(data[27]) << 8
	if 30 + name_len > len(data) do return false
	name := strings.to_lower(string(data[30:][:name_len]), context.temp_allocator)
	return strings.has_suffix(name, ".usda") || strings.has_suffix(name, ".usdc") || strings.has_suffix(name, ".usd")
}

// The most a .usdz may unpack to, and how many files it may hold: a package of one
// large mesh and its textures, with room to spare.
USDZ_LIMITS :: zip.Limits{entries = 4096, total = 4 << 30}

// Reads a USD file's meshes as parts appended to `parts`. `line` names the line of a
// text file's error (0 for none). A file with no mesh is Empty.
read :: proc(parts: ^[dynamic]geom.Mesh_Part, data: []u8) -> (skipped: Skipped, err: geom.Mesh_File_Error, line: int) {
	layer := data
	if bytes.has_prefix(data, []u8{'P', 'K'}) {
		// A .usdz: its first layer, as USD takes it (the rest are textures and layers it
		// may refer to, which are not followed).
		entries, zerr := zip.entries(data, USDZ_LIMITS, context.temp_allocator)
		if zerr != .None do return {}, .Not_Recognised, 0
		found := false
		for e in entries {
			name := strings.to_lower(e.name, context.temp_allocator)
			if !(strings.has_suffix(name, ".usda") || strings.has_suffix(name, ".usdc") || strings.has_suffix(name, ".usd")) do continue
			bytes, rerr := zip.read(data, e, context.temp_allocator)
			if rerr != .None do return {}, .Truncated, 0
			layer, found = bytes, true
			break
		}
		if !found do return {}, .Empty, 0
	}
	s: Stage
	s.prims = make([dynamic]Prim, context.temp_allocator)
	switch {
	case bytes.has_prefix(layer, transmute([]u8)string(USDA_MAGIC)):
		err, line = read_usda(&s, layer)
	case bytes.has_prefix(layer, transmute([]u8)string(USDC_MAGIC)):
		err = read_usdc(&s, layer)
	case:
		err = .Not_Recognised
	}
	if err != .None do return
	before := len(parts)
	err = stage_parts(&s, parts, &skipped)
	if err == .None && len(parts) == before do err = .Empty
	return
}
