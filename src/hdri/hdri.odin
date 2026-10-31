package hdri

import "core:fmt"
import "core:image"
import _ "core:image/bmp"
import _ "core:image/jpeg"
import _ "core:image/png"
import _ "core:image/qoi"
import _ "core:image/tga"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

import "../geom"

// Package hdri reads environment panoramas, the image-based light's pictures, with no
// rendering or interface: decoding runs on a worker thread and the app uploads the result.
//
// Environment panoramas from files (stage 4.1, notes/rendering/stage4-design.md): a
// Radiance `.hdr` (RGBE) or any image core:image reads, equirectangular, twice as wide as
// tall, as linear RGB at most `max_width` wide, halved by 2 x 2 box averages as rows are
// read, so a Radiance file, which streams row by row, never sits in memory at full size
// (a picture is decoded whole first, once its header says it is not too big).

// Panoramas wider than this are refused: 8192 x 4096 is the largest common HDRI size and
// what core:image accepts. Picture files (not Radiance) stop at 4096 on tablets, where a
// decoded 8k picture alone would be 128 MB.
MAX_SIDE :: 8192
MAX_PICTURE_SIDE :: 4096 when MOBILE else MAX_SIDE
// Tablets and phones: Android and iOS builds are a subtarget of their desktop OS.
@(private)
MOBILE :: ODIN_PLATFORM_SUBTARGET != .Default
// Panoramas smaller than this are refused: the renderer prefilters six halvings of it.
MIN_WIDTH :: 64
// A Radiance header longer than this is not one.
HDR_HEADER_MAX :: 4096
// The largest value a half float holds: brighter pixels (RGBE reaches 1.7e38) are clamped
// to it before they are summed, so no sum or upload becomes infinite.
HDR_MAX_VALUE :: 65504

// A panorama as linear RGB, rows top (straight up) to bottom (straight down), columns
// from behind the viewer (u = 0) round through straight ahead (u = 0.5).
Image :: struct {
	pixels: [][3]f32,
	width:  int,
	height: int,
}

image_destroy :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.pixels, allocator)
	img^ = {}
}

// Reads `data` as a panorama no wider than `max_width` (a power of two halves it); why it
// cannot be one otherwise ("" when it can, else a string in `allocator`, since decodes run
// on a thread whose temp memory ends with it). Never reads past `data`.
decode :: proc(data: []u8, max_width: int, allocator := context.allocator) -> (img: Image, why: string) {
	reason: string
	if len(data) >= 2 && data[0] == '#' && data[1] == '?' {
		img, reason = hdr_decode(data, max_width, allocator)
	} else if exr_is(data) {
		img, reason = exr_decode(data, max_width, allocator)
	} else {
		img, reason = picture_decode(data, max_width, allocator)
	}
	if reason != "" do return {}, strings.clone(reason, allocator)
	return img, ""
}

// A PNG, JPEG, BMP, TGA or QOI panorama, its sRGB values turned to linear light row by
// row straight from the decoded pixels.
@(private = "file")
picture_decode :: proc(data: []u8, max_width: int, allocator := context.allocator) -> (img: Image, why: string) {
	// The header first, so a picture too big for this device is refused before its pixels
	// take the memory.
	head, head_err := image.load_from_bytes(data, {.info})
	if head_err != nil do return {}, fmt.tprintf("%v (OpenEXR, Radiance .hdr, PNG, JPEG, BMP, TGA and QOI panoramas work)", head_err)
	width, height := head.width, head.height
	image.destroy(head)
	if why = panorama_size_check(width, height, MAX_PICTURE_SIDE); why != "" do return
	src, err := image.load_from_bytes(data)
	if err != nil do return {}, fmt.tprintf("%v (OpenEXR, Radiance .hdr, PNG, JPEG, BMP, TGA and QOI panoramas work)", err)
	defer image.destroy(src)
	if src.width != width || src.height != height do return {}, "its size changed between its header and its pixels"
	if src.depth != 8 && src.depth != 16 do return {}, fmt.tprintf("%d-bit channels are not supported", src.depth)
	// Eight-bit values take their linear value from a table rather than a power per channel.
	lut: [256]f32
	for &v, i in lut do v = geom.srgb_decode(f32(i) / 255)
	pixels := src.pixels.buf[:]
	wide := mem.slice_data_cast([]u16, pixels) if src.depth == 16 else nil
	channels := src.channels
	shrink := halvings(src.width, max_width)
	img = image_make(src.width, src.height, shrink, allocator)
	row := make([][3]f32, src.width, context.temp_allocator)
	for y in 0 ..< src.height {
		for &p, x in row {
			k := (y * src.width + x) * channels
			for c in 0 ..< 3 {
				// Grey (with or without alpha) spreads to all three channels.
				at := k + (0 if channels <= 2 else c)
				p[c] = lut[pixels[at]] if wide == nil else geom.srgb_decode(f32(wide[at]) / 65535)
			}
		}
		add_row(&img, row, y, shrink)
	}
	return img, ""
}

