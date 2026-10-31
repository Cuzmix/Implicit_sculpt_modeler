package main

import "core:fmt"
import "core:image"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:path/filepath"
import "core:strings"

import "../render"
import "../geom"

// MatCaps, as ZBrush's MatCap materials and Blender's MatCap shading: a picture of a lit
// sphere stands in for the lights (render/matcap.odin). The built-in ones are painted
// here, in code, from a few numbers each, so the app ships no image files and they stay
// sharp at any size; an image file can be loaded as one more (Material section, Load
// MatCap). Each tints by the material colour, so polypaint and the mask still show.

MATCAP_SIZE :: 256

// One built-in matcap: a sphere lit by a key light from the upper left, a sky above and a
// bounce from below, with a sharp highlight, a broad sheen and a rim, all in linear light.
Matcap_Recipe :: struct {
	label:       cstring,
	base:        [3]f32, // the surface's colour
	scatter:     [3]f32, // light that glows along the shadow's edge, as in wax and skin
	wrap:        f32, // how far the key light reaches past the side facing it
	sky, ground: f32, // light from above and from below, times base
	occlusion:   f32, // how much the light falls off toward the silhouette, as round forms do
	spec:        f32, // the sharp highlight's strength and tightness
	spec_power:  f32,
	sheen:       f32, // a broad gloss over the lit side
	sheen_power: f32,
	rim:         [3]f32, // light catching the edge, and how tight to it
	rim_power:   f32,
	bands:       int, // more than 1: cel shading in this many tones, hard-edged highlight and rim
}

@(rodata)
MATCAP_RECIPES := [?]Matcap_Recipe {
	// ZBrush's red wax: saturated, translucent at the terminator, glossy.
	{"Red wax", {0.42, 0.045, 0.03}, {0.30, 0.03, 0.015}, 0.40, 0.22, 0.04, 0.30, 0.55, 140, 0.10, 10, {0.20, 0.07, 0.05}, 3, 0},
	// Matte sculptor's clay with a cool rim, close to ZBrush's MatCap Gray in feel.
	{"Clay", {0.46, 0.32, 0.23}, {0.05, 0.015, 0.005}, 0.12, 0.20, 0.03, 0.55, 0.05, 30, 0.05, 6, {0.10, 0.11, 0.13}, 2.5, 0},
	// A neutral studio grey with a soft top light, as Blender's default matcap.
	{"Grey", {0.40, 0.40, 0.41}, {}, 0.18, 0.28, 0.03, 0.50, 0.22, 70, 0.08, 8, {0.16, 0.17, 0.20}, 4, 0},
	// Warm skin with red light along the shadow's edge and a slight oily sheen.
	{"Skin", {0.58, 0.34, 0.25}, {0.22, 0.04, 0.02}, 0.45, 0.20, 0.04, 0.40, 0.14, 45, 0.08, 8, {0.22, 0.14, 0.12}, 3, 0},
	// Pale, glossy and cool at the rim, which shows small forms and tool marks hard.
	{"Pearl", {0.62, 0.61, 0.60}, {0.05, 0.03, 0.06}, 0.15, 0.35, 0.06, 0.40, 0.45, 90, 0.16, 10, {0.30, 0.24, 0.40}, 3, 0},
	// Cel shading in three tones with a hard highlight and rim, for stylised work.
	{"Toon", {0.55, 0.58, 0.70}, {}, 0.25, 0.25, 0.10, 0, 1.0, 120, 0, 1, {0.45, 0.48, 0.60}, 5, 3},
}

// Material.matcap's value for the image loaded with Load MatCap; 1 + an index into
// MATCAP_RECIPES picks a built-in, 0 none.
MATCAP_IMAGE :: len(MATCAP_RECIPES) + 1

// The light every built-in matcap shares, in view space (toward the upper left, toward
// the viewer), so switching matcaps keeps the shadows where they were.
MATCAP_KEY :: [3]f32{-0.6, 0.7, 0.38}

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
	d := linalg.dot(n, key)
	diffuse := clamp((d + m.wrap) / (1 + m.wrap), 0, 1)
	spec := math.pow(max(linalg.dot(n, half), 0), m.spec_power)
	rim := math.pow(1 - n.z, m.rim_power)
	if m.bands > 1 {
		// Cel shading: the light in steps, each edge a little soft so it stays smooth
		// when filtered, and the highlight and rim as hard shapes.
		steps := f32(m.bands - 1)
		t := diffuse * steps
		diffuse = (math.floor(t) + math.smoothstep(f32(0.45), 0.55, t - math.floor(t))) / steps
		spec = math.smoothstep(f32(0.5), 0.56, spec)
		rim = math.smoothstep(f32(0.35), 0.42, rim)
	}
	hemi := m.ground + (m.sky - m.ground) * (n.y * 0.5 + 0.5)
	// The scatter glows where the light grazes the surface and fades into the shadow.
	glow := math.exp(-(d - 0.05) * (d - 0.05) / 0.06)
	edge := 1 - m.occlusion * (1 - n.z) * (1 - n.z)
	c := m.base * (diffuse + hemi) * edge + m.scatter * glow
	c += m.spec * spec + m.sheen * math.pow(max(linalg.dot(n, half), 0), m.sheen_power)
	c += m.rim * rim
	return c
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
	return nil
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
	if tex == nil {
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
	if img_err != nil do return nil, 0, 0, fmt.tprintf("%v (PNG, JPEG, BMP, TGA and QOI images work)", img_err)
	defer image.destroy(img)
	rgba = make([]u8, img.width * img.height * 4, allocator)
	if !image_rgba8(img, rgba) {
		delete(rgba, allocator)
		return nil, 0, 0, fmt.tprintf("%d-bit channels are not supported", img.depth)
	}
	return rgba, img.width, img.height, ""
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
