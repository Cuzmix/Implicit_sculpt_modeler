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
import imgui "deps:odin-imgui"

import "../camera"
import "../sculpt"

// Brush alphas in the app: the built-in ones and any images loaded, which way a dab's
// image faces, and the Alpha section of the Tools panel. The sculpting side is
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
	thumb: [ALPHA_THUMB * ALPHA_THUMB]u8, // what the panel draws: the image, small
}

// Thumbnail pixels a side, each drawn ALPHA_THUMB_PX screen pixels square.
ALPHA_THUMB :: 20
ALPHA_THUMB_PX :: 2

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
	if i < 0 || i >= len(app.alphas) || app.brush.kind == .Grab do return nil
	return &app.alphas[i].alpha
}

// How far the image's top is turned from the screen's up, counter-clockwise, in
// radians, for a dab now (or, `for_display`, for the brush outline, where Random shows
// the angle alone).
alpha_screen_angle :: proc(app: ^App, for_display := false) -> f32 {
	angle := math.to_radians(app.brush.alpha_angle)
	switch app.brush.alpha_mode {
	case .Fixed:
	case .Stroke:
		// The stroke's direction, once it has one; screen y grows downward. Between
		// strokes the outline faces up, as the next stroke's first dab will.
		d := app.stroke.dir
		if app.stroke.active && d != {} do angle += math.atan2(-d.x, -d.y)
	case .Random:
		if !for_display {
			// A cheap generator is plenty: the angle only has to look unpatterned.
			app.alpha_seed = app.alpha_seed * 1664525 + 1013904223
			angle += f32(app.alpha_seed >> 8) / f32(1 << 24) * 2 * math.PI
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
draw_alpha_outline :: proc(app: ^App, list: ^imgui.DrawList, center: imgui.Vec2, color: u32) {
	angle := alpha_screen_angle(app, for_display = true)
	r := app.brush.radius_px
	// Screen axes of the image: its up (y grows downward on screen) and its right.
	up := imgui.Vec2{-math.sin(angle), -math.cos(angle)}
	right := imgui.Vec2{-up.y, up.x}
	corners := [4]imgui.Vec2{center + r * (up - right), center + r * (up + right), center + r * (right - up), center - r * (up + right)}
	imgui.DrawList_AddPolyline(list, &corners[0], 4, color, 1.5, imgui.DrawFlags_Closed)
	imgui.DrawList_AddLine(list, center + r * up, center + r * 1.25 * up, color, 1.5)
}

// The Alpha section of the Tools panel: the round brush and every alpha as thumbnails,
// a button to load an image, and which way the image faces.
draw_alpha_section :: proc(app: ^App) {
	imgui.SeparatorText("Alpha")
	rgba :: proc(c: [4]f32) -> u32 {return imgui.ColorConvertFloat4ToU32(c)}
	SIZE :: f32(ALPHA_THUMB * ALPHA_THUMB_PX)
	PER_ROW :: 6
	list := imgui.GetWindowDrawList()
	for i in -1 ..< len(app.alphas) {
		if (i + 1) % PER_ROW != 0 do imgui.SameLine()
		o := imgui.GetCursorScreenPos()
		if imgui.InvisibleButton(fmt.ctprintf("alpha%d", i), {SIZE, SIZE}) do app.brush.alpha = i
		name := "Round (no alpha)" if i < 0 else app.alphas[i].name
		if imgui.IsItemHovered() do imgui.SetTooltip("%s", fmt.ctprintf("%s", name))
		imgui.DrawList_AddRectFilled(list, o, o + SIZE, rgba({0, 0, 0, 1}))
		if i < 0 {
			// The round brush's own falloff, as a disc.
			imgui.DrawList_AddCircleFilled(list, o + SIZE / 2, SIZE * 0.42, rgba({0.75, 0.75, 0.75, 1}), 24)
		} else {
			thumb := &app.alphas[i].thumb
			for j in 0 ..< ALPHA_THUMB {
				for k in 0 ..< ALPHA_THUMB {
					value := thumb[j * ALPHA_THUMB + k]
					if value < 8 do continue
					g := f32(value) / 255
					p := o + {f32(k), f32(j)} * ALPHA_THUMB_PX
					imgui.DrawList_AddRectFilled(list, p, p + ALPHA_THUMB_PX, rgba({g, g, g, 1}))
				}
			}
		}
		selected := app.brush.alpha == i || (i < 0 && app.brush.alpha >= len(app.alphas))
		border := rgba({0.95, 0.8, 0.45, 1} if selected else {1, 1, 1, 0.2})
		imgui.DrawList_AddRect(list, o, o + SIZE, border, 0, 2 if selected else 1)
	}
	if imgui.Button("Load image...") do file_dialog(app, .Alpha)
	imgui.SameLine()
	imgui.TextDisabled("PNG, JPEG, BMP, TGA, QOI")
	imgui.BeginDisabled(brush_alpha(app) == nil)
	for mode in Alpha_Mode {
		if mode != .Stroke do imgui.SameLine()
		if imgui.RadioButton(fmt.ctprintf("%s", ALPHA_MODE_NAMES[mode]), app.brush.alpha_mode == mode) do app.brush.alpha_mode = mode
	}
	imgui.SliderFloat("Angle", &app.brush.alpha_angle, -180, 180, "%.0f°")
	imgui.EndDisabled()
	imgui.TextDisabled("An alpha stamps each dab with an image: white\nworks fully, black not at all. Its square reaches\npast the circle where the image does.")
}