// Why a `width` by `height` image cannot be a panorama ("" when it can).
@(private)
panorama_size_check :: proc(width, height: int, max_side := MAX_SIDE) -> string {
	if width < MIN_WIDTH || height < MIN_WIDTH / 2 || width > max_side || height > max_side {
		return fmt.tprintf("%d x %d is not between %d x %d and %d a side", width, height, MIN_WIDTH, MIN_WIDTH / 2, max_side)
	}
	if abs(width - 2 * height) > 1 do return fmt.tprintf("%d x %d is not a panorama twice as wide as it is tall", width, height)
	return ""
}

// How many times a `width` panorama halves to be at most `max_width` wide.
@(private)
halvings :: proc(width, max_width: int) -> (n: int) {
	for width >> uint(n) > max(max_width, 2) do n += 1
	return
}

// An empty panorama the size of a `width` by `height` one halved `shrink` times.
@(private)
image_make :: proc(width, height, shrink: int, allocator := context.allocator) -> (img: Image) {
	img.width, img.height = max(width >> uint(shrink), 1), max(height >> uint(shrink), 1)
	img.pixels = make([][3]f32, img.width * img.height, allocator)
	return
}

// Adds source row `y` (as wide as the source) into `img`, each output pixel the mean of
// a 2^shrink square; source rows and columns past the last whole square are dropped.
@(private)
add_row :: proc(img: ^Image, row: [][3]f32, y, shrink: int) {
	block := 1 << uint(shrink)
	out_y := y >> uint(shrink)
	if out_y >= img.height do return
	weight := 1 / f32(block * block)
	out := img.pixels[out_y * img.width:][:img.width]
	for &o, x in out {
		sum: [3]f32
		for k in 0 ..< block do sum += row[x * block + k]
		o += sum * weight
	}
}

// Radiance RGBE: a `#?` line, header lines up to an empty one (FORMAT must be RGBE), a
// `-Y H +X W` size line, then W x H pixels, each row flat (4 bytes a pixel) or run-length
// encoded per channel (the 2 2 hi lo form). The older 1 1 1 n runs are refused.
@(private = "file")
hdr_decode :: proc(data: []u8, max_width: int, allocator := context.allocator) -> (img: Image, why: string) {
	at := 0
	line :: proc(data: []u8, at: ^int) -> (s: string, ok: bool) {
		start := at^
		for at^ < len(data) && at^ - start < HDR_HEADER_MAX {
			if data[at^] == '\n' {
				s = string(data[start:at^])
				at^ += 1
				return strings.trim_right(s, "\r"), true
			}
			at^ += 1
		}
		return "", false
	}
	format_ok := false
	for {
		s, ok := line(data, &at)
		if !ok || at > HDR_HEADER_MAX do return {}, "its Radiance header does not end"
		if s == "" do break
		if strings.has_prefix(s, "FORMAT=") do format_ok = s == "FORMAT=32-bit_rle_rgbe"
	}
	if !format_ok do return {}, "it is not an RGBE Radiance file (FORMAT=32-bit_rle_rgbe)"
	size, ok := line(data, &at)
	parts := strings.fields(size, context.temp_allocator)
	if !ok || len(parts) != 4 || parts[0] != "-Y" || parts[2] != "+X" do return {}, "its size line is not -Y height +X width"
	height, h_ok := strconv.parse_int(parts[1], 10)
	width, w_ok := strconv.parse_int(parts[3], 10)
	if !h_ok || !w_ok do return {}, "its size line is not -Y height +X width"
	if why = panorama_size_check(width, height); why != "" do return

	shrink := halvings(width, max_width)
	img = image_make(width, height, shrink, allocator)
	rgbe := make([]u8, width * 4, context.temp_allocator)
	row := make([][3]f32, width, context.temp_allocator)
	for y in 0 ..< height {
		if why = hdr_row(data, &at, rgbe, width, height - y); why != "" {
			image_destroy(&img, allocator)
			return {}, why
		}
		for &p, x in row {
			e := rgbe[x * 4 + 3]
			f := math.ldexp_f32(1, int(e) - 136) if e != 0 else 0
			for c in 0 ..< 3 do p[c] = min(f32(rgbe[x * 4 + c]) * f, HDR_MAX_VALUE)
		}
		add_row(&img, row, y, shrink)
	}
	return img, ""
}

