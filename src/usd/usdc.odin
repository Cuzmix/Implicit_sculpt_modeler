package usd

import "core:math"
import "core:slice"
import "core:strings"

import "../geom"

// USD's binary crate (.usdc, versions 0.4 to 0.x) into a Stage: the bootstrap header and
// its table of sections; TOKENS (LZ4 through TfFastCompression's chunks), STRINGS,
// FIELDS, FIELDSETS, PATHS (the compressed tree) and SPECS, their integer lists in USD's
// integer coding; then each spec's fields as ValueReps. Only the values a mesh needs
// are decoded (numbers, vectors and matrices as scalars and arrays, compressed int and
// float arrays included, tokens, strings, token vectors, specifiers, time samples);
// the rest are passed over. Every offset and size is checked against the file before it
// is followed, and every decoder against the room it was given, so a damaged file is
// refused, never trusted.

read_usdc :: proc(s: ^Stage, data: []u8) -> geom.Mesh_File_Error {
	c := Crate{data = data}
	if len(data) < 88 do return .Truncated
	c.major, c.minor = int(data[8]), int(data[9])
	if c.major != 0 || c.minor < 4 do return .Not_Recognised
	toc, ok := crate_u64(&c, 16)
	if !ok do return .Truncated
	count, count_ok := crate_u64(&c, int(toc))
	if !count_ok || count > 64 do return .Bad_Structure
	sections: [6]struct {
		start, size: int,
	}
	NAMES :: [6]string{"TOKENS", "STRINGS", "FIELDS", "FIELDSETS", "PATHS", "SPECS"}
	for k in 0 ..< int(count) {
		at := int(toc) + 8 + 32 * k
		if at + 32 > len(data) do return .Truncated
		name := string(data[at:][:16])
		if zero := strings.index_byte(name, 0); zero >= 0 do name = name[:zero]
		start, _ := crate_u64(&c, at + 16)
		size, _ := crate_u64(&c, at + 24)
		if start > u64(len(data)) || size > u64(len(data)) - start do return .Truncated
		for want, i in NAMES do if name == want do sections[i] = {int(start), int(size)}
	}
	for sec in sections do if sec.size == 0 do return .Bad_Structure

	crate_tokens(&c, sections[0].start) or_return
	crate_strings(&c, sections[1].start) or_return
	crate_fields(&c, sections[2].start) or_return
	crate_fieldsets(&c, sections[3].start) or_return
	crate_paths(&c, sections[4].start) or_return
	return crate_specs(&c, s, sections[5].start)
}

@(private = "file")
Crate :: struct {
	data:         []u8,
	major, minor: int,
	tokens:       []string,
	strings:      []u32, // token indices
	field_names:  []u32,
	field_reps:   []u64,
	fieldsets:    []u32,
	// The paths, each its parent's index (-1 for the root), its last element and whether
	// that names a property.
	path_parent:  []i32,
	path_name:    []string,
	path_prop:    []bool,
}

@(private = "file")
crate_u64 :: proc(c: ^Crate, at: int) -> (u64, bool) {
	if at < 0 || at + 8 > len(c.data) do return 0, false
	return u64((^u64le)(&c.data[at])^), true
}

// TfFastCompression's buffer: a chunk count, then one LZ4 block (count 0) or that many
// blocks each after its i32 size, into exactly `size` bytes.
@(private = "file")
fast_decompress :: proc(src: []u8, size: int) -> (out: []u8, ok: bool) {
	if len(src) < 1 || size < 0 || size > 1 << 34 do return nil, false
	out = make([]u8, size, context.temp_allocator)
	chunks := int(src[0])
	if chunks == 0 {
		n := lz4_block(src[1:], out) or_return
		return out, n == size
	}
	at, written := 1, 0
	for _ in 0 ..< chunks {
		if at + 4 > len(src) do return nil, false
		block := int(i32((^i32le)(&src[at])^))
		at += 4
		if block < 0 || block > len(src) - at do return nil, false
		n := lz4_block(src[at:][:block], out[written:]) or_return
		at += block
		written += n
	}
	return out, written == size
}

