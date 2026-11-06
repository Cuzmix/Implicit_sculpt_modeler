package main

import "core:c"
import "core:fmt"
import "core:image"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:path/filepath"
import "core:strings"

import stbi "vendor:stb/image"

import "../render"
import "../geom"

// MatCaps, as ZBrush's MatCap materials and Blender's MatCap shading: a picture of a lit
// sphere stands in for the lights (render/matcap.odin). The built-in ones are painted
// here, in code, from a few numbers each, so the app ships no image files and they stay
// sharp at any size; an image file can be loaded as one more (Material section, Load
// MatCap). Each tints by the material colour, so polypaint and the mask still show.

MATCAP_SIZE :: 256

// One built-in matcap: a sphere lit by one soft key light from the upper left front, as a
// large softbox, with a faint sky. The light's value (0 to 1) picks the colour from a ramp,
// as wax and clay photograph: Red wax goes from saturated orange-red in the shadow to a pale
// pink on top, while oil clay keeps one low saturation all the way. Toward the silhouette
// the value only falls, so the edge reads as a dark outline and never as a rim; a broad,
// dim gloss in the material's tint sits on the lit side and never reaches the edge.
Matcap_Recipe :: struct {
	label:       cstring,
	// The colours at evenly spaced light values from 0 (full shadow) to 1 (full light),
	// sRGB as a picker shows them, blended in linear light.
	ramp:        [MATCAP_STOPS][3]u8,
	softness:    f32, // the half-Lambert's exponent: higher keeps more of the sphere in shade
	key:         f32, // the key light's share of the value
	sky:         f32, // a faint light from above, so the underside is not flat black
	edge:        f32, // how far the value falls toward the silhouette
	broad:       f32, // a wide, dim gloss, as satin clay and wax have
	broad_power: f32,
	tight:       f32, // a smaller gloss inside it, never a white dot except on Toon
	tight_power: f32,
	gloss:       [3]u8, // the gloss's tint, sRGB
	bands:       int, // more than 1: cel shading in this many tones and a hard-edged highlight
}

// The ramp's stops: enough for the hue to drift between shadow and light without banding.
MATCAP_STOPS :: 9

@(rodata)
MATCAP_RECIPES := [?]Matcap_Recipe {
	// ZBrush's red wax, its colours measured from a ZBrush screenshot band by band: the
	// shadow saturated orange-red, the light a desaturated pink, no hot spot.
	{"Red wax", {{22, 5, 2}, {52, 16, 8}, {80, 31, 22}, {104, 46, 36}, {122, 63, 54}, {136, 80, 74}, {150, 98, 95}, {164, 117, 119}, {185, 140, 142}}, 2.6, 0.95, 0.08, 0.5, 0.07, 7, 0.05, 36, {255, 205, 205}, 0},
	// Oil-based sculpting clay as scanned for ZBrush's clay materials: low, even saturation,
	// a satin sheen, crevices that fall almost to black. Brown is the classic modelling clay.
	{"Brown clay", {{30, 20, 14}, {59, 42, 32}, {81, 57, 46}, {101, 71, 59}, {122, 87, 72}, {140, 101, 86}, {158, 118, 102}, {178, 138, 122}, {196, 160, 146}}, 2.4, 0.95, 0.08, 0.5, 0.05, 14, 0.045, 70, {245, 200, 182}, 0},
	// The same clay in a neutral, barely cool grey: the matcap the plain Solid view uses.
	{"Grey clay", {{22, 25, 25}, {46, 49, 49}, {68, 72, 72}, {89, 93, 94}, {109, 114, 114}, {129, 134, 135}, {149, 153, 154}, {170, 174, 174}, {194, 196, 197}}, 2.4, 0.95, 0.08, 0.5, 0.05, 14, 0.045, 70, {242, 245, 246}, 0},
	// The same clay in olive green, the colour of the older oil clays.
	{"Green clay", {{22, 24, 19}, {46, 48, 40}, {63, 65, 54}, {77, 79, 67}, {95, 98, 82}, {113, 116, 96}, {131, 134, 112}, {146, 149, 128}, {160, 163, 142}}, 2.4, 0.95, 0.08, 0.5, 0.05, 14, 0.045, 70, {200, 203, 177}, 0},
	// Warm skin: a red-brown shadow warming to peach, with a slight oily sheen.
	{"Skin", {{40, 12, 8}, {82, 34, 24}, {117, 58, 42}, {154, 84, 63}, {184, 118, 93}, {208, 146, 119}, {224, 173, 150}, {235, 194, 175}, {244, 212, 196}}, 2.2, 0.95, 0.1, 0.45, 0.06, 10, 0.04, 50, {255, 230, 220}, 0},
	// Pale and glossy with cool shade, which shows small forms and tool marks hard.
	{"Pearl", {{40, 38, 48}, {85, 83, 92}, {111, 109, 119}, {142, 140, 147}, {171, 169, 174}, {194, 192, 196}, {212, 210, 212}, {228, 226, 226}, {240, 238, 236}}, 2.2, 0.95, 0.12, 0.45, 0.12, 10, 0.1, 60, {255, 250, 255}, 0},
	// Cel shading in three tones with a hard highlight, for stylised work.
	{"Toon", {{60, 64, 84}, {89, 93, 114}, {109, 114, 136}, {126, 131, 154}, {140, 146, 170}, {160, 165, 187}, {176, 182, 202}, {191, 197, 215}, {205, 210, 228}}, 3, 0.9, 0.1, 0.3, 0, 1, 0.5, 120, {255, 255, 255}, 3},
}