// Reads one RGBE row of `width` pixels at `at` into `out` (4 bytes a pixel, channels
// interleaved), `rows` rows being left; why not ("" when it did).
@(private = "file")
hdr_row :: proc(data: []u8, at: ^int, out: []u8, width, rows: int) -> string {
	DAMAGED :: "its pixels end early or overrun a row"
	rest := data[at^:]
	rle := width >= 8 && width <= 0x7fff && len(rest) >= 4 && rest[0] == 2 && rest[1] == 2 && rest[2] & 0x80 == 0
	if !rle {
		// A flat file holds every row left in full; one too short whose next pixel is the
		// old 1 1 1 n run is the old form, where a flat pixel of (1, 1, 1, e) would not be.
		if len(rest) < rows * width * 4 {
			if len(rest) >= 4 && rest[0] == 1 && rest[1] == 1 && rest[2] == 1 do return "it uses the old Radiance run-length form, which is not read"
			return DAMAGED
		}
		copy(out, rest[:width * 4])
		at^ += width * 4
		return ""
	}
	if int(rest[2]) << 8 | int(rest[3]) != width do return DAMAGED
	at^ += 4
	for c in 0 ..< 4 {
		x := 0
		for x < width {
			if at^ >= len(data) do return DAMAGED
			n := int(data[at^])
			at^ += 1
			if n > 128 {
				n -= 128
				if x + n > width || at^ >= len(data) do return DAMAGED
				v := data[at^]
				at^ += 1
				for k in 0 ..< n do out[(x + k) * 4 + c] = v
			} else {
				if n == 0 || x + n > width || at^ + n > len(data) do return DAMAGED
				for k in 0 ..< n do out[(x + k) * 4 + c] = data[at^ + k]
				at^ += n
			}
			x += n
		}
	}
	return ""
}

// The direction pixel (`x`, `y`) of a `width` by `height` panorama looks along: +Y up,
// u = 0.5 straight ahead (-Z), as the shaders read it (u = atan(d.x, -d.z) / 2pi + 0.5).
direction :: proc(x, y, width, height: int) -> [3]f32 {
	theta := (f32(y) + 0.5) / f32(height) * math.PI
	phi := ((f32(x) + 0.5) / f32(width) - 0.5) * 2 * math.PI
	s := math.sin(theta)
	return {math.sin(phi) * s, math.cos(theta), -math.cos(phi) * s}
}

// The panorama's diffuse light as nine spherical harmonic coefficients (Ramamoorthi and
// Hanrahan 2001), already convolved with the cosine lobe and divided by pi: the shader's
// sum of coefficient times basis at a normal is the light a white Lambertian surface
// facing that way gives back. Summed in one fixed order, so the result never varies.
sh9 :: proc(img: Image) -> (sh: [9][3]f32) {
	acc: [9][3]f64
	d_phi := 2 * math.PI / f64(img.width)
	d_theta := math.PI / f64(img.height)
	for y in 0 ..< img.height {
		theta := (f64(y) + 0.5) * d_theta
		weight := math.sin(theta) * d_phi * d_theta
		for x in 0 ..< img.width {
			d := direction(x, y, img.width, img.height)
			basis := sh9_basis(d)
			p := img.pixels[y * img.width + x]
			for k in 0 ..< 9 {
				w := f64(basis[k]) * weight
				acc[k] += {f64(p.x) * w, f64(p.y) * w, f64(p.z) * w}
			}
		}
	}
	// The cosine lobe's convolution per band, over pi.
	band := [9]f64{1, 2.0 / 3, 2.0 / 3, 2.0 / 3, 0.25, 0.25, 0.25, 0.25, 0.25}
	for k in 0 ..< 9 do sh[k] = {f32(acc[k].x * band[k]), f32(acc[k].y * band[k]), f32(acc[k].z * band[k])}
	return
}

// The nine real spherical harmonics at unit direction `d`, in the order the shader sums
// them: l = 0; l = 1 as y, z, x; l = 2 as xy, yz, 3z^2 - 1, xz, x^2 - y^2.
sh9_basis :: proc(d: [3]f32) -> [9]f32 {
	x, y, z := d.x, d.y, d.z
	return {
		0.282095,
		0.488603 * y,
		0.488603 * z,
		0.488603 * x,
		1.092548 * x * y,
		1.092548 * y * z,
		0.315392 * (3 * z * z - 1),
		1.092548 * x * z,
		0.546274 * (x * x - y * y),
	}
}
