package main

import "core:fmt"
import "core:image"
import _ "core:image/bmp"
import _ "core:image/jpeg"
import _ "core:image/png"
import _ "core:image/qoi"
import _ "core:image/tga"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../camera"
import "../sculpt"
import "../ui"

// Brush alphas in the app: the built-in ones and any images loaded, which way a dab's
// image faces, and the Brush palette's Alpha section. The sculpting side is
// sculpt/alpha.odin.

// Which way the image's top faces on screen.
Alpha_Mode :: enum u8 {
	Stroke, // along the stroke, so a pattern runs with it
	Fixed,  // the screen's up, turned by the angle
	Random, // a new direction every dab, for texture without a visible repeat
}

ALPHA_MODE_NAMES := [Alpha_Mode]string {
	.Stroke = "Follow stroke",
	.Fixed  = "Fixed",
	.Random = "Random",
}

Alpha_Entry :: struct {
	name:  string, // owned
	alpha: sculpt.Alpha,
	thumb: [ALPHA_THUMB * ALPHA_THUMB]u8, // what the Alpha section draws: the image, small
}

// Thumbnail pixels a side: enough to tell the alphas apart in their 48 point tiles.
ALPHA_THUMB :: 20

// The built-in alphas, in the order the panel shows them.
alphas_init :: proc(app: ^App) {
	for shape in sculpt.Alpha_Shape {
		alpha_add(app, sculpt.ALPHA_SHAPE_NAMES[shape], sculpt.alpha_make(shape))
	}
}

alphas_destroy :: proc(app: ^App) {
	for &e in app.alphas {
		delete(e.name)
		sculpt.alpha_destroy(&e.alpha)
	}
	delete(app.alphas)
}

// Adds an alpha the app now owns, and returns its index.
@(private = "file")
alpha_add :: proc(app: ^App, name: string, alpha: sculpt.Alpha) -> int {
	e := Alpha_Entry{name = strings.clone(name), alpha = alpha}
	for j in 0 ..< ALPHA_THUMB {
		for i in 0 ..< ALPHA_THUMB {
			u := (f32(i) + 0.5) / ALPHA_THUMB * 2 - 1
			v := 1 - (f32(j) + 0.5) / ALPHA_THUMB * 2
			e.thumb[j * ALPHA_THUMB + i] = u8(clamp(sculpt.alpha_sample(&e.alpha, u, v), 0, 1) * 255 + 0.5)
		}
	}
	append(&app.alphas, e)
	return len(app.alphas) - 1
}

// The alpha with this name (a built-in's, any case) or, failing that, the image at
// this path loaded as a new one; selected for the brush. False, with a note, when
// neither works.
alpha_select :: proc(app: ^App, name_or_path: string) -> bool {
	for e, i in app.alphas {
		if strings.equal_fold(e.name, name_or_path) {
			app.brush.alpha = i
			return true
		}
	}
	return alpha_load(app, name_or_path)
}

// Loads an image (PNG, JPEG, BMP, TGA or QOI) as a new alpha and selects it. Its grey
// value sets the alpha, times its opacity where it has one, so a white shape on a
// transparent ground works as well as a grey image. The outcome becomes the file note;
// false when it failed.
alpha_load :: proc(app: ^App, path: string) -> bool {
	name := filepath.base(path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		file_note(app, true, "Cannot load alpha %s: %v", name, err)
		return false
	}
	defer delete(data)
	img, img_err := image.load_from_bytes(data)
	if img_err != nil {
		file_note(app, true, "Cannot load alpha %s: %v (PNG, JPEG, BMP, TGA and QOI images work)", name, img_err)
		return false
	}
	defer image.destroy(img)
	grey := make([]f32, img.width * img.height, context.temp_allocator)
	if !image_grey(img, grey) {
		file_note(app, true, "Cannot load alpha %s: %d-bit channels are not supported", name, img.depth)
		return false
	}
	alpha, ok := sculpt.alpha_from_grey(grey, img.width, img.height)
	if !ok {
		file_note(app, true, "Cannot load alpha %s: the image is empty", name)
		return false
	}
	stem := filepath.stem(path)
	app.brush.alpha = alpha_add(app, stem if stem != "" else name, alpha)
	if alpha.reach == 0 {
		// Kept and selected all the same, so the panel shows what was loaded.
		file_note(app, true, "Loaded alpha %s, but it is black all over, so it moves nothing", name)
	} else {
		file_note(app, false, "Loaded alpha %s: %d by %d pixels, used at %d by %d", name, img.width, img.height, alpha.size, alpha.size)
	}
	return true
}