// Decodes one LZ4 block into `out`, returning how many bytes it wrote; false when the
// block runs past its input, points before its output, or would overflow `out`.
@(private)
lz4_block :: proc(src: []u8, out: []u8) -> (written: int, ok: bool) {
	at, o := 0, 0
	for at < len(src) {
		token := src[at]
		at += 1
		literals := int(token >> 4)
		if literals == 15 {
			for {
				if at >= len(src) do return 0, false
				b := src[at]
				at += 1
				literals += int(b)
				if b != 255 do break
			}
		}
		if literals > len(src) - at || literals > len(out) - o do return 0, false
		copy(out[o:], src[at:][:literals])
		at += literals
		o += literals
		// The last sequence has literals only.
		if at >= len(src) do break
		if at + 2 > len(src) do return 0, false
		offset := int(src[at]) | int(src[at + 1]) << 8
		at += 2
		match := int(token & 15)
		if match == 15 {
			for {
				if at >= len(src) do return 0, false
				b := src[at]
				at += 1
				match += int(b)
				if b != 255 do break
			}
		}
		match += 4
		if offset == 0 || offset > o || match > len(out) - o do return 0, false
		// Byte by byte: a match may overlap what it copies.
		for k in 0 ..< match do out[o + k] = out[o - offset + k]
		o += match
	}
	return o, true
}

// USD's integer coding of `count` integers of `width` bytes (4 or 8), compressed: the
// buffer's size, then its TfFastCompression bytes, which hold the most common delta,
// two bits a value saying how wide its delta is, then the deltas. Returns the integers
// as i64 and where the buffer ended.
@(private = "file")
crate_ints :: proc(c: ^Crate, at: int, count: int, width: int) -> (out: []i64, end: int, ok: bool) {
	size := crate_u64(c, at) or_return
	if size > u64(len(c.data) - at - 8) || count < 0 || count > len(c.data) * 4 do return nil, 0, false
	// The decoded size is at most the common value, the codes, and a full width a value.
	raw := make([]u8, width + (2 * count + 7) / 8 + width * count, context.temp_allocator)
	written := fast_decompress_into(c.data[at + 8:][:size], raw) or_return
	raw = raw[:written]
	out = decode_ints(raw, count, width) or_return
	return out, at + 8 + int(size), true
}

// fast_decompress into a buffer that may be larger than what it holds.
@(private = "file")
fast_decompress_into :: proc(src: []u8, out: []u8) -> (written: int, ok: bool) {
	if len(src) < 1 do return 0, false
	chunks := int(src[0])
	if chunks == 0 do return lz4_block(src[1:], out)
	at := 1
	for _ in 0 ..< chunks {
		if at + 4 > len(src) do return 0, false
		block := int(i32((^i32le)(&src[at])^))
		at += 4
		if block < 0 || block > len(src) - at do return 0, false
		n := lz4_block(src[at:][:block], out[written:]) or_return
		at += block
		written += n
	}
	return written, true
}

@(private = "file")
decode_ints :: proc(raw: []u8, count: int, width: int) -> (out: []i64, ok: bool) {
	codes_bytes := (2 * count + 7) / 8
	if len(raw) < width + codes_bytes do return nil, false
	read :: proc(raw: []u8, at: ^int, size: int) -> (v: i64, ok: bool) {
		if at^ + size > len(raw) do return 0, false
		switch size {
		case 1: v = i64(cast(i8)raw[at^])
		case 2: v = i64(i16((^i16le)(&raw[at^])^))
		case 4: v = i64(i32((^i32le)(&raw[at^])^))
		case 8: v = i64((^i64le)(&raw[at^])^)
		}
		at^ += size
		return v, true
	}
	at := 0
	common := read(raw, &at, width) or_return
	codes := at
	at += codes_bytes
	// Small, medium and large deltas: 1, 2, 4 bytes for 32-bit values, 2, 4, 8 for 64.
	sizes := [4]int{0, 1, 2, 4} if width == 4 else [4]int{0, 2, 4, 8}
	out = make([]i64, count, context.temp_allocator)
	prev: i64
	for i in 0 ..< count {
		code := (raw[codes + i / 4] >> uint(2 * (i % 4))) & 3
		delta := common if code == 0 else (read(raw, &at, sizes[code]) or_return)
		prev += delta
		// 32-bit values wrap as their type does.
		if width == 4 do prev = i64(i32(prev))
		out[i] = prev
	}
	return out, true
}

