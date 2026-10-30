package geom

import "core:image"
import _ "core:image/bmp"
import _ "core:image/jpeg"
import _ "core:image/png"
import _ "core:image/qoi"
import _ "core:image/tga"
import "core:math"
import "core:path/slashpath"
import "core:strconv"
import "core:strings"

// A file's materials as far as their base colour goes, which import paints into the
// vertices as polypaint (mesh_parts_paint): the readers fill a Mesh_Look and give each
// part's triangles their material and, where a material has a texture, each corner its
// texture coordinate.

// Gives the bytes of a file that a file being read names by `uri` (relative to it, with
// any percent escapes undone), owned by the caller and kept until the read returns.
Mesh_Resolve :: #type proc(data: rawptr, uri: string) -> (bytes: []u8, ok: bool)

// One material's base colour: linear red, green and blue, times its image when it has one.
Mesh_Material :: struct {
	color: [3]f32,
	image: int, // into Mesh_Look.images, or -1
}

// An image a material names: its encoded bytes (PNG, JPEG, BMP, TGA or QOI), or nil when
// the file names one that could not be had. The bytes are borrowed (from the file, its
// buffers or what the resolver gave) and kept by the caller until the paint is done.
Mesh_Image :: struct {
	bytes: []u8,
}

Mesh_Look :: struct {
	materials: [dynamic]Mesh_Material,
	images:    [dynamic]Mesh_Image,
}

mesh_look_destroy :: proc(look: ^Mesh_Look) {
	delete(look.images)
	delete(look.materials)
	look^ = {}
}

// What painting the materials did, for the note.
Mesh_Paint_Report :: struct {
	painted:  bool, // the materials became the vertices' colours
	textures: int, // images sampled
	unread:   int, // images missing, or in a format or kind not decoded (WebP, progressive JPEG)
}

// Paints each part's materials into its vertex colours (sRGB, alpha 255), then drops the
// parts' materials, which nothing after import keeps (the texture coordinates stay, for
// the import to keep as the UVs of an object of quads). A vertex takes the mean over its
// corners of the corner's material colour times its texture's colour there (bilinear,
// repeating, averaged in linear light), times the colour it already had; a vertex no
// triangle uses keeps its own. A part is left as it was when its materials say nothing of
// colour: when its triangles all have one and the same grey and no image, as an
// exporter's default material does, so a plain model keeps its clay while the eyes beside
// it take their colours.
//
// Serial and in part, triangle and corner order, so its result does not depend on any
// pool. Images are decoded one at a time, so only one is ever held decoded.
mesh_parts_paint :: proc(parts: []Mesh_Part, look: ^Mesh_Look) -> (report: Mesh_Paint_Report) {
	// The texture coordinates stay, for an object of quads to keep as its UVs.
	defer for &p in parts {
		delete(p.materials)
		p.materials = {}
	}
	if look == nil do return
	used := make([]bool, len(look.images), context.temp_allocator)
	// Whether each part's materials tell of colour: an image, a colour that is not grey,
	// or two colours that differ.
	tells := make([]bool, len(parts), context.temp_allocator)
	for p, k in parts {
		first: Maybe([3]f32)
		for m in p.materials {
			material := mesh_look_material(look, m)
			if material.image >= 0 {
				used[material.image] = true
				tells[k] = true
				continue
			}
			c := material.color
			if c.r != c.g || c.g != c.b do tells[k] = true
			if f, ok := first.?; ok {
				if f != c do tells[k] = true
			} else {
				first = c
			}
		}
		report.painted ||= tells[k]
	}
	if !report.painted do return

	Sum :: struct {
		rgb: [3]f32,
		n:   f32,
	}
	sums := make([][]Sum, len(parts), context.temp_allocator)
	for p, k in parts do sums[k] = make([]Sum, len(p.mesh.positions), context.temp_allocator)
	failed := make([]bool, len(look.images), context.temp_allocator)
	// One pass an image, its corners taking colour times texture, then a last pass for
	// the corners of materials without one, or whose image could not be read.
	for pass in 0 ..= len(look.images) {
		img: ^image.Image
		if pass < len(look.images) {
			if !used[pass] do continue
			bytes := look.images[pass].bytes
			err: image.Error = .Unsupported_Format
			// On the heap, so each image's memory is given back before the next.
			if bytes != nil do img, err = image.load_from_bytes(bytes)
			if err != nil || img == nil || (img.depth != 8 && img.depth != 16) || img.width <= 0 || img.height <= 0 || img.channels < 1 || img.channels > 4 {
				if img != nil do image.destroy(img)
				failed[pass] = true
				report.unread += 1
				continue
			}
			report.textures += 1
		}
		defer if img != nil do image.destroy(img)
		for p, k in parts {
			if !tells[k] do continue
			for m, t in p.materials {
				material := mesh_look_material(look, m)
				texture := material.image
				if texture >= 0 && failed[texture] do texture = -1
				if pass < len(look.images) && texture != pass || pass == len(look.images) && texture >= 0 do continue
				for c in 0 ..< 3 {
					rgb := material.color
					if img != nil && len(p.uvs) > 0 do rgb *= image_sample(img, p.uvs[3 * t + c])
					s := &sums[k][p.mesh.indices[3 * t + c]]
					s.rgb += rgb
					s.n += 1
				}
			}
		}
	}
	for &p, k in parts {
		if !tells[k] do continue
		had := len(p.colors) > 0
		resize(&p.colors, len(p.mesh.positions))
		for s, v in sums[k] {
			if s.n == 0 do continue
			rgb := s.rgb / s.n
			if had && p.colors[v].a > 0 do for x in 0 ..< 3 do rgb[x] *= SRGB_TO_LINEAR[p.colors[v][x]]
			p.colors[v] = {srgb_byte_of_linear(rgb.r), srgb_byte_of_linear(rgb.g), srgb_byte_of_linear(rgb.b), 255}
		}
	}
	return
}