// Fills `grey` (width × height) with the image's brightness, 0 to 1, times its opacity
// where it has one. False for channel depths other than 8 and 16 bits.
@(private = "file")
image_grey :: proc(img: ^image.Image, grey: []f32) -> bool {
	n := img.width * img.height
	channels := img.channels
	pixels := img.pixels.buf[:]
	value: proc(pixels: []u8, i: int) -> f32
	switch img.depth {
	case 8:
		value = proc(pixels: []u8, i: int) -> f32 {return f32(pixels[i]) / 255}
	case 16:
		// The loaders give 16-bit channels in the machine's own byte order.
		value = proc(pixels: []u8, i: int) -> f32 {return f32(mem.slice_data_cast([]u16, pixels)[i]) / 65535}
	case:
		return false
	}
	for p in 0 ..< n {
		k := p * channels
		switch channels {
		case 1:
			grey[p] = value(pixels, k)
		case 2:
			grey[p] = value(pixels, k) * value(pixels, k + 1)
		case:
			// Rec. 709 luma, as a sculptor reading the image's light and dark expects.
			luma := 0.2126 * value(pixels, k) + 0.7152 * value(pixels, k + 1) + 0.0722 * value(pixels, k + 2)
			grey[p] = luma * value(pixels, k + 3) if channels >= 4 else luma
		}
	}
	return true
}

// The selected alpha, or nil for the round brush. Grab moves what it holds as one
// piece, so it has none.
brush_alpha :: proc(app: ^App) -> ^sculpt.Alpha {
	i := app.brush.alpha
	if i < 0 || i >= len(app.alphas) || .Grab in BRUSHES[app.brush.kind].flags do return nil
	return &app.alphas[i].alpha
}

// How far the image's top is turned from the screen's up, counter-clockwise, in
// radians, for a dab now (or, `for_display`, for the brush outline, where Random shows
// the angle alone).
alpha_screen_angle :: proc(app: ^App, for_display := false) -> f32 {
	angle := math.to_radians(app.brush.alpha_angle)
	mode := app.brush.alpha_mode
	// The stroke modes that place the image themselves: Spray turns each dab its own way,
	// Roll lays the top along the stroke whatever the alpha's mode.
	if app.stroke.active && app.stroke.mode == .Spray do return angle if for_display else angle + app.stroke.turn
	if (app.stroke.mode if app.stroke.active else app.brush.stroke) == .Roll do mode = .Stroke
	switch mode {
	case .Fixed:
	case .Stroke:
		// The stroke's direction, once it has one; screen y grows downward. Between
		// strokes the outline faces up, as the next stroke's first dab will.
		d := app.stroke.dir
		if app.stroke.active && d != {} do angle += math.atan2(-d.x, -d.y)
	case .Random:
		if !for_display {
			// From the stroke's seed and a step a dab, so a replayed stroke turns each dab
			// the same way.
			st := &app.stroke
			angle += 2 * math.PI * stroke_random(st.seed, st.step, 5)
			st.step += 1
		}
	}
	return angle
}