@(private = "file")
crate_tokens :: proc(c: ^Crate, at: int) -> geom.Mesh_File_Error {
	count := crate_u64(c, at) or_else max(u64)
	size := crate_u64(c, at + 8) or_else max(u64)
	packed := crate_u64(c, at + 16) or_else max(u64)
	if count > u64(len(c.data)) || size > 1 << 32 || packed > u64(len(c.data) - at - 24) do return .Truncated
	text := fast_decompress(c.data[at + 24:][:packed], int(size)) or_else nil
	if text == nil do return .Bad_Structure
	c.tokens = make([]string, count, context.temp_allocator)
	start := 0
	for k in 0 ..< int(count) {
		zero := slice.linear_search(text[start:], 0) or_else -1
		if zero < 0 do return .Bad_Structure
		c.tokens[k] = string(text[start:][:zero])
		start += zero + 1
	}
	return .None
}

@(private = "file")
crate_strings :: proc(c: ^Crate, at: int) -> geom.Mesh_File_Error {
	count := crate_u64(c, at) or_else max(u64)
	if count > u64(len(c.data) - at - 8) / 4 do return .Truncated
	c.strings = make([]u32, count, context.temp_allocator)
	for k in 0 ..< int(count) do c.strings[k] = u32((^u32le)(&c.data[at + 8 + 4 * k])^)
	return .None
}

@(private = "file")
crate_fields :: proc(c: ^Crate, at: int) -> geom.Mesh_File_Error {
	count := crate_u64(c, at) or_else max(u64)
	if count > u64(len(c.data)) do return .Truncated
	names, end, ok := crate_ints(c, at + 8, int(count), 4)
	if !ok do return .Bad_Structure
	c.field_names = make([]u32, count, context.temp_allocator)
	for n, k in names do c.field_names[k] = u32(n)
	size := crate_u64(c, end) or_else max(u64)
	if size > u64(len(c.data) - end - 8) do return .Truncated
	reps := fast_decompress(c.data[end + 8:][:size], 8 * int(count)) or_else nil
	if reps == nil do return .Bad_Structure
	c.field_reps = make([]u64, count, context.temp_allocator)
	for k in 0 ..< int(count) do c.field_reps[k] = u64((^u64le)(&reps[8 * k])^)
	return .None
}

@(private = "file")
crate_fieldsets :: proc(c: ^Crate, at: int) -> geom.Mesh_File_Error {
	count := crate_u64(c, at) or_else max(u64)
	if count > u64(len(c.data)) do return .Truncated
	sets, _, ok := crate_ints(c, at + 8, int(count), 4)
	if !ok do return .Bad_Structure
	c.fieldsets = make([]u32, count, context.temp_allocator)
	for x, k in sets do c.fieldsets[k] = u32(x)
	return .None
}

// The path tree, written depth first: each entry's jump says whether a child follows it
// (> 0 or -1) and where its next sibling is (>= 0: that many entries on).
@(private = "file")
crate_paths :: proc(c: ^Crate, at: int) -> geom.Mesh_File_Error {
	total := crate_u64(c, at) or_else max(u64)
	encoded := crate_u64(c, at + 8) or_else max(u64)
	if total > u64(len(c.data)) || encoded > total do return .Truncated
	n := int(encoded)
	indices, end, ok := crate_ints(c, at + 16, n, 4)
	if !ok do return .Bad_Structure
	elements, end2, ok2 := crate_ints(c, end, n, 4)
	if !ok2 do return .Bad_Structure
	jumps, _, ok3 := crate_ints(c, end2, n, 4)
	if !ok3 do return .Bad_Structure
	c.path_parent = make([]i32, total, context.temp_allocator)
	c.path_name = make([]string, total, context.temp_allocator)
	c.path_prop = make([]bool, total, context.temp_allocator)
	slice.fill(c.path_parent, -2) // not reached
	Pending :: struct {
		index:  int,
		parent: i32, // a path index, -1 for none yet (the root comes first)
	}
	stack := make([dynamic]Pending, context.temp_allocator)
	append(&stack, Pending{0, -1})
	for len(stack) > 0 {
		p := pop(&stack)
		cur, parent := p.index, p.parent
		for {
			if cur < 0 || cur >= n do return .Bad_Structure
			this := cur
			cur += 1
			path := int(indices[this])
			if path < 0 || path >= int(total) || c.path_parent[path] != -2 do return .Bad_Structure
			if parent < 0 && this == 0 {
				c.path_parent[path] = -1
			} else {
				token := elements[this]
				prop := token < 0
				token = abs(token)
				if token >= i64(len(c.tokens)) || parent < 0 do return .Bad_Structure
				c.path_parent[path], c.path_name[path], c.path_prop[path] = parent, c.tokens[token], prop
			}
			jump := jumps[this]
			child := jump > 0 || jump == -1
			sibling := jump >= 0
			if child {
				if sibling do append(&stack, Pending{this + int(jump), parent})
				parent = i32(path)
			}
			if !child && !sibling do break
		}
	}
	return .None
}