// Material.matcap's value for the image loaded with Load MatCap; 1 + an index into
// MATCAP_RECIPES picks a built-in, 0 none.
MATCAP_IMAGE :: len(MATCAP_RECIPES) + 1

// The light every built-in matcap shares, in view space (toward the upper left, toward
// the viewer), so switching matcaps keeps the shadows where they were.
MATCAP_KEY :: [3]f32{-0.45, 0.62, 0.64}

// Paints `recipe` into `out` (size by size RGBA8 sRGB, rows top to bottom). Outside the
// sphere each pixel takes the edge's colour, so filtering at the rim finds no background.
matcap_paint :: proc(recipe: Matcap_Recipe, size: int, out: []u8) {
	assert(len(out) == size * size * 4)
	key := linalg.normalize(MATCAP_KEY)
	half := linalg.normalize(key + {0, 0, 1})
	for y in 0 ..< size {
		for x in 0 ..< size {
			// The picture spans the sphere: its middle faces the viewer, up is up.
			p := [2]f32{(f32(x) + 0.5) / f32(size) * 2 - 1, 1 - (f32(y) + 0.5) / f32(size) * 2}
			r2 := linalg.dot(p, p)
			if r2 > 1 {
				p /= math.sqrt(r2)
				r2 = 1
			}
			n := [3]f32{p.x, p.y, math.sqrt(max(1 - r2, 0))}
			c := matcap_light(recipe, n, key, half)
			at := (y * size + x) * 4
			for k in 0 ..< 3 do out[at + k] = u8(math.round(geom.srgb_encode(c[k]) * 255))
			out[at + 3] = 255
		}
	}
}

// The linear colour of the recipe's sphere where its normal is `n`.
@(private = "file")
matcap_light :: proc(m: Matcap_Recipe, n, key, half: [3]f32) -> [3]f32 {
	// A raised half-Lambert: a wide terminator with no hard line to alias on fine forms.
	lit := math.pow(clamp(linalg.dot(n, key) * 0.5 + 0.5, 0, 1), m.softness)
	edge := 1 - m.edge * (1 - n.z) * (1 - n.z)
	v := clamp((lit * m.key + m.sky * (n.y * 0.5 + 0.5)) * edge, 0, 1)
	nh := max(linalg.dot(n, half), 0)
	spec := m.broad * math.pow(nh, m.broad_power) + m.tight * math.pow(nh, m.tight_power)
	if m.bands > 1 {
		// Cel shading: the light in steps, each edge a little soft so it stays smooth
		// when filtered, and the highlight as a hard shape.
		steps := f32(m.bands - 1)
		t := v * steps
		v = (math.floor(t) + math.smoothstep(f32(0.45), 0.55, t - math.floor(t))) / steps
		spec = m.tight * math.smoothstep(f32(0.5), 0.56, math.pow(nh, m.tight_power))
	}
	at := v * (MATCAP_STOPS - 1)
	i := min(int(at), MATCAP_STOPS - 2)
	f := at - f32(i)
	c := matcap_linear(m.ramp[i]) * (1 - f) + matcap_linear(m.ramp[i + 1]) * f
	return c + matcap_linear(m.gloss) * (spec * edge)
}