// A triangle's material: its own, or white for none (-1) or a number past the list.
@(private = "file")
mesh_look_material :: proc(look: ^Mesh_Look, m: i32) -> Mesh_Material {
	if m < 0 || int(m) >= len(look.materials) do return {color = 1, image = -1}
	material := look.materials[m]
	if material.image >= len(look.images) do material.image = -1
	return material
}

// The linear colour of an image at `uv` (u to the right, v down from the top row, as
// glTF has them), bilinear between texel centres and repeating past the edges; a grey
// image is grey in all three, and alpha is left out.
@(private = "file")
image_sample :: proc(img: ^image.Image, uv: [2]f32) -> [3]f32 {
	w, h := img.width, img.height
	u, v := uv.x, uv.y
	if !(u == u && abs(u) < 1e6) do u = 0
	if !(v == v && abs(v) < 1e6) do v = 0
	x := f64(u) * f64(w) - 0.5
	y := f64(v) * f64(h) - 0.5
	x0, y0 := math.floor(x), math.floor(y)
	fx, fy := f32(x - x0), f32(y - y0)
	wrap :: #force_inline proc(a: f64, n: int) -> int {
		k := int(a) % n
		return k + n if k < 0 else k
	}
	xs := [2]int{wrap(x0, w), wrap(x0 + 1, w)}
	ys := [2]int{wrap(y0, h), wrap(y0 + 1, h)}
	texel :: #force_inline proc(img: ^image.Image, x, y: int) -> [3]f32 {
		at := (y * img.width + x) * img.channels
		out: [3]f32
		for k in 0 ..< 3 {
			channel := k if img.channels >= 3 else 0
			byte: u8
			if img.depth == 8 do byte = img.pixels.buf[at + channel]
			else do byte = u8((^u16)(&img.pixels.buf[2 * (at + channel)])^ >> 8)
			out[k] = SRGB_TO_LINEAR[byte]
		}
		return out
	}
	top := texel(img, xs[0], ys[0]) * (1 - fx) + texel(img, xs[1], ys[0]) * fx
	bottom := texel(img, xs[0], ys[1]) * (1 - fx) + texel(img, xs[1], ys[1]) * fx
	return top * (1 - fy) + bottom * fy
}

// Each sRGB byte's linear value.
@(private = "file")
SRGB_TO_LINEAR := #partial [256]f32{}

@(init, private = "file")
srgb_table :: proc "contextless" () {
	for &x, k in SRGB_TO_LINEAR {
		s := f32(k) / 255
		x = s / 12.92 if s <= 0.04045 else math.pow((s + 0.055) / 1.055, 2.4)
	}
}

