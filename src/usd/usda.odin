package usd

import "core:bytes"
import "core:strconv"
import "core:strings"

import "../geom"

// USD's text form (.usda) into a Stage: prims (def, over and class, with their type and
// name), their properties' default values or first time samples, the metadata a mesh
// needs (active, interpolation, the layer's upAxis and metersPerUnit), and everything
// else read past by its brackets. Variant sets, references and payloads mark their prim
// as composed and are not followed. Everything comes from the temp allocator.

USDA_MAGIC :: "#usda"

// Reads `text` into `s`. `line` is where a malformed part was found (0 when no one line
// is to blame).
read_usda :: proc(s: ^Stage, text: []u8) -> (err: geom.Mesh_File_Error, line: int) {
	if !bytes.has_prefix(text, transmute([]u8)string(USDA_MAGIC)) do return .Not_Recognised, 1
	r := Usda{text = text, stage = s}
	// Past the magic's line, which a comment would otherwise swallow anyway.
	nl := bytes.index_byte(text, '\n')
	r.at = len(text) if nl < 0 else nl + 1
	if usda_peek(&r).kind == .Open_Paren {
		meta := usda_metadata(&r)
		if up, ok := meta.up_axis.?; ok do s.up_z = up == "Z"
		if m, ok := meta.meters.?; ok do s.meters_per_unit = m
	}
	for !r.failed {
		t := usda_peek(&r)
		if t.kind == .End do break
		if !usda_prim(&r, -1) do r.failed = true
	}
	if r.failed {
		return .Bad_Structure, 1 + bytes.count(text[:min(r.fail_at, len(text))], []u8{'\n'})
	}
	return .None, 0
}

@(private = "file")
Usda :: struct {
	text:    []u8,
	at:      int,
	stage:   ^Stage,
	failed:  bool,
	fail_at: int,
	peeked:  Maybe(Token),
}

@(private = "file")
Token_Kind :: enum u8 {
	End,
	Ident, // a name, keyword or type, ':' and '.' inside it allowed
	Number,
	String, // the text inside the quotes (escapes left as they are)
	Asset, // the path inside @...@
	Path, // the path inside <...>
	Open_Paren,
	Close_Paren,
	Open_Bracket,
	Close_Bracket,
	Open_Brace,
	Close_Brace,
	Equals,
	Comma,
	Colon,
	Semicolon,
	Bad,
}

@(private = "file")
Token :: struct {
	kind: Token_Kind,
	text: string,
	at:   int,
}

@(private = "file")
usda_fail :: proc(r: ^Usda, at: int) -> bool {
	if !r.failed do r.fail_at = at
	r.failed = true
	return false
}

@(private = "file")
usda_peek :: proc(r: ^Usda) -> Token {
	if t, ok := r.peeked.?; ok do return t
	t := usda_lex(r)
	r.peeked = t
	return t
}

@(private = "file")
usda_next :: proc(r: ^Usda) -> Token {
	if t, ok := r.peeked.?; ok {
		r.peeked = nil
		return t
	}
	return usda_lex(r)
}