// Spec types the stage reads.
@(private = "file")
SPEC_ATTRIBUTE :: 1
@(private = "file")
SPEC_PRIM :: 6
@(private = "file")
SPEC_PSEUDO_ROOT :: 7

// Crate value types the stage reads (crateDataTypes.h).
@(private = "file")
Crate_Type :: enum u8 {
	Invalid      = 0,
	Bool         = 1,
	UChar        = 2,
	Int          = 3,
	UInt         = 4,
	Int64        = 5,
	UInt64       = 6,
	Half         = 7,
	Float        = 8,
	Double       = 9,
	String       = 10,
	Token        = 11,
	Asset_Path   = 12,
	Matrix2d     = 13,
	Matrix3d     = 14,
	Matrix4d     = 15,
	Quatd        = 16,
	Quatf        = 17,
	Quath        = 18,
	Vec2d        = 19,
	Vec2f        = 20,
	Vec2h        = 21,
	Vec2i        = 22,
	Vec3d        = 23,
	Vec3f        = 24,
	Vec3h        = 25,
	Vec3i        = 26,
	Vec4d        = 27,
	Vec4f        = 28,
	Vec4h        = 29,
	Vec4i        = 30,
	Token_Vector = 41,
	Specifier    = 42,
	Time_Samples = 46,
	Double_Vector = 48,
	String_Vector = 50,
	Value_Block  = 51,
}

@(private = "file")
crate_specs :: proc(c: ^Crate, s: ^Stage, at: int) -> geom.Mesh_File_Error {
	count := crate_u64(c, at) or_else max(u64)
	if count > u64(len(c.data)) do return .Truncated
	n := int(count)
	paths, end, ok := crate_ints(c, at + 8, n, 4)
	if !ok do return .Bad_Structure
	sets, end2, ok2 := crate_ints(c, end, n, 4)
	if !ok2 do return .Bad_Structure
	types, _, ok3 := crate_ints(c, end2, n, 4)
	if !ok3 do return .Bad_Structure
	// Each path's prim, made the first time it or one below it is met, parents first.
	prim_of := make([]i32, len(c.path_parent), context.temp_allocator)
	slice.fill(prim_of, -2)
	for k in 0 ..< n {
		path := int(paths[k])
		if path < 0 || path >= len(c.path_parent) do return .Bad_Structure
		set := int(sets[k])
		switch types[k] {
		case SPEC_PSEUDO_ROOT:
			for f in crate_fieldset(c, set) or_else nil {
				switch c.tokens[c.field_names[f]] {
				case "upAxis":
					if up, is := crate_value(c, c.field_reps[f]).(string); is do s.up_z = up == "Z"
				case "metersPerUnit":
					if m := prop_f64(crate_value(c, c.field_reps[f])); len(m) == 1 do s.meters_per_unit = m[0]
				}
			}
		case SPEC_PRIM:
			prim := crate_prim(c, s, prim_of, path)
			if prim < 0 do continue
			p := &s.prims[prim]
			for f in crate_fieldset(c, set) or_else nil {
				rep := c.field_reps[f]
				switch c.tokens[c.field_names[f]] {
				case "specifier":
					// SdfSpecifier: def, over, class.
					x := int(rep & 0xFFFF_FFFF)
					p.specifier = .Def if x == 0 else (.Over if x == 1 else .Class)
				case "typeName":
					if t, is := crate_value(c, rep).(string); is do p.type_name = t
				case "active":
					if a, is := crate_value(c, rep).(bool); is do p.active = a
				case "instanceable":
					if a, is := crate_value(c, rep).(bool); is && a do p.composed = true
				case "references", "payload", "variantSetNames", "inherits", "specializes":
					p.composed = true
				}
			}
		case SPEC_ATTRIBUTE:
			parent := int(c.path_parent[path])
			if parent < 0 || !c.path_prop[path] do continue
			prim := crate_prim(c, s, prim_of, parent)
			if prim < 0 do continue
			prop: Prop
			sampled: Value
			for f in crate_fieldset(c, set) or_else nil {
				rep := c.field_reps[f]
				switch c.tokens[c.field_names[f]] {
				case "typeName":
					if t, is := crate_value(c, rep).(string); is do prop.type_name = t
				case "default":
					prop.value = crate_value(c, rep)
				case "timeSamples":
					sampled = crate_first_sample(c, rep)
				case "interpolation":
					if t, is := crate_value(c, rep).(string); is do prop.interpolation = t
				}
			}
			if prop.value == nil do prop.value = sampled
			s.prims[prim].props[c.path_name[path]] = prop
		}
	}
	return .None
}

