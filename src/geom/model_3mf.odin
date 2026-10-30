package geom

import "base:runtime"
import "../jobs"

// 3MF's model part (3D/3dmodel.model), the XML a 3D printing package holds: one object
// a part, each its own mesh of vertices and triangles, in millimetres, and a build that
// places every one as it stands, so a slicer keeps the parts apart (to colour or print
// each its own way) where an STL would fuse them into one. The package around it (its
// content types and relationship, zipped) is the caller's: geom knows no archives.

// A part of the model: its name, shown in the slicer's list, and its triangles.
Model_Part :: struct {
	name:      string,
	positions: []Vec3,
	indices:   []u32,
}

// The package's content types and its relationship to the model, the two small files a
// 3MF archive holds beside it.
MODEL_3MF_CONTENT_TYPES :: `<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
`
MODEL_3MF_RELS :: `<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
`

// Appends the model XML of `parts` (in millimetres) to `out`, formatting the numbers of
// big parts in parallel ranges joined in order, so the bytes are the same however many
// workers there are.
mesh_write_3mf_model :: proc(out: ^[dynamic]u8, parts: []Model_Part, pool: ^jobs.Pool = nil) {
	append(out, `<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
<metadata name="Application">Sculpt</metadata>
<resources>
`)
	tmp: [16]u8
	for part, i in parts {
		append(out, `<object id="`)
		append(out, ..tmp[:format_u32(tmp[:], u32(i + 1))])
		append(out, `" type="model" name="`)
		xml_escape(out, part.name)
		append(out, "\"><mesh><vertices>\n")
		model_ranges(out, part, true, pool)
		append(out, "</vertices><triangles>\n")
		model_ranges(out, part, false, pool)
		append(out, "</triangles></mesh></object>\n")
	}
	append(out, "</resources>\n<build>\n")
	for _, i in parts {
		append(out, `<item objectid="`)
		append(out, ..tmp[:format_u32(tmp[:], u32(i + 1))])
		append(out, "\"/>\n")
	}
	append(out, "</build>\n</model>\n")
}

// A part's vertices (or with `vertices` false its triangles) as XML elements, a range of
// RANGE_GRAIN at a time on the workers, appended to `out` in order.
@(private = "file")
model_ranges :: proc(out: ^[dynamic]u8, part: Model_Part, vertices: bool, pool: ^jobs.Pool) {
	Ranges :: struct {
		part:  Model_Part,
		lines: [][dynamic]u8,
	}
	count := len(part.positions) if vertices else len(part.indices) / 3
	r := Ranges{part = part, lines = make([][dynamic]u8, (count + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator)}
	work := proc(data: rawptr, lo, hi: int) {
		r := cast(^Ranges)data
		buf := make([dynamic]u8, 0, 48 * (hi - lo), runtime.heap_allocator())
		tmp: [32]u8
		for v in lo ..< hi {
			q := r.part.positions[v]
			append(&buf, `<vertex x="`)
			append(&buf, ..tmp[:format_f32(tmp[:], q.x)])
			append(&buf, `" y="`)
			append(&buf, ..tmp[:format_f32(tmp[:], q.y)])
			append(&buf, `" z="`)
			append(&buf, ..tmp[:format_f32(tmp[:], q.z)])
			append(&buf, "\"/>\n")
		}
		r.lines[lo / RANGE_GRAIN] = buf
	}
	if !vertices do work = proc(data: rawptr, lo, hi: int) {
		r := cast(^Ranges)data
		buf := make([dynamic]u8, 0, 40 * (hi - lo), runtime.heap_allocator())
		tmp: [16]u8
		names := [3]string{`<triangle v1="`, `" v2="`, `" v3="`}
		for t in lo ..< hi {
			for c in 0 ..< 3 {
				append(&buf, names[c])
				append(&buf, ..tmp[:format_u32(tmp[:], r.part.indices[3 * t + c])])
			}
			append(&buf, "\"/>\n")
		}
		r.lines[lo / RANGE_GRAIN] = buf
	}
	jobs.parallel_ranges(pool, count, &r, work, RANGE_GRAIN)
	for &l in r.lines {
		append(out, ..l[:])
		delete(l)
	}
}

// `s` as XML attribute text: the five characters XML gives meaning to, as entities.
@(private = "file")
xml_escape :: proc(out: ^[dynamic]u8, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&':  append(out, "&amp;")
		case '<':  append(out, "&lt;")
		case '>':  append(out, "&gt;")
		case '"':  append(out, "&quot;")
		case '\'': append(out, "&apos;")
		case:      append(out, s[i])
		}
	}
}