@(private = "file")
usda_lex :: proc(r: ^Usda) -> Token {
	text := r.text
	n := len(text)
	for r.at < n {
		c := text[r.at]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			r.at += 1
		} else if c == '#' {
			for r.at < n && text[r.at] != '\n' do r.at += 1
		} else {
			break
		}
	}
	start := r.at
	if start >= n do return {.End, "", start}
	c := text[start]
	single :: proc(r: ^Usda, kind: Token_Kind) -> Token {
		r.at += 1
		return {kind, string(r.text[r.at - 1:r.at]), r.at - 1}
	}
	switch c {
	case '(': return single(r, .Open_Paren)
	case ')': return single(r, .Close_Paren)
	case '[': return single(r, .Open_Bracket)
	case ']': return single(r, .Close_Bracket)
	case '{': return single(r, .Open_Brace)
	case '}': return single(r, .Close_Brace)
	case '=': return single(r, .Equals)
	case ',': return single(r, .Comma)
	case ':': return single(r, .Colon)
	case ';': return single(r, .Semicolon)
	case '"', '\'':
		// """...""" and '''...''' may span lines; the others end at their quote.
		if start + 2 < n && text[start + 1] == c && text[start + 2] == c {
			end := start + 3
			for end + 2 < n && !(text[end] == c && text[end + 1] == c && text[end + 2] == c) do end += 1 if text[end] != '\\' else 2
			if end + 2 >= n do return {.Bad, "", start}
			r.at = end + 3
			return {.String, string(text[start + 3:end]), start}
		}
		end := start + 1
		for end < n && text[end] != c && text[end] != '\n' do end += 1 if text[end] != '\\' else 2
		if end >= n || text[end] != c do return {.Bad, "", start}
		r.at = end + 1
		return {.String, string(text[start + 1:end]), start}
	case '@':
		if bytes.has_prefix(text[start:], transmute([]u8)string("@@@")) {
			end := bytes.index(text[start + 3:], transmute([]u8)string("@@@"))
			if end < 0 do return {.Bad, "", start}
			r.at = start + 3 + end + 3
			return {.Asset, string(text[start + 3:][:end]), start}
		}
		end := bytes.index_byte(text[start + 1:], '@')
		if end < 0 do return {.Bad, "", start}
		r.at = start + 1 + end + 1
		return {.Asset, string(text[start + 1:][:end]), start}
	case '<':
		end := bytes.index_byte(text[start + 1:], '>')
		if end < 0 do return {.Bad, "", start}
		r.at = start + 1 + end + 1
		return {.Path, string(text[start + 1:][:end]), start}
	}
	if c == '-' || c == '+' || c == '.' || (c >= '0' && c <= '9') {
		end := start + 1
		for end < n {
			d := text[end]
			if (d >= '0' && d <= '9') || d == '.' || d == 'e' || d == 'E' || ((d == '-' || d == '+') && (text[end - 1] == 'e' || text[end - 1] == 'E')) {
				end += 1
			} else {
				break
			}
		}
		// -inf, written as a sign and a word.
		if end == start + 1 && (c == '-' || c == '+') && bytes.has_prefix(text[end:], transmute([]u8)string("inf")) do end += 3
		r.at = end
		return {.Number, string(text[start:end]), start}
	}
	if is_ident_start(c) {
		end := start + 1
		for end < n && (is_ident_start(text[end]) || (text[end] >= '0' && text[end] <= '9') || text[end] == ':' || text[end] == '.') do end += 1
		// A type's array marker belongs to it: point3f[].
		if end + 1 < n && text[end] == '[' && text[end + 1] == ']' do end += 2
		r.at = end
		return {.Ident, string(text[start:end]), start}
	}
	r.at += 1
	return {.Bad, string(text[start:r.at]), start}

	is_ident_start :: proc(c: u8) -> bool {return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '!' || c >= 0x80}
}

// A prim spec, `def|over|class [Type] "name" [( metadata )] { body }`, added under
// `parent`.
@(private = "file")
usda_prim :: proc(r: ^Usda, parent: int) -> bool {
	t := usda_next(r)
	if t.kind != .Ident do return usda_fail(r, t.at)
	p := Prim{parent = parent, active = true, props = make(map[string]Prop, context.temp_allocator), children = make([dynamic]int, context.temp_allocator)}
	switch t.text {
	case "def": p.specifier = .Def
	case "over": p.specifier = .Over
	case "class": p.specifier = .Class
	case: return usda_fail(r, t.at)
	}
	name := usda_next(r)
	if name.kind == .Ident {
		p.type_name = name.text
		name = usda_next(r)
	}
	if name.kind != .String do return usda_fail(r, name.at)
	p.name = name.text
	if usda_peek(r).kind == .Open_Paren {
		meta := usda_metadata(r)
		if r.failed do return false
		if a, ok := meta.active.?; ok do p.active = a
		p.composed = meta.composed
	}
	if usda_next(r).kind != .Open_Brace do return usda_fail(r, t.at)
	s := r.stage
	index := len(s.prims)
	append(&s.prims, p)
	if parent >= 0 do append(&s.prims[parent].children, index)
	for {
		u := usda_peek(r)
		#partial switch u.kind {
		case .Close_Brace:
			usda_next(r)
			return true
		case .End, .Bad:
			return usda_fail(r, u.at)
		case .Semicolon:
			usda_next(r)
			continue
		case .Ident:
		case:
			return usda_fail(r, u.at)
		}
		switch u.text {
		case "def", "over", "class":
			if !usda_prim(r, index) do return false
		case "variantSet":
			// Variants are not followed: read past the whole set.
			usda_next(r)
			s.prims[index].composed = true
			for usda_peek(r).kind != .Open_Brace && usda_peek(r).kind != .End do usda_next(r)
			if !usda_skip(r) do return false
		case "reorder":
			// reorder nameChildren / properties = [...]: order only.
			usda_next(r)
			usda_next(r)
			if usda_next(r).kind != .Equals do return usda_fail(r, u.at)
			if !usda_value(r, nil, nil) do return false
		case:
			if !usda_property(r, index) do return false
		}
	}
}