// The world direction the image's top faces for a dab now: the screen direction
// alpha_screen_angle gives, in the view plane.
alpha_world_up :: proc(app: ^App) -> Vec3 {
	angle := alpha_screen_angle(app)
	view := camera.orbit_view(app.camera)
	right := Vec3{view[0, 0], view[0, 1], view[0, 2]}
	up := Vec3{view[1, 0], view[1, 1], view[1, 2]}
	return math.cos(angle) * up - math.sin(angle) * right
}

// Draws the brush outline for an alpha: its square, turned as the next dab's image
// will be, with a tick at its top edge.
draw_alpha_outline :: proc(app: ^App, o: Overlay, center: [2]f32, color: ui.Color) {
	angle := alpha_screen_angle(app, for_display = true)
	r := app.brush.radius_px
	// Screen axes of the image: its up (y grows downward on screen) and its right.
	up := [2]f32{-math.sin(angle), -math.cos(angle)}
	right := [2]f32{-up.y, up.x}
	corners := [4][2]f32{center + r * (up - right), center + r * (up + right), center + r * (right - up), center - r * (up + right)}
	overlay_polyline(o, corners[:], color, 1.5, closed = true)
	overlay_line(o, center + r * up, center + r * 1.25 * up, color, 1.5)
}

// The interface's Alpha section: the round brush and every alpha as thumbnails to tap,
// a button to load an image, and which way the image faces.
kit_alpha_section :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	PER_ROW :: 6
	cell := ui.fill_width(ctx) / PER_ROW
	count := len(app.alphas) + 1 // the round brush first
	for first := 0; first < count; first += PER_ROW {
		ui.begin(ctx, fmt.tprintf("alpha row %d", first), {direction = .Row})
		for j in first ..< min(first + PER_ROW, count) {
			i := j - 1
			name := "Round (no alpha)" if i < 0 else app.alphas[i].name
			a := ui.area(ctx, fmt.tprintf("%s##alpha %d", name, i), {cell, cell})
			if a.clicked do app.brush.alpha = i
			r := ui.Rect{a.rect.x + 4, a.rect.y + 4, a.rect.w - 8, a.rect.h - 8}
			ui.fill_rect(ctx, r, t.radius_small, {0, 0, 0, 0xff})
			if i < 0 {
				// The round brush's own falloff, as a disc.
				ui.fill_circle(ctx, {r.x + r.w * 0.5, r.y + r.h * 0.5}, r.w * 0.4, {0xc0, 0xc0, 0xc0, 0xff})
			} else {
				ui.grey_image(ctx, {r.x + 2, r.y + 2, r.w - 4, r.h - 4}, {ALPHA_THUMB, ALPHA_THUMB}, app.alphas[i].thumb[:], {0xff, 0xff, 0xff, 0xff})
			}
			selected := app.brush.alpha == i || (i < 0 && app.brush.alpha >= len(app.alphas))
			ui.stroke_rect(ctx, r, t.radius_small, t.accent if selected else t.border_strong, 2 if selected else 1)
			ui.tip(ctx, a.id, r, name)
		}
		ui.end(ctx)
	}
	if ui.button(ctx, "Load image...", .Bordered, glyph = ui.ICON_IMAGE) do file_dialog(app, .Alpha)
	if brush_alpha(app) != nil {
		modes: [len(Alpha_Mode)]string
		for m, i in Alpha_Mode do modes[i] = ALPHA_MODE_NAMES[m]
		if picked := ui.tabs(ctx, "alpha mode", modes[:], int(app.brush.alpha_mode)); picked >= 0 do app.brush.alpha_mode = Alpha_Mode(picked)
		_ = ui.slider(ctx, "Angle", &app.brush.alpha_angle, -180, 180, .Linear, fmt.tprintf("%.0f°", app.brush.alpha_angle))
	}
	ui.paragraph(ctx, "An alpha stamps each dab with an image (PNG, JPEG, BMP, TGA or QOI): white works fully, black not at all. Its square reaches past the circle where the image does.")
}