// An sRGB colour as linear light.
@(private = "file")
matcap_linear :: proc(c: [3]u8) -> [3]f32 {
	return {geom.srgb_decode(f32(c.r) / 255), geom.srgb_decode(f32(c.g) / 255), geom.srgb_decode(f32(c.b) / 255)}
}

// The recipe's middle colour in linear light, what an export writes as the base colour.
matcap_base :: proc(m: Matcap_Recipe) -> [3]f32 {
	return matcap_linear(m.ramp[MATCAP_STOPS / 2])
}

// Paints the built-in matcaps into textures; one that cannot be made stays nil, and its
// presets then draw with the lights instead.
matcaps_create :: proc(app: ^App) {
	pixels := make([]u8, MATCAP_SIZE * MATCAP_SIZE * 4)
	defer delete(pixels)
	for recipe, i in MATCAP_RECIPES {
		matcap_paint(recipe, MATCAP_SIZE, pixels)
		app.matcaps[i] = render.matcap_create(&app.renderer, pixels, MATCAP_SIZE, MATCAP_SIZE)
	}
}

matcaps_destroy :: proc(app: ^App) {
	for &tex in app.matcaps do render.matcap_destroy(&app.renderer, &tex)
	render.matcap_destroy(&app.renderer, &app.matcap_image)
	delete(app.matcap_path)
	app.matcap_path = ""
}

// The texture material `m` shades with, or nil for the lights.
material_matcap :: proc(app: ^App, m: Material) -> render.Texture {
	switch {
	case m.matcap == MATCAP_IMAGE:      return app.matcap_image
	case m.matcap > 0 && m.matcap <= len(MATCAP_RECIPES): return app.matcaps[m.matcap - 1]
	case m.matcap >= PACK_MATCAP:
		// Made at the frame's end when first used (pack_matcaps_settle); until then, the
		// lights.
		if mc, ok := pack_matcap_at(app, m.matcap - PACK_MATCAP); ok do return mc.texture
	}
	return 0
}

// Loads an image (PNG, JPEG, BMP, TGA or QOI) of a lit sphere as the matcap and makes the
// Custom material use it, in white, so the picture shows as painted. The outcome becomes
// the file note; false when it failed, leaving the matcap and material that were there.
matcap_load :: proc(app: ^App, path: string) -> bool {
	if !matcap_image_load(app, path) do return false
	material_set(app, {label = "Custom", selected = {1, 1, 1, 1}, idle = MATCAP_IDLE, matcap = MATCAP_IMAGE})
	return true
}

// Loads an image as the matcap the Custom material can use, leaving the materials as they
// are, as the settings file brings back the one loaded last (quietly, unless it fails). A
// failure becomes the file note and keeps the image that was there.
matcap_image_load :: proc(app: ^App, path: string, quiet := false) -> bool {
	name := filepath.base(path)
	data, err := file_read_any(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot load MatCap %s: %v", name, err)
		return false
	}
	defer delete(data)
	rgba, width, height, failed := matcap_pixels(data)
	defer delete(rgba)
	if failed != "" {
		file_note(app, true, "Cannot load MatCap %s: %s", name, failed)
		return false
	}
	tex := render.matcap_create(&app.renderer, rgba, width, height)
	if tex == 0 {
		file_note(app, true, "Cannot load MatCap %s: the GPU refused a %d x %d texture", name, width, height)
		return false
	}
	render.matcap_destroy(&app.renderer, &app.matcap_image)
	app.matcap_image = tex
	delete(app.matcap_path)
	app.matcap_path = strings.clone(path)
	// The frame keys know the texture by its address, which the new one may share with
	// the one just released, so the idle cache would keep the old picture.
	render.viewport_invalidate(&app.target)
	if !quiet do file_note(app, false, "Loaded MatCap %s (%d x %d)", name, width, height)
	return true
}