// The field indices of field set `set`: from there to its ~0 end.
@(private = "file")
crate_fieldset :: proc(c: ^Crate, set: int) -> (fields: []u32, ok: bool) {
	if set < 0 || set >= len(c.fieldsets) do return nil, false
	end := set
	for end < len(c.fieldsets) && c.fieldsets[end] != max(u32) do end += 1
	fields = c.fieldsets[set:end]
	for f in fields do if int(f) >= len(c.field_reps) || int(c.field_names[f]) >= len(c.tokens) do return nil, false
	return fields, true
}

// The prim of prim path `path`, made with its parents as needed; -1 for the root, for a
// property path and for anything under a variant (not followed: the prim holding the set
// is marked composed instead).
@(private = "file")
crate_prim :: proc(c: ^Crate, s: ^Stage, prim_of: []i32, path: int) -> int {
	if path < 0 || path >= len(prim_of) do return -1
	if prim_of[path] != -2 do return int(prim_of[path])
	parent := int(c.path_parent[path])
	if parent < 0 || c.path_prop[path] {
		prim_of[path] = -1
		return -1
	}
	name := c.path_name[path]
	if strings.has_prefix(name, "{") {
		prim_of[path] = -1
		return -1
	}
	// Depth is bounded by the number of paths: each step goes to a parent made earlier.
	up := crate_prim(c, s, prim_of, parent) if c.path_parent[parent] >= 0 else -1
	if c.path_parent[parent] >= 0 && up < 0 {
		prim_of[path] = -1
		return -1
	}
	index := len(s.prims)
	append(&s.prims, Prim{name = name, parent = up, active = true, props = make(map[string]Prop, context.temp_allocator), children = make([dynamic]int, context.temp_allocator)})
	if up >= 0 do append(&s.prims[up].children, index)
	prim_of[path] = i32(index)
	return index
}

// A value: inlined in the rep, or at the offset it names.
@(private = "file")
crate_value :: proc(c: ^Crate, rep: u64) -> Value {
	is_array := rep & (1 << 63) != 0
	inlined := rep & (1 << 62) != 0
	compressed := rep & (1 << 61) != 0
	type := Crate_Type((rep >> 48) & 0xFF)
	payload := rep & ((1 << 48) - 1)
	if inlined do return crate_inline(c, type, payload)
	at := int(payload)
	if at < 0 || at >= len(c.data) do return nil
	#partial switch type {
	case .Token_Vector:
		count := crate_u64(c, at) or_else max(u64)
		if count > u64(len(c.data) - at - 8) / 4 do return nil
		out := make([]string, count, context.temp_allocator)
		for k in 0 ..< int(count) {
			t := int((^u32le)(&c.data[at + 8 + 4 * k])^)
			if t >= len(c.tokens) do return nil
			out[k] = c.tokens[t]
		}
		return out
	case .Double_Vector:
		return crate_numbers(c, at, .Double, true, false)
	case .Token, .String, .Asset_Path:
		// An array of them (a single one is always inlined): token indices, or string
		// indices for strings.
		if !is_array do return nil
		count, start := crate_count(c, at)
		if count < 0 || count > (len(c.data) - start) / 4 do return nil
		out := make([]string, count, context.temp_allocator)
		for k in 0 ..< count {
			i := int((^u32le)(&c.data[start + 4 * k])^)
			if type == .String {
				if i >= len(c.strings) do return nil
				i = int(c.strings[i])
			}
			if i >= len(c.tokens) do return nil
			out[k] = c.tokens[i]
		}
		return out
	}
	return crate_numbers(c, at, type, is_array, compressed)
}