// An attribute or relationship line: `[custom] [uniform|varying|config] type name
// [.timeSamples] [= value] [( metadata )]`, or `rel name [= targets]`. Only attributes'
// values are kept.
@(private = "file")
usda_property :: proc(r: ^Usda, prim: int) -> bool {
	t := usda_next(r)
	for t.kind == .Ident && (t.text == "custom" || t.text == "uniform" || t.text == "varying" || t.text == "config" || t.text == "prepend" || t.text == "append" || t.text == "delete" || t.text == "add") do t = usda_next(r)
	if t.kind != .Ident do return usda_fail(r, t.at)
	is_rel := t.text == "rel"
	type_name := t.text
	name := usda_next(r)
	if name.kind != .Ident do return usda_fail(r, name.at)
	prop_name := name.text
	samples := false
	if strings.has_suffix(prop_name, ".timeSamples") {
		prop_name = prop_name[:len(prop_name) - len(".timeSamples")]
		samples = true
	} else if strings.has_suffix(prop_name, ".connect") || strings.has_suffix(prop_name, ".spline") {
		is_rel = true // a connection's targets, not a value
	}
	prop := r.stage.prims[prim].props[prop_name]
	prop.type_name = type_name
	if usda_peek(r).kind == .Equals {
		usda_next(r)
		if is_rel {
			if !usda_value(r, nil, nil) do return false
		} else if samples {
			v, ok := usda_samples(r, type_name)
			if !ok do return false
			if prop.value == nil do prop.value = v
		} else {
			v, ok := usda_typed(r, type_name)
			if !ok do return false
			prop.value = v
		}
	}
	if usda_peek(r).kind == .Open_Paren {
		meta := usda_metadata(r)
		if r.failed do return false
		if i, ok := meta.interpolation.?; ok do prop.interpolation = i
	}
	if !is_rel do r.stage.prims[prim].props[prop_name] = prop
	return true
}

// A value read as `type_name` says.
@(private = "file")
usda_typed :: proc(r: ^Usda, type_name: string) -> (v: Value, ok: bool) {
	nums := make([dynamic]f64, context.temp_allocator)
	strs := make([dynamic]string, context.temp_allocator)
	usda_value(r, &nums, &strs) or_return
	base := strings.trim_suffix(type_name, "[]")
	array := len(base) < len(type_name)
	switch {
	case base == "token" || base == "string" || base == "asset":
		if array do return strs[:], true
		if len(strs) > 0 do return strs[0], true
		return nil, true
	case base == "bool":
		if len(strs) > 0 do return strs[0] == "true", true
		return len(nums) > 0 && nums[0] != 0, true
	case strings.has_prefix(base, "int") || strings.has_prefix(base, "uint") || base == "uchar":
		out := make([]i32, len(nums), context.temp_allocator)
		for x, i in nums do out[i] = i32(clamp(x, f64(min(i32)), f64(max(i32))))
		return out, true
	case strings.has_prefix(base, "double") || strings.has_prefix(base, "matrix") || base == "timecode" || base == "frame4d":
		return nums[:], true
	}
	out := make([]f32, len(nums), context.temp_allocator)
	for x, i in nums do out[i] = f32(x)
	return out, true
}

// `{ time: value, ... }`: the value at the earliest time (None samples left out).
@(private = "file")
usda_samples :: proc(r: ^Usda, type_name: string) -> (v: Value, ok: bool) {
	open := usda_next(r)
	if open.kind != .Open_Brace do return nil, usda_fail(r, open.at)
	earliest := max(f64)
	for {
		t := usda_next(r)
		#partial switch t.kind {
		case .Close_Brace: return v, true
		case .Comma: continue
		case .Number:
		case: return nil, usda_fail(r, t.at)
		}
		time, _ := strconv.parse_f64(t.text)
		if usda_next(r).kind != .Colon do return nil, usda_fail(r, t.at)
		if u := usda_peek(r); u.kind == .Ident && u.text == "None" {
			usda_next(r)
			continue
		}
		x := usda_typed(r, type_name) or_return
		if time < earliest {
			earliest = time
			v = x
		}
	}
}