// An MTL file's materials by name (Kd as the colour, map_Kd as the image, a path
// relative to the MTL file) and in the order it defines them; the names point into
// `text`.
mtl_read :: proc(text: string, materials: ^map[string]Mtl_Material, order: ^[dynamic]string) {
	current := ""
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		key, value := first_word(line)
		// A comment ends a line, except in a path, where # may be part of a name.
		if hash := strings.index_byte(value, '#'); hash >= 0 && key != "map_Kd" do value = value[:hash]
		value = strings.trim_space(value)
		switch key {
		case "newmtl":
			current = value
			if value not_in materials do append(order, value)
			materials[value] = {color = 1}
		case "Kd":
			m, ok := materials[current]
			if !ok do continue
			fields := strings.fields(value, context.temp_allocator)
			if len(fields) < 1 || fields[0] == "spectral" || fields[0] == "xyz" do continue
			for k in 0 ..< 3 {
				x, parsed := strconv.parse_f32(fields[min(k, len(fields) - 1)])
				if parsed do m.color[k] = clamp(x, 0, 1)
			}
			materials[current] = m
		case "map_Kd":
			m, ok := materials[current]
			if !ok do continue
			m.image = mtl_map_path(value)
			materials[current] = m
		}
	}
}

Mtl_Material :: struct {
	color: [3]f32, // linear, as Blender writes and reads it
	image: string, // "" for none
}

// A line's first word and what follows it, both without the blanks between.
@(private = "file")
first_word :: proc(line: string) -> (word, rest: string) {
	l := strings.trim_left_space(line)
	end := 0
	for end < len(l) && l[end] != ' ' && l[end] != '\t' && l[end] != '\r' do end += 1
	return l[:end], strings.trim_left_space(l[end:])
}

// The file a `map_Kd` line names, after its options: each `-name` option takes the
// numbers and on/off words that follow it; the rest of the line is the path, spaces and
// all, its backslashes turned to slashes.
@(private = "file")
mtl_map_path :: proc(value: string) -> string {
	rest := value
	for strings.has_prefix(rest, "-") {
		_, rest = first_word(rest)
		for {
			word, after := first_word(rest)
			if word == "" || !mtl_option_word(word) do break
			rest = after
		}
	}
	path, _ := strings.replace_all(strings.trim_space(rest), "\\", "/", context.temp_allocator)
	return path
}

@(private = "file")
mtl_option_word :: proc(word: string) -> bool {
	if word == "on" || word == "off" do return true
	_, ok := strconv.parse_f64(word)
	return ok
}

// Reads the MTL files an OBJ file's `mtllib` lines name, through `resolve`, into `look`,
// giving each material name its number there (`names` points into the MTL files' bytes,
// which the resolver keeps). True when a material has an image that could be had, so
// the OBJ's texture coordinates are worth reading.
@(private)
obj_look :: proc(data: []u8, look: ^Mesh_Look, resolve: Mesh_Resolve, resolve_data: rawptr, names: ^map[string]i32) -> (textured: bool) {
	// Exporters write `mtllib` among the first lines, so only the head is searched
	// rather than every byte of a file of hundreds of megabytes.
	head := string(data[:min(len(data), 1 << 20)])
	images := make(map[string]int, context.temp_allocator)
	for line in strings.split_lines_iterator(&head) {
		key, value := first_word(line)
		if key != "mtllib" do continue
		value = strings.trim_space(value)
		// One name may hold spaces (Blender writes the file's own name), or the line may
		// list several files.
		libs := make([dynamic]string, context.temp_allocator)
		append(&libs, value)
		if strings.contains_space(value) do append(&libs, ..strings.fields(value, context.temp_allocator))
		for lib, l in libs {
			name, _ := strings.replace_all(lib, "\\", "/", context.temp_allocator)
			bytes, ok := resolve(resolve_data, name)
			if !ok do continue
			materials := make(map[string]Mtl_Material, context.temp_allocator)
			order := make([dynamic]string, context.temp_allocator)
			mtl_read(string(bytes), &materials, &order)
			dir := slashpath.dir(name, context.temp_allocator)
			// Numbered in MTL order, never map order.
			for n in order {
				if n in names do continue
				mm := materials[n]
				out := Mesh_Material{color = mm.color, image = -1}
				if mm.image != "" {
					path := mm.image if dir == "." || dir == "" else slashpath.join({dir, mm.image}, context.temp_allocator)
					k, seen := images[path]
					if !seen {
						k = len(look.images)
						images[path] = k
						image_bytes, found := resolve(resolve_data, path)
						// A path the exporter wrote as absolute, or into another folder,
						// is tried again by its name beside the OBJ file.
						if !found do image_bytes, found = resolve(resolve_data, slashpath.base(path))
						append(&look.images, Mesh_Image{bytes = image_bytes if found else nil})
						textured ||= found
					}
					out.image = k
				}
				names[n] = i32(len(look.materials))
				append(&look.materials, out)
			}
			// The whole line named a file, so its words are not tried as others.
			if l == 0 do break
		}
	}
	return
}