// An inlined value: small numbers and indices in the rep's low bits.
@(private = "file")
crate_inline :: proc(c: ^Crate, type: Crate_Type, payload: u64) -> Value {
	low := u32(payload)
	#partial switch type {
	case .Bool: return low != 0
	case .Token, .Asset_Path:
		if int(low) < len(c.tokens) do return c.tokens[low]
	case .String:
		if int(low) < len(c.strings) && int(c.strings[low]) < len(c.tokens) do return c.tokens[c.strings[low]]
	case .Int, .UInt, .UChar:
		out := make([]i32, 1, context.temp_allocator)
		out[0] = i32(low)
		return out
	case .Float:
		out := make([]f32, 1, context.temp_allocator)
		out[0] = transmute(f32)low
		return out
	case .Double:
		// Stored as a float when it is one exactly.
		out := make([]f64, 1, context.temp_allocator)
		out[0] = f64(transmute(f32)low)
		return out
	case .Half:
		out := make([]f32, 1, context.temp_allocator)
		out[0] = f32(transmute(f16)u16(low))
		return out
	case .Vec2d, .Vec2f, .Vec2h, .Vec2i, .Vec3d, .Vec3f, .Vec3h, .Vec3i, .Vec4d, .Vec4f, .Vec4h, .Vec4i:
		// Every component a whole number from -128 to 127: one signed byte each.
		n, _, _ := crate_shape(type)
		bytes := transmute([8]u8)payload
		if crate_is_double(type) {
			out := make([]f64, n, context.temp_allocator)
			for k in 0 ..< n do out[k] = f64(cast(i8)bytes[k])
			return out
		}
		out := make([]f32, n, context.temp_allocator)
		for k in 0 ..< n do out[k] = f32(cast(i8)bytes[k])
		return out
	case .Matrix2d, .Matrix3d, .Matrix4d:
		// A diagonal of whole numbers from -128 to 127.
		n, _, _ := crate_shape(type)
		side := int(math.sqrt(f64(n)))
		bytes := transmute([8]u8)payload
		out := make([]f64, n, context.temp_allocator)
		for k in 0 ..< side do out[k * side + k] = f64(cast(i8)bytes[k])
		return out
	}
	return nil
}

// A type's numbers per value, the bytes of each, and whether they are integers.
@(private = "file")
crate_shape :: proc(type: Crate_Type) -> (components: int, size: int, integer: bool) {
	#partial switch type {
	case .Bool, .UChar: return 1, 1, true
	case .Int, .UInt: return 1, 4, true
	case .Int64, .UInt64: return 1, 8, true
	case .Half: return 1, 2, false
	case .Float: return 1, 4, false
	case .Double: return 1, 8, false
	case .Vec2d: return 2, 8, false
	case .Vec2f: return 2, 4, false
	case .Vec2h: return 2, 2, false
	case .Vec2i: return 2, 4, true
	case .Vec3d: return 3, 8, false
	case .Vec3f: return 3, 4, false
	case .Vec3h: return 3, 2, false
	case .Vec3i: return 3, 4, true
	case .Vec4d, .Quatd: return 4, 8, false
	case .Vec4f, .Quatf: return 4, 4, false
	case .Vec4h, .Quath: return 4, 2, false
	case .Vec4i: return 4, 4, true
	case .Matrix2d: return 4, 8, false
	case .Matrix3d: return 9, 8, false
	case .Matrix4d: return 16, 8, false
	}
	return 0, 0, false
}

@(private = "file")
crate_is_double :: proc(type: Crate_Type) -> bool {
	#partial switch type {
	case .Double, .Vec2d, .Vec3d, .Vec4d, .Quatd, .Matrix2d, .Matrix3d, .Matrix4d: return true
	}
	return false
}