// One value, its numbers onto `nums` and its words onto `strs` (either nil to read past
// them): a number, a word, a string, an asset or a path, or a tuple or list of values
// (flattened); a dictionary is read past.
@(private = "file")
usda_value :: proc(r: ^Usda, nums: ^[dynamic]f64, strs: ^[dynamic]string) -> bool {
	t := usda_next(r)
	#partial switch t.kind {
	case .Number:
		if nums != nil {
			x, ok := strconv.parse_f64(t.text)
			if !ok do return usda_fail(r, t.at)
			append(nums, x)
		}
	case .Ident:
		switch t.text {
		case "inf": if nums != nil do append(nums, max(f64))
		case "nan": if nums != nil do append(nums, 0)
		case: if strs != nil do append(strs, t.text)
		}
	case .String, .Asset, .Path:
		if strs != nil do append(strs, t.text)
		// A reference: an asset and the prim in it, written together.
		if t.kind == .Asset && usda_peek(r).kind == .Path do usda_next(r)
	case .Open_Paren, .Open_Bracket:
		close := Token_Kind.Close_Paren if t.kind == .Open_Paren else .Close_Bracket
		for {
			u := usda_peek(r)
			if u.kind == close {
				usda_next(r)
				break
			}
			if u.kind == .Comma {
				usda_next(r)
				continue
			}
			if u.kind == .End || u.kind == .Bad do return usda_fail(r, u.at)
			if !usda_value(r, nums, strs) do return false
		}
	case .Open_Brace:
		r.peeked = t
		return usda_skip(r)
	case:
		return usda_fail(r, t.at)
	}
	return true
}

// Reads past a `{ ... }` block, braces inside it counted and strings respected.
@(private = "file")
usda_skip :: proc(r: ^Usda) -> bool {
	open := usda_next(r)
	if open.kind != .Open_Brace do return usda_fail(r, open.at)
	depth := 1
	for depth > 0 {
		t := usda_next(r)
		#partial switch t.kind {
		case .Open_Brace: depth += 1
		case .Close_Brace: depth -= 1
		case .End, .Bad: return usda_fail(r, t.at)
		}
	}
	return true
}

// What a metadata block says that this reader uses.
@(private = "file")
Usda_Meta :: struct {
	active:        Maybe(bool),
	composed:      bool,
	interpolation: Maybe(string),
	up_axis:       Maybe(string),
	meters:        Maybe(f64),
}

// `( entries )`: `[listop] key = value` entries and doc strings.
@(private = "file")
usda_metadata :: proc(r: ^Usda) -> (meta: Usda_Meta) {
	open := usda_next(r)
	if open.kind != .Open_Paren {
		usda_fail(r, open.at)
		return
	}
	for {
		t := usda_next(r)
		#partial switch t.kind {
		case .Close_Paren: return
		case .String, .Semicolon: continue
		case .Ident:
		case:
			usda_fail(r, t.at)
			return
		}
		key := t.text
		listop := key == "prepend" || key == "append" || key == "delete" || key == "add" || key == "reorder"
		if listop {
			k := usda_next(r)
			if k.kind != .Ident {
				usda_fail(r, k.at)
				return
			}
			key = k.text
		}
		eq := usda_next(r)
		if eq.kind != .Equals {
			usda_fail(r, eq.at)
			return
		}
		nums := make([dynamic]f64, context.temp_allocator)
		strs := make([dynamic]string, context.temp_allocator)
		if !usda_value(r, &nums, &strs) do return
		switch key {
		case "active": if len(strs) > 0 do meta.active = strs[0] == "true"
		case "interpolation": if len(strs) > 0 do meta.interpolation = strs[0]
		case "upAxis": if len(strs) > 0 do meta.up_axis = strs[0]
		case "metersPerUnit": if len(nums) > 0 do meta.meters = nums[0]
		case "references", "payload", "variantSets", "variants", "inherits", "specializes":
			// A delete removes; anything else brings in what is not followed.
			if t.text != "delete" && (len(strs) > 0 || key == "variants") do meta.composed = true
		case "instanceable":
			if len(strs) > 0 && strs[0] == "true" do meta.composed = true
		}
	}
}