// An image file's pixels as RGBA8 for a matcap, or why it cannot be one ("" when it can).
// Pure, so a pack's install thread checks its matcaps with it.
matcap_pixels :: proc(data: []u8, allocator := context.allocator) -> (rgba: []u8, width, height: int, failed: string) {
	img, img_err := image.load_from_bytes(data)
	if img_err != nil {
		// Odin's own readers leave out progressive JPEGs, which most pictures saved from the
		// web are, and a few rarer PNG and BMP kinds: stb_image reads those.
		if pixels, w, h, ok := stb_pixels(data, allocator); ok do return pixels, w, h, ""
		return nil, 0, 0, fmt.tprintf("%v (PNG, JPEG, BMP, TGA and QOI images work)", img_err)
	}
	defer image.destroy(img)
	rgba = make([]u8, img.width * img.height * 4, allocator)
	if !image_rgba8(img, rgba) {
		delete(rgba, allocator)
		return nil, 0, 0, fmt.tprintf("%d-bit channels are not supported", img.depth)
	}
	return rgba, img.width, img.height, ""
}

// An image file's pixels as RGBA8 read by stb_image, for what Odin's own readers refuse;
// false when stb_image refuses it too. Safe on any thread: it keeps no state between calls.
stb_pixels :: proc(data: []u8, allocator := context.allocator) -> (rgba: []u8, width, height: int, ok: bool) {
	if len(data) == 0 || len(data) > int(max(c.int)) do return
	w, h, channels: c.int
	pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &channels, 4)
	if pixels == nil do return
	defer stbi.image_free(pixels)
	if w <= 0 || h <= 0 do return
	rgba = make([]u8, int(w) * int(h) * 4, allocator)
	copy(rgba, pixels[:len(rgba)])
	return rgba, int(w), int(h), true
}

// The colour other objects are tinted with under a matcap: the picture a little dimmed,
// so the selected object still stands out.
MATCAP_IDLE :: [4]f32{0.68, 0.68, 0.70, 1}

// An image's pixels as RGBA8, rows top to bottom: grey spread to red, green and blue,
// opaque where it has no alpha, 16-bit channels rounded to 8. False for other depths.
@(private)
image_rgba8 :: proc(img: ^image.Image, out: []u8) -> bool {
	pixels := img.pixels.buf[:]
	channels := img.channels
	value: proc(pixels: []u8, i: int) -> u8
	switch img.depth {
	case 8:  value = proc(pixels: []u8, i: int) -> u8 {return pixels[i]}
	case 16: value = proc(pixels: []u8, i: int) -> u8 {return u8((u32(mem.slice_data_cast([]u16, pixels)[i]) + 128) / 257)}
	case:    return false
	}
	for p in 0 ..< img.width * img.height {
		k, at := p * channels, p * 4
		switch channels {
		case 1, 2:
			g := value(pixels, k)
			out[at], out[at + 1], out[at + 2] = g, g, g
		case:
			for c in 0 ..< 3 do out[at + c] = value(pixels, k + c)
		}
		out[at + 3] = value(pixels, k + channels - 1) if channels == 2 || channels == 4 else 255
	}
	return true
}

// The matcap's name for the Material section.
matcap_label :: proc(app: ^App, matcap: int) -> string {
	if matcap == MATCAP_IMAGE do return filepath.stem(app.matcap_path) if app.matcap_path != "" else "image"
	if mc, ok := pack_matcap_at(app, matcap - PACK_MATCAP); ok && matcap >= PACK_MATCAP do return mc.stem
	if matcap > 0 && matcap <= len(MATCAP_RECIPES) do return fmt.tprintf("%s", MATCAP_RECIPES[matcap - 1].label)
	return ""
}