// A value of numbers at `at`: one, or an array (its count first, u32 before crate 0.7),
// raw or compressed (integers in USD's coding; floats as integers ('i') or as a table and
// coded indices ('t')). Quaternions come out real first, as text USD writes them.
@(private = "file")
crate_numbers :: proc(c: ^Crate, at: int, type: Crate_Type, is_array, compressed: bool) -> Value {
	components, size, integer := crate_shape(type)
	if components == 0 do return nil
	count := 1
	start := at
	if is_array {
		count, start = crate_count(c, at)
		if count < 0 do return nil
	}
	values := count * components
	if values < 0 || values > len(c.data) * 8 do return nil
	nums := make([]f64, values, context.temp_allocator)
	if compressed && is_array && components == 1 {
		if integer {
			ints, _, ok := crate_ints(c, start, count, size if size == 8 else 4)
			if !ok do return nil
			for x, k in ints do nums[k] = f64(x)
		} else {
			if start >= len(c.data) do return nil
			switch c.data[start] {
			case 'i':
				ints, _, ok := crate_ints(c, start + 1, count, 4)
				if !ok do return nil
				for x, k in ints do nums[k] = f64(x)
			case 't':
				if start + 5 > len(c.data) do return nil
				table := int((^u32le)(&c.data[start + 1])^)
				lut_at := start + 5
				if table < 0 || table > (len(c.data) - lut_at) / size do return nil
				lut := make([]f64, table, context.temp_allocator)
				for k in 0 ..< table do lut[k] = crate_float(c.data[lut_at + k * size:], size)
				indices, _, ok := crate_ints(c, lut_at + table * size, count, 4)
				if !ok do return nil
				for x, k in indices {
					if x < 0 || int(x) >= table do return nil
					nums[k] = lut[x]
				}
			case:
				return nil
			}
		}
	} else {
		if values > (len(c.data) - start) / size do return nil
		for k in 0 ..< values {
			b := c.data[start + k * size:]
			if integer {
				switch size {
				case 1: nums[k] = f64(b[0])
				case 4: nums[k] = f64(i32((^i32le)(&b[0])^)) if type == .Int || type == .Vec2i || type == .Vec3i || type == .Vec4i else f64(u32((^u32le)(&b[0])^))
				case 8: nums[k] = f64(i64((^i64le)(&b[0])^))
				}
			} else {
				nums[k] = crate_float(b, size)
			}
		}
	}
	if type == .Quatd || type == .Quatf || type == .Quath {
		// Stored imaginary part first, then the real part.
		for q := 0; q + 3 < len(nums); q += 4 do nums[q], nums[q + 1], nums[q + 2], nums[q + 3] = nums[q + 3], nums[q], nums[q + 1], nums[q + 2]
	}
	switch {
	case type == .Bool:
		return len(nums) > 0 && nums[0] != 0
	case integer:
		out := make([]i32, len(nums), context.temp_allocator)
		for x, k in nums do out[k] = i32(clamp(x, f64(min(i32)), f64(max(i32))))
		return out
	case crate_is_double(type):
		return nums
	}
	out := make([]f32, len(nums), context.temp_allocator)
	for x, k in nums do out[k] = f32(x)
	return out
}

// An array's length at `at` (a u64 from crate 0.7, a u32 before) and where its items
// start; -1 when it runs past the file.
@(private = "file")
crate_count :: proc(c: ^Crate, at: int) -> (count: int, start: int) {
	if c.minor >= 7 {
		n := crate_u64(c, at) or_else max(u64)
		if n > u64(len(c.data)) do return -1, 0
		return int(n), at + 8
	}
	if at + 4 > len(c.data) do return -1, 0
	return int((^u32le)(&c.data[at])^), at + 4
}

@(private = "file")
crate_float :: proc(b: []u8, size: int) -> f64 {
	switch size {
	case 2: return f64(transmute(f16)u16((^u16le)(&b[0])^))
	case 4: return f64(f32((^f32le)(&b[0])^))
	case 8: return f64((^f64le)(&b[0])^)
	}
	return 0
}

// A TimeSamples value's sample at the earliest time: an offset to the times' rep, the
// times (a double vector), then an offset to the values' count and reps.
@(private = "file")
crate_first_sample :: proc(c: ^Crate, rep: u64) -> Value {
	at := int(rep & ((1 << 48) - 1))
	jump := i64(crate_u64(c, at) or_else 0)
	times_at := at + int(jump)
	if jump <= 0 || times_at < 0 || times_at + 8 > len(c.data) do return nil
	times := prop_f64(crate_value(c, crate_u64(c, times_at) or_else 0))
	values_jump_at := times_at + 8
	jump2 := i64(crate_u64(c, values_jump_at) or_else 0)
	values_at := values_jump_at + int(jump2)
	if jump2 <= 0 || values_at < 0 do return nil
	count := crate_u64(c, values_at) or_else max(u64)
	if count == 0 || count != u64(len(times)) || count > u64(len(c.data) - values_at - 8) / 8 do return nil
	first := 0
	for t, k in times do if t < times[first] do first = k
	value_rep := crate_u64(c, values_at + 8 + 8 * first) or_else 0
	if Crate_Type((value_rep >> 48) & 0xFF) == .Value_Block do return nil
	return crate_value(c, value_rep)
}
